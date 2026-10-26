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

report "EKS clusters" "$(aws eks list-clusters --region "$REGION" --query 'clusters[?starts_with(@, `auto-shop`)]' --output text)"
# EKS associates its cluster security group, tagged with the exact cluster name, with control-plane
# and managed-node ENIs. Text output is paginated, so split tabs and process every returned group ID.
EKS_CLUSTER_SG_IDS="$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:aws:eks:cluster-name,Values=auto-shop-staging" --query 'SecurityGroups[].GroupId' --output text | tr '\t' '\n')"
while IFS= read -r group_id; do
  [ -n "$group_id" ] || continue
  [ "$group_id" = "None" ] && continue
  report "EKS cluster network interfaces ($group_id)" "$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=group-id,Values=$group_id" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
done <<< "$EKS_CLUSTER_SG_IDS"
report "NAT gateways" "$(aws ec2 describe-nat-gateways --region "$REGION" --filter "$TAG_FILTER" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text)"
report "Elastic IPs" "$(aws ec2 describe-addresses --region "$REGION" --filters "$TAG_FILTER" --query 'Addresses[].AllocationId' --output text)"
report "Load balancers" "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[?starts_with(LoadBalancerName, `auto-shop`)].LoadBalancerName' --output text)"
report "EC2 instances" "$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:eks:cluster-name,Values=auto-shop-staging" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
report "EBS volumes" "$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:eks:cluster-name,Values=auto-shop-staging" --query 'Volumes[].VolumeId' --output text)"
report "VPCs" "$(aws ec2 describe-vpcs --region "$REGION" --filters "$TAG_FILTER" --query 'Vpcs[].VpcId' --output text)"

if [ "$FOUND" -eq 0 ]; then
  echo "No billable project resources left."
else
  exit 1
fi
