#!/usr/bin/env python3
"""Verify the exact successful GitHub Actions run that created a saved plan."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


PLAN_ID_PATTERN = re.compile(r"(?P<run_id>[1-9][0-9]*)-(?P<attempt>[1-9][0-9]*)\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40,64}\Z")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
EXPECTED_WORKFLOWS = {
    "apply": ".github/workflows/ci.yml",
    "destroy": ".github/workflows/destroy.yml",
}
ALLOWED_WORKFLOW_PATHS = {
    "apply": {
        ".github/workflows/ci.yml",
        ".github/workflows/cluster-ci.yml",
    },
    "destroy": {
        ".github/workflows/destroy.yml",
        ".github/workflows/cluster-destroy.yml",
    },
}


class PlanRunError(ValueError):
    """Raised when the saved plan's originating workflow run is not trusted."""


def fetch_workflow_run(
    *,
    repository: str,
    run_id: str,
    token: str,
    api_url: str,
) -> dict[str, object]:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise PlanRunError("GITHUB_REPOSITORY is invalid.")
    if not run_id.isdecimal() or int(run_id) <= 0:
        raise PlanRunError("The plan ID contains an invalid GitHub Actions run ID.")
    if not token.strip():
        raise PlanRunError("GITHUB_TOKEN is required to verify the originating plan run.")

    endpoint = f"{api_url.rstrip('/')}/repos/{repository}/actions/runs/{quote(run_id, safe='')}"
    request = Request(
        endpoint,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=20) as response:
            payload = json.loads(response.read())
    except (
        HTTPError,
        URLError,
        TimeoutError,
        OSError,
        UnicodeError,
        json.JSONDecodeError,
    ) as error:
        raise PlanRunError(
            "GitHub Actions run metadata is unavailable; refusing to download the plan attestation."
        ) from error

    if not isinstance(payload, dict):
        raise PlanRunError("GitHub returned an invalid Actions run record.")
    return payload


def verify_workflow_run(
    *,
    run: dict[str, object],
    repository: str,
    run_id: str,
    attempt: str,
    purpose: str,
    expected_commit_sha: str,
    expected_workflow_path: str | None = None,
) -> None:
    default_workflow = EXPECTED_WORKFLOWS.get(purpose)
    if default_workflow is None:
        raise PlanRunError("The plan purpose must be apply or destroy.")
    expected_workflow = expected_workflow_path or default_workflow
    if expected_workflow not in ALLOWED_WORKFLOW_PATHS[purpose]:
        raise PlanRunError("The expected plan workflow path is not allowed for this purpose.")
    if not COMMIT_PATTERN.fullmatch(expected_commit_sha):
        raise PlanRunError("The expected commit must be a lowercase Git commit SHA.")

    actual_run_id = run.get("id")
    if type(actual_run_id) is not int or str(actual_run_id) != run_id:
        raise PlanRunError("The GitHub run ID does not match the requested plan ID.")

    path = run.get("path")
    if not isinstance(path, str):
        raise PlanRunError("GitHub returned an incomplete Actions run record (workflow path).")
    workflow_path, separator, path_ref = path.partition("@")
    if workflow_path != expected_workflow:
        raise PlanRunError(f"The plan must originate from {expected_workflow}.")
    if separator and path_ref not in {"main", "refs/heads/main"}:
        raise PlanRunError("The plan workflow run ref must be main.")

    if run.get("event") != "workflow_dispatch":
        raise PlanRunError("The plan must originate from a workflow_dispatch run.")
    if run.get("head_branch") != "main":
        raise PlanRunError("The plan workflow run must target the main branch.")
    if run.get("head_sha") != expected_commit_sha:
        raise PlanRunError("The plan workflow run commit does not match this apply/destroy commit.")

    actual_attempt = run.get("run_attempt")
    if type(actual_attempt) is not int or str(actual_attempt) != attempt:
        raise PlanRunError("The plan ID attempt does not match the originating workflow run attempt.")

    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise PlanRunError("The originating plan workflow run must be completed successfully.")

    actual_repository = run.get("repository")
    if not isinstance(actual_repository, dict) or actual_repository.get("full_name") != repository:
        raise PlanRunError("The plan workflow run repository does not match GITHUB_REPOSITORY.")


def check_plan_run(arguments: argparse.Namespace) -> int:
    match = PLAN_ID_PATTERN.fullmatch(arguments.plan_id)
    if not match:
        raise PlanRunError("The plan ID must be a positive GitHub run ID and attempt, formatted as digits-digits.")

    run = fetch_workflow_run(
        repository=arguments.repository,
        run_id=match.group("run_id"),
        token=arguments.token,
        api_url=arguments.api_url,
    )
    verify_workflow_run(
        run=run,
        repository=arguments.repository,
        run_id=match.group("run_id"),
        attempt=match.group("attempt"),
        purpose=arguments.purpose,
        expected_commit_sha=arguments.expected_commit_sha,
        expected_workflow_path=arguments.expected_workflow_path,
    )
    print(f"Verified the successful {arguments.purpose} plan run for {arguments.plan_id}.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-id", required=True)
    parser.add_argument("--purpose", choices=sorted(EXPECTED_WORKFLOWS), required=True)
    parser.add_argument("--expected-workflow-path", choices=sorted({path for paths in ALLOWED_WORKFLOW_PATHS.values() for path in paths}))
    parser.add_argument("--expected-commit-sha", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        return check_plan_run(arguments)
    except PlanRunError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
