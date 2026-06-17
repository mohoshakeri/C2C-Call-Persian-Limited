#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================
# Authenticated coturn installer
# ==============================
# Installs coturn for WebRTC STUN/TURN use and forces authenticated TURN mode
# through both /etc/turnserver.conf and a systemd ExecStart override.

TURN_DOMAIN="${TURN_DOMAIN:-}"
TURN_REALM="${TURN_REALM:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ENABLE_TLS="${ENABLE_TLS:-true}"
STRICT_DNS="${STRICT_DNS:-false}"
UFW_ENABLE="${UFW_ENABLE:-true}"
TURN_VERBOSE="${TURN_VERBOSE:-false}"

TURN_USER="${TURN_USER:-mirotalk}"
TURN_PASSWORD="${TURN_PASSWORD:-}"

TURN_PORT="${TURN_PORT:-3478}"
TURNS_PORT="${TURNS_PORT:-5349}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"

PUBLIC_IP_OVERRIDE="${PUBLIC_IP_OVERRIDE:-}"
LISTENING_IP="${LISTENING_IP:-0.0.0.0}"
LOG_FILE="${LOG_FILE:-/var/log/turnserver.log}"
CONF_FILE="${CONF_FILE:-/etc/turnserver.conf}"
DROPIN_DIR="/etc/systemd/system/coturn.service.d"
DROPIN_FILE="$DROPIN_DIR/override.conf"
OUTPUT_FILE="${OUTPUT_FILE:-/root/coturn-stun-turn-output.txt}"
STATE_DIR="/var/lib/coturn-installer"
STATE_FILE="$STATE_DIR/state.env"
UFW_WAS_ACTIVE="unknown"

info() { printf '\033[1;34m[Info]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[Ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Warn]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[Error]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    die "Please run this script with sudo or as root"
  fi
}

normalize_host() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s' "$value"
}

validate_port() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    die "$name must be a TCP/UDP port between 1 and 65535"
  fi
}

