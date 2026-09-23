#!/usr/bin/env bash
# Q8 — Service-account scoping: prefixed ACLs, consumer groups, idempotence,
# transactions, and IdP group names containing spaces.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

probe() { docker exec clients python /app/probe.py "$@" 2>&1 | tail -1; }
ok()     { local d=$1; shift; local r; r=$(probe "$@"); jq -e .ok <<<"$r" >/dev/null && pass "$d" || { fail "$d"; note "$r"; }; }
denied() { local d=$1; shift; local r; r=$(probe "$@"); if jq -e .ok <<<"$r" >/dev/null; then fail "$d (was allowed)";
           elif grep -qiE 'AUTHORIZATION' <<<"$r"; then pass "$d"; note "-> $(jq -r .error <<<"$r" | cut -c1-150)";
           else fail "$d (failed without an authz error)"; note "$r"; fi; }

WP=(--user svc-wallet-producer --password svc-wallet-producer-secret)
WC=(--user svc-wallet-consumer --password svc-wallet-consumer-secret)
SP=(--user svc-scribe-producer --password svc-scribe-producer-secret)

hr "Prefixed topic ACLs (wallet_producer: WRITE on 'credit-wallet.')"
ok     "produce to credit-wallet.ledger"            produce "${WP[@]}" --topic credit-wallet.ledger
denied "produce outside the prefix (other-team.orders)" produce "${WP[@]}" --topic other-team.orders
rpk_admin topic create credit-wallet.refunds -p 1 >/dev/null 2>&1
ok     "produce to a NEW topic under the prefix, no ACL change" produce "${WP[@]}" --topic credit-wallet.refunds
rpk_admin topic delete credit-wallet.refunds >/dev/null 2>&1

hr "Idempotence without IDEMPOTENT_WRITE"
ok "idempotent producer works with only topic WRITE" produce "${WP[@]}" --topic credit-wallet.ledger --idempotent
note "IDEMPOTENT_WRITE on the cluster (as in the scribe example) is harmless but unnecessary."

hr "Transactions (TRANSACTIONAL_ID on 'credit-wallet-')"
ok     "transactional producer with id credit-wallet-tx-1" produce "${WP[@]}" --topic credit-wallet.ledger --idempotent --txn-id credit-wallet-tx-1
denied "transactional id outside the prefix (rogue-tx)"    produce "${WP[@]}" --topic credit-wallet.ledger --idempotent --txn-id rogue-tx
denied "scribe producer has no TRANSACTIONAL_ID grant"     produce "${SP[@]}" --topic ml-scribe.telemetry --idempotent --txn-id ml-scribe-tx-1

hr "Consumer groups (wallet_consumer: READ on group prefix 'credit-wallet-')"
ok     "consume with group credit-wallet-balance-svc" consume "${WC[@]}" --topic credit-wallet.ledger --group credit-wallet-balance-svc
denied "consume with a group outside the prefix"      consume "${WC[@]}" --topic credit-wallet.ledger --group analytics-adhoc
rpk_admin security user create svc-no-group -p svc-no-group-secret --mechanism SCRAM-SHA-256 >/dev/null 2>&1
rpk_admin security acl create --allow-principal User:svc-no-group --operation read,describe --topic credit-wallet.ledger >/dev/null
denied "topic READ alone is not enough to consume in a group" consume --user svc-no-group --password svc-no-group-secret --topic credit-wallet.ledger --group credit-wallet-x
rpk_admin security acl delete --allow-principal User:svc-no-group --operation read,describe --topic credit-wallet.ledger --no-confirm >/dev/null 2>&1
rpk_admin security user delete svc-no-group >/dev/null 2>&1

hr "IdP group names with spaces"
S=$(kc_token sam); note "sam groups claim: $(jwt_claims "$S" | jq -c .groups)"
out=$(timeout 15 rpk topic consume credit-wallet.ledger -n 1 -o start -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$S" 2>&1)
grep -q '"value"' <<<"$out" && ! grep -q AUTHORIZATION_FAILED <<<"$out" \
  && pass "Group:Application - Redpanda - Prod - Reader resolves and grants read" \
  || { fail "group with spaces did not resolve"; note "${out:0:300}"; }

summary
