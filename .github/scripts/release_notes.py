#!/usr/bin/env python3
"""CHANGELOG.md helpers for the release pipeline.

Three subcommands, each tiny enough that the release workflow stays readable:

    extract [PATH]                 Print the body of '## Unreleased' to stdout.
    html                           Read markdown bullets on stdin, write HTML to stdout.
    version <VER> <DATE> [PATH]    Rewrite the changelog in place: move 'Unreleased' to
                                   'v<VER> — <DATE>' and reset Unreleased to its empty
                                   placeholder.

PATH defaults to CHANGELOG.md (Dictator's changelog) so the existing call
sites — which pass no path — are unaffected. Dictator Meetings' release job
passes CHANGELOG-Meetings.md explicitly.

Run any of them locally to dry-run what the workflow will produce:

    python3 .github/scripts/release_notes.py extract
    python3 .github/scripts/release_notes.py extract | python3 .github/scripts/release_notes.py html
    python3 .github/scripts/release_notes.py extract CHANGELOG-Meetings.md
"""
import html
import pathlib
import re
import sys

CHANGELOG_PATH = pathlib.Path("CHANGELOG.md")
EMPTY_PLACEHOLDER = "_No changes yet._"
EMPTY_RELEASE_PROSE = "No user-facing changes in this release."


def read_unreleased(path: pathlib.Path = CHANGELOG_PATH) -> str:
    """Return the body of '## Unreleased', stripped. Body = everything after
    the heading line up to the next '## ' heading or EOF."""
    text = path.read_text()
    m = re.search(r'^## Unreleased\s*\n', text, flags=re.M)
    if not m:
        raise SystemExit(f"{path}: no '## Unreleased' heading found")
    rest = text[m.end():]
    next_heading = re.search(r'^## ', rest, flags=re.M)
    end = m.end() + next_heading.start() if next_heading else len(text)
    return text[m.end():end].strip()


def md_bullets_to_html(md: str) -> str:
    """Tiny markdown→HTML converter sized for the bullet-list release-notes
    format. Lines starting with '- ' become <li>; any other non-empty line
    becomes <p>. Inline markdown (bold/links/code) is NOT supported —
    deliberately, so release notes render identically on GitHub and in
    Sparkle's WebView."""
    lines = [ln.rstrip() for ln in md.strip().splitlines()]
    out: list[str] = []
    in_list = False
    for line in lines:
        if not line.strip():
            if in_list:
                out.append("</ul>")
                in_list = False
            continue
        stripped = line.lstrip()
        if stripped.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"  <li>{html.escape(stripped[2:])}</li>")
        else:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<p>{html.escape(stripped)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def version_unreleased(version: str, date: str, path: pathlib.Path = CHANGELOG_PATH) -> None:
    """Rewrite the changelog in place: move Unreleased body under a versioned
    heading and reset Unreleased to the empty placeholder. If the Unreleased
    body was already empty, the versioned section gets explicit
    'No user-facing changes' prose instead of carrying the placeholder
    forward (which would read as a bug)."""
    text = path.read_text()
    m = re.search(r'^## Unreleased\s*\n', text, flags=re.M)
    if not m:
        raise SystemExit(f"{path}: no '## Unreleased' heading found")
    rest = text[m.end():]
    next_heading = re.search(r'^## ', rest, flags=re.M)
    body_end = m.end() + next_heading.start() if next_heading else len(text)
    body = text[m.end():body_end].strip()
    versioned = body if body and body != EMPTY_PLACEHOLDER else EMPTY_RELEASE_PROSE
    replacement = (
        f"## Unreleased\n\n{EMPTY_PLACEHOLDER}\n\n"
        f"## v{version} — {date}\n\n"
        f"{versioned}\n\n"
    )
    new_text = text[:m.start()] + replacement + text[body_end:].lstrip("\n")
    path.write_text(new_text)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    if cmd == "extract":
        path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else CHANGELOG_PATH
        body = read_unreleased(path)
        print(body if body and body != EMPTY_PLACEHOLDER else EMPTY_PLACEHOLDER)
        return 0
    if cmd == "html":
        md = sys.stdin.read()
        if md.strip() in ("", EMPTY_PLACEHOLDER):
            print(f"<p>{html.escape(EMPTY_RELEASE_PROSE)}</p>")
        else:
            print(md_bullets_to_html(md))
        return 0
    if cmd == "version":
        if len(sys.argv) not in (4, 5):
            print("usage: release_notes.py version <VERSION> <DATE> [PATH]", file=sys.stderr)
            return 1
        path = pathlib.Path(sys.argv[4]) if len(sys.argv) == 5 else CHANGELOG_PATH
        version_unreleased(sys.argv[2], sys.argv[3], path)
        return 0
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
