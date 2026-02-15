#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# server.sh — VPS-side component for Stairway
# Installed and managed remotely by the stairway client.
# Can also be run standalone on the server.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
    BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" BOLD="" DIM="" RESET=""
fi

info() { printf "%s\n" "${GREEN}▸${RESET} $*"; }
warn() { printf "%s\n" "${YELLOW}▸${RESET} $*" >&2; }
die()  { printf "%s\n" "${RED}✖${RESET} $*" >&2; exit 1; }

need_root() {
    [[ $EUID -eq 0 ]] || die "This command requires root. Use sudo."
}

# ── Package manager abstraction ───────────────────────────────
install_pkg() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$@"
    elif command -v yum &>/dev/null; then
        yum install -y -q "$@"
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "$@"
    else
        die "Unsupported package manager. Install manually: $*"
    fi
}

# ── setup ─────────────────────────────────────────────────────
# Configures sshd for tunnel forwarding and opens base firewall
# ports. Run once during stairway init.
cmd_setup() {
    need_root

    info "Configuring SSH daemon..."

    local sshd_config="/etc/ssh/sshd_config"
    [[ -f "$sshd_config" ]] || die "$sshd_config not found."

    # Back up original
    if [[ ! -f "${sshd_config}.stairway.bak" ]]; then
        cp "$sshd_config" "${sshd_config}.stairway.bak"
        info "Backup saved to ${sshd_config}.stairway.bak"
    fi

    # Enable GatewayPorts
    if grep -qE '^\s*GatewayPorts\s+yes' "$sshd_config"; then
        info "GatewayPorts already enabled."
    else
        sed -i '/^#\?GatewayPorts/d' "$sshd_config"
        echo "GatewayPorts yes" >> "$sshd_config"
        info "GatewayPorts enabled."
    fi

    # Restart sshd
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        info "SSH daemon restarted."
    else
        warn "Could not restart SSH daemon — do it manually."
    fi

    # Base firewall rules
    if command -v ufw &>/dev/null; then
        info "Configuring UFW firewall..."
        ufw allow 22/tcp  >/dev/null 2>&1
        ufw allow 80/tcp  >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        info "UFW: ports 22, 80, 443 opened."
    elif command -v firewall-cmd &>/dev/null; then
        info "Configuring firewalld..."
        firewall-cmd --permanent --add-port=22/tcp  >/dev/null 2>&1
        firewall-cmd --permanent --add-port=80/tcp  >/dev/null 2>&1
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld: ports 22, 80, 443 opened."
    else
        warn "No firewall manager found. Ensure ports 22, 80, 443 are open."
    fi

    info "Server is ready for tunnels."
}

# ── nginx ─────────────────────────────────────────────────────
# Sets up nginx reverse proxy + Let's Encrypt SSL for a domain.
# Usage: server.sh nginx <domain> <tunnel_port>
cmd_nginx() {
    local domain="${1:-}"
    local tunnel_port="${2:-}"

    [[ -z "$domain" ]]      && die "Usage: server.sh nginx <domain> <tunnel_port>"
    [[ -z "$tunnel_port" ]] && die "Usage: server.sh nginx <domain> <tunnel_port>"

    need_root

    # Guard against port conflict
    if [[ "$tunnel_port" == "80" || "$tunnel_port" == "443" ]]; then
        die "Tunnel port ${tunnel_port} conflicts with nginx. Use a port above 1024."
    fi

    # Install nginx
    if ! command -v nginx &>/dev/null; then
        info "Installing nginx..."
        install_pkg nginx
    fi

    local conf="/etc/nginx/sites-available/${domain}"
    local enabled="/etc/nginx/sites-enabled/${domain}"

    info "Configuring nginx: ${domain} → 127.0.0.1:${tunnel_port}"

    cat > "$conf" <<NGINX
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${tunnel_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
NGINX

    mkdir -p /etc/nginx/sites-enabled
    ln -sf "$conf" "$enabled"
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        info "nginx configured and reloaded."
    else
        die "nginx config test failed — check ${conf}"
    fi

    # Open tunnel port in firewall
    if command -v ufw &>/dev/null; then
        ufw allow "${tunnel_port}/tcp" >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${tunnel_port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # SSL via certbot
    if ! command -v certbot &>/dev/null; then
        info "Installing certbot..."
        install_pkg certbot python3-certbot-nginx
    fi

    info "Requesting SSL certificate for ${domain}..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email

    info "SSL configured. https://${domain} is ready."
}

# ── help ──────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF

  server.sh — VPS-side component for Stairway

  USAGE
    sudo server.sh <command> [args]

  COMMANDS
    setup                       Configure sshd + firewall for tunneling
    nginx <domain> <port>       Set up nginx reverse proxy + SSL

  EXAMPLES
    sudo server.sh setup
    sudo server.sh nginx api.example.com 8080

EOF
}

# ── Main ──────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        setup)          cmd_setup "$@" ;;
        nginx)          cmd_nginx "$@" ;;
        help|-h|--help) cmd_help ;;
        *)              die "Unknown command: ${cmd}. Run: server.sh help" ;;
    esac
}

main "$@"
