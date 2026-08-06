#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_FILE="$HOME/.config/openshift-aws/config.env"
CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: configuration file not found: $CONFIG_FILE" >&2
  echo "Create it outside the repository, for example:" >&2
  echo "  mkdir -p '$HOME/.config/openshift-aws'" >&2
  echo "  cp '$ROOT_DIR/config.env.example' '$DEFAULT_CONFIG_FILE'" >&2
  echo "Then edit the values and rerun the command." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

required_config_vars=(
  AWS_REGION AWS_ACCOUNT_ID VPC_ID PRIVATE_SUBNET_ID PUBLIC_SUBNET_ID
  AVAILABILITY_ZONE EXTRA_SECURITY_GROUP_ID MACHINE_NETWORK_CIDR
  BASE_DOMAIN HOSTED_ZONE_ID CLUSTER_NAME CONTROL_PLANE_REPLICAS WORKER_REPLICAS
  CONTROL_PLANE_INSTANCE_TYPE WORKER_INSTANCE_TYPE ROOT_VOLUME_TYPE
  ROOT_VOLUME_SIZE_GIB PULL_SECRET_FILE SSH_PRIVATE_KEY SSH_PUBLIC_KEY
  BASTION_NAME BASTION_INSTANCE_TYPE BASTION_KEY_NAME BASTION_REMOTE_DIR INSTALL_DIR
)

for _cfg_var in "${required_config_vars[@]}"; do
  if [[ -z "${!_cfg_var:-}" ]]; then
    echo "ERROR: required configuration value is empty: $_cfg_var" >&2
    echo "Configuration file: $CONFIG_FILE" >&2
    exit 1
  fi
done
unset _cfg_var

AWS_PROFILE="${AWS_PROFILE:-default}"
OCP_CHANNEL="${OCP_CHANNEL:-stable-4.20}"
OCP_TOOLBOX_IMAGE="${OCP_TOOLBOX_IMAGE:-ocp-aws-toolbox:4.20}"
SSH_PROXY_HOST="${SSH_PROXY_HOST:-}"
SSH_PROXY_PORT="${SSH_PROXY_PORT:-1080}"

if [[ "$INSTALL_DIR" != /* ]]; then
  INSTALL_DIR="$ROOT_DIR/$INSTALL_DIR"
fi

BASTION_STATE_FILE="$ROOT_DIR/.bastion.env"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $cmd" >&2
      exit 1
    fi
  done
}


configure_ssh_args() {
  local connect_timeout="${1:-}"

  SSH_COMMON_ARGS=(
    -i "$SSH_PRIVATE_KEY"
    -o StrictHostKeyChecking=accept-new
  )

  if [[ -n "$connect_timeout" ]]; then
    SSH_COMMON_ARGS+=( -o "ConnectTimeout=$connect_timeout" )
  fi

  if [[ -n "$SSH_PROXY_HOST" ]]; then
    require_cmd nc
    SSH_COMMON_ARGS+=(
      -o "ProxyCommand=nc -X 5 -x ${SSH_PROXY_HOST}:${SSH_PROXY_PORT} %h %p"
    )
  fi
}

print_ssh_proxy_status() {
  if [[ -n "$SSH_PROXY_HOST" ]]; then
    echo "SSH transport: SOCKS5 proxy ${SSH_PROXY_HOST}:${SSH_PROXY_PORT}"
  else
    echo "SSH transport: direct"
  fi
}

aws_identity_check() {
  local account identity

  if ! account="$(aws sts get-caller-identity --query Account --output text)"; then
    echo "ERROR: unable to validate AWS credentials for profile '$AWS_PROFILE'." >&2
    echo "Run: aws sts get-caller-identity --profile '$AWS_PROFILE' --region '$AWS_REGION'" >&2
    exit 1
  fi

  if [[ "$account" != "$AWS_ACCOUNT_ID" ]]; then
    echo "ERROR: connected to AWS account $account; expected account from CONFIG_FILE" >&2
    exit 1
  fi

  identity="$(aws sts get-caller-identity --output json)"
  printf '%s\n' "$identity"
}

load_bastion_state() {
  if [[ ! -f "$BASTION_STATE_FILE" ]]; then
    echo "ERROR: bastion state not found: $BASTION_STATE_FILE" >&2
    echo "Run ./create-bastion.sh first." >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$BASTION_STATE_FILE"
}

effective_route_table_id() {
  local subnet_id="$1"
  local route_table_id

  route_table_id="$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)"

  if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
    route_table_id="$(aws ec2 describe-route-tables \
      --filters \
        "Name=vpc-id,Values=$VPC_ID" \
        "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)"
  fi

  printf '%s\n' "$route_table_id"
}

confirm_exact() {
  local expected="$1"
  local prompt="$2"
  local answer

  read -r -p "$prompt" answer
  if [[ "$answer" != "$expected" ]]; then
    echo "Cancelled."
    exit 0
  fi
}
