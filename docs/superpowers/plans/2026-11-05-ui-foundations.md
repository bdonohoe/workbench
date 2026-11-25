# UI Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pass 1 (foundations and correctness) and pass 3 (merge the duplicates) of the Workbench UI review, on the `feat/ui-foundations` branch, with the app's appearance otherwise unchanged.

**Architecture:** `Theme.swift` grows a small set of tokens (radius, type, fill, motion, status colors, bar heights) that the rest of the app adopts gradually. Hand-made copies of the same component (local and remote sidebar rows, local and remote tab bars, Mac and iPhone chat turns, six small widgets) become one implementation each. The diff view moves from one SwiftUI `Text` per line onto the file view's `NSTextView`, so text can be selected across lines.

**Tech Stack:** SwiftUI and AppKit on macOS 26, Swift 6 with main-actor default isolation, BenchKit (shared with the iPhone app, tested with `swift test`), xcodegen.

**Spec:** The UI review, published at https://claude.ai/artifact/7BhMkgVo7YdpayDDtbwX99. Pass 1 and pass 3 of its "Plan" section, with the detail in sections 02, 03, 06, 08 and the "Every finding" list. The sidebar's visual changes (section 04) are **out of scope**: the sidebar row merge in this plan changes code structure only.

## Global Constraints

- The app must look the same before and after every task here except where a task says otherwise. "Otherwise" is limited to: the four color fixes in Task 4, the prominent button in three places, and the diff view's gutter.
- Build with `make build` from the worktree root; it must end with `** BUILD SUCCEEDED **` and no new warnings in `Bench/`. BenchKit tests run with `cd BenchKit && swift test` and must stay at 130 passing or more.
- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. Mark shared value types `nonisolated` or `Sendable` as the existing code does.
- Never use `.borderedProminent` or `Color.accentColor` in the Mac app. The app's accent is `Theme.accent`.
- No new third-party dependencies.
- Copy stays in the app's plain voice; new UI strings use sentence case.
- The vendored toolchain is symlinked: a fresh worktree needs `mkdir -p vendor && ln -s /Users/matt/Apps/Bench/vendor/{ghostty,ghostty-deps,ghostty-resources,GhosttyKit.xcframework,zig} vendor/` before `make build`.
- Commit after each task with a one-line subject in the repo's style (no prefix, present tense, says what the user gets) and the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A window dragged from 1440 wide down to 900 with the inspector open: no crash, no layout loop, the tab bar's buttons still reachable (Task 2 pins this with a debug resize hook).
2. A terminal theme with a light background and the app in dark system appearance (and the reverse): every `Theme.Status` color stays readable on the panel it's drawn on (Task 3's token test covers the contrast of each ink on white and on near-black).
3. A diff with a 2,000-line file and multi-byte characters: the TextKit diff keeps line numbers aligned with text, and selecting from the middle of one line into the next copies both lines' text without the gutter numbers (Task 10).
4. A remote project row and a local project row showing the same state side by side: identical padding, fonts and indicators (Task 6 renders both through `RemoteRowsPreview` and `StepsBarPreview` and compares PNGs).
5. VoiceOver on Settings: every switch and picker is read with its row title (Task 5 asserts the `accessibilityLabel` through a `SettingsRow` test in BenchKit-free code, so it checks by inspection: see the task).

---

### Task 1: Debug hook for resizing the window

**Files:**
- Modify: `Bench/Views/ContentView.swift` (the `#if DEBUG` block, lines 15–55)

**Interfaces:**
- Produces: environment variables `BENCH_RESIZE=<width>x<height>` (applied 2s after launch, in 20pt steps every 50ms from the current frame, like a drag) and `BENCH_HIDE_PANEL=1` (sets `store.showsChanges = false` first). Used by Task 2 to reproduce and verify.

- [ ] **Step 1: Add the hook** as a third `.task` in the DEBUG block. Read `BENCH_RESIZE`, sleep 2s, find the main window (`NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }`), then loop `setFrame` toward the target width and height in 20pt steps with `Task.sleep(for: .milliseconds(50))`.
- [ ] **Step 2: Verify** with `make build`, then run `BENCH_RESIZE=1100x720 BENCH_QUIT_AFTER=12 build/Build/Products/Debug/Workbench.app/Contents/MacOS/Workbench` against a copy of the support folder (`BENCH_SUPPORT_DIR`) and confirm the crash from the review reproduces (`NSGenericException` in the log).
- [ ] **Step 3: Commit** `Add a debug hook that resizes the window like a drag`

