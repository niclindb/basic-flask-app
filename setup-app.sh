#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Modular Web App Deployment Script
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# --- Configuration & Constants ---
REGISTRY_DIR="/etc/app-registry"
NGINX_CONF_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

# --- Utility Functions ---

log() { echo -e "\e[34m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

check_root() {
    [[ $EUID -ne 0 ]] && error "This script must be run as root (sudo)."
}

get_next_port() {
    local port=$1
    while ss -tuln | grep -q ":$port "; do port=$((port + 1)); done
    echo $port
}

# --- Strategy: Framework Handlers ---

setup_flask() {
    local app_dir=$1 app_user=$2 port=$3 app_name=$4
    local venv="$app_dir/venv"
    
    log "Setting up Flask environment..."
    python3 -m venv "$venv"
    sudo -u "$app_user" "$venv/bin/pip" install -q wheel gunicorn flask
    [[ -f "$app_dir/requirements.txt" ]] && sudo -u "$app_user" "$venv/bin/pip" install -q -r "$app_dir/requirements.txt"
    
    cat <<EOF > "/etc/systemd/system/$app_name.service"
[Unit]
Description=$app_name Service
After=network.target

[Service]
User=$app_user
WorkingDirectory=$app_dir
ExecStart=$venv/bin/gunicorn --bind 127.0.0.1:$port app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    echo "proxy:$port" # Return registry data
}

setup_react() {
    local app_dir=$1 app_user=$2 app_name=$3
    log "Building React application..."
    
    # Ensure Node exists
    command -v node &>/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs)
    
    cd "$app_dir"
    sudo -u "$app_user" npm install --silent
    sudo -u "$app_user" npm run build --silent
    
    local static_path="$app_dir/dist"
    [[ ! -d "$static_path" ]] && static_path="$app_dir/build"
    echo "static:$static_path"
}

setup_static() {
    echo "static:$1"
}

# --- Core Logic Functions ---

configure_webhook() {
    local name=$1 user=$2 port=$3 secret=$4 deploy_cmd=$5
    local script_path="/home/$user/webhook-$name.py"

    cat <<EOF > "$script_path"
from flask import Flask, request
import subprocess, hmac, hashlib
app = Flask(__name__)
@app.route("/webhook", methods=["POST"])
def webhook():
    sig = request.headers.get("X-Hub-Signature-256", "")
    expected = "sha256=" + hmac.new(b"$secret", request.data, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected): return "Forbidden", 403
    subprocess.Popen(["/bin/bash", "-c", "$deploy_cmd"])
    return "OK", 200
if __name__ == "__main__": app.run(host="127.0.0.1", port=$port)
EOF
    chown "$user:$user" "$script_path"
    
    cat <<EOF > "/etc/systemd/system/webhook-$name.service"
[Unit]
Description=Webhook for $name
[Service]
User=$user
ExecStart=/usr/bin/python3 $script_path
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "webhook-$name"
    echo "$user ALL=(ALL) NOPASSWD: /bin/systemctl restart $name" > "/etc/sudoers.d/$user"
}

rebuild_nginx() {
    log "Rebuilding unified Nginx config..."
    local conf_path="$NGINX_CONF_DIR/unified-apps.conf"
    {
        echo "server { listen 80 default_server; server_name _; "
        for f in "$REGISTRY_DIR"/*; do
            [[ -f "$f" ]] || continue
            IFS=':' read -r name type val wport < "$f"
            echo "location /webhook-$name { proxy_pass http://127.0.0.1:$wport/webhook; }"
            echo "location /$name/ {"
            if [[ "$type" == "static" ]]; then
                echo "alias ${val%/}/; try_files \$uri \$uri/ /$name/index.html;"
            else
                echo "proxy_pass http://127.0.0.1:$val/; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Prefix /$name;"
            fi
            echo "}"
        done
        echo "}"
    } > "$conf_path"
    ln -sf "$conf_path" "$ENABLED_DIR/default"
    nginx -t && systemctl reload nginx
}

# --- Main Flow ---

main() {
    check_root
    
    # Input Collection
    read -p "App Name: " APP_NAME
    read -p "Repo URL: " REPO_URL
    read -p "User: " APP_USER
    read -p "Framework (flask/react/static): " FRAMEWORK
    read -s -p "Webhook Secret: " WEBHOOK_SECRET; echo

    APP_DIR="/home/$APP_USER/$APP_NAME"
    mkdir -p "$REGISTRY_DIR"

    # 1. System Prep
    apt update -qq && apt install -y git nginx curl python3-pip python3-venv > /dev/null
    pip3 install flask --break-system-packages -q 2>/dev/null || pip3 install flask -q
    id "$APP_USER" &>/dev/null || useradd -m -s /bin/bash "$APP_USER"

    # 2. Repo Prep
    if [[ -d "$APP_DIR" ]]; then git -C "$APP_DIR" pull; else git clone "$REPO_URL" "$APP_DIR"; fi
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"

    # 3. Framework Strategy Execution
    local w_port=$(get_next_port 9000)
    local app_data=""
    local deploy_cmd="git -C $APP_DIR pull"

    case $FRAMEWORK in
        flask) 
            local a_port=$(get_next_port 5000)
            app_data=$(setup_flask "$APP_DIR" "$APP_USER" "$a_port" "$APP_NAME")
            deploy_cmd="$deploy_cmd && sudo systemctl restart $APP_NAME"
            systemctl enable --now "$APP_NAME"
            ;;
        react) 
            app_data=$(setup_react "$APP_DIR" "$APP_USER" "$APP_NAME")
            deploy_cmd="$deploy_cmd && npm --prefix $APP_DIR install && npm --prefix $APP_DIR run build"
            ;;
        static) 
            app_data=$(setup_static "$APP_DIR")
            ;;
        *) error "Unsupported framework." ;;
    esac

    # 4. Persistence & Services
    echo "$APP_NAME:$app_data:$w_port" > "$REGISTRY_DIR/$APP_NAME"
    configure_webhook "$APP_NAME" "$APP_USER" "$w_port" "$WEBHOOK_SECRET" "$deploy_cmd"
    rebuild_nginx

    log "Deployment Complete: http://$(curl -s ifconfig.me)/$APP_NAME/"
}

main "$@"
