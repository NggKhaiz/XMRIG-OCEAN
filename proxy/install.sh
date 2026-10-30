#!/bin/sh
# Install zmrig-proxy as a service. One command, no flags required beyond the two
# that cannot be guessed: the wallet and the pool.
#
#   sudo ./proxy/install.sh --user=<wallet> --pool=<host:port>
#   sudo ./proxy/install.sh --user=<wallet> --pool=<host:port> --tunnel=wireguard
#   sudo ./proxy/install.sh --dry-run --user=<wallet> --pool=<host:port>
#
# Everything it writes is printed first when --dry-run is given, so a wrong
# address or a wrong flag is visible before anything is installed.

set -eu

PREFIX="${PREFIX:-/opt/zmrig-proxy}"
UNIT="/etc/systemd/system/zmrig-proxy.service"
NODE_MIN_MAJOR=18
NODE_MIN_MINOR=17

DRY_RUN=0
ARGS=""
USER_FLAG=""
POOL_FLAG=""

usage() {
  cat <<'EOF'
zmrig-proxy installer

  sudo ./proxy/install.sh --user=<wallet[.worker]> --pool=<host:port[,host:port]> [flags]

Flags are passed straight to `zmrig-proxy start` (see doc/PROXY.md):
  --tunnel=wireguard|tailscale|cf|cf-quick   how rigs in another building reach it
  --tunnel-token=<secret>                    auth key or Cloudflare tunnel token
  --token=<secret>                           the password every rig must send
  --allow=<cidr,...>                         who may connect
  --bind=<ip>                                default 127.0.0.1
  --ws                                       also serve WebSocket (needed by Cloudflare)
  --port=<n>                                 stratum port, default 3333

Installer options:
  --dry-run        print the unit and the commands, write nothing
  --uninstall      stop the service and remove what this script installed
  --help           this text
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for argument in "$@"; do
  case "$argument" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --user=*) USER_FLAG="${argument#--user=}" ;;
    --pool=*) POOL_FLAG="${argument#--pool=}" ;;
    *) ARGS="$ARGS $argument" ;;
  esac
done

if [ "${UNINSTALL:-0}" = "1" ]; then
  [ "$(id -u)" = "0" ] || die "--uninstall needs root"
  systemctl disable --now zmrig-proxy.service 2>/dev/null || true
  rm -f "$UNIT"
  rm -rf "$PREFIX"
  systemctl daemon-reload 2>/dev/null || true
  log "removed the service and $PREFIX"
  exit 0
fi

[ -n "$USER_FLAG" ] || die "--user=<wallet> is required"
[ -n "$POOL_FLAG" ] || die "--pool=<host:port> is required"

# --- node ------------------------------------------------------------------

command -v node >/dev/null 2>&1 || die "node is not installed: apt install -y nodejs  (18.17 or newer)"

NODE_VERSION="$(node -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
NODE_REST="${NODE_VERSION#*.}"
NODE_MINOR="${NODE_REST%%.*}"

if [ "$NODE_MAJOR" -lt "$NODE_MIN_MAJOR" ] || { [ "$NODE_MAJOR" -eq "$NODE_MIN_MAJOR" ] && [ "$NODE_MINOR" -lt "$NODE_MIN_MINOR" ]; }; then
  die "node $NODE_VERSION is too old: 18.17 or newer is required"
fi

NODE_BIN="$(command -v node)"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- the unit --------------------------------------------------------------

EXEC_START="$NODE_BIN $PREFIX/proxy/src/main.js start --user=$USER_FLAG --pool=$POOL_FLAG$ARGS"

UNIT_TEXT="[Unit]
Description=zmrig-proxy: one pool connection for every rig
Documentation=file://$PREFIX/doc/PROXY.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$EXEC_START
Restart=always
RestartSec=3
# The proxy holds a wallet address in its command line; keep it out of ps for
# other users on the machine.
PrivateTmp=yes
NoNewPrivileges=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target"

if [ "$DRY_RUN" = "1" ]; then
  log "would install to:  $PREFIX"
  log "would write unit:  $UNIT"
  log ""
  log "--- $UNIT ---"
  log "$UNIT_TEXT"
  log "--- end ---"
  log ""
  log "would then run:"
  log "  systemctl daemon-reload && systemctl enable --now zmrig-proxy"
  log ""
  log "after it is up, check it with:"
  log "  $NODE_BIN $PREFIX/proxy/src/main.js doctor --user=$USER_FLAG --pool=$POOL_FLAG"
  exit 0
fi

[ "$(id -u)" = "0" ] || die "installing a service needs root (sudo), or use --dry-run"

# --- install ---------------------------------------------------------------

log "installing into $PREFIX"
# Layout matters: proxy/src/downstream.js requires ../../pool/src/target, so the
# two trees have to keep their relative positions or the service dies on start.
mkdir -p "$PREFIX/proxy" "$PREFIX/pool" "$PREFIX/doc"
cp -R "$SOURCE_DIR/src" "$PREFIX/proxy/"
cp -R "$SOURCE_DIR/../pool/src" "$PREFIX/pool/"
cp "$SOURCE_DIR/package.json" "$SOURCE_DIR/install.sh" "$PREFIX/proxy/"
cp "$SOURCE_DIR/../doc/PROXY.md" "$PREFIX/doc/" 2>/dev/null || true

printf '%s\n' "$UNIT_TEXT" > "$UNIT"
chmod 0644 "$UNIT"

systemctl daemon-reload
systemctl enable --now zmrig-proxy.service

sleep 1
if systemctl is-active --quiet zmrig-proxy.service; then
  log "zmrig-proxy is running"
  log ""
  log "  logs:   journalctl -u zmrig-proxy -f"
  log "  status: curl -s http://127.0.0.1:3334/status"
  if [ -z "$(printf '%s' "$ARGS" | grep -o -- '--bind=0.0.0.0' || true)" ]; then
    log ""
    log "it listens on 127.0.0.1 only. For rigs on the LAN, reinstall with:"
    log "  --bind=0.0.0.0 --token=<a secret>"
  fi
else
  die "the service did not stay up: journalctl -u zmrig-proxy -n 50"
fi
