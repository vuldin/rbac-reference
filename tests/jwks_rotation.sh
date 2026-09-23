#!/usr/bin/env bash
# IdP signing-key rotation. Redpanda caches the IdP's JWKS for
# oidc_keys_refresh_interval and does not re-fetch when a token arrives signed
# with an unknown `kid`. After an unannounced rotation, every OIDC login fails
# until the cache refreshes (default 3600s).
#
# Okta publishes the next key in its JWKS before it signs with it, so routine
# rotations are covered by the cache; an emergency rotation is not.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

can_auth() { rpk_oidc "$(kc_token olivia)" topic list >/dev/null 2>&1; }
REALM_ID=$(kc_api "" | jq -r .id)
ORIG_INTERVAL=$(rpk_admin cluster config get oidc_keys_refresh_interval)
COMP=""
cleanup() {
  [[ -n $COMP ]] && kc_api "/components/$COMP" -X DELETE >/dev/null
  rpk_admin cluster config set oidc_keys_refresh_interval "$ORIG_INTERVAL" >/dev/null
}
trap cleanup EXIT

hr "Baseline"
expect_ok "olivia authenticates with the current key" can_auth
rpk_admin cluster config set oidc_keys_refresh_interval 3600 >/dev/null
note "oidc_keys_refresh_interval set to 3600s (the default)"

hr "Rotate: add a higher-priority RSA key in the IdP (new tokens use a new kid)"
kc_api "/components" -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$REALM_ID" \
  '{name:"rotated-key", providerId:"rsa-generated", providerType:"org.keycloak.keys.KeyProvider", parentId:$p,
    config:{priority:["500"], enabled:["true"], active:["true"], keySize:["2048"]}}')" >/dev/null
COMP=$(kc_api "/components?name=rotated-key" | jq -r '.[0].id')
note "new kid: $(cut -d. -f1 <<<"$(kc_token olivia)" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r .kid)"
if can_auth; then fail "expected auth to fail with an unknown kid"
else finding "tokens signed with the new key are rejected — Redpanda did not re-fetch JWKS on unknown kid"; fi

hr "Recover: changing oidc_keys_refresh_interval triggers a refresh"
rpk_admin cluster config set oidc_keys_refresh_interval 10 >/dev/null
for i in $(seq 1 12); do sleep 5; can_auth && break; done
expect_ok "olivia authenticates again after the JWKS refresh" can_auth

summary
