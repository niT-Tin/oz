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
zig build e2e -Dtest-filter="navigator"
zig build e2e -Dtest-filter="golden"
```

Current counts at the M3a implementation commit: **466 unit tests** and
**165 e2e tests**. `tools/verify.sh` writes `.verify/unit.log`, `.verify/e2e.log`, and
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
| **Model/unit (L1)** | Pure logic: piece table, motions, keymaps, SSE/OpenAI config parsing, AI workspace layout/focus/thread model, navigator tab model, note store (paths/titles/sorting/creation), inline selection mapping/fences/diff/pending policy, M3a agent loop bounds/card formatting/metrics/chart cache key + transcript→request assembly | `src/**/*.zig` `test` blocks, aggregated by `src/tests.zig` |
| **Protocol fixtures** | SSE chunking, request JSON (incl. assistant tool-call turns and `role:"tool"` results), streamed `tool_calls` fragments/parallel calls/malformed protocol, config env parsing, AI client cancellation/error paths; mock LSP JSON-RPC | `src/ai/sse.zig`, `src/ai/openai.zig`, `src/ai/tools.zig`, `src/ai/client.zig`, `src/ai/config.zig`, mock LSP tests |
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
currently covers 3 widths × filetree {closed,open} × rail {closed,open}, AI
streaming at 120 (dock) and 80 (drawer), hints overlays, and the navigator's
Notes/Agents tabs. A notes scenario gets a fresh temp `OZ_NOTES_DIR` with one
fixture note; the navigator box is located without its title text (hint labels
intentionally cover the tab words).

Scenario tags: `@layout @ai @filetree @stream @hints @navigator @notes
@inline @tools @80col @100col @120col @drawer @docked`. A new feature adds
its tag here and to at least one scenario.

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

### Notes test seam (`OZ_NOTES_DIR`)

Notes live in a global data directory, so tests must never touch the real
`$HOME`. `OZ_NOTES_DIR` is the first path source in production too
(`OZ_NOTES_DIR` > `$XDG_DATA_HOME/oz/notes` > `$HOME/.local/share/oz/notes`);
every navigator/notes e2e points it at a fresh `/tmp/oz_notes_*` directory
that is deleted afterwards. The error-path test uses
`OZ_NOTES_DIR=/dev/null/notes` to prove the Notes tab reports a clear error
and the editor stays usable.

### M3a agent-tool fixtures and e2e

`OZ_AI_MOCK_DIR` gained per-request fixtures for the automatic tool loop: the
nth request writes `request.json` (latest) plus `request-<n>.json`, and replays
`stream-<n>.sse` when present (falling back to `stream.sse` for the one-shot M1
tests). `error-<n>.txt` likewise falls back to `error.txt`. Existing text-only
tests are unchanged.

The M3a pty tests (`test/e2e.zig`, filter `tools:`) cover:

- a real `read_file` through two mock rounds: card running→ok, result excerpt,
  follow-up `request-2.json` with assistant `tool_calls` + `role:"tool"` +
  `tool_call_id`, Tools tab `calls 1`/`ok 1`/avg/max and a braille chart;
- parallel `read_file` + `grep` calls in one delta: both cards, both
  `tool_call_id`s in the follow-up, `2 calls`, chart;
- a missing file: real `error:` card and `ok 0 · err 1`, while the follow-up
  final text still arrives;
- `edit_file`: `approval required (M3b)`, the file bytes on disk are unchanged,
  the tool result says "not executed", no latency samples/chart;
- four tool rounds: execution stops, the transcript note names the bound, the
  fifth request is the final **no-tools** request (no `tools`/`tool_choice`),
  and no sixth request exists; Tools tab `calls 4`;
- a nine-call single batch: only the first eight execute, the ninth is a real
  `unsupported` tool result (`tool call limit (8) reached; not executed`),
  the follow-up is the final no-tools request, and Tools tab shows
  `calls 9` / `ok 8 · err 0 · unsup 1`;
- Ctrl+c during the follow-up stream: `cancelled` + frozen transcript, no
  `request-3.json`, and a second thread's Tools tab is still
  `no tool calls yet` (no cross-thread cards/metrics);
- 80x24 drawer: cards/chart fit with no horizontal overflow, and a drawn hint
  label on the card toggles the expanded result (only the second fixture line
  becomes visible);
- a valid-JSON tool-call entry missing `index`: the client surfaces a typed
  `tool call protocol` chat error, no card executes and no follow-up request
  is written.

The unit tests pin the bounded loop admission (`planBatch`), limit notes,
card status/argument/excerpt formatting, metrics average/max/ring/revision,
chart cache-key invalidation, `assistant tool_calls`/tool-result wire JSON, and
the transcript message order used by the follow-up request.

Known gaps at M3a (intentional, documented in DESIGN §20.8): metrics are
session/per-thread only (no cross-session persistence, no p95); calls
cancelled before their worker result is applied are not counted; writes and
approval buttons are M3b; tool-card expansion is hint-only (no mouse/card
cursor); the chart legend lists tool names but has no per-series average
annotation. The `stream-<n>.sse` seam is test-only and never used against a
real provider.

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
| Keyboard hints (labels, status, target actions, Esc) | L1 pure model (`src/app/hints.zig`) + L3 `hints:` tests + `@hints` matrix scenarios |
| Navigator tabs, notes list/create/save/reopen, agents attach | L1 (`src/app/navigator.zig`, `src/app/note_store.zig`) + L3 `navigator:` tests + `@navigator`/`@notes` matrix scenarios |
| Notes path fallback/error handling | L1 resolution/creation tests + L3 unavailable-dir e2e (`OZ_NOTES_DIR=/dev/null/notes`) |
| Inline assistant (selection→prompt→stream→Changes diff→Approve/Reject, stale, cancel, 80-col, hints) | L1 `src/app/inline.zig` + L3 `inline:` tests + `@inline` scenario |
| Mock LSP protocol | L4 mock server e2e |
| Deterministic build/test run | `tools/verify.sh` + CI |

Known gaps / deliberate limitations:

- No mutation testing and no fault-injection harness (e.g. allocation failure,
  signal injection); cancellation/error paths are covered by unit/mock tests
  but not by systematic fault injection.
- The browser does not apply: oz is a terminal application.
- Cursor position observability is not available (see above).
- Goldens cover two AI workspace frames by design, not every screen/theme.
- There is intentionally no hint-overlay golden: labels cover the target text and
  the target count depends on the repository-root filetree entries, so a full-frame
  golden would be dominated by volatile rows. The dedicated `hints:` e2e tests
  read labels back from the drawn cells and assert status/border/overflow instead.
- The file-tree L3 test navigates by key count and is sensitive to new
  top-level repository entries; adding a visible root directory can shift it.
  Keep this in mind when adding repo-root fixtures.
- Notes have no delete/rename and no directory watch: the list is refreshed
  only on Notes-tab entry, create, `:w` of a note, or `r`. Tests assert those
  explicit refresh points, not per-frame scans.
- Inline edit has one pending replacement and one live inline stream; there is
  no multi-file queue, word-level diff, hunk folding or soft-wrapped diff line.
  The diff is a line-level LCS capped at 400 lines per side (larger selections
  use an accurate all-removed/all-added fallback), computed once on completion.
  Approval is revision/path/range checked; after a workspace switch the pending
  diff has no matching buffer and must be rejected (safe failure, never apply).
  There is no auto-save: approve only edits the buffer.
- The navigator Agents tab is a view of the same session thread model; it is
  not persisted and is covered through that model's existing tests plus one
  attach/switch e2e, not a second state machine.
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