### Task 2: Fix the narrow-window crash

**Files:**
- Modify: whichever view is found responsible. First suspects, in order: `Bench/Views/WindowTitleArea.swift:38-52` (`TitleAreaScrollView` feeds its own measured width back into its content's `minWidth`, a feedback loop when the scroll view is squeezed), `Bench/Views/ProjectDetailView.swift:416-541` (`TabBar`), `Bench/Views/ArtifactsPanel.swift:12-31` (`InspectorModePicker`), `Bench/Terminal/TerminalSurfaceView.swift` (the libghostty view's size reporting).

- [ ] **Step 1: Bisect.** With the Task 1 hook, comment out candidates one at a time (replace `TitleAreaScrollView` with a plain `ScrollView(.horizontal)`; remove the trailing buttons from `TabBar`; show the inspector with `Color.clear`) and rebuild until the crash stops. Record which one.
- [ ] **Step 2: Fix the cause.** If it's `TitleAreaScrollView`: measure the width with `.onGeometryChange` on the scroll view's *container* only once per size and apply it as `.frame(minWidth:)` through `containerRelativeFrame`, or stop at `max(width, 0)` and only update when the difference exceeds 1pt, so measurement can't oscillate. Whatever the cause, the fix must keep the title-bar drag behavior that the scroll view exists for.
- [ ] **Step 3: Verify** `BENCH_RESIZE=900x600`, `1100x720` and `1150x800`, each with and without `BENCH_HIDE_PANEL=1`: the app survives 12s and the log has no `NSGenericException` and no "exceeds internal limits" warning.
- [ ] **Step 4: Commit** `Stop the window crashing when it's resized narrow with the panel open`

### Task 3: Design tokens in Theme.swift

**Files:**
- Modify: `Bench/Views/Theme.swift`
- Modify: `Bench/Views/ActivityBackground.swift:59-64` (the static colors become aliases)
- Test: `BenchKit/Tests/BenchKitTests/StatusColorTests.swift` (new) with the color *values* in BenchKit so they can be tested; the Mac's `Theme.Status` wraps them.
- Create: `BenchKit/Sources/BenchKit/UI/StatusColors.swift`

**Interfaces:**
- Produces, in BenchKit: `public enum StatusColors { public static let waiting, working, done, failed, modified, remote: (light: Color, dark: Color) }` plus `public static func contrast(_ a: Color, on b: Color) -> Double` (WCAG relative luminance ratio, sRGB).
  Values: waiting `#9A6400`/`#F2B54A`, working `#B9542F`/`#F08A64`, done `#1A7F37`/`#4CC774`, failed `#CF222E`/`#FF7B6E`, modified `#A06A00`/`#E5B740`, remote `#2F6FB5`/`#7DB4F0`.
- Produces, in the Mac app `Theme`:
  - `enum Radius { static let chip: CGFloat = 4, control = 6, row = 9, card = 10, dock = 14 }`
  - `enum Font { static func micro/meta/bodySmall/ui/title/page(weight:) -> SwiftUI.Font }` at 10, 11, 12, 13, 15, 22.
  - `enum Fill { static let hover = Color.primary.opacity(0.05), pressed = 0.09, selected = 0.10, subtle = 0.045, hairline = 0.08 }`
  - `enum Motion { static let hover = Animation.easeOut(duration: 0.12), state = .snappy(duration: 0.2), layout = .smooth(duration: 0.3) }`
  - `enum Status { static let waiting, working, done, failed, modified, remote, attention: Color }` each built with `Color(light:dark:)` from `StatusColors`; `attention` stays `.blue`. Plus `static func fill(_ color: Color) -> Color` returning `color.opacity(0.12)`.
  - `enum Layout { static let barHeight: CGFloat = 38, paneHeader = 34, listRow = 22 }`
  - `ActivityBackground.working/waiting/done/remote/attention` become `Theme.Status.*`. **Note:** this changes the sidebar's tint hue slightly. To honor "no sidebar changes", keep the old literal values for `ActivityBackground.working` and `.waiting` and `.done` and `.remote` as the *fill* colors, and add `Theme.Status` as the *ink* colors used by text. Only text and badges move to the new values.

