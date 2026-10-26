# oz

English | [中文](README.zh-CN.md)

A terminal text editor written in Zig.

## Features

**Editing (vim-style)**

- Six modes: Normal / Insert / Visual / Visual Line / Visual Block / Command
- Full motions with counts: hjkl, w/e/b/ge, ^/0/$, gg/G, {/}, %, f/F/t/T, Ctrl-u/d/f/b
- Text objects, surround, comments, alignment, EasyMotion (s / `<leader>f`), multi-cursor (Ctrl+n)
- Undo/redo (grouped + branch semantics), register semantics (linewise/charwise yank & put) with system clipboard interop (OSC52 + pbcopy/wl-copy/xclip/xsel, nvim `clipboard=unnamedplus` style)
- Keyboard macros: `q{reg}` records (q stops), `@{reg}` replays with count support (`3@a`, `@@`); in Visual mode `@` runs the macro once per selected line (`:'<,'>normal!` semantics); `recording @x` status indicator
- Splits (:sp/:vs + Ctrl-w family), buffer tab bar, relative line numbers, code folding

**Syntax & UI**

- tree-sitter syntax highlighting (multiple bundled grammars), rainbow brackets, indent guides + scope highlight animation
- Inline markdown rendering: headings/bold/italic/links/code, fence code highlighted in its own language, markup concealed off the cursor line, checkbox icons, heading/code-block background bands
- Multiple themes (`<leader>sp` theme picker with live preview; the choice persists automatically — no config or env var needed): kanagawa-wave, kanagawa-dragon, catppuccin (latte / frappe / macchiato / mocha), tokyonight (night / storm / moon), everforest, onedark, melange, doom-one, sonokai-shusia, flexoki-dark, flexoki-light
- Soft-wrap: lines wider than the window wrap onto continuation rows (grapheme/CJK-width aware)
- Large-file degradation: highlighting turns off above 100 KB to stay smooth

![Syntax highlighting, indent guides, inlay hints](docs/screenshots/editor.png)

**LSP**

- Async attach (never blocks startup); works with zls and other common servers (auto-detects mason install paths)
- Hover (K), goto definition/declaration/references/implementation (gd/gD/gr/gI), signature help (gs)
- Diagnostics gutter marks + `]d`/`[d` jumps + diagnostics list (`<leader>sd`)
- Auto-completion menu + ghost text (`<C-n>`/trigger characters), inlay hints (`<leader>ti`). Esc leaves Insert and closes the menu in one press; `<C-e>` only hides the menu and keeps Insert.
- Rename (`<leader>rn`), format (`<leader>lf`), document outline (`<leader>o`)

![LSP completion menu](docs/screenshots/completion.png)

**Navigation & search**

- Fuzzy pickers: files (`<leader>sf`), grep (`<leader>st`), buffers (`<leader>sb`), recent files (`<leader>sr`), keymaps (`<leader>sk`)
- **Navigator** (`<leader>e` toggle, `<leader>E` locate current file): the left sidebar with three tabs — **Files** (the existing lazy file tree, rooted at the workspace's project directory), **Notes** and **Agents**. Every tab and every list row is a `<leader>j` hint target and a mouse target; while the navigator owns the keyboard, `Tab`/`Shift-Tab` cycle tabs and `1`/`2`/`3` jump directly (`h`/`l` keep the file tree's fold/parent behavior).
  - **Full mode (≥90 cols)** — a 30-cell panel with a branded top border (`OZ` accent + bold) and a `workspace / branch` line using the real workspace slot and git branch when available, then icons + `Files N │ Notes N │ Agents N` badges. Counts are real cached values: visible tree rows, the loaded note list (no badge until the lazy list is loaded), and session threads. Active tabs use the shared `bg_sel` + accent underline treatment.
  - **Compact mode (<90 cols)** — a 7-cell icon rail (`OZ` on top, then folder/notes/agents two-row buttons) and the editor keeps the rest of the width (text starts at column 8, never under the rail). Selecting an icon by click, hint, or `1`/`2`/`3`/Tab while the navigator owns keys opens a 30-cell **peek** with the real tab content. `Esc` or a click outside closes the peek and returns the editor; opening a file/note/agent closes it too. The peek and the Agent drawer are mutually exclusive (opening one closes the other). `Ctrl-w h` enters the navigator (peek opens in compact mode); `Ctrl-w l/j/k` returns to the editor.
