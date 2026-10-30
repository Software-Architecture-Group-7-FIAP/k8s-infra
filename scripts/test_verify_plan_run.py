import io
import json
import unittest
from argparse import Namespace
from unittest.mock import patch
from urllib.error import URLError

from verify_plan_run import PlanRunError, check_plan_run


class VerifyPlanRunTests(unittest.TestCase):
    def arguments(self, *, purpose: str = "apply", plan_id: str = "202-1") -> Namespace:
        return Namespace(
            plan_id=plan_id,
            purpose=purpose,
            expected_commit_sha="a" * 40,
            repository="owner/repo",
            api_url="https://api.github.com",
            token="token",
        )

    def run_record(self, **overrides: object) -> dict[str, object]:
        record: dict[str, object] = {
            "id": 202,
            "path": ".github/workflows/ci.yml@refs/heads/main",
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_sha": "a" * 40,
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
            "repository": {"full_name": "owner/repo"},
        }
        record.update(overrides)
        return record

    def mock_run(self, record: dict[str, object]) -> io.BytesIO:
        return io.BytesIO(json.dumps(record).encode("utf-8"))

    def check_with_record(
        self,
        record: dict[str, object],
        *,
        arguments: Namespace | None = None,
    ) -> int:
        with patch("verify_plan_run.urlopen", return_value=self.mock_run(record)):
            return check_plan_run(arguments or self.arguments())

    def test_accepts_the_exact_successful_plan_run(self) -> None:
        self.assertEqual(self.check_with_record(self.run_record()), 0)

    def test_rejects_a_pull_request_run(self) -> None:
        record = self.run_record(event="pull_request", head_branch="feature")
        with self.assertRaisesRegex(PlanRunError, "workflow_dispatch"):
            self.check_with_record(record)

    def test_rejects_a_non_main_ref(self) -> None:
        record = self.run_record(path=".github/workflows/ci.yml@refs/heads/feature", head_branch="feature")
        with self.assertRaisesRegex(PlanRunError, "ref must be main"):
            self.check_with_record(record)

    def test_rejects_a_non_main_branch(self) -> None:
        with self.assertRaisesRegex(PlanRunError, "main branch"):
            self.check_with_record(self.run_record(head_branch="feature"))

    def test_rejects_a_different_commit(self) -> None:
        with self.assertRaisesRegex(PlanRunError, "commit does not match"):
            self.check_with_record(self.run_record(head_sha="b" * 40))

    def test_rejects_the_wrong_origin_workflow(self) -> None:
        record = self.run_record(path=".github/workflows/apply.yml@refs/heads/main")
        with self.assertRaisesRegex(PlanRunError, "ci.yml"):
            self.check_with_record(record)

    def test_destroy_plan_requires_destroy_workflow(self) -> None:
        record = self.run_record(path=".github/workflows/destroy.yml@refs/heads/main")
        self.assertEqual(self.check_with_record(record, arguments=self.arguments(purpose="destroy")), 0)

    def test_rejects_an_attempt_that_does_not_match_plan_id(self) -> None:
        arguments = self.arguments(plan_id="202-2")
        with self.assertRaisesRegex(PlanRunError, "attempt"):
            self.check_with_record(self.run_record(), arguments=arguments)

    def test_rejects_a_plan_run_that_is_not_completed_successfully(self) -> None:
        record = self.run_record(status="in_progress", conclusion=None)
        with self.assertRaisesRegex(PlanRunError, "completed successfully"):
            self.check_with_record(record)

    def test_github_api_failure_fails_closed(self) -> None:
        with patch("verify_plan_run.urlopen", side_effect=URLError("offline")):
            with self.assertRaisesRegex(PlanRunError, "refusing to download"):
                check_plan_run(self.arguments())


if __name__ == "__main__":
    unittest.main()
