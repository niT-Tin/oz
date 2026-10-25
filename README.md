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
- Auto-completion menu + ghost text (`<C-n>`/trigger characters), inlay hints (`<leader>ti`)
- Rename (`<leader>rn`), format (`<leader>lf`), document outline (`<leader>o`)

![LSP completion menu](docs/screenshots/completion.png)

**Navigation & search**

- Fuzzy pickers: files (`<leader>sf`), grep (`<leader>st`), buffers (`<leader>sb`), recent files (`<leader>sr`), keymaps (`<leader>sk`)
- **Navigator** (`<leader>e` toggle, `<leader>E` locate current file): the 30-cell left sidebar with three tabs — `files` (the existing lazy file tree, rooted at the workspace's project directory), `notes` and `agents`. While it has focus, `Tab`/`Shift-Tab` cycle tabs and `1`/`2`/`3` jump directly; `h`/`l` keep the file tree's fold/parent behavior. Every tab and every list row is a `<leader>j` hint target.
- **Notes** (`notes` tab): real markdown buffers stored globally under `$OZ_NOTES_DIR`, else `$XDG_DATA_HOME/oz/notes`, else `$HOME/.local/share/oz/notes` (the directory is created lazily, never at startup). `j`/`k` select · Enter opens the note as a normal buffer (`:w` saves it) · `n` creates the smallest free `note-N.md` containing `# Untitled note` (existing files are never overwritten) · `r` refreshes. Rows show the first markdown heading (else the filename), a body snippet and relative age, newest first. Notes are project-independent: opening one never re-roots the workspace file tree/picker. Delete/rename are intentionally not implemented yet.
- **Agents** (`agents` tab): a compact navigator view of the same real session threads (grouped under the current workspace) — `j`/`k` select · Enter attaches the thread in the rail/workbox · `n` creates a new thread. This is a view, not a second thread model.
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
- **Workbox tabs**: Chat (the M1 transcript, streaming, cancellation, errors, Markdown and prompt), Changes (`no pending changes`, badge 0 for now), Tools (`tools arrive in M3`), Terminal (`agent terminal arrives in M3`; the existing editor terminal is still `Alt+r`). Empty states are real — no fabricated diffs, counts or charts.
- Keys:
  - Prompt: Enter send · Ctrl+c cancel · Ctrl+n new thread · Tab → thread list · Ctrl+j/k scroll one line · PageUp/PageDown scroll a page · Esc → editor (drawer: closes)
  - Thread list / workbox: `j`/`k` select · Enter attach · `n`/`+` new thread · `c`/`d`/`t`/`r` Chat/Changes/Tools/Terminal · Tab/Shift+Tab cycle tabs · `q`/Esc → editor
  - `<Ctrl-w> a` re-enters the rail at the thread list from the editor (also opens a closed rail)
- **Keyboard hints (M2.6a)**: `<leader>j` overlays qutebrowser-style labels (`asdfghjkl`, fixed length 1–3) on every visible target — filetree rows, buffer tabs, agent threads, navigator tabs, note rows, Workbox tabs, the `+` new-thread button and the prompt row. Type a full label to run the target's normal action, Backspace edits the prefix, Esc cancels with no side effects. A `HINTS · N targets · Esc cancel` indicator appears on the status bar; with nothing visible it reads `HINTS · no targets`. Plain `f` stays vim find-char — hints never take it. Works from the editor, the dashboard, the file tree and the AI thread list (not while typing in the prompt).
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
