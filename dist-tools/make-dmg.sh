#!/usr/bin/env bash
# make-dmg.sh — package build/CornerCal.app into a distributable .dmg (and .zip).
#
# Usage (run from the CornerCalApp root, or this script cd's there itself):
#   dist-tools/make-dmg.sh
#
# Produces:
#   dist/CornerCal-<version>.dmg   (UDZO compressed, volume name "CornerCal")
#   dist/CornerCal-<version>.zip   (ditto archive, alternative to the dmg)
#
# Uses only Apple-supplied tools: hdiutil, ditto, PlistBuddy, shasum.
# CornerCal is not notarized (no paid Apple Developer account), so the
# staged volume includes a short "How to open" note for first launch.

set -euo pipefail

# Resolve the CornerCalApp root regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${APP_ROOT}"

APP_BUNDLE="build/CornerCal.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "error: ${APP_BUNDLE} not found. Build the app first." >&2
  exit 1
fi

if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "error: ${INFO_PLIST} not found." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${INFO_PLIST}")"
if [[ -z "${VERSION}" ]]; then
  echo "error: could not read CFBundleShortVersionString from ${INFO_PLIST}" >&2
  exit 1
fi

DIST_DIR="dist"
DMG_NAME="CornerCal-${VERSION}.dmg"
ZIP_NAME="CornerCal-${VERSION}.zip"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
VOL_NAME="CornerCal"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${ZIP_PATH}"

STAGE_DIR="$(mktemp -d /tmp/cornercal-dmg-stage.XXXXXX)"
cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

echo "Staging DMG contents in ${STAGE_DIR} ..."
ditto "${APP_BUNDLE}" "${STAGE_DIR}/CornerCal.app"
ln -s /Applications "${STAGE_DIR}/Applications"

cat > "${STAGE_DIR}/How to open CornerCal.txt" <<'EOF'
macOS is about to accuse CornerCal of being sketchy. It isn't — it's just
not notarized, because that costs $99/year and this was made by a
14-year-old, not a company. Here's how to let it in anyway:

  1. Drag CornerCal.app into Applications.
  2. Open it once (double-click). macOS blocks it. Expected, not broken.
  3. Open System Settings -> Privacy & Security.
  4. Scroll down. Next to "CornerCal was blocked...", click "Open Anyway".
     (This button disappears about an hour after step 2 — don't dawdle.)
  5. Enter your password, then click "Open" in the confirmation dialog.

Prefer Terminal?
  xattr -dr com.apple.quarantine /Applications/CornerCal.app

Then allow Calendar access when it asks — that's the entire app. It reads
your macOS Calendar locally and sends nothing anywhere, ever.
EOF

echo "Creating ${DMG_PATH} ..."
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "Creating ${ZIP_PATH} ..."
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo
echo "Done."
echo "sha256 (${DMG_NAME}):"
shasum -a 256 "${DMG_PATH}"
echo "sha256 (${ZIP_NAME}):"
shasum -a 256 "${ZIP_PATH}"
