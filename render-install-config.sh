#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd jq

if [[ "$CONTROL_PLANE_REPLICAS" != "3" ]]; then
  echo "ERROR: CONTROL_PLANE_REPLICAS must be 3 for this deployment." >&2
  echo "Do not use 2 unless intentionally configuring the special two-node fencing topology." >&2
  exit 1
fi

if [[ ! -f "$PULL_SECRET_FILE" ]]; then
  echo "ERROR: Red Hat pull secret not found: $PULL_SECRET_FILE" >&2
  exit 1
fi

if ! jq -e . "$PULL_SECRET_FILE" >/dev/null 2>&1; then
  echo "ERROR: pull secret is not valid JSON: $PULL_SECRET_FILE" >&2
  exit 1
fi

if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "ERROR: SSH public key not found: $SSH_PUBLIC_KEY" >&2
  echo "Create it with:" >&2
  echo "  ssh-keygen -t ed25519 -f '$SSH_PRIVATE_KEY' -N '' -C ocp-cpu-test" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

if [[ -e "$INSTALL_DIR/metadata.json" || -d "$INSTALL_DIR/.clusterapi_output" ]]; then
  echo "ERROR: $INSTALL_DIR already contains installer state." >&2
  echo "Do not regenerate install-config.yaml for an active or resumable installation." >&2
  echo "Use ./install-cluster.sh to resume, or destroy the existing cluster first." >&2
  exit 1
fi

# A new deployment directory should be empty except for an install-config that
# the operator is deliberately replacing with FORCE=1.  This catches copied
# kubeconfigs or partial state from a different cluster before they can be
# mixed with a new installation.
unexpected_state="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name install-config.yaml -print -quit 2>/dev/null || true)"
if [[ -n "$unexpected_state" ]]; then
  echo "ERROR: $INSTALL_DIR is not clean for a new installation." >&2
  echo "Unexpected existing path: $unexpected_state" >&2
  echo "Preserve it if it belongs to a resumable cluster; otherwise remove the old cluster directory before deploying." >&2
  exit 1
fi

if [[ -f "$INSTALL_DIR/install-config.yaml" && "${FORCE:-0}" != "1" ]]; then
  echo "ERROR: $INSTALL_DIR/install-config.yaml already exists." >&2
  echo "Review or remove it, or rerun with FORCE=1 to overwrite it." >&2
  exit 1
fi

PULL_SECRET="$(jq -c . "$PULL_SECRET_FILE")"
SSH_KEY="$(tr -d '\r\n' < "$SSH_PUBLIC_KEY")"

cat > "$INSTALL_DIR/install-config.yaml" <<EOF2
apiVersion: v1
credentialsMode: Mint
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}

publish: Internal

platform:
  aws:
    region: ${AWS_REGION}
    hostedZone: ${HOSTED_ZONE_ID}
    vpc:
      subnets:
      - id: ${PRIVATE_SUBNET_ID}
        roles:
        - type: ClusterNode
        - type: BootstrapNode
        - type: ControlPlaneInternalLB
        - type: IngressControllerLB

controlPlane:
  name: master
  replicas: ${CONTROL_PLANE_REPLICAS}
  hyperthreading: Enabled
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
      zones:
      - ${AVAILABILITY_ZONE}
      rootVolume:
        type: ${ROOT_VOLUME_TYPE}
        size: ${ROOT_VOLUME_SIZE_GIB}
      additionalSecurityGroupIDs:
      - ${EXTRA_SECURITY_GROUP_ID}

compute:
- name: worker
  replicas: ${WORKER_REPLICAS}
  hyperthreading: Enabled
  platform:
    aws:
      type: ${WORKER_INSTANCE_TYPE}
      zones:
      - ${AVAILABILITY_ZONE}
      rootVolume:
        type: ${ROOT_VOLUME_TYPE}
        size: ${ROOT_VOLUME_SIZE_GIB}
      additionalSecurityGroupIDs:
      - ${EXTRA_SECURITY_GROUP_ID}

networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: ${MACHINE_NETWORK_CIDR}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16

pullSecret: |
  ${PULL_SECRET}
sshKey: |
  ${SSH_KEY}
EOF2

chmod 600 "$INSTALL_DIR/install-config.yaml"
cp "$INSTALL_DIR/install-config.yaml" "$ROOT_DIR/install-config.yaml.backup"
chmod 600 "$ROOT_DIR/install-config.yaml.backup"

echo "Generated: $INSTALL_DIR/install-config.yaml"
echo "Backup:    $ROOT_DIR/install-config.yaml.backup"
