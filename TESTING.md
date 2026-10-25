# Testing & verification

This document describes oz's test layers, the machine verification entry
point, and the policy for agents/humans changing UI, layout, or AI workspace
behavior. The goal is that a UI regression is a failing command with a raw
log, not "looks wrong on my terminal".

## Quick start

```sh
./tools/verify.sh               # authoritative local run: diff check + unit + e2e
zig build test                  # L1 unit + L2 render snapshots
zig build e2e                   # L3 pty end-to-end (Linux)
zig build test -Dtest-filter="property:"   # one group (compile-time filter)
zig build e2e -Dtest-filter="scenario matrix"
zig build e2e -Dtest-filter="golden"
```

`tools/verify.sh` writes `.verify/unit.log`, `.verify/e2e.log`, and
`.verify/verify.json` (schema version 1, git commit/dirty flag, exact command
strings, timestamps, exit codes, log SHA-256s, parsed pass/fail counts). It
runs every command even after a failure and exits non-zero if any command
fails. `.verify/` is git-ignored.

CI (`.github/workflows/ci.yml`) runs the same script on pull requests and on
pushes to `master`, uploads `.verify/` even on failure, and is authoritative.
`release.yml` remains tag-only and is not involved.

Zig test steps use `has_side_effects = true`, so `zig build test` and
`zig build e2e` always execute the freshly built test binary instead of
replaying a cached successful run.

## Test layers

| Layer | What it covers | Where |
|---|---|---|
| **Model/unit (L1)** | Pure logic: piece table, motions, keymaps, SSE/OpenAI config parsing, AI workspace layout/focus/thread model | `src/**/*.zig` `test` blocks, aggregated by `src/tests.zig` |
| **Protocol fixtures** | SSE chunking, request JSON, config env parsing, AI client cancellation/error paths; mock LSP JSON-RPC | `src/ai/sse.zig`, `src/ai/openai.zig`, `src/ai/config.zig`, `src/ai/client.zig`, mock LSP tests |
| **Semantic frames (L3)** | Real `oz` binary in a pty; ANSI stream reconstructed into a cell grid; assertions on regions, borders, text, overlap, overflow | `test/e2e.zig` + `test/frame.zig` |
| **Scenario matrix** | Data-driven pairwise matrix over terminal widths, filetree, and AI rail states; fresh pty per scenario; tags enforced | `test/e2e.zig` (`scenario_matrix`) |
| **Goldens** | Cell-exact text + fg/bg frames for representative AI workspace sizes | `test/golden/`, `test/golden.zig` |
| **Property sweeps** | Deterministic exhaustive invariants over widths/heights/focus transitions | `src/ai/workspace.zig` (`property:` tests) |

### Semantic frame helpers

`test/frame.zig` provides reusable assertions over the reconstructed grid:

- `expectCellBg` / `expectRegionBg` / `expectRegionFg` / `expectRegionPainted`
- `expectBorderBox` — validates corners and both vertical borders (optionally
  the border foreground), replacing copied popup-geometry checks
- `expectTextInRegion` — cell-boundary-aware text search inside a rectangle
- `expectNoOverlap` — panes/floats must not share a cell
- `expectNoHorizontalOverflow` — catches wide glyphs in the last usable
  column and painted cells past an explicit content width
- `boxRect` / `findBoxByTitle` — derive a region from the **drawn** box
  corners instead of hard-coding coordinates

Cursor position is intentionally not exposed: the ANSI parser consumes
CSI `H`/`f`/`G` as drawing writes and does not separate vaxis's final cursor
placement. Tests assert visible focus state instead (accent rail border,
status text, cursorline background). Do not add a cursor oracle based on the
current parser.

### Scenario matrix

Scenarios live in one `scenario_matrix` array. Each `Scenario` declares:

- `name`, `tags`, `rows`, `cols`
- setup (`plain` or `ai_mock`), `filetree`/`rail` state
- optional extra key `steps` and a `prompt` (send/stream)
- expected text/absent text and mock request-body substrings

The runner spawns a fresh pty per scenario, waits for `NORMAL`, drives the
keys, settles the stream, and applies the semantic assertions. The matrix
currently covers 3 widths × filetree {closed,open} × rail {closed,open} plus
AI streaming at 120 (dock) and 80 (drawer).

Every scenario must carry tags; `required_scenario_tags` is the declared
feature set. A test fails with `UncoveredScenarioTag` if a declared tag has
no scenario, and with `UndeclaredScenarioTag` if a scenario introduces a tag
that is not in the set. Add new layout/AI features by adding the tag and at
least one scenario.

### Goldens

Two focused frames are stored under `test/golden/`:

- `ai-dock-120x30.txt` — docked rail + editor
- `ai-drawer-80x24.txt` — narrow overlay drawer

Format is plain text: header/size, one text row per screen row, then
run-length-encoded packed-RGB `bg` and `fg` rows covering every cell
(`-` means the default/unpainted color). It is diffable in code review and
needs no image codec/OCR. The frame setup uses a fixed non-git temp cwd, a
fixed fixture file, a fresh `HOME`, a fixed theme, and the mock stream; there
are no timestamps or volatile paths in the frame.

