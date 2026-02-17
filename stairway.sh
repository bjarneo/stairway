#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# stairway — self-hosted ngrok alternative
# Single CLI to set up your server and manage tunnels.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

readonly VERSION="2.0.0"
readonly STATE_DIR="${STAIRWAY_HOME:-$HOME/.stairway}"
readonly TUNNELS_DIR="$STATE_DIR/tunnels"
readonly SERVERS_DIR="$STATE_DIR/servers"
readonly REPO_URL="https://raw.githubusercontent.com/bjarneo/stairway/main"
readonly REMOTE_SCRIPT="/opt/stairway/server.sh"

# ── Colors ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
    CYAN=$'\e[36m' BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

info() { printf "%s\n" "${GREEN}▸${RESET} $*" >&2; }
warn() { printf "%s\n" "${YELLOW}▸${RESET} $*" >&2; }
err()  { printf "%s\n" "${RED}✖${RESET} $*" >&2; }
die()  { err "$@"; exit 1; }

ensure_dirs() { mkdir -p "$TUNNELS_DIR" "$SERVERS_DIR"; }

# ── Input validation ──────────────────────────────────────────
_validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        die "Invalid domain: ${domain}"
    fi
}

_validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        die "Invalid port: ${port}"
    fi
}

_validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Invalid server name: ${name}. Use only alphanumeric characters, hyphens, and underscores."
    fi
}

# ── Dependency check ──────────────────────────────────────────
check_autossh() {
    command -v autossh &>/dev/null && return

    err "autossh is not installed."
    echo ""
    echo "  Install it:"
    echo "    ${DIM}macOS:${RESET}         brew install autossh"
    echo "    ${DIM}Debian/Ubuntu:${RESET}  sudo apt install autossh"
    echo "    ${DIM}Arch:${RESET}          sudo pacman -S autossh"
    echo "    ${DIM}Fedora:${RESET}        sudo dnf install autossh"
    echo ""
    exit 1
}

# ── Server config helpers ─────────────────────────────────────
_load_server() {
    local name="$1"
    _validate_name "$name"
    local conf="$SERVERS_DIR/${name}.conf"

    if [[ ! -f "$conf" ]]; then
        die "Server '${name}' not found. Run: stairway init -s user@host"
    fi

    _srv_host=$(grep '^HOST=' "$conf" | cut -d= -f2- | head -n1)
    _srv_key=$(grep '^SSH_KEY=' "$conf" | cut -d= -f2- | head -n1)

    if [[ -z "$_srv_host" ]]; then die "Invalid config: HOST not set in ${conf}"; fi
}

# ── Find server.sh locally ────────────────────────────────────
_find_server_script() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$script_dir/server.sh" ]]; then
        echo "$script_dir/server.sh"
    elif [[ -f "$STATE_DIR/server.sh" ]]; then
        echo "$STATE_DIR/server.sh"
    else
        mkdir -p "$STATE_DIR"
        info "Downloading server.sh..."
        curl -fsSL "${REPO_URL}/server.sh" -o "$STATE_DIR/server.sh"
        chmod +x "$STATE_DIR/server.sh"
        echo "$STATE_DIR/server.sh"
    fi
}

# ── Safe meta file reader ─────────────────────────────────────
_read_meta() {
    local file="$1"
    TUNNEL_ID=$(grep '^TUNNEL_ID=' "$file" | cut -d= -f2- | head -n1)
    REMOTE_PORT=$(grep '^REMOTE_PORT=' "$file" | cut -d= -f2- | head -n1)
    LOCAL_PORT=$(grep '^LOCAL_PORT=' "$file" | cut -d= -f2- | head -n1)
    LOCAL_HOST=$(grep '^LOCAL_HOST=' "$file" | cut -d= -f2- | head -n1)
    SSH_HOST=$(grep '^SSH_HOST=' "$file" | cut -d= -f2- | head -n1)
    DOMAIN=$(grep '^DOMAIN=' "$file" | cut -d= -f2- | head -n1)
    PID=$(grep '^PID=' "$file" | cut -d= -f2- | head -n1)
    SERVER=$(grep '^SERVER=' "$file" | cut -d= -f2- | head -n1)
    STARTED=$(grep '^STARTED=' "$file" | cut -d= -f2- | head -n1)
}

