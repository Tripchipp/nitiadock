#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# fork: the scheme keeps upstream's name; the product is NitiaDock so its process name
# differs from the official app and `pkill -x` below never touches an official install.
SCHEME_NAME="NitiaDock"
APP_NAME="NitiaDock"
CLI_NAME="window-lab"
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/NitiaDock.xcodeproj"
DERIVED_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Must use the same certificate as install_local_release.sh: the dev build and the installed package share a
# bundle id and one Accessibility grant record, and mismatched identities invalidate each other.
DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
FALLBACK_SIGNING_IDENTITY="NitiaDock Local Code Signing"
# fork: a real certificate keeps the Accessibility grant across rebuilds; ad-hoc signing loses it
# every build. Defaults to the first "Apple Development" certificate in the keychain; set
# NITIADOCK_SIGNING_IDENTITY to a name from `security find-identity -v -p codesigning` to pin one.
FORK_SIGNING_IDENTITY="${NITIADOCK_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"

build_app() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >"${TMPDIR:-/tmp}/NitiaDock-build.log" 2>&1
}

sign_app() {
  local identities identity
  identities="$(security find-identity -v -p codesigning 2>&1)"
  # Same order as install_local_release.sh, so the debug build and the installed copy share one
  # Accessibility grant.
  if [[ -n "$DEVELOPER_ID" ]] && grep -Fq "\"$DEVELOPER_ID\"" <<<"$identities"; then
    identity="$DEVELOPER_ID"
  elif [[ -n "$FORK_SIGNING_IDENTITY" ]] && grep -Fq "\"$FORK_SIGNING_IDENTITY\"" <<<"$identities"; then
    identity="$FORK_SIGNING_IDENTITY"
  elif grep -Fq "\"$FALLBACK_SIGNING_IDENTITY\"" <<<"$identities"; then
    identity="$FALLBACK_SIGNING_IDENTITY"
  else
    echo "warning: no signing identity found; keeping Xcode's build signature" >&2
    return 0
  fi
  # Deliberately no --options runtime / --entitlements. The hardened runtime blocks debugger attach (our
  # entitlements file would replace the get-task-allow that Xcode injects for Debug), which would break lldb
  # in --debug mode. TCC goes by certificate chain + bundle id, not the runtime flag, so with the same
  # certificate the grant is shared with the daily build.
  #
  # Since Sparkle landed the bundle **no longer has a single executable**: Sparkle.framework also contains
  # Updater.app and Autoupdate. Xcode signs Debug builds with the local certificate configured in the project,
  # so re-signing only the outer layer here would leave the framework and the outer app on two different
  # certificates, and Sparkle refuses to launch the updater when its signature does not match the host. So
  # nested code is re-signed too, again inside out. Still no --deep: Apple has deprecated it, and it wrongly
  # applies the outer signing options to nested code.
  local framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$framework" ]]; then
    for nested in "$framework/Versions/B/Updater.app" "$framework/Versions/B/Autoupdate"; do
      [[ -e "$nested" ]] && /usr/bin/codesign --force --sign "$identity" "$nested" >>"${TMPDIR:-/tmp}/NitiaDock-codesign.log" 2>&1
    done
    /usr/bin/codesign --force --sign "$identity" "$framework" >>"${TMPDIR:-/tmp}/NitiaDock-codesign.log" 2>&1
  fi
  /usr/bin/codesign --force --sign "$identity" "$APP_BUNDLE" >>"${TMPDIR:-/tmp}/NitiaDock-codesign.log" 2>&1
}

run_cli() {
  xcodebuild -project "$PROJECT_PATH" -scheme "$CLI_NAME" -configuration Debug -derivedDataPath "$DERIVED_DATA_DIR" build >"${TMPDIR:-/tmp}/NitiaDock-build.log" 2>&1
  "$DERIVED_DATA_DIR/Build/Products/Debug/$CLI_NAME" "$@"
}

# Confirm the old process has really exited before launching. This used to be `open -n` (force a new
# instance); whenever pkill lagged or an instance started elsewhere was not covered by pkill, two identical
# taskbars appeared on screen and it was impossible to tell which version was being tested.
wait_for_exit() {
  local attempt
  pkill -x "NitiaBar" >/dev/null 2>&1 || true   # fork: the pre-rename name, see install_local_release.sh
  for attempt in $(seq 1 25); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  echo "warning: old instance did not exit within 5 seconds, force killing" >&2
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.3
}

open_app() {
  wait_for_exit
  /usr/bin/open "$APP_BUNDLE"
}

wait_for_app() {
  local attempt
  for attempt in $(seq 1 20); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

case "$MODE" in
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    ;;
  --debug|debug)
    build_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"no.thilip.nitiadock\""
    ;;
  --launch-trace|launch-trace)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    wait_for_exit
    DOCK_LAUNCH_TRACE=1 "$APP_EXECUTABLE" >"${TMPDIR:-/tmp}/launch-trace.log" 2>&1 &
    wait_for_app
    echo "launch trace: ${TMPDIR:-/tmp}/launch-trace.log"
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_app
    sign_app
    open_app
    wait_for_app
    ;;
  --lab|lab)
    run_cli "${@:2}"
    ;;
  --lab-minimize|lab-minimize)
    run_cli minimizeRestore "${@:2}"
    ;;
  --lab-close|lab-close)
    run_cli closeTarget "${@:2}"
    ;;
  --lab-replay|lab-replay)
    run_cli replay "${2:-minimize-restore-replay}"
    ;;
  --lab-placement|lab-placement)
    run_cli placementReplay "${2:-placement-permanent-hold-replay}"
    ;;
  --lab-transition|lab-transition)
    run_cli transitionReplay "${2:-focused-active-replay}"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--launch-trace|--verify|--lab|--lab-minimize|--lab-close|--lab-replay [scenario-name]|--lab-placement [scenario-name]|--lab-transition [scenario-name]]" >&2
    exit 2
    ;;
esac
