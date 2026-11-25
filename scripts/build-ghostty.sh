#!/bin/bash
# Builds GhosttyKit.xcframework (libghostty) from a pinned Ghostty commit and
# copies it plus Ghostty's runtime resources into vendor/.
#
# Ghostty v1.3.x needs Zig 0.15, which can't link against the macOS 27 SDK,
# so we pin a main-branch commit that builds with Zig 0.17.
set -euo pipefail

GHOSTTY_COMMIT="22f100c6"
ZIG_VERSION="0.17.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR"

if [ ! -x "$VENDOR/zig/zig" ] || [ "$("$VENDOR/zig/zig" version)" != "$ZIG_VERSION" ]; then
  echo "Downloading Zig $ZIG_VERSION"
  rm -rf "$VENDOR/zig" && mkdir -p "$VENDOR/zig"
  curl -sSfL "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" \
    | tar -xJ -C "$VENDOR/zig" --strip-components 1
fi

if [ ! -d "$VENDOR/ghostty/.git" ]; then
  git clone https://github.com/ghostty-org/ghostty.git "$VENDOR/ghostty"
fi
cd "$VENDOR/ghostty"
git fetch --quiet origin "$GHOSTTY_COMMIT" 2>/dev/null || git fetch --quiet origin
git checkout --quiet "$GHOSTTY_COMMIT"

# Zig 0.17's built-in downloader stalls on some networks, so fetch the
# dependency tarballs with curl and unpack them where `zig build` looks
# (zig-pkg/<hash>/). Git-based deps are left for zig to fetch itself.
echo "Prefetching dependencies"
python3 - "$VENDOR" <<'PY'
import glob, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
vendor = sys.argv[1]
src = os.path.join(vendor, "ghostty")
pkg = os.path.join(src, "zig-pkg")
downloads = os.path.join(vendor, "ghostty-deps")
os.makedirs(pkg, exist_ok=True)
os.makedirs(downloads, exist_ok=True)
pairs = {}
for zon in [os.path.join(src, "build.zig.zon")] + glob.glob(os.path.join(src, "pkg/*/build.zig.zon")):
    text = open(zon).read()
    for m in re.finditer(r'\.url\s*=\s*"(https://[^"]+)",\s*\.hash\s*=\s*"([^"]+)"', text):
        pairs[m.group(1)] = m.group(2)
todo = [(u, h) for u, h in pairs.items() if not os.path.isdir(os.path.join(pkg, h))]
def fetch(item):
    url, h = item
    path = os.path.join(downloads, os.path.basename(url))
    if not os.path.exists(path):
        subprocess.run(["curl", "-sSfL", "--max-time", "300", "-o", path, url], check=True)
    tmp = tempfile.mkdtemp(dir=downloads)
    subprocess.run(["tar", "-xf", path, "-C", tmp], check=True)
    entries = os.listdir(tmp)
    root = os.path.join(tmp, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(tmp, entries[0])) else tmp
    shutil.move(root, os.path.join(pkg, h))
    shutil.rmtree(tmp, ignore_errors=True)
with ThreadPoolExecutor(8) as ex:
    list(ex.map(fetch, todo))
print(f"  {len(todo)} unpacked, {len(pairs) - len(todo)} already present")
PY

echo "Building libghostty (this takes a few minutes)"
"$VENDOR/zig/zig" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false

rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/ghostty-resources"
cp -R macos/GhosttyKit.xcframework "$VENDOR/GhosttyKit.xcframework"
mkdir -p "$VENDOR/ghostty-resources"
cp -R zig-out/share/ghostty "$VENDOR/ghostty-resources/ghostty"
cp -R zig-out/share/terminfo "$VENDOR/ghostty-resources/terminfo"
echo "Done: vendor/GhosttyKit.xcframework"
