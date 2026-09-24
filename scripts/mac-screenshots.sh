#!/usr/bin/env bash
#
# Regenerate the Mac screenshots from the real apps — the eight on
# docs/index.html, plus `demo-history`, which isn't on the page but keeps the
# Demo-mode fixtures visible.
#
#   ./scripts/mac-screenshots.sh                  # every shot
#   ./scripts/mac-screenshots.sh today companion  # just these
#   BUILD_ONLY=1 ./scripts/mac-screenshots.sh     # compile both apps, capture nothing
#
# Each capture opens a window on screen, so name the shots you need rather
# than re-running the lot; an app with no shots named isn't even built.
#
# Both Mac apps carry a developer-only "screenshot mode" (inert unless
# DICTATOR_SCREENSHOT is set — see Sources/DictatorCore/Screenshots/
# ScreenshotMode.swift). Each run of this script:
#
#   1. copies project.yml to a temp spec with the `postBuildScripts:` blocks
#      stripped, so the build cannot overwrite (or ad-hoc re-sign) the user's
#      installed ~/Applications/Dictator.app and Dictator Meetings.app;
#   2. builds both schemes into a scratch derived-data directory;
#   3. runs each app once per shot, with a throwaway data root —
#      every settings / history / meeting / model / keychain path is redirected
#      there, so a capture never reads or writes the user's own data, and the
#      single-instance guard is skipped so the user's running copies are left
#      alone;
#   4. down-samples the PNGs and copies them into docs/media/;
#   5. restores the real project with ./gen.
#
# Safe to re-run. Requires .env (DICTATOR_TEAM_ID etc.) and Xcode (the beta if
# it's installed, otherwise the release).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DICTATOR_SHOTS="modes hud-styles assistant-draft journal chat demo-history"
MEETINGS_SHOTS="today companion live-recording notes coach"
WANT="$*"
wanted() { [ -z "$WANT" ] || [[ " $WANT " == *" $1 "* ]]; }
any_wanted() { local s; for s in $1; do wanted "$s" && return 0; done; return 1; }
for s in $WANT; do
  [[ " $DICTATOR_SHOTS $MEETINGS_SHOTS " == *" $s "* ]] || { echo "Unknown shot: $s" >&2; exit 64; }
done
cd "$REPO"

WORK="${DICTATOR_SHOTS_WORK:-$REPO/.screenshots-work}"
DD="$WORK/derived"
RAW="$WORK/raw"
SPEC="$WORK/project-noinstall.yml"
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode-beta.app ]; then
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
export DEVELOPER_DIR

mkdir -p "$WORK" "$RAW"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. temp spec
say "Stripping postBuildScripts from project.yml"
python3 - "$REPO/project.yml" "$SPEC" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
out, i, removed = [], 0, 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()
    if stripped.startswith("postBuildScripts:"):
        indent = len(line) - len(stripped)
        removed += 1
        i += 1
        # The block ends at the next non-blank line indented no further than
        # the key itself — found by indentation, never by line number.
        while i < len(lines):
            nxt = lines[i]
            if not nxt.strip():
                i += 1
                continue
            if len(nxt) - len(nxt.lstrip()) <= indent:
                break
            i += 1
        continue
    out.append(line)
    i += 1
open(dst, "w").write("\n".join(out))
print(f"stripped {removed} postBuildScripts block(s)")
if removed != 2:
    sys.exit("expected 2 postBuildScripts blocks — check project.yml")
PY

set -a; . ./.env; set +a
xcodegen generate --spec "$SPEC" --project-root "$REPO" --project "$REPO" >/dev/null

# ------------------------------------------------------------------- 2. builds
build() {
  local scheme="$1" log="$WORK/build-$1.log"
  say "Building $scheme"
  xcodebuild -project Dictator.xcodeproj -scheme "$scheme" -configuration Debug \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || true
  local compiles succeeded
  compiles=$(grep -c '^SwiftCompile' "$log" || true)
  succeeded=$(grep -c 'BUILD SUCCEEDED' "$log" || true)
  echo "    SwiftCompile=$compiles  BUILD SUCCEEDED=$succeeded"
  if [ "$succeeded" -ne 1 ]; then
    grep -n 'error:' "$log" | head -20 || true
    echo "Build of $scheme failed — see $log" >&2
    exit 1
  fi
}
if any_wanted "$DICTATOR_SHOTS"; then build Dictator; fi
if any_wanted "$MEETINGS_SHOTS"; then build DictatorMeetings; fi
if [ -n "${BUILD_ONLY:-}" ]; then
  say "Build only — no captures"
  ./gen >/dev/null
  exit 0
