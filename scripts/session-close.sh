#!/usr/bin/env bash
# Validates the bounded teardown context. No AWS calls.
set -euo pipefail

session_mode="${REQUESTED_SESSION_MODE:-}"
session_id="${REQUESTED_SESSION_ID:-}"
started_at="${REQUESTED_STARTED_AT:-}"
if [[ -n "${STAGING_SESSION_TOKEN:-}" ]]; then
  echo "::add-mask::${STAGING_SESSION_TOKEN}"
fi

python3 scripts/validate_staging_session.py \
  --session-id "$session_id" \
  --started-at "$started_at" \
  --mode "$session_mode" \
  --operation teardown

echo "Session-close preflight passed for $session_mode."
echo "Use destroy.yml to create, review, and apply each exact saved destroy plan."
