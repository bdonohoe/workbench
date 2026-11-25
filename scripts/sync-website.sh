#!/bin/zsh
# Copies the website (website/) into a clone of bench-releases, whose
# GitHub Pages serves it at https://workbenchapp.dev/
#
#   scripts/sync-website.sh <path to a bench-releases clone>
#
# Only the site's pages and its assets/ folder are copied. Everything else
# in bench-releases (appcast.xml, the release-note images/, README.md, the
# .md copies of the privacy policy and support page) is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=${1:?Pass the path to a bench-releases clone}
[[ -f "$DEST/appcast.xml" ]] || { echo "$DEST doesn't look like bench-releases (no appcast.xml)." >&2; exit 1; }

cp website/*.html "$DEST/"
rsync -a --delete website/assets/ "$DEST/assets/"
