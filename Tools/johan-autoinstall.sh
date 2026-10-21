#!/bin/bash
# Build one commit of the iOS app and install it on the iPhone, in the background.
#
# Started by .git/hooks/pre-push for every push of johan/whoop-ui; can also be run by hand:
#   Tools/johan-autoinstall.sh            # current HEAD
#   Tools/johan-autoinstall.sh <commit>
#
# Builds in its own detached worktree (~/Library/Caches/noop-autobuild), so the working tree, uncommitted
# edits and xcodegen's Info.plist drift are never touched, and builds exactly the commit that was pushed.
# Refuses to install unless the built bundle id is the one already on the phone, so an update never lands
# in a new, empty data container. A push during a build is queued; the newest queued commit wins.
# Log: ~/Library/Logs/noop-autobuild.log. Result: a macOS notification.
# Release, not Debug: unoptimized analytics blow the iOS background CPU limit and the re-score never finishes.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${NOOP_DEVICE:-00008150-000221820C00C01C}"
BUNDLE_ID="${NOOP_BUNDLE_ID:-com.johanstefanes.noop}"
BASE="$HOME/Library/Caches/noop-autobuild"
WT="$BASE/worktree"
DD="$BASE/DerivedData"
LOCK="$BASE/lock"
PENDING="$BASE/pending"
# The commit whose app is in $DD; a rerun for the same commit installs it without rebuilding.
BUILT="$BASE/built"
# The phone may be away or asleep; try again for up to an hour before giving up on this build.
INSTALL_TRIES=12
INSTALL_WAIT=300

mkdir -p "$BASE"
log() { echo "[$(date '+%F %T')] $*"; }
notify() { osascript -e "display notification \"$2\" with title \"NOOP\" subtitle \"$1\"" >/dev/null 2>&1 || true; }

SHA="$(git -C "$REPO" rev-parse "${1:-HEAD}^{commit}")"

# One build at a time. A second push while one runs leaves its commit for the running job to pick up.
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "$SHA" > "$PENDING"
    log "build running; queued ${SHA:0:8}"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

build_and_install() {
    local sha="$1" short="${1:0:8}" subject
    subject="$(git -C "$REPO" log -1 --format=%s "$sha")"
    local app="$DD/Build/Products/Release-iphoneos/NOOP.app" built
    if [ "$(cat "$BUILT" 2>/dev/null)" = "$sha" ] && [ -d "$app" ]; then
        log "already built $short $subject; installing"
    else
        log "building $short $subject"

        if [ ! -e "$WT/.git" ]; then
            git -C "$REPO" worktree prune
            git -C "$REPO" worktree add --detach "$WT" "$sha"
        else
            git -C "$WT" checkout --detach --force --quiet "$sha"
            git -C "$WT" clean -fdxq
        fi
        cp "$REPO/Config/BundleIdSecrets.xcconfig" "$WT/Config/"

        (cd "$WT" && xcodegen generate --quiet)
        if ! xcodebuild -project "$WT/Strand.xcodeproj" -scheme NOOPiOS -configuration Release \
                -destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates \
                -quiet build; then
            log "build FAILED for $short"
            notify "Build failed" "$short $subject — see ~/Library/Logs/noop-autobuild.log"
            return 1
        fi
        echo "$sha" > "$BUILT"
    fi

    built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    if [ "$built" != "$BUNDLE_ID" ]; then
        log "bundle id is $built, expected $BUNDLE_ID; not installing"
        notify "Not installed" "Bundle id changed to $built (your data lives under $BUNDLE_ID)"
        return 1
    fi

    local i
    for ((i = 1; i <= INSTALL_TRIES; i++)); do
        # A newer push supersedes this one; stop waiting and build that instead.
        [ -s "$PENDING" ] && { log "newer push queued; skipping install of $short"; return 0; }
        if xcrun devicectl device install app --device "$DEVICE" "$app" >/dev/null 2>&1; then
            log "installed $short"
            notify "Updated" "$short $subject"
            return 0
        fi
        log "iPhone not reachable (try $i/$INSTALL_TRIES)"
        [ "$i" -lt "$INSTALL_TRIES" ] && sleep "$INSTALL_WAIT"
    done
    notify "Not installed" "iPhone not reachable for an hour. Built $short; run Tools/johan-autoinstall.sh to install it"
    return 1
}

while :; do
    build_and_install "$SHA" || true
    [ -s "$PENDING" ] || break
    SHA="$(cat "$PENDING")"
    rm -f "$PENDING"
done
