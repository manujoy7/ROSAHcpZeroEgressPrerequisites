# ROSA HCP Zero Egress: Prerequisites and Deployment Guide

---

## 1. Overview

Red Hat OpenShift Service on AWS with Hosted Control Planes ([ROSA HCP](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-egress-zero-install)) supports a **zero egress** deployment model where all cluster traffic remains within the AWS network. Clusters with zero egress pull Red Hat container images from a regional Amazon Elastic Container Registry (ECR) mirror instead of from public registries on the internet. All requests to ECR are served over VPC endpoints within the cluster's VPC.

To enable zero egress, you configure a VPC with private subnets and the required VPC endpoints, then pass the `--properties zero_egress:true` flag during cluster creation. This guide provides CLI, Terraform, and [Validated Pattern module](https://github.com/rh-mobb/validated-pattern-terraform-rosa) deployment options — the latter is recommended for enterprises where different teams (Network, IAM/Security, Platform) own separate infrastructure layers.

### Limitations of Zero Egress

- **Red Hat Lightspeed and Telemetry** are not available
- **OperatorHub**: Only the default Operator channel is mirrored to ECR. Third-party operators that are not part of the default Red Hat mirrored catalog must be mirrored manually to a private registry (e.g., your own ECR repository) using the `oc-mirror` tool
- **Workloads requiring public internet** (e.g., pulling from `quay.io`, `docker.io`, or `ghcr.io`) will fail unless you mirror those images to an accessible private registry
- **Upgrades**: Supported via the mirrored ECR content; Red Hat recommends using the latest available z-stream release

---

## 2. Prerequisites

### 2.1 AWS Account Requirements

You need a blank AWS account with an IAM user or role that has the following minimum permissions. Ensure your Service Control Policy (SCP) does not restrict any of these.

| AWS Service | Required Permissions |
|---|---|
| **IAM** | `CreateRole`, `GetRole`, `DeleteRole`, `AttachRolePolicy`, `DetachRolePolicy`, `TagRole`, `CreatePolicy`, `GetPolicy`, `DeletePolicy`, `CreatePolicyVersion`, `DeletePolicyVersion`, `ListPolicyVersions`, `ListRoles`, `ListRoleTags`, `ListPolicyTags`, `ListAttachedRolePolicies`, `UpdateAssumeRolePolicy`, `CreateOpenIDConnectProvider`, `GetOpenIDConnectProvider`, `DeleteOpenIDConnectProvider`, `TagOpenIDConnectProvider` |
| **EC2** | `DescribeSubnets`, `DescribeRouteTables`, `DescribeAvailabilityZones`, `CreateTags`, `DescribeTags`, `DeleteTags` |
| **STS** | `AssumeRoleWithWebIdentity`, `GetCallerIdentity` |
| **S3** | Full access |
| **Service Quotas** | `ListServiceQuotas`, `GetServiceQuota` |

### 2.2 AWS Service Quotas

ROSA HCP requires minimum [service quotas](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-sts-required-aws-service-quotas) in `ap-southeast-1`. The default vCPU quota of **5** is insufficient.

| Quota Name | Service Code | AWS Default | Minimum Required | Notes |
|---|---|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `ec2` | 5 vCPUs | **100 vCPUs** | 3 x m5.2xlarge = 24 vCPUs baseline. 100 needed for upgrades, scaling, and operational headroom |
| Storage for General Purpose SSD (gp3) volumes (TiB) | `ebs` | 50 TiB | 1 TiB | Default of 50 TiB is sufficient |
| Storage for General Purpose SSD (gp2) volumes (TiB) | `ebs` | 50 TiB | 300 TiB | Recommended for production |
| ELB Classic Load Balancers | `elasticloadbalancing` | 20 | 20 | Default is sufficient |

**To check current quotas:**

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region ap-southeast-1
```

**To request a quota increase:**

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 100 \
  --region ap-southeast-1
```

> **Note**: Quota increases can take 1-5 business days. Submit requests before starting the deployment.

### 2.3 Red Hat Account Requirements

1. **Red Hat account**: Create or use an existing account at [access.redhat.com](https://access.redhat.com)
2. **OpenShift Cluster Manager (OCM) access**: Log in at [console.redhat.com/openshift](https://console.redhat.com/openshift)
3. **OCM offline token**: Obtain from [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token). This token is used for `rosa login` and does not expire (unlike the short-lived session token from `rosa token`)

> **Important**: Store the OCM token securely. Do not share it or commit it to version control.

### 2.4 ROSA HCP Activation and AWS Account Linking

This is a one-time process that connects your AWS billing account to your Red Hat account.

**Step 1 — Enable ROSA on the AWS Console**

1. Navigate to [AWS Console > ROSA](https://console.aws.amazon.com/rosa/) in your browser
2. Click **"Get started"**
3. Confirm that you want your contact information shared with Red Hat and enable the service
4. Wait for the process to complete (may take a few minutes). You will not be charged at this step — billing begins only after your first cluster is deployed
5. Verify that all prerequisites on the confirmation page are met:
   - ROSA service is enabled
   - ELB service-linked role exists (created automatically)
   - Service quotas meet requirements (use the region switcher to check `ap-southeast-1` specifically)

**Step 2 — Link your Red Hat and AWS accounts**

1. Click **"Continue to Red Hat"** on the AWS ROSA confirmation page
2. Log into your Red Hat account (or register a new one)
3. Review the terms and conditions, then click **"Connect accounts"**
4. Accept the managed services terms and conditions if prompted
5. You will see a confirmation that AWS prerequisites are completed

> **Important**: Only a single AWS billing account can be associated with a Red Hat account. Red Hat accounts belonging to the same Red Hat organization will be linked with the same AWS account. Typically, an organizational AWS payer account is used for billing rather than individual end-user accounts.

**Step 3 — Verify the ELB service-linked role**

```bash
aws iam get-role --role-name AWSServiceRoleForElasticLoadBalancing --region ap-southeast-1
```

If the role does not exist:

```bash
aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com
```

### 2.5 AWS SCP Verification

If your AWS account is part of an AWS Organization, verify that Service Control Policies do not block required ROSA permissions. See the [Red Hat SCP documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-sts-aws-prereqs#rosa-minimum-scp_rosa-sts-aws-prereqs) for the minimum effective permissions.

```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
```

---

## 3. Required Tools and Versions

All tools will be installed on the jump host (Amazon Linux 2023). The following versions are validated for ROSA HCP zero egress deployment.

| Tool | Minimum Version | Recommended Version | Purpose |
|---|---|---|---|
| **ROSA CLI** (`rosa`) | v1.2.48 | v1.2.61 (latest stable) | Cluster lifecycle management. v1.2.48+ required for `rosa create network` |
| **AWS CLI** (`aws`) | v2.0 | v2.34+ (latest) | AWS resource management and credential configuration |
| **OpenShift CLI** (`oc`) | v4.17 | v4.19+ (latest stable) | Cluster operations, application management |
| **Terraform** | v1.4.0 | v1.9+ (latest) | Infrastructure as Code for VPC and cluster provisioning |
| **Git** | v2.0 | v2.43+ (latest) | Cloning Terraform templates |
| **jq** | v1.6 | v1.7+ (latest) | JSON processing for CLI output parsing |
| **unzip** | any | latest | Extracting downloaded archives |

### Download URLs

| Tool | Download |
|---|---|
| ROSA CLI | [github.com/openshift/rosa/releases/latest](https://github.com/openshift/rosa/releases/latest) |
| AWS CLI v2 | [docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html) |
| OpenShift CLI | [mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/) |
| Terraform | [releases.hashicorp.com/terraform/](https://releases.hashicorp.com/terraform/) |

---

## 4. Phase 0: Jump Host Setup

Since the ROSA cluster operates with zero egress (no internet access from the worker nodes in private subnets), all CLI operations must be performed from a jump host that has both internet access (to reach Red Hat and AWS APIs) and network connectivity to the ROSA VPC private subnets.

The jump host is placed in the **public subnet** of the ROSA VPC, which has a route to the Internet Gateway. Zero egress applies only to the **private subnets** where ROSA worker nodes run — the jump host's public subnet is intentionally exempt so you can download tools, authenticate with Red Hat, and manage the cluster.

> **Dependency note**: The jump host requires the VPC and public subnet from Phase 1. You have two options:
> 1. **Run Phase 1 first** from your local machine or AWS CloudShell to create the VPC, then create the jump host in Phase 0.
> 2. **Create the VPC and public subnet manually** before the jump host, then proceed to Phase 1 for the remaining infrastructure (VPC endpoints, subnet tags, etc.).

### 4.1 Launch the Jump Host EC2 Instance

Launch an Amazon Linux 2023 instance in the public subnet of the ROSA VPC (or a separate management VPC with connectivity).

```bash
export REGION="ap-southeast-1"
export KEY_PAIR_NAME="rosa-jumphost-key"
export JUMP_HOST_SG_NAME="rosa-jumphost-sg"

# Create a key pair (save the .pem file securely)
aws ec2 create-key-pair \
  --key-name $KEY_PAIR_NAME \
  --query 'KeyMaterial' \
  --output text \
  --region $REGION > ${KEY_PAIR_NAME}.pem

chmod 400 ${KEY_PAIR_NAME}.pem

# Get the latest Amazon Linux 2023 AMI
AL2023_AMI=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text \
  --region $REGION)

echo "AMI: $AL2023_AMI"
```

Create a security group (assumes VPC is already created -- see Phase 1 below, or create the VPC first):

```bash
# Replace with your VPC ID after Phase 1
export VPC_ID="<your-vpc-id>"

JUMP_SG_ID=$(aws ec2 create-security-group \
  --group-name $JUMP_HOST_SG_NAME \
  --description "Security group for ROSA jump host" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --query 'GroupId' --output text)

# Allow SSH inbound (restrict to your IP in production)
aws ec2 authorize-security-group-ingress \
  --group-id $JUMP_SG_ID \
  --protocol tcp --port 22 \
  --cidr 0.0.0.0/0 \
  --region $REGION

echo "Jump Host Security Group: $JUMP_SG_ID"
```

Launch the instance:

```bash
# Replace with your public subnet ID after Phase 1
export PUBLIC_SUBNET_ID="<your-public-subnet-id>"

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AL2023_AMI \
  --instance-type t3.medium \
  --key-name $KEY_PAIR_NAME \
  --subnet-id $PUBLIC_SUBNET_ID \
  --security-group-ids $JUMP_SG_ID \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=rosa-jump-host}]" \
  --region $REGION \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the instance to be running
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Get the public IP
JUMP_HOST_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text --region $REGION)

echo "Jump Host IP: $JUMP_HOST_IP"
```

### 4.2 Connect to the Jump Host

```bash
ssh -i ${KEY_PAIR_NAME}.pem ec2-user@$JUMP_HOST_IP
```

### 4.3 Install Required Tools on the Jump Host

Run all of the following commands on the jump host.

**System updates and basic tools:**

```bash
sudo dnf update -y
sudo dnf install -y git jq unzip tar gzip
```

**AWS CLI v2:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
aws --version
```

**ROSA CLI (v1.2.61):**

```bash
curl -LO "https://github.com/openshift/rosa/releases/download/v1.2.61/rosa_Linux_x86_64.tar.gz"
tar -xzf rosa_Linux_x86_64.tar.gz rosa
sudo mv rosa /usr/local/bin/
rm -f rosa_Linux_x86_64.tar.gz
rosa version
```

**OpenShift CLI (oc):**

```bash
curl -LO "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"
tar -xzf openshift-client-linux.tar.gz oc kubectl
sudo mv oc kubectl /usr/local/bin/
rm -f openshift-client-linux.tar.gz README.md
oc version --client
```

**Terraform:**

```bash
TERRAFORM_VERSION="1.9.8"
curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip
sudo mv terraform /usr/local/bin/
rm -f terraform_${TERRAFORM_VERSION}_linux_amd64.zip
terraform version
```

### 4.4 Configure AWS Credentials

```bash
aws configure
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name: ap-southeast-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

### 4.5 Login to ROSA CLI

```bash
rosa login --token="<your-ocm-offline-token>"
rosa whoami
```

Expected output includes your Red Hat account, AWS account ID, and AWS ARN.

### 4.6 Verify Tool Versions

```bash
echo "=== Tool Versions ==="
aws --version
rosa version
oc version --client
terraform version
git --version
jq --version
```

### 4.7 URLs Required for Outbound Access

The following URLs must be reachable (HTTPS, port 443) from wherever the ROSA CLI and Terraform are run — whether that is the jump host, your laptop, or a CI/CD runner. This list is derived from the [ROSA HCP firewall prerequisites for egress-zero clusters](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-hcp-prereqs#rosa-hcp-firewall-prerequisites).

**ROSA CLI (cluster lifecycle operations):**

| URL | Port | Purpose |
|---|---|---|
| `sso.redhat.com` | 443 | Red Hat SSO authentication for `rosa login` |
| `api.openshift.com` | 443 | OpenShift Cluster Manager API (cluster creation, management) |
| `console.redhat.com` | 443 | Red Hat Hybrid Cloud Console (activation, token retrieval) |
| `mirror.openshift.com` | 443 | OpenShift client and CLI binary downloads |
| `iam.amazonaws.com` | 443 | AWS IAM API (role/policy creation) |
| `sts.ap-southeast-1.amazonaws.com` | 443 | AWS STS regional endpoint (token exchange) |
| `ec2.ap-southeast-1.amazonaws.com` | 443 | AWS EC2 API (subnet/VPC information retrieval) |
| `servicequotas.ap-southeast-1.amazonaws.com` | 443 | AWS Service Quotas API (pre-flight checks) |
| `tagging.us-east-1.amazonaws.com` | 443 | AWS Resource Tagging API |

**Terraform (provider download and AWS API calls):**

| URL | Port | Purpose |
|---|---|---|
| `registry.terraform.io` | 443 | Terraform provider registry (provider discovery) |
| `releases.hashicorp.com` | 443 | Terraform binary and provider package downloads |
| `github.com` | 443 | Terraform module sources and provider signing keys |
| `objects.githubusercontent.com` | 443 | GitHub release asset downloads |
| `release-assets.githubusercontent.com` | 443 | GitHub release asset downloads (new endpoint) |

**Tool downloads (initial setup only):**

| URL | Port | Purpose |
|---|---|---|
| `github.com/openshift/rosa/releases` | 443 | ROSA CLI binary download |
| `mirror.openshift.com` | 443 | `oc` CLI binary download |
| `awscli.amazonaws.com` | 443 | AWS CLI v2 installer download |
| `releases.hashicorp.com` | 443 | Terraform binary download |

### 4.8 Alternative: Run from Your Laptop (Without a Jump Host)

If your laptop has internet access and can reach the ROSA VPC private subnets (via AWS Client VPN, Direct Connect, or Transit Gateway), you can run all CLI and Terraform commands locally instead of from a jump host.

**Requirements:**
- Install the same tools listed in Section 3 (ROSA CLI, AWS CLI, `oc`, Terraform, `jq`)
- Configure AWS credentials: `aws configure` or set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables
- Authenticate to ROSA: `rosa login --token="<your-ocm-token>"`
- Outbound access to all URLs listed in Section 4.7

**Connecting to the private cluster after deployment:**

Since the cluster API and Ingress are private (PrivateLink), you cannot reach them from your laptop over the public internet. You need one of:

1. **AWS Client VPN** — Connect your laptop to the ROSA VPC via an OpenVPN-compatible client. If using the Validated Pattern (Section 6.3), set `enable_client_vpn = true`.
2. **SSH tunnel through the jump host** — Forward the cluster API port through SSH:

```bash
ssh -i rosa-jumphost-key.pem -L 6443:<cluster-api-hostname>:443 ec2-user@<jump-host-ip>
```

Then use `oc login https://localhost:6443 --username cluster-admin --password <password>`.

3. **AWS Direct Connect / Transit Gateway** — If your corporate network already has private connectivity to the AWS VPC, no additional tunnel is needed.

> **Note**: For initial infrastructure provisioning (VPC creation, IAM roles, cluster creation), internet access and AWS API access are sufficient — you do not need VPC-internal connectivity. VPC-internal connectivity is only required after deployment for `oc` commands against the private cluster API.

---

## 5. Phase 1: Networking and Infrastructure

### 5.1 Network Architecture and Machine CIDR

Red Hat enforces minimum [Machine CIDR sizes](https://cloud.redhat.com/experts/rosa/best-practices-recommendations/) for ROSA HCP:
- **Single-AZ**: `/25` (128 addresses)
- **Multi-AZ**: `/24` (256 addresses)
- **Recommended for production**: `/22` or larger when planning for growth toward the 500-node limit

Our VPC uses a `/23` CIDR (512 addresses), which exceeds the multi-AZ minimum. The Machine CIDR passed during cluster creation must match the VPC CIDR. See [VPC and Subnet IP Address Considerations with ROSA](https://cloud.redhat.com/experts/rosa/ip-addressing-and-subnets/) for detailed guidance.

### 5.2 Subnet Layout and IP Address Allocation

The following layout uses `/25` private subnets to maximize IP capacity for worker nodes, VPC endpoints, and load balancers:

| Subnet | CIDR | Size | AZ | Type | Purpose |
|---|---|---|---|---|---|
| Private Subnet 1 | `10.0.0.0/25` | 128 IPs | ap-southeast-1a | Private | ROSA workers, VPC endpoints |
| Private Subnet 2 | `10.0.0.128/25` | 128 IPs | ap-southeast-1b | Private | ROSA workers, VPC endpoints |
| Private Subnet 3 | `10.0.1.0/25` | 128 IPs | ap-southeast-1c | Private | ROSA workers, VPC endpoints |
| Public Subnet | `10.0.1.128/26` | 64 IPs | ap-southeast-1a | Public | Jump host, NAT Gateway (if needed) |
| Reserved | `10.0.1.192/26` | 64 IPs | — | — | Future use |

#### IP Capacity Planning (Per Private Subnet)

[AWS reserves 5 IPs](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html) in every subnet (network address, VPC router, DNS, future use, broadcast). Interface VPC endpoints each consume 1 ENI (= 1 IP) per subnet. The following table shows IP consumption for a `/25` private subnet:

| Consumer | IPs per Subnet | Notes |
|---|---|---|
| Total IPs in `/25` | 128 | |
| AWS reserved | -5 | First 4 + last address |
| **Usable IPs** | **123** | |
| Interface VPC endpoints (EC2, KMS, STS, ECR API, ECR DKR) | -5 | 1 ENI per endpoint per AZ |
| ROSA PrivateLink API endpoint | -1 | Created by ROSA in customer subnet |
| NLB for Ingress Controller | -8 | NLBs can scale up to ~8 nodes per AZ under load |
| **Available for worker nodes** | **~109** | Per AZ |
| **Total workers across 3 AZs** | **~327** | Within ROSA HCP 500-node limit |

For the initial deployment (3 workers of `m5.2xlarge`, one per AZ), each private subnet uses only ~20 IPs (5 AWS + 5 endpoints + 1 PrivateLink + 1 NLB + 1 worker + overhead), leaving **~100+ IPs per AZ for future scaling**.

> **Comparison**: With `/26` subnets (64 IPs, 59 usable), only ~40 IPs per AZ would remain for workers after overhead — workable for small clusters, but with little room for scaling or additional services.

### 5.3 VPC Endpoints

Zero-egress clusters require **6 VPC endpoints** (created in the VPC before cluster installation). Interface endpoints create one [ENI](https://docs.aws.amazon.com/vpc/latest/privatelink/interface-endpoints.html) per subnet; the S3 Gateway endpoint uses a route table entry only.

| Service | Endpoint Type | Service Name | ENIs per AZ |
|---|---|---|---|
| S3 | **Gateway** | `com.amazonaws.ap-southeast-1.s3` | 0 (route table entry only) |
| EC2 | **Interface** | `com.amazonaws.ap-southeast-1.ec2` | 1 |
| KMS | **Interface** | `com.amazonaws.ap-southeast-1.kms` | 1 |
| STS | **Interface** | `com.amazonaws.ap-southeast-1.sts` | 1 |
| ECR API | **Interface** | `com.amazonaws.ap-southeast-1.ecr.api` | 1 |
| ECR Docker | **Interface** | `com.amazonaws.ap-southeast-1.ecr.dkr` | 1 |

> **Total interface endpoint ENIs**: 5 endpoints × 3 AZs = **15 ENIs** across the cluster.

All interface endpoints must have `PrivateDnsEnabled: true` so that standard AWS service DNS names resolve to the private endpoint IPs within the VPC.

### 5.4 Subnet Tags

ROSA requires specific tags on subnets for [internal and external load balancer placement](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-egress-zero-install):

| Subnet Type | Tag Key | Tag Value |
|---|---|---|
| Private subnets (all 3) | `kubernetes.io/role/internal-elb` | `1` |
| Public subnet (if external LBs needed) | `kubernetes.io/role/elb` | `1` |

### 5.5 On-Premises and Hybrid Connectivity (Out of Scope)

To connect the ROSA VPC back to an on-premises data centre or other corporate networks, customers must establish external network connectivity using services such as [AWS Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html), [AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html), and Transit Gateway VPC attachments. This allows on-premises users and systems to reach the private cluster API, Ingress endpoints, and application workloads without traversing the public internet.

Designing and implementing hybrid connectivity is outside the scope of this document. Work with your network and security teams to plan Transit Gateway route tables, Direct Connect virtual interfaces, and any required VPN fallback paths before granting on-premises access to the ROSA cluster.

### 5.6 Create VPC: Option A — Terraform (Recommended)

Terraform gives precise control over subnet sizing, which is important for a `/23` CIDR. This uses the official [openshift-cs/terraform-vpc-example](https://github.com/openshift-cs/terraform-vpc-example/tree/main/zero-egress) repository.

**Clone the Terraform VPC example:**

```bash
git clone https://github.com/openshift-cs/terraform-vpc-example.git
cd terraform-vpc-example/zero-egress
```

**Create a `terraform.tfvars` file customized for Singapore and `/23` CIDR:**

```hcl
region             = "ap-southeast-1"
availability_zones = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
vpc_cidr_block     = "10.0.0.0/23"
private_subnets    = ["10.0.0.0/25", "10.0.0.128/25", "10.0.1.0/25"]
cluster_name       = "rosa-ze-sg"
```

> **Important**: Cluster name must be 15 characters or fewer, lowercase alphanumeric and hyphens only.

**Initialize and apply:**

```bash
terraform init

terraform plan -out rosa-zero-egress.tfplan

terraform apply rosa-zero-egress.tfplan
```

**Capture outputs:**

```bash
export VPC_ID=$(terraform output -raw vpc_id)
export PRIVATE_SUBNET_IDS=$(terraform output -raw private_subnet_ids)
echo "VPC ID: $VPC_ID"
echo "Private Subnet IDs: $PRIVATE_SUBNET_IDS"
```

**Add a public subnet for the jump host** (extend the Terraform configuration or create manually):

```bash
# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text --region $REGION)

aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID \
  --region $REGION

# Create public subnet
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.128/26 \
  --availability-zone ap-southeast-1a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=rosa-ze-sg-public-1a}]" \
  --query 'Subnet.SubnetId' \
  --output text --region $REGION)

# Enable auto-assign public IP
aws ec2 modify-subnet-attribute \
  --subnet-id $PUBLIC_SUBNET_ID \
  --map-public-ip-on-launch \
  --region $REGION

# Create public route table
PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' \
  --output text --region $REGION)

aws ec2 create-route \
  --route-table-id $PUBLIC_RT_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region $REGION

aws ec2 associate-route-table \
  --route-table-id $PUBLIC_RT_ID \
  --subnet-id $PUBLIC_SUBNET_ID \
  --region $REGION

echo "Public Subnet ID: $PUBLIC_SUBNET_ID"
```

**Verify subnet tags on private subnets:**

```bash
for SUBNET_ID in $(echo $PRIVATE_SUBNET_IDS | tr ',' ' '); do
  echo "Checking tags for subnet: $SUBNET_ID"
  aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$SUBNET_ID" \
    --region $REGION \
    --output table
done
```

If the `kubernetes.io/role/internal-elb` tag is missing, add it:

```bash
for SUBNET_ID in $(echo $PRIVATE_SUBNET_IDS | tr ',' ' '); do
  aws ec2 create-tags \
    --resources $SUBNET_ID \
    --tags Key=kubernetes.io/role/internal-elb,Value=1 \
    --region $REGION
done
```

### 5.7 Create VPC: Option B — ROSA CLI

The [`rosa create network`](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cli_tools/rosa-cli) command uses AWS CloudFormation to create the VPC and all associated resources. Available in ROSA CLI v1.2.48+.

```bash
rosa create network \
  --param Region=ap-southeast-1 \
  --param Name=rosa-ze-sg-stack \
  --param AvailabilityZoneCount=3 \
  --param VpcCidr=10.0.0.0/23
```

This command takes approximately 5 minutes and provides status updates. When complete, it outputs the created resource IDs including VPC ID, subnet IDs, and VPC endpoint IDs.

> **Note**: `rosa create network` with a `/23` CIDR may auto-size subnets differently than the layout in Section 5.0. Verify the created subnet CIDRs and ensure they meet your requirements. If precise subnet sizing is needed, use Terraform (Option A). The CloudFormation stack creates all 6 required VPC endpoints (S3, EC2, KMS, STS, ECR API, ECR DKR) automatically. It also creates a public subnet, Internet Gateway, and NAT Gateway — the NAT Gateway is part of the standard template but is **not used** by zero-egress workers (their private subnets have no route to the NAT). The public subnet can be used for the jump host.

**Tag private subnets** (if not already tagged):

```bash
aws ec2 create-tags \
  --resources <private-subnet-id-1> <private-subnet-id-2> <private-subnet-id-3> \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 \
  --region ap-southeast-1
```

**Create the public subnet and jump host infrastructure** using the same commands from Section 5.1.

### 5.8 Verify VPC Configuration

Before proceeding to cluster creation, verify the following:

```bash
# Verify VPC DNS settings
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames --region $REGION
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport --region $REGION

# Both should return "Value": true

# Verify VPC endpoints
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[*].{Service:ServiceName,Type:VpcEndpointType,State:State}' \
  --output table --region $REGION

# Expected: 6 endpoints (s3 Gateway, ec2 Interface, kms Interface, sts Interface, ecr.api Interface, ecr.dkr Interface)

# Verify private subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table --region $REGION

# Expected: 3 private subnets across 3 AZs
```

---

## 6. Phase 2: ROSA HCP Cluster Deployment with Zero Egress

This phase provides three deployment options:
- **Option A (Section 6.1):** ROSA CLI -- best for learning and single-operator deployments
- **Option B (Section 6.2):** Terraform with RHCS provider -- declarative IaC for a single team
- **Option C (Section 6.3):** Validated Pattern Terraform Modules -- **recommended for enterprises** where Network, IAM/Security, and Platform teams own separate infrastructure layers. Uses production-grade modules from [rh-mobb/validated-pattern-terraform-rosa](https://github.com/rh-mobb/validated-pattern-terraform-rosa) maintained by Red Hat MOBB.

### 6.0 Set Environment Variables

Run the following on the jump host to set variables used throughout the deployment:

```bash
export REGION="ap-southeast-1"
export CLUSTER_NAME="rosa-ze-sg"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OPERATOR_ROLES_PREFIX="${CLUSTER_NAME}"
export ACCOUNT_ROLES_PREFIX="ManagedOpenShift"

# From Phase 1 outputs
export SUBNET_IDS="<private-subnet-id-1>,<private-subnet-id-2>,<private-subnet-id-3>"

# Billing account (same as hosting account if not using cross-account billing)
export BILLING_ACCOUNT_ID="$AWS_ACCOUNT_ID"

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Subnet IDs: $SUBNET_IDS"
```

### 6.1 Option A: Deploy Using ROSA CLI

Follows the [ROSA HCP zero egress installation guide](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-egress-zero-install).

#### Step 1: Create Account-Wide STS Roles

```bash
rosa create account-roles --hosted-cp --mode auto --yes
```

This creates the following roles with the `ManagedOpenShift` prefix:
- `ManagedOpenShift-HCP-ROSA-Installer-Role`
- `ManagedOpenShift-HCP-ROSA-Support-Role`
- `ManagedOpenShift-HCP-ROSA-Worker-Role`

#### Step 2: Attach ECR Read-Only Policy to Worker Role

This is **required** for zero egress clusters to pull Red Hat platform images from the regional ECR mirror.

```bash
aws iam attach-role-policy \
  --role-name ${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
```

Verify the attachment:

```bash
aws iam list-attached-role-policies \
  --role-name ${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role \
  --query 'AttachedPolicies[*].PolicyName' \
  --output table
```

#### Step 3: Create OIDC Configuration

```bash
rosa create oidc-config --mode=auto --yes
```

Save the OIDC configuration ID:

```bash
export OIDC_ID=$(rosa list oidc-config -o json | jq -r '.[0].id')
echo "OIDC Config ID: $OIDC_ID"
```

#### Step 4: Create Operator Roles

```bash
rosa create operator-roles \
  --hosted-cp \
  --prefix=$OPERATOR_ROLES_PREFIX \
  --oidc-config-id=$OIDC_ID \
  --installer-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role \
  --mode auto --yes
```

Verify operator roles:

```bash
rosa list operator-roles --prefix $OPERATOR_ROLES_PREFIX
```

#### Step 5: Create the ROSA HCP Cluster with Zero Egress

```bash
rosa create cluster \
  --private \
  --cluster-name=$CLUSTER_NAME \
  --mode=auto \
  --hosted-cp \
  --operator-roles-prefix=$OPERATOR_ROLES_PREFIX \
  --oidc-config-id=$OIDC_ID \
  --subnet-ids=$SUBNET_IDS \
  --region $REGION \
  --machine-cidr 10.0.0.0/23 \
  --service-cidr 172.30.0.0/16 \
  --pod-cidr 10.128.0.0/14 \
  --host-prefix 23 \
  --compute-machine-type m5.2xlarge \
  --replicas 3 \
  --billing-account $BILLING_ACCOUNT_ID \
  --properties zero_egress:true \
  --yes
```

**Key flags explained:**

| Flag | Value | Purpose |
|---|---|---|
| `--private` | — | Private API and Ingress endpoints |
| `--hosted-cp` | — | Use Hosted Control Planes architecture |
| `--machine-cidr` | `10.0.0.0/23` | Must match VPC CIDR |
| `--compute-machine-type` | `m5.2xlarge` | 8 vCPU, 32 GiB RAM per worker |
| `--replicas` | `3` | One worker per AZ |
| `--properties` | `zero_egress:true` | Enable zero egress mode |

#### Step 6: Monitor Installation

```bash
rosa logs install --cluster=$CLUSTER_NAME --watch
```

Or check cluster status periodically:

```bash
rosa describe cluster --cluster=$CLUSTER_NAME
```

State progression: `pending (Preparing account)` → `installing (DNS setup in progress)` → `installing` → `ready`

> **Note**: Installation typically takes 15-30 minutes. If the state does not change to `ready` within 40 minutes, see the Troubleshooting section.

#### Step 7: Create Cluster Admin User

```bash
rosa create admin --cluster=$CLUSTER_NAME
```

Save the admin credentials from the output. You will need them to log into the cluster.

#### Step 8: Verify Cluster

```bash
rosa describe cluster --cluster=$CLUSTER_NAME

# Check specific details
rosa describe cluster --cluster=$CLUSTER_NAME -o json | jq '{
  name: .name,
  state: .state,
  version: .version.raw_id,
  region: .region.id,
  api_url: .api.url,
  console_url: .console.url,
  properties: .properties
}'
```

### 6.2 Option B: Deploy Using Terraform (RHCS Provider)

This section uses the [`terraform-redhat/rosa-hcp/rhcs`](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest) Terraform module to create the ROSA HCP cluster declaratively.

**RHCS Authentication**: Before running any Terraform commands, set credentials for the RHCS provider:

```bash
# Option 1: Offline token (suitable for local development)
export RHCS_TOKEN="<your-offline-token-from-console.redhat.com/openshift/token/rosa/show>"

# Option 2: Service account (recommended for CI/CD and automation)
# Create a service account at console.redhat.com → User Management → Service accounts
# Add it to a User Access group with RBAC roles for ROSA/OCM
export RHCS_CLIENT_ID="<your-client-id-uuid>"
export RHCS_CLIENT_SECRET="<your-client-secret>"
```

**Create a working directory:**

```bash
mkdir -p ~/rosa-terraform && cd ~/rosa-terraform
```

**Create `versions.tf`:**

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    rhcs = {
      source  = "terraform-redhat/rhcs"
      version = "~> 1.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "rhcs" {
  url = "https://api.openshift.com"
}

provider "aws" {
  region = var.aws_region
}
```

> **Note**: The `rhcs` provider reads `RHCS_TOKEN` or `RHCS_CLIENT_ID`/`RHCS_CLIENT_SECRET` from environment variables automatically. Do not store tokens in `.tf` files.

**Create `variables.tf`:**

```hcl
variable "aws_region" {
  description = "AWS region for ROSA cluster"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "ROSA cluster name (max 15 characters)"
  type        = string
  default     = "rosa-ze-sg"

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{0,13}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be <= 15 chars, lowercase alphanumeric and hyphens."
  }
}

variable "aws_account_id" {
  description = "AWS account ID for the ROSA cluster"
  type        = string
}

variable "aws_billing_account_id" {
  description = "AWS billing account ID (defaults to aws_account_id if not set)"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs from Phase 1"
  type        = list(string)
}

variable "openshift_version" {
  description = "OpenShift version to deploy"
  type        = string
  default     = "4.19.12"
}
```

**Create `main.tf`:**

```hcl
locals {
  billing_account_id = var.aws_billing_account_id != "" ? var.aws_billing_account_id : var.aws_account_id
}

module "account_iam_resources" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/account-iam-resources"

  account_role_prefix = "ManagedOpenShift"
}

module "oidc_config_and_provider" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/oidc-config-and-provider"

  managed = true
}

module "operator_roles" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/operator-roles"

  operator_role_prefix  = var.cluster_name
  account_role_prefix   = module.account_iam_resources.account_role_prefix
  oidc_endpoint_url     = module.oidc_config_and_provider.oidc_endpoint_url
  path                  = module.account_iam_resources.path
}

resource "aws_iam_role_policy_attachment" "worker_ecr_readonly" {
  role       = "${module.account_iam_resources.account_role_prefix}-HCP-ROSA-Worker-Role"
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

  depends_on = [module.account_iam_resources]
}

resource "rhcs_cluster_rosa_hcp" "cluster" {
  name                         = var.cluster_name
  cloud_region                 = var.aws_region
  aws_account_id               = var.aws_account_id
  aws_billing_account_id       = local.billing_account_id
  sts                          = {
    operator_role_prefix = module.operator_roles.operator_role_prefix
    role_arn             = module.account_iam_resources.account_roles_arn["HCP-ROSA-Installer"]
    support_role_arn     = module.account_iam_resources.account_roles_arn["HCP-ROSA-Support"]
    instance_iam_roles   = {
      worker_role_arn = module.account_iam_resources.account_roles_arn["HCP-ROSA-Worker"]
    }
    oidc_config_id = module.oidc_config_and_provider.oidc_config_id
  }
  aws_subnet_ids               = var.private_subnet_ids
  machine_cidr                 = "10.0.0.0/23"
  service_cidr                 = "172.30.0.0/16"
  pod_cidr                     = "10.128.0.0/14"
  host_prefix                  = 23
  replicas                     = 3
  compute_machine_type         = "m5.2xlarge"
  version                      = var.openshift_version
  private                      = true
  properties                   = {
    zero_egress = "true"
  }

  lifecycle {
    precondition {
      condition     = length(var.private_subnet_ids) >= 1
      error_message = "At least one private subnet ID is required."
    }
  }
}

resource "rhcs_cluster_wait" "wait" {
  cluster = rhcs_cluster_rosa_hcp.cluster.id
  timeout = 60
}
```

**Create `outputs.tf`:**

```hcl
output "cluster_id" {
  value = rhcs_cluster_rosa_hcp.cluster.id
}

output "cluster_api_url" {
  value = rhcs_cluster_rosa_hcp.cluster.api_url
}

output "cluster_console_url" {
  value = rhcs_cluster_rosa_hcp.cluster.console_url
}

output "oidc_endpoint_url" {
  value = module.oidc_config_and_provider.oidc_endpoint_url
}
```

**Create `terraform.tfvars`:**

```hcl
# RHCS authentication: set RHCS_TOKEN or RHCS_CLIENT_ID/RHCS_CLIENT_SECRET
# as environment variables before running terraform (do not store in tfvars)
aws_account_id     = "<your-aws-account-id>"
private_subnet_ids = ["<subnet-1>", "<subnet-2>", "<subnet-3>"]
cluster_name       = "rosa-ze-sg"
openshift_version  = "4.19.12"
```

> **Important**: Do not commit `terraform.tfvars` to version control as it contains sensitive tokens.

**Deploy:**

```bash
terraform init
terraform plan -out rosa-cluster.tfplan
terraform apply rosa-cluster.tfplan
```

**Create admin user** (after Terraform apply completes):

```bash
rosa create admin --cluster=$(terraform output -raw cluster_id)
```

### 6.3 Option C: Deploy Using the Validated Pattern Terraform Modules (Recommended for Enterprises)

For enterprise deployments where different teams own different aspects of the infrastructure (networking, IAM/security, platform), the [rh-mobb/validated-pattern-terraform-rosa](https://github.com/rh-mobb/validated-pattern-terraform-rosa) repository provides production-grade, modular Terraform configurations maintained by Red Hat's Managed OpenShift Black Belt (MOBB) team.

This approach follows a **Directory-Per-Cluster** pattern with state isolation and supports multi-team separation of concerns.

#### Why Use the Validated Pattern

| Feature | Basic Terraform (6.2) | Validated Pattern (6.3) |
|---|---|---|
| Module separation | Monolithic | Network, IAM, Cluster as independent modules |
| Multi-team support | Single team | Network team, IAM team, Platform team |
| KMS encryption | Optional | Built-in (EBS, EFS, ETCD) |
| EFS storage | Not included | Integrated |
| Destroy protection | None | Sleep/wake pattern with per-resource overrides |
| CloudWatch logging | Not included | Integrated with IAM roles |
| Cert Manager IAM | Not included | Integrated (AWS Private CA) |
| GitOps bootstrap | Not included | Built-in script |
| Client VPN | Not included | Integrated module |
| State management | Local | S3 remote state with DynamoDB locking |
| Makefile automation | None | Full lifecycle (`init`, `plan`, `apply`, `destroy`, `sleep`) |

#### Repository Structure

```
rosa-hcp-infrastructure/
├── modules/infrastructure/
│   ├── network-private/    # Private VPC (zero_egress = true disables NAT)
│   ├── network-public/     # Public VPC with NAT Gateways
│   ├── network-existing/   # Bring-your-own VPC
│   ├── iam/                # IAM roles, OIDC, KMS keys, operator IAM roles
│   ├── cluster/            # ROSA HCP cluster, machine pools, IDP, EFS, GitOps
│   └── client-vpn/         # AWS Client VPN for private cluster access
├── terraform/              # Shared Terraform entry point (providers, variables, main)
└── clusters/
    ├── public/             # Example public cluster config
    └── egress-zero/        # Example egress-zero cluster config
```

#### Multi-Team Deployment Scenarios

**Scenario: Complete Separation (Network, IAM, Cluster)**

This is the recommended approach for enterprises where distinct teams are responsible for networking, security/IAM, and platform operations.

**Network Team** manages VPC, subnets, VPC endpoints:

```hcl
module "network" {
  source = "../modules/infrastructure/network-private"

  name_prefix        = "prod-rosa-sg"
  vpc_cidr           = "10.0.0.0/23"
  multi_az           = true
  enable_nat_gateway = false
  zero_egress        = true

  tags = {
    Team        = "Network"
    Environment = "Production"
  }
}

output "vpc_id"             { value = module.network.vpc_id }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "security_group_id"  { value = module.network.security_group_id }
```

**IAM/Security Team** manages roles, OIDC, KMS keys:

```hcl
module "iam" {
  source = "../modules/infrastructure/iam"

  cluster_name         = "rosa-ze-sg"
  account_role_prefix  = "rosa-ze-sg"
  operator_role_prefix = "rosa-ze-sg"
  zero_egress          = true
  enable_storage       = true
  etcd_encryption      = true

  tags = {
    Team        = "Security"
    Environment = "Production"
  }
}

output "installer_role_arn" { value = module.iam.installer_role_arn }
output "worker_role_arn"    { value = module.iam.worker_role_arn }
output "oidc_config_id"     { value = module.iam.oidc_config_id }
output "ebs_kms_key_arn"    { value = module.iam.ebs_kms_key_arn }
```

**Platform Team** composes outputs from Network and IAM teams to create the cluster:

```hcl
module "cluster" {
  source = "../modules/infrastructure/cluster"

  cluster_name       = "rosa-ze-sg"
  region             = "ap-southeast-1"
  vpc_id             = var.vpc_id              # From Network team
  private_subnet_ids = var.private_subnet_ids  # From Network team
  installer_role_arn = var.installer_role_arn   # From IAM team
  support_role_arn   = var.support_role_arn     # From IAM team
  worker_role_arn    = var.worker_role_arn      # From IAM team
  oidc_config_id     = var.oidc_config_id      # From IAM team
  kms_key_arn        = var.ebs_kms_key_arn     # From IAM team

  private            = true
  zero_egress        = true
  multi_az           = true
  service_cidr       = "172.30.0.0/16"
  pod_cidr           = "10.128.0.0/14"
  host_prefix        = 23

  default_instance_type = "m5.2xlarge"
}
```

Teams coordinate via shared Terraform state outputs, CI/CD pipeline variables, or shared `tfvars` files.

#### Quick Start: Egress-Zero Cluster

```bash
# Clone the validated pattern repository
git clone https://github.com/rh-mobb/validated-pattern-terraform-rosa.git
cd validated-pattern-terraform-rosa

# Set RHCS authentication
export RHCS_TOKEN="<your-ocm-offline-token>"

# Edit the egress-zero tfvars for Singapore
# Key changes: region, vpc_cidr, instance type
cat > clusters/egress-zero/terraform.tfvars <<'EOF'
network_type          = "private"
zero_egress           = true
private               = true
region                = "ap-southeast-1"
vpc_cidr              = "10.0.0.0/23"
multi_az              = true
default_instance_type = "m5.2xlarge"
service_cidr          = "172.30.0.0/16"
pod_cidr              = "10.128.0.0/14"
host_prefix           = 23
enable_client_vpn     = true
fips                  = false
enable_persistent_dns_domain = true
enable_termination_protection = false
EOF

# Initialize and deploy
make init.egress-zero
make plan.egress-zero
make apply.egress-zero

# Access the cluster (after VPN connection)
make show-credentials.egress-zero
make login.egress-zero
```

#### Destroy Protection (Production Safety)

The validated pattern implements a sleep/wake pattern that prevents accidental cluster deletion:

```hcl
# Default: resources are protected
persists_through_sleep = true

# To sleep a cluster (preserves DNS, IAM, KMS, credentials):
persists_through_sleep = false
# Then: make sleep.egress-zero

# Per-resource overrides:
persists_through_sleep_cluster = false  # Sleep cluster only
persists_through_sleep_iam     = true   # Keep IAM roles
persists_through_sleep_network = true   # Keep VPC
```

---

## 7. Post-Deployment Verification

After the cluster reaches `ready` state, verify from the jump host.

### 7.1 Login to the Cluster

```bash
# Use the credentials from 'rosa create admin'
oc login <api-url> --username cluster-admin --password <password>
```

### 7.2 Verify Nodes

```bash
oc get nodes
```

Expected: 3 worker nodes in `Ready` state, each of type `m5.2xlarge`.

### 7.3 Verify Cluster Operators

```bash
oc get clusteroperators
```

All operators should show `Available=True`, `Progressing=False`, `Degraded=False`.

### 7.4 Verify Zero Egress Properties

```bash
rosa describe cluster --cluster=$CLUSTER_NAME -o json | jq '.properties'
```

Expected: `{"zero_egress": "true"}`

### 7.5 Verify Cluster Version

```bash
oc get clusterversion
```

---

## 8. Configuring ECR Registry Access for Application Images

The zero egress setup configures the worker role with `AmazonEC2ContainerRegistryReadOnly` to pull Red Hat platform images from the regional ECR mirror. For your own application images stored in ECR, additional configuration is needed.

### 8.1 Baseline: Worker Role ECR Policy (Platform Images)

The `AmazonEC2ContainerRegistryReadOnly` policy attached to the `ManagedOpenShift-HCP-ROSA-Worker-Role` in Phase 2 is **required** for zero egress to function. It allows worker nodes to pull Red Hat platform images from the regional ECR mirror. See [Configuring ROSA to Pull Images from ECR](https://cloud.redhat.com/experts/rosa/ecr/) for background.

This policy also grants read access to all ECR repositories in the same AWS account. OpenShift on AWS includes a built-in kubelet credential provider (`ecr-credential-provider`) that automatically handles ECR authentication at the node level.

**However, relying on the worker role for customer application images is not the recommended enterprise approach** because:
- Every pod on every node inherits the same broad ECR read permissions via IMDS, violating the principle of least privilege
- A compromised pod can access the node IAM role, enabling lateral movement to all ECR repositories in the account
- No namespace-level or repository-level access control is possible
- Only read (pull) is supported -- not push

> Per the [ROSA Architecture Decision Checklist](https://cloud.redhat.com/experts/rosa/best-practices-checklist/) (Decision #24): *"Safe default: IRSA -- dedicated ServiceAccount per app, dedicated IAM role with least-privilege trust policy. Don't: Embed static AWS keys."*
>
> Per [ROSA Best Practices](https://cloud.redhat.com/experts/rosa/best-practices-recommendations/): *"Application teams need the same STS-first discipline... should use IRSA. Avoid long-lived IAM user access keys."*

### 8.2 Recommended: External Secrets Operator with IRSA (Enterprise Best Practice)

The [External Secrets Operator (ESO) with IRSA](https://cloud.redhat.com/experts/rosa/ecr-external-secrets-irsa) is the Red Hat and AWS recommended approach for enterprise ECR access. It follows the STS-first, least-privilege model described in the [ROSA Best Practices](https://cloud.redhat.com/experts/rosa/best-practices-recommendations/) and the [ROSA Architecture Decision Checklist](https://cloud.redhat.com/experts/rosa/best-practices-checklist/).

ESO uses an IRSA-annotated service account to call the ECR `GetAuthorizationToken` API, automatically generating and refreshing a Kubernetes `dockerconfigjson` pull secret every 11 hours (before the 12-hour ECR token expiry). No long-lived credentials are stored.

#### Step 1: Install External Secrets Operator

> **Zero-egress note**: This works because the `redhat-operators` catalog is mirrored to the regional ECR mirror as part of zero-egress setup. The operator images are pulled via the ECR VPC endpoints — no internet access is required.

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: external-secrets-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: external-secrets-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-operators -l operators.coreos.com/external-secrets-operator.openshift-operators --timeout=300s
```

Create the `ExternalSecretsConfig` operand:

```bash
cat <<EOF | oc apply -f -
apiVersion: operator.external-secrets.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  name: cluster
spec: {}
EOF
```

Verify ESO pods are running:

```bash
oc get pods -n external-secrets
```

#### Step 2: Prepare Environment Variables

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION="ap-southeast-1"
export OIDC_ENDPOINT=$(rosa describe cluster --cluster=$CLUSTER_NAME -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
export ECR_REPOSITORY="my-app"
export APP_NAMESPACE="my-app-ns"
export ESO_SA_NAME="ecr-eso-sa"
export ECR_IAM_ROLE_NAME="${CLUSTER_NAME}-ecr-eso-role"
```

#### Step 3: Create an ECR Repository (if needed)

```bash
aws ecr create-repository \
  --repository-name $ECR_REPOSITORY \
  --region $AWS_REGION \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256
```

#### Step 4: Create IAM Policy for ECR Access

```bash
cat <<EOF > ecr-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPOSITORY}"
    }
  ]
}
EOF

ECR_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${CLUSTER_NAME}-ecr-pull-policy" \
  --policy-document file://ecr-policy.json \
  --query 'Policy.Arn' --output text)

echo "ECR Policy ARN: $ECR_POLICY_ARN"
```

#### Step 5: Create the Application Namespace and Dedicated Service Account

```bash
oc new-project $APP_NAMESPACE
oc create serviceaccount $ESO_SA_NAME -n $APP_NAMESPACE
```

#### Step 6: Create IAM Role with IRSA Trust Policy

```bash
cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ENDPOINT}:sub": "system:serviceaccount:${APP_NAMESPACE}:${ESO_SA_NAME}"
        }
      }
    }
  ]
}
EOF

