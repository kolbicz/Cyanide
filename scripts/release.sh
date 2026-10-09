#!/usr/bin/env bash
# Build, optionally commit + push, and publish the resulting IPA as a
# GitHub Release.
#
# Usage:
#   ./scripts/release.sh                                # auto-bump patch, auto-commit, push, build, release
#   ./scripts/release.sh "commit message"               # auto-bump patch + commit msg, push, build, release
#   ./scripts/release.sh "commit message" "release notes"   # custom notes for the GH Release
#   NOTES_FILE=NOTES.md ./scripts/release.sh "..."      # read notes from a file
#   BUMP=minor ./scripts/release.sh "..."               # bump minor (1.0.14 -> 1.1.0)
#   BUMP=major ./scripts/release.sh "..."               # bump major (1.0.14 -> 2.0.0)
#   BUMP=none  ./scripts/release.sh "..."               # leave MARKETING_VERSION as-is
#   VERSION=1.5.3 ./scripts/release.sh "..."            # set an explicit version
#   TAG=v1.2.3 ./scripts/release.sh "..."               # override tag (defaults to v${VERSION})
#
# The release script owns versioning end-to-end: it edits MARKETING_VERSION and
# CURRENT_PROJECT_VERSION in the xcodeproj, commits the bump (along with any
# other working-tree changes), pushes, builds, and tags. The compiled
# CFBundleShortVersionString, CFBundleVersion, the IPA filename, and the GitHub
# release tag all flow from the bumped version.
#
# Release notes default to auto-derived dirty-state bullets when possible,
# falling back to the commit subject when the script cannot infer good detail.
# Pass a second arg, NOTES, or NOTES_FILE to override the generated notes.
#
# Requires: git, gh (authenticated), xcodebuild.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v gh >/dev/null; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh not authenticated (gh auth login)" >&2
    exit 1
fi

MSG="${1:-}"
NOTES_ARG="${2:-}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PBXPROJ="Cyanide.xcodeproj/project.pbxproj"
RELEASE_NOTES_FILE="RELEASE_NOTES.md"

# --- versioning -------------------------------------------------------------

current_marketing_version() {
    grep -m1 "MARKETING_VERSION" "$PBXPROJ" \
        | sed -E 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/'
}

set_marketing_version() {
    local new="$1"
    # macOS sed needs the empty-string -i argument.
    sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${new};/g" "$PBXPROJ"
}

current_build_version() {
    grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" \
        | sed -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/'
}

set_build_version() {
    local new="$1"
    # macOS sed needs the empty-string -i argument.
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${new};/g" "$PBXPROJ"
}

build_version_for_marketing_version() {
    local version="$1"
    local major minor patch
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    patch=$(echo "$version" | cut -d. -f3)
    [ -z "$major" ] && major=0
    [ -z "$minor" ] && minor=0
    [ -z "$patch" ] && patch=0
    echo $((major * 1000000 + minor * 1000 + patch))
}

compute_new_version() {
    local current="$1"
    if [ -n "${VERSION:-}" ]; then
        echo "$VERSION"
        return
    fi
    local bump="${BUMP:-patch}"
    if [ "$bump" = "none" ]; then
        echo "$current"
        return
    fi
    local major minor patch
    major=$(echo "$current" | cut -d. -f1)
    minor=$(echo "$current" | cut -d. -f2)
    patch=$(echo "$current" | cut -d. -f3)
    [ -z "$minor" ] && minor=0
    [ -z "$patch" ] && patch=0
    case "$bump" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
        *)
            echo "error: unknown BUMP=$bump (use patch|minor|major|none)" >&2
            exit 1
            ;;
    esac
    echo "${major}.${minor}.${patch}"
}

parent_tree_dirty() {
    if ! git diff-index --quiet HEAD --; then
        return 0
    fi
    if [ -n "$(git ls-files --others --exclude-standard)" ]; then
        return 0
    fi
    return 1
}

submodule_paths() {
    git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
        | awk '{print $2}'
}

