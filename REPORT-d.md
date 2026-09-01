# perf/d-syntax: viewport span cache + query/predicate speedup — report

Worktree: `.wt-d`, branch `perf/d-syntax`. Files changed: `src/syntax.zig` (owned),
`src/main.zig` (only `visibleSpansFor` + the `Buffer` cache fields + their frees),
this report.

## Profile findings (temporary std.time instrumentation, ReleaseSafe, 50 calls)

Baseline `spansInRange` over a 40-row (1161-byte) viewport of
`.bench/corpus/medium.zig` (root = a 911-child ERROR node, token-dense):

| phase | per call | note |
|---|---|---|
| query loop (nextCapture + style) | ~9.1 ms | **the whole cost** |
| ・ `bracketDepth` (getParent chains) | ~7.4 ms | 46 brackets × 25 steps × ~6 µs/step |
| ・ nextCapture / capname / predicates / append | ~0.03 ms total | predicates are NOT the bottleneck |
| dedup | ~0.04 ms | |
| collectErrorRanges | ~0.003 ms | |
| sort | ~0.016 ms | |
| **total spansInRange** | **~9.5 ms** | matches DESIGN.md §12.7's ~9 ms/24 rows |

Root causes, both in tree-sitter 0.26's C API:

1. **`ts_node_parent` re-descends from the tree root on every call**
   (`ts_node_child_with_descendant` scans the current level's children and
   descends through hidden nodes). Each call costs ~6 µs on this corpus, and
   `bracketDepth` did one call per tree level per bracket — 46 brackets × 25
   levels ≈ 7 ms/frame.
2. **`ts_node_child(i)` rescans children from index 0** (O(N²) to enumerate a
   node's children). Enumerating the 911-child root ERROR via `getChild(i)`
   costs ~1.5 ms per walk, so the DFS that fed the depth map was unusable
   with plain child iteration.

`#lua-match?` predicates (`matchPredicates`/`luaMatch`) measured ~11 µs/call —
NOT the bottleneck; the matcher was left untouched (and the e2e color
assertions pin the resulting styles).

## Changes

### src/syntax.zig

1. **`walkVisible` replaces `collectErrorRanges`** — one DFS over the visible
   subtree produces both the ERROR ranges (fallback lexer input) and a
   `node id → depth` map (rainbow brackets) in a single O(visible) pass.
   - Traversal uses a **tree cursor, not `getChild(i)`** (incremental sibling
     walking — no O(N²)); out-of-range subtrees are skipped whole.
   - ERROR subtrees are *descended into* for depths (brackets inside broken
     regions are still captured by the query) while only top-level ERROR
     ranges are recorded for the lexer.
2. **`depthOf(node, depths)`** — rainbow depth is now a hashmap lookup with a
   fallback to the old `getParent` walk (never triggers in practice; verified
   **59/59 bracket captures match the old walk exactly** on the corpus and
   62/62 on a real zig file, so zero visual change).
3. **Reusable `Query.Cursor`** stored on `Highlighter` (created on first use,
   destroyed in `deinit`) — `ts_query_cursor_new` mallocs every frame.
4. **Fixed a broken vendored binding without touching it**: `treez.Tree.Cursor`
   declares `TSTreeCursor` as 24 bytes, but the real struct is 28 bytes
   (`context[3]`; word 3 = `root_alias_symbol`). `ts_tree_cursor_new` writes
   28 bytes into the 24-byte Zig struct; the overflow garbage makes
   `getCurrentNode().getType()` return NULL at the root position → segfault in
   `std.mem.span` (repro: open a zig file, edit, render). `syntax.zig` now
   declares a correctly-sized local `TsTreeCursor` + the `ts_tree_cursor_*`
   externs and links against the same `libtree-sitter` symbols.

Result: `spansInRange` **9.48 ms → 0.29 ms** (~33×), all depths identical to
the old getParent semantics.

### src/main.zig (`visibleSpansFor` + `Buffer`)

5. **Per-buffer span cache**: `Buffer` gains `spans_cache` (owned copy,
   `self.alloc`) + `spans_cache_valid/start/end/rev`. `visibleSpansFor` skips
   the query+merge when nothing relevant changed (revision == last query AND
   same visible byte range). Every non-scrolling key / cursor move / repaint
   then costs **0 syntax work**. The copy is freed on replace and in both
   buffer-destruction sites (`App.deinit`, `closeBufferAt`). Keyed by
   `history.revision`, which every text mutation bumps (verified: all edits
   go through `history.record` / undo / redo; `:e` creates a fresh buffer).

## Verification

- `zig build test`: **281/281 pass** (Debug exit 0). The lone ReleaseSafe
  failure `buffer.ops.test.wordStartBefore … leaked 1 allocations` is
  pre-existing — reproduced at baseline via `git stash` (281/281 passed, same
  leak).
- `zig build e2e`: **104/109** — the 5 failures (`file tree` ×3, `filetree`,
  `relative CLI path`) fail **identically at baseline** in this environment
  (103/109, same 5 + 1; the mission's "file tree" flakiness caveat; the
  shared `.zig-cache` symlink lets sibling worktrees interfere). All syntax
  tests — `tree-sitter: zig keywords/comments/strings get syntax colors`,
  `colors stay correct after o + typing + jk exit`, `visual: rainbow
  brackets…`, `windows: both splits keep highlighting…` — **pass**.
- `zig build -Doptimize=ReleaseFast -Dstrip`: clean.

## Benchmark (medium.zig, 3 iters, medians; `d-before.md` vs `d-after.md`)

| script | before /key | after /key | before total | after total |
|---|---|---|---|---|
| gg j x20 (line down) | 6.0 ms | 5.7 ms | 182.8 ms | 176.5 ms |
| G k x20 (line up) | 25.5 | 21.6 | 387.2 | 310.0 |
| gg w x30 (word fwd) | 0.4 | **0.1** | 14.1 | **4.6** |
| gg e x30 (word end) | 0.4 | **0.1** | 13.4 | **4.7** |
| G b x30 (word back) | 25.5 | 21.6 | 596.0 | 474.1 |
| gg ctrl-f x10 (page down) | 0.5 | **0.1** | 6.1 | **2.1** |
| G ctrl-b x10 (page up) | 9.4 | 5.3 | 162.0 | 85.8 |
| gg {} x30 (paragraph) | 0.7 | 0.3 | 186.8 | 179.9 |
| gg f4 + ; x20 (char find) | 0.4 | **0.1** | 10.5 | **3.5** |

The non-scrolling keys (w/e/ctrl-f/f4) dropped 3–5× — the cache removing the
per-frame query. The residual `j`/`G` cost is the render path (gutter/cursorline
repaint), which is the sibling agent's area: the syntax share per frame is now
≤ **0.29 ms** (measured) and ~0 on cache hits, under the 0.5 ms target. The
end-to-end "≤ 2 ms/key for gg j x20" target needs the render-side work.

## Commit scope

`src/syntax.zig`, `src/main.zig` (only the `Buffer` cache fields +
`visibleSpansFor` + two cache frees), this report. The untracked `bench/` and
`.guard-marker-d` are pre-existing setup artifacts and were left untouched.
