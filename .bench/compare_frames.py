#!/usr/bin/env python3
"""Time visible results in a private 120x40 tmux server (configured Vim-like editors).

Example: python3 .bench/compare_frames.py --editor oz=zig-out/bin/oz
    --editor nvim_clean=nvim --editor-arg nvim_clean=--clean --trials 7 --output /tmp/oz-frames.json

For Linux CPU sampling, build oz with -Doptimize=ReleaseFast -Dprofile
and repeat with --perf-dir /tmp/oz-traces and a separate --output manifest.
Use a fresh trace directory for each run. perf_report.py joins the traces
to independent, uninstrumented timings by editor, input and operation.

Each sample starts a fresh process with a warm file cache. Timers include tmux
key delivery and screen polling. Navigation measures when the destination first
appears, including any animation from the editor's configuration.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time


def make_fixture(path, size):
    zig = path.suffix == ".zig"
    row = b"const value_00000000: usize = 12345; // some source for scrolling\n" if zig else (
        b"2026-01-01 INFO worker completed a request successfully row 00000000\n")
    marker = b"// " if zig else b""
    paragraphs = (b"## Section 00000000\n", b"\n",
                  b"A paragraph with **emphasis**, a `code span` and [a reference](./next.txt).\n", b"\n")
    with path.open("wb") as out:
        first = marker + b"READY_BUFFER"
        if path.name == "wrapped.log":
            first += b" " + b"0123456789abcdef" * 32768
        out.write(first + b"\n")
        # Fixed-size chunks keep corpus generation out of the measurements.
        for end, label in [(size // 2, b"zqneedle SEARCH_LANDED"), (size, b"END_OF_BUFFER")]:
            while out.tell() < end:
                offset = out.tell()
                chunk = bytearray()
                for i in range(256):
                    template = paragraphs[i % len(paragraphs)] if path.suffix == ".md" else row
                    line = template.replace(b"00000000", f"{offset+i:08d}".encode())
                    if offset == len(first) + 1 and i == 79:
                        line = marker + b"SCROLL_CHECK\n"
                    chunk.extend(line)
                out.write(chunk)
            out.write(marker + label + b"\n")


def tree_pss_kib(pid):
    """Linux proportional resident memory, including the TUI's editor and LSP children."""
    pending = [pid]
    seen = set()
    total = 0
    try:
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            proc = Path("/proc") / pid
            for stat in (proc / "smaps_rollup").read_text().splitlines():
                if stat.startswith("Pss:"):
                    total += int(stat.split()[1])
                    break
            else:
                return None
            for thread in (proc / "task").iterdir():
                pending.extend((thread / "children").read_text().split())
        return total
    except OSError:
        # Unsupported platform, restricted procfs, or a transient child.
        return None


def editor_commands(parser, specs, flags):
    commands = {}
    for spec in specs:
        label, sep, exe = spec.partition("=")
        if not sep or not label or not exe or label in commands:
            parser.error("--editor requires a unique LABEL=EXECUTABLE")
        commands[label] = [str(Path(shutil.which(exe) or exe).resolve(strict=True))]
    for spec in flags:
        label, sep, arg = spec.partition("=")
        if not sep or label not in commands or not arg:
            parser.error("--editor-arg requires an existing LABEL=ARG")
        commands[label].append(arg)
    return list(commands.items())