# ── Auto port assignment ──────────────────────────────────────
_next_port() {
    local port=10000
    local used=()

    for meta in "$TUNNELS_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue
        local REMOTE_PORT=""
        _read_meta "$meta"
        if [[ -n "$REMOTE_PORT" ]]; then used+=("$REMOTE_PORT"); fi
    done

    if [[ ${#used[@]} -gt 0 ]]; then
        while printf '%s\n' "${used[@]}" | grep -qx "$port"; do
            port=$((port + 1))
        done
    fi

    echo "$port"
}

# ── Replace existing tunnel by domain or endpoint ─────────────
_replace_existing() {
    local host="$1" port="$2" domain="$3"

    for meta in "$TUNNELS_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue

        local TUNNEL_ID="" REMOTE_PORT="" LOCAL_PORT="" LOCAL_HOST="" SSH_HOST="" DOMAIN="" PID="" SERVER="" STARTED=""
        _read_meta "$meta"

        local match=false

        # Match by domain
        if [[ -n "$domain" && "$DOMAIN" == "$domain" ]]; then
            match=true
        fi

        # Match by host:port (only when port is explicitly set)
        if [[ -n "$port" && "$SSH_HOST" == "$host" && "$REMOTE_PORT" == "$port" ]]; then
            match=true
        fi

        if $match; then
            info "Replacing existing tunnel ${BOLD}${TUNNEL_ID}${RESET}..."
            _kill_tunnel "$TUNNEL_ID" 2>/dev/null || rm -f "$TUNNELS_DIR/${TUNNEL_ID}.pid" "$meta"
        fi
    done
}

# ── Tunnel ID ─────────────────────────────────────────────────
_tunnel_id() {
    printf "%s" "$1-$2" | md5sum 2>/dev/null | cut -c1-8 \
        || printf "%s" "$1-$2" | md5 2>/dev/null | cut -c1-8
}

# ══════════════════════════════════════════════════════════════
# Commands
# ══════════════════════════════════════════════════════════════

# ── init ──────────────────────────────────────────────────────
cmd_init() {
    local host="" ssh_key="" name="default"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) host="$2"; shift 2 ;;
            -k|--key)    ssh_key="$2"; shift 2 ;;
            -n|--name)   name="$2"; shift 2 ;;
            -*)          die "Unknown option: $1" ;;
            *)           [[ -z "$host" ]] && host="$1" && shift || die "Unexpected: $1" ;;
        esac
    done

    if [[ -z "$host" ]]; then die "Usage: stairway init -s user@host"; fi

    _validate_name "$name"
    ensure_dirs

    # Save server config
    cat > "$SERVERS_DIR/${name}.conf" <<EOF
HOST=${host}
SSH_KEY=${ssh_key}
EOF
    info "Server '${name}' saved."

    # Find server.sh
    local script
    script=$(_find_server_script)

    info "Installing server component on ${BOLD}${host}${RESET}..."

    local scp_args=(-o "StrictHostKeyChecking=accept-new")
    local ssh_args=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")
    if [[ -n "$ssh_key" ]]; then scp_args+=(-i "$ssh_key"); ssh_args+=(-i "$ssh_key"); fi

    # Upload and install
    scp "${scp_args[@]}" "$script" "${host}:/tmp/stairway-server.sh"
    ssh "${ssh_args[@]}" "$host" \
        "sudo mkdir -p /opt/stairway && sudo mv /tmp/stairway-server.sh ${REMOTE_SCRIPT} && sudo chmod +x ${REMOTE_SCRIPT} && sudo ${REMOTE_SCRIPT} setup"

    echo ""
    info "${GREEN}Server '${name}' is ready!${RESET}"
    echo ""
    echo "  Now expose a local port:"
    echo "    ${DIM}stairway up 3000${RESET}"
    echo ""
    echo "  Or with a custom domain:"
    echo "    ${DIM}stairway up 3000 -d api.example.com${RESET}"
    echo ""
}

