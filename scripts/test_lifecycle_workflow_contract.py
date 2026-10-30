from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LifecycleWorkflowContractTests(unittest.TestCase):
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
            self.assertLess(workflow.index("verify-attestation"), workflow.index("terraform -chdir=\"envs/staging/$STACK\" apply"))

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
                self.assertRegex(workflow, r"session_token:\s+description:[^\n]*\n\s+required: true")
                self.assertLess(
                    workflow.index("assert_unique_lifecycle_dispatch.py"),
                    workflow.index("aws-actions/configure-aws-credentials"),
                )


if __name__ == "__main__":
    unittest.main()
