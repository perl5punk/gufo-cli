#!/usr/bin/env bash
#
# install.sh — connect Gufo to a Lemonade Server install in one shot.
#
# Prerequisites: Lemonade Server (lemond + the lemonade CLI) already installed,
# podman, jq, curl, python3. Run as the user that owns the model files and can
# run GPU containers — NOT as root, and no sudo needed for the happy path.
#
#   ./install.sh                      # provider "gufo", bridge on :13399
#   ./install.sh --provider gufo --port 13399
#   ./install.sh --with-env-key       # also persist the API key in /etc (needs root)
#   ./install.sh --restart-lemond     # bounce lemond now instead of on its next restart
#   ./install.sh --no-autostart       # do not start the bridge at login/boot
#   ./install.sh --dry-run            # print what would happen
#
# What it does, without rebuilding or patching Lemonade:
#   1. installs `gufo` and `gufo-lemonade` into ~/.local/bin
#   2. writes ~/.config/gufo-lemonade/config.json
#   3. installs + starts a systemd *user* service for the bridge
#   4. registers the provider: lemonade cloud install <provider> --base-url ...
#   5. verifies that Lemonade now publishes <provider>.<Model> models
#
# The bridge re-asserts its own registration on start and whenever Lemonade's
# model list drifts, so the models survive a lemond restart without root.
# Pass --with-env-key if you would rather also pin LEMONADE_<PROVIDER>_API_KEY
# in /etc/default/lemond.
#
set -euo pipefail

PROVIDER="gufo"
BRIDGE_PORT="13399"
BRIDGE_HOST="127.0.0.1"
API_KEY="gufo-local"
ENABLE_UNIT=1
WITH_ENV_KEY=0
RESTART_LEMOND=0
DRY_RUN=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
GUFO_SRC="${REPO_DIR}/gufo"
BRIDGE_SRC="${SCRIPT_DIR}/bin/gufo-lemonade"
UNIT_NAME="gufo-lemonade"
UNIT_FILE="${HOME}/.config/systemd/user/${UNIT_NAME}.service"
UNIT_SRC="${SCRIPT_DIR}/systemd/gufo-lemonade.service"
CONFIG_DIR="${HOME}/.config/gufo-lemonade"
LEMOND_PORT="${LEMOND_PORT:-13305}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_blu" "$*" "$c_rst"; }
ok()   { printf '%s  ok %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s   ! %s%s\n' "$c_ylw" "$*" "$c_rst"; }
die()  { printf '%serror: %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '       [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() { sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --provider)       PROVIDER="${2:-}"; shift 2 ;;
    --port)           BRIDGE_PORT="${2:-}"; shift 2 ;;
    --host)           BRIDGE_HOST="${2:-}"; shift 2 ;;
    --api-key)        API_KEY="${2:-}"; shift 2 ;;
    --with-env-key)   WITH_ENV_KEY=1; shift ;;
    --restart-lemond) RESTART_LEMOND=1; shift ;;
    --no-autostart)   ENABLE_UNIT=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "$PROVIDER" =~ ^[a-z][a-z0-9_]*$ ]] || die "--provider must be lowercase letters/digits/underscore (got '$PROVIDER')"
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[ -n "$API_KEY" ] || die "--api-key must not be empty (the cloud recipe rejects an empty key)"
ENV_KEY="LEMONADE_$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"

# ---------------------------------------------------------------- 1. checks --
step "Checking prerequisites"
[ "$(uname -s)" = "Linux" ] || die "this bridge pairs Lemonade with Linux podman containers"
[ "$(id -u)" != 0 ] || die "do not run as root: the bridge drives your rootless podman and must run as you"
for tool in podman jq curl python3; do
  command -v "$tool" >/dev/null || die "$tool is required (install it, then re-run)"
done
ok "podman, jq, curl, python3 $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
command -v lemonade >/dev/null \
  || die "lemonade CLI not found - install Lemonade Server first: https://lemonade-server.ai/docs/guide/installation/"
[ -f "$GUFO_SRC" ] || die "gufo CLI not found next to this script ($GUFO_SRC)"
[ -f "$BRIDGE_SRC" ] || die "bridge not found ($BRIDGE_SRC)"
ok "lemonade $(lemonade --version 2>/dev/null | head -1 | awk '{print $NF}')"
lemonade cloud list >/dev/null 2>&1 \
  || warn "this lemonade CLI has no 'cloud' subcommand - Lemonade >= 11 is required"

if ! podman info >/dev/null 2>&1; then
  die "podman cannot start containers for this user (podman info failed)"
fi
ok "rootless podman responds"
if [ ! -e /dev/kfd ] && [ ! -e /dev/nvidia0 ]; then
  warn "/dev/kfd not found - containers would run without a GPU (very slow)"
fi

LEMOND_SCOPE="none"
if systemctl list-unit-files 2>/dev/null | grep -q '^lemond\.service'; then
  LEMOND_SCOPE="system"
elif systemctl --user list-unit-files 2>/dev/null | grep -q '^lemond\.service'; then
  LEMOND_SCOPE="user"