- [ ] **Step 1: Write the failing test** `StatusColorTests`: for each of the six pairs, `contrast(light, on: .white) >= 4.5` and `contrast(dark, on: Color(white: 0.11)) >= 4.5`. Also `contrast(.black, on: .white) == 21 ± 0.01`.
- [ ] **Step 2: Run** `cd BenchKit && swift test --filter StatusColorTests` → fails (no such symbols).
- [ ] **Step 3: Implement** `StatusColors.swift`. Luminance from sRGB components via `NSColor`/`UIColor` with `#if canImport(AppKit)`. Then the `Theme` additions.
- [ ] **Step 4: Run tests** → pass. `make build` → succeeds.
- [ ] **Step 5: Commit** `Add design tokens for radius, type, fills, motion and status colors`

### Task 4: Status colors and prominent buttons

**Files:**
- Modify: `Bench/Views/FeedbackView.swift:97`, `Bench/Views/ProjectDetailView.swift:343` → `.buttonStyle(.prominent)`
- Modify: `BenchKit/Sources/BenchKit/UI/QuestionCard.swift:52-53`: replace `.borderedProminent` + `.tint(palette.done)` with a BenchKit `CompanionProminentButtonStyle` (fill `palette.ink`, label `palette.canvas`-contrasting: use `palette.surface`... simplest: fill `palette.accent`, white text on iPhone where accent is orange; on the Mac the palette's accent is `Theme.accent` with `onAccent`). Add `public var onAccent: Color` to `CompanionPalette` (default `.white`), the Mac palette sets it to `Theme.onAccent`.
- Modify: `Bench/Views/ChangesPanel.swift:457-465` and `Bench/Views/FilesPanel.swift:259-267`: delete both `color` switches; add `extension ChangeKind { var color: Color }` in `Bench/Views/Theme.swift` using `Theme.Status` (added/untracked → done, deleted → failed, conflicted → waiting, renamed/copied → remote, default → modified).
- Modify: `Bench/Views/OverviewView.swift:129-131, 268-274, 490`: the fixed RGB inks become `Theme.Status.waiting/.working/.done/.remote`.
- Modify: `Bench/Views/Onboarding/OnboardingView.swift:124-128, 312-316`: the CTA fill becomes `Color(red: 0.76, green: 0.38, blue: 0.26)` (white text at 4.5:1). Keep the glow's orange.
- Modify: `Bench/Views/DiffView.swift:56-57` `+`/`−` counts → `Theme.Status.done/.failed`.

- [ ] **Step 1: Make the changes.** `grep -rn "borderedProminent\|accentColor" Bench BenchKit/Sources` must return nothing afterward except the comment in Theme.swift.
- [ ] **Step 2: Verify** `make build`, `swift test`, and `make phone` (the iPhone target must still compile, since QuestionCard and CompanionPalette are shared).
- [ ] **Step 3: Commit** `Use one status palette that reads in light and dark, and the graphite button everywhere`

### Task 5: Settings controls named for VoiceOver

**Files:**
- Modify: `Bench/Views/SettingsPage.swift:200-231` (`SettingsRow`), `:252, :375, :434, :468`; `Bench/Views/ClaudeAccountsSettings.swift:178, :229`; `Bench/Views/Theme.swift:47-82` (`BenchSwitchStyle`).

- [ ] **Step 1:** `SettingsRow`'s switch initializer passes `Toggle(title, isOn:)`. Every `Picker("", …)` listed gets its row's title string. The whole `SettingsRow` gets `.accessibilityElement(children: .contain)`, and the accessory gets `.accessibilityHint(detail ?? "")` when a detail exists.
- [ ] **Step 2:** `BenchSwitchStyle`: add `.focusable()` on the button and `.focusEffectDisabled(false)`; verify with Full Keyboard Access that Tab reaches a switch and Space toggles it.
- [ ] **Step 3:** Account `…` menu: `.accessibilityLabel("Account actions")`.
- [ ] **Step 4: Verify** with the Accessibility Inspector (`open -a "Accessibility Inspector"`) on Settings > General: each switch reads its title. `make build`.
- [ ] **Step 5: Commit** `Name every Settings switch and picker for VoiceOver`

### Task 6: One sidebar row for local and remote projects

**Files:**
- Create: `Bench/Views/SidebarRow.swift`
- Modify: `Bench/Views/SidebarView.swift:663-861` (`ProjectRow`), `:1190-1305` (`ProjectDetailsCard`), `:1155-1174` (`PullRequestDisplay`), `:1473-1512` (`WaitingDetail`)
- Modify: `Bench/Remote/RemoteSidebar.swift:434-704` (`RemoteProjectRow`), `:706-733`, `:779-817` (`RemoteWaitingDetail`), `:819-924` (`RemoteProjectDetailsCard`)

**Interfaces:**
- Produces: `struct SidebarRowModel` (plain data: `name`, `subtitle`, `isWorktree`, `icon: ProjectIconSource`, `activity: TabActivity`, `timer: ActiveTimerModel?`, `trail: [ActionTrailItem]`, `checklist: [ChecklistItem]?`, `status: RowStatus?`, `waiting: WaitingPrompt?`, `finished: FinishedSummary?`, `macName: String?`, `notifiesPhone: Bool`, `shortcut: Int?`), built by `ProjectRow` (local) and `RemoteProjectRow` (remote) from their own sources.
- Produces: `struct SidebarRowBody: View { let model: SidebarRowModel; let isSelected, isHovering, compact: Bool; let actions: SidebarRowActions }` that draws everything inside the row, and `struct SidebarRowChrome: ViewModifier` for the background (activity tint, hover fill, selection card and ring) that both rows apply.
- `SidebarRowActions` holds closures: `allow`, `deny`, `select`, `rename`.
- The remote row takes a `compact: Bool` like the local one and honors it.

- [ ] **Step 1: Capture before images.** `BENCH_RENDER_REMOTE=<folder> BENCH_RENDER_REMOTE_SNAPSHOT=<file>` and `BENCH_RENDER_STEPS=<folder>` (see `BenchApp.swift:53-62`) write PNGs; keep them as the baseline. If no snapshot file exists, create one with the shape `RemoteRowsPreview` expects (read `RemoteSidebar.swift:951`).
- [ ] **Step 2: Extract** `SidebarRowBody` and `SidebarRowChrome` from `ProjectRow` without changing any value. Point `ProjectRow` at them. Build, re-render, `cmp` the PNGs with the baseline (identical bytes expected; if the renderer isn't deterministic, compare visually and note it).
- [ ] **Step 3: Port** `RemoteProjectRow` onto the same body and chrome, deleting `RemoteWaitingDetail`, `RemoteProjectDetailsCard` and the duplicate PR helpers. The remote row's known drifts (no compact support, no selection animation, PR line without icon or red for failing checks, 9pt regular branch glyph) now follow the local row.
- [ ] **Step 4: Verify** `make build`, re-render remote rows: the only differences from the baseline are the four drifts above.
- [ ] **Step 5: Commit** `Draw local and remote project rows with one implementation`

### Task 7: One tab bar for local and remote projects

**Files:**
- Create: `Bench/Views/TabChips.swift`
- Modify: `Bench/Views/ProjectDetailView.swift:543-614` (`TabButton`), `:704-733` (`NewTabButton`)
- Modify: `Bench/Remote/RemoteProjectView.swift:241-313` (`RemoteTabButton`), `:365-394` (`RemoteBarButton`)

**Interfaces:**
- Produces: `struct TabChip<Badges: View>: View` with `init(symbol: String, tint: Color, title: String, isSelected: Bool, showsClose: Bool, canClose: Bool = true, help: String? = nil, select: @escaping () -> Void, close: @escaping () -> Void, @ViewBuilder badges: () -> Badges)`. The local tab passes its account badge, ports badge and activity indicator as `badges`; the remote tab passes its activity indicator.
- Produces: `struct BarButton: View` with `init(symbol: String, title: String, tint: Color, monospaced: Bool = false, action: @escaping () -> Void)`, replacing both `NewTabButton` and `RemoteBarButton` byte for byte.
- `TabKind.symbol` and `RemoteTab`'s symbol/tint/title helpers stay where they are; only the drawing moves.

- [ ] **Step 1: Extract** `TabChip` and `BarButton` from the local versions, values unchanged. Build.
- [ ] **Step 2: Port** the remote tab bar. Remote pins its bar height at 26 (`RemoteProjectView.swift:139`); keep that behavior on the remote side only.
- [ ] **Step 3: Verify** `make build`; open a local and a remote project (or the `RemoteRowsPreview` path if no Mac is paired) and compare the tab bars by eye.
- [ ] **Step 4: Commit** `Draw local and remote tab bars with one implementation`

### Task 8: One chat turn view for Mac and iPhone

**Files:**
- Modify: `BenchKit/Sources/BenchKit/UI/TranscriptTurns.swift:89-187` (`TranscriptTurnView`)
- Create: `BenchKit/Sources/BenchKit/UI/ChatTurnStyle.swift`
- Modify: `Bench/Views/ChatTurns.swift` (delete `ChatTurnView`; keep `ChatStyle`, `ChatLayout`, `ClaudeMark`, `copyOnHover`), `Bench/Views/ChatSessionView.swift:259, :269`
- Modify: `BenchPhone/SessionView.swift:315, :1059` (no change expected; confirm)

**Interfaces:**
- Produces: `public struct ChatTurnStyle: Sendable` with `bodyFont: Font`, `smallFont: Font`, `lineSpacing: CGFloat`, `indent: CGFloat`, `userBubble: UserBubbleStyle` (`.tail(radius: 16, tailRadius: 5, fill: .raised)` for Mac, `.gradient(radius: 20)` for iPhone), `userInset: CGFloat` (120 / 48), `mark: MarkStyle` (`.custom(size: 14)` for Mac, `.text(size: 13, width: 16)` for iPhone), `systemRow: SystemRowStyle` (Mac: surface, radius 10, no stroke; iPhone: raised, radius 14, hairline), `copyAffordance: Bool`. Environment key `\.chatTurnStyle`, default = the iPhone values.
- The Mac sets `.environment(\.chatTurnStyle, ChatTurnStyle.mac(scale:))` where it builds the transcript, rebuilt when `ChatTypography.shared.scale` changes. The Mac's `copyOnHover` is applied by the shared view when `copyAffordance` is true, through a `public` hook `ChatTurnStyle.copyDecorator: (@Sendable (AnyView, String, CopySide) -> AnyView)?`, since `CopyOnHover` uses AppKit's pasteboard. Simpler alternative allowed: move `CopyOnHover` into BenchKit under `#if os(macOS)`.

- [ ] **Step 1:** Write `ChatTurnStyle` and the environment key with the two presets. Test in BenchKit: `ChatTurnStyleTests` asserts `.phone.userInset == 48`, `.mac(scale: 1).userInset == 120`, `.mac(scale: 1.4).bodyFont` differs from `.mac(scale: 1).bodyFont` (compare via `ChatTurnStyle.bodySize`).
- [ ] **Step 2:** Make `TranscriptTurnView` draw from the style. Every Mac-only detail in `ChatTurnView` (the tailed bubble, `ClaudeMark`, `ChatStyle` fonts, `.textSelection`, `copyOnHover`, system-row card) has a style field; every iPhone detail keeps its current value under `.phone`.
- [ ] **Step 3:** Delete `ChatTurnView`; `ChatSessionView` uses `TranscriptTurnView` with the Mac style in the environment.
- [ ] **Step 4: Verify** `make build`, `make phone`, `swift test`. Mac: open a chat and compare against the review's screenshot `theme-wide--chat1-pitwall`. iPhone: `make phone` compiles; a simulator check is optional.
- [ ] **Step 5: Commit** `Draw chat turns on the Mac and iPhone with one view`

### Task 9: Shared small components

**Files:**
- Create: `Bench/Views/Components/DisclosureHeader.swift`, `Chip.swift`, `PaneHeader.swift`, `InspectorRow.swift`, `SheetHeader.swift`, `InfoBanner.swift`
- Modify (DisclosureHeader): `Bench/Views/ChangesPanel.swift:358-387` (`SectionHeader`), `Bench/Views/ChecklistSection.swift:12-31, 53-73`
- Modify (Chip): `Bench/Views/ClaudeAccountsSettings.swift:205-217` (`Tag`), `Bench/Views/Onboarding/OnboardingView.swift:542-547`, `Bench/App/WhatsNew.swift:271-276`, `Bench/Views/ChangesPanel.swift:326-339` (`Chip`, keep its stroke as an option)
- Modify (PaneHeader): `Bench/Views/DiffView.swift:40-69`, `Bench/Views/FileView.swift:68-106` (`FileHeader`), `Bench/Views/PreviewView.swift:48-87` (toolbar stays, but its height becomes `Theme.Layout.paneHeader`)
- Modify (InspectorRow): `Bench/Views/ChangesPanel.swift:395-422` (`FileRow`), `Bench/Views/FilesPanel.swift:239-256`, `Bench/Views/ArtifactsPanel.swift:99-138`
- Modify (SheetHeader): `NewAgentSheet.swift:27-34`, `SendTasksSheet.swift:42-49`, `FeedbackView.swift:36-43`, `ClaudeSignInSheet.swift:21-27`, `ShortcutEditor.swift:46-47`, `ClaudeAccountsSettings.swift:611-618`
- Modify (InfoBanner): `ClaudeAccountsSettings.swift:106-124` (`FoundNote`), `:339-382` (`AccountsFoundBanner`)

**Interfaces:**
- `DisclosureHeader(title: String, count: Int? = nil, countText: String? = nil, isCollapsed: Bool, toggle: () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() })`: `chevron.right` 9pt bold rotating 90° with `Theme.Motion.state`, 11pt semibold title, count in secondary with `monospacedDigit`, `.accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")`. Padding is a parameter (`insets: EdgeInsets`) since the Changes header is full-width and the Checklist header is inset.
- `Chip(_ text: String, tint: Color = .secondary, stroked: Bool = false)`: 10pt semibold, 6×2 padding, capsule, `tint.opacity(0.14)`.
- `PaneHeader<Trailing: View>(title: String, subtitle: String?, badge: String? = nil, @ViewBuilder trailing: () -> Trailing)`: height `Theme.Layout.paneHeader`, 12pt horizontal padding, 13pt semibold title, 12pt secondary subtitle truncated at the head.
- `InspectorRow` as a `ViewModifier` `.inspectorRow(isSelected: Bool, isHovering: Bool)`: 6pt horizontal inset, `Theme.Radius.control`, min height `Theme.Layout.listRow`, hover `Theme.Fill.hover`, selected `Theme.accent.opacity(0.14)`. **Visual change allowed here** (the spec asks for it): Changes and Files rows become inset and rounded; Artifacts rows keep their height.
- `SheetHeader(title: String, detail: String?)`: 15pt semibold, 12pt secondary, 4pt spacing.
- `InfoBanner(symbol: String, text: String, action: (label: String, run: () -> Void)? = nil, dismiss: (() -> Void)? = nil)`: radius 10, padding 10×12, 14pt icon in `Theme.accent`, fill `Theme.accent.opacity(0.08)`.

- [ ] **Step 1:** One component at a time: create it, replace its copies, `make build`, check the screen it's on. Order: SheetHeader, Chip, InfoBanner, DisclosureHeader, PaneHeader, InspectorRow.
- [ ] **Step 2: Verify** `make build`; `BENCH_RENDER_CHANGES=<folder>` before and after for the Changes panel (expected differences: inset rows only).
- [ ] **Step 3: Commit** once per component, e.g. `Share one sheet header across the sheets`.

### Task 10: Diff on TextKit

**Files:**
- Modify: `Bench/Views/DiffView.swift` (the body from line 120 on; `DiffLineRow` goes)
- Modify: `Bench/Views/FileView.swift:150-330` (`CodeTextContainer`, `LineNumberGutter`) to take a `GutterSource` instead of counting lines itself
- Create: `Bench/Views/DiffTextView.swift`
- Test: `BenchKit/Tests/BenchKitTests/DiffLayoutTests.swift`

**Interfaces:**
- Produces in BenchKit: `public struct DiffLayout` with `public init(lines: [DiffLine])`, `public let text: String` (the diff body with hunk and meta lines included, one line per `DiffLine`, no markers), `public func line(at utf16Offset: Int) -> Int?`, `public let ranges: [NSRange]` (one per line, in `text`), and `public let kinds: [DiffLine.Kind]`.
- Produces in the Mac app: `DiffTextView: NSViewRepresentable` with `init(layout: DiffLayout, segments: [[DiffSegment]], wraps: Bool, comments: [Int: [DiffComment]], composing: Int?, onComment: (Int) -> Void, …)`. It reuses `CodeTextContainer` with a `DiffGutter` that draws two number columns, a 1px `separatorColor` line after the new-number column, and a stronger gutter tint (`added` 0.22, `removed` 0.22 over the line's 0.12).
- Colors: `added`/`removed` come from `TerminalTheme.shared.ansiColor(2)` / `ansiColor(1)` when the theme is on, otherwise `Theme.Status.done`/`.failed`. Word-level highlight is the same color at 0.30 (light) / 0.35 (dark), as a `backgroundColor` attribute. Hunk bands: `primary.opacity(0.04)` with secondary text, no blue.
- Wrap: bound to the same `@AppStorage("fileViewWraps")` the file view uses; the toggle appears in the diff's `PaneHeader` (Task 9).
- Comments: a comment card is an `NSTextAttachment`-free approach is fine: draw comment cards and the editor as SwiftUI overlays positioned from `layoutManager.lineFragmentRect` for the line, updated on scroll. If this is too fragile, keep comments in a side list under the text (the orphans list already works this way) and note it in the commit.

- [ ] **Step 1: Write the failing test** `DiffLayoutTests`: three lines (`context "a"`, `added "b"`, `removed "c"`) → `text == "a\nb\nc"`, `ranges == [0..<1, 2..<3, 4..<5]`, `line(at: 2) == 1`, and a line with `"é"` keeps `ranges` in UTF-16 units.
- [ ] **Step 2: Run** → fails. **Implement** `DiffLayout`. Run → passes.
- [ ] **Step 3:** Build `DiffTextView` and swap it into `DiffView.content` for text diffs. Line attributes: per-line `backgroundColor` for added/removed, `foregroundColor` for hunk and meta, the monospaced 12pt font from the file view.
- [ ] **Step 4: Verify** `make build`; open a diff: drag-select across three lines and ⌘C → the pasteboard holds the three lines of text only. ⌘F finds text. Toggle wrap in a diff, open a file: the file view shows the same setting.
- [ ] **Step 5: Commit** `Show diffs in a text view, so you can select and search across lines`

### Task 11: Whole-branch verification

- [ ] `make build`, `make phone`, `cd BenchKit && swift test` all clean.
- [ ] Screenshot comparison: run the review's capture set on `main` and on the branch (the `BENCH_SNAPSHOT` hook at `ContentView.swift:30-55` with `BENCH_SUPPORT_DIR` pointing at a copy of `~/Library/Application Support/Bench`) for a project with the inspector on Changes, the chat, Settings > General, and the New Agent sheet. Every difference must be one the tasks above allow.
- [ ] Code review of `git diff main...feat/ui-foundations` for correctness (a reviewer subagent).

### Task 12: A second instance for testing

**Files:**
- Modify: `Bench/Model/BenchPaths.swift` so a bundle id other than `me.birchtree.Bench` (for example `me.birchtree.Bench.beta`) uses `Application Support/Bench-<suffix>`. Keep the `BENCH_SUPPORT_DIR` debug override.
- Modify: `Bench/App/Updater.swift` so Sparkle doesn't check for updates when the bundle id has a suffix (the feed would replace the beta with the release build).
- Modify: `Makefile`: `install-beta` target: Release build with `PRODUCT_NAME="Workbench Beta" PRODUCT_BUNDLE_IDENTIFIER=me.birchtree.Bench.beta`, copied to `/Applications/Workbench Beta.app`, then seeds `Application Support/Bench-beta/state.json` from the main copy's `state.json` if the beta folder doesn't exist yet.

- [ ] **Step 1:** Make the changes; `make install-beta`; both apps run at the same time with the same project list and separate settings.
- [ ] **Step 2: Commit** `Add make install-beta, a second copy of the app with its own settings`
