#!/usr/bin/env bash

# Datei: provision_from_csv.sh
# Autor: Tatjana Baier
# E-Mail: tatjana@phoolan.at
# Version: 1.0.0
# Lizenz:
#   MIT License


set -euo pipefail

CSV_FILE="${1:?Usage: $0 <csv-file>}"

: "${GITEA_URL:?env GITEA_URL missing}"
: "${ADMIN_TOKEN:?env ADMIN_TOKEN missing}"
: "${PRUEFUNG_ORG:?env PRUEFUNG_ORG missing}"

TEAM_PRUEFER_NAME="${TEAM_PRUEFER_NAME:-Pruefer}"

api() {
  # Usage: api [curl args...]
  curl -sS -H "Authorization: token $ADMIN_TOKEN" -H "Content-Type: application/json" "$@"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/ß/ss/g' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g'
}

rand_pw() {
  openssl rand -base64 18 | tr -d '\n'
}

# ---------- Date tag from filename: 31012026_teilnehmer.csv -> 31012026
base="$(basename "$CSV_FILE")"
DATE_TAG="$(echo "$base" | sed -nE 's/^([0-9]{8}).*/\1/p')"
if [[ -z "${DATE_TAG:-}" ]]; then
  echo "ERROR: Could not extract date tag (DDMMYYYY) from filename: $base"
  exit 1
fi

mkdir -p out
OUT_FILE="out/${DATE_TAG}_credentials.csv"
if [[ ! -s "$OUT_FILE" ]]; then
  echo "date,username,email,repo,repo_url,password,token,note" > "$OUT_FILE"
fi

echo "Using DATE_TAG=$DATE_TAG"
echo "Writing credentials to $OUT_FILE"

# ---------- Team-ID for Prüfer
teams_json="$(curl -sS -H "Authorization: token $ADMIN_TOKEN" \
  "$GITEA_URL/api/v1/orgs/$PRUEFUNG_ORG/teams")"

echo "$teams_json" | jq -e 'type=="array"' >/dev/null || {
  echo "ERROR: Expected team array, got:"
  echo "$teams_json"
  exit 1
}

TEAM_ID="$(echo "$teams_json" | jq -r --arg n "$TEAM_PRUEFER_NAME" '.[] | select(.name==$n) | .id' | head -n 1)"
if [[ -z "${TEAM_ID:-}" || "${TEAM_ID:-}" == "null" ]]; then
  echo "ERROR: Team '$TEAM_PRUEFER_NAME' not found in org '$PRUEFUNG_ORG'"
  exit 1
fi
echo "Using Pruefer team id=$TEAM_ID"

