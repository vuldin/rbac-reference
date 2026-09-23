#!/usr/bin/env bash
# Applies the reference data-plane access model to the local cluster.
#
# Humans   -> IdP groups (Group:<name>) assigned to Redpanda roles  (GBAC)
# Services -> SCRAM users assigned to one role per workload-capability (RBAC)
#
# In Redpanda Cloud the same model is applied per cluster (data-plane roles and
# ACLs are cluster-scoped); see cloud/terraform for the equivalent resources.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# Run idempotently: ignore "already exists", surface anything else.
quiet() {
  local out; out=$("$@" 2>&1) && return 0
  grep -qiE 'already exists|exists' <<<"$out" && return 0
  echo "ERROR: $*" >&2; echo "$out" >&2; return 1
}

hr "Topics"
for t in credit-wallet.ledger credit-wallet.events ml-scribe.telemetry other-team.orders; do
  quiet rpk_admin topic create "$t" -p 3
  note "$t"
done

hr "Human roles (bound to IdP groups)"
for r in prod_observer prod_reader prod_admin; do quiet rpk_admin security role create "$r"; done

# Observer: metadata + lag, no message contents. DESCRIBE only.
quiet rpk_admin security acl create --allow-role prod_observer \
  --operation describe,describe_configs --topic '*'
quiet rpk_admin security acl create --allow-role prod_observer \
  --operation describe --group '*'

# Reader: observer + READ on topics (the PHI-gated action) + read-only Schema Registry.
quiet rpk_admin security acl create --allow-role prod_reader \
  --operation describe,describe_configs,read --topic '*'
quiet rpk_admin security acl create --allow-role prod_reader \
  --operation describe --group '*'
# Human ad-hoc consumers may only use groups under this prefix
quiet rpk_admin security acl create --allow-role prod_reader \
  --operation read --group 'adhoc-' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role prod_reader \
  --operation read,describe,describe_configs --registry-subject '*'
quiet rpk_admin security acl create --allow-role prod_reader \
  --operation describe,describe_configs --registry-global

# Break-glass admin: everything on the data plane.
quiet rpk_admin security acl create --allow-role prod_admin \
  --operation all --topic '*' --group '*' --transactional-id '*' --cluster
quiet rpk_admin security acl create --allow-role prod_admin \
  --operation all --registry-subject '*' --registry-global

role_add_group prod_observer rp-prod-observer >/dev/null
role_add_group prod_reader   rp-prod-reader   >/dev/null
role_add_group prod_admin    rp-prod-admin    >/dev/null
# Okta-style display name with spaces, bound to the same role (tested in q8)
role_add_group prod_reader   "Application - Redpanda - Prod - Reader" >/dev/null
note "prod_observer <- Group:rp-prod-observer"
note "prod_reader   <- Group:rp-prod-reader, Group:Application - Redpanda - Prod - Reader"
note "prod_admin    <- Group:rp-prod-admin"

hr "Service accounts (one role per workload-capability)"
for u in svc-wallet-producer svc-wallet-consumer svc-scribe-producer; do
  quiet rpk_admin security user create "$u" -p "$u-secret" --mechanism SCRAM-SHA-256
done
for r in wallet_producer wallet_consumer scribe_producer; do quiet rpk_admin security role create "$r"; done

# wallet_producer: WRITE+DESCRIBE on prefix, transactional IDs on prefix, SR subject write.
# Deliberately no IDEMPOTENT_WRITE — q8 shows it isn't needed.
quiet rpk_admin security acl create --allow-role wallet_producer \
  --operation write,describe --topic 'credit-wallet.' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role wallet_producer \
  --operation write,describe --transactional-id 'credit-wallet-' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role wallet_producer \
  --operation read,write,describe --registry-subject 'credit-wallet.' --resource-pattern-type prefixed

# wallet_consumer: READ+DESCRIBE on topic prefix AND READ on its consumer group prefix.
quiet rpk_admin security acl create --allow-role wallet_consumer \
  --operation read,describe --topic 'credit-wallet.' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role wallet_consumer \
  --operation read,describe --group 'credit-wallet-' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role wallet_consumer \
  --operation read,describe --registry-subject 'credit-wallet.' --resource-pattern-type prefixed

# scribe_producer: mirrors the ml_scribe_producer example from the design doc.
quiet rpk_admin security acl create --allow-role scribe_producer \
  --operation write,describe --topic 'ml-scribe.' --resource-pattern-type prefixed
quiet rpk_admin security acl create --allow-role scribe_producer \
  --operation idempotent_write --cluster
quiet rpk_admin security acl create --allow-role scribe_producer \
  --operation read,write --registry-subject 'ml-scribe.' --resource-pattern-type prefixed

quiet rpk_admin security role assign wallet_producer --principal User:svc-wallet-producer
quiet rpk_admin security role assign wallet_consumer --principal User:svc-wallet-consumer
quiet rpk_admin security role assign scribe_producer --principal User:svc-scribe-producer
note "svc-wallet-producer -> wallet_producer"
note "svc-wallet-consumer -> wallet_consumer"
note "svc-scribe-producer -> scribe_producer"

hr "Audit exclusions (workaround)"
# audit_excluded_principals from .bootstrap.yaml is ignored until the value is
# CHANGED at runtime (FINDINGS.md issue 1). Toggle it so exclusions take effect.
# Re-run this script after any broker restart.
rpk_admin cluster config set audit_excluded_principals '["svc-wallet-consumer"]' >/dev/null
rpk_admin cluster config set audit_excluded_principals \
  '["svc-wallet-consumer","svc-wallet-producer","svc-scribe-producer"]' >/dev/null
note "service accounts excluded from the audit log"

hr "Seed data"
# (`group describe` on a missing group still prints TOTAL-LAG, so check the list)
if rpk_admin group list 2>/dev/null | grep -qw credit-wallet-balance-svc; then
  note "already seeded"; echo; echo "Model applied."; exit 0
fi
curl -sf -u "$SUPERUSER:$SUPERPASS" -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  -X POST "$SR_URL/subjects/credit-wallet.ledger-value/versions" \
  -d '{"schemaType":"JSON","schema":"{\"type\":\"object\",\"properties\":{\"member_id\":{\"type\":\"string\"},\"credits\":{\"type\":\"integer\"}}}"}' >/dev/null
note "registered schema credit-wallet.ledger-value"

for i in $(seq 1 30); do echo "{\"member_id\":\"m$((i % 5))\",\"credits\":$i}"; done \
  | rpk_scram svc-wallet-producer svc-wallet-producer-secret topic produce credit-wallet.ledger -k '' >/dev/null
note "produced 30 records to credit-wallet.ledger as svc-wallet-producer"

# Consume a few and commit, so the group has visible lag
rpk_scram svc-wallet-consumer svc-wallet-consumer-secret topic consume credit-wallet.ledger \
  -g credit-wallet-balance-svc -n 10 -o start >/dev/null
note "credit-wallet-balance-svc consumed 10 of 30 (lag = 20)"

echo; echo "Model applied."
