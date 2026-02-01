#!/usr/bin/env bash
set -euo pipefail

# Optional Debug
DEBUG="${DEBUG:-0}"
if [[ "$DEBUG" == "1" ]]; then
  set -x
fi

CSV_FILE="${1:?Usage: $0 <participants.csv>}"
echo "CSV_FILE=$CSV_FILE"

: "${GITEA_BASE_URL:?env GITEA_BASE_URL missing, e.g. http://172.25.183.89:3000}"
: "${ADMIN_TOKEN:?env ADMIN_TOKEN missing (token that can read MCCE_Module repos)}"
: "${GITEAUSER:?env GITEAUSER missing (user for module clone)}"

LOCATION="${LOCATION:-westeurope}"
WORKDIR="${WORKDIR:-/tmp/mcce_modules}"
mkdir -p "$WORKDIR"

KEYS_ROOT="${KEYS_ROOT:-/home/git/user_keys}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing command: $1"; exit 1; }; }
need_cmd git
need_cmd az
need_cmd sed
need_cmd cut
need_cmd head
need_cmd tail
need_cmd awk
need_cmd ssh
need_cmd ansible-playbook
need_cmd find
need_cmd ls

# ---- ensure az login is valid ----
echo "==> Checking Azure login..."
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: az is NOT logged in in this job. (Did az login --service-principal run?)"
  exit 1
fi

if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
fi

declare -A MOD_DIR

clone_module() {
  local module_repo="$1"
  local key="$module_repo"

  if [[ -n "${MOD_DIR[$key]:-}" ]]; then
    echo "${MOD_DIR[$key]}"
    return 0
  fi

  # netrc for module clone (runner/control-plane only)
  cat > ~/.netrc <<EOF
machine 172.25.183.89
login ${GITEAUSER}
password ${ADMIN_TOKEN}
EOF
  chmod 600 ~/.netrc

  local url="${GITEA_BASE_URL}/MCCE_Module/${module_repo}.git"
  local dir="${WORKDIR}/${module_repo}"
  rm -rf "$dir"

  # IMPORTANT: log to stderr so function stdout stays clean (=only path)
  echo "==> Cloning module repo: ${module_repo} -> ${dir}" >&2
  git clone --depth 1 "$url" "$dir" >&2

  MOD_DIR[$key]="$dir"
  echo "$dir"
}

module_from_template() { echo "$1" | sed -E 's/_Template$//'; }

# IMPORTANT: base_user should be "tanjatrebitsch" (no date, no _ or -)
base_user_from_names() {
  echo "$1$2" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/ß/ss/g' \
    | sed -E 's/[^a-z0-9]+//g'
}

# Extract host incl. port from GITEA_BASE_URL: http://host:3000 -> host:3000
gitea_host() {
  echo "$GITEA_BASE_URL" | sed -E 's#^https?://##' | sed -E 's#/.*$##'
}

# Expected credentials CSV columns:
# date,username,email,repo,repo_url,password,token,note
lookup_repo_and_token() {
  local u="$1"
  local file="$2"

  if [[ ! -s "$file" ]]; then
    echo "ERROR: credentials file missing/empty: $file" >&2
    return 1
  fi

  awk -F',' -v u="$u" '
    NR==1 { next }
    $2==u {
      repo_url=$5; token=$7
      gsub(/"/,"",repo_url); gsub(/"/,"",token)
      print repo_url "|" token
      exit
    }
  ' "$file"
}

# ---------- parse header ----------
header="$(head -n 1 "$CSV_FILE" | tr -d '\r')"
IFS=',' read -r -a cols <<< "$header"

idx_vor=-1; idx_nach=-1; idx_tpl=-1
for i in "${!cols[@]}"; do
  c="$(echo "${cols[$i]}" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ "$c" == "vorname" ]] && idx_vor="$i"
  [[ "$c" == "nachname" ]] && idx_nach="$i"
  [[ "$c" == "module_template" ]] && idx_tpl="$i"
