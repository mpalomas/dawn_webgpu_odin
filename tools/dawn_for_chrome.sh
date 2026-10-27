#!/usr/bin/env bash
# Finds the Dawn commit built into a Chrome release, and optionally checks it out. Needs only bash, curl
# and git: files are read through Gitiles, nothing is cloned but the Dawn commit itself (--fetch).
#
# Usage: tools/dawn_for_chrome.sh [options] <chrome>
#   <chrome>        A full version (156.0.8078.48), a milestone (156: its latest stable release), or a
#                   channel (stable, beta, dev, canary: its latest release)
#   --platform P    Platform for milestones and channels: Mac, Windows, Linux (default: this OS)
#   --fetch DIR     Check out the Dawn commit in DIR: a shallow clone if DIR is new or empty, else a fetch
#                   into the existing Dawn repo there
#   --deps          With --fetch, also fetch Dawn's third-party dependencies (tools/fetch_dawn_dependencies.py,
#                   needs python3), so that CMake can build with DAWN_FETCH_DEPENDENCIES=OFF
#   --env           Print KEY=VALUE lines only, e.g. to append to $GITHUB_OUTPUT or $GITHUB_ENV
#
# The commit is `dawn_revision` in Chromium's DEPS at the version's tag. Chromium's release branch BBBB
# (the version's third number) has a Dawn branch chromium/BBBB, where later fixes for the milestone are
# cherry-picked, so the script also reports how far the commit is from that branch's tip.
#
# --env keys: CHROME_VERSION, DAWN_COMMIT, DAWN_COMMIT_DATE, DAWN_COMMIT_TITLE, DAWN_BRANCH, DAWN_BRANCH_TIP,
# DAWN_BRANCH_AHEAD (commits on the branch after DAWN_COMMIT). The DAWN_BRANCH* values are empty when the
# branch does not exist (canary and dev builds from main).

set -euo pipefail

CHROMIUM_GITILES=https://chromium.googlesource.com/chromium/src
DAWN_GITILES=https://dawn.googlesource.com/dawn
CHROMIUMDASH=https://chromiumdash.appspot.com

usage() {
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0" | sed '$d' >&2
    exit 2
}

die() {
    echo "error: $*" >&2
    exit 1
}

fetch() {
    curl -fsSL --retry 3 "$1"
}

# Gitiles JSON starts with a `)]}'` line, against XSSI.
fetch_json() {
    fetch "$1" | tail -n +2
}

CHROME=""
PLATFORM=""
FETCH_DIR=""
DEPS=0
ENV=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
        --fetch) FETCH_DIR="${2:?--fetch needs a directory}"; shift 2 ;;
        --deps) DEPS=1; shift ;;
        --env) ENV=1; shift ;;
        -h | --help) usage ;;
        -*) die "unknown option $1" ;;
        *) [[ -z "$CHROME" ]] || die "expected one Chrome version"; CHROME="$1"; shift ;;
    esac
done
[[ -n "$CHROME" ]] || usage
[[ $DEPS == 0 || -n "$FETCH_DIR" ]] || die "--deps needs --fetch"

if [[ -z "$PLATFORM" ]]; then
    case "$(uname -s)" in
        Darwin) PLATFORM=Mac ;;
        Linux) PLATFORM=Linux ;;
        MINGW* | MSYS* | CYGWIN*) PLATFORM=Windows ;;
        *) PLATFORM=Linux ;;
    esac
fi

# Resolves a milestone or channel to its latest release, through chromiumdash.
latest_version() {
    local channel="$1" milestone="${2:-}" url
    url="$CHROMIUMDASH/fetch_releases?channel=$channel&platform=$PLATFORM&num=1"
    [[ -z "$milestone" ]] || url="$url&milestone=$milestone"
    fetch "$url" | grep -o '"version":"[^"]*"' | head -n 1 | cut -d '"' -f 4
}

case "$CHROME" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) VERSION="$CHROME" ;;
    [0-9]*) VERSION="$(latest_version Stable "$CHROME")" ;;
    stable | beta | dev | canary)
        channel="$(tr '[:lower:]' '[:upper:]' <<<"${CHROME:0:1}")${CHROME:1}"
        VERSION="$(latest_version "$channel")"
        ;;
    *) die "expected a version (156.0.8078.48), a milestone (156) or a channel (stable, beta, dev, canary), got '$CHROME'" ;;
esac
[[ -n "$VERSION" ]] || die "no $PLATFORM release found for '$CHROME'"

# DEPS at the version's tag, base64-encoded by ?format=TEXT.
DEPS_FILE="$(fetch "$CHROMIUM_GITILES/+/refs/tags/$VERSION/DEPS?format=TEXT" | base64 --decode)" ||
    die "no Chromium tag $VERSION"
