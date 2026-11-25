#!/bin/zsh
# Puts the website live without shipping a new version of the app:
#
#   make website
#
# Copies website/ into this repo's gh-pages branch and pushes it, and GitHub Pages
# serves it a minute or so later. Publish from main, so the live site
# matches what's merged. (make publish does the same copy with each
# release.)
set -euo pipefail
cd "$(dirname "$0")/.."

SITE_REPO=mattbirchler/workbench
SITE_BRANCH=gh-pages
WORK=build/website-publish

fail() { echo "$1" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || fail "Publish the website from main."
[[ -z "$(git status --porcelain website)" ]] || fail "Commit your website changes first."

rm -rf "$WORK" && mkdir -p "$WORK"
gh repo clone "$SITE_REPO" "$WORK/site" -- -q --branch "$SITE_BRANCH" --single-branch
scripts/sync-website.sh "$WORK/site"

git -C "$WORK/site" add -A
if git -C "$WORK/site" diff --cached --quiet; then
    echo "The live website is already up to date."
    exit 0
fi
git -C "$WORK/site" commit -q -m "Website from Bench $(git rev-parse --short HEAD)"
git -C "$WORK/site" push -q origin "$SITE_BRANCH"
echo "Pushed the website. It's live at https://workbenchapp.dev/ in a minute or so."
