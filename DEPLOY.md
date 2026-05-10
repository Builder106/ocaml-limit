# Deploying ocaml_lob to Oracle Cloud Always Free (E1 Micro AMD)

A self-contained guide for shipping the matching engine + Bloomberg Terminal dashboard to a free-forever Oracle Cloud VM. Total time: ~30-60 min if you already have an Oracle account, ~90 min from scratch (account verification is the slow part).

## What you get

- **VM**: Always-Free Ampere E2.1.Micro (1/8 OCPU, 1 GB RAM, 50 GB block storage)
- **Cost**: $0/month forever (in theory — see "Caveats" at the end)
- **Public URL**: `https://<your-hostname>/` with auto-renewing TLS
- **Architecture**: Caddy on host (handles 80/443 + Let's Encrypt) → Docker container running `bin/server.exe` on `127.0.0.1:8080`

## 1. Provision the VM

1. Sign up at [cloud.oracle.com](https://cloud.oracle.com). Verification requires a credit card for identity (no charges on the always-free tier) and takes ~15 min.
2. Console → **Compute → Instances → Create Instance**.
3. Configuration:
   - **Image**: Canonical Ubuntu 22.04
   - **Shape**: `VM.Standard.E2.1.Micro` (Always Free) — pick from the "Specialty and Legacy" tab if you don't see it under "AMD"
   - **Network**: default VCN, public subnet, "Assign a public IPv4 address"
   - **SSH key**: paste your `~/.ssh/id_ed25519.pub` (or generate one — Oracle will offer to)
4. Note the public IP after the instance reaches "Running" (~2 min).

## 2. Open ports 80 and 443

Two layers to punch through — Oracle's VCN security list, AND Ubuntu's host iptables (Oracle ships a default-deny set).

**VCN security list** (Console → Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → Add Ingress Rules):

| Source CIDR | Protocol | Destination Port |
|---|---|---|
| 0.0.0.0/0 | TCP | 80 |
| 0.0.0.0/0 | TCP | 443 |

**Host iptables**:
```bash
ssh ubuntu@<your-ip>
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

## 3. Add 1 GB swap

OCaml's compile uses ~600 MB peak. On a 1 GB RAM VM, the build OOMs without swap.

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 4. Install Docker

```bash
sudo apt-get update -y
sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu
exit  # log out and back in for the group to take effect
```

## 5. Build and run the server container

Two paths — pick one.

### Path A — Build on the VM (slower but self-contained)

```bash
git clone https://github.com/yinkavaughan/ocaml-limit-order-book.git
cd ocaml-limit-order-book
docker build -t ocaml_lob:latest .
```

Build takes ~15-25 min on a 1/8 OCPU box. The opam-install layer is the slow part; subsequent rebuilds (source-only) are <1 min thanks to layer caching.

### Path B — Build on your Mac, push to a registry (faster)

```bash
# On your Mac (assumes Docker Desktop with buildx)
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/<your-github-user>/ocaml_lob:latest \
  --push .

# On the VM
docker pull ghcr.io/<your-github-user>/ocaml_lob:latest
docker tag ghcr.io/<your-github-user>/ocaml_lob:latest ocaml_lob:latest
```

Mac M-series builds linux/amd64 via QEMU emulation — slower than native, but still ~5 min vs. the VM's ~20 min. Requires a public repo on GHCR or `docker login` first.

### Run

```bash
docker run -d \
  --name ocaml_lob \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  ocaml_lob:latest

# Sanity check
curl -i http://127.0.0.1:8080/
docker logs ocaml_lob
```

You should see `[demo bot] seeded 15 levels per side; starting loop` in the logs.

## 6. Pick a hostname

Three options, easiest to most-personal:

- **sslip.io** (zero setup): your URL becomes `https://<your-ip>.sslip.io/`. The DNS resolver auto-resolves any IP-shaped subdomain. Fine for a recruiter link, doesn't look polished.
- **DuckDNS** (free subdomain): register at [duckdns.org](https://duckdns.org), claim a subdomain, point the A record at your IP. Result: `https://yourname.duckdns.org/`.
- **Your own domain**: create an A record in your registrar pointing to the IP. Most polished.

## 7. Install Caddy and configure TLS

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update -y
sudo apt-get install -y caddy
```

Edit `/etc/caddy/Caddyfile` (replace `<hostname>` with your choice from step 6):

```
<hostname> {
    reverse_proxy 127.0.0.1:8080
    encode gzip
}
```

That's it — Caddy auto-handles WebSocket upgrades, HTTP→HTTPS redirects, and Let's Encrypt cert issuance.

```bash
sudo systemctl restart caddy
sudo systemctl status caddy   # confirm "active (running)"
```

First request to `https://<hostname>/` triggers cert issuance (~30 sec). After that, every subsequent request is served instantly with cached TLS.

## 8. Verify end-to-end

Open `https://<hostname>/` in a browser. You should see:
- The Bloomberg Terminal UI
- A populated order book (15 levels per side, seeded by the demo bot)
- Trades flowing on the tape every few hundred ms
- "LIVE" badge in the top right (WebSocket connection up)

## Updating the deployed code

### Manual

```bash
ssh ubuntu@<your-ip>
cd ocaml-limit-order-book
git pull
docker build -t ocaml_lob:latest .
docker stop ocaml_lob && docker rm ocaml_lob
docker run -d --name ocaml_lob --restart unless-stopped -p 127.0.0.1:8080:8080 ocaml_lob:latest
```

### Auto-deploy on push to `main`

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) builds a `linux/amd64` image, pushes to GitHub Container Registry as `ghcr.io/<your-user>/<repo>:latest` plus a `sha-<short>` tag, then SSHs into the VM to pull and restart. Sub-second downtime per deploy (Caddy 502s briefly while the container restarts).

**One-time setup:**

1. **Generate a deploy keypair** (separate from your personal SSH key — you'll be putting the private half into GitHub):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/oracle_deploy -N "" -C "ocaml_lob deploy"
   ```

2. **Authorize the public key on the VM:**
   ```bash
   ssh-copy-id -i ~/.ssh/oracle_deploy.pub ubuntu@<your-ip>
   # or, manually:
   cat ~/.ssh/oracle_deploy.pub | ssh ubuntu@<your-ip> 'cat >> ~/.ssh/authorized_keys'
   ```

3. **Add three secrets** at GitHub → repo → Settings → Secrets and variables → Actions → New repository secret:

   | Name | Value |
   |---|---|
   | `SSH_HOST` | the VM's public IP (or hostname from step 6) |
   | `SSH_USER` | `ubuntu` |
   | `SSH_PRIVATE_KEY` | contents of `~/.ssh/oracle_deploy` (the private half — `cat ~/.ssh/oracle_deploy`) |

4. **Push to `main`.** First run takes ~3-5 min — most of that is the OCaml dependency install in the build stage. Subsequent runs are <1 min thanks to GHA layer caching.

5. **Make the GHCR package public** (one-time, after the first successful push). GitHub → Packages → `ocaml_lob` → Package settings → "Change visibility" → Public. Without this, the VM's `docker pull` would need to authenticate to GHCR with a personal access token. Public packages are fine for a portfolio project.

You can also trigger the workflow manually from the Actions tab (Run workflow → main) — useful for redeploying without a code change.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `docker build` killed mid-OCaml-compile | Out of memory — confirm swap is on (`free -h`, expect ~1 GB swap visible) |
| `docker run` succeeds but `curl 127.0.0.1:8080` hangs | Container bound to localhost inside the container; check `INTERFACE=0.0.0.0` env var made it through |
| Caddy logs `502 Bad Gateway` | Container not running or bound to a different port — `docker logs ocaml_lob` |
| Caddy stuck on cert issuance | Port 80 not actually open — Let's Encrypt's HTTP-01 challenge needs it; re-check both VCN and iptables |
| Browser loads page but order book stays empty | WebSocket failing — open devtools, check Network → WS for handshake errors. Caddy v2 handles WS automatically; if you're behind another reverse proxy, you may need explicit `Connection: upgrade` headers |

## Caveats

- **Idle reclamation**: Oracle reclaims Always-Free instances that sit idle for 7+ days. SSH in or hit the URL once a week to keep the VM alive.
- **One IP**: the always-free quota gives you one public IP; using more incurs charges.
- **Outbound bandwidth**: 10 TB/month free. A recruiter demo won't come close.
- **Account verification**: Oracle is strict about CC verification. If your card is rejected, try a different one — sometimes prepaid/virtual cards are flagged.
