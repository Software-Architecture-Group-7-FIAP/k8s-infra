#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
fake_bin="$temporary_dir"
trap 'rm -rf "$temporary_dir"' EXIT

cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
printf '203.0.113.45\n'
SH

cat >"$fake_bin/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_AWS_LOG"

case " $* " in
  *" describe-cluster "*)
    current_cidrs="$(cat "$FAKE_CURRENT_CIDRS_FILE")"
    if [[ "$*" == *"publicAccessCidrs"* ]]; then
      printf '%s\n' "$current_cidrs"
    else
      printf '{"cluster":{"status":"ACTIVE","resourcesVpcConfig":{"endpointPublicAccess":true,"endpointPrivateAccess":true,"publicAccessCidrs":%s}}}\n' "$current_cidrs"
    fi
    ;;
  *" update-cluster-config "*)
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--resources-vpc-config" ]]; then
        printf '%s\n' "$2" >"$FAKE_UPDATE_JSON"
        jq -c '.publicAccessCidrs' "$FAKE_UPDATE_JSON" >"$FAKE_CURRENT_CIDRS_FILE"
        break
      fi
      shift
    done
    printf 'update-123\n'
    ;;
  *" describe-update "*)
    printf 'Successful\n'
    ;;
  *)
    echo "Unexpected fake AWS command: $*" >&2
    exit 99
    ;;
esac
SH

chmod +x "$fake_bin/aws" "$fake_bin/curl"
export PATH="$fake_bin:$PATH"
export FAKE_AWS_LOG="$temporary_dir/aws.log"
export FAKE_UPDATE_JSON="$temporary_dir/update.json"
export FAKE_CURRENT_CIDRS_FILE="$temporary_dir/current-cidrs.json"
touch "$FAKE_AWS_LOG"

fail() {
  echo "$1" >&2
  exit 1
}

assert_update_cidrs() {
  local expected="$1"
  local actual
  actual="$(jq -c '.publicAccessCidrs | sort' "$FAKE_UPDATE_JSON")"
  [[ "$actual" == "$expected" ]] || fail "Expected endpoint CIDRs $expected; got $actual"
  jq -e '.endpointPublicAccess == true and .endpointPrivateAccess == true' "$FAKE_UPDATE_JSON" >/dev/null \
    || fail "Endpoint update must keep public and private access enabled"
}

export EKS_CLUSTER_ENDPOINT_ADMIN_CIDRS='["198.51.100.8/32"]'
printf '["198.51.100.8/32"]\n' >"$FAKE_CURRENT_CIDRS_FILE"
bash "$repo_root/scripts/eks-endpoint-access.sh" add-runner >/dev/null
assert_update_cidrs '["198.51.100.8/32","203.0.113.45/32"]'

bash "$repo_root/scripts/eks-endpoint-access.sh" restore-admin >/dev/null
assert_update_cidrs '["198.51.100.8/32"]'

printf '["203.0.113.0/24"]\n' >"$FAKE_CURRENT_CIDRS_FILE"
bash "$repo_root/scripts/eks-endpoint-access.sh" runner-allowed >/dev/null \
  || fail "Runner inside an allowed CIDR should be accepted"

printf '["198.51.100.8/32"]\n' >"$FAKE_CURRENT_CIDRS_FILE"
set +e
bash "$repo_root/scripts/eks-endpoint-access.sh" runner-allowed >/dev/null 2>&1
runner_status=$?
set -e
[[ "$runner_status" -eq 10 ]] || fail "Runner outside the allowlist should return status 10"

for invalid_cidrs in '["198.51.100.8/0"]' '["0.0.0.0/0"]' '["2001:db8::/64"]' '[]' 'not-json'; do
  : >"$FAKE_AWS_LOG"
  export EKS_CLUSTER_ENDPOINT_ADMIN_CIDRS="$invalid_cidrs"
  if bash "$repo_root/scripts/eks-endpoint-access.sh" restore-admin >/dev/null 2>&1; then
    fail "Invalid administrator CIDRs should be rejected: $invalid_cidrs"
  fi
  [[ ! -s "$FAKE_AWS_LOG" ]] || fail "Invalid CIDRs must be rejected before calling AWS"
done

echo "EKS endpoint access contract tests passed."
