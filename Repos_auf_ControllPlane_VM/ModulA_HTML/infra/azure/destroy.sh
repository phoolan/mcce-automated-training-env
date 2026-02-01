#!/usr/bin/env bash

# Datei: destroy.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License

set -euo pipefail

LOCATION="${LOCATION:-westeurope}"
RG_NAME_BASE="${RG_NAME_BASE:-rg-mcce-poc}"
ONE_RG_PER_USER="${ONE_RG_PER_USER:-0}"

USER_NAME=""
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

usage() {
  cat <<EOF
Usage: $0 --user <username> [--rg-base <name>] [--one-rg-per-user 0|1]

Examples:
  # if ONE_RG_PER_USER=1 was used in create:
  ONE_RG_PER_USER=1 $0 --user alice

  # if you created a dedicated RG like rg-mcce-poc-alice:
  $0 --user alice --one-rg-per-user 1

  # custom RG base:
  $0 --user alice --rg-base rg-myproj --one-rg-per-user 1
EOF
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --rg-base) RG_NAME_BASE="${2:-}"; shift 2 ;;
    --one-rg-per-user) ONE_RG_PER_USER="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -z "$USER_NAME" ]] && usage

USER_SLUG="$(echo "$USER_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | sed -E 's/^-+|-+$//g')"

if [[ "$ONE_RG_PER_USER" == "1" ]]; then
  RG_NAME="${RG_NAME_BASE}-${USER_SLUG}"
else
  # If you used a shared RG, deleting it will delete ALL users.
  echo "ERROR: ONE_RG_PER_USER=0 (shared RG). This script would delete the shared RG '${RG_NAME_BASE}' for all users."
  echo "Use destroy_user_resources.sh instead, or set ONE_RG_PER_USER=1."
  exit 1
fi

need_cmd az

if ! az account show >/dev/null 2>&1; then
  az login >/dev/null
fi

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo "==> Deleting Resource Group: $RG_NAME"
az group delete -n "$RG_NAME" --yes --no-wait

echo "✅ Delete started (async). You can check status with:"
echo "   az group exists -n $RG_NAME"
