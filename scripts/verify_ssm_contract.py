#!/usr/bin/env python3
"""Verify exact published SSM contract names, types, and values without logging values."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Callable


MAX_PARAMETERS_PER_REQUEST = 10
ALLOWED_TYPES = {"String", "StringList"}
PREFIX = "/auto-shop/staging/"


class ContractVerificationError(ValueError):
    pass


def verify_contract(
    contract: object,
    fetch_parameters: Callable[[list[str]], list[dict[str, object]]],
) -> tuple[int, dict[str, int]]:
    if not isinstance(contract, dict) or not contract:
        raise ContractVerificationError("The Terraform SSM contract output must be a non-empty object.")

    expected: dict[str, dict[str, str]] = {}
    for name, parameter in contract.items():
        if not isinstance(name, str) or not name.startswith(PREFIX):
            raise ContractVerificationError("Every contract parameter must be under /auto-shop/staging/.")
        if not isinstance(parameter, dict):
            raise ContractVerificationError("Each contract parameter must contain a type and value.")
        parameter_type = parameter.get("type")
        value = parameter.get("value")
        if parameter_type not in ALLOWED_TYPES or not isinstance(value, str):
            raise ContractVerificationError("Only plain String and StringList parameters can be verified.")
        expected[name] = {"type": parameter_type, "value": value}

    names = sorted(expected)
    actual: dict[str, dict[str, object]] = {}
    for offset in range(0, len(names), MAX_PARAMETERS_PER_REQUEST):
        batch = names[offset : offset + MAX_PARAMETERS_PER_REQUEST]
        for parameter in fetch_parameters(batch):
            name = parameter.get("Name")
            if isinstance(name, str):
                actual[name] = parameter

    if set(actual) != set(expected):
        raise ContractVerificationError("The published SSM contract has missing or unexpected parameter names.")

    type_counts = {parameter_type: 0 for parameter_type in sorted(ALLOWED_TYPES)}
    for name, wanted in expected.items():
        published = actual[name]
        if published.get("Type") != wanted["type"] or published.get("Value") != wanted["value"]:
            raise ContractVerificationError("A published SSM contract parameter does not match Terraform.")
        type_counts[wanted["type"]] += 1

    return len(expected), type_counts


def _fetch_parameters(names: list[str]) -> list[dict[str, object]]:
    command = [
        "aws",
        "ssm",
        "get-parameters",
        "--names",
        *names,
        "--no-with-decryption",
        "--region",
        os.environ.get("AWS_REGION", "us-east-1"),
        "--output",
        "json",
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise ContractVerificationError("AWS could not read the expected plain SSM contract parameters.")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ContractVerificationError("AWS returned an invalid SSM contract response.") from error
    parameters = response.get("Parameters") if isinstance(response, dict) else None
    if not isinstance(parameters, list) or any(not isinstance(item, dict) for item in parameters):
        raise ContractVerificationError("AWS returned an incomplete SSM contract response.")
    return parameters


def main() -> int:
    try:
        contract = json.load(sys.stdin)
        count, types = verify_contract(contract, _fetch_parameters)
    except (json.JSONDecodeError, OSError, ContractVerificationError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print(
        "SSM contract publication verified: "
        f"{count} exact parameters ({types['String']} String, {types['StringList']} StringList); values suppressed."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
