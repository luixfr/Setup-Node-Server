#!/bin/bash
set -euo pipefail

# ============================================================
# Production Server Setup Script
# Run as root on a fresh Ubuntu DigitalOcean Droplet
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

read -rp "Deploy username [deploy]: " DEPLOY_USER
DEPLOY_USER="${DEPLOY_USER:-deploy}"

echo ""
read -rp "Public SSH key (leave blank to skip): " SSH_PUBLIC_KEY

echo ""
read -rp "Node.js app port [3000]: " APP_PORT
APP_PORT="${APP_PORT:-3000}"

echo ""
read -rp "Node.js version [lts]: " NODE_VERSION
NODE_VERSION="${NODE_VERSION:-lts}"

echo ""
info "Configuration summary:"
echo "  Domain:      $DOMAIN"
echo "  App name:    $APP_NAME"
echo "  Deploy user: $DEPLOY_USER"
echo "  App port:    $APP_PORT"
echo "  Node.js:     $NODE_VERSION"
echo ""
read -rp "Proceed with setup? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && error "Aborted by user."

APP_DIR="/var/www/${APP_NAME}"

# ============================================================
# 4. User Management
# ============================================================

section "4. User Management"

if id "$DEPLOY_USER" &>/dev/null; then
    warn "User '$DEPLOY_USER' already exists, skipping creation."
else
    groupadd "$DEPLOY_USER" 2>/dev/null || true
    useradd -m -g "$DEPLOY_USER" -s /bin/bash "$DEPLOY_USER"
    info "Created user '$DEPLOY_USER'."
fi

usermod -aG sudo "$DEPLOY_USER"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/"$DEPLOY_USER"
chmod 440 /etc/sudoers.d/"$DEPLOY_USER"
info "Sudo access configured for '$DEPLOY_USER' (no password required)."

# ============================================================
# 5. SSH Configuration
# ============================================================

section "5. SSH Configuration"

if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    SSH_DIR="/home/${DEPLOY_USER}/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$SSH_PUBLIC_KEY" > "${SSH_DIR}/authorized_keys"
    chmod 700 "$SSH_DIR"
    chmod 600 "${SSH_DIR}/authorized_keys"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$SSH_DIR"
    info "SSH key installed for '$DEPLOY_USER'."
else
    warn "No SSH key provided — skipping. Add one later: nano /home/${DEPLOY_USER}/.ssh/authorized_keys"
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

apt install -y nginx

chown -R root:"$DEPLOY_USER" /etc/nginx/
chmod -R 775 /etc/nginx/sites-available
chmod -R 775 /etc/nginx/sites-enabled

systemctl start nginx
systemctl enable nginx

ufw allow 'Nginx Full'
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
# 9. Runtime Environment — Node.js
# ============================================================

section "9. Node.js Installation (via n)"

# Bootstrap Node.js via nodesource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install nodejs -y

# Install n and switch to the requested version
npm install -g n
n "$NODE_VERSION"

# Ensure n-managed binaries take precedence over the apt-installed ones
export PATH="/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

npm install -g yarn
npm install -g prisma
info "Node.js $(node -v) / npm $(npm -v) installed via n (requested: $NODE_VERSION)."

# ============================================================
# 10. Process Management — PM2
# ============================================================

section "10. PM2 Installation"

npm install -g pm2
PM2_STARTUP_OUTPUT=$(su - "$DEPLOY_USER" -c "pm2 startup systemd -u $DEPLOY_USER --hp /home/$DEPLOY_USER" 2>&1 || true)
PM2_STARTUP=$(echo "$PM2_STARTUP_OUTPUT" | grep "sudo env" || true)
if [[ -n "$PM2_STARTUP" ]]; then
    eval "$PM2_STARTUP"
    info "PM2 startup configured."
else
    warn "Could not automatically configure PM2 startup. Run 'pm2 startup' manually as $DEPLOY_USER."
fi

su - "$DEPLOY_USER" -c "
    pm2 install pm2-logrotate
    pm2 set pm2-logrotate:max_size 10M
    pm2 set pm2-logrotate:retain 7
    pm2 set pm2-logrotate:compress true
    pm2 set pm2-logrotate:dateFormat YYYY-MM-DD_HH-mm-ss
    pm2 set pm2-logrotate:rotateInterval '0 0 * * *'
"
info "PM2 log rotation configured (10M max, 7 days, daily at midnight, gzip compressed)."

# ============================================================
# 11. Application Directory
# ============================================================

section "11. Application Setup"

mkdir -p "$APP_DIR"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_DIR"
info "Created application directory: $APP_DIR"

# ============================================================
# 11b. Hello World Placeholder App
# ============================================================

section "11b. Hello World Placeholder"

PLACEHOLDER_URL="https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main/placeholder.js"
info "Downloading placeholder from $PLACEHOLDER_URL ..."
curl -fsSL "$PLACEHOLDER_URL" -o "${APP_DIR}/server.js" || error "Failed to download placeholder.js"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${APP_DIR}/server.js"
info "Placeholder downloaded to ${APP_DIR}/server.js"

# ============================================================
# 12. PM2 Ecosystem Config
# ============================================================

section "12. PM2 Ecosystem Config"

ECOSYSTEM_FILE="/home/${DEPLOY_USER}/ecosystem.config.js"
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
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$ECOSYSTEM_FILE"
info "PM2 ecosystem config written to $ECOSYSTEM_FILE"

# ============================================================
# 13. NGINX Site Configuration
# ============================================================

section "13. NGINX Site Configuration"

NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
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

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

nginx -t || error "NGINX configuration test failed. Check $NGINX_CONF"
systemctl restart nginx
info "NGINX site configured and reloaded."

# ============================================================
# 14. SSL Certificate
# ============================================================

section "14. SSL Certificate"

info "Requesting SSL certificate from Let's Encrypt for $DOMAIN ..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN#*.}" --redirect || {
    warn "Certbot failed. This usually means DNS has not propagated yet."
    warn "Once DNS is ready, run: sudo certbot --nginx -d $DOMAIN"
}

# ============================================================
# Start placeholder app
# ============================================================

section "Starting Placeholder App"

su - "$DEPLOY_USER" -c "pm2 start /home/${DEPLOY_USER}/ecosystem.config.js"
su - "$DEPLOY_USER" -c "pm2 save"
info "Placeholder app started via PM2."

# ============================================================
# Done
# ============================================================

section "Setup Complete"

echo ""
info "Next steps:"
echo "  1. Visit http://${DOMAIN} to confirm the placeholder page loads."
echo ""
echo "  2. Verify SSH login from your local machine:"
echo "       ssh ${DEPLOY_USER}@${DOMAIN}"
echo ""
echo "  3. When ready to deploy your app:"
echo "       a. Push your build to ${DEPLOY_USER}@${DOMAIN}:${APP_DIR}"
echo "       b. Update ~/ecosystem.config.js (switch script to the command to start your application, e.g. 'npx next start')"
echo "       c. Run: pm2 restart ${APP_NAME} && pm2 save"
echo ""
echo "  4. Add your .env variables on the server:"
echo "       nano ${APP_DIR}/.env"
echo ""
echo "  5. Test certificate auto-renewal:"
echo "       sudo certbot renew --dry-run"
echo ""
info "Placeholder is live at http://${DOMAIN}"
info "Once certbot succeeded, it will also be at https://${DOMAIN}"
