#!/usr/bin/env python3
"""Fail closed when a saved Terraform plan exceeds its authorized lifecycle scope."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class PlanGuardError(ValueError):
    """Raised when a plan is malformed or contains an unauthorized resource action."""


NAT_ONLY_ADDRESS = re.compile(
    r"^module\.network\.module\.vpc\.aws_(?:nat_gateway\.this|eip\.nat|route\.private_nat_gateway)(?:\[|$)"
)
COMPUTE_MODULES = ("module.eks.", "module.alb.")


def _read_resource_changes(path: Path) -> list[dict[str, object]]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PlanGuardError("Could not read a valid Terraform plan JSON document.") from error

    if not isinstance(plan, dict):
        raise PlanGuardError("The Terraform plan JSON root must be an object.")
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        raise PlanGuardError("The Terraform plan JSON is missing resource_changes.")
    if any(not isinstance(item, dict) for item in changes):
        raise PlanGuardError("The Terraform plan contains a malformed resource change.")
    return changes


def _actions(change: dict[str, object]) -> tuple[str, ...]:
    resource_address = change.get("address")
    detail = change.get("change")
    actions = detail.get("actions") if isinstance(detail, dict) else None
    if not isinstance(resource_address, str) or not resource_address:
        raise PlanGuardError("Every resource change must have an address.")
    if not isinstance(actions, list) or not actions or any(not isinstance(action, str) for action in actions):
        raise PlanGuardError(f"Resource {resource_address} has malformed plan actions.")
    return tuple(actions)


def validate_plan(changes: list[dict[str, object]], policy: str) -> None:
    if policy not in {"open", "nat-disable", "compute-destroy", "all-destroy"}:
        raise PlanGuardError("Unsupported plan policy.")

    violations: list[str] = []
    changed_count = 0
    for change in changes:
        address = change.get("address")
        actions = _actions(change)
        if actions == ("read",):
            continue
        if actions == ("no-op",):
            if policy == "all-destroy" and change.get("mode", "managed") == "managed":
                violations.append(f"{address}: full teardown left a managed resource unchanged")
            continue
        changed_count += 1

        if policy == "open":
            if "delete" in actions:
                violations.append(f"{address}: opening plans cannot delete or replace resources")
            continue

        if policy == "nat-disable":
            if not NAT_ONLY_ADDRESS.match(str(address)) or actions != ("delete",):
                violations.append(f"{address}: NAT shutdown permits only pure NAT gateway, EIP, or NAT-route deletes")
            continue

        if policy == "compute-destroy":
            if not str(address).startswith(COMPUTE_MODULES) or actions != ("delete",):
                violations.append(f"{address}: compute teardown permits only pure deletes in module.eks or module.alb")
            continue

        if actions != ("delete",):
            violations.append(f"{address}: full teardown permits only pure deletes")

    if violations:
        raise PlanGuardError("Plan exceeds its authorized scope:\n" + "\n".join(violations))

    print(f"Plan guard {policy} passed for {changed_count} resource changes.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-json", required=True, type=Path)
    parser.add_argument(
        "--policy",
        required=True,
        choices=("open", "nat-disable", "compute-destroy", "all-destroy"),
    )
    arguments = parser.parse_args()
    try:
        validate_plan(_read_resource_changes(arguments.plan_json), arguments.policy)
    except PlanGuardError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
