#!/usr/bin/env bash
# =============================================================================
# ROSA HCP Zero Egress — ROSA VPC Validation
# =============================================================================
# Validates that the ROSA VPC is correctly configured for cluster deployment:
#   - VPC exists with correct CIDR and DNS settings
#   - Private subnets (count, AZ spread, CIDR sizes)
#   - Subnet tags (kubernetes.io/role/internal-elb)
#   - VPC endpoints (S3, STS, ECR API, ECR DKR + optional CloudWatch)
#   - Endpoint security groups (HTTPS 443 inbound)
#   - Route tables (no IGW routes on private subnets)
#
# Required inputs:
#   --vpc-id       The VPC ID to validate (REQUIRED unless auto-detected)
#   --region       AWS region (defaults to AWS_DEFAULT_REGION or ap-southeast-1)
#
# VPC Discovery (if --vpc-id is not provided):
#   1. If --cluster-name is given, searches for a VPC tagged with that name
#   2. Searches for any VPC with subnets tagged kubernetes.io/role/internal-elb
#   3. If multiple VPCs match, lists them and asks the user to specify --vpc-id
#
# Usage:
#   ./validate-rosa-vpc.sh --vpc-id vpc-0abc123
#   ./validate-rosa-vpc.sh --cluster-name prod-rosa-sg
#   ./validate-rosa-vpc.sh                                # auto-detect
#   ./validate-rosa-vpc.sh --vpc-id vpc-0abc123 --region us-east-1
# =============================================================================

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
VPC_ID=""
CLUSTER_NAME=""
MIN_PRIVATE_SUBNETS=3
REQUIRED_ENDPOINT_SUFFIXES=("s3" "sts" "ecr.api" "ecr.dkr")
OPTIONAL_ENDPOINT_SUFFIXES=("logs" "monitoring")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpc-id)       VPC_ID="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--vpc-id VPC_ID] [--region REGION] [--cluster-name NAME]"
      echo ""
      echo "Validates a VPC for ROSA HCP zero-egress deployment."
      echo ""
      echo "Required:"
      echo "  --vpc-id VPC_ID         VPC to validate (or omit for auto-detection)"
      echo ""
      echo "Optional:"
      echo "  --region REGION         AWS region (default: \$AWS_DEFAULT_REGION or ap-southeast-1)"
      echo "  --cluster-name NAME     Cluster name — used to find VPC by tag if --vpc-id is omitted"
      echo ""
      echo "Auto-detection strategy (when --vpc-id is not provided):"
      echo "  1. Search for VPCs tagged with --cluster-name"
      echo "  2. Search for VPCs with kubernetes.io/role/internal-elb tagged subnets"
      echo "  3. If multiple VPCs match, list them and exit"
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
echo "║  ROSA HCP Zero Egress — VPC Validation                      ║"
echo "║  Region: $REGION                                  ║"
echo "║  $(date)                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# =============================================================================
# VPC Discovery
# =============================================================================
header "1. VPC DISCOVERY"

if [[ -n "$VPC_ID" ]]; then
  info "VPC provided via --vpc-id: $VPC_ID"