- **Notes** (**Notes** tab): real markdown buffers stored globally under `$OZ_NOTES_DIR`, else `$XDG_DATA_HOME/oz/notes`, else `$HOME/.local/share/oz/notes` (the directory is created lazily, never at startup). `j`/`k` select · Enter opens the note as a normal buffer (`:w` saves it) · `n` creates the smallest free `note-N.md` containing `# Untitled note` (existing files are never overwritten) · `r` refreshes. Rows show the first markdown heading (else the filename), a body snippet and relative age, newest first. Notes are project-independent: opening one never re-roots the workspace file tree/picker. Delete/rename are intentionally not implemented yet.
- **Agents** (**Agents** tab): a compact navigator view of the same real session threads (grouped under the current workspace) — `j`/`k` select · Enter attaches the thread in the rail/workbox · `n` creates a new thread. This is a view, not a second thread model.
- In-buffer search (`/`, `?`, n/N)

![Fuzzy file picker (leader sf)](docs/screenshots/picker.png)

![Grep search (leader st, with live preview)](docs/screenshots/grep.png)

![File tree](docs/screenshots/filetree.png)

**Workspaces (Doom-Emacs style)**

- Swap-on-switch workspaces: `SPC TAB n` new / `.` pick / `r` rename / `d` delete / `x` clear session / `[` `]` prev · next
- Independent buffers, window layout and file tree per workspace; opening a file already open in another workspace is refused (no double-edit)
- The file tree and fuzzy file picker follow each workspace's project root — the opened file's nearest `.git` directory, else its own directory
- Status bar shows the current workspace name; a snacks-style dashboard greets a fresh workspace

![Workspace picker (SPC TAB .)](docs/screenshots/workspace.png)

![Startup dashboard](docs/screenshots/dashboard.png)

**Git**

- Gutter diff marks, `]c`/`[c` hunk jumps, `<leader>hs`/`<leader>hr` stage/reset, `<leader>hp` hunk preview
- Current-line blame ghost text (shows 1s after the cursor settles, `<leader>tb` toggles), `<leader>lg` floating lazygit
- Branch name in the status bar

![Gutter diff marks + current-line blame](docs/screenshots/git.png)

**Terminal**

- Embedded terminal (Linux / macOS): `Alt+r` floating / `Alt+w` bottom / `Alt+e` right; Esc in the terminal returns to Normal mode

![Embedded terminal (Alt+r floating layout)](docs/screenshots/terminal.png)

**AI workspace (M2a)**

- `<leader>a` opens the right-hand **Agent Rail + Workbox** and focuses its prompt; from the editor or thread list it closes the rail and returns focus to the editor. A docked rail is non-modal: editing continues beside it.
- Width behavior: **≥110 cols** reserves a 38-cell docked rail; **90–109** reserves 34; **<90** uses an overlay drawer (`min(34, width-8)`) while the editor keeps its full width underneath. The rail stops above the status bar and never draws over the editor's reserved area. In drawer mode Esc closes the drawer; there is no fake scrim, diff or telemetry.
- **Threads** are session-level and listed under the current workspace. `j`/`k` select, Enter attaches, `n` (or `+`) creates a new thread and focuses its prompt, Tab from the prompt returns to the thread list. One stream runs at a time: switching away from a streaming thread cancels it (status `cancelled`, transcript frozen); switching back shows that frozen transcript. Each thread has its own request history and client, so deltas can never land in another thread. Threads survive rail close and workspace switches, but are not persisted to disk.
- **Workbox tabs**: Chat (the M1 transcript, streaming, cancellation, errors, Markdown, tool cards and prompt), Changes (inline-edit **and staged agent-edit** review: a real unified-style diff with explicit Approve/Reject; multi-file patches add a selectable per-file list/window on top of the active diff; `no pending changes` when empty), Tools (real per-tool call/decision metrics, avg/max plus a nearest-rank p95 of the last ≤32 real samples, and a latency chart; `no tool calls yet` when empty), Terminal (the **approved agent terminal tool**: staged command, explicit Allow/Deny, real bounded output; the existing editor terminal is still `Alt+r` and stays separate). Empty states are real — no fabricated diffs, counts or charts.
- **Inline assistant (`<leader>i`)**: select lines in visual/visual-line mode, press `<leader>i`, type an instruction in the compact `inline edit` float, and press Enter. The request streams through its **own** OpenAI-compatible client (it never appends to a chat thread); on completion the rail opens on **Changes**, the badge becomes `changes 1`, and the diff shows the removed selection lines and the streamed replacement. Nothing is written until you approve:
  - Changes: `a`/Enter approve · `r`/`d` reject · `j`/`k` scroll a long diff; both buttons are `<leader>j` hint targets.
  - Prompt: Enter generate · Esc/Ctrl+c cancel · Ctrl+w delete the last word; UTF-8 typing and bracketed paste are supported while the selection stays visible.
  - Approve applies the replacement as **one undo group** (`u` restores the original), marks the buffer dirty and returns focus to the editor. Reject discards the pending diff and leaves the buffer byte-identical. A buffer edit after generation is refused as `stale selection` — the pending diff stays visible until you reject it.
  - Only one inline replacement can be pending (or streaming); a second `<leader>i` asks you to reject the pending change first. No tools, no automatic file writes, no silent edits.
