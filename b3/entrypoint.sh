#!/usr/bin/env bash
set -euo pipefail

# --- locate the example ini inside the cloned repo ---
TEMPLATE=""
for CAND in \
  /opt/b3/b3/conf/b3.distribution.ini \
  /opt/b3/b3/conf/b3.ini 
do
  if [ -f "$CAND" ]; then TEMPLATE="$CAND"; break; fi
done

if [ -z "${TEMPLATE}" ]; then
  echo "ERROR: could not find b3.distribution.ini in the image" >&2
  ls e-al /opt/b3/b3/conf || true
  exit 1
fi

mkdir -p /app/conf /app/logs

OUT_INI="/app/conf/b3.ini"
cp "$TEMPLATE" "$OUT_INI"
# strip CRLF to avoid pattern mismatch when files were created on Windows
sed -i 's/\r$//' "$OUT_INI"

# --- dequote helper (because .env often contains quotes on Windows) ---
dequote() {
  local v="${1:-}"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

# ---- Normalize DB envs (works with MYSQL_B3_* or B3_DB_*) --------------------
MYSQL_B3_HOST="${MYSQL_B3_HOST:-${B3_DB_HOST:-db}}"
MYSQL_B3_DB="${MYSQL_B3_DB:-${B3_DB_NAME:-b3}}"
MYSQL_B3_USER="${MYSQL_B3_USER:-${B3_DB_USER:-b3user}}"
MYSQL_B3_PASSWORD="${MYSQL_B3_PASSWORD:-${B3_DB_PASS:-b3pass}}"
# --- gather env (falling back to sane defaults) ---
DB_HOST="db"
DB_NAME="$(dequote "${MYSQL_B3_DB:-b3}")"
DB_USER="$(dequote "${MYSQL_B3_USER:-b3user}")"
DB_PASS="$(dequote "${MYSQL_B3_PASSWORD:-b3pass}")"
DB_DSN="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"


PARSER="$(dequote "${B3_PARSER:-cod}")"
BOT_NAME="$(dequote "${B3_BOT_NAME:-b3}")"
BOT_PREFIX="$(dequote "${B3_BOT_PREFIX:-!}")"

# Note: your .env uses B3_GAME_LOG_PATH for the Windows path; inside the container we want /game-logs/games_mp.log
# If you set B3_GAME_LOG explicitly, it will win. Otherwise default to /game-logs/games_mp.log.
GAME_LOG="$(dequote "${B3_GAME_LOG:-/game-logs/games_mp.log}")"

RCON_IP="$(dequote "${B3_RCON_IP:-host.docker.internal}")"
RCON_PORT="$(dequote "${B3_RCON_PORT:-28960}")"
RCON_PASSWORD="$(dequote "${B3_RCON_PASSWORD:-rconpass}")"

# --- show exactly what the entrypoint sees ---
echo "=== ENV seen by b3 entrypoint ==="
echo "MYSQL_B3_DB=${DB_NAME}"
echo "MYSQL_B3_USER=${DB_USER}"
echo "MYSQL_B3_PASSWORD=${DB_PASS}"
echo "B3_DB_HOST=${DB_HOST}"
echo "B3_PARSER=${PARSER}"
echo "B3_BOT_NAME=${BOT_NAME}"
echo "B3_BOT_PREFIX=${BOT_PREFIX}"
echo "B3_GAME_LOG=${GAME_LOG}"
echo "B3_RCON_IP=${RCON_IP}"
echo "B3_RCON_PORT=${RCON_PORT}"
echo "B3_RCON_PASSWORD=${RCON_PASSWORD}"
echo "DB_DSN=${DB_DSN}"
echo "Using template: ${TEMPLATE}"
echo "Writing to: ${OUT_INI}"
echo "================================="

# --- update ONLY the keys we care about, and only in their sections ---
awk -v parser="$PARSER" \
    -v dsn="$DB_DSN" \
    -v bot="$BOT_NAME" \
    -v prefix="$BOT_PREFIX" \
    -v game_log="$GAME_LOG" \
    -v rip="$RCON_IP" \
    -v rport="$RCON_PORT" \
    -v rpass="$RCON_PASSWORD" '
  BEGIN { sec = "" }
  /^\[/ { sec = $0 }
  {
    if (sec ~ /^\[b3\]/) {
      if ($0 ~ /^[ \t]*parser[ \t]*:/)        {$0="parser: " parser}
      else if ($0 ~ /^[ \t]*database[ \t]*:/)  {$0="database: " dsn}
      else if ($0 ~ /^[ \t]*bot_name[ \t]*:/)  {$0="bot_name: " bot}
      else if ($0 ~ /^[ \t]*bot_prefix[ \t]*:/){$0="bot_prefix: " prefix}
    } else if (sec ~ /^\[server\]/) {
      if ($0 ~ /^[ \t]*game_log[ \t]*:/)       {$0="game_log: " game_log}
      else if ($0 ~ /^[ \t]*rcon_ip[ \t]*:/)   {$0="rcon_ip: " rip}
      else if ($0 ~ /^[ \t]*port[ \t]*:/) {$0="port: " rport}
      else if ($0 ~ /^[ \t]*rcon_password[ \t]*:/){$0="rcon_password: " rpass}
	  else if ($0 ~ /^[ \t]*punkbuster[ \t]*:/){$0="punkbuster: " "off"}
    } else if (sec ~ /^\[plugins\]/) {
	  if ($0 ~ /^[ \t]*# xlrstats[ \t]*:/)       {$0="xlrstats: " "@b3/conf/plugin_xlrstats.ini"}
	}
    print
  }
' "$OUT_INI" > "${OUT_INI}.tmp" && mv "${OUT_INI}.tmp" "$OUT_INI"

echo "==== Using b3.ini (key lines) ===="
egrep -n '^\[b3\]$|^\[server\]$|^(parser|database|bot_name|bot_prefix|game_log|rcon_ip|port|rcon_password|punkbuster|xlrstats)\s*:' "$OUT_INI" || true
echo "=================================="

# --- B3: ensure schema is present ------------------------------------------------
echo "[b3-init] Ensuring B3 schema exists in ${MYSQL_B3_DB} …"

# Check a canonical table (e.g., "clients"). Adjust if your schema differs.
if ! mysql -h db -u"${MYSQL_B3_USER}" -p"${MYSQL_B3_PASSWORD}" "${MYSQL_B3_DB}" \
     -N -e "SHOW TABLES LIKE 'clients';" | grep -q clients; then
  echo "[b3-init] Importing /opt/b3/b3/sql/mysql/b3.sql into ${MYSQL_B3_DB} …"
  mysql -h db -u"${MYSQL_B3_USER}" -p"${MYSQL_B3_PASSWORD}" "${MYSQL_B3_DB}" < /opt/b3/b3/sql/mysql/b3.sql
  echo "[b3-init] B3 schema imported."
else
  echo "[b3-init] B3 schema already present; skipping import."
fi

# run b3
exec python /opt/b3/b3_run.py -c "$OUT_INI"
