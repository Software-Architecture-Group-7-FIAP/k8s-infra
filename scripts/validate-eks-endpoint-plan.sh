#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 || ! -f "$1" ]]; then
  echo "Usage: $0 <terraform-plan-json> [--allow-cluster-absent]" >&2
  exit 2
fi

allow_cluster_absent=false
if [[ "$#" -eq 2 ]]; then
  [[ "$2" == "--allow-cluster-absent" ]] || {
    echo "Unsupported endpoint-plan option: $2" >&2
    exit 2
  }
  allow_cluster_absent=true
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

if ! jq -e --argjson expected "$normalized_expected" --argjson allow_absent "$allow_cluster_absent" '
  def module_resources:
    (.resources[]?),
    (.child_modules[]? | module_resources);
  [.planned_values.root_module | module_resources
    | select(.type == "aws_eks_cluster")
    | .values] as $clusters
  | if ($clusters | length) == 0 then $allow_absent
    elif ($clusters | length) != 1 then false
    elif (($clusters[0].vpc_config | type) != "array" or ($clusters[0].vpc_config | length) != 1) then false
    else $clusters[0].vpc_config[0] as $vpc
      | $vpc.endpoint_public_access == true
        and $vpc.endpoint_private_access == true
        and (($vpc.public_access_cidrs // [] | sort) == $expected)
    end
' "$1" >/dev/null; then
  echo "Terraform plan must keep one EKS cluster with public and private access enabled and the exact restricted IPv4 administrator allowlist; only NAT shutdown may run after the cluster has been destroyed." >&2
  exit 1
fi

if jq -e '.planned_values.root_module | [.. | objects | select(.type? == "aws_eks_cluster")] | length == 0' "$1" >/dev/null; then
  echo "EKS cluster is already absent; the caller must still enforce NAT-only plan scope."
  exit 0
fi

cidr_count="$(jq -r 'length' <<<"$normalized_expected")"
echo "EKS endpoint plan verified: public and private access enabled; $cidr_count restricted IPv4 administrator CIDR(s)."
