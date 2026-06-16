# C2C Call — Persian Limited Edition

A fork of **[MiroTalk C2C](https://github.com/miroslavpejic85/mirotalkc2c)** by [Miroslav Pejic](https://github.com/miroslavpejic85), licensed under [AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html).

---

## What's different in this fork

- **LIMITED mode** — API-only, JWT-based time-limited sessions (`LIMITED=true` in `.env`).  
  Rooms are created via `POST /api/v1/session`; users join via a signed link; the session auto-ends when time expires.
- Persian (Farsi) UI improvements — Vazirmatn font, RTL-friendly session name display.

## Quick start

```bash
cp .env.sample .env   # fill in LIMITED, JWT_SECRET, API_KEY_SECRET
npm install
npm run start
```

## Create a session (LIMITED mode)

```bash
# session_name_b64 = base64 of UTF-8 name (avoids encoding issues with non-ASCII text)
curl -X POST http://localhost:8080/api/v1/session \
  -H "Content-Type: application/json" \
  -H "authorization: YOUR_API_KEY" \
  -d "{\"session_name_b64\": \"$(echo -n 'SESSION NAME' | base64)\", \"duration_minutes\": 60}"
```

Returns `{ "link": "http://…/?token=<jwt>" }` — share this link with participants.

---

Based on [MiroTalk C2C](https://github.com/miroslavpejic85/mirotalkc2c) by Miroslav Pejic — AGPL-3.0
