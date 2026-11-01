import argparse
import os
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


MAX_SESSION_DURATION = timedelta(hours=5)
CLEANUP_GRACE_DURATION = timedelta(hours=1)
CLEANUP_AUDIT_RESERVE = timedelta(minutes=15)
TEARDOWN_SAFETY_MARGIN = timedelta(minutes=5)
PRD_TIMEZONE = ZoneInfo("America/Sao_Paulo")
PRD_FIRST_DATE = date(2026, 11, 1)
PRD_LAST_DATE = date(2026, 11, 5)
PRD_START_TIME = time(6, 0)
PRD_WORK_END_TIME = time(22, 0)
PRD_CLEANUP_END_TIME = time(23, 0)
HML_EARLIEST_START = time(7, 0)
HML_LATEST_START = time(17, 0)
HML_LAST_DATE = date(2026, 11, 5)
HML_WORK_END_TIME = time(22, 0)
STARTED_AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
class StagingSessionError(ValueError):
    """Raised when a staging session is missing, unauthorized, or expired."""


def _parse_started_at(value: str) -> datetime:
    if not value:
        raise StagingSessionError("STAGING_SESSION_STARTED_AT is required.")

    try:
        parsed = datetime.strptime(value, STARTED_AT_FORMAT)
    except ValueError as error:
        raise StagingSessionError(
            "STAGING_SESSION_STARTED_AT must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        ) from error

    if parsed.strftime(STARTED_AT_FORMAT) != value:
        raise StagingSessionError(
            "STAGING_SESSION_STARTED_AT must use UTC format YYYY-MM-DDTHH:MM:SSZ."
        )

    return parsed.replace(tzinfo=timezone.utc)


def validate_staging_session(
    *,
    active: str,
    authorized: str,
    session_id: str,
    started_at: str,
    now: datetime,
    minimum_remaining_seconds: int = 0,
    mode: str = "hml",
    operation: str = "work",
) -> timedelta:
    if mode not in {"hml", "prd-window"}:
        raise StagingSessionError("The session mode must be hml or prd-window.")
    if operation not in {"work", "teardown", "audit"}:
        raise StagingSessionError("The operation must be work, teardown, or audit.")
    if operation == "work" and active != "true":
        raise StagingSessionError("STAGING_ACTIVE must be true.")
    if operation == "work" and authorized != "true":
        raise StagingSessionError("STAGING_SESSION_AUTHORIZED must be true for work.")
    if not session_id.strip():
        raise StagingSessionError("STAGING_SESSION_ID is required.")
    if (
        isinstance(minimum_remaining_seconds, bool)
        or not isinstance(minimum_remaining_seconds, int)
        or minimum_remaining_seconds < 0
    ):
        raise StagingSessionError("The minimum remaining time must be a non-negative integer.")
    if now.tzinfo is None or now.utcoffset() != timedelta(0):
        raise StagingSessionError("The current time must be UTC-aware.")

    start = _parse_started_at(started_at)
    elapsed = now - start
    if elapsed < timedelta(0):
        raise StagingSessionError("STAGING_SESSION_STARTED_AT is in the future.")

    local_now = now.astimezone(PRD_TIMEZONE)
    local_start = start.astimezone(PRD_TIMEZONE)
    if mode == "hml" and local_now.date() > HML_LAST_DATE:
        raise StagingSessionError("HML lifecycle actions are disabled after 05 November 2026 BRT.")

    expected_session_prefix = "hml" if mode == "hml" else "prd"
    expected_session_id = f"{expected_session_prefix}-{local_start.date().isoformat()}"
    if session_id != expected_session_id:
        raise StagingSessionError(
            f"session_id must be {expected_session_id} for the supplied mode and start date."
        )

    provisioning_mode = os.environ.get("HML_PROVISIONING_MODE", "").lower() == "true"

    if mode == "hml":
        if local_start.date() != local_now.date():
            raise StagingSessionError("An HML session must start on the current BRT day.")
        hml_start_time = local_start.time().replace(tzinfo=None)
        allow_any_time = os.environ.get("STAGING_SESSION_ALLOW_ANY_TIME", "").lower() == "true"
        if not allow_any_time and not provisioning_mode and not HML_EARLIEST_START <= hml_start_time <= HML_LATEST_START:
            raise StagingSessionError(
                "HML sessions must start between 07:00 and 17:00 America/Sao_Paulo."
            )
        hml_day_end = datetime.combine(
            local_start.date(), HML_WORK_END_TIME, tzinfo=PRD_TIMEZONE
        ).astimezone(timezone.utc)
        session_end = min(start + MAX_SESSION_DURATION, hml_day_end)
        cleanup_end = datetime.combine(
            local_start.date(), PRD_CLEANUP_END_TIME, tzinfo=PRD_TIMEZONE
        ).astimezone(timezone.utc)
    else:
        if not PRD_FIRST_DATE <= local_start.date() <= PRD_LAST_DATE:
            raise StagingSessionError(
                "PRD windows are allowed only from 01 through 05 November 2026."
            )
        if local_start.time().replace(tzinfo=None) != PRD_START_TIME:
            raise StagingSessionError(
                "PRD STAGING_SESSION_STARTED_AT must be exactly 06:00 America/Sao_Paulo."
            )
        if local_start.date() != local_now.date():
            raise StagingSessionError("The PRD session must start on the current BRT day.")
        session_end = min(
            start + MAX_SESSION_DURATION,
            datetime.combine(
                local_start.date(), PRD_WORK_END_TIME, tzinfo=PRD_TIMEZONE
            ).astimezone(timezone.utc),
        )
        cleanup_end = datetime.combine(
            local_start.date(), PRD_CLEANUP_END_TIME, tzinfo=PRD_TIMEZONE
        ).astimezone(timezone.utc)

    audit_start = cleanup_end - CLEANUP_AUDIT_RESERVE
    teardown_end = audit_start - TEARDOWN_SAFETY_MARGIN
    if operation == "teardown":
        if now < start:
            raise StagingSessionError("Teardown cannot start before the authorized session begins.")
        if now >= teardown_end:
            raise StagingSessionError("Teardown must stop 20 minutes before the cleanup deadline to reserve the audit window.")
        remaining = teardown_end - now
    elif operation == "audit":
        if now < audit_start:
            raise StagingSessionError("The read-only audit window opens 15 minutes before the cleanup deadline.")
        if now >= cleanup_end:
            raise StagingSessionError("The cleanup window ends at 23:00 America/Sao_Paulo.")
        remaining = cleanup_end - now
    else:
        if now >= session_end and not provisioning_mode:
            if mode == "hml":
                raise StagingSessionError(
                    "The HML session ended at the earlier of five hours or 22:00 BRT."
                )
            raise StagingSessionError("The PRD session ended at its five-hour limit or 22:00 BRT work cutoff.")
        remaining = session_end - now if session_end > now else timedelta(hours=24)
    if remaining < timedelta(seconds=minimum_remaining_seconds) and not provisioning_mode:
        boundary = "session" if operation == "work" else "authorized lifecycle"
        raise StagingSessionError(f"There is not enough remaining {boundary} time for this job.")

    return remaining


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an authorized staging session.")
    parser.add_argument("--minimum-remaining-seconds", type=int, default=0)
    parser.add_argument("--mode", choices=("hml", "prd-window"))
    parser.add_argument("--session-id")
    parser.add_argument("--started-at")
    parser.add_argument("--operation", choices=("work", "teardown", "audit"), default="work")
    parser.add_argument(
        "--github-output",
        help="Append the resolved session identity to a GitHub Actions output file.",
    )
    arguments = parser.parse_args()

    now = datetime.now(timezone.utc)
    mode = arguments.mode or os.environ.get("STAGING_SESSION_MODE", "")
    session_id = arguments.session_id or os.environ.get("STAGING_SESSION_ID", "")
    started_at = arguments.started_at or os.environ.get("STAGING_SESSION_STARTED_AT", "")

    try:
        remaining = validate_staging_session(
            active=os.environ.get("STAGING_ACTIVE", ""),
            authorized=os.environ.get("STAGING_SESSION_AUTHORIZED", ""),
            session_id=session_id,
            started_at=started_at,
            now=now,
            minimum_remaining_seconds=arguments.minimum_remaining_seconds,
            mode=mode,
            operation=arguments.operation,
        )
    except StagingSessionError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    if arguments.github_output:
        with open(arguments.github_output, "a", encoding="utf-8") as output_file:
            output_file.write(f"session_id={session_id}\n")
            output_file.write(f"started_at={started_at}\n")
            output_file.write(f"mode={mode}\n")
    print(f"Staging session {session_id} is valid; {int(remaining.total_seconds())} seconds remain.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
