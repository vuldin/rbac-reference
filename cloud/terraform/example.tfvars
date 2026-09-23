env             = "prod"
cluster_id      = "<cluster-id>"
cluster_api_url = "<cluster-api-url>"

observer_groups = ["Application - Redpanda - Prod - Observer"]
reader_groups   = ["Application - Redpanda - Prod - Reader"]
admin_groups    = ["Application - Redpanda - Prod - Admin"]

# Supply via TF_VAR_service_account_passwords from a secret store, not a file.
# service_account_passwords = { "svc-wallet-producer" = "...", "svc-wallet-consumer" = "..." }
