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
                self.assertIn("var.github_repository_ids[", section)

    def test_database_plan_role_is_limited_to_main_and_protected_plan_environment(self):
        plan_environments = VARIABLES_TF.split('variable "plan_environments"', 1)[1]
        plan_environments = plan_environments.split('\nvariable "', 1)[0]

        self.assertRegex(plan_environments, r'"database-infra"\s*=\s*\["aws-plan"\]')
        self.assertIn(":ref:refs/heads/main", MAIN_TF)
        self.assertNotIn(":pull_request", MAIN_TF)


if __name__ == "__main__":
    unittest.main()
