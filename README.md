# Production Server Setup

Automated setup for a production Ubuntu server hosting one or more Node applications. `setup.sh` prepares the server once (NGINX, Node.js, PM2, Certbot, admin/deploy users, SSH hardening). `add-app` then adds each application with its own isolated user, PM2 daemon, NGINX site, SSL certificate and a placeholder page, so you can verify it's live before deploying.

## Prerequisites

Complete these steps **before** running the script.

### 1. Linux server

- Create a linux server, recommended Ubuntu
- Note its public IP address
- Ensure you can SSH in as `root`

### 2. DNS

Point each app's domain at the server's IP address **before** adding the app — Certbot needs the domain to resolve for SSL to work.

On your DNS provider:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `your-subdomain` | `YOUR_SERVER_IP` | Off (DNS only) |

> DNS propagation can take up to 24 hours, but is usually a few minutes.

### 3. SSH Access

Have your public keys ready to paste when prompted (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`):

- **Admin key**: your personal key. If left blank, root's `authorized_keys` (e.g. the key your provider injected) is copied to the admin user.
- **Deploy key**: the key your CI or deploy machine uses. Ideally a different key from the admin one. Can be added later.

> If the admin user ends up with an SSH key, the script **disables root SSH login and password authentication**. Before closing your root session, confirm `ssh admin@<server>` and `sudo -v` work in a new terminal.

---

## Run the Script

SSH into the server as root, then download and run the setup script. It fetches `add-app` and the placeholder from this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main/setup.sh -o setup.sh && bash setup.sh
```

At the end, `setup.sh` offers to add the first app.

### Adding more apps

Log in as the admin user and run:

```bash
sudo add-app
```

Each run creates one fully isolated app. Run it again for every app you host on the server.

---

## What the Scripts Ask

### `setup.sh` (once per server)

| Prompt | Example | Notes |
|--------|---------|-------|
| Admin username | `admin` | SSH + sudo for server maintenance |
| Admin password | | Required by sudo. Only asked when the user is created |
| Admin SSH public key | `ssh-ed25519 AAAA...` | Leave blank to copy root's `authorized_keys` |
| Deploy username | `deploy` | Uploads code and restarts apps |
| Deploy SSH public key | `ssh-ed25519 AAAA...` | Leave blank to skip |
| Runtimes | `node` | Any of `node`, `deno`, `bun` |
| Node.js version | `lts` | Only asked when `node` is selected |
| SSL email | `you@example.com` | Default Let's Encrypt email for all apps |

### `add-app` (once per app)

| Prompt | Example | Notes |
|--------|---------|-------|
| App name | `[YOUR_APP_NAME]` | Lowercase letters, digits, `-`. Used for the user (`app-[YOUR_APP_NAME]`), directory (`/var/www/[YOUR_APP_NAME]`) and PM2 process name |
| Domain name | `[YOUR_APP_NAME].example.com` | Must already point to this server's IP. Must not be used by another app |
| App port | `3000` | Defaults to the first port not used by another app |
| SSL email | `you@example.com` | Defaults to the email given to `setup.sh` |

---

## What Gets Installed

### Per server (`setup.sh`)

| Component | Purpose |
|-----------|---------|
| `admin` user | The only sudoer (password required). Use it for server maintenance and `sudo add-app` |
| `deploy` user | Owns all app code. No sudo. Can only run `pm2` as each app's user |
| NGINX (stable, from nginx.org) | Reverse proxy. A catch-all (`/etc/nginx/conf.d/00-default.conf`) rejects requests for unknown hosts, such as the bare IP |
| Certbot | Obtains and auto-renews Let's Encrypt SSL certificates |
| Node.js LTS | JavaScript runtime |
| yarn, prisma | Global packages for Next.js apps |
| PM2 | Process manager (each app runs its own PM2 daemon) |
| SSH hardening | Root login and password auth disabled (only when the admin user has an SSH key) |
| `add-app` | Installed at `/usr/local/sbin/add-app`. Settings in `/etc/server-setup.conf` |

### Per app (`add-app`)

| Component | Purpose |
|-----------|---------|
| `app-<name>` user | Runs the app. No login shell, no sudo, read-only access to its own code only |
| `/var/www/<name>` | App code, owned by `deploy`, group `app-<name>`, mode `2750` |
| PM2 daemon | Runs as `app-<name>` (systemd unit `pm2-app-<name>`), with log rotation. Restarts the app on boot |
| Sudo rule | `/etc/sudoers.d/deploy-app-<name>`: lets `deploy` run `pm2` as `app-<name>` |
| NGINX site | `/etc/nginx/conf.d/<domain>.conf`, proxying to the app's port |
| SSL certificate | Requested from Let's Encrypt, with HTTP → HTTPS redirect |
| Placeholder app | Simple Node.js server so you can verify the stack works immediately |

### Security model

| | admin | deploy | app-&lt;name&gt; |
|---|---|---|---|
| SSH login | ✅ | ✅ | ❌ |
| sudo | ✅ (password) | ❌ (only `sudo -u app-<name> pm2`) | ❌ |
| Write app code (`/var/www/<name>`) | via sudo | ✅ (owner) | ❌ (read-only via group) |
| Read other apps' code, `.env`, logs | via sudo | ✅ | ❌ |
| Control other apps' processes | via sudo | ✅ (via pm2) | ❌ |
| Write NGINX config | via sudo | ❌ | ❌ |

A compromised app can't change its own code, touch other apps (their secrets, logs or processes), change the NGINX config, or escalate to root. Letting `deploy` run `pm2` as each app user adds nothing `deploy` couldn't already do, because it owns the code those users run.

---

## After Adding an App

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
# Add your environment variables (readable by the app, not by other apps)
nano /var/www/[YOUR_APP_NAME]/.env && chmod 640 /var/www/[YOUR_APP_NAME]/.env

# Update the PM2 config to run your app instead of the placeholder
nano /var/www/[YOUR_APP_NAME]/ecosystem.config.js
# Next.js:       script: "npx",      args: "next start"

# PM2 runs as the app's own user
sudo -u app-[YOUR_APP_NAME] pm2 restart [YOUR_APP_NAME] && sudo -u app-[YOUR_APP_NAME] pm2 save
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

You can test the scripts locally against a Docker container that mimics a fresh Ubuntu server before running them on a real one.

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
# Add more apps afterwards with:
add-app
```

When prompted, use any value for the domain (e.g. `test.example.com`) — Certbot will fail gracefully since there's no real DNS, but everything else runs to completion.

### Verify the placeholder

Requests must use the app's domain, since unknown hosts are rejected:

```bash
curl -H "Host: test.example.com" http://localhost:8080
```

You should see the "Server is ready" page served through NGINX → PM2 → Node.js.

### Iterate without rebuilding

`setup.sh`, `add-app.sh` and `placeholder.js` are volume-mounted into the container, so edits you make locally are reflected immediately — just re-run the script inside the container without rebuilding the image. `setup.sh` uses these local copies instead of downloading them.

### Tear down

```bash
docker compose -f docker-compose.test.yml down
```

### Known differences from a real server

| Feature | Behavior in Docker |
|---------|-------------------|
| `ufw` firewall | Works but is a no-op (container networking bypasses it) |
| `systemctl` / systemd | Works via privileged mode + systemd init |
| Certbot SSL cert | Always fails — no real DNS. Expected. |
| PM2 startup on reboot | Testable with `systemctl restart pm2-app-<name>` (the container uses the host cgroup namespace) |
| SSH hardening | Skipped unless root has an `authorized_keys` file or you paste an admin key |

---

## Troubleshooting

**Certbot failed while adding an app**
DNS hadn't propagated yet. Once the domain resolves, run:
```bash
sudo certbot --nginx -d your-domain.com   # as admin
```

**App not responding**
Check PM2 logs:
```bash
sudo -u app-[YOUR_APP_NAME] pm2 logs [YOUR_APP_NAME]   # as deploy
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
sudo systemctl status pm2-app-[YOUR_APP_NAME]
sudo pm2 startup systemd -u app-[YOUR_APP_NAME] --hp /home/app-[YOUR_APP_NAME]
```
Then, as `deploy`, save the process list:
```bash
sudo -u app-[YOUR_APP_NAME] pm2 save
```

**`add-app` says the app, domain or port is already in use**
Each app needs a unique name, domain and port. `add-app` checks the existing users, `/var/www`, the NGINX sites in `/etc/nginx/conf.d` and listening ports. It stops before changing anything.

**Locked out of SSH**
Root login and password authentication are disabled once the admin user has a key. Use your provider's web console to log in as root, then fix `/home/admin/.ssh/authorized_keys` or remove `/etc/ssh/sshd_config.d/00-hardening.conf`.
