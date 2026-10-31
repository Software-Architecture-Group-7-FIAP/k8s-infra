#!/usr/bin/env bash
set -euo pipefail

cluster_name="${EKS_CLUSTER_NAME:-auto-shop-staging}"
python_bin="${PYTHON_BIN:-python3}"
mode="${1:-}"

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 {add-runner|restore-admin|runner-allowed|private-runner-allowed}" >&2
  exit 2
fi

get_runner_ip() {
  curl --fail --silent --show-error --ipv4 https://checkip.amazonaws.com | tr -d '\r\n'
}

if [[ "$mode" == "runner-allowed" ]]; then
  runner_ip="$(get_runner_ip)"
  current_cidrs="$(aws eks describe-cluster --name "$cluster_name" --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output json)"
  "$python_bin" - "$runner_ip" "$current_cidrs" <<'PY'
import ipaddress
import json
import sys

try:
    runner_ip = ipaddress.ip_address(sys.argv[1])
    cidrs = json.loads(sys.argv[2])
    networks = [ipaddress.ip_network(cidr, strict=False) for cidr in cidrs]
except (ValueError, TypeError, json.JSONDecodeError) as exc:
    print(f"Invalid EKS endpoint allowlist response: {exc}", file=sys.stderr)
    sys.exit(2)

if any(runner_ip in network for network in networks):
    sys.exit(0)
sys.exit(10)
PY
  exit
fi

if [[ "$mode" == "private-runner-allowed" ]]; then
  cluster_json="$(aws eks describe-cluster --name "$cluster_name" --output json)"
  if ! jq -e '.cluster.resourcesVpcConfig.endpointPrivateAccess == true' <<<"$cluster_json" >/dev/null; then
    echo "The EKS cluster must have private endpoint access enabled for the VPC runner." >&2
    exit 1
  fi
  endpoint_host="$(jq -r '.cluster.endpoint | sub("^https://"; "") | split("/")[0]' <<<"$cluster_json")"
  if [[ -z "$endpoint_host" || "$endpoint_host" == "null" ]]; then
    echo "The EKS cluster endpoint is missing." >&2
    exit 1
  fi
  "$python_bin" - "$endpoint_host" <<'PY'
import ipaddress
import socket
import sys

host = sys.argv[1]
try:
    addresses = sorted({
        ipaddress.ip_address(result[4][0])
        for result in socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
    })
    if not addresses or any(not address.is_private for address in addresses):
        raise ValueError("the cluster endpoint did not resolve exclusively to private IPv4 addresses")
    connected = False
    for address in addresses:
        try:
            with socket.create_connection((str(address), 443), timeout=5):
                connected = True
                break
        except OSError:
            continue
    if not connected:
        raise OSError("TCP/443 to the private cluster endpoint is unreachable")
except (OSError, ValueError) as exc:
    print(f"Private EKS endpoint connectivity check failed: {exc}", file=sys.stderr)
    sys.exit(1)

print("Private EKS endpoint resolved to a VPC address and accepted TCP/443.")
PY
  exit
fi

if [[ "$mode" != "add-runner" && "$mode" != "restore-admin" ]]; then
  echo "Unknown mode: $mode" >&2
  exit 2
fi

admin_cidrs="${EKS_CLUSTER_ENDPOINT_ADMIN_CIDRS:-}"
if [[ -z "$admin_cidrs" ]]; then
  echo "EKS_CLUSTER_ENDPOINT_ADMIN_CIDRS must contain a JSON list of administrator CIDRs." >&2
  exit 2
fi

runner_ip=""
if [[ "$mode" == "add-runner" ]]; then
  runner_ip="$(get_runner_ip)"
fi

target_cidrs="$("$python_bin" - "$admin_cidrs" "$runner_ip" <<'PY'
import ipaddress
import json
import sys

