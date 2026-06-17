# Coturn STUN/TURN Server Guide

This folder installs and manages a standalone coturn server for WebRTC apps such as MiroTalk C2C.

The installer is intentionally strict about authenticated TURN. It writes both `/etc/turnserver.conf` and a systemd override so the running service explicitly includes `--lt-cred-mech` and `--user=...`. This avoids the failure mode where coturn answers an unauthenticated Allocate request with `0103` anonymous success, which Chrome rejects and reports as `701` with no relay candidate.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Install coturn, configure authenticated TURN, configure UFW, start service. |
| `debug.sh` | Collect service, config, auth, firewall, logs, and packet capture diagnostics. |
| `uninstall.sh` | Remove coturn package, config, DB, logs, systemd override, generated output, and installer state. |
| `.env.example` | Example installer environment variables. |

## Requirements

Use a fresh Ubuntu/Debian VPS with:

- Root or sudo access.
- A public IPv4 address.
- Provider firewall access, if your provider has one.
- Optional DNS name such as `turn.example.com` for `turns:` TLS.

Plain `turn:` does not require a domain or SSL certificate. `turns:` requires a domain and certificate.

## Ports

Open these in the VPS provider firewall, not only UFW:

```text
3478/udp
3478/tcp
49160-65535/udp
```

If using TLS TURN:

```text
80/tcp
5349/tcp
```

The relay range is large by default because TURN consumes relay UDP ports during calls. You can reduce it, but the same range must be open in every firewall.

## Install With IP Only

Use this when you do not have a TURN domain:

```bash
sudo ENABLE_TLS=false ./install.sh
```

The final output will include values like:

```env
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:YOUR_SERVER_IP:3478

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:YOUR_SERVER_IP:3478?transport=udp
TURN_SERVER_USERNAME=mirotalk
TURN_SERVER_CREDENTIAL=generated-password
```

## Install With Domain And TLS

Create a DNS-only A record first:

```text
turn.example.com -> YOUR_SERVER_IP
```

Do not proxy TURN through CDN/cloud proxy.

Then run:

```bash
sudo TURN_DOMAIN=turn.example.com \
ADMIN_EMAIL=admin@example.com \
./install.sh
```

The script requests a Let's Encrypt certificate and also prints:

```env
TURN_SERVER_URL_TLS=turns:turn.example.com:5349?transport=tcp
```

Most deployments should still start with plain UDP TURN:

```env
TURN_SERVER_URL=turn:turn.example.com:3478?transport=udp
```

## Custom Username And Password

```bash
sudo TURN_USER=mirotalk \
TURN_PASSWORD='StrongSafePassword123' \
ENABLE_TLS=false \
./install.sh
```

If `TURN_PASSWORD` is empty, the installer generates a strong hex password. Use only safe characters in custom credentials: letters, digits, `.`, `_`, `~`, `@`, `#`, `=`, `+`, `-`.

## Use In MiroTalk C2C

Set these environment variables exactly. `true` must be lowercase because the app checks for the string `true`.

```env
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:YOUR_TURN_HOST:3478

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:YOUR_TURN_HOST:3478?transport=udp
TURN_SERVER_USERNAME=mirotalk
TURN_SERVER_CREDENTIAL=generated-password
```

For a TCP fallback, use:

```env
TURN_SERVER_URL=turn:YOUR_TURN_HOST:3478?transport=tcp
```

For TLS TURN with a domain:

```env
TURN_SERVER_URL=turns:turn.example.com:5349?transport=tcp
```

## Verify In Browser

Use Trickle ICE:

```text
https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
```

Add:

```text
turn:YOUR_TURN_HOST:3478?transport=udp
```

Enter the username and password printed by `install.sh`, then gather candidates. A working TURN server produces at least one `relay` candidate.

A `701` error means the browser could not complete TURN allocation. It is not by itself proof of a password problem.

## Low-Level Auth Sanity Check

If relay candidates are missing, capture the first UDP exchange while testing:

```bash
OUT=/tmp/turn3478-$(date +%s).pcap
timeout 20 tcpdump -ni any -s 0 -U -w "$OUT" 'udp port 3478'
tcpdump -nn -vvv -X -r "$OUT" | sed -n '1,180p'
```

For authenticated TURN, the first unauthenticated Allocate response should be:

```text
0113
```

That is the normal `401 Unauthorized` challenge containing realm/nonce.

If the first response is:

```text
0103
```

coturn is allowing anonymous Allocate success. Chrome rejects that flow for configured TURN credentials. Re-run `install.sh` and confirm the active command line contains `--lt-cred-mech`.

Check the active command line:

```bash
pgrep -a turnserver
```

It must include:

```text
--lt-cred-mech
--user=USERNAME:PASSWORD
```

It must not include:

```text
--no-auth
```

## Debug

Run:

```bash
sudo bash debug.sh
```

During the packet capture window, run your browser TURN test. The script writes a full report and archive under `/tmp/coturn-debug-*`.

Useful options:

```bash
sudo CAPTURE_SECONDS=0 bash debug.sh
sudo CAPTURE_SECONDS=60 bash debug.sh
sudo TURN_PORT=3478 TURN_MIN_PORT=49160 TURN_MAX_PORT=65535 bash debug.sh
```

The debug report includes:

- coturn service status and systemd override.
- Active process command line.
- Open log file descriptors, including deleted `/var/tmp/turn_*.log` files.
- `/etc/turnserver.conf` and `/etc/default/coturn`.
- SQLite TURN users from `/var/lib/turn/turndb`.
- UFW, nftables, iptables state.
- Listening sockets.
- Journal and coturn logs.
- Packet capture and hex decode.

## Uninstall And Reinstall Test

To remove the installation:

```bash
sudo bash uninstall.sh
```

Then install again:

```bash
sudo ENABLE_TLS=false ./install.sh
```

A clean reinstall should still produce relay candidates.

The installer records state in `/var/lib/coturn-installer/state.env`. If it enabled UFW from an inactive state, `uninstall.sh` disables UFW again by default. By default, `uninstall.sh` does not delete Let's Encrypt certificates. To remove a TURN certificate too:

```bash
sudo REMOVE_CERTS=true TURN_DOMAIN=turn.example.com bash uninstall.sh
```

## Common Problems

### STUN Works But Relay Does Not

STUN only proves public address discovery. TURN relay also needs authenticated allocation and relay UDP ports. Check:

```text
3478/udp
3478/tcp
49160-65535/udp
```

### No Logs In journalctl

coturn may log to files instead of journald. Run `debug.sh`; it discovers the active log through `/proc/<pid>/fd`, even if coturn opened a deleted `/var/tmp/turn_*.log` file.

### Provider Says There Is No Firewall

Still verify packet flow with `debug.sh` or `tcpdump`. If packets arrive and responses leave, firewall is not the primary issue.

### DNS Or CDN Proxy

TURN must be DNS-only. Do not proxy TURN through ArvanCloud/Cloudflare/CDN HTTP proxy.

### Limited Session Capacity

Each relayed call consumes relay resources and UDP ports. Keep a broad range such as `49160-65535/udp` for production unless you have a reason to cap capacity.

## Security Notes

Use a strong TURN password. Do not expose coturn CLI. Keep provider firewall scoped to the required ports. Rotate credentials if they are shared outside trusted deployment channels.
