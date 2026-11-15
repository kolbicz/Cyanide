#!/usr/bin/env bash
# Generate Cyanide/Changelog.plist from the last N release tags so the Settings
# "What's New" section can render an in-app changelog without any manual upkeep.
#
# Output is an array of dicts, each:
#   <dict>
#     <key>version</key><string>1.0.31</string>
#     <key>date</key><string>2026-05-15</string>
#     <key>changes</key>
#     <array>
#       <string>commit subject 1</string>
#       <string>commit subject 2</string>
#     </array>
#   </dict>
#
# Pulled from `git tag --sort=-v:refname` matching `vN.N.N`, with each tag's
# commits taken as `git log <prev_tag>..<tag>` in chronological order. Pure
# "Bump to X.Y.Z" / "Bump version to X.Y.Z" subjects are filtered as noise.
#
# Pending-release mode (used by scripts/release.sh): when CHANGELOG_PENDING_VERSION
# is set and that tag doesn't exist yet, a synthetic top entry is prepended so
# the in-progress IPA carries its own version at the top of "What's New".
# Inputs (all env vars):
#   CHANGELOG_PENDING_VERSION  e.g. "1.0.32"
#   CHANGELOG_PENDING_BASE     e.g. "v1.0.31" (commits in BASE..HEAD become the entry)
#   CHANGELOG_PENDING_MSG      optional extra subject appended after the BASE..HEAD log
#                              (the about-to-be-made commit message). May be multi-line —
#                              each non-empty line becomes its own bullet. "Bump …" lines
#                              are filtered the same way as real commits.
#   CHANGELOG_PENDING_EXTRA    newline-separated additional bullets, emitted BEFORE
#                              PENDING_MSG. Used by release.sh to inject heuristically
#                              derived bullets (new tweak files, new packages) so a
#                              one-line MSG still produces a multi-bullet entry.
#   CHANGELOG_PENDING_SKIP_LOG set to 1 to skip BASE..HEAD commit subjects for
#                              the pending entry. Used when RELEASE_NOTES.md or
#                              auto-derived bullets are the intended source.
#   CHANGELOG_RELEASE_NOTES_FILE defaults to RELEASE_NOTES.md. Checked bullets
#                              under "### vX.Y.Z" in its Released section
#                              replace commit subjects for matching tags.
#
# Invoked from scripts/release.sh before xcodebuild. The output is gitignored —
# regenerated each release, never committed.

set -euo pipefail

cd "$(dirname "$0")/.."

. "$PWD/scripts/release-notes.sh"

OUT="Cyanide/Changelog.plist"
COUNT="${CHANGELOG_COUNT:-5}"
PENDING_VERSION="${CHANGELOG_PENDING_VERSION:-}"
PENDING_BASE="${CHANGELOG_PENDING_BASE:-}"
PENDING_MSG="${CHANGELOG_PENDING_MSG:-}"
PENDING_EXTRA="${CHANGELOG_PENDING_EXTRA:-}"
PENDING_SKIP_LOG="${CHANGELOG_PENDING_SKIP_LOG:-0}"
CHANGELOG_NOTES_OVERRIDE="${CHANGELOG_RELEASE_NOTES_FILE:-}"

