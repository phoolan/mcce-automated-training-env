#!/usr/bin/env bash

# Datei: create.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License

set -euo pipefail

echo "DEBUG(create.sh): PWD=$(pwd)"

# Defaults
LOCATION="${LOCATION:-westeurope}"
RG_NAME_BASE="${RG_NAME_BASE:-rg-mcce-poc}"      # gemeinsame RG (Standard)
VM_NAME_PREFIX="${VM_NAME_PREFIX:-mcce-poc}"     # Prefix für VM-Namen
ADMIN_USER="${ADMIN_USER:-azureuser}"
VM_SIZE="${VM_SIZE:-Standard_D2ds_v6}"
IMAGE="${IMAGE:-Ubuntu2204}"

# Persistent SSH key storage (host-side, e.g. on-prem control plane)
KEYS_ROOT="${KEYS_ROOT:-/home/git/user_keys}"

# Folder tag (default: today DDMMYYYY). You can pass DATE_TAG=31012026 from workflow.
DATE_TAG="${DATE_TAG:-$(date +%d%m%Y)}"

# Behavior flags
CREATE_SP="${CREATE_SP:-0}"           # 0 = kein Service Principal pro Lauf (empfohlen); 1 = pro Lauf
ONE_RG_PER_USER="${ONE_RG_PER_USER:-0}" # 0 = alle VMs in einer RG; 1 = RG pro User

# Args
USER_NAME=""
SSH_SOURCE=""  # z.B. 1.2.3.4/32, wenn leer -> auto-detect via ipify
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

usage() {
  cat <<EOF
Usage: $0 --user <username> [--location <region>] [--ssh-source <CIDR>] [--rg-base <name>] [--one-rg-per-user 0|1] [--create-sp 0|1]

Examples:
  $0 --user alice
  $0 --user bob --ssh-source 203.0.113.10/32
  ONE_RG_PER_USER=1 $0 --user charlie
  CREATE_SP=1 $0 --user diana

Persistent key storage:
  KEYS_ROOT=/home/git/user_keys DATE_TAG=31012026 $0 --user alice
EOF
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --ssh-source) SSH_SOURCE="${2:-}"; shift 2 ;;
    --rg-base) RG_NAME_BASE="${2:-}"; shift 2 ;;
    --one-rg-per-user) ONE_RG_PER_USER="${2:-}"; shift 2 ;;
    --create-sp) CREATE_SP="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -z "$USER_NAME" ]] && usage

# Sanitize username for Azure resource names (lowercase, alnum and -)
USER_SLUG="$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | sed -E 's/^-+|-+$//g')"
if [[ -z "$USER_SLUG" ]]; then
  echo "ERROR: username '$USER_NAME' results in empty slug."
  exit 1
fi

# Debug (now safe: variables exist)
echo "DEBUG(create.sh): DATE_TAG=$DATE_TAG USER_NAME=$USER_NAME USER_SLUG=$USER_SLUG"

# Per-user derived names/paths
OUT_DIR="out/${USER_SLUG}"
mkdir -p "$OUT_DIR"

if [[ "$ONE_RG_PER_USER" == "1" ]]; then
  RG_NAME="${RG_NAME_BASE}-${USER_SLUG}"
else
  RG_NAME="${RG_NAME_BASE}"
fi

VM_NAME="${VM_NAME_PREFIX}-${USER_SLUG}"

# ---- Persistent SSH key per user, stored on host
mkdir -p "${KEYS_ROOT}/${DATE_TAG}"
chmod 700 "${KEYS_ROOT}" 2>/dev/null || true
chmod 700 "${KEYS_ROOT}/${DATE_TAG}" 2>/dev/null || true

SSH_KEY_PATH="${SSH_KEY_PATH:-${KEYS_ROOT}/${DATE_TAG}/${USER_SLUG}}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-${SSH_KEY_PATH}.pub}"

# Tools
need_cmd az
need_cmd ssh-keygen
need_cmd curl
need_cmd python3

# Ensure logged in
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Running az login..."
  az login >/dev/null
fi

# Set subscription if provided
if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

ACTIVE_SUB_ID="$(az account show --query id -o tsv)"
ACTIVE_TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "==> Using subscription: $ACTIVE_SUB_ID"
echo "==> User: $USER_NAME (slug: $USER_SLUG)"
echo "==> Resource Group: $RG_NAME"
echo "==> VM Name: $VM_NAME"
echo "==> DATE_TAG: $DATE_TAG"
echo "==> SSH key path: $SSH_KEY_PATH"

# Create RG
az group create -n "$RG_NAME" -l "$LOCATION" -o none
RG_ID="$(az group show -n "$RG_NAME" --query id -o tsv)"

