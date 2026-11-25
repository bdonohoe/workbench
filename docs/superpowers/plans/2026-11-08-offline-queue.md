# Queue Prompts for a Sleeping Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the iPhone/iPad app queue a prompt for a project while its paired Mac is asleep. The Mac starts it as a new agent as soon as it's back online. Prompts wait on Workbench's relay, encrypted end to end.

**Architecture:**
- **Shared code (BenchKit):** derives a mailbox id and an AES-GCM key from the pairing token, and holds the relay client.
- **Relay:** a new Vercel function, `relay/api/queue.js`, stores sealed prompts in Upstash Redis under that id and hands them out once.
- **Mac:** a new `OfflineQueue` object polls the relay on launch, wake, network return and every 5 minutes, then starts each prompt through `CompanionSnapshots.newAgent`.
- **Phone:** saves the last project snapshot per Mac, shows it while offline, and offers a queue box on each project's screen.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`import Testing`), CryptoKit, Node 20 (no dependencies, `node --test`), Upstash Redis REST.

**Spec:** `docs/superpowers/specs/2026-11-08-offline-queue-design.md`

## Global Constraints

- **Never install into `/Applications`.** Never run `make install`, `make install-beta` or `make phone-install`, and never copy into `/Applications`. Run Mac builds from `build/Build/Products/Debug/` (`make build`; `make run` opens from there).
- Key derivation is HKDF-SHA256 over the pairing token's UTF-8 bytes:
  - mailbox id: salt `"workbench-queue-id-v1"`, 32 bytes, lowercase hex (64 chars);
  - prompt key: salt `"workbench-queue-key-v1"`, 32 bytes;
  - empty `info` for both.
- AES-GCM uses the mailbox id's UTF-8 bytes as associated data. The sealed form is base64 of `.combined`.
- Relay limits:
  - mailbox id matches `^[0-9a-f]{64}$`;
  - sealed prompt at most 32 KB (32768 base64 chars);
  - at most 25 waiting prompts per mailbox;
  - expiry 14 days (1209600 s) after the last add, and for taken ids 14 days after the last take.
- The mailbox id travels only in JSON bodies, never in a URL.
- Nothing is logged on the relay (no `console.log` of bodies or ids).
- Mac checks: on launch, on `NSWorkspace.didWakeNotification`, when `NWPathMonitor` becomes satisfied, and every 300 s. Only while `Companion.isEnabled`.
- DEBUG builds read the queue URL only from the `BENCH_TEST_OFFLINE_QUEUE` env var. If it's unset they never check.
- Expiry warning on the phone starts 12 days after `queuedAt` ("Expires in 2 days" / "Expires tomorrow").
- New feature string: `CompanionFeature.offlineQueue = "offlineQueue"`.
- Copy and code comments follow the repo's plain style: short sentences, no jargon.

## Review Focus

1. **Editing a prompt while the Mac takes it.** The edit must come back as "already started" and must not recreate the prompt. Pinned by `QueueRelayTests.addAfterTakeIsRefused` (Task 3) and `QueueSyncTests.editOfTakenIsStarted` (Task 2).
2. **No signal when tapping Queue.** The prompt must stay on the phone as "Not sent yet" and go out later with the same id. Pinned by `QueueStoreTests.failedAddStaysUnsentAndRetriesWithSameID` (Task 7).
3. **The Mac wakes before Wi-Fi is back.** The first check fails and nothing is lost; the network-back trigger checks again. Pinned by `OfflineQueueTests.relayFailureKeepsNothingAndRetriesLater` (Task 4).
4. **The project was deleted, or isn't git, on the Mac.** The prompt lands in the "couldn't start" list with its text intact. Pinned by `OfflineQueueTests.missingProjectGoesToFailed` and `nonGitProjectGoesToFailed` (Task 4).
5. **A very long or emoji-heavy prompt.** It must round-trip exactly, and a prompt over the 32 KB sealed limit gets a clear phone message instead of a silent failure. Pinned by `QueueSealTests.roundTripsUnicodeExactly` (Task 1) and `QueueRelayTests.oversizeIsRefused` (Task 3), plus the phone showing `QueueRelayError.tooLarge` (Task 7).

