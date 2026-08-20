#!/usr/bin/env bash
#
# study-release.sh — archive → export (Developer ID) → DMG → notarize → staple,
# for the manually distributed THESIS study artefact.
#
# This is the deliberate counterpart to release.sh, which refuses to run anywhere
# but `main`. Nothing here touches appcast.xml, GitHub releases, or the Sparkle
# signing key: a participant build must never be able to update itself, and must
# never appear in the public feed. The invariants that guarantee this are checked
# against the EXPORTED bundle, not against intent — the same four StudyBuild
# checks the app runs on itself at launch.
#
# Prereqs are identical to release.sh:
#   1. A "Developer ID Application" cert in the login keychain.
#   2. Stored notarytool credentials under the AIDrop-Notary profile.
#
# Usage:
#   scripts/study-release.sh                 # signed + notarized + stapled
#   SKIP_NOTARIZE=1 scripts/study-release.sh # signed only — local testing ONLY,
#                                            # never hand this to a participant.
#
# Output: build/study/Dragaway-Study-<version>.dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Guards ───────────────────────────────────────────────────────────────────
# Mirror image of release.sh's guard. A study DMG built from main would carry the
# Sparkle feed and update itself out from under a participant mid-study.
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
if [[ "$CURRENT_BRANCH" != "thesis" ]]; then
  echo "✗ study build blocked: current branch is '$CURRENT_BRANCH', not 'thesis'." >&2
  echo "  Public releases belong on main, via scripts/release.sh." >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :DragawayStudyBuild' \
    "$REPO_ROOT/MacNotchAI/Info.plist" 2>/dev/null | grep -qx 'true'; then
  echo "✗ study build blocked: source Info.plist is not marked DragawayStudyBuild." >&2
  exit 1
fi

PROJECT="MacNotchAI.xcodeproj"
SCHEME="MacNotchAI"
APP_NAME="MacNotchAI"
NOTARY_PROFILE="${NOTARY_PROFILE:-AIDrop-Notary}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-Developer ID Application: Moritz Wallbrecher (ASN2KAJ266)}"

# A separate tree from build/ on purpose: Sparkle's generate_appcast ingests EVERY
# archive it finds in the directory it is pointed at, so a study DMG must never
# share one with a public release.
BUILD_DIR="$REPO_ROOT/build/study"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGE_DIR="$BUILD_DIR/dmg-stage"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

run_xcb() {
  local log="$1"; shift
  if ! xcodebuild "$@" > "$log" 2>&1; then
    echo "✗ xcodebuild failed — error lines:" >&2
    grep -E "error:" "$log" | head -20 >&2 || true
    echo "  (full log: $log)" >&2
    exit 1
  fi
}

echo "▸ 1/6  Archiving (Release, THESIS_STUDY_BUILD)…"
run_xcb "$BUILD_DIR/archive.log" \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  clean archive

echo "▸ 2/6  Exporting (Developer ID)…"
run_xcb "$BUILD_DIR/export.log" \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$REPO_ROOT/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || { echo "✗ exported .app not found in $EXPORT_DIR" >&2; exit 1; }
echo "  exported: $APP_PATH"

# ── Invariants, checked on the artefact itself ───────────────────────────────
# Identical to StudyBuild.invariantViolations. The app refuses to arm a study when
# any of these fail; checking here means a violating DMG is never produced in the
# first place, rather than discovered by a participant.
echo "▸ 3/6  Verifying study-distribution invariants…"
APP_PLIST="$APP_PATH/Contents/Info.plist"
VIOLATIONS=()

read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PLIST" 2>/dev/null || true; }

[[ "$(read_key DragawayStudyBuild)" == "true" ]] \
  || VIOLATIONS+=("bundle study marker is missing")
[[ -z "$(read_key SUFeedURL)" ]] \
  || VIOLATIONS+=("public Sparkle feed is embedded")
[[ -z "$(read_key SUPublicEDKey)" ]] \
  || VIOLATIONS+=("public Sparkle signing key is embedded")
[[ "$(read_key SUEnableAutomaticChecks)" == "false" ]] \
  || VIOLATIONS+=("automatic update checks are not explicitly disabled")
if /usr/bin/find "$APP_PATH/Contents/Frameworks" -iname '*sparkle*' -maxdepth 1 2>/dev/null \
     | grep -q .; then
  VIOLATIONS+=("a Sparkle framework is embedded")
fi

if (( ${#VIOLATIONS[@]} > 0 )); then
  echo "✗ this build must not be distributed to participants:" >&2
  printf '    · %s\n' "${VIOLATIONS[@]}" >&2
  exit 1
fi
echo "  ✓ no update feed, no signing key, no Sparkle framework, marker present"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PLIST" 2>/dev/null || echo 0.0.0)"
# Named apart from the public Dragaway-<version>.dmg so the two artefacts can never
# be confused in a downloads folder or an upload dialog.
DMG="$BUILD_DIR/Dragaway-Study-$VERSION.dmg"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "▸ 4/6  Skipping notarization (SKIP_NOTARIZE=1) — building unsigned-ticket DMG…"
  rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
  cp -R "$APP_PATH" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"
  hdiutil create -volname "Dragaway Study" \
    -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG" >/dev/null
  echo
  echo "⚠ NOT notarized: $DMG"
  echo "  Local testing only. Never hand this to a participant."
  exit 0
fi

# The APP is notarized and stapled BEFORE the DMG is built, not only the DMG.
# A stapled disk image says nothing about the bundle a participant drags out of
# it: once copied to /Applications, an unstapled app forces Gatekeeper to ask
# Apple online, and on a machine that is offline, behind a filtering network, or
# simply unlucky, launching then fails outright. Stapling the app makes the first
# launch work with no network at all.
echo "▸ 4/6  Notarizing the app (this can take a few minutes)…"
APP_ZIP="$BUILD_DIR/$(basename "$APP_PATH" .app)-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$APP_ZIP"
echo "  ✓ app carries its own notarization ticket"

echo "▸ 5/6  Building and notarizing the DMG…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "Dragaway Study" \
  -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▸ 6/6  Verifying both tickets…"
xcrun stapler validate "$DMG"
# Proves the artefact a participant actually ends up with is self-sufficient.
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
if ! xcrun stapler validate "$MNT"/*.app >/dev/null 2>&1; then
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  echo "✗ the app inside the DMG has no stapled ticket — it would need Apple's" >&2
  echo "  server at first launch on the participant's machine. Not shippable." >&2
  exit 1
fi
hdiutil detach "$MNT" >/dev/null 2>&1 || true
echo "  ✓ DMG and the app inside it are both stapled"

echo
echo "✓ Study artefact ready: $DMG"
echo
echo "  Deliberately NOT done, and not to be done by hand afterwards:"
echo "   · no appcast.xml entry   — participants must not receive updates mid-study"
echo "   · no GitHub release      — this artefact is handed over directly"
echo "   · no tag, no push        — the public version history stays main's"
echo
echo "  Before handing it over, on a Mac that has never run it:"
echo "   1. Open the DMG — no Gatekeeper warning should appear."
echo "   2. Launch, then check the menu shows 'Intent Engine (Thesis)'."
echo "   3. Settings → the app must NOT offer 'Check for Updates…'."
echo
echo "  Send this checksum with the file. Messenger apps re-encode attachments,"
echo "  and a truncated DMG fails in ways that look like a signing problem:"
shasum -a 256 "$DMG"
