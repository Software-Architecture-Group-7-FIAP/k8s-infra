#!/usr/bin/env python3
"""Fail closed before AWS credentials when foundation operations lack runner configuration."""

from __future__ import annotations

import os
import re
import sys


CONNECTION_ARN = re.compile(
    r"^arn:aws:(?:codeconnections|codestar-connections):us-east-1:035611741563:connection/[A-Za-z0-9-]+$"
)


class RunnerConfigurationError(ValueError):
    pass


def validate_runner_configuration(
    *,
    stack: str,
    enabled: str,
    group_id: str,
    connection_arn: str,
) -> None:
    if stack != "foundation":
        return
    if enabled.lower() != "true":
        raise RunnerConfigurationError(
            "Foundation lifecycle operations require ENABLE_PRIVATE_EKS_RUNNER=true so the private runner remains managed."
        )
    try:
        parsed_group_id = int(group_id)
    except ValueError as error:
        raise RunnerConfigurationError("GITHUB_RUNNER_GROUP_ID must identify a custom organization runner group.") from error
    if parsed_group_id <= 1:
        raise RunnerConfigurationError("GITHUB_RUNNER_GROUP_ID must be greater than the default group ID 1.")
    if not CONNECTION_ARN.fullmatch(connection_arn):
        raise RunnerConfigurationError("GITHUB_CODECONNECTION_ARN must be a valid CodeConnections connection ARN.")


def main() -> int:
    try:
        validate_runner_configuration(
            stack=os.environ.get("REQUESTED_STACK", ""),
            enabled=os.environ.get("TF_VAR_enable_private_eks_runner", "false"),
            group_id=os.environ.get("TF_VAR_github_runner_group_id", "0"),
            connection_arn=os.environ.get("TF_VAR_github_codeconnection_arn", ""),
        )
    except RunnerConfigurationError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
