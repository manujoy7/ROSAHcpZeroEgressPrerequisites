#!/usr/bin/env bash
# =============================================================================
# ROSA HCP Zero Egress — Prerequisite Validation Script
# =============================================================================
# Run this on the bastion/jump host before starting the ROSA deployment.
# It checks all prerequisites documented in RosaHCPZeroEgressPrequisites.md.
#
# Usage:
#   ./validate-prerequisites.sh                          # auto-detect VPC
#   ./validate-prerequisites.sh --vpc-id vpc-0abc123     # specify VPC
#   ./validate-prerequisites.sh --region us-east-1       # override region
#   ./validate-prerequisites.sh --cluster-name mycluster # specify cluster name
# =============================================================================

set -euo pipefail

# ─── Defaults & Argument Parsing ────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
VPC_ID=""
CLUSTER_NAME=""
MIN_VCPU=100
MIN_PRIVATE_SUBNETS=3
REQUIRED_ENDPOINT_SUFFIXES=("s3" "sts" "ecr.api" "ecr.dkr")
OPTIONAL_ENDPOINT_SUFFIXES=("logs" "monitoring")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpc-id)      VPC_ID="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --min-vcpu)    MIN_VCPU="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--vpc-id VPC_ID] [--region REGION] [--cluster-name NAME] [--min-vcpu N]"
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
echo "║  ROSA HCP Zero Egress — Prerequisite Validation             ║"
echo "║  Region: $REGION                                  ║"
echo "║  $(date)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# =============================================================================
# Section 1: Jump Host Tools (Section 3 of the prerequisites doc)
# =============================================================================
header "1. JUMP HOST — CLI TOOLS"

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
    pass "$label found: v${ver:-unknown} (minimum: $min_ver)"
  else
    fail "$label NOT FOUND — install v${min_ver}+"
  fi
}

check_tool rosa      "1.2.48"  "ROSA CLI"
check_tool aws       "2.0"     "AWS CLI"
check_tool oc        "4.17"    "OpenShift CLI"
check_tool terraform "1.4.0"   "Terraform"
check_tool git       "2.0"     "Git"
check_tool jq        "1.6"     "jq"
check_tool unzip     "6.0"     "unzip"

# =============================================================================
# Section 2: AWS Identity & Region (Section 2.1)
# =============================================================================
header "2. AWS IDENTITY & REGION"

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
  warn "Default region may differ from target ($REGION). Ensure AWS_DEFAULT_REGION is set."
fi

# =============================================================================
# Section 3: AWS Service Quotas (Section 2.2)
# =============================================================================
header "3. AWS SERVICE QUOTAS"

VCPU_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")

if (( $(echo "$VCPU_QUOTA >= $MIN_VCPU" | bc -l 2>/dev/null || echo 0) )); then
  pass "On-Demand Standard vCPU quota: $VCPU_QUOTA (minimum: $MIN_VCPU)"
else
  fail "On-Demand Standard vCPU quota: $VCPU_QUOTA — need at least $MIN_VCPU"
  echo "       Request increase: aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value $MIN_VCPU"
fi

EBS_GP3_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ebs \
  --quota-code L-7A658B76 \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")
if (( $(echo "$EBS_GP3_QUOTA >= 1" | bc -l 2>/dev/null || echo 0) )); then
  pass "EBS gp3 storage quota: ${EBS_GP3_QUOTA} TiB"
else
  warn "EBS gp3 storage quota: ${EBS_GP3_QUOTA} TiB — verify sufficiency"
fi

ELB_QUOTA=$(aws service-quotas get-service-quota \
  --service-code elasticloadbalancing \
  --quota-code L-53DA6B97 \
  --query 'Quota.Value' --output text 2>/dev/null || echo "0")
if (( $(echo "$ELB_QUOTA >= 20" | bc -l 2>/dev/null || echo 0) )); then
  pass "Classic Load Balancer quota: $ELB_QUOTA (minimum: 20)"
else
  warn "Classic Load Balancer quota: $ELB_QUOTA — default of 20 is required"
