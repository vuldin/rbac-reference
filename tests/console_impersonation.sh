#!/usr/bin/env bash
# Console path — SSO login through Keycloak with user impersonation enabled.
# What each human sees in Console is decided by Redpanda ACLs/roles, exactly
# as on the Kafka API.
set -uo pipefail
cd "$(dirname "$0")/.."; source scripts/lib.sh

CONSOLE=http://localhost:8080
api() { curl -s -b "$1" "$CONSOLE$2"; }
# ListMessages is a Connect server-streaming RPC; frame the request envelope by hand
messages() {
  local body='{"topic":"credit-wallet.ledger","startOffset":"-2","partitionId":-1,"maxResults":2}'
  python3 -c "import sys,struct;b=sys.argv[1].encode();sys.stdout.buffer.write(b'\x00'+struct.pack('>I',len(b))+b)" "$body" \
    | curl -s -b "$1" -H 'Content-Type: application/connect+json' --data-binary @- \
        "$CONSOLE/redpanda.api.console.v1alpha1.ConsoleService/ListMessages" | tr -c '[:print:]\n' ' '
}
topics() { api "$1" /api/topics | jq -r '[.topics[]?.topicName] | map(select(startswith("credit-wallet"))) | length'; }
groups() { api "$1" /api/consumer-groups | jq -r '[.consumerGroups[]?.groupId] | length'; }

for u in nora olivia dana; do
  hr "$u — Console SSO login"
  J=$(scripts/console-login.sh "$u" | tail -1)
  if [[ -z $(api "$J" /api/topics | jq -r '.topics? // empty' 2>/dev/null) ]]; then fail "$u could not log in"; continue; fi
  pass "$u logged in via SSO"
  t=$(topics "$J"); g=$(groups "$J"); m=$(messages "$J")
  case $u in
    nora)
      [[ $t -eq 0 ]] && pass "sees no topics" || fail "sees $t credit-wallet topics"
      [[ $g -eq 0 ]] && pass "sees no consumer groups" || fail "sees $g groups" ;;
    olivia)
      [[ $t -gt 0 ]] && pass "sees topics ($t credit-wallet.*)" || fail "sees no topics"
      [[ $g -gt 0 ]] && pass "sees consumer groups ($g)" || fail "sees no groups"
      grep -q normalizedPayload <<<"$m" && fail "can view message payloads" || pass "cannot view message payloads"
      note "Console error shown: $(grep -oE '"message":"[^"]*' <<<"$m" | head -1 | cut -c12-)" ;;
    dana)
      [[ $t -gt 0 ]] && pass "sees topics ($t credit-wallet.*)" || fail "sees no topics"
      grep -q normalizedPayload <<<"$m" && pass "can view message payloads" || fail "cannot view messages" ;;
  esac
  rm -f "$J"
done

summary
