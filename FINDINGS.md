# Findings

Environment: Redpanda **v26.2.2**, Redpanda Console **v3.11.0**, Keycloak
26.0, rpk v26.2.1 on the host, built-in 30-day Enterprise trial. Results come
from a clean `docker compose down -v && up` followed by
`scripts/apply-model.sh && scripts/run-all.sh`.

## Results

| Test | Passed | Failed | Findings |
|---|---|---|---|
| `q2_tiers` | 11 | 0 | 0 |
| `q3_token_window` | 4 | 0 | 0 |
| `q4_union` | 3 | 0 | 0 |
| `q6_schema_registry` | 15 | 0 | 0 |
| `q7_audit` | 4 | 0 | 1 (issue 1) |
| `q8_service_accounts` | 11 | 0 | 0 |
| `console_impersonation` | 10 | 0 | 0 |
| `jwks_rotation` | 2 | 0 | 1 (issue 2) |
| **Total** | **60** | **0** | **2** |

`FINDING` means verified behaviour that contradicts the docs or a reasonable
expectation. It's reported separately and doesn't count as a test failure.

## Issues found

### 1. `audit_excluded_principals` is ignored at startup (bug)

**What:** a value loaded when the broker starts, whether from
`.bootstrap.yaml` or persisted from an earlier runtime change, has no effect.
Excluded principals keep being audited. The list only starts working once the
property is **changed** at runtime. Setting the same value again doesn't help.
It stops working again at the next restart.

**Reproduce:** `tests/q7_audit.sh` restarts the broker and checks both cases.

| Step | svc-wallet-consumer audit events |
|---|---|
| Fresh cluster, list set in `.bootstrap.yaml` | 9 |
| After broker restart | 14 |
| Same value re-set at runtime (no-op) | 9 |
| Value **changed** at runtime | **0** |
| Broker restart (value persisted) | 9 |

**Impact:** fails safe. You get more auditing, not less. But on Cloud,
maintenance restarts would quietly re-enable auditing of high-volume service
accounts, which raises audit volume and SIEM cost. **Workaround:** after each
restart, set a temporary value, then the real one.

### 2. JWKS isn't re-fetched on an unknown `kid`

**What:** Redpanda caches the IdP's signing keys for
`oidc_keys_refresh_interval` (default **3600s**). When a token arrives signed
with a key it hasn't seen, it rejects the token and doesn't refresh.

**Reproduce:** `tests/jwks_rotation.sh` adds a higher-priority key in the IdP.
OIDC logins then fail (`security::oidc::errc:6`) until the cache refreshes.
Changing `oidc_keys_refresh_interval` triggers an immediate refresh.

**Impact:** Okta publishes upcoming keys in its JWKS before it uses them, so
routine rotations should be fine. An **emergency key rotation** would cause an
OIDC outage of up to an hour for every human and OIDC workload.
**Mitigation:** a shorter interval (this lab uses 300s), and a runbook step:
"after an emergency IdP key rotation, change `oidc_keys_refresh_interval`."

### 3. Authorization is off unless explicitly enabled (self-managed pitfall)

With `authentication_method: sasl` set per listener but `enable_sasl: false`,
`kafka_enable_authorization` stays `null`, which means **off**. An
authenticated user with no ACLs (`nora`) could list and read every topic.
Fixed in `redpanda/bootstrap.yaml` with `kafka_enable_authorization: true`.
This probably doesn't apply to Cloud-managed clusters, but it's worth one
check on a Cloud cluster: a user with no ACLs should get an empty `rpk topic list`.

### 4. Console shows an unclear error when message read is denied

An Observer (DESCRIBE, no READ) who opens **Messages** in Console v3.11 sees
*"request was cancelled while waiting for messages"*, not an authorization
error. Access is correctly denied, but users will read it as a bug or a
timeout. Worth a Console UX ticket.

### 5. `rpk security role assign --principal Group:<name>` fails (rpk v26.2.1)

```
Role membership reserved for user principals, got {Group:rp-prod-reader}  (40001)
```

rpk calls `POST /v1/security/roles/<role>/members`, which only accepts users.
The Admin API v2 `SecurityService/AddRoleMembers` works, and so does the
Terraform `redpanda_role_assignment` resource (a different API). Not retested
with a newer rpk.

### 6. Terraform provider: no control-plane role or binding resources

v2.4.0 (the latest published at the time of testing) has no resource for
control-plane custom roles or for binding groups or users to roles. The
registry docs for `redpanda_service_account` tell you to "manage grants after
creation with the `redpanda_role_binding` resource", which doesn't exist in
v2.4.0. It looks like it's on the way; confirm with the provider team.

## Withdrawn

- **"GBAC doesn't apply on Schema Registry with OIDC bearer."** Seen on my
  first stack, where Keycloak issued tokens with no `sub` claim (a
  realm-import mistake that dropped the built-in client scopes). It didn't
  reproduce on a clean stack with standard tokens: `Group:` → role works on
  Schema Registry. The `sub` claim is the likely cause, but I haven't verified
  it.
- **"`User:` prefix is ignored in `audit_excluded_principals`."** The real
  cause is issue 1. Both `User:name` and `name` work when the value changes at
  runtime.

## Not verified here (Cloud only)

- What a control-plane-only custom Viewer sees inside the **Cloud** Console
  (topic list, metrics, lag). The data-plane equivalent is verified in
  `tests/q2_tiers.sh`.
- Whether resource-group-scoped bindings fully confine the Cloud Console and
  API. See `cloud/q4_rg_isolation_test_plan.md`.
- Whether a registered IdP group's ID is accepted as `account_id` in
  `POST /v1/role-bindings` (assumed by `cloud/controlplane-api/observer-role.sh`).
- Control-plane permission names: the script derives them from the built-in
  Reader role rather than hard-coding them.
- Native time-bound role bindings: none found in the docs or API reference.
