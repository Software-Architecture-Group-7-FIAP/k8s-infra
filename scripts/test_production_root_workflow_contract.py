from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def _choice_options(workflow: str, input_name: str) -> list[str]:
    input_match = re.search(
        rf"(?ms)^      {re.escape(input_name)}:\n(?P<section>.*?)(?=^      [\w-]+:|^permissions:)",
        workflow,
    )
    if input_match is None:
        raise AssertionError(f"workflow input '{input_name}' was not found")

    options_match = re.search(
        r"(?m)^        options:\n((?:^          - [^\n]+\n?)+)",
        input_match.group("section"),
    )
    if options_match is None:
        raise AssertionError(f"workflow input '{input_name}' has no choice options")

    return [line.strip()[2:].strip() for line in options_match.group(1).splitlines()]


class ProductionRootWorkflowContractTests(unittest.TestCase):
    def test_production_resolves_to_its_isolated_terraform_root(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "terraform_root.py"), "production"],
            cwd=ROOT,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "envs/production")
        self.assertTrue((ROOT / result.stdout.strip()).is_dir())

    def test_cluster_plan_and_apply_offer_production_as_a_stack(self) -> None:
        expected_stacks = ["hml", "platform", "production"]

        for workflow_name in ("cluster-ci.yml", "cluster-apply.yml"):
            workflow = (WORKFLOWS / workflow_name).read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_name):
                self.assertEqual(_choice_options(workflow, "stack"), expected_stacks)
                self.assertIn("hml|platform|production)", workflow)

    def test_production_plan_and_apply_keep_the_exact_root_readiness_gate(self) -> None:
        root_ready_env = (
            "K8S_PRODUCTION_TERRAFORM_ROOT_READY: "
            "${{ vars.K8S_PRODUCTION_TERRAFORM_ROOT_READY || 'false' }}"
        )
        exact_gate = (
            'if [[ "$K8S_PRODUCTION_TERRAFORM_ROOT_READY" != "true" || '
            '"$REQUESTED_SESSION_MODE" != "prd-window" ]]'
        )

        for workflow_name in ("cluster-ci.yml", "cluster-apply.yml"):
            workflow = (WORKFLOWS / workflow_name).read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_name):
                self.assertIn(root_ready_env, workflow)
                self.assertIn(exact_gate, workflow)
                self.assertIn("ENVIRONMENT_SCHEDULE_ENABLED", workflow)
                self.assertIn("PRD_LIFECYCLE_AUTOMATION_READY", workflow)
                self.assertIn("PRD_COST_EXCEPTION_APPROVED", workflow)

    def test_production_apply_uses_a_dedicated_role_and_the_existing_saved_plan(self) -> None:
        workflow = (WORKFLOWS / "cluster-apply.yml").read_text(encoding="utf-8")
        role_check = workflow.split(
            "- name: Require the exact isolated production deploy role before AWS credentials",
            maxsplit=1,
        )[1].split("\n      - ", maxsplit=1)[0]
        production_role = workflow.split(
            "name: Assume the dedicated production deploy role", maxsplit=1
        )[1].split("\n      - ", maxsplit=1)[0]
        shared_role = workflow.split(
            "name: Assume the shared staging deploy role", maxsplit=1
        )[1].split("\n      - ", maxsplit=1)[0]

        self.assertIn("AWS_PRODUCTION_DEPLOY_ROLE_ARN", role_check)
        self.assertIn(
            "arn:aws:iam::035611741563:role/auto-shop/gh-deploy-k8s-production",
            role_check,
        )
        self.assertIn("if: inputs.stack == 'production'", production_role)
        self.assertIn("vars.AWS_PRODUCTION_DEPLOY_ROLE_ARN", production_role)
        self.assertIn("if: inputs.stack == 'platform'", shared_role)
        self.assertIn('manifest_key="$PLAN_PREFIX/$PLAN_ID/apply/manifest-$STACK.json"', workflow)
        self.assertIn("verify-attestation", workflow)
        self.assertIn('terraform -chdir="$terraform_root" apply', workflow)

    def test_production_apply_keeps_lifecycle_authorization_and_private_runner_checks(self) -> None:
        workflow = (WORKFLOWS / "cluster-apply.yml").read_text(encoding="utf-8")

        self.assertIn("assert_unique_lifecycle_dispatch.py", workflow)
        self.assertIn("consume_lifecycle_dispatch.py", workflow)
        self.assertIn("require_trusted_lifecycle_operator.py", workflow)
        self.assertIn("verify_plan_run.py", workflow)
        self.assertIn("if: inputs.stack == 'platform' || inputs.stack == 'hml' || inputs.stack == 'production'", workflow)


if __name__ == "__main__":
    unittest.main()
