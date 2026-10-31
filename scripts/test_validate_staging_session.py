import unittest
from datetime import datetime, timezone

from validate_staging_session import (
    StagingSessionError,
    validate_staging_session,
)


class ValidateStagingSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 10, 28, 12, 0, 0, tzinfo=timezone.utc)
        self.session_id = "hml-2026-10-28"
        self.started_at = "2026-10-28T10:00:00Z"  # 07:00 BRT

    def validate(self, **overrides: object):
        values = {
            "active": "true",
            "authorized": "true",
            "session_id": self.session_id,
            "started_at": self.started_at,
            "now": self.now,
        }
        values.update(overrides)
        return validate_staging_session(**values)

    def test_accepts_authorized_hml_session_within_five_hours(self) -> None:
        remaining = self.validate(minimum_remaining_seconds=3600)

        self.assertEqual(remaining.total_seconds(), 3 * 60 * 60)

    def test_hml_lifecycle_window_matches_the_approved_spend_end_date(self) -> None:
        remaining = self.validate(
            session_id="hml-2026-11-05",
            started_at="2026-11-05T10:00:00Z",  # 07:00 BRT
            now=datetime(2026, 11, 5, 11, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(remaining.total_seconds(), 4 * 60 * 60)
        with self.assertRaisesRegex(StagingSessionError, "after 05 November 2026 BRT"):
            self.validate(
                session_id="hml-2026-11-06",
                started_at="2026-11-06T10:00:00Z",
                now=datetime(2026, 11, 6, 11, 0, tzinfo=timezone.utc),
            )

    def test_rejects_inactive_session_for_work(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "STAGING_ACTIVE"):
            self.validate(active="false")

    def test_rejects_unauthorized_work(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "STAGING_SESSION_AUTHORIZED"):
            self.validate(authorized="false")

    def test_teardown_remains_allowed_after_opening_gate_is_revoked(self) -> None:
        remaining = self.validate(
            active="false",
            authorized="false",
            now=datetime(2026, 10, 29, 1, 30, tzinfo=timezone.utc),
            operation="teardown",
        )

        self.assertEqual(remaining.total_seconds(), 10 * 60)

    def test_rejects_missing_session_id(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "STAGING_SESSION_ID"):
            self.validate(session_id="")

    def test_rejects_session_id_for_another_day(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "session_id must be hml"):
            self.validate(session_id="hml-2026-10-27")

    def test_rejects_missing_start_time(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "STAGING_SESSION_STARTED_AT"):
            self.validate(started_at="")

    def test_rejects_malformed_or_non_utc_start_time(self) -> None:
        for started_at in (
            "2026-10-28T11:00:00+00:00",
            "2026-10-28 11:00:00Z",
            "2026-02-30T11:00:00Z",
        ):
            with self.subTest(started_at=started_at):
                with self.assertRaisesRegex(StagingSessionError, "STAGING_SESSION_STARTED_AT"):
                    self.validate(started_at=started_at)

    def test_rejects_hml_start_outside_approved_five_hour_blocks(self) -> None:
        for started_at, now in (
            ("2026-10-28T09:59:59Z", self.now),
            ("2026-10-28T20:00:01Z", datetime(2026, 10, 28, 21, 0, tzinfo=timezone.utc)),
        ):
            with self.subTest(started_at=started_at):
                with self.assertRaisesRegex(StagingSessionError, "between 07:00 and 17:00"):
                    self.validate(started_at=started_at, now=now)

    def test_rejects_future_start_time(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "future"):
            self.validate(started_at="2026-10-28T12:00:01Z")

    def test_rejects_session_at_five_hour_limit(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "session ended"):
            self.validate(now=datetime(2026, 10, 28, 15, 0, tzinfo=timezone.utc))

    def test_rejects_session_with_insufficient_time_for_job(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "remaining session time"):
            self.validate(minimum_remaining_seconds=3 * 60 * 60 + 1)

    def test_accepts_exact_minimum_remaining_time(self) -> None:
        self.validate(minimum_remaining_seconds=3 * 60 * 60)

    def test_rejects_naive_clock(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "UTC-aware"):
            self.validate(now=datetime(2026, 10, 28, 12, 0))

    def test_rejects_negative_remaining_time_requirement(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "non-negative"):
            self.validate(minimum_remaining_seconds=-1)

    def test_hml_teardown_is_allowed_only_before_its_reserved_deadline(self) -> None:
        remaining = self.validate(
            active="false",
            now=datetime(2026, 10, 29, 1, 30, tzinfo=timezone.utc),
            operation="teardown",
        )

        self.assertEqual(remaining.total_seconds(), 10 * 60)

    def test_hml_teardown_can_start_before_session_expiry(self) -> None:
        remaining = self.validate(operation="teardown")

        self.assertEqual(remaining.total_seconds(), 13 * 60 * 60 + 40 * 60)

    def test_hml_teardown_is_rejected_when_the_audit_reserve_opens(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "stop 20 minutes before"):
            self.validate(
                active="false",
                now=datetime(2026, 10, 29, 1, 40, tzinfo=timezone.utc),
                operation="teardown",
            )

    def test_normal_work_is_rejected_after_hml_expiry_even_during_cleanup_window(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "session ended"):
            self.validate(now=datetime(2026, 10, 28, 15, 30, tzinfo=timezone.utc))

    def test_prd_window_accepts_work_during_the_teacher_access_period(self) -> None:
        remaining = validate_staging_session(
            active="true",
            authorized="true",
            session_id="prd-2026-11-01",
            started_at="2026-11-01T09:00:00Z",  # 06:00 BRT
            now=datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc),  # 09:00 BRT
            mode="prd-window",
        )

        self.assertEqual(remaining.total_seconds(), 2 * 60 * 60)

    def test_prd_window_accepts_the_last_delivery_date(self) -> None:
        remaining = validate_staging_session(
            active="true",
            authorized="true",
            session_id="prd-2026-11-05",
            started_at="2026-11-05T09:00:00Z",
            now=datetime(2026, 11, 5, 9, 0, tzinfo=timezone.utc),
            mode="prd-window",
        )

        self.assertEqual(remaining.total_seconds(), 5 * 60 * 60)

    def test_prd_window_requires_exact_06_brt_start(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "exactly 06:00 America/Sao_Paulo"):
            validate_staging_session(
                active="true",
                authorized="true",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:01Z",
                now=datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc),
                mode="prd-window",
            )

    def test_prd_window_rejects_dates_before_and_after_delivery_period(self) -> None:
        for session_date in ("2026-10-31", "2026-11-06"):
            with self.subTest(session_date=session_date):
                started_at = f"{session_date}T09:00:00Z"
                day = datetime.fromisoformat(f"{session_date}T12:00:00+00:00")
                with self.assertRaisesRegex(StagingSessionError, "01 through 05 November 2026"):
                    validate_staging_session(
                        active="true",
                        authorized="true",
                        session_id=f"prd-{session_date}",
                        started_at=started_at,
                        now=day,
                        mode="prd-window",
                    )

    def test_prd_work_is_rejected_at_22_brt(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "five-hour limit"):
            validate_staging_session(
                active="true",
                authorized="true",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 2, 1, 0, tzinfo=timezone.utc),
                mode="prd-window",
            )

    def test_prd_work_is_rejected_at_the_five_hour_limit(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "five-hour limit"):
            validate_staging_session(
                active="true",
                authorized="true",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 1, 14, 0, tzinfo=timezone.utc),  # 11:00 BRT
                mode="prd-window",
            )

    def test_prd_work_respects_minimum_remaining_time(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "remaining session time"):
            validate_staging_session(
                active="true",
                authorized="true",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 1, 13, 30, tzinfo=timezone.utc),  # 10:30 BRT
                mode="prd-window",
                minimum_remaining_seconds=30 * 60 + 1,
            )

    def test_prd_teardown_reserves_the_final_twenty_minutes(self) -> None:
        remaining = validate_staging_session(
            active="false",
            authorized="true",
            session_id="prd-2026-11-01",
            started_at="2026-11-01T09:00:00Z",
            now=datetime(2026, 11, 2, 1, 30, tzinfo=timezone.utc),  # 22:30 BRT
            mode="prd-window",
            operation="teardown",
        )

        self.assertEqual(remaining.total_seconds(), 10 * 60)

    def test_prd_teardown_is_rejected_at_its_deadline(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "stop 20 minutes before"):
            validate_staging_session(
                active="false",
                authorized="true",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 2, 2, 0, 1, tzinfo=timezone.utc),
                mode="prd-window",
                operation="teardown",
            )

    def test_audit_is_allowed_only_in_the_reserved_final_fifteen_minutes(self) -> None:
        remaining = validate_staging_session(
            active="false",
            authorized="false",
            session_id="prd-2026-11-01",
            started_at="2026-11-01T09:00:00Z",
            now=datetime(2026, 11, 2, 1, 45, tzinfo=timezone.utc),  # 22:45 BRT
            mode="prd-window",
            operation="audit",
            minimum_remaining_seconds=15 * 60,
        )

        self.assertEqual(remaining.total_seconds(), 15 * 60)

    def test_audit_is_rejected_before_its_reserved_window(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "audit window opens"):
            validate_staging_session(
                active="false",
                authorized="false",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 2, 1, 44, 59, tzinfo=timezone.utc),  # 22:44:59 BRT
                mode="prd-window",
                operation="audit",
            )

    def test_audit_cannot_exceed_the_cleanup_deadline(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "cleanup window ends at 23:00"):
            validate_staging_session(
                active="false",
                authorized="false",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 2, 2, 0, 1, tzinfo=timezone.utc),
                mode="prd-window",
                operation="audit",
            )

    def test_audit_enforces_its_job_runtime_budget(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "remaining authorized lifecycle time"):
            validate_staging_session(
                active="false",
                authorized="false",
                session_id="prd-2026-11-01",
                started_at="2026-11-01T09:00:00Z",
                now=datetime(2026, 11, 2, 1, 50, 1, tzinfo=timezone.utc),  # 22:50:01 BRT
                mode="prd-window",
                operation="audit",
                minimum_remaining_seconds=10 * 60,
            )

    def test_minimum_remaining_time_is_enforced_for_teardown(self) -> None:
        with self.assertRaisesRegex(StagingSessionError, "remaining authorized lifecycle time"):
            self.validate(
                active="false",
                now=datetime(2026, 10, 29, 1, 30, tzinfo=timezone.utc),
                operation="teardown",
                minimum_remaining_seconds=10 * 60 + 1,
            )

    def test_rejects_unknown_mode_and_operation(self) -> None:
        for values, expected in (
            ({"mode": "production"}, "mode must be hml or prd-window"),
            ({"operation": "destroy"}, "operation must be work, teardown, or audit"),
        ):
            with self.subTest(values=values):
                with self.assertRaisesRegex(StagingSessionError, expected):
                    self.validate(**values)


if __name__ == "__main__":
    unittest.main()
