#!/usr/bin/env python3
"""Diff two benchmark reports (baseline vs after) into a comparison table.

Usage: python3 bench/diff_reports.py bench/results/baseline.md /tmp/after.md
"""
import re
import sys


def parse(path):
    rows = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"\| ([^|]+) \| ([^|]+) \| ([^|]+) \| ([^|]+) \|", line.strip())
            if m:
                name, o, n, unit = m.groups()
                if name in ("metric", "script") or name.startswith("---"):
                    continue
                rows[name] = (o, n, unit)
    return rows


def num(x):
    try:
        return float(x)
    except ValueError:
        return None


def main():
    base, after = parse(sys.argv[1]), parse(sys.argv[2])
    print(f"| metric | oz base | oz after | Δ | nvim | unit |")
    print("|---|---|---|---|---|---|")
    for name, (o, n, u) in base.items():
        a = after.get(name)
        if a is None:
            print(f"| {name} | {o} | — | — | {n} | {u} |")
            continue
        ao, an, au = a
        ob, nb = num(o), num(ao)
        if ob is not None and nb is not None and nb != 0:
            d = f"{(nb / ob - 1) * 100:+.0f}%"
        elif ob is not None and nb is not None:
            d = f"{nb - ob:+.1f}"
        else:
            d = "—"
        print(f"| {name} | {o} | {ao} | {d} | {an} | {au} |")


if __name__ == "__main__":
    main()
