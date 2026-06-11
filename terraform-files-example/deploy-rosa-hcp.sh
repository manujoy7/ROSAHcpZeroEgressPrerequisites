#!/usr/bin/env bash
# =============================================================================
# ROSA HCP Zero Egress — Deployment Script
# =============================================================================
# This script collects all required inputs, generates terraform.tfvars,
# and deploys a ROSA HCP zero-egress cluster using the official
# terraform-redhat/rosa-hcp/rhcs module with a BYO (pre-existing) VPC.
#
# Prerequisites:
#   - terraform >= 1.4.0 installed
#   - aws CLI configured with credentials for the target account
#   - rosa CLI installed and logged in (export RHCS_TOKEN=...)
#   - VPC already created with: private subnets, VPC endpoints, DNS enabled
#   - Run validate-bastion.sh and validate-rosa-vpc.sh before this script
#
# Usage:
#   ./deploy-rosa-hcp.sh                    # interactive — prompts for all values
#   ./deploy-rosa-hcp.sh --auto             # uses defaults + auto-detects VPC
#   ./deploy-rosa-hcp.sh --destroy          # destroys the cluster
#   ./deploy-rosa-hcp.sh --plan-only        # generates tfvars and runs plan only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"

# ─── Defaults ───────────────────────────────────────────────────────────────
DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
DEFAULT_OPENSHIFT_VERSION="4.20.24"
DEFAULT_COMPUTE_TYPE="m5.xlarge"
DEFAULT_REPLICAS=3
DEFAULT_SERVICE_CIDR="172.30.0.0/16"
DEFAULT_POD_CIDR="10.128.0.0/14"
DEFAULT_HOST_PREFIX=23

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}ℹ${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${NC}  %s\n" "$1"; }
err()   { printf "${RED}✗${NC}  %s\n" "$1"; }

prompt() {
  local var_name="$1" prompt_text="$2" default="$3"
  local value
  if [[ -n "$default" ]]; then
    printf "${BOLD}%s${NC} [${CYAN}%s${NC}]: " "$prompt_text" "$default"
  else
    printf "${BOLD}%s${NC}: " "$prompt_text"
  fi
  read -r value
  value="${value:-$default}"
  eval "$var_name=\"$value\""
}

# ─── Parse Arguments ────────────────────────────────────────────────────────
MODE="interactive"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)      MODE="auto"; shift ;;
    --destroy)   MODE="destroy"; shift ;;
    --plan-only) MODE="plan-only"; shift ;;
    -h|--help)
      echo "Usage: $0 [--auto|--destroy|--plan-only]"
      echo ""
      echo "  (no flags)    Interactive mode — prompts for all values"
      echo "  --auto        Auto-detect VPC and use defaults"
      echo "  --destroy     Destroy the cluster"
      echo "  --plan-only   Generate terraform.tfvars and run plan only"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Destroy Mode ───────────────────────────────────────────────────────────
if [[ "$MODE" == "destroy" ]]; then
  echo ""
  printf "${RED}${BOLD}⚠  CLUSTER DESTRUCTION${NC}\n"
  echo ""
  if [[ ! -f "$TFVARS_FILE" ]]; then
    err "No terraform.tfvars found. Nothing to destroy."
    exit 1
  fi
  info "Using existing terraform.tfvars"
  cd "$SCRIPT_DIR"
  terraform init -input=false
  terraform destroy -var-file="terraform.tfvars" -auto-approve
  ok "Cluster destroyed successfully"
  exit 0
fi

# =============================================================================
# Preflight Checks
# =============================================================================
echo ""
printf "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${BOLD}║  ROSA HCP Zero Egress — Deployment                          ║${NC}\n"
printf "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}\n"
echo ""

# Check tools
for cmd in terraform aws rosa jq; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd is not installed. Install it before running this script."
    exit 1
  fi
done
ok "Required CLI tools found"

# Check RHCS_TOKEN
if [[ -z "${RHCS_TOKEN:-}" ]]; then
  err "RHCS_TOKEN environment variable is not set."
  echo "   Run: export RHCS_TOKEN=\$(rosa token)"
  exit 1
fi
ok "RHCS_TOKEN is set"

# Check AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || true
if [[ -z "$AWS_ACCOUNT" ]]; then
  err "AWS credentials not configured. Run: aws configure"
  exit 1
fi
ok "AWS credentials valid — Account: $AWS_ACCOUNT"

# =============================================================================
# Collect Inputs
# =============================================================================
echo ""
printf "${BOLD}━━━ Cluster Configuration ━━━${NC}\n"