submodule_is_dirty() {
    local path="$1"
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    if ! git -C "$path" diff-index --quiet HEAD --; then
        return 0
    fi
    if [ -n "$(git -C "$path" ls-files --others --exclude-standard)" ]; then
        return 0
    fi
    return 1
}

dirty_submodule_paths() {
    local path
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if submodule_is_dirty "$path"; then
            printf '%s\n' "$path"
        fi
    done < <(submodule_paths)
}

pending_release_note_bullets() {
    [ -f "$RELEASE_NOTES_FILE" ] || return 0
    awk '
        /^##[[:space:]]+Pending[[:space:]]*$/ { pending = 1; next }
        pending && /^##[[:space:]]+/ { exit }
        pending { print }
    ' "$RELEASE_NOTES_FILE" \
        | sed -nE 's/^-+[[:space:]]+\[[[:space:]]\][[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p'
}

combine_release_bullets() {
    printf '%s\n%s\n' "${1:-}" "${2:-}" \
        | sed -e '/^[[:space:]]*$/d' \
        | awk '!seen[tolower($0)]++'
}

mark_pending_release_notes_released() {
    local version="$1"
    local release_date="$2"
    [ -f "$RELEASE_NOTES_FILE" ] || return 0
    python3 - "$RELEASE_NOTES_FILE" "$version" "$release_date" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
release_date = sys.argv[3]
lines = path.read_text().splitlines()

out = []
pending = []
in_pending = False
for line in lines:
    if re.match(r"^##\s+Pending\s*$", line):
        in_pending = True
        out.append(line)
        continue
    if in_pending and re.match(r"^##\s+", line):
        in_pending = False
    if in_pending:
        match = re.match(r"^-\s+\[\s\]\s+(.+?)\s*$", line)
        if match:
            pending.append(match.group(1))
            continue
    out.append(line)

if not pending:
    sys.exit(0)

released_index = None
for i, line in enumerate(out):
    if re.match(r"^##\s+Released\s*$", line):
        released_index = i
        break

if released_index is None:
    if out and out[-1].strip():
        out.append("")
    out.extend(["## Released"])
    released_index = len(out) - 1

entry = [f"### v{version} - {release_date}", ""]
entry.extend(f"- [x] {bullet}" for bullet in pending)
entry.append("")

insert_at = released_index + 1
while insert_at < len(out) and out[insert_at].strip() == "":
    insert_at += 1

out = out[:released_index + 1] + [""] + entry + out[insert_at:]
path.write_text("\n".join(out).rstrip() + "\n")
PY
}

commit_dirty_submodules() {
    local paths="$1"
    local path branch
    [ -z "$paths" ] && return 0
    if [ -z "$MSG" ]; then
        echo "error: dirty submodule changes require a commit message." >&2
        echo "       pass a message as the first arg, or commit/stash submodule changes." >&2
        exit 1
    fi

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        submodule_is_dirty "$path" || continue

        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)
        if [ "$branch" = "HEAD" ]; then
            echo "error: submodule $path is on a detached HEAD; cannot push dirty changes safely." >&2
            exit 1
        fi

        echo "==> committing dirty submodule $path on $branch"
        git -C "$path" add -A
        if ! git -C "$path" diff --cached --quiet; then
            git -C "$path" commit -m "$MSG"
        fi

        echo "==> pushing submodule $path:$branch"
        git -C "$path" push origin "$branch"
    done <<< "$paths"
}

# Snapshot dirty state *before* the bump so we can tell apart bump-only commits
# (auto-message OK) vs. mixed commits (user-supplied message required).
TREE_WAS_DIRTY=0
DIRTY_SUBMODULES_BEFORE="$(dirty_submodule_paths)"
DIRTY_FILES_BEFORE="$(
    {
        git diff --name-only --diff-filter=ACMRT HEAD -- 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u
)"
if parent_tree_dirty || [ -n "$DIRTY_SUBMODULES_BEFORE" ]; then
    TREE_WAS_DIRTY=1
fi
if [ "$TREE_WAS_DIRTY" = "1" ] && [ -z "$MSG" ]; then
    echo "error: working tree has changes but no commit message was provided." >&2
    echo "       pass a message as the first arg, or stash changes." >&2
    exit 1
fi

CURRENT_VERSION=$(current_marketing_version)
if [ -z "$CURRENT_VERSION" ]; then
    echo "error: could not parse MARKETING_VERSION from $PBXPROJ" >&2
    exit 1
fi
NEW_VERSION=$(compute_new_version "$CURRENT_VERSION")
CURRENT_BUILD_VERSION=$(current_build_version)
if [ -z "$CURRENT_BUILD_VERSION" ]; then
    echo "error: could not parse CURRENT_PROJECT_VERSION from $PBXPROJ" >&2
    exit 1
fi
NEW_BUILD_VERSION=$(build_version_for_marketing_version "$NEW_VERSION")

BUMPED=0
if [ "$NEW_VERSION" != "$CURRENT_VERSION" ]; then
    echo "==> bumping MARKETING_VERSION: $CURRENT_VERSION -> $NEW_VERSION"
    set_marketing_version "$NEW_VERSION"
    BUMPED=1
else
    echo "==> MARKETING_VERSION unchanged at $CURRENT_VERSION"
fi
if [ "$NEW_BUILD_VERSION" != "$CURRENT_BUILD_VERSION" ]; then
    echo "==> bumping CURRENT_PROJECT_VERSION: $CURRENT_BUILD_VERSION -> $NEW_BUILD_VERSION"
    set_build_version "$NEW_BUILD_VERSION"
    BUMPED=1
else
    echo "==> CURRENT_PROJECT_VERSION unchanged at $CURRENT_BUILD_VERSION"
fi

# 1a. Summarize the dirty working tree into extra "What's New" bullets so a
#     one-line MSG that bundles many changes still produces a multi-bullet
#     in-app changelog. Heuristics only — fed to gen-changelog.sh and to the
#     GitHub Release notes default. Override with RELEASE_NO_AUTO_BULLETS=1.
#
#     Rules:
#       - Untracked Cyanide/tweaks/<name>.m       → "Add <Pretty Name> tweak"
#       - Added `name:@"X"` line in PackageCatalog → "Add X package"
#     Bullets whose key already appears in MSG (case-insensitive substring)
#     are dropped so we don't repeat the human's wording.
compute_extra_bullets() {
    local msg_lower out changed_files base pretty key_lower f name path sub_files
    msg_lower=$(printf '%s' "$MSG" | tr '[:upper:]' '[:lower:]')
    out=""
    changed_files="$DIRTY_FILES_BEFORE"

    add_bullet() {
        local bullet="$1"
        local key="${2:-$1}"
        local key_lower out_lower
        key_lower=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
        if [ -n "$msg_lower" ] && printf '%s' "$msg_lower" | grep -Fq "$key_lower"; then
            return
        fi
        out_lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
        if printf '%s' "$out_lower" | grep -Fq "$key_lower"; then
            return
        fi
        out+="$bullet"$'\n'
    }

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        add_bullet "Update $(basename "$path") submodule" "$(basename "$path") submodule"
    done <<< "$DIRTY_SUBMODULES_BEFORE"

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        base=$(basename "$f" .m)
        case "$base" in
            darksword_layout)  pretty="Home Layout Extras" ;;
            darksword_ota)     pretty="OTA Disabler" ;;
            darksword_tweaks)  pretty="DarkSword tweaks" ;;
            killallapps)       continue ;;     # disabled in UI; don't advertise
            *)                 pretty="$base" ;;
        esac
        add_bullet "Add ${pretty} tweak" "$pretty"
    done < <(git ls-files --others --exclude-standard 2>/dev/null \
             | grep -E '^Cyanide/tweaks/.*\.m$' || true)

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        add_bullet "Add ${name} package" "$name"
    done < <(git diff --no-color -- Cyanide/installer/PackageCatalog.m 2>/dev/null \
             | grep -E '^\+[[:space:]]+name:@"' \
             | sed -E 's/^\+[[:space:]]+name:@"([^"]+)".*/\1/' \
             | head -10)

    if printf '%s\n' "$changed_files" | grep -Eq '^Cyanide/installer/'; then
        add_bullet "Polish package installer queue, badges, and activity status UI" "installer"
    fi
    if printf '%s\n' "$changed_files" | grep -Fxq 'Cyanide/SettingsViewController.m'; then
        add_bullet "Track DarkSword toggle apply results independently in Settings" "settings"
    fi
    if printf '%s\n' "$changed_files" | grep -Fxq 'Cyanide/LogTextView.m'; then
        add_bullet "Tighten Log tab typography for dense verbose traces" "log view"
    fi
    if printf '%s\n' "$changed_files" | grep -Fxq 'Cyanide/tweaks/darksword_tweaks.m'; then
        add_bullet "Improve Disable App Library handling with an iOS 17 fallback path" "darksword"
    fi
    if printf '%s\n' "$changed_files" | grep -Fxq 'scripts/release.sh'; then
        add_bullet "Capture dirty submodule commits during release packaging" "release script"
    fi

    printf '%s' "$out"
}

