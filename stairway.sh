#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# stairway.sh — local tunnel client (self-hosted ngrok)
# Run this on your local machine to expose local ports.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

readonly VERSION="1.0.0"
readonly STATE_DIR="${STAIRWAY_HOME:-$HOME/.stairway}"
readonly TUNNELS_DIR="$STATE_DIR/tunnels"

# ── Colors ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
    CYAN=$'\e[36m' BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

info() { printf "%s\n" "${GREEN}▸${RESET} $*"; }
warn() { printf "%s\n" "${YELLOW}▸${RESET} $*" >&2; }
err()  { printf "%s\n" "${RED}✖${RESET} $*" >&2; }
die()  { err "$@"; exit 1; }

ensure_dirs() { mkdir -p "$TUNNELS_DIR"; }

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

# ── Tunnel ID (deterministic hash) ───────────────────────────
tunnel_id() {
    printf "%s" "$1-$2" | md5sum 2>/dev/null | cut -c1-8 \
        || printf "%s" "$1-$2" | md5 2>/dev/null | cut -c1-8
}

# ── Connect ───────────────────────────────────────────────────
cmd_connect() {
    local remote_port="" local_port="" local_host="localhost"
    local host="" ssh_key="" bind_addr="0.0.0.0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--remote)    remote_port="$2"; shift 2 ;;
            -l|--local)     local_port="$2"; shift 2 ;;
            -s|--server)    host="$2"; shift 2 ;;
            -k|--key)       ssh_key="$2"; shift 2 ;;
            -b|--bind)      local_host="$2"; shift 2 ;;
            --bind-remote)  bind_addr="$2"; shift 2 ;;
            -*)             die "Unknown option: $1" ;;
            *)
                # Positional: REMOTE:LOCAL USER@HOST
                if [[ -z "$remote_port" && "$1" == *:* ]]; then
                    remote_port="${1%%:*}"
                    local_port="${1##*:}"
                    shift
                elif [[ -z "$host" ]]; then
                    host="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$remote_port" ]] && die "Missing remote port.\n  Usage: stairway connect 8080:3000 user@host"
    [[ -z "$local_port" ]]  && die "Missing local port.\n  Usage: stairway connect 8080:3000 user@host"
    [[ -z "$host" ]]        && die "Missing SSH host.\n  Usage: stairway connect 8080:3000 user@host"

    check_autossh
    ensure_dirs

    local id
    id=$(tunnel_id "$remote_port" "$host")
    local pid_file="$TUNNELS_DIR/${id}.pid"
    local meta_file="$TUNNELS_DIR/${id}.meta"

    # Check for existing tunnel with same ID
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            warn "Tunnel ${BOLD}${id}${RESET} is already running (PID ${old_pid})."
            warn "Run ${BOLD}stairway disconnect ${id}${RESET} first."
            return 1
        fi
        rm -f "$pid_file" "$meta_file"
    fi

    local ssh_opts=(
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "ExitOnForwardFailure=yes"
        -o "StrictHostKeyChecking=accept-new"
    )
    [[ -n "$ssh_key" ]] && ssh_opts+=(-i "$ssh_key")

    echo ""
    info "Opening tunnel ${BOLD}${id}${RESET}"
    echo "  ${DIM}Remote:${RESET} ${host}:${remote_port}"
    echo "  ${DIM}Local:${RESET}  ${local_host}:${local_port}"
    echo ""

    export AUTOSSH_PIDFILE="$pid_file"
    export AUTOSSH_GATETIME=0

    autossh -M 0 -f -N \
        "${ssh_opts[@]}" \
        -R "${bind_addr}:${remote_port}:${local_host}:${local_port}" \
        "$host"

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
LOCAL_HOST=${local_host}
SSH_HOST=${host}
BIND_ADDR=${bind_addr}
PID=${pid}
STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
        info "${GREEN}Tunnel is live!${RESET} (PID ${pid})"
        echo ""
        echo "  ${BOLD}→ http://${host}:${remote_port}${RESET}"
        echo ""
    else
        die "Failed to start tunnel — check SSH connectivity to ${host}"
    fi
}

