#!/usr/bin/env bash
# Q7 — Break-glass & PHI read auditing.
# Shows that with `consume` in audit_enabled_event_types, every human fetch is
# recorded with who, which role/ACL authorized it, which topic, and from where;
# denied attempts are recorded too; and high-volume service accounts can be
# excluded to keep the log focused on humans.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

audit_since() {  # audit_since <epoch-ms>  -> OCSF API-activity events since then
  sleep 4        # audit events are batched before being written
  rpk_admin topic consume _redpanda.audit_log -o start -f '%v\n' 2>/dev/null | timeout 10 cat \
    | jq -c --argjson s "$1" 'select(.class_uid==6003 and .time >= $s)'
}
svc_consume() {  # fresh group each time so -o start always has a record to return
  timeout 15 rpk topic consume credit-wallet.ledger -g "credit-wallet-audit-$RANDOM" -n 1 -o start \
    -X brokers="$BROKERS" -X user=svc-wallet-consumer -X pass=svc-wallet-consumer-secret \
    -X sasl.mechanism=SCRAM-SHA-256 2>&1 | grep -q '"value"'
}
consume_oidc() { timeout 15 rpk topic consume credit-wallet.ledger -n 1 -o start -X brokers="$BROKERS" -X sasl.mechanism=OAUTHBEARER -X pass="$1" >/dev/null 2>&1; }

hr "Human read (dana) and denied read attempt (olivia)"
START=$(date +%s%3N)
consume_oidc "$(kc_token dana)"
consume_oidc "$(kc_token olivia)"
EV=$(audit_since "$START")

dana=$(jq -c 'select(.actor.user.name=="dana" and .api.operation=="fetch")' <<<"$EV" | head -1)
if [[ -n $dana ]]; then
  pass "dana's fetch is audited"
  note "$(jq -r '"user=\(.actor.user.name) via=\(.actor.user.groups|map(.type+":"+.name)|join(",")) topic=\(.resources[0].name) src=\(.src_endpoint.ip) decision=\(.actor.authorizations[0].decision)"' <<<"$dana")"
  note "policy: $(jq -r '.actor.authorizations[0].policy.desc' <<<"$dana")"
else fail "expected a fetch event for dana"; fi

olivia=$(jq -c 'select(.actor.user.name=="olivia" and .actor.authorizations[0].decision=="denied")' <<<"$EV" | head -1)
if [[ -n $olivia ]]; then
  pass "olivia's denied attempt is audited"
  note "$(jq -r '"user=\(.actor.user.name) op=\(.api.operation) resource=\(.resources[0].name // "-") decision=\(.actor.authorizations[0].decision)"' <<<"$olivia")"
else fail "expected a denied event for olivia"; fi

svc_events_since() { audit_since "$1" | jq -c 'select(.actor.user.name=="svc-wallet-consumer")' | wc -l; }

hr "Service-account exclusion — value loaded at startup"
note "audit_excluded_principals = $(rpk_admin cluster config get audit_excluded_principals | tr '\n' ' ')"
note "(set via .bootstrap.yaml or persisted from an earlier run; broker restarted since)"
docker restart redpanda >/dev/null
until rpk_admin cluster health 2>/dev/null | grep -q 'Healthy:.*true'; do sleep 2; done; sleep 3
START=$(date +%s%3N)
svc_consume || fail "svc-wallet-consumer could not consume (exclusion check would be meaningless)"
n=$(svc_events_since "$START")
if [[ $n -eq 0 ]]; then pass "startup value excludes svc-wallet-consumer"
else finding "exclusion list loaded at startup is ignored: svc-wallet-consumer produced $n events after restart"; fi

hr "Service-account exclusion — value CHANGED at runtime"
ORIG=$(rpk_admin cluster config get audit_excluded_principals | sed 's/^- //' | jq -Rsc 'split("\n")|map(select(length>0))')
rpk_admin cluster config set audit_excluded_principals '["User:svc-wallet-consumer"]' >/dev/null
sleep 2; START=$(date +%s%3N)
svc_consume || fail "svc-wallet-consumer could not consume (exclusion check would be meaningless)"
n=$(svc_events_since "$START")
[[ $n -eq 0 ]] && pass "runtime change excludes svc-wallet-consumer (User: prefix form)" \
               || fail "runtime change did not exclude ($n events)"
# Restoring is itself a change, so exclusions work again until the next restart.
rpk_admin cluster config set audit_excluded_principals "$ORIG" >/dev/null
note "Workaround until fixed: after every broker restart, change the value (e.g. set a"
note "temporary list, then the real one). In Cloud, raise with Support — maintenance restarts"
note "would re-enable auditing of excluded principals (more volume, not less security)."

hr "Audit topic retention"
ret=$(rpk_admin topic describe _redpanda.audit_log -c 2>/dev/null | awk '$1=="retention.ms"{print $2}')
note "_redpanda.audit_log retention.ms = $ret ($(( ${ret:-0} / 86400000 )) days) — ship to Datadog/SIEM for longer retention"
pass "audit topic retention inspected"

summary
