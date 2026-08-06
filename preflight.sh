#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws jq
aws_identity_check

echo "Checking local deployment inputs..."
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
  exit 1
fi
echo "  OK: pull secret and SSH public key are available"

echo "Checking configuration values..."
if [[ "$CONTROL_PLANE_REPLICAS" != "3" ]]; then
  echo "ERROR: CONTROL_PLANE_REPLICAS must be 3 for this standard highly available cluster." >&2
  echo "The value '$CONTROL_PLANE_REPLICAS' caused the earlier two-node fencing validation error." >&2
  exit 1
fi

if ! [[ "$WORKER_REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: WORKER_REPLICAS must be a non-negative integer." >&2
  exit 1
fi

echo "  OK: control plane is configured for 3 replicas"
echo "  OK: workers are configured for $WORKER_REPLICAS replicas"

echo "Checking AWS resources..."

vpc_cidr="$(aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' \
  --output text)"
if [[ "$vpc_cidr" != "$MACHINE_NETWORK_CIDR" ]]; then
  echo "ERROR: VPC $VPC_ID CIDR is $vpc_cidr; config expects $MACHINE_NETWORK_CIDR" >&2
  exit 1
fi
echo "  OK: VPC $VPC_ID uses $vpc_cidr"

read -r private_vpc private_az private_public <<<"$(aws ec2 describe-subnets \
  --subnet-ids "$PRIVATE_SUBNET_ID" \
  --query 'Subnets[0].[VpcId,AvailabilityZone,MapPublicIpOnLaunch]' \
  --output text)"
if [[ "$private_vpc" != "$VPC_ID" || "$private_az" != "$AVAILABILITY_ZONE" ]]; then
  echo "ERROR: private subnet $PRIVATE_SUBNET_ID does not match VPC/AZ configuration." >&2
  exit 1
fi
if [[ "$private_public" == "True" || "$private_public" == "true" ]]; then
  echo "WARNING: private subnet $PRIVATE_SUBNET_ID maps public IPs on launch."
else
  echo "  OK: private subnet is in $AVAILABILITY_ZONE and does not map public IPs"
fi

read -r public_vpc public_az <<<"$(aws ec2 describe-subnets \
  --subnet-ids "$PUBLIC_SUBNET_ID" \
  --query 'Subnets[0].[VpcId,AvailabilityZone]' \
  --output text)"
if [[ "$public_vpc" != "$VPC_ID" || "$public_az" != "$AVAILABILITY_ZONE" ]]; then
  echo "ERROR: public subnet $PUBLIC_SUBNET_ID does not match VPC/AZ configuration." >&2
  exit 1
fi
echo "  OK: public subnet is in $AVAILABILITY_ZONE"

sg_vpc="$(aws ec2 describe-security-groups \
  --group-ids "$EXTRA_SECURITY_GROUP_ID" \
  --query 'SecurityGroups[0].VpcId' \
  --output text)"
if [[ "$sg_vpc" != "$VPC_ID" ]]; then
  echo "ERROR: security group $EXTRA_SECURITY_GROUP_ID belongs to $sg_vpc, not $VPC_ID" >&2
  exit 1
fi
echo "  OK: security group belongs to the expected VPC"

hosted_zone_json="$(aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --output json)"
zone_name="$(jq -r '.HostedZone.Name' <<<"$hosted_zone_json")"
zone_private="$(jq -r '.HostedZone.Config.PrivateZone' <<<"$hosted_zone_json")"
zone_vpc_count="$(jq --arg vpc "$VPC_ID" --arg region "$AWS_REGION" \
  '[.VPCs[] | select(.VPCId == $vpc and .VPCRegion == $region)] | length' \
  <<<"$hosted_zone_json")"
if [[ "$zone_name" != "${BASE_DOMAIN}." || "$zone_private" != "true" || "$zone_vpc_count" == "0" ]]; then
  echo "ERROR: hosted zone $HOSTED_ZONE_ID is not the expected private zone associated with $VPC_ID." >&2
  exit 1
fi
echo "  OK: private Route53 zone ${BASE_DOMAIN}. is associated with $VPC_ID"

for instance_type in \
  "$CONTROL_PLANE_INSTANCE_TYPE" \
  "$WORKER_INSTANCE_TYPE" \
  "$BASTION_INSTANCE_TYPE"; do
  count="$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters \
      "Name=location,Values=$AVAILABILITY_ZONE" \
      "Name=instance-type,Values=$instance_type" \
    --query 'length(InstanceTypeOfferings)' \
    --output text)"

  if [[ "$count" == "0" ]]; then
    echo "ERROR: $instance_type is not offered in $AVAILABILITY_ZONE" >&2
    exit 1
  fi
  echo "  OK: $instance_type is offered in $AVAILABILITY_ZONE"
done

dns_support="$(aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' \
  --output text)"
dns_hostnames="$(aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' \
  --output text)"
if [[ "$dns_support" != "True" && "$dns_support" != "true" ]]; then
  echo "ERROR: VPC enableDnsSupport must be true" >&2
  exit 1
fi
if [[ "$dns_hostnames" != "True" && "$dns_hostnames" != "true" ]]; then
  echo "ERROR: VPC enableDnsHostnames must be true" >&2
  exit 1
fi
echo "  OK: VPC DNS support and hostnames are enabled"

public_route_table="$(effective_route_table_id "$PUBLIC_SUBNET_ID")"
igw_count="$(aws ec2 describe-route-tables \
  --route-table-ids "$public_route_table" \
  --query 'length(RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(GatewayId, `igw-`)])' \
  --output text)"
if [[ "$igw_count" == "0" ]]; then
  echo "ERROR: public subnet effective route table $public_route_table has no 0.0.0.0/0 route to an Internet Gateway." >&2
  exit 1
fi
echo "  OK: public subnet has an Internet Gateway route"

private_route_table="$(effective_route_table_id "$PRIVATE_SUBNET_ID")"
private_default_route="$(aws ec2 describe-route-tables \
  --route-table-ids "$private_route_table" \
  --output json | jq -c '.RouteTables[0].Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")' | head -n1)"

if [[ -z "$private_default_route" ]]; then
  echo "WARNING: private subnet effective route table $private_route_table has no IPv4 default route."
  echo "OpenShift nodes need an egress path or the required VPC endpoints to pull images and reach AWS services."
else
  route_state="$(jq -r '.State // "unknown"' <<<"$private_default_route")"
  if [[ "$route_state" != "active" ]]; then
    echo "ERROR: private subnet default route is not active (state=$route_state)." >&2
    exit 1
  fi

  nat_gateway_id="$(jq -r '.NatGatewayId // empty' <<<"$private_default_route")"
  if [[ -n "$nat_gateway_id" ]]; then
    nat_state="$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$nat_gateway_id" \
      --query 'NatGateways[0].State' \
      --output text)"
    if [[ "$nat_state" != "available" ]]; then
      echo "ERROR: NAT gateway $nat_gateway_id is $nat_state, not available." >&2
      exit 1
    fi
    echo "  OK: private subnet default route uses available NAT gateway $nat_gateway_id"
  else
    route_target="$(jq -r '.GatewayId // .TransitGatewayId // .NetworkInterfaceId // .InstanceId // "unknown"' <<<"$private_default_route")"
    echo "WARNING: private subnet default route is active but does not use a NAT gateway (target=$route_target)."
    echo "Verify this target provides the required OpenShift egress, or that all required VPC endpoints exist."
  fi
