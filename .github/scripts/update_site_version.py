#!/usr/bin/env python3
"""Update the "Latest release" line on the marketing site (docs/index.html)
with the version about to be released.

Called from .github/workflows/release.yml after the GitHub Release has been
created but before the appcast commit-back step, so a single workflow commit
ships the appcast + changelog + marketing version bump together.

The target anchor in docs/index.html looks like:

    <a id="latest-release-link" href="https://github.com/<owner>/<repo>/releases/tag/v2026.5.6">v2026.5.6</a>

We update the version in both the href and the link text in place — the
owner/repo segment of the URL stays whatever's in the file, so this script
works for forks without a code change.

Usage:
    update_site_version.py 2026.5.7
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SITE_PATH = Path("docs/index.html")

# Captures: 1=href prefix up to `tag/v`, 2=URL version, 3=text version.
# Anchored on the id so we never touch a different anchor that happens to
# share the same URL shape.
ANCHOR_RE = re.compile(
    r'(<a id="latest-release-link" href="https://github\.com/[^/]+/[^/]+/releases/tag/v)'
    r'([^"]+)'
    r'(">v)'
    r'([^<]+)'
    r'(</a>)'
)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <version>", file=sys.stderr)
        return 2

    version = sys.argv[1].lstrip("v").strip()
    if not version:
        print("error: empty version", file=sys.stderr)
        return 2

    if not SITE_PATH.exists():
        print(f"error: {SITE_PATH} not found (run from repo root)", file=sys.stderr)
        return 1

    original = SITE_PATH.read_text(encoding="utf-8")
    match = ANCHOR_RE.search(original)
    if not match:
        # Surface a clear error rather than silently leaving the version
        # stale. Catches the case where someone reshapes the anchor in the
        # HTML without updating the regex here.
        print(
            f"error: could not find <a id=\"latest-release-link\"> in {SITE_PATH}",
            file=sys.stderr,
        )
        return 1

    # Rebuild the anchor with the new version in both the URL and the text.
    replacement = f"{match.group(1)}{version}{match.group(3)}{version}{match.group(5)}"
    updated = ANCHOR_RE.sub(replacement, original, count=1)

    if updated == original:
        print(f"{SITE_PATH} already references v{version}; nothing to do")
        return 0

    SITE_PATH.write_text(updated, encoding="utf-8")
    print(f"updated {SITE_PATH} to v{version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