fi

# =============================================================================
# Section 4: ROSA / Red Hat Account Linking (Section 2.4)
# =============================================================================
header "4. ROSA ACCOUNT LINKING"

if command -v rosa &>/dev/null; then
  ROSA_WHOAMI=$(rosa whoami 2>&1) || true
  if echo "$ROSA_WHOAMI" | grep -q "OCM API"; then
    pass "ROSA CLI is logged in"
    info "$(echo "$ROSA_WHOAMI" | head -5 | sed 's/^/       /')"
  else
    fail "ROSA CLI not logged in — run: rosa login --token=<OCM_TOKEN>"
  fi

  # OCM Role
  OCM_ROLE_OUTPUT=$(rosa list ocm-role 2>&1) || true
  if echo "$OCM_ROLE_OUTPUT" | grep -qi "yes.*yes"; then
    pass "OCM Role: linked with admin"
  elif echo "$OCM_ROLE_OUTPUT" | grep -qi "yes"; then
    warn "OCM Role exists but may not have admin — verify: rosa list ocm-role"
  else
    fail "OCM Role not found or not linked — run: rosa create ocm-role --admin --mode auto --yes"
  fi

  # User Role
  USER_ROLE_OUTPUT=$(rosa list user-role 2>&1) || true
  if echo "$USER_ROLE_OUTPUT" | grep -qi "yes"; then
    pass "User Role: linked"
  else
    fail "User Role not found or not linked — run: rosa create user-role --mode auto --yes"
  fi

  # Account Roles
  ACCOUNT_ROLES=$(rosa list account-roles 2>&1) || true
  HCP_ROLES=$(echo "$ACCOUNT_ROLES" | grep -c "HCP" || true)
  if [[ "$HCP_ROLES" -ge 3 ]]; then
    pass "HCP Account Roles found: $HCP_ROLES roles"
  else
    warn "HCP Account Roles: only $HCP_ROLES found — may need: rosa create account-roles --hosted-cp --mode auto --yes"
  fi
else
  fail "ROSA CLI not installed — cannot check account linking"
fi

# ELB Service-Linked Role
ELB_SLR=$(aws iam get-role --role-name AWSServiceRoleForElasticLoadBalancing 2>&1) || true
if echo "$ELB_SLR" | jq -e '.Role.RoleName' &>/dev/null; then
  pass "ELB service-linked role exists"
else
  fail "ELB service-linked role missing — run: aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com"
fi

# =============================================================================
# Section 5: VPC Configuration (Section 5.1)
# =============================================================================
header "5. VPC CONFIGURATION"

