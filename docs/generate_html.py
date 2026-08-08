#!/usr/bin/env python3
"""Render docs/*.md to static HTML under docs/html/.

    pip install -r docs/requirements.txt
    python docs/generate_html.py
"""

import pathlib
import re
import sys

try:
    import markdown
except ImportError:
    sys.exit("Missing dependency: pip install -r docs/requirements.txt")

DOCS_DIR = pathlib.Path(__file__).resolve().parent
OUT_DIR = DOCS_DIR / "html"

PAGE_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — Thor Docs</title>
<style>
{css}
</style>
</head>
<body>
<nav>
{nav}
</nav>
<main>
{body}
</main>
</body>
</html>
"""

CSS = """
:root { color-scheme: light dark; }
body {
    margin: 0; display: flex; font: 16px/1.55 -apple-system, "Segoe UI", sans-serif;
}
nav {
    flex: 0 0 220px; padding: 1.5rem 1rem; box-sizing: border-box;
    border-right: 1px solid #8884; height: 100vh; position: sticky; top: 0; overflow-y: auto;
}
nav a { display: block; padding: 0.2rem 0; text-decoration: none; }
nav a:hover { text-decoration: underline; }
main { flex: 1 1 auto; max-width: 48rem; padding: 2rem 2.5rem; box-sizing: border-box; }
pre { background: #8882; padding: 0.75rem 1rem; overflow-x: auto; border-radius: 6px; }
code { background: #8882; padding: 0.1rem 0.3rem; border-radius: 4px; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; }
th, td { border: 1px solid #8886; padding: 0.3rem 0.7rem; text-align: left; }
"""

MD_EXTENSIONS = ["extra", "sane_lists", "toc"]


def title_of(md_text: str, fallback: str) -> str:
    m = re.search(r"^#\s+(.+)$", md_text, re.MULTILINE)
    return m.group(1).strip() if m else fallback


def build_nav(pages: list[tuple[str, str]], current: str) -> str:
    lines = []
    for stem, title in pages:
        href = f"{stem}.html"
        marker = ' aria-current="page"' if stem == current else ""
        lines.append(f'<a href="{href}"{marker}>{title}</a>')
    return "\n".join(lines)


def md_links_to_html(body_html: str) -> str:
    return re.sub(r'href="([^"]+)\.md(#[^"]*)?"', r'href="\1.html\2"', body_html)


def main() -> None:
    md_files = sorted(DOCS_DIR.glob("*.md"))
    if not md_files:
        sys.exit(f"No .md files found in {DOCS_DIR}")

    sources = [(f.stem, f.read_text(encoding="utf-8")) for f in md_files]
    pages = [(stem, title_of(text, stem)) for stem, text in sources]
    # index.md first, then alphabetical.
    pages.sort(key=lambda p: (p[0] != "index", p[0]))

    OUT_DIR.mkdir(exist_ok=True)
    for stem, text in sources:
        title = dict(pages)[stem]
        body = markdown.markdown(text, extensions=MD_EXTENSIONS)
        body = md_links_to_html(body)
        html = PAGE_TEMPLATE.format(
            title=title, css=CSS, nav=build_nav(pages, stem), body=body
        )
        out_path = OUT_DIR / f"{stem}.html"
        out_path.write_text(html, encoding="utf-8")
        print(f"wrote {out_path.relative_to(DOCS_DIR.parent)}")


if __name__ == "__main__":
    main()
