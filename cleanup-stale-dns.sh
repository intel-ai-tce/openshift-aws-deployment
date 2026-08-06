#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib.sh"

require_cmd aws jq
aws_identity_check

cat <<EOF2
This deletes only these cluster DNS record sets when present:
  api.${CLUSTER_NAME}.${BASE_DOMAIN}
  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}
  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
EOF2

confirm_exact "DELETE-DNS" "Type DELETE-DNS to continue: "

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --output json | jq \
  --arg api "api.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg api_int "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg apps "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --arg apps_escaped "\\052.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." '
{
  Changes: [
    .ResourceRecordSets[]
    | select(.Name == $api or .Name == $api_int or .Name == $apps or .Name == $apps_escaped)
    | {Action: "DELETE", ResourceRecordSet: .}
  ]
}' > "$tmp_file"

count="$(jq '.Changes | length' "$tmp_file")"
if [[ "$count" == "0" ]]; then
  echo "No matching stale records found."
  exit 0
fi

jq . "$tmp_file"

change_id="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "file://$tmp_file" \
  --query 'ChangeInfo.Id' \
  --output text)"

aws route53 wait resource-record-sets-changed --id "$change_id"
echo "Deleted $count stale DNS record set(s)."
