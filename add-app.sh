#!/bin/bash
set -euo pipefail

# ============================================================
# add-app — add an application to a server prepared by setup.sh
# Usage (as the admin user): sudo add-app
#
# Each app gets its own isolated user and PM2 daemon:
#   user app-<name> (no login, no sudo), code in /var/www/<name>,
#   systemd unit pm2-app-<name>, NGINX site, SSL certificate.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN} $*${NC}"; echo -e "${GREEN}========================================${NC}"; }

REPO_RAW_URL="https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main"
CONFIG_FILE="/etc/server-setup.conf"
PLACEHOLDER_FILE="/usr/local/share/server-setup/placeholder.js"
NGINX_CONF_DIR="/etc/nginx/conf.d"

# ============================================================
# Pre-flight checks
# ============================================================

[[ $EUID -ne 0 ]] && error "This script must be run as root. Try: sudo add-app"
[[ -f "$CONFIG_FILE" ]] || error "$CONFIG_FILE not found. Run setup.sh on this server first."
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${DEPLOY_USER:?DEPLOY_USER missing from $CONFIG_FILE}"
id "$DEPLOY_USER" &>/dev/null || error "Deploy user '$DEPLOY_USER' does not exist. Run setup.sh first."

export PATH="/usr/local/bin:$PATH"
for CMD in pm2 nginx certbot; do
    command -v "$CMD" >/dev/null 2>&1 || error "'$CMD' not found. Run setup.sh first."
done
PM2_BIN="$(command -v pm2)"

# Port is taken if another app's NGINX site proxies to it or something listens on it
port_in_use() {
    local port="$1"
    grep -rqsF "proxy_pass http://localhost:${port};" "$NGINX_CONF_DIR" && return 0
    ss -Hltn "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
    return 1
}

domain_in_use() {
    local domain="$1"
    [[ -e "${NGINX_CONF_DIR}/${domain}.conf" ]] && return 0
    grep -rqsE "server_name([^;]*[[:space:]])?${domain//./\\.}([[:space:]][^;]*)?;" "$NGINX_CONF_DIR" && return 0
    return 1
}

# ============================================================
# Gather configuration
# ============================================================

section "Add App"

read -rp "App name (lowercase letters, digits, '-'; e.g. my-app): " APP_NAME
[[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{0,27}$ ]] \
    || error "Invalid app name. Use 1–28 chars: lowercase letters, digits and '-', starting with a letter."

APP_USER="app-${APP_NAME}"
APP_HOME="/home/${APP_USER}"
APP_DIR="/var/www/${APP_NAME}"
ECOSYSTEM_FILE="${APP_DIR}/ecosystem.config.js"
PM2_UNIT="pm2-${APP_USER}"
DEPLOY_SUDOERS="/etc/sudoers.d/${DEPLOY_USER}-${APP_USER}"

id "$APP_USER" &>/dev/null && error "User '$APP_USER' already exists — is '$APP_NAME' already set up?"
[[ -e "$APP_DIR" ]] && error "$APP_DIR already exists — is '$APP_NAME' already set up?"

read -rp "Domain name (e.g. my-app.example.com): " DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || error "Invalid domain name."
DOMAIN="${DOMAIN,,}"
domain_in_use "$DOMAIN" && error "Domain '$DOMAIN' is already configured in $NGINX_CONF_DIR."

DEFAULT_PORT=3000
while port_in_use "$DEFAULT_PORT"; do DEFAULT_PORT=$((DEFAULT_PORT + 1)); done
read -rp "App port [${DEFAULT_PORT}]: " APP_PORT
APP_PORT="${APP_PORT:-$DEFAULT_PORT}"
[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1024 && APP_PORT <= 65535 )) \
    || error "Port must be a number between 1024 and 65535."
port_in_use "$APP_PORT" && error "Port $APP_PORT is already used by another app or process."

read -rp "Email for SSL certificate [${SSL_EMAIL:-}]: " APP_SSL_EMAIL
APP_SSL_EMAIL="${APP_SSL_EMAIL:-${SSL_EMAIL:-}}"
[[ -z "$APP_SSL_EMAIL" ]] && error "SSL email cannot be empty."

echo ""
info "App summary:"
echo "  App name:    $APP_NAME"
echo "  App user:    $APP_USER"
echo "  Directory:   $APP_DIR"
echo "  Domain:      $DOMAIN"
echo "  Port:        $APP_PORT"
echo "  SSL email:   $APP_SSL_EMAIL"
echo "  Deploy user: $DEPLOY_USER"
echo ""
read -rp "Create this app? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && error "Aborted by user."

