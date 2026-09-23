variable "env" {
  description = "Environment prefix for role names, e.g. prod"
  type        = string
}

variable "cluster_id" {
  description = "Redpanda Cloud cluster ID (for Schema Registry ACLs)"
  type        = string
}

variable "cluster_api_url" {
  description = "Cluster data-plane API URL (redpanda_cluster.<x>.cluster_api_url)"
  type        = string
}

variable "observer_groups" {
  description = "IdP groups that get the Observer tier (metadata + lag, no messages)"
  type        = list(string)
  default     = []
}

variable "reader_groups" {
  description = "IdP groups that get the Reader tier (message contents). In prod, use a JIT/time-boxed group."
  type        = list(string)
  default     = []
}

variable "admin_groups" {
  description = "IdP groups that get break-glass data-plane admin"
  type        = list(string)
  default     = []
}

variable "service_account_passwords" {
  description = "SCRAM passwords keyed by service-account name (source from a secret store)"
  type        = map(string)
  sensitive   = true
  ephemeral   = true
}

variable "password_version" {
  description = "Increment to rotate service-account passwords"
  type        = number
  default     = 1
}

variable "allow_deletion" {
  description = "Allow terraform destroy of roles/ACLs/users"
  type        = bool
  default     = false
}
