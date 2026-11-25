# Workbench relay

Two small Vercel functions:

- `/api/push` forwards Workbench's phone notifications to Apple, so people
  don't need their own APNs key. Workbench uses it whenever it has no key of
  its own (Settings > iPhone > Notifications).
- `/api/feedback` emails what people send from Help > Send Feedback, so
  the destination address never ships in the app.

- `/api/feedback-queue` hands feedback to the developer's Mac, which starts
  an agent to look into each message (Settings > Claude > Feedback Agent).
- `/api/queue` holds prompts typed on the iPhone while the Mac is asleep,
  until the Mac wakes and picks them up.

Nothing is logged. Notification text passes through on its way to Apple,
and feedback on its way to the inbox. With the feedback queue set up, each
message (without the sender's email) is also kept until the Mac picks it
up, for up to two weeks.

## Deploy

```sh
cd relay
vercel link                      # once: project "workbench-push"
vercel env add APNS_KEY production < AuthKey_XXXXXXXXXX.p8
printf XXXXXXXXXX | vercel env add APNS_KEY_ID production
printf ZPU7B69KH3 | vercel env add APNS_TEAM_ID production
vercel deploy --prod
```

`GET /api/push` answers `{"ok":true,"configured":true}` once the key is set.

For feedback, with a [Resend](https://resend.com) API key:

```sh
printf re_XXXXXXXX | vercel env add RESEND_API_KEY production
printf you@example.com | vercel env add FEEDBACK_TO production
# Optional, on a domain verified in Resend. Without it, mail comes from
# Resend's test address, which only delivers to the Resend account's email.
printf 'Workbench <feedback@example.com>' | vercel env add FEEDBACK_FROM production
vercel deploy --prod
```

`GET /api/feedback` answers `{"ok":true,"configured":true}` once both are set.

For the feedback queue, add an Upstash Redis database to the project
(Vercel > Storage > Upstash for Redis, which sets `KV_REST_API_URL` and
`KV_REST_API_TOKEN`), then a secret the Mac will use:

```sh
openssl rand -hex 24 | tee /dev/stderr | vercel env add FEEDBACK_QUEUE_SECRET production
vercel deploy --prod
```

`GET /api/feedback-queue` answers `{"ok":true,"configured":true}` once it's
ready. Paste the secret into Workbench on the Mac that should do the work.

## Push request

`POST /api/push` with JSON:

| Field | |
|---|---|
| `environment` | `sandbox` (Xcode builds) or `production` (TestFlight, App Store) |
| `token` | the device or Live Activity push token, in hex |
| `topic` | `me.birchtree.BenchPhone`, or with `.push-type.liveactivity` |
| `pushType` | `alert` or `liveactivity` |
| `priority` | `10` (default) or `5` |
| `collapseID` | optional, up to 64 bytes |
| `payload` | the notification, up to 4 KB |

Answers 200 on success, otherwise Apple's status with `{"reason": "..."}`.

## Feedback request

`POST /api/feedback` with JSON:

| Field | |
|---|---|
| `message` | what they wrote, up to 10,000 characters |
| `email` | optional; becomes the email's Reply-To |
| `screenshots` | optional; up to 4 JPEGs in base64, up to 850 KB each, attached to the email |
| `app`, `version`, `os` | optional, shown under the message |

Answers 200 on success, otherwise an error status with `{"reason": "..."}`
that's fine to show as is. Each address is held to 10 an hour.

## Feedback queue request

`POST /api/feedback-queue` with `Authorization: Bearer <FEEDBACK_QUEUE_SECRET>`
takes the oldest waiting message off the queue and answers
`{"item": {...} | null, "remaining": N}`. An item has `id`, `receivedAt`,
`message`, `app`, `version`, `os`, and `screenshots` (JPEGs in base64). The
queue holds the newest 50.

## Prompt queue request

`POST /api/queue` with JSON. Every request has `mailbox` (64 lowercase hex
characters, made from the pairing token) and `action`:

| Action | Fields | Answer |
|---|---|---|
| `add` | `id` (a UUID), `sealed` (base64, up to 32,768 characters) | `{"ok":true}` |
| `list` | `ids` (up to 100) | `{"items":[{id,sealed,addedAt}],"taken":[ids]}` |
| `delete` | `id` | `{"ok":true}` |
| `take` | | `{"items":[...]}`, and the mailbox is emptied |
| `ack` | `ids` (up to 100) | `{"ok":true}` |

The relay only sees sealed text, which the phone encrypts and only the Mac
can open. The mailbox id is sent in the body, never in the URL. Nothing is
logged. It uses the same Upstash variables as the feedback queue, so it
needs no secret of its own. `GET /api/queue` answers
`{"ok":true,"configured":true}` once the database is set up.

A mailbox holds 25 prompts and is cleared 14 days after the last add. `take`
hands everything over and remembers those ids for 14 days, so a late `add`
of one gets 409 `{"taken":true}`. Taken prompts are also held for a day
until the Mac sends `ack` with their ids, and each `take` hands back any
not acked yet, so a lost answer doesn't lose them. Other errors: 400 bad input, 413
too big, 429 mailbox full, 503 not set up.
