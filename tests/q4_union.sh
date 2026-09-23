#!/usr/bin/env bash
# Q4 (data-plane analogue) — Bindings are a UNION. A broad legacy binding left
# in place during a migration silently overrides the new least-privilege tier.
#
# Resource-group isolation itself is a Cloud control-plane concept and cannot
# be tested locally — see cloud/q4_rg_isolation_test_plan.md. The failure mode
# that matters most in practice (old org-wide bindings not removed) is the same
# on both planes, and is demonstrated here.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

read_as() {
  local out; out=$(timeout 15 rpk topic consume credit-wallet.ledger -n 1 -o start \
    -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$1" 2>&1)
  echo "$out" | head -c 300
  grep -q '"value"' <<<"$out" && ! grep -q 'AUTHORIZATION_FAILED' <<<"$out"
}

LEGACY=legacy-org-reader
USER_ID=$(kc_api "/users?username=olivia&exact=true" | jq -r '.[0].id')
cleanup() {
  local gid; gid=$(kc_api "/groups?search=$LEGACY&exact=true" | jq -r '.[0].id // empty')
  [[ -n $gid ]] && kc_api "/groups/$gid" -X DELETE >/dev/null
  rpk_admin security role delete legacy_org_reader --no-confirm >/dev/null 2>&1
}
trap cleanup EXIT; cleanup

hr "Baseline: olivia is an Observer only"
expect_denied "olivia cannot read messages" read_as "$(kc_token olivia)"

hr "Simulate a legacy org-wide Reader binding that was never removed"
rpk_admin security role create legacy_org_reader >/dev/null
rpk_admin security acl create --allow-role legacy_org_reader --operation read,describe --topic '*' >/dev/null
role_add_group legacy_org_reader "$LEGACY" >/dev/null
kc_api "/groups" -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$LEGACY\"}" >/dev/null
GID=$(kc_api "/groups?search=$LEGACY&exact=true" | jq -r '.[0].id')
kc_api "/users/$USER_ID/groups/$GID" -X PUT >/dev/null
T=$(kc_token olivia); note "olivia groups now: $(jwt_claims "$T" | jq -c .groups)"
if read_as "$T" >/dev/null; then
  pass "UNION: olivia can now read PHI — the legacy binding overrides the Observer tier"
else
  fail "expected the union of bindings to grant read"
fi

hr "Remove the legacy binding (the cutover step)"
cleanup
expect_denied "olivia is back to Observer-only" read_as "$(kc_token olivia)"

note ""
note "Takeaway: deleting the old Organization-scoped Reader/Writer/Admin group"
note "bindings is part of the cutover, not a follow-up. A deny rule would also"
note "work on the data plane (denies win), but the control plane has no denies."

summary
