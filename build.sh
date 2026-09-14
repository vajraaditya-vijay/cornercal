#!/bin/bash
# Builds build/CornerCal.app (universal: Apple Silicon + Intel) with plain swiftc and signs it ad hoc.
# Deliberately does nothing else: no quarantine stripping, no launchd, no launching. A native CornerCal
# that did those things got flagged by XProtect on 13 Sep 2026.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CornerCal.app"
# SDK 27.0 was built for a newer Swift than this toolchain (6.3.3); 26.5 works.
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
MIN=14.0

rm -rf "$APP" "$ROOT/build/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/obj"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos$MIN" \
    "$ROOT"/Sources/*.swift -o "$ROOT/build/obj/CornerCal-$arch"
done
lipo -create "$ROOT/build/obj/CornerCal-arm64" "$ROOT/build/obj/CornerCal-x86_64" -output "$APP/Contents/MacOS/CornerCal"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
