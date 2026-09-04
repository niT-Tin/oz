//! oz App: editor state, input handling, rendering — split out of
//! src/main.zig (physical move, zero behavior change). Per-domain
//! method groups live in src/app/<domain>.zig and surface through
//! the decl aliases at the bottom of the App struct.

const std = @import("std");
const vaxis = @import("vaxis");
const buffer = @import("buffer/root.zig");
const editor = @import("editor/root.zig");
const util = @import("util/root.zig");
const syntax = @import("syntax.zig");
const lsp = @import("lsp/client.zig");
const lsp_types = @import("lsp/types.zig");
const lsp_diag = @import("lsp/diagnostics.zig");
const lsp_nav = @import("lsp/navigation.zig");
const json_rpc = @import("util/json_rpc.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const keymap_list = @import("editor/keymap_list.zig");
const git = @import("git.zig");
const term = @import("term.zig");

const autil = @import("app/util.zig");
const git_job = @import("app/git_job.zig");

const GitJobKind = git_job.GitJobKind;
const GitApplyOp = git_job.GitApplyOp;
const QueuedGitJob = git_job.QueuedGitJob;
const GitJob = git_job.GitJob;
const gitJobMain = git_job.gitJobMain;
const dupOrNull = git_job.dupOrNull;
const formatHm = git_job.formatHm;
const gitPreviewLineCount = git_job.gitPreviewLineCount;

/// Cells a '\t' occupies on screen (vim's shiftwidth-style expansion). The
/// renderer expands tabs to this many spaces; every width computation that
/// positions the cursor/ghost/menu must use the same value or columns drift.
pub const tab_width: u32 = 4;

pub const status_row_count: u32 = 1;

/// Current-line blame CursorHold delay (ms) — nvim updatetime-style; the
/// ghost appears this long after the cursor settles (<leader>tb).
pub const blame_hold_ms: i64 = 1000;

/// Live gutter-mark hold (ms): while the user is typing (insert session) the
/// buffer-vs-HEAD diff is refreshed once typing has been quiet this long
/// (gitsigns debounce). The run loop polls during the hold so the refresh
/// fires without a keypress.
pub const git_marks_hold_ms: i64 = 400;

/// Discrete (non-insert) edit hold (ms): x/dd/o-exit/undo/paste etc. are
/// one-shot actions — the marks refresh this long after the edit so rapid
/// successive ops coalesce into one refresh while a single op still feels
/// near-instant. Insert-exit (Esc/jk) expires the hold immediately.
pub const git_discrete_hold_ms: i64 = 120;

/// Files larger than this skip current-line blame entirely (gitsigns'
/// max_file_length — blame on huge files is slow and useless).
pub const max_blame_lines: u32 = 40000;

/// LSP navigation request kinds (K / gd / gD / gr / gI / gs).
pub const NavAction = enum { none, hover, definition, declaration, references, implementation, signature };

/// An inlay hint: dim label shown inline at (line, character).
pub const InlayHint = struct { line: u32, character: u32, label: []const u8 };


pub const GitPreview = @import("app/git.zig").GitPreview;

pub const LspStartJob = @import("app/lsp.zig").LspStartJob;

/// Pending 'r{char}' capture: the count from '3r', the char filled when the
/// next plain key arrives (normal mode only).
pub const ReplacePending = struct {
    count: u32 = 1,
    ch: u8 = 0,
};

/// Outward scope-highlight animation (snacks.indent.animate style "out"):
/// when the focused window's scope block changes, the highlight spreads from
/// the cursor line to the scope edges over `duration_ms` (linear, ~500ms —
/// "slow but not too slow"). The run loop polls while active so the spread
/// advances frame by frame without keypresses.
pub const ScopeAnim = struct {
    start_line: u32,
    end_line: u32,
    cursor_line: u32,
    start_ms: i128, // monotonic clock, ms
    pub const duration_ms: i128 = 500;
};

/// Cached tree-sitter spans for one buffer's visible byte range. The query
/// result depends only on the tree (identified by the buffer's history
/// revision) and the byte range, so while both are unchanged the renderer
/// reuses the previous frame's spans instead of re-running the query — the
/// common case for cursor movement inside a window and for the ~30 scope-
/// animation frames that repaint the same viewport. Owned via self.alloc
/// (the frame arena would free it before the next frame); see
/// clearSpanCache, which must be called when the buffer's text is replaced.
pub const SpanRangeCache = struct {
    revision: u64, // buf.history.revision when computed
    start: u32, // byte range the spans cover (inclusive start)
    end: u32, // byte range the spans cover (exclusive end)
    spans: []syntax.Span, // owned via self.alloc
};

/// Cached result of `syntax.Highlighter.scopeAt` for one (window, buffer)
/// pair. scopeAt walks the tree from the ROOT on every call — on a large
/// file that is a linear scan of the root's children, which is the single
/// most expensive thing in the render path. The result depends only on the
/// tree (identified by the buffer's history revision) and the queried byte,
/// so it is sound to reuse it while both are unchanged — e.g. the ~30
/// animation frames after a scope change, or split windows sharing a buffer.
pub const ScopeCache = struct {
    buf: usize, // buffers.items index
    win: usize, // windows.items index
    revision: u64, // buf.history.revision when computed
    cursor: u32, // cursor byte the scope was computed for
    start_line: u32,
    end_line: u32,
    indent_col: u32,
    has: bool,
};

pub const BlameGhostLabel = @import("app/git.zig").BlameGhostLabel;

pub const TermPane = @import("app/terminal.zig").TermPane;

pub const App = struct {
    /// One open document. `pt`/`history` own their allocations; the struct is
    /// moved between the list and the active slots (never copied-and-deinit'd).
    /// Cursor/viewport live in Window — the same buffer may be shown in
    /// several split windows with independent cursors.
    pub const Buffer = struct {
        pt: buffer.PieceTable,
        history: buffer.History,
        path: ?[]u8 = null,
        dirty: bool = false,
        /// tree-sitter highlighter for THIS buffer (independent of any
        /// window) — lazily built on the first render of a window showing it,
        /// so every split window gets real highlighting for its own buffer.
        hl: ?syntax.Highlighter = null,
        /// Pane this buffer's tab belongs to in the split tab bar: the window
        /// that last SHOWED it. Each buffer's tab appears exactly once — in
        /// its owning pane's zone — and a buffer hidden from every pane keeps
        /// its tab in the pane it was last displayed in.
        last_win: usize = 0,
        /// history.revision at this buffer's last parse (incremental-parse
        /// bookkeeping; maxInt forces a full reparse).
        syntax_revision: u64 = 0,
        /// Cached merged visible spans from the last visibleSpansFor call
        /// (owned by this buffer, alloc'd with the app allocator; spans are
        /// tiny — one viewport's worth — so the copy is cheaper than the
        /// query+merge it skips). Valid iff `spans_cache_valid` and the key
        /// (syntax_revision, byte range) matches — non-scrolling keys then
        /// cost 0 syntax work instead of a full query+merge per frame.
        spans_cache: []syntax.Span = &.{},
        spans_cache_valid: bool = false,
        spans_cache_start: u32 = 0,
        spans_cache_end: u32 = 0,
        spans_cache_rev: u64 = 0,
        /// history.revision when this buffer's content was last sent to the
        /// LSP server (didOpen/didChange). Combined with the client's open
        /// set, equal revision ⇒ the server's copy is current, so a buffer
        /// switch back to it can skip the re-open and its full-text copy.
        lsp_synced_rev: u64 = 0,
        /// Closed folds (indent-detected, see editor/fold.zig), sorted by
        /// start line. Kept PER BUFFER, not per window: two splits showing
        /// the same buffer share the fold state, so za in one split is
        /// visible in the other (folds are a property of the document view
        /// of the buffer, like the dirty flag). Any edit clears the set
        /// (markDirty) — line numbers drift after edits, and re-folding is
        /// cheap; vim-style fold carryover across edits is out of scope.
        folds: std.ArrayList(editor.fold.Range) = .empty,
        /// Cached syntax spans for this buffer's last-rendered visible byte
        /// range (owned; see SpanRangeCache). null until the first render.
        span_cache: ?SpanRangeCache = null,
    };

    /// One split window: which buffer it shows plus its own cursor/viewport.
    pub const Window = struct {
        buf: usize = 0,
        cursor: u32 = 0,
        view_top: u32 = 0,
    };

    /// Split orientation (vim: :sp = horizontal split = stacked rows,
    /// :vs = vertical split = side-by-side columns).
    pub const SplitDir = enum { horizontal, vertical };

    /// Window layout tree. Leaves index into `windows`; splits divide the
    /// screen rectangle between two subtrees.
    pub const WinNode = union(enum) {
        leaf: usize,
        split: struct {
            dir: SplitDir,
            a: *WinNode,
            b: *WinNode,
        },
    };



    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    /// Active color theme (persisted to ~/.cache/oz/theme, switchable at runtime).
    theme: theme.Theme,
    /// Theme when the theme picker opened — Esc restores it (no allocation;
    /// value copy, nothing to free in deinit).
    theme_saved: ?theme.Theme = null,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    tty_buffer: []u8,
    loop: vaxis.Loop(vaxis.Event),

    state: editor.Mode.State,
    buffers: std.ArrayList(Buffer) = .empty,
    current: usize = 0,
    /// Split windows (one per leaf). `current_win` is the focused leaf.
    windows: std.ArrayList(Window) = .empty,
    win_root: ?*WinNode = null,
    current_win: usize = 0,
    in_insert: bool = false,
    quit: bool = false,

    // command line (':') state
    cmdline: std.ArrayList(u8),
    cmd_history: std.ArrayList([]u8),
    cmd_hist_idx: ?usize = null,
    /// Tab-completion cursor for ":e <path>" / command-name cycling. Separate
    /// from cmd_hist_idx: the completers must not clobber the history index
    /// (Up/Down) or vice versa, or a Tab after an Up would jump to a
    /// random history entry.
    cmd_complete_idx: usize = 0,
    /// What the cmdline collects: an ex command (':') or a buffer search
    /// ('/' forward, '?' backward). Same widget; Enter dispatches differently.
    cmdline_kind: enum { ex, search_fwd, search_bwd } = .ex,
    /// Last executed search query (owned) and its direction — for n/N.
    last_search: ?[]u8 = null,
    last_search_bwd: bool = false,
    /// The command-name match list from the last Tab (owned), so repeated
    /// Tabs cycle the ORIGINAL matches even after the line becomes a full
    /// command name (":b" Tab → bnext, Tab → bprev, …). Cleared on any
    /// command-line entry/exit and on path completion.
    cmd_complete_names: std.ArrayList([]const u8) = .empty,
    prev_insert_key: ?vaxis.Key = null,
    msg: ?[]u8 = null, // transient status message (owned)

    // visual selection
    visual_anchor: ?u32 = null,
    // yank buffer (M0: in-memory; OSC52 system clipboard is a later step)
    yank_buffer: ?[]u8 = null,
    /// Register type (vim regtype): yy/dd/V{y,d} and linewise operator
    /// motions yank LINEWISE — p/P then put whole lines below/above the
    /// cursor line; charwise yanks (yw, vey, …) paste inline after/at the
    /// cursor. nvim's unnamed register behaves exactly this way.
    yank_linewise: bool = false,

    /// 'r' seen; the next plain key is the replacement character (normal
    /// mode), applied `count` times (vim 3rx). Cleared by execAction when
    /// 'r' is pressed / by handleKey.
    pending_replace: ?ReplacePending = null,

    // easymotion (s / <leader>f) state
    em_active: bool = false,
    /// The 1-char query as UTF-8 bytes (1-2 bytes; may be non-ASCII like
    /// CJK). Kept as bytes because find() matches on bytes, not codepoints.
    em_query: [4]u8 = .{ 0, 0, 0, 0 },
    em_query_len: u8 = 0,
    em_labels: bool = false, // matches computed, labels shown
    em_matches: []editor.easymotion.Match = &.{},

    // multi-cursor (Ctrl+n)
    mc: editor.MultiCursor = undefined,
    mc_active: bool = false,

    // recent files (dashboard)
    recent_files: std.ArrayList([]u8) = .empty,
    recent_sel: usize = 0,

    // LSP: the current buffer's client (null when the filetype has no
    // server / spawn failed — silent degrade). Diagnostics received are
    // stashed here until the M2 diagnostics UI lands.
    lsp_client: ?*lsp.Client = null,
    /// In-flight async attach (ensureLsp); null when idle. Consumed by
    /// finishLspStart in the run loop.
    lsp_starting: ?*LspStartJob = null,
    lsp_diagnostics: std.ArrayList(lsp_types.Diagnostic) = .empty,
    /// Set by lspHandler when publishDiagnostics changed the list: the run
    /// loop must repaint or the gutter marks go stale (a final "all clean"
    /// push that isn't drawn leaves a phantom ✖ until the next keypress).
    diag_dirty: bool = false,

    // file tree (<leader>e)
    filetree_active: bool = false,
    filetree_sel: usize = 0,
    /// Scroll-window top for the sidebar: the selection moves freely inside
    /// the window; the window scrolls only when it crosses an edge.
    filetree_top: usize = 0,
    /// Window focus (vim Ctrl-w hjkl): which pane receives hjkl — the
    /// file-tree sidebar or the buffer. The sidebar keeps rendering either
    /// way; only the focused pane reacts to keys.
    focus: enum { buffer, filetree } = .buffer,
    /// Ctrl-w seen, awaiting the window-motion key (h/l/j/k).
    pending_window: bool = false,
    /// Content hash at insert-session entry, so an insert session that ends
    /// with no net change can clear the dirty flag ("typed then deleted it
    /// all back" must not mark the buffer modified).
    insert_base_hash: u64 = 0,
    insert_was_dirty: bool = false,
    /// cwd root node; its children are the first level (built on first open).
    filetree_root: ?*TreeNode = null,
    /// Visible rows (expanded subtree in DFS order), rebuilt whenever the
    /// tree structure changes (open / expand / collapse / locate). The
    /// selection indexes into this list, so it must stay in sync with the
    /// tree — rebuild is the only mutation path.
    filetree_rows: std.ArrayList(FiletreeRow) = .empty,

    // fuzzy picker (<leader>sf / <leader>st / <leader>sb / <leader>sr / <leader>sk / <leader>sp)
    picker_mode: enum { files, grep, buffers, recent, keymaps, themes } = .files,
    picker_active: bool = false,
    picker_files: std.ArrayList([]u8) = .empty, // owned paths
    picker_input: std.ArrayList(u8) = .empty,
    picker_matches: std.ArrayList(usize) = .empty, // indices into picker_files
    picker_sel: usize = 0,
    /// Scroll-window top for the picker list (same semantics as filetree_top).
    picker_top: usize = 0,
    // grep mode: one result per line from rg
    grep_results: std.ArrayList(GrepResult) = .empty,
    // split preview (grep panel right column, nav-list right column): the
    // selected entry's file content plus its tree-sitter highlighter, rebuilt
    // only when the selection's path changes (never per-frame).
    // preview_text == null means unavailable (>SIZE_LIMIT or read failed) —
    // the panel shows a "preview unavailable" hint.
    preview_path: ?[]u8 = null,
    preview_text: ?[]u8 = null,
    preview_hl: ?syntax.Highlighter = null,

    // M2 diagnostics list overlay (<leader>sd)
    diag_list_active: bool = false,
    diag_list_sel: usize = 0,
    diag_list_top: usize = 0,

    // M2 LSP navigation (K / gd / gD / gr / gI / gs): one in-flight request
    // at a time; the response lands in nav_slot and processNav() consumes it.
    nav_slot: ?std.json.Value = null,
    nav_action: NavAction = .none,
    /// Owned hover/signature text shown in a floating window (or null).
    nav_hover_text: ?[]u8 = null,
    /// Owned location list for gr/gI (uri strings owned per item).
    nav_locations: std.ArrayList(lsp_nav.NavLocation) = .empty,
    nav_list_active: bool = false,
    nav_list_sel: usize = 0,
    nav_loc_top: usize = 0,
    /// Float title for the location list (" Outline " / " References " /
    /// " Implementations " — static literal, set by whichever request filled
    /// the list; the list renders in the same floating window as the pickers).
    nav_list_title: []const u8 = " Locations ",
    /// Float geometry for the location list, refreshed every render — the
    /// cursor block (which runs after the overlays) lands the block cursor
    /// on the selected row of the float.
    nav_float_row: u32 = 0,
    nav_float_col: u32 = 0,

    // ---- M3a git (gutter / hunks / blame / lazygit) ----
    /// In-flight async git job (one at a time). See GitJob.
    git_job: ?*GitJob = null,
    /// A status refresh was requested while a job was running: when the
    /// current job completes, spawn another status job (keeps branch/marks
    /// fresh across fast open/save sequences).
    git_refresh_pending: bool = false,
    /// Branch of the current file's repo (owned), null when not a repo.
    git_branch: ?[]u8 = null,
    /// Parsed diff for the current file (owned).
    git_diff: git.FileDiff = .{},
    /// Path the diff/branch were computed for (owned, absolute) — the marks
    /// only render when it still matches the current buffer.
    git_diff_path: ?[]u8 = null,
    /// Parsed blame for the current file (owned).
    git_blame: ?git.Blame = null,
    /// Path the cached blame was computed for (owned, absolute) — the ghost
    /// only renders when it still matches the current buffer.
    git_blame_path: ?[]u8 = null,
    /// Inline blame panel visibility (<leader>tb).
    /// Current-line blame is ON BY DEFAULT (nvim gitsigns current_line_blame
    /// = true): the ghost appears on the cursor line 1s after it settles.
    /// <leader>tb toggles it.
    blame_active: bool = true,
    /// Current-line blame ghost (nvim gitsigns style): the blame of the
    /// cursor line shows as end-of-line dim text, 1s after the cursor
    /// settles (CursorHold). Fields track the hold: the last cursor byte
    /// offset seen by the renderer and when it changed.
    blame_last_cursor: u32 = 0,
    blame_move_ms: i64 = 0,
    /// Cached current-line blame ghost label (see BlameGhostLabel).
    blame_ghost_label: ?BlameGhostLabel = null,
    /// Hunk preview float (<leader>hp); owned patch text.
    git_preview: ?GitPreview = null,
    /// <leader>hp hit while the diff was stale: show the preview when the
    /// status job lands.
    git_preview_pending: bool = false,
    /// A non-status job (blame/apply) requested while another job was
    /// running — re-spawned with these exact params once the current job
    /// finishes (status refreshes use git_refresh_pending instead). Apply
    /// must NOT be dropped: ` hs` pressed while a blame job runs would
    /// otherwise silently do nothing.
    git_queued: ?QueuedGitJob = null,
    /// Live gutter marks: the current buffer's text changed after the last
    /// landed buffer-vs-HEAD diff. While true the marks shown are the last
    /// quiesced state (positionally shifted along by edits — see
    /// FileDiff.shiftInsert/shiftDelete); the run loop re-diffs once the
    /// edit hold expires (git_marks_at).
    git_marks_stale: bool = false,
    /// Monotonic ms DEADLINE: the live-refresh fires once `now` passes this
    /// (set by gitMarksStaleNow: now + typing/discrete hold; expired to now
    /// by gitRefreshSoon on insert-exit). 0 = expired.
    git_marks_at: i64 = 0,
    /// edit_seq at the moment the in-flight status job's buffer snapshot
    /// was taken. A landed status reflects the current text only when no
    /// edit bumped edit_seq after the snapshot — otherwise it stays stale
    /// and the loop refreshes again.
    git_status_spawn_seq: u64 = 0,

    // insert-mode completion (Ctrl+n and auto-suggest on word chars)
    completion_active: bool = false,
    /// Owned candidate items (text + LSP kind for the menu icon).
    completion_words: std.ArrayList(lsp_nav.CompletionItem) = .empty,
    completion_sel: usize = 0,
    /// Start of the word being typed when the menu opened; Enter replaces
    /// [completion_pos, cursor) with the selected word.
    completion_pos: u32 = 0,
    /// True when the last completion request came from Ctrl+n (vs the
    /// automatic suggest): an empty result then shows a status-bar hint so a
    /// silent "no candidates" doesn't get mistaken for a completed accept
    /// (whose Enter would otherwise insert a newline).
    completion_manual: bool = false,
    /// Set by Ctrl+n and cleared when its response is consumed: while it is
    /// set and no menu is open, Enter must NOT insert a newline (zls can take
    /// many seconds on build.zig) — it shows "completion pending…" instead,
    /// so the completion isn't silently swallowed by an early Enter.
    completion_waiting_enter: bool = false,
    /// LSP textDocument/completion response slot (filled by drain); consumed
    /// by processCompletion. Local word completion is the fallback.
    completion_slot: ?std.json.Value = null,
    /// LSP textDocument/formatting response slot (TextEdit[]).
    format_slot: ?std.json.Value = null,
    /// LSP textDocument/inlayHint response slot.
    inlay_slot: ?std.json.Value = null,
    /// LSP textDocument/documentSymbol response slot (outline list).
    outline_slot: ?std.json.Value = null,
    /// <leader>rn: cmdline is collecting the new name; Enter sends rename.
    pending_rename: bool = false,
    /// Owned inlay hints (line/character + label) rendered dim inline.
    /// Auto-requested for the focused window's visible range whenever the
    /// view scrolls (the request covers a band around the viewport — see
    /// requestInlayHints — so small scrolls render from the stored hints
    /// without asking the server again).
    ///
    /// The hints in the list are homogeneous: they all describe ONE
    /// buffer — the one `inlay_buf` names (requestInlayHints fetches for
    /// the focused window's buffer, and every accepted response REPLACES
    /// the whole list). A window renders them only while it shows that
    /// buffer (`inlay_buf == w.buf`); with two split windows showing
    /// DIFFERENT buffers, the unfocused window must never splice the
    /// focused buffer's hints — fetched at ITS line numbers/byte columns —
    /// into its own text (the "right window inlay hints misaligned"
    /// report). Hints for the other window are simply not loaded: only
    /// the focused window ever requests (single-document LSP client,
    /// same "current buffer only" model as diagnostics).
    inlay_hints: std.ArrayList(InlayHint) = .empty,
    /// buffers.items index of the buffer `inlay_hints` belongs to (the
    /// buffer the LAST ACCEPTED inlayHint response was fetched for). null
    /// while the list is empty (never requested, or invalidated by a
    /// buffer/window switch). lineHints' per-line filter is keyed on
    /// `line` alone, so this tag is what stops hints fetched for buffer A
    /// from rendering over buffer B's text at the same line numbers.
    inlay_buf: ?usize = null,
    /// Line range [inlay_view_top, inlay_view_end) covered by the LAST
    /// sent inlayHint request (its response only carries hints inside the
    /// requested range). The run loop re-requests when the focused
    /// viewport leaves this band. null until the first request.
    inlay_view_top: ?u32 = null,
    inlay_view_end: ?u32 = null,
    /// True while an inlayHint request is in flight (sent, response not
    /// yet consumed). The run loop skips the auto-refresh while true:
    /// fast scrolling must not pile superseded requests into the server
    /// queue (each would be computed and dropped) — the response to the
    /// newest band is enough, and the band check re-requests when it
    /// arrives while the viewport has moved outside the band.
    inlay_inflight: bool = false,
    /// buffers.items index of the buffer the LAST SENT inlayHint request
    /// targeted (== self.current when requestInlayHints ran). processInlay
    /// accepts a response only when this still names the CURRENT buffer:
    /// a buffer/window switch mid-flight must not install the previous
    /// buffer's hints (invalidateInlayHints cleared the list on the
    /// switch, and the re-request for the newly focused buffer has not
    /// landed yet). Left stale on purpose — invalidate does NOT clear it,
    /// or a response that raced a switch-then-switch-back could not be
    /// matched against the buffer it was fetched for.
    inlay_req_buf: ?usize = null,
    /// Scope-highlight animation state (null when idle / no scope). Restarted
    /// whenever the focused window's scope block changes; see ScopeAnim.
    scope_anim: ?ScopeAnim = null,
    /// True while the run loop is in the 1ms poll slice (scope animation,
    /// blame hold, or an open embedded terminal). Cleared the moment the
    /// loop switches back to blocking pollEvent; the run loop forces one
    /// render on that transition so the final state (ghost appearing as the
    /// CursorHold expires, animation's last spread) is never skipped.
    poll_mode_active: bool = false,
    /// Cached scopeAt result for the last rendered (window, buffer, cursor,
    /// revision) — recomputed only when the tree or the cursor byte changed.
    scope_cache: ?ScopeCache = null,
    /// Set when the inlay data no longer matches the document (after an
    /// insert session ends) until a fresh response arrives: renderers hide
    /// stale hints instead of drawing them at shifted, wrong columns, and
    /// the exit frame never flashes a "hints vanish → reappear" pair.
    inlay_stale: bool = false,
    /// Monotonic edit counter: bumped by every text edit. LSP responses that
    /// arrive after newer edits (fast typing) are discarded as stale, and
    /// inlay hints are re-requested only when the text is quiescent — this is
    /// what keeps insert mode from flickering on every keystroke.
    edit_seq: u64 = 0,
    /// edit_seq at the moment the in-flight inlayHint request was sent.
    inlay_req_seq: u64 = 0,
    /// edit_seq at the moment the in-flight completion request was sent.
    completion_req_seq: u64 = 0,
    /// edit_seq at the moment the in-flight formatting/rename request was
    /// sent (format_slot is shared by both).
    format_req_seq: u64 = 0,

    /// Per-frame memo for screenCellCol: the same (line, byte_pos) query
    /// recurs several times a frame (status bar, cursor block, completion
    /// menu, ghost text). Invalidated at the top of render().
    cell_col_memo: struct { line: u32 = 0, pos: u32 = 0, col: u32 = 0, valid: bool = false } = .{},

    // ---- M3b embedded terminal (<M-r> float / <M-w> bottom / <M-e> right) ----
    /// Embedded terminal session; TermPane is void on non-Linux (vaxis PTY
    /// backend), making this field ?void there. The vaxis widget's reader
    /// thread holds a *Terminal for its whole life, so the pane lives at a
    /// stable address — a plain App field, never a reallocating list.
    term_pane: ?TermPane = null,

    /// The active buffer (the focused window's buffer; per-buffer document
    /// state lives here, per-window cursor/viewport in `windows`).
    pub fn cur(self: *App) *Buffer {
        return &self.buffers.items[self.windows.items[self.current_win].buf];
    }

    /// The focused window's cursor (byte offset in its buffer).
    pub fn curCursor(self: *App) *u32 {
        return &self.windows.items[self.current_win].cursor;
    }

    /// The focused window's viewport top (first visible line).
    pub fn curViewTop(self: *App) *u32 {
        return &self.windows.items[self.current_win].view_top;
    }

    /// Height (in text rows) of the focused window's leaf rect. Runs the same
    /// layout math as render() so H/M/L and zz/zt/zb agree with what's on
    /// screen, including splits.
    pub fn focusedWinHeight(self: *App) u32 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const win = self.vx.window();
        const height: u32 = win.height;
        if (height <= status_row_count) return 1;
        const content_rows = height - status_row_count - self.tabBarRows(arena.allocator());
        const layout = self.layoutWindows(arena.allocator(), self.contentTop(arena.allocator()), content_rows, self.contentCol(), win.width) catch return content_rows;
        for (layout.leaves) |leaf| {
            if (leaf.win == self.current_win) return leaf.height;
        }
        return content_rows;
    }

    /// H/M/L: resolve a viewport motion to a document LINE using the focused
    /// window's view_top and height (the pure motion layer knows neither).
    /// Returns null for non-viewport motions. The count is ignored, like
    //  first_line/last_line (vim's {count}H targeting is out of scope).
    pub fn viewMotionTargetLine(self: *App, motion: editor.Motion.Motion) ?u32 {
        const w = &self.windows.items[self.current_win];
        const buf = &self.buffers.items[w.buf];
        const line_count = buf.pt.lineCount();
        const height = self.focusedWinHeight();
        const top = @min(w.view_top, line_count - 1);
        // walk VISIBLE lines from the top: a closed fold is one screen row,
        // so M/L can't be top + height (they'd overshoot past hidden lines)
        const steps: u32 = switch (motion) {
            .view_top_line => return top,
            .view_middle_line => (height -| 1) / 2,
            .view_bottom_line => height -| 1,
            else => return null,
        };
        var line = top;
        var i: u32 = 0;
        while (i < steps and line + 1 < line_count) : (i += 1) {
            line = foldNextLine(buf, line);
        }
        return @min(line, line_count - 1);
    }

    /// zz/zt/zb: scroll so the cursor line sits at the middle/top/bottom of
    /// the focused window; the cursor itself does not move. Clamped like the
    /// render loop's ensure-visible logic: no negative scroll, and never past
    /// "last line at the window bottom".
    pub fn scrollCursorTo(self: *App, where: enum { top, center, bottom }) void {
        const w = &self.windows.items[self.current_win];
        const buf = &self.buffers.items[w.buf];
        const line_count = buf.pt.lineCount();
        const height = self.focusedWinHeight();
        const cursor_line = buf.pt.lineOf(w.cursor);
        var top: u32 = switch (where) {
            .top => cursor_line,
            .center => cursor_line -| (height / 2),
            .bottom => cursor_line -| (height -| 1),
        };
        if (line_count > height) {
            top = @min(top, line_count - height);
        } else {
            top = 0;
        }
        w.view_top = top;
    }

    // ---- folds (za/zo/zc/zR/zM; detection lives in editor/fold.zig) ----
    //
    // A buffer's `folds` list holds the CLOSED ranges, sorted by start.
    // j/k treat a closed fold as one line; every other motion that lands
    // inside a hidden body snaps to the fold's header line (the cursor must
    // never rest on a hidden line). Rendering draws the header plus a dim
    // "… N lines" marker and skips the body.

    /// The closed fold whose header is `line`, if any.
    pub fn foldAt(buf: *const Buffer, line: u32) ?editor.fold.Range {
        for (buf.folds.items) |f| {
            if (f.start == line) return f;
        }
        return null;
    }

    /// The outermost closed fold whose hidden body contains `line`
    /// (start < line <= end), if any.
    pub fn foldCovering(buf: *const Buffer, line: u32) ?editor.fold.Range {
        var best: ?editor.fold.Range = null;
        for (buf.folds.items) |f| {
            if (line > f.start and line <= f.end) {
                if (best == null or f.start < best.?.start) best = f;
            }
        }
        return best;
    }

    /// Next visible line after `line`: a closed fold's whole body counts as
    /// part of its header row, so iteration jumps from header to end + 1.
    pub fn foldNextLine(buf: *const Buffer, line: u32) u32 {
        if (foldAt(buf, line)) |f| return f.end + 1;
        return line + 1;
    }

    /// Previous visible line before `line`; lands on a fold's header, never
    /// inside a hidden body.
    pub fn foldPrevLine(buf: *const Buffer, line: u32) u32 {
        if (line == 0) return 0;
        var l = line - 1;
        if (foldCovering(buf, l)) |f| l = f.start;
        return l;
    }

    /// Snap `pos` out of a closed fold's hidden body onto the header line
    /// (keeping the column); no-op when the line is visible.
    pub fn foldSnapPos(buf: *const Buffer, pos: u32) u32 {
        const line = buf.pt.lineOf(pos);
        const f = foldCovering(buf, line) orelse return pos;
        return editor.Motion.toLineKeepCol(&buf.pt, pos, f.start);
    }

    /// za/zo/zc/zR/zM. The fold set is per-buffer (shared between splits);
    /// `range`/detection is indent-based via editor.fold.
    pub fn execFold(self: *App, action: editor.KeyEvent.ActionId) !void {
        const buf = self.cur();
        switch (action) {
            .fold_open_all => buf.folds.clearRetainingCapacity(),
            .fold_close_all => {
                buf.folds.clearRetainingCapacity();
                const ranges = try editor.fold.allRanges(&buf.pt, self.alloc);
                defer self.alloc.free(ranges);
                // close outermost folds only: a nested range's body is
                // already hidden by its parent, and keeping nested entries
                // would make zR → re-zM behaviour surprising; one entry per
                // hidden screen region is enough
                for (ranges) |r| {
                    const covered = blk: {
                        for (buf.folds.items) |f| {
                            if (r.start > f.start and r.end <= f.end) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!covered) try buf.folds.append(self.alloc, r);
                }
                self.snapCursorOutOfFold();
            },
            .fold_toggle, .fold_open, .fold_close => {
                const line = buf.pt.lineOf(self.curCursor().*);
                // the innermost foldable range containing the cursor line
                const target = try editor.fold.innermostContaining(&buf.pt, self.alloc, line);
                if (target == null) {
                    // not an error — zc/za on a non-foldable line is a no-op
                    try self.setMsg(try self.alloc.dupe(u8, "该行没有可折叠的区域"));
                    return;
                }
                // is any closed fold covering the cursor line (or starting
                // exactly at it)? za/zo open the innermost such fold;
                // otherwise (zc, or za on an open fold) close `target`.
                var closed_hit: ?usize = null;
                for (buf.folds.items, 0..) |f, i| {
                    if (line >= f.start and line <= f.end) {
                        if (closed_hit == null or f.start > buf.folds.items[closed_hit.?].start) closed_hit = i;
                    }
                }
                const want_open = action == .fold_open or (action == .fold_toggle and closed_hit != null);
                if (want_open) {
                    const i = closed_hit orelse return; // zo/za on an open fold: no-op
                    _ = buf.folds.orderedRemove(i);
                } else {
                    // zc on an already-closed inner fold walks out to the
                    // enclosing open one; everything closed → no-op
                    var r = target.?;
                    while (true) {
                        const already = blk: {
                            for (buf.folds.items) |f| {
                                if (f.start == r.start) break :blk true;
                            }
                            break :blk false;
                        };
                        if (!already) break;
                        if (r.start == 0) return; // no enclosing line possible
                        const outer = try editor.fold.innermostContaining(&buf.pt, self.alloc, r.start - 1);
                        if (outer == null) return;
                        r = outer.?;
                    }
                    try buf.folds.append(self.alloc, r);
                    std.mem.sort(editor.fold.Range, buf.folds.items, {}, struct {
                        fn lt(_: void, x: editor.fold.Range, y: editor.fold.Range) bool {
                            return x.start < y.start;
                        }
                    }.lt);
                    self.snapCursorOutOfFold();
                }
            },
            else => unreachable,
        }
    }

    /// After a fold closes, the focused window's cursor may sit inside the
    /// hidden body — move it to the fold header (vim does the same).
    pub fn snapCursorOutOfFold(self: *App) void {
        const w = &self.windows.items[self.current_win];
        const buf = &self.buffers.items[w.buf];
        w.cursor = foldSnapPos(buf, w.cursor);
    }

    /// Free a window tree (recursive).
    pub fn freeWinTree(self: *App, node: *WinNode) void {
        switch (node.*) {
            .leaf => self.alloc.destroy(node),
            .split => |*s| {
                self.freeWinTree(s.a);
                self.freeWinTree(s.b);
                self.alloc.destroy(node);
            },
        }
    }

    /// Debug invariant: every window index appears exactly once as a leaf and
    /// all leaves are in range. Call after any tree mutation.
    pub fn winTreeSanity(self: *App) void {
        const root = self.win_root orelse return;
        var count: usize = 0;
        var stack: [128]*WinNode = undefined;
        var sp: usize = 0;
        stack[sp] = root;
        sp += 1;
        var seen = std.AutoHashMap(usize, void).init(self.alloc);
        defer seen.deinit();
        while (sp > 0) {
            sp -= 1;
            const n = stack[sp];
            switch (n.*) {
                .leaf => |i| {
                    count += 1;
                    if (i >= self.windows.items.len) std.debug.panic("leaf {d} out of range (windows {d})", .{ i, self.windows.items.len });
                    if (seen.contains(i)) std.debug.panic("duplicate leaf {d}", .{i});
                    seen.put(i, {}) catch {};
                },
                .split => |*s| {
                    if (sp + 2 >= stack.len) std.debug.panic("window tree too deep", .{});
                    stack[sp] = s.a;
                    sp += 1;
                    stack[sp] = s.b;
                    sp += 1;
                },
            }
        }
        if (count != self.windows.items.len) std.debug.panic("tree leaves {d} != windows {d}", .{ count, self.windows.items.len });
    }

    // ---- split windows (:vs / :sp / :q / Ctrl-w) ----

    /// Split the focused window in `dir`; the new window shows the same
    /// buffer with a copy of the current cursor/viewport and takes focus
    /// (vim: the split command focuses the new window).
    pub fn splitWindow(self: *App, dir: SplitDir) !void {
        const cur_win = self.current_win;
        try self.windows.append(self.alloc, .{
            .buf = self.windows.items[cur_win].buf,
            .cursor = self.windows.items[cur_win].cursor,
            .view_top = self.windows.items[cur_win].view_top,
        });
        const new_idx: usize = self.windows.items.len - 1;
        // the new pane (which takes focus) is the last to SHOW the shared
        // buffer, so the buffer's tab belongs to the new pane's zone (split
        // tab bar: each buffer's tab appears exactly once, in the pane that
        // last displayed it)
        self.buffers.items[self.windows.items[new_idx].buf].last_win = new_idx;
        const root = self.win_root orelse return;
        try self.replaceLeaf(root, cur_win, dir, new_idx);
        self.current_win = new_idx;
        self.winTreeSanity();
    }

    /// Replace the leaf `leaf_idx` under `node` with a split of it and a new
    /// leaf `new_idx` (recursive; the leaf must exist).
    pub fn replaceLeaf(self: *App, node: *WinNode, leaf_idx: usize, dir: SplitDir, new_idx: usize) !void {
        switch (node.*) {
            .leaf => |i| {
                if (i == leaf_idx) {
                    const a = try self.alloc.create(WinNode);
                    errdefer self.alloc.destroy(a);
                    a.* = .{ .leaf = leaf_idx };
                    const b = try self.alloc.create(WinNode);
                    b.* = .{ .leaf = new_idx };
                    node.* = .{ .split = .{ .dir = dir, .a = a, .b = b } };
                }
            },
            .split => |*s| {
                try self.replaceLeaf(s.a, leaf_idx, dir, new_idx);
                try self.replaceLeaf(s.b, leaf_idx, dir, new_idx);
            },
        }
    }

    /// Remove the leaf `leaf_idx` from the tree rooted at `root`. Returns the
    /// replacement subtree for `root` (a promoted sibling when the removed
    /// leaf was a direct child), freeing the removed leaf and split nodes.
    /// A lone root leaf is never passed here (single window goes through
    /// closeSingleWindow).
    pub fn removeWindow(self: *App, root: *WinNode, leaf_idx: usize) ?*WinNode {
        switch (root.*) {
            .leaf => |i| {
                // The removed leaf itself: free it (the caller promotes a
                // sibling). Only reachable for a non-root leaf; a matching
                // root leaf means single-window, handled before this call.
                if (i == leaf_idx) {
                    self.alloc.destroy(root);
                    return null;
                }
                return root;
            },
            .split => |*s| {
                if (self.removeWindow(s.a, leaf_idx)) |na| {
                    s.a = na;
                } else {
                    // s.a (a matching leaf) was freed by the recursion; its
                    // sibling takes this split's place
                    const promoted = s.b;
                    self.alloc.destroy(root);
                    return promoted;
                }
                if (self.removeWindow(s.b, leaf_idx)) |nb| {
                    s.b = nb;
                    return root;
                } else {
                    const promoted = s.a;
                    self.alloc.destroy(root);
                    return promoted;
                }
            },
        }
    }

    /// The leftmost leaf index in the tree (a valid focus target).
    pub fn firstLeaf(self: *App, node: *WinNode) usize {
        return switch (node.*) {
            .leaf => |i| i,
            .split => |s| self.firstLeaf(s.a),
        };
    }

    /// After removing a window, decrement every leaf index above `removed`
    /// (the windows list was shifted down by one).
    pub fn adjustLeafIndices(self: *App, node: *WinNode, removed: usize) void {
        switch (node.*) {
            .leaf => |*i| {
                if (i.* > removed) i.* -= 1;
            },
            .split => |*s| {
                self.adjustLeafIndices(s.a, removed);
                self.adjustLeafIndices(s.b, removed);
            },
        }
    }

    /// One leaf window's screen rectangle (content area coordinates).
    pub const LeafRect = struct {
        win: usize,
        row: u32,
        col: u32,
        height: u32,
        width: u32,
    };

    /// One window separator line (vim statusline semantics): the boundary
    /// between two panes, drawn OVER the leaf buffers so the layout math is
    /// untouched. Horizontal splits get a full "─" row at `row`; vertical
    /// splits a "│" column at `col`. `len` is the extent in the separator's
    /// own direction (cells). `active` marks the separators adjacent to the
    /// focused window (the path from the root to the current leaf), drawn
    /// bright; the rest are dim.
    pub const SepRect = struct {
        row: u32,
        col: u32,
        len: u32,
        horizontal: bool,
        active: bool,
    };

    /// true when leaf `leaf` lives anywhere inside `node`'s subtree.
    pub fn subTreeHasLeaf(self: *App, node: *WinNode, leaf: usize) bool {
        return switch (node.*) {
            .leaf => |i| i == leaf,
            .split => |s| self.subTreeHasLeaf(s.a, leaf) or self.subTreeHasLeaf(s.b, leaf),
        };
    }

    /// Compute each leaf window's rectangle from the split tree, plus the
    /// separator lines between the panes (one per split node).
    pub fn layoutWindows(self: *App, a: std.mem.Allocator, content_top: u32, content_rows: u32, content_col: u32, total_width: u32) !struct { leaves: []LeafRect, seps: []SepRect } {
        var leaves = std.ArrayList(LeafRect).empty;
        var seps = std.ArrayList(SepRect).empty;
        const root = self.win_root orelse return .{ .leaves = &.{}, .seps = &.{} };
        try self.layoutNode(a, root, .{
            .win = 0,
            .row = content_top,
            .col = content_col,
            .height = content_rows,
            .width = total_width,
        }, &leaves, &seps);
        return .{ .leaves = try leaves.toOwnedSlice(a), .seps = try seps.toOwnedSlice(a) };
    }

    pub fn layoutNode(self: *App, a: std.mem.Allocator, node: *WinNode, rect: LeafRect, out: *std.ArrayList(LeafRect), seps: *std.ArrayList(SepRect)) !void {
        switch (node.*) {
            .leaf => |i| try out.append(a, .{ .win = i, .row = rect.row, .col = rect.col, .height = rect.height, .width = rect.width }),
            .split => |*s| switch (s.dir) {
                .horizontal => {
                    const h1 = rect.height / 2;
                    try seps.append(a, .{
                        .row = rect.row + h1,
                        .col = rect.col,
                        .len = rect.width,
                        .horizontal = true,
                        .active = self.subTreeHasLeaf(node, self.current_win),
                    });
                    try self.layoutNode(a, s.a, .{ .win = 0, .row = rect.row, .col = rect.col, .height = h1, .width = rect.width }, out, seps);
                    try self.layoutNode(a, s.b, .{ .win = 0, .row = rect.row + h1, .col = rect.col, .height = rect.height - h1, .width = rect.width }, out, seps);
                },
                .vertical => {
                    const w1 = rect.width / 2;
                    try seps.append(a, .{
                        .row = rect.row,
                        .col = rect.col + w1,
                        .len = rect.height,
                        .horizontal = false,
                        .active = self.subTreeHasLeaf(node, self.current_win),
                    });
                    try self.layoutNode(a, s.a, .{ .win = 0, .row = rect.row, .col = rect.col, .height = rect.height, .width = w1 }, out, seps);
                    try self.layoutNode(a, s.b, .{ .win = 0, .row = rect.row, .col = rect.col + w1, .height = rect.height, .width = rect.width - w1 }, out, seps);
                },
            },
        }
    }

    /// :q — close the focused window. With several windows the tree loses one
    /// leaf and focus moves to its neighbor; with one window the buffer is
    /// closed (next buffer takes over, or the app quits when it was the last).
    pub fn closeWindow(self: *App) void {
        if (self.windows.items.len <= 1) {
            self.closeSingleWindow();
            return;
        }
        const cur_win = self.current_win;
        const root = self.win_root orelse return;
        const new_root = self.removeWindow(root, cur_win) orelse unreachable; // ≥2 windows: never the root itself
        self.win_root = new_root;
        _ = self.windows.orderedRemove(cur_win);
        self.adjustLeafIndices(self.win_root.?, cur_win);
        self.current_win = self.firstLeaf(self.win_root.?);
        self.winTreeSanity();
        // tab ownership tracks the window indices: the removed window's
        // buffers re-home to the surviving leftmost pane (unless another
        // window shows them), indices above shift down, and a displayed
        // buffer always owns its displaying pane
        const home = self.current_win;
        for (self.buffers.items) |*buf| {
            if (buf.last_win == cur_win) {
                buf.last_win = home;
            } else if (buf.last_win > cur_win) {
                buf.last_win -= 1;
            }
        }
        for (self.windows.items, 0..) |w, wi| {
            self.buffers.items[w.buf].last_win = wi;
        }
        // sync the current buffer/highlighter (and LSP client) with the
        // surviving window — same activation as Ctrl-w focus switches
        self.switchWindowTo(self.current_win);
    }

    /// Last-window :q — vim behavior: closing the last window quits the
    /// editor (all buffers end together). Multi-window :q only closes the
    /// focused window (closeWindow's other branch).
    pub fn closeSingleWindow(self: *App) void {
        self.quit = true;
    }

    /// Make window `i` the focused one, syncing the current buffer and the
    /// highlighter (vim: the focused window's buffer is "the" current buffer).
    /// When the window shows a buffer other than the previously current one,
    /// the FULL per-buffer activation runs — the same set switchTo applies:
    /// LSP client retarget (ensureLsp), inlay/diagnostic/hover invalidation,
    /// git status refresh. Without it the single LSP client stays attached to
    /// the previous window's document after a Ctrl-w switch: didChange edits
    /// and lsp_synced_rev bookkeeping would target the wrong file, and the
    /// newly focused buffer's diagnostics/hints/hover would silently go
    /// stale or missing (its server copy never sees the edits).
    pub fn switchWindowTo(self: *App, i: usize) void {
        const b = self.windows.items[i].buf;
        const changed = b != self.current;
        self.current_win = i;
        if (changed) {
            self.current = b;
            self.ensureLsp();
            // the newly focused window's cursor/viewport already belong to
            // this buffer (it has been showing it) — nothing to clamp
            self.invalidateInlayHints();
            self.clearDiagnostics();
            self.clearHover();
            self.nav_list_active = false;
            self.freeGrepPreview();
            self.closeCompletion();
            self.closeGitPreview();
            self.scheduleGitStatus();
        }
        self.visual_anchor = null;
        self.in_insert = false;
        self.state.mode = .normal;
    }

    /// Direction for window navigation / buffer moves (Ctrl-w hjkl family).
    pub const WinDir = enum { left, right, up, down };

    /// The leaf window geometrically in `dir` from the focused one (nearest,
    /// preferring windows that overlap the current one — vim's Ctrl-w hjkl
    /// targeting). null when there is no window that way (or only one).
    pub fn neighborWindow(self: *App, dir: WinDir) ?usize {
        if (self.windows.items.len <= 1) return null;
        const height: u32 = self.vx.window().height;
        if (height <= status_row_count) return null;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const content_rows = height - status_row_count - self.tabBarRows(a);
        const layout = self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), self.vx.window().width) catch return null;
        const leaves = layout.leaves;
        var cur_rect: ?LeafRect = null;
        for (leaves) |lr| {
            if (lr.win == self.current_win) {
                cur_rect = lr;
                break;
            }
        }
        const cr = cur_rect orelse return null;
        var best: ?usize = null;
        var best_score: i64 = std.math.maxInt(i64);
        for (leaves) |lr| {
            if (lr.win == self.current_win) continue;
            const in_dir = switch (dir) {
                .left => lr.col + lr.width <= cr.col,
                .right => lr.col >= cr.col + cr.width,
                .up => lr.row + lr.height <= cr.row,
                .down => lr.row >= cr.row + cr.height,
            };
            if (!in_dir) continue;
            const dx = @as(i64, @intCast(lr.col + lr.width / 2)) - @as(i64, @intCast(cr.col + cr.width / 2));
            const dy = @as(i64, @intCast(lr.row + lr.height / 2)) - @as(i64, @intCast(cr.row + cr.height / 2));
            const adx: i64 = if (dx < 0) -dx else dx;
            const ady: i64 = if (dy < 0) -dy else dy;
            const score: i64 = switch (dir) {
                .left, .right => adx * 2 + ady,
                .up, .down => ady * 2 + adx,
            };
            if (score < best_score) {
                best_score = score;
                best = lr.win;
            }
        }
        return best;
    }

    /// Ctrl-w hjkl: move focus to the leaf window geometrically in `dir`.
    pub fn navigateWindow(self: *App, dir: WinDir) void {
        if (self.neighborWindow(dir)) |b| self.switchWindowTo(b);
    }

    /// <leader>bh / <leader>bl — move the current buffer to the window on the
    /// left/right (vertical splits): the neighbor window adopts the buffer;
    /// the current window falls back to the next buffer in the list, or
    /// closes when the moved buffer was the last one (nothing left to show).
    pub fn moveBufferToWindow(self: *App, dir: WinDir) void {
        const target = self.neighborWindow(dir) orelse return;
        const moved = self.windows.items[self.current_win].buf;
        // the neighbor adopts the moved buffer (its old buffer stays open in
        // the list); its cursor is clamped to the new text
        self.windows.items[target].buf = moved;
        // …and the moved buffer's tab belongs to the neighbor's pane
        self.buffers.items[moved].last_win = target;
        const mlen = self.buffers.items[moved].pt.len();
        self.windows.items[target].cursor = @min(self.windows.items[target].cursor, mlen);
        if (self.buffers.items.len <= 1) {
            // the last buffer left this window — nothing else to show:
            // close the window (focus moves to a surviving leaf)
            self.closeWindow();
            return;
        }
        // the current window shows the next buffer instead — switchTo does
        // the assignment plus the per-buffer state cleanup (LSP retarget,
        // inlay/diagnostic/hover invalidation, git status refresh)
        self.switchTo((moved + 1) % self.buffers.items.len);
    }
    pub fn create(init: std.process.Init) !*App {
        const self = try init.gpa.create(App);
        errdefer init.gpa.destroy(self);

        const tty_buffer = try init.gpa.alloc(u8, 4096);
        errdefer init.gpa.free(tty_buffer);
        var tty = vaxis.Tty.init(init.io, tty_buffer) catch |e| {
            init.gpa.free(tty_buffer);
            std.process.fatal("oz: tty init failed: {s}", .{@errorName(e)});
        };
        const opts: vaxis.Vaxis.Options = .{
            .kitty_keyboard_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_alternate_keys = true,
                .report_all_as_ctl_seqs = true,
                .report_text = true,
            },
            .system_clipboard_allocator = init.gpa,
        };
        var vx = try vaxis.init(init.io, init.gpa, init.environ_map, opts);
        errdefer vx.deinit(init.gpa, tty.writer());

        self.* = .{
            .io = init.io,
            .alloc = init.gpa,
            .env_map = init.environ_map,
            .theme = theme.default,
            .vx = vx,
            .tty = tty,
            .tty_buffer = tty_buffer,
            .loop = undefined,
            .state = editor.Mode.State.init(),
            .buffers = .empty,
            .cmdline = .empty,
            .cmd_history = .empty,
            .mc = editor.MultiCursor.init(init.gpa),
            .picker_files = .empty,
            .picker_input = .empty,
            .picker_matches = .empty,
        };
        try self.buffers.append(init.gpa, .{
            .pt = try buffer.PieceTable.init(init.gpa, ""),
            .history = buffer.History.init(init.gpa),
        });
        // one window showing buffer 0 (the initial empty buffer)
        try self.windows.append(init.gpa, .{ .buf = 0 });
        const leaf = try init.gpa.create(WinNode);
        leaf.* = .{ .leaf = 0 };
        self.win_root = leaf;
        errdefer init.gpa.destroy(leaf);
        // NOTE: loop holds pointers to self.tty / self.vx, so the App must
        // stay at a stable address (heap) — never move it after this.
        self.loop = vaxis.Loop(vaxis.Event).init(init.io, &self.tty, &self.vx);
        try self.loop.installResizeHandler();
        return self;
    }

    pub fn destroy(self: *App) void {
        self.deinit();
        self.alloc.destroy(self);
    }

    pub fn deinit(self: *App) void {
        self.loop.stop();
        // An in-flight LSP attach must be cancelled and joined before the
        // pieces it borrows (env_map, io, the vaxis loop its wake posts to)
        // go away.
        self.cancelLspStart();
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.alloc.free(self.tty_buffer);
        for (self.buffers.items) |*buf| {
            buf.history.deinit();
            buf.pt.deinit();
            buf.folds.deinit(self.alloc);
            if (buf.spans_cache.len > 0) self.alloc.free(buf.spans_cache);
            if (buf.hl) |*h| h.deinit();
            if (buf.span_cache) |*sc| self.alloc.free(sc.spans);
            if (buf.path) |p| self.alloc.free(p);
        }
        self.buffers.deinit(self.alloc);
        if (self.win_root) |root| self.freeWinTree(root);
        self.windows.deinit(self.alloc);
        self.cmdline.deinit(self.alloc);
        for (self.cmd_history.items) |h| self.alloc.free(h);
        self.cmd_history.deinit(self.alloc);
        for (self.cmd_complete_names.items) |n| self.alloc.free(n);
        self.cmd_complete_names.deinit(self.alloc);
        if (self.msg) |m| self.alloc.free(m);
        if (self.last_search) |q| self.alloc.free(q);
        if (self.yank_buffer) |b| self.alloc.free(b);
        if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
        self.mc.deinit();
        if (self.filetree_root) |root| self.freeFiletreeNode(root);
        self.filetree_rows.deinit(self.alloc);
        for (self.recent_files.items) |f| self.alloc.free(f);
        self.recent_files.deinit(self.alloc);
        for (self.picker_files.items) |f| self.alloc.free(f);
        self.picker_files.deinit(self.alloc);
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.deinit(self.alloc);
        if (self.preview_hl) |*h| h.deinit();
        if (self.preview_text) |t| self.alloc.free(t);
        if (self.preview_path) |p| self.alloc.free(p);
        self.picker_input.deinit(self.alloc);
        self.picker_matches.deinit(self.alloc);
        if (self.lsp_client) |c| c.deinit();
        for (self.lsp_diagnostics.items) |*d| self.alloc.free(d.message);
        self.lsp_diagnostics.deinit(self.alloc);
        if (self.nav_slot) |*v| json_rpc.freeValue(self.alloc, v);
        if (self.nav_hover_text) |t| self.alloc.free(t);
        for (self.nav_locations.items) |*l| self.alloc.free(l.uri);
        self.nav_locations.deinit(self.alloc);
        if (self.completion_slot) |*v| json_rpc.freeValue(self.alloc, v);
        if (self.format_slot) |*v| json_rpc.freeValue(self.alloc, v);
        if (self.inlay_slot) |*v| json_rpc.freeValue(self.alloc, v);
        if (self.outline_slot) |*v| json_rpc.freeValue(self.alloc, v);
        for (self.inlay_hints.items) |*h| self.alloc.free(h.label);
        self.inlay_hints.deinit(self.alloc);
        for (self.completion_words.items) |it| self.alloc.free(it.text);
        self.completion_words.deinit(self.alloc);
        // M3a git state
        if (self.git_job) |job| {
            if (job.thread) |t| t.join(); // let the worker finish, then free
            self.alloc.free(job.path);
            self.alloc.free(job.cwd);
            if (job.work_path) |w| {
                std.Io.Dir.cwd().deleteFile(self.io, w) catch {};
                self.alloc.free(w);
            }
            if (job.out) |o| self.alloc.free(o);
            if (job.branch) |b| self.alloc.free(b);
            if (job.msg) |m| self.alloc.free(m);
            self.alloc.destroy(job);
        }
        if (self.git_branch) |b| self.alloc.free(b);
        if (self.git_diff_path) |p| self.alloc.free(p);
        if (self.git_queued) |q| self.alloc.free(q.path);
        self.git_diff.deinit(self.alloc);
        self.clearBlameGhostLabel();
        if (self.git_blame) |*b| b.deinit(self.alloc);
        if (self.git_blame_path) |bp| self.alloc.free(bp);
        if (self.git_preview) |p| self.alloc.free(p.text);
        // M3b embedded terminal (kills the child, joins the reader thread)
        if (term.supported) {
            if (self.term_pane) |*tp| {
                tp.t.destroy();
                if (tp.title) |x| self.alloc.free(x);
            }
        }
    }

    // ------------------------------------------------------------------
    // Domain aliases: method/type bodies live in src/app/<domain>.zig
    // (physical split of the original src/main.zig; decl aliases keep the
    // original call sites working unchanged).
    // ------------------------------------------------------------------
    // ---- dashboard → src/app/dashboard.zig ----
    pub const isDashboard = @import("app/dashboard.zig").isDashboard;
    pub const dashboardKey = @import("app/dashboard.zig").dashboardKey;
    pub const addRecent = @import("app/dashboard.zig").addRecent;
    // ---- easymotion → src/app/easymotion.zig ----
    pub const handleEasyMotionKey = @import("app/easymotion.zig").handleEasyMotionKey;
    pub const endEasyMotion = @import("app/easymotion.zig").endEasyMotion;
    pub const deleteBeforeCursor = @import("app/easymotion.zig").deleteBeforeCursor;
    pub const deleteWordBefore = @import("app/easymotion.zig").deleteWordBefore;
    // ---- number → src/app/number.zig ----
    pub const isDigitByte = @import("app/number.zig").isDigitByte;
    pub const numberAtDigit = @import("app/number.zig").numberAtDigit;
    pub const numberAtOrAfter = @import("app/number.zig").numberAtOrAfter;
    pub const firstNumberInLine = @import("app/number.zig").firstNumberInLine;
    pub const replaceNumber = @import("app/number.zig").replaceNumber;
    pub const execNumberDeltaAtCursor = @import("app/number.zig").execNumberDeltaAtCursor;
    pub const execSelectionNumberDelta = @import("app/number.zig").execSelectionNumberDelta;
    pub const execSelectionNumberColumn = @import("app/number.zig").execSelectionNumberColumn;
    pub const pasteBuffer = @import("app/number.zig").pasteBuffer;
    pub const Number = @import("app/number.zig").Number;
    // ---- diagnostics → src/app/diagnostics.zig ----
    pub const gotoDiagnostic = @import("app/diagnostics.zig").gotoDiagnostic;
    pub const showLineDiagnostics = @import("app/diagnostics.zig").showLineDiagnostics;
    pub const toggleDiagnosticsList = @import("app/diagnostics.zig").toggleDiagnosticsList;
    pub const diagnosticsListKey = @import("app/diagnostics.zig").diagnosticsListKey;
    // ---- navigation → src/app/navigation.zig ----
    pub const requestNav = @import("app/navigation.zig").requestNav;
    pub const processNav = @import("app/navigation.zig").processNav;
    pub const clearNavOverlays = @import("app/navigation.zig").clearNavOverlays;
    pub const clearHover = @import("app/navigation.zig").clearHover;
    pub const jumpToLocation = @import("app/navigation.zig").jumpToLocation;
    pub const navListKey = @import("app/navigation.zig").navListKey;
    // ---- terminal → src/app/terminal.zig ----
    pub const termCwd = @import("app/terminal.zig").termCwd;
    pub const termRect = @import("app/terminal.zig").termRect;
    pub const drawTerm = @import("app/terminal.zig").drawTerm;
    pub const toggleTerm = @import("app/terminal.zig").toggleTerm;
    pub const closeTerm = @import("app/terminal.zig").closeTerm;
    pub const handleTerminalKey = @import("app/terminal.zig").handleTerminalKey;
    pub const launchLazygit = @import("app/terminal.zig").launchLazygit;
    // ---- git → src/app/git.zig ----
    pub const spawnGitJob = @import("app/git.zig").spawnGitJob;
    pub const consumeGitJob = @import("app/git.zig").consumeGitJob;
    pub const finishGitJob = @import("app/git.zig").finishGitJob;
    pub const scheduleGitStatus = @import("app/git.zig").scheduleGitStatus;
    pub const gitMarksStaleNow = @import("app/git.zig").gitMarksStaleNow;
    pub const gitRefreshSoon = @import("app/git.zig").gitRefreshSoon;
    pub const gitShiftForEdit = @import("app/git.zig").gitShiftForEdit;
    pub const gitShiftInsertAt = @import("app/git.zig").gitShiftInsertAt;
    pub const snapshotGitWork = @import("app/git.zig").snapshotGitWork;
    pub const gotoHunk = @import("app/git.zig").gotoHunk;
    pub const applyHunk = @import("app/git.zig").applyHunk;
    pub const previewHunk = @import("app/git.zig").previewHunk;
    pub const showHunkPreview = @import("app/git.zig").showHunkPreview;
    pub const gitPreviewKey = @import("app/git.zig").gitPreviewKey;
    pub const closeGitPreview = @import("app/git.zig").closeGitPreview;
    pub const toggleBlame = @import("app/git.zig").toggleBlame;
    pub const clearBlameGhostLabel = @import("app/git.zig").clearBlameGhostLabel;
    pub const clearSpanCache = @import("app/git.zig").clearSpanCache;
    pub const maybeLoadBlame = @import("app/git.zig").maybeLoadBlame;
    // ---- buffers → src/app/buffers.zig ----
    pub const switchTo = @import("app/buffers.zig").switchTo;
    pub const switchBuffer = @import("app/buffers.zig").switchBuffer;
    pub const targetWindowForOpen = @import("app/buffers.zig").targetWindowForOpen;
    pub const loadPieceTable = @import("app/buffers.zig").loadPieceTable;
    pub const openInBuffer = @import("app/buffers.zig").openInBuffer;
    pub const teardownLsp = @import("app/buffers.zig").teardownLsp;
    pub const closeBufferAt = @import("app/buffers.zig").closeBufferAt;
    pub const closeCurrentBuffer = @import("app/buffers.zig").closeCurrentBuffer;
    pub const contentHash = @import("app/buffers.zig").contentHash;
    pub const beginInsertSession = @import("app/buffers.zig").beginInsertSession;
    pub const endInsertSession = @import("app/buffers.zig").endInsertSession;
    // ---- cmdline → src/app/cmdline.zig ----
    pub const handleCommandKey = @import("app/cmdline.zig").handleCommandKey;
    pub const completeCommandName = @import("app/cmdline.zig").completeCommandName;
    pub const completeCommandPath = @import("app/cmdline.zig").completeCommandPath;
    pub const clearCmdCompleteNames = @import("app/cmdline.zig").clearCmdCompleteNames;
    pub const pushHistory = @import("app/cmdline.zig").pushHistory;
    pub const loadHistory = @import("app/cmdline.zig").loadHistory;
    pub const execCommand = @import("app/cmdline.zig").execCommand;
    pub const execTheme = @import("app/cmdline.zig").execTheme;
    pub const loadTheme = @import("app/cmdline.zig").loadTheme;
    pub const saveTheme = @import("app/cmdline.zig").saveTheme;
    pub const execSubstitute = @import("app/cmdline.zig").execSubstitute;
    pub const listBuffers = @import("app/cmdline.zig").listBuffers;
    pub const setMsg = @import("app/cmdline.zig").setMsg;
    // ---- search → src/app/search.zig ----
    pub const execSearch = @import("app/search.zig").execSearch;
    pub const repeatSearch = @import("app/search.zig").repeatSearch;
    pub const findInPieces = @import("app/search.zig").findInPieces;
    pub const searchOnce = @import("app/search.zig").searchOnce;
    pub const leadingIndent = @import("app/search.zig").leadingIndent;
    pub const invalidateInlayHints = @import("app/search.zig").invalidateInlayHints;
    pub const adjustInlayHintsInsert = @import("app/search.zig").adjustInlayHintsInsert;
    pub const adjustInlayHintsDelete = @import("app/search.zig").adjustInlayHintsDelete;
    pub const lineHints = @import("app/search.zig").lineHints;
    pub const absolutePath = @import("app/search.zig").absolutePath;
    pub const writeBuffer = @import("app/search.zig").writeBuffer;
    pub const saveFile = @import("app/search.zig").saveFile;
    pub const openFile = @import("app/search.zig").openFile;
    pub const insertText = @import("app/search.zig").insertText;
    // ---- completion → src/app/completion.zig ----
    pub const isWordByte = @import("app/completion.zig").isWordByte;
    pub const containsIgnoreCase = @import("app/completion.zig").containsIgnoreCase;
    pub const kindGlyph = @import("app/completion.zig").kindGlyph;
    pub const startCompletion = @import("app/completion.zig").startCompletion;
    pub const requestLspCompletion = @import("app/completion.zig").requestLspCompletion;
    pub const isCompletionTriggerText = @import("app/completion.zig").isCompletionTriggerText;
    pub const maybeAutoComplete = @import("app/completion.zig").maybeAutoComplete;
    pub const processCompletion = @import("app/completion.zig").processCompletion;
    // ---- block_insert → src/app/block_insert.zig ----
    pub const charBoundaryForward = @import("app/block_insert.zig").charBoundaryForward;
    pub const charLenAt = @import("app/block_insert.zig").charLenAt;
    pub const blockRect = @import("app/block_insert.zig").blockRect;
    pub const applyBlockOp = @import("app/block_insert.zig").applyBlockOp;
    pub const blockInsert = @import("app/block_insert.zig").blockInsert;
    pub const placeBlockCursors = @import("app/block_insert.zig").placeBlockCursors;
    pub const handleMcInsertKey = @import("app/block_insert.zig").handleMcInsertKey;
    pub const mcInsertText = @import("app/block_insert.zig").mcInsertText;
    pub const mcBackspace = @import("app/block_insert.zig").mcBackspace;
    pub const mcDeleteWordBefore = @import("app/block_insert.zig").mcDeleteWordBefore;
    pub const exitMcInsert = @import("app/block_insert.zig").exitMcInsert;
    pub const mcSyncCursor = @import("app/block_insert.zig").mcSyncCursor;
    pub const BlockRect = @import("app/block_insert.zig").BlockRect;
    // ---- editing → src/app/editing.zig ----
    pub const pairCloser = @import("app/editing.zig").pairCloser;
    pub const autoPairInsert = @import("app/editing.zig").autoPairInsert;
    pub const autoPairBackspace = @import("app/editing.zig").autoPairBackspace;
    pub const setRegister = @import("app/editing.zig").setRegister;
    pub const applyOpRange = @import("app/editing.zig").applyOpRange;
    pub const applyOpRangeEx = @import("app/editing.zig").applyOpRangeEx;
    pub const execSurround = @import("app/editing.zig").execSurround;
    pub const surroundRange = @import("app/editing.zig").surroundRange;
    pub const execAlign = @import("app/editing.zig").execAlign;
    pub const applyEdit = @import("app/editing.zig").applyEdit;
    pub const isVisual = @import("app/editing.zig").isVisual;
    pub const toggleCommentLine = @import("app/editing.zig").toggleCommentLine;
    pub const exitVisual = @import("app/editing.zig").exitVisual;
    pub const exitVisualAfterOp = @import("app/editing.zig").exitVisualAfterOp;
    pub const mcSelectNext = @import("app/editing.zig").mcSelectNext;
    pub const mcChangeWords = @import("app/editing.zig").mcChangeWords;
    pub const SelEnd = @import("app/editing.zig").SelEnd;
    // ---- filetree → src/app/filetree.zig ----
    pub const toggleFiletree = @import("app/filetree.zig").toggleFiletree;
    pub const walkTreeLevel = @import("app/filetree.zig").walkTreeLevel;
    pub const sortTreeChildren = @import("app/filetree.zig").sortTreeChildren;
    pub const expandDir = @import("app/filetree.zig").expandDir;
    pub const collapseDir = @import("app/filetree.zig").collapseDir;
    pub const rebuildFiletreeRows = @import("app/filetree.zig").rebuildFiletreeRows;
    pub const appendTreeRows = @import("app/filetree.zig").appendTreeRows;
    pub const filetreeNodeAt = @import("app/filetree.zig").filetreeNodeAt;
    pub const rowIndexOf = @import("app/filetree.zig").rowIndexOf;
    pub const locateInFiletree = @import("app/filetree.zig").locateInFiletree;
    pub const revealPath = @import("app/filetree.zig").revealPath;
    pub const filetreeKey = @import("app/filetree.zig").filetreeKey;
    pub const freeFiletreeNode = @import("app/filetree.zig").freeFiletreeNode;
    pub const TreeNode = @import("app/filetree.zig").TreeNode;
    pub const FiletreeRow = @import("app/filetree.zig").FiletreeRow;
    // ---- lsp_edit → src/app/lsp_edit.zig ----
    pub const requestRename = @import("app/lsp_edit.zig").requestRename;
    pub const execRename = @import("app/lsp_edit.zig").execRename;
    pub const freeSimpleDocParams = @import("app/lsp_edit.zig").freeSimpleDocParams;
    pub const requestFormat = @import("app/lsp_edit.zig").requestFormat;
    pub const processFormat = @import("app/lsp_edit.zig").processFormat;
    pub const requestInlayHints = @import("app/lsp_edit.zig").requestInlayHints;
    pub const processInlay = @import("app/lsp_edit.zig").processInlay;
    pub const requestOutline = @import("app/lsp_edit.zig").requestOutline;
    pub const processOutline = @import("app/lsp_edit.zig").processOutline;
    pub const collectCompletionWords = @import("app/lsp_edit.zig").collectCompletionWords;
    pub const countCompletionWord = @import("app/lsp_edit.zig").countCompletionWord;
    pub const acceptCompletion = @import("app/lsp_edit.zig").acceptCompletion;
    pub const closeCompletion = @import("app/lsp_edit.zig").closeCompletion;
    pub const insertNewline = @import("app/lsp_edit.zig").insertNewline;
    pub const deleteToEol = @import("app/lsp_edit.zig").deleteToEol;
    // ---- lsp → src/app/lsp.zig ----
    pub const ensureLsp = @import("app/lsp.zig").ensureLsp;
    pub const lspStartMain = @import("app/lsp.zig").lspStartMain;
    pub const cancelLspStart = @import("app/lsp.zig").cancelLspStart;
    pub const finishLspStart = @import("app/lsp.zig").finishLspStart;
    pub const lspWake = @import("app/lsp.zig").lspWake;
    pub const curText = @import("app/lsp.zig").curText;
    pub const lspPositionAt = @import("app/lsp.zig").lspPositionAt;
    pub const utf16Units = @import("app/lsp.zig").utf16Units;
    pub const clearDiagnostics = @import("app/lsp.zig").clearDiagnostics;
    pub const lspHandler = @import("app/lsp.zig").lspHandler;
    pub const markDirtyBase = @import("app/lsp.zig").markDirtyBase;
    pub const markDirty = @import("app/lsp.zig").markDirty;
    pub const markDirtyRange = @import("app/lsp.zig").markDirtyRange;
    pub const syncLspFull = @import("app/lsp.zig").syncLspFull;
    // ---- picker → src/app/picker.zig ----
    pub const openPicker = @import("app/picker.zig").openPicker;
    pub const walkDir = @import("app/picker.zig").walkDir;
    pub const walkInto = @import("app/picker.zig").walkInto;
    pub const openBufferPicker = @import("app/picker.zig").openBufferPicker;
    pub const openRecentPicker = @import("app/picker.zig").openRecentPicker;
    pub const openKeymapPicker = @import("app/picker.zig").openKeymapPicker;
    pub const openThemePicker = @import("app/picker.zig").openThemePicker;
    pub const bufferName = @import("app/picker.zig").bufferName;
    pub const openGrepPicker = @import("app/picker.zig").openGrepPicker;
    pub const runGrep = @import("app/picker.zig").runGrep;
    pub const freeGrepPreview = @import("app/picker.zig").freeGrepPreview;
    pub const refreshGrepPreview = @import("app/picker.zig").refreshGrepPreview;
    pub const refreshNavPreview = @import("app/picker.zig").refreshNavPreview;
    pub const loadPreview = @import("app/picker.zig").loadPreview;
    pub const renderGrepPreviewRow = @import("app/picker.zig").renderGrepPreviewRow;
    pub const handlePickerKey = @import("app/picker.zig").handlePickerKey;
    pub const applyThemePreview = @import("app/picker.zig").applyThemePreview;
    pub const pickerRefilter = @import("app/picker.zig").pickerRefilter;
    pub const closePicker = @import("app/picker.zig").closePicker;
    pub const GrepResult = @import("app/picker.zig").GrepResult;
    // ---- input → src/app/input.zig ----
    pub const handleKey = @import("app/input.zig").handleKey;
    pub const exitInsert = @import("app/input.zig").exitInsert;
    // ---- highlight → src/app/highlight.zig ----
    pub const visibleSpansFor = @import("app/highlight.zig").visibleSpansFor;
    pub const loadRecent = @import("app/highlight.zig").loadRecent;
    pub const saveRecent = @import("app/highlight.zig").saveRecent;
    pub const execOpMotion = @import("app/highlight.zig").execOpMotion;
    pub const execAction = @import("app/highlight.zig").execAction;
    pub const replaceCharsAtCursor = @import("app/highlight.zig").replaceCharsAtCursor;
    // ---- render → src/app/render.zig ----
    pub const tabBarRows = @import("app/render.zig").tabBarRows;
    pub const contentTop = @import("app/render.zig").contentTop;
    pub const contentCol = @import("app/render.zig").contentCol;
    pub const gutterWidth = @import("app/render.zig").gutterWidth;
    pub const lineCellCol = @import("app/render.zig").lineCellCol;
    pub const textWidth = @import("app/render.zig").textWidth;
    pub const utf16Column = @import("app/render.zig").utf16Column;
    pub const byteColumnFromUtf16 = @import("app/render.zig").byteColumnFromUtf16;
    pub const screenCellCol = @import("app/render.zig").screenCellCol;
    pub const isBlankLine = @import("app/render.zig").isBlankLine;
    pub const lineIndentLevels = @import("app/render.zig").lineIndentLevels;
    pub const blankContextLevels = @import("app/render.zig").blankContextLevels;
    pub const renderWindowLines = @import("app/render.zig").renderWindowLines;
    pub const hoverFenceSegs = @import("app/render.zig").hoverFenceSegs;
    pub const hoverCodeLineSegs = @import("app/render.zig").hoverCodeLineSegs;
    pub const hoverLineSegs = @import("app/render.zig").hoverLineSegs;
    pub const render = @import("app/render.zig").render;
    pub const blameHoldActive = @import("app/render.zig").blameHoldActive;
    pub const gitHoldActive = @import("app/render.zig").gitHoldActive;
    pub const scopeAnimActive = @import("app/render.zig").scopeAnimActive;
    pub const run = @import("app/render.zig").run;
    pub const filetree_width = @import("app/render.zig").filetree_width;
    pub const TabSort = @import("app/render.zig").TabSort;
};
