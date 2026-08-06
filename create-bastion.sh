#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws jq
aws_identity_check

if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "ERROR: SSH public key not found: $SSH_PUBLIC_KEY" >&2
  exit 1
fi

if aws ec2 describe-key-pairs \
  --key-names "$BASTION_KEY_NAME" >/dev/null 2>&1; then
  echo "Reusing EC2 key pair: $BASTION_KEY_NAME"
else
  echo "Importing $SSH_PUBLIC_KEY as EC2 key pair $BASTION_KEY_NAME"
  aws ec2 import-key-pair \
    --key-name "$BASTION_KEY_NAME" \
    --public-key-material "fileb://$SSH_PUBLIC_KEY" >/dev/null
fi

sg_json="$(aws ec2 describe-security-groups \
  --group-ids "$EXTRA_SECURITY_GROUP_ID" \
  --output json)"

ssh_rule_count="$(jq '
  [
    .SecurityGroups[0].IpPermissions[]
    | select(
        .IpProtocol == "-1" or
        (.IpProtocol == "tcp" and (.FromPort // 65536) <= 22 and (.ToPort // -1) >= 22)
      )
  ] | length
' <<<"$sg_json")"

if [[ "$ssh_rule_count" == "0" ]]; then
  echo "ERROR: security group $EXTRA_SECURITY_GROUP_ID has no inbound rule covering TCP/22." >&2
  echo "Add an SSH rule restricted to the approved Intel egress IP/CIDR, then rerun." >&2
  exit 1
fi

offering_count="$(aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters \
    "Name=location,Values=$AVAILABILITY_ZONE" \
    "Name=instance-type,Values=$BASTION_INSTANCE_TYPE" \
  --query 'length(InstanceTypeOfferings)' \
  --output text)"
if [[ "$offering_count" == "0" ]]; then
  echo "ERROR: $BASTION_INSTANCE_TYPE is not offered in $AVAILABILITY_ZONE." >&2
  exit 1
fi

mapfile -t existing_ids < <(aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$BASTION_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text | tr '\t' '\n' | sed '/^$/d;/^None$/d')

if (( ${#existing_ids[@]} > 1 )); then
  echo "ERROR: multiple non-terminated instances have Name=$BASTION_NAME:" >&2
  printf '  %s\n' "${existing_ids[@]}" >&2
  exit 1
fi

if (( ${#existing_ids[@]} == 1 )); then
  BASTION_ID="${existing_ids[0]}"
  echo "Found existing bastion instance: $BASTION_ID"

  instance_json="$(aws ec2 describe-instances --instance-ids "$BASTION_ID" --output json)"
  state="$(jq -r '.Reservations[0].Instances[0].State.Name' <<<"$instance_json")"
  existing_type="$(jq -r '.Reservations[0].Instances[0].InstanceType' <<<"$instance_json")"
  existing_subnet="$(jq -r '.Reservations[0].Instances[0].SubnetId' <<<"$instance_json")"
  existing_vpc="$(jq -r '.Reservations[0].Instances[0].VpcId' <<<"$instance_json")"
  existing_az="$(jq -r '.Reservations[0].Instances[0].Placement.AvailabilityZone' <<<"$instance_json")"
  existing_key="$(jq -r '.Reservations[0].Instances[0].KeyName // ""' <<<"$instance_json")"
  expected_sg_count="$(jq --arg sg "$EXTRA_SECURITY_GROUP_ID" '[.Reservations[0].Instances[0].SecurityGroups[]? | select(.GroupId == $sg)] | length' <<<"$instance_json")"

  mismatch=0
  [[ "$existing_type" == "$BASTION_INSTANCE_TYPE" ]] || { echo "ERROR: existing bastion type is $existing_type; expected $BASTION_INSTANCE_TYPE" >&2; mismatch=1; }
  [[ "$existing_subnet" == "$PUBLIC_SUBNET_ID" ]] || { echo "ERROR: existing bastion subnet is $existing_subnet; expected $PUBLIC_SUBNET_ID" >&2; mismatch=1; }
  [[ "$existing_vpc" == "$VPC_ID" ]] || { echo "ERROR: existing bastion VPC is $existing_vpc; expected $VPC_ID" >&2; mismatch=1; }
  [[ "$existing_az" == "$AVAILABILITY_ZONE" ]] || { echo "ERROR: existing bastion AZ is $existing_az; expected $AVAILABILITY_ZONE" >&2; mismatch=1; }
  [[ "$existing_key" == "$BASTION_KEY_NAME" ]] || { echo "ERROR: existing bastion key is $existing_key; expected $BASTION_KEY_NAME" >&2; mismatch=1; }
  [[ "$expected_sg_count" != "0" ]] || { echo "ERROR: existing bastion does not use security group $EXTRA_SECURITY_GROUP_ID" >&2; mismatch=1; }

  if (( mismatch != 0 )); then
    echo "Refusing to reuse a bastion whose configuration does not match the external configuration." >&2
    exit 1
  fi
  echo "Reusing existing bastion; configuration matches the external configuration."

  if [[ "$state" == "stopped" ]]; then
    aws ec2 start-instances --instance-ids "$BASTION_ID" >/dev/null
  elif [[ "$state" == "stopping" ]]; then
    aws ec2 wait instance-stopped --instance-ids "$BASTION_ID"
    aws ec2 start-instances --instance-ids "$BASTION_ID" >/dev/null
  fi
else
  AMI_ID="$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' \
    --output text)"

  echo "Launching $BASTION_INSTANCE_TYPE bastion in $PUBLIC_SUBNET_ID..."

  BASTION_ID="$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$BASTION_INSTANCE_TYPE" \
    --key-name "$BASTION_KEY_NAME" \
    --network-interfaces \
      "AssociatePublicIpAddress=true,DeleteOnTermination=true,DeviceIndex=0,Groups=$EXTRA_SECURITY_GROUP_ID,SubnetId=$PUBLIC_SUBNET_ID" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$BASTION_NAME},{Key=Purpose,Value=OpenShiftAdministration}]" \
    --query 'Instances[0].InstanceId' \
    --output text)"
fi

aws ec2 wait instance-running --instance-ids "$BASTION_ID"
aws ec2 wait instance-status-ok --instance-ids "$BASTION_ID"

BASTION_IP="$(aws ec2 describe-instances \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"

if [[ -z "$BASTION_IP" || "$BASTION_IP" == "None" ]]; then
  echo "ERROR: bastion has no public IPv4 address." >&2
  exit 1
fi

cat > "$BASTION_STATE_FILE" <<EOF2
BASTION_ID="$BASTION_ID"
BASTION_IP="$BASTION_IP"
BASTION_SG="$EXTRA_SECURITY_GROUP_ID"
BASTION_KEY_NAME="$BASTION_KEY_NAME"
EOF2
chmod 600 "$BASTION_STATE_FILE"

echo
echo "Bastion is ready:"
echo "  Instance ID: $BASTION_ID"
echo "  Public IP:   $BASTION_IP"
echo
echo "Connect with:"
echo "  ssh -i '$SSH_PRIVATE_KEY' ec2-user@$BASTION_IP"
