#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws openshift-install
aws_identity_check

if [[ ! -f "$INSTALL_DIR/metadata.json" ]]; then
  echo "ERROR: installer metadata not found: $INSTALL_DIR/metadata.json" >&2
  echo "Use the same install directory that created the cluster." >&2
  exit 1
fi

cat <<EOF2
This destroys the OpenShift cluster using:
  $INSTALL_DIR

It does not terminate the bastion and does not delete the shared VPC,
subnets, security group, or private Route53 hosted zone.
EOF2

confirm_exact "DESTROY-CLUSTER" "Type DESTROY-CLUSTER to continue: "

openshift-install destroy cluster \
  --dir "$INSTALL_DIR" \
  --log-level=info