# ── update ────────────────────────────────────────────────────
cmd_update() {
    local name="default"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)         die "Unexpected argument: $1" ;;
        esac
    done

    ensure_dirs

    # Update local stairway binary
    local self_path
    self_path="$(command -v stairway 2>/dev/null || true)"

    if [[ -n "$self_path" && -w "$self_path" ]]; then
        info "Updating stairway..."
        curl -fsSL "${REPO_URL}/stairway.sh" -o "${self_path}.tmp"
        chmod +x "${self_path}.tmp"
        mv "${self_path}.tmp" "$self_path"
        info "stairway updated."
    elif [[ -n "$self_path" ]]; then
        info "Updating stairway (requires sudo)..."
        curl -fsSL "${REPO_URL}/stairway.sh" -o /tmp/stairway-update
        chmod +x /tmp/stairway-update
        sudo mv /tmp/stairway-update "$self_path"
        info "stairway updated."
    else
        warn "Could not find stairway in PATH — skipping self-update."
    fi

    # Update cached server.sh
    info "Downloading latest server.sh..."
    mkdir -p "$STATE_DIR"
    curl -fsSL "${REPO_URL}/server.sh" -o "$STATE_DIR/server.sh"
    chmod +x "$STATE_DIR/server.sh"

    # Upload to server if configured
    if [[ -f "$SERVERS_DIR/${name}.conf" ]]; then
        _load_server "$name"

        info "Uploading server.sh to ${BOLD}${_srv_host}${RESET}..."

        local scp_args=(-o "StrictHostKeyChecking=accept-new")
        if [[ -n "$_srv_key" ]]; then scp_args+=(-i "$_srv_key"); fi

        scp "${scp_args[@]}" "$STATE_DIR/server.sh" "${_srv_host}:/tmp/stairway-server.sh"

        local ssh_args=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")
        if [[ -n "$_srv_key" ]]; then ssh_args+=(-i "$_srv_key"); fi

        ssh "${ssh_args[@]}" "$_srv_host" \
            "sudo mv /tmp/stairway-server.sh ${REMOTE_SCRIPT} && sudo chmod +x ${REMOTE_SCRIPT}"

        info "Server component updated."
    else
        warn "No server '${name}' configured — skipping remote update."
    fi

    echo ""
    info "Update complete."
    echo ""
}

# ── up ────────────────────────────────────────────────────────
cmd_up() {
    local local_port="" domain="" remote_port="" name="default"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) domain="$2"; shift 2 ;;
            -p|--port)   remote_port="$2"; shift 2 ;;
            -n|--name)   name="$2"; shift 2 ;;
            -*)          die "Unknown option: $1" ;;
            *)
                if [[ -z "$local_port" ]]; then
                    local_port="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [[ -z "$local_port" ]]; then die "Usage: stairway up <local_port> [-d domain] [-p remote_port]"; fi

    _validate_port "$local_port"
    if [[ -n "$remote_port" ]]; then _validate_port "$remote_port"; fi
    if [[ -n "$domain" ]]; then _validate_domain "$domain"; fi

    check_autossh
    ensure_dirs

    _load_server "$name"

    # Replace any existing tunnel using the same domain or endpoint
    _replace_existing "$_srv_host" "$remote_port" "$domain"

    # Auto-assign remote port (after cleanup so freed ports can be reused)
    if [[ -z "$remote_port" ]]; then
        remote_port=$(_next_port)
    fi

    # Set up domain remotely if requested
    if [[ -n "$domain" ]]; then
        info "Configuring ${BOLD}${domain}${RESET} on server..."
        local ssh_args=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")
        if [[ -n "$_srv_key" ]]; then ssh_args+=(-i "$_srv_key"); fi
        ssh "${ssh_args[@]}" "$_srv_host" sudo "${REMOTE_SCRIPT}" nginx "${domain}" "${remote_port}"
    fi

    # Check for existing tunnel with same ID (same host:port combo)
    local id
    id=$(_tunnel_id "$remote_port" "$_srv_host")
    local pid_file="$TUNNELS_DIR/${id}.pid"
    local meta_file="$TUNNELS_DIR/${id}.meta"

    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            warn "Tunnel ${BOLD}${id}${RESET} already running (PID ${old_pid})."
            warn "Run ${BOLD}stairway down ${id}${RESET} first."
            return 1
        fi
        rm -f "$pid_file" "$meta_file"
    fi

    # Build SSH options
    local ssh_opts=(
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "ExitOnForwardFailure=yes"
        -o "StrictHostKeyChecking=accept-new"
    )
    if [[ -n "$_srv_key" ]]; then ssh_opts+=(-i "$_srv_key"); fi

    echo ""
    info "Opening tunnel ${BOLD}${id}${RESET}"
    echo "  ${DIM}Remote:${RESET} ${_srv_host}:${remote_port}"
    echo "  ${DIM}Local:${RESET}  localhost:${local_port}"
    echo ""

    export AUTOSSH_PIDFILE="$pid_file"
    export AUTOSSH_GATETIME=0

    autossh -M 0 -f -N \
        "${ssh_opts[@]}" \
        -R "0.0.0.0:${remote_port}:localhost:${local_port}" \
        "$_srv_host"

    # Wait for PID file
    local retries=15
    while [[ ! -f "$pid_file" && $retries -gt 0 ]]; do
        sleep 0.2
        retries=$((retries - 1))
    done

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")

        cat > "$meta_file" <<EOF
