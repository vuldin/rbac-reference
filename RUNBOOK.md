# Runbook: verify each identity has only its expected access

Walk through logging in as every identity in the model and check that each one
can do what it should and nothing more. Every step has a **Console** path
(browser SSO) and a **CLI** path. The expected results below match what
`scripts/run-all.sh` asserts.

> The automated tests cover all of this. Use the runbook for a live
> walkthrough with a customer, or to see the behaviour for yourself.
> A full manual pass takes about 15 minutes, including one 70-second wait.

## 0. Setup

Check the [prerequisites in the README](README.md#prerequisites) first
(Docker, `rpk`, `jq`, `curl`, free ports, ~5 GB RAM). Run everything from the
**repo root**; the paths below are relative.

```bash
docker compose up -d --wait        # skip these two if you already ran the README quick start
./scripts/apply-model.sh           # (both are safe to re-run)
bash                               # the helpers are bash; start bash if your shell is zsh
source scripts/lib.sh
```

`scripts/lib.sh` defines everything the commands below use:

| Helper | What it does |
|---|---|
| `kc_token <user>` | Gets an OIDC access token from Keycloak (password `password`), as SSO would |
| `jwt_claims <token>` | Decodes a token's claims |
| `rpk_oidc <token> <rpk args>` | Runs `rpk` as that human (OAUTHBEARER) |
| `rpk_admin <rpk args>` | Runs `rpk` as the bootstrap superuser (`admin` / `admin-secret`) |
| `kc_api <path> [curl args]` | Calls the Keycloak admin REST API for realm `acme` |
| `$SR_URL` | `http://localhost:18081` (Schema Registry) |

Run each section's commands in the **same** bash session: later rows reuse
the `$T` token set at the top of the section. Tokens live 60 seconds; if a
command suddenly fails with `SASL_AUTHENTICATION_FAILED`, re-run the
section's `T=...` line.

| Service | URL | Credentials |
|---|---|---|
| Redpanda Console | http://localhost:8080 | SSO as any user below (realm `acme`) |
| Keycloak (IdP, stands in for Okta) | http://localhost:8180/admin | `admin` / `admin`; users live in realm **`acme`** |
| Kafka API | `localhost:19092` | OIDC token or SCRAM |
| Schema Registry | http://localhost:18081 | OIDC bearer or HTTP basic |
| Admin API | http://localhost:19644 | `admin` / `admin-secret` |

**Logging in to Console:** open http://localhost:8080 and choose the
**SSO / OIDC** login option. The Console also offers a username/password form;
that's basic auth for SCRAM users and isn't part of this walkthrough. The
browser is redirected to Keycloak at `localhost:8180`, so that port must be
reachable from the browser. Sign in with one of the users below and the
password `password`. Accept the consent screen if Keycloak shows one.

Use a **new private/incognito window for each user**. Keycloak keeps an SSO
session, so logging out of Console alone may sign you straight back in as the
previous user.

### Identities

| User | IdP group(s) | Redpanda role | Tier |
|---|---|---|---|
| `nora` | none | none | Authenticated only: should see nothing |
| `olivia` | `rp-prod-observer` | `prod_observer` | Observer: metadata + lag, **no messages** |
| `dana` | `rp-prod-reader` | `prod_reader` | Reader: + message contents (the JIT/PHI group) |
| `sam` | `Application - Redpanda - Prod - Reader` | `prod_reader` | Reader, via an Okta-style group name with spaces |
| `alex` | `rp-prod-admin` | `prod_admin` | Break-glass admin |
| `svc-wallet-producer` | n/a (SCRAM) | `wallet_producer` | Writes `credit-wallet.*` |
| `svc-wallet-consumer` | n/a (SCRAM) | `wallet_consumer` | Reads `credit-wallet.*` in `credit-wallet-*` groups |
| `svc-scribe-producer` | n/a (SCRAM) | `scribe_producer` | Writes `ml-scribe.*` |

To see a user's token claims (what Redpanda actually evaluates):

```bash
jwt_claims "$(kc_token olivia)" | jq '{preferred_username, groups, aud, exp}'
```

---

## 1. nora: authenticated, no groups

```bash
T=$(kc_token nora)
```

**Expect:** she can log in but sees nothing, and every read is denied.

| Check | Console | CLI | Expected |
|---|---|---|---|
| Log in | Sign in via SSO as `nora` | (the `T=` line above) | ✅ succeeds |
| Topic list | **Topics** page | `rpk_oidc "$T" topic list` | Header row only |
| Consumer groups | **Consumer Groups** page | `rpk_oidc "$T" group list` | Header row only |
| Read messages | n/a (no topics visible) | `rpk_oidc "$T" topic consume credit-wallet.ledger -n 1 -o start` | ❌ `unable to check topic existence: TOPIC_AUTHORIZATION_FAILED` |
| Schemas | **Schema Registry** page | `curl -s -H "Authorization: Bearer $T" $SR_URL/subjects` | `[]` |

## 2. olivia: Observer

```bash
T=$(kc_token olivia)
```

**Expect:** topics, configs and consumer-group lag are visible. Message
contents are not.

| Check | Console | CLI | Expected |
|---|---|---|---|
| Topic list | **Topics** | `rpk_oidc "$T" topic list` | ✅ all topics, including `_schemas` and `_redpanda.audit_log` |
| Topic config | Topic → **Configuration** | `rpk_oidc "$T" topic describe credit-wallet.ledger -c` | ✅ |
| Consumer lag | **Consumer Groups** → `credit-wallet-balance-svc` | `rpk_oidc "$T" group describe credit-wallet-balance-svc` | ✅ `TOTAL-LAG 20` on a fresh cluster (higher once section 6 or `run-all.sh` has produced more records) |
| Read messages | Topic → **Messages** | see the command below the table | ❌ CLI prints `TOPIC_AUTHORIZATION_FAILED` for each partition and keeps retrying, because olivia can see the topic metadata. Console shows **"request was cancelled while waiting for messages"**, not a clear permission error. Expect users to ask about it. |
| Schemas | **Schema Registry** | `curl -s -H "Authorization: Bearer $T" $SR_URL/subjects` | `[]` (Observer has no SR grants) |

Read messages (CLI). rpk retries forever here, so pipe it through `timeout`,
which can't wrap `rpk_oidc` directly because it's a shell function:

```bash
rpk_oidc "$T" topic consume credit-wallet.ledger -n 1 -o start 2>&1 | timeout 10 cat
```

This is Q2 answered on the data plane: **DESCRIBE on topics and groups is
enough for lag. READ is not needed.**

## 3. dana: Reader (the JIT/PHI group)

```bash
T=$(kc_token dana)
```

**Expect:** Observer access plus message contents and read-only schemas.
No writes.

| Check | Console | CLI | Expected |
|---|---|---|---|
| Read messages | Topic → **Messages** | `rpk_oidc "$T" topic consume credit-wallet.ledger -n 1 -o start` | ✅ payload shown |
| Produce | Topic → **Produce record** | `rpk_oidc "$T" topic produce credit-wallet.ledger <<< x` | ❌ `CLUSTER_AUTHORIZATION_FAILED` |
| Delete a topic | Topic → **Delete** | `rpk_oidc "$T" topic delete other-team.orders` | ❌ `Authorized to describe but not allowed to delete this topic` (note that rpk still exits 0) |
| Read a schema | **Schema Registry** → `credit-wallet.ledger-value` | `curl -s -H "Authorization: Bearer $T" $SR_URL/subjects/credit-wallet.ledger-value/versions/latest` | ✅ schema version 1 |
| Read compatibility | Subject → compatibility setting | `curl -s -H "Authorization: Bearer $T" $SR_URL/config` | ✅ `{"compatibilityLevel":"BACKWARD"}` |
| Change compatibility | Subject → **Edit compatibility** | `curl -s -X PUT -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"compatibility":"NONE"}' $SR_URL/config` | ❌ `403 Forbidden (missing required ACLs)` |
| Register a schema version | Subject → **Add version** | `curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"schemaType":"JSON","schema":"{\"type\":\"object\"}"}' $SR_URL/subjects/credit-wallet.ledger-value/versions` | ❌ 403 |
| Delete a subject | Subject → **Delete** | `curl -s -X DELETE -H "Authorization: Bearer $T" $SR_URL/subjects/credit-wallet.ledger-value` | ❌ 403 |

### 3a. Revoke dana's access (JIT expiry) and watch the window

This is the most important walkthrough for a PHI tier (Q3). Run it in one go:
the timing matters.

1. Get a token and confirm dana can read:
   ```bash
   T1=$(kc_token dana); rpk_oidc "$T1" topic consume credit-wallet.ledger -n 1 -o start
   ```
2. Remove her from the group. Either use the **Keycloak admin UI**
   (http://localhost:8180/admin → realm `acme` → Users → `dana` → Groups →
   select `rp-prod-reader` → **Leave**), or the API:
   ```bash
   U=$(kc_api "/users?username=dana&exact=true" | jq -r '.[0].id')
   G=$(kc_api "/groups?search=rp-prod-reader&exact=true" | jq -r '.[]|select(.name=="rp-prod-reader")|.id')
   kc_api "/users/$U/groups/$G" -X DELETE
   ```
3. A **new** token is denied immediately:
   ```bash
   rpk_oidc "$(kc_token dana)" topic consume credit-wallet.ledger -n 1 -o start   # ❌ TOPIC_AUTHORIZATION_FAILED
   ```
4. The **old** token still reads, even on a new connection, until it expires
   (60s in this lab; Okta's default is 1h):
   ```bash
   rpk_oidc "$T1" topic consume credit-wallet.ledger -n 1 -o start               # ✅ still works
   ```
5. Wait until a few seconds past the token's expiry, then try again. Redpanda
   allows a few seconds of clock skew, so allow ~10s margin:
   ```bash
   echo "expires in $(( $(jwt_claims "$T1" | jq .exp) - $(date +%s) ))s"; sleep 70
   rpk_oidc "$T1" topic consume credit-wallet.ledger -n 1 -o start               # ❌ SASL_AUTHENTICATION_FAILED ... Invalid credentials
   ```
6. In Console, dana's existing session behaves the same way until its token
   expires. Sign in again to pick up the new group membership.
7. Restore her, and check that a new token reads again:
   ```bash
   kc_api "/users/$U/groups/$G" -X PUT
   rpk_oidc "$(kc_token dana)" topic consume credit-wallet.ledger -n 1 -o start   # ✅
   ```

**Takeaway:** revocation latency is the remaining lifetime of tokens already
issued. Keep the access-token lifetime short for the Redpanda Okta app.

## 4. sam: Reader, via a group name with spaces

```bash
T=$(kc_token sam)
jwt_claims "$T" | jq .groups   # ["Application - Redpanda - Prod - Reader"]
```

Repeat the section 3 table with this `$T`. The expected results are the same
as dana's. This confirms that `Group:Application - Redpanda - Prod - Reader`
resolves exactly as written in the token.

## 5. alex: break-glass admin

```bash
T=$(kc_token alex)
```

**Expect:** full data-plane access, with every action audited.

| Check | CLI | Expected |
|---|---|---|
| Read messages | `rpk_oidc "$T" topic consume credit-wallet.ledger -n 1 -o start` | ✅ |
| Create a topic | `rpk_oidc "$T" topic create bg-probe` | ✅ `OK` |
| Delete it | `rpk_oidc "$T" topic delete bg-probe` | ✅ `OK` |
| It's audited | see section 7 | ✅ `alex` appears with role `prod_admin` |

Note: `prod_admin` is a role with ALL ACLs, not a superuser. Cluster-config
changes still need a superuser. In Cloud, that's a control-plane Admin.

## 6. Service accounts (SCRAM)

`rpk` can't run a transactional producer, so these checks use a small Python
probe in the `clients` container. It prints `{"ok": true, ...}` or
`{"ok": false, "error": "..."}`.

```bash
P() { docker exec clients python /app/probe.py "$@"; }
WP="--user svc-wallet-producer --password svc-wallet-producer-secret"
WC="--user svc-wallet-consumer --password svc-wallet-consumer-secret"
```

| Check | Command | Expected |
|---|---|---|
| Produce in prefix | `P produce $WP --topic credit-wallet.ledger` | ✅ |
| Produce outside prefix | `P produce $WP --topic other-team.orders` | ❌ `TOPIC_AUTHORIZATION_FAILED` |
| New topic under prefix, no ACL change | `rpk_admin topic create credit-wallet.refunds` then `P produce $WP --topic credit-wallet.refunds` | ✅ (the create fails with `TOPIC_ALREADY_EXISTS` on a rerun; that's fine) |
| Idempotent producer without `IDEMPOTENT_WRITE` | `P produce $WP --topic credit-wallet.ledger --idempotent` | ✅ (so `IDEMPOTENT_WRITE` isn't needed) |
| Transactional id in prefix | `P produce $WP --topic credit-wallet.ledger --idempotent --txn-id credit-wallet-tx-1` | ✅ |
| Transactional id outside prefix | `P produce $WP --topic credit-wallet.ledger --idempotent --txn-id rogue-tx` | ❌ `TRANSACTIONAL_ID_AUTHORIZATION_FAILED` |
| Consume in its group prefix | `P consume $WC --topic credit-wallet.ledger --group credit-wallet-balance-svc` | ✅ |
| Consume with another group | `P consume $WC --topic credit-wallet.ledger --group analytics-adhoc` | ❌ `GROUP_AUTHORIZATION_FAILED` |

## 7. Audit: confirm who read what

With `consume` enabled, every human fetch is recorded, including which role
and which ACL authorized it, and denied attempts too.

```bash
rpk_admin topic consume _redpanda.audit_log -o start -f '%v\n' | timeout 10 cat \
  | jq -r 'select(.class_uid==6003 and .api.operation=="fetch")
           | [.actor.user.name, (.actor.user.groups // [] | map(.name) | join(",")),
              .resources[0].name, .actor.authorizations[0].decision, .src_endpoint.ip] | @tsv' \
  | sort | uniq -c
```

Expected:
- `dana`, `sam` and `alex` appear as `authorized`, with their role in the second column.
- `olivia` appears as `denied`.
- `admin ... _redpanda.audit_log authorized` rows also appear. That's this
  query auditing itself, and the count grows each time you run it.
- `nora` has no `fetch` rows: she's denied earlier, at metadata. To see her
  attempts, drop the `.api.operation=="fetch"` filter.
- Service accounts should **not** appear. They're excluded.

The query reads the whole audit topic (`-o start`), so it shows history, not
just what you did. **After `run-all.sh`** you'll also see:
- `svc-wallet-consumer` rows. The audit test restarts the broker and generates
  them on purpose to demonstrate FINDINGS.md issue 1. They stay in the topic.
- `olivia` **authorized** via `legacy_org_reader`, from the union test (q4).
- A second source IP: the Console container's, from the Console test.

**Checking the service-account exclusion is active now:** note the
`svc-wallet-consumer` count, run the section 6 "Consume in its group prefix"
command, run the query again, and confirm the count hasn't grown. If it has
grown, the exclusion was lost. A known issue (FINDINGS.md issue 1) means the
startup value of `audit_excluded_principals` is ignored until it's changed at
runtime, and every broker restart undoes the change. Re-run
`./scripts/apply-model.sh` (which applies the workaround and is safe to re-run),
then check again.

## 8. Reset

```bash
docker compose down -v    # wipes the cluster; the next `up` gets a fresh 30-day trial license
```