done

if [[ $idx_vor -lt 0 || $idx_nach -lt 0 || $idx_tpl -lt 0 ]]; then
  echo "ERROR: CSV must have header: vorname,nachname,email,module_template"
  echo "Header was: $header"
  exit 1
fi

# ---------- derive DATE_TAG from filename ----------
base="$(basename "$CSV_FILE")"
DATE_TAG="$(echo "$base" | sed -nE 's/^([0-9]{8}).*/\1/p')"
if [[ -z "${DATE_TAG:-}" ]]; then
  echo "ERROR: Could not extract date tag (DDMMYYYY) from filename: $base"
  exit 1
fi

# credentials CSV is in THIS repo (Teilnehmerlisten) under out/
CREDENTIALS_CSV="${CREDENTIALS_CSV:-out/${DATE_TAG}_credentials.csv}"
if [[ ! -s "$CREDENTIALS_CSV" ]]; then
  echo "ERROR: credentials csv missing: $CREDENTIALS_CSV"
  echo "Hint: provision_from_csv.sh must run first and commit/persist out/${DATE_TAG}_credentials.csv"
  exit 1
fi

echo "==> Using DATE_TAG=$DATE_TAG"
echo "==> CREDENTIALS_CSV=$CREDENTIALS_CSV"
echo "==> LOCATION=$LOCATION"
echo "==> WORKDIR=$WORKDIR"
echo "==> KEYS_ROOT=$KEYS_ROOT"