# Optional: per-run Service Principal (usually NOT needed)
if [[ "$CREATE_SP" == "1" ]]; then
  SP_NAME="mcce-poc-sp-${USER_SLUG}-$(date +%Y%m%d%H%M%S)"
  echo "==> Creating Service Principal: $SP_NAME (scope: $RG_NAME)"
  SP_JSON="$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --role Contributor \
    --scopes "$RG_ID" \
    --output json
  )"

  AZURE_CLIENT_ID="$(echo "$SP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])')"
  AZURE_CLIENT_SECRET="$(echo "$SP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"
  AZURE_TENANT_ID="$(echo "$SP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tenant"])')"

  cat > "${OUT_DIR}/sp.env" <<EOF
AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
AZURE_TENANT_ID=${AZURE_TENANT_ID}
AZURE_SUBSCRIPTION_ID=${ACTIVE_SUB_ID}
EOF
  chmod 600 "${OUT_DIR}/sp.env"
  echo "$SP_JSON" > "${OUT_DIR}/sp.json"
  chmod 600 "${OUT_DIR}/sp.json"
fi

# SSH key per user (persistent)
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "==> Creating SSH key for user: $SSH_KEY_PATH"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" >/dev/null
  chmod 600 "$SSH_KEY_PATH" || true
  chmod 644 "$SSH_PUBKEY_PATH" || true
else
  echo "==> SSH key exists: $SSH_KEY_PATH"
fi

if [[ ! -f "$SSH_PUBKEY_PATH" ]]; then
  echo "ERROR: missing public key: $SSH_PUBKEY_PATH"
  exit 1
fi

# SSH source
if [[ -z "$SSH_SOURCE" ]]; then
  MY_IP="$(curl -s https://api.ipify.org || true)"
  if [[ -z "${MY_IP}" ]]; then
    echo "WARN: Could not determine public IP; opening SSH to 0.0.0.0/0"
    SSH_SOURCE="0.0.0.0/0"
  else
    SSH_SOURCE="${MY_IP}/32"
  fi
fi
echo "==> SSH allowed from: $SSH_SOURCE"

# Create VM (infra only)
echo "==> Creating VM..."
az vm create \
  --resource-group "$RG_NAME" \
  --name "$VM_NAME" \
  --image "$IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_PUBKEY_PATH" \
  --public-ip-sku Standard \
  --authentication-type ssh \
  --output json > "${OUT_DIR}/vm.json"

# NSG rules
NIC_ID="$(az vm show -g "$RG_NAME" -n "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv)"
NSG_ID="$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv)"
NSG_NAME="$(basename "$NSG_ID")"

az network nsg rule create \
  -g "$RG_NAME" --nsg-name "$NSG_NAME" \
  -n "Allow-SSH-${USER_SLUG}" \
  --priority 100 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$SSH_SOURCE" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 22 \
  -o none

az network nsg rule create \
  -g "$RG_NAME" --nsg-name "$NSG_NAME" \
  -n "Allow-HTTP-${USER_SLUG}" \
  --priority 110 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 80 \
  -o none

az network nsg rule create \
  -g "$RG_NAME" --nsg-name "$NSG_NAME" \
  -n "Allow-HTTPS-${USER_SLUG}" \
  --priority 120 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 443 \
  -o none

# Outputs: public IP + inventory per user
PUBLIC_IP="$(az vm show -d -g "$RG_NAME" -n "$VM_NAME" --query publicIps -o tsv)"
echo "==> Public IP: $PUBLIC_IP"

cat > "${OUT_DIR}/inventory.ini" <<EOF
[poc]
${PUBLIC_IP} ansible_user=${ADMIN_USER} ansible_ssh_private_key_file=${SSH_KEY_PATH} ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Helpful SSH info file in key folder
cat > "${KEYS_ROOT}/${DATE_TAG}/${USER_SLUG}.ssh.txt" <<EOF
User: ${USER_NAME}
VM:   ${VM_NAME}
IP:   ${PUBLIC_IP}

SSH:
  ssh -i ${SSH_KEY_PATH} ${ADMIN_USER}@${PUBLIC_IP}
EOF

# Convenience: also write a "current" inventory for configure.sh if you want
ln -sf "${OUT_DIR}/inventory.ini" inventory.ini

# -------------------------------------------------------------------
# EXTRA: Write inventory to a stable absolute path (for workflows)
# -------------------------------------------------------------------
ABS_OUT_ROOT="${ABS_OUT_ROOT:-/home/git/mcce_out}"
ABS_OUT_DIR="${ABS_OUT_ROOT}/${DATE_TAG}/${USER_SLUG}"
mkdir -p "$ABS_OUT_DIR"

cp -f "${OUT_DIR}/inventory.ini" "${ABS_OUT_DIR}/inventory.ini"
chmod 600 "${ABS_OUT_DIR}/inventory.ini" || true

echo "==> Also wrote inventory to: ${ABS_OUT_DIR}/inventory.ini"

echo ""
echo "✅ Provisioned user VM."
echo "User:      $USER_NAME"
echo "VM:        $VM_NAME"
echo "RG:        $RG_NAME"
echo "Inventory: ${OUT_DIR}/inventory.ini"
echo "SSH key:   ${SSH_KEY_PATH}"
echo ""