if [[ "$MODE" == "interactive" ]]; then
  prompt CLUSTER_NAME      "Cluster name"               ""
  prompt REGION            "AWS region"                  "$DEFAULT_REGION"
  prompt OPENSHIFT_VERSION "OpenShift version"           "$DEFAULT_OPENSHIFT_VERSION"
  prompt BILLING_ACCOUNT   "AWS billing account ID"      "$AWS_ACCOUNT"
  prompt COMPUTE_TYPE      "Worker instance type"        "$DEFAULT_COMPUTE_TYPE"
  prompt REPLICAS          "Number of worker nodes"      "$DEFAULT_REPLICAS"
else
  CLUSTER_NAME="${TF_VAR_cluster_name:-}"
  if [[ -z "$CLUSTER_NAME" ]]; then
    prompt CLUSTER_NAME "Cluster name" ""
  fi
  REGION="$DEFAULT_REGION"
  OPENSHIFT_VERSION="$DEFAULT_OPENSHIFT_VERSION"
  BILLING_ACCOUNT="$AWS_ACCOUNT"
  COMPUTE_TYPE="$DEFAULT_COMPUTE_TYPE"
  REPLICAS="$DEFAULT_REPLICAS"
fi

# Validate cluster name
if ! [[ "$CLUSTER_NAME" =~ ^[a-z][-a-z0-9]{0,13}[a-z0-9]$ ]]; then
  err "Cluster name must be 2-15 chars, lowercase alphanumeric/hyphens, start with letter"
  exit 1
fi
ok "Cluster name: $CLUSTER_NAME"

# =============================================================================
# VPC Discovery
# =============================================================================
echo ""
printf "${BOLD}━━━ VPC Configuration ━━━${NC}\n"

export AWS_DEFAULT_REGION="$REGION"

if [[ "$MODE" == "interactive" ]]; then
  prompt VPC_ID "VPC ID (leave blank to auto-detect)" ""
fi

if [[ -z "${VPC_ID:-}" ]]; then
  info "Auto-detecting VPC..."

  # Search by cluster name tag
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

  # Search by internal-elb tagged subnets
  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    TAGGED_VPCS=$(aws ec2 describe-subnets \
      --filters "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
      --query 'Subnets[*].VpcId' --output json 2>/dev/null || echo "[]")
    UNIQUE_VPCS=$(echo "$TAGGED_VPCS" | jq -r 'unique[]')
    VPC_COUNT=$(echo "$UNIQUE_VPCS" | grep -c 'vpc-' || true)

    if [[ "$VPC_COUNT" -eq 1 ]]; then
      VPC_ID="$UNIQUE_VPCS"
    elif [[ "$VPC_COUNT" -gt 1 ]]; then
      warn "Multiple VPCs found with ROSA subnet tags:"
      for vid in $UNIQUE_VPCS; do
        VPC_NAME=$(aws ec2 describe-vpcs --vpc-ids "$vid" \
          --query 'Vpcs[0].Tags[?Key==`Name`].Value|[0]' --output text 2>/dev/null || echo "unnamed")
        VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$vid" \
          --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || echo "unknown")
        echo "    $vid  ($VPC_CIDR)  $VPC_NAME"
      done
      prompt VPC_ID "Enter the VPC ID to use" ""
    fi
  fi

  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    err "Could not auto-detect VPC. Provide the VPC ID manually."
    prompt VPC_ID "VPC ID" ""
  fi
fi

# Get VPC CIDR
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || echo "")
if [[ -z "$VPC_CIDR" ]]; then
  err "VPC $VPC_ID not found in $REGION"
  exit 1
fi
ok "VPC: $VPC_ID (CIDR: $VPC_CIDR)"

# =============================================================================
# Subnet Discovery
# =============================================================================
echo ""
printf "${BOLD}━━━ Subnet Discovery ━━━${NC}\n"

