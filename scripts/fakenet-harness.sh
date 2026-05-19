#!/usr/bin/env bash
# ============================================================================
# Vesl-core Fakenet Harness
#
# Boots a local Nockchain fakenet (hub + miner) so the hull can talk to a
# real chain in fakenet mode. Adapted from hull-llm's harness when the two
# repos split — vesl-core needs its own copy because the hull lives here.
#
# Prerequisites:
#   - nockchain on PATH (make install-nockchain from $NOCK_HOME)
#   - hull binary built (make build, or cargo build -p hull --release)
#
# Usage:
#   ./scripts/fakenet-harness.sh start    # boot hub + miner in background
#   ./scripts/fakenet-harness.sh stop     # tear them down
#   ./scripts/fakenet-harness.sh status   # show pids
#   ./scripts/fakenet-harness.sh logs     # tail recent log output
#
# State lives under vesl-core/.fakenet/ (gitignored). Override defaults via
# scripts/.env.fakenet (already in the repo).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.fakenet}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# Defaults — overridable via .env.fakenet or environment.
NOCKCHAIN_GRPC_ADDR="${NOCKCHAIN_GRPC_ADDR:-127.0.0.1:9090}"
# Demo signing key PKH from vesl_core::signing::demo_signing_key()
# (sk[0]=12345, sk[1]=67890). Letting the miner mine to this PKH means the
# hull can spend mined coinbase UTXOs in fakenet mode without seed setup.
MINING_PKH="${MINING_PKH:-5pJiNWqnouxku6SvGU6XZhu98nHH5VFMaNJ4r1vtHxPJ5sHurHBfYnk}"
FAKENET_POW_LEN="${FAKENET_POW_LEN:-2}"
FAKENET_LOG_DIFFICULTY="${FAKENET_LOG_DIFFICULTY:-1}"

# State isolation
FAKENET_DIR="$PROJECT_ROOT/.fakenet"
HUB_DIR="$FAKENET_DIR/hub"
MINER_DIR="$FAKENET_DIR/miner"
HUB_PID="$FAKENET_DIR/hub.pid"
MINER_PID="$FAKENET_DIR/miner.pid"

# Hub multiaddr (fixed for peer discovery)
HUB_BIND="/ip4/127.0.0.1/udp/3006/quic-v1"

log() { echo "[fakenet] $*"; }
err() { echo "[fakenet] ERROR: $*" >&2; }

check_binary() {
    if ! command -v "$1" &>/dev/null; then
        err "$1 not found in PATH."
        err "Install it from \$NOCK_HOME: make install-$1"
        exit 1
    fi
}

