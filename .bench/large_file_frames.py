#!/usr/bin/env python3
"""Measure first frame and immediate navigation on real files with verified cold/warm file pages.

Linux only. Uses the same fixtures, tmux screen oracle and cycles:u period as compare_frames.py.
The supplied corpus directory holds only generated fixtures; each editor opens a private hard link.
"""
import argparse
import ctypes
import json
import mmap
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

from compare_frames import editor_commands, make_fixture, tree_pss_kib


def set_cache(file, cold):
    if cold:
        os.posix_fadvise(file.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
    else:
        while file.read(1024**2):
            pass
    size = os.fstat(file.fileno()).st_size
    pages = (size + mmap.PAGESIZE - 1) // mmap.PAGESIZE
    vec = (ctypes.c_ubyte * pages)()
    libc = ctypes.CDLL(None, use_errno=True)
    with mmap.mmap(file.fileno(), size, access=mmap.ACCESS_COPY) as mapping:
        addr = ctypes.addressof(ctypes.c_char.from_buffer(mapping))
        if libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(size), vec):
            raise OSError(ctypes.get_errno(), "mincore")
    count = sum(v & 1 for v in vec)
    if count != (0 if cold else pages):
        raise RuntimeError(f"unexpected cache residency {count}/{pages}, cold={cold}")
    return count, pages


def measure(server, label, program, path, cold, trial, trace_dir, with_search=True, editor_args=()):
    def tmux(*args):
        return subprocess.check_output([*server, *args], text=True)
    name = f"{path.parent.parent.name}-{'cold' if cold else 'warm'}.log"
    argv = [program, *editor_args, str(path)]
    result = dict(editor=label, trial=trial + 1, file=name, bytes=path.stat().st_size)
    if trace_dir:
        trace = trace_dir / f"{label}-{name}-{trial+1}.data"
        if trace.exists():
            raise FileExistsError(trace)
        argv = ["perf", "record", "-q", "-N", "-B", "-e", "cycles:u", "-c", "2000000",
                "--clockid", "mono", "--user-callchains", "--call-graph", "fp", "-o", str(trace), "--", *argv]
        result["perf_data"] = trace.name
    windows = {}

    def timed(key, send, marker, absent=None):
        start = time.perf_counter_ns()
        send()
        while True:
            frame = tmux("capture-pane", "-p", "-t", "bench")
            if marker in frame and (absent is None or absent not in frame):
                break
            if time.perf_counter_ns() - start > 120_000_000_000:
                raise RuntimeError(f"{label}/{name}/{key}: waiting for {marker}\n{frame}")
        end = time.perf_counter_ns()
        result[key] = round((end - start) / 1e6, 2)
        windows[key] = [start, end]

    def keys(*args):
        tmux("send-keys", "-t", "bench", *args)

    with path.open("rb") as file:
        result["resident_pages"], result["total_pages"] = set_cache(file, cold)
    try:
        timed("open_ms", lambda: tmux("new-session", "-d", "-s", "bench", "-x", "120", "-y", "40",
                                      "-c", str(path.parent), "exec " + shlex.join(argv)), "READY_BUFFER")
        # Intentionally no settling delay: an immediate G includes any outstanding index work.
        timed("jump_ms", lambda: keys("G"), "END_OF_BUFFER")
        if with_search:
            timed("line_ms", lambda: keys(":81", "Enter"), "SCROLL_CHECK")
            timed("search_ms", lambda: keys("/zqneedle", "Enter"), "SEARCH_LANDED")
        timed("top_ms", lambda: keys("gg"), "READY_BUFFER")
        timed("insert_ms", lambda: keys("iTYPE_CHECK", "Escape"), "TYPE_CHECK")
        timed("undo_ms", lambda: keys("u"), "READY_BUFFER", absent="TYPE_CHECK")
        timed("repeat_jump_ms", lambda: keys("G"), "END_OF_BUFFER")
        if not trace_dir:
            pid = tmux("display-message", "-p", "-t", "bench", "#{pane_pid}").strip()
            result["pss_kib"] = tree_pss_kib(pid)
        keys(":q!", "Enter")
        deadline = time.monotonic() + 120
        while subprocess.run([*server, "has-session", "-t", "=bench"], capture_output=True).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError(f"{label} failed to exit")
            time.sleep(.02)
        if trace_dir:
            result["windows_ns"] = windows
        return result
    finally:
        subprocess.run([*server, "kill-session", "-t", "=bench"], capture_output=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--corpus", type=Path, required=True)
    p.add_argument("--mib", type=int, required=True)
    p.add_argument("--editor", action="append", default=[])
    p.add_argument("--editor-arg", action="append", default=[], metavar="LABEL=ARG",
                   help="Pass one argument to a named editor, e.g. nvim_clean=--clean")
    p.add_argument("--trials", type=int, default=3)
    p.add_argument("--perf-dir", type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--fixture-repo", type=Path, help="Isolated fixture repo tracking large.log. Use its Git metadata for every run.")
    args = p.parse_args()
    root = args.corpus.resolve() / str(args.mib)
    root.mkdir(parents=True, exist_ok=True)
    source = root / "large.log"
    if not source.exists():
        with tempfile.NamedTemporaryFile(dir=root, suffix=".log") as tmp:
            make_fixture(Path(tmp.name), args.mib * 1024**2)
            os.fsync(tmp.fileno())
            os.link(tmp.name, source)
    if args.fixture_repo:
        repo = args.fixture_repo.resolve(strict=True)
        if not (repo / "large.log").samefile(source):
            p.error("the corpus must be a hard link to fixture-repo/large.log")
        subprocess.run(["git", "-C", repo, "ls-files", "--error-unmatch", "--", "large.log"],
                       check=True, stdout=subprocess.DEVNULL)
    if not args.editor:
        return
    if not args.output or args.trials < 1:
        p.error("specify --output and a positive number of trials")
    editors = editor_commands(p, args.editor, args.editor_arg)
    if args.perf_dir:
        args.perf_dir = args.perf_dir.resolve()
        args.perf_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    with tempfile.TemporaryDirectory() as sock:
        server = ["tmux", "-S", str(Path(sock) / "server"), "-f", "/dev/null"]
        subprocess.run([*server, "new-session", "-d", "-s", "keeper", "-x", "120", "-y", "40"], check=True)
        try:
            for i in range(args.trials):
                for label, argv in editors[i % len(editors):] + editors[:i % len(editors)]:
                    for cold in ((True, False) if i % 2 == 0 else (False, True)):
                        with tempfile.TemporaryDirectory(dir=root) as temp:
                            path = Path(temp) / source.name
                            os.link(source, path)
                            if args.fixture_repo:
                                # Private path for each editor's view/undo history, shared immutable HEAD.
                                (path.parent / ".git").symlink_to(repo / ".git", target_is_directory=True)
                            row = measure(server, label, argv[0], path, cold, i, args.perf_dir,
                                          editor_args=argv[1:])
                        rows.append(row)
                        print(json.dumps(row), flush=True)
                        with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent, delete=False) as progress:
                            json.dump(rows, progress, indent=2)
                            progress.write("\n")
                        os.replace(progress.name, args.output)
        finally:
            subprocess.run([*server, "kill-server"], capture_output=True)


if __name__ == "__main__":
    main()
