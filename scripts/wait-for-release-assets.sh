#!/bin/bash
# Poll a GitHub release until specific assets are published, instead of
# assuming they already exist.
#
#   scripts/wait-for-release-assets.sh <owner/repo> <tag> <asset>...
#
# Why this exists: aur-test and scoop-test fetch assets that release.yml is
# still building when both are triggered by the same tag push. They cannot
# pass on that push -- only on a manual re-run once release.yml finishes.
# This polls instead of failing on the first miss.
#
# Exit 0: all requested assets are present on the release <tag>.
# Exit 1: timed out (WAIT_TIMEOUT_SECONDS, default 900s / 15 min), and the
#         message distinguishes two different problems that need different
#         action:
#           - the release was never observed at all -- expected if this is
#             running against a manifest-bump commit made BEFORE the git tag
#             was pushed; the release simply doesn't exist yet.
#           - the release exists but is still missing a specific asset by
#             the deadline -- a real defect in release.yml (wrong filename,
#             upload step broken/removed). The asset name is printed.
#
# Uses `gh api` when authenticated (what Actions provides via GITHUB_TOKEN);
# falls back to an unauthenticated curl against the public REST API
# otherwise, so this also runs standalone from a dev machine for testing.
set -euo pipefail

REPO="${1:?usage: wait-for-release-assets.sh <owner/repo> <tag> <asset>...}"
TAG="${2:?usage: wait-for-release-assets.sh <owner/repo> <tag> <asset>...}"
shift 2
ASSETS=("$@")
if [ "${#ASSETS[@]}" -eq 0 ]; then
    echo "usage: wait-for-release-assets.sh <owner/repo> <tag> <asset>..." >&2
    exit 2
fi

TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"   # ~15 min ceiling: v2.9.0's
                                                  # release.yml run took a
                                                  # few minutes end to end.
INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-30}"

fetch_release_json() {
    if command -v gh >/dev/null 2>&1 && { [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; }; then
        gh api "repos/$REPO/releases/tags/$TAG" 2>/dev/null || true
    else
        curl --fail --silent --show-error --connect-timeout 15 \
             "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null || true
    fi
}

asset_names_from_json() {
    # Tolerant extraction of .assets[].name -- avoids a hard `jq` dependency
    # (this script also runs unauthenticated/standalone) for a simple exact
    # filename match, which is all that's needed here.
    grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$1" | sed -E 's/.*"([^"]*)"$/\1/'
}

start_ts=$(date +%s)
attempt=0
release_ever_seen=false
missing=("${ASSETS[@]}")

while :; do
    attempt=$((attempt + 1))
    elapsed=$(( $(date +%s) - start_ts ))

    json="$(fetch_release_json)"

    if [ -n "$json" ]; then
        release_ever_seen=true
        have_names="$(asset_names_from_json "$json")"
        missing=()
        for a in "${ASSETS[@]}"; do
            if ! grep -qxF "$a" <<<"$have_names"; then
                missing+=("$a")
            fi
        done

        if [ "${#missing[@]}" -eq 0 ]; then
            echo "[attempt $attempt, ${elapsed}s] OK: release $TAG has all ${#ASSETS[@]} required asset(s)."
            exit 0
        fi
        echo "[attempt $attempt, ${elapsed}s] release $TAG exists but is still missing: ${missing[*]}"
    else
        echo "[attempt $attempt, ${elapsed}s] release $TAG not found yet."
    fi

    if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
        break
    fi
    sleep "$INTERVAL_SECONDS"
done

echo
if [ "$release_ever_seen" = false ]; then
    echo "::error::Timed out after ${TIMEOUT_SECONDS}s -- release $TAG was never observed."
    echo "This is EXPECTED if this run was triggered by a manifest bump commit made"
    echo "BEFORE 'git tag $TAG' was pushed: the release doesn't exist yet. It will"
    echo "resolve once the tag is pushed and release.yml publishes it; re-run this"
    echo "workflow (or wait for the tag-push trigger) at that point."
    exit 1
else
    echo "::error::Timed out after ${TIMEOUT_SECONDS}s -- release $TAG is published but never gained: ${missing[*]}"
    echo "This looks like a real defect in .github/workflows/release.yml: the asset"
    echo "name changed, or its build/upload step is broken or missing."
    exit 1
fi
