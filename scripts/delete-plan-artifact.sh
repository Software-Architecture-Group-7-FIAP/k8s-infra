#!/usr/bin/env bash
# Permanently removes only the exact saved-plan objects after a successful apply/destroy.
set -euo pipefail

PLAN_ID="${1:?usage: delete-plan-artifact.sh PLAN_ID PURPOSE STACK}"
PURPOSE="${2:?usage: delete-plan-artifact.sh PLAN_ID PURPOSE STACK}"
STACK="${3:?usage: delete-plan-artifact.sh PLAN_ID PURPOSE STACK}"
PLAN_BUCKET="auto-shop-tfstate-035611741563-use1"
EXPECTED_AWS_ACCOUNT_ID="035611741563"
PLAN_BASE_KEY="k8s-infra/staging/plans/$PLAN_ID/$PURPOSE"
AWS_REGION="${AWS_REGION:-}"

if [[ ! "$PLAN_ID" =~ ^[0-9]+-[0-9]+$ ]]; then
  echo "Invalid plan ID." >&2
  exit 2
fi
case "$PURPOSE" in
  apply|destroy) ;;
  *) echo "Invalid plan purpose." >&2; exit 2 ;;
esac
case "$STACK" in
  foundation|platform) ;;
  *) echo "Invalid stack." >&2; exit 2 ;;
esac
if [[ "$AWS_REGION" != "us-east-1" ]]; then
  echo "Cleanup is restricted to us-east-1; set AWS_REGION explicitly." >&2
  exit 2
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$account_id" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
  echo "Cleanup expected AWS account $EXPECTED_AWS_ACCOUNT_ID, received $account_id." >&2
  exit 1
fi

delete_exact_object_version() {
  local key="$1"
  local version_id

  version_id="$(aws s3api head-object \
    --bucket "$PLAN_BUCKET" \
    --key "$key" \
    --region "$AWS_REGION" \
    --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
    --query VersionId \
    --output text)"

  if [[ -n "$version_id" && "$version_id" != "None" ]]; then
    aws s3api delete-object \
      --bucket "$PLAN_BUCKET" \
      --key "$key" \
      --version-id "$version_id" \
      --region "$AWS_REGION" \
      --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
      --no-cli-pager >/dev/null
  else
    aws s3api delete-object \
      --bucket "$PLAN_BUCKET" \
      --key "$key" \
      --region "$AWS_REGION" \
      --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
      --no-cli-pager >/dev/null
  fi
}

delete_exact_object_version "$PLAN_BASE_KEY/$STACK.tfplan"
delete_exact_object_version "$PLAN_BASE_KEY/manifest.json"
echo "Removed the consumed saved-plan objects from the private S3 prefix."
