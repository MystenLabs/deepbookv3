#!/usr/bin/env bash
# create-enclave-ec2.sh — Launch a Nitro-capable EC2 instance from scratch.
#
# Creates a key pair, security group, and launches an Amazon Linux 2023 instance
# with Nitro Enclaves enabled. Outputs the IP and key path for use with setup-ec2.sh.
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure / aws login)
#   - An existing VPC with a subnet (uses default VPC if not specified)
#
# Usage:
#   ./create-enclave-ec2.sh
#   ./create-enclave-ec2.sh --name my-enclave --region us-east-2 --instance-type m5.xlarge
#   ./create-enclave-ec2.sh --subnet-id subnet-abc123 --region us-east-2
#
# After this script completes, run:
#   ./setup-ec2.sh --host <IP> --key <key-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────
NAME="deepbook-enclave"
REGION="us-east-2"
INSTANCE_TYPE="m5.xlarge"
SUBNET_ID=""
KEY_DIR="$HOME/.ssh"
VOLUME_SIZE=50

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --name NAME           Instance name tag (default: deepbook-enclave)
  --region REGION       AWS region (default: us-east-2)
  --instance-type TYPE  Instance type (default: m5.xlarge, must support Nitro Enclaves)
  --subnet-id ID        Subnet to launch in (default: first subnet in default VPC)
  --key-dir DIR         Directory to save the key pair (default: ~/.ssh)
  --volume-size GB      Root volume size in GB (default: 50)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)           NAME="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
    --subnet-id)      SUBNET_ID="$2"; shift 2 ;;
    --key-dir)        KEY_DIR="$2"; shift 2 ;;
    --volume-size)    VOLUME_SIZE="$2"; shift 2 ;;
    --help|-h)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

