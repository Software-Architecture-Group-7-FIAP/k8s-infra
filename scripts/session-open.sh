#!/usr/bin/env bash
# Validates an explicit session context. This preflight never calls AWS or Terraform.
set -euo pipefail

session_mode="${REQUESTED_SESSION_MODE:-}"
session_id="${REQUESTED_SESSION_ID:-}"
started_at="${REQUESTED_STARTED_AT:-}"
authorized_mode="${AUTHORIZED_SESSION_MODE:-}"

if [[ "$session_mode" != "$authorized_mode" ]]; then
  echo "::error::The requested session mode does not match the protected Environment authorization."
  exit 1
fi

if [[ "$session_mode" == "prd-window" ]]; then
  if [[ "${ENVIRONMENT_SCHEDULE_ENABLED:-false}" != "true" || \
    "${PRD_LIFECYCLE_AUTOMATION_READY:-false}" != "true" || \
    "${PRD_COST_EXCEPTION_APPROVED:-false}" != "true" ]]; then
    echo "::error::PRD opening requires schedule, automation-readiness, and cost-exception gates."
    exit 1
  fi
elif [[ "$session_mode" != "hml" ]]; then
  echo "::error::The session mode must be hml or prd-window."
  exit 1
fi

python3 scripts/validate_staging_session.py \
  --session-id "$session_id" \
  --started-at "$started_at" \
  --mode "$session_mode" \
  --operation work \
  --minimum-remaining-seconds 3600

echo "Session-open preflight passed for $session_mode."
echo "No AWS or Terraform action is implemented in this disabled-by-default coordinator."
