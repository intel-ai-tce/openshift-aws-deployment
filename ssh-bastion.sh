#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

load_bastion_state
configure_ssh_args
print_ssh_proxy_status

exec ssh \
  "${SSH_COMMON_ARGS[@]}" \
  "ec2-user@$BASTION_IP"
