#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws openshift-install
aws_identity_check

if [[ ! -f "$INSTALL_DIR/install-config.yaml" && ! -f "$INSTALL_DIR/metadata.json" ]]; then
  echo "ERROR: neither install-config.yaml nor installer metadata exists in $INSTALL_DIR." >&2
  echo "Run ./render-install-config.sh for a new installation." >&2
  exit 1
fi

if [[ -f "$INSTALL_DIR/install-config.yaml" && ! -f "$ROOT_DIR/install-config.yaml.backup" ]]; then
  cp "$INSTALL_DIR/install-config.yaml" "$ROOT_DIR/install-config.yaml.backup"
  chmod 600 "$ROOT_DIR/install-config.yaml.backup"
fi

echo "Starting or resuming OpenShift installation from $INSTALL_DIR"
echo "The installer consumes install-config.yaml; backup: $ROOT_DIR/install-config.yaml.backup"

echo "This installer must run on the AWS bastion, not on the Intel workstation,"
echo "because the cluster API is private."

openshift-install create cluster \
  --dir "$INSTALL_DIR" \
  --log-level=info

echo "OpenShift installation completed."
echo "Kubeconfig: $INSTALL_DIR/auth/kubeconfig"
echo
echo "Use:"
echo "  export KUBECONFIG='$INSTALL_DIR/auth/kubeconfig'"
echo "  oc get nodes -o wide"
echo "  oc get co"
