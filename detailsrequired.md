# ROSA HCP Zero Egress — Required Details from Customer

This document lists all information required from the customer/user before provisioning a ROSA HCP zero-egress cluster. Items marked **Required** must be provided; all others have sensible defaults.

> **Scope**: This document covers a zero-egress, private (PrivateLink) ROSA HCP deployment. The `zero_egress` and `private` flags are always `true` and are not listed as customer decisions.

---

## 1. AWS Account

| # | Detail | Example | Required | Notes |
|---|--------|---------|----------|-------|
| 1.1 | **AWS Account ID** | `123456789012` | **Yes** | The account where the cluster will be deployed |
| 1.2 | AWS Billing Account ID | `123456789012` | Only if different from 1.1 | Required when using AWS Organizations — the payer account linked to the Red Hat Marketplace subscription |
| 1.3 | **AWS Region** | `ap-southeast-1` | **Yes** | Target region for deployment |

> **Note**: The customer configures AWS CLI credentials (access key / IAM instance profile) on the jump host themselves. Credentials are not collected in this form.

---

## 2. Red Hat Account & ROSA

| # | Detail | Example | Required | Notes |
|---|--------|---------|----------|-------|
| 2.1 | **OCM Offline Token** | `eyJhbG...` | **Yes** | From [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token). Required for `rosa login` and Terraform RHCS provider |
| 2.2 | **Marketplace Subscription** | Completed (Yes/No) | **Yes** | Must be subscribed to [ROSA HCP on AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-juiwfhpeizxro) |
| 2.3 | **AWS–Red Hat Account Linking** | Completed (Yes/No) | **Yes** | The "Continue to Red Hat" flow from the AWS ROSA console must be completed |

> These are one-time prerequisites. If not completed, cluster creation will fail with `billing account not linked to organization at the aws marketplace`.

---

## 3. Cluster Configuration

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 3.1 | **Cluster Name** | `prod-rosa-sg` | — | **Yes** | Max 15 characters, lowercase alphanumeric and hyphens only |
| 3.2 | **Multi-AZ** | `true` | `false` | **Yes** | `true` recommended for production (deploys across 3 AZs) |
| 3.3 | OpenShift Version | `4.21.9` | Latest stable | No | Pin to a specific version if required |
| 3.4 | FIPS Compliance | `false` | `false` | No | Requires FIPS-compatible instance types |
| 3.5 | Termination Protection | `false` | `false` | No | Prevents accidental deletion via OCM |

---

## 4. Network Configuration

The customer must choose one of two approaches:

### Option A — Terraform creates the VPC (`network_type = "private"`)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 4A.1 | **VPC CIDR** | `10.0.0.0/23` | — | **Yes** | Minimum `/25` per subnet. Recommended `/23` or larger for scaling |
| 4A.2 | Service CIDR | `172.30.0.0/16` | `172.30.0.0/16` | No | Kubernetes services network. Must not overlap with VPC CIDR |
| 4A.3 | Pod CIDR | `10.128.0.0/14` | `10.128.0.0/14` | No | Pod network. Must not overlap with VPC or Service CIDRs |
| 4A.4 | Host Prefix | `23` | `23` | No | Subnet mask for per-node pod allocation |

### Option B — Customer provides an existing VPC (`network_type = "existing"`)

| # | Detail | Example | Required | Notes |
|---|--------|---------|----------|-------|
| 4B.1 | **VPC ID** | `vpc-0abc123def456` | **Yes** | Must have DNS Support and DNS Hostnames enabled |
| 4B.2 | **Private Subnet IDs** | `subnet-aaa, subnet-bbb, subnet-ccc` | **Yes** | 1 for single-AZ, 3 for multi-AZ. Must be tagged with `kubernetes.io/role/internal-elb=1` |
| 4B.3 | Public Subnet IDs | `subnet-ddd` | No | Only if external-facing load balancers are needed. Tag with `kubernetes.io/role/elb=1` |
| 4B.4 | Service CIDR | `172.30.0.0/16` | No | Defaults to `172.30.0.0/16` |
| 4B.5 | Pod CIDR | `10.128.0.0/14` | No | Defaults to `10.128.0.0/14` |
| 4B.6 | Host Prefix | `23` | No | Defaults to `23` |

> **Customer responsibility for BYO VPC**: The following must be in place before cluster creation:
>
> | Prerequisite | Details |
> |---|---|
> | **VPC DNS** | `enableDnsSupport` and `enableDnsHostnames` must both be `true` |
> | **VPC Endpoints** | S3 (Gateway), STS (Interface), ECR API (Interface), ECR DKR (Interface). All Interface endpoints need `PrivateDnsEnabled: true` and security groups allowing HTTPS (443) from VPC CIDR |
> | **Optional VPC Endpoints** | CloudWatch Logs + Monitoring — only if control plane log forwarding to CloudWatch is enabled |
> | **Subnet Tags** | `kubernetes.io/role/internal-elb=1` on all private subnets |

---

## 5. Worker Node Configuration

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 5.1 | **Instance Type** | `m5.xlarge` | `m5.xlarge` | Recommended | EC2 instance type for default worker pool. Confirm the type meets workload requirements |
| 5.2 | Min Replicas (per AZ) | `1` | `1` (multi-AZ) / `2` (single-AZ) | No | Minimum workers per AZ for autoscaling |
| 5.3 | Max Replicas (per AZ) | `2` | `2` (multi-AZ) / `4` (single-AZ) | No | Maximum workers per AZ for autoscaling |
| 5.4 | Worker Labels | `{"env": "prod"}` | `{}` | No | Kubernetes labels for default machine pool |
| 5.5 | Worker Taints | — | `[]` | No | Kubernetes taints for default machine pool |

