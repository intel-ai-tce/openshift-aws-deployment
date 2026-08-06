#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws
aws_identity_check
load_bastion_state

cat <<EOF2
This terminates the public bastion:
  Instance ID: $BASTION_ID
  Public IP:   $BASTION_IP

Destroy the OpenShift cluster first from the bastion.
EOF2

confirm_exact "TERMINATE-BASTION" "Type TERMINATE-BASTION to continue: "

state="$(aws ec2 describe-instances \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || true)"

if [[ -z "$state" || "$state" == "None" || "$state" == "terminated" ]]; then
  echo "Bastion is already terminated or no longer exists."
else
  aws ec2 terminate-instances --instance-ids "$BASTION_ID" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$BASTION_ID"
  echo "Terminated bastion: $BASTION_ID"
fi

rm -f "$BASTION_STATE_FILE"