# ---------- loop rows ----------
while IFS= read -r line; do
  line="${line//$'\r'/}"
  [[ -z "${line// /}" ]] && continue

  IFS=',' read -r -a f <<< "$line"

  vor="$(echo "${f[$idx_vor]:-}" | xargs)"
  nach="$(echo "${f[$idx_nach]:-}" | xargs)"
  tpl="$(echo "${f[$idx_tpl]:-}" | xargs)"

  if [[ -z "$vor" || -z "$nach" || -z "$tpl" ]]; then
    echo "SKIP: missing required fields in line: $line"
    continue
  fi

  base_user="$(base_user_from_names "$vor" "$nach")"

  # 1) GITEA username (matches provision_from_csv.sh + credentials CSV)
  username_raw="${base_user}_${DATE_TAG}"

  # 2) Azure/VM slug (matches create.sh sanitize, inventory folder, key filename)
  user_slug="$(echo "$username_raw" | tr '_' '-')"

  template_repo="$(echo "$tpl" | cut -d'/' -f2)"
  module_repo="$(module_from_template "$template_repo")"

  echo "----"
  echo "Row: $line"
  echo "Derived: base_user=$base_user username_raw=$username_raw user_slug=$user_slug module_repo=$module_repo"

  mod_dir="$(clone_module "$module_repo")"
  echo "DEBUG: mod_dir='$mod_dir'"

  # Ensure scripts executable (even if repo stored without +x)
  find "$mod_dir/infra/azure" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \; || true

  create_user="$mod_dir/infra/azure/create.sh"
  create_testvm="$mod_dir/infra/azure/create_testvm.sh"

  [[ -f "$create_user" ]] || { echo "ERROR: create.sh missing: $create_user"; exit 1; }

  # -------------------------
  # TestVM only once (Azure exists-check)
  # -------------------------
  TESTVM_NAME="${TESTVM_NAME:-mcce-testvm}"
  TESTVM_RG="${TESTVM_RG:-rg-mcce-poc}"

  if [[ -x "$create_testvm" ]]; then
    if az vm show -g "$TESTVM_RG" -n "$TESTVM_NAME" >/dev/null 2>&1; then
      echo "==> TestVM exists ($TESTVM_RG/$TESTVM_NAME) -> skip"
    else
      echo "==> Provisioning TestVM (not found yet)"
      (
        cd "$mod_dir"
        DATE_TAG="$DATE_TAG" LOCATION="$LOCATION" bash "infra/azure/create_testvm.sh"
      )
    fi
  else
    echo "WARN: no create_testvm.sh -> skipping TestVM"
  fi

  # -------------------------
  # Participant VM create
  # IMPORTANT: pass username_raw (with _), create.sh makes slug itself
  # IMPORTANT: run from module root
  # -------------------------
  echo "==> Provisioning participant VM for user=${username_raw} (slug=${user_slug})"
  (
    cd "$mod_dir"
    DATE_TAG="$DATE_TAG" LOCATION="$LOCATION" bash "infra/azure/create.sh" --user "$username_raw"
  )

  # Inventory written by create.sh
  inv_file="$mod_dir/out/${user_slug}/inventory.ini"
  if [[ ! -s "$inv_file" ]]; then
    echo "ERROR: inventory missing: $inv_file"
    echo "DEBUG: find any inventory.ini under mod_dir:"
    find "$mod_dir" -maxdepth 5 -type f -name "inventory.ini" -print || true
    exit 1
  fi

  # Run Ansible base.yml on the new VM
  playbook="$mod_dir/infra/config/ansible/base.yml"
  if [[ ! -f "$playbook" ]]; then
    echo "ERROR: playbook missing: $playbook"
    exit 1
  fi

  echo "==> Running Ansible base.yml for $user_slug"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$inv_file" "$playbook"

  # Extract IP from inventory (first host under [poc])
  vm_ip="$(awk '/^\[poc\]/{found=1;next} found && $1!=""{print $1; exit}' "$inv_file")"
  if [[ -z "${vm_ip:-}" ]]; then
    echo "ERROR: could not extract vm ip from $inv_file"
    exit 1
  fi

  # SSH key created by create.sh on runner host
  ssh_key="${KEYS_ROOT}/${DATE_TAG}/${user_slug}"
  if [[ ! -f "$ssh_key" ]]; then
    echo "ERROR: expected SSH key not found: $ssh_key"
    echo "DEBUG: list keys dir:"
    ls -la "${KEYS_ROOT}/${DATE_TAG}" || true
    exit 1
  fi

  # Lookup repo_url + token for this participant (MUST use username_raw with _)
  pair="$(lookup_repo_and_token "$username_raw" "$CREDENTIALS_CSV" || true)"
  if [[ -z "${pair:-}" ]]; then
    echo "ERROR: no repo_url/token for user '$username_raw' in $CREDENTIALS_CSV"
    echo "DEBUG: first lines of credentials:"
    head -n 5 "$CREDENTIALS_CSV" || true
    exit 1
  fi

  repo_url="${pair%%|*}"
  token="${pair##*|}"
  if [[ -z "${repo_url:-}" || -z "${token:-}" ]]; then
    echo "ERROR: repo_url/token empty for user '$username_raw'"
    exit 1
  fi

  # -------------------------
  # Bootstrap repo on VM (token via stdin)
  # IMPORTANT: USERNAME must be Gitea username (with _)
  # -------------------------
  bootstrap="$mod_dir/infra/azure/bootstrap_user_repo.sh"
  [[ -f "$bootstrap" ]] || { echo "ERROR: missing bootstrap script: $bootstrap"; exit 1; }

  echo "==> Bootstrapping participant repo on VM: $username_raw @ $vm_ip"

  # IMPORTANT: disable xtrace so token never leaks
  set +x

  ssh -o StrictHostKeyChecking=no -i "$ssh_key" "azureuser@${vm_ip}" \
    "ADMIN_USER=azureuser USERNAME='$username_raw' REPO_URL='$repo_url' GITEA_HOST='$(gitea_host)' TOKEN='$token' bash -s" \
    < "$bootstrap"

  [[ "$DEBUG" == "1" ]] && set -x


done < <(tail -n +2 "$CSV_FILE")

echo "✅ Azure provisioning from participants CSV finished."
