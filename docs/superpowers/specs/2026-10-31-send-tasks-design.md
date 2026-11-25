# Send Tasks to Projects

Date: 2026-10-31
Status: design, awaiting approval
Prototype: https://claude.ai/artifact/7L2nbH6VqHGSFQ9Lj8unAX (layout A is the chosen one)

## Why

When Matt has several things in mind across projects, he opens each project
and types each request separately. This feature lets him write one message
describing everything ("add this feature to X, there's a bug in Y, add this
to Z"), have Workbench split it into one task per request, check exactly
what will be sent, and start them all at once.

Every task runs as a new agent in its own git worktree on its own branch,
through the existing New Agent flow. That avoids any question of which open
session a request should go to: nothing already open is touched.

## Goals

- One free-form message in, one task per request out, each matched to a
  Workbench project.
- Two requests for the same project become two tasks on two branches.
- Nothing is sent until Matt has seen and approved the exact prompt, the
  project and the branch for every task.
- Each prompt is a light, conservative cleanup of Matt's own words.
- Starting reuses `AgentLauncher.start` so worktrees, setup files, setup
  commands, the sidebar and merged-worktree cleanup all work as they do for
  a single agent today.

## Non-goals

- The ⌘K command palette. Matt has one in progress on his own. This feature
  only needs to be openable from a command so the palette can call it later.
- The iPhone, iPad and remote Macs. Mac only for now.
- Sending into existing sessions or tabs.
- Non-git folders. A worktree needs a repo.

## Anti-goals (a failure even if it works)

- **Adding scope.** The cleanup must not invent requirements, tests,
  approaches or acceptance criteria Matt didn't ask for. In the prototype the
  bug-fix prompt gained "add a test"; the real thing must not do that unless
  he said it.
- **Guessing a project silently.** If a request could belong to more than
  one project, or none, Workbench says so instead of picking.
- **Starting anything without approval.** Cancel, Esc or a failed split
  start nothing.
- **Losing Matt's words.** Each task shows the part of his message it came
  from, so he can check the cleanup against the original.

## How it works

### Opening it

- A **Send Tasks…** button sits at the trailing end of the Overview's
  header (`Bench/Views/OverviewView.swift`), and the Overview's empty state
  offers it too. The Overview is the one page that spans every project, so
  an action that fans out across projects belongs there. *(It first shipped
  beside the project tab bar's **+** button, which read as a per-project
  action and confused people; moved on 2026-11-01.)*
- The same action is available as a menu command with a keyboard shortcut,
  so it works when no project is selected and so the future palette can call
  it. *(My call: the menu item and shortcut. ⇧⌘N, shown in the prototype, is
  already "New Agent on a Branch…" in `Bench/App/BenchApp.swift`, so use a free
  combination such as ⌥⌘N and update the button's tooltip to match.)*
- It opens a **sheet over the window** (layout A, Matt's choice), styled like
  `NewAgentSheet`.

### Step 1: Write

- Title "Send Tasks to Projects", one line explaining that nothing starts
  until he checks the split.
- One large text box: "What should Claude work on?"
- **Split into Tasks** button; ⌘↩ does the same. **Cancel** and Esc close
  the sheet.
- While splitting: a spinner with "Reading your message and matching
  projects…".

### Step 2: Review (the same sheet)

- Top: the original message as a one- or two-line quote with **Edit
  message**, which returns to step 1 with the text intact. Splitting again
  replaces the task list.
- A header: "N tasks. Each gets its own branch, worktree and Claude tab.
  These prompts are sent exactly as written."
- One card per task, in the order the requests appeared:
  - **Project** picker listing Workbench's git projects (not worktrees).
  - **Branch** field, editable, prefilled with a suggested name.
  - **Prompt**, an editable multi-line field. This is exactly what gets sent.
  - **From:** the excerpt of Matt's message this task came from.
  - **✕** removes the task.
- **Uncertain tasks** get an amber card (Workbench's "waiting" amber) with
  a line saying why, like "'the reading app' could be read-later or
  quick-reads-ios", and an empty project picker.
- **+ Add a task** adds a blank card for anything the split missed.
- **Start N Agents** is the primary button. It stays disabled until every
  task has a project, a non-empty branch and a non-empty prompt.
- **Cancel** / Esc discards the split and starts nothing.

### Step 3: Start

- For each task, call `AgentLauncher.start` with the chosen project, branch,
  prompt, and the project's saved worktree setup (`setupFiles`,
  `setupCommand`), or `Worktrees.suggestedSetupFiles` when none is saved,
  just as `NewAgentSheet` prefills. The base branch is chosen the way
  `NewAgentSheet` chooses it: the repo's default branch, falling back to the
  current one.
- Before starting anything, check each task's branch against its repo. A
  branch that already exists is flagged on its card ("feat/x already exists")
  and blocks Start until it's renamed. `Worktrees.create` would otherwise
  quietly reuse the old branch.
- On success the sheet closes. The new agents appear in the sidebar under
  their projects like any other agent.
- *(My call.)* The selection stays where it was. `AppStore.addWorktree`
  selects each new worktree, which would jump the window to the last agent
  started; batch starts should skip that.
- If some tasks fail (for example the branch already exists), the sheet stays
  open showing only the failed tasks, each with its error, so Matt can fix
  and retry them. Tasks that started are not started again. *(My call.)*
  Tasks start one after another, not in parallel, so git operations on the
  same repo don't collide. *(My call.)*

## The split

- Uses the existing `ClaudeRunner.ask` helper (the one recaps use), which
  runs `claude -p` with no tools and no settings. No new API keys.
  `ClaudeRunner.ask` currently returns nil on any failure; extend it (or add
  a sibling) so the sheet can tell "Claude Code isn't installed" from "timed
  out" from "bad response".
- *(My call: model.)* Use a mid-size model (`sonnet`) rather than `haiku`,
  since matching projects and keeping Matt's wording faithful matter more
  here than speed. Timeout around 60 seconds.
- Input to the model: Matt's message, plus a list of his git projects. For
  each project, its name and a short description taken from the first
  paragraph of its README or CLAUDE.md, so phrases like "the podcast app"
  can be matched. *(My call: which files and how much.)*
- Output: structured JSON, one entry per task, with project name (or none),
  a reason when unsure, the cleaned-up prompt, and the source excerpt.
  Workbench validates every project name against its own list; an unknown
  name is treated as "unsure".
- Branch names come from `Worktrees.suggestBranch(from:)` on each cleaned
  prompt, made unique among the tasks in the split and against the repo's
  existing branches.

### Cleanup rules (the system prompt must enforce these)

- Keep Matt's words and meaning. Fix only what's needed for the prompt to
  stand alone in a fresh session: drop the project name and lead-ins ("In
  pitwall I want to…", "Also in Bench…", "oh and"), resolve references to
  other parts of the message ("that", "also"), and fix obvious typos.
- Never add requirements, steps, tests, approaches or acceptance criteria.
- Never merge two requests into one task or split one request into two.
- When unsure which project something belongs to, leave the project empty
  and say why; don't guess.
- Text that isn't a request (greetings, asides) produces no task.

## Failure cases

- **Claude Code isn't installed or the call fails or times out:** stay on
  the write step with the message intact and an error saying what happened,
  with Try Again. *(My call: no fallback that sends the raw message.)*
- **The model returns nothing usable:** same as above.
- **No tasks found:** show the empty state, "No tasks found. Edit your
  message and split again," with Add a Task available.

## Left to the builder

- Exact view structure, and whether to extend `NewAgentSheet` or write a
  new sheet that shares pieces with it.
- The toolbar icon (the prototype uses a fan-out arrow) and its tooltip.
- JSON schema details, prompt wording within the rules above, and parsing.
- How many README/CLAUDE.md characters to send per project.
- Tests: the JSON parsing, project-name validation and branch de-duplication
  are pure logic and should have unit tests. The repo has no test target
  yet, so this means adding one.
