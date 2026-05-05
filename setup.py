#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path

def run(cmd):
    print(f"> {cmd}")
    # Using shell=True for complex piping, but be careful with untrusted input
    subprocess.run(cmd, shell=True, check=True)

def require_root():
    if os.geteuid() != 0:
        print("Error: This script must be run as root (sudo).")
        sys.exit(1)

def get_next_port(start):
    port = start
    while True:
        # Check if port is already listening
        result = subprocess.run(f"ss -tuln | grep -q :{port}", shell=True)
        if result.returncode != 0:
            return port
        port += 1

# ── INPUT ────────────────────────────────────────────────────────────────────
def get_input():
    app = input("App name: ").strip()
    print("\n1) Flask\n2) React\n3) Static")
    choice = input("Choose framework (1-3): ").strip()
    repo = input("GitHub repo URL: ").strip()
    user = input("Linux user to own the app: ").strip()
    secret = input("Webhook secret (for GitHub): ").strip()

    mapping = {"1": "flask", "2": "react", "3": "static"}
    if choice not in mapping:
        print("Invalid choice")
        sys.exit(1)

    return app, mapping[choice], repo, user, secret

# ── SETUP ────────────────────────────────────────────────────────────────────
def install_dependencies(framework):
    run("apt update -qq")
    run("apt install -y git nginx curl python3 python3-pip python3-venv")

    # Ensure Flask is available for the webhook script globally or in a safe place
    run("pip3 install flask --break-system-packages || pip3 install flask")

    if framework == "react":
        # Install Node.js if not present
        run("command -v node || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs)")

def setup_user(user):
    run(f"id {user} || useradd -m -s /bin/bash {user}")

def setup_repo(repo, path, user):
    if Path(path).exists():
        run(f"git -C {path} pull")
    else:
        run(f"git clone {repo} {path}")
    run(f"chown -R {user}:{user} {path}")

# ── FRAMEWORK SPECIFIC ───────────────────────────────────────────────────────
def setup_flask(app, path, user, port):
    venv = f"{path}/venv"
    run(f"sudo -u {user} python3 -m venv {venv}")
    
    pip = f"sudo -u {user} {venv}/bin/pip"
    run(f"{pip} install wheel flask gunicorn")

    if Path(f"{path}/requirements.txt").exists():
        run(f"{pip} install -r {path}/requirements.txt")

    service = f"""[Unit]
Description={app}
After=network.target

[Service]
User={user}
WorkingDirectory={path}
Environment="PATH={venv}/bin"
ExecStart={venv}/bin/gunicorn --bind 127.0.0.1:{port} app:app
Restart=always

[Install]
WantedBy=multi-user.target
"""
    Path(f"/etc/systemd/system/{app}.service").write_text(service)
    run("systemctl daemon-reload")
    run(f"systemctl enable --now {app}")

    # Return the command the webhook will use to redeploy
    return f"git -C {path} pull && {venv}/bin/pip install -r {path}/requirements.txt && sudo systemctl restart {app}"

def setup_react(path, user):
    # Run npm as the specific user to avoid permission issues in build folders
    run(f"cd {path} && sudo -u {user} npm install --silent")
    run(f"cd {path} && sudo -u {user} npm run build --silent")

    static_path = f"{path}/dist" if Path(f"{path}/dist").exists() else f"{path}/build"
    
    deploy_cmd = f"git -C {path} pull && npm --prefix {path} install && npm --prefix {path} run build"
    return static_path, deploy_cmd

def setup_static(path):
    return path, f"git -C {path} pull"