# Auto-detect VPC if not specified
if [[ -z "$VPC_ID" ]]; then
  info "No --vpc-id specified, attempting auto-detect..."
  if [[ -n "$CLUSTER_NAME" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs \
      --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
  fi
  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    # Try to find a VPC with the internal-elb tagged subnets (likely the ROSA VPC)
    VPC_ID=$(aws ec2 describe-subnets \
      --filters "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
      --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo "None")
  fi
  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    fail "Could not auto-detect ROSA VPC. Re-run with --vpc-id <VPC_ID>"
    VPC_ID=""
  fi
fi

if [[ -n "$VPC_ID" ]]; then
  info "Validating VPC: $VPC_ID"

  # VPC exists?
  VPC_INFO=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --output json 2>&1) || true
  if echo "$VPC_INFO" | jq -e '.Vpcs[0]' &>/dev/null; then
    VPC_CIDR=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].CidrBlock')
    VPC_STATE=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].State')
    pass "VPC $VPC_ID exists — CIDR: $VPC_CIDR, State: $VPC_STATE"

    # CIDR size check (minimum /23 recommended)
    CIDR_PREFIX=$(echo "$VPC_CIDR" | cut -d/ -f2)
    if [[ "$CIDR_PREFIX" -le 23 ]]; then
      pass "VPC CIDR /$CIDR_PREFIX meets recommended /23 minimum"
    elif [[ "$CIDR_PREFIX" -le 25 ]]; then
      warn "VPC CIDR /$CIDR_PREFIX is smaller than recommended /23 — may limit scaling"
    else
      fail "VPC CIDR /$CIDR_PREFIX is too small — ROSA HCP requires at least /25 per subnet"
    fi
  else
    fail "VPC $VPC_ID not found in $REGION"
  fi

  # DNS settings
  DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value' --output text 2>/dev/null || echo "false")
  DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport \
    --query 'EnableDnsSupport.Value' --output text 2>/dev/null || echo "false")

  if [[ "$DNS_HOSTNAMES" == "true" ]]; then
    pass "VPC DNS Hostnames: enabled"
  else
    fail "VPC DNS Hostnames: DISABLED — must be enabled for VPC endpoints"
  fi

  if [[ "$DNS_SUPPORT" == "true" ]]; then
    pass "VPC DNS Support: enabled"
  else
    fail "VPC DNS Support: DISABLED — must be enabled"
  fi

  # ─── Subnets (Section 5.2) ───────────────────────────────────────────────
  header "6. PRIVATE SUBNETS"

  PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`]' --output json 2>/dev/null || echo "[]")

  PRIVATE_COUNT=$(echo "$PRIVATE_SUBNETS" | jq 'length')

  if [[ "$PRIVATE_COUNT" -ge "$MIN_PRIVATE_SUBNETS" ]]; then
    pass "Private subnets: $PRIVATE_COUNT found (minimum: $MIN_PRIVATE_SUBNETS)"
  else
    fail "Private subnets: $PRIVATE_COUNT found — need at least $MIN_PRIVATE_SUBNETS"
  fi

  # Check AZ distribution
  AZ_COUNT=$(echo "$PRIVATE_SUBNETS" | jq '[.[].AvailabilityZone] | unique | length')
  if [[ "$AZ_COUNT" -ge 3 ]]; then
    pass "Private subnets span $AZ_COUNT availability zones"
  elif [[ "$AZ_COUNT" -ge 1 ]]; then
    warn "Private subnets span only $AZ_COUNT AZ(s) — 3 AZs recommended for multi-AZ"
  fi

  # Check subnet CIDR sizes
  echo "$PRIVATE_SUBNETS" | jq -r '.[] | "\(.SubnetId) \(.CidrBlock) \(.AvailabilityZone) \(.AvailableIpAddressCount)"' | \
  while read -r sid cidr az ips; do
    PREFIX=$(echo "$cidr" | cut -d/ -f2)
    if [[ "$PREFIX" -le 25 ]]; then
      pass "Subnet $sid ($az): $cidr — $ips IPs available"
    else
      warn "Subnet $sid ($az): $cidr (/$PREFIX) is smaller than recommended /25"
    fi
  done

  # Check subnet tags (Section 5.4)
  header "7. SUBNET TAGS"

  TAGGED_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query 'Subnets[*].SubnetId' --output json 2>/dev/null || echo "[]")
  TAGGED_COUNT=$(echo "$TAGGED_SUBNETS" | jq 'length')

  if [[ "$TAGGED_COUNT" -ge "$MIN_PRIVATE_SUBNETS" ]]; then
    pass "kubernetes.io/role/internal-elb=1 tag: found on $TAGGED_COUNT subnets"
  elif [[ "$TAGGED_COUNT" -ge 1 ]]; then
    warn "kubernetes.io/role/internal-elb=1 tag: only $TAGGED_COUNT subnet(s) tagged — need $MIN_PRIVATE_SUBNETS"
  else
    fail "kubernetes.io/role/internal-elb=1 tag: NOT FOUND on any subnets"
    echo "       Fix: aws ec2 create-tags --resources <subnet-ids> --tags Key=kubernetes.io/role/internal-elb,Value=1"
  fi

  # ─── VPC Endpoints (Section 5.3) ─────────────────────────────────────────
  header "8. VPC ENDPOINTS"

  ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[*].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivateDns:PrivateDnsEnabled}' \
    --output json 2>/dev/null || echo "[]")

  for svc in "${REQUIRED_ENDPOINT_SUFFIXES[@]}"; do
    FULL_SVC="com.amazonaws.${REGION}.${svc}"
    MATCH=$(echo "$ENDPOINTS" | jq -r --arg s "$FULL_SVC" '.[] | select(.Service == $s)')
    if [[ -n "$MATCH" ]]; then
      STATE=$(echo "$MATCH" | jq -r '.State')
      TYPE=$(echo "$MATCH" | jq -r '.Type')
      PDNS=$(echo "$MATCH" | jq -r '.PrivateDns // "N/A"')

      if [[ "$STATE" == "available" ]]; then
        pass "$svc endpoint ($TYPE): available"
      else
        fail "$svc endpoint ($TYPE): state is '$STATE' — expected 'available'"
      fi

      # PrivateDnsEnabled check for Interface endpoints
      if [[ "$TYPE" == "Interface" ]]; then
        if [[ "$PDNS" == "true" ]]; then
          pass "$svc endpoint: PrivateDnsEnabled=true"
        else
          fail "$svc endpoint: PrivateDnsEnabled=$PDNS — must be true for Interface endpoints"
        fi
      fi
    else
      fail "$svc endpoint: NOT FOUND — required for zero-egress"
      echo "       Create: aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name $FULL_SVC ..."
    fi
  done

  # Optional CloudWatch endpoints
  for svc in "${OPTIONAL_ENDPOINT_SUFFIXES[@]}"; do
    FULL_SVC="com.amazonaws.${REGION}.${svc}"
    MATCH=$(echo "$ENDPOINTS" | jq -r --arg s "$FULL_SVC" '.[] | select(.Service == $s)')
    if [[ -n "$MATCH" ]]; then
      STATE=$(echo "$MATCH" | jq -r '.State')
      info "$svc endpoint: present ($STATE) — optional, for CloudWatch log forwarding"
    else
      info "$svc endpoint: not present — optional, only needed if using Validated Pattern with CloudWatch forwarding"
    fi
  done

  # Check endpoint security groups allow HTTPS from VPC CIDR
  header "9. VPC ENDPOINT SECURITY GROUPS"

  INTERFACE_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=vpc-endpoint-type,Values=Interface" \
    --query 'VpcEndpoints[*].{Service:ServiceName,Groups:Groups[*].GroupId}' \
    --output json 2>/dev/null || echo "[]")

  SG_IDS=$(echo "$INTERFACE_ENDPOINTS" | jq -r '.[].Groups[]' | sort -u)

  for sg in $SG_IDS; do
    ALLOWS_443=$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query "SecurityGroups[0].IpPermissions[?ToPort==\`443\` && FromPort==\`443\`]" \
      --output json 2>/dev/null || echo "[]")

    if [[ $(echo "$ALLOWS_443" | jq 'length') -gt 0 ]]; then
      pass "Security group $sg: allows inbound HTTPS (443)"
    else
      fail "Security group $sg: no inbound rule for HTTPS (443) — VPC endpoints require this"
      echo "       Fix: aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 443 --cidr $VPC_CIDR"
    fi
  done

  if [[ -z "$SG_IDS" ]]; then
    info "No interface endpoint security groups to check (endpoints may not exist yet)"
  fi

  # ─── Route Tables ────────────────────────────────────────────────────────
  header "10. ROUTE TABLES"

  # Check that private subnets have route tables (no default route to IGW)
  echo "$PRIVATE_SUBNETS" | jq -r '.[].SubnetId' | while read -r sid; do
    RTB=$(aws ec2 describe-route-tables \
      --filters "Name=association.subnet-id,Values=$sid" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")

    if [[ "$RTB" == "None" ]]; then
      RTB=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None")
      info "Subnet $sid uses main route table: $RTB"
    fi

    if [[ "$RTB" != "None" ]]; then
      HAS_IGW_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$RTB" \
        --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, 'igw-')]" \
        --output json 2>/dev/null || echo "[]")

      if [[ $(echo "$HAS_IGW_ROUTE" | jq 'length') -eq 0 ]]; then
        pass "Subnet $sid: no internet gateway route (correct for private/zero-egress)"
      else
        warn "Subnet $sid: has route to Internet Gateway — private subnets should not route to IGW for zero-egress"
      fi
    fi
  done

  # Check S3 gateway endpoint is in route tables
  S3_GW=$(echo "$ENDPOINTS" | jq -r '.[] | select(.Service | endswith(".s3")) | select(.Type == "Gateway")')
  if [[ -n "$S3_GW" ]]; then
    pass "S3 Gateway endpoint present — route table entries managed automatically by AWS"
  fi

else
  warn "Skipping VPC, subnet, endpoint, and route table checks (no VPC ID)"
fi

# =============================================================================
# Section 6: ROSA CLI Verification (Section 2.4 / 6)
# =============================================================================
header "11. ROSA VERIFICATION COMMANDS"

if command -v rosa &>/dev/null; then
  ROSA_VERIFY=$(rosa verify permissions 2>&1) || true
  if echo "$ROSA_VERIFY" | grep -qi "sufficient"; then
    pass "rosa verify permissions: sufficient"
  elif echo "$ROSA_VERIFY" | grep -qi "error\|fail"; then
    fail "rosa verify permissions: failed — check IAM permissions"
  else
    info "rosa verify permissions: $(echo "$ROSA_VERIFY" | head -1)"
  fi

  ROSA_QUOTA=$(rosa verify quota --region="$REGION" 2>&1) || true
  if echo "$ROSA_QUOTA" | grep -qi "sufficient"; then
    pass "rosa verify quota: sufficient"
  elif echo "$ROSA_QUOTA" | grep -qi "error\|fail"; then
    fail "rosa verify quota: failed — check service quotas"
  else
    info "rosa verify quota: $(echo "$ROSA_QUOTA" | head -1)"
  fi
else
  fail "ROSA CLI not available — cannot run verify commands"
fi

# =============================================================================
# Section 7: Network Connectivity from Jump Host
# =============================================================================
header "12. JUMP HOST NETWORK CONNECTIVITY"

check_url() {
  local url="$1" label="$2"
  if curl -sf --connect-timeout 5 --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    pass "$label: reachable"
  else
    fail "$label: NOT reachable from this host"
  fi
}

check_url "https://sso.redhat.com"            "sso.redhat.com (Red Hat SSO)"
check_url "https://api.openshift.com"          "api.openshift.com (ROSA API)"
check_url "https://console.redhat.com"         "console.redhat.com (Hybrid Cloud Console)"
check_url "https://registry.terraform.io"      "registry.terraform.io (Terraform Registry)"
check_url "https://mirror.openshift.com"       "mirror.openshift.com (CLI downloads)"
check_url "https://github.com"                 "github.com (Git repos)"
check_url "https://releases.hashicorp.com"     "releases.hashicorp.com (Terraform binaries)"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
printf "║  \033[1mVALIDATION SUMMARY\033[0m                                          ║\n"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  \033[32m✓ PASS : %-4d\033[0m                                              ║\n" "$PASS"
printf "║  \033[31m✗ FAIL : %-4d\033[0m                                              ║\n" "$FAIL"
printf "║  \033[33m⚠ WARN : %-4d\033[0m                                              ║\n" "$WARN"
printf "║  \033[36mℹ INFO : %-4d\033[0m                                              ║\n" "$INFO"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  printf "\033[32m✓ All prerequisite checks passed. Ready for ROSA HCP zero-egress deployment.\033[0m\n"
  exit 0
elif [[ "$FAIL" -le 3 ]]; then
  printf "\033[33m⚠ $FAIL issue(s) found. Review the FAIL items above before proceeding.\033[0m\n"
  exit 1
else
  printf "\033[31m✗ $FAIL issues found. Fix the FAIL items before starting deployment.\033[0m\n"
  exit 1
fi
