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

    def test_database_bootstrap_namespace_and_pod_identity_agent_access_remain(self):
        self.assertIn('ops_namespace  = "auto-shop-ops"', NAMESPACES_TF)
        self.assertIn(
            'resource "kubernetes_network_policy_v1" "pod_identity_agent" {',
            NETWORK_POLICIES_TF,
        )
        self.assertIn("namespace = local.ops_namespace", NETWORK_POLICIES_TF)
        self.assertIn("`gh-deploy-database-infra`", README)
        self.assertIn("Edit em `auto-shop-ops` (Job de bootstrap de banco)", README)


if __name__ == "__main__":
    unittest.main()