PRIVATE_SUBNETS_JSON=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`]' --output json 2>/dev/null || echo "[]")

SUBNET_COUNT=$(echo "$PRIVATE_SUBNETS_JSON" | jq 'length')

if [[ "$SUBNET_COUNT" -lt 1 ]]; then
  err "No private subnets found in VPC $VPC_ID"
  exit 1
fi

info "Found $SUBNET_COUNT private subnets:"
SUBNET_IDS=()
AZ_LIST=()

echo "$PRIVATE_SUBNETS_JSON" | jq -r '.[] | "\(.SubnetId) \(.AvailabilityZone) \(.CidrBlock) \(.AvailableIpAddressCount)"' | \
while read -r sid az cidr ips; do
  SUBNET_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$sid" "Name=key,Values=Name" \
    --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
  NAME_LABEL=""
  [[ -n "$SUBNET_NAME" && "$SUBNET_NAME" != "None" ]] && NAME_LABEL=" ($SUBNET_NAME)"
  printf "    ${CYAN}%s${NC}%s  %s  %s  %s IPs\n" "$sid" "$NAME_LABEL" "$az" "$cidr" "$ips"
done

# Build arrays
SUBNET_IDS_STR=$(echo "$PRIVATE_SUBNETS_JSON" | jq -r '.[].SubnetId' | paste -sd',' -)
AZ_LIST_STR=$(echo "$PRIVATE_SUBNETS_JSON" | jq -r '[.[].AvailabilityZone] | unique | .[]' | paste -sd',' -)

# Format for tfvars
SUBNET_IDS_TF=$(echo "$PRIVATE_SUBNETS_JSON" | jq -r '.[].SubnetId' | awk '{printf "  \"%s\",\n", $1}')
AZ_LIST_TF=$(echo "$PRIVATE_SUBNETS_JSON" | jq -r '[.[].AvailabilityZone] | unique | .[]' | awk '{printf "  \"%s\",\n", $1}')

ok "Subnets and AZs collected"

# =============================================================================
# Generate terraform.tfvars
# =============================================================================
echo ""
printf "${BOLD}━━━ Generating terraform.tfvars ━━━${NC}\n"

cat > "$TFVARS_FILE" << TFVARS
# =============================================================================
# ROSA HCP Zero Egress — Generated by deploy-rosa-hcp.sh
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# =============================================================================

##############################################################
# Cluster Identity
##############################################################
cluster_name      = "${CLUSTER_NAME}"
openshift_version = "${OPENSHIFT_VERSION}"

##############################################################
# AWS Account & Billing
##############################################################
aws_billing_account_id = "${BILLING_ACCOUNT}"

##############################################################
# BYO VPC — Pre-Existing Network
##############################################################
aws_subnet_ids = [
${SUBNET_IDS_TF}]

aws_availability_zones = [
${AZ_LIST_TF}]

machine_cidr = "${VPC_CIDR}"

##############################################################
# Worker Nodes
##############################################################
replicas             = ${REPLICAS}
compute_machine_type = "${COMPUTE_TYPE}"

##############################################################
# Network CIDRs
##############################################################
service_cidr = "${DEFAULT_SERVICE_CIDR}"
pod_cidr     = "${DEFAULT_POD_CIDR}"
host_prefix  = ${DEFAULT_HOST_PREFIX}

##############################################################
# Tags
##############################################################
tags = {
  Environment  = "production"
  ManagedBy    = "terraform"
  Project      = "${CLUSTER_NAME}"
  ClusterName  = "${CLUSTER_NAME}"
}
TFVARS

ok "Generated: $TFVARS_FILE"
echo ""
info "Contents:"
echo "─────────────────────────────────────────────"
cat "$TFVARS_FILE"
echo "─────────────────────────────────────────────"

# =============================================================================
# Terraform Init & Plan
# =============================================================================
echo ""
printf "${BOLD}━━━ Terraform Init ━━━${NC}\n"

cd "$SCRIPT_DIR"
terraform init -input=false

echo ""
printf "${BOLD}━━━ Terraform Plan ━━━${NC}\n"

terraform plan -var-file="terraform.tfvars" -out=tfplan

if [[ "$MODE" == "plan-only" ]]; then
  echo ""
  ok "Plan complete. Review above and run: terraform apply tfplan"
  exit 0
fi

# =============================================================================
# Confirm & Apply
# =============================================================================
echo ""
printf "${YELLOW}${BOLD}━━━ Ready to Deploy ━━━${NC}\n"
echo ""
info "Cluster:    $CLUSTER_NAME"
info "Region:     $REGION"
info "Version:    $OPENSHIFT_VERSION"
info "VPC:        $VPC_ID ($VPC_CIDR)"
info "Subnets:    $SUBNET_COUNT private subnets"
info "Workers:    $REPLICAS x $COMPUTE_TYPE"
info "Billing:    $BILLING_ACCOUNT"
info "Zero Egress: enabled"
info "Private API: enabled (PrivateLink)"
echo ""

if [[ "$MODE" == "interactive" ]]; then
  printf "${BOLD}Proceed with deployment? (yes/no)${NC}: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    warn "Deployment cancelled."
    exit 0
  fi
fi

echo ""
printf "${BOLD}━━━ Terraform Apply ━━━${NC}\n"
terraform apply tfplan

echo ""
printf "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${GREEN}${BOLD}║  ✓ ROSA HCP Cluster Deployed Successfully                    ║${NC}\n"
printf "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}\n"
echo ""
info "Cluster:     $CLUSTER_NAME"
info "Region:      $REGION"
terraform output -json 2>/dev/null | jq -r 'to_entries[] | "  ℹ  \(.key): \(.value.value)"' 2>/dev/null || true
echo ""
info "To access the cluster:"
echo "    oc login \$(terraform output -raw cluster_api_url) -u cluster-admin -p \$(terraform output -raw admin_password)"
echo ""
info "To destroy the cluster:"
echo "    $0 --destroy"