validate_inputs() {
  validate_port TURN_PORT "$TURN_PORT"
  validate_port TURNS_PORT "$TURNS_PORT"
  validate_port TURN_MIN_PORT "$TURN_MIN_PORT"
  validate_port TURN_MAX_PORT "$TURN_MAX_PORT"

  if [ "$TURN_MIN_PORT" -gt "$TURN_MAX_PORT" ]; then
    die "TURN_MIN_PORT must be lower than or equal to TURN_MAX_PORT"
  fi

  if ! [[ "$TURN_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "TURN_USER may contain only letters, digits, dot, underscore, and dash"
  fi

  if [ -n "$TURN_PASSWORD" ] && ! [[ "$TURN_PASSWORD" =~ ^[A-Za-z0-9._~@#=+-]+$ ]]; then
    die "TURN_PASSWORD contains unsafe characters for coturn static credentials. Use letters, digits, . _ ~ @ # = + -"
  fi
}

detect_public_ip() {
  if [ -n "$PUBLIC_IP_OVERRIDE" ]; then
    printf '%s' "$PUBLIC_IP_OVERRIDE"
    return 0
  fi

  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
  if [ -z "$ip" ]; then ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip || true)"; fi
  if [ -z "$ip" ]; then ip="$(curl -4 -fsS --max-time 8 https://icanhazip.com || true)"; fi
  printf '%s' "$ip" | tr -d '[:space:]'
}

resolve_domain_ipv4() {
  local domain="$1"
  dig +short A "$domain" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | tail -n 1 || true
}

write_turnserver_config() {
  local cert_file="$1"
  local pkey_file="$2"
  local tls_installed="$3"

  info "Writing $CONF_FILE"
  cat > "$CONF_FILE" <<EOF
listening-port=$TURN_PORT
listening-ip=$LISTENING_IP

relay-ip=$LOCAL_IPV4
external-ip=$EXTERNAL_IP

min-port=$TURN_MIN_PORT
max-port=$TURN_MAX_PORT

fingerprint
lt-cred-mech
stale-nonce=600

realm=$TURN_HOST
server-name=$TURN_HOST
user=$TURN_USER:$TURN_PASSWORD

no-cli
simple-log
log-file=$LOG_FILE
EOF

  if [ "$TURN_VERBOSE" = "true" ]; then
    echo "verbose" >> "$CONF_FILE"
  fi

  if [ "$tls_installed" = "true" ]; then
    cat >> "$CONF_FILE" <<EOF

tls-listening-port=$TURNS_PORT
cert=$cert_file
pkey=$pkey_file
no-tlsv1
no-tlsv1_1
EOF
  fi

  chmod 600 "$CONF_FILE"
}

write_systemd_override() {
  local cert_file="$1"
  local pkey_file="$2"
  local tls_installed="$3"

  info "Writing authenticated systemd override: $DROPIN_FILE"
  mkdir -p "$DROPIN_DIR"

  cat > "$DROPIN_FILE" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/turnserver \\
  --listening-port=$TURN_PORT \\
  --listening-ip=$LISTENING_IP \\
  --relay-ip=$LOCAL_IPV4 \\
  --external-ip=$EXTERNAL_IP \\
  --min-port=$TURN_MIN_PORT \\
  --max-port=$TURN_MAX_PORT \\
  --fingerprint \\
  --lt-cred-mech \\
  --stale-nonce=600 \\
  --realm=$TURN_HOST \\
  --server-name=$TURN_HOST \\
  --user=$TURN_USER:$TURN_PASSWORD \\
  --no-cli \\
  --simple-log \\
  --log-file=$LOG_FILE \\
EOF

  if [ "$TURN_VERBOSE" = "true" ]; then
    cat >> "$DROPIN_FILE" <<EOF
  --verbose \\
EOF
  fi

  if [ "$tls_installed" = "true" ]; then
    cat >> "$DROPIN_FILE" <<EOF
  --tls-listening-port=$TURNS_PORT \\
  --cert=$cert_file \\
  --pkey=$pkey_file \\
  --no-tlsv1 \\
  --no-tlsv1_1 \\
EOF
  fi

  cat >> "$DROPIN_FILE" <<EOF
  --pidfile=
EOF
}

sync_turn_database_user() {
  if ! command -v turnadmin >/dev/null 2>&1; then
    warn "turnadmin not found; skipping SQLite credential sync"
    return 0
  fi

  info "Syncing TURN user in SQLite DB as a fallback auth source"
  mkdir -p /var/lib/turn
  turnadmin -d -u "$TURN_USER" -r "$TURN_HOST" --db=/var/lib/turn/turndb >/dev/null 2>&1 || true
  if turnadmin -a -u "$TURN_USER" -p "$TURN_PASSWORD" -r "$TURN_HOST" --db=/var/lib/turn/turndb; then
    success "TURN user synced in /var/lib/turn/turndb"
  else
    warn "Could not sync TURN user into /var/lib/turn/turndb; static --user auth is still configured"
  fi
}

configure_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      UFW_WAS_ACTIVE="true"
    else
      UFW_WAS_ACTIVE="false"
    fi
  fi

  if [ "$UFW_ENABLE" != "true" ]; then
    warn "Skipping UFW because UFW_ENABLE=false"
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw command not found; skipping local firewall setup"
    return 0
  fi

  info "Configuring UFW firewall"
  ufw allow OpenSSH
  ufw allow "$TURN_PORT/tcp"
  ufw allow "$TURN_PORT/udp"
  ufw allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp"
  if [ "$TLS_INSTALLED" = "true" ]; then
    ufw allow 80/tcp
    ufw allow "$TURNS_PORT/tcp"
  fi
  ufw --force enable
}

enable_coturn_default() {
  if [ -f /etc/default/coturn ]; then
    if grep -q '^#TURNSERVER_ENABLED=1' /etc/default/coturn; then
      sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
    fi
    grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
  fi
}

write_state_file() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
TURN_HOST=$TURN_HOST
TURN_PORT=$TURN_PORT
TURNS_PORT=$TURNS_PORT
TURN_MIN_PORT=$TURN_MIN_PORT
TURN_MAX_PORT=$TURN_MAX_PORT
TLS_INSTALLED=$TLS_INSTALLED
UFW_ENABLE=$UFW_ENABLE
UFW_WAS_ACTIVE=$UFW_WAS_ACTIVE
LOG_FILE=$LOG_FILE
CONF_FILE=$CONF_FILE
DROPIN_FILE=$DROPIN_FILE
OUTPUT_FILE=$OUTPUT_FILE
EOF
  chmod 600 "$STATE_FILE"
}

restart_and_verify() {
  info "Starting coturn"
  systemctl daemon-reload
  systemctl enable coturn
  systemctl restart coturn
  sleep 2

  if ! systemctl is-active --quiet coturn; then
    systemctl --no-pager --full status coturn || true
    die "coturn failed to start"
  fi

  local cmdline
  cmdline="$(pgrep -a turnserver || true)"
  printf '%s\n' "$cmdline"
  if ! printf '%s\n' "$cmdline" | grep -q -- '--lt-cred-mech'; then
    die "coturn is running, but --lt-cred-mech is missing from the active command line"
  fi
  if printf '%s\n' "$cmdline" | grep -q -- '--no-auth'; then
    die "coturn is running with --no-auth; refusing anonymous TURN allocation"
  fi

  success "coturn is running in authenticated TURN mode"
}

write_output() {
  local tls_url="not installed"
  if [ "$TLS_INSTALLED" = "true" ]; then
    tls_url="turns:$TURN_HOST:$TURNS_PORT?transport=tcp"
  fi

  cat > "$OUTPUT_FILE" <<EOF
Coturn STUN/TURN Installation Finished

Public IPv4:
$PUBLIC_IP

Local Outbound IPv4:
$LOCAL_IPV4

TURN Host / Realm:
$TURN_HOST

Plain STUN/TURN for MiroTalk:
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:$TURN_HOST:$TURN_PORT

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:$TURN_HOST:$TURN_PORT?transport=udp
TURN_SERVER_USERNAME=$TURN_USER
TURN_SERVER_CREDENTIAL=$TURN_PASSWORD

TCP TURN fallback:
TURN_SERVER_URL_TCP=turn:$TURN_HOST:$TURN_PORT?transport=tcp

TLS TURN:
TURN_SERVER_URL_TLS=$tls_url

Ports to open in provider firewall:
$TURN_PORT/tcp
$TURN_PORT/udp
$TURN_MIN_PORT-$TURN_MAX_PORT/udp
$(if [ "$TLS_INSTALLED" = "true" ]; then printf '%s/tcp\n80/tcp\n' "$TURNS_PORT"; fi)

Verification:
1. Open the browser Trickle ICE test page.
2. Use URL: turn:$TURN_HOST:$TURN_PORT?transport=udp
3. Use username: $TURN_USER
4. Use password: $TURN_PASSWORD
5. A relay candidate means TURN works.

Low-level auth sanity check:
The first unauthenticated Allocate response should be STUN 0113 (401 challenge), not 0103 (anonymous success).
Use debug.sh if relay candidates are not produced.

Service commands:
sudo systemctl status coturn
sudo systemctl restart coturn
sudo journalctl -u coturn -n 100 --no-pager

Config files:
$CONF_FILE
$DROPIN_FILE

Uninstall:
sudo bash uninstall.sh
EOF
}

main() {
  require_root

  if ! command -v apt-get >/dev/null 2>&1; then
    die "This installer is designed for Ubuntu/Debian servers with apt-get"
  fi

  TURN_DOMAIN="$(normalize_host "$TURN_DOMAIN")"
  TURN_REALM="$(normalize_host "$TURN_REALM")"
  validate_inputs

  info "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release coturn ufw openssl dnsutils iproute2 certbot

  PUBLIC_IP="$(detect_public_ip)"
  if ! [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "Could not detect a valid public IPv4 address. Set PUBLIC_IP_OVERRIDE and rerun."
  fi

  LOCAL_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [ -z "$LOCAL_IPV4" ]; then
    LOCAL_IPV4="$PUBLIC_IP"
  fi

  if [ -z "$TURN_PASSWORD" ]; then
    TURN_PASSWORD="$(openssl rand -hex 24)"
  fi
  validate_inputs

  if [ -n "$TURN_REALM" ]; then
    TURN_HOST="$TURN_REALM"
  elif [ -n "$TURN_DOMAIN" ]; then
    TURN_HOST="$TURN_DOMAIN"
  else
    TURN_HOST="$PUBLIC_IP"
    ENABLE_TLS="false"
    warn "TURN_DOMAIN is empty. Using public IP without TLS."
  fi

  if [ "$LOCAL_IPV4" = "$PUBLIC_IP" ]; then
    EXTERNAL_IP="$PUBLIC_IP"
  else
    EXTERNAL_IP="$PUBLIC_IP/$LOCAL_IPV4"
  fi

  TLS_READY="false"
  if [ -n "$TURN_DOMAIN" ]; then
    TURN_RESOLVED_IP="$(resolve_domain_ipv4 "$TURN_DOMAIN")"
    if [ "$TURN_RESOLVED_IP" = "$PUBLIC_IP" ]; then
      success "TURN_DOMAIN resolves to this server IP"
      TLS_READY="true"
    else
      warn "TURN_DOMAIN does not resolve to this server IP yet"
      warn "Domain: $TURN_DOMAIN"
      warn "Resolved: ${TURN_RESOLVED_IP:-empty}"
      warn "Expected: $PUBLIC_IP"
      if [ "$STRICT_DNS" = "true" ]; then
        die "DNS check failed and STRICT_DNS=true"
      fi
    fi
  fi

  CERT_FILE=""
  PKEY_FILE=""
  TLS_INSTALLED="false"
  if [ "$ENABLE_TLS" = "true" ] && [ "$TLS_READY" = "true" ]; then
    if [ -z "$ADMIN_EMAIL" ]; then
      warn "ADMIN_EMAIL is empty. Skipping TLS certificate."
    else
      info "Requesting Let's Encrypt certificate for TURN TLS"
      certbot certonly --standalone --non-interactive --agree-tos --email "$ADMIN_EMAIL" -d "$TURN_DOMAIN"
      CERT_FILE="/etc/letsencrypt/live/$TURN_DOMAIN/fullchain.pem"
      PKEY_FILE="/etc/letsencrypt/live/$TURN_DOMAIN/privkey.pem"
      TLS_INSTALLED="true"
    fi
  fi

  write_turnserver_config "$CERT_FILE" "$PKEY_FILE" "$TLS_INSTALLED"
  write_systemd_override "$CERT_FILE" "$PKEY_FILE" "$TLS_INSTALLED"
  sync_turn_database_user
  enable_coturn_default

  touch "$LOG_FILE" || true
  chown turnserver:turnserver "$LOG_FILE" 2>/dev/null || true
  chmod 640 "$LOG_FILE" 2>/dev/null || true

  configure_ufw
  write_state_file
  restart_and_verify
  write_output

  echo ""
  echo "============================================================"
  echo "Coturn STUN/TURN Installation Finished"
  echo "============================================================"
  echo ""
  cat "$OUTPUT_FILE"
  echo ""
  echo "Output saved to: $OUTPUT_FILE"
  echo "============================================================"
}

main "$@"