TUNNEL_ID=${id}
REMOTE_PORT=${remote_port}
LOCAL_PORT=${local_port}
LOCAL_HOST=localhost
SSH_HOST=${_srv_host}
DOMAIN=${domain}
PID=${pid}
SERVER=${name}
STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
        info "${GREEN}Tunnel is live!${RESET} (PID ${pid})"
        echo ""
        if [[ -n "$domain" ]]; then
            echo "  ${BOLD}→ https://${domain}${RESET}"
        else
            echo "  ${BOLD}→ http://${_srv_host}:${remote_port}${RESET}"
        fi
        echo ""
    else
        die "Failed to start tunnel — check SSH connectivity to ${_srv_host}"
    fi
}

# ── domain ────────────────────────────────────────────────────
cmd_domain() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        rm|remove) cmd_domain_remove "$@" ;;
        *)
            err "Usage: stairway domain rm <domain> [-n server_name]"
            exit 1
            ;;
    esac
}

cmd_domain_remove() {
    local domain="" name="default"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) name="$2"; shift 2 ;;
            -*)        die "Unknown option: $1" ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [[ -z "$domain" ]]; then die "Usage: stairway domain rm <domain>"; fi

    _validate_domain "$domain"
    ensure_dirs
    _load_server "$name"

    # Kill any active tunnel using this domain
    for meta in "$TUNNELS_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue

        local TUNNEL_ID="" REMOTE_PORT="" LOCAL_PORT="" LOCAL_HOST="" SSH_HOST="" DOMAIN="" PID="" SERVER="" STARTED=""
        _read_meta "$meta"

        if [[ "$DOMAIN" == "$domain" ]]; then
            info "Stopping tunnel ${BOLD}${TUNNEL_ID}${RESET}..."
            _kill_tunnel "$TUNNEL_ID" 2>/dev/null || rm -f "$TUNNELS_DIR/${TUNNEL_ID}.pid" "$meta"
        fi
    done

    # Remove nginx + SSL on server
    info "Removing ${BOLD}${domain}${RESET} from server..."
    local ssh_args=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10")
    if [[ -n "$_srv_key" ]]; then ssh_args+=(-i "$_srv_key"); fi
    ssh "${ssh_args[@]}" "$_srv_host" sudo "${REMOTE_SCRIPT}" nginx-remove "${domain}"

    echo ""
    info "${domain} removed."
    echo ""
}

# ── down ──────────────────────────────────────────────────────
cmd_down() {
    ensure_dirs
    local target="${1:-}"

    if [[ -z "$target" ]]; then die "Usage: stairway down <id|all>"; fi

    if [[ "$target" == "all" ]]; then
        local count=0
        for pid_file in "$TUNNELS_DIR"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local id
            id=$(basename "$pid_file" .pid)
            _kill_tunnel "$id" && count=$((count + 1))
        done
        if [[ $count -eq 0 ]]; then warn "No active tunnels."; else info "Disconnected ${count} tunnel(s)."; fi
        return
    fi

    _kill_tunnel "$target"
}

_kill_tunnel() {
    local id="$1"
    local pid_file="$TUNNELS_DIR/${id}.pid"
    local meta_file="$TUNNELS_DIR/${id}.meta"

    if [[ ! -f "$pid_file" ]]; then
        err "No tunnel found with ID ${BOLD}${id}${RESET}"
        return 1
    fi

    local pid
    pid=$(cat "$pid_file")

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        local retries=10
        while kill -0 "$pid" 2>/dev/null && [[ $retries -gt 0 ]]; do
            sleep 0.2
            retries=$((retries - 1))
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        info "Disconnected tunnel ${BOLD}${id}${RESET} (PID ${pid})"
    else
        warn "Tunnel ${BOLD}${id}${RESET} was not running (stale PID)."
    fi

    rm -f "$pid_file" "$meta_file"
}

