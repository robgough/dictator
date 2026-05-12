#!/usr/bin/env python3
"""Insert a new release <item> into docs/appcast.xml.

Invoked by .github/workflows/release.yml. All inputs come from env vars so
we don't have to thread them through positional argv; that also keeps the
workflow YAML free of fragile multi-line shell quoting.

Required env:
    APPCAST_VERSION    e.g. 0.2.0
    APPCAST_BUILD      build number (CFBundleVersion / sparkle:version)
    APPCAST_DMG_URL    full URL to the DMG asset on the GitHub Release
    APPCAST_LENGTH     bytes (from Sparkle's sign_update)
    APPCAST_ED_SIG     EdDSA signature (from Sparkle's sign_update)
    APPCAST_PUBDATE    RFC-822 pubDate, e.g. "Mon, 12 May 2026 10:00:00 +0000"
"""
import os
import pathlib
import re
import sys


def main() -> int:
    required = (
        "APPCAST_VERSION",
        "APPCAST_BUILD",
        "APPCAST_DMG_URL",
        "APPCAST_LENGTH",
        "APPCAST_ED_SIG",
        "APPCAST_PUBDATE",
    )
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        print(f"missing required env: {', '.join(missing)}", file=sys.stderr)
        return 1

    version = os.environ["APPCAST_VERSION"]
    build = os.environ["APPCAST_BUILD"]
    url = os.environ["APPCAST_DMG_URL"]
    length = os.environ["APPCAST_LENGTH"]
    ed_sig = os.environ["APPCAST_ED_SIG"]
    pubdate = os.environ["APPCAST_PUBDATE"]

    item = (
        "        <item>\n"
        f"            <title>Version {version}</title>\n"
        f"            <pubDate>{pubdate}</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        "            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
        "            <enclosure\n"
        f'                url="{url}"\n'
        f'                length="{length}"\n'
        '                type="application/octet-stream"\n'
        f'                sparkle:edSignature="{ed_sig}" />\n'
        "        </item>\n    "
    )

    path = pathlib.Path("docs/appcast.xml")
    src = path.read_text()
    updated, count = re.subn(r"(\s*)</channel>", f"\n{item}\\1</channel>", src, count=1)
    if count != 1:
        print("could not locate </channel> in docs/appcast.xml", file=sys.stderr)
        return 1
    path.write_text(updated)
    print(f"appended v{version} to docs/appcast.xml")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
