# Copyright Red Hat
# SPDX-License-Identifier: Apache-2.0

output "cluster_id" {
  value       = module.hcp.cluster_id
  description = "ROSA HCP cluster ID."
}

output "cluster_api_url" {
  value       = module.hcp.cluster_api_url
  description = "Cluster API endpoint URL."
}

output "cluster_console_url" {
  value       = module.hcp.cluster_console_url
  description = "OpenShift web console URL."
}

output "cluster_domain" {
  value       = module.hcp.cluster_domain
  description = "Cluster base domain (e.g. xxxx.p3.openshiftapps.com)."
}

output "oidc_config_id" {
  value       = module.hcp.oidc_config_id
  description = "OIDC configuration ID."
}

output "oidc_endpoint_url" {
  value       = module.hcp.oidc_endpoint_url
  description = "OIDC endpoint URL."
}

output "account_role_prefix" {
  value       = module.hcp.account_role_prefix
  description = "Prefix used for account IAM roles."
}

output "operator_role_prefix" {
  value       = module.hcp.operator_role_prefix
  description = "Prefix used for operator IAM roles."
}

output "admin_password" {
  value       = random_password.password.result
  description = "Generated cluster-admin password."
  sensitive   = true
}
