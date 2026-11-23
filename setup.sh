#!/bin/bash
set -euo pipefail

# ============================================================
# Production Server Setup Script — run ONCE per server
# Run as root on a fresh Ubuntu server.
#
# Prepares the server (users, SSH, NGINX, Certbot, runtimes, PM2) and installs
# `add-app`, which adds each application with its own isolated user:
#
#   ops     — SSH (key only) + passwordless sudo, for server maintenance
#   deploy  — SSH, owns app code, may only run pm2 as each app's user
#   <name>  — one user per app, named after the app (created by add-app):
#             no login, no sudo
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/server-setup.conf"
SHARE_DIR="/usr/local/share/server-setup"
ADD_APP_BIN="/usr/local/sbin/add-app"
REMOVE_APP_BIN="/usr/local/sbin/remove-app"

# ============================================================
# Pre-flight checks
# ============================================================

[[ $EUID -ne 0 ]] && error "This script must be run as root. Try: sudo bash setup.sh"

command -v apt >/dev/null 2>&1 || error "This script requires an apt-based Linux distribution (Ubuntu/Debian)."

# ============================================================
# Gather configuration
# ============================================================

section "Configuration"

read -rp "Admin username (SSH + sudo, for server maintenance) [ops]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-ops}"

read -rp "Admin SSH public key (leave blank to copy root's authorized_keys): " ADMIN_SSH_KEY

echo ""
read -rp "Deploy username (uploads code, restarts apps) [deploy]: " DEPLOY_USER
DEPLOY_USER="${DEPLOY_USER:-deploy}"

read -rp "Deploy SSH public key (leave blank to skip): " DEPLOY_SSH_KEY

[[ "$ADMIN_USER" == "$DEPLOY_USER" ]] && error "Admin and deploy users must be different."
for U in "$ADMIN_USER" "$DEPLOY_USER"; do
    [[ "$U" == "root" ]] && error "'root' cannot be used as the admin or deploy user."
done

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
read -rp "Default email for SSL certificates (Let's Encrypt): " SSL_EMAIL
[[ -z "$SSL_EMAIL" ]] && error "SSL email cannot be empty."

echo ""
info "Configuration summary:"
echo "  Admin user:  $ADMIN_USER"
echo "  Deploy user: $DEPLOY_USER"
echo "  Runtimes:    ${RUNTIMES[*]}"
[[ -n "$NODE_VERSION" ]] && echo "  Node.js ver: $NODE_VERSION"
echo "  SSL email:   $SSL_EMAIL"
echo ""
read -rp "Proceed with setup? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && error "Aborted by user."

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

# Use a file shipped next to this script if present, otherwise download it from the repo
fetch_file() {
    local name="$1" dest="$2"
    if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
        cp "${SCRIPT_DIR}/${name}" "$dest"
    else
        curl -fsSL "${REPO_RAW_URL}/${name}" -o "$dest" || error "Failed to download ${REPO_RAW_URL}/${name}"
    fi
}

# ============================================================
# 1. User Management
# ============================================================

section "1. User Management"

# --- Admin: the only user with sudo. No password: it logs in with an SSH key only,
# so its key is effectively root access — keep it safe. ---
if id "$ADMIN_USER" &>/dev/null; then
    warn "User '$ADMIN_USER' already exists, skipping creation."
else
    # useradd leaves the password locked, so password login is impossible
    useradd -m -U -s /bin/bash "$ADMIN_USER"
    info "Created admin user '$ADMIN_USER' (no password, SSH key login only)."
fi
ADMIN_SUDOERS="/etc/sudoers.d/${ADMIN_USER}"
echo "${ADMIN_USER} ALL=(ALL) NOPASSWD: ALL" > "$ADMIN_SUDOERS"
chmod 440 "$ADMIN_SUDOERS"
visudo -cf "$ADMIN_SUDOERS" >/dev/null || { rm -f "$ADMIN_SUDOERS"; error "Invalid sudoers rule for $ADMIN_USER."; }
info "'$ADMIN_USER' can use sudo without a password."