ECR_ROLE_ARN=$(aws iam create-role \
  --role-name $ECR_IAM_ROLE_NAME \
  --assume-role-policy-document file://trust-policy.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name $ECR_IAM_ROLE_NAME \
  --policy-arn $ECR_POLICY_ARN

echo "ECR Role ARN: $ECR_ROLE_ARN"
```

#### Step 7: Annotate the Service Account with IRSA

```bash
oc annotate serviceaccount $ESO_SA_NAME \
  -n $APP_NAMESPACE \
  eks.amazonaws.com/role-arn=$ECR_ROLE_ARN
```

#### Step 8: Create ECR Token Generator and ExternalSecret

```bash
cat <<EOF | oc apply -f -
apiVersion: generators.external-secrets.io/v1alpha1
kind: ECRAuthorizationToken
metadata:
  name: ecr-gen
  namespace: $APP_NAMESPACE
spec:
  region: $AWS_REGION
  auth:
    serviceAccountRef:
      name: $ESO_SA_NAME
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ecr-token
  namespace: $APP_NAMESPACE
spec:
  refreshInterval: 11h
  target:
    name: ecr-docker-credentials
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: ECRAuthorizationToken
          name: ecr-gen
EOF
```

#### Step 9: Link Pull Secret to Service Accounts

```bash
oc secrets link default ecr-docker-credentials --for=pull -n $APP_NAMESPACE
```

If your workloads use a different service account, link the secret to that account as well.

#### Step 10: Validate with a Test Pod

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ecr-test
  namespace: $APP_NAMESPACE
spec:
  containers:
  - name: test
    image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:latest
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF

oc get pod ecr-test -n $APP_NAMESPACE -w
```

The pod should reach `Running` state, confirming the ESO pipeline (IRSA, token generator, pull secret) is working.

### 8.3 ECR VPC Endpoint Considerations

- The `ecr.api` and `ecr.dkr` VPC endpoints created in Phase 1 serve both the Red Hat ECR mirror and your own ECR repositories in the same region
- No additional VPC endpoints are required for customer ECR access
- The security group on VPC endpoints must allow HTTPS (port 443) inbound from the private subnet CIDR ranges
- For cross-account ECR access, configure ECR repository policies and IAM trust relationships in the source account

---

## 9. Accessing the Cluster

### 9.1 From the Jump Host

The cluster is created with `--private`, so the API endpoint uses AWS PrivateLink. The jump host is in the same VPC and can resolve the private API DNS and reach the endpoint directly via the PrivateLink ENI in the private subnets. No internet routing is involved.

```bash
# Verify DNS resolution first (should return a private IP within the VPC CIDR)
nslookup <api-url>

# Login
oc login <api-url> --username cluster-admin --password <password>
oc get nodes
oc get co
```

### 9.2 AWS Client VPN (Optional, for Remote Access)

For remote access to the private cluster without SSH-ing through the jump host, set up an AWS Client VPN endpoint. If you deployed using the Validated Pattern (Section 6.3), the Client VPN module is integrated — set `enable_client_vpn = true` in your `terraform.tfvars` and import the generated `.ovpn` file into your OpenVPN-compatible client.

For manual setup, see the [AWS Client VPN documentation](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html). The VPN endpoint should be associated with the private subnets in the ROSA VPC.

---

## 10. Cleanup and Teardown

### If Deployed via CLI (Options A/B)

Execute in order:

```bash
# Step 1: Delete the ROSA cluster
rosa delete cluster --cluster=$CLUSTER_NAME --yes --watch

# Step 2: Delete operator roles
rosa delete operator-roles --prefix $OPERATOR_ROLES_PREFIX --oidc-config-id $OIDC_ID --mode auto --yes

# Step 3: Delete OIDC provider
rosa delete oidc-provider --oidc-config-id $OIDC_ID --mode auto --yes

# Step 4: Delete account roles (if no other clusters use them)
rosa delete account-roles --prefix $ACCOUNT_ROLES_PREFIX --hosted-cp --mode auto --yes

# Step 5: Terminate the jump host
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION

# Step 6: Delete VPC resources
# If using Terraform:
cd ~/terraform-vpc-example/zero-egress
terraform destroy -auto-approve

# If created manually, delete in reverse order:
# VPC endpoints → subnets → route tables → IGW → security groups → VPC

# Step 7: Delete ECR repositories (if created)
aws ecr delete-repository --repository-name $ECR_REPOSITORY --force --region $REGION
```

### If Deployed via Validated Pattern (Option C)

```bash
cd validated-pattern-terraform-rosa

# Option 1: Permanent destroy (prompts for confirmation)
make destroy.egress-zero

# Option 2: Sleep the cluster (preserves DNS, IAM, KMS, credentials for restart)
make sleep.egress-zero

# Option 3: Force destroy without confirmation
make destroy_force.egress-zero
```

---

## 11. Troubleshooting

### Cluster Stuck in "installing" State

- Verify VPC endpoints are active: `aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID"`
- Verify subnet tags: `aws ec2 describe-tags --filters "Name=resource-id,Values=<subnet-id>"`
- Verify DNS is enabled on VPC: `aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames`
- Check DHCP option set does not include spaces or capital letters in the domain name
- If using a custom DNS resolver, ensure it can resolve Route53 private hosted zones
- Check installation logs: `rosa logs install --cluster=$CLUSTER_NAME`

### Quota Errors

```bash
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region $REGION
```

If insufficient, request an increase and wait for approval before retrying.

### ECR ImagePullBackOff Errors

- Verify the worker role has `AmazonEC2ContainerRegistryReadOnly` attached
- Verify VPC endpoints for `ecr.api` and `ecr.dkr` are in `available` state
- Verify the security group on VPC endpoints allows HTTPS (443) from private subnets
- For ESO-managed pull secrets, verify the `ExternalSecret` status: `oc get externalsecret -n <namespace>`
- Check if the ECR token has expired: `oc get secret ecr-docker-credentials -n <namespace> -o yaml`

### VPC Endpoint Issues

- Interface endpoints must have `PrivateDnsEnabled: true`
- The security group must allow inbound traffic from the VPC CIDR on port 443
- Verify endpoints exist for all 6 required services (S3, EC2, KMS, STS, ECR API, ECR DKR)

### Cannot Access Cluster API from Jump Host

- Verify the jump host is in the same VPC as the ROSA cluster (or a peered VPC)
- Verify the security group allows outbound traffic to the private subnets
- Run `nslookup <api-url>` to verify DNS resolution

---

## 12. References

### Red Hat Documentation
- [ROSA HCP Zero Egress Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-egress-zero-install)
- [ROSA Best Practices and Recommendations](https://cloud.redhat.com/experts/rosa/best-practices-recommendations/)
- [ROSA Architecture Decision Checklist](https://cloud.redhat.com/experts/rosa/best-practices-checklist/)
- [ROSA Security Reference Architecture](https://cloud.redhat.com/experts/rosa/security-ra/)
- [ROSA CLI Reference](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cli_tools/rosa-cli)
- [Required AWS Service Quotas for ROSA](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-sts-required-aws-service-quotas)

### ECR Integration
- [Configuring ROSA to Pull Images from ECR](https://cloud.redhat.com/experts/rosa/ecr/)
- [Automating ECR Pull Secrets with External Secrets Operator and IRSA](https://cloud.redhat.com/experts/rosa/ecr-external-secrets-irsa)
- [Fine-Grained ECR Repository Access for ROSA (AWS Blog)](https://aws.amazon.com/blogs/ibm-redhat/configuring-rosa-for-fine-grained-ecr-repository-access/)

### AWS Documentation
- [ROSA Getting Started with HCP (AWS)](https://docs.aws.amazon.com/rosa/latest/userguide/getting-started-hcp.html)
- [ROSA Endpoints and Quotas (AWS)](https://docs.aws.amazon.com/general/latest/gr/rosa.html)
- [AWS CLI Installation](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)

### Terraform Resources
- [Terraform VPC Example for Zero Egress](https://github.com/openshift-cs/terraform-vpc-example/tree/main/zero-egress)
- [RHCS Terraform Provider](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest)
- [Validated Pattern Terraform ROSA](https://github.com/rh-mobb/validated-pattern-terraform-rosa)

### Tools
- [ROSA CLI Releases](https://github.com/openshift/rosa/releases)
- [OpenShift CLI Downloads](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)
- [Terraform Downloads](https://releases.hashicorp.com/terraform/)