MANUAL_RELEASE_BULLETS="$(pending_release_note_bullets)"
AUTO_RELEASE_BULLETS=""
if [ -z "$MANUAL_RELEASE_BULLETS" ] &&
   [ "$TREE_WAS_DIRTY" = "1" ] &&
   [ -z "${RELEASE_NO_AUTO_BULLETS:-}" ]; then
    AUTO_RELEASE_BULLETS="$(compute_extra_bullets)"
fi
EXTRA_BULLETS="$(combine_release_bullets "$MANUAL_RELEASE_BULLETS" "$AUTO_RELEASE_BULLETS")"
if [ -n "$EXTRA_BULLETS" ]; then
    echo "==> release-note bullets:"
    printf '%s' "$EXTRA_BULLETS" | sed 's/^/      - /'
fi

# 1b. Regenerate Cyanide/Changelog.plist with the new version as the top entry,
#     so the IPA we're about to build carries its own "What's New" content.
#     Commits between the last release tag and HEAD become the changes list,
#     plus the auto-derived EXTRA_BULLETS. If no richer bullets are available,
#     the about-to-be-made release commit subject is used as the fallback.
LAST_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
CHANGELOG_MSG="$MSG"
CHANGELOG_SKIP_LOG=0
if [ -n "$EXTRA_BULLETS" ] && [ -z "${RELEASE_INCLUDE_SUMMARY_IN_CHANGELOG:-}" ]; then
    CHANGELOG_MSG=""
    CHANGELOG_SKIP_LOG=1
