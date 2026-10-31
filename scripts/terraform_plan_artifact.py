#!/usr/bin/env python3
"""Create and verify metadata for private, saved Terraform plan objects."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
import sys
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path


PLAN_ID_PATTERN = re.compile(r"[0-9]+-[0-9]+\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40,64}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
ALLOWED_STACKS = {"foundation", "platform", "hml", "production"}
ALLOWED_PURPOSES = {"apply", "destroy"}
ALLOWED_SESSION_MODES = {"hml", "prd-window"}
STARTED_AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


class PlanArtifactError(ValueError):
    """Raised when saved-plan metadata or its file does not match expectations."""


def _parse_utc(value: str, label: str) -> datetime:
    try:
        parsed = datetime.strptime(value, STARTED_AT_FORMAT)
    except ValueError as error:
        raise PlanArtifactError(f"{label} must use UTC format YYYY-MM-DDTHH:MM:SSZ.") from error
    if parsed.strftime(STARTED_AT_FORMAT) != value:
        raise PlanArtifactError(f"{label} must use UTC format YYYY-MM-DDTHH:MM:SSZ.")
    return parsed.replace(tzinfo=timezone.utc)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as plan_file:
            for chunk in iter(lambda: plan_file.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise PlanArtifactError(f"Could not read saved plan file: {path.name}.") from error
    return digest.hexdigest()


def create_attestation(arguments: argparse.Namespace) -> int:
    manifest_path = Path(arguments.manifest)
    try:
        manifest_digest = _sha256(manifest_path)
        output_path = Path(arguments.output)
        output_path.write_text(f"{manifest_digest}\n", encoding="ascii")
    except OSError as error:
        raise PlanArtifactError("Could not create the saved-plan manifest attestation.") from error

    print(f"Created the saved-plan manifest attestation at {output_path.name}.")
    return 0


def verify_attestation(arguments: argparse.Namespace) -> int:
    manifest_digest = _sha256(Path(arguments.manifest))
    try:
        attested_digest = Path(arguments.attestation).read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise PlanArtifactError("The saved-plan manifest attestation is missing or unreadable.") from error

    if attested_digest.endswith("\n"):
        attested_digest = attested_digest[:-1]
    if not SHA256_PATTERN.fullmatch(attested_digest):
        raise PlanArtifactError("The saved-plan manifest attestation must contain one SHA-256 digest.")
    if not hmac.compare_digest(manifest_digest, attested_digest):
        raise PlanArtifactError("The saved-plan manifest does not match its GitHub Actions attestation.")

    print("Verified the saved-plan manifest against its GitHub Actions attestation.")
    return 0


def _validate_common(plan_id: str, purpose: str, commit_sha: str, session_id: str) -> None:
    if not PLAN_ID_PATTERN.fullmatch(plan_id):
        raise PlanArtifactError("plan_id must be a GitHub run ID and attempt, formatted as digits-digits.")
    if purpose not in ALLOWED_PURPOSES:
        raise PlanArtifactError("purpose must be apply or destroy.")
    if not COMMIT_PATTERN.fullmatch(commit_sha):
        raise PlanArtifactError("commit_sha must be a 40- to 64-character lowercase hexadecimal SHA.")
    if not session_id or session_id.strip() != session_id or any(ord(char) < 32 for char in session_id):
        raise PlanArtifactError("session_id must be non-empty and contain no surrounding/control whitespace.")


def _validate_aws_scope(account_id: str, region: str) -> None:
    if not re.fullmatch(r"[0-9]{12}", account_id):
        raise PlanArtifactError("aws_account_id must contain exactly 12 digits.")
    if not re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]", region):
        raise PlanArtifactError("aws_region must be a valid region identifier.")


def _parse_plan_argument(value: str) -> tuple[str, Path]:
    stack, separator, file_name = value.partition("=")
    if not separator or stack not in ALLOWED_STACKS or not file_name:
        raise PlanArtifactError(
            "Each plan must be supplied as foundation=FILE, platform=FILE, hml=FILE, or production=FILE."
        )
    path = Path(file_name)
    if not path.is_file():
        raise PlanArtifactError(f"Saved plan for {stack} does not exist.")
    return stack, path


def create_manifest(arguments: argparse.Namespace) -> int:
    _validate_common(arguments.plan_id, arguments.purpose, arguments.commit_sha, arguments.session_id)
    _validate_aws_scope(arguments.aws_account_id, arguments.aws_region)
    session_mode = getattr(arguments, "session_mode", "hml")
    default_scope = "open"
    if arguments.purpose == "destroy":
        requested_stacks = {value.partition("=")[0] for value in arguments.plan}
        default_scope = "compute" if requested_stacks == {"foundation"} else "all"
    scope = getattr(arguments, "scope", default_scope)
    _validate_lifecycle_scope(arguments.purpose, scope, session_mode)
    session_started_at = _parse_utc(arguments.session_started_at, "session_started_at")
    created_at = datetime.now(timezone.utc).replace(microsecond=0)
    if created_at < session_started_at:
        raise PlanArtifactError("The plan cannot be created before the authorized session starts.")

    plans: dict[str, dict[str, str]] = {}
    for value in arguments.plan:
        stack, path = _parse_plan_argument(value)
        _validate_stack_session_mode(stack, session_mode)
        if stack in plans:
            raise PlanArtifactError(f"The {stack} plan was supplied more than once.")
        plans[stack] = {"file": f"{stack}.tfplan", "sha256": _sha256(path)}
    if not plans:
        raise PlanArtifactError("At least one saved plan is required.")
    _validate_scope_stack(arguments.purpose, scope, plans.keys())

    manifest = {
        "schema_version": 2,
        "plan_id": arguments.plan_id,
        "purpose": arguments.purpose,
        "aws_account_id": arguments.aws_account_id,
        "aws_region": arguments.aws_region,
        "commit_sha": arguments.commit_sha,
        "session_id": arguments.session_id,
        "session_started_at": arguments.session_started_at,
        "session_mode": session_mode,
        "scope": scope,
        "created_at": created_at.strftime(STARTED_AT_FORMAT),
        "terraform_version": arguments.terraform_version,
        "plans": plans,
    }
    output = Path(arguments.output)
    try:
        output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        output.chmod(0o600)
    except OSError as error:
        raise PlanArtifactError("Could not write the saved-plan manifest.") from error

    print(f"Created {arguments.purpose} plan manifest for {arguments.plan_id}.")
    return 0


def verify_manifest(arguments: argparse.Namespace) -> int:
    _validate_common(arguments.plan_id, arguments.purpose, arguments.commit_sha, arguments.session_id)
    _validate_aws_scope(arguments.aws_account_id, arguments.aws_region)
    session_mode = getattr(arguments, "session_mode", "hml")
    default_scope = "open"
    if arguments.purpose == "destroy":
        default_scope = "compute" if arguments.stack == "foundation" else "all"
    scope = getattr(arguments, "scope", default_scope)
    _validate_lifecycle_scope(arguments.purpose, scope, session_mode)
    if arguments.stack not in ALLOWED_STACKS:
        raise PlanArtifactError("stack must be foundation, platform, hml, or production.")
    _validate_stack_session_mode(arguments.stack, session_mode)
    _validate_scope_stack(arguments.purpose, scope, (arguments.stack,))
    expected_started_at = _parse_utc(arguments.session_started_at, "session_started_at")

    try:
        manifest = json.loads(Path(arguments.manifest).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PlanArtifactError("Could not read a valid saved-plan manifest.") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
        raise PlanArtifactError("The saved-plan manifest has an unsupported schema.")

    expected_values = {
        "aws_account_id": arguments.aws_account_id,
        "aws_region": arguments.aws_region,
        "plan_id": arguments.plan_id,
        "purpose": arguments.purpose,
        "commit_sha": arguments.commit_sha,
        "session_id": arguments.session_id,
        "session_started_at": arguments.session_started_at,
        "session_mode": session_mode,
        "scope": scope,
        "terraform_version": arguments.terraform_version,
    }
    for key, expected in expected_values.items():
        if manifest.get(key) != expected:
            raise PlanArtifactError(f"The saved plan does not match the requested {key}.")

    created_at_value = manifest.get("created_at")
    if not isinstance(created_at_value, str):
        raise PlanArtifactError("The saved-plan manifest is missing its creation time.")
    created_at = _parse_utc(created_at_value, "created_at")
    now = datetime.now(timezone.utc)
    if created_at < expected_started_at or created_at > now:
        raise PlanArtifactError("The saved plan was created outside the authorized session window.")

    plans = manifest.get("plans")
    if not isinstance(plans, dict) or set(plans) != {arguments.stack}:
        raise PlanArtifactError("The manifest must contain only the requested Terraform stack.")
    plan_record = plans.get(arguments.stack)
    if not isinstance(plan_record, dict):
        raise PlanArtifactError(f"The manifest does not contain a {arguments.stack} plan.")
    if plan_record.get("file") != f"{arguments.stack}.tfplan":
        raise PlanArtifactError("The saved-plan manifest contains an unexpected file name.")
    expected_digest = plan_record.get("sha256")
    if not isinstance(expected_digest, str) or not SHA256_PATTERN.fullmatch(expected_digest):
        raise PlanArtifactError("The saved-plan manifest has an invalid SHA-256 checksum.")

    actual_digest = _sha256(Path(arguments.plan_file))
    if actual_digest != expected_digest:
        raise PlanArtifactError("The saved plan checksum does not match its manifest.")

    print(f"Verified {arguments.purpose} plan {arguments.plan_id} for {arguments.stack}.")
    return 0


def _validate_lifecycle_scope(purpose: str, scope: str, session_mode: str) -> None:
    if session_mode not in ALLOWED_SESSION_MODES:
        raise PlanArtifactError("session_mode must be hml or prd-window.")
    if purpose == "apply" and scope not in {"open", "nat-disable"}:
        raise PlanArtifactError("An apply plan scope must be open or nat-disable.")
    if purpose == "destroy" and scope not in {"all", "compute"}:
        raise PlanArtifactError("A destroy plan scope must be all or compute.")


def _validate_stack_session_mode(stack: str, session_mode: str) -> None:
    expected_mode = {"hml": "hml", "production": "prd-window"}.get(stack)
    if expected_mode is not None and session_mode != expected_mode:
        raise PlanArtifactError(f"The {stack} root requires session_mode={expected_mode}.")


def _validate_scope_stack(purpose: str, scope: str, stacks: Iterable[str]) -> None:
    stack_set = set(stacks)
    if len(stack_set) != 1:
        raise PlanArtifactError("Each saved-plan artifact must contain exactly one Terraform stack.")
    if purpose == "destroy" and scope == "all" and stack_set == {"foundation"}:
        raise PlanArtifactError(
            "The all destroy scope cannot target foundation; it must preserve persistent network and SSM resources."
        )
    if scope == "compute" and stack_set != {"foundation"}:
        raise PlanArtifactError("The compute destroy scope is valid only for foundation.")
    if purpose == "apply" and scope == "nat-disable" and stack_set != {"foundation"}:
        raise PlanArtifactError("The NAT-only apply scope is valid only for foundation.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create-manifest")
    create.add_argument("--plan-id", required=True)
    create.add_argument("--purpose", required=True)
    create.add_argument("--aws-account-id", required=True)
    create.add_argument("--aws-region", required=True)
    create.add_argument("--commit-sha", required=True)
    create.add_argument("--session-id", required=True)
    create.add_argument("--session-started-at", required=True)
    create.add_argument("--session-mode", required=True, choices=tuple(sorted(ALLOWED_SESSION_MODES)))
    create.add_argument("--scope", required=True)
    create.add_argument("--terraform-version", required=True)
    create.add_argument("--output", required=True)
    create.add_argument("--plan", action="append", default=[])
    create.set_defaults(handler=create_manifest)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--plan-file", required=True)
    verify.add_argument("--plan-id", required=True)
    verify.add_argument("--purpose", required=True)
    verify.add_argument("--aws-account-id", required=True)
    verify.add_argument("--aws-region", required=True)
    verify.add_argument("--stack", required=True)
    verify.add_argument("--commit-sha", required=True)
    verify.add_argument("--session-id", required=True)
    verify.add_argument("--session-started-at", required=True)
    verify.add_argument("--session-mode", required=True, choices=tuple(sorted(ALLOWED_SESSION_MODES)))
    verify.add_argument("--scope", required=True)
    verify.add_argument("--terraform-version", required=True)
    verify.set_defaults(handler=verify_manifest)

    create_attestation_parser = subparsers.add_parser("create-attestation")
    create_attestation_parser.add_argument("--manifest", required=True)
    create_attestation_parser.add_argument("--output", required=True)
    create_attestation_parser.set_defaults(handler=create_attestation)

    verify_attestation_parser = subparsers.add_parser("verify-attestation")
    verify_attestation_parser.add_argument("--manifest", required=True)
    verify_attestation_parser.add_argument("--attestation", required=True)
    verify_attestation_parser.set_defaults(handler=verify_attestation)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        return arguments.handler(arguments)
    except PlanArtifactError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
