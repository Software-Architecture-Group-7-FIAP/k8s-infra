#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 <terraform-plan-json>" >&2
  exit 2
fi

expected_cidrs="${TF_VAR_cluster_endpoint_public_access_cidrs:-}"
python_bin="${PYTHON_BIN:-python3}"
if [[ -z "$expected_cidrs" ]]; then
  echo "TF_VAR_cluster_endpoint_public_access_cidrs must be a JSON list." >&2
  exit 2
fi

normalized_expected="$("$python_bin" - "$expected_cidrs" <<'PY'
import ipaddress
import json
import sys

try:
    cidrs = json.loads(sys.argv[1])
    if not isinstance(cidrs, list) or not cidrs:
        raise ValueError("administrator CIDRs must be a non-empty JSON list")
    networks = [ipaddress.ip_network(cidr, strict=True) for cidr in cidrs]
    if any(network.version != 4 or network.prefixlen == 0 for network in networks):
        raise ValueError("only restricted IPv4 administrator CIDRs are allowed")
    if len({network.with_prefixlen for network in networks}) != len(networks):
        raise ValueError("administrator CIDRs must be unique")
except (ValueError, TypeError, json.JSONDecodeError) as exc:
    print(f"Invalid administrator CIDRs: {exc}", file=sys.stderr)
    sys.exit(2)

print(json.dumps(sorted(network.with_prefixlen for network in networks), separators=(",", ":")))
PY
)"

if ! jq -e --argjson expected "$normalized_expected" '
  def module_resources:
    (.resources[]?),
    (.child_modules[]? | module_resources);
  [.planned_values.root_module | module_resources
    | select(.type == "aws_eks_cluster")
    | .values] as $clusters
  | if ($clusters | length) != 1 then false
    elif (($clusters[0].vpc_config | type) != "array" or ($clusters[0].vpc_config | length) != 1) then false
    else $clusters[0].vpc_config[0] as $vpc
      | $vpc.endpoint_public_access == true
        and $vpc.endpoint_private_access == true
        and (($vpc.public_access_cidrs // [] | sort) == $expected)
    end
' "$1" >/dev/null; then
  echo "Terraform plan must keep one EKS cluster with public and private access enabled and the exact restricted IPv4 administrator allowlist." >&2
  exit 1
fi

cidr_count="$(jq -r 'length' <<<"$normalized_expected")"
echo "EKS endpoint plan verified: public and private access enabled; $cidr_count restricted IPv4 administrator CIDR(s)."
