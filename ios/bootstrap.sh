#!/bin/sh
# Checks the tools, creates Config/Local.xcconfig from the example if it is missing, and
# generates Musicless.xcodeproj with XcodeGen. Safe to re-run after every pull.
set -eu
cd "$(dirname "$0")"

fail() { printf 'bootstrap: %s\n' "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 \
  || fail "Xcode is missing. Install Xcode 26 or newer from the App Store, open it once, then re-run."
xcode_version=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {print $2; exit}')
[ -n "$xcode_version" ] \
  || fail "xcodebuild did not report a version. Run: sudo xcode-select -s /Applications/Xcode.app"
xcode_major=${xcode_version%%.*}
[ "$xcode_major" -ge 26 ] 2>/dev/null \
  || fail "Xcode $xcode_version found; this project needs Xcode 26 or newer."

command -v xcodegen >/dev/null 2>&1 \
  || fail "XcodeGen is missing. Install it with: brew install xcodegen"

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  printf 'bootstrap: created Config/Local.xcconfig; set DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX in it before building for a phone.\n'
fi
if ! grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' Config/Local.xcconfig; then
  printf 'bootstrap: note: DEVELOPMENT_TEAM is empty in Config/Local.xcconfig (fine for the simulator, required for a phone).\n'
fi

# ONNX Runtime (Microsoft's NuGet package, 184 MB once, cached in .vendor/): MusiclessCore links it.
tools/fetch_onnxruntime.sh

xcodegen generate --spec project.yml
printf 'bootstrap: Xcode %s, XcodeGen %s. Open Musicless.xcodeproj, or build with xcodebuild (see README.md).\n' \
  "$xcode_version" "$(xcodegen --version | awk '{print $2}')"
