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
HML_ROOT_TF = (REPO_ROOT / "envs/hml/main.tf").read_text(encoding="utf-8")
PRODUCTION_ROOT_TF = (REPO_ROOT / "envs/production/main.tf").read_text(
    encoding="utf-8"
)
MIGRATION_OUTPUTS_TF = (
    REPO_ROOT / "modules/application-environment/outputs.tf"
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
        environment_expression = "$" + "{var.environment}"
        self.assertIn(
            'name                 = "auto-shop-staging-db-migrate-' + environment_expression + '"',
            APPLICATION_ENVIRONMENT_TF,
        )
        self.assertIn(
            'name = "/auto-shop/staging/database/iam/migrations-' + environment_expression + '-read-policy-arn"',
            APPLICATION_ENVIRONMENT_TF,
        )
        self.assertIn(
            "role_arn        = aws_iam_role.db_migration.arn", APPLICATION_ENVIRONMENT_TF
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
        self.assertIn(chr(96) + "gh-deploy-database-infra" + chr(96), README)
        self.assertIn(
            "Edit em " + chr(96) + "auto-shop-ops" + chr(96) + " (Job de bootstrap de banco)",
            README,
        )

    def test_hml_database_bootstrap_identity_is_environment_scoped_and_destroyable(self):
        self.assertIn('namespace = "auto-shop-ops"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('name      = "auto-shop-db-bootstrap-hml"', HML_BOOTSTRAP_IDENTITY_TF)
        account_expression = "$" + "{var.expected_account_id}"
        self.assertIn(
            'role_arn        = "arn:aws:iam::' + account_expression + ':role/auto-shop/auto-shop-staging-db-bootstrap-hml"',
            HML_BOOTSTRAP_IDENTITY_TF,
        )
        self.assertIn('Purpose             = "db-bootstrap"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn('KubernetesNamespace = "auto-shop-ops"', HML_BOOTSTRAP_IDENTITY_TF)
        self.assertIn(
            'resource "aws_eks_pod_identity_association" "database_bootstrap"',
            HML_BOOTSTRAP_IDENTITY_TF,
        )
        self.assertIn(
            'resource "kubernetes_role_binding_v1" "hml_database_bootstrap_identity"',
            PLATFORM_TERRAFORM,
        )
        self.assertIn('name      = "auto-shop-hml-infra"', PLATFORM_TERRAFORM)
        self.assertIn('resource_names = ["auto-shop-db-bootstrap-hml"]', PLATFORM_TERRAFORM)
        self.assertNotIn("owner-read-policy-arn", HML_BOOTSTRAP_IDENTITY_TF)

    def test_only_migration_pods_in_each_app_namespace_can_reach_pod_identity_agent(self):
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

    def test_migration_service_account_is_handed_to_application_manifests(self):
        service_account_marker = (
            'resource "kubernetes_service_account_v1" "db_migration" {'
        )
        self.assertNotIn(service_account_marker, APPLICATION_ENVIRONMENT_TF)

        for environment, environment_root in (
            ("hml", HML_ROOT_TF),
            ("production", PRODUCTION_ROOT_TF),
        ):
            with self.subTest(environment=environment):
                self.assertNotIn(service_account_marker, environment_root)
                self.assertEqual(1, environment_root.count("removed {"))
                handoff_block = environment_root.split("removed {", maxsplit=1)[1].split(
                    "\n}", maxsplit=1
                )[0]
                self.assertIn(
                    "from = module.environment.kubernetes_service_account_v1.db_migration",
                    handoff_block,
                )
                self.assertIn("destroy = false", handoff_block)
                self.assertNotIn(
                    "to   = kubernetes_service_account_v1.db_migration",
                    environment_root,
                )

        migration_output = MIGRATION_OUTPUTS_TF.split(
            'output "migration_service_account" {', maxsplit=1
        )[1]
        self.assertIn('value       = "auto-shop-migration"', migration_output)
        self.assertNotIn("kubernetes_service_account_v1.db_migration", migration_output)

        association_marker = (
            'resource "aws_eks_pod_identity_association" "db_migration" {'
        )
        self.assertIn(association_marker, APPLICATION_ENVIRONMENT_TF)
        association = APPLICATION_ENVIRONMENT_TF.split(
            association_marker, maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertIn("namespace       = local.namespace_name", association)
        self.assertIn('service_account = "auto-shop-migration"', association)
        self.assertIn("role_arn        = aws_iam_role.db_migration.arn", association)
        self.assertNotIn("depends_on = [kubernetes_service_account_v1.db_migration]", association)


if __name__ == "__main__":
    unittest.main()
