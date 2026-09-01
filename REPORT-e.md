# perf/e-startup — memory, alloc-free search, incremental LSP didChange

Agent: worktree `.wt-e` (branch `perf/e-startup`). Owned paths: file load path,
`searchOnce`/`repeatSearch`, `curText`, `ensureLsp`, `markDirty`, LSP text-sync.

## 1. Memory: mmap-backed origin (2× → 1× transient, heap copy eliminated)

**Before:** `openInBuffer` and the CLI open path read the file into a heap
buffer (`alloc` + `readPositionalAll`) and `PieceTable.init` **duped it again**
into `origin` — the whole file existed twice in the heap during load (peak
~2× the file), and the steady-state copy was unreclaimable by the kernel.

**After:**
- `src/buffer/piece_table.zig` (additive only): new `initMapped` constructor
  plus an `origin_mapping` field; `deinit` munmaps when the origin is a
  mapping, otherwise frees as before. No existing function's logic changed.
- `src/main.zig` `loadPieceTable()`: read-only **PRIVATE mmap**
  (`std.posix.mmap(PROT.READ)`) of the file backs the origin piece — zero
  heap copy. Falls back to read+dupe for empty files and when mmap fails
  (special filesystems, quota). Both load sites (`openInBuffer` + CLI arg
  path) go through it.
- `saveFile` now writes to a sibling temp file and `rename`s over the path.
  This was REQUIRED by the mmap: truncating the mapped file in place
  SIGBUSes every later read of the mapping (the file no longer backs those
  pages). Temp+rename also makes saves atomic for other readers and keeps
  the old inode alive for the mapping. The original file's mode is
  preserved via `statFile` → `permissions`.

**Honest RSS (pty bench, `--iters 3`, medians):**

| metric | before | after |
|---|---|---|
| open huge.txt (50 MB) RSS | 58 464 KiB | **58 468 KiB** |
| open large.log (12 MB) RSS | 29 664 KiB | **18 540 KiB** |
| open huge.txt ready | 145.8 ms | 140.6 ms |
| open large.log ready | 129.5 ms | 127.7 ms |

For huge.txt the steady-state VmRSS is unchanged (~1.17× file + overhead):
the load path scans the whole document for the line index
(`ensureLineStarts`), touching every mapped page, so the mapping counts as
resident — we can't reach nvim's ~10 MB without lazy paging. The real wins:
(1) the file is no longer duplicated in the heap — the **transient load peak
drops from ~2× to ~1× the file**, and there is no 50 MB heap allocation at
all; (2) mapped file pages are **kernel-reclaimable** (can be evicted and
re-read under memory pressure, unlike a heap copy); (3) large.log RSS drops
29.6 MB → 18.5 MB because its read buffer was previously not returned to the
OS, while the mmap holds one reclaimable copy.

## 2. Search: zero-allocation piece-walking (12 MB copy eliminated)

**Before:** every `/` **and** every `n` ran `curText()` — a full-document
allocation + memcpy (12 MB on large.log) — then `indexOf`/`lastIndexOf` on
the copy.

**After:** `searchOnce` walks the piece table in document order with a new
`findInPieces(pt, start, end, query, want_last)`:
- `std.mem.indexOf` per piece on direct slices of `origin`/`add` (no copy);
- a pattern_len−1 byte window carried across piece boundaries (stack
  buffers: 255-byte tail + 510-byte concat) catches matches straddling two
  pieces; absolute offsets are tracked by walking document offsets;
- exact wrap-around semantics preserved: forward = first match starting in
  [cursor+1, len), else wrap to [0, cursor+1); backward = last match in
  [0, cursor), else last in [cursor+1, len);
- patterns longer than 256 bytes fall back to the (rare) full-text path.
`repeatSearch` (`n`/`N`) shares the same path.

Bench: `search /len n x10` on large.log — **before 0.4 ms/key → after
0.2 ms/key** (target ≤ 0.5 ms ✓), now zero allocation on the hot path.

