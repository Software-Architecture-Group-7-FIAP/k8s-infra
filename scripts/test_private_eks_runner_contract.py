from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PrivateEksRunnerContractTests(unittest.TestCase):
    def test_foundation_runner_is_vpc_hosted_and_uses_a_dedicated_github_runner_group(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(encoding="utf-8")
        variables = (ROOT / "envs" / "staging" / "foundation" / "variables.tf").read_text(encoding="utf-8")

        self.assertIn('resource "aws_codebuild_project" "private_eks_runner"', foundation)
        self.assertIn('resource "aws_codebuild_webhook" "private_eks_runner"', foundation)
        self.assertIn('type     = "CODECONNECTIONS"', foundation)
        self.assertIn('value = tostring(var.github_runner_group_id)', foundation)
        self.assertIn('CODEBUILD_CONFIG_GITHUB_ACTIONS_ORG_REGISTRATION_NAME', foundation)
        self.assertRegex(foundation, r"subnets\s*= module\.network\.workload_subnet_ids")
        self.assertIn('security_group_ids = [aws_security_group.private_eks_runner.id]', foundation)
        self.assertIn('var.github_runner_group_id > 1', variables)
        self.assertIn('variable "enable_private_eks_runner"', variables)
        self.assertIn('variable "github_runner_group_id"', variables)

    def test_runner_security_group_has_no_ingress_and_only_https_egress(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(encoding="utf-8")
        security_group = foundation.split('resource "aws_security_group" "private_eks_runner" {', 1)[1].split(
            "\n}", 1
        )[0]

        self.assertNotIn("ingress {", security_group)
        self.assertIn('protocol    = "tcp"', security_group)
        self.assertIn("from_port   = 443", security_group)
        self.assertIn("to_port     = 443", security_group)
        self.assertIn('cidr_blocks = ["0.0.0.0/0"]', security_group)

    def test_cluster_endpoint_and_private_security_group_allow_the_runner(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(encoding="utf-8")
        endpoint_guard = (ROOT / "scripts" / "eks-endpoint-access.sh").read_text(encoding="utf-8")

        self.assertIn("endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs", foundation)
        self.assertIn("security_group_additional_rules", foundation)
        self.assertIn("aws_security_group.private_eks_runner.id", foundation)
        self.assertRegex(foundation, r"from_port\s*=\s*443")
        self.assertRegex(foundation, r"to_port\s*=\s*443")
        self.assertIn('[[ "$mode" == "private-runner-allowed" ]]', endpoint_guard)
        self.assertIn("endpointPrivateAccess", endpoint_guard)
        self.assertIn("socket.create_connection", endpoint_guard)
        self.assertNotIn("get_runner_ip", endpoint_guard.split('if [[ "$mode" == "private-runner-allowed" ]]', 1)[1].split("fi", 1)[0])

    def test_webhook_only_accepts_the_three_guarded_cluster_workflows(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(encoding="utf-8")
        webhook = foundation.split('resource "aws_codebuild_webhook" "private_eks_runner" {', 1)[1].split(
            "\n}", 1
        )[0]

        self.assertIn('pattern = "WORKFLOW_JOB_QUEUED"', webhook)
        for name in ("K8s HML Cluster Plan", "K8s HML Cluster Apply", "K8s HML Cluster Destroy"):
            self.assertIn(name, webhook)
        self.assertNotRegex(webhook, r'pattern\s*=\s*"(PUSH|PULL_REQUEST_CREATED|PULL_REQUEST_UPDATED)"')

    def test_only_isolated_cluster_workflows_use_the_private_runner_group(self) -> None:
        workflow_names = ("cluster-ci.yml", "cluster-apply.yml", "cluster-destroy.yml")
        for workflow_name in workflow_names:
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_name):
                self.assertIn("group: k8s-private-eks", workflow)
                self.assertIn("codebuild-auto-shop-k8s-private-${{ github.run_id }}-${{ github.run_attempt }}", workflow)
                self.assertIn("workflow_dispatch:", workflow)
                self.assertNotIn("pull_request:", workflow)
                self.assertNotIn("push:", workflow)

        destroy_workflow = (ROOT / ".github" / "workflows" / "cluster-destroy.yml").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"(?m)^  [a-z][a-z-]+:\s*$", destroy_workflow.split("jobs:\n", 1)[1])), 2)

    def test_hosted_workflows_restrict_cluster_operations_to_private_dispatch_routes(self) -> None:
        private_routes = {
            "ci.yml": "cluster-ci.yml",
            "apply.yml": "cluster-apply.yml",
            "destroy.yml": "cluster-destroy.yml",
        }
        for workflow_name, private_route in private_routes.items():
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            stack_block = workflow.split("      stack:\n", 1)[1].split("\n      ", 1)[0]
            with self.subTest(workflow=workflow_name):
                self.assertIn(private_route, workflow)
                self.assertNotRegex(stack_block, r"(?m)^\s*- (hml|platform)$")

    def test_foundation_workflows_pass_the_persistent_runner_inputs(self) -> None:
        for workflow_name in ("ci.yml", "apply.yml", "destroy.yml"):
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(encoding="utf-8")
            with self.subTest(workflow=workflow_name):
                self.assertIn("TF_VAR_enable_private_eks_runner", workflow)
                self.assertIn("TF_VAR_github_runner_group_id", workflow)
                self.assertIn("TF_VAR_github_codeconnection_arn", workflow)
                self.assertIn("vars.PRIVATE_EKS_RUNNER_GROUP_ID", workflow)
                self.assertIn("vars.AWS_CODECONNECTION_ARN", workflow)
                self.assertNotIn("vars.GITHUB_RUNNER_GROUP_ID", workflow)
                self.assertNotIn("vars.GITHUB_CODECONNECTION_ARN", workflow)

    def test_codebuild_role_is_scoped_and_cannot_consume_lifecycle_or_manage_eks(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(encoding="utf-8")
        bootstrap = (ROOT / "envs" / "staging" / "bootstrap" / "main.tf").read_text(encoding="utf-8")
        role = foundation.split('resource "aws_iam_role" "private_eks_runner" {', 1)[1].split("\n}", 1)[0]
        policy = foundation.split('data "aws_iam_policy_document" "private_eks_runner" {', 1)[1].split("\n}", 1)[0]

        self.assertIn("permissions_boundary = local.project_boundary_arn", role)
        self.assertIn('codeconnections:GetConnectionToken', policy)
        self.assertIn('ec2:CreateNetworkInterfacePermission', policy)
        self.assertIn('logs:PutLogEvents', policy)
        self.assertNotIn('eks:', policy)
        self.assertNotIn('dynamodb:', policy)
        self.assertNotIn('iam:PassRole', policy)
        self.assertIn('iam:PassedToService', bootstrap)
        self.assertIn('codebuild.amazonaws.com', bootstrap)
        self.assertIn('k8s-infra-codebuild-private-runner', bootstrap)


if __name__ == "__main__":
    unittest.main()
