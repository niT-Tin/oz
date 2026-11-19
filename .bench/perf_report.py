#!/usr/bin/env python3
"""Turn compare_frames.py results and Linux perf traces into a portable offline report.

--profile takes one WINDOWS.json=TRACE_DIRECTORY pair per recording run.
--timing takes separate recordings made without perf. All inputs must use
the same editors, clock, hardware cycle period and corpus sizes.
"""
import argparse
from collections import Counter, defaultdict
from decimal import Decimal
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess

HEADER = re.compile(r"^\s*(.*?)\s+\d+\s+(\d+\.\d+):\s+cycles:u:\s*$")
FRAME = re.compile(r"^\s+[0-9a-f]+\s+(.+) \((.*)\)\s*$")
PERIOD = 2_000_000


def collect_trace(trace, windows):
    """Attribute samples only between sending the keys and observing their destination."""
    env = dict(os.environ, DEBUGINFOD_URLS="")
    stats = subprocess.check_output(["perf", "report", "--stats", "-i", trace], env=env, text=True)
    sample_count = int(re.search(r"SAMPLE events:\s*(\d+)", stats)[1])
    lost = re.search(r"\bLOST(?:_SAMPLES)? events:\s*(\d+)", stats)
    if lost and int(lost[1]):
        raise ValueError(f"{trace}: {lost[0]}")
    by_phase = defaultdict(Counter)
    comm = phase = None
    total = 0
    frames = []
    windows = sorted((start, end, key) for key, (start, end) in windows.items())
    def flush():
        if phase is None:
            return
        # Some frame-pointer chains end with unmapped return addresses. Keep
        # any unknown leaf, and never attribute it to the last known function.
        while len(frames) > 1 and frames[-1] == "[unknown]":
            frames.pop()
        by_phase[phase][(comm, *reversed(frames or ["[unknown]"]))] += 1

    with subprocess.Popen(["perf", "script", "--ns", "--no-inline", "-i", trace,
                           "-F", "comm,pid,time,event,ip,sym,dso"], env=env, text=True,
                          stdout=subprocess.PIPE) as proc:
        for line in proc.stdout:
            if match := HEADER.match(line):
                flush()
                total += 1
                frames.clear()
                comm = match[1]
                stamp = int(Decimal(match[2]) * 10**9)
                phase = next((key for start, end, key in windows if start <= stamp < end), None)
            elif phase is not None and (match := FRAME.match(line)):
                symbol, dso = match.groups()
                if symbol == "[unknown]" and dso != "[unknown]":
                    library = Path(dso).name
                    if re.fullmatch(r"perf-\d+\.map", library):
                        library = "JIT map"
                    symbol = f"[{library}: unknown]"
                frames.append(symbol)
        flush()
        if proc.wait():
            raise ValueError(f"perf script failed for {trace}")
    if total != sample_count:
        raise ValueError(f"{trace}: decoded {total} of {sample_count} samples")
    return by_phase, total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", action="append", required=True)
    parser.add_argument("--timing", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    profiles = defaultdict(Counter)
    runs = Counter()
    recorded = 0
    sizes = {}
    def check_size(row):
        name, size = row["file"], row["bytes"]
        if sizes.setdefault(name, size) != size:
            raise ValueError(f"Different corpora for {name}")
    for arg in args.profile:
        manifest, folder = arg.split("=", 1)
        for row in json.loads(Path(manifest).read_text()):
            check_size(row)
            base = (row["file"], row["editor"])
            phase_counts, total = collect_trace(Path(folder) / row["perf_data"], row["windows_ns"])
            recorded += total
            runs[base] += 1
            for phase, stacks in phase_counts.items():
                profiles[(*base, phase)].update(stacks)
    latencies = defaultdict(list)
    for filename in args.timing:
        for row in json.loads(filename.read_text()):
            check_size(row)
            if "perf_data" in row:
                raise ValueError("Use unprofiled runs for latencies")
            for metric, value in row.items():
                if metric.endswith("_ms"):
                    latencies[(row["file"], row["editor"], metric)].append(value)
    symbols = {}
    entries = []
    for key, values in sorted(latencies.items()):
        file, editor, phase = key
        stacks = profiles.get(key, {})
        weighted = []
        for stack, count in stacks.items():
            ids = [symbols.setdefault(name, len(symbols)) for name in stack]
            weighted.append([count, ids])
        entries.append(dict(file=file, editor=editor, phase=phase, traces=runs[(file, editor)],
                            n=len(values), median=statistics.median(values),
                            p90=sorted(values)[math.ceil(len(values) * .9) - 1], stacks=weighted))
    if {tuple(k[:2]) for k in latencies} != set(runs):
        raise ValueError("Profile and timing populations differ")
    report = dict(symbols=list(symbols), entries=entries, sizes=sizes, period=PERIOD, recorded=recorded)
    payload = json.dumps(report, ensure_ascii=False, separators=(",", ":")).replace("<", r"\u003c")
    template = Path(__file__).with_suffix(".html").read_text()
    args.output.write_text(template.replace("PERF_REPORT_DATA", payload))
    print(f'{sum(runs.values())} profiles, {recorded} samples, '
          f'{sum(sum(v.values()) for v in profiles.values())} in measured windows')


if __name__ == "__main__":
    main()
