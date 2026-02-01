#!/usr/bin/env bash

# Datei: destroy_all.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License

set -euo pipefail

# =========================
# Settings / Safety gates
# =========================
DRY_RUN="${DRY_RUN:-0}"                 # 1 = show only, 0 = actually delete
FORCE="${FORCE:-1}"                     # must be 1 when DRY_RUN=0
ALL_SUBSCRIPTIONS="${ALL_SUBSCRIPTIONS:-1}"  # 1 = loop all enabled subscriptions you can access
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"

# If 1: attempt to disable Network Watcher in all locations before deleting RGs
DISABLE_NETWORK_WATCHER="${DISABLE_NETWORK_WATCHER:-1}"

# Exclusions:
# Set to empty to delete *everything*, including NetworkWatcherRG etc.
# Example to exclude system RGs:
# EXCLUDE_RG_REGEX_CSV="^NetworkWatcherRG$,^AzureBackupRG"
EXCLUDE_RG_REGEX_CSV="${EXCLUDE_RG_REGEX_CSV:-}"

usage() {
  cat <<EOF
Usage:
  DRY_RUN=1  $0                         # list what would be deleted (default)
  DRY_RUN=0 FORCE=1 $0                  # actually delete (requires FORCE=1)

Optional env vars:
  ALL_SUBSCRIPTIONS=1|0                 # default 1
  SUBSCRIPTION_ID=<id>                  # required when ALL_SUBSCRIPTIONS=0
  DISABLE_NETWORK_WATCHER=1|0            # default 1
  EXCLUDE_RG_REGEX_CSV="regex1,regex2"  # RG name patterns to skip (default: none)

Examples:
  # Really delete ALL RGs across all subscriptions (dangerous):
  DRY_RUN=0 FORCE=1 ALL_SUBSCRIPTIONS=1 $0

  # Only one subscription:
  DRY_RUN=0 FORCE=1 ALL_SUBSCRIPTIONS=0 SUBSCRIPTION_ID="xxxx-..." $0

  # Keep system RGs:
  DRY_RUN=0 FORCE=1 EXCLUDE_RG_REGEX_CSV="^NetworkWatcherRG$,^AzureBackupRG" $0
EOF
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

need_cmd az
need_cmd sed
need_cmd grep
need_cmd sort

# =========================
# Auth
# =========================
if ! az account show >/dev/null 2>&1; then
  echo "==> Not logged in. Running az login..."
  az login >/dev/null
fi

# =========================
# Helpers
# =========================
get_subscriptions() {
  if [[ "$ALL_SUBSCRIPTIONS" == "1" ]]; then
    # enabled subscriptions you can access
    az account list --query "[?state=='Enabled'].id" -o tsv
  else
    [[ -z "${SUBSCRIPTION_ID}" ]] && { echo "ERROR: SUBSCRIPTION_ID required when ALL_SUBSCRIPTIONS=0"; usage; }
    echo "$SUBSCRIPTION_ID"
  fi
}

confirm_or_die() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ "$FORCE" != "1" ]]; then
    echo "ERROR: Refusing to delete because FORCE!=1. Set FORCE=1 to proceed."
    exit 1
  fi

  echo
  echo "!!! EXTREMELY DESTRUCTIVE OPERATION !!!"
  echo "This will delete Resource Groups (and therefore resources) in the selected subscription(s)."
  #echo "Type exactly: DELETE to continue"
  #read -r answer
  #if [[ "$answer" != "DELETE" ]]; then
  #  echo "Aborted."
  #  exit 1
  #fi
}

build_exclude_regex() {
  if [[ -z "$EXCLUDE_RG_REGEX_CSV" ]]; then
    echo ""
  else
    echo "$EXCLUDE_RG_REGEX_CSV" | sed 's/,/|/g'
  fi
}

