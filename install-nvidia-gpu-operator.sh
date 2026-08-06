#!/usr/bin/env bash
set -euo pipefail

# Post-install OpenShift GPU enablement.
#
# Installs:
#   1. Red Hat Node Feature Discovery (NFD) Operator
#   2. NVIDIA GPU Operator from certified-operators
#   3. NodeFeatureDiscovery and ClusterPolicy instances from the installed CSVs
#
# CPU-only workers are safe: NVIDIA operands target nodes discovered with the
# NVIDIA PCI vendor label feature.node.kubernetes.io/pci-10de.present=true.

if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

for cmd in oc jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

TIMEOUT="${GPU_INSTALL_TIMEOUT_SECONDS:-1800}"
DRIVER_REPOSITORY="${NVIDIA_DRIVER_REPOSITORY:-}"
DRIVER_IMAGE="${NVIDIA_DRIVER_IMAGE:-}"
DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 60 )); then
  echo "ERROR: GPU_INSTALL_TIMEOUT_SECONDS must be an integer >= 60." >&2
  exit 1
fi

if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null || true)" != "yes" ]]; then
  echo "ERROR: gpu-install requires cluster-admin privileges." >&2
  exit 1
fi

wait_for_subscription_csv() {
  local namespace="$1"
  local subscription="$2"
  local deadline=$((SECONDS + TIMEOUT))
  local csv phase

  while (( SECONDS < deadline )); do
    csv="$(oc get subscription "$subscription" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"

    if [[ -n "$csv" ]]; then
      phase="$(oc get csv "$csv" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "$phase" == "Succeeded" ]]; then
        printf '%s\n' "$csv"
        return 0
      fi
    fi
    sleep 5
  done

  echo "ERROR: timed out waiting for $namespace/$subscription to install." >&2
  oc get subscription,csv -n "$namespace" >&2 || true
  return 1
}

wait_for_install_plan() {
  local namespace="$1"
  local subscription="$2"
  local deadline=$((SECONDS + TIMEOUT))
  local plan

  while (( SECONDS < deadline )); do
    plan="$(oc get subscription "$subscription" -n "$namespace" \
      -o jsonpath='{.status.installplan.name}' 2>/dev/null || true)"
    if [[ -n "$plan" ]]; then
      printf '%s\n' "$plan"
      return 0
    fi
    sleep 5
  done

  echo "ERROR: timed out waiting for an install plan for $namespace/$subscription." >&2
  return 1
}

alm_example() {
  local namespace="$1"
  local csv="$2"
  local kind="$3"

  oc get csv "$csv" -n "$namespace" \
    -o jsonpath='{.metadata.annotations.alm-examples}' \
    | jq -c --arg kind "$kind" '[.[] | select(.kind == $kind)][0] // empty'
}

echo "==> Installing Node Feature Discovery Operator"
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
  labels:
    name: openshift-nfd
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

nfd_csv="$(wait_for_subscription_csv openshift-nfd nfd)"
echo "  NFD CSV: $nfd_csv"

if ! oc get nodefeaturediscovery nfd-instance -n openshift-nfd >/dev/null 2>&1; then
  nfd_example="$(alm_example openshift-nfd "$nfd_csv" NodeFeatureDiscovery)"
  if [[ -z "$nfd_example" ]]; then
    echo "ERROR: installed NFD CSV does not contain a NodeFeatureDiscovery alm-example." >&2
    exit 1
  fi

  # Use the operator-provided example so required operand image fields match
  # the NFD Operator version installed by OLM.
  printf '%s\n' "$nfd_example" \
    | jq '.metadata.name = "nfd-instance" | .metadata.namespace = "openshift-nfd"' \
    | oc apply -f -
else
  echo "  NodeFeatureDiscovery nfd-instance already exists"
fi

echo "==> Installing NVIDIA GPU Operator"

gpu_channel="$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"
if [[ -z "$gpu_channel" ]]; then
  echo "ERROR: gpu-operator-certified is not available in OperatorHub." >&2
  exit 1
fi

gpu_starting_csv="$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace \
  -o json \
  | jq -r --arg channel "$gpu_channel" \
      '.status.channels[] | select(.name == $channel) | .currentCSV')"
if [[ -z "$gpu_starting_csv" || "$gpu_starting_csv" == "null" ]]; then
  echo "ERROR: cannot resolve current CSV for gpu-operator-certified/$gpu_channel." >&2
  exit 1
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${gpu_channel}
  installPlanApproval: Manual
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${gpu_starting_csv}
EOF

install_plan="$(wait_for_install_plan nvidia-gpu-operator gpu-operator-certified)"
approved="$(oc get installplan "$install_plan" -n nvidia-gpu-operator \
  -o jsonpath='{.spec.approved}' 2>/dev/null || true)"
if [[ "$approved" != "true" ]]; then
  echo "  Approving initial GPU Operator install plan: $install_plan"
  oc patch installplan "$install_plan" -n nvidia-gpu-operator \
    --type merge --patch '{"spec":{"approved":true}}'
fi

gpu_csv="$(wait_for_subscription_csv nvidia-gpu-operator gpu-operator-certified)"
echo "  GPU Operator CSV: $gpu_csv"

if ! oc get clusterpolicy gpu-cluster-policy >/dev/null 2>&1; then
  cluster_policy="$(alm_example nvidia-gpu-operator "$gpu_csv" ClusterPolicy)"
  if [[ -z "$cluster_policy" ]]; then
    echo "ERROR: installed GPU Operator CSV does not contain a ClusterPolicy alm-example." >&2
    exit 1
  fi

  # Start from the operator-provided example so its defaults track the installed
  # CSV. Optional config values can deliberately pin driver fields.
  printf '%s\n' "$cluster_policy" \
    | jq \
        --arg repository "$DRIVER_REPOSITORY" \
        --arg image "$DRIVER_IMAGE" \
        --arg version "$DRIVER_VERSION" '
          .metadata.name = "gpu-cluster-policy"
          | if $repository != "" then .spec.driver.repository = $repository else . end
          | if $image != "" then .spec.driver.image = $image else . end
          | if $version != "" then .spec.driver.version = $version else . end
        ' \
    | oc apply -f -
else
  echo "  ClusterPolicy gpu-cluster-policy already exists"
fi

echo "==> Waiting for GPU ClusterPolicy"
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  state="$(oc get clusterpolicy gpu-cluster-policy \
    -o jsonpath='{.status.state}' 2>/dev/null || true)"
  if [[ "${state,,}" == "ready" ]]; then
    echo "  ClusterPolicy state: $state"
    break
  fi
  sleep 10
done

state="$(oc get clusterpolicy gpu-cluster-policy \
  -o jsonpath='{.status.state}' 2>/dev/null || true)"
if [[ "${state,,}" != "ready" ]]; then
  echo "ERROR: GPU ClusterPolicy did not become ready within ${TIMEOUT}s (state=${state:-unknown})." >&2
  oc get pods,daemonset -n nvidia-gpu-operator >&2 || true
  exit 1
fi

gpu_node_count="$(oc get nodes \
  -l feature.node.kubernetes.io/pci-10de.present=true \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$gpu_node_count" == "0" ]]; then
  echo "WARNING: GPU Operator is ready, but NFD has not discovered an NVIDIA GPU node yet."
  echo "Add/check the GPU worker and run: ./container.sh gpu-status"
else
  echo "GPU enablement complete. NVIDIA GPU nodes discovered: $gpu_node_count"
  echo "Run: ./container.sh gpu-status"
fi
