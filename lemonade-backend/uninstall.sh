#!/usr/bin/env bash
#
# uninstall.sh — remove the Gufo <-> Lemonade bridge.
#
#   ./uninstall.sh                  # unregister the provider, stop + remove the bridge
#   ./uninstall.sh --provider gufo  # if you installed under another provider name
#   ./uninstall.sh --stop-models    # also stop every running gufo container
#   ./uninstall.sh --purge          # also remove ~/.local/bin/{gufo,gufo-lemonade} and config
#
set -euo pipefail

PROVIDER="gufo"
STOP_MODELS=0
PURGE=0
RESTART_LEMOND=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
UNIT_NAME="gufo-lemonade"
UNIT_FILE="${HOME}/.config/systemd/user/${UNIT_NAME}.service"
BRIDGE_PORT="${GUFO_LEMONADE_PORT:-13399}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_blu" "$*" "$c_rst"; }
ok()   { printf '%s  ✔ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s  ! %s%s\n' "$c_ylw" "$*" "$c_rst"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --provider)     PROVIDER="${2:-}"; shift 2 ;;
    --port)         BRIDGE_PORT="${2:-}"; shift 2 ;;
    --stop-models)  STOP_MODELS=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --no-restart)   RESTART_LEMOND=0; shift ;;
    -h|--help)      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              printf '%sunknown option: %s%s\n' "$c_red" "$1" "$c_rst" >&2; exit 1 ;;
  esac
done
ENV_KEY="LEMONADE_$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"

step "Unregistering the '${PROVIDER}' provider from Lemonade"
if command -v lemonade >/dev/null; then
  lemonade cloud uninstall "$PROVIDER" && ok "provider removed" \
    || warn "lemonade cloud uninstall ${PROVIDER} failed (was it installed?)"
else
  warn "lemonade CLI not found; skipping"
fi

step "Stopping and removing the bridge service"
if systemctl --user list-unit-files 2>/dev/null | grep -q "^${UNIT_NAME}\.service"; then
  systemctl --user disable --now "${UNIT_NAME}.service" 2>/dev/null || true
  ok "service stopped + disabled"
fi
rm -f "$UNIT_FILE"
rm -f "${HOME}/.config/systemd/user/${UNIT_NAME}.service.d"/*.conf 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
ok "${UNIT_FILE} removed"

step "Removing ${ENV_KEY} from lemond's environment"
if [ -f /etc/default/lemond ] && grep -qF "${ENV_KEY}=" /etc/default/lemond; then
  if command -v sudo >/dev/null; then
    sudo sed -i "/^${ENV_KEY}=/d" /etc/default/lemond && ok "cleaned /etc/default/lemond"
  else
    warn "remove '${ENV_KEY}=...' from /etc/default/lemond yourself"
  fi
fi
DROP="${HOME}/.config/systemd/user/lemond.service.d/gufo-${PROVIDER}.conf"
if [ -f "$DROP" ]; then
  rm -f "$DROP" && ok "removed ${DROP}"
fi

if [ "$RESTART_LEMOND" = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^lemond\.service'; then
  step "Restarting lemond to drop the environment variable"
  sudo systemctl restart lemond && ok "lemond restarted"
fi

if [ "$STOP_MODELS" = 1 ] && command -v gufo >/dev/null; then
  step "Stopping gufo containers"
  gufo stop all || warn "gufo stop all reported a problem"
fi

if [ "$PURGE" = 1 ]; then
  step "Purging installed tools and configuration"
  rm -f "${BIN_DIR}/gufo-lemonade"
  rm -f "${BIN_DIR}/gufo"
  rm -rf "${HOME}/.config/gufo-lemonade"
  ok "removed ${BIN_DIR}/{gufo,gufo-lemonade} and ~/.config/gufo-lemonade"
else
  warn "kept ${BIN_DIR}/gufo*, ~/.config/gufo-lemonade and any running model containers"
fi

printf '\n%sDone.%s Lemonade no longer advertises %s.* models.\n' "$c_grn" "$c_rst" "$PROVIDER"
