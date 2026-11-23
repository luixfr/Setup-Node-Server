#!/bin/bash
set -euo pipefail

# ============================================================
# remove-app — remove an application created by add-app
# Usage (as the admin user, e.g. ops): sudo remove-app [name]
#
# Undoes everything add-app created for the app:
#   PM2 daemon + systemd unit pm2-<name>, deploy's sudo rule, NGINX site,
#   SSL certificate, /var/www/<name>, the <name> user/group and its home.
# Optionally saves a backup archive first.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN} $*${NC}"; echo -e "${GREEN}========================================${NC}"; }

APPS_DIR="/var/lib/server-setup/apps"
NGINX_CONF_DIR="/etc/nginx/conf.d"
BACKUP_DIR="/root/app-backups"

# ============================================================
# Pre-flight checks
# ============================================================

[[ $EUID -ne 0 ]] && error "This script must be run as root. Try: sudo remove-app <name>"
export PATH="/usr/local/bin:$PATH"

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
    if compgen -G "${APPS_DIR}/*.conf" >/dev/null; then
        info "Apps on this server:"
        for F in "${APPS_DIR}"/*.conf; do echo "  $(basename "$F" .conf)"; done
        echo ""
    fi
    read -rp "App name to remove: " APP_NAME
fi
[[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || error "Invalid app name '$APP_NAME'."

RECORD="${APPS_DIR}/${APP_NAME}.conf"
[[ -f "$RECORD" ]] || error "'$APP_NAME' was not created by add-app (no ${RECORD}). Nothing removed."

# shellcheck source=/dev/null
source "$RECORD"
: "${APP_USER:?APP_USER missing from $RECORD}"
: "${DOMAIN:?DOMAIN missing from $RECORD}"
: "${DEPLOY_USER:?DEPLOY_USER missing from $RECORD}"

APP_HOME="/home/${APP_USER}"
APP_DIR="/var/www/${APP_NAME}"
PM2_UNIT="pm2-${APP_USER}"
PM2_UNIT_FILE="/etc/systemd/system/${PM2_UNIT}.service"
DEPLOY_SUDOERS="/etc/sudoers.d/${DEPLOY_USER}-${APP_USER}"
NGINX_CONF="${NGINX_CONF_DIR}/${DOMAIN}.conf"
CERT_RENEWAL_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"

# Never delete a privileged or login-capable account, whatever the record says
[[ "$APP_USER" == "root" || "$APP_USER" == "$DEPLOY_USER" ]] && error "Refusing to remove user '$APP_USER'."
if id "$APP_USER" &>/dev/null; then
    [[ "$(id -u "$APP_USER")" -eq 0 ]] && error "Refusing to remove '$APP_USER': it has UID 0."
    id -nG "$APP_USER" | tr ' ' '\n' | grep -qxE "sudo|admin|wheel" \
        && error "Refusing to remove '$APP_USER': it is a sudoer, not an app user."
    [[ -e "/etc/sudoers.d/${APP_USER}" ]] && error "Refusing to remove '$APP_USER': it has a sudoers rule."
    APP_SHELL="$(getent passwd "$APP_USER" | cut -d: -f7)"
    [[ "$APP_SHELL" == "/usr/sbin/nologin" || "$APP_SHELL" == "/bin/false" ]] \
        || error "Refusing to remove '$APP_USER': it has a login shell ($APP_SHELL), so it isn't an add-app user."
fi

# ============================================================
# Confirm
# ============================================================

section "Remove App '$APP_NAME'"

info "The following will be removed:"
id "$APP_USER" &>/dev/null           && echo "  User and group:  $APP_USER (home $APP_HOME, incl. PM2 logs)"
[[ -d "$APP_DIR" ]]                  && echo "  App directory:   $APP_DIR (code, .env)"
[[ -f "$PM2_UNIT_FILE" ]]            && echo "  systemd unit:    $PM2_UNIT"
[[ -f "$DEPLOY_SUDOERS" ]]           && echo "  Sudo rule:       $DEPLOY_SUDOERS"
[[ -f "$NGINX_CONF" ]]               && echo "  NGINX site:      $NGINX_CONF"
[[ -f "$CERT_RENEWAL_CONF" ]]        && echo "  SSL certificate: $DOMAIN (Let's Encrypt)"
echo "  App record:      $RECORD"
echo ""
warn "This cannot be undone."
read -rp "Type the app name ('$APP_NAME') to confirm: " CONFIRM_NAME
[[ "$CONFIRM_NAME" != "$APP_NAME" ]] && error "Confirmation did not match. Nothing removed."

read -rp "Save a backup archive (code, .env, logs, NGINX site) to ${BACKUP_DIR} first? [Y/n]: " DO_BACKUP

# ============================================================
# 1. Backup
# ============================================================

if [[ "${DO_BACKUP,,}" != "n" ]]; then
    section "1. Backup"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    BACKUP_FILE="${BACKUP_DIR}/${APP_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
    BACKUP_PATHS=()
    for P in "$APP_DIR" "${APP_HOME}/.pm2/logs" "${APP_HOME}/.pm2/dump.pm2" "$NGINX_CONF" "$RECORD"; do
        [[ -e "$P" ]] && BACKUP_PATHS+=("${P#/}")
    done
    # Created with a restrictive umask: the archive contains secrets (.env)
    (umask 077 && tar -czf "$BACKUP_FILE" -C / "${BACKUP_PATHS[@]}")
    info "Backup saved: $BACKUP_FILE"
else
    warn "Skipping backup."
fi

# ============================================================
# 2. Stop the app and its PM2 daemon
# ============================================================

section "2. Stopping PM2"

systemctl disable --now "$PM2_UNIT" &>/dev/null || true

if id "$APP_USER" &>/dev/null; then
    # A daemon started outside systemd (e.g. by hand) would survive the unit stop
    if [[ -d "${APP_HOME}/.pm2" ]] && command -v pm2 >/dev/null 2>&1; then
        (cd "$APP_HOME" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" PM2_HOME="${APP_HOME}/.pm2" pm2 kill) &>/dev/null || true
    fi
    # Anything else still running as the app user must go before userdel
    pkill -u "$APP_USER" &>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -u "$APP_USER" &>/dev/null || break
        sleep 1
    done
    pkill -KILL -u "$APP_USER" &>/dev/null || true
fi
info "All processes of '$APP_USER' stopped."

rm -f "$PM2_UNIT_FILE"
systemctl daemon-reload
systemctl reset-failed "$PM2_UNIT" &>/dev/null || true
info "Removed systemd unit $PM2_UNIT."

# ============================================================
# 3. Deploy access
# ============================================================

section "3. Deploy Access"

rm -f "$DEPLOY_SUDOERS"
gpasswd -d "$DEPLOY_USER" "$APP_USER" &>/dev/null || true
info "Removed '$DEPLOY_USER' sudo rule and group membership for '$APP_USER'."

# ============================================================
# 4. NGINX site and SSL certificate
# ============================================================

section "4. NGINX and SSL"

if [[ -f "$NGINX_CONF" ]]; then
    NGINX_CONF_BACKUP="$(mktemp)"
    cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"
    rm -f "$NGINX_CONF"
    if nginx -t &>/dev/null; then
        systemctl reload nginx
        info "Removed NGINX site $NGINX_CONF."
    else
        # Don't leave NGINX unable to reload because of an unrelated broken config
        cp "$NGINX_CONF_BACKUP" "$NGINX_CONF"
        rm -f "$NGINX_CONF_BACKUP"
        error "NGINX config test fails without $NGINX_CONF (see: sudo nginx -t). Restored it; fix NGINX and re-run remove-app."
    fi
    rm -f "$NGINX_CONF_BACKUP"
else
    info "No NGINX site for $DOMAIN."
fi

if [[ -f "$CERT_RENEWAL_CONF" ]]; then
    certbot delete --cert-name "$DOMAIN" --non-interactive \
        && info "Deleted SSL certificate for $DOMAIN." \
        || warn "Could not delete the certificate. Run: sudo certbot delete --cert-name $DOMAIN"
else
    info "No SSL certificate for $DOMAIN."
fi

# ============================================================
# 5. Files and user
# ============================================================

section "5. Files and User"

rm -rf "$APP_DIR"
info "Removed $APP_DIR."

if id "$APP_USER" &>/dev/null; then
    userdel -r "$APP_USER" &>/dev/null || userdel "$APP_USER"
fi
getent group "$APP_USER" >/dev/null && groupdel "$APP_USER"
rm -rf "$APP_HOME"
info "Removed user and group '$APP_USER' and $APP_HOME."

rm -f "$RECORD"

# ============================================================
# Done
# ============================================================

section "App '$APP_NAME' Removed"

[[ -n "${BACKUP_FILE:-}" ]] && info "Backup: $BACKUP_FILE (restore files with: sudo tar -xzf $BACKUP_FILE -C /)"
info "Remember to remove the DNS record for $DOMAIN if it's no longer needed."
