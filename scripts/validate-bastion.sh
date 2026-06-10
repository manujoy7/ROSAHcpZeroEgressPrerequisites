#!/usr/bin/env bash
# =============================================================================
# ROSA HCP Zero Egress — Bastion Host Validation
# =============================================================================
# Validates that the bastion/jump host is correctly set up for ROSA deployment:
#   - CLI tools installed with correct versions
#   - AWS credentials configured and working
#   - ROSA CLI logged in and account linking complete
#   - Network connectivity to all required external URLs
#
# This script requires NO inputs — it checks the local machine it runs on.
#
# Usage:
#   ./validate-bastion.sh
#   ./validate-bastion.sh --region ap-southeast-1    # override region
# =============================================================================

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--region REGION]"
      echo ""
      echo "Validates the bastion/jump host readiness for ROSA deployment."
      echo "No VPC or cluster inputs needed — this checks the local machine only."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

export AWS_DEFAULT_REGION="$REGION"

# ─── Output Helpers ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; INFO=0
pass()  { PASS=$((PASS+1)); printf "  \033[32m✓ PASS\033[0m  %s\n" "$1"; }
fail()  { FAIL=$((FAIL+1)); printf "  \033[31m✗ FAIL\033[0m  %s\n" "$1"; }
warn()  { WARN=$((WARN+1)); printf "  \033[33m⚠ WARN\033[0m  %s\n" "$1"; }
info()  { INFO=$((INFO+1)); printf "  \033[36mℹ INFO\033[0m  %s\n" "$1"; }
header(){ printf "\n\033[1;37m━━━ %s ━━━\033[0m\n" "$1"; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  ROSA HCP Zero Egress — Bastion Host Validation             ║"
echo "║  Region: $REGION                                  ║"
echo "║  $(date)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# =============================================================================
# 1. CLI Tools
# =============================================================================
header "1. CLI TOOLS"

check_tool() {
  local cmd="$1" min_ver="$2" label="$3"
  if command -v "$cmd" &>/dev/null; then
    local ver
    case "$cmd" in
      rosa)      ver=$(rosa version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
      aws)       ver=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+\.[0-9]+\.[0-9]+' | cut -d/ -f2) ;;
      oc)        ver=$(oc version --client 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
      terraform) ver=$(terraform --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v) ;;
      git)       ver=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') ;;
      jq)        ver=$(jq --version 2>&1 | grep -oE '[0-9]+\.[0-9.]+') ;;
      unzip)     ver=$(unzip -v 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1) ;;
      *)         ver="unknown" ;;
    esac
    pass "$label: v${ver:-unknown} (minimum: $min_ver)"
  else
    fail "$label: NOT FOUND — install v${min_ver}+"
  fi
}

check_tool rosa      "1.2.48"  "ROSA CLI"
check_tool aws       "2.0"     "AWS CLI"
check_tool oc        "4.17"    "OpenShift CLI (oc)"
check_tool terraform "1.4.0"   "Terraform"
check_tool git       "2.0"     "Git"
check_tool jq        "1.6"     "jq"
check_tool unzip     "6.0"     "unzip"

# =============================================================================
# 2. AWS Credentials & Region
# =============================================================================
header "2. AWS CREDENTIALS & REGION"

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || true
if echo "$CALLER_IDENTITY" | jq -e '.Account' &>/dev/null; then
  AWS_ACCOUNT=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
  AWS_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
  pass "AWS credentials valid — Account: $AWS_ACCOUNT"
  info "IAM identity: $AWS_ARN"
else
  fail "AWS credentials not configured or expired"
  echo "       Run: aws configure"
fi

