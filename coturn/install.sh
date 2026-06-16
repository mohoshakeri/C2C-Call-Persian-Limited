#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================
# Coturn Stun Turn Installer
# ==============================

# Configuration Defaults
TURN_DOMAIN="${TURN_DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ENABLE_TLS="${ENABLE_TLS:-true}"
STRICT_DNS="${STRICT_DNS:-false}"
UFW_ENABLE="${UFW_ENABLE:-true}"

TURN_USER="${TURN_USER:-mirotalk}"
TURN_PASSWORD="${TURN_PASSWORD:-}"

TURN_PORT="${TURN_PORT:-3478}"
TURNS_PORT="${TURNS_PORT:-5349}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49200}"

PUBLIC_IP_OVERRIDE="${PUBLIC_IP_OVERRIDE:-}"
LISTENING_IP="${LISTENING_IP:-0.0.0.0}"

# Print Info Message
info() {
  echo -e "\033[1;34m[Info]\033[0m $*"
}

# Print Success Message
success() {
  echo -e "\033[1;32m[Ok]\033[0m $*"
}

# Print Warning Message
warn() {
  echo -e "\033[1;33m[Warn]\033[0m $*"
}

# Print Error Message
die() {
  echo -e "\033[1;31m[Error]\033[0m $*" >&2
  exit 1
}

# Require Root Privileges
if [ "${EUID}" -ne 0 ]; then
  die "Please Run This Script With Sudo Or As Root"
fi

# Require Apt Based Linux
if ! command -v apt-get >/dev/null 2>&1; then
  die "This Script Is Designed For Ubuntu Or Debian Based Servers"
fi

# Normalize Domain Value
TURN_DOMAIN="${TURN_DOMAIN#http://}"
TURN_DOMAIN="${TURN_DOMAIN#https://}"
TURN_DOMAIN="${TURN_DOMAIN%%/*}"

# Install Base Dependencies
info "Installing Base Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  coturn \
  ufw \
  openssl \
  dnsutils \
  iproute2 \
  certbot

# Detect Public IPv4
detect_public_ip() {
  if [ -n "$PUBLIC_IP_OVERRIDE" ]; then
    echo "$PUBLIC_IP_OVERRIDE"
    return 0
  fi

  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"

  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me/ip || true)"
  fi

  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsS --max-time 8 https://icanhazip.com || true)"
  fi

  echo "$ip" | tr -d '[:space:]'
}

PUBLIC_IP="$(detect_public_ip)"

if ! [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "Could Not Detect A Valid Public IPv4 Address"
fi

# Detect Local Outbound IPv4
LOCAL_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"

if [ -z "$LOCAL_IPV4" ]; then
  LOCAL_IPV4="$PUBLIC_IP"
fi

# Generate Turn Password
if [ -z "$TURN_PASSWORD" ]; then
  TURN_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)"
fi

# Decide Turn Host
if [ -n "$TURN_DOMAIN" ]; then
  TURN_HOST="$TURN_DOMAIN"
else
  TURN_HOST="$PUBLIC_IP"
  ENABLE_TLS="false"
  warn "TURN_DOMAIN Is Empty. The Installer Will Use Public IP Without TLS"
fi

# Resolve A Record
resolve_domain_ipv4() {
  local domain="$1"
  dig +short A "$domain" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | tail -n 1 || true
}

# Check Dns
TLS_READY="false"

if [ -n "$TURN_DOMAIN" ]; then
  TURN_RESOLVED_IP="$(resolve_domain_ipv4 "$TURN_DOMAIN")"

  if [ "$TURN_RESOLVED_IP" = "$PUBLIC_IP" ]; then
    success "TURN_DOMAIN Resolves To This Server IP"
    TLS_READY="true"
  else
    warn "TURN_DOMAIN Does Not Resolve To This Server IP Yet"
    warn "Domain: $TURN_DOMAIN"
    warn "Resolved: ${TURN_RESOLVED_IP:-Empty}"
    warn "Expected: $PUBLIC_IP"

    if [ "$STRICT_DNS" = "true" ]; then
      die "DNS Check Failed And STRICT_DNS=true"
    fi
  fi
fi

# Configure Coturn Relay Address
if [ "$LOCAL_IPV4" = "$PUBLIC_IP" ]; then
  COTURN_EXTERNAL_LINE="external-ip=$PUBLIC_IP"
