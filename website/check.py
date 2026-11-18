#!/usr/bin/env python3
"""Check the public site artifact, assets, links, and progressive enhancement."""
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.elements = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


def check(root):
    root = root.resolve()
    html = (root / "index.html").read_text()
    doc = Document(html)
    ids = Counter(attrs["id"] for _, attrs in doc.elements if "id" in attrs)
    assert all(count == 1 for count in ids.values()), "Duplicate HTML id"
    assert '<html lang="en">' in html and "<noscript>" in html
    assert len([1 for tag, _ in doc.elements if tag == "h1"]) == 1
    resources = []
    for tag, attrs in doc.elements:
        for key in ("href", "src"):
            if key not in attrs:
                continue
            url = urlsplit(attrs[key])
            if url.scheme:
                assert url.scheme == "https", f"Non-HTTPS URL: {attrs[key]}"
                continue
            if url.path:
                target = (root / unquote(url.path)).resolve()
                assert target.is_relative_to(root) and target.is_file(), f"Missing/escaping resource: {target}"
                resources.append(target)
            if url.fragment:
                assert url.fragment in ids, f"Missing anchor: {url.fragment}"
        if tag == "img":
            assert attrs.get("alt") and attrs.get("width") and attrs.get("height")
        if "data-copy" in attrs:
            assert attrs["data-copy"] in ids, "Copy target is missing"
        if "aria-controls" in attrs:
            assert attrs["aria-controls"] in ids
    css = (root / "style.css").read_text()
    for rel in re.findall(r"url\(['\"]?([^)'\"]+)", css):
        assert (root / rel).is_file(), f"Missing stylesheet asset: {rel}"
    assert "prefers-reduced-motion" in css and ":focus-visible" in css
    assert not re.search(r"font-size:[^;}]*vw", css), "Font size must respect text scaling"
    for name in ("editor", "completion", "agent"):
        assert (root / "assets" / f"{name}.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    for name in ("DMSans", "InstrumentSerif"):
        assert (root / "assets/fonts" / f"{name}.woff2").read_bytes().startswith(b"wOF2")
        assert (root / "assets/fonts" / f"{name}-OFL.txt").is_file()
    if (root / ".nojekyll").exists():
        for private in ("README.md", "build.py", "check.py", "browser-check.js", "__pycache__"):
            assert not (root / private).exists(), f"Development file in public artifact: {private}"
    js = (root / "site.js").read_text()
    zh = js.split("const zh = {", 1)[1].split("\n  };", 1)[0]
    translated = set(re.findall(r"'([^']+)'\s*:", zh))
    required = {attrs["data-i18n"] for _, attrs in doc.elements if "data-i18n" in attrs}
    assert required <= translated, f"Missing Chinese text: {required - translated}"
    print(f"PASS: {len(ids)} unique IDs, {len(required)} bilingual strings, local assets, anchors, copy targets and public-only packaging")


if __name__ == "__main__":
    check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent)
