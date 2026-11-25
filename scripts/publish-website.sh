#!/bin/zsh
# Puts the website live without shipping a new version of the app:
#
#   make website
#
# Copies website/ into bench-releases and pushes it, and GitHub Pages
# serves it a minute or so later. Publish from main, so the live site
# matches what's merged. (make publish does the same copy with each
# release.)
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_REPO=mattbirchler/bench-releases
WORK=build/website-publish

fail() { echo "$1" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || fail "Publish the website from main."
[[ -z "$(git status --porcelain website)" ]] || fail "Commit your website changes first."

rm -rf "$WORK" && mkdir -p "$WORK"
gh repo clone "$RELEASES_REPO" "$WORK/releases" -- -q
scripts/sync-website.sh "$WORK/releases"

git -C "$WORK/releases" add -A
if git -C "$WORK/releases" diff --cached --quiet; then
    echo "The live website is already up to date."
    exit 0
fi
git -C "$WORK/releases" commit -q -m "Website from Bench $(git rev-parse --short HEAD)"
git -C "$WORK/releases" push -q origin main
echo "Pushed the website. It's live at https://workbenchapp.dev/ in a minute or so."
