#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="/var/www/html"
CFG_DIR="$APP_ROOT/app/Config"
INST_FLAG="$APP_ROOT/app/tmp/installed.lock"

log(){ echo "[xlr-init] $*"; }

# Show what we think the base URL is (helps debug)
echo "XLR_BASE_URL=${XLR_BASE_URL:-unset}"

# If XLR_BASE_URL is like 'http://xlrstats.local', make sure that hostname resolves in the container
if [ -n "${XLR_BASE_URL:-}" ]; then
  _host="$(echo "$XLR_BASE_URL" | sed -E 's~^[a-zA-Z]+://([^/:]+).*~\1~')"
  if [ -n "$_host" ]; then
    # If it doesn't resolve, pin it to 127.0.0.1 in /etc/hosts
    if ! getent hosts "$_host" >/dev/null 2>&1; then
      echo "127.0.0.1 $_host" >> /etc/hosts
      echo "Pinned $_host -> 127.0.0.1 in /etc/hosts"
    fi
  fi
fi

# Run XLRstats schema if tables missing
SCHEMA_SQL="$APP_ROOT/app/Config/Schema/xlrstats.sql"

if [ -f "$SCHEMA_SQL" ]; then
  log "Checking if XLRstats schema needs to be applied..."
  if ! mysql -h"db" -u"${XLR_DB_USER}" -p"${XLR_DB_PASS}" "${XLR_DB_NAME}" -e "SHOW TABLES LIKE 'users';" | grep -q users; then
    log "No users table found, applying schema..."
    mysql -h"db" -u"${XLR_DB_USER}" -p"${XLR_DB_PASS}" "${XLR_DB_NAME}" < "$SCHEMA_SQL"
    log "Schema applied to ${XLR_DB_NAME}"
  else
    log "Schema already present, skipping."
  fi
else
  log "Schema file not found at $SCHEMA_SQL"
fi


DB_DIR=/var/www/html/app/Config
DB_FILE=$CFG_DIR/database.php

mkdir -p "$DB_DIR"

echo "XLR_DB_USER = ${XLR_DB_USER}"
echo "XLR_DB_PASS = ${XLR_DB_PASS}"
echo "XLR_DB_NAME = ${XLR_DB_NAME}"

cat > "$DB_FILE" <<'PHP'
<?php
class DATABASE_CONFIG {
  public $default;

  public function __construct() {
    $this->default = array(
    'datasource' => 'Database/Mysql',
    'persistent' => false,
    'host'       => 'db',
    'login'      => getenv('XLR_DB_USER') ? getenv('XLR_DB_USER') : 'xlruser',
    'password'   => getenv('XLR_DB_PASS') ? getenv('XLR_DB_PASS') : 'xlrpass',
    'database'   => getenv('XLR_DB_NAME') ? getenv('XLR_DB_NAME') : 'xlrstats',
    'encoding'   => 'utf8mb4',
    'prefix'     => '',
	);
  }
}
PHP
log "Wrote app/Config/database.php"

# --- Normalize and apply host settings ---------------------------------
: "${XLR_VHOST:=xlrstats.local}"

# Tell Apache its ServerName (quiets AH00558 and ensures $_SERVER vars are sane)
sed -i "s/^ServerName .*/ServerName ${XLR_VHOST}/" /etc/apache2/conf-available/servername.conf \
  || echo "ServerName ${XLR_VHOST}" > /etc/apache2/conf-available/servername.conf
apachectl -t >/dev/null 2>&1 || true

# --- Patch XlrFunctionsComponent to disable license calls ---
XLR_FILE="/var/www/html/app/Controller/Component/XlrFunctionsComponent.php"
if [ -f "$XLR_FILE" ]; then
  echo "Patching getLicenseDetails() in $XLR_FILE ..."
  # Replace the entire function block (201–249) with a stub
  sed -i '201,249c\
    public function getLicenseDetails($key) {\n\
        return false;\n\
    }' "$XLR_FILE"
fi

# --- Disable installer wizard ---
CORE_FILE="$APP_ROOT/app/Config/core.php"
if [ -f "$CORE_FILE" ]; then
  sed -i "s/Configure::write('Installer.enable', *true);/Configure::write('Installer.enable', false);/" "$CORE_FILE"
  echo "[xlr-init] Disabled installer wizard in core.php"
fi


