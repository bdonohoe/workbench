# Home Network Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the iPhone app (and Workbench on another Mac) connect to a Mac over the local network, found with Bonjour, encrypted with a pinned self-signed certificate. It's the fallback when Tailscale isn't available, and the only path for Macs without Tailscale.

**Architecture:**
- `CompanionServer` gains a second `NWListener`: TLS, all interfaces, a system-picked port, advertised as `_workbench._tcp`. It feeds the existing `accept(_:)`.
- `PairingInfo` gains an optional local part (`mac` id, certificate `fingerprint`). `host` stays the Mac's identity everywhere.
- `CompanionClient` gives Tailscale a head start, races it against a Bonjour-resolved local connection that checks the pin, and prefers Tailscale.

**Tech Stack:**
- Swift 6 and SwiftUI.
- Network.framework: `NWListener`, `NWBrowser`, `NWProtocolTLS`.
- Security.framework and CryptoKit.
- `URLSessionWebSocketTask` with a trust delegate.
- Swift Testing.
- No new packages: the DER builder is hand-rolled.

**Spec:** `docs/superpowers/specs/2026-11-11-local-network-design.md` (read it first; it holds the reasons).

## Global Constraints

- Never install to /Applications. Never run `make install`, `make install-beta`, `make run` or `make phone-install`, and never pkill, killall or kill anything matching "Workbench". The user's real app is running on this Mac. Kill only xcodebuild/xctest PIDs you started.
- Build and test with:
  - `make build` (Mac)
  - `make phone` (iOS simulator build)
  - `make test` (BenchTests)
  - `cd BenchKit && swift test` (BenchKit)
- If you're in a worktree, link the main checkout's `vendor/` first.
- "Tailscale always wins when it's available. The home network is the fallback."
- The existing Tailscale paths must behave as before. Don't change what `PairingStore`, `SnapshotCache`, `QueueStoreCore`, `NotificationSeal` or `RemoteMacs` key on (`host`).
- Bonjour service type: `_workbench._tcp`. The instance name is the Mac's random `mac` id, never a user or computer name.
- Local-only host form: `<mac id>.local-only.workbench`.
- Pairing URL: `bench://pair?host=…&token=…&mac=…&fp=…`. `fp` is the lowercase hex SHA-256 of the certificate's DER.
- Welcome feature flag: `CompanionFeature.localNetwork = "localNetwork"`.
- Usage string, phone and Mac: `"Workbench looks for your Mac on your home network when Tailscale isn't available."`
- Mac-side copy: `"Works on your home Wi-Fi. To use it anywhere, set up Tailscale."`
- Phone error when only local is possible: `"Your Mac isn't on this network. It's asleep, or you're away from home."`
- A one-time local network prompt for everyone is approved (spec, Anti-goals).
- Keep the repo's comment and copy voice: short, plain sentences.
- Commit after each task with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on a branch (`feat/local-network`), not main.

## Review Focus

1. **IPv6 link-local results from Bonjour** (`fe80::…%en0`). A URL built from them must be valid, or the resolver must prefer IPv4 or the `.local` hostname. Test in Task 6.
2. **Networks that block devices from seeing each other** (hotel or office Wi-Fi), where Bonjour finds nothing. The local attempt must give up in a bounded time (8 s) and must never hold up a working Tailscale connection. Test in Task 6.
3. **The phone denies local network permission.** The browser waits with a policy-denied error. The client must stop trying locally and show a message pointing to Settings, not spin forever. Test in Task 6.
4. **A certificate that doesn't match the pin** (another Workbench on the network, or an impostor). The connection must be rejected before the hello is sent. Test in Task 3.
5. **"Make a New Code", the server stopping, or the network changing** must close local clients too. The listener must come back and re-advertise. Test in Task 3.

---

### Task 1: Self-signed certificate builder and pin (BenchKit)

**Files:**
- Create: `BenchKit/Sources/BenchKit/SelfSignedCertificate.swift`
- Create: `BenchKit/Sources/BenchKit/CertificatePin.swift`
- Test: `BenchKit/Tests/BenchKitTests/SelfSignedCertificateTests.swift`

