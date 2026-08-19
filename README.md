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

## Newsletter sending

Set SMTP and admin credentials in Railway or your local environment:

```txt
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=you@example.com
SMTP_PASSWORD=...
SMTP_FROM="Samuel <you@example.com>"
ADMIN_USERNAME=samuel
ADMIN_PASSWORD=long-random-password
```

Then open `/admin`. The admin page is protected with HTTP Basic Auth and sends one plain-text email to each confirmed subscriber. Each message includes that subscriber's unsubscribe link.

The CLI command validates an update file and reports how many confirmed subscribers would receive it; it does not send mail:

```sh
zig build run -- send-update ./updates/example.md
```

