#!/usr/bin/env bash
# Control plane (Redpanda Cloud only): create a custom "Observer" role that has
# the predefined Reader's permissions MINUS every data-plane permission, then
# bind it (and the data-reader tier) to IdP groups at resource-group scope.
#
# The Terraform provider (v2.4.0) has no resource for custom roles or group
# role bindings, so this uses the Control Plane API directly.
#
# Status: NOT run against a live org in this repo. Dry-run by default — prints
# every request. Review the permission list it derives before using --apply.
#
# Usage:
#   export RP_CLIENT_ID=... RP_CLIENT_SECRET=...          # Cloud service account
#   ./observer-role.sh --rg <resource-group-id> --observer-group-id <id> [--apply]
set -euo pipefail

API=${RP_API:-https://api.redpanda.com}
AUTH=${RP_AUTH:-https://auth.prd.cloud.redpanda.com/oauth/token}
APPLY=false; RG=""; OBS_GROUP=""; ROLE_NAME=${ROLE_NAME:-observer-no-data}

while [[ $# -gt 0 ]]; do
  case $1 in
    --rg) RG=$2; shift 2 ;;
    --observer-group-id) OBS_GROUP=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n $RG && -n $OBS_GROUP ]] || { echo "need --rg and --observer-group-id" >&2; exit 2; }

TOKEN=$(curl -sf -X POST "$AUTH" -H 'Content-Type: application/x-www-form-urlencoded' \
  -d grant_type=client_credentials -d client_id="$RP_CLIENT_ID" -d client_secret="$RP_CLIENT_SECRET" \
  -d audience=cloudv2-production.redpanda.cloud | jq -r .access_token)
call() { curl -sf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }

# 1. Derive permissions from the built-in Reader role, excluding data-plane ones.
#    Permission strings are not hard-coded here because we could not verify the
#    exact names offline; inspect the output before applying.
reader=$(call "$API/v1/roles?filter.name=Reader" | jq '.roles[] | select(.is_builtin and .name=="Reader")')
perms=$(jq -c '[.permissions[] | select(test("^dataplane"; "i") | not)]' <<<"$reader")
dropped=$(jq -c '[.permissions[] | select(test("^dataplane"; "i"))]' <<<"$reader")
echo "Reader permissions kept for $ROLE_NAME:"; jq -r '.[]' <<<"$perms" | sed 's/^/  + /'
echo "Dropped (data plane):";                    jq -r '.[]' <<<"$dropped" | sed 's/^/  - /'

role_body=$(jq -nc --arg n "$ROLE_NAME" --argjson p "$perms" \
  '{role:{name:$n, description:"Console + metrics, no message contents", permissions:$p}}')
bind_body=$(jq -nc --arg r "$ROLE_NAME" --arg a "$OBS_GROUP" --arg rg "$RG" \
  '{role_binding:{role_name:$r, account_id:$a, scope:{resource_type:"SCOPE_RESOURCE_TYPE_RESOURCE_GROUP", resource_id:$rg}}}')

echo; echo "POST $API/v1/roles";          jq . <<<"$role_body"
echo "POST $API/v1/role-bindings";        jq . <<<"$bind_body"
echo "  (assumes a registered IdP group's ID is accepted as account_id — confirm)"

if $APPLY; then
  call -X POST "$API/v1/roles" -d "$role_body" | jq .
  call -X POST "$API/v1/role-bindings" -d "$bind_body" | jq .
else
  echo; echo "Dry run. Re-run with --apply to create."
fi
