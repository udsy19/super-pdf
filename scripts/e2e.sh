#!/bin/bash
# End to end with the real app: builds build/Super PDF.app, launches it on throwaway data, and drives that one process
# through Accessibility as a person would: open a PDF, open Tools, Make smaller, Combine (with a second file, saved),
# Black out a word, Sign (a typed signature placed on the page, Sign and save…), To Word; then checks every output on
# disk (scripts/e2e-check.swift, the same checks the self-test runs on headless outputs) and opens each PDF again.
#
#   scripts/e2e.sh                   build (debug) and run
#   E2E_SKIP_BUILD=1 scripts/e2e.sh  run the app already in build/
#   E2E_CLEAN=1 scripts/e2e.sh       remove the run's folder afterwards (kept by default, to look at)
#
# Needs: the Terminal (or whichever app runs this) allowed under System Settings › Privacy & Security › Accessibility.
# Don't touch the mouse or keyboard while it runs: it brings Super PDF to the front and stops if anything else takes it.
# What it touches: build/e2e/<run>/ (the files, the app's Application Support, its log); a throwaway defaults suite whose
# plist (~/Library/Preferences/superpdf-e2e-<uuid>.plist) is removed at the end; macOS registers the build with
# LaunchServices when it starts. It never starts the updater, the PDF Services offer or window restoration, and it
# quits only the process it started (its own PID).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
APP="$ROOT/build/Super PDF.app"
RUN="$ROOT/build/e2e/run-$(date +%Y%m%d-%H%M%S)"
FILES="$RUN/files"
SUITE="superpdf-e2e-$(uuidgen | tr '[:upper:]' '[:lower:]')"
PID=""

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'E2E FAILED: %s\n' "$*" >&2; exit 1; }

osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1 \
  || fail "this terminal can't use Accessibility; allow it in System Settings › Privacy & Security › Accessibility"

if [ "${E2E_SKIP_BUILD:-0}" != 1 ]; then
  [ -d "$ROOT/Vendor/QPDF.xcframework" ] || scripts/build-qpdf.sh fetch
  ./scripts/build-app.sh --debug
fi
[ -x "$APP/Contents/MacOS/SuperPDF" ] || fail "no app at $APP"

# Fixtures go in build/e2e, not the temporary folder: PDFs there open as "printed" new documents (features #48).
mkdir -p "$FILES"
swift scripts/e2e-check.swift fixtures "$FILES"

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
  [ -f "$HOME/Library/Preferences/$SUITE.plist" ] && rm -f "$HOME/Library/Preferences/$SUITE.plist"
  if [ "${E2E_CLEAN:-0}" = 1 ]; then rm -rf "$RUN"; else echo "The run's files are in $RUN"; fi
}
trap cleanup EXIT

say "Launching the build on throwaway data"
SUPERPDF_DATA_DIR="$RUN/data" SUPERPDF_DEFAULTS_SUITE="$SUITE" \
  "$APP/Contents/MacOS/SuperPDF" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO >"$RUN/app.log" 2>&1 &
