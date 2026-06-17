#!/usr/bin/env bash

set -Eeuo pipefail

# Comprehensive coturn diagnostic collector.
# Run on the TURN server. While packet capture is running, run a browser TURN test.

TURN_PORT="${TURN_PORT:-3478}"
TURNS_PORT="${TURNS_PORT:-5349}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-25}"
OUT_DIR="${OUT_DIR:-/tmp/coturn-debug-$(date +%Y%m%d-%H%M%S)}"
CONF_FILE="${CONF_FILE:-/etc/turnserver.conf}"
DROPIN_FILE="/etc/systemd/system/coturn.service.d/override.conf"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash debug.sh" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
exec > >(tee "$OUT_DIR/debug.log") 2>&1

section() {
  echo
  echo "========== $* =========="
}

run_cmd() {
  echo "\$ $*"
  "$@" || true
}

read_file() {
  local file="$1"
  if [ -f "$file" ]; then
    echo "--- $file ---"
    sed -n '1,260p' "$file" || true
  else
    echo "--- $file missing ---"
  fi
}

TURN_PID="$(pgrep -xo turnserver || true)"
ACTIVE_LOG_FD=""
ACTIVE_LOG_TARGET=""
if [ -n "$TURN_PID" ]; then
  ACTIVE_LOG_FD="$(
    find "/proc/$TURN_PID/fd" -maxdepth 1 -type l -printf '%p -> %l\n' 2>/dev/null \
      | grep -E '/(var/log|var/tmp|tmp)/turn.*\.log( \(deleted\))?$' \
      | head -n 1 \
      | awk '{print $1}' || true
  )"
  if [ -n "$ACTIVE_LOG_FD" ]; then
    ACTIVE_LOG_TARGET="$(readlink "$ACTIVE_LOG_FD" || true)"
  fi
fi

section "Summary"
echo "Output directory: $OUT_DIR"
echo "UTC date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "turnserver PID: ${TURN_PID:-not running}"
echo "active log fd: ${ACTIVE_LOG_FD:-not found}"
echo "active log target: ${ACTIVE_LOG_TARGET:-not found}"

section "Operating System"
read_file /etc/os-release
run_cmd uname -a
run_cmd uptime

section "Packages And Versions"
run_cmd dpkg -l coturn
run_cmd turnserver -V
run_cmd turnadmin --help

section "Network"
run_cmd ip -br addr
run_cmd ip -4 route
run_cmd ip -6 route
if command -v curl >/dev/null 2>&1; then
  echo "Public IPv4 checks:"
  curl -4 -fsS --max-time 5 https://api.ipify.org || true
  echo
  curl -4 -fsS --max-time 5 https://icanhazip.com || true
  echo
fi
run_cmd ss -luntp

section "Service"
run_cmd systemctl --no-pager --full status coturn
run_cmd systemctl cat coturn
run_cmd systemctl show coturn -p FragmentPath -p DropInPaths -p ExecStart -p User -p Group -p WorkingDirectory

section "Process"
run_cmd pgrep -a turnserver
if [ -n "$TURN_PID" ]; then
  echo "Command line:"
  tr '\0' ' ' < "/proc/$TURN_PID/cmdline" || true
  echo
  echo "Open files:"
  find "/proc/$TURN_PID/fd" -maxdepth 1 -type l -printf '%p -> %l\n' 2>/dev/null | sort || true
fi

section "Configuration"
read_file "$CONF_FILE"
read_file /etc/default/coturn
read_file "$DROPIN_FILE"

section "Auth Sanity"
if [ -n "$TURN_PID" ]; then
  CMDLINE="$(tr '\0' ' ' < "/proc/$TURN_PID/cmdline" || true)"
  case "$CMDLINE" in
    *--lt-cred-mech*) echo "OK: active command line contains --lt-cred-mech" ;;
    *) echo "WARN: active command line does not contain --lt-cred-mech" ;;
  esac
  case "$CMDLINE" in
    *--no-auth*) echo "ERROR: active command line contains --no-auth" ;;
    *) echo "OK: active command line does not contain --no-auth" ;;
  esac
fi
if [ -f "$CONF_FILE" ]; then
  grep -nE '^(lt-cred-mech|no-auth|user=|realm=|server-name=|external-ip=|relay-ip=|min-port=|max-port=)' "$CONF_FILE" || true
fi

section "TURN SQLite Database"
if command -v turnadmin >/dev/null 2>&1; then
  run_cmd turnadmin -l --db=/var/lib/turn/turndb
else
  echo "turnadmin not found"
fi
ls -l /var/lib/turn /var/lib/turn/turndb 2>/dev/null || true

section "Firewall"
if command -v ufw >/dev/null 2>&1; then run_cmd ufw status verbose; fi
if command -v nft >/dev/null 2>&1; then run_cmd nft list ruleset; fi
if command -v iptables >/dev/null 2>&1; then run_cmd iptables -S; fi
if command -v ip6tables >/dev/null 2>&1; then run_cmd ip6tables -S; fi

section "Logs"
run_cmd journalctl -u coturn -n 250 --no-pager
if [ -n "$ACTIVE_LOG_FD" ]; then
  echo "--- active log via $ACTIVE_LOG_FD -> $ACTIVE_LOG_TARGET ---"
  tail -n 250 "$ACTIVE_LOG_FD" || true
fi
for pattern in /var/log/turnserver.log /var/log/turn_*.log /var/tmp/turn_*.log /tmp/turn_*.log; do
  for file in $pattern; do
    [ -e "$file" ] || continue
    echo "--- $file ---"
    tail -n 120 "$file" || true
  done
 done

section "Packet Capture"
if ! command -v tcpdump >/dev/null 2>&1; then
  echo "tcpdump is not installed. Install it with: apt-get install -y tcpdump"
elif [ "$CAPTURE_SECONDS" = "0" ]; then
  echo "Skipping capture because CAPTURE_SECONDS=0"
else
  PCAP="$OUT_DIR/turn.pcap"
  PACKETS_TXT="$OUT_DIR/turn-packets.txt"
  echo "Capturing for ${CAPTURE_SECONDS}s. Run the browser TURN test now."
  echo "Filter: port $TURN_PORT or port $TURNS_PORT or udp portrange $TURN_MIN_PORT-$TURN_MAX_PORT"
  timeout "$CAPTURE_SECONDS" tcpdump -ni any -s 0 -U -w "$PCAP" "port $TURN_PORT or port $TURNS_PORT or udp portrange $TURN_MIN_PORT-$TURN_MAX_PORT" || true
  ls -lh "$PCAP" || true
  tcpdump -nn -vvv -X -r "$PCAP" > "$PACKETS_TXT" 2>&1 || true
  sed -n '1,260p' "$PACKETS_TXT" || true
  echo
  echo "STUN/TURN hint: unauthenticated Allocate should receive 0113 (401 challenge), not 0103 (anonymous Allocate success)."
fi

section "Browser Test Values"
HOST_VALUE="$(grep -E '^realm=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
USER_VALUE="$(grep -E '^user=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | cut -d: -f1 || true)"
echo "TURN URL UDP: turn:${HOST_VALUE:-SERVER_IP}:$TURN_PORT?transport=udp"
echo "TURN URL TCP: turn:${HOST_VALUE:-SERVER_IP}:$TURN_PORT?transport=tcp"
echo "Username: ${USER_VALUE:-unknown}"
echo "Use the password printed by install.sh in /root/coturn-stun-turn-output.txt"

section "Archive"
ARCHIVE="$OUT_DIR.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" || true
echo "Debug archive: $ARCHIVE"
