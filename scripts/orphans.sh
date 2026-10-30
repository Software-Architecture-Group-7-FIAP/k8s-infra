#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell expansion
# Fails if billable resources of the project survive a teardown (session-down safety net).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
TAG_FILTER="Name=tag:Project,Values=auto-shop"
FOUND=0

report() {
  local label="$1" value="$2"
  if [ -n "$value" ] && [ "$value" != "None" ]; then
    echo "ORPHAN $label: $value"
    FOUND=1
  fi
}

fail_inventory() {
  printf 'AWS inventory request failed while checking %s; refusing to report a clean teardown.\n' "$1" >&2
  exit 1
}

report_aws() {
  local label="$1" value
  shift
  if ! value="$("$@" 2>/dev/null)"; then
    fail_inventory "$label"
  fi
  report "$label" "$value"
}

report_aws "EKS clusters" aws eks list-clusters --region "$REGION" --query 'clusters[?starts_with(@, `auto-shop`)]' --output text
# EKS associates its cluster security group, tagged with the exact cluster name, with control-plane
# and managed-node ENIs. Text output is paginated, so split tabs and process every returned group ID.
if ! EKS_CLUSTER_SG_IDS="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:aws:eks:cluster-name,Values=auto-shop-staging" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)"; then
  fail_inventory "EKS cluster security groups"
fi
EKS_CLUSTER_SG_IDS="$(printf '%s\n' "$EKS_CLUSTER_SG_IDS" | tr '\t' '\n')"
while IFS= read -r group_id; do
  [ -n "$group_id" ] || continue
  [ "$group_id" = "None" ] && continue
  report_aws "EKS cluster network interfaces ($group_id)" aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=group-id,Values=$group_id" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
done <<< "$EKS_CLUSTER_SG_IDS"
report_aws "NAT gateways" aws ec2 describe-nat-gateways --region "$REGION" --filter "$TAG_FILTER" "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text
report_aws "Elastic IPs" aws ec2 describe-addresses --region "$REGION" --filters "$TAG_FILTER" --query 'Addresses[].AllocationId' --output text
report_aws "Load balancers" aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[?starts_with(LoadBalancerName, `auto-shop`)].LoadBalancerName' --output text
report_aws "Target groups" aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[?starts_with(TargetGroupName, `auto-shop`)].TargetGroupName' --output text
report_aws "EC2 instances" aws ec2 describe-instances --region "$REGION" --filters "Name=tag:aws:eks:cluster-name,Values=auto-shop-staging" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'Reservations[].Instances[].InstanceId' --output text
report_aws "EC2 instances (Kubernetes cluster tag)" aws ec2 describe-instances --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/auto-shop-staging,Values=owned,shared" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'Reservations[].Instances[].InstanceId' --output text
report_aws "EBS volumes" aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:aws:eks:cluster-name,Values=auto-shop-staging" --query 'Volumes[].VolumeId' --output text
report_aws "EBS volumes (Kubernetes cluster tag)" aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/auto-shop-staging,Values=owned,shared" --query 'Volumes[].VolumeId' --output text
report_aws "RDS instances" aws rds describe-db-instances --region "$REGION" --query 'DBInstances[?starts_with(DBInstanceIdentifier, `auto-shop-staging`)].DBInstanceIdentifier' --output text
report_aws "RDS clusters" aws rds describe-db-clusters --region "$REGION" --query 'DBClusters[?starts_with(DBClusterIdentifier, `auto-shop-staging`)].DBClusterIdentifier' --output text
report_aws "RDS proxies" aws rds describe-db-proxies --region "$REGION" --query 'DBProxies[?starts_with(DBProxyName, `auto-shop-staging`)].DBProxyName' --output text
report_aws "RDS snapshots" aws rds describe-db-snapshots --region "$REGION" --query 'DBSnapshots[?DBInstanceIdentifier != `null` && starts_with(DBInstanceIdentifier, `auto-shop-staging`)].DBSnapshotIdentifier' --output text
report_aws "RDS cluster snapshots" aws rds describe-db-cluster-snapshots --region "$REGION" --query 'DBClusterSnapshots[?DBClusterIdentifier != `null` && starts_with(DBClusterIdentifier, `auto-shop-staging`)].DBClusterSnapshotIdentifier' --output text
report_aws "EKS cluster log groups" aws logs describe-log-groups --region "$REGION" --log-group-name-prefix '/aws/eks/auto-shop-staging/cluster' --query 'logGroups[].logGroupName' --output text

if [ "$FOUND" -eq 0 ]; then
  echo "No dynamic billable resources left; the persistent VPC, subnets, and SSM contract may remain."
else
  exit 1
fi
