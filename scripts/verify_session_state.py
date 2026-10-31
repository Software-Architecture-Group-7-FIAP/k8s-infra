#!/usr/bin/env python3
"""Check that Terraform state contains only the intentionally persistent network contract."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class StateAuditError(ValueError):
    """Raised when state still tracks a disposable session resource."""


def _managed_addresses(path: Path) -> list[str]:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise StateAuditError(f"Could not read valid Terraform state JSON for {path.name}.") from error

    if not isinstance(state, dict) or state.get("version") != 4:
        raise StateAuditError(f"Terraform state {path.name} has an unsupported format.")
    resources = state.get("resources")
    if not isinstance(resources, list):
        raise StateAuditError(f"Terraform state {path.name} has no valid resources list.")

    addresses: list[str] = []
    for resource in resources:
        if not isinstance(resource, dict):
            raise StateAuditError(f"Terraform state {path.name} contains a malformed resource.")
        mode = resource.get("mode")
        resource_type = resource.get("type")
        resource_name = resource.get("name")
        module_path = resource.get("module", "")
        if mode not in ("managed", "data"):
            raise StateAuditError(f"Terraform state {path.name} contains an unsupported resource mode.")
        if not isinstance(resource_type, str) or not resource_type or not isinstance(resource_name, str) or not resource_name:
            raise StateAuditError(f"Terraform state {path.name} contains a resource without a valid address.")
        if not isinstance(module_path, str):
            raise StateAuditError(f"Terraform state {path.name} contains an invalid module address.")
        if mode == "data":
            continue
        address_parts = [part for part in (module_path, resource_type, resource_name) if part]
        addresses.append(".".join(address_parts))
    return addresses


def verify_session_state(
    foundation_file: Path,
    platform_file: Path,
    hml_file: Path | None = None,
    production_file: Path | None = None,
) -> None:
    platform = _managed_addresses(platform_file)
    foundation = _managed_addresses(foundation_file)
    violations: list[str] = []

    if platform:
        violations.append("platform state must be empty after teardown; remaining managed addresses:")
        violations.extend(f"  {address}" for address in platform)

    for environment, state_file in (("HML", hml_file), ("production", production_file)):
        if state_file is None:
            continue
        environment_addresses = _managed_addresses(state_file)
        if environment_addresses:
            violations.append(
                f"{environment} state must be empty after teardown; remaining managed addresses:"
            )
            violations.extend(f"  {address}" for address in environment_addresses)

    unexpected_foundation = [
        address
        for address in foundation
        if not _is_allowed_persistent_foundation_address(address)
        or _is_nat_resource(address)
    ]
    if unexpected_foundation:
        violations.append(
            "foundation state may retain only VPC/network resources, the persistent SSM contract, "
            "and the explicitly configured private runner service resources; "
            "remaining unexpected addresses:"
        )
        violations.extend(f"  {address}" for address in unexpected_foundation)

    if violations:
        raise StateAuditError("\n".join(violations))

    print(
        "Terraform state audit passed: platform and environment roots have no managed resources; "
        f"foundation retains {len(foundation)} persistent network/contract/runner resources."
    )


def _is_allowed_persistent_foundation_address(address: str) -> bool:
    return address.startswith(("module.network.", "module.contract.")) or address in {
        "aws_security_group.private_eks_runner",
        "aws_iam_role.private_eks_runner",
        "aws_iam_role_policy.private_eks_runner",
        "aws_cloudwatch_log_group.private_eks_runner",
        "aws_codebuild_source_credential.private_eks_runner",
        "aws_codebuild_project.private_eks_runner",
        "aws_codebuild_webhook.private_eks_runner",
    }


def _is_nat_resource(address: str) -> bool:
    return address in {
        "module.network.module.vpc.aws_nat_gateway.this",
        "module.network.module.vpc.aws_eip.nat",
        "module.network.module.vpc.aws_route.private_nat_gateway",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--foundation-state", required=True, type=Path)
    parser.add_argument("--platform-state", required=True, type=Path)
    parser.add_argument("--hml-state", type=Path)
    parser.add_argument("--production-state", type=Path)
    arguments = parser.parse_args()
    try:
        verify_session_state(
            arguments.foundation_state,
            arguments.platform_state,
            arguments.hml_state,
            arguments.production_state,
        )
    except StateAuditError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