# ── status ────────────────────────────────────────────────────
cmd_status() {
    ensure_dirs
    local found=0

    echo ""
    printf "${BOLD}  %-10s %-8s %-26s %-20s %s${RESET}\n" "ID" "STATUS" "ENDPOINT" "LOCAL" "PID"
    printf "  ${DIM}──────────────────────────────────────────────────────────────────────────${RESET}\n"

    for meta_file in "$TUNNELS_DIR"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        found=1

        local TUNNEL_ID="" REMOTE_PORT="" LOCAL_PORT="" LOCAL_HOST="" SSH_HOST="" PID="" DOMAIN="" SERVER="" STARTED=""
        _read_meta "$meta_file"

        local status="${RED}dead${RESET}"
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            status="${GREEN}live${RESET}"
        fi

        local endpoint
        if [[ -n "$DOMAIN" ]]; then
            endpoint="https://${DOMAIN}"
        else
            endpoint="${SSH_HOST}:${REMOTE_PORT}"
        fi

        printf "  %-10s %-17s %-26s %-20s %s\n" \
            "$TUNNEL_ID" \
            "$status" \
            "$endpoint" \
            "localhost:${LOCAL_PORT}" \
            "$PID"
    done

    if [[ $found -eq 0 ]]; then echo "  ${DIM}No active tunnels.${RESET}"; fi
    echo ""
}

# ── clean ─────────────────────────────────────────────────────
cmd_clean() {
    ensure_dirs
    local count=0

    for pid_file in "$TUNNELS_DIR"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        local pid
        pid=$(cat "$pid_file")
        if ! kill -0 "$pid" 2>/dev/null; then
            local id
            id=$(basename "$pid_file" .pid)
            rm -f "$pid_file" "$TUNNELS_DIR/${id}.meta"
            count=$((count + 1))
        fi
    done

    info "Cleaned ${count} stale tunnel(s)."
}

# ── help ──────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF

  ${BOLD}${CYAN}stairway${RESET} ${DIM}v${VERSION}${RESET} — self-hosted ngrok alternative

  ${BOLD}USAGE${RESET}
    stairway <command> [options]

  ${BOLD}COMMANDS${RESET}
    init     ${DIM}-s <user@host>${RESET}             Set up a new server
    update                                Re-upload server.sh to the server
    up       ${DIM}<local_port>${RESET}                Expose a local port
    down     ${DIM}<id|all>${RESET}                    Close tunnel(s)
    domain rm ${DIM}<domain>${RESET}               Remove a domain from the server
    status                                List active tunnels
    clean                                 Remove stale entries

  ${BOLD}INIT OPTIONS${RESET}
    -s, --server ${DIM}<user@host>${RESET}    SSH destination (required)
    -k, --key    ${DIM}<path>${RESET}         SSH private key
    -n, --name   ${DIM}<name>${RESET}         Server name ${DIM}(default: "default")${RESET}

  ${BOLD}UP OPTIONS${RESET}
    -d, --domain ${DIM}<domain>${RESET}       Set up nginx + SSL and tunnel through it
    -p, --port   ${DIM}<port>${RESET}         Remote port ${DIM}(default: auto-assigned)${RESET}
    -n, --name   ${DIM}<name>${RESET}         Which server to use ${DIM}(default: "default")${RESET}

  ${BOLD}EXAMPLES${RESET}
    ${DIM}# One-time server setup${RESET}
    stairway init -s root@203.0.113.10

    ${DIM}# Expose local port 3000${RESET}
    stairway up 3000

    ${DIM}# Expose with a custom domain (sets up nginx + SSL automatically)${RESET}
    stairway up 3000 -d api.example.com

    ${DIM}# Use a named server${RESET}
    stairway init -s root@staging.example.com -n staging
    stairway up 3000 -n staging

    ${DIM}# Check tunnels${RESET}
    stairway status

    ${DIM}# Remove a domain${RESET}
    stairway domain rm api.example.com

    ${DIM}# Tear down${RESET}
    stairway down all

EOF
}

# ── Main ──────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init|i)         cmd_init "$@" ;;
        update)         cmd_update "$@" ;;
        up|u)           cmd_up "$@" ;;
        down|d)         cmd_down "$@" ;;
        domain)         cmd_domain "$@" ;;
        status|s|ls)    cmd_status "$@" ;;
        clean)          cmd_clean "$@" ;;
        version|-v)     echo "stairway v${VERSION}" ;;
        help|-h|--help) cmd_help ;;
        *)
            err "Unknown command: ${cmd}"
            echo "  Run ${BOLD}stairway help${RESET} for usage."
            exit 1
            ;;
    esac
}

main "$@"