- **Agent tools (M3a read-only + M3b1/M3b2 staged edits + M3b3 approved terminal)**: chat requests advertise `read_file`, `list_directory`, `grep`, `edit_file`, `apply_patch` and `terminal` (`tools` + `tool_choice:"auto"`). When a response finishes with tool calls, each call gets a compact card in the transcript and the safe read-only calls run in a **background worker** against the thread's workspace root — the UI never blocks on a file read or grep. Cards show name, argument summary, real status (`running`/`ok`/`error`), duration and a bounded result excerpt; a failed or blocked call never pretends to succeed. Results are appended as `role:"tool"` messages and one follow-up request continues automatically (at most **4 tool rounds / 8 executed calls per turn**; after a bound the final request carries no tools so a text answer can still arrive). The executor only runs read-only tools; `edit_file` and `apply_patch` go through the staged-diff approval path below, `terminal` goes through its own explicit per-command approval path below, and unknown tools show `unsupported` and are never executed. Ctrl+c or switching threads cancels the stream **and** stops further loop/tool execution; stale results are discarded per thread. Chat cards are `<leader>j` targets: activating the label expands/collapses the real result. The **Tools** tab aggregates per-thread calls/ok/error/approval/denied/unsupported, average/max latency and the recent samples as a braille line chart (sparkline fallback), e.g. `read_file · calls 1 · avg 3ms · p95 8ms · max 12ms`. **p95** is the integer nearest-rank percentile (`ceil(0.95*n)-1`, clamped) of that tool's last ≤32 executed calls — avg/max cover all calls, p95 only that recent window; zero samples show `no latency samples` rather than a fabricated 0ms. The tab header's p95 pools each tool's recent window (≤32 per tool) with the same rule. Narrow rails/drawers drop `max`, then `avg`, so `p95` still fits at 80/100/120 columns without overflow. The chart is cached until metrics or layout change. Metrics are recorded only for real calls — no mock/baseline data.
- **Staged agent edits (M3b1/M3b2)**: `edit_file` and single-file `apply_patch` tool calls **never write to disk**. oz reads the target read-only (the already-open buffer text, otherwise the file, ≤256 KiB), validates the change and stages a bounded diff in **Changes** with badge `changes 1`; the Chat card becomes `approval required` and the `role:"tool"` result says “staged; not applied”. Approve (`a`/Enter or its `<leader>j` hint) opens/activates the buffer, re-checks the full text and buffer revision, applies the change as **one undo group** (dirty; `u` restores it; `:w` remains the separate user write) and flips the card to `approved` with real counts. Reject discards it (`rejected`, metrics `denied`) without touching the buffer, history or dirty flag. A changed/missing buffer or file refuses as `stale edit`/`stale patch` and keeps the diff reviewable. Only one review (agent or inline) exists at a time; a second write answers `resolve the pending edit first`. The pending edit is thread-scoped: switching threads hides the badge/review but preserves it, and applying requires returning to that thread. Unknown tools remain unexecuted (`unsupported`); `terminal` has the separate approval path below.
  `apply_patch` now accepts **1–8 modified files** as back-to-back `diff --git`/`---`/`+++`/`@@` sections (git-style headers and `index` optional; multiple hunks, omitted hunk counts and `\ No newline at end of file` supported). Every file is applied to its old full text and **the whole set is validated before the review is shown**; one stale/unsafe/malformed file rejects the set with a per-file reason and writes nothing. The Chat card shows `K files · -N +M` plus a bounded file list; **Changes** lists every file (`j`/`k` select, `J`/`K` scroll the active diff, `a`/Enter approve, `r`/`d` reject; every file row is also a hint/mouse target). **Multi-file approve is an explicit whole-set disk write**: all targets are re-resolved and re-verified, new bytes are staged as sibling temp files (modes preserved), then renamed; a phase-1 failure changes no target, and a phase-2 rename failure restores already-renamed files from their old text and reports any rollback failure truthfully. It is not a filesystem-wide atomic commit. Open buffers are refreshed in place (clean, no stale buffer; LSP resynced) and **one `u` restores every file in the set, including files that were not open**, with `Ctrl+r` redo (only the most recent set is retained; if a file changed after apply, undo refuses rather than partially restoring). Reject and every validation failure write nothing. Add/delete (`/dev/null`), binary, rename/copy, mode changes, duplicate/unsafe paths, malformed hunks/counts, context/removal mismatches, out-of-range hunks, missing files, >8 files, >256 hunks total (128/file), >16K hunk lines total (8K/file), patches/old/result over 256 KiB per file or 2 MiB per set are typed errors with no stage and no partial apply.
