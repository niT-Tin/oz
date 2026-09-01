#!/usr/bin/env python3
"""oz vs nvim(--clean) performance benchmark harness.

Runs both editors in a pty of identical size, drives scripted keys, and
measures wall-clock end-to-end latency the same way for both:

  startup    : spawn -> first stable frame (quiescence)
  load       : open file -> stable frame
  key latency: per-key time from write(master) until new bytes arrive
  bulk ops   : sum of per-key latencies over a key sequence
  memory     : VmRSS of the editor process

Usage:
  python3 bench/run_bench.py [--iters N] [--out results.md]
"""
import argparse
import fcntl
import os
import select
import struct
import subprocess
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OZ = os.path.join(HERE, "..", "zig-out", "bin", "oz")
NVIM = "nvim"

COLS, ROWS = 120, 40
QUIESCE_MS = 120          # no output for this long => "stable frame"
MAX_WAIT_S = 30           # hard deadline for any single wait
KEY_WAIT_S = 3.0          # per-key latency cap; longer => NaN (no output)
ENV = dict(os.environ, TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS))


class Editor:
    def __init__(self, argv, label):
        self.label = label
        self.master, slave = os.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", ROWS, COLS, 0, 0))
        os.set_blocking(self.master, False)
        def _preexec():
            # session leader + controlling tty (vaxis opens /dev/tty)
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.proc = subprocess.Popen(
            argv,
            stdin=slave, stdout=slave, stderr=slave,
            preexec_fn=_preexec,
            env=ENV, close_fds=True,
        )
        os.close(slave)
        self.rss = 0
        self.total_out = 0

    def read_available(self, timeout_s=0.0):
        """Read everything available; return bytes."""
        out = bytearray()
        deadline = time.monotonic() + timeout_s
        while True:
            r, _, _ = select.select([self.master], [], [], max(0.0, deadline - time.monotonic()))
            if not r:
                break
            try:
                chunk = os.read(self.master, 65536)
            except BlockingIOError:
                break
            if not chunk:
                break
            out += chunk
            if time.monotonic() >= deadline:
                break
        self.total_out += len(out)
        return bytes(out)

    def wait_quiesce(self, quiet_ms=QUIESCE_MS, max_s=MAX_WAIT_S):
        """Wait until no output for quiet_ms. Returns total bytes seen."""
        n = 0
        end = time.monotonic() + max_s
        while time.monotonic() < end:
            r, _, _ = select.select([self.master], [], [], quiet_ms / 1000.0)
            if r:
                try:
                    chunk = os.read(self.master, 65536)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    n += len(chunk)
                    self.total_out += len(chunk)
                    continue
            return n  # quiet
        raise TimeoutError(f"{self.label}: never quiesced")

    def send(self, s):
        os.write(self.master, s.encode() if isinstance(s, str) else s)

    def key_latency(self, key, pre_sleep=0.0):
        """Send key; return ms until new bytes appear (or None on timeout)."""
        self.read_available()
        if pre_sleep:
            time.sleep(pre_sleep)
        t0 = time.perf_counter()
        self.send(key)
        end = t0 + KEY_WAIT_S
        while time.perf_counter() < end:
            r, _, _ = select.select([self.master], [], [], 0.002)
            if r:
                try:
                    chunk = os.read(self.master, 65536)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    self.total_out += len(chunk)
                    return (time.perf_counter() - t0) * 1000.0
        return None

    def rss_kb(self):
        try:
            with open(f"/proc/{self.proc.pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1])
        except Exception:
            pass
        return 0

    def kill(self):
        try:
            os.killpg(self.proc.pid, 15)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except Exception:
            try:
                os.killpg(self.proc.pid, 9)
            except Exception:
                pass


def bench_open(cmd, path, label, iters):
    """startup+load latency and memory for opening `path`."""
    ready = []
    rss = []
    for _ in range(iters):
        e = Editor([*cmd, path], label)
        t0 = time.perf_counter()
        e.wait_quiesce()
        ready.append((time.perf_counter() - t0) * 1000.0)
        e.wait_quiesce(quiet_ms=60)
        rss.append(e.rss_kb())
        e.kill()
    return ms(ready), min(rss)


def bench_keys(cmd, path, script, label, iters, setup=None, per_key=True):
    """Run a key script; measure per-key latency (sum) or whole-script time."""
    per_key_times = []
    total_times = []
    for _ in range(iters):
        e = Editor([*cmd, path], label)
        e.wait_quiesce()
        if setup:
            setup(e)
        e.read_available()
        t0 = time.perf_counter()
        times = []
        for key in script:
            if isinstance(key, tuple):  # (keys, pre_sleep)
                k, sleep = key
            else:
                k, sleep = key, 0.0
            lat = e.key_latency(k, pre_sleep=sleep)
            if lat is None:
                lat = float("nan")
            times.append(lat)
        total_times.append((time.perf_counter() - t0) * 1000.0)
        per_key_times.append(times)
        e.kill()
    if per_key:
        # median over the middle iteration's per-key latencies, NaN-filtered
        med = [t for t in per_key_times[len(per_key_times) // 2] if t == t]
        med = sorted(med) if med else [float("nan")]
        return ms(med), ms(total_times)
    return ms(total_times), None


def ms(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]


def fmt(x, unit="ms"):
    if isinstance(x, (int, float)):
        return f"{x:.1f}"
    return "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=5)
    ap.add_argument("--out", default=os.path.join(HERE, "results", "baseline.md"))
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    corpus = os.path.join(HERE, "corpus")
    small = os.path.join(corpus, "small.zig")
    medium = os.path.join(corpus, "medium.zig")
    large = os.path.join(corpus, "large.log")
    huge = os.path.join(corpus, "huge.txt")

    oz = [OZ]
    nv = ["nvim", "--clean"]

    L = []
    L.append("# oz vs nvim(--clean) benchmark\n")
    L.append(f"- terminal: pty {COLS}x{ROWS}, TERM=xterm-256color")
    L.append(f"- iters: {args.iters}, medians; latency = keypress -> first output byte\n")

    def row(name, o, n, unit="ms"):
        L.append(f"| {name} | {o} | {n} | {unit} |")

    L.append("\n## startup & load (time-to-first-stable-frame, ms)\n")
    L.append("| metric | oz | nvim --clean | unit |")
    L.append("|---|---|---|---|")

    tiny = os.path.join(corpus, "tiny.txt")
    with open(tiny, "w") as f:
        f.write("hello\n")
    for path, name in ((tiny, "tiny (startup only)"), (small, "small.zig (28KB)"),
                       (medium, "medium.zig (90KB)"), (large, "large.log (12MB)"),
                       (huge, "huge.txt (50MB)")):
        os_ = bench_open(oz, path, "oz", args.iters)
        nv_ = bench_open(nv, path, "nv", args.iters)
        row(f"open {name}", os_[0], nv_[0])
        row(f"memory RSS {name} (KiB)", os_[1], nv_[1], "KiB")
        print(f"open {name}: oz ready={os_[0]:.1f}ms rss={os_[1]} | nvim ready={nv_[0]:.1f}ms rss={nv_[1]}", flush=True)

    # movements on medium file (syntax-heavy, real editing feel)
    L.append("\n## cursor movement (median per-key ms, sum = whole script)\n")
    L.append("| script | oz /key | nvim /key | oz total | nvim total | unit |")
    L.append("|---|---|---|---|---|---|")

    scripts = [
        ("gg j x20 (line down)", "gg" + "j" * 20),
        ("G k x20 (line up)", "G" + "k" * 20),
        ("gg w x30 (word fwd)", "gg" + "w" * 30),
        ("gg e x30 (word end)", "gg" + "e" * 30),
        ("G b x30 (word back)", "G" + "b" * 30),
        ("gg ctrl-f x10 (page down)", "gg" + "\x0c" * 10),
        ("G ctrl-b x10 (page up)", "G" + "\x02" * 10),
        ("gg {} x30 (paragraph)", "gg" + "{}{}" * 15),
        ("gg f4 + ; x20 (char find)", "gg" + "f4" + ";" * 20),
    ]
    for name, script in scripts:
        om, ot = bench_keys(oz, medium, script, "oz", args.iters)
        nm, nt = bench_keys(nv, medium, script, "nv", args.iters)
        row(f"{name}", f"{fmt(om)}", f"{fmt(nm)}")
        row(f"{name} (total)", f"{fmt(ot)}", f"{fmt(nt)}")
        print(f"{name}: oz {fmt(om)}ms/key (total {fmt(ot)}) | nvim {fmt(nm)}ms/key (total {fmt(nt)})", flush=True)

    # large jumps on the 12MB file
    L.append("\n## big jumps on large.log (12MB, 200k+ lines)\n")
    L.append("| script | oz /key | nvim /key | unit |")
    L.append("|---|---|---|---|")
    for name, script in [("gg (to top)", "gg"), ("G (to bottom)", "G"),
                         ("ctrl-f x20", "\x0c" * 20), ("search /len n x10", "/len\r" + "n" * 10)]:
        om, ot = bench_keys(oz, large, script, "oz", args.iters)
        nm, nt = bench_keys(nv, large, script, "nv", args.iters)
        row(f"{name}", f"{fmt(om)}", f"{fmt(nm)}")
        print(f"{name}: oz {fmt(om)}ms/key | nvim {fmt(nm)}ms/key", flush=True)

    # typing on a .log file (no syntax/LSP involvement for either side)
    L.append("\n## insert typing on large.log (no syntax/LSP)\n")
    L.append("| script | oz /key | nvim /key | unit |")
    L.append("|---|---|---|---|")
    om, ot = bench_keys(oz, large, "i" + "abcdefghij" * 5, "oz", args.iters)
    nm, nt = bench_keys(nv, large, "i" + "abcdefghij" * 5, "nv", args.iters)
    row("i + 50 chars", f"{fmt(om)}", f"{fmt(nm)}")
    print(f"typing 50 chars: oz {fmt(om)}ms/key | nvim {fmt(nm)}ms/key", flush=True)

    L.append("\n## notes\n")
    L.append("- NaN = key produced no output within timeout")
    L.append("- corpus: bench/corpus (generated by corpus/gen.py)\n")

    with open(args.out, "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"\nreport: {args.out}")


if __name__ == "__main__":
    main()
