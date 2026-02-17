# Stairway

A self-hosted ngrok alternative in bash. One CLI to set up your server and expose local ports to the internet.

No accounts. No third-party servers. No monthly fees.

## How It Works

Stairway uses SSH remote port forwarding to tunnel traffic from a public VPS to your local machine. It wraps `autossh` for automatic reconnection and manages nginx + Let's Encrypt on the server side, all from a single command on your laptop.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bjarneo/stairway/main/stairway.sh -o /tmp/stairway
chmod +x /tmp/stairway

if command -v stairway &>/dev/null; then
  echo "Warning: 'stairway' already exists at $(which stairway)"
  echo "Remove it first or choose a different install path."
else
  sudo mv /tmp/stairway /usr/local/bin/stairway
  echo "Installed to /usr/local/bin/stairway"
fi
```

Stairway requires `autossh` on your local machine:

```bash
# macOS
brew install autossh

# Debian / Ubuntu
sudo apt install autossh

# Arch
sudo pacman -S autossh

# Fedora
sudo dnf install autossh
```

## Quick Start

### 1. Point stairway at your VPS

```bash
stairway init -s root@203.0.113.10
```

This SSHes into your server, configures `GatewayPorts` in sshd, sets up firewall rules, and saves the connection details locally. You only run this once.

### 2. Expose a local port

```bash
stairway up 3000
```

That's it. Stairway auto-assigns a remote port and prints the public URL.

### 3. Expose with a custom domain

```bash
stairway up 3000 -d api.example.com
```

This automatically installs nginx on your VPS, configures a reverse proxy, provisions an SSL certificate via Let's Encrypt, and opens the tunnel. Point your domain's A record to your VPS IP beforehand.

## Usage

### Init a server

```bash
stairway init -s root@203.0.113.10
stairway init -s deploy@myserver -k ~/.ssh/id_tunnel
stairway init -s root@staging.example.com -n staging
```

### Open a tunnel

```bash
stairway up 3000                             # auto-assign remote port
stairway up 3000 -d api.example.com          # with domain + SSL
stairway up 8080 -p 9090                     # explicit remote port
stairway up 3000 -n staging                  # use a named server
```

Running `up` again with the same domain or endpoint automatically replaces the previous tunnel. No need to manually `down` first.

### Check active tunnels

```bash
stairway status
```

```
  ID         STATUS   SERVER       ENDPOINT                   LOCAL                PID
  ────────────────────────────────────────────────────────────────────────────────────
  a1b2c3d4   live     production   https://api.example.com    localhost:3000       48291
  e5f6g7h8   live     staging      203.0.113.10:10001         localhost:8080       48305
```

### Disconnect

```bash
stairway down a1b2c3d4   # by tunnel ID (or partial: stairway down a1b)
stairway down all        # tear down everything
```

### Remove a domain

This stops any active tunnel for the domain and removes the nginx config and SSL certificate from the server:

```bash
stairway domain rm api.example.com
```

### List configured servers

```bash
stairway servers
```

### Clean up stale entries

```bash
stairway clean
```

## Update

Update both the local stairway binary and the server component in one command:

```bash
stairway update
```

This downloads the latest version from GitHub, replaces the installed binary (requires sudo), and uploads the new server.sh to your VPS.

## Multiple Servers

Name your servers during init and reference them with `--name`:

```bash
stairway init -s root@203.0.113.10 -n production
stairway init -s root@10.0.0.50 -n staging

stairway up 3000 -n production -d api.example.com
stairway up 3000 -n staging
```

The first server you init becomes the default. All commands use it unless you pass `--name`.

## What Gets Installed Where

**On your VPS** (during `stairway init` and `stairway up -d`):

* Server script installed at `/opt/stairway/server.sh`
* sshd config modified with `GatewayPorts yes` (backup at `sshd_config.stairway.bak`)
* nginx site configs at `/etc/nginx/sites-available/<domain>` (only when using `--domain`)
* SSL certificates managed by certbot (only when using `--domain`)

**On your machine**:

* Config and tunnel state stored in `~/.stairway/`
* Nothing is installed globally beyond the `stairway` binary itself

## Security

Opening a tunnel means traffic can reach your local service. Keep this in mind:

* Use `--domain` so traffic goes through nginx with SSL encryption
* Restrict access with firewall rules on the VPS if the tunnel should not be public
* The SSH tunnel itself is always encrypted

## Requirements

* A VPS with a public IP and SSH access
* `autossh` on your local machine
* bash 4+

## License

MIT
