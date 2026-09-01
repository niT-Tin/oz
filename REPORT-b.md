# perf/b-render — render-path latency report

Branch `perf/b-render`, worktree `.wt-b`. Scope: `src/main.zig` RENDER path only
(`renderWindowLines`, `render`, `run` loop, gutter/number/guide buffers, blank
scan, diag/git marks, scopeAt call site, spans call site, blame ghost).
`syntax.zig`, `piece_table.zig`, `visibleSpansFor`, `lsp/` untouched.

## Summary

| metric (per-key median) | baseline | after my commit | target |
|---|---|---|---|
| medium.zig `gg j x20` | 6.1 ms | **1.14 ms** | ≤ 2 ms ✅ |
| medium.zig `G k x20` | 25.2 ms | **6.5 ms** | ≤ 2 ms ❌ (scopeAt residual, see below) |
| large.log `gg j x20` | — | **0.19 ms** | ≤ 0.5 ms ✅ |

(Measurements taken on an otherwise-idle box; the box is shared with four
parallel agents and numbers inflate 3-10× under their build/bench load —
e.g. `G k` reads 21 ms while `loadavg` ≈ 3.)

## What was already in the tree (committed as `d40bbcc` / `1568559`)

The worktree arrived with a prior render pass already committed:
- blank-line context scan hoisted into `blankContextLevels` + per-run memo
  (`prev_blank`/`blank_run_ctx`), `isBlankLine`/`lineIndentLevels` rewritten to
  ONE chunked `copyRange` (no per-char `byteAt`);
- per-frame `text_buf`/`num_buf`/`guide_buf` + one pre-reserved `segs`
  ArrayList (clearRetainingCapacity per row), stack-buffer relative numbers;
- diag + git-hunk moving pointers (O(rows + items) instead of O(rows × items));
- `scope_cache` keyed on (buf, win, revision, cursor byte).

**None of that moved the needle on the spikes**: benchmark on that commit still
measured 6.2 ms (`gg j`) / 25.5 ms (`G k`).

## Profiling (temporary `std.Io.Timestamp` instrumentation, removed)

Per-frame breakdown on medium.zig at the bottom of the file (38-row viewport):

```
render=9641us  spans=3957us  scope=5504us(1 call)  rows=38  rowloop=51us  blank=0us(4)  print=50us
render=3971us  spans=3843us  scope=0us(0)          rows=38  rowloop=46us  blank=0us(4)  print=45us
poll-sleep=16013us anim=true blame=false
```

Three findings:

1. **The 16 ms poll sleep was the dominant per-key cost** (this is the real
   spike the mission described). After any scope change the 500 ms
   scope-highlight animation flips the run loop into poll mode, and the poll
   was `sleep(16 ms)` — a keypress arriving mid-sleep waited up to a full
   animation frame. `G k x20` spends its entire 500 ms run inside the
   animation window, so every key paid ~16 ms + render. `gg j` pays it too
   (every fn-boundary crossing restarts the animation), which is why the
   "good" keys measured 6 ms instead of 0.4 ms.
2. **`visibleSpansFor` re-runs the tree-sitter query every frame** (~4 ms at
   the file bottom, ~0.3 ms at the top — the query cursor's range walk is
   position-dependent), even when the visible byte range is unchanged
   (cursor moving inside a window, animation frames).
3. **`scopeAt` costs ~5.5 ms per call at the file bottom** — a linear scan of
   the root's ~2400 children (each fn is a root child; the scan finds the one
   containing the cursor). Cheap at the top (early break), ~5.5 ms at the
   bottom. This is `syntax.zig`'s `scopeAt` implementation — out of my scope.

The blank scan, per-row allocs and diag/git lookups were already negligible
after the committed pass (blank 0 us, rowloop ~50 us, print ~50 us).

## Changes in this commit (all `src/main.zig`)

1. **Run loop: poll in 1 ms slices + render pacing** (`run()`). While the
   scope animation / blame hold / terminal is active, the loop now sleeps
   1 ms instead of 16 ms, and renders only when an event was handled or 16 ms
   have elapsed since the last frame. A keypress wakes the loop within ~1 ms
   while animation frames still advance at ~60 fps. This removed the
   sleep-dominated 6-16 ms from every key during the animation window.
   (`last_render_ms` tracks the pacing; the LSP/git "ready" renders keep
   rendering unconditionally.)

2. **Per-buffer spans cache** (`SpanRangeCache` on `Buffer`, used in
   `renderWindowLines`). The tree-sitter span query result is a pure function
   of (history revision, visible byte range), so the renderer reuses the
   previous frame's spans when both are unchanged — the common case for
   cursor movement inside a window and for the ~30 animation frames per scope
   change. Falls back to `visibleSpansFor` on any revision/range change;
   owned via `self.alloc`, freed on buffer close/replace (`clearSpanCache` at
   the two CLI file-open sites, `App.deinit`, `closeBufferAt`). Rendering is
   bit-identical: the spans are the same object the old path produced.

3. Removed the leftover `pb_*` profiling instrumentation.

## Residual: `scopeAt` ~5.5 ms at the file bottom (NOT fixed — syntax.zig's area)

`G k x20` now measures ~6.5 ms/key on an idle box: ~5.5 ms `scopeAt` (the
root child scan, aggravated by the bottom-of-file cursor) + ~0.9 ms everything
else. The scope cache cannot soundly absorb cursor MOVES (the deepest block
changes as the cursor enters/leaves nested blocks; the e2e
"rainbow brackets, indent guides and scope highlight" test asserts the
nested-scope colors exactly), and `scopeAt` itself lives in `syntax.zig`.

Recommended fix for the syntax owner: replace the linear root-child scan in
`scopeAt` with a binary search over children (children are sorted by byte) or
a "cached last sibling index" walk, or a per-line → block precompute. That
alone would take `G k` from ~6.5 ms to ~1 ms.

## Verification

- `zig build test` — all pass.
- `zig build e2e` — 107-108/109 pass. The two failures that rotate
  (`relative CLI path: :w saves`, `git: … blame ghost`, `grep picker`) also
  fail on the pre-change commit `d40bbcc` under the same concurrent-load
  conditions (verified by rebuilding the pristine commit and re-running);
  they are timing-sensitive pty tests (5 s `Wait.until` timeouts) that flake
  when the four parallel agents build/bench concurrently. The scope-highlight
  visual test and every other assertion pass consistently.
- `zig fmt` — my hunks are format-clean (the only fmt delta is an unrelated
  region owned by another agent; left untouched).
- ReleaseFast build with `-Dstrip` clean.

## Files

- `src/main.zig` — the render-path changes above.
- `REPORT-b.md` — this report.
