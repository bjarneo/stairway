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
        sed -i '/^[[:space:]]*#\?[[:space:]]*GatewayPorts/d' "$sshd_config"
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

    # Validate inputs
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        die "Invalid domain: ${domain}"
    fi
    if [[ ! "$tunnel_port" =~ ^[0-9]+$ ]] || [[ "$tunnel_port" -lt 1 ]] || [[ "$tunnel_port" -gt 65535 ]]; then
        die "Invalid port: ${tunnel_port}"
    fi

    need_root

    # Guard against port conflict
    if [[ "$tunnel_port" -eq 80 || "$tunnel_port" -eq 443 ]]; then
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

    # Tunnel port is only accessed via localhost (nginx proxy_pass),
    # so no firewall rule is needed — reduces attack surface.

    # SSL via certbot
    if ! command -v certbot &>/dev/null; then
        info "Installing certbot..."
        install_pkg certbot python3-certbot-nginx
    fi

    if certbot certificates -d "$domain" 2>/dev/null | grep -q "Certificate Name: ${domain}"; then
        info "SSL certificate for ${domain} already exists — skipping certbot."
        # Ensure nginx is configured for SSL (certbot may need to update config)
        certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring 2>/dev/null || true
    else
        info "Requesting SSL certificate for ${domain}..."
        if certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email; then
            info "SSL configured. https://${domain} is ready."
        else
            warn "SSL certificate request failed. The tunnel is accessible via HTTP only:"
            warn "  http://${domain}"
            warn "Common causes: DNS not pointed to this server, Let's Encrypt rate limit."
            exit 1
        fi
    fi
}

# ── nginx-remove ──────────────────────────────────────────────
# Removes nginx config and SSL certificate for a domain.
# Usage: server.sh nginx-remove <domain>
cmd_nginx_remove() {
    local domain="${1:-}"

    [[ -z "$domain" ]] && die "Usage: server.sh nginx-remove <domain>"

    # Validate input
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        die "Invalid domain: ${domain}"
    fi

    need_root

    local conf="/etc/nginx/sites-available/${domain}"
    local enabled="/etc/nginx/sites-enabled/${domain}"

    # Remove nginx config
    if [[ -f "$conf" ]] || [[ -L "$enabled" ]]; then
        rm -f "$enabled" "$conf"
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            info "nginx config for ${domain} removed."
        else
            warn "nginx config removed but reload failed — check manually."
        fi
    else
        warn "No nginx config found for ${domain}."
    fi

    # Remove SSL certificate
    if command -v certbot &>/dev/null; then
        if certbot certificates -d "$domain" 2>/dev/null | grep -q "$domain"; then
            certbot delete --cert-name "$domain" --non-interactive 2>/dev/null
            info "SSL certificate for ${domain} removed."
        else
            info "No SSL certificate found for ${domain}."
        fi
    fi

    info "Domain ${domain} cleaned up."
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
    nginx-remove <domain>       Remove nginx config + SSL for a domain

  EXAMPLES
    sudo server.sh setup
    sudo server.sh nginx api.example.com 8080
    sudo server.sh nginx-remove api.example.com

EOF
}

# ── Main ──────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        setup)          cmd_setup "$@" ;;
        nginx)          cmd_nginx "$@" ;;
        nginx-remove)   cmd_nginx_remove "$@" ;;
        help|-h|--help) cmd_help ;;
        *)              die "Unknown command: ${cmd}. Run: server.sh help" ;;
    esac
}

main "$@"
