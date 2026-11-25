# Send Tasks to Projects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One message in Workbench becomes several reviewed tasks, each started as a New Agent (its own worktree, branch and Claude tab) in the right project.

**Architecture:** The pure logic (the prompt sent to Claude, parsing its JSON reply, project matching, branch names, readiness checks, README briefs) lives in BenchKit, where it gets the repo's first unit tests through SwiftPM. The app side adds error reasons to `ClaudeRunner`, a `TaskSplitter` that calls Claude, a batch `AgentLauncher.startAll`, an `@Observable` sheet model, the sheet itself, and two ways to open it.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), Swift Testing, `claude -p` through `ClaudeRunner`, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-31-send-tasks-design.md`

## Global Constraints

- Mac app only (`Bench` target). No phone, iPad or remote-Mac changes.
- The split runs through `ClaudeRunner` with model `sonnet`, timeout 60 seconds. No new API keys or network code.
- Nothing starts without the user pressing **Start N Agents**. Cancel, Esc and a failed split start nothing.
- Prompts are a conservative cleanup: never add requirements, steps, tests, approaches or acceptance criteria.
- Every task starts through `AgentLauncher.start`, one at a time, never in parallel.
- Starting agents from the sheet doesn't change the selected project.
- The pickable projects are top-level projects (not worktrees) whose folder is a git repo.
- Menu item: "Send Tasks to Projects…", shortcut ⌥⌘N. Toolbar button tooltip: "Send tasks to several projects (⌥⌘N)".
- UI copy as in the spec: "Send Tasks to Projects", "What should Claude work on?", "Split into Tasks", "Reading your message and matching projects…", "Edit message", "Each gets its own branch, worktree and Claude tab. These prompts are sent exactly as written.", "+ Add a task", "Start N Agents", "No tasks found. Edit your message and split again."
- Code style: comments are short and plain like the rest of the repo; commit messages are plain sentences ("Add …"), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Claude wraps its JSON in prose or a ```json fence.** It should still parse. Test in Task 1.
2. **Two tasks get the same suggested branch in one project** (for example two Bench fixes with similar words). The second gets `-2`. Test in Task 2.
3. **A branch the user types already exists locally in that repo.** Start is blocked and the card says so, since `Worktrees.create` would otherwise reuse the old branch. Test in Task 2.
4. **Two of the user's projects share a name** (two folders both called `app`). A reply naming that project is treated as unsure, not matched to either. Test in Task 1.
5. **The sheet is closed while Claude is still splitting.** The late reply is dropped and nothing changes or starts. Covered by the generation check in Task 5 and its manual check.

---

### Task 1: BenchKit test target, branch names, and parsing Claude's reply

**Files:**
- Modify: `BenchKit/Package.swift`
- Create: `BenchKit/Sources/BenchKit/BranchNames.swift`
- Create: `BenchKit/Sources/BenchKit/TaskSplit.swift`
- Modify: `Bench/Git/Worktrees.swift:163-173` (`suggestBranch` forwards to BenchKit)
- Test: `BenchKit/Tests/BenchKitTests/TaskSplitTests.swift`

**Interfaces:**
- Produces:
  - `public enum BranchNames { public static func suggest(from prompt: String) -> String }`, the body moved verbatim from `Worktrees.suggestBranch`.
  - `public struct SplitProject: Sendable, Hashable { public var id: UUID; public var name: String; public var summary: String; public init(id:name:summary:) }`
  - `public struct DraftTask: Identifiable, Sendable, Hashable { public var id: UUID; public var projectID: UUID?; public var unsure: String?; public var prompt: String; public var source: String; public var branch: String; public init(id: UUID = UUID(), projectID: UUID? = nil, unsure: String? = nil, prompt: String = "", source: String = "", branch: String = "") }`
  - `public enum TaskSplit` with `public static let instructions: String`, `public static func input(message: String, projects: [SplitProject]) -> String`, `public static func parse(_ reply: String, projects: [SplitProject]) throws -> [DraftTask]`, and `public struct ParseError: Error {}`.

- [ ] **Step 1: Add the test target**

In `BenchKit/Package.swift` add `.testTarget(name: "BenchKitTests", dependencies: ["BenchKit"])` to `targets`.

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import BenchKit

let pitwall = SplitProject(id: UUID(), name: "pitwall", summary: "F1 race tracker.")
let bench = SplitProject(id: UUID(), name: "Bench", summary: "Mac terminal.")

@Test func parsesTasksInOrder() throws {
    let reply = #"{"tasks":[{"project":"pitwall","unsure":null,"prompt":"Add a lap delta chart.","source":"In pitwall I want"},{"project":"Bench","unsure":null,"prompt":"Fix the sidebar flicker.","source":"Also in Bench"}]}"#
    let tasks = try TaskSplit.parse(reply, projects: [pitwall, bench])
    #expect(tasks.map(\.projectID) == [pitwall.id, bench.id])
    #expect(tasks.map(\.prompt) == ["Add a lap delta chart.", "Fix the sidebar flicker."])
    #expect(tasks[0].source == "In pitwall I want")
    #expect(tasks[0].branch == BranchNames.suggest(from: "Add a lap delta chart."))
    #expect(tasks[1].branch.hasPrefix("fix/"))
}

@Test func parsesJSONInsideProseAndFences() throws {
    let reply = "Here you go:\n```json\n{\"tasks\":[{\"project\":\"Bench\",\"prompt\":\"Add export.\",\"source\":\"x\"}]}\n```\nDone."
    #expect(try TaskSplit.parse(reply, projects: [bench]).count == 1)
}

