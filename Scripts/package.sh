#!/usr/bin/env bash
# Scripts/package.sh — Build, sign, notarize, staple, DMG
#
# Uso:
#   export TEAM_ID="XXXXXXXXXX"
#   export APPLE_ID="tua@email.com"
#   export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password per notarytool
#   export BUNDLE_ID="it.musifixapp.MusiFixApp"  # opzionale, default sotto
#   ./Scripts/package.sh [release_version]
#
# Richiede: Xcode Command Line Tools, Developer ID Application certificate in keychain.

set -euo pipefail

VERSION="${1:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-it.musifixapp.MusiFixApp}"
APP_NAME="MusiFixApp"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/MusiFix-$VERSION.dmg"

XCPROJECT="$PROJECT_DIR/MusiFixApp.xcodeproj"
SCHEME="MusiFixApp"

echo "==> MusiFix Packaging — v$VERSION"
echo "    PROJECT: $PROJECT_DIR"
echo "    TEAM_ID: ${TEAM_ID:-<non impostato>}"

# ── Controlli preliminari ──────────────────────────────────────────────────────

if [ -z "${TEAM_ID:-}" ]; then
    echo "[ERRORE] Imposta TEAM_ID prima di eseguire questo script."
    exit 1
fi
if [ -z "${APPLE_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
    echo "[ERRORE] Imposta APPLE_ID e APP_PASSWORD per la notarizzazione."
    exit 1
fi

command -v xcodebuild  >/dev/null || { echo "[ERRORE] xcodebuild non trovato."; exit 1; }
command -v xcrun       >/dev/null || { echo "[ERRORE] xcrun non trovato."; exit 1; }
command -v hdiutil     >/dev/null || { echo "[ERRORE] hdiutil non trovato."; exit 1; }

mkdir -p "$BUILD_DIR"

# ── 1. Archive ─────────────────────────────────────────────────────────────────

echo ""
echo "==> 1/5  Archivio (xcodebuild archive)…"
xcodebuild archive \
    -project "$XCPROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    SWIFT_VERSION=6.0 \
    | xcpretty 2>/dev/null || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "[ERRORE] Archive fallito — $ARCHIVE_PATH non trovato."
    exit 1
fi
echo "    OK: $ARCHIVE_PATH"

# ── 2. Export (firma Developer ID) ────────────────────────────────────────────

echo ""
echo "==> 2/5  Export con firma Developer ID…"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$BUILD_DIR" \
    | xcpretty 2>/dev/null || true

APP_PATH="$BUILD_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "[ERRORE] Export fallito — $APP_PATH non trovato."
    exit 1
fi
echo "    OK: $APP_PATH"

# ── 3. Verifica firma ─────────────────────────────────────────────────────────

echo ""
echo "==> 3/5  Verifica firma…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --verbose=4 --type exec "$APP_PATH" || true
echo "    OK"

# ── 4. Notarizzazione ─────────────────────────────────────────────────────────

echo ""
echo "==> 4/5  Notarizzazione (xcrun notarytool)…"

ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait \
    --output-format plist \
    > "$BUILD_DIR/notarization_result.plist" 2>&1

# Controlla status
STATUS=$(plutil -extract status raw "$BUILD_DIR/notarization_result.plist" 2>/dev/null || echo "unknown")
if [ "$STATUS" != "Accepted" ]; then
    echo "[ERRORE] Notarizzazione fallita (status: $STATUS)."
    echo "    Log: $BUILD_DIR/notarization_result.plist"
    exit 1
fi
echo "    OK — notarizzazione accettata"

# ── 4b. Stapling ──────────────────────────────────────────────────────────────

echo ""
echo "==> 4b  Stapling biglietto notarizzazione…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
echo "    OK"

# ── 5. DMG ────────────────────────────────────────────────────────────────────

echo ""
echo "==> 5/5  Creazione DMG…"

DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "MusiFix $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"
echo "    OK: $DMG_PATH"

# ── Riepilogo ─────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " MusiFix v$VERSION — packaging completato"
echo " DMG: $DMG_PATH"
echo " $(du -sh "$DMG_PATH" | cut -f1)  —  $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
