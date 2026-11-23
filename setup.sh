#!/bin/bash
set -euo pipefail

# ============================================================
# Production Server Setup Script
# Run as root on a fresh Ubuntu server
#
# Users created:
#   admin  — SSH + sudo (password required) for server maintenance
#   deploy — SSH, owns the app code, can only run pm2 as the app user
#   app    — no login, no sudo; runs the application process via PM2
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN} $*${NC}"; echo -e "${GREEN}========================================${NC}"; }

# ============================================================
# Pre-flight checks
# ============================================================

[[ $EUID -ne 0 ]] && error "This script must be run as root. Try: sudo bash setup.sh"

command -v apt >/dev/null 2>&1 || error "This script requires an apt-based Linux distribution (Ubuntu/Debian)."

# ============================================================
# Gather configuration
# ============================================================

section "Configuration"

read -rp "Domain name (e.g. my-new-app.domain-name.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Domain name cannot be empty."

read -rp "App name (used for directories and PM2, e.g. my-new-app): " APP_NAME
[[ -z "$APP_NAME" ]] && error "App name cannot be empty."

echo ""
read -rp "Admin username (SSH + sudo, for server maintenance) [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

if id "$ADMIN_USER" &>/dev/null; then
    ADMIN_PASSWORD=""
    info "User '$ADMIN_USER' already exists — keeping its current password."
else
    read -rsp "Password for '$ADMIN_USER' (required for sudo): " ADMIN_PASSWORD; echo ""
    [[ -z "$ADMIN_PASSWORD" ]] && error "Admin password cannot be empty."
    read -rsp "Confirm password: " ADMIN_PASSWORD_CONFIRM; echo ""
    [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]] && error "Passwords do not match."
fi

read -rp "Admin SSH public key (leave blank to copy root's authorized_keys): " ADMIN_SSH_KEY

echo ""
read -rp "Deploy username (uploads code, restarts the app) [deploy]: " DEPLOY_USER
DEPLOY_USER="${DEPLOY_USER:-deploy}"

read -rp "Deploy SSH public key (leave blank to skip): " DEPLOY_SSH_KEY

echo ""
read -rp "App runtime username (runs the app, no login) [app]: " APP_USER
APP_USER="${APP_USER:-app}"

[[ "$ADMIN_USER" == "$DEPLOY_USER" || "$ADMIN_USER" == "$APP_USER" || "$DEPLOY_USER" == "$APP_USER" ]] \
    && error "Admin, deploy and app users must all be different."
for U in "$ADMIN_USER" "$DEPLOY_USER" "$APP_USER"; do
    [[ "$U" == "root" ]] && error "'root' cannot be used as the admin, deploy or app user."
done

echo ""
read -rp "Node.js app port [3000]: " APP_PORT
APP_PORT="${APP_PORT:-3000}"

echo ""
info "Available runtimes: node, deno, bun (space-separated, e.g. 'node bun')"
read -rp "Runtimes to install [node]: " RUNTIMES_INPUT
RUNTIMES_INPUT="${RUNTIMES_INPUT:-node}"
read -ra RUNTIMES <<< "$RUNTIMES_INPUT"

NODE_VERSION=""
if printf '%s\n' "${RUNTIMES[@]}" | grep -q "^node$"; then
    echo ""
    read -rp "Node.js version [lts]: " NODE_VERSION
    NODE_VERSION="${NODE_VERSION:-lts}"
fi

echo ""
read -rp "Email for SSL certificate (Let's Encrypt): " SSL_EMAIL
[[ -z "$SSL_EMAIL" ]] && error "SSL email cannot be empty."

echo ""
info "Configuration summary:"
echo "  Domain:      $DOMAIN"
echo "  App name:    $APP_NAME"
echo "  Admin user:  $ADMIN_USER"
echo "  Deploy user: $DEPLOY_USER"
echo "  App user:    $APP_USER"
echo "  App port:    $APP_PORT"
echo "  Runtimes:    ${RUNTIMES[*]}"
[[ -n "$NODE_VERSION" ]] && echo "  Node.js ver: $NODE_VERSION"
echo "  SSL email:   $SSL_EMAIL"
echo ""
read -rp "Proceed with setup? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && error "Aborted by user."