try:
    admins = json.loads(sys.argv[1])
    runner = sys.argv[2]
    if not isinstance(admins, list) or not admins:
        raise ValueError("administrator CIDRs must be a non-empty JSON list")
    networks = [ipaddress.ip_network(cidr, strict=False) for cidr in admins]
    if any(network.version != 4 for network in networks):
        raise ValueError("only IPv4 administrator CIDRs are allowed for this cluster")
    if any(network.prefixlen == 0 for network in networks):
        raise ValueError("unrestricted IPv4 CIDRs are not allowed")
    cidrs = {network.with_prefixlen for network in networks}
    if runner:
        cidrs.add(f"{ipaddress.ip_address(runner)}/32")
except (ValueError, TypeError, json.JSONDecodeError) as exc:
    print(f"Invalid administrator CIDRs: {exc}", file=sys.stderr)
    sys.exit(2)

print(json.dumps(sorted(cidrs), separators=(",", ":")))
PY
)"

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
if ! cluster_json="$(aws eks describe-cluster --name "$cluster_name" --output json 2>"$err_file")"; then
  if grep -q "ResourceNotFoundException" "$err_file" && [[ "$mode" == "restore-admin" ]]; then
    echo "Cluster $cluster_name does not exist; endpoint restore is not needed."
    exit 0
  fi
  cat "$err_file" >&2
  exit 1
fi

cluster_status="$(jq -r '.cluster.status' <<<"$cluster_json")"
if [[ "$cluster_status" != "ACTIVE" ]]; then
  for ((attempt = 1; attempt <= 90; attempt++)); do
    cluster_status="$(aws eks describe-cluster --name "$cluster_name" --query 'cluster.status' --output text)"
    [[ "$cluster_status" == "ACTIVE" ]] && break
    [[ "$cluster_status" == "FAILED" ]] && { echo "Cluster $cluster_name is in FAILED status." >&2; exit 1; }
    sleep 10
  done
  if [[ "$cluster_status" != "ACTIVE" ]]; then
    echo "Timed out waiting for cluster $cluster_name to become ACTIVE." >&2
    exit 1
  fi
fi

current_cidrs="$(jq -c '.cluster.resourcesVpcConfig.publicAccessCidrs | sort' <<<"$cluster_json")"
target_cidrs="$(jq -c 'sort' <<<"$target_cidrs")"
if [[ "$current_cidrs" == "$target_cidrs" ]]; then
  echo "EKS endpoint CIDRs already match the requested allowlist."
  exit 0
fi

resources_vpc_config="$(jq -cn --argjson cidrs "$target_cidrs" '{endpointPublicAccess:true,endpointPrivateAccess:true,publicAccessCidrs:$cidrs}')"
update_id="$(aws eks update-cluster-config --name "$cluster_name" --resources-vpc-config "$resources_vpc_config" --query 'update.id' --output text)"

for ((attempt = 1; attempt <= 60; attempt++)); do
  update_status="$(aws eks describe-update --name "$cluster_name" --update-id "$update_id" --query 'update.status' --output text)"
  case "$update_status" in
    Successful)
      verified=false
      for ((verify_attempt = 1; verify_attempt <= 6; verify_attempt++)); do
        if verified_cluster_json="$(aws eks describe-cluster --name "$cluster_name" --output json 2>"$err_file")"; then
          verified_cidrs="$(jq -c '.cluster.resourcesVpcConfig.publicAccessCidrs | sort' <<<"$verified_cluster_json")"
          if [[ "$verified_cidrs" == "$target_cidrs" ]] && jq -e '
            .cluster.resourcesVpcConfig.endpointPublicAccess == true and
            .cluster.resourcesVpcConfig.endpointPrivateAccess == true
          ' <<<"$verified_cluster_json" >/dev/null; then
            verified=true
            break
          fi
        fi
        sleep 5
      done
      if [[ "$verified" != true ]]; then
        echo "EKS endpoint update completed but the requested allowlist could not be verified." >&2
        exit 1
      fi
      echo "EKS endpoint allowlist updated and verified."
      exit 0
      ;;
    Failed|Cancelled)
      aws eks describe-update --name "$cluster_name" --update-id "$update_id" --query 'update.errors' --output json >&2
      exit 1
      ;;
  esac
  sleep 10
done

echo "Timed out waiting for EKS endpoint update $update_id." >&2
exit 1
