import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MAIN_TF = (REPO_ROOT / "envs/staging/bootstrap/main.tf").read_text(encoding="utf-8")
VARIABLES_TF = (REPO_ROOT / "envs/staging/bootstrap/variables.tf").read_text(encoding="utf-8")


class BootstrapOidcTrustTests(unittest.TestCase):
    def test_trusted_repositories_have_fixed_github_numeric_ids(self):
        self.assertIn('default     = "279547328"', VARIABLES_TF)

        repository_ids = {
            "k8s-infra": "1431503198",
            "database-infra": "1420971567",
            "lambda-auth": "1418895421",
            "auto-shop-system": "1221936756",
        }
        for repository, repository_id in repository_ids.items():
            with self.subTest(repository=repository):
                self.assertRegex(
                    VARIABLES_TF,
                    rf'"{re.escape(repository)}"\s*=\s*"{repository_id}"',
                )

    def test_repo_subject_local_is_built_from_the_fixed_repository_ids(self):
        locals_block = MAIN_TF.split("locals {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("var.github_org_id", locals_block)
        self.assertIn("var.github_repository_ids[repo]", locals_block)

    def test_all_oidc_trusts_use_exact_subject_equality(self):
        trust_documents = (
            "plan_trust",
            "deploy_trust",
            "orphan_audit_trust",
        )
        for name in trust_documents:
            with self.subTest(trust_document=name):
                marker = f'data "aws_iam_policy_document" "{name}"'
                start = MAIN_TF.index(marker)
                next_document = MAIN_TF.find('\ndata "', start + len(marker))
                section = MAIN_TF[start:] if next_document == -1 else MAIN_TF[start:next_document]

                self.assertIn('test     = "StringEquals"', section)
                self.assertNotIn('test     = "StringLike"', section)
                self.assertNotIn("@*/", section)
                self.assertIn("local.repo_subject[", section)

    def test_database_plan_role_is_limited_to_main_and_protected_plan_environment(self):
        plan_environments = VARIABLES_TF.split('variable "plan_environments"', 1)[1]
        plan_environments = plan_environments.split('\nvariable "', 1)[0]

        self.assertRegex(plan_environments, r'"database-infra"\s*=\s*\["aws-plan"\]')
        self.assertIn(":ref:refs/heads/main", MAIN_TF)
        self.assertNotIn(":pull_request", MAIN_TF)

    def test_plan_state_policy_is_attached_before_broad_state_policy_is_removed(self):
        marker = 'resource "aws_iam_role_policy_attachment" "plan_state"'
        start = MAIN_TF.index(marker)
        next_resource = MAIN_TF.find('\nresource "', start + len(marker))
        section = MAIN_TF[start:] if next_resource == -1 else MAIN_TF[start:next_resource]

        self.assertIn("create_before_destroy = true", section)

    def test_plan_restriction_description_does_not_force_policy_replacement(self):
        marker = 'resource "aws_iam_policy" "plan_restrictions"'
        start = MAIN_TF.index(marker)
        next_resource = MAIN_TF.find('\nresource "', start + len(marker))
        section = MAIN_TF[start:] if next_resource == -1 else MAIN_TF[start:next_resource]

        self.assertIn("ignore_changes = [description]", section)

    def test_deploy_roles_have_boundary_and_backend_access_remains_identity_scoped(self):
        role_names = ("deploy", "hml_deploy", "lambda_auth_hml_deploy")
        for name in role_names:
            with self.subTest(role=name):
                marker = f'resource "aws_iam_role" "{name}" {{'
                start = MAIN_TF.index(marker)
                end = MAIN_TF.index("\n}", start)
                self.assertIn(
                    "permissions_boundary = aws_iam_policy.project_boundary.arn",
                    MAIN_TF[start:end],
                )

        boundary = MAIN_TF.split(
            'data "aws_iam_policy_document" "project_boundary"', maxsplit=1
        )[1].split('resource "aws_iam_policy" "project_boundary"', maxsplit=1)[0]
        state_bucket_deny = boundary.split(
            'sid     = "DenyStateBucketRegardlessOfIdentityPolicy"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('test     = "ArnNotLike"', state_bucket_deny)
        self.assertIn('role${var.iam_path}gh-deploy-*', state_bucket_deny)

        state_policy = MAIN_TF.split(
            'data "aws_iam_policy_document" "state"', maxsplit=1
        )[1].split('resource "aws_iam_policy" "state"', maxsplit=1)[0]
        self.assertIn("lambda-auth/prd/terraform.tfstate", state_policy)
        self.assertIn("lambda-auth/prd/terraform.tfstate.tflock", state_policy)
        self.assertIn('"lambda-auth/prd/*"', state_policy)

    def test_hml_deploy_iam_boundary_grants_are_principal_and_resource_scoped(self):
        boundary = MAIN_TF.split(
            'data "aws_iam_policy_document" "project_boundary"', maxsplit=1
        )[1].split('resource "aws_iam_policy" "project_boundary"', maxsplit=1)[0]

        create_execution_role = boundary.split(
            'sid       = "AllowHmlLambdaCreateBoundedExecutionRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions   = ["iam:CreateRole"]', create_execution_role)
        self.assertIn("role${var.iam_path}lambda-auth-hml-execution", create_execution_role)
        self.assertIn('variable = "aws:PrincipalArn"', create_execution_role)
        self.assertIn("role${var.iam_path}gh-deploy-lambda-auth-hml", create_execution_role)
        self.assertIn('variable = "iam:PermissionsBoundary"', create_execution_role)
        self.assertIn("policy${var.iam_path}auto-shop-boundary", create_execution_role)

        manage_execution_role = boundary.split(
            'sid = "AllowHmlLambdaManageExecutionRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn("role${var.iam_path}lambda-auth-hml-execution", manage_execution_role)
        self.assertIn('variable = "aws:PrincipalArn"', manage_execution_role)
        self.assertIn("role${var.iam_path}gh-deploy-lambda-auth-hml", manage_execution_role)

        pass_lambda_execution_role = boundary.split(
            'sid       = "AllowHmlLambdaPassExecutionRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions   = ["iam:PassRole"]', pass_lambda_execution_role)
        self.assertIn("role${var.iam_path}lambda-auth-hml-execution", pass_lambda_execution_role)
        self.assertIn('variable = "aws:PrincipalArn"', pass_lambda_execution_role)
        self.assertIn("role${var.iam_path}gh-deploy-lambda-auth-hml", pass_lambda_execution_role)
        self.assertIn('variable = "iam:PassedToService"', pass_lambda_execution_role)
        self.assertIn('values   = ["lambda.amazonaws.com"]', pass_lambda_execution_role)

        pass_migration_role = boundary.split(
            'sid       = "AllowHmlK8sPassMigrationRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions   = ["iam:PassRole"]', pass_migration_role)
        self.assertIn("role/auto-shop/auto-shop-staging-db-migrate-hml", pass_migration_role)
        self.assertIn('variable = "aws:PrincipalArn"', pass_migration_role)
        self.assertIn("role${var.iam_path}gh-deploy-k8s-hml", pass_migration_role)
        self.assertIn('variable = "iam:PassedToService"', pass_migration_role)
        self.assertIn('values   = ["pods.eks.amazonaws.com"]', pass_migration_role)

    def test_k8s_deploy_boundary_grants_are_limited_to_foundation_roles(self):
        boundary = MAIN_TF.split(
            'data "aws_iam_policy_document" "project_boundary"', maxsplit=1
        )[1].split('resource "aws_iam_policy" "project_boundary"', maxsplit=1)[0]

        create_roles = boundary.split(
            'sid     = "AllowK8sInfraCreateFoundationRoles"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions = ["iam:CreateRole"]', create_roles)
        self.assertIn("role${var.iam_path}k8s-infra-codebuild-private-runner", create_roles)
        self.assertIn(
            "role${var.iam_path}auto-shop-staging-cloudwatch-observability",
            create_roles,
        )
        self.assertIn('variable = "aws:PrincipalArn"', create_roles)
        self.assertIn("role${var.iam_path}gh-deploy-k8s-infra", create_roles)
        self.assertIn('variable = "iam:PermissionsBoundary"', create_roles)
        self.assertIn("policy${var.iam_path}auto-shop-boundary", create_roles)

        manage_roles = boundary.split(
            'sid = "AllowK8sInfraManageFoundationRoles"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('"iam:PutRolePolicy"', manage_roles)
        self.assertIn("role${var.iam_path}k8s-infra-codebuild-private-runner", manage_roles)
        self.assertIn(
            "role${var.iam_path}auto-shop-staging-cloudwatch-observability",
            manage_roles,
        )
        self.assertIn('variable = "aws:PrincipalArn"', manage_roles)
        self.assertIn("role${var.iam_path}gh-deploy-k8s-infra", manage_roles)

        pass_runner_role = boundary.split(
            'sid       = "AllowK8sInfraPassPrivateRunnerRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions   = ["iam:PassRole"]', pass_runner_role)
        self.assertIn("role${var.iam_path}k8s-infra-codebuild-private-runner", pass_runner_role)
        self.assertIn("role${var.iam_path}gh-deploy-k8s-infra", pass_runner_role)
        self.assertIn('variable = "iam:PassedToService"', pass_runner_role)
        self.assertIn('values   = ["codebuild.amazonaws.com"]', pass_runner_role)

        pass_observability_role = boundary.split(
            'sid       = "AllowK8sInfraPassObservabilityRole"', maxsplit=1
        )[1].split("\n  }", maxsplit=1)[0]
        self.assertIn('actions   = ["iam:PassRole"]', pass_observability_role)
        self.assertIn(
            "role${var.iam_path}auto-shop-staging-cloudwatch-observability",
            pass_observability_role,
        )
        self.assertIn("role${var.iam_path}gh-deploy-k8s-infra", pass_observability_role)
        self.assertNotIn('variable = "iam:PassedToService"', pass_observability_role)


if __name__ == "__main__":
    unittest.main()