delete_scope_locks() {
  # Deletes locks for a given scope:
  # - resource group scope: pass "--resource-group <rg>"
  # - subscription scope: pass nothing, then list locks and delete by id
  local rg="${1:-}"
  local lock_ids

  if [[ -n "$rg" ]]; then
    lock_ids="$(az lock list --resource-group "$rg" --query "[].id" -o tsv 2>/dev/null || true)"
  else
    # all locks visible in current subscription context
    lock_ids="$(az lock list --query "[].id" -o tsv 2>/dev/null || true)"
  fi

  if [[ -z "$lock_ids" ]]; then
    return 0
  fi

  while IFS= read -r lock_id; do
    [[ -z "$lock_id" ]] && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [DRY] would delete lock: $lock_id"
    else
      echo "  deleting lock: $lock_id"
      az lock delete --ids "$lock_id" >/dev/null || true
    fi
  done <<< "$lock_ids"
}

disable_network_watcher_all_locations() {
  [[ "$DISABLE_NETWORK_WATCHER" != "1" ]] && return 0

  # list locations where Network Watcher is available/registered
  # (this is best-effort; if command fails, we continue)
  local locs
  locs="$(az account list-locations --query "[].name" -o tsv 2>/dev/null || true)"
  [[ -z "$locs" ]] && return 0

  echo "==> Disabling Network Watcher (best-effort) in all locations..."
  while IFS= read -r loc; do
    [[ -z "$loc" ]] && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [DRY] would run: az network watcher configure --locations $loc --enabled false"
    else
      az network watcher configure --locations "$loc" --enabled false >/dev/null 2>&1 || true
    fi
  done <<< "$locs"
}

# =========================
# Main
# =========================
confirm_or_die

exclude_regex="$(build_exclude_regex)"
if [[ -n "$exclude_regex" ]]; then
  echo "==> Excluding RG name patterns: $exclude_regex"
else
  echo "==> No exclusions: ALL resource groups will be targeted (including system RGs)."
fi

subs="$(get_subscriptions)"
if [[ -z "$subs" ]]; then
  echo "No enabled subscriptions found (or no access)."
  exit 0
fi

while IFS= read -r sub; do
  [[ -z "$sub" ]] && continue
  echo
  echo "============================================================"
  echo "==> Subscription: $sub"
  az account set --subscription "$sub"

  # Remove subscription locks (common delete blocker)
  echo "==> Removing locks (subscription scope / best-effort)..."
  delete_scope_locks ""

  # Disable network watcher (optional) so it doesn't reappear as easily
  disable_network_watcher_all_locations

  # List RGs
  rgs="$(az group list --query "[].name" -o tsv | sort || true)"
  if [[ -z "$rgs" ]]; then
    echo "No resource groups in subscription."
    continue
  fi

  # Apply exclusions (if any)
  if [[ -n "$exclude_regex" ]]; then
    to_delete="$(echo "$rgs" | grep -Ev "$exclude_regex" || true)"
    skipped="$(echo "$rgs" | grep -E "$exclude_regex" || true)"

    if [[ -n "$skipped" ]]; then
      echo "==> Skipping RGs:"
      echo "$skipped" | sed 's/^/  - /'
    fi
  else
    to_delete="$rgs"
  fi

  if [[ -z "$to_delete" ]]; then
    echo "==> Nothing to delete (after exclusions)."
    continue
  fi

  echo "==> RGs to delete:"
  echo "$to_delete" | sed 's/^/  - /'

  # Delete RGs
  while IFS= read -r rg; do
    [[ -z "$rg" ]] && continue
    echo
    echo "==> Processing RG: $rg"

    # Remove RG locks first (very common blocker)
    echo "  removing locks in RG (best-effort)..."
    delete_scope_locks "$rg"

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [DRY] would run: az group delete -n \"$rg\" --yes --no-wait"
    else
      echo "  deleting RG (async): $rg"
      az group delete -n "$rg" --yes --no-wait
    fi
  done <<< "$to_delete"

done <<< "$subs"

echo
if [[ "$DRY_RUN" == "1" ]]; then
  echo "✅ DRY RUN complete. To actually delete: DRY_RUN=0 FORCE=1 $0"
else
  echo "✅ Delete requests submitted (async). Check status with:"
  echo "   az group list -o table"
  echo "   az group exists -n <rgname>"
fi
