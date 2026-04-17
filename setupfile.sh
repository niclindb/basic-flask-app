#!/bin/bash
# ─────────────────────────────────────────────
# Flask App Deployment Setup Script
# Supports multiple apps via subpaths
# Usage: sudo setup-flask-app
# ─────────────────────────────────────────────

set -e

# ── Prompt for config ─────────────────────────
read -p "App name (e.g. myapp): " APP_NAME
read -p "GitHub repo URL (https://github.com/user/repo.git): " REPO_URL
read -p "Linux user to run the app as (e.g. pipeline): " APP_USER
read -p "Webhook secret (anything secret): " WEBHOOK_SECRET

APP_DIR="/home/$APP_USER/$APP_NAME"
NGINX_CONF="/etc/nginx/sites-available/flask-apps"

# ── Auto-assign ports ─────────────────────────
echo ""
echo "Finding available ports..."

get_next_port() {
    local port=$1
    while ss -tuln | grep -q ":$port "; do
        port=$((port + 1))
    done
    echo $port
}

FLASK_PORT=$(get_next_port 5000)
WEBHOOK_PORT=$(get_next_port 9000)
VENV="$APP_DIR/venv"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setting up: $APP_NAME"
echo " User:       $APP_USER"
echo " Directory:  $APP_DIR"
echo " Flask port: $FLASK_PORT  (auto-assigned)"
echo " Webhook:    $WEBHOOK_PORT  (auto-assigned)"
echo " Subpath:    /$APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. Install dependencies ───────────────────
echo "[1/7] Installing system dependencies..."
apt update -qq
apt install -y python3 python3-pip python3-venv git nginx curl > /dev/null

# ── 2. Create user if needed ──────────────────
echo "[2/7] Setting up user '$APP_USER'..."
if ! id "$APP_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$APP_USER"
    echo "  Created user $APP_USER"
else
    echo "  User $APP_USER already exists"
fi

# ── 3. Clone repo and set up venv ─────────────
echo "[3/7] Cloning repo and setting up virtualenv..."
if [ -d "$APP_DIR" ]; then
    echo "  Directory already exists, pulling latest..."
    git -C "$APP_DIR" pull
else
    git clone "$REPO_URL" "$APP_DIR"
fi

python3 -m venv "$VENV"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
sudo -u "$APP_USER" "$VENV/bin/pip" install -q -r "$APP_DIR/requirements.txt"
sudo -u "$APP_USER" "$VENV/bin/pip" install -q flask

# ── 4. Flask systemd service ──────────────────
echo "[4/7] Creating Flask systemd service..."
cat > /etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=Flask App - $APP_NAME
After=network.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment="PORT=$FLASK_PORT"
ExecStart=$VENV/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ── 5. Webhook script ─────────────────────────
echo "[5/7] Creating webhook listener..."
cat > /home/$APP_USER/webhook-${APP_NAME}.py <<EOF
from flask import Flask, request
import subprocess, hmac, hashlib

app = Flask(__name__)
SECRET = b"$WEBHOOK_SECRET"

@app.route("/webhook", methods=["POST"])
def webhook():
    sig = request.headers.get("X-Hub-Signature-256", "")
    expected = "sha256=" + hmac.new(SECRET, request.data, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return "Forbidden", 403
    subprocess.Popen(["bash", "-c", "git -C $APP_DIR pull && sudo systemctl restart $APP_NAME"])
    return "OK", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=$WEBHOOK_PORT)
EOF

chown "$APP_USER:$APP_USER" /home/$APP_USER/webhook-${APP_NAME}.py

# ── 6. Webhook systemd service ────────────────
echo "[6/7] Creating webhook service..."
cat > /etc/systemd/system/webhook-${APP_NAME}.service <<EOF
[Unit]
Description=Webhook Listener - $APP_NAME
After=network.target

[Service]
User=$APP_USER
ExecStart=$VENV/bin/python /home/$APP_USER/webhook-${APP_NAME}.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Sudoers rule
SUDOERS_LINE="$APP_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $APP_NAME"
if ! grep -qF "$SUDOERS_LINE" /etc/sudoers; then
    echo "$SUDOERS_LINE" >> /etc/sudoers
fi

# ── 7. Nginx ──────────────────────────────────
echo "[7/7] Configuring nginx..."

# Create shared nginx config if it doesn't exist yet
if [ ! -f "$NGINX_CONF" ]; then
    cat > "$NGINX_CONF" <<'EOF'
server {
    listen 80;
}
EOF
fi

# Add this app's location blocks if not already present
if ! grep -q "location /$APP_NAME" "$NGINX_CONF"; then
    sed -i "s|}|    location /webhook-$APP_NAME {\n        proxy_pass http://127.0.0.1:$WEBHOOK_PORT;\n    }\n\n    location /$APP_NAME {\n        proxy_pass http://127.0.0.1:$FLASK_PORT/;\n        proxy_set_header Host \$host;\n    }\n}|" "$NGINX_CONF"
fi

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/flask-apps
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ── Start everything ──────────────────────────
systemctl daemon-reload
systemctl enable ${APP_NAME} webhook-${APP_NAME}
systemctl restart ${APP_NAME} webhook-${APP_NAME}

# ── Summary ───────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done! $APP_NAME is live."
echo ""
echo " App URL:     http://YOUR_IP/$APP_NAME"
echo " Webhook URL: http://YOUR_IP/webhook-$APP_NAME"
echo ""
echo " On a restricted network? Run:"
echo "   cloudflared tunnel --url http://localhost:$WEBHOOK_PORT"
echo " Then use the tunnel URL as your GitHub webhook URL."
echo ""
echo " GitHub webhook secret: $WEBHOOK_SECRET"
echo " To deploy: git push origin main"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"