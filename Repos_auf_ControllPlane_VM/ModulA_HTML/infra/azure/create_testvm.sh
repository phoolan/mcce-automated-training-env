#!/usr/bin/env bash

# Datei: create_testvm.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License

set -euo pipefail

# ===== Defaults =====
LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-rg-mcce-poc}"
VM_NAME="${VM_NAME:-mcce-testvm}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
VM_SIZE="${VM_SIZE:-Standard_D2ds_v6}"     # 2 vCPU / 4GB (guter Cypress-Start)
IMAGE="${IMAGE:-Ubuntu2204}"

# Persistent SSH key storage (host-side)
KEYS_ROOT="${KEYS_ROOT:-/home/git/user_keys}"
DATE_TAG="${DATE_TAG:-$(date +%d%m%Y)}"

# SSH key for testvm (persistent, stored in /home/git/user_keys/<DATE_TAG>/testvm)
SSH_KEY_PATH="${SSH_KEY_PATH:-${KEYS_ROOT}/${DATE_TAG}/testvm}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-${SSH_KEY_PATH}.pub}"

# Networking
SSH_SOURCE="${SSH_SOURCE:-}"           # z.B. "1.2.3.4/32"; wenn leer -> auto detect
OPEN_WEB_PORTS="${OPEN_WEB_PORTS:-0}"  # 1 => 80/443 öffnen (meist unnötig)

# Cypress settings
CYPRESS_IMAGE="${CYPRESS_IMAGE:-cypress/included:13.6.4}"
# Optional: Repo URL für Tests (wenn du willst, dass TestVM selber clont)
TEST_REPO_URL="${TEST_REPO_URL:-}"     # z.B. "https://gitea.example.com/org/repo.git"
TEST_REPO_DIR="${TEST_REPO_DIR:-/opt/tests}"
# Optional: Branch
TEST_REPO_BRANCH="${TEST_REPO_BRANCH:-main}"

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

usage() {
  cat <<EOF
Usage: $0 [--rg <rg>] [--name <vmname>] [--ssh-source <CIDR>] [--open-web 0|1]

Examples:
  $0
  $0 --ssh-source 203.0.113.10/32
  OPEN_WEB_PORTS=1 $0
  TEST_REPO_URL=https://... TEST_REPO_BRANCH=main $0

Persistent keys:
  KEYS_ROOT=/home/git/user_keys DATE_TAG=31012026 $0
EOF
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rg) RG_NAME="${2:-}"; shift 2 ;;
    --name) VM_NAME="${2:-}"; shift 2 ;;
    --ssh-source) SSH_SOURCE="${2:-}"; shift 2 ;;
    --open-web) OPEN_WEB_PORTS="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

need_cmd az
need_cmd ssh-keygen
need_cmd curl

OUT_DIR="out/testvm"
mkdir -p "$OUT_DIR"

# ===== Ensure logged in =====
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Running az login..."
  az login >/dev/null
fi

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo "==> Active account:"
az account show --query "{name:name,id:id,tenantId:tenantId,state:state}" -o json

# ===== Ensure RG =====
echo "==> Ensuring resource group: $RG_NAME ($LOCATION)"
az group create -n "$RG_NAME" -l "$LOCATION" -o none

# ===== SSH key (persistent) =====
mkdir -p "${KEYS_ROOT}/${DATE_TAG}"
chmod 700 "${KEYS_ROOT}" 2>/dev/null || true
chmod 700 "${KEYS_ROOT}/${DATE_TAG}" 2>/dev/null || true

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "==> Creating SSH key for testvm: $SSH_KEY_PATH"
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

# ===== SSH source =====
if [[ -z "$SSH_SOURCE" ]]; then
  MY_IP="$(curl -s https://api.ipify.org || true)"
  if [[ -z "${MY_IP}" ]]; then
    echo "WARN: Could not determine your public IP; opening SSH to 0.0.0.0/0"
    SSH_SOURCE="0.0.0.0/0"
  else
    SSH_SOURCE="${MY_IP}/32"
  fi
fi
echo "==> SSH allowed from: $SSH_SOURCE"

# ===== Create VM (infra) =====
echo "==> Creating test VM: $VM_NAME"
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

# ===== NSG rules =====
NIC_ID="$(az vm show -g "$RG_NAME" -n "$VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv)"
NSG_ID="$(az network nic show --ids "$NIC_ID" --query "networkSecurityGroup.id" -o tsv)"
NSG_NAME="$(basename "$NSG_ID")"
echo "==> Using NSG: $NSG_NAME"

# SSH (restricted)
az network nsg rule create \
  -g "$RG_NAME" --nsg-name "$NSG_NAME" \
  -n "Allow-SSH-TestVM" \
  --priority 100 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$SSH_SOURCE" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 22 \
  -o none

