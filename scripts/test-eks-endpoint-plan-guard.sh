#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

export TF_VAR_cluster_endpoint_public_access_cidrs='["198.51.100.8/32"]'

cat >"$temporary_dir/valid.json" <<'JSON'
{"planned_values":{"root_module":{"child_modules":[{"address":"module.eks","resources":[{"address":"module.eks.aws_eks_cluster.this[0]","mode":"managed","type":"aws_eks_cluster","name":"this","values":{"vpc_config":[{"endpoint_public_access":true,"endpoint_private_access":true,"public_access_cidrs":["198.51.100.8/32"]}]}}]}]}}}
JSON

cat >"$temporary_dir/unrestricted.json" <<'JSON'
{"planned_values":{"root_module":{"child_modules":[{"address":"module.eks","resources":[{"address":"module.eks.aws_eks_cluster.this[0]","mode":"managed","type":"aws_eks_cluster","name":"this","values":{"vpc_config":[{"endpoint_public_access":true,"endpoint_private_access":true,"public_access_cidrs":["0.0.0.0/0"]}]}}]}]}}}
JSON

cat >"$temporary_dir/private-disabled.json" <<'JSON'
{"planned_values":{"root_module":{"child_modules":[{"address":"module.eks","resources":[{"address":"module.eks.aws_eks_cluster.this[0]","mode":"managed","type":"aws_eks_cluster","name":"this","values":{"vpc_config":[{"endpoint_public_access":true,"endpoint_private_access":false,"public_access_cidrs":["198.51.100.8/32"]}]}}]}]}}}
JSON

cat >"$temporary_dir/no-cluster.json" <<'JSON'
{"planned_values":{"root_module":{"resources":[]}}}
JSON

bash "$repo_root/scripts/validate-eks-endpoint-plan.sh" "$temporary_dir/valid.json" >/dev/null
bash "$repo_root/scripts/validate-eks-endpoint-plan.sh" "$temporary_dir/no-cluster.json" --allow-cluster-absent >/dev/null

for plan_file in "$temporary_dir/unrestricted.json" "$temporary_dir/private-disabled.json" "$temporary_dir/no-cluster.json"; do
  if bash "$repo_root/scripts/validate-eks-endpoint-plan.sh" "$plan_file" >/dev/null 2>&1; then
    echo "Unsafe EKS endpoint plan should be rejected: $plan_file" >&2
    exit 1
  fi
done

if bash "$repo_root/scripts/validate-eks-endpoint-plan.sh" "$temporary_dir/private-disabled.json" --allow-cluster-absent >/dev/null 2>&1; then
  echo "NAT shutdown must still reject an unsafe EKS endpoint when the cluster remains in the plan: $temporary_dir/private-disabled.json" >&2
  exit 1
fi

for invalid_cidrs in '["198.51.100.8/0"]' '["0.0.0.0/0"]' '["2001:db8::/64"]' '["198.51.100.1/24"]'; do
  export TF_VAR_cluster_endpoint_public_access_cidrs="$invalid_cidrs"
  if bash "$repo_root/scripts/validate-eks-endpoint-plan.sh" "$temporary_dir/valid.json" >/dev/null 2>&1; then
    echo "Invalid administrator CIDR should be rejected: $invalid_cidrs" >&2
    exit 1
  fi
done

echo "EKS endpoint plan guard tests passed."
