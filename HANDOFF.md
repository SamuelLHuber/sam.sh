# Handoff: sam.sh

## Current state

Initialized a Zig personal contact hub scaffold for `sam.sh`.

Repository:

- GitHub: https://github.com/SamuelLHuber/sam.sh
- Local VCS: Jujutsu (`jj`) colocated with Git
- Main bookmark: `main`

Railway:

- Project: `sam.sh`
- Project ID: `83caf615-ae3e-4e1c-b0ec-af6738b05761`
- Environment: `production` (`193fc912-3f64-408d-b240-6a7fd3e0a7c0`)
- Service: `web` (`8838f7cf-7604-486e-b452-543f875ef239`)
- Source: `SamuelLHuber/sam.sh`, branch `main`
- Volume mounted at `/data`
- Variables already set:
  - `PORT=8080`
  - `BASE_URL=https://sam.sh`
  - `DATABASE_PATH=/data/sam-sh.sqlite`

## What exists

Files:

```txt
AGENTS.md                    product/style/architecture instructions
README.md                    quick dev notes
HANDOFF.md                   this handoff
build.zig                    Zig build config
build.zig.zon                Zig package metadata
nixpacks.toml                Railway/Nixpacks build config
railway.json                 Railway deploy config
schema.sql                   SQLite schema reference
.env.example                 expected config/secrets
src/main.zig                 HTTP server, SQLite glue, routes
src/styles.css               embedded stylesheet copy
public/styles.css            source stylesheet copy
src/templates/*.html         embedded HTML fragments/templates
updates/example.md           manual update example
```

Implemented:

- Zig stdlib HTTP server.
- SQLite persistence via direct C ABI declarations and system `sqlite3` link.
- `GET /` main one-page contact hub.
- `GET /styles.css` embedded CSS.
- `GET /health` healthcheck.
- `POST /subscribe` stores confirmed email subscribers in SQLite.
- `GET /unsubscribe/:token` unsubscribes by unguessable token.
- Datastar-style SSE patch responses for subscribe/private-contact fragments.
- `GET /private-contact` closed-door fragment.
- `GET /private-contact?demo=verified` demo private phone reveal.
- Auth placeholders for:
  - `/auth/farcaster/start`
  - `/auth/farcaster/callback`
  - `/auth/twitter/start`
  - `/auth/twitter/callback`
- Scaffolded `send-update` CLI command; SMTP sending is not implemented yet.
- Anthracite/stone wall + dark wooden boards/door styling.

Verified locally:

```sh
zig build check
zig build run
curl http://127.0.0.1:8080/health
curl -X POST -d 'email=test@example.com' http://127.0.0.1:8080/subscribe
```

## Important caveats

1. `src/styles.css` and `public/styles.css` are currently duplicated because Zig 0.17 rejected `@embedFile("../public/styles.css")` as outside package path. Keep them in sync or change build/package paths.
2. Datastar CDN URL uses `@main`; pin to a specific Datastar version before production.
3. URL decoding is minimal. It handles `+` but currently skips percent escapes. Fix before production.
4. Random token generation uses a PRNG seeded from current time. Replace with OS CSPRNG before production.
5. Phone number defaults are placeholders. Set real Railway variables before testing private reveal.
6. SMTP is scaffolded only; no actual email delivery yet.
7. Farcaster/Twitter mutual verification is not implemented yet.
8. Twitter/X mutual verification may require paid/restricted API access. Treat Twitter as manual approval/allowlist unless API access is confirmed.

## Next tasks

### 1. Deploy first Railway build

Either push is already connected and should trigger, or run:

```sh
railway up --service web
```

Then check:

```sh
railway logs --service web
railway status
```

Set real variables in Railway:

```sh
railway variable set PRIVATE_PHONE=... WHATSAPP_NUMBER=... IMESSAGE_TARGET=...
railway variable set SMTP_HOST=... SMTP_PORT=587 SMTP_USERNAME=... SMTP_PASSWORD=... SMTP_FROM='Samuel <you@example.com>'
railway variable set SESSION_SECRET=...
```

Do not put real secrets in git.

### 2. Production hardening before launch

- Replace `randomBytes` with OS CSPRNG.
- Implement full URL percent decoding.
- Add basic rate limiting or honeypot for `/subscribe`.
- Add double opt-in if desired.
- Escape user-controlled values in HTML fragments.
- Use secure session cookies for verified identities.
- Decide whether raw phone number should be shown or only WhatsApp/iMessage buttons.

### 3. SMTP manual update sender

Implement `zig build run -- send-update ./updates/file.md` to:

- Parse `Subject:` from the markdown file.
- Query confirmed subscribers.
- Send through `SMTP_HOST`/`SMTP_PORT`/`SMTP_USERNAME`/`SMTP_PASSWORD`.
- Include unsubscribe link based on `BASE_URL` and `unsubscribe_token`.
- Record row in `sent_updates`.

### 4. Farcaster auth

Recommended v1 path:

- Use Sign in with Farcaster / Neynar or similar.
- Verify identity.
- Check Samuel <-> visitor mutual relation.
- Insert/update `verified_identities`.
- Set secure, HTTP-only session cookie.
- Make `/private-contact` inspect session and reveal phone links only for verified mutuals.

### 5. Twitter/X auth

Recommended v1 path:

- Twitter login proves identity.
- Check SQLite allowlist/manual approval first.
- Add automatic mutual check only if API access is available and reliable.

## Design brief reminder

See `AGENTS.md` for full guidance. In short:

- Anthracite / dark stone wall background.
- Dark wood board contact links.
- Mutual-only phone area as a wooden door/hatch in the wall.
- Matte paper/card texture, warm cream text, bronze/amber accents.
- Prefilled intent links where platforms support them.
- Never include private phone data in initial HTML.
