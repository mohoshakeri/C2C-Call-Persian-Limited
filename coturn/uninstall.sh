#!/usr/bin/env bash

set -Eeuo pipefail

# Remove coturn installation artifacts created by install.sh.
# By default this removes coturn config, systemd override, logs, DB, and package.
# It does not delete Let's Encrypt certs unless REMOVE_CERTS=true and TURN_DOMAIN is set.

TURN_DOMAIN="${TURN_DOMAIN:-}"
TURN_PORT="${TURN_PORT:-3478}"
TURNS_PORT="${TURNS_PORT:-5349}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"
UFW_CLEANUP="${UFW_CLEANUP:-true}"
PURGE_PACKAGE="${PURGE_PACKAGE:-true}"
REMOVE_CERTS="${REMOVE_CERTS:-false}"
REMOVE_LOGS="${REMOVE_LOGS:-true}"
UFW_DISABLE_IF_INSTALLED="${UFW_DISABLE_IF_INSTALLED:-true}"
STATE_FILE="/var/lib/coturn-installer/state.env"

info() { printf '\033[1;34m[Info]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[Ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Warn]\033[0m %s\n' "$*"; }

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash uninstall.sh" >&2
  exit 1
fi

TURN_DOMAIN="${TURN_DOMAIN#http://}"
TURN_DOMAIN="${TURN_DOMAIN#https://}"
TURN_DOMAIN="${TURN_DOMAIN%%/*}"

if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

info "Stopping coturn"
systemctl stop coturn 2>/dev/null || true
systemctl disable coturn 2>/dev/null || true

info "Removing systemd override"
rm -f /etc/systemd/system/coturn.service.d/override.conf
rmdir /etc/systemd/system/coturn.service.d 2>/dev/null || true
systemctl daemon-reload

if [ "$UFW_CLEANUP" = "true" ] && command -v ufw >/dev/null 2>&1; then
  info "Removing UFW rules added by installer when present"
  ufw --force delete allow "$TURN_PORT/tcp" 2>/dev/null || true
  ufw --force delete allow "$TURN_PORT/udp" 2>/dev/null || true
  ufw --force delete allow "$TURNS_PORT/tcp" 2>/dev/null || true
  ufw --force delete allow 80/tcp 2>/dev/null || true
  ufw --force delete allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp" 2>/dev/null || true
  if [ "$UFW_DISABLE_IF_INSTALLED" = "true" ] && [ "${UFW_WAS_ACTIVE:-unknown}" = "false" ]; then
    info "Disabling UFW because installer enabled it from an inactive state"
    ufw --force disable 2>/dev/null || true
  fi
fi

info "Removing coturn config, DB, and generated output"
rm -f /etc/turnserver.conf
rm -f /etc/default/coturn
rm -f /root/coturn-stun-turn-output.txt
rm -rf /var/lib/turn
rm -rf /var/lib/coturn-installer

if [ "$REMOVE_LOGS" = "true" ]; then
  info "Removing coturn logs and temporary debug captures"
  rm -f /var/log/turnserver.log /var/log/turn_*.log /var/tmp/turn_*.log /tmp/turn_*.log /tmp/turn*.pcap
  rm -rf /tmp/turn-live-check-* /tmp/coturn-debug-*
fi

if [ "$REMOVE_CERTS" = "true" ] && [ -n "$TURN_DOMAIN" ]; then
  if command -v certbot >/dev/null 2>&1; then
    info "Removing Let's Encrypt certificate for $TURN_DOMAIN"
    certbot delete --cert-name "$TURN_DOMAIN" --non-interactive 2>/dev/null || true
  else
    warn "certbot not found; certificate cleanup skipped"
  fi
else
  warn "Let's Encrypt certificates left intact. Set REMOVE_CERTS=true TURN_DOMAIN=... to delete them."
fi

if [ "$PURGE_PACKAGE" = "true" ] && command -v apt-get >/dev/null 2>&1; then
  info "Purging coturn package"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y coturn || true
  apt-get autoremove -y || true
else
  warn "coturn package left installed because PURGE_PACKAGE=false or apt-get is unavailable"
fi

systemctl daemon-reload
success "coturn uninstall completed"