@Test func matchesProjectNamesIgnoringCase() throws {
    let reply = #"{"tasks":[{"project":"bench","prompt":"Add export.","source":"x"}]}"#
    #expect(try TaskSplit.parse(reply, projects: [bench])[0].projectID == bench.id)
}

@Test func keepsUnsureReasonWithNoProject() throws {
    let reply = #"{"tasks":[{"project":null,"unsure":"Could be read-later or quick-reads-ios.","prompt":"Add a font slider.","source":"the reading app"}]}"#
    let task = try TaskSplit.parse(reply, projects: [bench])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "Could be read-later or quick-reads-ios.")
}

@Test func unknownProjectBecomesUnsure() throws {
    let reply = #"{"tasks":[{"project":"Nonesuch","prompt":"Do it.","source":"x"}]}"#
    let task = try TaskSplit.parse(reply, projects: [bench])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "Claude suggested “Nonesuch”, which isn't one of your projects.")
}

@Test func duplicateProjectNamesBecomeUnsure() throws {
    let a = SplitProject(id: UUID(), name: "app", summary: ""), b = SplitProject(id: UUID(), name: "app", summary: "")
    let reply = #"{"tasks":[{"project":"app","prompt":"Do it.","source":"x"}]}"#
    let task = try TaskSplit.parse(reply, projects: [a, b])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "More than one of your projects is called “app”.")
}

@Test func emptyTaskListIsNotAnError() throws {
    #expect(try TaskSplit.parse(#"{"tasks":[]}"#, projects: [bench]).isEmpty)
}

@Test func unreadableReplyThrows() {
    #expect(throws: TaskSplit.ParseError.self) { try TaskSplit.parse("Sorry, I can't help.", projects: [bench]) }
    #expect(throws: TaskSplit.ParseError.self) { try TaskSplit.parse(#"{"items":[]}"#, projects: [bench]) }
}

