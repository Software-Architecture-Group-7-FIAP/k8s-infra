from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import consume_lifecycle_dispatch as lifecycle_consumer
from consume_lifecycle_dispatch import (
    AuthorizationError,
    _canonical_input_hash,
    _expected_action,
    _validate_dispatch_actor,
    _validate_target,
)
from require_trusted_lifecycle_operator import main as require_trusted_operator


class LifecycleDispatchActorTests(unittest.TestCase):
    def test_cluster_workflows_keep_the_open_and_close_actions_distinct(self) -> None:
        self.assertEqual(
            _expected_action("K8s HML Cluster Plan", {"operation": "open"}),
            "open",
        )
        self.assertEqual(
            _expected_action("K8s HML Cluster Apply", {"operation": "open"}),
            "open",
        )
        self.assertEqual(
            _expected_action("K8s HML Cluster Destroy", {"operation": "plan"}),
            "close",
        )
        self.assertEqual(
            _expected_action("K8s HML Cluster Destroy", {"operation": "destroy"}),
            "close",
        )

    def test_cluster_workflows_reject_unrelated_lifecycle_operations(self) -> None:
        with self.assertRaisesRegex(AuthorizationError, "allowed lifecycle action"):
            _expected_action("K8s HML Cluster Apply", {"operation": "nat-disable"})

    def test_accepts_the_configured_dispatch_actor_bound_to_the_session_operator(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        session_state = {"operator": "trusted-operator"}
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            self.assertEqual(_validate_dispatch_actor(authorization, session_state), "dispatch-bot[bot]")

    def test_rejects_a_different_allowlisted_actor_attempting_to_consume(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        session_state = {"operator": "trusted-operator"}
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "another-operator",
                "LIFECYCLE_TRIGGERING_ACTOR": "another-operator",
                "LIFECYCLE_TRUSTED_OPERATORS": "another-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "does not match the authorized cross-repository actor"):
                _validate_dispatch_actor(authorization, session_state)

    def test_rejects_missing_dispatch_actor_or_mismatched_source_operator(self) -> None:
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRUSTED_OPERATORS": "dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "dispatch actor is missing"):
                _validate_dispatch_actor({"source_actor": "trusted-operator"}, {"operator": "trusted-operator"})

            with self.assertRaisesRegex(AuthorizationError, "source operator does not match"):
                _validate_dispatch_actor(
                    {"dispatch_actor": "dispatch-bot[bot]", "source_actor": "different-operator"},
                    {"operator": "trusted-operator"},
                )

    def test_consumer_rejects_a_different_current_triggering_actor(self) -> None:
        authorization = {
            "dispatch_actor": "dispatch-bot[bot]",
            "source_actor": "trusted-operator",
        }
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "dispatch-bot[bot]",
                "LIFECYCLE_TRIGGERING_ACTOR": "trusted-operator",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator,dispatch-bot[bot]",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(AuthorizationError, "triggering actor does not match the original workflow actor"):
                _validate_dispatch_actor(authorization, {"operator": "trusted-operator"})

    def test_actor_gate_rejects_a_rerun_before_any_aws_assumption(self) -> None:
        with patch.dict(
            os.environ,
            {
                "GITHUB_ACTOR": "trusted-operator",
                "LIFECYCLE_TRIGGERING_ACTOR": "untrusted-rerunner",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator",
            },
            clear=False,
        ), patch("sys.argv", ["require_trusted_lifecycle_operator.py"]):
            self.assertEqual(require_trusted_operator(), 1)


class LifecycleDispatchTargetTests(unittest.TestCase):
    def _validate(self, target_ref: str) -> None:
        _validate_target(
            {
                "record_type": "authorization",
                "status": "issued",
                "stage": "hml",
                "action": "open",
                "target_repository": "Software-Architecture-Group-7-FIAP/k8s-infra",
                "target_workflow": "CI",
                "target_ref": target_ref,
                "inputs_sha256": "a" * 64,
                "expires_at": 200,
                "session_id": "hml-2026-10-31",
            },
            session_id="hml-2026-10-31",
            stage="hml",
            action="open",
            workflow="CI",
            input_hash="a" * 64,
            now=100,
        )

    def test_accepts_dispatch_branch_name_for_main(self) -> None:
        self._validate("main")

    def test_accepts_canonical_main_ref(self) -> None:
        self._validate("refs/heads/main")

    def test_rejects_another_branch_or_tag(self) -> None:
        for target_ref in ("develop", "refs/heads/develop", "refs/tags/main"):
            with self.subTest(target_ref=target_ref), self.assertRaises(AuthorizationError):
                self._validate(target_ref)


class LifecycleDispatchConsumeExpressionTests(unittest.TestCase):
    def test_consume_aliases_reserved_action_attribute(self) -> None:
        session_id = "hml-2026-10-31"
        dispatch_id = "a" * 32
        workflow = "CI"
        inputs = {
            "session_id": session_id,
            "lifecycle_dispatch_id": dispatch_id,
            "started_at": "2026-10-31T15:38:30Z",
            "session_mode": "hml",
            "stack": "foundation",
            "operation": "open",
            "enable_nat_gateway": "true",
        }
        authorization = {
            "record_type": "authorization",
            "status": "issued",
            "stage": "hml",
            "action": "open",
            "target_repository": "Software-Architecture-Group-7-FIAP/k8s-infra",
            "target_workflow": workflow,
            "target_ref": "refs/heads/main",
            "inputs_sha256": _canonical_input_hash(inputs),
            "expires_at": 200,
            "session_id": session_id,
            "dispatch_actor": "trusted-operator",
            "source_actor": "trusted-operator",
        }
        session_state = {"operator": "trusted-operator"}

        with tempfile.TemporaryDirectory(prefix="lifecycle-dispatch-test-") as temporary_directory:
            event_path = Path(temporary_directory) / "event.json"
            event_path.write_text(json.dumps({"inputs": inputs}), encoding="utf-8")
            environment = {
                "GITHUB_RUN_ID": "12345",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REPOSITORY": "Software-Architecture-Group-7-FIAP/k8s-infra",
                "GITHUB_WORKFLOW": workflow,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_ACTOR": "trusted-operator",
                "LIFECYCLE_TRIGGERING_ACTOR": "trusted-operator",
                "LIFECYCLE_TRUSTED_OPERATORS": "trusted-operator",
            }
            with (
                patch.dict(os.environ, environment, clear=False),
                patch.object(lifecycle_consumer, "_get_item", side_effect=[authorization, session_state]),
                patch.object(lifecycle_consumer, "_dynamodb") as dynamodb,
                patch.object(lifecycle_consumer.time, "time", return_value=100),
            ):
                lifecycle_consumer.consume(session_id, dispatch_id, workflow)

        update_request = dynamodb.call_args.args[1]
        self.assertEqual(update_request["ExpressionAttributeNames"]["#action"], "action")
        self.assertIn("#action = :action", update_request["ConditionExpression"])


if __name__ == "__main__":
    unittest.main()
