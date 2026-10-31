import unittest

from terraform_plan_guard import PlanGuardError, validate_plan


LEGACY_RULES = {
    'module.alb.aws_vpc_security_group_ingress_rule.alb_listener["hml"]': {
        "id": "sgr-00f836f67420b89b1",
        "security_group_id": "sg-0dc57c6822fb9678a",
        "description": "hml listener from inside the VPC",
        "ip_protocol": "tcp",
        "from_port": 8001,
        "to_port": 8001,
        "cidr_ipv4": "10.80.0.0/20",
    },
    'module.alb.aws_vpc_security_group_ingress_rule.alb_listener["prd"]': {
        "id": "sgr-0a86dc85878bd33c9",
        "security_group_id": "sg-0dc57c6822fb9678a",
        "description": "prd listener from inside the VPC",
        "ip_protocol": "tcp",
        "from_port": 8002,
        "to_port": 8002,
        "cidr_ipv4": "10.80.0.0/20",
    },
}


def resource_change(address: str, actions: list[str], before: dict[str, object] | None = None) -> dict[str, object]:
    return {
        "address": address,
        "mode": "managed",
        "change": {"actions": actions, "before": before},
    }


class TerraformPlanGuardTests(unittest.TestCase):
    def test_open_policy_still_accepts_non_deletion_changes(self) -> None:
        validate_plan(
            [resource_change("module.alb.aws_lb.this", ["update"])],
            "open",
        )

    def test_open_policy_allows_the_exact_legacy_ingress_deletions(self) -> None:
        changes = [
            resource_change(address, ["delete"], dict(before))
            for address, before in LEGACY_RULES.items()
        ]

        validate_plan(changes, "open")

    def test_open_policy_rejects_an_unlisted_deletion(self) -> None:
        with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
            validate_plan(
                [resource_change("module.alb.aws_lb.this", ["delete"])],
                "open",
            )

    def test_open_policy_rejects_replacement_of_a_legacy_rule(self) -> None:
        address, before = next(iter(LEGACY_RULES.items()))

        with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
            validate_plan([resource_change(address, ["delete", "create"], dict(before))], "open")

    def test_open_policy_rejects_a_legacy_address_without_before_state(self) -> None:
        address = next(iter(LEGACY_RULES))

        with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
            validate_plan([resource_change(address, ["delete"])], "open")

    def test_open_policy_rejects_an_unmanaged_legacy_address(self) -> None:
        address, before = next(iter(LEGACY_RULES.items()))
        change = resource_change(address, ["delete"], dict(before))
        change["mode"] = "data"

        with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
            validate_plan([change], "open")

    def test_open_policy_rejects_legacy_rule_state_that_does_not_match_exactly(self) -> None:
        for field, value in (
            ("id", "sgr-11111111111111111"),
            ("security_group_id", "sg-11111111111111111"),
            ("description", "unexpected ingress rule"),
            ("ip_protocol", "-1"),
            ("from_port", 0),
            ("to_port", 65535),
            ("cidr_ipv4", "0.0.0.0/0"),
        ):
            with self.subTest(field=field):
                address, expected_before = next(iter(LEGACY_RULES.items()))
                before = {**expected_before, field: value}

                with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
                    validate_plan([resource_change(address, ["delete"], before)], "open")

    def test_open_policy_rejects_an_additional_ingress_source_selector(self) -> None:
        address, expected_before = next(iter(LEGACY_RULES.items()))
        before = {**expected_before, "cidr_ipv6": "::/0"}

        with self.assertRaisesRegex(PlanGuardError, "cannot delete or replace"):
            validate_plan([resource_change(address, ["delete"], before)], "open")


if __name__ == "__main__":
    unittest.main()