- **Approved terminal tool (M3b3)**: `terminal` lets the model request **one** non-interactive shell command, but it **never runs automatically**. Each command is staged first (Chat card `approval required`, full escaped command + timeout); the rail opens the **Terminal** tab with `[a] allow  [r] deny` (keyboard, `<leader>j` hint or mouse). Deny spawns nothing and sends a truthful `denied ... not executed` tool result. Allow spawns a background `/bin/sh -c <command>` with cwd = the thread's captured workspace root, empty stdin, and a filtered environment (`PATH/HOME/TERM/LANG/LC_ALL/TMPDIR`); it is **not sandboxed and not network-restricted** — it runs with your permissions. Combined stdout+stderr is capped at **64 KiB**, runtime at **100–10000 ms** (default 5000), and timeout/cancel SIGKILLs the whole process group. On exit the card/result carry the real exit code, duration and bounded output excerpt, and the paused model follow-up resumes with that result. At most one terminal command is pending/running per session; a pending approval survives a thread switch (hidden, no process), while leaving the thread or pressing Ctrl+c kills a running command and records `cancelled` with no follow-up. The model transcript sees the final result, not the intermediate approval. This is deliberately **not a shell UI**: no PTY, no stdin forwarding, no scrollback; the editor terminal (`Alt+r`) is unchanged. Terminal and file reviews use separate surfaces (Terminal vs Changes) and can coexist.
- Keys:
  - Prompt: Enter send · Ctrl+c cancel (stops an active tool loop too) · Ctrl+n new thread · Tab → thread list · Ctrl+j/k scroll one line · PageUp/PageDown scroll a page · Esc → editor (drawer: closes). While a terminal command awaits approval, sending a new prompt is refused with `resolve the pending terminal command first`.
  - Thread list / workbox: `j`/`k` select · Enter attach · `n`/`+` new thread · `c`/`d`/`t`/`r` Chat/Changes/Tools/Terminal · Tab/Shift+Tab cycle tabs · `q`/Esc → editor. With a pending inline **or single-file agent** edit on Changes, `a`/Enter approve, `r`/`d` reject and `j`/`k` scroll the diff; a **multi-file** patch review uses `j`/`k` to select the active file, `J`/`K` to scroll its diff, and the same `a`/Enter + `r`/`d` decisions. With a staged terminal command on Terminal, `a`/Enter allow, `r`/`d` deny and `j`/`k` scroll. With no visible pending those keys keep their normal tab-switch meaning.
  - `<Ctrl-w> a` re-enters the rail at the thread list from the editor (also opens a closed rail)
- **Keyboard hints (M2.6a)**: `<leader>j` overlays qutebrowser-style labels (`asdfghjkl`, fixed length 1–3) on every visible target — filetree rows, buffer tabs, agent threads, navigator tabs, note rows, Workbox tabs, the `+` new-thread button, the prompt row and the Changes Approve/Reject buttons. Type a full label to run the target's normal action (including Allow/Deny on staged edits and terminal commands), Backspace edits the prefix, Esc cancels with no side effects. A `HINTS · N targets · Esc cancel` indicator appears on the status bar; with nothing visible it reads `HINTS · no targets`. Plain `f` stays vim find-char — hints never take it. Works from the editor, the dashboard, the file tree and the AI thread list (not while typing in the prompt).
- **Mouse (`feat/mouse`)**: vaxis cell-coordinate mouse reporting is enabled at startup and reset on exit (including error paths). Left-click focuses split panes and places the cursor from the clicked line/column (relative-number gutter, `view_top`, soft wrap and inlay hints considered), and clicks buffer tabs and their `×`, navigator tabs/rows (files/notes/agents), AI thread rows, workbox tabs, the prompt and `+`, tool cards, and the Changes/Terminal Approve·Allow/Reject·Deny buttons. Clicks run the **same** App methods as the keyboard/hints, so approval/stale/dirty safety is unchanged; the last buffer's `×` is never registered, empty areas are no-ops, and a click finalizes an active insert session first (text kept). Wheel scrolls the editor (3 lines/notch, cursor column preserved), filetree/notes/agents selection and the Chat/Changes transcript/diff — always clamped; over the focused embedded terminal the wheel is left alone (clicking the terminal focuses it, clicking elsewhere returns to the editor). Plain drag belongs to mouse reporting — hold **Shift** while dragging to select/copy text in your terminal (terminal-dependent). v1 has no drag/resize, middle/right button, or terminal mouse forwarding; heavily wrapped lines and grapheme clusters map approximately (DESIGN §21).