xml_escape() {
    # &  <  >  only — strings inside <string> tags don't need quote escaping.
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

is_noisy_bump() {
    # Filter pure version-bump subjects (no descriptive suffix). Both shapes
    # the release script auto-generates are matched.
    printf '%s' "$1" | grep -Eq '^Bump (to|version to) [0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'
}

emit_change_line() {
    local subj="$1"
    [ -z "$subj" ] && return
    if is_noisy_bump "$subj"; then return; fi
    local escaped
    # What's New shows plain text: drop the Markdown the versioned
    # release-notes drafts use -- links become their text ("[#18](url)" ->
    # "#18"), bold and code markers go.
    subj="$(printf '%s' "$subj" | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/\*\*//g; s/`//g')"
    escaped="$(printf '%s' "$subj" | xml_escape)"
    echo "      <string>${escaped}</string>"
}

released_notes_for_version() {
    local version="$1"
    local notes_file
    # The override names the PENDING release's notes; released versions keep
    # their own curated files (or RELEASE_NOTES.md history).
    notes_file="$(release_notes_file_for_version "$version" "")"
    release_notes_bullets_for_version "$version" "$notes_file"
}

# Pull the most-recent N release tags. If git isn't usable here (e.g. a
# shallow checkout with no tags) just emit an empty array so the in-app
# section silently hides itself.
if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    cat > "$OUT" <<'EMPTY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array/>
</plist>
EMPTY
    echo "==> wrote $OUT (no git; empty changelog)"
    exit 0
fi

# When a pending version is supplied and its tag doesn't yet exist, the
# synthetic top entry consumes one of the COUNT slots so we only pull
# (COUNT - 1) prior tags. Plus one extra tag as a lower bound for the oldest
# displayed real version (otherwise its range would dump full history).
HAVE_PENDING=0
if [ -n "$PENDING_VERSION" ] && ! git rev-parse -q --verify "refs/tags/v${PENDING_VERSION}" >/dev/null; then
    HAVE_PENDING=1
fi

TAG_SLOTS="$COUNT"
if [ "$HAVE_PENDING" = "1" ]; then
    TAG_SLOTS=$((COUNT - 1))
fi

EXTRA=$((TAG_SLOTS + 1))
# (no mapfile: macOS ships bash 3.2, where it doesn't exist and the whole
# changelog silently went missing from every IPA)
TAGS=()
while IFS= read -r tag; do
    [ -n "$tag" ] && TAGS+=("$tag")
done < <(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n "$EXTRA")
DISPLAY=${#TAGS[@]}
if [ "$DISPLAY" -gt "$TAG_SLOTS" ]; then DISPLAY="$TAG_SLOTS"; fi

TMP="$(mktemp -t cyanide-changelog)"
trap 'rm -f "$TMP"' EXIT

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<array>'

    # Synthetic top entry for the in-progress release. Commits in BASE..HEAD
    # (already on this branch) plus PENDING_MSG (the about-to-be-made release
    # commit's subject, if provided) become the entry's changes list. The date
    # is today — the real tag isn't created until later in release.sh.
    if [ "$HAVE_PENDING" = "1" ]; then
        TODAY="$(date '+%Y-%m-%d')"
        if [ -z "$PENDING_EXTRA" ]; then
            PENDING_NOTES_FILE="$(release_notes_file_for_version "$PENDING_VERSION" "$CHANGELOG_NOTES_OVERRIDE")"
            PENDING_EXTRA="$(release_notes_bullets_for_version "$PENDING_VERSION" "$PENDING_NOTES_FILE")"
        fi
        echo "  <dict>"
        echo "    <key>version</key><string>$(printf '%s' "$PENDING_VERSION" | xml_escape)</string>"
        echo "    <key>date</key><string>${TODAY}</string>"
        echo "    <key>changes</key>"
        echo "    <array>"
        if [ "$PENDING_SKIP_LOG" != "1" ] &&
           [ -n "$PENDING_BASE" ] &&
           git rev-parse -q --verify "refs/tags/${PENDING_BASE}" >/dev/null; then
            while IFS= read -r SUBJ; do
                emit_change_line "$SUBJ"
            done < <(git log --reverse --no-merges --pretty=tformat:%s "${PENDING_BASE}..HEAD" 2>/dev/null)
        fi
        # Auto-derived bullets (from release.sh's dirty-state summarizer)
        # come before the user's MSG so the granular detail leads, with the
        # one-line summary trailing as the wrap-up.
        if [ -n "$PENDING_EXTRA" ]; then
            while IFS= read -r SUBJ; do
                emit_change_line "$SUBJ"
            done <<< "$PENDING_EXTRA"
        fi
        if [ -n "$PENDING_MSG" ]; then
            while IFS= read -r SUBJ; do
                emit_change_line "$SUBJ"
            done <<< "$PENDING_MSG"
        fi
        echo "    </array>"
        echo "  </dict>"
    fi

    for ((i = 0; i < DISPLAY; i++)); do
        TAG="${TAGS[$i]}"
        VERSION="${TAG#v}"
        DATE="$(git log -1 --format=%cs "$TAG")"

        NEXT=$((i + 1))
        if [ "$NEXT" -lt "${#TAGS[@]}" ]; then
            PREV="${TAGS[$NEXT]}"
            RANGE="${PREV}..${TAG}"
        else
            # Oldest of the top-N with no older tag to bound against — show
            # only the tag's tip commit so we don't dump unrelated history.
            RANGE="${TAG}~1..${TAG}"
        fi

        echo "  <dict>"
        echo "    <key>version</key><string>$(printf '%s' "$VERSION" | xml_escape)</string>"
        echo "    <key>date</key><string>$(printf '%s' "$DATE" | xml_escape)</string>"
        echo "    <key>changes</key>"
        echo "    <array>"
        RELEASED_NOTES="$(released_notes_for_version "$VERSION")"
        if [ -n "$RELEASED_NOTES" ]; then
            while IFS= read -r SUBJ; do
                emit_change_line "$SUBJ"
            done <<< "$RELEASED_NOTES"
        else
            # %s gives commit subject only. --reverse so oldest-first within
            # the tag — reads naturally as "we added X, then fixed Y, then
            # shipped". tformat (trailing newline) so single-commit ranges
            # aren't dropped by `read` hitting EOF before seeing a newline.
            # Process substitution keeps the loop in the parent shell, so a
            # single-line `read` failure doesn't trigger pipefail mid-build.
            while IFS= read -r SUBJ; do
                emit_change_line "$SUBJ"
            done < <(git log --reverse --no-merges --pretty=tformat:%s "$RANGE" 2>/dev/null)
        fi
        echo "    </array>"
        echo "  </dict>"
    done

    echo '</array>'
    echo '</plist>'
} > "$TMP"

mv "$TMP" "$OUT"
trap - EXIT

TOTAL="$DISPLAY"
if [ "$HAVE_PENDING" = "1" ]; then
    TOTAL=$((TOTAL + 1))
    echo "==> wrote $OUT ($TOTAL versions; pending v${PENDING_VERSION} + ${DISPLAY} tags)"
else
    echo "==> wrote $OUT ($TOTAL versions)"
fi