if [[ "$OPEN_WEB_PORTS" == "1" ]]; then
  az network nsg rule create \
    -g "$RG_NAME" --nsg-name "$NSG_NAME" \
    -n "Allow-HTTP-TestVM" \
    --priority 110 \
    --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "*" \
    --source-port-ranges "*" \
    --destination-address-prefixes "*" \
    --destination-port-ranges 80 \
    -o none

  az network nsg rule create \
    -g "$RG_NAME" --nsg-name "$NSG_NAME" \
    -n "Allow-HTTPS-TestVM" \
    --priority 120 \
    --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "*" \
    --source-port-ranges "*" \
    --destination-address-prefixes "*" \
    --destination-port-ranges 443 \
    -o none
fi

# ===== Get Public IP + inventory =====
PUBLIC_IP="$(az vm show -d -g "$RG_NAME" -n "$VM_NAME" --query publicIps -o tsv)"
echo "==> Public IP: $PUBLIC_IP"

cat > "${OUT_DIR}/inventory.ini" <<EOF
[testvm]
${PUBLIC_IP} ansible_user=${ADMIN_USER} ansible_ssh_private_key_file=${SSH_KEY_PATH} ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Convenience link (optional)
ln -sf "${OUT_DIR}/inventory.ini" inventory_testvm.ini

# Helpful SSH info file in key folder
cat > "${KEYS_ROOT}/${DATE_TAG}/testvm.ssh.txt" <<EOF
TestVM: ${VM_NAME}
IP:     ${PUBLIC_IP}

SSH:
  ssh -i ${SSH_KEY_PATH} ${ADMIN_USER}@${PUBLIC_IP}
EOF

# ===== Fixed config on testvm: Docker + optional repo clone + Cypress image pull =====
echo "==> Installing Docker & basic deps via Azure RunCommand..."
RUN_SCRIPT=$(cat <<'BASH'
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg git
# Docker (official Ubuntu method)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER" || true
sudo systemctl enable --now docker
BASH
)

az vm run-command invoke \
  -g "$RG_NAME" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$RUN_SCRIPT" \
  -o none

# Optional: Repo auf VM clonen (wenn TEST_REPO_URL gesetzt ist)
if [[ -n "$TEST_REPO_URL" ]]; then
  echo "==> Cloning test repo on VM: $TEST_REPO_URL"
  CLONE_SCRIPT=$(cat <<BASH
set -euo pipefail
sudo mkdir -p "$TEST_REPO_DIR"
sudo chown -R $ADMIN_USER:$ADMIN_USER "$TEST_REPO_DIR"
if [[ ! -d "$TEST_REPO_DIR/.git" ]]; then
  git clone --branch "$TEST_REPO_BRANCH" "$TEST_REPO_URL" "$TEST_REPO_DIR"
else
  cd "$TEST_REPO_DIR"
  git fetch --all
  git checkout "$TEST_REPO_BRANCH"
  git pull
fi
BASH
)
  az vm run-command invoke \
    -g "$RG_NAME" -n "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "$CLONE_SCRIPT" \
    -o none
fi

# Pull Cypress image (damit erster Run schneller ist)
echo "==> Pre-pulling Cypress Docker image: $CYPRESS_IMAGE"
PULL_SCRIPT=$(cat <<BASH
set -euo pipefail
sudo docker pull "$CYPRESS_IMAGE"
BASH
)
az vm run-command invoke \
  -g "$RG_NAME" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$PULL_SCRIPT" \
  -o none

cat > "${OUT_DIR}/howto_run_cypress.txt" <<EOF
SSH:
  ssh -i ${SSH_KEY_PATH} ${ADMIN_USER}@${PUBLIC_IP}

Example Cypress run (assuming tests live in ${TEST_REPO_DIR}):
  sudo docker run --rm -t \
    -v ${TEST_REPO_DIR}:/e2e \
    -w /e2e \
    ${CYPRESS_IMAGE}

If you want to run a specific command:
  sudo docker run --rm -t \
    -v ${TEST_REPO_DIR}:/e2e \
    -w /e2e \
    ${CYPRESS_IMAGE} \
    npx cypress run
EOF

echo ""
echo "✅ TestVM deployed & configured."
echo "RG:        $RG_NAME"
echo "VM:        $VM_NAME"
echo "Public IP: $PUBLIC_IP"
echo "Inventory: ${OUT_DIR}/inventory.ini"
echo "Info:      ${OUT_DIR}/howto_run_cypress.txt"
echo "SSH key:   ${SSH_KEY_PATH}"
