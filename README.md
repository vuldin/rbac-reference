# Redpanda Cloud RBAC/GBAC reference tested locally

A reproducible lab for checking a group-based access model for Redpanda
Cloud (BYOC/Dedicated) before you roll it out. It targets a multi-environment
estate where prod holds sensitive data (e.g. PHI), humans come in through
Okta SSO, and workloads use service accounts.

Every claim in this README links to a script that proves it against a real
Redpanda broker, Redpanda Console and an OIDC identity provider (Keycloak,
standing in for Okta). No managed cluster needed.

From the repo root:

```bash
docker compose up -d --wait  # first run pulls ~1 GB of images; ~1 min after that
./scripts/apply-model.sh     # roles, ACLs, groups, service accounts, seed data (~25s)
./scripts/run-all.sh         # ~5 min; prints PASS / FAIL / FINDING per check
docker compose down -v       # tear down
```

## Prerequisites

| Need | Notes |
|---|---|
| Docker with Compose v2 | `--wait` needs Compose v2. Tested with Docker 29.8, Compose v5.5 |
| `rpk` on your `PATH` | The scripts run `rpk` on the host. Tested with v26.2.1; [install rpk](https://docs.redpanda.com/current/get-started/rpk-install/) |
| `bash`, `curl`, `jq`, `python3`, `timeout` (coreutils) | On macOS, `timeout` comes from `brew install coreutils` (`gtimeout`); see below |
| ~5 GB free RAM, ~2 GB disk | Redpanda uses ~3.8 GB, Keycloak ~0.9 GB |
| Free host ports | `8080` (Console), `8180` (Keycloak), `19092` (Kafka), `18081` (Schema Registry), `19644` (Admin API) |
| Internet on first run | Pulls Redpanda, Console, Keycloak and socat images and builds a small Python client image |

Tested on Linux x86_64. macOS and arm64 should work (all images are
multi-arch) but haven't been tested; on macOS, make sure `timeout` resolves
(e.g. `alias timeout=gtimeout`) before running the scripts.

The scripts are bash. If your shell is zsh, run them as `./scripts/...` (they
have a bash shebang), and start `bash` before `source scripts/lib.sh` in the
runbook.

For a hands-on walkthrough as each user, see **[RUNBOOK.md](RUNBOOK.md)**.
For results and issues found, see **[FINDINGS.md](FINDINGS.md)**.

## What local testing can and can't prove

Redpanda Cloud authorizes access in two places:

- **Control plane:** who can see and manage orgs, resource groups, clusters and
  networks. Custom roles and resource-group-scoped role bindings. **Cloud only.**
- **Data plane:** who can read and write topics, consumer groups, transactional
  IDs and Schema Registry subjects. ACLs, roles and `Group:` principals. **Same
  engine as self-managed Redpanda**, so this repo tests it directly.

| Question | Local? | Where |
|---|---|---|
| 1. Two-role read tier (Viewer + `<env>_reader`) | Data-plane half | `tests/q2_tiers.sh` |
| 2. Can an Observer see lag without reading messages? | yes (ACL level) | `tests/q2_tiers.sh`, `tests/console_impersonation.sh` |
| 3. Is expiring IdP group membership OK for time-bound PHI read? | yes | `tests/q3_token_window.sh` |
| 4. Does a resource-group binding isolate prod? | no, cloud only; the union risk is tested | `cloud/q4_rg_isolation_test_plan.md`, `tests/q4_union.sh` |
| 5. Managing access as code | Partly | `cloud/terraform/`, `cloud/controlplane-api/` |
| 6. Read-only Schema Registry grant | yes | `tests/q6_schema_registry.sh` |
| 7. Break-glass and audit | yes | `tests/q7_audit.sh` |
| 8. Over- or under-scoped service accounts / group names | yes | `tests/q8_service_accounts.sh` |
| (not asked) IdP signing-key rotation | yes | `tests/jwks_rotation.sh` |

## Answers

**1. Two-role read tier.** Yes, that's the intended pattern. On BYOC/Dedicated
the predefined Reader/Writer/Admin roles include data-plane permissions, so
"console, no messages" needs a custom role with only Control Plane
permissions. The reader tier's data-plane half is a per-cluster Redpanda role
with IdP groups as members. Data-plane roles are cluster-scoped (`cloud/terraform/` is written to be
applied per cluster).

**2. Lag without messages.** On the data plane, `DESCRIBE` on topics and
consumer groups is enough to see lag, and `READ` isn't needed. Verified with
rpk and through Console with user impersonation. In a
local Console, an Observer who opens the Messages tab gets *"request was
cancelled while waiting for messages"*, not a clear permission error.

**3. Time-bound PHI read.** Expiring Okta group membership works, but
revocation isn't instant. The groups claim is read from the token at
authentication, so a token issued before removal keeps working, on new
connections too, until it expires. A new token is denied immediately. Keep the
Redpanda Okta app's access-token lifetime short (e.g. 5–15 min, versus Okta's
1h default). `oidc_token_expire_disconnect: true` cuts long-lived connections
at expiry.