**Interfaces:**
- Produces:
  - `public enum SelfSignedCertificate { public static func make(key: P256.Signing.PrivateKey, commonName: String, serial: UInt64, notBefore: Date, years: Int) throws -> Data }`. It returns X.509 v3 DER, ECDSA-with-SHA256, self-signed.
  - `public enum CertificatePin { public static func fingerprint(_ der: Data) -> String }` (lowercase hex SHA-256).
  - `public static func matches(_ trust: SecTrust, pin: String) -> Bool`. It compares the leaf only and ignores the hostname and the chain.

- [ ] **Step 1: Write the failing tests**
  - `makesACertificateSecurityAccepts`: build with a fresh key and CN `"Workbench"`. `SecCertificateCreateWithData(nil, der)` is non-nil. `SecCertificateCopyKey` gives a key whose external representation equals `key.publicKey.x963Representation`.
  - `signatureVerifies`: parse the TBS bytes back out of the DER and check `key.publicKey.isValidSignature(...)` over them. A tiny DER reader in the test is fine.
  - `fingerprintIsStable`: the same DER gives the same 64-char lowercase hex. Different DER gives a different value.
  - `pinMatchesOnlyItsCertificate`: build a `SecTrust` with `SecTrustCreateWithCertificates` for cert A. `matches(trust, pin: fingerprint(A))` is true, and with `fingerprint(B)` it's false.