APP_DIR="/var/www/${APP_NAME}"
APP_HOME="/home/${APP_USER}"
ECOSYSTEM_FILE="${APP_DIR}/ecosystem.config.js"

# Run a command as the app user (which has no login shell) with its own PM2 home
as_app() {
    (cd "$APP_HOME" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" PM2_HOME="${APP_HOME}/.pm2" "$@")
}

# Write an authorized_keys file for a user
install_ssh_keys() {
    local user="$1" keys="$2"
    local ssh_dir="/home/${user}/.ssh"
    mkdir -p "$ssh_dir"
    printf '%s\n' "$keys" > "${ssh_dir}/authorized_keys"
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${user}:${user}" "$ssh_dir"
}

# ============================================================
# 4. User Management
# ============================================================

section "4. User Management"

# --- Admin: the only user with sudo, and it requires a password ---
if id "$ADMIN_USER" &>/dev/null; then
    warn "User '$ADMIN_USER' already exists, skipping creation."
else
    useradd -m -U -s /bin/bash "$ADMIN_USER"
    echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
    info "Created admin user '$ADMIN_USER'."
fi
unset ADMIN_PASSWORD ADMIN_PASSWORD_CONFIRM
usermod -aG sudo "$ADMIN_USER"
info "'$ADMIN_USER' can use sudo (password required)."

# --- Deploy: owns the code, no sudo ---
if id "$DEPLOY_USER" &>/dev/null; then
    warn "User '$DEPLOY_USER' already exists, skipping creation."
else
    useradd -m -U -s /bin/bash "$DEPLOY_USER"
    info "Created deploy user '$DEPLOY_USER'."
fi
# Revoke any full sudo access left over from earlier versions of this script
gpasswd -d "$DEPLOY_USER" sudo &>/dev/null || true
rm -f "/etc/sudoers.d/${DEPLOY_USER}"
info "'$DEPLOY_USER' has no sudo access (pm2-as-${APP_USER} rule is added in the PM2 step)."

# --- App: runs the process, cannot log in ---
if id "$APP_USER" &>/dev/null; then
    warn "User '$APP_USER' already exists, skipping creation."
else
    useradd --system -U --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
    info "Created app runtime user '$APP_USER' (no login shell)."
fi
gpasswd -d "$APP_USER" sudo &>/dev/null || true
chmod 750 "$APP_HOME"

# Deploy joins the app group so it can set group ownership/permissions on deployed files
# and read PM2 logs. (The reverse is not true: the app user cannot write deploy's files.)
usermod -aG "$APP_USER" "$DEPLOY_USER"

# ============================================================
# 5. SSH Configuration
# ============================================================

section "5. SSH Configuration"

# Admin keys: provided key, or fall back to root's keys (e.g. the provider-injected key)
if [[ -n "$ADMIN_SSH_KEY" ]]; then
    install_ssh_keys "$ADMIN_USER" "$ADMIN_SSH_KEY"
    info "SSH key installed for '$ADMIN_USER'."
elif [[ -s /root/.ssh/authorized_keys ]]; then
    install_ssh_keys "$ADMIN_USER" "$(cat /root/.ssh/authorized_keys)"
    info "Copied root's authorized_keys to '$ADMIN_USER'."
else
    warn "No SSH key available for '$ADMIN_USER'."
fi

if [[ -n "$DEPLOY_SSH_KEY" ]]; then
    install_ssh_keys "$DEPLOY_USER" "$DEPLOY_SSH_KEY"
    info "SSH key installed for '$DEPLOY_USER'."
else
    warn "No deploy SSH key provided — skipping. Add one later: /home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

# Harden sshd only if the admin can log in with a key, so we never lock ourselves out
SSH_HARDENED=false
if [[ -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] && [[ -d /etc/ssh/sshd_config.d ]]; then
    # sshd uses the first value it reads, so this must sort before e.g. 50-cloud-init.conf
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        SSH_HARDENED=true
        info "SSH hardened: root login and password authentication disabled."
    else
        rm -f /etc/ssh/sshd_config.d/00-hardening.conf
        warn "sshd config test failed — SSH hardening skipped."
    fi
else
    warn "Skipping SSH hardening (root login stays enabled) because '$ADMIN_USER' has no SSH key."
fi

# ============================================================
# 6. System Updates
# ============================================================

section "6. System Updates"

apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y
apt autoremove -y
info "System packages updated."

# ============================================================
# 7. Web Server Installation
# ============================================================

section "7. NGINX Installation"

# Install the stable branch from the official nginx.org repository
# (https://nginx.org/en/linux_packages.html#Ubuntu) instead of Ubuntu's
# package, which often lags behind the current stable release.
apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring

curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

# Verify the downloaded key matches the fingerprint published on nginx.org
NGINX_KEY_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
NGINX_KEY_INFO=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show \
    /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true)
if grep -q "$NGINX_KEY_FINGERPRINT" <<< "$NGINX_KEY_INFO"; then
    info "nginx signing key verified ($NGINX_KEY_FINGERPRINT)."
else
    rm -f /usr/share/keyrings/nginx-archive-keyring.gpg
    error "nginx signing key fingerprint mismatch. Check https://nginx.org/en/linux_packages.html#Ubuntu"
fi

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list

# Prefer nginx.org packages over the distribution-provided ones
printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    > /etc/apt/preferences.d/99nginx

apt update -y
apt install -y nginx
info "Installed $(nginx -v 2>&1)"

# NGINX config stays root-owned; only the admin (via sudo) may change it.
# nginx.org packages load site configs from conf.d/*.conf (no sites-available/sites-enabled)
chown -R root:root /etc/nginx/

# Remove the stock welcome page so only our site config is served
rm -f /etc/nginx/conf.d/default.conf

systemctl start nginx
systemctl enable nginx

# nginx.org packages don't ship a ufw app profile, so open ports directly
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable

info "NGINX installed and firewall configured."
ufw status

# ============================================================
# 8. SSL Certificate Setup (Certbot install only)
# ============================================================

section "8. Certbot Installation"

apt install -y certbot python3-certbot-nginx
info "Certbot installed."

# ============================================================
# 9. Runtime Installation
# ============================================================

section "9. Runtime Installation"

# Runtimes are installed system-wide (not under /root) so the app user can execute them
for RUNTIME in "${RUNTIMES[@]}"; do
    case "$RUNTIME" in
        node)
            info "Installing Node.js (via n) — version: $NODE_VERSION ..."
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
            apt install nodejs -y
            npm install -g n
            n "$NODE_VERSION"
            export PATH="/usr/local/bin:$PATH"
            hash -r 2>/dev/null || true
            npm install -g yarn
            npm install -g prisma
            info "Node.js $(node -v) / npm $(npm -v) installed."
            ;;
        deno)
            info "Installing Deno ..."
            DENO_INSTALL="/opt/deno"
            curl -fsSL https://deno.land/install.sh | DENO_INSTALL="$DENO_INSTALL" sh -s -- --yes
            ln -sf "${DENO_INSTALL}/bin/deno" /usr/local/bin/deno
            info "Deno $(deno --version | head -1) installed."
            ;;
        bun)
            info "Installing Bun ..."
            BUN_INSTALL="/opt/bun"
            curl -fsSL https://bun.sh/install | BUN_INSTALL="$BUN_INSTALL" bash
            ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun
            info "Bun $(bun --version) installed."
            ;;
        *)
            warn "Unknown runtime '$RUNTIME' — skipping."
            ;;
    esac