---

### Task 1: Queue keys, sealing and the prompt type (BenchKit)

**Files:**
- Create: `BenchKit/Sources/BenchKit/OfflineQueue.swift`
- Modify: `BenchKit/Sources/BenchKit/CompanionExtras.swift`: add `offlineQueue` to the `CompanionFeature` extension.
- Modify: `BenchKit/Sources/BenchKit/CompanionProtocol.swift`: add `public var isGit: Bool?` to `CompanionProject` (optional, defaults `nil` in `init`; `nil` means "assume git").
- Test: `BenchKit/Tests/BenchKitTests/QueueSealTests.swift`

**Interfaces:**
- Produces:
  - `public struct QueuedPrompt: Codable, Sendable, Hashable, Identifiable { id: UUID; projectID: UUID; projectName: String; prompt: String; queuedAt: Date; device: String }`
  - `public enum QueueSeal`, with:
    - `static func mailboxID(token: String) -> String`
    - `static func key(token: String) -> SymmetricKey`
    - `static func seal(_ prompt: QueuedPrompt, key: SymmetricKey, mailbox: String) throws -> String`
    - `static func open(_ sealed: String, key: SymmetricKey, mailbox: String) -> QueuedPrompt?`
  - Uses `CompanionCoding`'s date strategy if there is one, otherwise ISO 8601.
  - `CompanionFeature.offlineQueue`
  - `CompanionProject.isGit`

- [ ] **Step 1: Write the failing tests** in `QueueSealTests.swift` (`@Suite struct QueueSealTests`):
  - `mailboxIDIsStableHex`: the same token twice gives an equal value; it matches `^[0-9a-f]{64}$`.
  - `differentTokensDifferentMailboxes`
  - `keyDiffersFromNotificationKey`: `QueueSeal.key(token:)` bytes ≠ `NotificationSeal.key(token:host:"mac")` bytes.
  - `roundTripsUnicodeExactly`: a prompt containing `"Fix the 🐛 in café — “quotes”\nline 2"` plus 20 000 characters seals and opens equal.
  - `wrongKeyFails` and `wrongMailboxFails`: `open` returns nil.
  - `projectDecodesWithoutIsGit`: a `CompanionProject` JSON with no `isGit` key decodes with `isGit == nil`.
- [ ] **Step 2: Run, expect failure.** `cd BenchKit && swift test --filter QueueSealTests` fails with "cannot find 'QueueSeal'".
- [ ] **Step 3: Implement** per the interfaces and Global Constraints, following `NotificationSeal`'s shape.
- [ ] **Step 4: Run, expect PASS.** `cd BenchKit && swift test --filter QueueSealTests`. Then run the full `swift test` to confirm nothing else broke.
- [ ] **Step 5: Commit.** `git commit -m "BenchKit: keys and sealing for queued prompts"`

### Task 2: Relay client and sync rules (BenchKit)

**Files:**
- Create: `BenchKit/Sources/BenchKit/QueueRelay.swift`
- Test: `BenchKit/Tests/BenchKitTests/QueueRelayClientTests.swift`, `BenchKit/Tests/BenchKitTests/QueueSyncTests.swift`

