# Copyright Red Hat
# SPDX-License-Identifier: Apache-2.0

##############################################################
# Cluster Identity
##############################################################
variable "cluster_name" {
  type        = string
  description = "Name of the ROSA HCP cluster."
  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{0,13}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be 2-15 chars, lowercase alphanumeric/hyphens, start with a letter."
  }
}

variable "openshift_version" {
  type        = string
  default     = "4.20.24"
  description = "OpenShift version (e.g. 4.20.24)."
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openshift_version))
    error_message = "openshift_version must be <major>.<minor>.<patch> (e.g. 4.20.24)."
  }
}

##############################################################
# AWS Account & Billing
##############################################################
variable "aws_billing_account_id" {
  type        = string
  description = "AWS billing account ID linked to Red Hat marketplace."
}

##############################################################
# BYO VPC — Network
##############################################################
variable "aws_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the ROSA cluster (minimum 3 for multi-AZ)."
}

variable "aws_availability_zones" {
  type        = list(string)
  description = "Availability zones matching the provided subnets."
}

variable "machine_cidr" {
  type        = string
  description = "VPC CIDR block (must match the existing VPC CIDR, e.g. 10.0.0.0/23)."
}

##############################################################
# Zero Egress & Private Cluster
##############################################################
variable "private" {
  type        = bool
  default     = true
  description = "Use PrivateLink for API endpoint (required for zero egress)."
}

variable "properties" {
  type        = map(string)
  default     = { zero_egress = "true" }
  description = "Cluster properties. Set zero_egress = \"true\" for zero egress mode."
}

##############################################################
# Worker Nodes
##############################################################
variable "replicas" {
  type        = number
  default     = 3
  description = "Number of worker nodes (must be multiple of subnet count)."
}

variable "compute_machine_type" {
  type        = string
  default     = "m5.xlarge"
  description = "EC2 instance type for worker nodes."
}

variable "ec2_metadata_http_tokens" {
  type        = string
  default     = "required"
  description = "IMDSv2 setting: 'required' (v2 only) or 'optional' (v1+v2)."
}

##############################################################
# Network CIDRs
##############################################################
variable "service_cidr" {
  type        = string
  default     = "172.30.0.0/16"
  description = "Kubernetes service CIDR."
}

variable "pod_cidr" {
  type        = string
  default     = "10.128.0.0/14"
  description = "Kubernetes pod CIDR."
}

variable "host_prefix" {
  type        = number
  default     = 23
  description = "Subnet prefix length for each node."
}

##############################################################
# Ingress
##############################################################
variable "default_ingress_listening_method" {
  type        = string
  default     = "internal"
  description = "Ingress listening method: 'internal' or 'external'."
}

##############################################################
# Admin User
##############################################################
variable "create_admin_user" {
  type        = bool
  default     = true
  description = "Create a cluster admin user."
}

variable "admin_credentials_username" {
  type        = string
  default     = "cluster-admin"
  description = "Admin username."
}

##############################################################
# STS / IAM Roles
##############################################################
variable "create_account_roles" {
  type        = bool
  default     = true
  description = "Create AWS account roles for ROSA."
}

variable "account_role_prefix" {
  type        = string
  default     = null
  description = "Prefix for IAM account roles (defaults to cluster_name-account)."
}

variable "create_operator_roles" {
  type        = bool
  default     = true
  description = "Create AWS operator roles for ROSA."
}

variable "operator_role_prefix" {
  type        = string
  default     = null
  description = "Prefix for IAM operator roles (defaults to cluster_name-operator)."
}

##############################################################
# OIDC Configuration
##############################################################
variable "create_oidc" {
  type        = bool
  default     = true
  description = "Create OIDC configuration."
}

variable "managed_oidc" {
  type        = bool
  default     = true
  description = "Use Red Hat managed OIDC (recommended)."
}

##############################################################
# Encryption
##############################################################
variable "etcd_encryption" {
  type        = bool
  default     = false
  description = "Enable etcd encryption (optional, requires KMS key if using CMK)."
}

##############################################################
# Cluster Behavior
##############################################################
variable "wait_for_create_complete" {
  type        = bool
  default     = true
  description = "Wait for cluster creation to complete."
}

variable "wait_for_std_compute_nodes_complete" {
  type        = bool
  default     = false
  description = "Wait for compute nodes (set false for zero egress — nodes take longer)."
}

##############################################################
# Tags
##############################################################
variable "tags" {
  type        = map(string)
  default     = {}
  description = "AWS resource tags."
}
