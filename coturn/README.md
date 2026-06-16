# Beginner Guide: Install Your Own STUN/TURN Server With coturn

This guide installs only **coturn**.

It does not install MiroTalk, Django, Node.js, Nginx, or any web app.

coturn can work as:

- A **STUN server**.
- A **TURN server**.
- A **TURNS server** when TLS certificate is available.

At the end, the script prints ready-to-copy values like:

```env
STUN_SERVER_URL=stun:turn.example.com:3478
TURN_SERVER_URL=turn:turn.example.com:3478
TURN_SERVER_USERNAME=mirotalk
TURN_SERVER_CREDENTIAL=generated-password
```

---

## 1. What Is STUN/TURN?

### STUN

STUN helps WebRTC clients discover their public IP and port.

```text
Browser -> STUN Server -> Public Address Discovery
```

STUN does not relay video or audio.

### TURN

TURN is used when direct peer-to-peer connection fails.

```text
Browser A -> TURN Server -> Browser B
```

TURN relays media, so it consumes server bandwidth.

coturn provides both STUN and TURN.

---

## 2. What You Need

You need:

1. A VPS with Ubuntu 22.04 or Ubuntu 24.04.
2. Root or sudo SSH access.
3. A public IPv4 address.
4. Optional but recommended: a domain or subdomain like:

```text
turn.example.com
```

A domain is required if you want `turns:` TLS support.

---

## 3. Recommended Server Size

For testing:

```text
1 vCPU
1 GB RAM
Ubuntu 22.04 Or 24.04
```

For more real users:

```text
2 vCPU
2 GB RAM
Good Network Bandwidth
```

TURN uses bandwidth when it relays calls. CPU is usually less important than network traffic.

---

## 4. Connect To VPS With SSH

### Windows

Open PowerShell:

```bash
ssh root@YOUR_SERVER_IP
```

Example:

```bash
ssh root@203.0.113.10
```

Type `yes` if SSH asks to trust the server.

Then enter the password.

### macOS Or Linux

Open Terminal:

```bash
ssh root@YOUR_SERVER_IP
```

Example:

```bash
ssh root@203.0.113.10
```

---

## 5. Update The Server

Run:

```bash
apt update && apt upgrade -y
```

---

## 6. Configure DNS In ArvanCloud

If you have a domain, create a subdomain for TURN.

Example:

```text
turn.example.com
```

### Add DNS Record

In ArvanCloud DNS panel, create this record:

| Type | Name | Value | Proxy / Cloud |
|---|---|---|---|
| A | turn | Your VPS IP | DNS Only / Cloud Off |

Example:

```text
A    turn    203.0.113.10
```

Important:

```text
TURN must be DNS Only / Cloud Off.
```

Do not proxy TURN traffic through CDN. TURN is not normal HTTP traffic.

### Check DNS

On your VPS:

```bash
dig +short turn.example.com
```

It should print your VPS IP.

---

## 7. Open Ports In VPS Provider Firewall

Open these ports in your VPS provider panel:

```text
22/tcp
80/tcp
3478/tcp
3478/udp
5349/tcp
49160-49200/udp
```

Why each port is needed:

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | Let's Encrypt Certificate Validation |
| 3478 | TCP/UDP | STUN/TURN |
| 5349 | TCP | TURNS TLS |
| 49160-49200 | UDP | TURN Relay Media Ports |

The script also configures Ubuntu UFW firewall, but provider firewall must allow these ports too.

---

## 8. Create The Installer File

On the VPS:

```bash
nano install.sh
```

Paste the script content into nano.

Save:

```text
Ctrl + O
Enter
Ctrl + X
```

Make it executable:

```bash
chmod +x install.sh
```

---

## 9. Install With Domain And TLS

Use this for production:

```bash
sudo TURN_DOMAIN=turn.example.com \
ADMIN_EMAIL=admin@example.com \
./install.sh
```

The script will:

1. Install coturn.
2. Detect public IP.
3. Generate TURN password.
4. Configure coturn.
5. Configure firewall.
6. Request Let's Encrypt certificate.
7. Start coturn.
8. Print final STUN/TURN settings.

---

## 10. Install Without Domain

Use this for IP-based testing:

```bash
sudo ENABLE_TLS=false ./install.sh
```

At the end, you will get:

```env
STUN_SERVER_URL=stun:YOUR_SERVER_IP:3478
TURN_SERVER_URL=turn:YOUR_SERVER_IP:3478
```

This is okay for testing.

For production, a domain is better.

---

## 11. Use Custom Username And Password