fi
CHANGELOG_PENDING_VERSION="$NEW_VERSION" \
CHANGELOG_PENDING_BASE="$LAST_TAG" \
CHANGELOG_PENDING_MSG="$CHANGELOG_MSG" \
CHANGELOG_PENDING_EXTRA="$EXTRA_BULLETS" \
CHANGELOG_PENDING_SKIP_LOG="$CHANGELOG_SKIP_LOG" \
    ./scripts/gen-changelog.sh \
    || echo "==> changelog generation failed (continuing without it)"

# 1b. Build the IPA against the newly resolved MARKETING_VERSION and
#     CURRENT_PROJECT_VERSION. build.sh writes build/Cyanide-${VERSION}.ipa and
#     refreshes a build/Cyanide.ipa symlink. We build *before* committing so the
#     actual IPA size can be baked into source.json in the same commit.
# Release configuration, the same as ./build.sh -- what gets tested on device
# is what ships. scripts/build.sh on its own defaults to Debug (-O0, ~2x the
# code, slower), which would ship differently timed exploit/RemoteCall code
# than every tested build. Logs and backtrace symbols are the same in both
# (no #if DEBUG code; a plain build is not stripped). CONFIG=Debug overrides.
export CONFIG="${CONFIG:-Release}"
./scripts/build.sh