if [[ "$REGION" == "$(aws configure get region 2>/dev/null || echo '')" ]] || [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
  pass "Region is set to $REGION"
else
  warn "Default region may differ from target ($REGION). Set AWS_DEFAULT_REGION=$REGION"
fi

# =============================================================================
# 3. ROSA Account Linking
# =============================================================================
header "3. ROSA ACCOUNT LINKING"

if command -v rosa &>/dev/null; then
  ROSA_WHOAMI=$(rosa whoami 2>&1) || true
  if echo "$ROSA_WHOAMI" | grep -q "OCM API"; then
    pass "ROSA CLI logged in"
    info "$(echo "$ROSA_WHOAMI" | grep -E 'AWS Account|OCM Account|OCM API' | sed 's/^/       /')"
  else
    fail "ROSA CLI not logged in — run: rosa login --token=<OCM_TOKEN>"
  fi

  OCM_ROLE_OUTPUT=$(rosa list ocm-role 2>&1) || true
  if echo "$OCM_ROLE_OUTPUT" | grep -qi "yes.*yes"; then
    pass "OCM Role: linked with admin"
  elif echo "$OCM_ROLE_OUTPUT" | grep -qi "yes"; then
    warn "OCM Role exists but may not have admin — verify: rosa list ocm-role"
  else
    fail "OCM Role not found or not linked — run: rosa create ocm-role --admin --mode auto --yes"
  fi

  USER_ROLE_OUTPUT=$(rosa list user-role 2>&1) || true
  if echo "$USER_ROLE_OUTPUT" | grep -qi "yes"; then
    pass "User Role: linked"
  else
    fail "User Role not found or not linked — run: rosa create user-role --mode auto --yes"
  fi

  ACCOUNT_ROLES=$(rosa list account-roles 2>&1) || true
  HCP_ROLES=$(echo "$ACCOUNT_ROLES" | grep -c "HCP" || true)
  if [[ "$HCP_ROLES" -ge 3 ]]; then
    pass "HCP Account Roles: $HCP_ROLES found"
  else
    warn "HCP Account Roles: only $HCP_ROLES found — may need: rosa create account-roles --hosted-cp --mode auto --yes"
  fi
else
  fail "ROSA CLI not installed — cannot check account linking"
fi

ELB_SLR=$(aws iam get-role --role-name AWSServiceRoleForElasticLoadBalancing 2>&1) || true
if echo "$ELB_SLR" | jq -e '.Role.RoleName' &>/dev/null; then
  pass "ELB service-linked role exists"
else
  fail "ELB service-linked role missing — run: aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com"
fi

# =============================================================================
# 4. AWS Service Quotas
# =============================================================================
header "4. AWS SERVICE QUOTAS (in $REGION)"

MIN_VCPU=100
VCPU_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")
if (( $(echo "$VCPU_QUOTA >= $MIN_VCPU" | bc -l 2>/dev/null || echo 0) )); then
  pass "On-Demand Standard vCPU quota: $VCPU_QUOTA (minimum: $MIN_VCPU)"
else
  fail "On-Demand Standard vCPU quota: $VCPU_QUOTA — need at least $MIN_VCPU"
  echo "       Request: aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value $MIN_VCPU"
fi

EBS_GP3_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ebs --quota-code L-7A658B76 \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")
if (( $(echo "$EBS_GP3_QUOTA >= 1" | bc -l 2>/dev/null || echo 0) )); then
  pass "EBS gp3 storage quota: ${EBS_GP3_QUOTA} TiB"
else
  warn "EBS gp3 storage quota: ${EBS_GP3_QUOTA} TiB — verify sufficiency"
fi

ELB_QUOTA=$(aws service-quotas get-service-quota \
  --service-code elasticloadbalancing --quota-code L-53DA6B97 \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")
if (( $(echo "$ELB_QUOTA >= 20" | bc -l 2>/dev/null || echo 0) )); then
  pass "Classic Load Balancer quota: $ELB_QUOTA (minimum: 20)"
else
  warn "Classic Load Balancer quota: $ELB_QUOTA — default of 20 is required"
fi

# =============================================================================
# 5. ROSA Verify Commands
# =============================================================================
header "5. ROSA VERIFY"

if command -v rosa &>/dev/null; then
  ROSA_VERIFY=$(rosa verify permissions 2>&1) || true
  if echo "$ROSA_VERIFY" | grep -qi "sufficient\|have required permissions"; then
    pass "rosa verify permissions: sufficient"
  elif echo "$ROSA_VERIFY" | grep -qi "error\|fail\|denied"; then
    fail "rosa verify permissions: failed — check IAM permissions"
  else
    info "rosa verify permissions: $(echo "$ROSA_VERIFY" | head -1)"
  fi

  ROSA_QUOTA=$(rosa verify quota --region="$REGION" 2>&1) || true
  if echo "$ROSA_QUOTA" | grep -qi "sufficient\|validated"; then
    pass "rosa verify quota: sufficient in $REGION"
  elif echo "$ROSA_QUOTA" | grep -qi "error\|fail\|insufficient"; then
    fail "rosa verify quota: failed — check service quotas in $REGION"
  else
    info "rosa verify quota: $(echo "$ROSA_QUOTA" | head -1)"
  fi
fi

# =============================================================================
# 6. Network Connectivity to Required URLs
# =============================================================================
header "6. NETWORK CONNECTIVITY"

info "Testing HTTPS reachability to required external services..."

check_url() {
  local url="$1" label="$2"
  if curl -sf --connect-timeout 5 --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    pass "$label: reachable"
  else
    fail "$label: NOT reachable — check firewall/proxy settings"
  fi
}

check_url "https://sso.redhat.com"            "sso.redhat.com (Red Hat SSO)"
check_url "https://api.openshift.com"          "api.openshift.com (ROSA API)"
check_url "https://console.redhat.com"         "console.redhat.com (Hybrid Cloud Console)"
check_url "https://registry.terraform.io"      "registry.terraform.io (Terraform Registry)"
check_url "https://releases.hashicorp.com"     "releases.hashicorp.com (Terraform binaries)"
check_url "https://mirror.openshift.com"       "mirror.openshift.com (CLI downloads)"
check_url "https://github.com"                 "github.com (Git repos)"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
printf "║  \033[1mBASTION HOST VALIDATION SUMMARY\033[0m                              ║\n"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  \033[32m✓ PASS : %-4d\033[0m                                              ║\n" "$PASS"
printf "║  \033[31m✗ FAIL : %-4d\033[0m                                              ║\n" "$FAIL"
printf "║  \033[33m⚠ WARN : %-4d\033[0m                                              ║\n" "$WARN"
printf "║  \033[36mℹ INFO : %-4d\033[0m                                              ║\n" "$INFO"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  printf "\033[32m✓ Bastion host is ready. Next: run validate-rosa-vpc.sh to check the ROSA VPC.\033[0m\n"
  exit 0
else
  printf "\033[31m✗ $FAIL issue(s) found. Fix the FAIL items above before proceeding.\033[0m\n"
  exit 1
fi
