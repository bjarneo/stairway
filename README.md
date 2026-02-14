# Stairway

A self-hosted ngrok alternative in two bash scripts. One runs on your VPS, the other on your laptop. Traffic flows through SSH tunnels you control.

No accounts. No third-party servers. No monthly fees.

## How It Works

**server.sh** configures your VPS to accept tunnel connections. It enables `GatewayPorts` in sshd, optionally sets up nginx as a reverse proxy, provisions SSL with Let's Encrypt, and opens the right firewall ports.

**stairway.sh** runs on your local machine. It wraps `autossh` to create persistent, auto-reconnecting SSH tunnels that expose your local ports through the VPS.

## Server Setup

SSH into your VPS and run the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/bjarneo/stairway/main/server.sh | sudo bash
```

This runs the minimal setup: enables `GatewayPorts` in sshd and restarts the daemon. Your VPS is now ready to accept tunnels.

### Full Setup with Domain and SSL

```bash
curl -fsSL https://raw.githubusercontent.com/bjarneo/stairway/main/server.sh \
  | sudo bash -s -- -d api.example.com -p 8080
```

This will:

1. Configure sshd with `GatewayPorts yes`
2. Install and configure nginx as a reverse proxy from your domain to the tunnel port
3. Provision a free SSL certificate via Let's Encrypt
4. Open ports 22, 80, 443, and your tunnel port in the firewall

### Server Options

```
sudo ./server.sh                              # sshd only
sudo ./server.sh -d api.example.com           # sshd + nginx + ssl
sudo ./server.sh -d api.example.com -p 9090   # custom tunnel port
sudo ./server.sh -d api.example.com --no-ssl  # skip ssl
sudo ./server.sh --no-firewall                # skip firewall config
```

## Client Setup

Install `autossh` on your local machine:

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

Then install `stairway`:

```bash
curl -fsSL https://raw.githubusercontent.com/bjarneo/stairway/main/stairway.sh -o /tmp/stairway
chmod +x /tmp/stairway

# Verify no existing binary conflicts with the name
if command -v stairway &>/dev/null; then
  echo "Warning: 'stairway' already exists at $(which stairway)"
  echo "Remove it first or choose a different install path."
else
  sudo mv /tmp/stairway /usr/local/bin/stairway
  echo "Installed to /usr/local/bin/stairway"
fi
```

## Usage

### Open a Tunnel

Expose your local port 3000 on the VPS at port 8080:

```bash
stairway connect 8080:3000 user@your-vps-ip
```

The tunnel runs in the background and automatically reconnects if your connection drops.

### Check Active Tunnels

```bash
stairway status
```

```
  ID         STATUS   REMOTE                   LOCAL                PID
  ──────────────────────────────────────────────────────────────────────
  a1b2c3d4   live     root@203.0.113.10:8080   localhost:3000       48291
```

### Disconnect

```bash
stairway disconnect a1b2c3d4   # by tunnel ID
stairway disconnect all        # tear down everything
```

### Clean Up Stale Tunnels

If a tunnel died without cleaning up its PID file:

```bash
stairway clean
```

### Named Flags

You can also use named flags instead of positional arguments:

```bash
stairway connect -r 80 -l 3000 -s deploy@myserver -k ~/.ssh/id_tunnel
```

## What Gets Installed Where

**On the server** (via server.sh):

* Modifies `/etc/ssh/sshd_config` (backup saved as `sshd_config.tunl.bak`)
* Optionally installs nginx and certbot via your system package manager
* Creates an nginx site config at `/etc/nginx/sites-available/<domain>`

**On your machine** (via stairway.sh):

* Tunnel state is stored in `~/.stairway/tunnels/`
* Nothing is installed globally. The script is standalone.

## Security

Opening a port on your VPS means anyone who knows the IP and port can reach your local service. Keep this in mind:

* Use nginx with SSL so traffic is encrypted end to end
* Restrict access with firewall rules if the tunnel is not meant to be public
* Your SSH tunnel itself is always encrypted

## Requirements

* A VPS with a public IP and SSH access
* `autossh` on your local machine
* bash 4+

## License

MIT
