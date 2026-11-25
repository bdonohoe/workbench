#!/usr/bin/env python3
"""Trims a Claude Code transcript (.jsonl) down to a test fixture.

    scripts/trim-claude-fixture.py <session.jsonl> <fixture.jsonl>

A real transcript is mostly bookkeeping Workbench never reads: copies of
each API request, the skill and tool listings, your own instructions
files. This keeps the lines the app's readers use (what was said, the
tools, queueing, titles, turn times) whole and in order, plus the small
bookkeeping lines, so the readers are still tested on skipping lines
they don't know. Lines that could carry account details are dropped.
"""
import json, sys

KEEP = {"user", "assistant", "system", "queue-operation", "ai-title", "custom-title", "summary"}
DROP = {"session-owner", "api-request", "api-request-blob", "api-request-shape", "data-flow-records", "cost-state"}
KEEP_ATTACHMENTS = {"queued_command"}
SMALL = 1500

def keep(line, entry):
    kind = entry.get("type")
    if kind in KEEP:
        return True
    if kind in DROP:
        return False
    if kind == "attachment":
        return (entry.get("attachment") or {}).get("type") in KEEP_ATTACHMENTS
    return len(line) <= SMALL

def shorten_context(line, entry):
    """/context lists every connected service and agent. The first table
    is enough to test with."""
    message = entry.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        return line
    text = message["content"]
    cut = text.find("\n\n### Other MCP tools")
    if not text.startswith("## Context Usage") or cut < 0:
        return line
    message["content"] = text[:cut] + "\n"
    return json.dumps(entry, separators=(",", ":")) + "\n"

source, target = sys.argv[1], sys.argv[2]
kept = 0
with open(source) as lines, open(target, "w") as out:
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if keep(line, entry):
            line = shorten_context(line, entry)
            out.write(line)
            kept += 1
print(f"kept {kept} lines in {target}")
