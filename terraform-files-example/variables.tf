# Copyright Red Hat
# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  type        = string
  description = "Name of the ROSA HCP cluster."
}

variable "openshift_version" {
  type        = string
  default     = "4.19.3"
  description = "OpenShift version (e.g. 4.19.3)."
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openshift_version))
    error_message = "openshift_version must be <major>.<minor>.<patch> (e.g. 4.19.3)."
  }
}

variable "aws_billing_account_id" {
  type        = string
  description = "AWS billing account ID linked to Red Hat marketplace."
}

variable "machine_cidr" {
  type        = string
  description = "VPC CIDR block (e.g. 10.0.0.0/23)."
}

variable "aws_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the ROSA cluster (minimum 3 for multi-AZ)."
}

variable "aws_availability_zones" {
  type        = list(string)
  description = "Availability zones matching the provided subnets."
}

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

variable "tags" {
  type        = map(string)
  default     = {}
  description = "AWS resource tags."
}
