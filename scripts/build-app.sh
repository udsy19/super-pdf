#!/bin/bash
# Builds build/Super PDF.app (release by default; `--debug` for a fast debug build; UNIVERSAL=1 for Apple silicon +
# Intel) and signs it with the project-local identity from scripts/signing-setup.sh (falls back to ad hoc).
# QPDF is linked statically from Vendor/QPDF.xcframework (`scripts/build-qpdf.sh fetch` once per checkout), so the app
# embeds no frameworks. The Finder Quick Actions are four app extensions in Contents/PlugIns sharing one executable
# (SuperPDFQuickActions, entered through NSExtensionMain), each with its Info.plist from Resources/QuickActions; they
# are sandboxed and signed before the app that seals them. The icon (scripts/make-icon.swift), the licences and the
# SwiftPM resource bundles go into Contents/Resources. The script ends with static launch checks (nothing is launched
# and no window opens): entitlements, rpaths, every @rpath dependency present, executables and entry points, the
# extensions, resources and Info.plist.
# Adapted from super-granola scripts/build-app.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CONFIG=release; [ "${1:-}" = "--debug" ] && CONFIG=debug
APP_EXE=SuperPDF
EXT_EXE=SuperPDFQuickActions
PRODUCTS=("$APP_EXE" "$EXT_EXE")
[ -d "$ROOT/Vendor/QPDF.xcframework" ] || { echo "error: Vendor/QPDF.xcframework is missing; run scripts/build-qpdf.sh fetch" >&2; exit 1; }
if [ "${UNIVERSAL:-0}" = 1 ]; then
  # Build each architecture separately (the CLT toolchain has no multi-arch build) and merge with lipo.
  for arch in arm64 x86_64; do
    # The Command Line Tools ship the Swift back-deployment compatibility libraries for arm64 only, and packages built for
    # older systems (swift-crypto, swift-certificates) ask for them; macOS 14 has everything they back-deploy, so skip them.
    for product in "${PRODUCTS[@]}"; do swift build -c "$CONFIG" --product "$product" --triple "$arch-apple-macosx14.0" -Xswiftc -runtime-compatibility-version -Xswiftc none; done
  done
  ARM="$(swift build -c "$CONFIG" --triple arm64-apple-macosx14.0 --show-bin-path)"
  INTEL="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN="$ROOT/build/universal"; mkdir -p "$BIN"; RES_BIN="$ARM"
  for product in "${PRODUCTS[@]}"; do lipo -create -output "$BIN/$product" "$ARM/$product" "$INTEL/$product"; done
else
  for product in "${PRODUCTS[@]}"; do swift build -c "$CONFIG" --product "$product"; done
  BIN="$(swift build -c "$CONFIG" --show-bin-path)"; RES_BIN="$BIN"
fi

