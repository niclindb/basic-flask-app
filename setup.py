#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path

# ───UTIL─────────────────────────────────────
def run(cmd):
    print(f"> {cmd}")
    subprocess.run(cmd, shell=True, check=True)

def require_root():
    if os.geteuid() != 0:
        print("This script must be run as root (sudo).")
        sys.exit(1)

def get_next_port(start):
    used_ports = set()

    registry = Path("/etc/app-registry")
    if registry.exists():
        for file in registry.glob("*"):
            try:
                _, _, a, b = file.read_text().strip().split(":")
                
                used_ports.add(int(a))
                used_ports.add(int(b))
            except:
                continue

    port = start
    while port in used_ports:
        port += 1

    return port

REGISTRY_DIR = Path("/etc/app-registry")
REGISTRY_DIR.mkdir(exist_ok=True)

# ─────INPUT────────────────────────────────────
def get_input():
    app = input("App name: ").strip()
    print("\n1) Flask\n2) React\n3) Static")
    choice = input("Framework: ").strip()
    repo = input("GitHub repo URL: ").strip()
    user = input("Linux user: ").strip()
    secret = input("Webhook secret: ").strip()

    mapping = {"1": "flask", "2": "react", "3": "static"}
    if choice not in mapping:
        sys.exit("Invalid choice")

    return app, mapping[choice], repo, user, secret

    # ─────INSTALL────────────────────────────────────

def install_dependencies(framework):
    run("apt update -qq")
    run("apt install -y git nginx curl python3 python3-venv python3-pip")

    if framework == "react":
        run("command -v node || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs)")

# ────USER────────────────────────────────

def setup_user(user):
    run(f"id {user} || useradd -m -s /bin/bash {user}")

def setup_repo(repo, path, user):
    if Path(path).exists():
        run(f"git -C {path} pull")
    else:
        run(f"git clone {repo} {path}")
    run(f"chown -R {user}:{user} {path}")

# ────FLASK────────────────────────────────
def setup_flask(app, path, user, port):
    venv = f"{path}/venv"

    run(f"sudo -u {user} python3 -m venv {venv}")

    pip = f"{venv}/bin/pip"
    run(f"{pip} install flask gunicorn")

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

    deploy_cmd = (
        f"git -C {path} pull && "
        f"{venv}/bin/pip install -r {path}/requirements.txt || true && "
        f"sudo /bin/systemctl restart {app}"
    )

    return deploy_cmd

# ─────REACT or STATIC──────────────────────────────
def setup_react(path, user):
    run(f"cd {path} && sudo -u {user} npm install")
    run(f"cd {path} && sudo -u {user} npm run build")

    deploy_cmd = (
        f"git -C {path} pull && "
        f"npm --prefix {path} install && "
        f"npm --prefix {path} run build"
    )

    return f"{path}/build", deploy_cmd

def setup_static(path):
    return path, f"git -C {path} pull"

# ────WEBHOOK────────────────────────────────
def setup_webhook(app, user, secret, deploy_cmd, port):
    script_path = f"/home/{user}/webhook-{app}.py"

    code = f"""
from flask import Flask, request
import subprocess, hmac, hashlib

app = Flask(__name__)
SECRET = b"{secret}"

DEPLOY_CMD = "{deploy_cmd}"

@app.route("/webhook", methods=["POST"])
def webhook():
    sig = request.headers.get("X-Hub-Signature-256", "")
    if not sig:
        return "No signature", 400

    expected = "sha256=" + hmac.new(SECRET, request.data, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return "Forbidden", 403

    subprocess.Popen(["/bin/bash", "-c", DEPLOY_CMD])
    return "Deployment started", 200

if __name__ == "__main__":
    app.run(host="127.0.0.1", port={port})
"""

    Path(script_path).write_text(code)
    run(f"chown {user}:{user} {script_path}")

    service = f"""[Unit]
Description=Webhook {app}
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

# ──────NGINX────────────────────────────────
def register_app(app, framework, value, webhook_port):
    app_type = "proxy" if framework == "flask" else "static"
    data = f"{app}:{app_type}:{value}:{webhook_port}"
    (REGISTRY_DIR / app).write_text(data)



def build_nginx():
    conf_path = Path("/etc/nginx/sites-available/app.conf")

    lines = [
        "server {",
        "    listen 80;",
        "    server_name _;",
        "    client_max_body_size 100M;",
    ]

    for file in REGISTRY_DIR.glob("*"):
        try:
            name, app_type, value, webhook_port = file.read_text().strip().split(":")

            # webhook route
            lines += [
                f"\n    location /webhook-{name} {{",
                f"        proxy_pass http://127.0.0.1:{webhook_port}/webhook;",
                "    }"
            ]

            # app route
            lines += [f"\n    location /{name}/ {{"]

            if app_type == "static":
                lines += [
                    f"        alias {value}/;",
                    "        try_files $uri $uri/ /index.html;",
                ]
            else:
                lines += [
                    f"        proxy_pass http://127.0.0.1:{value}/;",
                    "        proxy_set_header Host $host;",
                    "        proxy_set_header X-Real-IP $remote_addr;",
                ]

            lines += ["    }"]

        except Exception as e:
            print(f"Skipping {file.name}: {e}")

    lines += ["}"]

    conf_path.write_text("\n".join(lines))

    run("nginx -t && systemctl reload nginx")

def enable_nginx():
    run("rm -f /etc/nginx/sites-enabled/default")
    run("ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf")
    run("nginx -t && systemctl reload nginx")


# ──────MAIN────────────────────────────────────
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

    print("\nDeployment complete")
    print(f"http://SERVER_IP/{app}/")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("To set up automatic deployment")
    print("1. go to the repo settings")
    print("2. Webhooks -> Add webhook")
    print("3. paste URL, set content type to application/json, and paste the secret")
    print("4. then add webhook")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

if __name__ == "__main__":
    main()