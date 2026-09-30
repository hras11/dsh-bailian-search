#!/usr/bin/env bash
# install.sh — install the DSH anthropic search proxy.
#
# Typical use, on any machine with DSH already configured:
#
#   git clone <repo> dsh-search-proxy && cd dsh-search-proxy && ./install.sh
#
# Files are installed to $PREFIX (default ~/.local/share/dsh-search-proxy) so
# the systemd unit points at a stable path and the clone directory can be moved
# or deleted afterwards. To update, re-run this script from a fresh clone or
# from the original one: it records the source directory and refreshes in place.
#
# Usage:
#   ./install.sh                       # install (auto-detects gateway + profile)
#   ./install.sh --upstream URL        # override the Aliyun gateway
#   ./install.sh --port 8788           # override the listen port
#   ./install.sh --profile DIR         # override the DSH profile directory
#   ./install.sh --prefix DIR          # override the install location
#   ./install.sh --dry-run             # show what would change
#   ./install.sh --uninstall           # remove service + installed files
#
# Idempotent: safe to re-run, both to upgrade and to repair.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT_NAME="anthropic-search-proxy"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME.service"

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/dsh-search-proxy"
STATE_FILE="$PREFIX/.install-state"

UPSTREAM=""
PORT="${PROXY_PORT:-8787}"
PROFILE=""
DRY_RUN=0
NO_ENABLE=0
UNINSTALL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
  exit 0
}

need_val() { [ -n "${2:-}" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --upstream)  need_val "$1" "${2:-}"; UPSTREAM="$2";  shift 2 ;;
    --port)      need_val "$1" "${2:-}"; PORT="$2";      shift 2 ;;
    --profile)   need_val "$1" "${2:-}"; PROFILE="$2";   shift 2 ;;
    --prefix)    need_val "$1" "${2:-}"; PREFIX="$2";    shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --no-enable) NO_ENABLE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

STATE_FILE="$PREFIX/.install-state"

# --- uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  say "Uninstalling $UNIT_NAME"
  systemctl --user disable --now "$UNIT_NAME.service" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH" && ok "removed unit"
  systemctl --user daemon-reload
  ok "systemd reloaded"
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    PATCH_SAVED=$(sed -n 's/^PATCH=//p' "$STATE_FILE" || true)
    if [ -n "${PATCH_SAVED:-}" ] && [ -f "$PATCH_SAVED" ]; then
      say "  note: DSH config still points at the proxy — remove the"
      say "        'web-search-deepseek' entry from $PATCH_SAVED"
      say "        (or restore its backup) if you want search fully reverted."
    fi
  fi
  if [ -d "$PREFIX" ]; then
    rm -rf "$PREFIX" && ok "removed $PREFIX"
  fi
  say "Done."
  exit 0
fi

say "DSH anthropic search proxy — installer"
say ""

# --- preconditions -----------------------------------------------------------
command -v node >/dev/null 2>&1 || die "node not found in PATH"
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 18 ] || die "node >= 18 required (found $(node -v)); the proxy relies on global fetch"

[ -f "$SCRIPT_DIR/src/proxy.mjs" ] || die "missing src/proxy.mjs — run this from the repo root"
[ -f "$SCRIPT_DIR/bin/proxy-ctl" ] || die "missing bin/proxy-ctl"
ok "node $(node -v)"

STATE=$(systemctl --user is-system-running 2>&1 || true)
case "$STATE" in
  running|degraded) ;;
  *) warn "systemd --user reports '$STATE'; continuing anyway" ;;
esac
ok "systemd --user available"

# --- resolve the DSH profile -------------------------------------------------
# An explicitly passed --profile must be real: silently continuing turns a typo
# into a confusing "could not auto-detect upstream" further down.
if [ -n "$PROFILE" ]; then
  [ -d "$PROFILE" ] || die "--profile directory does not exist: $PROFILE"
  [ -f "$PROFILE/cordis.patch.yml" ] || die "--profile has no cordis.patch.yml: $PROFILE"