## 3. LSP text sync: incremental didChange per keystroke

**Before:** `markDirty` called `curText()` (full copy) + `didChange(full
text)` on EVERY edit with an LSP server attached, and `ensureLsp` re-copied
the full text on every buffer switch.

**After (`src/lsp/client.zig` + `src/main.zig`):**
- `Client.didChange(range: ?types.Range, text)` — non-null range sends an
  incremental `contentChanges = [{range, text}]` (the per-keystroke path);
  null sends the full-document replacement (fallback for undo/redo,
  multi-cursor, paste, format…). `freeDidChangeParams` frees the nested
  range maps.
- `markDirtyRange(start_pos, end_pos, text)` sends the incremental change;
  the App computes LSP positions (line + **UTF-16** character) from byte
  offsets with `lspPositionAt` + a new `utf16Units` piece-walker (no
  document copy, carries split multi-byte sequences across piece
  boundaries). Threaded through every call site that knows its edit range:
  `insertText` (typing), `deleteBeforeCursor` (backspace), `deleteWordBefore`
  (Ctrl-w), `autoPairBackspace`, the jk-exit phantom-'j' removal,
  `applyOpRangeEx` (d/c), `applyEdit` (surround/comment/align), completion
  accept, `deleteToEol`, and normal-mode x/X/D/C/S. `markDirty()` remains as
  the full-text fallback for everything else.
- `ensureLsp` buffer-switch: the server now keeps documents open
  (`switchDocument` no longer didClose's; new `retarget` + `isDocOpen`), so
  switching back to a buffer whose content is unchanged since its last sync
  (`Buffer.lsp_synced_rev` vs `history.revision`) only retargets the client
  — **no didOpen, no full-text copy**. `lsp_synced_rev` is recorded after
  every successful didOpen/didChange.
- `src/lsp/mock_lsp.zig`: `recordDidChange` now applies incremental range
  edits to its recorded document (`applyChange` + `byteOffsetAt`, UTF-16
  aware; range-less changes still replace wholesale, so the existing
  full-text mock tests keep passing). A new unit test locks in
  insert/delete/replace range application. `jsonInt` tolerates the
  codebase's `.number_string` JSON numbers.

## Build & verification status

- `zig build test` — **PASS** (all unit tests, incl. new mock incremental-
  change test).
- `zig build e2e` — **108/109 pass**. All LSP tests pass (mock handshake +
  didOpen + didChange + diagnostics round-trip, clear_on_change repaint,
  jk-sync phantom removal, auto-suggest, completion user flows).
  The single failure, `lsp: … relative CLI path: :w saves without
  BadPathName`, is **pre-existing and environmental**: it fails identically
  on the untouched baseline (verified via `git stash`), because the test
  opens `../../../../tmp/…` assuming cwd = the main repo (4 levels up = `/`),
  but worktrees sit one level deeper, so the path resolves to the
  nonexistent `/home/tmp` (read-only here — not fixable from the repo).
- `zig build -Doptimize=ReleaseFast -Dstrip` — **PASS**.
- Benchmarks (`--iters 3`): startup tiny 123.7 ms (≤ 150 ✓); open large.log
  127.7 ms (unchanged ✓, RSS 29.6→18.5 MB); search 0.2 ms/key (≤ 0.5 ✓);
  typing on large.log 3.7 ms/key (unchanged ~3.8 — render path, another
  agent).

## Files changed

- `src/buffer/piece_table.zig` — `initMapped` + `origin_mapping` (additive)
- `src/main.zig` — mmap load path, temp+rename save, alloc-free search,
  `markDirtyRange`/incremental LSP sync, buffer-switch skip
- `src/lsp/client.zig` — range-aware `didChange`, open-doc tracking,
  keep-open `switchDocument` + `retarget`
- `src/lsp/mock_lsp.zig` — incremental change application + test

Note: `zig fmt` also re-indented two pre-existing misindented blocks in
main.zig (lazygit launch, blame-ghost render) — whitespace-only, semantics
unchanged.
