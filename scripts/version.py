#!/usr/bin/env python3
"""Reads or sets an app's version and build number in project.yml.

  version.py get              prints the Mac app's "<version> <build>"
  version.py set 0.3 7        sets them
  version.py --phone get      the same for the iPhone app and its widgets
  version.py --phone set 0.1.0 4
"""
import re
import sys

args = sys.argv[1:]
phone = args[:1] == ["--phone"]
if phone:
    args = args[1:]

PATH = "project.yml"
text = open(PATH).read()
if phone:
    # The iPhone app and its widget extension share a version, and run to
    # the end of the file.
    start = text.index("\n  BenchPhone:\n")
    end = len(text)
else:
    # The Mac app's block runs from "  Bench:" to the next target.
    start = text.index("\n  Bench:\n")
    end = text.index("\n  BenchPhone:\n", start)
block = text[start:end]

def field(name):
    return re.search(rf"{name}: (\S+)", block).group(1).strip('"')

if args[0] == "get":
    print(field("MARKETING_VERSION"), field("CURRENT_PROJECT_VERSION"))
elif args[0] == "set":
    version, build = args[1], args[2]
    # Quoted, or YAML reads a version like 0.10 as the number 0.1, and the
    # app ships saying it's 0.1.
    block = re.sub(r"MARKETING_VERSION: \S+", f'MARKETING_VERSION: "{version}"', block)
    block = re.sub(r"CURRENT_PROJECT_VERSION: \S+", f"CURRENT_PROJECT_VERSION: {build}", block)
    open(PATH, "w").write(text[:start] + block + text[end:])
