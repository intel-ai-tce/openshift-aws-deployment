#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd ssh scp tar
load_bastion_state

if [[ ! -f "$SSH_PRIVATE_KEY" ]]; then
  echo "ERROR: SSH private key not found: $SSH_PRIVATE_KEY" >&2
  exit 1
fi
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
  echo "ERROR: pull secret not found: $PULL_SECRET_FILE" >&2
  exit 1
fi
if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "ERROR: SSH public key not found: $SSH_PUBLIC_KEY" >&2
  exit 1
fi

remote_home_path() {
  local local_path="$1"
  if [[ "$local_path" != "$HOME/"* ]]; then
    echo "ERROR: file copied to bastion must be under HOME: $local_path" >&2
    echo "Use a location under ~/.config/openshift-aws or ~/.ssh." >&2
    exit 1
  fi
  printf '/home/ec2-user/%s\n' "${local_path#"$HOME/"}"
}

SSH_ARGS=(
  -i "$SSH_PRIVATE_KEY"
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)
REMOTE="ec2-user@$BASTION_IP"
REMOTE_CONFIG="/home/ec2-user/.config/openshift-aws/config.env"
REMOTE_PULL_SECRET="$(remote_home_path "$PULL_SECRET_FILE")"
REMOTE_PUBLIC_KEY="$(remote_home_path "$SSH_PUBLIC_KEY")"
AWS_CONFIG_SOURCE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
AWS_CREDENTIALS_SOURCE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

echo "Copying deployment source to $REMOTE:$BASTION_REMOTE_DIR ..."

tar \
  --exclude='./cluster' \
  --exclude='./.git' \
  --exclude='./.bastion.env' \
  --exclude='./config.env' \
  --exclude='./install-config.yaml.backup' \
  --exclude='./pull-secret*.txt' \
  -C "$ROOT_DIR" \
  -czf - . | \
ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "mkdir -p '$BASTION_REMOTE_DIR' && tar -xzf - -C '$BASTION_REMOTE_DIR'"

ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "mkdir -p ~/.config/openshift-aws ~/.aws '$(dirname "$REMOTE_PULL_SECRET")' '$(dirname "$REMOTE_PUBLIC_KEY")'; chmod 700 ~/.config/openshift-aws ~/.aws ~/.ssh 2>/dev/null || true"

scp "${SSH_ARGS[@]}" "$CONFIG_FILE" "$REMOTE:$REMOTE_CONFIG"
scp "${SSH_ARGS[@]}" "$PULL_SECRET_FILE" "$REMOTE:$REMOTE_PULL_SECRET"
scp "${SSH_ARGS[@]}" "$SSH_PUBLIC_KEY" "$REMOTE:$REMOTE_PUBLIC_KEY"

# Static AWS credentials/config are copied only when present. If the bastion uses
# an IAM instance profile, these files can be absent and the AWS SDK will use the role.
if [[ -f "$AWS_CONFIG_SOURCE" ]]; then
  scp "${SSH_ARGS[@]}" "$AWS_CONFIG_SOURCE" "$REMOTE:/home/ec2-user/.aws/config"
fi
if [[ -f "$AWS_CREDENTIALS_SOURCE" ]]; then
  scp "${SSH_ARGS[@]}" "$AWS_CREDENTIALS_SOURCE" "$REMOTE:/home/ec2-user/.aws/credentials"
fi

ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "chmod 600 '$REMOTE_CONFIG' '$REMOTE_PULL_SECRET'; chmod 644 '$REMOTE_PUBLIC_KEY'; [[ ! -f ~/.aws/config ]] || chmod 600 ~/.aws/config; [[ ! -f ~/.aws/credentials ]] || chmod 600 ~/.aws/credentials; chmod +x '$BASTION_REMOTE_DIR'/*.sh"

echo "Copy completed."
echo "Configuration installed on bastion at ~/.config/openshift-aws/config.env"
if [[ -f "$AWS_CONFIG_SOURCE" || -f "$AWS_CREDENTIALS_SOURCE" ]]; then
  echo "AWS CLI configuration/credentials copied to bastion ~/.aws (static-credential flow)."
else
  echo "No local ~/.aws files copied; bastion must use an IAM role or other AWS credential provider."
fi
echo "SSH private key remains on the workstation; only the public key is copied."
echo "Next: ./ssh-bastion.sh"
