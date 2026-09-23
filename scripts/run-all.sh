#!/usr/bin/env bash
# Runs every local test in order and prints a combined summary.
set -uo pipefail
cd "$(dirname "$0")/.."

tests=(q2_tiers q3_token_window q4_union q6_schema_registry q7_audit q8_service_accounts console_impersonation jwks_rotation)
declare -A result
for t in "${tests[@]}"; do
  printf '\n\033[1;34m######## %s ########\033[0m\n' "$t"
  out=$(./tests/$t.sh 2>&1); rc=$?
  echo "$out"
  result[$t]="$(tail -1 <<<"$out")$([[ $rc -ne 0 ]] && echo '  <-- FAILED')"
done

# q7 restarts the broker, which drops the runtime audit-exclusion workaround
./scripts/apply-model.sh >/dev/null 2>&1

printf '\n\033[1m======== Summary ========\033[0m\n'
for t in "${tests[@]}"; do printf '%-24s %s\n' "$t" "${result[$t]}"; done
! grep -q FAILED <<<"${result[*]}"
