# ROSA HCP Zero Egress — Required Details from Customer

This document lists all information required from the customer/user before provisioning a ROSA HCP zero-egress cluster. Collect these details upfront to avoid delays during deployment.

---

## 1. AWS Account & Credentials

| # | Detail | Example | Notes |
|---|--------|---------|-------|
| 1.1 | AWS Account ID | `123456789012` | The account where the cluster will be deployed |
| 1.2 | AWS Billing Account ID | `123456789012` | Often the same as the hosting account. If using AWS Organizations, this is the payer account linked to the Red Hat Marketplace subscription |
| 1.3 | AWS Region | `ap-southeast-1` | Region for the ROSA cluster deployment |
| 1.4 | AWS IAM User or Role ARN | `arn:aws:iam::123456789012:user/rosa-admin` | Must have the permissions listed in the prerequisites document (Section 2.1) |
| 1.5 | AWS Access Key ID | `AKIA...` | For jump host AWS CLI configuration. Alternatively use IAM instance profile |
| 1.6 | AWS Secret Access Key | `wJal...` | Pair with the Access Key ID above |

> **Security note**: If the customer prefers not to share long-lived credentials, the jump host can use an IAM instance profile with the required permissions attached.

---

## 2. Red Hat Account & ROSA

| # | Detail | Example | Notes |
|---|--------|---------|-------|
| 2.1 | Red Hat Account Email | `admin@company.com` | Must have access to [console.redhat.com](https://console.redhat.com) |
| 2.2 | OCM Offline Token | `eyJhbG...` | Obtained from [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token). Required for `rosa login` |
| 2.3 | ROSA HCP Marketplace Subscription | Completed (Yes/No) | Must be subscribed to [ROSA HCP on AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-juiwfhpeizxro) |
| 2.4 | AWS–Red Hat Account Linking | Completed (Yes/No) | The "Continue to Red Hat" flow from the AWS ROSA console must be completed |

---

## 3. Cluster Configuration

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 3.1 | **Cluster Name** | `prod-rosa-sg` | — | **Yes** | Max 15 characters, lowercase alphanumeric and hyphens only |
| 3.2 | **Zero Egress** | `true` | `false` | **Yes** | Set `true` for zero-egress deployment |
| 3.3 | **Private (PrivateLink)** | `true` | `true` | **Yes** | Enables PrivateLink API endpoint. Must be `true` for zero egress |
| 3.4 | Multi-AZ | `true` | `false` | Recommended | Deploy across 3 availability zones for production HA |
| 3.5 | OpenShift Version | `4.21.9` | Latest stable | No | Pin to a specific version if required. Otherwise uses latest available |
| 3.6 | FIPS Compliance | `false` | `false` | No | Set `true` for FIPS 140-2 compliance (requires compatible instance types) |
| 3.7 | Termination Protection | `false` | `false` | No | Prevents accidental cluster deletion via OCM |

---

## 4. Network Configuration

### 4A. If the Validated Pattern creates the VPC (`network_type = "private"`)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 4A.1 | **VPC CIDR** | `10.0.0.0/23` | — | **Yes** | Minimum `/25` per subnet. Recommended `/23` or larger |
| 4A.2 | Service CIDR | `172.30.0.0/16` | `172.30.0.0/16` | No | Kubernetes services network. Must not overlap with VPC CIDR |
| 4A.3 | Pod CIDR | `10.128.0.0/14` | `10.128.0.0/14` | No | Pod network. Must not overlap with VPC or Service CIDRs |
| 4A.4 | Host Prefix | `23` | `23` | No | Subnet mask for per-node pod allocation |

### 4B. If the customer provides an existing VPC (`network_type = "existing"`)

| # | Detail | Example | Required | Notes |
|---|--------|---------|----------|-------|
| 4B.1 | **VPC ID** | `vpc-0abc123def456` | **Yes** | Must have DNS Support and DNS Hostnames enabled |
| 4B.2 | **VPC Name** | `prod-rosa-vpc` | For reference | Used for tagging and identification |
| 4B.3 | **VPC CIDR** | `10.0.0.0/23` | **Yes** | Must match the Machine CIDR passed during cluster creation |
| 4B.4 | **Private Subnet IDs** | `subnet-aaa, subnet-bbb, subnet-ccc` | **Yes** | Minimum 1 (single-AZ) or 3 (multi-AZ). Must be tagged with `kubernetes.io/role/internal-elb=1` |
| 4B.5 | **Private Subnet Names** | `prod-rosa-private-1a, prod-rosa-private-1b, prod-rosa-private-1c` | For reference | One per AZ |
| 4B.6 | **Private Subnet CIDRs** | `10.0.0.0/25, 10.0.0.128/25, 10.0.1.0/25` | **Yes** | Minimum `/25` per subnet recommended |
| 4B.7 | **Availability Zones** | `ap-southeast-1a, ap-southeast-1b, ap-southeast-1c` | **Yes** | One per private subnet |
| 4B.8 | Public Subnet IDs (optional) | `subnet-ddd` | No | Only if external load balancers are needed. Must be tagged with `kubernetes.io/role/elb=1` |
| 4B.9 | Service CIDR | `172.30.0.0/16` | No | Kubernetes services network |
| 4B.10 | Pod CIDR | `10.128.0.0/14` | No | Pod network |
| 4B.11 | Host Prefix | `23` | No | Per-node pod subnet mask |

#### VPC Endpoints Required (customer must create if providing existing VPC)

The following VPC endpoints must exist in the customer VPC before cluster creation:

| Endpoint | Service Name | Type | Required |
|----------|-------------|------|----------|
| **S3** | `com.amazonaws.<region>.s3` | Gateway | **Yes** |
| **STS** | `com.amazonaws.<region>.sts` | Interface | **Yes** |
| **ECR API** | `com.amazonaws.<region>.ecr.api` | Interface | **Yes** |
| **ECR Docker** | `com.amazonaws.<region>.ecr.dkr` | Interface | **Yes** |
| CloudWatch Logs | `com.amazonaws.<region>.logs` | Interface | Optional — only if CloudWatch log forwarding is enabled |
| CloudWatch Monitoring | `com.amazonaws.<region>.monitoring` | Interface | Optional — only if CloudWatch log forwarding is enabled |

All Interface endpoints must have `PrivateDnsEnabled: true` and their security groups must allow inbound HTTPS (port 443) from the VPC CIDR.

#### Subnet Tags Required

| Tag Key | Tag Value | Applied To |
|---------|-----------|------------|
| `kubernetes.io/role/internal-elb` | `1` | All private subnets |
| `kubernetes.io/role/elb` | `1` | Public subnets (if applicable) |

---

## 5. Worker Node Configuration

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 5.1 | **Instance Type** | `m5.xlarge` | `m5.xlarge` | **Yes** | EC2 instance type for default worker nodes |
| 5.2 | Min Replicas (per AZ) | `1` | `1` (multi-AZ) / `2` (single-AZ) | No | Minimum workers per AZ for autoscaling |
| 5.3 | Max Replicas (per AZ) | `2` | `2` (multi-AZ) / `4` (single-AZ) | No | Maximum workers per AZ for autoscaling |
| 5.4 | Worker Labels | `{"env": "prod"}` | `{}` | No | Kubernetes labels for default machine pool |
| 5.5 | Worker Taints | — | `[]` | No | Kubernetes taints for default machine pool |
| 5.6 | Worker Disk Size (GiB) | `300` | `300` | No | Root volume size for worker nodes |

### Additional Machine Pools (optional)

If the customer requires machine pools beyond the default (e.g., dedicated compute, GPU, infra nodes), provide the following per pool:

| Detail | Example | Notes |
|--------|---------|-------|
| Pool Name | `compute-0` | Unique name for the pool |
| Subnet Index | `0` | 0 = first AZ, 1 = second AZ, 2 = third AZ |
| Instance Type | `m5.2xlarge` | Can differ from default pool |
| Autoscaling | `true` | Enable/disable autoscaling |
| Min Replicas | `1` | Minimum replicas for this pool |
| Max Replicas | `3` | Maximum replicas for this pool |
| Labels | `{"workload": "compute"}` | Pool-specific labels |
| Taints | `[{"key":"dedicated","value":"compute","schedule_type":"NoSchedule"}]` | Pool-specific taints |

---

## 6. Encryption & Security

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 6.1 | KMS Key ARN (EBS encryption) | `arn:aws:kms:...` | Auto-created | No | Provide if using a customer-managed KMS key. Otherwise the Validated Pattern creates one |
| 6.2 | KMS Key Deletion Window (days) | `10` | `10` | No | Waiting period before KMS key is deleted |
| 6.3 | etcd Encryption | `false` | `false` | No | Enable encryption at rest for etcd |

---

## 7. Logging & Monitoring

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 7.1 | Control Plane Log Forwarding | `true` | `false` | No | Enable ROSA managed control plane log forwarding |
| 7.2 | Forward to CloudWatch | `false` | `false` | No | Requires CloudWatch VPC endpoints |
| 7.3 | Forward to S3 | `true` | `false` | No | More cost-effective than CloudWatch |
| 7.4 | S3 Log Retention (days) | `30` | `30` | No | How long to retain logs in S3 |
| 7.5 | S3 Bucket Name | `my-cluster-logs` | Auto-generated | No | Custom bucket name (if not auto-generated) |
| 7.6 | CloudWatch Logging (Operator) | `false` | `false` | No | OpenShift Logging Operator → CloudWatch |
| 7.7 | Log Groups | `["api","authentication","controller manager","scheduler"]` | All 4 | No | Which control plane log groups to forward |

---

## 8. Access & Connectivity

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 8.1 | Jump Host / Bastion | External (customer-managed) | — | **Yes** | How will CLI tools be run? Jump host in VPC, separate management VPC, or VPN |
| 8.2 | Enable Bastion (Validated Pattern) | `false` | `false` | No | The pattern can optionally create a bastion host |
| 8.3 | Enable Client VPN | `false` | `false` | No | AWS Client VPN for private cluster access |
| 8.4 | VPN Client CIDR | `10.100.0.0/22` | `10.100.0.0/22` | No | Must not overlap with VPC CIDR. Only if Client VPN is enabled |
| 8.5 | SSH Key Pair Name | `rosa-jumphost-key` | — | If using bastion | For jump host access |
| 8.6 | Allowed SSH Source CIDR | `203.0.113.0/32` | — | If using bastion | Restrict SSH access to specific IPs |

---

## 9. DNS & Domain

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 9.1 | Persistent DNS Domain | `false` | `false` | No | When `true`, DNS domain persists across cluster recreations |
| 9.2 | Custom Domain | — | ROSA-assigned | No | If a custom domain is required, additional configuration is needed post-deploy |

---

## 10. GitOps & Day-2 Configuration

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 10.1 | Enable GitOps Bootstrap | `false` | `false` | No | Install GitOps (ArgoCD) operator during cluster creation |
| 10.2 | Git Repo URL | `https://github.com/org/cluster-config.git` | — | If GitOps enabled | Repository containing cluster configuration |
| 10.3 | Git Branch/Tag | `main` | `HEAD` | No | Target revision for GitOps sync |
| 10.4 | Git Path | `prod/cluster-01` | — | If GitOps enabled | Path within repo to cluster config |
| 10.5 | Enable Cert-Manager IAM | `false` | `false` | No | Create IAM role for cert-manager + AWS Private CA |
| 10.6 | Enable Secrets Manager IAM | `false` | `false` | No | Create IAM role for ArgoCD Vault Plugin |

---

## 11. Resource Tags

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 11.1 | Tags | `{"Environment":"production","ManagedBy":"terraform","Project":"rosa-hcp","CostCenter":"12345"}` | `{}` | Recommended | Applied to all AWS resources created by Terraform |

---

## 12. Proxy Configuration (if applicable)

| # | Detail | Example | Default | Required | Notes |
|---|--------|---------|---------|----------|-------|
| 12.1 | HTTP Proxy | `http://proxy.corp.com:8080` | None | No | Only if cluster needs to route through a corporate proxy |
| 12.2 | HTTPS Proxy | `http://proxy.corp.com:8080` | None | No | URL scheme must be `http` even for HTTPS proxy |
| 12.3 | No Proxy | `.corp.com,10.0.0.0/8` | None | No | Comma-separated domains/CIDRs to bypass proxy |
| 12.4 | Additional Trust Bundle | PEM certificate bundle | None | No | Custom CA certificates for the proxy |

---

## 13. Firewall Allowlist (if bastion is behind a firewall)

If the jump host/bastion is in a restricted network with egress filtering, the following HTTPS domains must be allowed:

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

For the fastest deployment, these are the absolute minimum details needed from the customer:

| # | Detail | Why |
|---|--------|-----|
| 1 | **AWS Account ID** | Where to deploy |
| 2 | **AWS Region** | Which region |
| 3 | **AWS Credentials** (Access Key + Secret) or IAM Role | Authentication |
| 4 | **OCM Offline Token** | ROSA authentication |
| 5 | **Cluster Name** | Identifier for the cluster |
| 6 | **VPC CIDR** (if Terraform creates it) or **VPC ID + Subnet IDs** (if BYO VPC) | Network placement |
| 7 | **Worker Instance Type** | Node sizing |
| 8 | **Multi-AZ (yes/no)** | Availability requirement |
| 9 | **Marketplace subscription + account linking completed** | Billing prerequisite |

Everything else has sensible defaults in the Validated Pattern.
