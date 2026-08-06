#!/usr/bin/env bash
set -euo pipefail

for cmd in oc jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

echo "=== NVIDIA GPU Operator ==="
if oc get clusterpolicy gpu-cluster-policy >/dev/null 2>&1; then
  oc get clusterpolicy gpu-cluster-policy \
    -o custom-columns='NAME:.metadata.name,STATE:.status.state' \
    --no-headers
else
  echo "Not installed: gpu-cluster-policy"
fi

echo
echo "=== Worker GPU resources ==="
printf '%-55s %-12s %-10s %-12s\n' "NODE" "NVIDIA_PCI" "CAPACITY" "ALLOCATABLE"
while IFS=$'\t' read -r node pci capacity allocatable; do
  printf '%-55s %-12s %-10s %-12s\n' "$node" "$pci" "$capacity" "$allocatable"
done < <(
  oc get nodes -o json | jq -r '
    .items[]
    | select(
        (.metadata.labels["node-role.kubernetes.io/worker"] // null) != null
        or (.metadata.labels["node-role.kubernetes.io/master"] // null) == null
      )
    | [
        .metadata.name,
        (.metadata.labels["feature.node.kubernetes.io/pci-10de.present"] // "false"),
        (.status.capacity["nvidia.com/gpu"] // "0"),
        (.status.allocatable["nvidia.com/gpu"] // "0")
      ]
    | @tsv
  '
)

echo
echo "=== NVIDIA GPU Operator pods ==="
if oc get namespace nvidia-gpu-operator >/dev/null 2>&1; then
  oc get pods -n nvidia-gpu-operator -o wide
else
  echo "Namespace nvidia-gpu-operator does not exist."
fi

echo
echo "A GPU workload requests devices with, for example:"
cat <<'EOF'
resources:
  limits:
    nvidia.com/gpu: 2
EOF
