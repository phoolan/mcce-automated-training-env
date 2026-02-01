#!/usr/bin/env bash

# Datei: destroy_testvm.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License

set -euo pipefail

RG_NAME="${RG_NAME:-rg-mcce-poc}"
VM_NAME="${VM_NAME:-mcce-testvm}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need_cmd az

if ! az account show >/dev/null 2>&1; then
  az login >/dev/null
fi
if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo "==> Deleting test VM: $VM_NAME in RG: $RG_NAME"
az vm delete -g "$RG_NAME" -n "$VM_NAME" --yes --force-deletion true || true

echo "==> Best-effort cleanup leftovers..."
for nic in $(az network nic list -g "$RG_NAME" --query "[?contains(name,'${VM_NAME}')].name" -o tsv); do
  az network nic delete -g "$RG_NAME" -n "$nic" || true
done
for pip in $(az network public-ip list -g "$RG_NAME" --query "[?contains(name,'${VM_NAME}')].name" -o tsv); do
  az network public-ip delete -g "$RG_NAME" -n "$pip" || true
done
for disk in $(az disk list -g "$RG_NAME" --query "[?contains(name,'${VM_NAME}')].name" -o tsv); do
  az disk delete -g "$RG_NAME" -n "$disk" --yes || true
done

echo "✅ TestVM delete done."