```bash
sudo TURN_DOMAIN=turn.example.com \
ADMIN_EMAIL=admin@example.com \
TURN_USER=myuser \
TURN_PASSWORD='VeryStrongPasswordHere' \
./install.sh
```

If you do not provide `TURN_PASSWORD`, the script generates one.

---

## 12. Final Output Example

The final output looks like this:

```text
Coturn STUN/TURN Installation Finished

Public IPv4:
203.0.113.10

TURN Host:
turn.example.com

Plain STUN/TURN:
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:turn.example.com:3478

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:turn.example.com:3478
TURN_SERVER_USERNAME=mirotalk
TURN_SERVER_CREDENTIAL=generated-password

TLS TURN:
TURN_SERVER_URL_TLS=turns:turn.example.com:5349
```

The output is also saved here:

```bash
/root/coturn-stun-turn-output.txt
```

You can read it later:

```bash
cat /root/coturn-stun-turn-output.txt
```

---

## 13. Use In MiroTalk C2C

Put the final values into your MiroTalk `.env`:

```env
STUN_SERVER_ENABLED=true
STUN_SERVER_URL=stun:turn.example.com:3478

TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:turn.example.com:3478
TURN_SERVER_USERNAME=mirotalk
TURN_SERVER_CREDENTIAL=generated-password
```

If your app supports TLS TURN, you can also try:

```env
TURN_SERVER_URL=turns:turn.example.com:5349
```

Most setups work fine with:

```env
turn:turn.example.com:3478
```

---

## 14. Test In Browser

Open this WebRTC ICE test page:

```text
https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
```

Add your STUN server:

```text
stun:turn.example.com:3478
```

Add your TURN server:

```text
turn:turn.example.com:3478
```

Username:

```text
mirotalk
```

Password:

```text
your generated password
```

Click **Gather candidates**.

If you see candidates with type `relay`, TURN works.

---

## 15. Check Service Status

```bash
sudo systemctl status coturn
```

Restart coturn:

```bash
sudo systemctl restart coturn
```

View logs:

```bash
sudo tail -f /var/log/turnserver.log
```

Edit config:

```bash
sudo nano /etc/turnserver.conf
```

After editing config:

```bash
sudo systemctl restart coturn
```

---

## 16. Increase Capacity

The default relay range is:

```text
49160-49200/udp
```

For more concurrent TURN relays, use a bigger range:

```bash
sudo TURN_DOMAIN=turn.example.com \
ADMIN_EMAIL=admin@example.com \
TURN_MIN_PORT=49160 \
TURN_MAX_PORT=49360 \
./install.sh
```

Also open the same UDP range in your VPS provider firewall.

---

## 17. Common Problems

### DNS Does Not Point To Server

Check:

```bash
dig +short turn.example.com
```

It must show your VPS IP.

### TLS Certificate Fails

Make sure:

1. `turn.example.com` points to your VPS IP.
2. Port `80/tcp` is open.
3. No other service is using port 80.

Then rerun:

```bash
sudo TURN_DOMAIN=turn.example.com ADMIN_EMAIL=admin@example.com ./install.sh
```

### STUN Works But TURN Does Not

Check UDP ports:

```text
3478/udp
49160-49200/udp
```

They must be open both in Ubuntu firewall and VPS provider firewall.

### No Relay Candidate In Trickle ICE Test

Check:

1. Correct username.
2. Correct password.
3. Correct TURN URL.
4. UDP relay range is open.
5. coturn is running.

Command:

```bash
sudo systemctl status coturn
```

### ArvanCloud Proxy Is Enabled

Set the record to:

```text
DNS Only / Cloud Off
```

TURN does not work correctly through normal CDN proxy.

---

## 18. Security Notes

Use a strong TURN password.

Do not expose the coturn CLI.

The script uses:

```text
no-cli
```

Do not create open TURN relay servers without authentication.

The script uses:

```text
lt-cred-mech
user=username:password
```

---

## 19. Uninstall

Stop coturn:

```bash
sudo systemctl stop coturn
sudo systemctl disable coturn
```

Remove package:

```bash
sudo apt remove coturn -y
```

Remove config:

```bash
sudo rm -f /etc/turnserver.conf
sudo rm -f /root/coturn-stun-turn-output.txt
```

---

## 20. Change Password

Open `nano /etc/turnserver.conf`
Change password.

---

## 21. Files Created By The Installer

Main config:

```text
/etc/turnserver.conf
```

Output credentials:

```text
/root/coturn-stun-turn-output.txt
```

Log file:

```text
/var/log/turnserver.log
```