elif pgrep -x lemond >/dev/null 2>&1; then
  LEMOND_SCOPE="manual"
else
  warn "no lemond process or service detected - start Lemonade Server, then re-run this step with: gufo-lemonade refresh"
fi
ok "lemond managed by: ${LEMOND_SCOPE}"

if ! curl -fsS --max-time 4 "http://127.0.0.1:${LEMOND_PORT}/v1/models" >/dev/null 2>&1; then
  warn "lemond is not answering on 127.0.0.1:${LEMOND_PORT} (override with LEMOND_PORT=...)"
fi

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${BRIDGE_PORT}$"; then
  # A bridge left running by a previous install is fine - the systemd unit is
  # restarted below. Anything else on that port is a real conflict.
  if curl -fsS --max-time 3 "http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" 2>/dev/null | grep -q '"bridge"'; then
    ok "port ${BRIDGE_PORT} is held by a running gufo-lemonade bridge (it will be restarted)"
  else
    die "port ${BRIDGE_PORT} is already in use - choose another with --port"
  fi
fi

# ------------------------------------------- 2. command line entry points ----
step "Installing command line tools into ${BIN_DIR}"
run mkdir -p "$BIN_DIR"
run install -m 755 "$GUFO_SRC" "${BIN_DIR}/gufo"
run install -m 755 "$BRIDGE_SRC" "${BIN_DIR}/gufo-lemonade"
ok "gufo, gufo-lemonade"
case ":${PATH}:" in
  *":${BIN_DIR}:"*) : ;;
  *) warn "${BIN_DIR} is not on your PATH - add:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ------------------------------------------------------------- 3. config ----
step "Bridge configuration"
if [ "$DRY_RUN" = 1 ]; then
  printf '       [dry-run] create %s/config.json if missing\n' "$CONFIG_DIR"
else
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    "$BIN_DIR/gufo-lemonade" config >/dev/null
    ok "created ${CONFIG_DIR}/config.json"
  else
    ok "keeping existing ${CONFIG_DIR}/config.json"
  fi
  python3 - "$BRIDGE_PORT" "$BRIDGE_HOST" "$PROVIDER" "$API_KEY" "$LEMOND_PORT" <<'PY'
import json, os, sys
port, host, provider, api_key, lemond_port = sys.argv[1:6]
path = os.path.expanduser("~/.config/gufo-lemonade/config.json")
try:
    with open(path) as fh:
        cfg = json.load(fh)
except FileNotFoundError:
    cfg = {}
cfg.update({
    "host": host,
    "port": int(port),
    "provider": provider,
    "api_key": api_key,
    "lemond_url": f"http://127.0.0.1:{lemond_port}",
    "auto_register": True,
})
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
  ok "provider='${PROVIDER}'  endpoint=http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1  (models dirs: $(python3 -c "import json,os;print(', '.join(json.load(open(os.path.expanduser('~/.config/gufo-lemonade/config.json')))['models_dirs']))"))"
fi

# ------------------------------------------------ 4. bridge as a user service --
step "Installing the bridge service (${UNIT_NAME}.service, user scope)"
run mkdir -p "${HOME}/.config/systemd/user"
if [ -f "$UNIT_SRC" ]; then
  sed -e "s|@BRIDGE@|${BIN_DIR}/gufo-lemonade|" \
      -e "s|@PORT@|${BRIDGE_PORT}|" \
      "$UNIT_SRC" > "$UNIT_FILE"
  ok "$UNIT_FILE"
else
  warn "$UNIT_SRC missing - writing a minimal unit"
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Gufo bridge for Lemonade Server
After=network-online.target

[Service]
ExecStart=${BIN_DIR}/gufo-lemonade serve
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
fi
run systemctl --user daemon-reload
if [ "$ENABLE_UNIT" = 1 ]; then
  run systemctl --user enable --now "${UNIT_NAME}.service"
  ok "started, and started again at login"
  # Linger keeps the user manager (and therefore the bridge) alive with no open
  # session, so the models are there after a reboot. Needs root; optional.
  me="${USER:-$(id -un)}"
  if [ "$(loginctl show-user "$me" -p Linger --value 2>/dev/null)" != "yes" ]; then
    if sudo -n loginctl enable-linger "$me" 2>/dev/null; then
      ok "lingering enabled for $me (bridge survives logout and reboot)"
    else
      warn "to keep the bridge up after logout/reboot run: sudo loginctl enable-linger $me"
    fi
  else
    ok "lingering already enabled for $me"
  fi
else
  run systemctl --user start "${UNIT_NAME}.service"
  ok "started for now (not enabled at login)"
fi

for _ in $(seq 1 40); do
  curl -fsS --max-time 3 "http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" >/dev/null 2>&1 && break
  sleep 1
done
if curl -fsS --max-time 3 "http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" >/dev/null 2>&1; then
  ok "bridge healthy: $(curl -fsS --max-time 3 "http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" | jq -c '{catalog, loaded}')"
else
  warn "bridge is not answering on ${BRIDGE_PORT} - check: systemctl --user status ${UNIT_NAME}"
fi

