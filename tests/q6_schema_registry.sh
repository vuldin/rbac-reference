#!/usr/bin/env bash
# Q6 — What Schema Registry grant gives a read-only "browse schemas" tier?
#   Proposed:    subject: Read, Describe  +  registry: Describe
#   Recommended: add DescribeConfigs on subject and registry (matches Cloud's
#                predefined Reader), so compatibility/mode settings are visible.
# Also checks GBAC on Schema Registry, and what happens when
# schema_registry_enable_authorization is OFF (its default).
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

SUBJ=credit-wallet.ledger-value
NEW_SCHEMA='{"schemaType":"JSON","schema":"{\"type\":\"object\",\"properties\":{\"member_id\":{\"type\":\"string\"},\"credits\":{\"type\":\"integer\"},\"note\":{\"type\":\"string\"}}}"}'

# sr <curl-auth-args...> -- <method> <path> [body]  -> prints HTTP status
sr() {
  local auth=(); while [[ $1 != -- ]]; do auth+=("$1"); shift; done; shift
  local m=$1 path=$2 body=${3:-}
  curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" -X "$m" \
    -H 'Content-Type: application/vnd.schemaregistry.v1+json' ${body:+-d "$body"} "$SR_URL$path"
}
# GET /subjects is filtered, not denied: check the subject is actually listed
lists_subject() { curl -s "$@" "$SR_URL/subjects" | jq -e --arg s "$SUBJ" 'index($s) != null' >/dev/null; }
allowed() { [[ $2 =~ ^(200|404)$ ]] && pass "$1 ($2)" || fail "$1 (got $2)"; }
denied()  { [[ $2 == 403 ]] && pass "$1 (403)" || fail "$1 (got $2, want 403)"; }

tmp_user_in_role() {  # tmp_user_in_role <user> <role> -> SCRAM user assigned to role
  rpk_admin security user create "$1" -p "$1-secret" --mechanism SCRAM-SHA-256 >/dev/null 2>&1
  rpk_admin security role assign "$2" --principal "User:$1" >/dev/null
}
tmp_user_rm() { rpk_admin security user delete "$1" >/dev/null 2>&1; }

hr "Recommended reader grant (prod_reader role) — SCRAM user in the role"
tmp_user_in_role sr-reader prod_reader
R=(-u sr-reader:sr-reader-secret)
lists_subject "${R[@]}" && pass "subject is listed" || fail "subject should be listed"
allowed "read latest schema"          "$(sr "${R[@]}" -- GET /subjects/$SUBJ/versions/latest)"
allowed "read schema by id"           "$(sr "${R[@]}" -- GET /schemas/ids/1)"
allowed "read global compatibility"   "$(sr "${R[@]}" -- GET /config)"
allowed "read subject compatibility"  "$(sr "${R[@]}" -- GET /config/$SUBJ)"
denied  "register a new version"      "$(sr "${R[@]}" -- POST /subjects/$SUBJ/versions "$NEW_SCHEMA")"
denied  "delete the subject"          "$(sr "${R[@]}" -- DELETE /subjects/$SUBJ)"
denied  "change global compatibility" "$(sr "${R[@]}" -- PUT /config '{"compatibility":"NONE"}')"
tmp_user_rm sr-reader

hr "Proposed grant (no DescribeConfigs)"
rpk_admin security role create sr_proposal >/dev/null 2>&1
rpk_admin security acl create --allow-role sr_proposal --operation read,describe --registry-subject '*' >/dev/null
rpk_admin security acl create --allow-role sr_proposal --operation describe --registry-global >/dev/null
tmp_user_in_role sr-proposal sr_proposal
P=(-u sr-proposal:sr-proposal-secret)
lists_subject "${P[@]}" && pass "subject is listed" || fail "subject should be listed"
allowed "read latest schema"                     "$(sr "${P[@]}" -- GET /subjects/$SUBJ/versions/latest)"
denied  "GAP: cannot read global compatibility"  "$(sr "${P[@]}" -- GET /config)"
denied  "GAP: cannot read subject compatibility" "$(sr "${P[@]}" -- GET /config/$SUBJ)"
tmp_user_rm sr-proposal
rpk_admin security role delete sr_proposal --no-confirm >/dev/null 2>&1

hr "GBAC on Schema Registry — dana (Group:rp-prod-reader -> prod_reader) via OIDC bearer"
D=(-H "Authorization: Bearer $(kc_token dana)")
code=$(sr "${D[@]}" -- GET /subjects/$SUBJ/versions/latest)
if [[ $code == 200 ]]; then pass "group-derived role applies on Schema Registry"
else
  finding "Group: principals are not applied on Schema Registry with OIDC bearer auth (got $code)."
  note "Same token is authorized on the Kafka API via the same role; a User:dana SR ACL works."
  rpk_admin security acl create --allow-principal User:dana --operation read,describe --registry-subject "$SUBJ" >/dev/null 2>&1
  sleep 1
  code=$(sr "${D[@]}" -- GET /subjects/$SUBJ/versions/latest)
  [[ $code == 200 ]] && note "control: User:dana ACL -> $code" || note "control: User:dana ACL -> $code (unexpected)"
  rpk_admin security acl delete --allow-principal User:dana --operation read,describe --registry-subject "$SUBJ" --no-confirm >/dev/null 2>&1
fi

hr "Observer tier has no SR grants — olivia"
lists_subject -H "Authorization: Bearer $(kc_token olivia)" && fail "olivia should not see subjects" || pass "olivia sees an empty subject list"

hr "With schema_registry_enable_authorization=false (the default!)"
rpk_admin cluster config set schema_registry_enable_authorization false >/dev/null
trap 'rpk_admin cluster config set schema_registry_enable_authorization true >/dev/null' EXIT
sleep 2
curl -s -o /dev/null -u "$SUPERUSER:$SUPERPASS" -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  -d '{"schemaType":"JSON","schema":"{\"type\":\"object\"}"}' "$SR_URL/subjects/throwaway-value/versions"
code=$(sr -H "Authorization: Bearer $(kc_token nora)" -- DELETE /subjects/throwaway-value)
[[ $code == 200 ]] && pass "RISK shown: nora (no groups, no ACLs) can DELETE a subject when SR authz is off" \
                   || fail "expected unauthorized delete to succeed with authz off (got $code)"
rpk_admin cluster config set schema_registry_enable_authorization true >/dev/null; trap - EXIT
curl -s -o /dev/null -u "$SUPERUSER:$SUPERPASS" -X DELETE "$SR_URL/subjects/throwaway-value?permanent=true"

summary
