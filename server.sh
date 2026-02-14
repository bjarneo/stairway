#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# server.sh — VPS setup for SSH tunnel ingress
# Run this on your public-facing server (once).
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
    [[ $EUID -eq 0 ]] || die "Run this script as root (or with sudo)."
}

# ── Detect package manager ────────────────────────────────────
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

# ── 1. Configure SSHD ────────────────────────────────────────
setup_sshd() {
    info "Configuring SSH daemon..."

    local sshd_config="/etc/ssh/sshd_config"
    [[ -f "$sshd_config" ]] || die "$sshd_config not found."

    # Back up original
    if [[ ! -f "${sshd_config}.tunl.bak" ]]; then
        cp "$sshd_config" "${sshd_config}.tunl.bak"
        info "Backup saved to ${sshd_config}.tunl.bak"
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
}

# ── 2. Install & configure Nginx ─────────────────────────────
setup_nginx() {
    local domain="$1"
    local tunnel_port="$2"

    if ! command -v nginx &>/dev/null; then
        info "Installing nginx..."
        install_pkg nginx
    else
        info "nginx is already installed."
    fi

    local conf="/etc/nginx/sites-available/${domain}"
    local enabled="/etc/nginx/sites-enabled/${domain}"

    info "Writing nginx config for ${BOLD}${domain}${RESET} → 127.0.0.1:${tunnel_port}"

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

    # Ensure sites-enabled directory exists
    mkdir -p /etc/nginx/sites-enabled

    ln -sf "$conf" "$enabled"

    # Remove default site if it exists (avoids conflicts on port 80)
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        info "nginx configured and reloaded."
    else
        die "nginx config test failed — check ${conf}"
    fi
}

# ── 3. SSL with Let's Encrypt ─────────────────────────────────
setup_ssl() {
    local domain="$1"

    if ! command -v certbot &>/dev/null; then
        info "Installing certbot..."
        install_pkg certbot python3-certbot-nginx
    else
        info "certbot is already installed."
    fi

    info "Requesting SSL certificate for ${BOLD}${domain}${RESET}..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email

    info "SSL configured. Auto-renewal is enabled by default."
}

# ── 4. Firewall ───────────────────────────────────────────────
setup_firewall() {
    local tunnel_port="$1"

    if command -v ufw &>/dev/null; then
        info "Configuring UFW firewall..."
        ufw allow 22/tcp   >/dev/null 2>&1
        ufw allow 80/tcp   >/dev/null 2>&1
        ufw allow 443/tcp  >/dev/null 2>&1
        ufw allow "${tunnel_port}/tcp" >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        info "UFW: ports 22, 80, 443, ${tunnel_port} opened."
    elif command -v firewall-cmd &>/dev/null; then
        info "Configuring firewalld..."
        firewall-cmd --permanent --add-port=80/tcp   >/dev/null 2>&1
        firewall-cmd --permanent --add-port=443/tcp  >/dev/null 2>&1
        firewall-cmd --permanent --add-port="${tunnel_port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld: ports 80, 443, ${tunnel_port} opened."
    else
        warn "No firewall manager found. Ensure ports 80, 443, and ${tunnel_port} are open."
    fi
}

# ── Usage ─────────────────────────────────────────────────────
usage() {
    cat <<EOF

${BOLD}server.sh${RESET} — VPS setup for SSH tunnel ingress

${BOLD}USAGE${RESET}
  sudo ./server.sh [options]

${BOLD}OPTIONS${RESET}
  -d, --domain  <domain>    Domain name for nginx + SSL  ${DIM}(optional)${RESET}
  -p, --port    <port>      Tunnel port on this server   ${DIM}(default: 8080)${RESET}
      --no-nginx             Skip nginx setup
      --no-ssl               Skip SSL setup
      --no-firewall          Skip firewall setup
  -h, --help                 Show this help

${BOLD}EXAMPLES${RESET}
  ${DIM}# Minimal — just configure sshd${RESET}
  sudo ./server.sh

  ${DIM}# Full setup with domain and SSL${RESET}
  sudo ./server.sh -d api.example.com -p 8080

  ${DIM}# SSH + nginx, no SSL${RESET}
  sudo ./server.sh -d api.example.com --no-ssl

EOF
}

# ── Main ──────────────────────────────────────────────────────
main() {
    local domain="" tunnel_port="8080"
    local do_nginx=true do_ssl=true do_firewall=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)     domain="$2"; shift 2 ;;
            -p|--port)       tunnel_port="$2"; shift 2 ;;
            --no-nginx)      do_nginx=false; shift ;;
            --no-ssl)        do_ssl=false; shift ;;
            --no-firewall)   do_firewall=false; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown option: $1" ;;
        esac
    done

    need_root

    # Guard against port conflicts with nginx
    if [[ "$tunnel_port" == "80" || "$tunnel_port" == "443" ]] && $do_nginx && [[ -n "$domain" ]]; then
        die "Tunnel port ${tunnel_port} conflicts with nginx (which needs 80/443).\n  Use a different port, e.g.: --port 8080"
    fi

    echo ""
    echo "  ${BOLD}Server Setup${RESET}"
    echo "  ${DIM}────────────────────────────────${RESET}"
    echo ""

    # Always configure sshd
    setup_sshd

    # Firewall
    if $do_firewall; then
        setup_firewall "$tunnel_port"
    fi

    # Nginx requires a domain
    if $do_nginx && [[ -n "$domain" ]]; then
        setup_nginx "$domain" "$tunnel_port"
    elif $do_nginx && [[ -z "$domain" ]]; then
        info "Skipping nginx (no --domain provided)."
    fi

    # SSL requires nginx + domain
    if $do_ssl && [[ -n "$domain" ]] && $do_nginx; then
        setup_ssl "$domain"
    elif $do_ssl && [[ -z "$domain" ]]; then
        info "Skipping SSL (no --domain provided)."
    fi

    echo ""
    info "${GREEN}Server is ready!${RESET}"
    echo ""
    echo "  Tunnel port: ${BOLD}${tunnel_port}${RESET}"
    [[ -n "$domain" ]] && echo "  Domain:      ${BOLD}${domain}${RESET}"
    echo ""
    echo "  From your local machine, run:"
    echo "    ${DIM}./stairway.sh connect ${tunnel_port}:<local_port> user@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<this-ip>')${RESET}"
    echo ""
}

main "$@"