# ── Disconnect ────────────────────────────────────────────────
cmd_disconnect() {
    ensure_dirs
    local target="${1:-}"

    [[ -z "$target" ]] && die "Usage: stairway disconnect <id|all>"

    if [[ "$target" == "all" ]]; then
        local count=0
        for pid_file in "$TUNNELS_DIR"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local id
            id=$(basename "$pid_file" .pid)
            _kill_tunnel "$id" && count=$((count + 1))
        done
        [[ $count -eq 0 ]] && warn "No active tunnels." || info "Disconnected ${count} tunnel(s)."
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

# ── Status ────────────────────────────────────────────────────
cmd_status() {
    ensure_dirs
    local found=0

    echo ""
    printf "${BOLD}  %-10s %-8s %-24s %-20s %s${RESET}\n" "ID" "STATUS" "REMOTE" "LOCAL" "PID"
    printf "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}\n"

    for meta_file in "$TUNNELS_DIR"/*.meta; do
        [[ -f "$meta_file" ]] || continue
        found=1

        local TUNNEL_ID="" REMOTE_PORT="" LOCAL_PORT="" LOCAL_HOST="" SSH_HOST="" PID="" STARTED="" BIND_ADDR=""
        # shellcheck disable=SC1090
        source "$meta_file"

        local status="${RED}dead${RESET}"
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            status="${GREEN}live${RESET}"
        fi

        printf "  %-10s %-17s %-24s %-20s %s\n" \
            "$TUNNEL_ID" \
            "$status" \
            "${SSH_HOST}:${REMOTE_PORT}" \
            "${LOCAL_HOST}:${LOCAL_PORT}" \
            "$PID"
    done

    [[ $found -eq 0 ]] && echo "  ${DIM}No active tunnels.${RESET}"
    echo ""
}

# ── Clean ─────────────────────────────────────────────────────
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

# ── Help ──────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF

  ${BOLD}${CYAN}stairway${RESET} ${DIM}v${VERSION}${RESET} — SSH tunnel client

  ${BOLD}USAGE${RESET}
    stairway <command> [options]

  ${BOLD}COMMANDS${RESET}
    connect      ${DIM}<remote:local> <user@host>${RESET}   Open a tunnel
    disconnect   ${DIM}<id|all>${RESET}                     Close tunnel(s)
    status                                     List active tunnels
    clean                                      Remove stale PID files

  ${BOLD}CONNECT OPTIONS${RESET}
    -r, --remote  ${DIM}<port>${RESET}      Remote port on VPS
    -l, --local   ${DIM}<port>${RESET}      Local port to forward
    -s, --server  ${DIM}<user@ip>${RESET}   SSH destination
    -k, --key     ${DIM}<path>${RESET}      SSH private key
    -b, --bind    ${DIM}<host>${RESET}      Local bind address   ${DIM}(default: localhost)${RESET}
    --bind-remote ${DIM}<addr>${RESET}      Remote bind address  ${DIM}(default: 0.0.0.0)${RESET}

  ${BOLD}EXAMPLES${RESET}
    ${DIM}# Expose local :3000 on your VPS :8080${RESET}
    stairway connect 8080:3000 root@203.0.113.10

    ${DIM}# With a specific SSH key${RESET}
    stairway connect -r 80 -l 3000 -s deploy@myserver -k ~/.ssh/id_tunnel

    ${DIM}# Check what's running${RESET}
    stairway status

    ${DIM}# Tear down everything${RESET}
    stairway disconnect all

EOF
}

# ── Main ──────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        connect|c)      cmd_connect "$@" ;;
        disconnect|dc)  cmd_disconnect "$@" ;;
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
