#!/bin/bash
# Seed the iOS Simulator with realistic state for App Store screenshots.
#
# Run against a BOOTED simulator. Usage:
#   ./scripts/seed-dictator-screenshots.sh "iPhone 17 Pro Max"
#
# What it sets up:
#   1. Dummy Parakeet model files so the UI thinks the model's installed
#      (no actual ~460 MB download needed for screenshots).
#   2. A realistic history.json with a mix of dictation + assist entries.
#   3. UserDefaults — onboarding completed, model picked, cleanup enabled.
#   4. App Group readiness so the keyboard chip would show green if shown.
#   5. Status bar override to Apple's iconic 9:41 with full bars + 100% battery
#      so screenshots look polished rather than "captured at 11:47 PM, 47%".
#
# Paired with `./scripts/extract-screenshots.sh` which pulls the captured
# images out of the .xcresult bundle after running the screenshot UI tests.
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <simulator name>" >&2
    echo "Example: $0 'iPhone 17 Pro Max'" >&2
    exit 64
fi

SIM="$1"
APP_BUNDLE="net.robgough.DictatorIOS"
GROUP_ID="group.net.robgough.DictatorIOS"
XCRUN="DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer} xcrun simctl"

CONTAINER=$(eval "$XCRUN get_app_container \"$SIM\" \"$APP_BUNDLE\" data")
# `groups` exits non-zero (117 / usage) but still prints the path on stdout.
# Allow the failure and grep for the tab-separated path.
GROUP_DIR=$(eval "$XCRUN get_app_container \"$SIM\" \"$APP_BUNDLE\" groups 2>&1" \
    | awk -F'\t' '/AppGroup/ {print $2; exit}')
DEVICE_ID=$(eval "$XCRUN list devices booted" \
    | grep "$SIM" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)

echo "Container: $CONTAINER"
echo "Group:     $GROUP_DIR"
echo "Device:    $DEVICE_ID"

# 1) Seed dummy model files so modelsExist() returns true.
MODEL_DIR="$CONTAINER/Library/Application Support/Dictator/Models/parakeet/parakeet-tdt-0.6b-v3"
mkdir -p "$MODEL_DIR/Preprocessor.mlmodelc" \
         "$MODEL_DIR/Encoder.mlmodelc" \
         "$MODEL_DIR/Decoder.mlmodelc" \
         "$MODEL_DIR/JointDecisionv3.mlmodelc"
echo "{}" > "$MODEL_DIR/parakeet_vocab.json"

# 2) Seed dictation history with a realistic mix of entries.
#    Timestamps are computed relative to *now* (spread over the last ~3 days)
#    so they always fall inside the store's 7-day prune window. Hardcoded
#    dates silently go stale — every entry gets pruned on load and the
#    history shot captures an empty state.
HISTORY_DIR="$CONTAINER/Library/Application Support/Dictator"
mkdir -p "$HISTORY_DIR"
HISTORY_OUT="$HISTORY_DIR/history.json" python3 <<'PYEOF'
import os, json, pathlib
from datetime import datetime, timezone, timedelta

now = datetime.now(timezone.utc)
def ago(hours):
    return (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")

entries = [
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "timestamp": ago(3),
        "mode": "dictation",
        "text": "Picking up bread, milk, and a couple of those nice apples from the new place on the corner. Should be back by six.",
    },
    {
        "id": "22222222-2222-2222-2222-222222222222",
        "timestamp": ago(6),
        "mode": "assist",
        "text": "Hi Sarah, thanks for sending the brief over. I'll have feedback to you by Friday afternoon — let me know if that's too late and I can move things around. Cheers, Rob",
        "raw": "tell sarah thanks for the brief feedback friday afternoon move things around if too late",
    },
    {
        "id": "33333333-3333-3333-3333-333333333333",
        "timestamp": ago(27),
        "mode": "dictation",
        "text": "Remember to ask the dentist about that crown next time — it's been clicking on the left side for about a week now.",
    },
    {
        "id": "44444444-4444-4444-4444-444444444444",
        "timestamp": ago(33),
        "mode": "dictation",
        "text": "Three points for tomorrow's stand-up: deployment is unblocked, the analytics dashboard needs one more pass, and we should sync on the new onboarding copy.",
    },
    {
        "id": "55555555-5555-5555-5555-555555555555",
        "timestamp": ago(49),
        "mode": "assist",
        "text": "Could you share the latest figures for the Q2 forecast? Specifically the cohort retention numbers — happy to jump on a quick call if that's easier than email.",
        "raw": "ask for q2 forecast figures cohort retention numbers offer call if easier",
    },
    {
        "id": "66666666-6666-6666-6666-666666666666",
        "timestamp": ago(72),
        "mode": "dictation",
        "text": "Idea: a little widget that surfaces the last thing you dictated, so you can re-paste it without diving back into the app.",
    },
]
pathlib.Path(os.environ["HISTORY_OUT"]).write_text(json.dumps(entries, indent=2, ensure_ascii=False))
PYEOF

# 3) Seed UserDefaults — pre-completed onboarding, model selection, etc.
PLIST="$CONTAINER/Library/Preferences/${APP_BUNDLE}.plist"
mkdir -p "$(dirname "$PLIST")"

cat > /tmp/dictator_prefs.plist <<'EOF'
{
  "DictatorIOS.onboardingCompleted" = 1;
  "DictatorIOS.keyboardOnboardingDismissed" = 1;
  "DictatorIOS.selectedModelID" = "parakeet-tdt-0.6b-v3";
  "DictatorIOS.foundationCleanupEnabled" = 1;
  "DictatorIOS.cues.punctuation" = 1;
  "DictatorIOS.cues.numbers" = 1;
  "DictatorIOS.cues.times" = 1;
  "DictatorIOS.cues.currency" = 1;
  "DictatorIOS.cues.emojis" = 1;
}
EOF
plutil -convert binary1 -o "$PLIST" /tmp/dictator_prefs.plist

# 4) Seed App Group readiness so the keyboard chip would show green if rendered.
if [ -n "$GROUP_DIR" ]; then
    GROUP_PLIST="$GROUP_DIR/Library/Preferences/${GROUP_ID}.plist"
    mkdir -p "$(dirname "$GROUP_PLIST")"

    GROUP_PLIST_OUT="$GROUP_PLIST" python3 <<'PYEOF'
import os, plistlib, json, datetime, pathlib

now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
readiness = json.dumps({
    "diskStatus": "downloaded",
    "modelID": "parakeet-tdt-0.6b-v3",
    "loaded": True,
    "updatedAt": now,
}).encode()
host_active = json.dumps({
    "active": True,
    "updatedAt": now,
}).encode()
prefs = {
    "DictatorKeyboard.modelReadiness": readiness,
    "DictatorKeyboard.hostActive": host_active,
}
path = pathlib.Path(os.environ["GROUP_PLIST_OUT"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("wb") as f:
    plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)
PYEOF
fi

# 5) Status-bar override. App Store screenshots are always shot at 9:41 with
#    full bars + 100% battery — Apple's been doing it since the original
#    iPhone keynote. `simctl status_bar override` writes a snapshot the
#    simulator displays in place of the live status bar; persists until
#    `--clear` or simulator reboot.
eval "$XCRUN status_bar \"$DEVICE_ID\" override \
    --time '9:41' \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --operatorName '' \
    --batteryState charged \
    --batteryLevel 100"

# Kill cfprefsd so it re-reads the prefs file we just wrote.
eval "$XCRUN spawn \"$DEVICE_ID\" launchctl stop com.apple.cfprefsd.xpc.daemon" 2>/dev/null || true

echo "Done seeding $SIM"
