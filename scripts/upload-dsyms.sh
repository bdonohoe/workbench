#!/bin/zsh
# Uploads a build's debug symbols (dSYMs) to PostHog, so crash reports
# from that build show function names and line numbers instead of bare
# memory addresses:
#
#   scripts/upload-dsyms.sh <folder of .dSYM bundles> <bundle id>
#
# The bundle id is the release name PostHog matches crashes against (the
# SDK sends it with every event). The version and build number are read
# from the dSYMs themselves.
#
# Upload before the build reaches anyone. A crash that arrives before its
# symbols stays unreadable, even after they're uploaded.
#
# Signs in with `posthog-cli login` (a personal API key with the
# error_tracking:write scope), or POSTHOG_CLI_API_KEY and
# POSTHOG_CLI_PROJECT_ID in the environment. DRY_RUN=1 checks the
# folder without uploading.
set -euo pipefail

DSYMS=${1:?Pass the folder of .dSYM bundles}
RELEASE=${2:?Pass the bundle id}

fail() { echo "$1" >&2; exit 1; }

command -v posthog-cli >/dev/null || fail "posthog-cli isn't installed: npm install -g @posthog/cli"
[[ -d "$DSYMS" ]] || fail "No dSYMs folder at $DSYMS."
MAIN=$(cd "$DSYMS" && ls -d *.app.dSYM 2>/dev/null | head -1)
[[ -n "$MAIN" ]] || fail "No app dSYM in $DSYMS."

DRY=()
[[ "${DRY_RUN:-0}" == 1 ]] && DRY=(--dry-run)

echo "Uploading debug symbols for $RELEASE to PostHog" >&2
if ! OUTPUT=$(posthog-cli "${DRY[@]}" dsym upload --directory "$DSYMS" --main-dsym "$MAIN" \
        --release-name "$RELEASE" --skip-on-conflict 2>&1); then
    tail -5 <<< "$OUTPUT" >&2
    fail "Couldn't upload debug symbols. If it's a sign-in or scope error, run: posthog-cli login"
fi