@Test func inputListsMessageThenProjects() {
    let text = TaskSplit.input(message: "Fix it.", projects: [pitwall, SplitProject(id: UUID(), name: "nono", summary: "")])
    #expect(text == "Message:\nFix it.\n\nProjects:\n- pitwall: F1 race tracker.\n- nono: No description.")
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path BenchKit --filter TaskSplitTests`
Expected: compile failure, `cannot find 'TaskSplit' in scope`.

- [ ] **Step 4: Implement `BranchNames.suggest`, the types, `input` and `parse`**

Move the body of `Worktrees.suggestBranch(from:)` into `BranchNames.suggest(from:)` unchanged; `Worktrees.suggestBranch` becomes `BranchNames.suggest(from: prompt)` and `Worktrees.swift` imports BenchKit if it doesn't already.

`parse`: take the text from the first `{` to the last `}`, decode `{"tasks":[{"project":String?,"unsure":String?,"prompt":String,"source":String?}]}` with `JSONDecoder` (a missing `tasks` key or bad JSON throws `ParseError`), trim each prompt and drop entries whose prompt is empty, match `project` against `projects` by case-insensitive name, and set `branch` to `BranchNames.suggest(from: prompt)`. The two unsure messages are the exact strings in the tests.

`instructions` is exactly this text:

```
You split a developer's message into separate coding tasks, one per request, and match each task to one of their projects.

You get the message, then their projects, each with its name and a short description.

Rules:
- One task per request. Never merge two requests, and never split one request into two. Two requests for the same project are two tasks.
- Keep their words and meaning. Change only what's needed for the prompt to stand alone in a fresh coding session that already works inside that project: drop the project name and lead-ins like "In pitwall I want to", "Also in Bench" or "oh and", resolve words that point at other parts of the message, like "that" or "also", and fix obvious typos.
- Never add requirements, steps, tests, approaches or acceptance criteria they didn't ask for.
- Match a project only when the message makes it clear. If a request could belong to more than one project, or to none, set "project" to null and say why in "unsure", naming the likely projects.
- Greetings, asides and anything that isn't a request produce no task.
- "source" is their own words that the task came from, at most 120 characters.

Reply with only JSON and no other text:
{"tasks":[{"project":"<a project name exactly as listed, or null>","unsure":"<why, or null>","prompt":"<the cleaned-up request>","source":"<their words>"}]}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path BenchKit --filter TaskSplitTests`
Expected: all 9 tests pass.

- [ ] **Step 6: Check the app still builds**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add BenchKit Bench/Git/Worktrees.swift
git commit -m "Parse a message split into tasks, with BenchKit's first tests"
```

---

### Task 2: Branch uniqueness, readiness checks, and README briefs

**Files:**
- Modify: `BenchKit/Sources/BenchKit/TaskSplit.swift`
- Test: `BenchKit/Tests/BenchKitTests/TaskSplitTests.swift`

**Interfaces:**
- Consumes: `DraftTask`, `SplitProject` from Task 1.
- Produces:
  - `public static func uniquingBranches(_ tasks: [DraftTask], existing: [UUID: Set<String>]) -> [DraftTask]`
  - `public static func problems(_ tasks: [DraftTask], existing: [UUID: Set<String>], names: [UUID: String]) -> [UUID: String]`, keyed by task id, an empty dictionary meaning ready to start.
  - `public static func brief(fromMarkdown text: String, limit: Int = 400) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func secondTaskWithSameBranchGetsSuffix() {
    let tasks = [DraftTask(projectID: bench.id, branch: "fix/sidebar"), DraftTask(projectID: bench.id, branch: "fix/sidebar"),
                 DraftTask(projectID: pitwall.id, branch: "fix/sidebar")]
    let result = TaskSplit.uniquingBranches(tasks, existing: [:])
    #expect(result.map(\.branch) == ["fix/sidebar", "fix/sidebar-2", "fix/sidebar"])
}

@Test func suffixSkipsExistingBranches() {
    let tasks = [DraftTask(projectID: bench.id, branch: "feat/export")]
    let result = TaskSplit.uniquingBranches(tasks, existing: [bench.id: ["feat/export", "feat/export-2"]])
    #expect(result[0].branch == "feat/export-3")
}

@Test func readyTasksHaveNoProblems() {
    let task = DraftTask(projectID: bench.id, prompt: "Add export.", branch: "feat/export")
    #expect(TaskSplit.problems([task], existing: [bench.id: ["main"]], names: [bench.id: "Bench"]).isEmpty)
}

@Test func problemsNameWhatToFix() {
    let noProject = DraftTask(prompt: "x", branch: "feat/a")
    let noBranch = DraftTask(projectID: bench.id, prompt: "x", branch: "  ")
    let noPrompt = DraftTask(projectID: bench.id, prompt: " \n", branch: "feat/b")
    let taken = DraftTask(projectID: bench.id, prompt: "x", branch: "main")
    let twinA = DraftTask(projectID: pitwall.id, prompt: "x", branch: "feat/c")
    let twinB = DraftTask(projectID: pitwall.id, prompt: "y", branch: "feat/c")
    let p = TaskSplit.problems([noProject, noBranch, noPrompt, taken, twinA, twinB],
                               existing: [bench.id: ["main"], pitwall.id: []],
                               names: [bench.id: "Bench", pitwall.id: "pitwall"])
    #expect(p[noProject.id] == "Pick a project.")
    #expect(p[noBranch.id] == "Add a branch name.")
    #expect(p[noPrompt.id] == "Write a prompt.")
    #expect(p[taken.id] == "main already exists in Bench. Pick another branch name.")
    #expect(p[twinA.id] == nil)
    #expect(p[twinB.id] == "Another task in pitwall already uses feat/c.")
}

@Test func briefSkipsHeadingsBadgesAndCode() {
    let readme = "# Workbench\n\n[![CI](x.svg)](y)\n\n```sh\nmake\n```\n\nA lean Mac terminal for working\nacross many projects.\n\nMore text."
    #expect(TaskSplit.brief(fromMarkdown: readme) == "A lean Mac terminal for working across many projects.")
}

@Test func briefStopsAtLimitOnAWord() {
    #expect(TaskSplit.brief(fromMarkdown: "one two three four", limit: 9) == "one two…")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path BenchKit --filter TaskSplitTests`
Expected: compile failure, `type 'TaskSplit' has no member 'uniquingBranches'`.

- [ ] **Step 3: Implement the three functions**

`uniquingBranches`: walk tasks in order, keeping a used set per project seeded from `existing`. Tasks with no project are left alone. On a clash try `-2`, `-3`, … until free.

`problems`: check in this order and report only the first problem per task: no project, blank branch, blank prompt, branch in `existing[project]`, branch already used by an earlier task in the same project. Compare branches after trimming whitespace. The copy is the exact strings in the test.

`brief`: skip blank lines, lines starting with `#`, `![`, `[![`, `<`, `>`, `|`, and everything between ``` fences. Join the first run of remaining lines (up to the next blank line) with single spaces. If it's longer than `limit`, cut at the last space at or before `limit` and append `…`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path BenchKit --filter TaskSplitTests`
Expected: all 15 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BenchKit
git commit -m "Unique branch names, readiness checks and README briefs for split tasks"
```

---

### Task 3: Ask Claude to split, with reasons when it fails

**Files:**
- Modify: `Bench/Terminal/ClaudeRunner.swift`
- Create: `Bench/Git/TaskSplitter.swift`

**Interfaces:**
- Consumes: `TaskSplit.instructions`, `TaskSplit.input`, `TaskSplit.parse`, `TaskSplit.brief`, `TaskSplit.uniquingBranches` (Tasks 1–2).
- Produces:
  - `ClaudeRunner.Failure: Error, Equatable` with cases `notInstalled`, `couldNotStart`, `timedOut`, `failed(status: Int32)`, `emptyReply`.
  - `nonisolated static func ClaudeRunner.run(_ input: String, instructions: String, model: String, timeout: TimeInterval) -> Result<String, ClaudeRunner.Failure>`. `ask` keeps its signature and becomes `try? run(...).get()`.
  - `enum TaskSplitter` with:
    - `static func projects(in store: AppStore) -> [SplitProject]`, MainActor.
    - `nonisolated static func split(_ message: String, projects: [SplitProject]) async -> Result<[DraftTask], TaskSplitter.Failure>`
    - `nonisolated static func existingBranches(repo: URL) async -> Set<String>`
    - `struct Failure: Error { var message: String }`

- [ ] **Step 1: Add `ClaudeRunner.run`**

Same process setup as `ask` today. Set a `timedOut` flag inside the timer's work item before `terminate()`. Map: no `claude` path → `.notInstalled`; `process.run()` throws → `.couldNotStart`; flag set → `.timedOut`; non-zero exit → `.failed(status:)`; blank output → `.emptyReply`. Recaps and the morning summary keep calling `ask` unchanged.

- [ ] **Step 2: Write `TaskSplitter`**

`projects(in:)`: `store.projects` filtered to `!isWorktree` and a `.git` entry at the folder (file or directory). Use `project.name` and `TaskSplit.brief` of `README.md`, falling back to `CLAUDE.md` and then to an empty string. Read at most the first 16 KB of either file.

`split`: run on a detached task at `.userInitiated`. `ClaudeRunner.run(TaskSplit.input(...), instructions: TaskSplit.instructions, model: "sonnet", timeout: 60)`, then `TaskSplit.parse`, then fetch `existingBranches` for each distinct project in the result and return `TaskSplit.uniquingBranches(tasks, existing:)`. Failure copy:
- `.notInstalled`: "Claude Code isn't installed, so Workbench can't split your message. Install it, then try again."
- `.timedOut`: "Claude took too long to answer. Try again."
- `.couldNotStart`, `.failed`: "Claude Code couldn't split your message. Try again, or run claude in a terminal to check you're signed in."
- `.emptyReply` or `ParseError`: "Claude's answer couldn't be read. Try again."

`existingBranches(repo:)`: `GitClient(root: repo).optionalString(["for-each-ref", "--format=%(refname:short)", "refs/heads"])`, split on newlines. Local branches only, since those are what `Worktrees.create` would reuse.

- [ ] **Step 3: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`, no new warnings in `Bench/`.

- [ ] **Step 4: Spot-check the split for real**

Add a temporary `#if DEBUG` launch hook that runs `TaskSplitter.split` on this example message and prints the result:

```
In pitwall I want to add a lap-time delta chart to the race view, comparing each driver to the leader.

There's a bug in read-later where articles behind a paywall show a blank page instead of the excerpt.

For Bench, add an export button to recaps so I can copy a day's recap as Markdown. Also in Bench, the sidebar flickers when you rename a project, please fix that.

And in the reading app, add a font size slider to the reader settings.
``` Run it once with `make run`. Expected: five tasks; pitwall, read-later and two Bench tasks matched; the "reading app" task has no project and an `unsure` reason; no prompt adds a test or anything else that isn't in the message. Remove the hook. If the prompts add scope, tighten `TaskSplit.instructions` and re-run before moving on.

- [ ] **Step 5: Commit**

```bash
git add Bench/Terminal/ClaudeRunner.swift Bench/Git/TaskSplitter.swift
git commit -m "Ask Claude to split a message into tasks, and say why when it can't"
```

---

### Task 4: Start a batch of agents without moving the selection

**Files:**
- Modify: `Bench/Git/AgentLauncher.swift`
- Modify: `Bench/Model/AppStore.swift:419-438` (`addWorktree`)
- Modify: `Bench/Views/NewAgentSheet.swift:150-158` (use the shared base choice)

**Interfaces:**
- Consumes: `DraftTask` (Task 1).
- Produces:
  - `AppStore.addWorktree(parent:path:branch:base:prompt:setupCommand:select: Bool = true) -> UUID`. When `select` is false, `selectedProjectID` stays as it was.
  - `AgentLauncher.start(... , select: Bool = true)`, passed through to `addWorktree`.
  - `nonisolated static func AgentLauncher.preferredBase(repo: URL) async -> String?`: the logic now in `NewAgentSheet` (default base with `origin/` dropped if that branch exists, else the current branch, else the first branch).
  - `static func AgentLauncher.startAll(_ tasks: [DraftTask], store: AppStore, terminals: TerminalManager) async -> [UUID: String]`: failures keyed by task id, empty when all started.

- [ ] **Step 1: Add `select` to `addWorktree` and `start`, and extract `preferredBase`**

`NewAgentSheet` calls `preferredBase` for its initial `base` and keeps loading `branches` for its picker as it does now.

- [ ] **Step 2: Write `startAll`**

For each task in order, awaiting each before the next: look up `store.project(task.projectID)`. If it's missing, record "This project is no longer in Workbench." Otherwise call `start` with the task's trimmed branch and prompt, `files: parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url)`, `command: parent.setupCommand`, `base: await preferredBase(repo: parent.url)`, `select: false`. Record `error.localizedDescription` on a throw and carry on with the next task.

- [ ] **Step 3: Build and check New Agent still works**

Run: `make build`, then `make run`, then use **New Agent on a Branch…** (⇧⌘N) once in a test repo.
Expected: the build succeeds; the sheet's "From" picker shows the same base as before; the new agent is selected as before.

- [ ] **Step 4: Commit**

```bash
git add Bench/Git/AgentLauncher.swift Bench/Model/AppStore.swift Bench/Views/NewAgentSheet.swift
git commit -m "Start a batch of agents one at a time, leaving the selection alone"
```

---

### Task 5: The Send Tasks sheet and its two entry points

**Files:**
- Create: `Bench/Views/SendTasksModel.swift`
- Create: `Bench/Views/SendTasksSheet.swift`
- Modify: `Bench/Model/AppStore.swift` (near `newAgentParentID`, line 60)
- Modify: `Bench/Views/ContentView.swift:84-91` (present the sheet next to the New Agent sheet)
- Modify: `Bench/Views/ProjectDetailView.swift:338-347` (button right before the `+`)
- Modify: `Bench/App/BenchApp.swift:248-251` (menu item after "New Agent on a Branch…")

**Interfaces:**
- Consumes: `TaskSplitter` (Task 3), `AgentLauncher.startAll` (Task 4), `TaskSplit.problems` (Task 2).
- Produces:
  - `AppStore.showsSendTasks: Bool` and `func AppStore.startSendTasks()`, which sets it to true. The future ⌘K palette calls `startSendTasks()`.
  - `@Observable final class SendTasksModel` with `enum Step { case write, splitting, review, starting }`, `step`, `message: String`, `tasks: [DraftTask]`, `error: String?`, `startErrors: [UUID: String]`, `projects: [SplitProject]`, `problems: [UUID: String]` (computed with `TaskSplit.problems`), `canStart: Bool` (`!tasks.isEmpty && problems.isEmpty`), and methods `split()`, `editMessage()`, `addTask()`, `remove(_ id: UUID)`, `setProject(_ projectID: UUID?, for taskID: UUID)`, `cancelSplit()`, `start(store:terminals:) async -> Bool`.

- [ ] **Step 1: Write `SendTasksModel`**

- `split()` sets `.splitting`, bumps a private `generation: Int`, and runs `TaskSplitter.split`. When the reply arrives, it's dropped if `generation` changed. On success: `tasks` = result, `step` = `.review`. On failure: `error` = message, `step` = `.write`, `message` untouched.
- `cancelSplit()` bumps `generation`. The sheet calls it on dismiss.
- `setProject` updates the task, clears its `unsure`, and loads `existingBranches` for that project if it isn't in the private `existing` cache yet.
- `start` sets `.starting`, calls `startAll` with all tasks, and removes the tasks that started. Returns true when none failed. Otherwise it keeps the failed tasks with `startErrors` filled, and goes back to `.review`.

- [ ] **Step 2: Write `SendTasksSheet`**

Match `NewAgentSheet`'s look: padding, 15 pt semibold title, 12 pt secondary text, `TerminalTheme.shared.canvas` text areas with the same rounded border. Width about 620 pt.
- **Write step:** title, the line "Say what you want done across your projects. You'll check the split before anything starts.", the label "What should Claude work on?", a `TextEditor` about 160 pt tall, focused on appear. `error` in red under it. **Cancel** (Esc, `.cancelAction`) and **Split into Tasks** (⌘↩, `.defaultAction`), disabled when the message is blank.
- **Splitting:** `ProgressView` plus "Reading your message and matching projects…". Cancel still works.
- **Review step:** the message as a two-line `lineLimit` quote with **Edit message**; header "\(n) task(s)" and the spec's explainer line; a scrolling list of cards, at most about 520 pt tall. Each card has:
  - a left stripe: `ActivityBackground.working` normally, `ActivityBackground.waiting` when there's no project
  - a project `Picker`, with "Which project?" as the nil option, then `model.projects` by name
  - a monospaced branch `TextField`
  - an ✕ button with the help text "Remove task"
  - the `unsure` reason in amber when there's no project, then the problem or start error in red
  - the prompt `TextEditor`, at least 64 pt tall
  - "From “source”" in secondary text, hidden when the source is empty
  
  Under the list: **+ Add a task** on the left; **Cancel**, and **Start N Agents** (`.defaultAction`, disabled unless `canStart`) on the right. With no tasks, show "No tasks found. Edit your message and split again." in place of the list.
- **Starting:** the Start button shows a `ProgressView`, and `.interactiveDismissDisabled(true)` blocks Cancel and Esc.
- On `start` returning true, dismiss.

- [ ] **Step 3: Wire up the entry points**

- `ContentView`: `.sheet(isPresented: $store.showsSendTasks) { SendTasksSheet() }`.
- `ProjectDetailView`: a borderless button before the `+`, 22×22 like it, with `Image(systemName: "arrow.triangle.branch")` (or another fan-out symbol; the spec leaves the icon open) tinted `ActivityBackground.working`, calling `store.startSendTasks()`, with help "Send tasks to several projects (⌥⌘N)".
- `BenchApp`: `Button("Send Tasks to Projects…") { store.startSendTasks() }.keyboardShortcut("n", modifiers: [.command, .option])`. It isn't disabled when no project is selected.

- [ ] **Step 4: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`, no new warnings in `Bench/`.

- [ ] **Step 5: Check it by hand in the running app**

Run `make run` and work through these, in throwaway repos or ones where extra branches are fine:
1. ⌥⌘N with no project selected opens the sheet; so does the new toolbar button.
2. Paste the example message from Task 3, Step 4, and press ⌘↩. Expected: five cards, the reading-app card amber, **Start** disabled.
3. Pick a project for the amber card. Expected: it turns orange and Start enables.
4. Change a branch to `main`. Expected: "main already exists in …" and Start disabled. Change it back.
5. **Edit message**, change the text, split again. Expected: the task list is replaced.
6. Split, then press Cancel while it's still reading. Expected: the sheet closes; reopening shows the write step; nothing starts later.
7. Remove all but two tasks and press **Start 2 Agents**. Expected: the sheet closes, two agents appear in the sidebar under their projects, and the selected project hasn't changed.
8. Temporarily rename `claude` on PATH, or set `Tools` to miss it in a debug build, and split. Expected: the "isn't installed" message, with your text still in the box.

- [ ] **Step 6: Commit**

```bash
git add Bench/Views/SendTasksModel.swift Bench/Views/SendTasksSheet.swift Bench/Model/AppStore.swift Bench/Views/ContentView.swift Bench/Views/ProjectDetailView.swift Bench/App/BenchApp.swift
git commit -m "Send tasks to several projects from one message"
```
