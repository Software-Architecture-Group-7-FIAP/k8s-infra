#!/usr/bin/env bash
# Optional preflight helper; orphan-audit.yml performs the read-only AWS inventory itself.
set -euo pipefail

if [[ "${ENVIRONMENT_SCHEDULE_ENABLED:-false}" != "true" ]]; then
  echo "Lifecycle automation is disabled; no orphan audit was requested."
  exit 0
fi

session_mode="${REQUESTED_SESSION_MODE:-}"
session_id="${REQUESTED_SESSION_ID:-}"
started_at="${REQUESTED_STARTED_AT:-}"
python3 scripts/validate_staging_session.py \
  --session-id "$session_id" \
  --started-at "$started_at" \
  --mode "$session_mode" \
  --operation audit

echo "Orphan-audit preflight passed for $session_mode."
echo "Preflight passed; use orphan-audit.yml for the credentialed read-only inventory."
