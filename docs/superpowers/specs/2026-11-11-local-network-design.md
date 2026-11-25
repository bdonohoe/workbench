# Connecting over the home network (no Tailscale needed)

Date: 2026-11-11. Status: design, waiting for approval. Matt's answers so far are marked.

## Why

Today the iPhone app (and Workbench on another Mac) can only reach a Mac
through Tailscale. Some people don't have it and don't want it, for
example someone with a headless Mac mini in the house who only uses the
phone at home. Tailscale setup is also where people get stuck: a user this
week couldn't connect because another app (MAMP) held port 443 on their Mac.

This adds a second way in: the phone finds the Mac on the same Wi-Fi with
Bonjour and connects to it directly, encrypted, with no account or install.

## The rule (Matt's)

**Tailscale always wins when it's available. The home network is the
fallback.**

## Goals

- A Mac without Tailscale can turn on Remote Access and pair a phone right
  away. It works whenever both are on the same network.
- A Mac with Tailscale puts both ways into one pairing code. The phone uses
  Tailscale, and falls back to the home network when Tailscale can't reach
  the Mac (for example, Tailscale is switched off on the phone).
- The local connection is as private as the Tailscale one: encrypted, and
  the phone only trusts the exact Mac it paired with.
- Everything that works over Tailscale works over the local connection,
  with no protocol changes. It's the same WebSocket, the same hello and
  token, and the same messages.
- The Mac-to-Mac client (Bench/Remote, which uses the same
  `CompanionClient`) gets the fallback too.

## Non-goals

- Reaching the Mac from outside the home network without Tailscale. A
  relay server is a separate, later decision.
- Supporting other VPNs (ZeroTier and so on).
- Changing the Tailscale path, apart from adding the local option next to it.
- Making older phone apps work with a local-only Mac (see Compatibility).

## Anti-goals (would make this a failure even if it works)

- Anyone on the same Wi-Fi being able to see sessions or impersonate the
  Mac. Coffee-shop and office networks are shared.
- Tailscale users facing new setup steps. **Matt approved** a one-time
  local network permission prompt on the Mac, and on the phone the first
  time it falls back, for everyone, including Tailscale users. That's the
  price of the fallback.
- A Tailscale user being silently dropped to a worse path while Tailscale
  works.
- Broadcasting the Mac's or the user's name on the network.

## Agreed experience

**Mac, Settings → Remote Access, and onboarding:**

- **No Tailscale:** the pairing code shows right away, with a short note
  like "Works on your home Wi-Fi. To use it anywhere, set up Tailscale" and
  a link to the existing Tailscale steps. The "Tailscale isn't installed"
  state is no longer an error that blocks pairing.
- **Tailscale working:** the same as today. The code also carries the local
  details, invisibly.
- **Tailscale installed but broken** (HTTPS off, the self-check failing):
  the error still shows in Status. The code still shows too, because the
  home network path works regardless. Onboarding no longer hides the code
  behind a Tailscale error; it shows the code plus the error.
- **Tailscale installed later:** Workbench notices on its own, as it already
  re-checks. The code changes to include the Tailscale address, and the
  user pairs again once to get the away-from-home path. (Builder: the phone
  may say something like "This Mac can now be reached anywhere. Scan its
  code again" if the Mac's welcome says it now has a Tailscale address.
  This is nice-to-have, not required.)
- **Status section:** add a "Home network" row showing that the Mac is
  listening locally, or why it isn't.

**Phone:**

- Pairing works the same way: scan the code, or pair manually.
- The phone tries Tailscale first and falls back to the local connection.
  Once connected locally, it switches back to Tailscale when Tailscale works
  again.
- Away from home with only a local pairing, the Mac looks asleep or
  offline, as it does today. The saved project list and the offline queue
  still work, because the queue goes through Workbench's relay and not
  through the Mac.
- iOS asks once for local network access, the first time the phone tries
  the local path. With the head start below, that's likely to include
  Tailscale users at home. Matt accepted that. Fast home connections win
  over avoiding the prompt.
