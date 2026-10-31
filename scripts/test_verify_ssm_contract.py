import unittest

from verify_ssm_contract import ContractVerificationError, verify_contract


class VerifySsmContractTests(unittest.TestCase):
    def test_verifies_exact_names_types_and_values_in_batches(self) -> None:
        contract = {
            "/auto-shop/staging/network/vpc-id": {"type": "String", "value": "vpc-0123456789abcdef0"},
            "/auto-shop/staging/network/workload-subnet-ids": {
                "type": "StringList",
                "value": "subnet-a,subnet-b",
            },
        }
        requested_batches: list[list[str]] = []

        def fetch(names: list[str]) -> list[dict[str, object]]:
            requested_batches.append(names)
            return [
                {"Name": name, "Type": contract[name]["type"], "Value": contract[name]["value"]}
                for name in names
            ]

        count, types = verify_contract(contract, fetch)

        self.assertEqual(count, 2)
        self.assertEqual(types, {"String": 1, "StringList": 1})
        self.assertEqual(len(requested_batches), 1)

    def test_rejects_secure_strings_before_fetching_any_parameter(self) -> None:
        calls = 0

        def fetch(_: list[str]) -> list[dict[str, object]]:
            nonlocal calls
            calls += 1
            return []

        with self.assertRaisesRegex(ContractVerificationError, "Only plain String and StringList"):
            verify_contract(
                {"/auto-shop/staging/secret": {"type": "SecureString", "value": "hidden"}},
                fetch,
            )
        self.assertEqual(calls, 0)

    def test_rejects_wrong_names_types_or_values_without_echoing_value(self) -> None:
        contract = {"/auto-shop/staging/network/vpc-id": {"type": "String", "value": "secret-like"}}

        with self.assertRaisesRegex(ContractVerificationError, "does not match Terraform") as error:
            verify_contract(
                contract,
                lambda _: [{"Name": "/auto-shop/staging/network/vpc-id", "Type": "String", "Value": "wrong"}],
            )

        self.assertNotIn("wrong", str(error.exception))
        self.assertNotIn("secret-like", str(error.exception))

    def test_rejects_missing_and_out_of_prefix_names(self) -> None:
        with self.assertRaisesRegex(ContractVerificationError, "missing or unexpected"):
            verify_contract(
                {"/auto-shop/staging/network/vpc-id": {"type": "String", "value": "vpc-1"}},
                lambda _: [],
            )

        with self.assertRaisesRegex(ContractVerificationError, "under /auto-shop/staging"):
            verify_contract(
                {"/other/path": {"type": "String", "value": "value"}},
                lambda _: [],
            )


if __name__ == "__main__":
    unittest.main()
