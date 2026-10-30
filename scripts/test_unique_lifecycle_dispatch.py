import io
import json
import unittest
from argparse import Namespace
from unittest.mock import patch
from urllib.error import URLError

from assert_unique_lifecycle_dispatch import (
    LifecycleDispatchError,
    assert_unique_dispatch_id,
    check_dispatch,
    fetch_workflow_runs,
)


DISPATCH_ID = "a" * 32


class UniqueLifecycleDispatchTests(unittest.TestCase):
    def run_record(self, run_id: int, dispatch_id: str = DISPATCH_ID) -> dict[str, object]:
        return {
            "id": run_id,
            "display_title": f"hml-2026-10-29-foundation-open:{dispatch_id}",
        }

    def test_accepts_a_new_dispatch_id(self) -> None:
        assert_unique_dispatch_id(
            runs=[self.run_record(101, "b" * 32)],
            dispatch_id=DISPATCH_ID,
            current_run_id="202",
        )

    def test_rejects_a_dispatch_id_already_used_by_another_run(self) -> None:
        with self.assertRaisesRegex(LifecycleDispatchError, "already used"):
            assert_unique_dispatch_id(
                runs=[self.run_record(101)],
                dispatch_id=DISPATCH_ID,
                current_run_id="202",
            )

    def test_reruns_are_rejected_even_when_the_run_id_is_current(self) -> None:
        arguments = Namespace(
            dispatch_id=DISPATCH_ID,
            repository="owner/repo",
            workflow_file="ci.yml",
            started_at="2026-10-29T09:00:00Z",
            token="token",
            api_url="https://api.github.com",
            current_run_id="202",
            current_run_attempt="2",
        )
        with patch("assert_unique_lifecycle_dispatch.urlopen") as request:
            with self.assertRaisesRegex(LifecycleDispatchError, "reruns are not allowed"):
                check_dispatch(arguments)
        request.assert_not_called()

    def test_missing_dispatch_id_is_rejected_before_api_access(self) -> None:
        arguments = Namespace(
            dispatch_id="",
            repository="owner/repo",
            workflow_file="ci.yml",
            started_at="2026-10-29T09:00:00Z",
            token="token",
            api_url="https://api.github.com",
            current_run_id="202",
            current_run_attempt="1",
        )
        with patch("assert_unique_lifecycle_dispatch.urlopen") as request:
            with self.assertRaisesRegex(LifecycleDispatchError, "is required"):
                check_dispatch(arguments)
        request.assert_not_called()

    def test_history_api_failure_fails_closed(self) -> None:
        arguments = Namespace(
            dispatch_id=DISPATCH_ID,
            repository="owner/repo",
            workflow_file="ci.yml",
            started_at="2026-10-29T09:00:00Z",
            token="token",
            api_url="https://api.github.com",
            current_run_id="202",
            current_run_attempt="1",
        )
        with patch(
            "assert_unique_lifecycle_dispatch.urlopen",
            side_effect=URLError("offline"),
        ):
            with self.assertRaisesRegex(LifecycleDispatchError, "refusing to continue"):
                check_dispatch(arguments)

    def test_history_query_is_limited_to_the_authorized_session_day(self) -> None:
        response = io.BytesIO(json.dumps({"workflow_runs": []}).encode("utf-8"))
        with patch("assert_unique_lifecycle_dispatch.urlopen", return_value=response) as request:
            result = fetch_workflow_runs(
                repository="owner/repo",
                workflow_file="ci.yml",
                started_at="2026-10-29T09:00:00Z",
                token="token",
                api_url="https://api.github.com",
            )

        self.assertEqual(result, [])
        requested_url = request.call_args.args[0].full_url
        self.assertIn("created=%3E%3D2026-10-29T09%3A00%3A00Z", requested_url)
        self.assertIn("event=workflow_dispatch", requested_url)

    def test_rejects_malformed_dispatch_ids(self) -> None:
        with self.assertRaisesRegex(LifecycleDispatchError, "32 lowercase"):
            assert_unique_dispatch_id(
                runs=[],
                dispatch_id="not-a-uuid",
                current_run_id="202",
            )


if __name__ == "__main__":
    unittest.main()