- [ ] **Step 2: Run `cd BenchKit && swift test --filter SelfSignedCertificateTests`.** Expected: fails to compile.
- [ ] **Step 3: Implement.**
  - A minimal DER writer (SEQUENCE, INTEGER, OID, UTCTime/GeneralizedTime, BIT STRING, NULL, explicit tag `[0]` for version).
  - SubjectPublicKeyInfo for id-ecPublicKey / prime256v1 using `x963Representation`.
  - Sign the TBS with `key.signature(for:).derRepresentation`.
  - Add a `basicConstraints CA:false` extension, and `subjectAltName` DNS `workbench.local` (harmless; the pin is what's checked).
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(kit): self-signed certificate builder and pin`

### Task 2: Pairing code local part (BenchKit)

**Files:**
- Modify: `BenchKit/Sources/BenchKit/Pairing.swift`
- Modify: `BenchKit/Sources/BenchKit/CompanionProtocol.swift` (feature flag)
- Test: `BenchKit/Tests/BenchKitTests/PairingInfoTests.swift`

**Interfaces:**
- Produces:
  - `PairingInfo.local: LocalEndpoint?`, where `public struct LocalEndpoint: Codable, Sendable, Hashable { public var mac: String; public var fingerprint: String }`.
  - `init(host:token:local: LocalEndpoint? = nil)`.
  - `public static func localOnlyHost(mac: String) -> String` (`"\(mac).local-only.workbench"`).
  - `public var isLocalOnly: Bool` (host has the suffix `.local-only.workbench`).
  - `socketURL` returns nil when `isLocalOnly`.
  - `CompanionFeature.localNetwork`.

- [ ] **Step 1: Write the failing tests**
  - `roundTripsWithLocalPart`: build `PairingInfo(host: "a.ts.net", token: "t", local: .init(mac: "m1", fingerprint: "ab"))`, then `PairingInfo(url: info.url!) == info`.
  - `oldCodesStillParse`: `bench://pair?host=a.ts.net&token=t` parses with `local == nil`.
  - `ignoresHalfALocalPart`: `mac` without `fp` gives `local == nil`.
  - `decodesSavedPairingsFromBeforeLocal`: JSON `{"host":"a","token":"t"}` decodes with `local == nil`.
  - `localOnlyHasNoTailscaleURL`: `PairingInfo(host: PairingInfo.localOnlyHost(mac: "m1"), token: "t").socketURL == nil` and `isLocalOnly`.
- [ ] **Step 2: Run `swift test --filter PairingInfoTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** in `Pairing.swift`. Add `localNetwork` to `CompanionFeature`.
- [ ] **Step 4: Run the BenchKit tests.** Expected: all pass.
- [ ] **Step 5: Commit.** `feat(kit): pairing codes carry the Mac's local id and certificate pin`

### Task 3: The Mac's identity and local TLS listener

The risky part, so it goes first on the Mac side. If `sec_identity_t` creation doesn't work as described, stop and report before going on.

**Files:**
- Create: `Bench/Companion/LocalIdentity.swift`
- Create: `BenchKit/Sources/BenchKit/HelloThrottle.swift`
- Modify: `Bench/Companion/CompanionServer.swift` (second listener, throttle, stop both)
- Modify: `Bench/Info.plist` (`NSLocalNetworkUsageDescription`, `NSBonjourServices` = `["_workbench._tcp"]`)
- Test: `BenchTests/LocalListenerTests.swift`, `BenchKit/Tests/BenchKitTests/HelloThrottleTests.swift`

**Interfaces:**
- Consumes: `SelfSignedCertificate.make`, `CertificatePin` (Task 1), `CompanionFeature.localNetwork` (Task 2).
- Produces:
  - `final class LocalIdentity { static func loadOrMake(folder: URL, keychainLabel: String) throws -> LocalIdentity; let macID: String; let fingerprint: String; let identity: sec_identity_t }`.
    - `macID` is 16 random bytes as lowercase hex, saved in `folder/local-id`.
    - The certificate DER is saved in `folder/local-cert.der`.
    - The private key goes in the login keychain under `keychainLabel`. Pair them with `SecIdentityCreateWithCertificate`.
    - It makes new ones only when something is missing or doesn't match.
    - Secondary instances use a different folder and label, so they never share the real Mac's id.
  - `CompanionServer`:
    - `init(..., identity: LocalIdentity? = nil, advertises: Bool = true)`.
    - `private(set) var localPort: UInt16?` and `private(set) var localError: String?`.
    - `start()` also starts the local listener when `identity != nil`, and `stop()` stops both.
  - `struct HelloThrottle` (BenchKit, pure): `mutating func failed(from: String, at: Date)` and `func isBlocked(_ address: String, at: Date) -> Bool`. Five failures within 60 s block that address for 300 s.

- [ ] **Step 1: Write the failing tests**
  - `HelloThrottleTests`:
    - four failures don't block, and a fifth within 60 s does;
    - the block ends after 300 s;
    - failures more than 60 s apart don't add up.
  - `LocalListenerTests`, using the `CompanionServerTests` helpers. Start a server with a `LocalIdentity` in a temp folder, a test keychain label and `advertises: false`, then wait for `localPort`.
    - `pinnedClientConnects`: a `URLSession` whose delegate checks `CertificatePin.matches` opens `wss://127.0.0.1:<localPort>/ws`. A hello with the right token gets a welcome whose features include `localNetwork`.
    - `wrongPinIsRejected` (Review Focus 4): the same with pin `"00…"`. The task fails with a TLS error and the server never records a device.
    - `badTokensGetThrottled`: five bad hellos from 127.0.0.1, then a good one, which is refused (connection closed with no welcome).
    - `stopClosesLocalClients` (Review Focus 5): connect, `server.stop()`, and the client's receive fails. Then `start()` again and a new `localPort` accepts.
    - `identityIsStable`: `loadOrMake` twice in the same folder gives the same `macID` and `fingerprint`.
  - Clean up the test keychain item in each test.
- [ ] **Step 2: Run `make test`.** Expected: FAIL (types missing).
- [ ] **Step 3: Implement `LocalIdentity`, `HelloThrottle`, and the second listener.**
  - Parameters: `NWParameters(tls: options, tcp: .init())`. Use `sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)` and `sec_protocol_options_set_min_tls_protocol_version(…, .TLSv12)`. Use the same WebSocket options as the localhost listener.
  - No `requiredLocalEndpoint`, and port `.any`.
  - `listener.service = NWListener.Service(name: macID, type: "_workbench._tcp")` when `advertises`.
  - Set `localPort` from `listener.port` on `.ready`.
  - On `.failed`, set `localError`, cancel, and retry after 5 s while the server is meant to run. This covers network changes.
  - Feed `accept(_:)`. Throttle by `connection.endpoint` host, only for connections from the local listener: tag the `Client` with `isLocal`.
- [ ] **Step 4: Run `make test`.** Expected: the new and existing tests pass.
- [ ] **Step 5: Commit.** `feat(mac): local TLS listener advertised over Bonjour`

### Task 4: Mac identity, pairing code and publish without Tailscale

**Files:**
- Create: `BenchKit/Sources/BenchKit/PairingIdentity.swift`
- Modify: `Bench/Companion/Companion.swift`
- Test: `BenchKit/Tests/BenchKitTests/PairingIdentityTests.swift`

**Interfaces:**
- Consumes: `LocalIdentity` and `CompanionServer(identity:)` (Task 3); `PairingInfo.local` and `localOnlyHost` (Task 2).
- Produces:
  - `public enum PairingIdentity { public static func host(tailnetAddress: String?, remembered: String?, isTailscaleInstalled: Bool, mac: String) -> String }`. The rules:
    1. the current tailnet address if there is one;
    2. otherwise the remembered address, if it isn't local-only and Tailscale is still installed;
    3. otherwise `localOnlyHost(mac:)`.
  - `Companion.identityHost: String`, saved in UserDefaults under `companion.identityHost` whenever it changes.
  - `Companion.pairing` is always non-nil when the local identity loaded: `PairingInfo(host: identityHost, token: token, local: .init(mac:, fingerprint:))`.
  - `push.hostName = identityHost` always.
  - `Companion.hasTailscale: Bool` (installed and has an address), for the UI.

- [ ] **Step 1: Write the failing tests** for each rule:
  - `prefersCurrentTailnet`
  - `keepsRememberedWhenTailscaleIsDown`
  - `dropsRememberedWhenUninstalled`
  - `neverRemembersLocalOnly`: remembered local-only plus a new tailnet address gives the tailnet address.
  - `localOnlyWithoutTailscale`
- [ ] **Step 2: Run `swift test --filter PairingIdentityTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - In `publish()`, "Tailscale isn't installed" and "isn't running or signed in" no longer stop the pairing code from appearing. Keep `tailscaleError` set for the Status row only when Tailscale is installed but broken. Not installed means no error, just the note.
  - Load `LocalIdentity` in `init`. Folder: `BenchPaths.support`. Label: `"Workbench local network"`, plus a suffix for secondary instances.
  - If it fails, keep working without the local part and log the problem in `server.localError`.
  - Add `localNetwork` to `CompanionServer.features`.
- [ ] **Step 4: Run `swift test` and `make test`.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(mac): pairing code works without Tailscale and keeps a stable identity`

### Task 5: Mac Settings and onboarding

**Files:**
- Modify: `Bench/Views/SettingsPage.swift` (`CompanionSettings`, about lines 590–690)
- Modify: `Bench/Views/Onboarding/OnboardingView.swift` (about lines 955–1000)

**Interfaces:**
- Consumes: `Companion.pairing`, `hasTailscale`, `tailscaleError`, `server.localPort`, `server.localError` (Tasks 3–4).

- [ ] **Step 1: Settings.**
  - The pairing code shows whenever `pairing` exists.
  - Without `hasTailscale`, show the Mac-side copy under the code, with a link to `https://tailscale.com/download` labeled "Set Up Tailscale".
  - The code's description becomes: "The code holds how to reach this Mac and a secret…"
  - The detail text of "Let my iPhone and other Macs connect" says: "It connects over Tailscale or your home network, so only your own devices can reach it."
  - Status:
    - a new "Home network" row: "On this network" when `localPort != nil`, otherwise `localError ?? "Starting…"`;
    - the "Tailscale" row shows "Not set up" in secondary when it isn't installed, instead of the red error.
- [ ] **Step 2: Onboarding.**
  - Show the code whenever `pairing` exists, with any Tailscale error underneath it, not in place of it.
  - Add the same Mac-side copy when there's no Tailscale.
  - Replace the "Asking Tailscale for this Mac's name…" spinner text with "Getting the pairing code ready…".
  - Update the "It connects over Tailscale…" sentence the same way as Settings.
- [ ] **Step 3: `make build`.** Expected: BUILD SUCCEEDED. Check the two screens by reading the code paths for no Tailscale, Tailscale working and Tailscale with HTTPS off. Don't launch the debug app; see Global Constraints.
- [ ] **Step 4: Commit.** `feat(mac): pairing code and status for the home network`

### Task 6: Client path choice and local connection (BenchKit)

**Files:**
- Create: `BenchKit/Sources/BenchKit/UI/LocalResolver.swift`
- Create: `BenchKit/Sources/BenchKit/UI/PinnedSession.swift`
- Create: `BenchKit/Sources/BenchKit/ConnectionRace.swift`
- Modify: `BenchKit/Sources/BenchKit/UI/CompanionClient.swift` (`open()`, `failed`, `plain`, welcome handling)
- Test: `BenchKit/Tests/BenchKitTests/ConnectionRaceTests.swift`, `BenchKit/Tests/BenchKitTests/LocalResolverTests.swift`

**Interfaces:**
- Consumes: `PairingInfo.local`, `isLocalOnly`, `socketURL` (Task 2); `CertificatePin.matches` (Task 1).
- Produces:
  - `public enum ConnectionPath: Sendable, Equatable { case tailscale, local }`.
  - `public struct ConnectionRace` (pure), with `headStart = 1.5`, `localTimeout = 8`, `holdForTailscale = 0.3`:
    - `init(hasTailscale: Bool, hasLocal: Bool)`
    - `func startsLocal(at elapsed: TimeInterval) -> Bool`
    - `mutating func welcomed(_ path: ConnectionPath, at: TimeInterval) -> ConnectionPath?`. It returns the winner when decided. Tailscale wins immediately. Local wins once `holdForTailscale` has passed with no Tailscale welcome; the client calls `tick(at:)` to let that hold expire.
    - `mutating func failed(_ path: ConnectionPath) -> Bool`. It returns true when both possible paths have failed.
  - `LocalResolver`:
    - `static func resolve(mac: String, timeout: TimeInterval) async throws -> URL`. It browses `_workbench._tcp` for the instance `mac`, connects with `NWConnection` to resolve, and builds the URL from the remote endpoint.
    - `static func socketURL(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL?`. It prefers IPv4. For IPv6 it brackets the address and percent-encodes the zone (`%25`).
    - It throws `LocalResolver.Failure.denied` on a policy-denied state, and `.notFound` on timeout.
  - `PinnedSession.make(pin: String) -> URLSession` (delegate uses `CertificatePin.matches`).
  - `CompanionClient`:
    - `public private(set) var path: ConnectionPath?` (set on welcome, nil on disconnect);
    - `public private(set) var macHasTailscale: Bool` (from the welcome's `localNetwork` feature plus a non-local-only host);
    - and while `path == .local` and the pairing has a Tailscale URL, `tryTailscaleQuietly()`.

- [ ] **Step 1: Write the failing tests**
  - `ConnectionRaceTests`:
    - `tailscaleOnlyNeverStartsLocal`
    - `localOnlyStartsLocalAtZero`
    - `localStartsAfterHeadStart`: false at 1.0, true at 1.5.
    - `tailscaleBeatsLocalInsideHold`: local welcomed at 2.0 and Tailscale at 2.2 gives `.tailscale`.
    - `localWinsAfterHold`: local at 2.0, `tick(at: 2.31)` gives `.local`.
    - `bothFailedEndsTheRace`
    - `localGivesUpAtTimeout` (Review Focus 2): `startsLocal`/elapsed past 1.5 + 8 counts as a local failure.
  - `LocalResolverTests`:
    - `ipv4URL`: `wss://192.168.1.5:50123/ws`.
    - `ipv6LinkLocalURL` (Review Focus 1): `fe80::1%en0` gives `wss://[fe80::1%25en0]:50123/ws`, `URL(string:)` is non-nil, and its `host` round-trips.
    - `deniedMapsToPlainMessage` (Review Focus 3): `CompanionClient.plain(LocalResolver.Failure.denied)` contains `"Local Network"` and `"Settings"`.
    - `notFoundForLocalOnlyMac`: `plain(.notFound)` equals the Global Constraints phone error.
- [ ] **Step 2: Run `swift test`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `open()` runs the race. The Tailscale attempt is today's `URLSession.shared` task. The local attempt is `LocalResolver.resolve` and then a `PinnedSession` task.
  - Send the hello on each attempt, and treat its welcome as "welcomed". When the race picks a winner, cancel the loser and hand the winner to today's `receive` loop unchanged.
  - Once denied, stop trying locally until the next `connect` or foreground, so the client doesn't loop on denied. If both fail, `failed(_:)` gets the Tailscale error, or the local one for a local-only Mac.
  - `tryTailscaleQuietly()` runs on `retry()`/foreground and every 60 s while on local. It opens a Tailscale probe (hello and welcome, then close). On success it sets a flag, so the next natural reconnect uses Tailscale. If no session is being watched with a reply in flight, it reconnects right away.
- [ ] **Step 4: Run `swift test`.** Expected: all pass. Also run `make build` and `make phone` (BenchKit is shared).
- [ ] **Step 5: Commit.** `feat(kit): fall back to the home network, preferring Tailscale`

### Task 7: Phone and Mac-client integration

**Files:**
- Modify: `BenchPhone/PairingStore.swift` (`pair`)
- Modify: `Bench/Remote/RemoteMacs.swift` (`add`)
- Modify: `BenchKit/Sources/BenchKit/UI/SnapshotCache.swift`, `BenchKit/Sources/BenchKit/UI/QueueStoreCore.swift` (`move(from:to:)`)
- Modify: `BenchPhone/MacSwitcher.swift` (`probe`)
- Modify: `BenchPhone/PairView.swift` (manual footer)
- Modify: `BenchPhone/PhoneSettings.swift` (connected-via line)
- Modify: `project.yml` (BenchPhone: `INFOPLIST_KEY_NSLocalNetworkUsageDescription`; Bonjour services via an `info` plist entry or `INFOPLIST_KEY_NSBonjourServices`, whichever XcodeGen supports for an array)
- Test: `BenchKit/Tests/BenchKitTests/SnapshotCacheTests.swift`, `QueueStoreTests.swift` (add cases)

**Interfaces:**
- Consumes: `PairingInfo.local` (Task 2), `CompanionClient.path` and `LocalResolver`/`PinnedSession` (Task 6).
- Produces:
  - `SnapshotCache.move(from: String, to: String)`
  - `QueueStoreCore.move(folder: URL, from: String, to: String)`
  - `PairingStore.pair` replaces an entry with the same `local?.mac` and a different host. It moves names, the saved list and queued prompts to the new host, and keeps the selection.

- [ ] **Step 1: Write the failing tests.**
  - `SnapshotCacheTests.movesToNewHost`: save under `a`, move from `a` to `b`. `load(b)` equals the saved value and `load(a)` is nil.
  - `QueueStoreTests.movesToNewHost`: the same for the queue file. A `shared(folder:host:)` actor for the old host must not keep writing the old file; drop it from the shared table.
- [ ] **Step 2: Run `swift test`.** Expected: FAIL.
- [ ] **Step 3: Implement.** Do the moves and `PairingStore.pair`. Add the same matching-by-mac to `RemoteMacs.add`, which has no queue or snapshot to move.
  - `MacSwitcher.probe` uses the same race: try `socketURL`, and if it fails, `LocalResolver.resolve` with a 3 s timeout and a pinned session.
  - Manual pairing footer: append "To pair with a Mac that doesn't use Tailscale, scan its code instead."
  - Phone Settings, the current Mac's row: "Connected over Tailscale" or "Connected over your home network", from `client.path`.
- [ ] **Step 4: Run `swift test`, `make phone` and `make build`.** Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit.** `feat(phone): pair and reconnect over the home network`

### Task 8: Privacy policy and release notes

**Files:**
- Modify: `website/privacy.html` (line 66, plus the "Last updated" date → November 11, 2026)
- Modify: `fastlane/whattotest.txt`

- [ ] **Step 1: Update the policy.** Replace "over your own Tailscale network" with "over your own Tailscale network or, at home, directly over your local network". Then add one sentence: "To be found at home, Workbench announces itself on your local network under a random ID, not your name or your Mac's name." Leave the rest unchanged.
- [ ] **Step 2: Add a TestFlight note:** "No Tailscale? Workbench on your Mac now shows a pairing code right away, and the app connects over your home Wi-Fi. With Tailscale, it still uses Tailscale, and falls back to Wi-Fi when Tailscale is off."
- [ ] **Step 3: Commit.** `docs: privacy policy and TestFlight notes for home network connections`

### Task 9: End-to-end check (manual, with Matt)

- [ ] Write the steps into the PR description. Don't run them yourself (they need the installed app quit, which only Matt does):
  1. **Release build from the build folder:** with Tailscale off on the phone, it pairs and connects at home, and Settings says "home network".
  2. **Phone's Tailscale turned on:** after a minute, or on the next foreground, it says Tailscale.
  3. **Off the Wi-Fi with Tailscale off:** it shows asleep or offline, and queuing works.
  4. **Make a New Code:** the phone asks to pair again.
