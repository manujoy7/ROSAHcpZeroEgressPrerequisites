# Copyright Red Hat
# SPDX-License-Identifier: Apache-2.0
#
# ROSA HCP Zero Egress — BYO VPC Example
# No VPC module — customer provides pre-created subnet IDs directly.

locals {
  account_role_prefix  = coalesce(var.account_role_prefix, "${var.cluster_name}-account")
  operator_role_prefix = coalesce(var.operator_role_prefix, "${var.cluster_name}-operator")
}

############################
# Cluster
############################
module "hcp" {
  source = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.7.3"

  cluster_name               = var.cluster_name
  openshift_version          = var.openshift_version
  machine_cidr               = var.machine_cidr
  aws_subnet_ids             = var.aws_subnet_ids
  aws_availability_zones     = var.aws_availability_zones
  aws_billing_account_id     = var.aws_billing_account_id
  replicas                   = var.replicas
  compute_machine_type       = var.compute_machine_type
  private                    = var.private
  ec2_metadata_http_tokens   = var.ec2_metadata_http_tokens
  properties                 = var.properties

  create_admin_user          = var.create_admin_user
  admin_credentials_username = var.admin_credentials_username
  admin_credentials_password = random_password.password.result

  wait_for_create_complete            = var.wait_for_create_complete
  wait_for_std_compute_nodes_complete = var.wait_for_std_compute_nodes_complete

  default_ingress_listening_method = var.default_ingress_listening_method

  service_cidr = var.service_cidr
  pod_cidr     = var.pod_cidr
  host_prefix  = var.host_prefix

  // STS configuration
  create_account_roles  = var.create_account_roles
  account_role_prefix   = local.account_role_prefix
  create_oidc           = var.create_oidc
  managed_oidc          = var.managed_oidc
  create_operator_roles = var.create_operator_roles
  operator_role_prefix  = local.operator_role_prefix

  etcd_encryption = var.etcd_encryption

  tags = var.tags
}

resource "random_password" "password" {
  length      = 14
  special     = true
  min_lower   = 1
  min_numeric = 1
  min_special = 1
  min_upper   = 1
}
