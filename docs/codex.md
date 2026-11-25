# Codex in Workbench

Workbench runs OpenAI's Codex in the same tabs it runs Claude Code in, with the same chat, cards, shortcuts and phone app. It is offered on a Mac that has `codex` installed. Settings > Agents > Coding Agents has the switch, which agent new tabs run, and the command Codex tabs start with.

**Status: beta.** Workbench is built for Claude Code, and Claude Code is what setup asks for. Codex is offered beside it and marked Beta in setup and Settings.

## How it works

- Workbench starts `codex` in a terminal tab and passes its hooks on the command line (`-c hooks.…`). It never writes to `~/.codex`. It reads your sessions there, and the starting effort from `config.toml`.
- Codex asks you to trust the hooks the first time ("Hooks need review"). The chat shows that as a card. Without them Workbench can't tell what Codex is doing.
- All agent-specific code is in `Bench/Agents/Codex` and `BenchKit/Sources/BenchKit/CodexTranscriptFormat.swift`. `ProviderLeakTests` fails if anything else names it.

## What works

Starting, resuming and past sessions. Working, waiting and done states. The chat with commands, file changes and diffs. Allow and deny for commands. The folder trust and hook review prompts as cards. Model and effort switching (for the session only). Compact and Clear. Side questions. Recaps and task splitting through `codex exec` when Codex is your default agent. Agents on a branch, and `bench agent --with codex`. Token totals in spend.

## What doesn't yet

- Codex's own multiple-choice questions and plans: answer those in the terminal.
- Queued messages can't be taken back or sent early. Codex has no key for it.
- Permission modes can't be switched from the chat.
- Pictures attached to a message.
- Subagents as a list.
- Costs. Spend shows tokens only.
- Plan limits are read (`CodexPlanLimits`) but not shown.
- Picking the agent when starting a session from the phone. It uses the Mac's default.

## Testing

Fixtures were recorded from Codex 0.172: session files in `BenchKit/Tests/BenchKitTests/Fixtures/codex`, screens in `BenchTests/Screens/codex`. `scripts/trim-codex-fixture.py` trims a new recording and removes account ids.