- Builder's call, small: Settings → the Mac's row says how it's connected
  ("Tailscale" or "Home network").

## How it works

### Mac: a second listener

`CompanionServer` keeps its localhost listener for Tailscale Serve,
unchanged. It adds a second `NWListener`:

- on all interfaces, on a port the system picks (no fixed port, so nothing
  like MAMP can clash);
- with TLS, using a self-signed certificate the Mac makes once and keeps
  (see Certificate);
- advertised with Bonjour as `_workbench._tcp`. The instance name is an
  opaque random id for this Mac, made once and stored, never the computer's
  or user's name;
- feeding the same `accept(_:)` path as the localhost listener, so the
  hello, token check and 15-second timeout apply unchanged.

It runs whenever Remote Access is on, with or without Tailscale, so a
Tailscale-paired phone can fall back to it. (My call: no separate switch
for it. If you want a "Allow connections on this network" switch, say so.)

The test instance (`CompanionServer.testPort`, the secondary instance) must
not advertise under the real Mac's id. Give it its own id, or skip local
listening there.

### Certificate and pinning

- **Mac:** on first use, makes a P-256 key and a self-signed certificate,
  and keeps both (in the login keychain, or as files in the support folder
  with 0600 permissions; builder's choice, but the private key must not be
  readable by other users). It makes a new pair only if they're missing.
  "Make a New Code" does **not** have to rotate the certificate. It rotates
  the token, which is what grants access.
- **Pairing code:** carries the certificate's SHA-256 fingerprint.
- **Phone:** connects with `URLSession` as today, with a delegate that
  answers the server-trust challenge by comparing the presented leaf
  certificate's fingerprint with the pinned one. It accepts on a match,
  rejects otherwise, and ignores the hostname. The Tailscale path keeps
  normal system trust, and the delegate must not loosen it.

Making an X.509 certificate needs DER encoding, which Apple has no public
API for. Either hand-roll the small DER builder (a self-signed cert with
one key is short and testable), or add Apple's `swift-certificates`
package. Builder's call; prefer whichever keeps dependencies smaller.
Turning the key and certificate into the `sec_identity_t` that
`NWProtocolTLS.Options` needs is the fiddly part. Spike it first.

### Pairing code

`PairingInfo` gains an optional local part:

```
bench://pair?host=<identity>&token=<token>&mac=<id>&fp=<sha256 hex>
```

- `mac` is the Bonjour instance id, and `fp` is the certificate fingerprint.
- **`host` stays the Mac's identity everywhere it's used today:**
  `PairingStore`, `SnapshotCache`, `QueueStore`, `NotificationSeal.key`
  and `keyID`, the push payload's `host`, and `MacSwitcher`. Don't change
  what those key on.
  - **Mac with Tailscale:** `host` is the tailnet address (plus
    `servePath`), exactly as today.
  - **Mac without Tailscale:** `host` is a stable made-up name that can't
    resolve, built from the Mac's id, for example `<id>.local-only.workbench`
    (builder picks the exact form). It has to be stable across launches.
- **The Mac must remember the identity it last put in a code** and use it
  for `push.hostName`. Otherwise notification sealing breaks whenever
  Tailscale is down or missing. Today `push.hostName` is nil when Tailscale
  isn't running, so notifications already fail in that case. This fixes it
  as a side effect. When the Mac gains Tailscale, the identity becomes the
  tailnet address. Phones paired under the old identity keep working locally
  until they re-pair, but their notifications are sealed for the old
  identity, so the Mac should seal for the identity of the code shown. This
  means phones on the old code lose sealed notifications until they re-pair.
  Accepted, since we agreed they re-pair once.
- **The identity is sticky (my call).** Once a Mac has had a tailnet
  address, it keeps using that address, and its `servePath`, as `host` in the
  code, even while Tailscale is signed out, not running or broken. The
  identity doesn't flip when Tailscale goes up and down, and the code stays
  on screen with the local part working. It changes only when Tailscale
  reports a different address, or after Tailscale is uninstalled. The
  made-up local-only host is used only by a Mac that has never had one.
