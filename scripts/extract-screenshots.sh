#!/bin/bash
# Extract iOS App Store screenshots from the most recent xcresult bundle.
# Usage: extract-screenshots.sh <out-dir>
# Example: extract-screenshots.sh screenshots/6.7
set -euo pipefail

OUT_DIR="${1:?Usage: extract-screenshots.sh <out-dir>}"
DERIVED_DATA="${DERIVED_DATA:-.derivedData}"

# Pick the newest .xcresult bundle.
XCRESULT=$(find "$DERIVED_DATA/Logs/Test" -name "*.xcresult" -type d -depth 1 2>/dev/null | head -1)
if [ -z "$XCRESULT" ]; then
    echo "No xcresult bundle found under $DERIVED_DATA/Logs/Test" >&2
    exit 1
fi

echo "Source: $XCRESULT"
echo "Target: $OUT_DIR"
mkdir -p "$OUT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer} \
    xcrun xcresulttool export attachments \
    --path "$XCRESULT" --output-path "$TMP" >/dev/null

python3 - <<PY
import json, shutil, pathlib

manifest = json.loads(pathlib.Path("$TMP/manifest.json").read_text())
out_dir = pathlib.Path("$OUT_DIR")
out_dir.mkdir(parents=True, exist_ok=True)

for entry in manifest:
    for att in entry["attachments"]:
        # Test rig saves attachments with name = "<base>". Xcode mangles
        # the on-disk name as "<base>_0_<uuid>.png" — strip the suffix
        # back to the base.
        suggested = att["suggestedHumanReadableName"]
        base = suggested.split("_0_")[0]
        if not base.endswith(".png"):
            base = base + ".png" if "." not in base else base
        src = pathlib.Path("$TMP") / att["exportedFileName"]
        dst = out_dir / base
        shutil.copy(src, dst)
        print(f"-> {dst}")
PY
