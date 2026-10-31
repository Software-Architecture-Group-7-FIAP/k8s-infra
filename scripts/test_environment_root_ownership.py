import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class EnvironmentRootOwnershipTests(unittest.TestCase):
    def test_environment_roots_use_distinct_states_and_expected_namespace_owners(self) -> None:
        roots = {
            "hml": ("hml", False, "k8s-infra/hml/terraform.tfstate"),
            "production": ("prd", True, "k8s-infra/production/terraform.tfstate"),
        }

        backend_keys = set()
        for root_name, (environment, create_namespace, backend_key) in roots.items():
            with self.subTest(root=root_name):
                root_path = ROOT / "envs" / root_name
                main = (root_path / "main.tf").read_text(encoding="utf-8")
                module = re.search(r'module\s+"environment"\s*\{(.*?)\n\}', main, re.DOTALL)
                self.assertIsNotNone(module)
                self.assertRegex(module.group(1), rf'environment\s*=\s*"{environment}"')
                self.assertRegex(
                    module.group(1),
                    rf"create_namespace\s*=\s*{str(create_namespace).lower()}",
                )

                versions = (root_path / "versions.tf").read_text(encoding="utf-8")
                self.assertIn(f'key          = "{backend_key}"', versions)
                backend_keys.add(backend_key)

        self.assertEqual(len(backend_keys), len(roots))
        bootstrap = (ROOT / ".github" / "hml-namespace-bootstrap.yaml").read_text(encoding="utf-8")
        self.assertIn("kind: Namespace", bootstrap)
        self.assertIn("name: auto-shop-hml", bootstrap)