### Additional Machine Pools (optional)

Only needed if the customer requires machine pools beyond the default (e.g., dedicated compute, GPU, infra nodes):

| Detail | Example | Notes |
|--------|---------|-------|
| Pool Name | `compute-0` | Unique name per pool |
| Subnet Index | `0` | 0 = first AZ, 1 = second AZ, 2 = third AZ |
| Instance Type | `m5.2xlarge` | Can differ from default pool |
| Autoscaling Enabled | `true` | Enable/disable per-pool autoscaling |
| Min Replicas | `1` | Per-pool minimum |
| Max Replicas | `3` | Per-pool maximum |
| Labels | `{"workload": "compute"}` | Pool-specific labels |
| Taints | `[{"key":"dedicated","value":"compute","schedule_type":"NoSchedule"}]` | Pool-specific taints |

---

## 6. Encryption (optional)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 6.1 | KMS Key ARN | `arn:aws:kms:...` | Auto-created | No | Provide only if a specific customer-managed KMS key must be used. Otherwise the Validated Pattern creates EBS and EFS KMS keys automatically |
| 6.2 | etcd Encryption | `false` | `false` | No | Enable encryption at rest for etcd data |

---

## 7. Logging (optional)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 7.1 | Enable Control Plane Log Forwarding | `true` | `false` | No | ROSA managed log forwarder |
| 7.2 | Forward to S3 | `true` | `false` | No | Cost-effective log storage |
| 7.3 | Forward to CloudWatch | `false` | `false` | No | Requires CloudWatch VPC endpoints in the ROSA VPC |
| 7.4 | S3 Log Retention (days) | `30` | `30` | No | Auto-expiry of log objects |

---

## 8. Resource Tags (recommended)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 8.1 | Tags | `{"Environment":"production", "ManagedBy":"terraform", "Project":"rosa-hcp", "CostCenter":"12345"}` | `{}` | Recommended | Applied to all AWS resources. Useful for cost allocation and governance |

---

## 9. Advanced Options (rarely needed)

These options are available but most customers use the defaults:

| # | Detail | Default | When to change |
|---|--------|---------|----------------|
| 9.1 | Persistent DNS Domain | `false` | Set `true` if the DNS domain must survive cluster recreation |
| 9.2 | Enable GitOps Bootstrap | `false` | Set `true` to install ArgoCD during provisioning. Requires Git Repo URL and Git Path |
| 9.3 | Git Repo URL | — | Only if GitOps is enabled |
| 9.4 | Git Branch/Tag | `HEAD` | Only if GitOps is enabled |
| 9.5 | Git Path | — | Only if GitOps is enabled |
| 9.6 | Enable Cert-Manager IAM | `false` | Set `true` if using AWS Private CA with cert-manager |
| 9.7 | Enable Client VPN | `false` | Alternative to jump host for private cluster access |
| 9.8 | VPN Client CIDR | `10.100.0.0/22` | Only if Client VPN is enabled. Must not overlap with VPC CIDR |

---

## Reference: Firewall Allowlist for Bastion Host

This is not a customer *input* but reference information for network teams. If the bastion/jump host is behind a firewall with egress filtering, these HTTPS domains must be allowed:

| # | Domain | Purpose |
|---|--------|---------|
| 1 | `sso.redhat.com` | ROSA CLI authentication |
| 2 | `api.openshift.com` | ROSA cluster lifecycle API |
| 3 | `.amazonaws.com` | All AWS API calls (wildcard) |
| 4 | `registry.terraform.io` | Terraform provider/module registry |
| 5 | `releases.hashicorp.com` | Terraform binary downloads |
| 6 | `checkpoint-api.hashicorp.com` | Terraform version checks |
| 7 | `github.com` | Git repository access |
| 8 | `objects.githubusercontent.com` | GitHub raw content |
| 9 | `release-assets.githubusercontent.com` | Terraform provider binaries |
| 10 | `mirror.openshift.com` | ROSA CLI and oc CLI downloads |
| 11 | `console.redhat.com` | Red Hat Hybrid Cloud Console |

---

## Quick Reference: Minimum Required Details

For the fastest deployment with all defaults, collect only these:

| # | Detail | Terraform Variable | Why |
|---|--------|--------------------|-----|
| 1 | **AWS Account ID** | (credentials) | Where to deploy |
| 2 | **AWS Region** | `region` | Which region |
| 3 | **OCM Offline Token** | `RHCS_TOKEN` env var | ROSA + Terraform RHCS provider authentication |
| 4 | **Marketplace + account linking** | — | Billing prerequisite (must be done before Terraform) |
| 5 | **Cluster Name** | `cluster_name` | Cluster identifier |
| 6 | **VPC CIDR** | `vpc_cidr` | Network sizing (if Terraform creates VPC) |
| | — *or* **VPC ID + Subnet IDs** | `existing_vpc_id`, `existing_private_subnet_ids` | Network placement (if BYO VPC) |
| 7 | **Multi-AZ** | `multi_az` | HA requirement |

Everything else uses sensible defaults from the Validated Pattern (`m5.xlarge` workers, autoscaling 1–2 per AZ, no FIPS, no GitOps, auto-created KMS keys, no log forwarding).