# --- Seed admin user and initial server WITHOUT loading Cake in CLI ----
# helpers
_mysql() {
  mysql -h"db" -u"${XLR_DB_USER:-xlruser}" -p"${XLR_DB_PASS:-xlrpass}" "${XLR_DB_NAME:-xlrstats}" -N -e "$1"
}
have_table() { _mysql "SHOW TABLES LIKE '$1'" | grep -qx "$1"; }
have_col()   { _mysql "SHOW COLUMNS FROM $1 LIKE '$2'" | grep -q .; }
sql_esc()    { printf "%s" "$1" | sed "s/'/''/g"; }

# 3a) Admin user
if have_table "users"; then
  U="${XLR_ADMIN_USERNAME:-xlradmin}"
  E="${XLR_ADMIN_EMAIL:-null@xlrstats.local}"
  N="${XLR_ADMIN_NAME:-Admin}"
  P="${XLR_ADMIN_PASSWORD:-changeme}"

  # exists?
  if ! _mysql "SELECT id FROM users WHERE username='$(sql_esc "$U")' LIMIT 1" | grep -q .; then
    # Make a bcrypt hash with PHP *without* loading Cake
    HASH="$(php -r 'echo password_hash(getenv("PW"), PASSWORD_BCRYPT);' 2>/dev/null PW="$P")"
    [ -n "$HASH" ] || HASH="$(php -r 'echo crypt(getenv("PW"), "$2y$10$abcdefghijklmnopqrstuv");' PW="$P")"

    # Build field list dynamically based on available columns
    FIELDS=(username password email)
    VALUES=("'$(sql_esc "$U")'" "'$(sql_esc "$HASH")'" "'$(sql_esc "$E")'")
    if have_col users name;     then FIELDS+=(name)     ; VALUES+=("'$(sql_esc "$N")'"); fi
    if have_col users realname; then FIELDS+=(realname) ; VALUES+=("'$(sql_esc "$N")'"); fi
    if have_col users role;     then FIELDS+=(role)     ; VALUES+=("'admin'"); fi
    if have_col users created;  then FIELDS+=(created)  ; VALUES+=("'$(date +"%F %T")'"); fi

    _mysql "INSERT INTO users ($(IFS=,; echo "${FIELDS[*]}")) VALUES ($(IFS=,; echo "${VALUES[*]}"))"
    echo "[xlr-init] admin user created: ${U}"
  else
    echo "[xlr-init] admin user exists: ${U}"
  fi
else
  echo "[xlr-init] users seed skipped (no users table)"
fi

# 3b) Initial server row with B3 link
if have_table "servers"; then
  SNAME="${XLR_SERVER_NAME:-server}"
  GAME="${XLR_GAME:-coduo}"
  B3H="db"
  B3U="${B3_DB_USER:-b3user}"
  B3P="${B3_DB_PASS:-b3pass}"

  if ! _mysql "SELECT id FROM servers WHERE servername='$(sql_esc "$SNAME")' LIMIT 1" | grep -q .; then
    F=(servername gamename dbhost dbuser dbpass)
    V=(
      "'$(sql_esc "$SNAME")'"
      "'$(sql_esc "$GAME")'"
      "'$(sql_esc "$B3H")'"
      "'$(sql_esc "$B3U")'"
      "'$(sql_esc "$B3P")'"
    )
    if have_col servers created; then F+=(created); V+=("'$(date +"%F %T")'"); fi
    if have_col servers updated; then F+=(updated); V+=("'$(date +"%F %T")'"); fi

    _mysql "INSERT INTO servers ($(IFS=,; echo "${F[*]}")) VALUES ($(IFS=,; echo "${V[*]}"))"
    echo "[xlr-init] server row created: ${SNAME} (${GAME})"
  else
    echo "[xlr-init] server row exists: ${SNAME}"
  fi
else
  echo "[xlr-init] servers seed skipped (no servers table)"
fi



# Mark install complete so wizard won’t run

mkdir -p "$(dirname "$INST_FLAG")"
echo "ok" > "$INST_FLAG"
log "Install flag written: $INST_FLAG"


# Optional: force IPv4 for curl in case of weird IPv6 resolution
export CURL_IPRESOLVE=4
export XLR_BASE_URL=${XLR_BASE_URL:-http://xlrstats.local}

echo "XLR_BASE_URL=${XLR_BASE_URL}"
echo "Apache ServerName => ${XLR_VHOST}"

export CURL_FORCE_HTTP_1_1=1

exec apache2-foreground