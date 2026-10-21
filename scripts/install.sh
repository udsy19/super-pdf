#!/bin/bash
# Super PDF installer (adapted from super-granola scripts/install.sh, itself from super-flow).
#
#   Install / update:  curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash
#   Uninstall:         curl -fsSL https://udsy19.github.io/super-pdf/install.sh | bash -s -- --uninstall
#
# Downloads the latest release from GitHub, installs it into /Applications (or ~/Applications when /Applications
# isn't writable) and opens it. Nothing else on your system is changed.
# Options (environment): SUPERPDF_INSTALL_DIR=<folder> to install elsewhere, SUPERPDF_NO_OPEN=1 to skip launching.
set -euo pipefail

REPO="udsy19/super-pdf"
APP="Super PDF.app"
DMG_URL="https://github.com/$REPO/releases/latest/download/SuperPDF.dmg"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

# Asks a running copy to quit and waits up to five seconds for it.
quit_running() {
  pgrep -x SuperPDF >/dev/null 2>&1 || return 0
  step "Quitting the running copy of Super PDF"
  osascript -e 'tell application id "com.udsy.superpdf" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SuperPDF >/dev/null 2>&1 || return 0; sleep 0.5; done
  fail "Super PDF is still running. Quit it from its Dock icon and run the installer again."
}

# Every installed copy, one path per line.
installed_paths() {
  for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir/$APP" ] && printf '%s\n' "$dir/$APP"
  done
  return 0
}

[ "$(uname -s)" = "Darwin" ] || fail "Super PDF runs on macOS only."

if [ "${1:-}" = "--uninstall" ]; then
  paths="$(installed_paths)"
  [ -n "$paths" ] || fail "Super PDF isn't installed."
  quit_running
  while IFS= read -r path; do
    step "Removing $path"
    rm -rf "$path"
  done <<< "$paths"
  # The Print dialog's "Save to Super PDF" item, if Super PDF added it: a link to the app just removed.
  item="$HOME/Library/PDF Services/Save to Super PDF"
  if [ -L "$item" ] && [ ! -e "$item" ]; then
    step "Removing $item"
    rm -f "$item"
  fi
  say "${green}✓ Super PDF was uninstalled.${reset}"
  say "${dim}Your signatures, routines, signature requests and settings were kept in ~/Library/Application Support/Super PDF and${reset}"
  say "${dim}~/Library/Preferences/com.udsy.superpdf.plist — delete them to remove everything.${reset}"
  exit 0
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Super PDF needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

say "${bold}Installing Super PDF${reset} ${dim}— every PDF tool, with the window of Preview, all on your Mac${reset}"
tmp="$(mktemp -d -t superpdf-install)"
mnt="$tmp/mount"
cleanup() { hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

step "Downloading the latest release"
curl -fL --progress-bar -o "$tmp/SuperPDF.dmg" "$DMG_URL" || fail "Download failed — check your connection and try again."

step "Verifying the disk image"
hdiutil verify "$tmp/SuperPDF.dmg" -quiet || fail "The download is damaged. Please try again."
mkdir -p "$mnt"
hdiutil attach "$tmp/SuperPDF.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet || fail "Couldn't open the disk image."
[ -d "$mnt/$APP" ] || fail "The disk image doesn't contain $APP."

dest="${SUPERPDF_INSTALL_DIR:-/Applications}"
mkdir -p "$dest" 2>/dev/null || true
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"; mkdir -p "$dest"
fi

[ "${SUPERPDF_NO_OPEN:-0}" = 1 ] || quit_running
step "Installing to $dest"
rm -rf "$dest/$APP"
ditto "$mnt/$APP" "$dest/$APP"
# Downloads made with curl aren't quarantined; clear the flag anyway in case the image was cached by a browser.
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "${SUPERPDF_NO_OPEN:-0}" = 1 ]; then
  say "${green}✓ Super PDF ${version} is installed in $dest.${reset}"
else
  say "${green}✓ Super PDF ${version} is installed.${reset} Opening it now."
  open "$dest/$APP"
fi