done

# ============================================================
# 10. Process Management — PM2 (runs as the app user)
# ============================================================

section "10. PM2 Installation"

npm install -g pm2
PM2_BIN="$(command -v pm2)"

# systemd unit pm2-<app user> starts PM2 as the app user on boot
if pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME"; then
    systemctl start "pm2-${APP_USER}" || true
    info "PM2 startup configured (systemd unit: pm2-${APP_USER})."
else
    warn "Could not configure PM2 startup. Run as root: pm2 startup systemd -u $APP_USER --hp $APP_HOME"
fi

# The deploy user may run pm2 only as the app user — never as root.
# This grants nothing beyond what deploy already has: it owns the code the app runs.
DEPLOY_SUDOERS="/etc/sudoers.d/${DEPLOY_USER}-pm2"
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
# 11. Application Directory
# ============================================================

section "11. Application Setup"

# Code is owned by deploy and only readable by the app user (setgid keeps new files in the app group).
# The app cannot modify its own code; grant write access only to directories that need it.
mkdir -p "$APP_DIR"
chown -R "${DEPLOY_USER}:${APP_USER}" "$APP_DIR"
chmod 2750 "$APP_DIR"
info "Created application directory: $APP_DIR (owner: $DEPLOY_USER, group: $APP_USER, mode 2750)"