**Interfaces:**
- Consumes: Task 1's `QueuedPrompt`, `QueueSeal`.
- Produces:
  - `public struct QueueItem: Codable, Sendable, Hashable { id: UUID; sealed: String; addedAt: Date }`
  - `public enum QueueRelayError: Error, Equatable { case taken, full, tooLarge, notConfigured, badAnswer(Int), unreachable }`
  - `public struct QueueRelay: Sendable`:
    - `init(url: URL, mailbox: String, transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) })`
    - `static let productionURL = URL(string: "https://workbench-push.vercel.app/api/queue")!`
  - `static func urlForBuild() -> URL?`: in DEBUG, `BENCH_TEST_OFFLINE_QUEUE` or nil; in Release, `productionURL`. Both the Mac and the phone use it.
    - `func add(id: UUID, sealed: String) async throws`
    - `func list(asking ids: [UUID]) async throws -> (items: [QueueItem], taken: Set<UUID>)`
    - `func delete(id: UUID) async throws`
    - `func take() async throws -> [QueueItem]`
  - `public enum QueueSync`:
    - `enum State: Equatable { case waiting, started, expired }`
    - `static func state(of id: UUID, items: [QueueItem], taken: Set<UUID>) -> State`
    - `static func expiryNote(queuedAt: Date, now: Date) -> String?` returns nil before day 12, then "Expires in 2 days" / "Expires tomorrow" / "Expires today".
- Wire format:
  - every call is a POST to `url` with body `{"mailbox", "action", …}`;
  - `add` sends `id` and `sealed`; `delete` sends `id`; `list` sends `ids`;
  - status mapping: 409 `{"taken":true}` → `.taken`, 429 → `.full`, 413 → `.tooLarge`, 503 → `.notConfigured`, any other non-2xx → `.badAnswer(code)`, a transport throw → `.unreachable`.

- [ ] **Step 1: Write the failing tests.**
  - `QueueRelayClientTests` uses a stub transport that records the `URLRequest` and returns canned answers:
    - `addSendsMailboxInBodyNotURL`: the URL has no query, and the body JSON has `mailbox`, `action == "add"`, `id` and `sealed`.
    - `takeDecodesItems`
    - `listReturnsTaken`
    - `conflictMapsToTaken` (409)
    - `tooLargeMaps` (413)
    - `fullMaps` (429)
    - `transportThrowMapsToUnreachable`
  - `QueueSyncTests`:
    - `waitingWhenListed`
    - `startedWhenTaken`
    - `expiredWhenNeither`
    - `editOfTakenIsStarted`: an id that's both in `taken` and missing from `items` is `.started`.
    - `noNoteBeforeDay12`
    - `noteOnDay12` → "Expires in 2 days"
    - `noteOnDay13` → "Expires tomorrow"
- [ ] **Step 2: Run, expect failure.** `cd BenchKit && swift test --filter "QueueRelayClientTests|QueueSyncTests"` fails.
- [ ] **Step 3: Implement** `QueueRelay` and `QueueSync` per the interfaces.
- [ ] **Step 4: Run, expect PASS.** Same command, then the full `swift test`.
- [ ] **Step 5: Commit.** `git commit -m "BenchKit: relay client and sync rules for queued prompts"`

### Task 3: Relay endpoint

**Files:**
- Create: `relay/api/_mailbox.js` (Redis helpers; the `_` prefix keeps Vercel from serving it)
- Create: `relay/api/queue.js` (the handler)
- Create: `relay/test/queue.test.js`
- Modify: `relay/package.json`: add `"scripts": {"test": "node --test test/"}`
- Modify: `relay/README.md`: add an `/api/queue` section (what it stores, limits, that nothing is logged, and that it uses the same Upstash variables).

**Interfaces:**
- Consumes: the wire format from Task 2.
- Produces: `export default async function handler(req, res)`.
  - `GET` → `{ok:true, configured}`. `configured` means the database variables exist; no secret is needed.
  - `POST` actions `add`, `list`, `delete`, `take`. Responses:
    - `add` → `{ok:true}`
    - `list` → `{items:[{id,sealed,addedAt}], taken:[ids]}`
    - `delete` → `{ok:true}`
    - `take` → `{items:[…]}`
  - Status codes: 400 bad input, 409 `{taken:true}`, 413 oversize, 429 full, 503 not configured.
  - `_mailbox.js` reads `KV_REST_API_*` / `UPSTASH_REDIS_REST_*` the way `_queue.js` does.