Normal runs compare and fail with `error.GoldenMismatch`, printing the first
differing lines and writing:

- `.verify/golden/<name>.actual.txt` — the full actual frame
- `.verify/golden/<name>.diff.txt` — expected/actual differing lines

CI uploads `.verify/`, so these are available even on failure.

Goldens are **never** updated by a normal run. To update intentionally:

```sh
OZ_UPDATE_GOLDEN=1 zig build e2e -Dtest-filter="golden"
git diff -- test/golden/        # review EVERY changed cell/style run
```

The update prints the exact files written. A missing golden is an error, not
an automatic create.

### Property tests

`src/ai/workspace.zig` sweeps deterministic invariants (fast, no RNG):

- widths 40..200: dock/editor widths partition `cols`; drawer width ≤ cols;
  breakpoint monotonicity; exact 90/110 breakpoints
- heights 0..200 and every workbox tab: metrics stay inside the rail, thread
  rows are bounded, prompt/body rows never overflow
- extreme widths/heights (including `maxInt(u32)`) do not panic or overflow
- every focus-transition combination lands in a valid state (closed rail is
  always editor-focused)

## Agent / verifier policy

1. **No "I ran it" without evidence.** Report exact commands, exit codes,
   and pass/fail counts. On this repo, the raw evidence is
   `.verify/verify.json` plus `.verify/*.log`; CI is authoritative.
2. **Fail before, pass after.** For a fix, first reproduce the failure
   (or show the current failing assertion); then show the same command
   passing after the change.
3. **Do not edit tests or goldens to hide a failure.** Existing expectations
   are evidence. If a product requirement changed, update the test and the
   golden explicitly, call it out in the commit message, and keep the
   assertion at least as strong. Never delete an assertion or narrow it to
   make CI green.
4. **No silent golden updates.** Only `OZ_UPDATE_GOLDEN=1`, then review the
   diff. A commit containing golden changes must explain them.
5. **Protected paths.** Treat `test/**`, `test/golden/**`, and
   `tools/verify.sh` as review-sensitive. Test-only helper modules
   (`test/frame.zig`, `test/golden.zig`) may grow, but assertions and golden
   content need justification.
6. **Clean-worktree verification.** `verify.json.git.dirty` is true when
   tracked files differ from `HEAD` (untracked files are not counted). Commit
   the change under test, then run `tools/verify.sh`; a dirty run is useful
   during development but is not a release/CI claim.
7. **Version, not environment.** If a failure is environment-dependent
   (missing tree-sitter, no `/dev/ptmx`), `tools/verify.sh` fails; do not
   accept a partial run as success. Run `./.scripts/bootstrap-deps.sh` once.

## Current coverage matrix

| Area | Covered by |
|---|---|
| Editor modes/motions/undo/registers/splits | L1 + existing L3 tests |
| File tree, picker, dashboard, popups | L3 `assertPopupBox` + semantic frame helpers |
| AI layout widths (80/100/120), rail/drawer, filetree combinations | scenario matrix |
| AI chat send/stream at 120 (dock) and 80 (drawer) | scenario matrix + goldens |
| AI thread isolation/cancel/error, selection context | existing deep L3 tests |
| Layout arithmetic / focus state | property sweeps |
| AI/frame cell colors and borders | goldens + semantic assertions |
| Mock LSP protocol | L4 mock server e2e |
| Deterministic build/test run | `tools/verify.sh` + CI |

Known gaps / deliberate limitations:

- No mutation testing and no fault-injection harness (e.g. allocation failure,
  signal injection); cancellation/error paths are covered by unit/mock tests
  but not by systematic fault injection.
- The browser does not apply: oz is a terminal application.
- Cursor position observability is not available (see above).
- Goldens cover two AI workspace frames by design, not every screen/theme.
- The file-tree L3 test navigates by key count and is sensitive to new
  top-level repository entries; adding a visible root directory can shift it.
  Keep this in mind when adding repo-root fixtures.
- CI caches the Zig tarball and the small global Zig cache only; the ~1 GB
  `.vendor/tree-sitter` sources and multi-GB local compile cache are fetched/
  rebuilt each run to keep cache keys small and deterministic.
- `zig build`/`zig build test` require the vendored tree-sitter sources; run
  `./.scripts/bootstrap-deps.sh` after a fresh clone.

## Troubleshooting

- `.verify/unit.log` / `.verify/e2e.log` hold complete stdout+stderr.
- `verify.json.commands[].exit_code` records each command independently.
- `verify.json.tests.unit/e2e` shows parsed pass counts; `null` means the
  summary line was not parseable (inspect the log).
- A golden mismatch is not "flaky" unless two runs produce different actual
  frames; compare `.verify/golden/*.actual.txt` across runs before updating.
- Scenario failures print the scenario name and tags, then dump the grid.