else
  COTURN_EXTERNAL_LINE="external-ip=$PUBLIC_IP/$LOCAL_IPV4"
fi

# Prepare Tls Certificate Paths
CERT_FILE=""
PKEY_FILE=""
TLS_INSTALLED="false"

if [ "$ENABLE_TLS" = "true" ] && [ "$TLS_READY" = "true" ]; then
  if [ -z "$ADMIN_EMAIL" ]; then
    warn "ADMIN_EMAIL Is Empty. Skipping TLS Certificate"
  else
    info "Requesting Let's Encrypt Certificate For TURN TLS"
    certbot certonly \
      --standalone \
      --non-interactive \
      --agree-tos \
      --email "$ADMIN_EMAIL" \
      -d "$TURN_DOMAIN"

    CERT_FILE="/etc/letsencrypt/live/$TURN_DOMAIN/fullchain.pem"
    PKEY_FILE="/etc/letsencrypt/live/$TURN_DOMAIN/privkey.pem"
    TLS_INSTALLED="true"
  fi
fi

# Write Coturn Configuration
info "Writing Coturn Configuration"

cat > /etc/turnserver.conf <<EOF
listening-port=$TURN_PORT
tls-listening-port=$TURNS_PORT

listening-ip=$LISTENING_IP
relay-ip=$LOCAL_IPV4
$COTURN_EXTERNAL_LINE

min-port=$TURN_MIN_PORT
max-port=$TURN_MAX_PORT

fingerprint
lt-cred-mech
stale-nonce=600

realm=$TURN_HOST
server-name=$TURN_HOST

user=$TURN_USER:$TURN_PASSWORD

no-loopback-peers
no-multicast-peers
no-cli

simple-log
log-file=/var/log/turnserver.log
EOF

if [ "$TLS_INSTALLED" = "true" ]; then
  cat >> /etc/turnserver.conf <<EOF

cert=$CERT_FILE
pkey=$PKEY_FILE
no-tlsv1
no-tlsv1_1
EOF
fi

chmod 600 /etc/turnserver.conf

# Enable Coturn Service
info "Enabling Coturn Service"

if [ -f /etc/default/coturn ]; then
  if grep -q '^#TURNSERVER_ENABLED=1' /etc/default/coturn; then
    sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
  fi

  grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
fi

# Configure Firewall
if [ "$UFW_ENABLE" = "true" ]; then
  info "Configuring UFW Firewall"
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow "$TURN_PORT/tcp"
  ufw allow "$TURN_PORT/udp"
  ufw allow "$TURNS_PORT/tcp"
  ufw allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp"
  ufw --force enable
else
  warn "Skipping UFW Because UFW_ENABLE=false"
fi

# Start Coturn
info "Starting Coturn"
systemctl daemon-reload
systemctl enable coturn
systemctl restart coturn

sleep 2

if systemctl is-active --quiet coturn; then
  success "Coturn Is Running"
else
  systemctl --no-pager --full status coturn || true
  die "Coturn Failed To Start"
fi

# Save Output File
OUTPUT_FILE="/root/coturn-stun-turn-output.txt"

cat > "$OUTPUT_FILE" <<EOF
Coturn STUN/TURN Installation Finished

Public IPv4:
$PUBLIC_IP

Local Outbound IPv4:
$LOCAL_IPV4

TURN Host:
$TURN_HOST

Plain STUN/TURN:
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:$TURN_HOST:$TURN_PORT

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:$TURN_HOST:$TURN_PORT
TURN_SERVER_USERNAME=$TURN_USER
TURN_SERVER_CREDENTIAL=$TURN_PASSWORD

TLS TURN:
TURN_SERVER_URL_TLS=turns:$TURN_HOST:$TURNS_PORT

Ports To Open In Provider Firewall:
22/tcp
80/tcp
$TURN_PORT/tcp
$TURN_PORT/udp
$TURNS_PORT/tcp
$TURN_MIN_PORT-$TURN_MAX_PORT/udp

Service Commands:
sudo systemctl status coturn
sudo systemctl restart coturn
sudo tail -f /var/log/turnserver.log

Config File:
sudo nano /etc/turnserver.conf
EOF

# Final Output
echo ""
echo "============================================================"
echo "Coturn STUN/TURN Installation Finished"
echo "============================================================"
echo ""
cat "$OUTPUT_FILE"
echo ""
echo "Output Saved To:"
echo "$OUTPUT_FILE"
echo ""
echo "============================================================"
