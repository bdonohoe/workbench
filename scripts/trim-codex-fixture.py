#!/usr/bin/env python3
"""Cuts a Codex session file down to what Workbench reads, for a test fixture.

Usage: trim-codex-fixture.py <rollout.jsonl> <out.jsonl>

Keeps the session's first line, every event, the turn settings and the
token records. Drops what Codex sends the model and Workbench never
reads (its instructions, its tool list, raw tool calls, the world state),
which is most of the file, and takes the account's ids and the long
instructions out of the first line.
"""
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
kept = []
for line in open(src):
    entry = json.loads(line)
    payload = entry.get("payload", {})
    kind = entry.get("type")
    if kind == "session_meta":
        for key in ("creator_user_id", "creator_account_id", "base_instructions", "dynamic_tools", "git"):
            payload.pop(key, None)
    elif kind == "response_item":
        # Only what was said, which is small. The rest is for the model.
        if payload.get("type") != "message" or payload.get("role") not in ("user", "assistant"):
            continue
        text = json.dumps(payload.get("content"))
        if "<environment_context>" in text or len(text) > 4000:
            continue
    elif kind == "world_state":
        continue
    elif kind == "turn_context":
        entry["payload"] = {key: payload[key] for key in ("turn_id", "cwd", "model", "effort", "approval_policy") if key in payload}
    elif kind == "event_msg" and payload.get("type") == "thread_settings_applied":
        settings = payload.get("thread_settings", {})
        payload["thread_settings"] = {key: settings[key] for key in ("model", "reasoning_effort", "approval_policy", "service_tier") if key in settings}
    kept.append(json.dumps(entry, separators=(",", ":")))

with open(dst, "w") as out:
    out.write("\n".join(kept) + "\n")
print(f"{dst}: {len(kept)} lines")