# ---------- CSV read (comma or semicolon), CRLF tolerant
# NOTE: If your CSV contains line breaks inside a row, you MUST fix the CSV (Excel export / editor).
tail -n +2 "$CSV_FILE" | while IFS= read -r line; do
  [[ -z "${line// /}" ]] && continue
  line="${line//$'\r'/}"  # remove CR

  # try comma first
  IFS=',' read -r vorname nachname email modul_template <<< "$line"
  # fallback: semicolon (common in DE Excel)
  if [[ -z "${modul_template:-}" ]]; then
    IFS=';' read -r vorname nachname email modul_template <<< "$line"
  fi

  # trim
  vorname="$(echo "${vorname:-}" | xargs)"
  nachname="$(echo "${nachname:-}" | xargs)"
  email="$(echo "${email:-}" | xargs)"
  modul_template="$(echo "${modul_template:-}" | xargs)"

  echo "PARSED: vorname='$vorname' nachname='$nachname' email='$email' modul_template='$modul_template'"

  if [[ -z "$vorname" || -z "$nachname" || -z "$email" || -z "$modul_template" ]]; then
    echo "SKIP: missing field(s) after parsing"
    continue
  fi

  # modul_template must be "OWNER/REPO"
  TEMPLATE_OWNER="$(echo "$modul_template" | cut -d'/' -f1)"
  TEMPLATE_REPO="$(echo "$modul_template" | cut -d'/' -f2)"

  if [[ -z "${TEMPLATE_OWNER:-}" || -z "${TEMPLATE_REPO:-}" ]]; then
    echo "ERROR: modul_template must be OWNER/REPO, got: '$modul_template'"
    exit 1
  fi

  base_user="$(slugify "${vorname}${nachname}")"
  username="$(slugify "${base_user}_${DATE_TAG}")"
  repo_name="$(slugify "${DATE_TAG}_${vorname}${nachname}")"
  repo_url="$GITEA_URL/$PRUEFUNG_ORG/$repo_name.git"

  echo "----"
  echo "User=$username Repo=$PRUEFUNG_ORG/$repo_name Template=$TEMPLATE_OWNER/$TEMPLATE_REPO"

  # ---------- 1) Repo from template (only if not exists)
  repo_check="$(api "$GITEA_URL/api/v1/repos/$PRUEFUNG_ORG/$repo_name" || true)"
  repo_exists="$(echo "$repo_check" | jq -r 'if has("id") then "yes" else "no" end' 2>/dev/null || echo no)"

  if [[ "$repo_exists" == "no" ]]; then
    # IMPORTANT: set at least one template item (git_content=true), otherwise Gitea errors
    # Fields are part of GenerateRepoOption (git_content/labels/topics/webhooks/...) :contentReference[oaicite:1]{index=1}
    gen_resp="$(api -X POST "$GITEA_URL/api/v1/repos/$TEMPLATE_OWNER/$TEMPLATE_REPO/generate" \
      -d "{
        \"owner\": \"$PRUEFUNG_ORG\",
        \"name\": \"$repo_name\",
        \"private\": true,
        \"description\": \"Prüfung $DATE_TAG – $vorname $nachname\",
        \"git_content\": true
      }")"

    echo "DEBUG generate response: $gen_resp"

    if echo "$gen_resp" | jq -e 'has("message")' >/dev/null 2>&1; then
      echo "ERROR: repo generate failed: $gen_resp"
      exit 1
    fi

    echo "Repo created."

    # wait until repo is available  
    for i in {1..10}; do
    chk="$(api "$GITEA_URL/api/v1/repos/$PRUEFUNG_ORG/$repo_name" || true)"
    echo "$chk" | jq -e 'has("id")' >/dev/null 2>&1 && break
    sleep 1
    done

  else
    echo "Repo exists -> skip create."
  fi

  # ---------- 2) User create (idempotent)
  user_check="$(api "$GITEA_URL/api/v1/users/$username" || true)"
  user_exists="$(echo "$user_check" | jq -r 'if has("id") then "yes" else "no" end' 2>/dev/null || echo no)"

  pw=""
  token=""
  note=""

  if [[ "$user_exists" == "no" ]]; then
    pw="$(rand_pw)"

    api -X POST "$GITEA_URL/api/v1/admin/users" \
      -d "{
        \"username\": \"$username\",
        \"email\": \"$email\",
        \"password\": \"$pw\",
        \"must_change_password\": false,
        \"send_notify\": false
      }" >/dev/null

    # Token via BasicAuth + scopes required in newer Gitea
    token_resp="$(curl -sS -L -X POST \
      "$GITEA_URL/api/v1/users/$username/tokens" \
      -u "$username:$pw" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"vm-$DATE_TAG\",\"scopes\":[\"write:repository\"]}")"

    token="$(echo "$token_resp" | jq -r '.sha1 // empty')"
    if [[ -z "${token:-}" ]]; then
      echo "ERROR: token creation failed. response=$token_resp"
      exit 1
    fi

    note="created"
  else
    # User exists -> password unknown -> cannot mint token here
    note="user-exists-skip-token"
    echo "User exists -> skipping token creation (password unknown)."
  fi

  # 3) Rechte setzen: User write (Debug-Version)
  collab_body="$(mktemp)"
  collab_code="$(curl -sS -o "$collab_body" -w "%{http_code}" \
    -H "Authorization: token $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -X PUT "$GITEA_URL/api/v1/repos/$PRUEFUNG_ORG/$repo_name/collaborators/$username" \
    -d '{ "permission": "write" }')"

  echo "DEBUG collaborator http=$collab_code body=$(cat "$collab_body")"

  if [[ "$collab_code" != "204" && "$collab_code" != "201" ]]; then
    echo "ERROR: collaborator add failed"
    exit 1
  fi



  api -X PUT "$GITEA_URL/api/v1/teams/$TEAM_ID/repos/$PRUEFUNG_ORG/$repo_name" >/dev/null || true

  echo "$DATE_TAG,$username,$email,$repo_name,$repo_url,\"$pw\",\"$token\",\"$note\"" >> "$OUT_FILE"
  echo "DEBUG writing out line for $username (note=$note)"
done

echo "DONE: $OUT_FILE"