else
  if [ -d "$HOME/.dsh/profiles/web" ]; then
    PROFILE="$HOME/.dsh/profiles/web"
  else
    PROFILE=$(find "$HOME/.dsh/profiles" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1 || true)
  fi
fi

PATCH=""
if [ -n "$PROFILE" ] && [ -f "$PROFILE/cordis.patch.yml" ]; then
  PATCH="$PROFILE/cordis.patch.yml"
  ok "DSH profile: $PROFILE"
else
  warn "no cordis.patch.yml found; the DSH side must be configured manually"
fi

# --- resolve the upstream gateway -------------------------------------------
# Prefer an explicit flag, then an existing aliyun gateway already used for chat,
# because the same workspace+region serves both chat and search.
if [ -z "$UPSTREAM" ] && [ -n "$PATCH" ]; then
  DETECTED=$(grep -oE 'https://[A-Za-z0-9.-]+\.maas\.aliyuncs\.com/apps/anthropic' "$PATCH" 2>/dev/null | head -1 || true)
  if [ -n "$DETECTED" ]; then
    UPSTREAM="${DETECTED%/}/v1"
    ok "detected upstream from cordis.patch.yml"
  fi
fi

if [ -z "$UPSTREAM" ]; then
  say ""
  warn "could not auto-detect the Aliyun gateway URL."
  say "     Pass it explicitly, e.g.:"
  say "       ./install.sh --upstream https://<WorkspaceId>.<region>.maas.aliyuncs.com/apps/anthropic/v1"
  die  "upstream required"
fi

# The search endpoint needs the /v1 segment; without it the gateway returns 404.
case "$UPSTREAM" in
  */v1) ;;
  *) UPSTREAM="${UPSTREAM%/}/v1"; warn "appended missing /v1 to upstream" ;;
esac
case "$UPSTREAM" in
  https://*) ;;
  *) die "upstream must be https" ;;
esac
ok "upstream: $UPSTREAM"

case "$PORT" in
  ''|*[!0-9]*) die "port must be numeric (got '$PORT')" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port out of range: $PORT"
ok "listen port: $PORT"

say ""
say "Plan:"
say "  install   $PREFIX"
say "  unit      $UNIT_PATH"
say "  upstream  $UPSTREAM"
say "  port      $PORT"
[ -n "$PATCH" ] && say "  config    $PATCH"
say ""

if [ "$DRY_RUN" = "1" ]; then
  say "dry run — nothing written."
  exit 0
fi

# --- install files to a stable location --------------------------------------
# Copying (rather than pointing at the clone) keeps the unit valid even after
# the clone is moved or deleted; re-running this script refreshes the copy.
mkdir -p "$PREFIX/bin"
install -m 0644 "$SCRIPT_DIR/src/proxy.mjs" "$PREFIX/proxy.mjs"
install -m 0755 "$SCRIPT_DIR/bin/proxy-ctl" "$PREFIX/proxy-ctl"
ok "installed files to $PREFIX"

# --- install the unit --------------------------------------------------------
mkdir -p "$UNIT_DIR"

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Anthropic search proxy for DSH (injects Aliyun Bailian web_search billing header)
Documentation=file:$PREFIX/proxy.mjs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
Environment=UPSTREAM_BASE_URL=$UPSTREAM
Environment=PROXY_PORT=$PORT
ExecStart=$(command -v node) $PREFIX/proxy.mjs

# The proxy must survive DSH restarts and machine reboots; systemd owns its
# lifetime so that DSH never does. Restart aggressively — a dead proxy silently
# breaks web search, which is the failure this whole setup exists to fix.
Restart=always
RestartSec=2

# Journald captures stdout/stderr, which proxy-ctl logs surfaces for DSH.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=anthropic-search-proxy

# Loopback-only listener, no privilege needed.
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
ok "wrote $UNIT_PATH"

