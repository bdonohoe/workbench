#!/bin/zsh
# Copies the website (website/) into a checkout of this repo's gh-pages
# branch, which GitHub Pages serves at https://workbenchapp.dev/
#
#   scripts/sync-website.sh <path to a gh-pages checkout>
#
# Only the site's pages and its assets/ folder are copied. Everything else
# on gh-pages (appcast.xml, the release-note images/, CNAME, .nojekyll, the
# .md copies of the privacy policy and support page) is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=${1:?Pass the path to a gh-pages checkout}
[[ -f "$DEST/appcast.xml" ]] || { echo "$DEST doesn't look like the gh-pages branch (no appcast.xml)." >&2; exit 1; }

cp website/*.html "$DEST/"
rsync -a --delete website/assets/ "$DEST/assets/"
