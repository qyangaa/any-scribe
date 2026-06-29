#!/bin/bash
# Package AnyScribe.app into a distributable DMG. Optionally notarize + staple (CI / release).
#
# Env:
#   VERSION       version string for the dmg filename (default 0.1.0)
#   NOTARIZE      "1" to submit the dmg to Apple notarization and staple the ticket.
#                 Requires: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="AnyScribe.app"
VOL_NAME="Any Scribe"
VERSION="${VERSION:-0.1.0}"
DMG="AnyScribe-${VERSION}.dmg"

[ -d "${APP_DIR}" ] || { echo "✗ ${APP_DIR} not found — run ./package-app.sh first."; exit 1; }

echo "▶ Staging DMG contents…"
STAGE="$(mktemp -d)"
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"   # drag-to-install target

echo "▶ Creating ${DMG}…"
rm -f "${DMG}"
hdiutil create -volname "${VOL_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"

if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "▶ Notarizing ${DMG} (this can take a few minutes)…"
    xcrun notarytool submit "${DMG}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --wait
    echo "▶ Stapling ticket…"
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
fi

echo ""
echo "✓ ${DMG}"