# --- Deploy: owns the code, no sudo (per-app pm2 rules are added by add-app) ---
if id "$DEPLOY_USER" &>/dev/null; then
    warn "User '$DEPLOY_USER' already exists, skipping creation."
else
    useradd -m -U -s /bin/bash "$DEPLOY_USER"
    info "Created deploy user '$DEPLOY_USER'."
fi
# Revoke any full sudo access left over from earlier versions of this script
gpasswd -d "$DEPLOY_USER" sudo &>/dev/null || true
rm -f "/etc/sudoers.d/${DEPLOY_USER}"
info "'$DEPLOY_USER' has no sudo access."

# ============================================================
# 2. SSH Configuration
# ============================================================

section "2. SSH Configuration"

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
# 3. System Updates
# ============================================================

section "3. System Updates"

apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y
apt autoremove -y
info "System packages updated."

# ============================================================
# 4. Web Server Installation
# ============================================================

section "4. NGINX Installation"

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

# Replace the stock welcome page with a catch-all that rejects requests for unknown
# hosts (e.g. scans of the bare IP), so they never reach one of the apps by accident.
rm -f /etc/nginx/conf.d/default.conf
cat > /etc/nginx/conf.d/00-default.conf <<'EOF'
# Catch-all for requests that don't match any app's server_name
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
EOF
nginx -t || error "NGINX configuration test failed."

systemctl start nginx
systemctl enable nginx
systemctl reload nginx

# nginx.org packages don't ship a ufw app profile, so open ports directly
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable

info "NGINX installed and firewall configured."
ufw status

# ============================================================
# 5. SSL Certificate Setup (Certbot install only)
# ============================================================

section "5. Certbot Installation"

apt install -y certbot python3-certbot-nginx
info "Certbot installed."

# ============================================================
# 6. Runtime Installation
# ============================================================

section "6. Runtime Installation"

# Runtimes are installed system-wide (not under /root) so app users can execute them
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
# 7. Process Management — PM2
# ============================================================

section "7. PM2 Installation"

# Each app user runs its own PM2 daemon; add-app sets that up per app.
npm install -g pm2
info "PM2 installed."

# ============================================================
# 8. Install add-app and remove-app
# ============================================================

section "8. Installing add-app and remove-app"

mkdir -p "$SHARE_DIR"
fetch_file "add-app.sh" "$ADD_APP_BIN"
fetch_file "remove-app.sh" "$REMOVE_APP_BIN"
chmod 755 "$ADD_APP_BIN" "$REMOVE_APP_BIN"
fetch_file "placeholder.js" "${SHARE_DIR}/placeholder.js"
chmod 644 "${SHARE_DIR}/placeholder.js"

# Server-wide settings that add-app reads
{
    echo "# Written by setup.sh — read by add-app"
    printf 'DEPLOY_USER=%q\n' "$DEPLOY_USER"
    printf 'SSL_EMAIL=%q\n' "$SSL_EMAIL"
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

info "Installed $ADD_APP_BIN and $REMOVE_APP_BIN (settings in $CONFIG_FILE)."

# ============================================================
# Done — optionally add the first app
# ============================================================

section "Server Setup Complete"

echo ""
read -rp "Add the first app now? [Y/n]: " ADD_FIRST_APP
if [[ "${ADD_FIRST_APP,,}" != "n" ]]; then
    "$ADD_APP_BIN"
else
    info "Add an app any time (as ${ADMIN_USER}): sudo add-app"
fi

echo ""
if [[ "$SSH_HARDENED" == true ]]; then
    warn "Root SSH login is now DISABLED. Before closing this session, verify in a new terminal:"
    echo "       ssh ${ADMIN_USER}@<server>   (then: sudo -n true)"
    echo ""
fi
info "Logins:"
echo "  ssh ${ADMIN_USER}@<server>    # server maintenance (sudo), add apps: sudo add-app"
echo "  ssh ${DEPLOY_USER}@<server>   # deployments"
