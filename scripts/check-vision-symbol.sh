#!/usr/bin/env bash
#
# Verify that the mangled symbol `WindowVisionContext.imageAttachmentAPIAvailable`
# probes for is the one the built binary actually imports.
#
#   ./scripts/check-vision-symbol.sh <path to Dictator.app>
#
# Why this exists. That gate decides whether Apple's on-device model is handed a
# screenshot. It works by asking dyld whether the running OS exports
# `Attachment(_ cgImage:orientation:)` — because an OS that doesn't would crash
# uncatchably the moment the initializer is constructed. The probe is a
# hardcoded mangled string, and a hardcoded mangled string can disagree with the
# binary in two ways, both silent:
#
#   * String wrong, binary right  — the gate never resolves, vision is dead code
#     on every Mac. This happened: the shipped string carried one extra
#     character (`Rszrl` for `Rszl`) and the feature was off for months on an OS
#     that could do it all along.
#   * String right, binary wrong  — the gate says yes, the binary asks for a
#     symbol the user's OS hasn't got, and the app crashes. Reachable by
#     building against a beta SDK whose generic signature differs from GA.
#
# Both disappear if the two are checked against each other. A mismatch here is
# not "update the string and move on": it means the SDK you are building with
# emits a different symbol from the one you tested against, and the right
# question is which SDK the release should be using.
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -e "$APP" ]; then
    echo "usage: $0 <path to Dictator.app>" >&2
    exit 2
fi

# Every Mach-O in the bundle, because a Debug build puts the app's own code in
# `Dictator.debug.dylib` and leaves a ~40KB stub at Contents/MacOS/Dictator —
# checking only the stub finds nothing and passes for the wrong reason.
BINARIES="$(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null || true)"
[ -f "$APP" ] && BINARIES="$APP"

SOURCE="$(dirname "$0")/../Sources/Dictator/Injection/WindowVisionContext.swift"

# The string the gate probes for.
EXPECTED="$(grep -o '\$s16FoundationModels10Attachment[A-Za-z0-9_]*' "$SOURCE" | head -1)"
if [ -z "$EXPECTED" ]; then
    echo "FAIL: no Attachment symbol constant found in WindowVisionContext.swift" >&2
    exit 1
fi

# What the binary imports. Dyld's C prefix `_` is dropped to match the source.
# The pattern matches on `CGImageRef` rather than on the content type's name:
# Swift mangling substitutes repeated components, so `ImageAttachmentContent`
# appears as `05ImageC7Content` and never literally.
ACTUAL="$(for f in $BINARIES; do nm -u "$f" 2>/dev/null; done \
    | grep 'FoundationModels10Attachment.*CGImageRef.*cfC' \
    | sed 's/^_//' | tr -d ' ' | sort -u | head -1)"

if [ -z "$ACTUAL" ]; then
    # Not an error on its own: a build with FOUNDATION_MODELS_VISION off (the
    # macOS 26 SDK) compiles the call site out entirely, so there is no import
    # to check and nothing can crash.
    if for f in $BINARIES; do nm -u "$f" 2>/dev/null; done | grep -q FoundationModels; then
        echo "OK: binary links FoundationModels but imports no image-attachment init"
        echo "    (FOUNDATION_MODELS_VISION is off — built against an SDK older than macOS 27)"
        exit 0
    fi
    echo "FAIL: $APP doesn't look like it links FoundationModels at all" >&2
    exit 1
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    cat >&2 <<MSG
FAIL: the vision gate probes for a symbol this build does not use.

  gate probes : $EXPECTED
  binary uses : $ACTUAL

The gate would answer a question about a different function than the one that
gets called. Do NOT just paste the binary's symbol into the source — first work
out why they differ. The usual cause is building against a beta SDK, whose
generic signature differs from GA; a binary built that way cannot use Apple
vision on a GA machine whatever this string says.
MSG
    exit 1
fi

echo "OK: vision gate and binary agree on $ACTUAL"