**4. Resource-group isolation.** A Cloud control-plane question; use the test
plan in `cloud/`. Keep in mind that bindings are a union. If the old Organization-scoped Reader/Writer/Admin
groups are still bound, an Observer silently becomes a Reader. Removing them is
part of the cutover.

**5. Access as code.** The `redpanda` Terraform provider (v2.4.0) covers the
data plane: `redpanda_role`, `redpanda_role_assignment` (`Group:`
principals supported), `redpanda_acl` and `redpanda_schema_registry_acl`. It
has no resource for control-plane custom roles or group role bindings
(`redpanda_service_account` can carry bindings at creation only). The provider
docs refer to a `redpanda_role_binding` resource that isn't in v2.4.0 yet. For
now, use the Control Plane API (`/v1/roles`, `/v1/role-bindings`); see
`cloud/controlplane-api/`.

**6. Schema Registry read-only.** The proposed `subject: Read, Describe` +
`registry: Describe` can't read compatibility settings. Add
`DescribeConfigs` on subject and registry which matches the predefined
Reader. Make sure `schema_registry_enable_authorization` is on. With it
off, a user with no ACLs at all can delete subjects.

**7. Break-glass and audit.** Use the Okta group with approval, a short
duration and an alert on membership changes. On the cluster, add `consume` to
`audit_enabled_event_types`. Each human fetch is then logged with the user,
the role and exact ACL that authorized it, the topic, the source IP, and
denied attempts too. The audit topic keeps 7 days, so ship it to your
SIEM/Datadog. See FINDINGS.md for a known issue with `audit_excluded_principals`.

**8. Scoping.**
- Consumers need READ on their consumer group (prefixed works), not just
  the topic.
- `IDEMPOTENT_WRITE` isn't needed; topic `WRITE` is enough for idempotent
  producers.
- Transactional producers need `TRANSACTIONAL_ID` WRITE+DESCRIBE, and a prefix
  pattern works.
- Okta group names with spaces work as `Group:` principals.
- Prefixed topic ACLs cover new topics with no ACL change.

## Layout

```
docker-compose.yml       Redpanda v26.2, Console v3.11 (OIDC + impersonation), Keycloak, test client
redpanda/                broker config + cluster bootstrap (each setting commented)
keycloak/realm.json      Okta-shaped IdP: users, groups, groups claim, audience
console/config.yaml      Console SSO with impersonation on Kafka, SR and Admin API
scripts/apply-model.sh   the access model (mirrors cloud/terraform)
scripts/run-all.sh       all tests
scripts/console-login.sh scripted browser SSO login (used by tests)
tests/                   one script per question
clients/probe.py         transactional/idempotent client probe
cloud/terraform/         per-cluster data-plane model for Redpanda Cloud (validated, not applied)
cloud/controlplane-api/  custom Observer role + RG binding via API (dry-run by default)
cloud/q4_rg_isolation_test_plan.md
```

## Notes

- **License:** new clusters get a built-in 30-day Enterprise trial, which
  covers RBAC, GBAC, OIDC, audit logging, SR authorization and Console SSO.
  `docker compose down -v` resets it.
- **Self-managed pitfall:** with `authentication_method: sasl` on listeners,
  you must also set `kafka_enable_authorization: true`, or every authenticated
  user can read everything.
- **rpk v26.2.1** (the version tested) can't assign `Group:` principals to
  roles (it calls a v1 endpoint that only accepts users). The scripts use the Admin API v2 `SecurityService` directly.
- **Keycloak** runs on port 80 inside the Docker network. With it on 8080,
  the discovery document came back with a `keycloak:80` JWKS URL. Redpanda's
  discovery request appears to omit the port from `Host`, and Keycloak builds
  backchannel URLs from that header. Harmless with Okta (HTTPS on 443).

## License

[Apache License 2.0](LICENSE)
