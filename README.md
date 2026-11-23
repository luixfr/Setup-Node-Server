# Production Server Setup

Automated setup script for a production Ubuntu server hosting a Node application. Installs and configures NGINX, Node.js, PM2, Certbot (SSL), separate admin/deploy/app users, and a placeholder page so you can verify the stack is live before deploying your app.

## Prerequisites

Complete these steps **before** running the script.

### 1. Linux server

- Create a linux server, recommended Ubuntu
- Note its public IP address
- Ensure you can SSH in as `root`

### 2. DNS

Point your subdomain at the Droplet's IP address **before** running the script — Certbot needs the domain to resolve for SSL to work.

On your DNS provider:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `your-subdomain` | `YOUR_DROPLET_IP` | Off (DNS only) |

> DNS propagation can take up to 24 hours, but is usually a few minutes with Cloudflare.

### 3. SSH Access

Have your public keys ready to paste when prompted (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`):

- **Admin key**: your personal key. If left blank, root's `authorized_keys` (e.g. the key your provider injected) is copied to the admin user.
- **Deploy key**: the key your CI or deploy machine uses. Ideally a different key from the admin one. Can be added later.

> If the admin user ends up with an SSH key, the script **disables root SSH login and password authentication**. Before closing your root session, confirm `ssh admin@your-domain.com` and `sudo -v` work in a new terminal.

---

## Run the Script

SSH into your Droplet as root, then download and run both files:

```bash
curl -fsSL https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main/setup.sh -o setup.sh && bash setup.sh
```

---

## What the Script Asks

| Prompt | Example | Notes |
|--------|---------|-------|
| Domain name | `[YOUR_APP_NAME].example.com` | Must already point to this server's IP |
| App name | `[YOUR_APP_NAME]` | Used for the app directory (`/var/www/[YOUR_APP_NAME]`) and PM2 process name |
| Admin username | `admin` | SSH + sudo for server maintenance |
| Admin password | | Required by sudo. Only asked when the user is created |
| Admin SSH public key | `ssh-ed25519 AAAA...` | Leave blank to copy root's `authorized_keys` |
| Deploy username | `deploy` | Uploads code and restarts the app |
| Deploy SSH public key | `ssh-ed25519 AAAA...` | Leave blank to skip |
| App runtime username | `app` | Runs the app process. No login, no sudo |
| App port | `3000` | Press Enter to use the default |
| Runtimes | `node` | Any of `node`, `deno`, `bun` |
| Node.js version | `lts` | Only asked when `node` is selected |
| SSL email | `you@example.com` | Used by Let's Encrypt |

---

## What Gets Installed

| Component | Purpose |
|-----------|---------|
| `admin` user | The only sudoer (password required). Use it for server maintenance |
| `deploy` user | Owns the app code. No sudo. Can only run `pm2` as the `app` user |
| `app` user | Runs the app via PM2. No login shell, no sudo, read-only access to the code |
| NGINX (stable, from nginx.org) | Reverse proxy, forwards port 80/443 → app port. Site config: `/etc/nginx/conf.d/<domain>.conf` |
| Certbot | Obtains and auto-renews a Let's Encrypt SSL certificate |
| Node.js LTS | JavaScript runtime |
| yarn, prisma | Global packages for Next.js apps |
| PM2 | Process manager, running as `app` (systemd unit `pm2-app`). Keeps the app running and restarts it on boot |
| SSH hardening | Root login and password auth disabled (only when the admin user has an SSH key) |
| Placeholder app | Simple Node.js server so you can verify the stack works immediately |

### Security model

| | admin | deploy | app |
|---|---|---|---|
| SSH login | ✅ | ✅ | ❌ |
| sudo | ✅ (password) | ❌ (only `sudo -u app pm2`) | ❌ |
| Write app code (`/var/www/<app>`) | via sudo | ✅ (owner) | ❌ (read-only via group) |
| Write NGINX config | via sudo | ❌ | ❌ |

A compromised app can't change its own code, the NGINX config, or escalate to root. Letting `deploy` run `pm2` as `app` adds nothing `deploy` couldn't already do, because it owns the code `app` runs.

---

## After Setup

### 1. Verify the placeholder is live

Open `http://your-domain.com` in a browser. You should see a "Server is ready" page. If Certbot succeeded, `https://` will also work.

### 2. Deploy your app

From your local machine, push your build to the server and restart PM2:

```bash
# Example using rsync
rsync -avz --delete .next package.json public deploy@your-domain.com:/var/www/[YOUR_APP_NAME]/
```

Then on the server, as `deploy`:

```bash
# Add your environment variables (readable by the app, not by other users)
nano /var/www/[YOUR_APP_NAME]/.env && chmod 640 /var/www/[YOUR_APP_NAME]/.env

# Update the PM2 config to run your app instead of the placeholder
nano /var/www/[YOUR_APP_NAME]/ecosystem.config.js
# Next.js:       script: "npx",      args: "next start"

# PM2 runs as the app user
sudo -u app pm2 restart [YOUR_APP_NAME] && sudo -u app pm2 save
```

The app user can only **read** the code. If your app writes to disk (e.g. Next.js `.next/cache`, an uploads folder), make only those directories group-writable:

```bash
chmod -R g+w /var/www/[YOUR_APP_NAME]/.next/cache
```

> `rsync -a` copies permissions from your local machine, so re-apply this after deploys that recreate the directory.

### 3. Confirm SSL auto-renewal

As `admin`:

```bash
sudo certbot renew --dry-run
```

---

## Testing in Docker

You can test the script locally against a Docker container that mimics a fresh Ubuntu Droplet before running it on a real server.

### Requirements

- Docker Desktop (Mac/Windows) or Docker Engine (Linux)

### Start the container

```bash
docker compose -f docker-compose.test.yml up -d --build
```

This starts a privileged Ubuntu 22.04 container with systemd as init. Port `8080` on your machine maps to port `80` inside the container.

### Run the script

```bash
docker exec -it droplet-test bash
bash /root/setup.sh
```

When prompted, use any value for the domain (e.g. `test.example.com`) — Certbot will fail gracefully since there's no real DNS, but everything else runs to completion.

### Verify the placeholder

Open [http://localhost:8080](http://localhost:8080) in your browser. You should see the "Server is ready" page served through NGINX → PM2 → Node.js.

### Iterate without rebuilding

`setup.sh` and `placeholder.js` are volume-mounted into the container, so edits you make locally are reflected immediately — just re-run the script inside the container without rebuilding the image.

### Tear down

```bash
docker compose -f docker-compose.test.yml down
```

### Known differences from a real Droplet

| Feature | Behavior in Docker |
|---------|-------------------|
| `ufw` firewall | Works but is a no-op (container networking bypasses it) |
| `systemctl` / systemd | Works via privileged mode + systemd init |
| Certbot SSL cert | Always fails — no real DNS. Expected. |
| PM2 startup on reboot | Testable with `systemctl restart pm2-app` (the container uses the host cgroup namespace) |
| SSH hardening | Skipped unless root has an `authorized_keys` file or you paste an admin key |

---

## Troubleshooting

**Certbot failed during setup**
DNS hadn't propagated yet. Once the domain resolves, run:
```bash
sudo certbot --nginx -d your-domain.com   # as admin
```

**App not responding**
Check PM2 logs:
```bash
sudo -u app pm2 logs [YOUR_APP_NAME]   # as deploy
```

**NGINX errors**
Test and inspect the config:
```bash
sudo nginx -t
sudo journalctl -u nginx --no-pager -n 50
```

**PM2 not starting on reboot**
As `admin`:
```bash
sudo systemctl status pm2-app
sudo pm2 startup systemd -u app --hp /home/app
```
Then, as `deploy`, save the process list:
```bash
sudo -u app pm2 save
```

**Locked out of SSH**
Root login and password authentication are disabled once the admin user has a key. Use your provider's web console to log in as root, then fix `/home/admin/.ssh/authorized_keys` or remove `/etc/ssh/sshd_config.d/00-hardening.conf`.
