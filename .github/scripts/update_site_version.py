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

Dictator Meetings reuses this same script against the same file, pointed at
its own anchor id and its own tag prefix:

    <a id="latest-meetings-release-link" href="https://github.com/<owner>/<repo>/releases/tag/meetings-v2026.9.0">v2026.9.0</a>

Usage:
    update_site_version.py <version> [--site PATH] [--element-id ID] [--tag-prefix PREFIX]

    update_site_version.py 2026.5.7
    update_site_version.py 2026.9.0 --element-id latest-meetings-release-link --tag-prefix meetings-v
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_SITE_PATH = "docs/index.html"
DEFAULT_ELEMENT_ID = "latest-release-link"
DEFAULT_TAG_PREFIX = "v"


def anchor_re(element_id: str, tag_prefix: str) -> re.Pattern[str]:
    # Captures: 1=href prefix up to the tag prefix, 2=URL version, 3=text
    # version. Anchored on the id so we never touch a different anchor that
    # happens to share the same URL shape.
    return re.compile(
        r'(<a id="' + re.escape(element_id) + r'" href="https://github\.com/[^/]+/[^/]+/releases/tag/'
        + re.escape(tag_prefix) + r')'
        r'([^"]+)'
        r'(">v)'
        r'([^<]+)'
        r'(</a>)'
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Update the marketing site's latest-release anchor.")
    parser.add_argument("version", help="Version to publish, e.g. 2026.5.7")
    parser.add_argument("--site", default=DEFAULT_SITE_PATH, help=f"Path to the site HTML (default: {DEFAULT_SITE_PATH})")
    parser.add_argument("--element-id", default=DEFAULT_ELEMENT_ID, help=f"Anchor id to update (default: {DEFAULT_ELEMENT_ID})")
    parser.add_argument("--tag-prefix", default=DEFAULT_TAG_PREFIX, help=f"Release-tag prefix before the version (default: {DEFAULT_TAG_PREFIX!r})")
    parser.add_argument("--download-id", action="append", default=[],
                        help="id of an <a> whose href should point at this release's DMG (repeatable). Requires --asset.")
    parser.add_argument("--asset", default=None, help="Release asset filename for --download-id links, e.g. Dictator.dmg")
    parser.add_argument("--jsonld", action="store_true",
                        help="Also rewrite the JSON-LD \"downloadUrl\" to this release's DMG (requires --asset)")
    args = parser.parse_args()
    if (args.download_id or args.jsonld) and not args.asset:
        parser.error("--download-id / --jsonld need --asset")

    site_path = Path(args.site)
    version = args.version.lstrip("v").strip()
    if not version:
        print("error: empty version", file=sys.stderr)
        return 2

    if not site_path.exists():
        print(f"error: {site_path} not found (run from repo root)", file=sys.stderr)
        return 1

    original = site_path.read_text(encoding="utf-8")
    pattern = anchor_re(args.element_id, args.tag_prefix)
    match = pattern.search(original)
    if not match:
        # Surface a clear error rather than silently leaving the version
        # stale. Catches the case where someone reshapes the anchor in the
        # HTML without updating the regex here.
        print(
            f"error: could not find <a id=\"{args.element_id}\"> in {site_path}",
            file=sys.stderr,
        )
        return 1

    # Rebuild the anchor with the new version in both the URL and the text.
    replacement = f"{match.group(1)}{version}{match.group(3)}{version}{match.group(5)}"
    updated = pattern.sub(replacement, original, count=1)

    # Download buttons. Two apps release from one repository, and GitHub's
    # `releases/latest/download/<asset>` resolves against the repository's
    # single latest release — so a Dictator link 404s the moment a Meetings
    # release is newer, and vice versa. Point each button at the versioned
    # asset URL of the release being cut instead. The owner/repo segment is
    # taken from the "Latest release" anchor so forks keep working.
    if args.download_id or args.jsonld:
        repo_match = re.search(r'href="(https://github\.com/[^/]+/[^/]+)/releases/tag/', updated)
        if not repo_match:
            print("error: could not infer the GitHub repository from the release anchor", file=sys.stderr)
            return 1
        asset_url = f"{repo_match.group(1)}/releases/download/{args.tag_prefix}{version}/{args.asset}"
        for element_id in args.download_id:
            link_re = re.compile(r'(<a\s[^>]*\bid="' + re.escape(element_id) + r'"[^>]*\bhref=")([^"]*)(")')
            if not link_re.search(updated):
                print(f"error: could not find <a id=\"{element_id}\"> in {site_path}", file=sys.stderr)
                return 1
            updated = link_re.sub(lambda m: f"{m.group(1)}{asset_url}{m.group(3)}", updated)
        if args.jsonld:
            jsonld_re = re.compile(r'("downloadUrl":\s*")([^"]*)(")')
            if not jsonld_re.search(updated):
                print(f"error: no JSON-LD downloadUrl in {site_path}", file=sys.stderr)
                return 1
            updated = jsonld_re.sub(lambda m: f"{m.group(1)}{asset_url}{m.group(3)}", updated, count=1)

    if updated == original:
        print(f"{site_path} already references v{version}; nothing to do")
        return 0

    site_path.write_text(updated, encoding="utf-8")
    print(f"updated {site_path} to v{version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
