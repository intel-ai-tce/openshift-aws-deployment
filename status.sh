#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws
aws_identity_check

echo "OpenShift-related EC2 instances:"
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=${CLUSTER_NAME}-*" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress}' \
  --output table

echo "Bastion:"
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$BASTION_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,State:State.Name,Type:InstanceType,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output table

cluster_kubeconfig=""
if [[ -f "$INSTALL_DIR/auth/kubeconfig" ]]; then
  cluster_kubeconfig="$INSTALL_DIR/auth/kubeconfig"
elif [[ -n "${KUBECONFIG:-}" ]]; then
  IFS=':' read -r -a kubeconfigs <<<"$KUBECONFIG"
  for candidate in "${kubeconfigs[@]}"; do
    if [[ -f "$candidate" ]]; then
      cluster_kubeconfig="$candidate"
      break
    fi
  done
fi

if [[ -n "$cluster_kubeconfig" ]] && command -v oc >/dev/null 2>&1; then
  echo "Cluster status (kubeconfig: $cluster_kubeconfig):"
  KUBECONFIG="$cluster_kubeconfig" oc get nodes -o wide || true
  KUBECONFIG="$cluster_kubeconfig" oc get co || true
else
  echo "Cluster status: kubeconfig not available; showing AWS resources only."
fi
