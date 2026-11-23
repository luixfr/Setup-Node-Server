# Production Server Setup

Automated setup for a production Ubuntu server hosting one or more Node applications. `setup.sh` prepares the server once (NGINX, Node.js, PM2, Certbot, ops/deploy users, SSH hardening). `add-app` then adds each application with its own isolated user, PM2 daemon, NGINX site, SSL certificate and a placeholder page, so you can verify it's live before deploying.

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

> If the admin user ends up with an SSH key, the script **disables root SSH login and password authentication**. Before closing your root session, confirm `ssh ops@<server>` and `sudo -n true` work in a new terminal.

---

## Run the Script

SSH into the server as root, then download and run the setup script. It fetches `add-app` and the placeholder from this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/luixfr/Setup-Node-Server/main/setup.sh -o setup.sh && bash setup.sh
```

At the end, `setup.sh` offers to add the first app.

### Adding more apps

Log in as the admin user (`ops` by default) and run:

```bash
sudo add-app
```

Each run creates one fully isolated app. Run it again for every app you host on the server.

---

## What the Scripts Ask

### `setup.sh` (once per server)

| Prompt | Example | Notes |
|--------|---------|-------|
| Admin username | `ops` | SSH (key only) + passwordless sudo, for server maintenance |
| Admin SSH public key | `ssh-ed25519 AAAA...` | Leave blank to copy root's `authorized_keys` |
| Deploy username | `deploy` | Uploads code and restarts apps |
| Deploy SSH public key | `ssh-ed25519 AAAA...` | Leave blank to skip |
| Runtimes | `node` | Any of `node`, `deno`, `bun` |
| Node.js version | `lts` | Only asked when `node` is selected |
| SSL email | `you@example.com` | Default Let's Encrypt email for all apps |

### `add-app` (once per app)

| Prompt | Example | Notes |
|--------|---------|-------|
| App name | `[YOUR_APP_NAME]` | Lowercase letters, digits, `-` (max 32). Used as the app's Linux user, directory (`/var/www/[YOUR_APP_NAME]`) and PM2 process name. Can't match an existing user or group (e.g. `nginx`, `deploy`) |
| Domain name | `[YOUR_APP_NAME].example.com` | Must already point to this server's IP. Must not be used by another app |
| App port | `3000` | Defaults to the first port not used by another app |
| SSL email | `you@example.com` | Defaults to the email given to `setup.sh` |

---

## What Gets Installed

### Per server (`setup.sh`)

| Component | Purpose |
|-----------|---------|
| `ops` user | The only sudoer. No password: logs in with its SSH key only and uses sudo without a password, so **its SSH key is effectively root access**. Use it for server maintenance and `sudo add-app` |
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
| `<name>` user | Runs the app. No login shell, no sudo, read-only access to its own code only |
| `/var/www/<name>` | App code, owned by `deploy`, group `<name>`, mode `2750` |
| PM2 daemon | Runs as `<name>` (systemd unit `pm2-<name>`), with log rotation. Restarts the app on boot |
| Sudo rule | `/etc/sudoers.d/deploy-<name>`: lets `deploy` run `pm2` as `<name>` |
| NGINX site | `/etc/nginx/conf.d/<domain>.conf`, proxying to the app's port |
| SSL certificate | Requested from Let's Encrypt, with HTTP → HTTPS redirect |
| Placeholder app | Simple Node.js server so you can verify the stack works immediately |

### Security model

| | ops | deploy | &lt;name&gt; |
|---|---|---|---|
| SSH login | ✅ | ✅ | ❌ |
| sudo | ✅ (no password) | ❌ (only `sudo -u <name> pm2`) | ❌ |
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
sudo -u [YOUR_APP_NAME] pm2 restart [YOUR_APP_NAME] && sudo -u [YOUR_APP_NAME] pm2 save
```

The app user can only **read** the code. If your app writes to disk (e.g. Next.js `.next/cache`, an uploads folder), make only those directories group-writable:

```bash
chmod -R g+w /var/www/[YOUR_APP_NAME]/.next/cache
```

> `rsync -a` copies permissions from your local machine, so re-apply this after deploys that recreate the directory.

### 3. Confirm SSL auto-renewal

As `ops`:

```bash
sudo certbot renew --dry-run
```

---

## Managing PM2 and Logs

Each app has its own PM2, running as that app's user. There's no shared or root PM2:

| | Example for app `alpha` |
|---|---|
| Linux user | `alpha` |
| PM2 data and logs | `/home/alpha/.pm2/` |
| systemd service (starts PM2 on boot) | `pm2-alpha` |

App users can't log in, so manage PM2 from the `deploy` user, prefixing every command with `sudo -u <name>`. That's the only thing `deploy` is allowed to run with sudo.

### Processes (as `deploy`)

