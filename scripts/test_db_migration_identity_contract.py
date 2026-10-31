import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PLATFORM_DIR = REPO_ROOT / "envs/staging/platform"
PLATFORM_TERRAFORM = "\n".join(
    path.read_text(encoding="utf-8") for path in sorted(PLATFORM_DIR.glob("*.tf"))
)
NAMESPACES_TF = (PLATFORM_DIR / "namespaces.tf").read_text(encoding="utf-8")
NETWORK_POLICIES_TF = (PLATFORM_DIR / "network_policies.tf").read_text(
    encoding="utf-8"
)
APPLICATION_ENVIRONMENT_TF = (
    REPO_ROOT / "modules/application-environment/main.tf"
).read_text(encoding="utf-8")
HML_BOOTSTRAP_IDENTITY_TF = (
    REPO_ROOT / "envs/hml/database_bootstrap_identity.tf"
).read_text(encoding="utf-8")
README = (REPO_ROOT / "README.md").read_text(encoding="utf-8")


class DatabaseMigrationIdentityContractTests(unittest.TestCase):
    def test_k8s_platform_does_not_read_database_owner_or_migration_policy_arns(self):
        forbidden_parameter_paths = (
            "/auto-shop/staging/database/iam/owner-read-policy-arn",
            "/auto-shop/staging/database/iam/migrations-hml-read-policy-arn",
            "/auto-shop/staging/database/iam/migrations-prd-read-policy-arn",
            "/auto-shop/staging/database/secrets/migrations-hml-arn",
            "/auto-shop/staging/database/secrets/migrations-prd-arn",
        )
        for parameter_path in forbidden_parameter_paths:
            with self.subTest(parameter_path=parameter_path):
                self.assertNotIn(parameter_path, PLATFORM_TERRAFORM)

    def test_k8s_platform_does_not_create_or_associate_database_migration_identity(self):
        self.assertNotIn("auto-shop-db-migrate", PLATFORM_TERRAFORM)
        self.assertNotIn('"db_migration"', PLATFORM_TERRAFORM)
        self.assertNotIn("db_migration_", PLATFORM_TERRAFORM)

    def test_each_environment_owns_its_own_migration_identity(self):
        self.assertIn(
            'resource "aws_iam_role" "db_migration"', APPLICATION_ENVIRONMENT_TF
        )
        self.assertIn(
            'name                 = "auto-shop-staging-db-migrate-${var.environment}"',
            APPLICATION_ENVIRONMENT_TF,
        )
        self.assertIn(
            'name = "/auto-shop/staging/database/iam/migrations-${var.environment}-read-policy-arn"',
            APPLICATION_ENVIRONMENT_TF,
        )
        self.assertIn(
            'role_arn        = aws_iam_role.db_migration.arn', APPLICATION_ENVIRONMENT_TF
        )

    def test_database_bootstrap_namespace_and_pod_identity_agent_access_remain(self):
        self.assertIn('ops_namespace = "auto-shop-ops"', NAMESPACES_TF)
        self.assertIn(
            'resource "kubernetes_network_policy_v1" "pod_identity_agent" {',
            NETWORK_POLICIES_TF,
        )
        self.assertIn(
            "namespace = kubernetes_namespace_v1.this.metadata[0].name",
            NETWORK_POLICIES_TF,
        )
        self.assertIn("`gh-deploy-database-infra`", README)
        self.assertIn("Edit em `auto-shop-ops` (Job de bootstrap de banco)", README)

    def test_hml_database_bootstrap_identity_is_environment_scoped_and_destroyable(self):
        self.assertIn('namespace = "auto-shop-ops"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('name      = "auto-shop-db-bootstrap-hml"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn(
            'role_arn        = "arn:aws:iam::${var.expected_account_id}:role/auto-shop/auto-shop-staging-db-bootstrap-hml"',
            HML_BOOTSTRAP_IDENTITY_TF,
        )
        self.assertIn('Purpose             = "db-bootstrap"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('KubernetesNamespace = "auto-shop-ops"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('resource "aws_eks_pod_identity_association" "database_bootstrap"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('resource "kubernetes_role_binding_v1" "hml_database_bootstrap_identity"', PLATFORM_TERRAFORM)
        self.assertIn('name      = "auto-shop-hml-infra"', PLATFORM_TERRAFORM)
        self.assertIn('resource_names = ["auto-shop-db-bootstrap-hml"]', PLATFORM_TERRAFORM)
        self.assertNotIn("owner-read-policy-arn", HML_BOOTSTRAP_IDENTITY_TF)

    def test_only_migration_pods_in_each_app_namespace_can_reach_pod_identity_agent(
        self,
    ):
        # The HML/PRD namespaces are no longer created by the shared platform root (each
        # environment's own Terraform root owns its namespace instead), so this policy now lives
        # once per environment in the application-environment module, not for_each in platform.
        self.assertNotIn("migration_pod_identity_agent", NETWORK_POLICIES_TF)
        marker = 'resource "kubernetes_network_policy_v1" "migration_pod_identity_agent" {'
        self.assertIn(marker, APPLICATION_ENVIRONMENT_TF)
        migration_policy = APPLICATION_ENVIRONMENT_TF.split(marker, maxsplit=1)[
            1
        ].split("\nresource ", maxsplit=1)[0]

        self.assertIn("namespace = local.namespace_name", migration_policy)
        self.assertIn(
            '"app.kubernetes.io/name"      = "auto-shop-system"', migration_policy
        )
        self.assertIn(
            '"app.kubernetes.io/component" = "migrate"', migration_policy
        )
        self.assertIn('cidr = "169.254.170.23/32"', migration_policy)
        self.assertIn('protocol = "TCP"\n        port     = "80"', migration_policy)
        self.assertNotIn('port     = "2703"', migration_policy)
        self.assertNotIn("pod_selector {}", migration_policy)


if __name__ == "__main__":
    unittest.main()
