# Universal Web App Deployment Script

This script automates the deployment of Flask and React apps on a Linux server.

## Features
- **Auto-Port Discovery**: Finds available ports for your app and webhook.
- **Systemd Integration**: Manages your apps as system services (auto-restart on crash).
- **Nginx Automation**: Automatically configures reverse proxy and subpath routing.
- **CI/CD Webhook**: Secure GitHub webhook listener for automatic deployments on `git push`.

## Quick Start
1. **Run the script**:
   change permissoins on the file
   ```bash
   chmod +x setup-app.sh
   ```
   ```bash
   sudo ./setup-app.sh
   ```
2. **Configure GitHub**:
   - Add a webhook in GitHub settings.
   - URL: `http://<your-ip>/webhook-<your-app-name>`
   - Secret: The one you chose during setup.
   - Content type: `application/json`

## Post-Install Checklist
- **SSL**: Install Certbot (`sudo apt install certbot python3-certbot-nginx && sudo certbot --nginx`) to enable HTTPS.
- **React**: Ensure `"homepage": "/app-name"` is in `package.json` if using subpaths.
- **Firewall**: Ensure ports 80 (HTTP) and 443 (HTTPS) are open.

## Process Management
- **View Logs**: `sudo journalctl -u <app-name> -f`
- **Restart App**: `sudo systemctl restart <app-name>`
- **Restart Webhook**: `sudo systemctl restart webhook-<app-name>`

## Security
- App code is owned by the designated unprivileged user.
- Sudoers permissions are restricted to only allow restarting the specific app service.
- Webhook uses HMAC SHA-256 signature verification to prevent unauthorized triggers.

## Directory Structure
- **App Code**: `/home/<user>/<app-name>`
- **Webhook script**: `/home/<user>/webhook-<app-name>.py`
- **Nginx Config**: `/etc/nginx/sites-available/<app-name>.conf`
- **Registry**: `/etc/app-registry/` (Used to track assigned ports)

## 🗑️ Removing an App (Teardown)

If you need to remove an application and free up its assigned ports, use the `teardown-app.sh` script.

### 1. Run the Teardown Script

     sudo ./teardown-app.sh <app-name>

### 2. Check Port Registry
To see which apps are assigned to which ports:

     cat /etc/app-registry/*

## Requirements
    GitHub repository must be public

    The script will fail if it uses a database
    #flask
      if you are using flask you need to have a app.py file in the root of the repository
      if you have routes use the following
      from werkzeug.middleware.proxy_fix import ProxyFix
      app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_prefix=1)
      <base href="/app-name/"> use this in your html files to work with subpaths

## TODO
    if .env file is present use it.
    adding this line to the [Service] section of /etc/systemd/system/myapp.service
