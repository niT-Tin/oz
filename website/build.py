#!/usr/bin/env python3
"""Package only public site files. No Node install or framework build needed."""
import argparse
import pathlib
import re
import shutil

import benchmarks

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
FILES = ("index.html", "style.css", "site.js", "favicon.svg", "404.html", "robots.txt", "sitemap.xml")


def build(output, version=None):
    output = output.resolve()
    if not output.is_relative_to(ROOT / ".verify") or output == ROOT / ".verify":
        raise ValueError("Output must be a subdirectory of .verify")
    if version and not re.fullmatch(r"v\d+\.\d+\.\d+(?:\.\d+)?(?:-[\w.-]+)?", version):
        raise ValueError("Expected a release version such as v0.4.0")
    for path in SITE.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Do not publish symlinks: {path}")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for name in FILES:
        shutil.copy2(SITE / name, output / name)
    shutil.copytree(SITE / "assets", output / "assets")
    benchmarks.build(output / "benchmark")
    if version:
        path = output / "index.html"
        text, count = re.subn(r'(data-release-version[^>]*>)[^<]*(?=</a>)', rf'\g<1>{version}', path.read_text())
        if count != 1:
            raise ValueError("Release badge must appear exactly once")
        path.write_text(text)
    (output / ".nojekyll").touch()
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".verify/website")
    parser.add_argument("--version", help="Latest published GitHub release tag")
    args = parser.parse_args()
    result = build(args.output, args.version)
    print(f"Packaged {sum(p.is_file() for p in result.rglob('*'))} public files in {result}")
