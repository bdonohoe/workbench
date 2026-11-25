#!/usr/bin/env python3
"""Builds Bench/Resources/Acknowledgements.json from the license files of
everything Bench ships: Sparkle, PostHog, libghostty, and the libraries and fonts
compiled into libghostty. Run after scripts/build-ghostty.sh or a Sparkle
update; the output is committed because vendor/ isn't."""
import glob, json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ghostty = os.path.join(root, "vendor", "ghostty")
pkg = os.path.join(ghostty, "zig-pkg")

def find(pattern):
    matches = sorted(glob.glob(os.path.join(pkg, pattern)))
    if not matches:
        sys.exit(f"missing license: {pattern}")
    return matches[0]

def package(checkout):
    """The LICENSE of a Swift package, from wherever Xcode checked it out."""
    for base in [os.path.join(root, "build"), os.path.join(root, "build", "dd"), os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*")]:
        for path in glob.glob(os.path.join(base, "SourcePackages", "checkouts", checkout, "LICENSE")):
            return path
    sys.exit(f"missing {checkout} LICENSE: build Bench once so Xcode fetches the package")

SIMDUTF = """Copyright 2021 The simdutf authors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""

Z2D = """z2d is licensed under the Mozilla Public License, version 2.0. Bench uses it unmodified, as part of libghostty. Its source code is available at https://github.com/vancluever/z2d, and the license at https://mozilla.org/MPL/2.0/."""

# (name, license, homepage, file or literal text)
items = [
    ("Ghostty", "MIT", "https://github.com/ghostty-org/ghostty", os.path.join(ghostty, "LICENSE")),
    ("Sparkle", "MIT", "https://sparkle-project.org", package("Sparkle")),
    ("PostHog", "MIT", "https://github.com/PostHog/posthog-ios", package("posthog-ios")),
    ("Breakpad", "BSD 3-Clause", "https://chromium.googlesource.com/breakpad/breakpad", find("N-V-__8AALw2uwF_*/LICENSE")),
    ("Dear ImGui", "MIT", "https://github.com/ocornut/imgui", find("N-V-__8AAEbOf*/LICENSE.txt")),
    ("FreeType", "FreeType License", "https://freetype.org", find("N-V-__8AAKLKpwC4*/docs/FTL.TXT")),
    ("glslang", "BSD and others", "https://github.com/KhronosGroup/glslang", find("N-V-__8AABzkUgIS*/LICENSE.txt")),
    ("Highway", "Apache 2.0 or BSD 3-Clause", "https://github.com/google/highway", find("N-V-__8AAGmZhABb*/LICENSE-BSD3")),
    ("JetBrains Mono", "SIL Open Font License 1.1", "https://www.jetbrains.com/lp/mono/", find("N-V-__8AAIC5lw*/OFL.txt")),
    ("libpng", "libpng License", "http://www.libpng.org/pub/png/libpng.html", find("N-V-__8AAJrvXQ*/LICENSE")),
    ("libxev", "MIT", "https://github.com/mitchellh/libxev", find("libxev-*/LICENSE")),
    ("Nerd Fonts Symbols", "MIT and SIL Open Font License 1.1", "https://www.nerdfonts.com", find("N-V-__8AAMVLT*/LICENSE")),
    ("Oniguruma", "BSD 2-Clause", "https://github.com/kkos/oniguruma", find("N-V-__8AAHjwMQDB*/COPYING")),
    ("Sentry Native", "MIT", "https://github.com/getsentry/sentry-native", find("N-V-__8AAPlZGwBE*/LICENSE")),
    ("simdutf", "MIT or Apache 2.0", "https://github.com/simdutf/simdutf", SIMDUTF),
    ("SPIRV-Cross", "Apache 2.0", "https://github.com/KhronosGroup/SPIRV-Cross", find("N-V-__8AANb6pwD7*/LICENSE")),
    ("uucode", "MIT", "https://github.com/jacobsandlund/uucode", find("uucode-*/LICENSE.md")),
    ("Wuffs", "Apache 2.0 or MIT", "https://github.com/google/wuffs", find("N-V-__8AAP5JWgCGP*/LICENSE-MIT")),
    ("z2d", "Mozilla Public License 2.0", "https://github.com/vancluever/z2d", Z2D),
    ("zig-objc", "MIT", "https://github.com/mitchellh/zig-objc", find("zig_objc-*/LICENSE")),
    ("zlib", "zlib License", "https://zlib.net", find("N-V-__8AAB0eQwD*/LICENSE")),
]

out = []
for name, license, url, source in items:
    if os.path.isfile(source):
        with open(source, encoding="utf-8", errors="replace") as f:
            text = f.read().strip()
    else:
        text = source
    out.append({"name": name, "license": license, "url": url, "text": text})

dest = os.path.join(root, "Bench", "Resources", "Acknowledgements.json")
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"wrote {len(out)} entries to {os.path.relpath(dest, root)}")