# Read bundle versions from the just-built app. CFBundleShortVersionString
# drives the IPA filename and tag; CFBundleVersion must advance too so iOS/Xcode
# never keeps a stale installed bundle around under the same internal build.
APP_PATH="$PWD/build/DerivedData/Build/Products/${CONFIG}-iphoneos/Cyanide.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from $APP_PATH/Info.plist" >&2
    exit 1
fi
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$BUNDLE_IDENTIFIER" ]; then
    echo "error: could not read CFBundleIdentifier from $APP_PATH/Info.plist" >&2
    exit 1
fi
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$BUILD_VERSION" ]; then
    echo "error: could not read CFBundleVersion from $APP_PATH/Info.plist" >&2
    exit 1
fi
if [ "$BUILD_VERSION" != "$NEW_BUILD_VERSION" ]; then
    echo "error: built CFBundleVersion=$BUILD_VERSION, expected $NEW_BUILD_VERSION" >&2
    exit 1
fi
echo "==> built bundle version: marketing=$VERSION build=$BUILD_VERSION bundle=$BUNDLE_IDENTIFIER"

IPA="$PWD/build/Cyanide-${VERSION}.ipa"
if [ ! -f "$IPA" ]; then
    echo "error: $IPA not found after build" >&2
    exit 1
fi
EFFECTIVE_TAG="${TAG:-v${VERSION}}"
RELEASE_DATE=$(date '+%Y-%m-%d')

# 2. Refresh source.json (AltSource manifest) so AltStore/SideStore clients
#    pull the new release automatically. Updates bundleIdentifier, version,
#    date, size, downloadURL on apps[0] of source.json at the repo root.
SOURCE_JSON="source.json"
if [ -f "$SOURCE_JSON" ]; then
    IPA_BYTES=$(stat -f%z "$IPA")
    ORIGIN_URL_FOR_JSON=$(git remote get-url origin 2>/dev/null || true)
    REPO_SLUG_FOR_JSON=$(echo "$ORIGIN_URL_FOR_JSON" \
        | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##' \
        | sed -E 's#\.git$##')
    DOWNLOAD_URL="https://github.com/${REPO_SLUG_FOR_JSON}/releases/download/${EFFECTIVE_TAG}/Cyanide-${VERSION}.ipa"
    echo "==> refreshing $SOURCE_JSON: version=$VERSION size=$IPA_BYTES"
    python3 - <<PY
import json
path = "$SOURCE_JSON"
with open(path) as f:
    data = json.load(f)
app = data["apps"][0]
app["bundleIdentifier"] = "$BUNDLE_IDENTIFIER"
if data.get("featuredApps"):
    data["featuredApps"][0] = "$BUNDLE_IDENTIFIER"
ver = app["versions"][0]
ver["version"]     = "$VERSION"
ver["date"]        = "$RELEASE_DATE"
ver["size"]        = $IPA_BYTES
ver["downloadURL"] = "$DOWNLOAD_URL"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
fi

if [ -n "$MANUAL_RELEASE_BULLETS" ]; then
    echo "==> marking pending release notes as v$VERSION"
    mark_pending_release_notes_released "$VERSION" "$RELEASE_DATE"
fi

commit_dirty_submodules "$DIRTY_SUBMODULES_BEFORE"

# 3. Commit if there's anything to commit: pre-existing tree changes, the
#    MARKETING_VERSION bump, or the source.json refresh.
NEEDS_COMMIT=0
if [ "$TREE_WAS_DIRTY" = "1" ] || [ "$BUMPED" = "1" ]; then
    NEEDS_COMMIT=1
elif ! git diff-index --quiet HEAD --; then
    # source.json may have changed even when the version didn't, e.g. when
    # downloading and re-uploading the same TAG with a different binary.
    NEEDS_COMMIT=1
