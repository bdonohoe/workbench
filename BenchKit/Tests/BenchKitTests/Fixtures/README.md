# Recorded sessions

Real sessions, recorded from the agent's own CLI in a throwaway project,
for the tests that pin how Workbench reads them (`*GoldenTests`).

- `claude/tools.jsonl`: one prompt run with `claude -p`. Covers a to-do
  list, Read, Edit, Write, Bash (one that fails), Grep, Glob and a subagent
  (its own transcript is in `claude/tools/subagents`).
- `claude/interactive.jsonl`: typed into the terminal app. Covers a `!`
  shell run, `/context`, a question picker, a permission prompt, a queued
  message, an interrupt, and `/compact`.
- `claude/hooks/*.jsonl`: every hook payload from those two sessions, one
  per line, in the order they fired.

Each transcript went through `scripts/trim-claude-fixture.py`, which drops
the bookkeeping the app never reads and anything naming an account.

The expected results are in `../Goldens` (and `BenchTests/Goldens` for the
Mac app's readers). After a change that is meant to alter them, write them
again with `BENCH_RECORD_GOLDENS=1 swift test` (or the same variable as
`TEST_RUNNER_BENCH_RECORD_GOLDENS=1 make test`) and read the diff.
