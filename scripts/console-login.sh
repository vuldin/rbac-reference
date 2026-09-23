#!/usr/bin/env bash
# Log in to Redpanda Console through Keycloak SSO the way a browser would, and
# leave the session cookie in a jar so Console's API can be called as that user.
#
#   scripts/console-login.sh <username> [password]   -> prints the cookie-jar path
set -euo pipefail
USER_NAME=$1; PASSWORD=${2:-password}
CONSOLE=http://localhost:8080
JAR=$(mktemp -t "console-$USER_NAME.XXXX")

# 1. Console redirects to Keycloak's authorization endpoint
auth_url=$(curl -s -c "$JAR" -b "$JAR" -o /dev/null -w '%{redirect_url}' "$CONSOLE/auth/login/oidc")
# 2. Keycloak login form
form=$(curl -s -c "$JAR" -b "$JAR" "$auth_url")
action=$(grep -oE 'action="[^"]+"' <<<"$form" | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
# 3. Submit credentials; follow redirects back through Console's callback
curl -s -c "$JAR" -b "$JAR" -L -o /dev/null \
  --data-urlencode "username=$USER_NAME" --data-urlencode "password=$PASSWORD" "$action"
# Keycloak may show a consent screen on first login (prompt=consent)
consent=$(curl -s -c "$JAR" -b "$JAR" "$auth_url")
if grep -q 'kc-login\|accept' <<<"$consent" && grep -q 'consent' <<<"$consent"; then
  caction=$(grep -oE 'action="[^"]+"' <<<"$consent" | head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  code=$(grep -oE 'name="code" value="[^"]+"' <<<"$consent" | sed -e 's/.*value="//' -e 's/"$//')
  curl -s -c "$JAR" -b "$JAR" -L -o /dev/null -d "code=$code" -d "accept=Yes" "$caction"
fi
echo "$JAR"
