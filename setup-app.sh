#!/bin/bash
# ─────────────────────────────────────────────
# Universal Web App Deployment Script (Revised)
# Supports: Flask, FastAPI, Django, Node.js, React, Static
# ─────────────────────────────────────────────

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)."
   exit 1
fi

# ── Prompt for config ─────────────────────────
read -p "App name (e.g. myapp): " APP_NAME
echo -e "\nFramework options:\n 1) Flask\n 2) FastAPI\n 3) Django\n 4) Node.js\n 5) React\n 6) Static site"
read -p "Choose framework (1-6): " FRAMEWORK_CHOICE
read -p "GitHub repo URL: " REPO_URL
read -p "Linux user (e.g. webuser): " APP_USER
read -p "Webhook secret: " WEBHOOK_SECRET

APP_DIR="/home/$APP_USER/$APP_NAME"
NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"
APP_REGISTRY="/etc/app-registry"
VENV="$APP_DIR/venv"

case $FRAMEWORK_CHOICE in
    1) FRAMEWORK="flask" ;;
    2) FRAMEWORK="fastapi" ;;
    3) FRAMEWORK="django" ;;
    4) FRAMEWORK="nodejs" ;;
    5) FRAMEWORK="react" ;;
    6) FRAMEWORK="static" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

# ── Port Assignment ───────────────────────────
get_next_port() {
    local port=$1
    while ss -tuln | grep -q ":$port "; do
        port=$((port + 1))
    done
    echo $port
}

WEBHOOK_PORT=$(get_next_port 9000)
[[ "$FRAMEWORK" =~ ^(flask|fastapi|django|nodejs)$ ]] && APP_PORT=$(get_next_port 5000)

# ── 1. Dependencies ───────────────────────────
echo "[1/6] Installing dependencies..."
apt update -qq && apt install -y git nginx curl python3 python3-pip python3-venv > /dev/null

# Install Flask globally for the webhook (handling PEP 668)
pip3 install flask --break-system-packages -q 2>/dev/null || pip3 install flask -q

if [[ "$FRAMEWORK" =~ ^(nodejs|react)$ ]]; then
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null
        apt install -y nodejs > /dev/null
    fi
fi

# ── 2. User Setup ─────────────────────────────
echo "[2/6] Setting up user..."
id "$APP_USER" &>/dev/null || useradd -m -s /bin/bash "$APP_USER"

# ── 3. Repo Setup ─────────────────────────────
echo "[3/6] Cloning repository..."
if [ -d "$APP_DIR" ]; then
    git -C "$APP_DIR" pull
else
    git clone "$REPO_URL" "$APP_DIR"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ── 4. Framework Logic & Service Creation ─────
echo "[4/6] Configuring framework..."

case $FRAMEWORK in
    flask|fastapi|django)
        python3 -m venv "$VENV"
        chown -R "$APP_USER:$APP_USER" "$VENV"
        SUDO_PIP="sudo -u $APP_USER $VENV/bin/pip install -q"
        $SUDO_PIP wheel
        
        if [[ "$FRAMEWORK" == "flask" ]]; then
            $SUDO_PIP flask gunicorn
            EXEC_CMD="$VENV/bin/gunicorn --bind 127.0.0.1:$APP_PORT app:app"
        elif [[ "$FRAMEWORK" == "fastapi" ]]; then
            $SUDO_PIP fastapi uvicorn
            EXEC_CMD="$VENV/bin/uvicorn main:app --host 127.0.0.1 --port $APP_PORT"
        elif [[ "$FRAMEWORK" == "django" ]]; then
            $SUDO_PIP django gunicorn
            read -p "Django project name (folder with wsgi.py): " DJANGO_PROJ
            EXEC_CMD="$VENV/bin/gunicorn ${DJANGO_PROJ}.wsgi --bind 127.0.0.1:$APP_PORT"
        fi
        [ -f "$APP_DIR/requirements.txt" ] && $SUDO_PIP -r "$APP_DIR/requirements.txt"
        DEPLOY_CMD="git -C $APP_DIR pull && sudo systemctl restart $APP_NAME"
        ;;

    nodejs)
        cd "$APP_DIR" && sudo -u "$APP_USER" npm install --silent
        read -p "Entry file (e.g. index.js): " NODE_ENTRY
        EXEC_CMD="/usr/bin/node $NODE_ENTRY"
        DEPLOY_CMD="git -C $APP_DIR pull && npm --prefix $APP_DIR install && sudo systemctl restart $APP_NAME"
        ;;

    react)
        cd "$APP_DIR"
        sudo -u "$APP_USER" npm install --silent
        sudo -u "$APP_USER" npm run build --silent
        # Support both 'build' (CRA) and 'dist' (Vite)
        [ -d "$APP_DIR/dist" ] && STATIC_PATH="$APP_DIR/dist" || STATIC_PATH="$APP_DIR/build"
        DEPLOY_CMD="git -C $APP_DIR pull && npm --prefix $APP_DIR install && npm --prefix $APP_DIR run build"
        ;;

    static)
        STATIC_PATH="$APP_DIR"
        DEPLOY_CMD="git -C $APP_DIR pull"
        ;;