# Run a command as the app user (which has no login shell) with its own PM2 home
as_app() {
    (cd "$APP_HOME" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" PM2_HOME="${APP_HOME}/.pm2" "$@")
}

# ============================================================
# 1. App User
# ============================================================

section "1. App User"

useradd --system -U --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
chmod 750 "$APP_HOME"
info "Created '$APP_USER' (no login shell, no sudo)."

# Deploy joins the app group so it can set group ownership/permissions on deployed
# files and read PM2 logs. (The reverse is not true: the app cannot write deploy's files.)
usermod -aG "$APP_USER" "$DEPLOY_USER"

# ============================================================
# 2. Application Directory
# ============================================================

section "2. Application Directory"

# Code is owned by deploy and only readable by this app's user (setgid keeps new files
# in the app group). Other apps cannot read it. Grant write access only where needed.
mkdir -p "$APP_DIR"
chown "${DEPLOY_USER}:${APP_USER}" "$APP_DIR"
chmod 2750 "$APP_DIR"

if [[ -f "$PLACEHOLDER_FILE" ]]; then
    cp "$PLACEHOLDER_FILE" "${APP_DIR}/server.js"
else
    curl -fsSL "${REPO_RAW_URL}/placeholder.js" -o "${APP_DIR}/server.js" || error "Failed to download placeholder.js"
fi

cat > "$ECOSYSTEM_FILE" <<EOF
module.exports = {
  apps: [
    {
      // Placeholder: update script/interpreter for your app after deploying:
      //
      // Next.js:
      //   script: "npx", args: "next start"
      //
      // TypeScript (tsx):
      //   script: "index.ts", interpreter: "./node_modules/.bin/tsx"
      //   (or interpreter: "tsx" if tsx is installed globally)
      name: "${APP_NAME}",
      script: "node",
      args: "server.js",
      cwd: "${APP_DIR}/",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      env: {
        NODE_ENV: "production",
        PORT: ${APP_PORT},
        DOMAIN: "${DOMAIN}",
      },
    },
  ],
}
EOF

chown "${DEPLOY_USER}:${APP_USER}" "${APP_DIR}/server.js" "$ECOSYSTEM_FILE"
chmod 640 "${APP_DIR}/server.js" "$ECOSYSTEM_FILE"
info "Created $APP_DIR (owner: $DEPLOY_USER, group: $APP_USER, mode 2750) with placeholder app."

# ============================================================
# 3. PM2 (dedicated daemon for this app user)
# ============================================================

section "3. PM2"

# systemd unit pm2-app-<name> starts this app's PM2 daemon on boot
if pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME"; then
    systemctl start "$PM2_UNIT" || true
    info "PM2 startup configured (systemd unit: $PM2_UNIT)."
else
    warn "Could not configure PM2 startup. Run as root: pm2 startup systemd -u $APP_USER --hp $APP_HOME"
fi

# Deploy may run pm2 only as this app's user — never as root.
echo "${DEPLOY_USER} ALL=(${APP_USER}) NOPASSWD: ${PM2_BIN}" > "$DEPLOY_SUDOERS"
chmod 440 "$DEPLOY_SUDOERS"
visudo -cf "$DEPLOY_SUDOERS" >/dev/null || { rm -f "$DEPLOY_SUDOERS"; error "Invalid sudoers rule for $DEPLOY_USER."; }
info "'$DEPLOY_USER' can run: sudo -u $APP_USER pm2 ..."

as_app pm2 install pm2-logrotate
as_app pm2 set pm2-logrotate:max_size 10M
as_app pm2 set pm2-logrotate:retain 7
as_app pm2 set pm2-logrotate:compress true
as_app pm2 set pm2-logrotate:dateFormat YYYY-MM-DD_HH-mm-ss
as_app pm2 set pm2-logrotate:rotateInterval '0 0 * * *'
info "PM2 log rotation configured (10M max, 7 days, daily at midnight, gzip compressed)."

# ============================================================
# 4. NGINX Site
# ============================================================

section "4. NGINX Site"

NGINX_CONF="${NGINX_CONF_DIR}/${DOMAIN}.conf"
# Only the HTTP block — certbot will add the redirect and the 443 SSL block
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 30M;

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

if ! nginx -t; then
    rm -f "$NGINX_CONF"
    error "NGINX configuration test failed; removed $NGINX_CONF."
fi
systemctl reload nginx
info "NGINX site configured: $NGINX_CONF"

# ============================================================
# 5. SSL Certificate
# ============================================================

section "5. SSL Certificate"

info "Requesting SSL certificate from Let's Encrypt for $DOMAIN ..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$APP_SSL_EMAIL" --redirect || {
    warn "Certbot failed. This usually means DNS has not propagated yet."
    warn "Once DNS is ready, run: sudo certbot --nginx -d $DOMAIN"
}

# ============================================================
# 6. Start placeholder app
# ============================================================

section "6. Starting Placeholder App"

as_app pm2 start "$ECOSYSTEM_FILE"
as_app pm2 save
info "Placeholder app started via PM2 as '$APP_USER'."

# ============================================================
# Done
# ============================================================

section "App '$APP_NAME' Ready"

echo ""
info "Next steps:"
echo "  1. Visit http://${DOMAIN} to confirm the placeholder page loads."
echo ""
echo "  2. When ready to deploy your app (as ${DEPLOY_USER}):"
echo "       a. Push your build to ${DEPLOY_USER}@${DOMAIN}:${APP_DIR}"
echo "       b. Update ${ECOSYSTEM_FILE} (switch script to the command to start your application, e.g. 'npx next start')"
echo "       c. Run: sudo -u ${APP_USER} pm2 restart ${APP_NAME} && sudo -u ${APP_USER} pm2 save"
echo "       d. If the app writes to disk (e.g. Next.js .next/cache, uploads), make only those directories writable:"
echo "            chmod -R g+w ${APP_DIR}/.next/cache"
echo ""
echo "  3. Add your .env variables on the server (as ${DEPLOY_USER}):"
echo "       nano ${APP_DIR}/.env && chmod 640 ${APP_DIR}/.env"
echo ""
echo "  4. Test certificate auto-renewal (as admin):"
echo "       sudo certbot renew --dry-run"
echo ""
info "Placeholder is live at http://${DOMAIN}"
info "Once certbot succeeded, it will also be at https://${DOMAIN}"
