#!/usr/bin/env bash
# Fail closed unless the existing plan/state bucket is private and owned by the expected account.
set -euo pipefail

PLAN_BUCKET="auto-shop-tfstate-035611741563-use1"
EXPECTED_AWS_ACCOUNT_ID="035611741563"
AWS_REGION="${AWS_REGION:-}"

if [[ "$AWS_REGION" != "us-east-1" ]]; then
  echo "Plan storage is restricted to us-east-1; set AWS_REGION explicitly." >&2
  exit 2
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$account_id" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
  echo "Plan storage expected AWS account $EXPECTED_AWS_ACCOUNT_ID, received $account_id." >&2
  exit 1
fi

bucket_region="$(aws s3api get-bucket-location \
  --bucket "$PLAN_BUCKET" \
  --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
  --query LocationConstraint \
  --output text)"
if [[ "$bucket_region" == "None" || -z "$bucket_region" ]]; then
  bucket_region="us-east-1"
fi
if [[ "$bucket_region" != "$AWS_REGION" ]]; then
  echo "Plan bucket is in $bucket_region, expected $AWS_REGION." >&2
  exit 1
fi

public_access_block="$(aws s3api get-public-access-block \
  --bucket "$PLAN_BUCKET" \
  --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
  --query PublicAccessBlockConfiguration \
  --output json)"
if ! jq -e '
  .BlockPublicAcls == true and
  .IgnorePublicAcls == true and
  .BlockPublicPolicy == true and
  .RestrictPublicBuckets == true
' <<< "$public_access_block" >/dev/null; then
  echo "The plan bucket must enable all four S3 Block Public Access settings." >&2
  exit 1
fi

ownership_controls="$(aws s3api get-bucket-ownership-controls \
  --bucket "$PLAN_BUCKET" \
  --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
  --query OwnershipControls.Rules \
  --output json)"
if ! jq -e 'any(.[]?; .ObjectOwnership == "BucketOwnerEnforced")' <<< "$ownership_controls" >/dev/null; then
  echo "The plan bucket must use BucketOwnerEnforced object ownership." >&2
  exit 1
fi

echo "Plan bucket account, region, Block Public Access, and ownership controls are valid."
