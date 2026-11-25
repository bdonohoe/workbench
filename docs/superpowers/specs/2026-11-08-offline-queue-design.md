# Queue Prompts for a Sleeping Mac

Date: 2026-11-08
Status: approved
Mockup: `.superpowers/brainstorm/66283-1794167052/content/offline-queue.html` (screen 3 is the chosen project screen; screen 1 the project list)

## Why

Matt often has an idea for one of his projects while he's out and his laptop
is asleep at home. The iPhone app talks straight to the Mac over Tailscale,
so with the Mac asleep the app can do nothing and the idea gets lost. This
feature lets him write the prompt on his phone anyway. The Mac picks it up
as soon as it's back online and starts it as a new agent, with no further
input.

## Goals

- When the paired Mac can't be reached, the phone still shows its projects
  and lets him queue a prompt for any of them.
- When the Mac is back (launch, wake, network back, or a periodic check),
  Workbench starts each queued prompt **right away, without asking**, as a
  new agent on its own branch in its own worktree. Nothing already open is
  touched, so it can't conflict with work in progress.
- The prompts are stored on Workbench's relay, encrypted end to end. Only
  devices paired with that Mac can read them. Not Matt, Vercel or Upstash.
- The privacy policy says what's stored, for how long, and who can read it.
- Ships in the next iOS update, with the matching Mac update and a relay
  deploy.

## Non-goals

- iCloud or CloudKit. People's phone and Mac are often on different Apple
  Accounts, so it can't be relied on.
- Waking the Mac. A sleeping Mac runs nothing; the queue waits for it.
- Photos or files in queued prompts. Text only for now.
- Queueing into an existing session, or a New Claude Tab. Queued prompts
  always become new agents.
- Non-git projects. A new agent needs a repo, so they can't take a queued
  prompt (see "Phone" below).
- A setting to turn this on. It works for any paired Mac running a version
  that supports it.

## Anti-goals (a failure even if it works)

- **The relay or its operator being able to read a prompt**, or tell which
  Mac, person or project a queue belongs to.
- **Losing an idea.** A prompt that can't start stays visible somewhere
  (on the Mac) instead of disappearing.
- **A prompt starting twice**, or starting on the wrong Mac.
- **Offering to queue for a Mac that will never pick it up** (an older
  Workbench).
- **Touching the user's open work.** No existing tab, session or branch is
  used.

## How it works

### Keys and the mailbox (shared, BenchKit)

The Mac has one pairing token (32 random bytes, `PairingInfo.makeToken`,
kept in `companion-token`). Every phone paired with it has the same token in
its keychain. `NotificationSeal` already derives a key from it to encrypt
notification text. The queue does the same thing with its own labels:

- **Mailbox id:** `HKDF-SHA256(token, salt: "workbench-queue-id-v1")`, 32
  bytes, hex. It's what the relay files the prompts under. It can't be
  turned back into the token and says nothing about the Mac. Knowing it is
  what lets someone add, list, delete or take prompts.
- **Prompt key:** `HKDF-SHA256(token, salt: "workbench-queue-key-v1")`, 32
  bytes. Each prompt is sealed with AES-GCM, with the mailbox id as
  associated data so a sealed prompt can't be moved to another mailbox.
- Uses the token alone, not the host, so a Tailscale name change doesn't
  orphan a queue.
- Since the token is per Mac, **the queue is per Mac**: every phone or iPad
  paired with that Mac shares one mailbox. A prompt goes to the Mac that was
  selected when it was queued.

Sealed contents (JSON, before encryption):

```
{ "id": "<uuid>", "projectID": "<uuid>", "projectName": "Bench",
  "prompt": "…", "queuedAt": "<ISO date>", "device": "Matt's iPhone" }
```

`projectName` is there so the Mac can say which project a prompt was meant
for if that project is gone.

A new pairing code (Settings on the Mac) makes a new token, so a new key and
mailbox. Prompts left in the old mailbox can't be read and expire. The phone
still has its own copy (see "Phone"), and re-queues anything not picked up
under the new mailbox the next time it connects with the new pairing.

### Relay (`relay/api/queue.js`, new)

Same style as `feedback-queue.js` and `_queue.js`: no dependencies, Upstash
Redis over REST, nothing logged. One Redis hash per mailbox:
`queue:<mailboxID>`, field = prompt id, value = `{sealed, addedAt}`.

- `GET /api/queue` → `{"ok":true,"configured":bool}`, like the other
  endpoints.