# ----------------------------------------------- 5. register with Lemonade ----
step "Registering '${PROVIDER}' as a Lemonade provider"
if lemonade cloud install "$PROVIDER" \
      --base-url "http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1" \
      --api-key "$API_KEY" \
      --allow-insecure-http; then
  ok "provider '${PROVIDER}' -> http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1"
else
  die "lemonade cloud install failed - is lemond running on :${LEMOND_PORT}, and is this CLI >= 11.x?"
fi

# Optional: pin the key in lemond's own environment (root). Not required: the
# bridge re-registers itself, which restores the in-memory key after a restart.
if [ "$WITH_ENV_KEY" = 1 ] || { [ -z "${SUDO_SKIP:-}" ] && sudo -n true 2>/dev/null; }; then
  step "Persisting ${ENV_KEY} for the lemond service (optional)"
  case "$LEMOND_SCOPE" in
    system)
      if [ -f /etc/default/lemond ] && grep -qF "${ENV_KEY}=" /etc/default/lemond; then
        ok "/etc/default/lemond already sets ${ENV_KEY}"
      elif sudo tee -a /etc/default/lemond >/dev/null <<EOF

# added by gufo-cli/lemonade-backend
${ENV_KEY}=${API_KEY}
EOF
      then
        ok "appended ${ENV_KEY} to /etc/default/lemond"
      fi
      ;;
    user)
      dir="${HOME}/.config/systemd/user/lemond.service.d"
      drop="${dir}/gufo-${PROVIDER}.conf"
      run mkdir -p "$dir"
      printf '[Service]\nEnvironment=%s=%s\n' "$ENV_KEY" "$API_KEY" > "$drop"
      run systemctl --user daemon-reload
      ok "wrote $drop"
      ;;
    *)
      warn "lemond is not a systemd unit here; set ${ENV_KEY}=${API_KEY} in its environment if you want it pinned"
      ;;
  esac
else
  step "Skipping the root-only step (nothing to do)"
  ok "the bridge re-registers itself after a lemond restart, so ${ENV_KEY} is not needed"
  printf '       (pinned alternative: ./install.sh --with-env-key, which writes %s to /etc)\n' "$ENV_KEY"
fi

if [ "$RESTART_LEMOND" = 1 ]; then
  step "Restarting lemond (--restart-lemond)"
  case "$LEMOND_SCOPE" in
    system) sudo systemctl restart lemond ;;
    user)   systemctl --user restart lemond ;;
    *)      warn "lemond is not managed by systemd here; restart it yourself" ;;
  esac
  for _ in $(seq 1 40); do
    curl -fsS --max-time 3 "http://127.0.0.1:${LEMOND_PORT}/v1/models" >/dev/null 2>&1 && break
    sleep 1
  done
  ok "lemond is back up (previously loaded models are unloaded)"
fi

# ------------------------------------------------------------- 7. verify ----
step "Verifying that Lemonade publishes the Gufo models"
sleep 2
PUBLISHED="$(curl -fsS --max-time 30 "http://127.0.0.1:${LEMOND_PORT}/v1/models" \
  | jq -r --arg p "${PROVIDER}." '.data[]?.id | select(startswith($p))' || true)"
if [ -n "$PUBLISHED" ]; then
  printf '%s\n' "$PUBLISHED" | sed 's/^/       /'
  ok "$(printf '%s\n' "$PUBLISHED" | grep -c .) model(s) visible to every Lemonade client"
else
  warn "no '${PROVIDER}.*' models in /v1/models yet"
  warn "  models found by the bridge : gufo-lemonade models"
  warn "  retry publishing          : gufo-lemonade refresh"
fi

# Smoke test only when a model is already loaded - do not block on a cold load.
RUNNING_MODEL="$(printf '%s\n' "$PUBLISHED" | head -1)"
if [ -n "$RUNNING_MODEL" ] \
   && curl -fsS --max-time 5 "http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" 2>/dev/null | grep -q '"loaded":\[[^]]'; then
  step "Smoke test: Lemonade -> bridge -> gufo container ('${RUNNING_MODEL}')"
  if curl -fsS --max-time 240 "http://127.0.0.1:${LEMOND_PORT}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${RUNNING_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: GUFO-OK\"}],\"max_tokens\":4096}" \
        | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
    ok "chat completion round-tripped through Lemonade"
  else
    warn "smoke test failed - gufo-lemonade status; journalctl --user -u ${UNIT_NAME} -n 50"
  fi
fi

cat <<DONE

${c_grn}Done.${c_rst} Lemonade now serves Gufo as the '${PROVIDER}' provider.

  gufo-lemonade models      # GGUF catalog and load state
  gufo-lemonade load <id>   # warm a model now (recommended before chatting)
  gufo-lemonade status      # bridge + Lemonade view
  gufo-lemonade refresh     # re-publish after adding or removing GGUF files

In the Lemonade app: pick '${PROVIDER}.<model>'. The first request starts a
container, which can take minutes for a large model; if that request returns a
503 saying the model is still loading, the load continues in the background -
send the message again once 'gufo-lemonade status' shows it running.

Uninstall with: ${SCRIPT_DIR}/uninstall.sh
DONE
