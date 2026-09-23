#!/usr/bin/env bash
# Q3 — Is expiring IdP group membership a safe mechanism for time-bound PHI read?
#
# Redpanda reads the groups claim from the access token at authentication time.
# So removing someone from the group does NOT revoke a token they already hold:
# access continues until that token expires. This test measures that window.
#
# Realm access-token lifespan is 60s (keycloak/realm.json) so this runs ~75s.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

USER_ID=$(kc_api "/users?username=dana&exact=true" | jq -r '.[0].id')
GROUP_ID=$(kc_api "/groups?search=rp-prod-reader&exact=true" | jq -r '.[] | select(.name=="rp-prod-reader") | .id')
restore() { kc_api "/users/$USER_ID/groups/$GROUP_ID" -X PUT >/dev/null; }
trap restore EXIT

read_as() {
  local out; out=$(timeout 15 rpk topic consume credit-wallet.ledger -n 1 -o start \
    -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$1" 2>&1)
  echo "$out" | head -c 300
  grep -q '"value"' <<<"$out" && ! grep -qE 'AUTHORIZATION_FAILED|SASL_AUTHENTICATION_FAILED' <<<"$out"
}

hr "Grant: dana is in rp-prod-reader"
T1=$(kc_token dana)
EXP=$(jwt_claims "$T1" | jq .exp)
note "token T1 groups=$(jwt_claims "$T1" | jq -c .groups) expires in $((EXP - $(date +%s)))s"
expect_ok "dana reads with T1" read_as "$T1"

hr "Revoke: remove dana from rp-prod-reader in the IdP"
kc_api "/users/$USER_ID/groups/$GROUP_ID" -X DELETE >/dev/null && note "removed at $(date +%T)"

T2=$(kc_token dana)
note "fresh token T2 groups=$(jwt_claims "$T2" | jq -c .groups)"
expect_denied "a NEW token (T2) is denied immediately" read_as "$T2"

# This is the exposure window: the old token still carries the group claim.
if read_as "$T1" >/dev/null; then
  pass "WINDOW: the OLD token (T1) still reads after revocation, on a new connection ($((EXP - $(date +%s)))s left)"
else
  fail "expected T1 to still be accepted until it expires"
fi

hr "Wait for T1 to expire"
WAIT=$((EXP - $(date +%s) + 8)); (( WAIT > 0 )) && { note "sleeping ${WAIT}s"; sleep "$WAIT"; }
expect_denied "T1 is rejected once expired" read_as "$T1"

note ""
note "Takeaway: revocation latency = remaining lifetime of tokens already issued."
note "Okta default access-token lifetime is 1h; set the Redpanda auth server/app"
note "to a short lifetime (e.g. 5–15 min) for the PHI reader group, and keep"
note "oidc_token_expire_disconnect=true so long-lived connections are cut at expiry."

summary
