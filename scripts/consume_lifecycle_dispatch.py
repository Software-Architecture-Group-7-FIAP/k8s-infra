#!/usr/bin/env python3
"""Atomically consume a coordinator-issued workflow_dispatch authorization."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any


TABLE_NAME = "auto-shop-staging-lifecycle-sessions"
TARGET_REPOSITORY = "Software-Architecture-Group-7-FIAP/k8s-infra"
TARGET_REF = "refs/heads/main"
WORKFLOWS = ("CI", "Apply", "Destroy", "Orphan Audit")
SESSION_PATTERN = re.compile(r"^(hml|prd)-(\d{4}-\d{2}-\d{2})$")
DISPATCH_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
ACTOR_PATTERN = re.compile(r"^[A-Za-z0-9-]{1,39}(?:\[bot\])?$")


class AuthorizationError(ValueError):
    """Raised when the exact workflow dispatch cannot be authorized."""


class ConditionalWriteConflict(AuthorizationError):
    """Raised when another run consumed the one-use authorization first."""


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise AuthorizationError(f"{name} is required; lifecycle authorization fails closed.")
    return value


def _region() -> str:
    return os.environ.get("AWS_REGION", "").strip() or _required_environment("AWS_DEFAULT_REGION")


def _string(value: str) -> dict[str, str]:
    return {"S": value}


def _number(value: int) -> dict[str, str]:
    return {"N": str(value)}


def _key(session_id: str, record_key: str) -> dict[str, dict[str, str]]:
    return {"session_id": _string(session_id), "record_key": _string(record_key)}


def _dynamodb(operation: str, request: dict[str, Any]) -> dict[str, Any]:
    payload = {"TableName": TABLE_NAME, **request}
    command = [
        "aws",
        "dynamodb",
        operation,
        "--region",
        _region(),
        "--cli-input-json",
        json.dumps(payload, separators=(",", ":")),
        "--no-cli-pager",
    ]
    try:
        result = subprocess.run(command, capture_output=True, check=False, text=True)
    except OSError as error:
        raise AuthorizationError("AWS CLI is unavailable; lifecycle authorization fails closed.") from error

    if result.returncode != 0:
        if "ConditionalCheckFailedException" in result.stderr:
            raise ConditionalWriteConflict("The one-use lifecycle authorization was already consumed.")
        raise AuthorizationError(
            f"DynamoDB {operation} failed; lifecycle authorization fails closed."
        )
    try:
        response = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as error:
        raise AuthorizationError("DynamoDB returned an invalid response; authorization fails closed.") from error
    if not isinstance(response, dict):
        raise AuthorizationError("DynamoDB returned an invalid response; authorization fails closed.")
    return response


def _decode_item(item: Any) -> dict[str, Any]:
    if not isinstance(item, dict):
        raise AuthorizationError("The lifecycle authorization item is missing; authorization fails closed.")
    decoded: dict[str, Any] = {}
    for name, attribute in item.items():
        if not isinstance(attribute, dict):
            continue
        if isinstance(attribute.get("S"), str):
            decoded[name] = attribute["S"]
        elif isinstance(attribute.get("N"), str):
            try:
                decoded[name] = int(attribute["N"])
            except ValueError as error:
                raise AuthorizationError("The lifecycle authorization item is malformed.") from error
    return decoded


def _get_item(session_id: str, record_key: str) -> dict[str, Any]:
    response = _dynamodb(
        "get-item",
        {"Key": _key(session_id, record_key), "ConsistentRead": True},
    )
    return _decode_item(response.get("Item"))


def _validate_dispatch_actor(authorization: dict[str, Any], session_state: dict[str, Any]) -> str:
    actor = _required_environment("GITHUB_ACTOR")
    triggering_actor = _required_environment("LIFECYCLE_TRIGGERING_ACTOR")
    dispatch_actor = authorization.get("dispatch_actor")
    source_actor = authorization.get("source_actor")
    if triggering_actor != actor:
        raise AuthorizationError("The triggering actor does not match the original workflow actor.")
    if not ACTOR_PATTERN.fullmatch(actor):
        raise AuthorizationError("The GitHub dispatch actor is malformed; authorization fails closed.")
    if not isinstance(dispatch_actor, str) or not ACTOR_PATTERN.fullmatch(dispatch_actor):
        raise AuthorizationError("The authorized cross-repository dispatch actor is missing or malformed.")
    if not isinstance(source_actor, str) or not ACTOR_PATTERN.fullmatch(source_actor):
        raise AuthorizationError("The authorized source operator is missing or malformed.")
    if source_actor != session_state.get("operator"):
        raise AuthorizationError("The authorization source operator does not match the lifecycle session.")
    if actor != dispatch_actor:
        raise AuthorizationError("The GitHub actor does not match the authorized cross-repository actor.")
    return actor


def _inputs_from_event() -> dict[str, str]:
    event_path = Path(_required_environment("GITHUB_EVENT_PATH"))
    try:
        event = json.loads(event_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorizationError("The GitHub dispatch event could not be read; authorization fails closed.") from error
    inputs = event.get("inputs") if isinstance(event, dict) else None
    if not isinstance(inputs, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in inputs.items()
    ):
        raise AuthorizationError("The GitHub dispatch inputs are malformed; authorization fails closed.")
    return inputs


def _validate_session_id(session_id: str) -> str:
    match = SESSION_PATTERN.fullmatch(session_id)
    if match is None:
        raise AuthorizationError("The lifecycle session ID is malformed; authorization fails closed.")
    try:
        datetime.strptime(match.group(2), "%Y-%m-%d")
    except ValueError as error:
        raise AuthorizationError("The lifecycle session date is invalid; authorization fails closed.") from error
    return match.group(1)


def _canonical_input_hash(inputs: dict[str, str]) -> str:
    canonical = json.dumps(inputs, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _expected_action(workflow: str, inputs: dict[str, str]) -> str:
    if workflow == "Orphan Audit":
        return "audit"
    if workflow == "Destroy":
        return "close"
    if workflow in {"CI", "Apply"}:
        operation = inputs.get("operation")
        if operation == "open":
            return "open"
        if operation == "nat-disable":
            return "close"
    raise AuthorizationError("The workflow inputs do not identify an allowed lifecycle action.")


def _validate_target(
    item: dict[str, Any],
    *,
    session_id: str,
    stage: str,
    action: str,
    workflow: str,
    input_hash: str,
    now: int,
) -> None:
    if (
        item.get("record_type") != "authorization"
        or item.get("status") != "issued"
        or item.get("stage") != stage
        or item.get("action") != action
        or item.get("target_repository") != TARGET_REPOSITORY
        or item.get("target_workflow") != workflow
        or item.get("target_ref") != TARGET_REF
        or item.get("inputs_sha256") != input_hash
        or int(item.get("expires_at", 0)) <= now
    ):
        raise AuthorizationError("The one-use lifecycle authorization is invalid or expired.")
    if item.get("session_id") != session_id:
        raise AuthorizationError("The lifecycle authorization belongs to another session.")


def consume(session_id: str, dispatch_id: str, workflow: str) -> None:
    if workflow not in WORKFLOWS:
        raise AuthorizationError("The workflow is not an allowed lifecycle consumer.")
    if not DISPATCH_ID_PATTERN.fullmatch(dispatch_id):
        raise AuthorizationError("A valid lifecycle dispatch ID is required; authorization fails closed.")
    stage = _validate_session_id(session_id)
    run_id = _required_environment("GITHUB_RUN_ID")
    run_attempt_text = _required_environment("GITHUB_RUN_ATTEMPT")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id) or not re.fullmatch(r"[1-9][0-9]*", run_attempt_text):
        raise AuthorizationError("The GitHub run identity is malformed; authorization fails closed.")
    run_attempt = int(run_attempt_text)

    if (
        _required_environment("GITHUB_EVENT_NAME") != "workflow_dispatch"
        or _required_environment("GITHUB_REPOSITORY") != TARGET_REPOSITORY
        or _required_environment("GITHUB_WORKFLOW") != workflow
        or _required_environment("GITHUB_REF") != TARGET_REF
    ):
        raise AuthorizationError("The consumer repository, workflow, or ref does not match authorization.")

    inputs = _inputs_from_event()
    if inputs.get("session_id") != session_id or inputs.get("lifecycle_dispatch_id") != dispatch_id:
        raise AuthorizationError("The requested session and dispatch ID differ from the workflow inputs.")
    input_hash = _canonical_input_hash(inputs)
    action = _expected_action(workflow, inputs)
    record_key = f"AUTH#DISPATCH#{dispatch_id}"
    now = int(time.time())
    item = _get_item(session_id, record_key)
    session_state = _get_item(session_id, "STATE")
    actor = _validate_dispatch_actor(item, session_state)
    _validate_target(
        item,
        session_id=session_id,
        stage=stage,
        action=action,
        workflow=workflow,
        input_hash=input_hash,
        now=now,
    )

    try:
        _dynamodb(
            "update-item",
            {
                "Key": _key(session_id, record_key),
                "UpdateExpression": (
                    "SET #status = :consumed, consumer_actor = :actor, consumer_run_id = :run_id, "
                    "consumer_run_attempt = :run_attempt, consumed_at = :now"
                ),
                "ConditionExpression": (
                    "#status = :issued AND record_type = :record_type "
                    "AND expires_at > :now AND stage = :stage AND action = :action "
                    "AND target_repository = :repository AND target_workflow = :workflow "
                    "AND target_ref = :ref AND inputs_sha256 = :input_hash AND dispatch_actor = :dispatch_actor"
                ),
                "ExpressionAttributeNames": {"#status": "status"},
                "ExpressionAttributeValues": {
                    ":consumed": _string("consumed"),
                    ":issued": _string("issued"),
                    ":record_type": _string("authorization"),
                    ":now": _number(now),
                    ":stage": _string(stage),
                    ":action": _string(action),
                    ":repository": _string(TARGET_REPOSITORY),
                    ":workflow": _string(workflow),
                    ":ref": _string(TARGET_REF),
                    ":input_hash": _string(input_hash),
                    ":actor": _string(actor),
                    ":dispatch_actor": _string(actor),
                    ":run_id": _string(run_id),
                    ":run_attempt": _number(run_attempt),
                },
            },
        )
    except ConditionalWriteConflict:
        existing = _get_item(session_id, record_key)
        if (
            existing.get("record_type") == "authorization"
            and existing.get("status") == "consumed"
            and existing.get("consumer_actor") == actor
            and existing.get("consumer_run_id") == run_id
            and int(existing.get("consumer_run_attempt", 0)) == run_attempt
            and existing.get("stage") == stage
            and existing.get("action") == action
            and existing.get("target_repository") == TARGET_REPOSITORY
            and existing.get("target_workflow") == workflow
            and existing.get("target_ref") == TARGET_REF
            and existing.get("inputs_sha256") == input_hash
        ):
            print("This GitHub run attempt already consumed the matching lifecycle authorization.")
            return
        raise AuthorizationError("The one-use lifecycle authorization is invalid, expired, or already consumed.")

    print(f"Consumed lifecycle authorization for {workflow}, session {session_id}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--dispatch-id", required=True)
    parser.add_argument("--workflow", required=True, choices=WORKFLOWS)
    arguments = parser.parse_args()
    try:
        consume(arguments.session_id, arguments.dispatch_id, arguments.workflow)
    except (AuthorizationError, TypeError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