APP="$ROOT/build/Super PDF.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp "$BIN/$APP_EXE" "$APP/Contents/MacOS/$APP_EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
# Licences travel with the app (Apache-2.0 NOTICE texts, the IJG line); SwiftPM resource bundles (swift-crypto's
# privacy manifests) sit where Bundle.module looks for them.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
find "$RES_BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# The Quick Actions: one bundle per action around the shared executable, its version the app's.
EXTENSIONS=()
for plist in "$ROOT"/Resources/QuickActions/*.plist; do
  name="$(basename "$plist" .plist)"
  ext="$APP/Contents/PlugIns/$name.appex"
  mkdir -p "$ext/Contents/MacOS"
  cp "$BIN/$EXT_EXE" "$ext/Contents/MacOS/$EXT_EXE"
  cp "$plist" "$ext/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$ext/Contents/Info.plist"
  EXTENSIONS+=("$ext")
done

# rpaths: SwiftPM adds build-tree and toolchain rpaths; the bundle needs none of them (Swift comes from /usr/lib/swift).
for exe in "$APP/Contents/MacOS/$APP_EXE" "${EXTENSIONS[@]/%//Contents/MacOS/$EXT_EXE}"; do
  while IFS= read -r rpath; do
    [ -n "$rpath" ] && install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null || true
  done < <(otool -l "$exe" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep -E '\.build/|CommandLineTools|Xcode' || true)
done

# The icon, re-rendered when the script changes.
ICONS="$ROOT/build/icons"
if [ ! -f "$ICONS/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICONS/AppIcon.icns" ]; then
  rm -rf "$ICONS"
  swift "$ROOT/scripts/make-icon.swift" "$ICONS" && iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"
fi
cp "$ICONS/AppIcon.icns" "$APP/Contents/Resources/"

KC="$ROOT/.signing/super-pdf.keychain-db"
ENT="$ROOT/Resources/SuperPDF.entitlements"
EXT_ENT="$ROOT/Resources/QuickActions/QuickActions.entitlements"
IDENTITY="Super PDF Local Signing"
FRAMEWORKS=()
[ -d "$APP/Contents/Frameworks" ] && while IFS= read -r fw; do FRAMEWORKS+=("$fw"); done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework')
if [ -f "$KC" ]; then
  security unlock-keychain -p superpdf "$KC"
  ORIG=()
  while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; line="${line//\"/}"; [ -n "$line" ] && ORIG+=("$line"); done < <(security list-keychains -d user)
  # The project keychain joins the search list only while codesign runs; the trap puts the user's list back even
  # when signing fails.
  restore() { security list-keychains -d user -s "${ORIG[@]}"; }
  trap restore EXIT
  security list-keychains -d user -s "${ORIG[@]}" "$KC"
  # Nested code first (frameworks, then the extensions), then the bundle that seals it.
  for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do codesign -f -s "$IDENTITY" --keychain "$KC" -o runtime "$fw"; done
  for ext in "${EXTENSIONS[@]}"; do codesign -f -s "$IDENTITY" --keychain "$KC" -o runtime --entitlements "$EXT_ENT" "$ext"; done
  codesign -f -s "$IDENTITY" --keychain "$KC" -o runtime --entitlements "$ENT" "$APP"
  restore; trap - EXIT
else
  echo "warning: no project signing identity (run scripts/signing-setup.sh); signing ad hoc, so privacy grants won't survive rebuilds" >&2
  for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do codesign -f -s - "$fw"; done
  for ext in "${EXTENSIONS[@]}"; do codesign -f -s - -o runtime --entitlements "$EXT_ENT" "$ext"; done
  codesign -f -s - -o runtime --entitlements "$ENT" "$APP"
fi
codesign --verify --deep --strict "$APP"

# ---- Static launch checks. The app is never launched here (no GUI on a build machine); instead everything that would
# make it abort at launch, or lose a feature silently, is checked on disk.
fail() { echo "error: $*" >&2; exit 1; }
EXE="$APP/Contents/MacOS/$APP_EXE"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
# Embedded frameworks would be signed without an Apple Team ID, so the hardened runtime refuses to load them unless
# library validation is off. Without this the app aborts at launch; fail the build instead.
if [ ${#FRAMEWORKS[@]} -gt 0 ] && ! grep -q disable-library-validation <<< "$ENTITLEMENTS"; then
  fail "$APP embeds frameworks but lacks com.apple.security.cs.disable-library-validation"
fi
for entitlement in com.apple.security.device.camera com.apple.security.device.audio-input \
                   com.apple.security.personal-information.addressbook com.apple.security.automation.apple-events; do
  grep -q "$entitlement" <<< "$ENTITLEMENTS" || fail "entitlement $entitlement missing (the hardened runtime would refuse it)"
done
if grep -q com.apple.security.app-sandbox <<< "$ENTITLEMENTS"; then fail "the app must not be sandboxed"; fi
# Executables and their dependencies: no rpath or library in the build tree or the toolchain, every @rpath dependency
# inside Contents/Frameworks.
BINARIES=("$EXE")
for ext in "${EXTENSIONS[@]}"; do BINARIES+=("$ext/Contents/MacOS/$EXT_EXE"); done
for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do name="$(basename "$fw" .framework)"; BINARIES+=("$fw/Versions/Current/$name"); done
for bin in "${BINARIES[@]}"; do
  [ -x "$bin" ] || fail "missing executable $bin"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    rel="${dep#@rpath/}"
    [ -e "$APP/Contents/Frameworks/$rel" ] || fail "$(basename "$bin") depends on $dep, which is not in Contents/Frameworks"
  done < <(otool -L "$bin" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }' | sort -u)
  if grep -qE '\.build/|CommandLineTools|Xcode' <<< "$(otool -L "$bin" | awk 'NR > 1 { print $1 }')"; then fail "$(basename "$bin") links into the build tree"; fi
  if grep -qE '\.build/|CommandLineTools|Xcode' <<< "$(otool -l "$bin" | awk '/LC_RPATH/ {getline; getline; print $2}')"; then
    fail "$(basename "$bin") has a build-tree rpath"
  fi
done
# NSDocument finds the PDF document class by the name Info.plist gives it.
grep -q '_OBJC_CLASS_\$_SuperPDFDocument' <<< "$(nm -m "$EXE")" || fail "the executable has no SuperPDFDocument class for Info.plist's NSDocumentClass"
# Info.plist: the executable, the bundle id, the URL scheme, document types, the Services item, every usage string.
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null; }
[ "$(plist CFBundleExecutable)" = "$APP_EXE" ] || fail "CFBundleExecutable is not $APP_EXE"
[ "$(plist CFBundleIdentifier)" = "com.udsy.superpdf" ] || fail "CFBundleIdentifier is not com.udsy.superpdf"
[ "$(plist :CFBundleURLTypes:0:CFBundleURLSchemes:0)" = "superpdf" ] || fail "the superpdf:// scheme is not registered"
[ "$(plist :CFBundleDocumentTypes:0:LSItemContentTypes:0)" = "com.adobe.pdf" ] && [ "$(plist :CFBundleDocumentTypes:0:NSDocumentClass)" = "SuperPDFDocument" ] \
  || fail "PDF is not the first document type with NSDocumentClass SuperPDFDocument"
[ "$(plist :NSServices:0:NSMessage)" = "openSelectionAsPDF" ] || fail "the Services item (Open Selection as PDF) is missing"
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSContactsUsageDescription NSAppleEventsUsageDescription \
           NSDesktopFolderUsageDescription NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription; do
  plist "$key" >/dev/null || fail "Info.plist lacks $key"
done
[ "$(plist NSCameraUseContinuityCameraDeviceType)" = "true" ] || fail "Continuity Camera isn't enabled (NSCameraUseContinuityCameraDeviceType)"
# The Quick Actions: sandboxed extensions entered through NSExtensionMain, ids under the app's, versions the app's.
[ ${#EXTENSIONS[@]} -eq 4 ] || fail "expected four Quick Action extensions, found ${#EXTENSIONS[@]}"
grep -q '_OBJC_CLASS_\$_QuickActionRequestHandler' <<< "$(nm -m "$BIN/$EXT_EXE")" || fail "the Quick Actions have no QuickActionRequestHandler class"
for ext in "${EXTENSIONS[@]}"; do
  info() { /usr/libexec/PlistBuddy -c "Print $1" "$ext/Contents/Info.plist" 2>/dev/null; }
  [ "$(info :NSExtension:NSExtensionPointIdentifier)" = "com.apple.services" ] || fail "$(basename "$ext"): not an action extension"
  [ "$(info :NSExtension:NSExtensionPrincipalClass)" = "QuickActionRequestHandler" ] || fail "$(basename "$ext"): wrong principal class"
  [[ "$(info CFBundleIdentifier)" == com.udsy.superpdf.quickactions.* ]] || fail "$(basename "$ext"): its bundle id isn't under the app's"
  [ "$(info CFBundleShortVersionString)" = "$VERSION" ] && [ "$(info CFBundleVersion)" = "$BUILD" ] || fail "$(basename "$ext"): version differs from the app's"
  info SuperPDFQuickAction >/dev/null || fail "$(basename "$ext"): no SuperPDFQuickAction key"
  grep -q LC_MAIN <<< "$(otool -l "$ext/Contents/MacOS/$EXT_EXE")" || fail "$(basename "$ext"): no entry point"
  grep -q '(undefined) external _NSExtensionMain' <<< "$(nm -m "$ext/Contents/MacOS/$EXT_EXE")" || fail "$(basename "$ext"): not entered through NSExtensionMain"
  grep -q com.apple.security.app-sandbox <<< "$(codesign -d --entitlements :- "$ext" 2>/dev/null)" || fail "$(basename "$ext"): not sandboxed"
done
# Resources the app expects at runtime.
for res in Resources/AppIcon.icns Resources/LICENSE Resources/THIRD_PARTY_NOTICES.md PkgInfo; do
  [ -e "$APP/Contents/$res" ] || fail "missing $res in the bundle"
done
echo "Static launch checks passed: entitlements, rpaths, dependencies, entry points, Quick Actions, resources, Info.plist"
echo "Built $APP"
