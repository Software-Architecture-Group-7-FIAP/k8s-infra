#!/usr/bin/env bash
set -euo pipefail

target_stack="${1:?Usage: assert_roots_empty_before_destroy.sh <platform|foundation> }"

case "$target_stack" in
  platform)
    stacks=(hml production)
    ;;
  foundation)
    stacks=(hml production platform)
    ;;
  *)
    echo "::error::Unsupported shared stack destroy target '$target_stack'."
    exit 2
    ;;
esac

for stack in "${stacks[@]}"; do
  case "$stack" in
    hml)
      root="envs/hml"
      state_key="k8s-infra/hml/terraform.tfstate"
      ;;
    production)
      root="envs/production"
      state_key="k8s-infra/production/terraform.tfstate"
      ;;
    platform)
      root="envs/staging/platform"
      state_key="k8s-infra/staging/platform.tfstate"
      ;;
  esac

  present_key="$(aws s3api list-objects-v2 \
    --bucket "$PLAN_BUCKET" \
    --prefix "$state_key" \
    --region "$REQUESTED_AWS_REGION" \
    --expected-bucket-owner "$EXPECTED_AWS_ACCOUNT_ID" \
    --query "Contents[?Key == '$state_key'].Key | [0]" \
    --output text)"

  if [[ "$present_key" == "None" || -z "$present_key" ]]; then
    continue
  fi

  terraform -chdir="$root" init -input=false -lockfile=readonly
  state_addresses="$(terraform -chdir="$root" state list -lock=false)"
  managed_addresses=()
  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    case "$address" in
      data.*|*.data.*) ;;
      *) managed_addresses+=("$address") ;;
    esac
  done <<< "$state_addresses"

  if (( ${#managed_addresses[@]} > 0 )); then
    echo "::error::Cannot destroy $target_stack while $stack owns managed resources. Destroy $stack first."
    printf '%s\n' "${managed_addresses[@]}" >&2
    exit 1
  fi
done
