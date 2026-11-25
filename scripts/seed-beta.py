#!/usr/bin/env python3
"""Gives a fresh second copy of Workbench the real app's project list.

Usage: seed-beta.py <from-state.json> <to-state.json>

Copies the state but drops each tab's saved Claude session and pending
prompt, so the copy opens the same projects with fresh tabs instead of
resuming sessions the real app may still be running. Does nothing if the
destination already exists.
"""
import json
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
if os.path.exists(dst):
    sys.exit(0)
if not os.path.exists(src):
    sys.exit(0)

with open(src) as f:
    state = json.load(f)

for project in state.get("projects", []):
    for tab in project.get("tabs", []):
        tab.pop("resumeSessionID", None)
        tab.pop("initialPrompt", None)
        # A tab that runs its command when shown (a dev server, say) would
        # start a second copy beside the real app's.
        if "runsCommandOnStart" in tab:
            tab["runsCommandOnStart"] = False

os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w") as f:
    json.dump(state, f, indent=2)
print(f"Seeded {dst} from {src}")
