# Shared helpers. Source from scripts/ and tests/.
# shellcheck shell=bash

BROKERS="${BROKERS:-localhost:19092}"
SR_URL="${SR_URL:-http://localhost:18081}"
ADMIN_URL="${ADMIN_URL:-localhost:19644}"
KC_URL="${KC_URL:-http://localhost:8180}"
KC_REALM="acme"

SUPERUSER="admin"
SUPERPASS="admin-secret"

PASS_COUNT=0
FAIL_COUNT=0
FINDING_COUNT=0

# rpk as the bootstrap superuser
rpk_admin() {
  rpk "$@" -X brokers="$BROKERS" -X admin.hosts="$ADMIN_URL" -X registry.hosts="${SR_URL#http://}" \
    -X user="$SUPERUSER" -X pass="$SUPERPASS" -X sasl.mechanism=SCRAM-SHA-256
}

# rpk as a SCRAM service account: rpk_scram <user> <pass> <args...>
rpk_scram() {
  local u="$1" p="$2"; shift 2
  rpk "$@" -X brokers="$BROKERS" -X user="$u" -X pass="$p" -X sasl.mechanism=SCRAM-SHA-256
}

# rpk as a human with an OIDC access token: rpk_oidc <token> <args...>
rpk_oidc() {
  local t="$1"; shift
  rpk "$@" -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$t"
}

# Assign an IdP group to a Redpanda role via the Admin API v2 SecurityService
# (rpk <= v26.2.1 calls the v1 endpoint, which only accepts User: principals).
role_add_group() {
  curl -sf -u "$SUPERUSER:$SUPERPASS" -H 'Content-Type: application/json' \
    -X POST "http://$ADMIN_URL/redpanda.core.admin.v2.SecurityService/AddRoleMembers" \
    -d "$(jq -nc --arg r "$1" --arg g "$2" '{roleName:$r, members:[{group:{name:$g}}]}')"
}
role_remove_group() {
  curl -sf -u "$SUPERUSER:$SUPERPASS" -H 'Content-Type: application/json' \
    -X POST "http://$ADMIN_URL/redpanda.core.admin.v2.SecurityService/RemoveRoleMembers" \
    -d "$(jq -nc --arg r "$1" --arg g "$2" '{roleName:$r, members:[{group:{name:$g}}]}')"
}

# Password-grant an access token for a Keycloak user (stand-in for Okta SSO)
kc_token() {
  curl -sf -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=rp-cli -d client_secret=rp-cli-secret \
    -d username="$1" -d password="${2:-password}" -d scope=openid | jq -r .access_token
}

kc_admin_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
    | jq -r .access_token
}

# Keycloak admin REST call. Fetches a fresh admin token per call: master-realm
# admin tokens live 60s, shorter than some tests.
kc_api() { curl -sf -H "Authorization: Bearer $(kc_admin_token)" "$KC_URL/admin/realms/$KC_REALM$1" "${@:2}"; }

# Decode a JWT payload (for showing claims in test output)
jwt_claims() {
  local p; p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p+="="; done
  base64 -d <<<"$p" 2>/dev/null
}

hr()    { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note()  { printf '   %s\n' "$*"; }
pass()  { PASS_COUNT=$((PASS_COUNT+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
# A verified behaviour that contradicts docs/expectations — reported, not a test failure
finding() { FINDING_COUNT=$((FINDING_COUNT+1)); printf '  \033[33mFINDING\033[0m %s\n' "$*"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# expect_ok "<description>" <command...>   — command must succeed
expect_ok() {
  local d="$1"; shift
  local out; if out=$("$@" 2>&1); then pass "$d"; else fail "$d"; note "${out:0:400}"; fi
}

# expect_denied "<description>" <command...> — command must fail with an authz error
expect_denied() {
  local d="$1"; shift
  local out; if out=$("$@" 2>&1); then fail "$d (was allowed)"; note "${out:0:400}";
  elif grep -qiE 'AUTHORIZATION_FAILED|not authorized|unauthorized|forbidden|403|40301|access denied|SASL_AUTHENTICATION_FAILED' <<<"$out"; then pass "$d"; note "-> ${out//$'\n'/ }" | cut -c1-200;
  else fail "$d (failed, but not with an authz error)"; note "${out:0:400}"; fi
}

# Some rpk commands exit 0 but report per-resource authz errors; make them fail.
strict() { local out rc; out=$("$@" 2>&1); rc=$?; echo "$out"; [[ $rc -eq 0 ]] && ! grep -q 'AUTHORIZATION_FAILED' <<<"$out"; }

summary() {
  printf '\n%d passed, %d failed, %d findings\n' "$PASS_COUNT" "$FAIL_COUNT" "$FINDING_COUNT"
  [[ $FAIL_COUNT -eq 0 ]]
}