fi

DICTATOR_APP="$DD/Build/Products/Debug/Dictator.app"
MEETINGS_APP="$DD/Build/Products/Debug/Dictator Meetings.app"
# Ad-hoc signing is all this environment can do, and it is all an unsigned
# scratch build needs to launch. Nothing under ~/Applications is touched.
codesign --force --deep --sign - "$DICTATOR_APP" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$MEETINGS_APP" >/dev/null 2>&1 || true

# ----------------------------------------------------------------- 3. captures
shoot() {
  local app="$1" binary="$2" shot="$3"
  wanted "$shot" || return 0
  local data="$WORK/data-$shot"
  rm -rf "$data"; mkdir -p "$data"
  # Never let a previous run's PNG stand in for a capture that failed.
  rm -f "$RAW/$shot.png"
  say "Capturing $shot"
  DICTATOR_SCREENSHOT="$shot" \
  DICTATOR_SCREENSHOT_OUT="$RAW/$shot.png" \
  DICTATOR_SCREENSHOT_DATA="$data" \
    "$app/Contents/MacOS/$binary" 2>&1 | grep -E '\[Screenshot\]' || true
  if [ ! -s "$RAW/$shot.png" ]; then
    echo "Capture '$shot' produced no file" >&2
    exit 1
  fi
}

for shot in $DICTATOR_SHOTS; do
  shoot "$DICTATOR_APP" "Dictator" "$shot"
done
for shot in $MEETINGS_SHOTS; do
  shoot "$MEETINGS_APP" "Dictator Meetings" "$shot"
done

# ---------------------------------------------------------- 4. post-processing
say "Down-sampling into docs/media"
mkdir -p docs/media/mac docs/media/meetings
# 1400 px on the long edge: comfortably above the 1280 px the page renders a
# shot at, and small enough to stay inside the page's ~400 KB per-image budget
# as a PNG (sharper for UI text than a JPEG would be). A shot that still comes
# out heavy is re-run at 1300, which is still >= the display width.
place() {
  local shot="$1" dest="$2" bytes
  wanted "$shot" || return 0
  for edge in 1400 1300; do
    sips -Z "$edge" "$RAW/$shot.png" --out "$dest" >/dev/null
    bytes=$(stat -f%z "$dest")
    [ "$bytes" -le 409600 ] && break
  done
  printf '    %-42s %6s KB\n' "$dest" "$((bytes / 1024))"
  if [ "$bytes" -gt 460800 ]; then
    echo "    WARNING: $dest is over ~450 KB — try a JPEG (sips -s format jpeg -s formatOptions 88)" >&2
  fi
}
place modes           docs/media/mac/modes.png
place hud-styles      docs/media/mac/hud-styles.png
place assistant-draft docs/media/mac/assistant-draft.png
place journal         docs/media/mac/journal.png
place chat            docs/media/mac/chat.png
# Not referenced by docs/index.html — a look at the Demo-mode fixtures.
place demo-history    docs/media/mac/demo-history.png
place today           docs/media/meetings/today.png
place companion       docs/media/meetings/companion.png
place live-recording  docs/media/meetings/live-recording.png
place notes           docs/media/meetings/notes.png
place coach           docs/media/meetings/coach.png

# Print the real pixel dimensions — docs/index.html's width/height attributes
# must match, or the page jumps as the images load.
say "Dimensions (put these in docs/index.html)"
for f in docs/media/mac/*.png docs/media/meetings/*.png; do
  printf '    %-42s %s\n' "$f" "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2}')"
done

# ------------------------------------------------------------ 5. restore project
say "Restoring the real Xcode project"
./gen >/dev/null
count=$(grep -c "Install to ~/Applications" Dictator.xcodeproj/project.pbxproj)
echo "    'Install to ~/Applications' occurrences in project.pbxproj: $count (expected 6)"
[ "$count" -eq 6 ] || { echo "Project restore looks wrong — re-run ./gen" >&2; exit 1; }

say "Done"