```bash
sudo -u [YOUR_APP_NAME] pm2 status                          # list processes
sudo -u [YOUR_APP_NAME] pm2 restart [YOUR_APP_NAME]         # restart (brief downtime)
sudo -u [YOUR_APP_NAME] pm2 reload [YOUR_APP_NAME]          # zero-downtime reload (cluster mode only)
sudo -u [YOUR_APP_NAME] pm2 stop [YOUR_APP_NAME]
sudo -u [YOUR_APP_NAME] pm2 start [YOUR_APP_NAME]
sudo -u [YOUR_APP_NAME] pm2 describe [YOUR_APP_NAME]        # script, cwd, env, restarts, log paths
sudo -u [YOUR_APP_NAME] pm2 monit                           # live CPU/memory dashboard
```

After changing `ecosystem.config.js` (start command, port, env), a plain `restart` won't pick up the change. Restart from the file instead:

```bash
sudo -u [YOUR_APP_NAME] pm2 startOrRestart /var/www/[YOUR_APP_NAME]/ecosystem.config.js --update-env
sudo -u [YOUR_APP_NAME] pm2 save
```

> Always run `pm2 save` after changing the process list. On reboot, PM2 restores what was last saved, not what was running.

### Logs (as `deploy`)

```bash
sudo -u [YOUR_APP_NAME] pm2 logs [YOUR_APP_NAME]              # live tail (Ctrl+C to exit)
sudo -u [YOUR_APP_NAME] pm2 logs [YOUR_APP_NAME] --lines 200  # last 200 lines, then follow
sudo -u [YOUR_APP_NAME] pm2 logs [YOUR_APP_NAME] --err        # errors only
sudo -u [YOUR_APP_NAME] pm2 flush [YOUR_APP_NAME]             # clear the log files
```

The log files are also readable directly, because `deploy` is in each app's group:

```bash
ls /home/[YOUR_APP_NAME]/.pm2/logs/
#   [YOUR_APP_NAME]-out.log    stdout
#   [YOUR_APP_NAME]-error.log  stderr
#   *.gz                       rotated archives (10 MB max per file, kept 7 days)
zcat /home/[YOUR_APP_NAME]/.pm2/logs/[YOUR_APP_NAME]-out__*.gz | less
```

> If `deploy` was already logged in when you ran `add-app`, it isn't in the new app's group yet. Log out and back in (or run `newgrp [YOUR_APP_NAME]`) before reading files directly. The `sudo -u` commands work either way.

### The PM2 service (as `ops`)

These manage the PM2 instance itself rather than the app inside it. Use them when PM2 won't start, for example after a reboot:

```bash
sudo systemctl status pm2-[YOUR_APP_NAME]
sudo journalctl -u pm2-[YOUR_APP_NAME] -n 100 --no-pager   # PM2 startup errors
sudo systemctl restart pm2-[YOUR_APP_NAME]                 # restart PM2 (restores the saved list)
```

`ops` can also run any of the PM2 commands above with `sudo -u [YOUR_APP_NAME] pm2 ...`.

### Shortcut aliases

To avoid typing `sudo -u <name>` every time, add aliases to deploy's `~/.bashrc`:

```bash
alias pm2-alpha='sudo -u alpha pm2'
alias pm2-beta='sudo -u beta pm2'
# usage: pm2-alpha logs alpha
```

> Aliases only apply in interactive shells. CI scripts that SSH in should use the full `sudo -u <name> pm2 ...` form.

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
| PM2 startup on reboot | Testable with `systemctl restart pm2-<name>` (the container uses the host cgroup namespace) |
| SSH hardening | Skipped unless root has an `authorized_keys` file or you paste an admin key |

---

## Troubleshooting

**Certbot failed while adding an app**
DNS hadn't propagated yet. Once the domain resolves, run:
```bash
sudo certbot --nginx -d your-domain.com   # as ops
```

**App not responding**
Check PM2 logs:
```bash
sudo -u [YOUR_APP_NAME] pm2 logs [YOUR_APP_NAME]   # as deploy
```

**NGINX errors**
Test and inspect the config:
```bash
sudo nginx -t
sudo journalctl -u nginx --no-pager -n 50
```

**PM2 not starting on reboot**
As `ops`:
```bash
sudo systemctl status pm2-[YOUR_APP_NAME]
sudo pm2 startup systemd -u [YOUR_APP_NAME] --hp /home/[YOUR_APP_NAME]
```
Then, as `deploy`, save the process list:
```bash
sudo -u [YOUR_APP_NAME] pm2 save
```

**`add-app` says the app, domain or port is already in use**
Each app needs a unique name, domain and port. `add-app` checks the existing users, `/var/www`, the NGINX sites in `/etc/nginx/conf.d` and listening ports. It stops before changing anything.

**Locked out of SSH**
Root login and password authentication are disabled once the admin user has a key. Use your provider's web console to log in as root, then fix `/home/ops/.ssh/authorized_keys` or remove `/etc/ssh/sshd_config.d/00-hardening.conf`.
