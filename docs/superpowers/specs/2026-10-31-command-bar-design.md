# Command bar (⌘K) design

Date: 2026-10-31. Branch: `feat/need-build-command-bar`.

## Intent

Workbench's sidebar splits projects into Active and a collapsible Inactive
section. Getting to anything outside Active means scrolling, expanding
Inactive, finding the row, and clicking. ⌘K opens a search field over the
main window: type a few letters, press return, and you're there. It's a
project switcher first and a command palette second.

Matt's two uses, in his words: switch quickly to one of the projects or
feature branches already open, and bring an inactive project back to start
a new session.

## Goals

- Reach any project or worktree on this Mac in a keystroke and a few letters,
  whether it's Active, Inactive, or folded under a parent.
- Opening an inactive project lands you in a session: the one it already
  has, or a fresh Claude tab if it has none.
- The existing menu actions are reachable from the same field, so ⌘K is the
  one place to type what you want.

## Non-goals

- Searching inside sessions, transcripts, files, or diffs.
- Switching between tabs within a project (⌘⇧] and ⌘⇧[ already do this).
- Replacing ⌘1 to ⌘9 or the sidebar.
- Running shell commands typed into the field.

## Anti-goals

- Anything slow to appear. The bar must open instantly from a terminal tab
  and never block on disk or network.
- Picking a project from ⌘K must behave the same as clicking it in the
  sidebar. No new surprises in what gets selected or shown.

## What's decided

### Opening and dismissing

- ⌘K opens it. It's a menu item ("Go to Project or Action…") in the app's
  command menu so it works while focus is in a Ghostty terminal tab, which
  forwards ⌘ key equivalents to the main menu. ⌘K is currently unused.
- It appears as a floating panel centered horizontally near the top of the
  main window, over the content, with the window still visible behind it.
  Escape, clicking outside it, or picking a result dismisses it. ⌘K while
  it's open also dismisses it.
- The field is focused and empty every time it opens.

### What's listed

Projects on this Mac, each as one row:

- Top-level projects, Active and Inactive alike. Row shows the project icon,
  the name, and a small muted "Inactive" tag when it's inactive.
- Agent worktrees, shown as "ParentName · branch" with the parent's icon.
  Matching works against both the parent name and the branch.
- Projects on paired remote Macs that you've added to Active, shown with the
  Mac's name as a tag. (Matt didn't ask for these; including them is my
  call so Active's contents aren't missing from the list.)

Actions, below the projects, taken from the existing command menu:
New Claude Tab, New Shell Tab, New Agent on a Branch…, Add Project…,
Overview, Usage and Costs, Past Sessions, Next Session Needing You,
Show/Hide Changes, Settings…. Each shows its keyboard shortcut on the right
when it has one. Actions that are disabled in the menu (no selected project)
are left out rather than shown greyed.

### Ordering and matching

- Empty field: projects in recent-use order (the same `lastUsed` dates that
  drive Active), with the currently selected project excluded from the top
  since you're already there. Worktrees sit right after their parent.
  Actions follow in the menu's order.
- With text: case-insensitive match that scores a prefix match on a word
  highest, then a substring, then a subsequence (letters in order, like
  "bcb" for "Bench command-bar"). Ties break by recent use. Rows that don't
  match at all are hidden. Projects and actions compete in one ranked list,
  with a small bonus for projects so a project named "Over" beats the
  Overview action.
- Up to about 12 rows are visible; the list scrolls past that. The first
  row is selected whenever the text changes.

### Picking a result

- Return picks the selected row. Up and down arrows move the selection.
  Clicking a row picks it.
- A project or worktree on this Mac: set it as the selected project, clear
  any page (Overview, Usage, History, Settings) so the project is visible,
  and show its last selected tab. If it has no tabs, add a new Claude tab
  and select it. Opening a tab notes use, which brings an inactive project
  back into Active on its own; picking a project that already has tabs
  should also note use, so it comes back into Active too.
- A remote Mac project: select it exactly as ⌘1 to ⌘9 does for a remote
  entry.
- An action: run the same code the menu item runs.

### Look

Follows the app's own neutral theme (graphite accent, no system accent
blue). Text field at the top with a magnifying glass, a thin divider, then
rows with a 16pt icon, the title, a tag or shortcut on the trailing edge.
Selected row uses the same highlight the sidebar uses. Width about 560pt.
No em dashes anywhere in the copy.

## Constraints

- macOS app, SwiftUI with AppKit where needed, matching the rest of Bench.
- Key handling must work while a Ghostty terminal has focus. Opening via
  the menu item handles ⌘K; once open, the panel's own field has focus so
  arrows, return, and escape are plain SwiftUI or an `NSEvent` local
  monitor like the sidebar already uses.
- No new dependencies.
- The command bar reads `AppStore` and `TerminalManager` through the
  environment like other views. Project selection and tab creation go
  through existing `AppStore` methods (`selectedProjectID`, `selectTab`,
  `addTab`, `selectActive`, `noteUse`) rather than new paths.

## Left to the builder

- Whether the panel is a SwiftUI overlay inside the main window or an
  `NSPanel`. An overlay is simpler and matches how the Welcome screen is
  shown; a panel can float over full-screen terminals more reliably. Pick
  what works with Ghostty focus and say which.
- Exact scoring weights for matching.
- Whether to show a project's activity dot (working, waiting) in its row.
  Nice if cheap, since `TerminalManager.activity(for:)` already exists.
- File layout: a `CommandBar` view plus a small pure `CommandBarMatcher`
  that can be unit tested with no UI.
- Menu item wording.

## Testing

- Unit tests for the matcher: prefix beats substring beats subsequence,
  tie-break by recency, worktrees match on branch, project bonus over
  action.
- Manual: open from a terminal tab, from Overview, from Settings; pick an
  inactive project with no tabs and confirm a Claude tab starts and the
  project moves to Active; pick a worktree; run an action; escape and
  click-outside dismiss.
