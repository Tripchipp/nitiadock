#!/usr/bin/env bash
# Build Release, sign it and install it to /Applications for day-to-day use.
#
# Release, not Debug: Debug has no optimisation and timing-sensitive things such as minimizing
# feel noticeably worse. The signature must stay the same from build to build, because macOS ties
# the Accessibility grant to the code identity; an ad-hoc signature changes with every build and
# silently breaks the grant. build_and_run.sh signs with the same certificate for the same reason.
#
# This does not notarize (a local build has no quarantine flag, so Gatekeeper does not check it).
# Scripts/release.sh makes the public, notarized download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/NitiaDock.xcodeproj"
SCHEME="NitiaDock"
# fork: NitiaDock builds and installs under its own name, next to any official install.
BUILT_NAME="NitiaDock"
APP_NAME="NitiaDock"
DEST="/Applications/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Resources/NitiaDock.entitlements"
DD="$ROOT/build/LocalReleaseDD"
PRODUCTS="$DD/Build/Products/Release"

DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
FALLBACK_IDENTITY="NitiaDock Local Code Signing"
# fork: same identity rule as build_and_run.sh, so the debug build and the installed copy share one
# Accessibility grant.
FORK_IDENTITY="${NITIADOCK_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"

[[ -f "$ENTITLEMENTS" ]] || { echo "error: entitlements not found: $ENTITLEMENTS" >&2; exit 1; }

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
# Developer ID first: it is what the published download is signed with, so a local install and a
# downloaded one share one Accessibility grant. Apple Development is the fallback for people who
# build from source without a paid account.
if [[ -n "$DEVELOPER_ID" ]] && grep -Fq "\"$DEVELOPER_ID\"" <<<"$IDENTITIES"; then
  IDENTITY="$DEVELOPER_ID"
elif [[ -n "$FORK_IDENTITY" ]] && grep -Fq "\"$FORK_IDENTITY\"" <<<"$IDENTITIES"; then
  IDENTITY="$FORK_IDENTITY"
elif grep -Fq "\"$FALLBACK_IDENTITY\"" <<<"$IDENTITIES"; then
  IDENTITY="$FALLBACK_IDENTITY"
  echo "warning: no Developer ID or Apple Development certificate, using '${FALLBACK_IDENTITY}'." >&2
else
  echo "error: no usable code-signing certificate found." >&2
  echo "       Add an Apple Development certificate in Xcode > Settings > Accounts." >&2
  exit 1
fi

echo "==> Building Release…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" build >"${TMPDIR:-/tmp}/nitiadock-local-install.log" 2>&1
echo "    ok"

STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
cp -R "$PRODUCTS/$BUILT_NAME.app" "$APP"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"   # GPL: the license travels with the binary

# Same as release.sh: hardened runtime, secure timestamp, same entitlements.
# --timestamp needs network access (about 1 second). It has no effect at runtime and is kept so the local
# package's signing configuration matches the release package exactly. If it ever gets in the way offline,
# removing it is safe.
#
# The Sparkle framework contains nested code (Updater.app / Autoupdate) that signing the outer app once **does
# not reach**; under the hardened runtime the main binary only loads libraries signed with the same Team ID,
# and the Sparkle built by Xcode still carries the local build certificate (no Team ID), so without re-signing
# dyld refuses to load it and the app crashes at launch (hit on 2026-08-21: Sparkle was embedded on 08-20 and
# this script was not updated then). So sign inside out like the release script: nested code -> framework ->
# app. No --deep: deprecated, and it wrongly applies the outer entitlements to nested code.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "error: Sparkle.framework is not embedded in the build" >&2; exit 1; }
# The two XPC services are only for sandboxed hosts and the release package does not ship them either; delete
# them **before** signing the framework, otherwise the seal does not match the contents.
rm -rf "$SPARKLE/Versions/B/XPCServices"
echo "==> Signing Sparkle's nested code (inside out)…"
for nested in "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/Autoupdate"; do
  [[ -e "$nested" ]] || { echo "error: Sparkle is missing expected nested code: $nested" >&2; exit 1; }
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE"

echo "==> Signing with ${IDENTITY} (hardened runtime + entitlements)…"
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

# The main binary and Sparkle must have the same Team ID, otherwise the load refusal above repeats on users'
# machines.
APP_TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
SPARKLE_TEAM="$(codesign -dvv "$SPARKLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$APP_TEAM" == "$SPARKLE_TEAM" ]] \
  || { echo "error: Sparkle and the app have different Team IDs ($SPARKLE_TEAM vs $APP_TEAM); the hardened runtime would refuse to load it" >&2; exit 1; }

# Read back right after signing; do not wait until runtime to find the entitlement missing.
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority=|^Identifier=|^TeamIdentifier=|flags=" | sed 's/^/    /'
SIGNED_ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
grep -q 'com.apple.security.automation.apple-events' <<<"$SIGNED_ENTS" \
  || { echo "error: the signed app lacks the Apple Events entitlement (Finder previews would break)" >&2; exit 1; }
# Store in a variable first, **do not write `codesign … | grep -q`**: `grep -q` closes the pipe on the first
# match, codesign gets SIGPIPE and exits non-zero, and under `set -o pipefail` the whole pipeline fails. The
# signature is fine but the script reports "no hardened runtime flag" (actually hit on 2026-08-19).
SIGNED_INFO="$(codesign -dvvv "$APP" 2>&1 || true)"
grep -q 'flags=.*runtime' <<<"$SIGNED_INFO" \
  || { echo "error: the signed app lacks the hardened runtime flag" >&2; exit 1; }

echo "==> Quitting the running instance…"
pkill -x "$BUILT_NAME" >/dev/null 2>&1 || true
# fork: the app was called NitiaBar before the rename. Two copies would both draw a bar, so the old
# one is stopped and moved to the Trash (not deleted). Its settings are carried over on first
# launch by ForkBundleMigration.
pkill -x "NitiaBar" >/dev/null 2>&1 || true
if [[ -d "/Applications/NitiaBar.app" ]]; then
  mv "/Applications/NitiaBar.app" "$HOME/.Trash/NitiaBar-$(date +%Y%m%d-%H%M%S).app"
  echo "==> moved the old /Applications/NitiaBar.app to the Trash"
fi
for _ in $(seq 1 25); do
  pgrep -x "$BUILT_NAME" >/dev/null 2>&1 || break
  sleep 0.2
done

# Braces matter: "$DEST…" would read the ellipsis as part of the name under set -u.
echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$APP" "$DEST"          # ditto keeps symlinks; cp would break the signature
rm -rf "$STAGE"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
echo "==> Done: $VER ($BUILD)"
# --verify does not catch nested code signed by someone else; the Team ID check above does.
codesign --verify --strict "$DEST" && echo "    signature OK"
echo "    launch: open \"$DEST\""
