#!/bin/bash
# Build Any Scribe, bundle the whisper engine, and assemble a signed .app.
#
# Env:
#   VERSION         app version string (default 0.1.0)
#   WHISPER_BUILD   path to a Metal whisper.cpp build dir (default ~/.local/share/anyscribe/whisper.cpp/build)
#   SIGN_IDENTITY   codesign identity. Default: "Any Scribe Self-Signed" if present, else ad-hoc ("-").
#                   In CI, pass the Developer ID: "Developer ID Application: NAME (TEAMID)".
#   NOTARIZE        "1" to sign with hardened runtime + secure timestamp (required before notarizing).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Any Scribe"
EXEC_NAME="AnyScribe"
BUNDLE_ID="com.arky.anyscribe"
VERSION="${VERSION:-0.1.0}"
APP_DIR="${EXEC_NAME}.app"
WHISPER_BUILD="${WHISPER_BUILD:-$HOME/.local/share/anyscribe/whisper.cpp/build}"

echo "▶ Building release binary…"
swift build -c release --product "${EXEC_NAME}"
BIN_PATH="$(swift build -c release --product "${EXEC_NAME}" --show-bin-path)/${EXEC_NAME}"
BIN_DIR="$(dirname "${BIN_PATH}")"

echo "▶ Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"

# SPM resource bundles (e.g. KeyboardShortcuts localizations).
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"; done
shopt -u nullglob

# ── Bundle the whisper engine so the app is self-contained (no Homebrew needed) ──
ENGINE_DIR="${APP_DIR}/Contents/Resources/whisper"
if [ -x "${WHISPER_BUILD}/bin/whisper-server" ]; then
    echo "▶ Bundling whisper engine from ${WHISPER_BUILD}…"
    mkdir -p "${ENGINE_DIR}"
    cp "${WHISPER_BUILD}/bin/whisper-server" "${ENGINE_DIR}/"
    cp -a "${WHISPER_BUILD}/bin/"lib*.dylib* "${ENGINE_DIR}/"
    rm -f "${ENGINE_DIR}/"libparakeet*   # not used by whisper-server
    # Make relocatable: each Mach-O references siblings via @rpath. Strip whatever absolute
    # build-dir rpaths it baked in and point @rpath at its own directory.
    while IFS= read -r macho; do
        while IFS= read -r rp; do
            [ -n "${rp}" ] && install_name_tool -delete_rpath "${rp}" "${macho}" 2>/dev/null || true
        done < <(otool -l "${macho}" | awk '/LC_RPATH/{f=1;next} f&&/path/{print $2;f=0}')
        install_name_tool -add_rpath "@loader_path" "${macho}" 2>/dev/null || true
    done < <(find "${ENGINE_DIR}" -type f \( -name '*.dylib' -o -name 'whisper-server' \))
else
    echo "⚠ No whisper build at ${WHISPER_BUILD} — app will fall back to Homebrew/Metal-build at runtime."
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${EXEC_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
        <string>Any Scribe transcribes your microphone during meetings.</string>
</dict>
</plist>
PLIST

ENT_FILE="$(mktemp -t anyscribe-ent).plist"
cat > "${ENT_FILE}" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

# ── Determine signing identity ──
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-certificate -c "Any Scribe Self-Signed" >/dev/null 2>&1; then
        SIGN_IDENTITY="Any Scribe Self-Signed"
    else
        SIGN_IDENTITY="-"
    fi
fi
RUNTIME_OPTS=()
[ "${NOTARIZE:-0}" = "1" ] && RUNTIME_OPTS=(--options runtime --timestamp)
echo "▶ Signing with: ${SIGN_IDENTITY}  ${RUNTIME_OPTS[*]:-(local)}"

sign() { codesign --force ${RUNTIME_OPTS[@]+"${RUNTIME_OPTS[@]}"} --sign "${SIGN_IDENTITY}" "$@"; }

# Sign nested code inner→outer (required for notarization), then the app last.
if [ -d "${ENGINE_DIR}" ]; then
    while IFS= read -r macho; do sign "${macho}"; done \
        < <(find "${ENGINE_DIR}" -type f -name '*.dylib')
    sign "${ENGINE_DIR}/whisper-server"
fi
codesign --force ${RUNTIME_OPTS[@]+"${RUNTIME_OPTS[@]}"} --entitlements "${ENT_FILE}" --sign "${SIGN_IDENTITY}" "${APP_DIR}"
rm -f "${ENT_FILE}"

codesign --verify --deep --strict --verbose=1 "${APP_DIR}" 2>&1 | tail -1 || true

echo ""
echo "✓ Built ${APP_DIR} (v${VERSION})"
echo "  Run:     open \"${APP_DIR}\""
