# perf/a-piece — incremental line index + piece-list reuse in PieceTable

## What changed (`src/buffer/piece_table.zig` only)

1. **Incremental `line_starts` maintenance** (root cause #1, the big win).
   `replace()` no longer invalidates the line cache. A new private
   `updateLineStarts(pos, del_len, bytes)` updates only the affected suffix of
   the cached `line_starts` array:
   - `li = lineOf(pos)` (binary search; unchanged prefix `starts[0..=li]`).
   - `le` = first line start **strictly after** `pos + del_len` — starts at
     exactly `pos + del_len` disappear (their `'\n'` was deleted); a start at
     `pos` itself survives. This is the "deleted span ending exactly on a line
     start" edge, handled uniformly by the strict `>` scan.
   - Old starts in `[li+1, le)` are dropped; `'\n'`s inside `bytes` produce new
     starts at absolute offsets `pos + k + 1` (a trailing `'\n'` yields the
     start at `pos + bytes.len`); starts `[le..]` shift by
     `delta = bytes.len - del_len` (i64 arithmetic).
   - One `ArrayList.replaceRange` call performs the splice; the suffix shift is
     a plain add loop over `starts[le..]` (≈135k × 4B ≈ tens of µs).
   - `line_starts_valid` stays `true` forever in the steady state. The full
     `ensureLineStarts` scan remains only for `init` (and as an OOM fallback:
     if the incremental update's allocation fails, the flag is cleared and the
     next line* query lazily rescans — correctness is preserved, never a
     silent wrong index).
   - Vim line semantics (trailing `'\n'` = extra empty line) are preserved; the
     500-step random-invariant test (`random edits preserve all invariants`)
     cross-checks every edit/compact against a mirror and passes.

2. **Piece-list churn eliminated** (root cause #2). `replace()` fills the
   persistent `scratch: std.ArrayList(Piece)` (capacity retained across
   edits) and commits with a `std.mem.swap` of the list pointers — the old
   list becomes the next scratch, so the common case performs **zero**
   allocations on the pieces path (the add-buffer append still allocates
   amortized O(1)). "Allocation failure leaves the table unchanged" still
   holds: the scratch build and the add append both happen before the swap.

3. **`byteAt` hint** (root cause #3). New `byte_hint_index`/`byte_hint_offset`
   fields: `byteAt` starts its scan at the last piece it resolved (correct
   because pieces are contiguous and ordered), making sequential access
   O(1) amortized. The hint is reset by `replace` and `compact` (interior
   mutation through `@constCast`, same established pattern as
   `ensureLineStarts`).

4. **`compact`** keeps its semantics (content unchanged ⇒ line cache valid)
   and now also resets the byteAt hint.

Public API (init/deinit/len/byteAt/copyRange/replace/lineCount/lineStart/
lineLen/lineOf/compact/iterator) is unchanged; only private fields and a
private helper were added. `zig fmt` clean.

## Numbers

| metric | before | after | target |
|---|---|---|---|
| insert typing on large.log (12MB, 135k lines) | 3.8 ms/key | **0.2 ms/key** | ≤ 0.5 ms/key ✓ |
| typing on medium.zig (manual, no bench row exists) | — | 0.58 ms/key | ≤ 3 ms/key ✓ |
| open huge.txt (50MB) ready / RSS | — | 145.8 ms / 58.5 MiB | no regression ✓ |
| open large.log (12MB) ready / RSS | — | 129.9 ms / 29.7 MiB | — |
| PieceTable.replace alone (12.6MB, 244k lines, micro-bench) | ~2–3 ms (full scan) | **0.024 ms/key** | — |

Official run: `python3 .bench/run_bench.py --iters 3 --out .bench/results/a-after.md`
(report saved there). A micro-benchmark of the table alone (built as a
throwaway test, not committed) shows `replace` at ~24 µs/key on a 12.6MB doc.

## Test status

- `zig build test` — **all pass** (incl. the random-invariant test).
- `zig build -Doptimize=ReleaseFast -Dstrip` — builds clean.
- `zig build e2e` — 104/109; the 5 failures are **pre-existing on this
  machine and identical on the unmodified baseline** (verified by testing the
  baseline commit): 4 file-tree tests (known flaky under concurrent builds —
  5 agents build in parallel in this repo) and `relative CLI path: :w saves`
  (its path math `../../../../tmp` assumes cwd = repo root, which fails from a
  worktree). A `grep picker` test flaked once under load, passed otherwise.

## Notes for the orchestrator

- **Shared-repo stash incident**: while verifying the baseline I ran
  `git stash push <path>` (no `--`), which git treats as a *message* and
  stashes everything. Concurrent stash operations from the `perf/c-motion`
  agent (same `.git`, 5 worktrees) interleaved: the c-motion stash (motion.zig
  changes) landed on this worktree and my piece_table stash was popped into
  `.wt-c`'s working tree. I reverted the foreign motion.zig changes here and
  recovered my change from the dangling stash commit; `.wt-c` may still carry
  my `src/buffer/piece_table.zig` in its working tree — the c-motion agent
  could accidentally commit it. Worth checking before merging perf/c-motion.
- **Residual per-key cost on large.log** (0.2 ms/key now, vs nvim 0.1) is
  **not** in the piece table (table alone: 0.024 ms/key). It lives in the
  editor's per-frame render path in `main.zig`, out of scope for this commit:
  - `renderWindowLines` counts rows below the cursor by walking **every line
    to EOF** each frame (~30–50 µs on large.log, would be a 244k-iteration
    walk; fix: bound the walk or only run it near EOF).
  - `visibleSpansFor` does a **full tree-sitter reparse of the whole document
    on every edit** for grammared files (medium.zig typing ≈ 0.58 ms/key is
    dominated by this). Suggested follow-up: incremental syntax edits or a
    debounce (the code already has an `incremental` branch for single edits).
