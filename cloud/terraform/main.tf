# Data-plane access model for ONE Redpanda Cloud BYOC/Dedicated cluster.
#
# Data-plane roles, ACLs and SASL users are cluster-scoped: apply this once per
# cluster (one workspace, or one module call per cluster). It mirrors
# scripts/apply-model.sh, which is what the local tests exercise.
#
# Status: `terraform validate` passes against redpanda-data/redpanda v2.4.0.
# Not applied against a live Cloud cluster in this repo.
#
# Control-plane custom roles and IdP-group role bindings are NOT covered: the
# provider (v2.4.0) has no resource for them. See ../controlplane-api/.

terraform {
  required_version = ">= 1.11"
  required_providers {
    redpanda = {
      source  = "redpanda-data/redpanda"
      version = "~> 2.4"
    }
  }
}

provider "redpanda" {}

locals {
  api = var.cluster_api_url

  # Human tiers: role -> IdP groups (Okta group names, exactly as they appear in
  # the token's groups claim; spaces are fine — see tests/q8_service_accounts.sh)
  human_roles = {
    observer = { groups = var.observer_groups }
    reader   = { groups = var.reader_groups }
    admin    = { groups = var.admin_groups }
  }

  # role, resource_type, resource_name, pattern, operation
  kafka_acls = concat(
    [for op in ["DESCRIBE", "DESCRIBE_CONFIGS"] : ["observer", "TOPIC", "*", "LITERAL", op]],
    [["observer", "GROUP", "*", "LITERAL", "DESCRIBE"]],

    [for op in ["DESCRIBE", "DESCRIBE_CONFIGS", "READ"] : ["reader", "TOPIC", "*", "LITERAL", op]],
    [["reader", "GROUP", "*", "LITERAL", "DESCRIBE"]],
    [["reader", "GROUP", "adhoc-", "PREFIXED", "READ"]],

    [for t in ["TOPIC", "GROUP", "TRANSACTIONAL_ID"] : ["admin", t, "*", "LITERAL", "ALL"]],
    [["admin", "CLUSTER", "kafka-cluster", "LITERAL", "ALL"]],

    [for op in ["WRITE", "DESCRIBE"] : ["wallet_producer", "TOPIC", "credit-wallet.", "PREFIXED", op]],
    [for op in ["WRITE", "DESCRIBE"] : ["wallet_producer", "TRANSACTIONAL_ID", "credit-wallet-", "PREFIXED", op]],

    [for op in ["READ", "DESCRIBE"] : ["wallet_consumer", "TOPIC", "credit-wallet.", "PREFIXED", op]],
    [for op in ["READ", "DESCRIBE"] : ["wallet_consumer", "GROUP", "credit-wallet-", "PREFIXED", op]],
  )

  # role, resource_type (SUBJECT|REGISTRY), resource_name, pattern, operation
  sr_acls = concat(
    [for op in ["READ", "DESCRIBE", "DESCRIBE_CONFIGS"] : ["reader", "SUBJECT", "*", "LITERAL", op]],
    [for op in ["DESCRIBE", "DESCRIBE_CONFIGS"] : ["reader", "REGISTRY", "*", "LITERAL", op]],
    [["admin", "SUBJECT", "*", "LITERAL", "ALL"], ["admin", "REGISTRY", "*", "LITERAL", "ALL"]],
    [for op in ["READ", "WRITE", "DESCRIBE"] : ["wallet_producer", "SUBJECT", "credit-wallet.", "PREFIXED", op]],
    [for op in ["READ", "DESCRIBE"] : ["wallet_consumer", "SUBJECT", "credit-wallet.", "PREFIXED", op]],
  )

  service_accounts = {
    svc-wallet-producer = "wallet_producer"
    svc-wallet-consumer = "wallet_consumer"
  }

  all_roles = toset(concat(keys(local.human_roles), distinct(values(local.service_accounts))))

  group_assignments = merge([
    for role, cfg in local.human_roles : { for g in cfg.groups : "${role}:${g}" => { role = role, group = g } }
  ]...)
}

resource "redpanda_role" "this" {
  for_each        = local.all_roles
  name            = "${var.env}_${each.key}"
  cluster_api_url = local.api
  allow_deletion  = var.allow_deletion
}

resource "redpanda_acl" "kafka" {
  for_each = { for a in local.kafka_acls : join("|", a) => a }

  principal             = "RedpandaRole:${redpanda_role.this[each.value[0]].name}"
  resource_type         = each.value[1]
  resource_name         = each.value[2]
  resource_pattern_type = each.value[3]
  operation             = each.value[4]
  permission_type       = "ALLOW"
  host                  = "*"
  cluster_api_url       = local.api
  allow_deletion        = var.allow_deletion
}

resource "redpanda_schema_registry_acl" "sr" {
  for_each = { for a in local.sr_acls : join("|", a) => a }

  cluster_id     = var.cluster_id
  principal      = "RedpandaRole:${redpanda_role.this[each.value[0]].name}"
  resource_type  = each.value[1]
  resource_name  = each.value[2]
  pattern_type   = each.value[3]
  operation      = each.value[4]
  permission     = "ALLOW"
  host           = "*"
  allow_deletion = var.allow_deletion
}

# GBAC: IdP groups as role members. Note tests/q6_schema_registry.sh — on
# self-managed v26.2.2, Group: principals were NOT honoured by Schema Registry
# over OIDC bearer auth. Verify in Cloud before relying on this for SR access.
resource "redpanda_role_assignment" "groups" {
  for_each        = local.group_assignments
  role_name       = redpanda_role.this[each.value.role].name
  principal       = "Group:${each.value.group}"
  cluster_api_url = local.api
}

resource "redpanda_user" "svc" {
  for_each            = local.service_accounts
  name                = each.key
  password_wo         = var.service_account_passwords[each.key]
  password_wo_version = var.password_version
  mechanism           = "scram-sha-256"
  cluster_api_url     = local.api
  allow_deletion      = var.allow_deletion
}

resource "redpanda_role_assignment" "svc" {
  for_each        = local.service_accounts
  role_name       = redpanda_role.this[each.value].name
  principal       = "User:${redpanda_user.svc[each.key].name}"
  cluster_api_url = local.api
}
