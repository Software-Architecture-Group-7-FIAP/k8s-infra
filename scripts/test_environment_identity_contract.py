from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class EnvironmentIdentityContractTests(unittest.TestCase):
    def test_runtime_secret_access_is_scoped_to_each_environment(self) -> None:
        platform = (ROOT / "envs" / "staging" / "platform" / "addons.tf").read_text(encoding="utf-8")
        environment = (ROOT / "modules" / "application-environment" / "main.tf").read_text(encoding="utf-8")

        self.assertIn('for_each = local.eso_environments', platform)
        self.assertRegex(platform, r'controller_namespace\s*=\s*"external-secrets-\$\{env\}"')
        self.assertRegex(platform, r'runtime_secret_name\s*=\s*"auto-shop/staging/\$\{env\}/app-runtime"')
        self.assertIn('secret:${each.value.runtime_secret_name}-*', platform)
        self.assertRegex(platform, r'scopedRBAC\s*=\s*true')
        self.assertIn('scopedNamespace = local.eso_environments["hml"].app_namespace', platform)
        self.assertIn('scopedNamespace = local.eso_environments["prd"].app_namespace', platform)
        self.assertRegex(platform, r'installCRDs\s*=\s*true')
        self.assertRegex(platform, r'installCRDs\s*=\s*false')
        self.assertRegex(platform, r'createClusterSecretStore\s*=\s*false')
        self.assertRegex(platform, r'processClusterStore\s*=\s*false')
        self.assertIn('kind       = "SecretStore"', environment)
        self.assertIn('kind = "SecretStore"', environment)
        self.assertIn('namespace = local.namespace_name', environment)
        self.assertIn('depends_on = [kubernetes_manifest.app_runtime_store]', environment)
        self.assertNotIn('ClusterSecretStore', environment)

        deployer_crd_role = environment.split(
            'resource "kubernetes_role_v1" "deployer_crds" {', maxsplit=1
        )[1].split('resource "kubernetes_role_binding_v1"', maxsplit=1)[0]
        self.assertRegex(deployer_crd_role, r'resources\s*=\s*\["externalsecrets"\]')
        self.assertNotIn('"secretstores"', deployer_crd_role)
        self.assertIn('count = var.environment == "hml" ? 0 : 1', deployer_crd_role)

    def test_migration_roles_attach_each_database_contract_policy(self) -> None:
        # Migration identity is not shared in envs/staging/platform: each environment's own root
        # (via the application-environment module) creates and owns its own role, so an HML pod
        # can never assume the PRD role or vice versa.
        platform = (ROOT / "envs" / "staging" / "platform").glob("*.tf")
        platform_terraform = "\n".join(path.read_text(encoding="utf-8") for path in platform)
        environment = (ROOT / "modules" / "application-environment" / "main.tf").read_text(encoding="utf-8")

        self.assertNotIn("db_migration", platform_terraform)
        self.assertIn(
            'name = "/auto-shop/staging/database/iam/migrations-${var.environment}-read-policy-arn"',
            environment,
        )
        self.assertIn('resource "aws_iam_role" "db_migration"', environment)
        self.assertIn('aws:RequestTag/kubernetes-namespace"', environment)
        self.assertIn('values   = ["auto-shop-${var.environment}"]', environment)
        self.assertNotIn("owner-read-policy-arn", environment)
        self.assertIn(
            "policy_arn = data.aws_ssm_parameter.db_migration_secret_read_policy_arn.value",
            environment,
        )
        self.assertIn('name                 = "auto-shop-staging-db-migrate-${var.environment}"', environment)
        self.assertIn("role_arn        = aws_iam_role.db_migration.arn", environment)

    def test_new_environment_state_docs_preserve_existing_owners_and_closed_gates(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        environment_docs = (ROOT / ".github" / "ENVIRONMENTS.md").read_text(encoding="utf-8")
        branch_pipeline = (ROOT / ".github" / "workflows" / "branch-pipeline.yml").read_text(
            encoding="utf-8"
        )
        hml_bootstrap = (ROOT / ".github" / "hml-namespace-bootstrap.yaml").read_text(
            encoding="utf-8"
        )
        session_ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        apply_workflow = (ROOT / ".github" / "workflows" / "apply.yml").read_text(
            encoding="utf-8"
        )

        for state_key in (
            "k8s-infra/staging/foundation.tfstate",
            "k8s-infra/staging/platform.tfstate",
            "k8s-infra/hml/terraform.tfstate",
            "k8s-infra/production/terraform.tfstate",
        ):
            self.assertIn(state_key, readme)
            self.assertIn(state_key, environment_docs)

        self.assertIn("No HML or production state objects exist yet", readme)
        self.assertIn("no shared-resource state migration is required", readme)
        self.assertIn("start empty", readme)
        self.assertIn("must not import or declare shared foundation/platform resources", readme)
        self.assertIn("No shared-resource migration is needed or intended", environment_docs)
        self.assertIn("read-only inventory found no HML or production state", environment_docs)
        self.assertIn("Keep them unset or `false`", environment_docs)

        for readiness_variable in ("K8S_HML_TERRAFORM_ROOT_READY", "K8S_PRODUCTION_TERRAFORM_ROOT_READY"):
            default_false = f"vars.{readiness_variable} || 'false'"
            self.assertIn(default_false, session_ci)

        self.assertIn('auto-shop-hml-infra', hml_bootstrap)
        self.assertIn('name: auto-shop-deployers', hml_bootstrap)
        self.assertIn('name: auto-shop-hml', hml_bootstrap)
        self.assertIn('create_namespace = false', (ROOT / "envs" / "hml" / "main.tf").read_text(encoding="utf-8"))
        self.assertNotIn("aws-actions/configure-aws-credentials@", branch_pipeline)
        self.assertNotIn("id-token: write", branch_pipeline)
        self.assertNotIn("terraform apply", branch_pipeline)
        self.assertNotIn("production", branch_pipeline)
        self.assertIn("AWS_HML_DEPLOY_ROLE_ARN", apply_workflow)
        self.assertIn("gh-deploy-k8s-hml", apply_workflow)

    def test_hml_access_entries_and_deploy_role_are_namespace_scoped(self) -> None:
        foundation = (ROOT / "envs" / "staging" / "foundation" / "main.tf").read_text(
            encoding="utf-8"
        )
        bootstrap = (ROOT / "envs" / "staging" / "bootstrap" / "main.tf").read_text(
            encoding="utf-8"
        )
        hml_root = (ROOT / "envs" / "hml" / "main.tf").read_text(encoding="utf-8")

        self.assertIn('principal_arn     = "${local.role_arn}/gh-deploy-k8s-hml"', foundation)
        hml_infra_entry = foundation.split('hml-infrastructure = {', maxsplit=1)[1].split(
            'hml-app-deploy = {', maxsplit=1
        )[0]
        self.assertIn('/AmazonEKSAdminPolicy"', hml_infra_entry)
        self.assertIn('namespaces = ["auto-shop-hml"]', hml_infra_entry)
        self.assertNotIn('/AmazonEKSClusterAdminPolicy"', hml_infra_entry)
        self.assertIn(
            'principal_arn     = "arn:aws:iam::035611741563:role/auto-shop-staging-github-staging"',
            foundation,
        )
        self.assertIn('/AmazonEKSEditPolicy"', foundation)
        self.assertNotIn('resource "aws_eks_access_entry"', hml_root)
        self.assertIn('name                 = "gh-deploy-k8s-hml"', bootstrap)
        hml_role = bootstrap.split('data "aws_iam_policy_document" "hml_deploy" {', maxsplit=1)[1].split(
            'resource "aws_iam_role_policy" "hml_deploy"', maxsplit=1
        )[0]
        self.assertIn('k8s-infra/hml/terraform.tfstate', hml_role)
        self.assertIn('podidentityassociation/auto-shop-staging/*', hml_role)
        self.assertIn('aws:RequestTag/KubernetesNamespace', hml_role)
        self.assertIn('aws:ResourceTag/KubernetesNamespace', hml_role)
        self.assertNotIn('PowerUserAccess', hml_role)


if __name__ == "__main__":
    unittest.main()