fi

echo "Checking bastion SSH security-group rules..."
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
  echo "WARNING: security group $EXTRA_SECURITY_GROUP_ID has no inbound rule covering TCP/22."
else
  echo "  OK: security group has an inbound rule covering TCP/22"
fi

open_ssh_count="$(jq '
  [
    .SecurityGroups[0].IpPermissions[]
    | select(
        .IpProtocol == "-1" or
        (.IpProtocol == "tcp" and (.FromPort // 65536) <= 22 and (.ToPort // -1) >= 22)
      )
    | .IpRanges[]?
    | select(.CidrIp == "0.0.0.0/0")
  ] | length
' <<<"$sg_json")"

if [[ "$open_ssh_count" != "0" ]]; then
  echo "WARNING: TCP/22 appears open to 0.0.0.0/0. Restrict it to approved Intel egress CIDRs."
fi

echo "Checking for stale cluster DNS records..."
dns_records="$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output json | jq -r \
  --arg api "api.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg api_int "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg apps "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg apps_escaped "\\052.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." '
    .ResourceRecordSets[]
    | select(.Name == $api or .Name == $api_int or .Name == $apps or .Name == $apps_escaped)
    | .Name + " " + .Type
  ')"

if [[ -n "$dns_records" ]]; then
  echo "ERROR: conflicting cluster DNS records already exist:" >&2
  echo "$dns_records" >&2
  echo "If no active cluster owns them, run ./cleanup-stale-dns.sh and rerun preflight." >&2
  exit 1
else
  echo "  OK: no conflicting cluster DNS records found"
fi

echo "Preflight completed successfully."