- Streaming OpenAI-compatible completions (`POST {base_url}/chat/completions`, SSE); Markdown + fenced code rendering, auto-scroll
- Editor context is attached automatically: current file path, visual selection with its 1-based line range, otherwise the cursor line ± a small window (capped at 8 KB)
- Configuration via env (read when the rail opens):

  | Variable | Default | Meaning |
  |---|---|---|
  | `OZ_AI_BASE_URL` | `http://127.0.0.1:11434/v1` | OpenAI-compatible base URL (Ollama / LM Studio / DeepSeek / gateways) |
  | `OZ_AI_MODEL` | `qwen2.5-coder:7b` | Model name |
  | `OZ_AI_API_KEY` | unset | Optional `Authorization: Bearer …`; never logged or persisted |
  | `OZ_AI_SYSTEM` | built-in | Optional system-prompt override |

  Example: `OZ_AI_BASE_URL=https://api.deepseek.com/v1 OZ_AI_MODEL=deepseek-chat OZ_AI_API_KEY=sk-… oz`.

Notes use the same environment-config style: `OZ_NOTES_DIR=/path/to/notes oz` redirects the global note store; leave it unset to use `$XDG_DATA_HOME/oz/notes` or `$HOME/.local/share/oz/notes`.

## Build & run

Requires Zig 0.17.0:

```sh
./.scripts/bootstrap-deps.sh                # fetch tree-sitter (~50MB download, ~1GB on disk; once)
zig build                                    # dev build
zig build -Doptimize=ReleaseFast -Dstrip     # release build (daily driver)
zig build test                               # unit tests
zig build e2e                                # pty end-to-end tests (Linux only for now)
```

Run: `oz [file[:line]]`

For the full verification entry point (CI uses it), semantic layout/AI
scenarios, cell-level golden frames, and the agent/verifier policy, see
**[TESTING.md](TESTING.md)**. In short:

```sh
./tools/verify.sh                            # diff check + unit + e2e, writes .verify/verify.json
zig build e2e -Dtest-filter="scenario matrix"
OZ_UPDATE_GOLDEN=1 zig build e2e -Dtest-filter="golden"   # explicit golden update
```

## Performance

Methodology: pty-driven with screen reconstruction, same machine (Apple Silicon, macOS), same files, median of 3 runs.

| Scenario | oz | nvim --clean |
|---|---|---|
| Startup (small file) | 66 ms | 115 ms |
| Startup (5 MB / 100k lines) | 65 ms | 118 ms |
| Startup (.zig, zls installed) | 52 ms | 117 ms |
| G to end of file (100k lines) | 54 ms | 65 ms |
| 100× Ctrl-F paging | 54 ms | 100 ms |
| 500× j cursor moves | 53 ms | 100 ms |
| Type 100 chars | 64 ms | 66 ms |
| Type 30 chars at EOF of a 100k-line file | 71 ms | 56 ms |
| Full-text search (100k lines) | 58 ms | 66 ms |
| Type 60 chars with LSP attached | 60 ms | 56 ms |

On par with or faster than nvim in every scenario. Key design choices: mmap-backed lazy file loading, PieceTable with incremental line index, incremental tree-sitter parsing, async LSP handshake + writer thread + incremental sync, atomic saves (temp file + rename).

## Download

Prebuilt binaries for Linux (x86_64/arm64) and macOS (x86_64/arm64) are
attached to each [GitHub Release](https://github.com/niT-Tin/oz/releases) —
download, extract and run, no Zig needed. To build from source see
"Build & Run" above.

## License

[MIT](LICENSE) © niT-Tin

## Maintenance

A personal project maintained in spare time — please set expectations
accordingly:

- Features are driven by my own daily use; bug reports with repro steps are
  very welcome;
- Pull requests are reviewed and merged, but on my own schedule;
- Keybindings / APIs may still change during 0.x;
- A star is the nicest encouragement.
