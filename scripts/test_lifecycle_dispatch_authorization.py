from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from consume_lifecycle_dispatch import AuthorizationError, _expected_action, _validate_dispatch_actor
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


if __name__ == "__main__":
    unittest.main()
