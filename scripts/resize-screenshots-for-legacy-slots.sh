#!/bin/bash
# Resize the 6.9" Display screenshots into the legacy ASC display-size slots.
#
# Background: Apple only requires the 6.9" Display slot (1320×2868) for new
# iOS submissions, but App Store Connect still exposes the older slots — 6.5"
# Display (1242×2688 or 1284×2778) and 5.5" Display (1242×2208) — and won't
# let you upload native 6.9" files into them. The aspect ratios are close
# enough that a `sips` resize produces clean output without re-running the
# whole simulator-capture flow.
#
# Usage:
#   ./scripts/resize-screenshots-for-legacy-slots.sh
#
# Reads from screenshots/6.7/*.png (1320×2868 native).
# Writes to screenshots/6.5/*.png (1284×2778, fits the ASC 6.5" Display slot).
#
# Skipping 5.5" Display — different aspect ratio (1:1.778 vs 1:2.173), would
# require a cropped composition rather than a scale. Add a `5.5/` target here
# if Apple starts requiring it again.
set -e

SRC=screenshots/6.7
DST=screenshots/6.5

if [ ! -d "$SRC" ]; then
    echo "No source screenshots at $SRC — run the capture flow first:" >&2
    echo "  ./scripts/seed-dictator-screenshots.sh 'iPhone 17 Pro Max'" >&2
    echo "  xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test" >&2
    echo "  ./scripts/extract-screenshots.sh $SRC" >&2
    exit 1
fi

mkdir -p "$DST"

for src in "$SRC"/*.png; do
    name=$(basename "$src")
    sips --resampleHeightWidth 2778 1284 "$src" --out "$DST/$name" > /dev/null
    echo "  → $DST/$name"
done

echo "Resized $(ls "$SRC"/*.png | wc -l | tr -d ' ') screenshots into $DST."