PID=$!
# Keys, typing and windows go through System Events (e2e-drive.applescript); finding and pressing controls goes through the
# Accessibility API (e2e-ax.swift, compiled once), which reads the labels SwiftUI controls give VoiceOver.
mkdir -p "$RUN/bin"
swiftc -O scripts/e2e-ax.swift -o "$RUN/bin/e2e-ax" 2>"$RUN/bin/swiftc.log" || { cat "$RUN/bin/swiftc.log" >&2; fail "couldn't build scripts/e2e-ax.swift"; }
sysevents() { osascript "$ROOT/scripts/e2e-drive.applescript" "$PID" "$@"; }
ax() { "$RUN/bin/e2e-ax" "$PID" "$@"; }
drive() {
  case "$1" in
    wait-element) ax wait "${@:2}" ;;
    click) ax press "${@:2}" ;;
    fill) ax focus "$2" && sysevents type "$3" ;; # fill <placeholder> <text>
    click-in|click-page) ax "$@" ;;
    *) sysevents "$@" ;;
  esac >/dev/null || { "$RUN/bin/e2e-ax" "$PID" dump >"$RUN/failed-step-screen.txt" 2>&1; fail "step failed: $* (what was on screen: $RUN/failed-step-screen.txt)"; }
}
wait_file() { # path seconds
  for _ in $(seq 1 "$2"); do [ -s "$1" ] && return 0; kill -0 "$PID" 2>/dev/null || fail "the app quit (see $RUN/app.log)"; sleep 1; done
  fail "timed out waiting for $(basename "$1")"
}
tools() { # search text: ⌘T, type, Return (the first result opens)
  drive keys t command; sleep 1
  drive type "$1"; sleep 0.5
  drive press return; sleep 1.5
}
for _ in $(seq 1 30); do [ "$(sysevents ready 2>/dev/null)" = "true" ] && break; sleep 1; done
sleep 2

say "Open a PDF"
open -a "$APP" "$FILES/Lease.pdf"
drive wait-window "Lease" 30

say "Tools › Make smaller"
tools "smaller"
drive wait-element "Make smaller" 10
drive click "Make smaller"
wait_file "$FILES/Lease (smaller).pdf" 120
drive wait-window "Lease (smaller)" 30
drive keys w command; sleep 1

say "Tools › Combine files, with Schedule.pdf, saved as Combined.pdf"
tools "combine"
drive click "Files"; sleep 1.5
drive goto "$FILES/Schedule.pdf"; sleep 1
drive press return; sleep 1
drive click "Combine 2 files"
drive wait-window "Combined" 60
# A document made here asks where to save it, proposing "Combined.pdf": keep the name, choose the folder.
drive keys s command; sleep 1.5
drive goto "$FILES"; sleep 1
drive press return
wait_file "$FILES/Combined.pdf" 60
drive keys w command; sleep 1

say "Tools › Black out “CONFIDENTIAL”"
tools "black out"
drive click "Find and mark"; sleep 1
drive fill "Words to find" "CONFIDENTIAL"; sleep 2
drive click "Black out 1" prefix; sleep 1
drive click "Black out"
wait_file "$FILES/Lease (blacked out).pdf" 120
drive wait-window "Lease (blacked out)" 30
drive keys w command; sleep 1

say "Tools › Sign: a typed signature, placed on the page, Sign and save…"
tools "sign"
drive click "Create signature…"; sleep 1.5
drive click "Type"; sleep 0.5
drive fill "Your name" "Udaya Vijay Anand"; sleep 0.5
drive click "Save signature"; sleep 1.5
drive click-in "My signature" 0.5 0.12; sleep 0.5
drive click-page 0.5 0.55; sleep 1
drive click "Sign and save…"; sleep 1.5
drive press return
wait_file "$FILES/Lease (signed).pdf" 60
drive wait-window "Lease (signed)" 30
drive keys w command; sleep 1

say "Tools › To Word"
tools "word"
drive click "Save as Word…"; sleep 1.5
drive press return
wait_file "$FILES/Lease.docx" 120

say "Checking the outputs on disk"
swift scripts/e2e-check.swift verify "$FILES" || fail "the outputs don't check out"

say "Opening each output again"
for name in "Lease (smaller)" "Combined" "Lease (blacked out)" "Lease (signed)"; do
  open -a "$APP" "$FILES/$name.pdf"
  drive wait-window "$name" 30
done

say "Quitting"
drive keys q command
for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$PID" 2>/dev/null; then
  # A document asked about unsaved changes: discard them (the run's own documents only).
  ax press "Discard Changes" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
fi
PID_LEFT="$PID"
kill -0 "$PID_LEFT" 2>/dev/null && fail "the app didn't quit"
PID=""
echo "E2E PASSED"