# ============================================================
# 11b. Hello World Placeholder App
# ============================================================

section "11b. Hello World Placeholder"

PLACEHOLDER_URL="https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main/placeholder.js"
info "Downloading placeholder from $PLACEHOLDER_URL ..."
curl -fsSL "$PLACEHOLDER_URL" -o "${APP_DIR}/server.js" || error "Failed to download placeholder.js"
chown "${DEPLOY_USER}:${APP_USER}" "${APP_DIR}/server.js"
chmod 640 "${APP_DIR}/server.js"
info "Placeholder downloaded to ${APP_DIR}/server.js"

# ============================================================
# 12. PM2 Ecosystem Config
# ============================================================

section "12. PM2 Ecosystem Config"

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
chown "${DEPLOY_USER}:${APP_USER}" "$ECOSYSTEM_FILE"
chmod 640 "$ECOSYSTEM_FILE"
info "PM2 ecosystem config written to $ECOSYSTEM_FILE"

# ============================================================
# 13. NGINX Site Configuration
# ============================================================

section "13. NGINX Site Configuration"

NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
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

nginx -t || error "NGINX configuration test failed. Check $NGINX_CONF"
systemctl restart nginx
info "NGINX site configured and reloaded."

# ============================================================
# 14. SSL Certificate
# ============================================================

section "14. SSL Certificate"

info "Requesting SSL certificate from Let's Encrypt for $DOMAIN ..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect || {
    warn "Certbot failed. This usually means DNS has not propagated yet."
    warn "Once DNS is ready, run: sudo certbot --nginx -d $DOMAIN"
}

# ============================================================
# Start placeholder app
# ============================================================

section "Starting Placeholder App"

as_app pm2 start "$ECOSYSTEM_FILE"
as_app pm2 save
info "Placeholder app started via PM2 as '$APP_USER'."

# ============================================================
# Done
# ============================================================

section "Setup Complete"

echo ""
if [[ "$SSH_HARDENED" == true ]]; then
    warn "Root SSH login is now DISABLED. Before closing this session, verify in a new terminal:"
    echo "       ssh ${ADMIN_USER}@${DOMAIN}   (then: sudo -v)"
    echo ""
fi
info "Next steps:"
echo "  1. Visit http://${DOMAIN} to confirm the placeholder page loads."
echo ""
echo "  2. Verify SSH login from your local machine:"
echo "       ssh ${ADMIN_USER}@${DOMAIN}    # server maintenance (sudo)"
echo "       ssh ${DEPLOY_USER}@${DOMAIN}   # deployments"
echo ""
echo "  3. When ready to deploy your app (as ${DEPLOY_USER}):"
echo "       a. Push your build to ${DEPLOY_USER}@${DOMAIN}:${APP_DIR}"
echo "       b. Update ${ECOSYSTEM_FILE} (switch script to the command to start your application, e.g. 'npx next start')"
echo "       c. Run: sudo -u ${APP_USER} pm2 restart ${APP_NAME} && sudo -u ${APP_USER} pm2 save"
echo "       d. If the app writes to disk (e.g. Next.js .next/cache, uploads), make only those directories writable:"
echo "            chmod -R g+w ${APP_DIR}/.next/cache"
echo ""
echo "  4. Add your .env variables on the server (as ${DEPLOY_USER}):"
echo "       nano ${APP_DIR}/.env && chmod 640 ${APP_DIR}/.env"
echo ""
echo "  5. Test certificate auto-renewal (as ${ADMIN_USER}):"
echo "       sudo certbot renew --dry-run"
echo ""
info "Placeholder is live at http://${DOMAIN}"
info "Once certbot succeeded, it will also be at https://${DOMAIN}"
