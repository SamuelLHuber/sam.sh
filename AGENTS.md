# AGENTS.md

## Project intent

Build a small personal website for `sam.sh`.

The site is a one-page personal contact hub with:

- A short paragraph/about section.
- Public contact links for anyone:
  - Instagram
  - LinkedIn
  - Twitter/X
  - Telegram
- A lightweight personal-update subscription tracker/newsletter:
  - Visitors can subscribe with email.
  - Samuel can manually send updates from his own mail via SMTP from Zig.
  - Updates are personal/life/travel/status notes so subscribers do not miss important changes.

## Architecture decision

This is not pure HTML because subscriber persistence and manual update tracking are required.

Use:

- Zig backend
- Datastar for hypermedia/reactive page interactions
- SQLite for persistence
- SMTP for manual email sending from Samuel's own mailbox
- Railway deployment with a persistent volume for the SQLite database

Use the official Datastar Zig examples as the implementation reference:

- https://github.com/starfederation/datastar-zig/tree/main/examples

Keep the implementation small. Avoid turning this into a large framework app.

## Deployment target

Primary deployment target: Railway.

Assumptions:

- Railway CLI is available locally.
- SQLite database should live on a Railway persistent volume.
- Runtime configuration comes from environment variables.
- The service should bind to Railway's provided `PORT` env var when present.

A small VPS is also acceptable later, but Railway + volume is the current intended path.

## Expected environment variables

Use environment variables for secrets and deployment-specific values.

Suggested names:

```txt
PORT=8080
BASE_URL=https://sam.sh
DATABASE_PATH=/data/sam-sh.sqlite

SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=you@example.com
SMTP_PASSWORD=...
SMTP_FROM="Samuel <you@example.com>"

```

Do not commit real secrets.

## Product behavior

### Public page

`GET /` should render the main page.

It should include:

- About paragraph.
- Public social/contact links.
- Email subscription form.

### Public contact links

Anyone can use:

- Instagram DM/profile link
- LinkedIn profile/message link
- Twitter/X DM/profile link
- Telegram link

### Newsletter/update tracker

The subscriber flow should be simple but respectful:

- Subscribe by email.
- Persist subscriber in SQLite.
- Include an unsubscribe token/link.
- Prefer double opt-in if the implementation remains simple.
- Manual email sending is acceptable and preferred for v1.

Sending updates can be implemented as a CLI command first, for example:

```sh
zig build run -- send-update ./updates/2025-01-berlin.md
```

An admin web UI is not required for v1.

## Suggested routes

```txt
GET  /                         main page
POST /subscribe                 subscribe email
GET  /confirm/:token            optional email confirmation
GET  /unsubscribe/:token        unsubscribe email

```

Optional later:

```txt
GET  /admin
POST /admin/send-update
```

## Suggested SQLite schema

Use migrations or an idempotent schema init.

Initial tables can be close to:

```sql
CREATE TABLE IF NOT EXISTS subscribers (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending',
  confirm_token TEXT,
  unsubscribe_token TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  confirmed_at INTEGER,
  unsubscribed_at INTEGER
);

CREATE TABLE IF NOT EXISTS sent_updates (
  id INTEGER PRIMARY KEY,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  sent_at INTEGER NOT NULL,
  recipient_count INTEGER NOT NULL
);
```

## Styling direction

The visual design should feel modern, sophisticated, organic, tactile, and quiet.

Concept: anthracite dark-charcoal palette, dark wood grain accents, stone-wall mass, wooden board affordances, and a matte paper-like physical texture.

Reference/inspiration:

- Behance: `Little Red Hen bakery website` (`https://www.behance.net/gallery/104056823/Little-Red-Hen-bakery-website`)
- If the Behance page is inaccessible, keep the spirit rather than copying: warm handcrafted layout, tactile materials, rustic sophistication, dark wood, earthy contrast, and editorial spacing.

The intended metaphor: the visitor approaches a dark anthracite/stone wall. Contact options are presented as wooden boards set into that wall.

### Color and background

- Base anthracite canvas:
  - `#1E2224`
  - `#23272A`
- Stone/anthracite wall:
  - Use as the main environmental surface/background.
  - Should feel like dark stone, slate, or anthracite plaster rather than flat black.
  - Use subtle mottling, roughness, and mineral-like noise.
- Dark wood accents:
  - Use low-contrast dark oak / charred wood grain feel.
  - Base around `#181A1B` with warmer brown grain tones layered in.
  - Use on structural cards, headers, side panels, and contact boards.
- Avoid pure white text.
- Use warm cream or muted stone gray:
  - Warm cream: `#F4F1EA`
  - Muted stone gray for secondary text.
- Use muted bronze/amber accents for interactive elements.

### Texture

- Apply a faint high-frequency noise/fibrous paper texture overlay.
- CSS/SVG grain at roughly `2%` to `4%` opacity is enough.
- Containers should feel matte, not glossy.
- Avoid glassmorphism, neon gradients, and synthetic-looking shine.

### Cards and layout

- Content blocks can mimic heavy cotton paper or matte parchment pinned/placed on dark wooden boards.
- Public contact methods may appear as separate wooden planks/boards mounted on the stone wall.
- Use soft, diffused, multi-layer shadows for physical depth.
- Avoid harsh outlines.
- Use thin charcoal-brown/inset borders:

```css
border: 1px solid rgba(255, 255, 255, 0.06);
```

- Cards may use very subtle noise, grain, and warm undertones.

### Typography

Use a warm, calm type treatment.

Good directions:

- Elegant serif for headings with readable sans-serif body.
- Or a soft, well-spaced sans-serif throughout.

Avoid overly futuristic or sterile type.

### Interaction styling

- Keep interactive states minimal.
- Use warm amber or muted bronze for links/buttons.
- No loud animations.
- Hover/focus should feel like a slight lift, door-latch glow, or warm illumination from behind a wooden panel.
- Focus states must remain accessible.
- Contact links should use prefilled intent URLs whenever the platform supports it, so the visitor can message Samuel directly with context instead of starting from a blank compose window.

Suggested accent colors:

```txt
bronze: #B88955
amber:  #D0A05F
soft gold: #C9A66B
```

## Coding guidelines

- Keep the codebase small and direct.
- Prefer simple Zig modules over abstraction-heavy structure.
- Avoid unnecessary dependencies.
- Keep secrets out of source control.
- Treat all user input as untrusted.
- Validate and normalize email addresses.
- Use parameterized SQLite statements.
- Ensure unsubscribe links are unguessable.
- Log enough for debugging but avoid logging secrets, tokens, or private contact details.

## Initial file layout suggestion

```txt
AGENTS.md
README.md
build.zig
schema.sql
src/main.zig
src/db.zig
src/smtp.zig
src/templates.zig
src/config.zig
public/styles.css
updates/
```

This layout is only a suggestion. Prefer clarity over ceremony.
