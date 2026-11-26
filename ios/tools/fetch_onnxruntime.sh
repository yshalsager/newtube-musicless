#!/bin/sh
# Fetches ONNX Runtime from nuget.org and assembles Packages/MusiclessCore/Vendor/onnxruntime.xcframework
# (gitignored). bootstrap.sh runs it; it is idempotent and works offline once cached.
#
# Why NuGet (DECISIONS D27): Microsoft pulled its Swift package repo and download.onnxruntime.ai in
# November 2026. Microsoft.ML.OnnxRuntime on nuget.org is still Microsoft's own signed package, and it
# carries an iOS xcframework (static, CoreML execution provider included) plus an osx-arm64 dylib.
#
# The assembled xcframework holds:
# - the package's ios-arm64 and ios-arm64_x86_64-simulator frameworks, unchanged, plus a module map;
# - a macos-arm64 framework wrapping the osx-arm64 dylib (install name changed, so ad-hoc re-signed),
#   only so `swift test` runs on the Mac. It never ships in the app.
set -eu

VERSION=1.32.0
NUPKG_SHA256=a9150bc2992cbbb6722070da9910e1ffa989a8bfc67bdd5bb8e745ca755641db
URL="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$VERSION/microsoft.ml.onnxruntime.$VERSION.nupkg"

ios=$(cd "$(dirname "$0")/.." && pwd)
cache="$ios/.vendor/cache"
vendor="$ios/Packages/MusiclessCore/Vendor"
stamp="$vendor/onnxruntime.xcframework/.musicless-source"
# Bump LAYOUT when the assembled xcframework changes (module map, slices), so checkouts reassemble.
LAYOUT=2
want="Microsoft.ML.OnnxRuntime $VERSION sha256 $NUPKG_SHA256 layout $LAYOUT"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  printf 'onnxruntime: %s already assembled\n' "$VERSION"
  exit 0
fi

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
mkdir -p "$cache"
nupkg="$cache/microsoft.ml.onnxruntime.$VERSION.nupkg"
if [ ! -f "$nupkg" ] || [ "$(sha "$nupkg")" != "$NUPKG_SHA256" ]; then
  printf 'onnxruntime: downloading Microsoft.ML.OnnxRuntime %s from nuget.org (184 MB, once)\n' "$VERSION"
  curl -fL --retry 3 --progress-bar -o "$nupkg.part" "$URL"
  mv "$nupkg.part" "$nupkg"
fi
if [ "$(sha "$nupkg")" != "$NUPKG_SHA256" ]; then
  rm -f "$nupkg"
  printf 'onnxruntime: SHA-256 mismatch for %s; deleted it. Re-run to download again.\n' "$nupkg" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/onnxruntime.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$nupkg" 'runtimes/ios/native/onnxruntime.xcframework.zip' 'runtimes/osx-arm64/native/libonnxruntime.dylib' \
  LICENSE ThirdPartyNotices.txt -d "$work"
unzip -q "$work/runtimes/ios/native/onnxruntime.xcframework.zip" -d "$work/nuget"
slices="$work/nuget/onnxruntime.xcframework"

# Swift imports the C API through this module map (the package ships none). C++ headers stay out.
modulemap() {
  cat > "$1" <<'EOF'
framework module onnxruntime {
  header "onnxruntime_c_api.h"
  header "coreml_provider_factory.h"
  header "cpu_provider_factory.h"
  export *
  link "c++"
  link "z"
  link "sqlite3"
  link framework "CoreML"
  link framework "Foundation"
}
EOF
}

frameworks=""
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  framework="$work/$slice/onnxruntime.framework"
  mkdir -p "$work/$slice"
  cp -R "$slices/$slice/onnxruntime.framework" "$framework"
  mkdir -p "$framework/Modules"
  modulemap "$framework/Modules/module.modulemap"
  frameworks="$frameworks -framework $framework"
done

# macOS: a versioned framework around the dylib.
mac="$work/macos-arm64/onnxruntime.framework"
mkdir -p "$mac/Versions/A/Resources" "$mac/Versions/A/Modules"
cp "$work/runtimes/osx-arm64/native/libonnxruntime.dylib" "$mac/Versions/A/onnxruntime"
install_name_tool -id @rpath/onnxruntime.framework/Versions/A/onnxruntime "$mac/Versions/A/onnxruntime" 2>/dev/null
# Re-signing over Microsoft's signature fails ("timestamps differ"); strip it first, then sign ad hoc.
codesign --remove-signature "$mac/Versions/A/onnxruntime"
codesign --sign - --timestamp=none "$mac/Versions/A/onnxruntime"
cp -R "$slices/ios-arm64/onnxruntime.framework/Headers" "$mac/Versions/A/Headers"
modulemap "$mac/Versions/A/Modules/module.modulemap"
cat > "$mac/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>onnxruntime</string>
  <key>CFBundleIdentifier</key><string>com.microsoft.onnxruntime</string>
  <key>CFBundleName</key><string>onnxruntime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
</dict></plist>
EOF
(cd "$mac/Versions" && ln -s A Current)
(cd "$mac" && ln -s Versions/Current/onnxruntime onnxruntime && ln -s Versions/Current/Headers Headers \
  && ln -s Versions/Current/Modules Modules && ln -s Versions/Current/Resources Resources)
frameworks="$frameworks -framework $mac"

# shellcheck disable=SC2086
xcodebuild -create-xcframework $frameworks -output "$work/onnxruntime.xcframework" >/dev/null
printf '%s\n' "$want" > "$work/onnxruntime.xcframework/.musicless-source"

mkdir -p "$vendor"
rm -rf "$vendor/onnxruntime.xcframework"
mv "$work/onnxruntime.xcframework" "$vendor/onnxruntime.xcframework"
cp "$work/LICENSE" "$vendor/LICENSE-ONNXRuntime"
cp "$work/ThirdPartyNotices.txt" "$vendor/ThirdPartyNotices-ONNXRuntime.txt"
printf 'onnxruntime: assembled %s in %s\n' "$VERSION" "$vendor"