def benchmark(editors, trials, root, selected_file, large_mib, perf_dir=None, first_save=False):
    server = ["tmux", "-S", str(root / "tmux.sock"), "-f", "/dev/null"]
    fixtures = {"code.zig": 32 * 1024, "large.log": large_mib * 1024**2,
                "wrapped.log": 2 * 1024**2, "notes.md": 160 * 1024}
    lsp_only = selected_file == "hover.zig"
    if lsp_only:
        source = root / "hover.zig"
        source.write_text('const api = @import("api.zig"); // READY_BUFFER\n'
                          'pub fn main() void {\n    api.warmup();\n    api.measure();\n}\n')
        files = [source]
    else:
        files = [root / selected_file] if selected_file else [root / name for name in fixtures]
        for path in files:
            make_fixture(path, fixtures[path.name])

    def tmux(*args):
        return subprocess.check_output(server + list(args), text=True, cwd=root)

    def wait_screen(marker, absent=None):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            frame = tmux("capture-pane", "-p", "-t", "bench")
            if marker in frame and (absent is None or absent not in frame):
                return
        raise RuntimeError(f"Timed out waiting for {marker!r} (absent={absent!r}):\n{frame}")

    def keys(*args):
        tmux("send-keys", "-t", "bench", *args)

    samples = []
    tmux("new-session", "-d", "-s", "keeper", "-x", "120", "-y", "40")
    try:
        for trial in range(trials):
            # Rotate the order. Both programs read the same warm page cache.
            for label, command_args in editors[trial % len(editors):] + editors[:trial % len(editors)]:
                for path in files:
                    with path.open("rb") as fixture:
                        while fixture.read(1024 * 1024):
                            pass
                    # Distinct names avoid restored cursors and swap files from earlier trials.
                    directory = Path(tempfile.mkdtemp(dir=root))
                    fixture_path = directory / path.name
                    measure_save = first_save and path.name == "large.log"
                    if measure_save:
                        # Some editors write in place. Give each process its own inode.
                        shutil.copyfile(path, fixture_path)
                    else:
                        os.link(path, fixture_path)
                    if lsp_only:
                        (directory / "zls.json").write_text("{}\n")
                        (directory / "api.zig").write_text(
                            "/// WARM_DOC_FROM_ZLS\npub fn warmup() void {}\n"
                            "/// MEASURE_DOC_FROM_ZLS\npub fn measure() void {}\n")
                    sibling = directory / "next.txt"
                    sibling.write_text("SECOND_BUFFER\n")
                    if path.name == "code.zig":
                        (directory / "second.zig").write_bytes(b"// SECOND_ZIG_FILE\n" + path.read_bytes())
                    result = {"editor": label, "trial": trial + 1, "file": path.name, "bytes": path.stat().st_size}

                    windows = {}

                    def timed(metric, action, marker, absent=None):
                        start = time.perf_counter_ns()
                        action()
                        wait_screen(marker, absent)
                        end = time.perf_counter_ns()
                        result[metric] = round((end - start) / 1e6, 2)
                        windows[metric] = [start, end]

                    argv = [*command_args, str(fixture_path)]
                    if perf_dir:
                        trace = perf_dir / f"{label}-{path.name}-{trial + 1}.data"
                        if trace.exists():
                            raise FileExistsError(trace)
                        argv = ["perf", "record", "-q", "-N", "-B", "-e", "cycles:u",
                                "-c", "2000000", "--clockid", "mono", "--user-callchains",
                                "--call-graph", "fp", "-o", str(trace), "--", *argv]
                    command = "exec " + shlex.join(argv)
                    try:
                        timed("open_ms", lambda: tmux("new-session", "-d", "-s", "bench", "-x", "120", "-y", "40",
                                                       "-c", str(directory), command), "READY_BUFFER")
                        time.sleep(0.35)
                        pid = tmux("display-message", "-p", "-t", "bench", "#{pane_pid}").strip()
                        pss = tree_pss_kib(pid)
                        if pss is not None:
                            result["open_pss_kib"] = pss
                        if lsp_only:
                            # A real cross-file response proves the language server is ready.
                            # Measure a distinct symbol so an editor's hover cache cannot win.
                            wait_screen("zls")
                            keys("ggjj0fwK")
                            wait_screen("WARM_DOC_FROM_ZLS")
                            keys("j0fm")
                            wait_screen("api.measure", absent="WARM_DOC_FROM_ZLS")
                            timed("hover_ms", lambda: keys("K"), "MEASURE_DOC_FROM_ZLS")
                        else:
                            timed("jump_ms", lambda: keys("G"), "END_OF_BUFFER")
                            timed("top_ms", lambda: keys("g", "g"), "READY_BUFFER")
                            timed("search_ms", lambda: keys("/zqneedle", "Enter"), "SEARCH_LANDED")
                            keys("g", "g")
                            wait_screen("READY_BUFFER")
                            timed("insert_ms", lambda: keys("iTYPE_CHECK", "Escape"), "TYPE_CHECK")
                            timed("scroll_ms", lambda: keys("80j"), "SCROLL_CHECK")
                            timed("undo_ms", lambda: keys("u"), "READY_BUFFER", absent="TYPE_CHECK")
                            if measure_save:
                                keys("gg0iSAVED_CHECK", "Escape")
                                wait_screen("SAVED_CHECKREADY_BUFFER")
                                timed("save_ms", lambda: keys(":w", "Enter", "iWRITE_ACK", "Escape"), "WRITE_ACK")
                                with fixture_path.open("rb") as saved:
                                    if saved.readline() != b"SAVED_CHECKREADY_BUFFER\n":
                                        raise RuntimeError("First save did not persist the expected edit")
                                keys("u")
                                wait_screen("SAVED_CHECKREADY_BUFFER", absent="WRITE_ACK")
                            timed("switch_ms", lambda: keys(":e next.txt", "Enter"), "SECOND_BUFFER")
                            if path.name == "code.zig":
                                timed("switch_zig_ms", lambda: keys(":e second.zig", "Enter"), "SECOND_ZIG_FILE")
                        keys(":q!", "Enter")
                        if perf_dir:
                            # Allow the recorder to close the trace before destroying the PTY.
                            deadline = time.monotonic() + 20
                            while subprocess.run(server + ["has-session", "-t", "=bench"],
                                                 capture_output=True).returncode == 0:
                                if time.monotonic() >= deadline:
                                    raise RuntimeError(f"Recorder failed to exit: {trace}")
                                time.sleep(.02)
                            result["windows_ns"] = windows
                            result["perf_data"] = trace.name
                        samples.append(result)
                        print(json.dumps(result), flush=True)
                    finally:
                        subprocess.run(server + ["kill-session", "-t", "bench"], capture_output=True)
                        if measure_save:
                            fixture_path.unlink(missing_ok=True)
    finally:
        subprocess.run(server + ["kill-server"], capture_output=True)
    return samples


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", action="append", required=True, metavar="LABEL=EXECUTABLE")
    parser.add_argument("--editor-arg", action="append", default=[], metavar="LABEL=ARG")
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--file", choices=["code.zig", "large.log", "wrapped.log", "notes.md", "hover.zig"],
                        help="select one corpus; hover.zig measures cross-file K with configured ZLS")
    parser.add_argument("--large-mib", type=int, default=50, help="target size of the large.log corpus")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--first-save", action="store_true", help="also time the first edited :w on a private large.log")
    parser.add_argument("--perf-dir", type=Path,
                        help="record user CPU stacks and monotonic operation windows (Linux); time separately without this option")
    args = parser.parse_args()
    if args.trials < 1 or args.large_mib < 1:
        parser.error("--trials and --large-mib must be positive")
    editors = editor_commands(parser, args.editor, args.editor_arg)
    if args.perf_dir:
        args.perf_dir = args.perf_dir.resolve()
        args.perf_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="oz-frame-bench-") as tmp:
        results = benchmark(editors, args.trials, Path(tmp), args.file, args.large_mib, args.perf_dir, args.first_save)
    args.output.write_text(json.dumps(results, indent=2) + "\n")