fi
if [ "$NEEDS_COMMIT" = "1" ]; then
    if [ -z "$MSG" ]; then
        if [ "$TREE_WAS_DIRTY" = "0" ] && [ "$BUMPED" = "1" ]; then
            MSG="Bump version to $NEW_VERSION"
            echo "==> auto-commit message: $MSG"
        elif [ "$TREE_WAS_DIRTY" = "0" ]; then
            MSG="Refresh source.json for $EFFECTIVE_TAG"
            echo "==> auto-commit message: $MSG"
        else
            echo "error: working tree has changes but no commit message was provided." >&2
            echo "       pass a message as the first arg, or stash changes." >&2
            exit 1
        fi
    fi
    echo "==> committing"
    git add -A
    git commit -m "$MSG"
fi

# 4. Push (no-op if already in sync).
echo "==> pushing $BRANCH"
git push origin "$BRANCH"

# 5. Tag + release. Default tag is v${VERSION}. Override with TAG=v1.2.3 if you
#    need an off-cycle tag.
HASH=$(git rev-parse --short HEAD)
HEAD_SHA=$(git rev-parse HEAD)
TAG="$EFFECTIVE_TAG"
SUBJECT=$(git log -1 --pretty=%s)

# Release notes: explicit second arg > NOTES_FILE > NOTES env > auto-derived
# dirty-state bullets > commit subject.
NOTES_FROM_FILE=""
if [ -n "${NOTES_FILE:-}" ] && [ -f "${NOTES_FILE}" ]; then
    NOTES_FROM_FILE=$(cat "${NOTES_FILE}")
fi
NOTES_DEFAULT="$SUBJECT"
if [ -n "$EXTRA_BULLETS" ]; then
    NOTES_DEFAULT="$(printf '%s' "$EXTRA_BULLETS" \
        | sed -e '/^[[:space:]]*$/d' -e 's/^/- /')"
fi
NOTES="${NOTES_ARG:-${NOTES_FROM_FILE:-${NOTES:-$NOTES_DEFAULT}}}"

# Pin --repo to the origin push URL so gh doesn't try to create the release
# on the upstream parent (which it prefers by default for forks).
ORIGIN_URL=$(git remote get-url origin)
REPO_SLUG=$(echo "$ORIGIN_URL" \
    | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##' \
    | sed -E 's#\.git$##')
RELEASE_TITLE="Cyanide ${TAG}"

LOCAL_TAG_SHA=""
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    LOCAL_TAG_SHA=$(git rev-parse "refs/tags/$TAG^{commit}")
    if [ "$LOCAL_TAG_SHA" != "$HEAD_SHA" ]; then
        echo "error: local tag $TAG points to $LOCAL_TAG_SHA, not HEAD $HEAD_SHA" >&2
        exit 1
    fi
else
    echo "==> tagging $TAG"
    git tag "$TAG" "$HEAD_SHA"
fi

REMOTE_TAG_SHA=$(git ls-remote --tags origin "refs/tags/$TAG^{}" | awk '{print $1; exit}')
if [ -z "$REMOTE_TAG_SHA" ]; then
    REMOTE_TAG_SHA=$(git ls-remote --tags origin "refs/tags/$TAG" | awk '{print $1; exit}')
fi
if [ -n "$REMOTE_TAG_SHA" ] && [ "$REMOTE_TAG_SHA" != "$HEAD_SHA" ]; then
    echo "error: remote tag $TAG points to $REMOTE_TAG_SHA, not HEAD $HEAD_SHA" >&2
    exit 1
fi

if [ -z "$REMOTE_TAG_SHA" ]; then
    echo "==> pushing tag $TAG"
    git push origin "refs/tags/$TAG"
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "==> release $TAG already exists on $REPO_SLUG; replacing IPA asset"
    gh release upload "$TAG" "$IPA" --repo "$REPO_SLUG" --clobber
    gh release edit "$TAG" --repo "$REPO_SLUG" --title "$RELEASE_TITLE" --notes "$NOTES" --latest
else
    echo "==> creating release $TAG on $REPO_SLUG"
    gh release create "$TAG" "$IPA" \
        --repo "$REPO_SLUG" \
        --verify-tag \
        --latest \
        --title "$RELEASE_TITLE" \
        --notes "$NOTES"
fi

echo "==> done"
gh release view "$TAG" --repo "$REPO_SLUG" | head -10
