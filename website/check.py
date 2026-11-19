#!/usr/bin/env python3
"""Check the public site artifact, assets, links, and progressive enhancement."""
from collections import Counter
import csv
import json
from math import ceil
from statistics import median
from tempfile import TemporaryDirectory
from build import ROOT, build
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


def check(root, expected_version=None):
    root = root.resolve()
    html = (root / "index.html").read_text()
    doc = Document(html)
    if expected_version is not None:
        badges = re.findall(r'<a\b[^>]*\bdata-release-version\b[^>]*>([^<]*)</a>', html)
        assert badges == [expected_version], f"Expected release badge {expected_version}, got {badges}"
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
                if target.is_dir():
                    target = target / "index.html"
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
    font = root / "assets/fonts/DMSans.woff2"
    assert font.read_bytes().startswith(b"wOF2")
    assert font.with_name("DMSans-OFL.txt").is_file()
    if (root / ".nojekyll").exists():
        for private in ("README.md", "build.py", "check.py", "browser-check.js", "__pycache__"):
            assert not (root / private).exists(), f"Development file in public artifact: {private}"
    js = (root / "site.js").read_text()
    zh = js.split("const zh = {", 1)[1].split("\n  };", 1)[0]
    translated = set(re.findall(r"'([^']+)'\s*:", zh))
    required = {attrs["data-i18n"] for _, attrs in doc.elements if "data-i18n" in attrs}
    assert required <= translated, f"Missing Chinese text: {required - translated}"
    print(f"PASS: {len(ids)} unique IDs, {len(required)} bilingual strings, local assets, anchors, copy targets and public-only packaging")


def check_benchmarks(root):
    folder = root / "benchmark"
    for page, lang in [("index.html", "en"), ("zh.html", "zh-CN")]:
        html = (folder / page).read_text()
        doc = Document(html)
        assert f'<html lang="{lang}">' in html and "181.33" in html and "2.94" in html
        assert len([1 for tag, _ in doc.elements if tag == "table"]) == 5
        for _, attrs in doc.elements:
            url = urlsplit(attrs.get("href", ""))
            if url.scheme or not url.path:
                continue
            target = (folder / url.path).resolve()
            if target.is_dir():
                target /= "index.html"
            assert target.is_relative_to(root.resolve()) and target.is_file(), str(target)
    for study, n, expected_entries, traces in [("large", 3, 64, 2), ("daily", 7, 18, 7)]:
        with (folder / f"{study}-timings.csv").open() as f:
            rows = list(csv.DictReader(f))
        assert {r["editor"] for r in rows} == {"final", "nvim_clean"}
        for lang in ("en", "zh"):
            report = (folder / f"{study}-flames-{lang}.html").read_text()
            data, _ = json.JSONDecoder().raw_decode(report.split("const data = ", 1)[1])
            entries = data["entries"]
            assert {r["editor"] for r in entries} == {"final", "nvim_clean"}
            assert len({(r["file"], r["editor"], r["phase"]) for r in entries}) == len(entries) == expected_entries
            assert all("/home/" not in s and "/Users/" not in s and "/tmp/" not in s for s in data["symbols"])
            for entry in entries:
                group = [r for r in rows if (r["editor"], r["file"]) == (entry["editor"], entry["file"])]
                assert {int(r["trial"]) for r in group} == set(range(1, n + 1))
                values = sorted(float(r[entry["phase"]]) for r in group)
                assert len(values) == entry["n"] == n and entry["traces"] == traces
                assert (entry["median"], entry["p90"]) == (median(values), values[ceil(.9 * n) - 1])
                for count, stack in entry["stacks"]:
                    assert count > 0 and stack and all(0 <= i < len(data["symbols"]) for i in stack)
    print("PASS: bilingual benchmarks, links, timing distributions and flame-graph samples")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        artifact = Path(sys.argv[1]).resolve()
        check(artifact, sys.argv[2] if len(sys.argv) > 2 else None)
        check_benchmarks(artifact)
    else:
        # Generated pages must be checked under the same project layout that Pages serves.
        (ROOT / ".verify").mkdir(exist_ok=True)
        with TemporaryDirectory(dir=ROOT / ".verify") as temp:
            artifact = build(Path(temp) / "oz")
            check(artifact)
            check_benchmarks(artifact)