esac

# Create Systemd Service for Apps
if [[ -n "$EXEC_CMD" ]]; then
    cat > /etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=$APP_NAME Service
After=network.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment="PORT=$APP_PORT"
ExecStart=$EXEC_CMD
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now $APP_NAME
fi

# ── 5. Webhook Setup ──────────────────────────
echo "[5/6] Setting up webhook..."
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
    subprocess.Popen(["/bin/bash", "-c", "$DEPLOY_CMD"])
    return "OK", 200

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=$WEBHOOK_PORT)
EOF

chown "$APP_USER:$APP_USER" /home/$APP_USER/webhook-${APP_NAME}.py

cat > /etc/systemd/system/webhook-${APP_NAME}.service <<EOF
[Unit]
Description=Webhook for $APP_NAME
After=network.target

[Service]
User=$APP_USER
ExecStart=/usr/bin/python3 /home/$APP_USER/webhook-${APP_NAME}.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Safe Sudoers
echo "$APP_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $APP_NAME" > /etc/sudoers.d/$APP_USER

systemctl daemon-reload
systemctl enable --now webhook-${APP_NAME}

# ── 6. Nginx Registry ─────────────────────────
echo "[6/6] Finalizing Nginx..."
mkdir -p "$APP_REGISTRY"

if [[ "$FRAMEWORK" =~ ^(static|react)$ ]]; then
    echo "$APP_NAME:static:$STATIC_PATH:$WEBHOOK_PORT" > "$APP_REGISTRY/$APP_NAME"
else
    echo "$APP_NAME:proxy:$APP_PORT:$WEBHOOK_PORT" > "$APP_REGISTRY/$APP_NAME"
fi

# Rebuild Nginx Unified Config
{
    echo "server {"
    echo "    listen 80;"
    for app_file in "$APP_REGISTRY"/*; do
        [ -f "$app_file" ] || continue
        IFS=':' read -r name type val wport < "$app_file"
        
        # Webhook Location
        echo "    location /webhook-$name {"
        echo "        proxy_pass http://127.0.0.1:$wport/webhook;"
        echo "    }"

        # App Location
        echo "    location /$name/ {"
        if [[ "$type" == "static" ]]; then
            echo "        alias $val/;"
            echo "        try_files \$uri \$uri/ /$name/index.html;"
        else
            echo "        proxy_pass http://127.0.0.1:$val/;"
            echo "        proxy_set_header Host \$host;"
            echo "        proxy_set_header X-Real-IP \$remote_addr;"
        fi
        echo "    }"
    done
    echo "}"
} > "$NGINX_CONF"

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Deployment Complete!"
echo " URL: http://$(curl -s ifconfig.me)/$APP_NAME/"
echo " Webhook: http://$(curl -s ifconfig.me)/webhook-$APP_NAME"
echo " Secret: $WEBHOOK_SECRET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"