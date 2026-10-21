#!/bin/bash
# Builds the universal DMG and publishes it as a GitHub release.
#   ./scripts/release.sh 1.0.1
# The asset is uploaded twice: "SuperPDF-<version>.dmg" and a stable "SuperPDF.dmg", which the one-line installer and
# UpdateKit download from (https://github.com/<repo>/releases/latest/download/SuperPDF.dmg). The notes end with the line
# UpdateKit verifies the download against: SHA-256 (SuperPDF.dmg): `<hex>`. The app is signed with the project-local
# identity (scripts/signing-setup.sh); the updater only installs updates signed by the same one, so never change it.
# Adapted from super-granola scripts/release.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${1:?usage: release.sh <version>}"
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
[ -f "$ROOT/.signing/super-pdf.keychain-db" ] || { echo "No project signing identity: run scripts/signing-setup.sh (once, and keep .signing/)" >&2; exit 1; }
[ -d "$ROOT/Vendor/QPDF.xcframework" ] || scripts/build-qpdf.sh fetch
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(( $(git rev-list --count HEAD) + 1 )); /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
git add Resources/Info.plist
git diff --cached --quiet || git commit -q -m "Release $VERSION"
git push -q origin HEAD
./scripts/make-dmg.sh
cp "dist/SuperPDF-$VERSION.dmg" dist/SuperPDF.dmg
SHA=$(shasum -a 256 dist/SuperPDF.dmg | cut -d' ' -f1)
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\["v"\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
git tag -s "v$VERSION" -m "Super PDF $VERSION" 2>/dev/null || git tag "v$VERSION" -m "Super PDF $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "dist/SuperPDF-$VERSION.dmg" dist/SuperPDF.dmg --title "Super PDF $VERSION" \
  --notes "$NOTES

**Install:** \`curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash\` — or download the DMG below.

SHA-256 (SuperPDF.dmg): \`$SHA\`"