else
  info "No --vpc-id specified — attempting auto-detection..."

  CANDIDATE_VPCS=()

  # Strategy 1: search by cluster name tag
  if [[ -n "$CLUSTER_NAME" ]]; then
    TAGGED_VPCS=$(aws ec2 describe-vpcs \
      --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
      --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
      --output json 2>/dev/null || echo "[]")
    while IFS= read -r line; do
      [[ -n "$line" ]] && CANDIDATE_VPCS+=("$line")
    done < <(echo "$TAGGED_VPCS" | jq -r '.[] | "\(.[0]) \(.[1]) \(.[2] // "unnamed")"')
  fi

  # Strategy 2: search by internal-elb tagged subnets
  if [[ ${#CANDIDATE_VPCS[@]} -eq 0 ]]; then
    ELB_VPCS=$(aws ec2 describe-subnets \
      --filters "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
      --query 'Subnets[*].VpcId' --output json 2>/dev/null || echo "[]")
    UNIQUE_VPCS=$(echo "$ELB_VPCS" | jq -r 'unique[]')
    for vid in $UNIQUE_VPCS; do
      VPC_DETAIL=$(aws ec2 describe-vpcs --vpc-ids "$vid" \
        --query 'Vpcs[0].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
        --output json 2>/dev/null || echo "[]")
      CANDIDATE_VPCS+=("$(echo "$VPC_DETAIL" | jq -r '"\(.[0]) \(.[1]) \(.[2] // "unnamed")"')")
    done
  fi

  if [[ ${#CANDIDATE_VPCS[@]} -eq 0 ]]; then
    fail "No ROSA VPC found. Specify --vpc-id or --cluster-name."
    echo ""
    echo "  To list all VPCs in this region:"
    echo "    aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==\`Name\`].Value|[0]]' --output table"
    echo ""
    exit 1
  elif [[ ${#CANDIDATE_VPCS[@]} -eq 1 ]]; then
    VPC_ID=$(echo "${CANDIDATE_VPCS[0]}" | awk '{print $1}')
    VPC_NAME=$(echo "${CANDIDATE_VPCS[0]}" | awk '{print $3}')
    pass "Auto-detected VPC: $VPC_ID ($VPC_NAME)"
  else
    echo ""
    printf "  \033[33mMultiple VPCs found. Please specify --vpc-id:\033[0m\n"
    echo ""
    printf "  %-25s %-18s %s\n" "VPC ID" "CIDR" "Name"
    printf "  %-25s %-18s %s\n" "-------------------------" "------------------" "----"
    for entry in "${CANDIDATE_VPCS[@]}"; do
      vid=$(echo "$entry" | awk '{print $1}')
      cidr=$(echo "$entry" | awk '{print $2}')
      name=$(echo "$entry" | awk '{print $3}')
      printf "  %-25s %-18s %s\n" "$vid" "$cidr" "$name"
    done
    echo ""
    echo "  Re-run with: $0 --vpc-id <VPC_ID>"
    exit 1
  fi
fi

# =============================================================================
# 2. VPC Configuration
# =============================================================================
header "2. VPC CONFIGURATION"

VPC_INFO=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --output json 2>&1) || true
if ! echo "$VPC_INFO" | jq -e '.Vpcs[0]' &>/dev/null; then
  fail "VPC $VPC_ID not found in $REGION"
  exit 1
fi

VPC_CIDR=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].CidrBlock')
VPC_STATE=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].State')
VPC_NAME=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].Tags[]? | select(.Key=="Name") | .Value // "unnamed"')
pass "VPC $VPC_ID ($VPC_NAME) — CIDR: $VPC_CIDR, State: $VPC_STATE"

CIDR_PREFIX=$(echo "$VPC_CIDR" | cut -d/ -f2)
if [[ "$CIDR_PREFIX" -le 23 ]]; then
  pass "VPC CIDR /$CIDR_PREFIX meets recommended /23 minimum"
elif [[ "$CIDR_PREFIX" -le 25 ]]; then
  warn "VPC CIDR /$CIDR_PREFIX is smaller than recommended /23 — may limit scaling"
else
  fail "VPC CIDR /$CIDR_PREFIX is too small — ROSA HCP requires at least /25 per subnet"
fi

# DNS settings
DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames \
  --output json 2>/dev/null | jq -r '.EnableDnsHostnames.Value // false')
DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport \
  --output json 2>/dev/null | jq -r '.EnableDnsSupport.Value // false')

if [[ "$DNS_HOSTNAMES" == "true" ]]; then
  pass "VPC DNS Hostnames: enabled"
else
  fail "VPC DNS Hostnames: DISABLED — must be enabled for VPC endpoints"
  echo "       Fix: aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames"
fi

if [[ "$DNS_SUPPORT" == "true" ]]; then
  pass "VPC DNS Support: enabled"
else
  fail "VPC DNS Support: DISABLED — must be enabled"
  echo "       Fix: aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support"
fi

# =============================================================================
# 3. Private Subnets
# =============================================================================
header "3. PRIVATE SUBNETS"

PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`]' --output json 2>/dev/null || echo "[]")

PRIVATE_COUNT=$(echo "$PRIVATE_SUBNETS" | jq 'length')

if [[ "$PRIVATE_COUNT" -ge "$MIN_PRIVATE_SUBNETS" ]]; then
  pass "Private subnets: $PRIVATE_COUNT found (minimum: $MIN_PRIVATE_SUBNETS)"
else
  fail "Private subnets: only $PRIVATE_COUNT found — need at least $MIN_PRIVATE_SUBNETS for multi-AZ"
fi

AZ_COUNT=$(echo "$PRIVATE_SUBNETS" | jq '[.[].AvailabilityZone] | unique | length')
if [[ "$AZ_COUNT" -ge 3 ]]; then
  pass "Private subnets span $AZ_COUNT availability zones"
elif [[ "$AZ_COUNT" -ge 1 ]]; then
  warn "Private subnets span only $AZ_COUNT AZ(s) — 3 AZs recommended for multi-AZ"
fi

echo "$PRIVATE_SUBNETS" | jq -r '.[] | "\(.SubnetId) \(.CidrBlock) \(.AvailabilityZone) \(.AvailableIpAddressCount)"' | \
while read -r sid cidr az ips; do
  PREFIX=$(echo "$cidr" | cut -d/ -f2)
  SUBNET_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$sid" "Name=key,Values=Name" \
    --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
  LABEL="$sid ($az): $cidr — $ips IPs available"
  [[ -n "$SUBNET_NAME" && "$SUBNET_NAME" != "None" ]] && LABEL="$sid ($SUBNET_NAME, $az): $cidr — $ips IPs available"

  if [[ "$PREFIX" -le 25 ]]; then
    pass "$LABEL"
  else
    warn "$LABEL — /$PREFIX is smaller than recommended /25"
  fi
done

# =============================================================================
# 4. Subnet Tags
# =============================================================================
header "4. SUBNET TAGS"

TAGGED_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' --output json 2>/dev/null || echo "[]")
TAGGED_COUNT=$(echo "$TAGGED_SUBNETS" | jq 'length')

if [[ "$TAGGED_COUNT" -ge "$MIN_PRIVATE_SUBNETS" ]]; then
  pass "kubernetes.io/role/internal-elb=1: found on $TAGGED_COUNT subnets"
else
  fail "kubernetes.io/role/internal-elb=1: only $TAGGED_COUNT subnet(s) tagged — need $MIN_PRIVATE_SUBNETS"
  echo "       Fix: aws ec2 create-tags --resources <subnet-ids> --tags Key=kubernetes.io/role/internal-elb,Value=1"
fi

# =============================================================================
# 5. VPC Endpoints
# =============================================================================
header "5. VPC ENDPOINTS"

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
      pass "$svc ($TYPE): available"
    else
      fail "$svc ($TYPE): state is '$STATE' — expected 'available'"
    fi

    if [[ "$TYPE" == "Interface" ]]; then
      if [[ "$PDNS" == "true" ]]; then
        pass "$svc: PrivateDnsEnabled=true"
      else
        fail "$svc: PrivateDnsEnabled=$PDNS — must be true"
      fi
    fi
  else
    fail "$svc endpoint: NOT FOUND — required for zero-egress"
    echo "       Create: aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name $FULL_SVC --vpc-endpoint-type $(if [[ "$svc" == "s3" ]]; then echo Gateway; else echo Interface; fi)"
  fi
done

for svc in "${OPTIONAL_ENDPOINT_SUFFIXES[@]}"; do
  FULL_SVC="com.amazonaws.${REGION}.${svc}"
  MATCH=$(echo "$ENDPOINTS" | jq -r --arg s "$FULL_SVC" '.[] | select(.Service == $s)')
  if [[ -n "$MATCH" ]]; then
    STATE=$(echo "$MATCH" | jq -r '.State')
    info "$svc: present ($STATE) — optional, for CloudWatch log forwarding"
  else
    info "$svc: not present — only needed if using CloudWatch log forwarding"
  fi
done

# =============================================================================
# 6. Endpoint Security Groups
# =============================================================================
header "6. ENDPOINT SECURITY GROUPS"

INTERFACE_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[*].{Service:ServiceName,Groups:Groups[*].GroupId}' \
  --output json 2>/dev/null || echo "[]")

SG_IDS=$(echo "$INTERFACE_ENDPOINTS" | jq -r '.[].Groups[]' | sort -u)

if [[ -z "$SG_IDS" ]]; then
  info "No interface endpoint security groups found (endpoints may not exist yet)"
else
  for sg in $SG_IDS; do
    ALLOWS_443=$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query "SecurityGroups[0].IpPermissions[?ToPort==\`443\` && FromPort==\`443\`]" \
      --output json 2>/dev/null || echo "[]")

    SG_NAME=$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || echo "")

    if [[ $(echo "$ALLOWS_443" | jq 'length') -gt 0 ]]; then
      pass "Security group $sg ($SG_NAME): allows HTTPS (443) inbound"
    else
      fail "Security group $sg ($SG_NAME): no HTTPS (443) inbound rule"
      echo "       Fix: aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 443 --cidr $VPC_CIDR"
    fi
  done
fi

# =============================================================================
# 7. Route Tables
# =============================================================================
header "7. ROUTE TABLES"

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

    HAS_NAT_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$RTB" \
      --query "RouteTables[0].Routes[?NatGatewayId!=null]" \
      --output json 2>/dev/null || echo "[]")

    if [[ $(echo "$HAS_IGW_ROUTE" | jq 'length') -eq 0 ]]; then
      pass "Subnet $sid: no IGW route (correct for zero-egress)"
    else
      fail "Subnet $sid: has route to Internet Gateway — private subnets must not route to IGW"
    fi

    if [[ $(echo "$HAS_NAT_ROUTE" | jq 'length') -eq 0 ]]; then
      pass "Subnet $sid: no NAT Gateway route (correct for zero-egress)"
    else
      warn "Subnet $sid: has route to NAT Gateway — not needed for zero-egress (workers won't use it)"
    fi
  fi
done

S3_GW=$(echo "$ENDPOINTS" | jq -r '.[] | select(.Service | endswith(".s3")) | select(.Type == "Gateway")')
if [[ -n "$S3_GW" ]]; then
  pass "S3 Gateway endpoint: route table entries managed automatically by AWS"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
printf "║  \033[1mROSA VPC VALIDATION SUMMARY\033[0m                                  ║\n"
echo "║  VPC: $VPC_ID                             ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  \033[32m✓ PASS : %-4d\033[0m                                              ║\n" "$PASS"
printf "║  \033[31m✗ FAIL : %-4d\033[0m                                              ║\n" "$FAIL"
printf "║  \033[33m⚠ WARN : %-4d\033[0m                                              ║\n" "$WARN"
printf "║  \033[36mℹ INFO : %-4d\033[0m                                              ║\n" "$INFO"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  printf "\033[32m✓ VPC is ready for ROSA HCP zero-egress deployment.\033[0m\n"
  exit 0
else
  printf "\033[31m✗ $FAIL issue(s) found. Fix the FAIL items above before cluster creation.\033[0m\n"
  exit 1
fi