# --- point DSH at the proxy --------------------------------------------------
if [ -n "$PATCH" ]; then
  cp "$PATCH" "$PATCH.bak.$$"
  if grep -q 'id: web-search-deepseek' "$PATCH"; then
    awk -v url="http://127.0.0.1:$PORT/v1" '
      /id: web-search-deepseek/ { inblk=1 }
      inblk && /baseURL:/ { sub(/baseURL:.*/, "baseURL: " url); inblk=0 }
      { print }
    ' "$PATCH.bak.$$" > "$PATCH"
    ok "updated web-search-deepseek.baseURL in cordis.patch.yml"
  else
    cat >> "$PATCH" <<EOF
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  config:
    baseURL: http://127.0.0.1:$PORT/v1
EOF
    ok "appended web-search-deepseek section to cordis.patch.yml"
  fi

  # Validate before trusting the edit; a YAML typo here breaks DSH startup.
  YAML_LIB=""
  for cand in "$HOME/.npm/_npx"/*/node_modules/yaml /usr/lib/node_modules/yaml /usr/local/lib/node_modules/yaml; do
    [ -d "$cand" ] && YAML_LIB="$cand" && break
  done
  if [ -n "$YAML_LIB" ]; then
    if node -e "
      const YAML=require('$YAML_LIB');
      const d=YAML.parse(require('fs').readFileSync('$PATCH','utf8'));
      if(!Array.isArray(d)) throw new Error('top level is not an array');
      const ws=d.find(e=>String(e?.name||'').includes('web-search-deepseek'));
      if(!ws) throw new Error('web-search-deepseek entry missing');
      if(ws.config.baseURL!=='http://127.0.0.1:$PORT/v1') throw new Error('baseURL not applied');
    " 2>/dev/null; then
      ok "validated cordis.patch.yml"
      rm -f "$PATCH.bak.$$"
    else
      mv "$PATCH.bak.$$" "$PATCH"
      die "cordis.patch.yml validation failed — restored the original"
    fi
  else
    warn "yaml module not found; skipped validation (backup kept at $PATCH.bak.$$)"
  fi
fi

# Record where this came from so proxy-ctl can offer a one-command update.
cat > "$STATE_FILE" <<EOF
# Written by install.sh — used by proxy-ctl upgrade.
SRC=$SCRIPT_DIR
PREFIX=$PREFIX
PATCH=$PATCH
PORT=$PORT
UPSTREAM=$UPSTREAM
INSTALLED_AT=$(date -Is)
VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo unknown)
EOF
ok "recorded install state"

# --- start the service -------------------------------------------------------
systemctl --user daemon-reload
ok "systemd reloaded"

if [ "$NO_ENABLE" = "1" ]; then
  systemctl --user restart "$UNIT_NAME.service"
  ok "restarted (boot autostart left unchanged)"
else
  systemctl --user enable --now "$UNIT_NAME.service" >/dev/null 2>&1
  systemctl --user restart "$UNIT_NAME.service"
  ok "enabled + started"
fi

# --- verify ------------------------------------------------------------------
say ""
say "Verifying..."
sleep 2

FAIL=0
if systemctl --user is-active --quiet "$UNIT_NAME.service"; then
  ok "service active"
else
  warn "service not active — check: journalctl --user -u $UNIT_NAME -n 30"
  FAIL=1
fi

HEALTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo 000)
if [ "$HEALTH" = "200" ]; then
  ok "port $PORT responding"
else
  warn "health check returned HTTP $HEALTH"
  FAIL=1
fi

LINGER=$(loginctl show-user "$USER" 2>/dev/null | sed -n 's/^Linger=//p' || true)
if [ "$LINGER" = "yes" ]; then
  ok "lingering enabled (starts at boot without login)"
else
  warn "lingering is OFF — the proxy will not start until you log in"
  say "     enable with: sudo loginctl enable-linger $USER"
fi

say ""
if [ "$FAIL" = "0" ]; then
  say "Done. Web search is routed through http://127.0.0.1:$PORT/v1"
  say ""
  say "Next: restart DSH so it picks up the new config, then run a search."
  say "Manage with: $PREFIX/proxy-ctl status"
else
  say "Installed with warnings — see messages above."
  exit 1
fi