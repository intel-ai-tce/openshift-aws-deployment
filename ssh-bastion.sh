#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

load_bastion_state

exec ssh \
  -i "$SSH_PRIVATE_KEY" \
  -o StrictHostKeyChecking=accept-new \
  "ec2-user@$BASTION_IP"