# ── WEBHOOK & PERMISSIONS ────────────────────────────────────────────────────
def setup_webhook(app, user, secret, deploy_cmd, port):
    script_path = f"/home/{user}/webhook-{app}.py"
    
    # We create a simple Flask listener for the GitHub Webhook
    code = f"""
from flask import Flask, request
import subprocess, hmac, hashlib

app = Flask(__name__)
SECRET = b"{secret}"

@app.route("/webhook", methods=["POST"])
def webhook():
    sig = request.headers.get("X-Hub-Signature-256", "")
    if not sig: return "No signature", 400
    
    expected = "sha256=" + hmac.new(SECRET, request.data, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return "Forbidden", 403
    
    subprocess.Popen(["/bin/bash", "-c", "{deploy_cmd}"])
    return "Deployment started", 200

if __name__ == "__main__":
    app.run(host="127.0.0.1", port={port})
"""
    Path(script_path).write_text(code)
    run(f"chown {user}:{user} {script_path}")

    service = f"""[Unit]
Description=Webhook for {app}
After=network.target

[Service]
User={user}
ExecStart=/usr/bin/python3 {script_path}
Restart=always

[Install]
WantedBy=multi-user.target
"""
    Path(f"/etc/systemd/system/webhook-{app}.service").write_text(service)
    run("systemctl daemon-reload")
    run(f"systemctl enable --now webhook-{app}")

    # Allow the user to restart the specific app service without a password
    sudoers_file = f"/etc/sudoers.d/{user}"
    run(f'echo "{user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart {app}" > {sudoers_file}')
    run(f"chmod 440 {sudoers_file}")

# ── NGINX CONFIGURATION ──────────────────────────────────────────────────────
def register_app(app, framework, value, webhook_port):
    """Saves app info so Nginx can rebuild the unified config."""
    registry = Path("/etc/app-registry")
    registry.mkdir(exist_ok=True)
    
    type_ = "proxy" if framework == "flask" else "static"
    content = f"{app}:{type_}:{value}:{webhook_port}"
    Path(registry / app).write_text(content)

def build_nginx():
    registry = Path("/etc/app-registry")
    conf_path = Path("/etc/nginx/sites-available/unified.conf")

    lines = [
        "server {",
        "    listen 80 default_server;",
        "    server_name _;",
        "    client_max_body_size 100M;"
    ]

    for file in registry.glob("*"):
        try:
            name, type_, val, wport = file.read_text().strip().split(":")
            
            # Webhook Location
            lines += [
                f"\n    location /webhook-{name} {{",
                f"        proxy_pass http://127.0.0.1:{wport}/webhook;",
                "    }"
            ]
            
            # App Location
            lines += [f"\n    location /{name}/ {{"]
            if type_ == "static":
                lines += [
                    f"        alias {val}/;",
                    "        try_files $uri $uri/ /index.html;",
                ]
            else:
                lines += [
                    f"        proxy_pass http://127.0.0.1:{val}/;",
                    "        proxy_set_header Host $host;",
                    "        proxy_set_header X-Real-IP $remote_addr;"
                ]
            lines += ["    }"]
        except Exception as e:
            print(f"Skipping {file.name} due to error: {e}")

    lines += ["}\n"]
    conf_path.write_text("\n".join(lines))

def enable_nginx():
    enabled_path = "/etc/nginx/sites-enabled/unified.conf"
    if not os.path.exists(enabled_path):
        run(f"ln -s /etc/nginx/sites-available/unified.conf {enabled_path}")
    
    run("rm -f /etc/nginx/sites-enabled/default")
    run("nginx -t && systemctl reload nginx")

# ── MAIN ─────────────────────────────────────────────────────────────────────
def main():
    require_root()

    app, framework, repo, user, secret = get_input()
    app_dir = f"/home/{user}/{app}"

    webhook_port = get_next_port(9000)
    app_port = get_next_port(5000) if framework == "flask" else None

    install_dependencies(framework)
    setup_user(user)
    setup_repo(repo, app_dir, user)

    if framework == "flask":
        deploy_cmd = setup_flask(app, app_dir, user, app_port)
        register_app(app, framework, app_port, webhook_port)
    elif framework == "react":
        static_path, deploy_cmd = setup_react(app_dir, user)
        register_app(app, framework, static_path, webhook_port)
    else:
        static_path, deploy_cmd = setup_static(app_dir)
        register_app(app, framework, static_path, webhook_port)

    setup_webhook(app, user, secret, deploy_cmd, webhook_port)
    build_nginx()
    enable_nginx()

    print(f"\n✅ Deployment complete for {app}")
    print(f"🌍 App:     http://<your-server-ip>/{app}/")
    print(f"⚓ Webhook: http://<your-server-ip>/webhook-{app}")

if __name__ == "__main__":
    main()