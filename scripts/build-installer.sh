#!/usr/bin/env bash
# Genera un instalador limpio de CuyAppleReport: compila Release desde cero, firma sin
# permisos de depuración y crea dist/CuyAppleReport-<versión>.dmg con acceso directo a Aplicaciones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

echo "→ Compilando Release (limpio)…"
xcodebuild -project CuyAppleReport.xcodeproj -scheme CuyAppleReport -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/DerivedData" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO clean build -quiet

APP="$WORK/DerivedData/Build/Products/Release/CuyAppleReport.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "→ Firmando (ad hoc, solo con los entitlements de la app)…"
xattr -cr "$APP"
codesign --force --deep --sign - --entitlements CuyAppleReport/CuyAppleReport.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "✗ La app todavía tiene get-task-allow" >&2
  exit 1
fi

echo "→ Creando DMG…"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/CuyAppleReport-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "CuyAppleReport $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "✓ Instalador listo: $DMG ($(du -h "$DMG" | cut -f1))"