- Keys:
  - `queue:<mailbox>` is a hash: id → `{"sealed","addedAt"}` JSON.
  - `queue:<mailbox>:taken` is a set.
- `take` must be atomic. Use one `EVAL` Lua script that:
  1. reads `HGETALL`;
  2. `SADD`s every id into the taken set;
  3. `EXPIRE`s the taken set by 1209600;
  4. `DEL`s the hash;
  5. returns the pairs.
- `add`:
  - refuses ids in the taken set (409);
  - refuses a 26th entry unless the id already exists (429);
  - otherwise `HSET`s, then `EXPIRE`s the hash by 1209600.
  - A Lua script keeps these checks and the write together.

- [ ] **Step 1: Write the failing tests** in `relay/test/queue.test.js` with `node:test`. Stub `globalThis.fetch` with an in-memory fake of the Upstash `/pipeline` and EVAL endpoints. Set env vars in the test. Drive the handler with tiny `req`/`res` stand-ins.
  - `add then list returns it`
  - `take returns everything and empties the mailbox`
  - `second take returns nothing`
  - `addAfterTakeIsRefused` (409)
  - `list reports taken ids it was asked about, and only those`
  - `oversizeIsRefused` (413 at 32769 chars)
  - `26th add is refused, replacing an existing id is not`
  - `bad mailbox id is 400`
  - `GET reports configured false without database vars`
  - `mailbox never appears in the URL the handler fetches`
  - The fake honours EVAL by running a JS port of the script's logic. Keep the Lua and the fake's port next to each other in `_mailbox.js` exports so they're reviewed together.
- [ ] **Step 2: Run, expect failure.** `cd relay && npm test` fails (module not found).
- [ ] **Step 3: Implement** `_mailbox.js` and `queue.js`.
- [ ] **Step 4: Run, expect PASS.** `cd relay && npm test` reports every test passing.
- [ ] **Step 5: Commit.** `git commit -m "Relay: a mailbox for prompts queued while a Mac is asleep"`
- Deploying (`vercel deploy --prod`) happens at release time (Task 9), not here.

### Task 4: Mac picks up and starts queued prompts

**Files:**
- Create: `Bench/Companion/OfflineQueue.swift`
- Modify: `Bench/Companion/CompanionServer.swift:94`: add `CompanionFeature.offlineQueue` to `features`.
- Modify: `Bench/Companion/CompanionSnapshots.swift:27-40`: set `isGit: monitor.snapshot?.isRepository` (see `Bench/Git/Git.swift:24`) when building `CompanionProject`.
- Modify: `Bench/Companion/Companion.swift:101` (`regenerateToken`): before replacing the token, call `offlineQueue.drain(oldToken:)`.
- Modify: `Bench/App/BenchApp.swift:~165`: create `OfflineQueue`, wire `notifyPhone` the way `feedbackAgent.notifyPhone` is, and put it in the environment.
- Test: `BenchTests/OfflineQueueTests.swift`

**Interfaces:**
- Consumes: Task 1's `QueueSeal`/`QueuedPrompt`; Task 2's `QueueRelay`/`QueueItem`; `CompanionSnapshots.newAgent(parentID:prompt:branch:base:)`.
- Produces: `@MainActor @Observable final class OfflineQueue`:
  - `init(token: @escaping () -> String?, isEnabled: @escaping () -> Bool, relayURL: URL?, start: @escaping (QueuedPrompt) async throws -> (project: UUID, tab: UUID)?, folder: URL)`
    - `relayURL` is nil → never checks.
    - `folder` is where `pending.json` and `failed.json` live (`BenchPaths.support`; tests pass a temp folder).
  - `BenchApp` passes `QueueRelay.urlForBuild()` (Task 2) as `relayURL`.
  - `func check() async`
  - `func drain(oldToken: String) async`
  - `private(set) var failed: [FailedPrompt]`
    - `struct FailedPrompt: Codable, Identifiable, Hashable { prompt: QueuedPrompt; reason: String; id: UUID { prompt.id } }`
  - `func retry(_ id: UUID, in projectID: UUID) async`
  - `func discard(_ id: UUID)`
  - `var notifyPhone: ((_ title: String, _ body: String, _ projectID: UUID?, _ tabID: UUID?) -> Void)?`
  - `var onFailure: (([FailedPrompt]) -> Void)?`, which Task 5 uses for the Mac notification.
