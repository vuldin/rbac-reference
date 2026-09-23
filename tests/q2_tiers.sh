#!/usr/bin/env bash
# Q1/Q2 — Does the read-tier split work on the data plane?
#   Observer: sees topics, configs, consumer-group lag; cannot read messages.
#   Reader:   Observer + message contents.
#   No group: sees nothing.
#   Break-glass admin: everything.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

consume_one() { timeout 15 rpk topic consume "$2" -n 1 -o start -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$1" 2>&1 | grep -v '^$'; return "${PIPESTATUS[0]}"; }
# rpk consume retries on authz errors instead of exiting non-zero; treat ERR lines as failure
consume_check() { local out; out=$(consume_one "$@"); grep -q '"value"' <<<"$out" && ! grep -q 'AUTHORIZATION_FAILED' <<<"$out" && { echo "$out"; return 0; }; echo "$out"; return 1; }
topics_visible() { rpk_oidc "$1" topic list 2>&1 | grep -q 'credit-wallet.ledger'; }
lag_visible()    { rpk_oidc "$1" group describe credit-wallet-balance-svc 2>&1 | grep -qE 'TOTAL-LAG +[0-9]+'; }

hr "nora — authenticated, in no groups"
N=$(kc_token nora); note "groups claim: $(jwt_claims "$N" | jq -c .groups)"
if topics_visible "$N"; then fail "nora should not see topics"; else pass "nora sees no topics"; fi
expect_denied "nora cannot read messages" consume_check "$N" credit-wallet.ledger

hr "olivia — rp-prod-observer (DESCRIBE only)"
O=$(kc_token olivia); note "groups claim: $(jwt_claims "$O" | jq -c .groups)"
if topics_visible "$O"; then pass "olivia sees topic list"; else fail "olivia should see topics"; fi
expect_ok     "olivia sees topic configs" rpk_oidc "$O" topic describe credit-wallet.ledger -c
if lag_visible "$O"; then pass "olivia sees consumer-group lag without READ"; else fail "olivia should see lag"; fi
note "$(rpk_oidc "$O" group describe credit-wallet-balance-svc 2>&1 | grep TOTAL-LAG)"
expect_denied "olivia cannot read messages" consume_check "$O" credit-wallet.ledger

hr "dana — rp-prod-reader (JIT group in prod)"
D=$(kc_token dana); note "groups claim: $(jwt_claims "$D" | jq -c .groups)"
expect_ok     "dana reads messages" consume_check "$D" credit-wallet.ledger
expect_denied "dana cannot produce" bash -c "echo x | rpk topic produce credit-wallet.ledger -X brokers=$BROKERS -X sasl.mechanism=OAUTHBEARER -X pass=$D"
expect_denied "dana cannot delete topics" strict rpk_oidc "$D" topic delete other-team.orders

hr "alex — rp-prod-admin (break-glass)"
A=$(kc_token alex); note "groups claim: $(jwt_claims "$A" | jq -c .groups)"
expect_ok "alex reads messages" consume_check "$A" credit-wallet.ledger
expect_ok "alex creates and deletes a topic" bash -c "
  rpk topic create breakglass-probe -X brokers=$BROKERS -X sasl.mechanism=OAUTHBEARER -X pass=$A &&
  rpk topic delete breakglass-probe -X brokers=$BROKERS -X sasl.mechanism=OAUTHBEARER -X pass=$A"

summary
