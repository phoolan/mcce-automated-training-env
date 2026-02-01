#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-azureuser}"
: "${USERNAME:?missing USERNAME (gitea username, with _)}"
: "${REPO_URL:?missing REPO_URL}"
: "${GITEA_HOST:?missing GITEA_HOST}"
: "${TOKEN:?missing TOKEN (env var)}"

# Ensure git exists
if ! command -v git >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y git
fi

WS="/home/${ADMIN_USER}/workspace"
mkdir -p "$WS"
cd "$WS"

# .netrc for THIS VM USER only
NETRC="/home/${ADMIN_USER}/.netrc"
umask 077
cat > "$NETRC" <<EOF
machine ${GITEA_HOST}
login ${USERNAME}
password ${TOKEN}
EOF

chmod 600 "$NETRC"
sudo chown "${ADMIN_USER}:${ADMIN_USER}" "$NETRC"

repo_dir="$(basename "$REPO_URL")"
repo_dir="${repo_dir%.git}"

# aktivieren bei via internet erreichbarem gitsrv
#if [[ ! -d "$repo_dir/.git" ]]; then
#  git clone "$REPO_URL" "$repo_dir"
#else
#  cd "$repo_dir"
#  git remote set-url origin "$REPO_URL" || true
#  git fetch --all
#  git reset --hard origin/HEAD || true
#fi

sudo chown -R "${ADMIN_USER}:${ADMIN_USER}" "$WS"
echo "OK(bootstrap): repo ready in $WS/$repo_dir"
