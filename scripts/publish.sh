#!/bin/zsh
# Ships a new version of Bench to every Mac that runs it:
#
#   make publish NOTES=notes.md [VERSION=0.3]
#
# 1. Runs BenchKit's tests, and stops here if any fail.
# 2. Bumps the build number (and the version, if given) in a commit
#    named "<version> build <number>".
# 3. Builds, signs with Developer ID, and notarizes (scripts/notarize.sh).
# 4. Uploads the build's debug symbols to PostHog, so its crash reports
#    are readable (scripts/upload-dsyms.sh). SKIP_DSYMS=1 skips this if
#    PostHog is down; upload them afterwards with `make dsyms`.
# 5. Signs the zip with Bench's Sparkle key, puts it in a GitHub release
#    on mattbirchler/bench-releases with the notes, and adds it to the
#    update feed there, along with the latest website (website/). The
#    release also carries Workbench.dmg, the disk image new people
#    download; releases/latest/download/Workbench.dmg always points at the
#    newest one.
# 6. Pushes the version commit and a tag to Bench's main branch.
#
# NOTES is a short Markdown file written for people: what changed and why
# they'd care. It shows in Sparkle's update window and on the release page.
#
# DRY_RUN=1 does everything except the commit, the upload, and the pushes,
# and leaves the feed it would publish in build/publish/.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASES_REPO=mattbirchler/bench-releases
FEED_URL=https://workbenchapp.dev/appcast.xml
WORK=build/publish
DRY_RUN=${DRY_RUN:-0}

fail() { echo "$1" >&2; exit 1; }

[[ -n "${NOTES:-}" && -s "$NOTES" ]] || fail "Write release notes for people first, then run: make publish NOTES=path/to/notes.md"
NOTES=$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")

if [[ "$DRY_RUN" != 1 ]]; then
    [[ "$(git branch --show-current)" == main ]] || fail "Publish from main."
    [[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in step with origin/main."
fi

rm -rf "$WORK" && mkdir -p "$WORK"

# Updates install themselves on idle Macs, so a bad release spreads with
# nobody watching. Nothing is committed or built until these pass.
echo "Running tests"
if ! (cd BenchKit && swift test) > "$WORK/tests.log" 2>&1; then
    tail -40 "$WORK/tests.log" >&2
    fail "Tests failed, so nothing was published. Full output: $WORK/tests.log"
fi

scripts/sparkle-tools.sh >/dev/null

# The next build number is one past both this repo and the live feed, so
# Sparkle always sees it as newer.
gh repo clone "$RELEASES_REPO" "$WORK/releases" -- -q
CURRENT=$(python3 scripts/version.py get)
CURRENT_VERSION=${CURRENT% *}
CURRENT_BUILD=${CURRENT#* }
FEED_BUILD=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$WORK/releases/appcast.xml" | grep -o '[0-9]*' | sort -n | tail -1 || true)
BUILD=$(( (CURRENT_BUILD > ${FEED_BUILD:-0} ? CURRENT_BUILD : ${FEED_BUILD:-0}) + 1 ))
VERSION=${VERSION:-$CURRENT_VERSION}
TAG="v$VERSION-$BUILD"
echo "Publishing Workbench $VERSION build $BUILD"

cp project.yml "$WORK/project.yml.before"
python3 scripts/version.py set "$VERSION" "$BUILD"
# A dry run puts the version back the way it was.
restore() { [[ "$DRY_RUN" == 1 ]] && cp "$WORK/project.yml.before" project.yml || true; }
trap restore EXIT
if [[ "$DRY_RUN" != 1 ]]; then
    git commit -q -am "$VERSION build $BUILD"
    echo "Committed \"$VERSION build $BUILD\" (not pushed until the release is up)"
fi

ZIP=$(scripts/notarize.sh | tail -1)
[[ -f "$ZIP" ]] || fail "No notarized zip."
DMG="${ZIP%.zip}.dmg"
[[ -f "$DMG" ]] || fail "No notarized disk image."
# One fixed name, so a link to the latest release's Workbench.dmg works.
cp "$DMG" "$WORK/Workbench.dmg"

# Before anything goes public, so a failed upload stops here.
if [[ "${SKIP_DSYMS:-0}" != 1 ]]; then
    DRY_RUN=$DRY_RUN scripts/upload-dsyms.sh build/notarized/Bench.xcarchive/dSYMs me.birchtree.Bench \
        || fail "Nothing was published. Fix the upload, or run again with SKIP_DSYMS=1 and then make dsyms."
fi

# Signature and size for Sparkle, like: sparkle:edSignature="…" length="…"
SIGNATURE=$(vendor/sparkle/bin/sign_update --account bench "$ZIP")
[[ "$SIGNATURE" == *edSignature* ]] || fail "Couldn't sign the update: $SIGNATURE"
ZIP_URL="https://github.com/$RELEASES_REPO/releases/download/$TAG/$(basename "$ZIP")"

python3 scripts/appcast.py "$WORK/releases/appcast.xml" "$VERSION" "$BUILD" "$ZIP_URL" "$SIGNATURE" "$NOTES"

if [[ "$DRY_RUN" == 1 ]]; then
    cp "$WORK/releases/appcast.xml" "$WORK/appcast.xml"
    echo "Dry run done. Zip: $ZIP  Disk image: $WORK/Workbench.dmg  Feed: $WORK/appcast.xml"
    exit 0
fi

# The zip goes up before the feed points at it.
gh release create "$TAG" "$ZIP" "$WORK/Workbench.dmg" --repo "$RELEASES_REPO" --title "Workbench $VERSION (build $BUILD)" --notes-file "$NOTES"
# The website goes up with each release, so the live site matches main.
scripts/sync-website.sh "$WORK/releases"
git -C "$WORK/releases" add -A
git -C "$WORK/releases" commit -q -m "Workbench $VERSION build $BUILD"
git -C "$WORK/releases" push -q origin main

git tag "$TAG"
git push -q origin main "$TAG"
echo "Published Workbench $VERSION build $BUILD. Macs pick it up within four hours, or right away with Check for Updates."
