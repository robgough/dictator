#!/usr/bin/env python3
"""Insert a new release <item> into an appcast XML file (docs/appcast.xml by
default).

Invoked by .github/workflows/release.yml. Most inputs come from env vars so
we don't have to thread them through positional argv; that also keeps the
workflow YAML free of fragile multi-line shell quoting. The one exception is
the appcast path itself, taken as an optional positional argument so the
Dictator Meetings release job can point this at docs/appcast-meetings.xml
without duplicating the script.

Usage:
    append_appcast.py [APPCAST_PATH]   # defaults to docs/appcast.xml

Required env:
    APPCAST_VERSION    e.g. 0.2.0
    APPCAST_BUILD      build number (CFBundleVersion / sparkle:version)
    APPCAST_DMG_URL    full URL to the DMG asset on the GitHub Release
    APPCAST_LENGTH     bytes (from Sparkle's sign_update)
    APPCAST_ED_SIG     EdDSA signature (from Sparkle's sign_update)
    APPCAST_PUBDATE    RFC-822 pubDate, e.g. "Mon, 12 May 2026 10:00:00 +0000"

Optional env:
    APPCAST_DESCRIPTION_HTML  HTML for Sparkle's "What's new" panel. When set,
                              wrapped in CDATA inside a <description> element
                              on the item. Empty/unset skips the element.
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
    description_html = (os.environ.get("APPCAST_DESCRIPTION_HTML") or "").strip()

    parts = [
        "        <item>",
        f"            <title>Version {version}</title>",
        f"            <pubDate>{pubdate}</pubDate>",
        f"            <sparkle:version>{build}</sparkle:version>",
        f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>",
        "            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>",
    ]
    if description_html:
        # CDATA so Sparkle's HTML rendering panel gets raw HTML without the
        # appcast XML parser tripping on angle brackets. Pre-escape the
        # CDATA terminator just in case a release note ever contains it.
        safe = description_html.replace("]]>", "]]]]><![CDATA[>")
        parts.append(f"            <description><![CDATA[{safe}]]></description>")
    parts += [
        "            <enclosure",
        f'                url="{url}"',
        f'                length="{length}"',
        '                type="application/octet-stream"',
        f'                sparkle:edSignature="{ed_sig}" />',
        "        </item>",
    ]
    item = "\n".join(parts) + "\n    "

    appcast_path = sys.argv[1] if len(sys.argv) > 1 else "docs/appcast.xml"
    path = pathlib.Path(appcast_path)
    src = path.read_text()
    updated, count = re.subn(r"(\s*)</channel>", f"\n{item}\\1</channel>", src, count=1)
    if count != 1:
        print(f"could not locate </channel> in {path}", file=sys.stderr)
        return 1
    path.write_text(updated)
    print(f"appended v{version} to {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
