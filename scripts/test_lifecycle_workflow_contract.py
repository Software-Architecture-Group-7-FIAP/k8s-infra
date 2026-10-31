from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LifecycleWorkflowContractTests(unittest.TestCase):
    def test_lifecycle_consumers_bind_current_actor_before_aws_credentials(self) -> None:
        for workflow_name in ("ci.yml", "apply.yml", "destroy.yml", "orphan-audit.yml"):
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            self.assertIn("LIFECYCLE_TRIGGERING_ACTOR: ${{ github.triggering_actor }}", workflow)
            jobs = workflow.split("jobs:", maxsplit=1)[1]
            for match in re.finditer(r"(?m)^  [A-Za-z0-9_-]+:\s*$", jobs):
                next_job = re.search(r"(?m)^  [A-Za-z0-9_-]+:\s*$", jobs[match.end() :])
                end = match.end() + next_job.start() if next_job else len(jobs)
                job = jobs[match.start() : end]
                role_step = "aws-actions/configure-aws-credentials@"
                if role_step not in job:
                    continue
                gate = "require_trusted_lifecycle_operator.py"
                self.assertIn(gate, job, f"{workflow_name} job lacks an actor gate before AWS credentials")
                self.assertLess(
                    job.index(gate),
                    job.index(role_step),
                    f"{workflow_name} gates the actor after AWS credentials",
                )

    def test_bootstrap_oidc_environment_map_matches_the_configured_workflows(self) -> None:
        variables = (ROOT / "envs" / "staging" / "bootstrap" / "variables.tf").read_text(
            encoding="utf-8"
        )
        bootstrap = (ROOT / "envs" / "staging" / "bootstrap" / "main.tf").read_text(
            encoding="utf-8"
        )
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        branch_pipeline = (ROOT / ".github" / "workflows" / "branch-pipeline.yml").read_text(
            encoding="utf-8"
        )

        expected_deploy_environments = {
            "k8s-infra": '["staging"]',
            "database-infra": '["staging", "hml", "production"]',
            "lambda-auth": '["hml", "prd"]',
            "auto-shop-system": '["hml", "prd"]',
        }
        expected_deploy_workflows = {
            "k8s-infra": (
                ("staging", "Apply", "refs/heads/main"),
                ("staging", "Destroy", "refs/heads/main"),
            ),
            "database-infra": (
                ("staging", "Apply database staging", "refs/heads/main"),
                ("staging", "Destroy database staging", "refs/heads/main"),
                ("hml", "Database infrastructure delivery", "refs/heads/develop"),
                ("production", "Database infrastructure delivery", "refs/heads/main"),
            ),
            "lambda-auth": (
                ("hml", "Promote lambda-auth", "refs/heads/main"),
                ("prd", "Promote lambda-auth", "refs/heads/main"),
            ),
            "auto-shop-system": (
                ("hml", "CD Staging", "refs/heads/develop"),
                ("prd", "CD Production", "refs/heads/main"),
                ("prd", "Lifecycle ledger bootstrap", "refs/heads/main"),
            ),
        }
        repositories = variables.split('variable "repositories" {', maxsplit=1)[1]
        for repository, environments in expected_deploy_environments.items():
            with self.subTest(repository=repository):
                repository_config = repositories.split(f'"{repository}" = {{', maxsplit=1)[1].split(
                    "\n    }", maxsplit=1
                )[0]
                self.assertIn(
                    f"deploy_environments = {environments}", repository_config
                )
                for environment, workflow, ref in expected_deploy_workflows[repository]:
                    self.assertIn(
                        f'{{ environment = "{environment}", workflow = "{workflow}", ref = "{ref}"',
                        repository_config,
                    )

        k8s_repository_config = repositories.split('"k8s-infra" = {', maxsplit=1)[1].split(
            "\n    }", maxsplit=1
        )[0]
        expected_k8s_workflow_refs = (
            "Software-Architecture-Group-7-FIAP/k8s-infra/.github/workflows/apply.yml@refs/heads/main",
            "Software-Architecture-Group-7-FIAP/k8s-infra/.github/workflows/destroy.yml@refs/heads/main",
        )
        for workflow_ref in expected_k8s_workflow_refs:
            self.assertIn(f'workflow_ref = "{workflow_ref}"', k8s_repository_config)
        self.assertNotIn("branch-pipeline.yml", k8s_repository_config)
        self.assertNotIn('environment = "production"', k8s_repository_config)

        plan_environments = variables.split('variable "plan_environments" {', maxsplit=1)[1].split(
            '\nvariable "plan_state_keys" {', maxsplit=1
        )[0]
        self.assertIn('"k8s-infra" = ["staging"]', plan_environments)
        self.assertNotIn('"database-infra"', plan_environments)

        self.assertIn('repo == "auto-shop-system"', bootstrap)
        self.assertIn('"repo:${var.github_org}/${repo}"', bootstrap)
        self.assertIn(
            '"repo:${var.github_org}@${local.github_owner_id}/'
            '${repo}@${local.repository_ids[repo]}"',
            bootstrap,
        )
        self.assertIn('"database-infra"   = "1420971567"', bootstrap)
        self.assertIn('"k8s-infra"        = "1431503198"', bootstrap)
        self.assertIn('"lambda-auth"      = "1418895421"', bootstrap)
        plan_trust = bootstrap.split('data "aws_iam_policy_document" "plan_trust" {', maxsplit=1)[
            1
        ].split("# Deploy role:", maxsplit=1)[0]
        self.assertEqual(plan_trust.count('test     = "StringEquals"'), 2)
        self.assertNotIn("StringLike", plan_trust)
        self.assertNotIn("*", plan_trust)
        for claim in ("aud", "sub"):
            self.assertIn(f'variable = "${{local.oidc_host}}:{claim}"', plan_trust)
        for unsupported_claim in ("workflow", "ref"):
            self.assertNotIn(
                f'variable = "${{local.oidc_host}}:{unsupported_claim}"', plan_trust
            )
        self.assertIn('default     = "Software-Architecture-Group-7-FIAP"', variables)
        self.assertIn(
            'plan    = "${var.github_org}/k8s-infra/.github/workflows/ci.yml@refs/heads/main"',
            bootstrap,
        )
        self.assertIn("local.k8s_workflow_ref.plan", plan_trust)
        self.assertIn('"${local.repo_subject[each.key]}:ref:refs/heads/main"', plan_trust)
        self.assertIn(":environment:staging:workflow_ref:${local.k8s_workflow_ref.plan}", plan_trust)

        deploy_trust = bootstrap.split(
            'data "aws_iam_policy_document" "deploy_trust" {', maxsplit=1
        )[1].split(
            '# Read-only identity for the coordinator-triggered staging orphan audit.', maxsplit=1
        )[0]
        self.assertIn('dynamic "statement" {', deploy_trust)
        self.assertEqual(deploy_trust.count('test     = "StringEquals"'), 2)
        for claim in ("aud", "sub"):
            self.assertIn(f'variable = "${{local.oidc_host}}:{claim}"', deploy_trust)
        for unsupported_claim in ("workflow", "ref"):
            self.assertNotIn(
                f'variable = "${{local.oidc_host}}:{unsupported_claim}"', deploy_trust
            )
        self.assertIn("statement.value.workflow_ref == \"\" ? \"\"", deploy_trust)
        self.assertIn(":environment:${statement.value.environment}:workflow_ref:${statement.value.workflow_ref}", deploy_trust)
        self.assertNotIn("StringLike", deploy_trust)
        self.assertNotIn("*", deploy_trust)

        audit_trust = bootstrap.split(
            'data "aws_iam_policy_document" "orphan_audit_trust" {', maxsplit=1
        )[1].split('data "aws_iam_policy_document" "orphan_audit" {', maxsplit=1)[0]
        self.assertEqual(audit_trust.count('test     = "StringEquals"'), 2)
        for claim in ("aud", "sub"):
            self.assertIn(f'variable = "${{local.oidc_host}}:{claim}"', audit_trust)
        for unsupported_claim in ("workflow", "ref"):
            self.assertNotIn(
                f'variable = "${{local.oidc_host}}:{unsupported_claim}"', audit_trust
            )
        self.assertIn(
            'audit   = "${var.github_org}/k8s-infra/.github/workflows/orphan-audit.yml@refs/heads/main"',
            bootstrap,
        )
        self.assertIn("local.k8s_workflow_ref.audit", audit_trust)
        self.assertIn(":environment:staging:workflow_ref:${local.k8s_workflow_ref.audit}", audit_trust)

        hml_trust = bootstrap.split(
            'data "aws_iam_policy_document" "hml_deploy_trust" {', maxsplit=1
        )[1].split('resource "aws_iam_role" "hml_deploy"', maxsplit=1)[0]
        self.assertIn("local.k8s_workflow_ref.apply", hml_trust)
        self.assertIn("local.k8s_workflow_ref.destroy", hml_trust)
        self.assertNotIn("branch-pipeline.yml", hml_trust)
        self.assertNotIn("production", hml_trust)
        self.assertIn('name                 = "gh-deploy-k8s-hml"', bootstrap)
        hml_policy = bootstrap.split(
            'data "aws_iam_policy_document" "hml_deploy" {', maxsplit=1
        )[1].split('resource "aws_iam_role_policy" "hml_deploy"', maxsplit=1)[0]
        self.assertIn("k8s-infra/hml/terraform.tfstate", hml_policy)
        self.assertIn("manifest-hml.json", hml_policy)
        self.assertNotIn("production/terraform.tfstate", hml_policy)
        self.assertNotIn("PowerUserAccess", hml_policy)

        hml_state_denial = bootstrap.split(
            'sid     = "DenyIsolatedK8sEnvironmentStateAndPlans"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn("k8s-infra/hml/*", hml_state_denial)
        self.assertIn("k8s-infra/production/*", hml_state_denial)

        for role_name in (
            'name                 = "gh-plan-${each.key}"',
            'name                 = "gh-deploy-${each.key}"',
            'name                 = "gh-deploy-k8s-hml"',
            'name                 = "gh-audit-k8s-infra"',
        ):
            self.assertIn(role_name, bootstrap)
        terraform_configuration = "\n".join(
            path.read_text(encoding="utf-8") for path in (ROOT / "envs").rglob("*.tf")
        )
        self.assertNotRegex(terraform_configuration, r"gh-deploy-k8s-infra\*")

        for workflow_name in ("session-open.yml", "session-close.yml"):
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            self.assertNotIn("aws-actions/configure-aws-credentials@", workflow)

        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
            ci_workflow,
        )
        self.assertIn("environment: staging", ci_workflow)
        self.assertIn("HML branch readiness handoff", branch_pipeline)
        self.assertNotIn("id-token: write", branch_pipeline)
        self.assertNotIn("configure-aws-credentials@", branch_pipeline)
        self.assertNotIn("terraform apply", branch_pipeline)
        self.assertNotIn("production", branch_pipeline)

        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        destroy_workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("- production", apply_workflow)
        self.assertIn("vars.AWS_HML_DEPLOY_ROLE_ARN", apply_workflow)
        self.assertIn("if: inputs.stack == 'hml'", apply_workflow)
        self.assertIn("if: inputs.stack != 'hml'", apply_workflow)
        self.assertLess(
            apply_workflow.index("require_trusted_lifecycle_operator.py"),
            apply_workflow.index("role-to-assume: ${{ vars.AWS_HML_DEPLOY_ROLE_ARN }}"),
        )
        for workflow in (ci_workflow, apply_workflow, destroy_workflow):
            self.assertIn("manifest-$STACK.json", workflow)

    def test_private_ecr_retains_immutable_commit_tagged_app_images(self) -> None:
        registry = (ROOT / "envs" / "staging" / "platform" / "ecr.tf").read_text(encoding="utf-8")

        self.assertIn('image_tag_mutability = "IMMUTABLE"', registry)
        self.assertIn('tagPrefixList = ["sha-"]', registry)
        self.assertIn('description  = "Keep the ten most recent commit-tagged images"', registry)

    def test_orphan_audit_serializes_with_infrastructure_mutations(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "orphan-audit.yml").read_text(encoding="utf-8")
        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        destroy_workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")

        self.assertIn("concurrency:\n  group: staging-infra\n  cancel-in-progress: false", workflow)
        self.assertIn("group: staging-infra", apply_workflow)
        self.assertIn("group: staging-infra", destroy_workflow)

    def test_eks_endpoint_allowlist_is_preserved_and_platform_operations_fail_closed(self) -> None:
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        destroy_workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")

        for workflow in (ci_workflow, apply_workflow, destroy_workflow):
            self.assertIn("TF_VAR_cluster_endpoint_public_access_cidrs", workflow)
        for workflow in (apply_workflow, destroy_workflow):
            self.assertIn("EKS_CLUSTER_ENDPOINT_ADMIN_CIDRS", workflow)

        self.assertIn("EKS endpoint access contract tests", ci_workflow)
        for workflow in (ci_workflow, apply_workflow, destroy_workflow):
            self.assertIn("runner-allowed", workflow)
        for workflow in (apply_workflow, destroy_workflow):
            self.assertIn("outside the EKS administrator allowlist", workflow)
            self.assertNotIn("eks-endpoint-access.sh add-runner", workflow)
            self.assertNotIn("eks-endpoint-access.sh restore-admin", workflow)

    def test_orphan_audit_is_capped_to_the_reserved_fifteen_minute_window(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "orphan-audit.yml").read_text(encoding="utf-8")
        audit_job = workflow.split("  audit:\n", maxsplit=1)[1]
        self.assertIn("timeout-minutes: 13", audit_job)
        self.assertIn("AWS_AUDIT_ROLE_ARN", audit_job)
        self.assertIn("verify_session_state.py", audit_job)
        self.assertIn("--minimum-remaining-seconds 780", audit_job)
        self.assertIn("--minimum-remaining-seconds 600", audit_job)

    def test_teardown_jobs_fit_before_the_audit_reserve(self) -> None:
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        destroy_workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")

        self.assertIn("group: staging-infra\n      cancel-in-progress: false", ci_workflow)
        self.assertIn("inputs.operation == 'nat-disable' && 13 || 60", ci_workflow)
        self.assertIn("inputs.operation == 'nat-disable' && 13 || 60", apply_workflow)
        self.assertEqual(destroy_workflow.count("timeout-minutes: 13"), 2)
        self.assertIn("minimum_remaining_seconds=720", ci_workflow)
        self.assertIn("minimum_remaining_seconds=720", apply_workflow)
        self.assertIn("--minimum-remaining-seconds 720", destroy_workflow)

    def test_saved_plan_manifest_is_attested_by_its_originating_workflow_run(self) -> None:
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(encoding="utf-8")
        destroy_workflow = (ROOT / ".github" / "workflows" / "destroy.yml").read_text(encoding="utf-8")

        self.assertIn("create-attestation", ci_workflow)
        self.assertIn("actions/upload-artifact@", ci_workflow)
        self.assertIn("actions/upload-artifact@", destroy_workflow)
        for workflow in (apply_workflow, destroy_workflow):
            self.assertIn("actions/download-artifact@", workflow)
            self.assertIn("run-id: ${{ steps.validate-session.outputs.plan_run_id }}", workflow)
            self.assertIn("scripts/verify_plan_run.py", workflow)
            self.assertLess(workflow.index("scripts/verify_plan_run.py"), workflow.index("actions/download-artifact@"))
            self.assertIn("verify-attestation", workflow)
            self.assertLess(workflow.index("verify-attestation"), workflow.index('terraform -chdir="$terraform_root" apply'))

    def test_lifecycle_workflows_reject_replayed_dispatch_ids_before_aws_access(self) -> None:
        workflows = (
            "ci.yml",
            "apply.yml",
            "destroy.yml",
            "orphan-audit.yml",
        )
        for workflow_name in workflows:
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_name):
                self.assertIn("assert_unique_lifecycle_dispatch.py", workflow)
                self.assertRegex(workflow, r"lifecycle_dispatch_id:\s+description:[^\n]*\n\s+required: true")
                self.assertNotRegex(workflow, r"session_token:")
                self.assertIn("consume_lifecycle_dispatch.py", workflow)
                self.assertLess(
                    workflow.index("assert_unique_lifecycle_dispatch.py"),
                    workflow.index("consume_lifecycle_dispatch.py"),
                )
                deploy_role = next(
                    role
                    for role in (
                        "role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}",
                        "role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}",
                        "role-to-assume: ${{ vars.AWS_AUDIT_ROLE_ARN }}",
                    )
                    if role in workflow
                )
                self.assertLess(
                    workflow.index("consume_lifecycle_dispatch.py"),
                    workflow.index(deploy_role),
                )


if __name__ == "__main__":
    unittest.main()