log()  { echo "[$(date +%H:%M:%S)] $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

KEY_NAME="${NAME}-key"
SG_NAME="${NAME}-sg"
KEY_PATH="$KEY_DIR/${KEY_NAME}.pem"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    CREATE NITRO ENCLAVE EC2 INSTANCE                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Name:           $NAME"
echo "  Region:         $REGION"
echo "  Instance type:  $INSTANCE_TYPE"
echo "  Volume size:    ${VOLUME_SIZE} GB"
echo "  Key path:       $KEY_PATH"
echo ""

# ── Verify AWS CLI ────────────────────────────────────────────
log "Verifying AWS CLI credentials..."
AWS="aws --region $REGION --output json"
ACCOUNT_ID=$($AWS sts get-caller-identity --query 'Account' --output text 2>/dev/null) \
  || fail "AWS CLI not configured. Run 'aws configure' or 'aws sso login' first."
log "Authenticated as account: $ACCOUNT_ID"

# ── Step 1: Create key pair ──────────────────────────────────
if [[ -f "$KEY_PATH" ]]; then
  log "Key pair file already exists at $KEY_PATH — reusing."
  # Check if the key pair exists in AWS
  if ! $AWS ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    log "Key pair '$KEY_NAME' not found in AWS — importing from local file..."
    # Extract public key and import
    PUB_KEY=$(ssh-keygen -y -f "$KEY_PATH")
    $AWS ec2 import-key-pair \
      --key-name "$KEY_NAME" \
      --public-key-material "$(echo "$PUB_KEY" | base64)" \
      > /dev/null
    log "Key pair imported."
  fi
else
  # Check if it exists in AWS already (but we don't have the local file)
  if $AWS ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null 2>&1; then
    fail "Key pair '$KEY_NAME' exists in AWS but local file $KEY_PATH is missing. Delete the AWS key pair first or use a different --name."
  fi

  log "Creating key pair '$KEY_NAME'..."
  mkdir -p "$KEY_DIR"
  $AWS ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --key-type ed25519 \
    --query 'KeyMaterial' \
    --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
  log "Key pair saved to $KEY_PATH"
fi

# ── Step 2: Get VPC and subnet ────────────────────────────────
if [[ -z "$SUBNET_ID" ]]; then
  log "Finding default VPC and subnet..."
  VPC_ID=$($AWS ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
  
  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    fail "No default VPC found. Specify --subnet-id explicitly."
  fi

  SUBNET_ID=$($AWS ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[0].SubnetId' --output text)
  
  log "Using default VPC: $VPC_ID, subnet: $SUBNET_ID"
else
  VPC_ID=$($AWS ec2 describe-subnets \
    --subnet-ids "$SUBNET_ID" \
    --query 'Subnets[0].VpcId' --output text)
  log "Using provided subnet: $SUBNET_ID (VPC: $VPC_ID)"
fi

# ── Step 3: Create security group ─────────────────────────────
SG_ID=$($AWS ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  log "Creating security group '$SG_NAME'..."
  SG_ID=$($AWS ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Enclave instance: SSH + enclave API" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)

  # SSH access
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr 0.0.0.0/0 > /dev/null

  # Enclave API (socat forwards to this port)
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 3000 \
    --cidr 0.0.0.0/0 > /dev/null

  log "Security group created: $SG_ID (SSH:22, Enclave API:3000)"
else
  log "Security group already exists: $SG_ID"
fi

# ── Step 4: Resolve AMI ───────────────────────────────────────
log "Resolving latest Amazon Linux 2023 AMI..."
AMI_ID=$($AWS ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query 'Parameter.Value' --output text)
log "AMI: $AMI_ID"

# ── Step 5: Launch instance ───────────────────────────────────
log "Launching $INSTANCE_TYPE with Nitro Enclaves enabled..."
INSTANCE_JSON=$($AWS ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --enclave-options "Enabled=true" \
  --associate-public-ip-address \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --count 1)

INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.Instances[0].InstanceId')
log "Instance launched: $INSTANCE_ID"

# ── Step 6: Wait for running state ────────────────────────────
log "Waiting for instance to enter 'running' state..."
$AWS ec2 wait instance-running --instance-ids "$INSTANCE_ID"
log "Instance is running."

# ── Step 7: Get public IP ─────────────────────────────────────
log "Fetching public IP..."
for i in $(seq 1 10); do
  PUBLIC_IP=$($AWS ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  if [[ "$PUBLIC_IP" != "None" && -n "$PUBLIC_IP" ]]; then
    break
  fi
  sleep 3
done

if [[ "$PUBLIC_IP" == "None" || -z "$PUBLIC_IP" ]]; then
  PRIVATE_IP=$($AWS ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  echo ""
  echo "WARNING: No public IP assigned. Private IP: $PRIVATE_IP"
  echo "You may need to assign an Elastic IP or use the private IP with a VPN."
  PUBLIC_IP="$PRIVATE_IP"
fi

# ── Step 8: Wait for SSH ──────────────────────────────────────
log "Waiting for SSH to become available..."
for i in $(seq 1 20); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_PATH" ec2-user@"$PUBLIC_IP" "echo ok" &>/dev/null; then
    break
  fi
  sleep 5
done

if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_PATH" ec2-user@"$PUBLIC_IP" "echo ok" &>/dev/null; then
  log "SSH is ready."
else
  log "WARNING: SSH not yet available — instance may still be initializing."
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  EC2 INSTANCE CREATED"
echo "============================================================"
echo ""
echo "  Instance ID:    $INSTANCE_ID"
echo "  Public IP:      $PUBLIC_IP"
echo "  Instance type:  $INSTANCE_TYPE"
echo "  Region:         $REGION"
echo "  Key:            $KEY_PATH"
echo "  Security group: $SG_ID"
echo ""
echo "  Nitro Enclaves: ENABLED"
echo ""
echo "  Next step — install enclave dependencies on the instance:"
echo ""
echo "    ./setup-ec2.sh \\"
echo "      --host $PUBLIC_IP \\"
echo "      --key $KEY_PATH"
echo ""
echo "  Then push code and start the enclave:"
echo ""
echo "    ./setup-ec2.sh \\"
echo "      --host $PUBLIC_IP \\"
echo "      --key $KEY_PATH"
echo ""
echo "  To SSH in manually:"
echo "    ssh -i $KEY_PATH ec2-user@$PUBLIC_IP"
echo ""
echo "  To terminate later:"
echo "    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
echo ""