- **Re-pairing the same Mac replaces it (my call).** In `PairingStore` and
  `RemoteMacs`, a new pairing whose `mac` id matches a saved one replaces
  that entry instead of adding a second. It carries over the saved name, and
  moves the saved project list and queued-prompts file to the new host. The
  relay mailbox is keyed by token, not host, so prompts already sent are
  unaffected.
- Manual pairing keeps the two fields. The local part only comes in through
  the QR code or the pairing link. (Manual entry of a local-only Mac isn't
  supported; say so in the manual sheet's footer.)

### Phone: choosing a path

In `CompanionClient.open()`, and in `MacSwitcher`'s probe:

1. If the pairing has a real Tailscale `host`, try `wss://host/ws` as today.
2. If it has a local part, resolve the Bonjour service `mac` with
   `NWBrowser` to an address and port, then try `wss://<address>:<port>/ws`
   with pinning.
3. The order is "prefer Tailscale", not "wait for Tailscale to fail". Start
   Tailscale, give it a short head start (on the order of 1–2 s), then start
   local too. Keep the first to finish its hello, preferring Tailscale if
   both finish in that window, and close the other. A wrong-network
   Tailscale attempt can take a long time to time out, and the user
   shouldn't wait that long at home.
4. While connected locally, check Tailscale quietly (when the app comes to
   the foreground, and every minute or so), and switch over when it
   answers. Don't tear down the local connection mid-reply. Swap at a quiet
   moment, or simply on the next reconnect. Builder's call, as long as a
   working Tailscale path gets used without the user doing anything.
5. Errors: if both fail, show the Tailscale error as today. Add a local-only
   message for Macs without Tailscale, along the lines of "Your Mac isn't on
   this network. It's asleep, or you're away from home."

Info.plist for the phone (and for the Mac, which also browses as a
client): `NSLocalNetworkUsageDescription` ("Workbench looks for your Mac on
your home network when Tailscale isn't available.") and
`NSBonjourServices = [_workbench._tcp]`. On macOS 15+, advertising and
connecting on the local network can trigger the Mac's own local network
prompt, so word it to match.

### Compatibility

- New Mac, old phone: the code adds unknown query items, which old phones
  ignore. Tailscale Macs keep working exactly as before. A local-only Mac's
  code gives an old phone a made-up host that fails to connect. Accepted:
  the phone app ships with this.
- Old Mac, new phone: no local part in the code, so the phone uses Tailscale
  only, as today.
- No protocol version bump is needed. Add a `localNetwork` feature flag to
  the welcome anyway, so the phone can tell that a Mac supports it (for
  the "pair again" hint).

## Security notes

- The local listener is reachable by anyone on the network. What protects it:
  - TLS with a pinned certificate, so the network can't read or tamper.
  - The 32-byte token, checked on hello as now.
  - The existing 15-second timeout for connections that never say hello.
- Add basic protection against token guessing on the local listener: after
  repeated bad hellos from an address, ignore it for a while. My call: it's
  cheap, and the LAN is a wider audience than a tailnet.
- The Bonjour name is a random id. It reveals that some Workbench is on
  the network, but not whose.
- Update `website/privacy.html`. It currently says the phone connects "over
  your own Tailscale network". It should say it connects directly over
  Tailscale or, at home, over your local network, still without passing
  through our servers, and that Workbench announces itself on the local
  network with a random id.

## Constraints

- Never install to /Applications or quit the user's running Workbench while
  building or testing (see the repo memory). Test dev builds from the build
  folder, and use the secondary-instance mechanism for running a second copy.
- Keep the existing Tailscale code paths behaving the same.
- Unit-test the pure parts in BenchKit: `PairingInfo` URL round-trip with and
  without the local part, the fingerprint comparison, path-choice logic as a
  pure function, and DER building if hand-rolled.

## Left to the builder

- Where the certificate and key live.
- `swift-certificates` vs a hand-rolled DER builder.
- The exact made-up host form for local-only Macs.
- The exact head-start timing and when to switch back to Tailscale.
- The exact UI wording (use the repo's existing voice), and the "connected
  via" detail.
