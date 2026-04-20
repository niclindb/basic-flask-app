#!/bin/bash
# ─────────────────────────────────────────────
# Universal Web App Teardown Script
# Usage: sudo ./teardown-app.sh <app_name>
# ─────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)."
   exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: sudo ./teardown-app.sh <app_name>"
    echo "Example: sudo ./teardown-app.sh myapp"
    exit 1
fi

APP_NAME=$1
APP_REGISTRY="/etc/app-registry"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Decommissioning: $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Stop and Disable Systemd Services
echo "[1/4] Stopping services..."
systemctl disable --now "$APP_NAME" 2>/dev/null || echo "  App service not found."
systemctl disable --now "webhook-$APP_NAME" 2>/dev/null || echo "  Webhook service not found."

# 2. Remove Systemd Service Files
echo "[2/4] Removing service files..."
rm -f "/etc/systemd/system/$APP_NAME.service"
rm -f "/etc/systemd/system/webhook-$APP_NAME.service"
systemctl daemon-reload

# 3. Clean up Nginx & Registry
echo "[3/4] Cleaning up Nginx and Registry..."
rm -f "$APP_REGISTRY/$APP_NAME"

# Find which nginx config contains this app
NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"

# Rebuild Nginx Unified Config (Matches setup script logic)
if [ -d "$APP_REGISTRY" ] && [ "$(ls -A $APP_REGISTRY)" ]; then
    echo "  Rebuilding Nginx config for remaining apps..."
    {
        echo "server {"
        echo "    listen 80;"
        for app_file in "$APP_REGISTRY"/*; do
            [ -f "$app_file" ] || continue
            IFS=':' read -r name type val wport < "$app_file"
            echo "    location /webhook-$name { proxy_pass http://127.0.0.1:$wport/webhook; }"
            echo "    location /$name/ {"
            if [[ "$type" == "static" ]]; then
                echo "        alias $val/;"
                echo "        try_files \$uri \$uri/ /$name/index.html;"
            else
                echo "        proxy_pass http://127.0.0.1:$val/;"
                echo "        proxy_set_header Host \$host;"
                echo "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
                echo "        proxy_set_header X-Forwarded-Proto $scheme;"
                echo "        proxy_set_header X-Forwarded-Prefix /$name;"
                echo "        proxy_set_header X-Real-IP \$remote_addr;"
            fi
            echo "    }"
        done
        echo "}"
    } > "$NGINX_CONF"
    nginx -t && systemctl reload nginx
else
    echo "  No apps remaining. Removing Nginx config..."
    rm -f "$NGINX_CONF"
    rm -f "/etc/nginx/sites-enabled/$APP_NAME.conf"
    systemctl reload nginx
fi

# 4. Remove Webhook Script and Sudoers
echo "[4/4] Removing webhook script and sudoers rules..."
find /home -name "webhook-$APP_NAME.py" -exec rm -f {} \;
rm -f "/etc/sudoers.d/$APP_NAME"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done! $APP_NAME has been removed from system services."
echo " NOTE: App files in /home/ are preserved."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"