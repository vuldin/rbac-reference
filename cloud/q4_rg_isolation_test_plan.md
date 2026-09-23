# Q4 test plan: resource-group isolation (Redpanda Cloud only)

Resource groups and control-plane role bindings exist only in Redpanda Cloud,
so this can't be tested in the local stack. Run it in your own org. It takes
about 20 minutes and needs no new clusters if dev and prod resource groups
already exist.

## Setup

1. Create two throwaway Okta groups: `rp-test-dev-only` and `rp-test-prod-only`.
   Put one test user in each, and a third test user in neither.
2. Register both groups in **Organization IAM → Groups**.
3. Bind `Reader` (or your custom Observer role) to:
   - `rp-test-dev-only` at the **dev** resource-group scope.
   - `rp-test-prod-only` at the **prod** resource-group scope.
4. Make sure none of the three test users is in any **Organization-scoped**
   group. The union of bindings would hide the result (see `tests/q4_union.sh`).

## Checks

Log in as each test user in a private browser window.

| Check | dev-only user | prod-only user | no-group user |
|---|---|---|---|
| Clusters list shows dev clusters | ✅ | ❌ | ❌ |
| Clusters list shows prod clusters | ❌ | ✅ | ❌ |
| Direct URL to a prod cluster page (copy it from the prod user) | denied | ✅ | denied |
| `GET /v1/clusters` with the user's token lists only in-scope clusters | dev only | prod only | none |
| Networks / network peerings in the other RG are hidden | ✅ | ✅ | ✅ |
| Audit / org-level pages (Billing, IAM) are hidden | ✅ | ✅ | ✅ |

Record what you see for each row. The direct-URL row matters most: hiding
something in the UI isn't the same as enforcing access to it.

## Also check

- **Data plane is still separate.** A control-plane Viewer with no data-plane
  role should see topic names, but reading messages should fail. This matches
  `tests/q2_tiers.sh` locally.
- **Removal latency.** Remove the dev-only user from the Okta group, and time
  how long it takes their Cloud Console session to lose access. Compare with
  `tests/q3_token_window.sh`, which covers the data plane.
