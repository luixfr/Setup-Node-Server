# Production Server Setup

Automated setup script for a production Ubuntu server hosting a Next.js application. Installs and configures NGINX, Node.js, PM2, Certbot (SSL), a deploy user, and a placeholder page so you can verify the stack is live before deploying your app.

## Prerequisites

Complete these steps **before** running the script.

### 1. DigitalOcean Droplet

- Create an Ubuntu 22.04 (or 24.04) Droplet
- Note its public IP address
- Ensure you can SSH in as `root`

### 2. DNS

Point your subdomain at the Droplet's IP address **before** running the script — Certbot needs the domain to resolve for SSL to work.

In Cloudflare (or your DNS provider):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `your-subdomain` | `YOUR_DROPLET_IP` | Off (DNS only) |

> DNS propagation can take up to 24 hours, but is usually a few minutes with Cloudflare.

### 3. SSH Access

Have your local machine's public key ready to paste when prompted (`~/.ssh/id_rsa.pub` or `~/.ssh/id_ed25519.pub`). You can skip this during setup and add it manually later.

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
| Deploy username | `deploy` | Press Enter to use the default |
| Public SSH key | `ssh-ed25519 AAAA...` | Leave blank to skip |
| App port | `3000` | Press Enter to use the default |

---

## What Gets Installed

| Component | Purpose |
|-----------|---------|
| `deploy` user | Unprivileged user that runs and owns the app |
| NGINX | Reverse proxy, forwards port 80/443 → app port |
| Certbot | Obtains and auto-renews a Let's Encrypt SSL certificate |
| Node.js LTS | JavaScript runtime |
| yarn, prisma | Global packages for Next.js apps |
| PM2 | Process manager — keeps the app running and restarts it on boot |
| Placeholder app | Simple Node.js server so you can verify the stack works immediately |

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

Then on the server:

```bash
# Add your environment variables
nano /var/www/[YOUR_APP_NAME]/.env

# Update the PM2 config to run Next.js instead of the placeholder
nano ~/ecosystem.config.js
# Change:  script: "node", args: "server.js"
# To:      your start script: For example, for Next.js "npx",  args: "next start"

pm2 restart [YOUR_APP_NAME] && pm2 save
```

### 3. Confirm SSL auto-renewal

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
| PM2 startup on reboot | Configured but not testable in a container |

---

## Troubleshooting

**Certbot failed during setup**
DNS hadn't propagated yet. Once the domain resolves, run:
```bash
sudo certbot --nginx -d your-domain.com
```

**App not responding**
Check PM2 logs:
```bash
pm2 logs [YOUR_APP_NAME]
```

**NGINX errors**
Test and inspect the config:
```bash
sudo nginx -t
sudo journalctl -u nginx --no-pager -n 50
```

**PM2 not starting on reboot**
Run as the deploy user:
```bash
pm2 startup
# Copy and run the command it prints, then:
pm2 save
```
