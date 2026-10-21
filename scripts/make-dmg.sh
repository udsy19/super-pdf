#!/bin/bash
# Produces dist/SuperPDF-<version>.dmg: universal (Apple silicon + Intel) app, drag-to-Applications layout, and install
# notes for Gatekeeper (the app is self-signed, not notarized). Adapted from super-granola scripts/make-dmg.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

UNIVERSAL=1 ./scripts/build-app.sh

STAGE="$ROOT/build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "build/Super PDF.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install Super PDF.txt" <<TXT
Installing Super PDF $VERSION
==========================

1. Drag Super PDF into the Applications folder.
2. Open Super PDF from Applications. macOS will say it "cannot be opened" because the app
   is not notarized by Apple. Click Done.
3. Open System Settings → Privacy & Security, scroll down and click "Open Anyway" next to
   the Super PDF message, then confirm with your password.
   (Alternatively, in Terminal: xattr -dr com.apple.quarantine "/Applications/Super PDF.app")
4. Open a PDF, or drop any file on the window to turn it into one. Everything happens on your Mac.

Finder's Quick Actions (Combine in Super PDF, Make Smaller, Convert to PDF, Recognise Text) appear
after the first launch; turn them on in System Settings → General → Login Items & Extensions if they don't.

Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.
TXT

mkdir -p dist
DMG="dist/SuperPDF-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Super PDF $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