- `POST /api/queue` with JSON `{mailbox, action, …}`:
  - `add` `{id, sealed}`: stores it, or replaces the prompt with that id, for
    edits. Refreshes the mailbox's expiry.
  - `list` → `{items:[{id, sealed, addedAt}]}`, for the phone to show what's
    still waiting.
  - `delete` `{id}`: removes one, for the phone.
  - `take` → `{items:[…]}`: removes and returns everything waiting, in one
    atomic step (`HGETALL` + `DEL` in a `MULTI`, or a small Lua script), so
    two Macs or two wakes can't both get the same prompt. In the same step
    it records each taken prompt id in a second set, `queue:<mailboxID>:taken`,
    which expires 14 days after the last take.
- **Taken ids** let the phone tell "started" from "expired" and stop
  double starts. `add` refuses an id that's in the taken set, answering
  `{"taken":true}`. `list` returns `{items:[…], taken:[ids]}`, with the taken
  ids limited to the ones the caller asks about (`ids` in the request), so it
  never hands back the whole history. Prompt ids are random UUIDs and say
  nothing on their own. *(Claude's call.)*
- The mailbox id goes in the JSON body, not the URL, so it doesn't land in
  access logs.
- Limits: mailbox id must be 64 hex characters; sealed prompt at most 32 KB;
  at most 25 prompts per mailbox (`add` is refused past that, and the phone
  says so); everything expires **14 days** after the last `add`, matching the
  feedback queue.
- Uses the same `KV_REST_API_*` / `UPSTASH_REDIS_REST_*` variables
  `_queue.js` already reads. No new secret: the mailbox id is the
  credential.
- `relay/README.md` gets a short section.

### Mac (`Bench/Companion/`, new `OfflineQueue.swift`)

- Advertises a new `CompanionFeature.offlineQueue` in the welcome's
  feature list, so phones know this Mac picks up queued prompts.
- Checks the mailbox with `take`:
  - when Workbench launches,
  - on `NSWorkspace.didWakeNotification`,
  - when the network comes back (`NWPathMonitor` going to satisfied),
  - every 5 minutes while running.
- Only checks while the Companion (iPhone pairing) is on and a token exists.
  Turning the Companion off is the user switching the phone link off, so
  queued prompts wait (and the phone's expiry warning covers them).
  *(Claude's call.)*
- **Debug builds never take from the real relay.** They share the release
  app's bundle id and `companion-token`, so a dev build launched on Matt's
  Mac would otherwise grab his real queue. In DEBUG the queue URL comes only
  from `BENCH_TEST_OFFLINE_QUEUE` (like `BENCH_TEST_FEEDBACK_QUEUE`), and
  with it unset the Mac doesn't check at all. End-to-end testing points both
  a debug phone build and a debug Mac build at the same stand-in or a
  preview relay deploy. *(Claude's call.)*
- **Before starting**, the Mac saves the prompts it took to Application
  Support, and clears each one once its agent has started, so a crash between
  `take` and the start can't lose them. Leftovers are retried on next
  launch.
- **New pairing code:** when the Mac makes a new token, it does one last
  `take` from the old mailbox first and starts what it finds, so nothing is
  stranded.
- Starts each prompt, oldest `queuedAt` first, through the same path as the
  phone's New Agent: `CompanionSnapshots.newAgent(parentID:prompt:branch:base:)`,
  with an empty branch so `Worktrees.suggestBranch(from:)` names it, and no
  base so `AgentLauncher.preferredBase` picks one. No confirmation.
  Analytics: `agentStarted` with `"from_queue": true`.
- Tells the phone through the existing sealed notification path
  ("Started *branch* in Bench from your queue"), opening that tab, when
  notifications are on.
- **If a prompt can't start** (project gone, not a git repo, worktree
  failed, can't decrypt): it's saved on the Mac in Application Support and
  shown so it's not lost. Workbench posts a Mac notification ("A queued
  prompt couldn't start") that opens a small window or sheet. The sheet
  lists each one with its project name, the text (selectable, with Copy),
  why it failed, and **Start in…** (pick a project) or **Delete**. The
  builder picks where it lives; the Overview is a natural home.
- If the relay can't be reached, it waits for the next check; nothing is
  lost, since `take` didn't happen.

### Phone (`BenchPhone/`, `BenchKit/…/UI/CompanionClient.swift`)

**Saved project list (fixes a regression).** After every successful
connection and each snapshot, the phone saves the Mac's latest snapshot
(projects, groups) plus its feature list and the time, per Mac, in the app's
Application Support. When the selected Mac can't be reached, the Projects
screen shows the saved list (screen 1 in the mockup):

- A note at the top: "Your Mac is asleep or offline. These are your
  projects from 2 hours ago." *(My wording.)*
- Sessions are left out, since they'd be stale. Projects show as
  quiet rows in their usual sections.
- Projects with queued prompts show a "1 queued" badge.

**Project screen while offline (screen 3, chosen).** Tapping a project
while the Mac is offline shows:

- A note: "Your Mac is asleep. Prompts you queue start as new agents when
  it's back online."
- A text box ("What should the agent do?") with a **Queue** button, right on
  the screen. The keyboard's dictation works as usual.
- "Starts on a new branch, named from the prompt."
- A **Queued** list underneath, with each prompt waiting for this project.
  Tap one to edit it; swipe to delete. Both go straight to the relay.
- Anything that needs a live Mac (New Claude Tab, Past Sessions, Files,
  Changes, the project menu's live actions) is hidden or dimmed.
- If the saved project isn't a git repo (needs a new optional field on
  `CompanionProject`, since today it has none; a Mac without the field means
  "assume git"), the box is replaced by a line
  saying queued prompts need a git project.
- If the Mac never advertised `offlineQueue`, the box is replaced by "Update
  Workbench on your Mac to queue prompts while it's asleep."

**Keeping the queue straight on the phone.**

- The phone keeps its own copy of each prompt it queued (per Mac, in
  Application Support), with the mailbox id it was sent to.
- It refreshes with `list` (passing its local ids) when the offline project
  screen or Projects screen appears, and when the app becomes active.
- Each local copy is then one of:
  - **Waiting:** still on the relay.
  - **Started:** in the taken ids. It's dropped locally.
  - **Expired:** gone and not taken. It stays on the phone, shown as
    "Expired: your Mac wasn't online for 14 days", with **Queue Again** and
    **Delete**. Never silently dropped.
- From day 12, a waiting prompt shows "Expires in 2 days". *(Claude's call.)*
- Editing a prompt the Mac already took fails with `taken`. The phone then
  says it already started, and doesn't recreate it.
- If an `add` fails (no signal), the prompt stays local as "Not sent yet"
  and is retried when the app is next active. The relay call must succeed
  before the phone says it's queued. Retries reuse the same id, so a retry
  after a lost response can't make a second copy.
- After a new pairing code, the phone still knows the old mailbox id for
  its local copies and lists against it. Started copies are dropped. Anything
  neither waiting nor taken there is re-queued under the new mailbox.
- iPad gets all of this, since it's the same app.

### Privacy policy (`website/privacy.html`)

- The opening summary currently says prompts "never [go] to us". Reword it so
  it's still true: queued prompts pass through and wait on Workbench's
  server, encrypted so only your devices can read them.
- Add **Workbench's queue service** to the list of services the apps talk to.
- Add a bullet under the iPhone section along these lines:
  - prompts you queue while your Mac is offline are encrypted on your phone
    with a key from your pairing code, and stored on Workbench's server until
    your Mac picks them up or 14 days pass;
  - the server keeps only the scrambled text, a random mailbox number, when
    it was added, and for 14 days the random ids of prompts already picked
    up;
  - neither Workbench, its host (Vercel) nor its database provider (Upstash)
    can read them;
  - a new pairing code makes old ones unreadable.
- Be accurate about network details. Workbench doesn't log requests, but its
  host's standard request logs can briefly record the IP address and time of
  each call. So the claim is that nobody can read the prompts, not that the
  calls are invisible. *(Claude's call.)*
- Mention that the phone keeps a copy of your project list from the last
  connection, on the phone only.
- Update the policy's date if it shows one, and run
  `scripts/sync-website.sh` / the usual website publish step.

## Shipping order

1. Relay: add `queue.js`, deploy (`vercel deploy --prod` from `relay/`),
   check `GET /api/queue` says configured.
2. Mac: release with `offlineQueue`. Older phones ignore the new feature.
3. iOS: release. The phone only offers queuing for Macs that advertised the
   feature, so it's safe even before people update their Mac.
4. Website privacy policy goes live with step 1 at the latest.

## Testing

- BenchKit unit tests: key and mailbox id derivation (stable, different
  from the notification key, different tokens → different ids), seal/open
  round trip, opening with the wrong key or wrong mailbox fails.
- Relay: a small Node test or script against a local stand-in for Upstash
  covering add / list / delete / take, atomic `take`, limits and bad input.
- Mac: queue processing with a stand-in relay URL (like
  `BENCH_TEST_FEEDBACK_QUEUE`), including a missing project and a non-git
  project ending up in the "couldn't start" list.
- Phone: the saved snapshot loads when offline; queue, edit, delete with a
  stand-in relay.
- Manual end to end: pair, put the Mac to sleep (or quit Workbench), queue
  two prompts from the phone, wake the Mac, see two agents start and a
  notification arrive.
- Dev builds run from the build folder only. Never install into
  `/Applications` on Matt's Mac.

## Left to the builder

- Exact copy, icons and spacing, within the mockup's direction and
  `PhoneTheme`.
- Where the Mac's "couldn't start" list lives.
- File layout and type names.
- Whether `take` uses `MULTI` or a Lua script.