is_running() {
    local pidfile="$1"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

wait_for_port() {
    local host="$1" port="$2" timeout="${3:-30}"
    local elapsed=0
    while ! bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            err "Timeout waiting for $host:$port after ${timeout}s"
            return 1
        fi
    done
    log "$host:$port is ready (${elapsed}s)"
}

cmd_start() {
    check_binary nockchain
    log "Starting Vesl-core fakenet..."
    mkdir -p "$HUB_DIR" "$MINER_DIR"

    if is_running "$HUB_PID"; then
        log "Hub already running (pid $(cat "$HUB_PID"))"
    else
        log "Starting hub node..."
        (
            cd "$HUB_DIR"
            export RUST_LOG="${RUST_LOG:-info}"
            export MINIMAL_LOG_FORMAT="${MINIMAL_LOG_FORMAT:-true}"
            nockchain \
                --fakenet \
                --bind "$HUB_BIND" \
                --bind-public-grpc-addr "$NOCKCHAIN_GRPC_ADDR" \
                --fakenet-pow-len "$FAKENET_POW_LEN" \
                --fakenet-log-difficulty "$FAKENET_LOG_DIFFICULTY" \
                > "$FAKENET_DIR/hub.log" 2>&1 &
            echo $! > "$HUB_PID"
        )
        log "Hub started (pid $(cat "$HUB_PID")), log: $FAKENET_DIR/hub.log"
    fi

    local grpc_host grpc_port
    grpc_host="${NOCKCHAIN_GRPC_ADDR%%:*}"
    grpc_port="${NOCKCHAIN_GRPC_ADDR##*:}"
    log "Waiting for hub gRPC at $NOCKCHAIN_GRPC_ADDR..."
    wait_for_port "$grpc_host" "$grpc_port" 60

    if is_running "$MINER_PID"; then
        log "Miner already running (pid $(cat "$MINER_PID"))"
    else
        log "Starting miner node..."
        (
            cd "$MINER_DIR"
            export RUST_LOG="${RUST_LOG:-info}"
            export MINIMAL_LOG_FORMAT="${MINIMAL_LOG_FORMAT:-true}"
            nockchain \
                --mine \
                --fakenet \
                --mining-pkh "$MINING_PKH" \
                --peer "$HUB_BIND" \
                --no-default-peers \
                --fakenet-pow-len "$FAKENET_POW_LEN" \
                --fakenet-log-difficulty "$FAKENET_LOG_DIFFICULTY" \
                > "$FAKENET_DIR/miner.log" 2>&1 &
            echo $! > "$MINER_PID"
        )
        log "Miner started (pid $(cat "$MINER_PID")), log: $FAKENET_DIR/miner.log"
    fi

    sleep 3
    log ""
    log "Fakenet is running."
    log "  Hub gRPC:  http://$NOCKCHAIN_GRPC_ADDR"
    log "  Hub log:   $FAKENET_DIR/hub.log"
    log "  Miner log: $FAKENET_DIR/miner.log"
    log ""
    log "Run the hull against it:"
    log "  HULL_API_KEY=dev cargo run -p hull -- --settlement-mode fakenet \\"
    log "    --chain-endpoint http://$NOCKCHAIN_GRPC_ADDR --no-auth"
}

cmd_stop() {
    log "Stopping fakenet..."
    for pidfile in "$MINER_PID" "$HUB_PID"; do
        if [[ -f "$pidfile" ]]; then
            local pid name
            pid=$(cat "$pidfile")
            name=$(basename "$pidfile" .pid)
            if kill -0 "$pid" 2>/dev/null; then
                log "Stopping $name (pid $pid)..."
                kill "$pid" 2>/dev/null || true
                local i=0
                while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
                    sleep 1
                    i=$((i + 1))
                done
                if kill -0 "$pid" 2>/dev/null; then
                    log "Force-killing $name..."
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
            rm -f "$pidfile"
        fi
    done
    log "Fakenet stopped."
}

cmd_status() {
    log "Fakenet status:"
    for pidfile in "$HUB_PID" "$MINER_PID"; do
        local name
        name=$(basename "$pidfile" .pid)
        if is_running "$pidfile"; then
            log "  $name: running (pid $(cat "$pidfile"))"
        else
            log "  $name: stopped"
        fi
    done
}

cmd_logs() {
    local target="${1:-both}"
    case "$target" in
        hub)   tail -n 100 "$FAKENET_DIR/hub.log" ;;
        miner) tail -n 100 "$FAKENET_DIR/miner.log" ;;
        both)
            echo "--- hub.log (tail) ---"
            tail -n 50 "$FAKENET_DIR/hub.log" 2>/dev/null || echo "(no hub log)"
            echo
            echo "--- miner.log (tail) ---"
            tail -n 50 "$FAKENET_DIR/miner.log" 2>/dev/null || echo "(no miner log)"
            ;;
        *) err "unknown logs target '$target' (use hub|miner|both)"; exit 1 ;;
    esac
}

case "${1:-help}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   shift || true; cmd_logs "${1:-both}" ;;
    *)
        echo "Usage: $0 {start|stop|status|logs [hub|miner|both]}"
        echo
        echo "  start   Boot fakenet hub + miner (background)"
        echo "  stop    Stop all fakenet processes"
        echo "  status  Show running processes"
        echo "  logs    Tail hub and/or miner logs"
        exit 1
        ;;
esac
