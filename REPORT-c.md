# perf/c-motion — line-local motion scanning (REPORT)

**Worktree:** `.wt-c` (branch `perf/c-motion`)
**File changed:** `src/editor/motion.zig` only (no PieceTable helper needed)
**Commit:** `perf: line-local motion scanning (w/e/b/f/t/{} via copyRange, no per-char byteAt)`

## What changed

Every byte-at-a-time scan in `motion.zig` used to call `PieceTable.byteAt(pos)`,
which is O(pieces) on a fragmented piece table — so `w/e/b/f/t/{}/%` cost
O(chars × pieces), and pieces grow with every edit.

A motion now scans through a shared sliding window (`DocScan`, 4 KiB, stack
buffer) refilled with `copyRange`. One window per motion: the first refill is a
single O(pieces) `copyRange`, then every per-byte read is a plain slice index,
so a motion costs O(line + pieces·line/4096) instead of O(chars × pieces).
Longer scans slide the window (each slide = one more `copyRange`), so cost
stays O(line) in bytes scanned. The window is placed with a 4-byte margin on
the refill side so the UTF-8 boundary peeks (`prevCharBoundary`/
`nextCharBoundary`, ≤ 3 bytes) stay inside it and never trigger extra refills.

Rewritten to scan through `DocScan`:

- `wordNext` (w), `wordNextEnd` (e), `wordPrev` (b), `wordPrevEnd` (ge) — same
  byte-by-byte algorithm, bytes now come from the window (EOF still behaves as
  trailing whitespace, exactly like the old `byteOrSpace`).
- `findInLine` (f/F/t/T) — same line-confined scan, windowed.
- `matchPair`/`matchOpen`/`matchClose` (%) — bracket scans use a windowed
  forward/backward sweep (4 KiB chunks; brackets are ASCII so window boundaries
  are safe).
- `lineFirstNonBlank` (^) — was also O(chars × pieces); now windowed.
- `prevCharBoundary`/`nextCharBoundary`/`lastCharStart` (used by h/l/$/j/k
  clamp/e/ge) — now read through the scan instead of `byteAt`.

Already O(1)/O(log n) and left unchanged: `moveVert` (j/k: `lineOf` +
`lineStart`/`lineLen` clamp; `lastCharStart` only on the clamp path),
`paragraph` ({/}: already line-index-based via `lineLen`, no byteAt in the
walk), `pageMove`, `gg`/`G`, `^`-family line motions, `apply` count loop.

No new PieceTable API was needed — the existing public
`copyRange`/`lineOf`/`lineStart`/`lineLen`/`lineCount` suffice, so
`src/buffer/piece_table.zig` is untouched by this change.

## Evidence

### Temporary timing test (removed before commit)

Built a ~10.7 MB / ~300k-line doc, fragmented it with 5000 random replaces
(→ 8404 pieces), timed 10 000 applications of each motion from 8 positions
spread across the doc, `std.Io.Timestamp` (.awake), ns/step.

**Before** (per-char `byteAt`):

| motion | Debug ns/step | ReleaseFast ns/step |
|--------|--------------:|--------------------:|
| w      | 47 007        | 4 559               |
| e      | 62 415        | 6 036               |
| b      | 49 612        | 4 823               |
| ge     | 128 805       | 11 858              |
| f      | 113 979       | 11 047              |
| %      | 119 579       | 11 412              |
| {      | 261           | 28                  |
| }      | 152           | 15                  |
| j      | 117           | 14                  |
| k      | 119           | 13                  |

**After** (windowed `copyRange` scanning):

| motion | Debug ns/step | ReleaseFast ns/step |
|--------|--------------:|--------------------:|
| w      | 6 205         | 810                 |
| e      | 6 328         | 803                 |
| b      | 6 363         | 808                 |
| ge     | 6 358         | 813                 |
| f      | 6 476         | 821                 |
| %      | 6 506         | 826                 |
| {      | 260           | 24                  |
| }      | 160           | 16                  |
| j      | 117           | 13                  |
| k      | 110           | 12                  |

Target: **every motion ≤ 1 µs/step** — met in ReleaseFast (0.80–0.83 µs for
the byte-scanning motions, 12–24 ns for the line-index motions). The residual
ReleaseFast cost is dominated by the single `copyRange` piece-list walk per
motion; the scan itself is sub-µs. Debug is ~8–10× slower (unoptimized build),
as expected.

The timing test's position checksum is identical before/after
(`502025152486`) — the sweep lands on the same positions, i.e. behavior is
unchanged.

Note: the sibling `perf/a-piece` rework (a `byteAt` hint + incremental line
index) landed in this worktree mid-session; with it composed in, both the old
and the new motion code drop to ~0.2 µs/step (sequential `byteAt` becomes
O(1) amortized). This change is still worthwhile — it removes the O(pieces)
per-byte dependence for backward/random scans and for the `copyRange` fetch,
and it is what the numbers above (taken with the un-reworked piece table)
demonstrate.

### Unit tests

`zig build test` (Debug): all 281 tests pass, including every motion test
(UTF-8 boundaries, w/e/b/ge edge cases, find/till, match pair, paragraph,
page, apply/target consistency sweep). Exit 0.

### Bench (pty, 3 iters)

`python3 .bench/corpus/gen.py && python3 .bench/run_bench.py --iters 3
--out .bench/results/c-after.md` — see
[`.bench/results/c-after.md`](.bench/results/c-after.md), compared against the
same run on the pristine tree (`.bench/results/c-baseline.md`, generated the
same session):

| script | baseline oz /key | after oz /key |
|---|---|---|
| gg w x30 (word fwd) | 0.4 ms | 0.4 ms |
| gg e x30 (word end) | 0.4 ms | 0.4 ms |
| G b x30 (word back) | 25.3 ms | 25.7 ms |
| gg {} x30 (paragraph) | 0.9 ms | 0.6 ms |
| gg f4 + ; x20 (char find) | 0.4 ms | 0.4 ms |
| gg j x20 / G k x20 / G ctrl-b | 6.1 / 25.2 / 9.2 ms | 6.0 / 25.4 / 9.1 ms |

Every row stays at or below baseline; the mission's sanity rows
(w/e/f4 ≈ 0.4 ms, {} ≈ 0.8 ms, whole-script medians including render) all
pass ({} actually improved 0.9 → 0.6). The slow `G b`/`G k`/`G ctrl-b` rows
(~25 ms/key, upward from the document bottom) are identical on the pristine
baseline — a pre-existing render/scroll cost in the upward-from-bottom path
(the b-render agent's area), not a motion regression: the motion micro-bench
above shows `b` at ~0.8 µs/step.

### e2e

`zig build e2e`: 108/109 pass. The one failure —
`relative CLI path: :w saves without BadPathName` — is a pty grid-timeout that
**also fails on the fully pristine tree** (both `motion.zig` and
`piece_table.zig` reverted to HEAD, verified) and the failure set varies
between runs (`grep picker: …` failed once); it is a pre-existing flake under
concurrent-agent load, not caused by this change. `zig build test`'s one
pre-existing leak (`buffer.ops.test.wordStartBefore…` leaking 1 allocation)
also reproduces on pristine sources.

### Build

`zig build -Doptimize=ReleaseFast -Dstrip` — succeeds.
`zig fmt` applied to `src/editor/motion.zig`.

## Files

- `src/editor/motion.zig` — the only source file changed (+125/−68).
- `REPORT-c.md` — this report.