COMMIT="$(sed -n "s/^ *'dawn_revision': *'\([0-9a-f]\{40\}\)'.*/\1/p" <<<"$DEPS_FILE")"
[[ -n "$COMMIT" ]] || die "no dawn_revision in DEPS at $VERSION"

# Commit date and title. The JSON is one key per line; `time` follows `committer`.
COMMIT_JSON="$(fetch_json "$DAWN_GITILES/+/$COMMIT?format=JSON")"
COMMIT_DATE="$(awk '/"committer": \{/ {c = 1} c && /"time":/ {sub(/.*"time": "/, ""); sub(/".*/, ""); print; exit}' <<<"$COMMIT_JSON")"
COMMIT_TITLE="$(sed -n 's/^ *"message": "//p' <<<"$COMMIT_JSON" | sed 's/\\n.*//; s/\\"/"/g' | head -n 1)"

# The milestone's Dawn branch, missing for builds from main.
CHROME_BRANCH="$(cut -d . -f 3 <<<"$VERSION")"
BRANCH="chromium/$CHROME_BRANCH"
BRANCH_TIP="$(fetch_json "$DAWN_GITILES/+refs/heads/$BRANCH?format=JSON" | sed -n 's/^ *"value": "\([0-9a-f]*\)".*/\1/p')"
AHEAD=""
if [[ -z "$BRANCH_TIP" ]]; then
    BRANCH=""
elif [[ "$BRANCH_TIP" == "$COMMIT" ]]; then
    AHEAD=0
else
    LOG="$(fetch_json "$DAWN_GITILES/+log/$COMMIT..$BRANCH_TIP?format=JSON")"
    AHEAD="$(grep -c '^ *"commit": "' <<<"$LOG" || true)"
    # Gitiles pages logs; a "next" key means there are more.
    ! grep -q '"next":' <<<"$LOG" || AHEAD="$AHEAD+"
fi

if [[ $ENV == 1 ]]; then
    echo "CHROME_VERSION=$VERSION"
    echo "DAWN_COMMIT=$COMMIT"
    echo "DAWN_COMMIT_DATE=$COMMIT_DATE"
    echo "DAWN_COMMIT_TITLE=$COMMIT_TITLE"
    echo "DAWN_BRANCH=$BRANCH"
    echo "DAWN_BRANCH_TIP=$BRANCH_TIP"
    echo "DAWN_BRANCH_AHEAD=$AHEAD"
else
    echo "Chrome:      $VERSION"
    echo "Dawn commit: $COMMIT"
    echo "             $COMMIT_DATE  $COMMIT_TITLE"
    echo "             $DAWN_GITILES/+/$COMMIT"
    if [[ -z "$BRANCH" ]]; then
        echo "Dawn branch: none (chromium/$CHROME_BRANCH does not exist: a build from main)"
    elif [[ "$AHEAD" == 0 ]]; then
        echo "Dawn branch: $BRANCH, at its tip"
    else
        echo "Dawn branch: $BRANCH, whose tip $BRANCH_TIP has $AHEAD more commit(s)"
    fi
fi

[[ -n "$FETCH_DIR" ]] || exit 0

# Progress goes to stderr, so that --env output stays clean.
{
    if [[ ! -d "$FETCH_DIR" || -z "$(ls -A "$FETCH_DIR")" ]]; then
        echo "Fetching Dawn $COMMIT into $FETCH_DIR (shallow)"
        mkdir -p "$FETCH_DIR"
        git -C "$FETCH_DIR" init -q
        git -C "$FETCH_DIR" remote add origin "$DAWN_GITILES"
        git -C "$FETCH_DIR" fetch -q --depth 1 origin "$COMMIT"
    elif git -C "$FETCH_DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
        echo "Dawn $COMMIT is already in $FETCH_DIR"
    else
        git -C "$FETCH_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$FETCH_DIR is not empty and not a git repository"
        echo "Fetching Dawn $COMMIT into $FETCH_DIR"
        # Keep a full clone full: --depth would make it shallow.
        depth=()
        [[ "$(git -C "$FETCH_DIR" rev-parse --is-shallow-repository)" == false ]] || depth=(--depth 1)
        git -C "$FETCH_DIR" fetch -q "${depth[@]}" "$DAWN_GITILES" "$COMMIT"
    fi
    git -C "$FETCH_DIR" -c advice.detachedHead=false checkout -q --detach "$COMMIT"
    echo "Checked out $COMMIT in $FETCH_DIR"

    if [[ $DEPS == 1 ]]; then
        echo "Fetching Dawn's dependencies"
        (cd "$FETCH_DIR" && python3 tools/fetch_dawn_dependencies.py)
    fi
} >&2
