#!/usr/bin/env bash
# shellcheck disable=SC2016
# Runs terraform plan for one stack and prints a Markdown summary with addresses and actions only.
# Attribute values are never printed, so plans cannot leak data into logs or the job summary.
set -euo pipefail

STACK_DIR="$1"
PLAN_FILE="$(mktemp)"
PLAN_JSON="$(mktemp)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'rm -f "$PLAN_FILE" "$PLAN_JSON"' EXIT

terraform -chdir="$STACK_DIR" init -input=false >/dev/null
terraform -chdir="$STACK_DIR" plan -input=false -lock-timeout=120s -out="$PLAN_FILE" >/dev/null
terraform -chdir="$STACK_DIR" show -json "$PLAN_FILE" >"$PLAN_JSON"

echo "### $(basename "$STACK_DIR")"
jq -r '
  [.resource_changes[]? | select(.change.actions != ["no-op"])] as $changes
  | "Changes: \($changes | length)",
    "",
    ($changes[] | "- `\(.change.actions | join("/"))` \(.address)")
'
if [[ "$(basename "$STACK_DIR")" == "foundation" ]]; then
  bash "$SCRIPT_DIR/validate-eks-endpoint-plan.sh" "$PLAN_JSON"
fi
echo