- Behavior of `check()`:
  1. Skip if `!isEnabled()` or no token or no URL.
  2. If `pending.json` has leftovers, start those first.
  3. `take()`. Open each item; one that can't be opened goes to failed with reason "Couldn't be unlocked. It may be from an older pairing code."
  4. Write all opened prompts to `pending.json` *before* starting any.
  5. Sort by `queuedAt`, then start each:
     - success: remove it from pending, then call `notifyPhone("Started from your queue", "<project name>: <first 80 chars>", project, tab)`;
     - `start` returns nil (project gone) or throws: move it to `failed.json` with a plain reason ("Bench isn't in Workbench anymore." / the error's description).
  6. A relay error: return quietly; nothing changes.
- Triggers:
  - `start()` on init (launch);
  - `NSWorkspace.shared.notificationCenter` `didWakeNotification`;
  - `NWPathMonitor` path to `.satisfied`;
  - `Timer` every 300 s.
  - All of them call `check()`, guarded so two checks never overlap.
- The `start` closure in `BenchApp` calls `snapshots.newAgent(parentID: prompt.projectID, prompt: prompt.prompt, branch: "", base: nil)`. Before that it rejects non-git projects with reason "Queued prompts need a git project." Non-git means the matching `CompanionProject.isGit == false`.
- Analytics: `Analytics.capture(.agentStarted, ["kind": "single", "count": 1, "from_queue": true])`. That means `CompanionSnapshots.newAgent` needs a `fromQueue: Bool = false` parameter, so the existing `from_phone` event isn't sent too.

- [ ] **Step 1: Write the failing tests** in `BenchTests/OfflineQueueTests.swift`. Use a stub `QueueRelay` transport serving a real sealed item for a fixed token, a fake `start` closure, and a temp folder.
  - `startsTakenPromptsOldestFirst`
  - `writesPendingBeforeStarting`: the fake `start` reads `pending.json` and sees the prompt.
  - `leftoverPendingIsStartedOnNextCheck`
  - `missingProjectGoesToFailed` (`start` returns nil)
  - `nonGitProjectGoesToFailed` (the start closure throws with the git reason)
  - `unopenableItemGoesToFailed` (sealed with another token)
  - `relayFailureKeepsNothingAndRetriesLater`: the transport throws, and both `failed` and `pending` stay empty.
  - `disabledCompanionNeverCallsRelay`
  - `nilURLNeverCallsRelay`
  - `drainTakesFromOldMailbox`: the request body carries `QueueSeal.mailboxID(token: old)`.
  - `retryMovesFailedIntoNewProject`
  - `discardRemovesFailed`
- [ ] **Step 2: Run, expect failure.** `make test` fails with "cannot find 'OfflineQueue'".
- [ ] **Step 3: Implement** `OfflineQueue.swift` and the wiring listed under Files.
- [ ] **Step 4: Run, expect PASS.** Run `make test`, which should report TEST SUCCEEDED, and then `make build`, which should report BUILD SUCCEEDED.
- [ ] **Step 5: Commit.** `git commit -m "Mac: start prompts queued from the phone when Workbench is back online"`

### Task 5: Mac "couldn't start" list

**Files:**
- Create: `Bench/Companion/QueuedPromptsSheet.swift`
- Modify: `Bench/App/BenchApp.swift`, to post the notification and present the sheet. Also modify the Overview's header in `Bench/Views/OverviewView.swift`: a small "N queued prompts couldn't start" button shows there only while `offlineQueue.failed` isn't empty.

**Interfaces:**
- Consumes: Task 4's `OfflineQueue.failed`, `retry(_:in:)`, `discard(_:)` and `onFailure`.
- Produces: `struct QueuedPromptsSheet: View`.
  - Each row shows the project name, the prompt in selectable text, the reason, and three controls:
    - **Copy**;
    - **Start in…**, a `Picker` over the store's git projects, which calls `retry`;
    - **Delete**, which calls `discard`.
  - When `onFailure` fires, a local `UNUserNotificationCenter` notification posts: title "A queued prompt couldn't start" (or "N queued prompts couldn't start"), body = the first reason. Clicking it opens the sheet.

- [ ] **Step 1: Build and look.** Run `make build` and launch `build/Build/Products/Debug/Workbench.app` with `BENCH_TEST_OFFLINE_QUEUE` pointed at a local stand-in that serves one prompt for a deleted project. Check that the notification and the sheet both appear and that Copy, Start in… and Delete each work. (The logic is tested in Task 4; this task is UI.)
- [ ] **Step 2: Commit.** `git commit -m "Mac: show queued prompts that couldn't start"`

### Task 6: Phone keeps the last project list

**Files:**
- Create: `BenchKit/Sources/BenchKit/UI/SnapshotCache.swift`
- Modify: `BenchKit/Sources/BenchKit/UI/CompanionClient.swift`:
  - add `public private(set) var savedAt: Date?` and `public var isShowingSaved: Bool`;
  - load from the cache in `connect(_:)` when `snapshot == nil`;
  - save on `.projects` and `.welcome`.
- Modify: `BenchPhone/ProjectsView.swift:100-130`. While `client.isShowingSaved`:
  - replace `ConnectionBanner` with an offline note ("Your Mac is asleep or offline. These are your projects from \(relative savedAt). You can queue prompts for when it wakes.");
  - leave out the session sections;
  - show a "N queued" badge on project rows (Task 7 supplies the counts).
- Test: `BenchKit/Tests/BenchKitTests/SnapshotCacheTests.swift`

**Interfaces:**
- Produces:
  - `public struct SavedMac: Codable, Sendable { snapshot: ProjectsSnapshot; features: Set<String>; macName: String?; savedAt: Date }`
  - `public struct SnapshotCache`:
    - `init(folder: URL)`
    - `func save(_ saved: SavedMac, host: String)`
    - `func load(host: String) -> SavedMac?`
    - `func remove(host: String)`
    - The file name per host is `NotificationSeal.opaque(host) + ".json"`, so the host isn't spelled out on disk. It lives in Application Support/`SavedMacs`.
  - The saved snapshot has every project's `sessions` emptied, since sessions go stale.
  - `CompanionClient.savedFeatures: Set<String>` comes from the cache when offline, and `macFeatures` when connected. Task 7 reads it to decide whether the queue box shows.
  - `forgetMac()` (CompanionClient.swift:198) must not wipe the cache. Unpairing a Mac (`PairingStore`'s remove) calls `SnapshotCache.remove(host:)`.

- [ ] **Step 1: Write the failing tests:**
  - `savesAndLoadsPerHost`
  - `differentHostsDontMix`
  - `sessionsAreDropped`
  - `fileNameDoesNotContainHost`
  - `removeDeletes`
  - `missingFileLoadsNil`
- [ ] **Step 2: Run, expect failure.** `cd BenchKit && swift test --filter SnapshotCacheTests`
- [ ] **Step 3: Implement** the cache, the client hooks and the ProjectsView changes.
- [ ] **Step 4: Run, expect PASS.** Run `swift test` in BenchKit and `make phone` (BUILD SUCCEEDED). In the simulator: pair with a debug Mac build, quit the Mac app, relaunch the phone app, and check that the projects show with the offline note.
- [ ] **Step 5: Commit.** `git commit -m "Phone: keep the Mac's project list for when it's offline"`

### Task 7: Phone queues prompts

**Files:**
- Create: `BenchPhone/QueueStore.swift`, for the local copies and the relay sync.
- Create: `BenchPhone/OfflineProjectView.swift`, mockup screen 3.
- Modify: `BenchPhone/SessionView.swift:15-40`: when `client.isShowingSaved`, show `OfflineProjectView(projectID:)` instead of the live views.
- Modify: `BenchPhone/StartViews.swift:13` (`ProjectMenu`): hide live-only items while offline.
- Modify: `BenchPhone/BenchPhoneApp.swift`: create `QueueStore` and put it in the environment. Refresh on `scenePhase == .active`.
- Modify: `BenchPhone/PairingStore.swift` `pair(_:)`: when a known host gets a new token, keep the old mailbox id around for `QueueStore`'s re-pair check (spec: "After a new pairing code").
- Test: `BenchTests` doesn't cover the phone, so add `BenchKit/Tests/BenchKitTests/QueueStoreTests.swift`. Put `QueueStore`'s logic in `BenchKit/Sources/BenchKit/UI/QueueStoreCore.swift` (UI-free, testable). `BenchPhone/QueueStore.swift` is then a thin `@Observable` wrapper.

**Interfaces:**
- Consumes: Tasks 1, 2 and 6 (`client.savedFeatures`, `client.isShowingSaved`).
- Produces: `public struct LocalQueued: Codable, Hashable, Identifiable { prompt: QueuedPrompt; mailbox: String; status: Status; id: UUID { prompt.id } }`, where `enum Status: String, Codable { case unsent, waiting, expired }`.
- Produces: `public actor QueueStoreCore`:
  - `init(folder: URL, relay: @escaping @Sendable (String) -> QueueRelay)`
    - the app builds each relay with `QueueRelay.urlForBuild()`; with nil, the queue box says queuing isn't available in this build.
    - `relay` builds a client for a mailbox; tests pass a stub transport.
  - `func queue(_ prompt: QueuedPrompt, token: String) async -> QueueRelayError?`
    - saves locally as `.unsent` first, then adds; becomes `.waiting` on success.
  - `func edit(_ id: UUID, text: String, token: String) async -> QueueRelayError?`
    - returns `.taken` when the Mac already took it, and drops the local copy.
  - `func delete(_ id: UUID, token: String) async`
  - `func refresh(token: String) async`
    1. retries `.unsent` items with the same id;
    2. lists per distinct mailbox;
    3. applies `QueueSync.state`: started → dropped, expired → `.expired`;
    4. a copy on an old mailbox that's neither waiting nor taken there is re-queued under the current mailbox.
  - `func items(projectID: UUID?) -> [LocalQueued]` (nil means all)
- Stored per Mac host in Application Support/`Queued/<opaque(host)>.json`.
- `OfflineProjectView` copy (exact):
  - note: "Your Mac is asleep. Prompts you queue start as new agents when it's back online."
  - placeholder: "What should the agent do?"
  - button: "Queue"
  - helper: "Starts on a new branch, named from the prompt."
  - section: "Queued"
  - row status: "Waiting for your Mac" / "Not sent yet" / "Expired: your Mac wasn't online for 14 days" (with **Queue Again**, **Delete**), plus `QueueSync.expiryNote`.
  - Not git: "Queued prompts need a git project."
  - Older Mac (no `offlineQueue` in `savedFeatures`): "Update Workbench on your Mac to queue prompts while it's asleep."
  - `.tooLarge`: "That's too long to queue. Try a shorter prompt."
  - `.full`: "Your Mac already has 25 prompts waiting."
  - `.taken` on edit: "Your Mac already started this one."
- Tapping a row edits it in place. Swiping deletes it.

- [ ] **Step 1: Write the failing tests** in `QueueStoreTests.swift` with a stub transport.
  - `queueSavesThenSends`
  - `failedAddStaysUnsentAndRetriesWithSameID`: the first add throws; `refresh` sends the same `id`.
  - `refreshDropsStarted`
  - `refreshMarksExpired`
  - `editOfTakenReturnsTakenAndDrops`
  - `oldMailboxCopyIsRequeuedUnderNew`
  - `oldMailboxCopyTakenThereIsDropped`
  - `itemsFilterByProject`
- [ ] **Step 2: Run, expect failure.** `cd BenchKit && swift test --filter QueueStoreTests`
- [ ] **Step 3: Implement** `QueueStoreCore`, the wrapper, the view and the wiring.
- [ ] **Step 4: Run, expect PASS.** Run `swift test` and `make phone`. In the simulator against a local stand-in relay, with the Mac app quit:
  - queue a prompt, edit it, delete it;
  - turn the network off, queue one, and check it shows "Not sent yet";
  - turn the network on, foreground the app, and check it goes out.
- [ ] **Step 5: Commit.** `git commit -m "Phone: queue prompts for a Mac that's asleep"`

### Task 8: Privacy policy

**Files:**
- Modify: `website/privacy.html`, lines 44, 60, and 65-70 (the summary, the services list and the iPhone section).

- [ ] **Step 1: Edit**, using the spec's "Privacy policy" section for the content.
  - Summary (line 44): replace "Your code, prompts, and conversations go from your Mac to your own devices and never to us." with "Your code, prompts, and conversations go from your Mac to your own devices. The one exception is a prompt you queue while your Mac is offline: it waits on Workbench's server, encrypted so only your devices can read it."
  - Services list: add "**Workbench's queue service,** when you queue a prompt for a Mac that's offline."
  - iPhone section: add the queued-prompts bullet. It covers four things:
    - stored encrypted until picked up or 14 days pass;
    - the server keeps only scrambled text, a random mailbox number, when it was added, and for 14 days the random ids of prompts already picked up;
    - not readable by Workbench, Vercel or Upstash;
    - a new pairing code makes old ones unreadable.
  - Also add a bullet for the saved project list: kept on your phone only.
  - Add the network-details sentence: Workbench doesn't log requests, but its host's standard logs can briefly record the IP address and time of each request.
  - Update the "last updated" date if the page has one.
- [ ] **Step 2: Check.** Open `website/privacy.html` in a browser. It reads cleanly and its HTML is valid (no unclosed tags).
- [ ] **Step 3: Commit.** `git commit -m "Privacy policy: prompts queued for an offline Mac"`
- Publishing (`scripts/publish-website.sh`) waits for Matt at release time.

### Task 9: End-to-end check and release notes

- [ ] **Step 1: Deploy a preview relay.** `cd relay && vercel deploy`, a preview deploy, not `--prod`. Check that `GET <preview>/api/queue` answers `{"ok":true,"configured":true}`.
- [ ] **Step 2: Run the full flow.** Run both a debug Mac build (from `build/…/Debug`, never `/Applications`) and the phone simulator, with `BENCH_TEST_OFFLINE_QUEUE=<preview>/api/queue`.
  1. Pair the devices.
  2. Quit Workbench.
  3. Queue two prompts on two projects.
  4. Relaunch Workbench.
  5. Check that two agents start on new branches, the phone gets "Started from your queue", and the phone's Queued list empties.
- [ ] **Step 3: Test a pairing change.** Queue one prompt, quit Workbench, relaunch it, and regenerate the pairing code before the first check fires. To make that possible, temporarily set the timer to a long delay with a local edit, and don't commit it. Check the prompt still starts through `drain`.
- [ ] **Step 4: Write release notes.** Add a line to `fastlane/whattotest.txt` describing the feature for TestFlight.
- [ ] **Step 5: Commit.** `git commit -m "TestFlight notes: queued prompts"`
- Release order, for Matt:
  1. `vercel deploy --prod` the relay and publish the website;
  2. ship the Mac release;
  3. ship the iOS release.
