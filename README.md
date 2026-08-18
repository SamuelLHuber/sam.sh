# sam.sh

Personal contact hub for Samuel Huber.

## Stack

- Zig HTTP server
- Datastar for small hypermedia interactions
- SQLite persistence
- Railway deployment with a persistent volume
- Manual SMTP newsletter/update sending from Samuel's mailbox

See `AGENTS.md` for product intent, design direction, and implementation constraints.

## Development

```sh
zig build check
zig build run
```

Open <http://localhost:8080>.

Test the private-contact reveal UI locally:

```txt
/private-contact?demo=verified
```

## Environment

Copy `.env.example` into your secret manager / Railway variables. Do not commit real secrets.

```txt
PORT=8080
BASE_URL=https://sam.sh
DATABASE_PATH=./sam-sh.sqlite
```

On Railway, set:

```txt
DATABASE_PATH=/data/sam-sh.sqlite
```

and mount a persistent volume at `/data`.

## Newsletter CLI

Scaffolded command:

```sh
zig build run -- send-update ./updates/example.md
```

SMTP delivery is intentionally still TODO in this initial scaffold.

## Auth status

Farcaster/Twitter mutual verification routes are placeholders. V1 implementation plan:

1. Farcaster Sign-in + social graph mutual check.
2. SQLite verified identity/session storage.
3. Datastar private-contact fragment reveal.
4. Twitter/X login/manual allowlist or automatic check if API access is available.
