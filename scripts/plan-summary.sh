#!/usr/bin/env bash
# Prints resource addresses and actions from an already-saved plan, never attribute values.
set -euo pipefail

PLAN_FILE="${1:?usage: plan-summary.sh PLAN_FILE STACK_NAME}"
STACK_NAME="${2:?usage: plan-summary.sh PLAN_FILE STACK_NAME}"

case "$STACK_NAME" in
  foundation|platform) ;;
  *) echo "Unsupported stack: $STACK_NAME" >&2; exit 2 ;;
esac

if [ ! -f "$PLAN_FILE" ]; then
  echo "Saved plan file does not exist." >&2
  exit 2
fi

echo "### $STACK_NAME"
terraform show -json "$PLAN_FILE" | jq -r '
  [.resource_changes[]? | select(.change.actions != ["no-op"])] as $changes
  | "Changes: \($changes | length)",
    "",
    ($changes[] | "- `\(.change.actions | join("/"))` \(.address)")
'
echo
