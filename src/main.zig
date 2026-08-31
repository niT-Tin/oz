//! oz entry point: vaxis event loop + M0 integration (DESIGN.md §5).
//!
//! Loop:
//!   nextEvent → Mode state machine → execute result against PieceTable
//!   → render frame (line numbers + text + status bar) → vaxis diff output.
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

/// Cells a '\t' occupies on screen (vim's shiftwidth-style expansion). The
/// renderer expands tabs to this many spaces; every width computation that
/// positions the cursor/ghost/menu must use the same value or columns drift.
const tab_width: u32 = 4;

// Silence vaxis's per-frame debug logging (pollutes the tty byte stream and
// interferes with e2e screen reconstruction).
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .err }},
};

const status_row_count: u32 = 1;

/// Current-line blame CursorHold delay (ms) — nvim updatetime-style; the
/// ghost appears this long after the cursor settles (<leader>tb).
const blame_hold_ms: i64 = 1000;

/// Files larger than this skip current-line blame entirely (gitsigns'
/// max_file_length — blame on huge files is slow and useless).
const max_blame_lines: u32 = 40000;

/// LSP navigation request kinds (K / gd / gD / gr / gI / gs).
const NavAction = enum { none, hover, definition, declaration, references, implementation, signature };

/// An inlay hint: dim label shown inline at (line, character).
const InlayHint = struct { line: u32, character: u32, label: []const u8 };

// ---- M3a git: async job plumbing (types live at file scope so the worker
// thread functions — which are NOT App methods — can reference them) ----

const GitJobKind = enum { status, blame, apply };
const GitApplyOp = enum { stage, reset };

/// A git job requested while the single job slot was busy — re-spawned
/// verbatim when the slot frees (path owned).
const QueuedGitJob = struct {
    kind: GitJobKind,
    path: []u8, // owned
    hunk_start: u32,
    op: GitApplyOp,
};

/// One async git job: the worker thread spawns git, captures stdout/stderr,
/// fills the result fields and flips `done` (release); the main loop
/// consumes it (acquire) and joins the thread. Result fields are written by
/// the thread BEFORE `done.store(true)` — no locking needed. Output buffers
/// are owned by the job and freed by finishGitJob (after the App moved out
/// what it keeps).
const GitJob = struct {
    kind: GitJobKind,
    path: []u8, // owned (relative path, as git wants it)
    /// apply: 0-based final-file line where the target hunk STARTS (from the
    /// user's diff view). The worker re-diffs and locates the hunk by this
    /// line — a stale INDEX would otherwise pick the wrong hunk when the
    /// working tree changed between the view and the apply.
    hunk_start: u32 = 0,
    op: GitApplyOp = .stage,
    alloc: std.mem.Allocator,
    io: std.Io,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    out: ?[]u8 = null, // status: diff output; blame: blame output
    branch: ?[]u8 = null, // status: current branch (null = not a repo)
    untracked: bool = false, // status: file untracked ("??")
    msg: ?[]u8 = null, // apply: result message
    thread: ?std.Thread = null,
    /// Wake callback invoked from the worker thread when the job lands —
    /// posts an event so the main loop (blocked in pollEvent) wakes and
    /// drains the job without waiting for a keypress.
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (ctx: *anyopaque) void = null,
};

/// Hunk preview float (<leader>hp): the raw patch text of the hunk under
/// the cursor, shown in a floating window until Esc/Enter/q.
const GitPreview = struct {
    text: []u8, // owned (patch)
    top: usize, // scroll offset
};

/// Pending 'r{char}' capture: the count from '3r', the char filled when the
/// next plain key arrives (normal mode only).
const ReplacePending = struct {
    count: u32 = 1,
    ch: u8 = 0,
};

/// Outward scope-highlight animation (snacks.indent.animate style "out"):
/// when the focused window's scope block changes, the highlight spreads from
/// the cursor line to the scope edges over `duration_ms` (linear, ~500ms —
/// "slow but not too slow"). The run loop polls while active so the spread
/// advances frame by frame without keypresses.
const ScopeAnim = struct {
    start_line: u32,
    end_line: u32,
    cursor_line: u32,
    start_ms: i128, // monotonic clock, ms
    const duration_ms: i128 = 500;
};

const App = struct {
    /// One open document. `pt`/`history` own their allocations; the struct is
    /// moved between the list and the active slots (never copied-and-deinit'd).
    /// Cursor/viewport live in Window — the same buffer may be shown in
    /// several split windows with independent cursors.
    const Buffer = struct {
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
        /// Closed folds (indent-detected, see editor/fold.zig), sorted by
        /// start line. Kept PER BUFFER, not per window: two splits showing
        /// the same buffer share the fold state, so za in one split is
        /// visible in the other (folds are a property of the document view
        /// of the buffer, like the dirty flag). Any edit clears the set
        /// (markDirty) — line numbers drift after edits, and re-folding is
        /// cheap; vim-style fold carryover across edits is out of scope.
        folds: std.ArrayList(editor.fold.Range) = .empty,
    };

    /// One split window: which buffer it shows plus its own cursor/viewport.
    const Window = struct {
        buf: usize = 0,
        cursor: u32 = 0,
        view_top: u32 = 0,
    };

    /// Split orientation (vim: :sp = horizontal split = stacked rows,
    /// :vs = vertical split = side-by-side columns).
    const SplitDir = enum { horizontal, vertical };

    /// Window layout tree. Leaves index into `windows`; splits divide the
    /// screen rectangle between two subtrees.
    const WinNode = union(enum) {
        leaf: usize,
        split: struct {
            dir: SplitDir,
            a: *WinNode,
            b: *WinNode,
        },
    };

    const GrepResult = struct { path: []u8, line: u32, text: []u8 };

    /// One node of the lazy directory tree (snacks-explorer style). `name`
    /// (basename) and `path` (relative, owned; dir paths carry a trailing
    /// '/') are owned by the node. Children are populated only when a dir is
    /// expanded; collapsed dirs keep their loaded children (cheap re-expand).
    const TreeNode = struct {
        name: []u8,
        path: []u8,
        is_dir: bool,
        expanded: bool,
        children: std.ArrayList(*TreeNode),
        parent: ?*TreeNode,
    };
    /// One visible sidebar row: the node plus its DFS depth (for indent).
    const FiletreeRow = struct { node: *TreeNode, depth: usize };

    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    /// Active color theme (from OZ_THEME, switchable at runtime).
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
    // grep picker split preview: the selected result's file content plus its
    // tree-sitter highlighter, rebuilt only when the selection's path changes
    // (never per-frame). preview_text == null means unavailable (>SIZE_LIMIT
    // or read failed) — the panel shows a "preview unavailable" hint.
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
    /// Auto-requested for the visible range whenever the view scrolls.
    inlay_hints: std.ArrayList(InlayHint) = .empty,
    inlay_view_top: ?u32 = null,
    /// Scope-highlight animation state (null when idle / no scope). Restarted
    /// whenever the focused window's scope block changes; see ScopeAnim.
    scope_anim: ?ScopeAnim = null,
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

    /// The active buffer (the focused window's buffer; per-buffer document
    /// state lives here, per-window cursor/viewport in `windows`).
    fn cur(self: *App) *Buffer {
        return &self.buffers.items[self.windows.items[self.current_win].buf];
    }

    /// The focused window's cursor (byte offset in its buffer).
    fn curCursor(self: *App) *u32 {
        return &self.windows.items[self.current_win].cursor;
    }

    /// The focused window's viewport top (first visible line).
    fn curViewTop(self: *App) *u32 {
        return &self.windows.items[self.current_win].view_top;
    }

    /// Height (in text rows) of the focused window's leaf rect. Runs the same
    /// layout math as render() so H/M/L and zz/zt/zb agree with what's on
    /// screen, including splits.
    fn focusedWinHeight(self: *App) u32 {
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
    fn viewMotionTargetLine(self: *App, motion: editor.Motion.Motion) ?u32 {
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
    fn scrollCursorTo(self: *App, where: enum { top, center, bottom }) void {
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
    fn foldAt(buf: *const Buffer, line: u32) ?editor.fold.Range {
        for (buf.folds.items) |f| {
            if (f.start == line) return f;
        }
        return null;
    }

    /// The outermost closed fold whose hidden body contains `line`
    /// (start < line <= end), if any.
    fn foldCovering(buf: *const Buffer, line: u32) ?editor.fold.Range {
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
    fn foldNextLine(buf: *const Buffer, line: u32) u32 {
        if (foldAt(buf, line)) |f| return f.end + 1;
        return line + 1;
    }

    /// Previous visible line before `line`; lands on a fold's header, never
    /// inside a hidden body.
    fn foldPrevLine(buf: *const Buffer, line: u32) u32 {
        if (line == 0) return 0;
        var l = line - 1;
        if (foldCovering(buf, l)) |f| l = f.start;
        return l;
    }

    /// Snap `pos` out of a closed fold's hidden body onto the header line
    /// (keeping the column); no-op when the line is visible.
    fn foldSnapPos(buf: *const Buffer, pos: u32) u32 {
        const line = buf.pt.lineOf(pos);
        const f = foldCovering(buf, line) orelse return pos;
        return editor.Motion.toLineKeepCol(&buf.pt, pos, f.start);
    }

    /// za/zo/zc/zR/zM. The fold set is per-buffer (shared between splits);
    /// `range`/detection is indent-based via editor.fold.
    fn execFold(self: *App, action: editor.KeyEvent.ActionId) !void {
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
    fn snapCursorOutOfFold(self: *App) void {
        const w = &self.windows.items[self.current_win];
        const buf = &self.buffers.items[w.buf];
        w.cursor = foldSnapPos(buf, w.cursor);
    }

    /// Free a window tree (recursive).
    fn freeWinTree(self: *App, node: *WinNode) void {
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
    fn winTreeSanity(self: *App) void {
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
    fn splitWindow(self: *App, dir: SplitDir) !void {
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
    fn replaceLeaf(self: *App, node: *WinNode, leaf_idx: usize, dir: SplitDir, new_idx: usize) !void {
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
    fn removeWindow(self: *App, root: *WinNode, leaf_idx: usize) ?*WinNode {
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
    fn firstLeaf(self: *App, node: *WinNode) usize {
        return switch (node.*) {
            .leaf => |i| i,
            .split => |s| self.firstLeaf(s.a),
        };
    }

    /// After removing a window, decrement every leaf index above `removed`
    /// (the windows list was shifted down by one).
    fn adjustLeafIndices(self: *App, node: *WinNode, removed: usize) void {
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
    const LeafRect = struct {
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
    const SepRect = struct {
        row: u32,
        col: u32,
        len: u32,
        horizontal: bool,
        active: bool,
    };

    /// true when leaf `leaf` lives anywhere inside `node`'s subtree.
    fn subTreeHasLeaf(self: *App, node: *WinNode, leaf: usize) bool {
        return switch (node.*) {
            .leaf => |i| i == leaf,
            .split => |s| self.subTreeHasLeaf(s.a, leaf) or self.subTreeHasLeaf(s.b, leaf),
        };
    }

    /// Compute each leaf window's rectangle from the split tree, plus the
    /// separator lines between the panes (one per split node).
    fn layoutWindows(self: *App, a: std.mem.Allocator, content_top: u32, content_rows: u32, content_col: u32, total_width: u32) !struct { leaves: []LeafRect, seps: []SepRect } {
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

    fn layoutNode(self: *App, a: std.mem.Allocator, node: *WinNode, rect: LeafRect, out: *std.ArrayList(LeafRect), seps: *std.ArrayList(SepRect)) !void {
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
    fn closeWindow(self: *App) void {
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
        // sync the current buffer/highlighter with the surviving window
        const b = self.windows.items[self.current_win].buf;
        if (b != self.current) {
            self.current = b;
        }
        self.state.mode = .normal;
        self.visual_anchor = null;
        self.in_insert = false;
    }

    /// Last-window :q — vim behavior: closing the last window quits the
    /// editor (all buffers end together). Multi-window :q only closes the
    /// focused window (closeWindow's other branch).
    fn closeSingleWindow(self: *App) void {
        self.quit = true;
    }

    /// Make window `i` the focused one, syncing the current buffer and the
    /// highlighter (vim: the focused window's buffer is "the" current buffer).
    fn switchWindowTo(self: *App, i: usize) void {
        self.current_win = i;
        const b = self.windows.items[i].buf;
        if (b != self.current) {
            self.current = b;
        }
        self.visual_anchor = null;
        self.in_insert = false;
        self.state.mode = .normal;
    }

    /// Direction for window navigation / buffer moves (Ctrl-w hjkl family).
    const WinDir = enum { left, right, up, down };

    /// The leaf window geometrically in `dir` from the focused one (nearest,
    /// preferring windows that overlap the current one — vim's Ctrl-w hjkl
    /// targeting). null when there is no window that way (or only one).
    fn neighborWindow(self: *App, dir: WinDir) ?usize {
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
    fn navigateWindow(self: *App, dir: WinDir) void {
        if (self.neighborWindow(dir)) |b| self.switchWindowTo(b);
    }

    /// <leader>bh / <leader>bl — move the current buffer to the window on the
    /// left/right (vertical splits): the neighbor window adopts the buffer;
    /// the current window falls back to the next buffer in the list, or
    /// closes when the moved buffer was the last one (nothing left to show).
    fn moveBufferToWindow(self: *App, dir: WinDir) void {
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
    fn create(init: std.process.Init) !*App {
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
            .theme = theme.fromEnv(init.environ_map),
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

    fn destroy(self: *App) void {
        self.deinit();
        self.alloc.destroy(self);
    }

    fn deinit(self: *App) void {
        self.loop.stop();
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.alloc.free(self.tty_buffer);
        for (self.buffers.items) |*buf| {
            buf.history.deinit();
            buf.pt.deinit();
            buf.folds.deinit(self.alloc);
            if (buf.hl) |*h| h.deinit();
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
            if (job.out) |o| self.alloc.free(o);
            if (job.branch) |b| self.alloc.free(b);
            if (job.msg) |m| self.alloc.free(m);
            self.alloc.destroy(job);
        }
        if (self.git_branch) |b| self.alloc.free(b);
        if (self.git_diff_path) |p| self.alloc.free(p);
        if (self.git_queued) |q| self.alloc.free(q.path);
        self.git_diff.deinit(self.alloc);
        if (self.git_blame) |*b| b.deinit(self.alloc);
        if (self.git_blame_path) |bp| self.alloc.free(bp);
        if (self.git_preview) |p| self.alloc.free(p.text);
    }

    // ---- input ----

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // Command mode first: while the ':' command line is open, Enter/Esc
        // and the rest must reach it — the file-tree and picker overlays
        // would otherwise swallow Enter (opening a file / confirming) and
        // :q could never execute.
        if (self.state.mode == .command) {
            try self.handleCommandKey(key);
            return;
        }

        // Fuzzy picker input — the picker is a modal overlay, so its keys
        // must win over the file-tree sidebar (which sits behind it).
        if (self.picker_active) {
            try self.handlePickerKey(key);
            return;
        }

        // Diagnostics list overlay (<leader>sd)
        if (self.diag_list_active) {
            if (self.diagnosticsListKey(key)) return;
        }
        // Navigation location list overlay (gr / gI)
        if (self.nav_list_active) {
            if (self.navListKey(key)) return;
        }
        // Hunk preview float (<leader>hp): Esc/Enter/q close, j/k scroll
        if (self.git_preview != null) {
            if (self.gitPreviewKey(key)) return;
        }

        // A status message (e.g. "no candidates") lives until the next
        // keystroke, like vim's message line.
        if (self.msg) |m| {
            self.alloc.free(m);
            self.msg = null;
        }

        // Ctrl-w window commands: switch keyboard focus between split windows
        // (vim Ctrl-w hjkl geometric navigation) and the file-tree sidebar.
        // Not in insert mode — there Ctrl+w still deletes the word before it.
        if (key.codepoint == 'w' and key.mods.ctrl and self.state.mode != .insert) {
            self.pending_window = true;
            return;
        }
        if (self.pending_window) {
            self.pending_window = false;
            if (key.codepoint == vaxis.Key.escape) return;
            switch (key.codepoint) {
                // Vim Ctrl-w hjkl geometric navigation. The file-tree
                // sidebar is a full-height pane at column 0, so h from the
                // leftmost buffer window (or from the tree: nothing further
                // left) reaches it, l from the tree re-enters the buffer,
                // and j/k always move between buffer windows (the tree spans
                // every row; from it j/k enter the buffer). Previously h/l
                // only toggled tree ↔ current window, stranding the other
                // split windows unreachable.
                'h' => {
                    if (self.filetree_active and self.focus == .buffer) {
                        const before = self.current_win;
                        self.navigateWindow(.left);
                        if (self.current_win == before) self.focus = .filetree;
                    } else if (!self.filetree_active) {
                        self.navigateWindow(.left);
                    }
                    // from the tree (tree open, focus == .filetree) there is
                    // nothing further left
                },
                'l' => {
                    if (self.filetree_active and self.focus == .filetree) {
                        self.focus = .buffer;
                    } else {
                        self.navigateWindow(.right);
                    }
                },
                'j' => {
                    if (self.filetree_active and self.focus == .filetree) {
                        self.focus = .buffer;
                    } else {
                        self.navigateWindow(.down);
                    }
                },
                'k' => {
                    if (self.filetree_active and self.focus == .filetree) {
                        self.focus = .buffer;
                    } else {
                        self.navigateWindow(.up);
                    }
                },
                else => {},
            }
            return;
        }

        // File tree navigation (j/k/Enter/Esc); other keys fall through.
        // Only the focused pane reacts: with buffer focus the sidebar stays
        // visible but hjkl move the buffer cursor.
        if (self.filetree_active and self.focus == .filetree) {
            if (try self.filetreeKey(key)) return;
        }

        // Dashboard (no file open): j/k/Enter navigate recent files
        if (self.isDashboard()) {
            if (try self.dashboardKey(key)) return;
        }

        // EasyMotion capture: query char, then a label to jump to
        if (self.em_active) {
            try self.handleEasyMotionKey(key);
            return;
        }

        // r{char}: replace the character under the cursor. The first 'r'
        // (execAction .replace_char) sets pending_replace; the NEXT plain
        // key is the replacement character (normal mode only — in insert
        // mode 'r' is just a typed character).
        if (self.pending_replace) |pr| {
            if (self.state.mode != .insert and key.text != null and key.text.?.len > 0 and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super and
                key.codepoint != vaxis.Key.escape)
            {
                const ch = key.text.?[0];
                self.pending_replace = null;
                try self.replaceCharsAtCursor(ch, pr.count);
                return;
            }
            // Esc / anything else cancels the pending replace
            self.pending_replace = null;
        }

        // Esc cancels an active multi-cursor selection (word cursors). In
        // insert mode Esc exits the insert session instead (see below).
        if (self.mc_active and self.state.mode != .insert and key.codepoint == vaxis.Key.escape) {
            self.mc.clear();
            self.mc_active = false;
            return;
        }

        // 'd' with an active multi-cursor selection deletes the selected word
        // at every cursor (normal-mode 'd' would pend for a motion instead);
        // cursors sit at word starts, so the word is [pos, pos+wlen)
        if (self.mc_active and self.state.mode != .insert and key.codepoint == 'd' and !key.mods.ctrl and !key.mods.alt) {
            const w = self.mc.wordRange(&self.cur().pt, self.mc.cursors.items[self.mc.main]);
            if (w.end > w.start) {
                const wlen = w.end - w.start;
                self.cur().history.beginGroup();
                var i = self.mc.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const pos = self.mc.cursors.items[i];
                    try self.cur().history.record(&self.cur().pt, pos, wlen, "");
                }
                self.cur().history.endGroup();
                // LSP sync (same rule as every other edit): the server's
                // copy must follow the deletion.
                self.markDirty();
            }
            self.mc.clear();
            self.mc_active = false;
            return;
        }

        // 'n' with an active multi-cursor selection extends the selection:
        // add the next matching word — the plain-key twin of Ctrl+n (which
        // carries mods.ctrl and is handled by the keymap as .mc_add).
        if (self.mc_active and self.state.mode != .insert and !self.isVisual() and
            key.codepoint == 'n' and !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.mcSelectNext();
            return;
        }

        // 'c' with an active multi-cursor selection changes every selected
        // word: delete each word and enter insert mode with the cursors on
        // the word-start slots; every typed key then applies at all cursors
        // via handleMcInsertKey (like visual-block I/A insert).
        if (self.mc_active and self.state.mode != .insert and !self.isVisual() and
            key.codepoint == 'c' and !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.mcChangeWords();
            return;
        }

        // Visual block (<C-v>) then I/A: fan one insert cursor out per line
        // of the block and enter insert mode (vim visual-block insert).
        // Intercepted before the mode state machine, whose I/A would only
        // move the single main cursor.
        if (self.state.mode == .visual_block and self.visual_anchor != null and
            (key.codepoint == 'I' or key.codepoint == 'A') and
            !key.mods.ctrl and !key.mods.alt and !key.mods.super)
        {
            try self.blockInsert(key.codepoint == 'A');
            return;
        }

        // Insert mode: characters insert directly; jk exits (removing the
        // just-typed 'j'), backspace and Ctrl-w delete before the cursor.
        if (self.state.mode == .insert) {
            // Visual-block multi-cursor insert (I/A after <C-v>): every key
            // applies at every cursor. The single-cursor path below is
            // unchanged.
            if (self.mc_active) {
                try self.handleMcInsertKey(key);
                return;
            }
            // ---- insert-mode completion (Ctrl+n and auto-suggest) ----
            // Esc while the menu is open only dismisses it (stays in insert);
            // a second Esc exits the insert session as usual.
            if (self.completion_active and key.codepoint == vaxis.Key.escape) {
                self.closeCompletion();
                return;
            }
            // Ctrl+e: hide the menu (blink.cmp mapping), stay in insert.
            if (self.completion_active and key.codepoint == 'e' and key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                self.closeCompletion();
                return;
            }
            // Ctrl+n: next candidate when the menu is open; otherwise collect
            // candidates and open the menu — but only when the cursor is
            // inside a word. Without a word prefix the key is swallowed.
            // (Insert-mode completion only; in normal mode the keymap routes
            // Ctrl+n to multi-cursor .mc_add instead.)
            if (self.state.mode == .insert and key.codepoint == 'n' and key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                if (self.completion_active) {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + 1) % n;
                } else {
                    try self.startCompletion();
                }
                return;
            }
            if (self.completion_active) {
                // Ctrl+p / ↑: previous candidate; ↓: next candidate
                if ((key.codepoint == 'p' and key.mods.ctrl and !key.mods.alt and !key.mods.super) or
                    key.codepoint == vaxis.Key.up)
                {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + n - 1) % n;
                    return;
                }
                if (key.codepoint == vaxis.Key.down) {
                    const n = self.completion_words.items.len;
                    if (n > 0) self.completion_sel = (self.completion_sel + 1) % n;
                    return;
                }
                // Enter accepts the selected word (replaces the typed prefix).
                // Matches the user's nvim: Enter is the only accept key; Tab
                // always inserts literal spaces.
                if (key.codepoint == vaxis.Key.enter) {
                    try self.acceptCompletion();
                    return;
                }
                // Word-char or trigger-char input keeps the menu open — the
                // prefix grows / the trigger context changes and
                // maybeAutoComplete below re-requests. Anything else (space,
                // backspace, Ctrl+w, j/k, Ctrl+c…) dismisses the menu, then
                // falls through to the normal insert handling so jk exit,
                // Esc exit and text entry behave as usual.
                const is_comp_input = key.text != null and key.text.?.len > 0 and
                    !key.mods.ctrl and !key.mods.alt and !key.mods.super and
                    (isWordByte(key.text.?[0]) or self.isCompletionTriggerText(key.text.?));
                if (!is_comp_input) self.closeCompletion();
            }
            // Arrow keys move the cursor without leaving insert mode (up/down
            // with the completion menu open select candidates, handled above).
            // prev_insert_key is left untouched so a jk exit still works after
            // arrow movement.
            if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.right or
                key.codepoint == vaxis.Key.up or key.codepoint == vaxis.Key.down)
            {
                var c = self.curCursor().*;
                editor.Motion.apply(&self.cur().pt, switch (key.codepoint) {
                    vaxis.Key.left => .left,
                    vaxis.Key.right => .right,
                    vaxis.Key.up => .up,
                    else => .down,
                }, .{}, &c, 1);
                self.curCursor().* = c;
                self.clearHover();
                return;
            }
            if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
                self.exitInsert();
                return;
            }
            // jk → drop the 'j' we just inserted, then exit (no chars left)
            if (self.prev_insert_key) |p| {
                if (p.codepoint == 'j' and key.codepoint == 'k' and
                    !key.mods.ctrl and !key.mods.alt and !key.mods.super)
                {
                    if (self.curCursor().* > 0 and self.cur().pt.byteAt(self.curCursor().* - 1) == 'j') {
                        const pos = self.curCursor().* - 1;
                        try self.cur().history.record(&self.cur().pt, pos, 1, "");
                        self.curCursor().* = pos;
                        // The 'j' was shift-adjusted INTO the hints when it
                        // was inserted (adjustInlayHintsInsert +1); removing
                        // it must shift them back, or every jk exit leaves the
                        // hints one column too far right (accumulating).
                        const line = self.cur().pt.lineOf(pos);
                        const col = pos - self.cur().pt.lineStart(line);
                        self.adjustInlayHintsDelete(line, col, "j");
                        // markDirty: the 'j' insertion already sent a
                        // didChange, so the LSP server's copy still contains
                        // the phantom 'j'. Re-sync the removal or the server
                        // keeps analyzing text that never existed — stale
                        // diagnostics ("expected ',' after field" at col 0)
                        // and inlay hints computed against the wrong
                        // document. Also bumps edit_seq so any in-flight
                        // response is discarded as stale. (Runs before
                        // exitInsert, so in_insert is still true and the
                        // freshly shifted-back hints are NOT invalidated.)
                        self.markDirty();
                    }
                    self.exitInsert();
                    return;
                }
            }
            if (key.codepoint == vaxis.Key.enter) {
                // A manual Ctrl+n asked the server for candidates but the
                // response hasn't arrived (zls on build.zig can take many
                // seconds). A blind Enter here would insert a newline and the
                // completion would look ignored — the cursor ends up on the
                // wrong line. Wait instead: tell the user, and let the next
                // Enter accept once the menu opens.
                if (self.completion_waiting_enter and !self.completion_active) {
                    try self.setMsg(try self.alloc.dupe(u8, "completion pending…"));
                    return;
                }
                try self.insertNewline();
                return;
            }
            if (key.codepoint == 'k' and key.mods.ctrl) {
                try self.deleteToEol();
                return;
            }
            if (key.codepoint == vaxis.Key.backspace) {
                // between an empty auto-pair, backspace deletes both sides
                if (!try self.autoPairBackspace()) try self.deleteBeforeCursor();
                return;
            }
            if (key.codepoint == 'w' and key.mods.ctrl) {
                try self.deleteWordBefore();
                return;
            }
            // Tab: insert indentation. Spaces, not a literal tab: a \t is a
            // terminal control character whose display width differs between
            // the terminal and vaxis's cell grid (causing the cursor/char
            // misalignment bug). vim default without expandtab is a tab, but
            // spaces are predictable here (M1).
            if (key.codepoint == vaxis.Key.tab) {
                self.prev_insert_key = key;
                try self.insertText("    ");
                return;
            }
            // Alt+b / Alt+f: emacs word motion. Pure cursor movement — no
            // text change, and prev_insert_key stays untouched (the jk exit
            // and backspace paths must not see these). vaxis parses ESC+b/f
            // as codepoint 'b'/'f' with mods.alt.
            if (key.mods.alt and !key.mods.ctrl and !key.mods.super) {
                if (key.codepoint == 'b') {
                    self.curCursor().* = buffer.ops.wordStartBefore(&self.cur().pt, self.curCursor().*);
                    return;
                }
                if (key.codepoint == 'f') {
                    var c = self.curCursor().*;
                    editor.Motion.apply(&self.cur().pt, .word_next_end, .{}, &c, 1);
                    self.curCursor().* = c;
                    return;
                }
            }
            self.prev_insert_key = key;
            if (key.text) |text| {
                // auto-pairs: openers/quotes close themselves (cursor lands
                // between), closers skip over an identical closer. The
                // signature-help / auto-suggest triggers below still apply.
                const paired = try self.autoPairInsert(text);
                if (!paired) try self.insertText(text);
                // Signature help: typing '(' asks the language server for
                // the callee's signature and shows it in the floating window
                // (LSP signatureHelp; the response arrives via the wake
                // mechanism and renders without a keypress).
                if (key.codepoint == '(' and !key.mods.ctrl and !key.mods.alt) {
                    try self.requestNav("textDocument/signatureHelp", .signature);
                }
                // Auto-suggest: typing a word character asks the LSP for
                // candidates, and typing a trigger character (".", "::", …)
                // asks it to resolve the context ("b." member access). The
                // menu appears when the response lands. 'j' is excluded:
                // jk is the insert-exit shortcut, and asking the server on
                // the 'j' alone makes the menu flash between 'j' and 'k'.
                if (!key.mods.ctrl and !key.mods.alt and !key.mods.super and
                    key.codepoint != 'j' and
                    (isWordByte(text[0]) or self.isCompletionTriggerText(text)))
                {
                    try self.maybeAutoComplete(text);
                }
                return;
            }
            return;
        }

        const keymap: editor.KeyEvent.KeyMap = switch (self.state.mode) {
            .normal => editor.Keymaps.normal,
            .insert => editor.Keymaps.insert,
            .visual_char, .visual_line, .visual_block, .command => editor.Keymaps.normal,
        };
        const res = editor.Mode.handle(&self.state, key, keymap);
        switch (res) {
            .pending => {},
            .action => |a| try self.execAction(a.action, a.count),
            .motion => |m| {
                var new_cursor = self.curCursor().*;
                if (self.viewMotionTargetLine(m.motion)) |line| {
                    // H/M/L: target line resolved from the focused window's
                    // viewport; keep the column, clamp to the line end (j/k
                    // semantics).
                    new_cursor = editor.Motion.toLineKeepCol(&self.cur().pt, new_cursor, line);
                } else if (m.motion == .down or m.motion == .up) {
                    // j/k: a closed fold counts as ONE line — walk visible
                    // lines instead of document lines (foldNext/foldPrev
                    // skip hidden bodies).
                    const buf = self.cur();
                    const line_count = buf.pt.lineCount();
                    var line = buf.pt.lineOf(new_cursor);
                    var i: u32 = 0;
                    while (i < m.count) : (i += 1) {
                        if (m.motion == .down) {
                            if (line + 1 >= line_count) break;
                            line = @min(foldNextLine(buf, line), line_count - 1);
                        } else {
                            if (line == 0) break;
                            line = foldPrevLine(buf, line);
                        }
                    }
                    new_cursor = editor.Motion.toLineKeepCol(&buf.pt, new_cursor, line);
                } else {
                    editor.Motion.apply(&self.cur().pt, m.motion, m.args, &new_cursor, m.count);
                    // any other motion landing inside a closed fold snaps to
                    // its header line — the cursor never rests on hidden text
                    new_cursor = foldSnapPos(self.cur(), new_cursor);
                }
                if (new_cursor != self.curCursor().*) {
                    // The cursor moved: nvim-style hover windows vanish once
                    // the cursor leaves the annotated token.
                    self.clearHover();
                }
                self.curCursor().* = new_cursor;
            },
            .op_motion => |m| try self.execOpMotion(m),
            .surround => |s| try self.execSurround(s),
            .align_lines => |a| try self.execAlign(a),
            .command_mode => {
                // ':' pressed: open the command line (Mode already set .command)
                self.cmdline.clearRetainingCapacity();
                self.cmd_hist_idx = null;
                self.cmd_complete_idx = 0;
                self.clearCmdCompleteNames();
                self.cmdline_kind = .ex;
                try self.setMsg(try self.alloc.dupe(u8, ""));
                // From visual mode vim auto-types :'<,'>; :s then applies to
                // the selection (the anchor survives until Enter).
                if (self.visual_anchor != null) {
                    try self.cmdline.appendSlice(self.alloc, "'<,'>");
                }
            },
            .search_mode => |dir| {
                // '/' or '?' pressed: the command line collects the search
                // query (Mode already set .command)
                self.cmdline.clearRetainingCapacity();
                self.cmd_hist_idx = null;
                self.cmd_complete_idx = 0;
                self.clearCmdCompleteNames();
                self.cmdline_kind = if (dir == .forward) .search_fwd else .search_bwd;
                try self.setMsg(try self.alloc.dupe(u8, ""));
            },
            .to_normal => {
                self.state.mode = .normal;
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
                // Esc from visual mode must clear the selection anchor, or
                // the render loop keeps painting the stale selection
                // highlight (anchor is null on the insert-exit path anyway).
                self.visual_anchor = null;
            },
        }
    }

    fn exitInsert(self: *App) void {
        self.state.mode = .normal;
        self.cur().history.endGroup();
        self.in_insert = false;
        self.prev_insert_key = null;
        self.closeCompletion();
        self.endInsertSession();
        // The old code forced a full reparse here (syntax_revision = maxInt)
        // to avoid the "chars turn comment-gray after jk" drift. That guard
        // was belt-and-suspenders: the drift comes from multi-edit structural
        // ops (o/O insert a newline AND indentation as two records in one
        // frame), and THOSE sites already force a full reparse themselves.
        // A plain typing session (including jk's trailing 'j' deletion) is a
        // sequence of single-record edits — the incremental path is exact for
        // them, and forcing a full reparse on every insert exit made large
        // files visibly flash/stutter the frame after jk. Leave the revision
        // alone; visibleSpansFor takes the incremental path when it can.
        // The session's in-place shifts kept the hint DATA current (adjust
        // on every edit), so hints stay rendered across the exit — no
        // clear + async re-request, which was the "hints vanish then
        // reappear" flash after jk. But code WRITTEN during the session has
        // no hints at all until the server is asked again, so reset the
        // request bookkeeping (NOT the displayed hints): the run loop
        // re-requests the visible range in the background and processInlay
        // swaps the fresh hints in atomically — no flash, and new code
        // gets its hints.
        self.inlay_view_top = null;
    }

    // ---- visual-block multi-cursor insert (<C-v> block then I/A) ----

    /// The vim visual-block rectangle: the lines between the anchor and
    /// cursor rows and the columns between their columns (both ends
    /// inclusive). Columns are byte columns within a line.
    const BlockRect = struct {
        top: u32,
        bottom: u32,
        left: u32,
        right: u32,
    };

    /// Align `pos` (a byte offset within [line_start, line_end)) forward to a
    /// UTF-8 character boundary, so a visual-block column landing on a
    /// continuation byte doesn't slice a multibyte char mid-sequence.
    fn charBoundaryForward(self: *App, pt: *const buffer.PieceTable, pos: u32, line_end: u32) u32 {
        _ = self;
        var p = pos;
        while (p < line_end and (pt.byteAt(p) & 0xC0) == 0x80) : (p += 1) {}
        return p;
    }

    /// Byte length of the UTF-8 character starting at `pos` (1 for ASCII,
    /// 2-4 for sequences; malformed bytes — stray continuation bytes and
    /// invalid leads 0xF8..0xFF — count as 1, matching motion.zig).
    fn charLenAt(self: *App, pt: *const buffer.PieceTable, pos: u32) u32 {
        _ = self;
        if (pos >= pt.len()) return 0;
        const b = pt.byteAt(pos);
        if (b < 0x80) return 1;
        if (b < 0xC0) return 1; // stray continuation byte: its own char
        const n: u32 = if (b < 0xE0) 2 else if (b < 0xF0) 3 else if (b < 0xF8) 4 else 1;
        return @min(n, pt.len() - pos);
    }

    fn blockRect(self: *App) ?BlockRect {
        const anchor = self.visual_anchor orelse return null;
        const pt = &self.cur().pt;
        const a_line = pt.lineOf(anchor);
        const c_line = pt.lineOf(self.curCursor().*);
        const a_col = anchor - pt.lineStart(a_line);
        const c_col = self.curCursor().* - pt.lineStart(c_line);
        return .{
            .top = @min(a_line, c_line),
            .bottom = @max(a_line, c_line),
            .left = @min(a_col, c_col),
            .right = @max(a_col, c_col),
        };
    }

    /// d/c/y over a visual-block rectangle: operate on every covered line's
    /// [left, min(right+1, lineLen)) slice — bottom-up for edits so earlier
    /// positions stay valid; blank slices on short lines are skipped.
    fn applyBlockOp(self: *App, op: editor.KeyEvent.ActionId) !void {
        const rect = self.blockRect() orelse return;
        const pt = &self.cur().pt;
        switch (op) {
            .delete, .change => {
                self.cur().history.beginGroup();
                var line = rect.bottom + 1;
                while (line > rect.top) {
                    line -= 1;
                    const ls = pt.lineStart(line);
                    const len = pt.lineLen(line);
                    if (rect.left >= len) continue;
                    const line_end = ls + len;
                    const start = self.charBoundaryForward(pt, ls + rect.left, line_end);
                    const end = @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end);
                    if (end <= start) continue;
                    try self.cur().history.record(pt, start, end - start, "");
                }
                self.cur().history.endGroup();
                self.markDirty();
                if (op == .change) {
                    // vim blockwise change: after deleting the rectangle, one
                    // insert cursor per covered line at the block's left edge
                    // — the typed text lands in EVERY line of the block, not
                    // just at the cursor. placeBlockCursors opens the insert
                    // session undo group (typing joins it).
                    try self.placeBlockCursors(rect, false);
                } else {
                    self.curCursor().* = pt.lineStart(rect.top) + @min(rect.left, pt.lineLen(rect.top));
                }
            },
            .yank => {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                var line = rect.top;
                while (line <= rect.bottom) : (line += 1) {
                    const ls = pt.lineStart(line);
                    const len = pt.lineLen(line);
                    if (rect.left < len) {
                        const line_end = ls + len;
                        const start = self.charBoundaryForward(pt, ls + rect.left, line_end);
                        const end = @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end);
                        if (end <= start) continue;
                        const seg = try self.alloc.alloc(u8, end - start);
                        defer self.alloc.free(seg);
                        pt.copyRange(start, seg);
                        try buf.appendSlice(self.alloc, seg);
                    }
                    if (line < rect.bottom) try buf.append(self.alloc, '\n');
                }
                if (self.yank_buffer) |b| self.alloc.free(b);
                self.yank_buffer = try buf.toOwnedSlice(self.alloc);
                self.yank_linewise = false; // blockwise yank pastes inline (no blockwise put yet)
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked block {d} bytes", .{self.yank_buffer.?.len}));
            },
            else => {},
        }
    }

    /// I/A after a Ctrl+v block (or blockwise c after the rectangle was
    /// deleted): place one insert cursor per line of the block and enter
    /// insert mode. I puts each cursor at the block's left edge; A (append)
    /// puts them one column past the block's right edge (vim: the right edge
    /// is the last selected column, so +1 inserts right after the selection's
    /// rightmost character). Both clamp to the end of the line, so
    /// short/empty lines get their cursor at end-of-line. The top line's
    /// cursor is added first so it becomes the main one.
    fn blockInsert(self: *App, append: bool) !void {
        const rect = self.blockRect() orelse return;
        try self.placeBlockCursors(rect, append);
    }

    fn placeBlockCursors(self: *App, rect: BlockRect, append: bool) !void {
        const pt = &self.cur().pt;
        self.mc.clear();
        const anchor_line = pt.lineStart(rect.top);
        const anchor_end = anchor_line + pt.lineLen(rect.top);
        const anchor_col: u32 = if (append)
            @min(self.charBoundaryForward(pt, anchor_line + rect.right + 1, anchor_end), anchor_end)
        else
            @min(self.charBoundaryForward(pt, anchor_line + rect.left, anchor_end), anchor_end);
        _ = try self.mc.add(anchor_col);
        var line = rect.top;
        while (line <= rect.bottom) : (line += 1) {
            if (line == rect.top) continue;
            const ls = pt.lineStart(line);
            const line_end = ls + pt.lineLen(line);
            const col: u32 = if (append)
                @min(self.charBoundaryForward(pt, ls + rect.right + 1, line_end), line_end)
            else
                @min(self.charBoundaryForward(pt, ls + rect.left, line_end), line_end);
            _ = try self.mc.add(col);
        }
        self.mc_active = true;
        self.visual_anchor = null; // the selection is consumed by I/A/c
        self.state.mode = .insert;
        // open the undo group immediately: the first key (backspace or
        // typing) must join the same session group
        self.cur().history.beginGroup();
        self.in_insert = true;
        self.prev_insert_key = null;
        self.mcSyncCursor();
    }

    /// Insert-mode keys with an active visual-block multi-cursor selection.
    /// Mirrors the single-cursor insert path, but every edit applies at every
    /// cursor (one history.record per cursor, right-to-left so the earlier
    /// positions stay valid) and the whole session lives in one undo group.
    fn handleMcInsertKey(self: *App, key: vaxis.Key) !void {
        // Arrow keys move the main cursor without leaving insert.
        if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.right or
            key.codepoint == vaxis.Key.up or key.codepoint == vaxis.Key.down)
        {
            var c = self.curCursor().*;
            editor.Motion.apply(&self.cur().pt, switch (key.codepoint) {
                vaxis.Key.left => .left,
                vaxis.Key.right => .right,
                vaxis.Key.up => .up,
                else => .down,
            }, .{}, &c, 1);
            self.curCursor().* = c;
            self.mcSyncCursor();
            return;
        }
        // Esc / Ctrl-c: exit, one main cursor remains
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.exitMcInsert();
            return;
        }
        // jk → drop the just-typed 'j' at every cursor, then exit
        if (self.prev_insert_key) |p| {
            if (p.codepoint == 'j' and key.codepoint == 'k' and
                !key.mods.ctrl and !key.mods.alt and !key.mods.super)
            {
                var deleted_any = false;
                var i = self.mc.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const pos = self.mc.cursors.items[i];
                    if (pos > 0 and self.cur().pt.byteAt(pos - 1) == 'j') {
                        deleted_any = true;
                        try self.cur().history.record(&self.cur().pt, pos - 1, 1, "");
                        // the deletion shifts every cursor at/after it back
                        for (self.mc.cursors.items[i..]) |*c| c.* -= 1;
                    }
                }
                // The 'j' insertions were synced via didChange (mcInsertText
                // → markDirty); re-sync the removals too, or the server
                // analyzes a document with phantom 'j's (stale diagnostics,
                // wrong inlay positions).
                if (deleted_any) self.markDirty();
                self.exitMcInsert();
                return;
            }
        }
        // Enter at every cursor: insert a newline at each one. (No
        // indentation carry-over — M1 keeps the multi-cursor path simple.
        // Ctrl+k / Alt+b / Alt+f are intentionally not handled here.)
        if (key.codepoint == vaxis.Key.enter) {
            try self.mcInsertText("\n");
            return;
        }
        if (key.codepoint == vaxis.Key.backspace) {
            try self.mcBackspace();
            return;
        }
        if (key.codepoint == 'w' and key.mods.ctrl) {
            try self.mcDeleteWordBefore();
            return;
        }
        self.prev_insert_key = key;
        if (key.text) |text| {
            try self.mcInsertText(text);
        }
    }

    /// Insert `text` at every visual-block cursor. One history.record per
    /// cursor, applied right-to-left so earlier positions stay valid; every
    /// cursor at or after an insertion point moves forward by `text.len`
    /// (mirrors MultiCursor.applyInsert, but each edit lands in history).
    fn mcInsertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const tlen: u32 = @intCast(text.len);
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            try self.cur().history.record(&self.cur().pt, pos, 0, text);
            for (self.mc.cursors.items[i..]) |*c| c.* += tlen;
        }
        self.mcSyncCursor();
        self.markDirty();
    }

    /// Backspace at every visual-block cursor: delete one character before
    /// each cursor (right-to-left); cursors at/after a deletion shift back,
    /// ones inside its range clamp to its start.
    fn mcBackspace(self: *App) !void {
        // safety net: the deletion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            if (pos == 0) continue;
            const start = buffer.ops.prevCharStart(&self.cur().pt, pos);
            const del = pos - start;
            try self.cur().history.record(&self.cur().pt, start, del, "");
            var j: usize = 0;
            while (j < self.mc.cursors.items.len) : (j += 1) {
                const c = self.mc.cursors.items[j];
                if (c < start) continue;
                self.mc.cursors.items[j] = if (c >= pos) c - del else start;
            }
        }
        self.mcSyncCursor();
        // LSP sync: the deletions changed the buffer — the server's copy
        // must follow or diagnostics/hints are computed against stale text.
        self.markDirty();
    }

    /// Ctrl-w at every visual-block cursor: delete the word before each
    /// cursor (right-to-left); cursors shift like backspace.
    fn mcDeleteWordBefore(self: *App) !void {
        // safety net: the deletion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            if (pos == 0) continue;
            const start = buffer.ops.wordStartBefore(&self.cur().pt, pos);
            if (start == pos) continue;
            const del = pos - start;
            try self.cur().history.record(&self.cur().pt, start, del, "");
            var j: usize = 0;
            while (j < self.mc.cursors.items.len) : (j += 1) {
                const c = self.mc.cursors.items[j];
                if (c < start) continue;
                self.mc.cursors.items[j] = if (c >= pos) c - del else start;
            }
        }
        self.mcSyncCursor();
        // LSP sync: the deletions changed the buffer — the server's copy
        // must follow or diagnostics/hints are computed against stale text.
        self.markDirty();
    }

    /// Exit a visual-block multi-cursor insert session: close the undo group,
    /// drop the extra cursors and leave a single main cursor (the block's
    /// anchor-line cursor) in normal mode.
    fn exitMcInsert(self: *App) void {
        self.mcSyncCursor();
        self.mc.clear();
        self.mc_active = false;
        self.state.mode = .normal;
        self.cur().history.endGroup();
        self.in_insert = false;
        self.prev_insert_key = null;
        self.endInsertSession();
        // Force a full reparse on the next render: incremental edits during
        // the insert session may have drifted the highlight tree.
        self.cur().syntax_revision = std.math.maxInt(u64);
        // the mc edits were not position-adjusted (unlike single-cursor
        // insert); fetch fresh hints for the new text
        self.invalidateInlayHints();
    }

    /// Keep the visible (main) cursor on the main multi-cursor's position.
    fn mcSyncCursor(self: *App) void {
        if (self.mc.len() > 0) self.curCursor().* = self.mc.cursors.items[self.mc.main];
    }

    // ---- easymotion (s / <leader>f) ----

    fn handleEasyMotionKey(self: *App, key: vaxis.Key) !void {
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.endEasyMotion();
            return;
        }
        if (!self.em_labels) {
            // first key = the query character. Use the key's UTF-8 text so
            // non-ASCII queries (CJK etc.) work — codepoint-only matching
            // capped the query at 0xFF and swallowed multibyte keys.
            const text = key.text orelse {
                // keys without text (Enter etc.): take the codepoint as a
                // single byte when it is printable ASCII
                if (key.codepoint >= 0x20 and key.codepoint <= 0x7F and
                    !key.mods.ctrl and !key.mods.alt and !key.mods.super)
                {
                    self.em_query[0] = @intCast(key.codepoint);
                    self.em_query_len = 1;
                    if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
                    const q = self.em_query[0..self.em_query_len];
                    self.em_matches = try editor.easymotion.find(self.alloc, &self.cur().pt, q);
                    self.em_labels = true;
                }
                return;
            };
            if (text.len > 0 and text.len <= 2 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                @memcpy(self.em_query[0..text.len], text);
                self.em_query_len = @intCast(text.len);
                if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
                const q = self.em_query[0..self.em_query_len];
                self.em_matches = try editor.easymotion.find(self.alloc, &self.cur().pt, q);
                self.em_labels = true;
            }
            return;
        }
        // label key: jump to the match carrying this label
        const ch = key.codepoint;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            for (self.em_matches) |m| {
                if (m.label == ch) {
                    self.curCursor().* = m.pos;
                    break;
                }
            }
        }
        self.endEasyMotion();
    }

    fn endEasyMotion(self: *App) void {
        if (self.em_matches.len > 0) self.alloc.free(self.em_matches);
        self.em_matches = &.{};
        self.em_active = false;
        self.em_labels = false;
        self.em_query = .{ 0, 0, 0, 0 };
        self.em_query_len = 0;
    }

    /// Delete the character before the cursor (backspace). The edit lands in
    /// the open insert undo group so it stays part of the insert session.
    fn deleteBeforeCursor(self: *App) !void {
        if (self.curCursor().* == 0) return;
        // safety net: make sure the insert-session group is open even if a
        // future entry path forgets to open it (backspace is a deletion, and
        // history.record would otherwise auto-open/close its own group)
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const start = buffer.ops.prevCharStart(&self.cur().pt, self.curCursor().*);
        const cursor = self.curCursor().*;
        const line = self.cur().pt.lineOf(start);
        const col = start - self.cur().pt.lineStart(line);
        var deleted: [16]u8 = undefined;
        const del_len: usize = @intCast(cursor - start);
        self.cur().pt.copyRange(start, deleted[0..del_len]);
        try self.cur().history.record(&self.cur().pt, start, cursor - start, "");
        self.curCursor().* = start;
        self.adjustInlayHintsDelete(line, col, deleted[0..del_len]);
        self.markDirty();
    }

    /// Delete the word before the cursor (Ctrl-w). Vim semantics: walk back
    /// over whitespace then word characters; deletes [start, cursor).
    fn deleteWordBefore(self: *App) !void {
        if (self.curCursor().* == 0) return;
        const start = buffer.ops.wordStartBefore(&self.cur().pt, self.curCursor().*);
        if (start == self.curCursor().*) return;
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const cursor = self.curCursor().*;
        const line = self.cur().pt.lineOf(start);
        const col = start - self.cur().pt.lineStart(line);
        const del_len: usize = @intCast(cursor - start);
        const deleted = try self.alloc.alloc(u8, del_len);
        defer self.alloc.free(deleted);
        self.cur().pt.copyRange(start, deleted);
        try self.cur().history.record(&self.cur().pt, start, cursor - start, "");
        self.curCursor().* = start;
        self.adjustInlayHintsDelete(line, col, deleted);
        self.markDirty();
    }

    // ---- insert-mode keyword completion (Ctrl+n) ----

    /// Word characters for keyword completion: [a-zA-Z0-9_] plus any
    /// non-ASCII byte (mirrors editor/multicursor.zig's classification).
    fn isWordByte(b: u8) bool {
        return (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '_' or
            b >= 0x80;
    }

    /// Case-insensitive substring match (completion filtering — loose, like
    /// blink's fuzzy matching).
    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Nerd Font glyph for an LSP CompletionItemKind (1-25); " " for unknown.
    /// Mirrors the user's nvim icons (AstroNvim style) so the completion menu
    /// looks like blink.cmp.
    fn kindGlyph(kind: u8) []const u8 {
        return switch (kind) {
            2, 3, 4 => "", // Method / Function / Constructor
            5, 10, 20 => "", // Field / Property / EnumMember
            6 => "", // Variable
            7 => "", // Class
            8 => "", // Interface
            9, 19 => "", // Module / Folder
            11 => "", // Unit
            12, 1, 18 => "", // Value / Text / Reference
            13 => "", // Enum
            14 => "", // Keyword
            15 => "", // Snippet
            16 => "", // Color
            17 => "", // File
            21 => "", // Constant
            22 => "", // Struct
            23 => "", // Event
            24 => "", // Operator
            25 => "", // TypeParameter
            else => " ",
        };
    }

    /// Ctrl+n in insert mode with the cursor inside a word: collect keyword
    /// candidates from the whole buffer and open the completion menu. Without
    /// a word prefix the key is swallowed (no candidates, no side effect).
    fn startCompletion(self: *App) !void {
        if (self.completion_active) return;
        if (self.curCursor().* == 0) return;
        if (!isWordByte(self.cur().pt.byteAt(self.curCursor().* - 1))) return;
        // LSP completion first: ask the language server for candidates at the
        // cursor; the response lands in completion_slot and processCompletion
        // opens the menu. Without a client we fall back to buffer words.
        if (self.lsp_client) |c| {
            self.completion_manual = true;
            self.completion_waiting_enter = true;
            try self.requestLspCompletion(c, false);
            return;
        }
        try self.collectCompletionWords(false);
        if (self.completion_words.items.len > 0) {
            self.completion_active = true;
        }
    }

    /// Send a textDocument/completion request at the cursor (the menu opens
    /// when the response lands in processCompletion). Shared by Ctrl+n and
    /// the insert-mode auto-suggest. `no_prefix` is true after a trigger
    /// character ("b."): there is no word prefix — completion_pos is the
    /// cursor and accept inserts at it (the server resolves members etc.).
    fn requestLspCompletion(self: *App, c: anytype, no_prefix: bool) !void {
        // remember the start of the word being typed so acceptCompletion
        // replaces just [completion_pos, cursor) with the chosen item
        var pos = self.curCursor().*;
        if (!no_prefix) {
            while (pos > 0 and isWordByte(self.cur().pt.byteAt(pos - 1))) pos -= 1;
            if (pos == self.curCursor().*) return;
        }
        self.completion_pos = pos;
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        const line = self.cur().pt.lineOf(self.curCursor().*);
        const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
        var params = lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
        defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
        c.request("textDocument/completion", params, &self.completion_slot) catch return;
        self.completion_req_seq = self.edit_seq;
    }

    /// True when the just-typed `text` is one of the server's completion
    /// trigger characters (e.g. "." after "b" → "b." member access), or the
    /// tail of a multi-char trigger ("-" + ">" → "->"). No LSP → false.
    fn isCompletionTriggerText(self: *App, text: []const u8) bool {
        const c = self.lsp_client orelse return false;
        if (c.isCompletionTrigger(text)) return true;
        if (text.len == 1 and self.curCursor().* >= 2) {
            var two: [2]u8 = undefined;
            self.cur().pt.copyRange(self.curCursor().* - 2, two[0..2]);
            if (c.isCompletionTrigger(two[0..2])) return true;
        }
        return false;
    }

    /// Insert-mode auto-suggest: after typing a word character or a trigger
    /// character (".", "::", …), ask the LSP for candidates at the cursor
    /// (the response opens/updates the menu; stale responses are discarded in
    /// processCompletion). Without an LSP, buffer-word completion is triggered
    /// only for word prefixes on small documents — a full-buffer scan per
    /// keystroke on a huge file would jitter.
    fn maybeAutoComplete(self: *App, text: []const u8) !void {
        if (self.curCursor().* == 0) return;
        self.completion_manual = false; // auto-suggest: silent on empty
        const trigger = !isWordByte(text[0]) and self.isCompletionTriggerText(text);
        if (self.lsp_client) |c| {
            if (trigger) {
                // no word prefix: the server resolves the trigger context
                self.completion_pos = self.curCursor().*;
                try self.requestLspCompletion(c, true);
                return;
            }
            if (!isWordByte(self.cur().pt.byteAt(self.curCursor().* - 1))) return;
            try self.requestLspCompletion(c, false);
            return;
        }
        if (trigger) return; // buffer words need a prefix
        if (self.cur().pt.len() > 16 * 1024) return;
        const was_active = self.completion_active;
        try self.collectCompletionWords(was_active);
        if (self.completion_words.items.len > 0) {
            self.completion_active = true;
        }
    }

    /// Consume a completed LSP completion response (called after drain each
    /// frame): fill completion_words and open the menu. Returns true when a
    /// response was consumed (caller renders immediately).
    fn processCompletion(self: *App) bool {
        var result = self.completion_slot orelse return false;
        defer {
            json_rpc.freeValue(self.alloc, &result);
            self.completion_slot = null;
        }
        // Stale: the text changed after the request (fast typing) or the
        // user left insert mode (e.g. Esc before the response landed). Keep
        // the current items — the next keystroke sends a fresh request.
        // The manual request's response is still consumed, so Enter must be
        // unblocked (otherwise it would stay stuck on "completion pending…"
        // forever with no menu to open).
        if (self.edit_seq != self.completion_req_seq or self.state.mode != .insert) {
            self.completion_waiting_enter = false;
            return true;
        }
        for (self.completion_words.items) |it| self.alloc.free(it.text);
        self.completion_words.clearRetainingCapacity();
        lsp_nav.parseCompletionItems(self.alloc, result, &self.completion_words) catch {};
        // Client-side filter: servers like zls return the FULL candidate set
        // and leave matching to the client (blink/nvim do the same via
        // filterText/label). Substring match, case-insensitive — loose like
        // fuzzy matching; without this the menu would show the same
        // unfiltered list no matter what you type.
        if (self.completion_words.items.len > 0 and self.completion_pos < self.curCursor().*) {
            const typed_len = self.curCursor().* - self.completion_pos;
            var typed_buf: [256]u8 = undefined;
            if (typed_len <= 256) {
                self.cur().pt.copyRange(self.completion_pos, typed_buf[0..typed_len]);
                const typed = typed_buf[0..typed_len];
                var write: usize = 0;
                for (self.completion_words.items) |*it| {
                    if (containsIgnoreCase(it.text, typed)) {
                        self.completion_words.items[write] = it.*;
                        write += 1;
                    } else {
                        self.alloc.free(it.text);
                    }
                }
                self.completion_words.shrinkRetainingCapacity(write);
            }
        }
        if (self.completion_words.items.len > 0) {
            self.completion_active = true;
            // keep the user's selection when the list refreshed while typing
            if (self.completion_sel >= self.completion_words.items.len) self.completion_sel = 0;
        } else {
            // nothing matches the typed prefix: keep typing clean. A manual
            // Ctrl+n with zero matches gets a status hint — otherwise the
            // user can't tell the accept never happened and Enter quietly
            // inserts a newline (the classic "cursor is not after the
            // semicolon" confusion).
            self.completion_active = false;
            self.completion_sel = 0;
            if (self.completion_manual) {
                self.setMsg(self.alloc.dupe(u8, "no candidates") catch return true) catch {};
            }
        }
        // the manual request's response has been consumed: Enter is free
        // again (accept if the menu opened, newline otherwise)
        self.completion_waiting_enter = false;
        return true;
    }

    // ---- LSP editing (<leader>rn / <leader>lf / <leader>ti / <leader>o) ----

    /// <leader>rn: open the command line prefilled with the word under the
    /// cursor; Enter sends textDocument/rename with the edited name.
    fn requestRename(self: *App) !void {
        if (self.lsp_client == null) {
            try self.setMsg(try self.alloc.dupe(u8, "no language server"));
            return;
        }
        const cursor = self.curCursor().*;
        if (cursor == 0 or !isWordByte(self.cur().pt.byteAt(cursor - 1))) {
            try self.setMsg(try self.alloc.dupe(u8, "no symbol under cursor"));
            return;
        }
        var start = cursor;
        while (start > 0 and isWordByte(self.cur().pt.byteAt(start - 1))) start -= 1;
        var end = cursor;
        while (end < self.cur().pt.len() and isWordByte(self.cur().pt.byteAt(end))) end += 1;
        self.cmdline.clearRetainingCapacity();
        const wlen = end - start;
        const wbuf = self.alloc.alloc(u8, wlen) catch return;
        defer self.alloc.free(wbuf);
        self.cur().pt.copyRange(start, wbuf);
        try self.cmdline.appendSlice(self.alloc, wbuf);
        self.cmd_hist_idx = null;
        self.cmd_complete_idx = 0;
        self.clearCmdCompleteNames();
        try self.setMsg(try self.alloc.dupe(u8, ""));
        self.state.mode = .command;
        self.pending_rename = true;
    }

    /// Execute the pending rename with the command line's text.
    fn execRename(self: *App) !void {
        self.pending_rename = false;
        const client = self.lsp_client orelse return;
        const new_name = self.cmdline.items;
        if (new_name.len == 0) return;
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        const line = self.cur().pt.lineOf(self.curCursor().*);
        const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
        var params = lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
        defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
        const name_copy = try self.alloc.dupe(u8, new_name);
        // Always freed exactly once, on every exit path (put failure, request
        // failure, success): params never frees it, so defer is safe and no
        // path leaks it.
        defer self.alloc.free(name_copy);
        try params.object.put(self.alloc, "newName", .{ .string = name_copy });
        client.request("textDocument/rename", params, &self.format_slot) catch return;
        self.format_req_seq = self.edit_seq;
    }

    /// Free a manually-built {textDocument:{uri(dupe)}, ...} params object
    /// (used by format/inlay/outline; json_rpc.encodeRequest only
    /// serializes — it does not free the params).
    fn freeSimpleDocParams(self: *App, v: *std.json.Value) void {
        if (v.object.getPtr("textDocument")) |td| {
            if (td.object.getPtr("uri")) |u| {
                if (u.* == .string) self.alloc.free(u.string);
            }
            td.object.deinit(self.alloc);
        }
        if (v.object.getPtr("options")) |o| o.object.deinit(self.alloc);
        if (v.object.getPtr("range")) |r| {
            if (r.object.getPtr("start")) |st| st.object.deinit(self.alloc);
            if (r.object.getPtr("end")) |en| en.object.deinit(self.alloc);
            r.object.deinit(self.alloc);
        }
        v.object.deinit(self.alloc);
    }

    /// <leader>lf: request textDocument/formatting; the TextEdit[] response
    /// is applied in processFormat.
    fn requestFormat(self: *App) !void {
        const client = self.lsp_client orelse return;
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        const uri_copy = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        var options = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer options.deinit(self.alloc);
        try options.put(self.alloc, "tabSize", .{ .integer = 4 });
        try options.put(self.alloc, "insertSpaces", .{ .bool = true });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "options", .{ .object = options });
        var params_value = std.json.Value{ .object = params };
        defer self.freeSimpleDocParams(&params_value);
        client.request("textDocument/formatting", params_value, &self.format_slot) catch return;
        self.format_req_seq = self.edit_seq;
    }

    /// Consume a formatting/rename response (TextEdit[]) and apply the edits
    /// right-to-left so earlier offsets stay valid. Returns true when a
    /// response was consumed.
    fn processFormat(self: *App) bool {
        var result = self.format_slot orelse return false;
        defer {
            json_rpc.freeValue(self.alloc, &result);
            self.format_slot = null;
        }
        // Stale response: the document changed after this request was sent
        // (edits typed between <leader>lf and the reply). The TextEdits were
        // computed against the old text; applying them would corrupt the
        // buffer, so drop them like the inlay-hint path does.
        if (self.edit_seq != self.format_req_seq) return true;
        var edits = std.ArrayList(lsp_nav.TextEdit).empty;
        defer {
            for (edits.items) |*e| self.alloc.free(e.new_text);
            edits.deinit(self.alloc);
        }
        // formatting → TextEdit[]; rename → WorkspaceEdit {changes:{uri:[edits]}}
        const edits_value: ?std.json.Value = if (result == .array)
            result
        else if (result == .object) blk: {
            const changes = result.object.get("changes") orelse break :blk null;
            if (changes != .object) break :blk null;
            var it = changes.object.iterator();
            break :blk if (it.next()) |e| e.value_ptr.* else null;
        } else null;
        if (edits_value) |ev| {
            lsp_nav.parseTextEdits(self.alloc, ev, &self.cur().pt, &edits) catch return true;
        }
        if (edits.items.len == 0) return true;
        self.cur().history.beginGroup();
        var i = edits.items.len;
        while (i > 0) {
            i -= 1;
            const e = edits.items[i];
            if (e.end < e.start) continue;
            self.cur().history.record(&self.cur().pt, e.start, e.end - e.start, e.new_text) catch {};
        }
        self.cur().history.endGroup();
        self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
        self.markDirty();
        self.cur().syntax_revision = std.math.maxInt(u64);
        return true;
    }

    /// <leader>ti: request inlay hints for the current line.
    fn requestInlayHints(self: *App) !void {
        const client = self.lsp_client orelse return;
        if (!client.caps_inlay) return; // server doesn't support inlay hints
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        // request the visible line range; clamp the end to a real line so
        // strict servers (zls) don't stall on an out-of-range end line
        const top = self.curViewTop().*;
        const line_count = self.cur().pt.lineCount();
        const bottom = if (line_count == 0) 0 else @min(top + 24, line_count) - 1;
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        const uri_copy = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        var range = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer range.deinit(self.alloc);
        var start = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer start.deinit(self.alloc);
        try start.put(self.alloc, "line", .{ .integer = top });
        try start.put(self.alloc, "character", .{ .integer = 0 });
        var end = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer end.deinit(self.alloc);
        try end.put(self.alloc, "line", .{ .integer = bottom });
        try end.put(self.alloc, "character", .{ .integer = 0 });
        try range.put(self.alloc, "start", .{ .object = start });
        try range.put(self.alloc, "end", .{ .object = end });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        try params.put(self.alloc, "range", .{ .object = range });
        var params_value = std.json.Value{ .object = params };
        defer self.freeSimpleDocParams(&params_value);
        client.request("textDocument/inlayHint", params_value, &self.inlay_slot) catch return;
        self.inlay_req_seq = self.edit_seq;
    }

    /// Consume an inlayHint response: collect (line, character, label) hints
    /// for inline rendering. Returns true when a response was consumed.
    fn processInlay(self: *App) bool {
        var result = self.inlay_slot orelse {
            return false;
        };
        defer {
            json_rpc.freeValue(self.alloc, &result);
            self.inlay_slot = null;
        }
        // Stale response: the document changed after this request was sent
        // (fast typing in insert mode). Discard it — the in-place adjusted
        // hints stay rendered, and the next quiescent request replaces them.
        // Applying it would jump the hints to pre-edit positions (flicker).
        if (self.edit_seq != self.inlay_req_seq) return true;
        // The response matches the current document: the hints are no longer
        // stale, so renderers may draw them again.
        self.inlay_stale = false;
        for (self.inlay_hints.items) |*h| self.alloc.free(h.label);
        self.inlay_hints.clearRetainingCapacity();
        if (result != .array) {
            return true;
        }
        for (result.array.items) |hint| {
            if (hint != .object) continue;
            const label = hint.object.get("label") orelse continue;
            const text: ?[]const u8 = switch (label) {
                .string => |str| str,
                .array => blk: {
                    // InlayHintPart[] — concatenate the `value` strings. Must
                    // transfer ownership (toOwnedSlice) — returning out.items
                    // and letting a defer deinit free the buffer would leave a
                    // dangling slice (rendered as 0xAA garbage).
                    var out = std.ArrayList(u8).empty;
                    for (label.array.items) |part| {
                        if (part == .object) {
                            if (part.object.get("value")) |val| {
                                if (val == .string) out.appendSlice(self.alloc, val.string) catch {};
                            }
                        }
                    }
                    if (out.items.len == 0) {
                        out.deinit(self.alloc);
                        break :blk null;
                    }
                    break :blk out.toOwnedSlice(self.alloc) catch {
                        out.deinit(self.alloc);
                        break :blk null;
                    };
                },
                else => null,
            };
            const t = text orelse continue;
            if (t.len == 0) continue;
            // The array branch owns its slice (toOwnedSlice); the string
            // branch borrows from `result` (freed below). A malformed hint
            // that fails the position parse below must release the owned
            // slice — otherwise every such response leaks the label.
            const position = hint.object.get("position") orelse {
                if (label == .array) self.alloc.free(t);
                continue;
            };
            const line = lsp_nav.posLine(position) orelse {
                if (label == .array) self.alloc.free(t);
                continue;
            };
            const character_utf16 = lsp_nav.posCharacter(position) orelse {
                if (label == .array) self.alloc.free(t);
                continue;
            };
            // LSP positions are UTF-16 code units; store the hint at the
            // byte column instead so adjustInlayHints* and the renderer's
            // byte-column comparisons stay consistent on non-ASCII lines.
            const character = self.byteColumnFromUtf16(line, character_utf16);
            const copy = switch (label) {
                .array => t,
                else => self.alloc.dupe(u8, t) catch continue,
            };
            self.inlay_hints.append(self.alloc, .{ .line = line, .character = character, .label = copy }) catch {
                self.alloc.free(copy);
                continue;
            };
        }
        return true;
    }

    /// <leader>o: request document symbols; the response fills the outline
    /// list overlay (reuses the navigation location list UI).
    fn requestOutline(self: *App) !void {
        const client = self.lsp_client orelse return;
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        var td = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer td.deinit(self.alloc);
        const uri_copy = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_copy);
        try td.put(self.alloc, "uri", .{ .string = uri_copy });
        var params = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        errdefer params.deinit(self.alloc);
        try params.put(self.alloc, "textDocument", .{ .object = td });
        var params_value = std.json.Value{ .object = params };
        defer self.freeSimpleDocParams(&params_value);
        client.request("textDocument/documentSymbol", params_value, &self.outline_slot) catch return;
    }

    /// Consume a documentSymbol response: flatten into the outline list
    /// (reuses nav_locations for the overlay; the label rides in a packed
    /// "label\x00line" uri slot so the list shows it and Enter jumps).
    fn processOutline(self: *App) bool {
        var result = self.outline_slot orelse return false;
        defer {
            json_rpc.freeValue(self.alloc, &result);
            self.outline_slot = null;
        }
        for (self.nav_locations.items) |*l| self.alloc.free(l.uri);
        self.nav_locations.clearRetainingCapacity();
        self.nav_list_sel = 0;
        self.nav_loc_top = 0;
        if (result == .array) {
            for (result.array.items) |item| {
                if (item != .object) continue;
                var name: ?[]const u8 = null;
                if (item.object.get("name")) |nm| {
                    if (nm == .string) name = nm.string;
                }
                const rng = if (item.object.get("range")) |r| r else blk: {
                    const loc = item.object.get("location") orelse continue;
                    break :blk if (loc.object.get("range")) |rr| rr else continue;
                };
                if (rng != .object) continue;
                const start = rng.object.get("start") orelse continue;
                const line = lsp_nav.posLine(start) orelse continue;
                const nm = name orelse continue;
                const packed_uri = std.fmt.allocPrint(self.alloc, "{s}\x00{d}", .{ nm, line }) catch continue;
                self.nav_locations.append(self.alloc, .{ .uri = packed_uri, .line = line, .character = 0 }) catch {
                    self.alloc.free(packed_uri);
                    continue;
                };
            }
        }
        self.nav_list_active = self.nav_locations.items.len > 0;
        self.nav_list_title = " Outline ";
        return true;
    }

    /// Scan the whole buffer for words and fill completion_words with the
    /// most frequent ones (ties broken alphabetically), capped at 20. The
    /// word currently being typed (from completion_pos to the cursor) is
    /// excluded from the candidates.
    fn collectCompletionWords(self: *App, keep_sel: bool) !void {
        const pt = &self.cur().pt;
        const cursor = self.curCursor().*;
        // start of the word under/behind the cursor — the replacement anchor
        var pos = cursor;
        while (pos > 0 and isWordByte(pt.byteAt(pos - 1))) pos -= 1;
        if (pos == cursor) return; // cursor not inside a word
        self.completion_pos = pos;
        const typed_len = cursor - pos;
        const typed = try self.alloc.alloc(u8, typed_len);
        defer self.alloc.free(typed);
        if (typed_len > 0) pt.copyRange(pos, typed);

        var counts = std.StringHashMap(u32).init(self.alloc);
        defer {
            var it = counts.iterator();
            while (it.next()) |e| self.alloc.free(e.key_ptr.*);
            counts.deinit();
        }

        // Scan the document in chunks, stitching words that straddle a chunk
        // boundary: the word bytes are accumulated in `pending` until a
        // non-word byte ends them. `pending_start` tracks the absolute start
        // of the word being assembled so the word currently being typed (the
        // one starting at completion_pos — it spans the cursor and continues
        // past it, e.g. "HELLObase" while typing HELLO into "base") is
        // excluded, exactly like blink.cmp skips the word under the cursor.
        var pending = std.ArrayList(u8).empty;
        defer pending.deinit(self.alloc);
        var pending_start: u32 = 0;
        var chunk: [4096]u8 = undefined;
        var off: u32 = 0;
        const doc_len = pt.len();
        while (off < doc_len) {
            const n: usize = @intCast(@min(chunk.len, doc_len - off));
            pt.copyRange(off, chunk[0..n]);
            var i: usize = 0;
            while (i < n) {
                if (isWordByte(chunk[i])) {
                    var j = i;
                    while (j < n and isWordByte(chunk[j])) j += 1;
                    if (pending.items.len == 0) pending_start = off + @as(u32, @intCast(i));
                    try pending.appendSlice(self.alloc, chunk[i..j]);
                    if (j == n) break; // may continue on the next chunk
                    try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
                    pending.clearRetainingCapacity();
                    i = j;
                } else {
                    if (pending.items.len > 0) {
                        try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
                        pending.clearRetainingCapacity();
                    }
                    i += 1;
                }
            }
            off += @intCast(n);
        }
        // a word running to the end of the document
        if (pending.items.len > 0) {
            try self.countCompletionWord(&counts, pending.items, typed, pending_start == self.completion_pos);
            pending.clearRetainingCapacity();
        }

        // (word, count) pairs, sorted by count desc then word asc
        const Pair = struct { word: []const u8, count: u32 };
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(self.alloc);
        {
            var it = counts.iterator();
            while (it.next()) |e| {
                try pairs.append(self.alloc, .{ .word = e.key_ptr.*, .count = e.value_ptr.* });
            }
        }
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.word, b.word);
            }
        }.lt);

        const max_words: usize = 20;
        const limit = @min(max_words, pairs.items.len);
        try self.completion_words.ensureTotalCapacity(self.alloc, limit);
        errdefer {
            for (self.completion_words.items) |it| self.alloc.free(it.text);
            self.completion_words.clearRetainingCapacity();
        }
        var k: usize = 0;
        while (k < limit) : (k += 1) {
            const w = try self.alloc.dupe(u8, pairs.items[k].word);
            try self.completion_words.append(self.alloc, .{ .text = w, .kind = 0 });
        }
        if (!keep_sel) self.completion_sel = 0;
    }

    /// Count one occurrence of `word` (skipping the word currently being
    /// typed). StringHashMap does not copy keys, and the scan buffers are
    /// reused, so keys are duplicated — the pending buffer can be overwritten
    /// by the very next word.
    fn countCompletionWord(self: *App, counts: *std.StringHashMap(u32), word: []const u8, typed: []const u8, is_current: bool) !void {
        // the word currently being typed (spans the cursor) is not a
        // candidate — blink skips it too
        if (is_current) return;
        // prefix filter: only words starting with the typed prefix are
        // candidates (vim C-n keyword completion); the exact typed word is
        // excluded
        if (word.len < typed.len or !std.mem.startsWith(u8, word, typed)) return;
        if (word.len == typed.len and std.mem.eql(u8, word, typed)) return;
        // fast path: word already counted — no allocation
        if (counts.getPtr(word)) |p| {
            p.* += 1;
            return;
        }
        const key = try self.alloc.dupe(u8, word);
        errdefer self.alloc.free(key);
        const gop = try counts.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            self.alloc.free(key); // duplicate of an existing key — drop ours
            gop.value_ptr.* += 1;
        }
    }

    /// Enter while the menu is open: replace the typed prefix
    /// [completion_pos, cursor) with the selected word — one edit inside the
    /// open insert-session undo group — then close the menu (insert stays
    /// active, the session continues). Matches the user's nvim (blink.cmp):
    /// Enter is the only accept key; Tab always inserts literal spaces.
    fn acceptCompletion(self: *App) !void {
        if (self.completion_words.items.len == 0 or self.completion_sel >= self.completion_words.items.len) {
            self.closeCompletion();
            return;
        }
        const word = self.completion_words.items[self.completion_sel].text;
        const pt = &self.cur().pt;
        const cursor = self.curCursor().*;
        const pos = @min(self.completion_pos, cursor);
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        try self.cur().history.record(pt, pos, cursor - pos, word);
        self.curCursor().* = pos + @as(u32, @intCast(word.len));
        self.markDirty();
        self.closeCompletion();
    }

    /// Drop the completion menu and free its candidate words (the list keeps
    /// its capacity for the next trigger).
    fn closeCompletion(self: *App) void {
        if (!self.completion_active and self.completion_words.items.len == 0) return;
        for (self.completion_words.items) |it| self.alloc.free(it.text);
        self.completion_words.clearRetainingCapacity();
        self.completion_active = false;
        self.completion_sel = 0;
        self.completion_pos = 0;
    }

    /// Enter in insert mode (vim semantics): split the current line at the
    /// cursor and carry the original line's leading indentation (the run of
    /// spaces/tabs before the cursor) over to the new line. The cursor lands
    /// right after the carried indentation (insertText advances it). Done as
    /// one edit so it is a single undo step.
    fn insertNewline(self: *App) !void {
        // safety net: the '\n' insertion must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const pt = &self.cur().pt;
        const cursor = self.curCursor().*;
        const line = pt.lineOf(cursor);
        const line_start = pt.lineStart(line);
        const col = cursor - line_start;
        // leading indentation of the original line, capped at the cursor
        var indent_end: u32 = 0;
        while (indent_end < col) : (indent_end += 1) {
            const b = pt.byteAt(line_start + indent_end);
            if (b != ' ' and b != '\t') break;
        }
        const indent = try self.alloc.alloc(u8, @intCast(indent_end));
        defer self.alloc.free(indent);
        pt.copyRange(line_start, indent);
        const text = try std.fmt.allocPrint(self.alloc, "\n{s}", .{indent});
        defer self.alloc.free(text);
        try self.insertText(text);
    }

    /// Ctrl+k in insert mode (emacs kill-line): delete from the cursor to the
    /// end of the line. When the cursor is already at the end of the line,
    /// delete the trailing newline instead, joining the next line (no-op on
    /// the last line).
    fn deleteToEol(self: *App) !void {
        // safety net: the kill must join the insert-session group
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const pt = &self.cur().pt;
        const cursor = self.curCursor().*;
        const line = pt.lineOf(cursor);
        const line_start = pt.lineStart(line);
        const line_end = line_start + pt.lineLen(line);
        const col = cursor - line_start;
        if (cursor < line_end) {
            const del_len: usize = @intCast(line_end - cursor);
            const deleted = try self.alloc.alloc(u8, del_len);
            defer self.alloc.free(deleted);
            pt.copyRange(cursor, deleted);
            try self.cur().history.record(pt, cursor, line_end - cursor, "");
            self.adjustInlayHintsDelete(line, col, deleted);
        } else if (line_end < pt.len()) {
            // at end of line: swallow the trailing newline (joins next line)
            try self.cur().history.record(pt, line_end, 1, "");
            self.adjustInlayHintsDelete(line, col, "\n");
        } else {
            return; // last line, nothing to delete
        }
        self.markDirty();
    }

    // ---- command line (':') ----

    fn handleCommandKey(self: *App, key: vaxis.Key) !void {
        // cancel
        if (key.codepoint == vaxis.Key.escape or (key.codepoint == 'c' and key.mods.ctrl)) {
            self.state.mode = .normal;
            // Esc cancelling ':' from visual mode must drop the anchor too
            // (it was kept so :'<,'>s could resolve the range on Enter).
            self.visual_anchor = null;
            self.pending_rename = false;
            self.cmdline_kind = .ex;
            self.cmdline.clearRetainingCapacity();
            self.cmd_hist_idx = null;
            self.cmd_complete_idx = 0;
            self.clearCmdCompleteNames();
            return;
        }
        switch (key.codepoint) {
            vaxis.Key.enter => {
                const from_visual = self.visual_anchor != null;
                if (self.pending_rename) {
                    // <leader>rn collected the new name — send the rename
                    self.state.mode = .normal;
                    self.cmd_hist_idx = null;
                    try self.execRename();
                    self.cmdline.clearRetainingCapacity();
                    return;
                }
                const line = self.cmdline.items;
                if (self.cmdline_kind != .ex) {
                    // '/' / '?' search: Enter jumps to the first match after
                    // (before) the cursor, wrapping; remembers the query for
                    // n/N. The text borrows the cmdline buffer — execSearch
                    // dupes what it keeps.
                    const bwd = self.cmdline_kind == .search_bwd;
                    self.state.mode = .normal;
                    self.cmdline_kind = .ex;
                    self.cmd_hist_idx = null;
                    self.cmd_complete_idx = 0;
                    self.clearCmdCompleteNames();
                    if (line.len > 0) try self.pushHistory(line);
                    try self.execSearch(line, bwd);
                    self.cmdline.clearRetainingCapacity();
                    return;
                }
                const cmd = editor.ex_command.parse(line);
                if (cmd != .empty) try self.pushHistory(line);
                self.state.mode = .normal;
                self.cmd_hist_idx = null;
                self.cmd_complete_idx = 0;
                self.clearCmdCompleteNames();
                // execCommand must run BEFORE clearing: Command slices borrow
                // the cmdline buffer (pattern/replacement/edit paths)
                try self.execCommand(cmd);
                if (from_visual) self.exitVisual();
                self.cmdline.clearRetainingCapacity();
            },
            vaxis.Key.backspace => {
                if (self.cmdline.items.len > 0) _ = self.cmdline.pop();
            },
            vaxis.Key.up => {
                self.cmd_hist_idx = if (self.cmd_hist_idx) |i|
                    if (i > 0) i - 1 else i
                else if (self.cmd_history.items.len > 0)
                    self.cmd_history.items.len - 1
                else
                    null;
                try self.loadHistory();
            },
            vaxis.Key.down => {
                self.cmd_hist_idx = if (self.cmd_hist_idx) |i|
                    if (i + 1 < self.cmd_history.items.len) i + 1 else null
                else
                    null;
                try self.loadHistory();
            },
            else => {},
        }
        // Tab: complete the command name (":w" → ":write") or, after
        // ":e " / ":edit ", the file path.
        if (key.codepoint == vaxis.Key.tab) {
            const line = self.cmdline.items;
            const is_path_ctx = (line.len >= 2 and (std.mem.eql(u8, line[0..2], "e ") or
                (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit "))));
            if (is_path_ctx) {
                try self.completeCommandPath();
            } else {
                try self.completeCommandName();
            }
            return;
        }

        // Ctrl-w: delete the word before the cursor (M0: back to last space)
        if (key.codepoint == 'w' and key.mods.ctrl) {
            var i = self.cmdline.items.len;
            while (i > 0 and self.cmdline.items[i - 1] != ' ') : (i -= 1) {}
            self.cmdline.shrinkRetainingCapacity(i);
            return;
        }
        if (key.text) |text| {
            try self.cmdline.appendSlice(self.alloc, text);
        }
    }

    /// Tab in command mode: complete the command NAME (":w" → ":write",
    /// ":b" → cycles ":bnext/:bprev/:buffers/:bdelete", …). The prefix is
    /// the token before the first space; repeated Tabs cycle through the
    /// ORIGINAL match list (stored, since the line becomes a full command
    /// name after the first Tab), advancing the completion cursor.
    fn completeCommandName(self: *App) !void {
        const line = self.cmdline.items;
        // the command token is up to the first space (or the whole line)
        var split: usize = 0;
        while (split < line.len and line[split] != ' ') : (split += 1) {}
        const prefix = line[0..split];
        if (prefix.len == 0) return;

        // first Tab: compute the match list for the typed prefix; later Tabs
        // reuse the stored list so cycling keeps working after completion
        if (self.cmd_complete_names.items.len == 0) {
            // canonical command names, matching ex_command.zig's parser
            const commands = [_][]const u8{
                "write",   "quit",       "quitall", "wq",    "edit",
                "vsplit",  "split",      "bnext",   "bprev", "buffers",
                "bdelete", "nohlsearch", "set",     "theme", "colorscheme",
                "noh",
            };
            for (commands) |c| {
                if (std.mem.startsWith(u8, c, prefix)) {
                    const copy = try self.alloc.dupe(u8, c);
                    errdefer self.alloc.free(copy);
                    try self.cmd_complete_names.append(self.alloc, copy);
                }
            }
            if (self.cmd_complete_names.items.len == 0) return;
            self.cmd_complete_idx = 0;
        }
        const matches = self.cmd_complete_names.items;
        const chosen = matches[self.cmd_complete_idx % matches.len];
        self.cmd_complete_idx += 1;

        // replace the command token with the full name
        self.cmdline.shrinkRetainingCapacity(0);
        try self.cmdline.appendSlice(self.alloc, chosen);
        // keep any existing argument (e.g. ":set " arg)
        if (split < line.len) {
            try self.cmdline.appendSlice(self.alloc, line[split..]);
        }
    }

    /// Tab in command mode: complete the path prefix after ":e ".
    /// Cycles through matches on repeated Tab.
    fn completeCommandPath(self: *App) !void {
        const line = self.cmdline.items;
        // find the token after "e " / "edit " (the leading ':' isn't stored)
        var skip: usize = 0;
        if (line.len >= 2 and std.mem.eql(u8, line[0..2], "e ")) {
            skip = 2;
        } else if (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit ")) {
            skip = 5;
        } else return;
        const prefix = line[skip..];

        var matches = std.ArrayList([]const u8).empty;
        defer {
            for (matches.items) |m| self.alloc.free(m);
            matches.deinit(self.alloc);
        }
        var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
        defer root.close(self.io);
        var files = std.ArrayList([]u8).empty;
        defer {
            for (files.items) |f| self.alloc.free(f);
            files.deinit(self.alloc);
        }
        try self.walkInto(root, "", &files);
        for (files.items) |f| {
            if (std.mem.startsWith(u8, f, prefix)) {
                const c = try self.alloc.dupe(u8, f);
                try matches.append(self.alloc, c);
            }
        }
        if (matches.items.len == 0) return;

        // cycle: self.cmd_complete_idx is the completion cursor
        // cycle through the matches: the FIRST Tab picks the first match,
        // further Tabs advance (the cursor is reset on command-line entry)
        const chosen = matches.items[self.cmd_complete_idx % matches.items.len];
        self.cmd_complete_idx += 1;

        // rebuild "e <chosen>" preserving the user's command form (e/edit)
        self.clearCmdCompleteNames();
        const cmd = if (line.len >= 5 and std.mem.eql(u8, line[0..5], "edit ")) "edit" else "e";
        self.cmdline.clearRetainingCapacity();
        try self.cmdline.appendSlice(self.alloc, cmd);
        try self.cmdline.appendSlice(self.alloc, " ");
        try self.cmdline.appendSlice(self.alloc, chosen);
    }

    /// Drop the stored command-name completion matches (owned strings).
    fn clearCmdCompleteNames(self: *App) void {
        for (self.cmd_complete_names.items) |n| self.alloc.free(n);
        self.cmd_complete_names.clearRetainingCapacity();
    }

    fn pushHistory(self: *App, line: []const u8) !void {
        if (self.cmd_history.items.len > 0 and
            std.mem.eql(u8, self.cmd_history.items[self.cmd_history.items.len - 1], line))
            return;
        const copy = try self.alloc.dupe(u8, line);
        errdefer self.alloc.free(copy);
        try self.cmd_history.append(self.alloc, copy);
        while (self.cmd_history.items.len > 100) {
            self.alloc.free(self.cmd_history.orderedRemove(0));
        }
    }

    fn loadHistory(self: *App) !void {
        self.cmdline.clearRetainingCapacity();
        if (self.cmd_hist_idx) |i| {
            try self.cmdline.appendSlice(self.alloc, self.cmd_history.items[i]);
        }
    }

    fn execCommand(self: *App, cmd: editor.ex_command.Command) !void {
        switch (cmd) {
            .empty => {},
            .write => _ = try self.writeBuffer(),
            .quit => {
                // vim E37: refuse to quit when the current buffer has
                // unsaved changes — data loss is worse than a message.
                if (self.cur().dirty) {
                    try self.setMsg(try self.alloc.dupe(u8, "E37: No write since last change (add ! to override)"));
                    return;
                }
                self.closeWindow(); // :q closes the focused window (or its buffer when it is the last window)
            },
            .quit_force => self.closeWindow(),
            .quit_all => self.quit = true,
            .vsplit => try self.splitWindow(.vertical),
            .split => try self.splitWindow(.horizontal),
            .write_quit => {
                // only quit when the write actually succeeded
                if (try self.writeBuffer()) self.quit = true;
            },
            .edit => |path| try self.openFile(path),
            .buffer_next => try self.switchBuffer(1),
            .buffer_prev => try self.switchBuffer(-1),
            .buffer_delete => self.closeCurrentBuffer(),
            .buffer_list => try self.listBuffers(),
            .noh => try self.setMsg(try self.alloc.dupe(u8, "")),
            .goto_line => |ln| {
                // :<number> — vim: 1-based, clamped to the last line (:0
                // and :1 both land on the first line)
                const target = @min(ln -| 1, self.cur().pt.lineCount() - 1);
                self.curCursor().* = self.cur().pt.lineStart(target);
                self.clearHover();
            },
            .set => |opt| try self.setMsg(try std.fmt.allocPrint(self.alloc, "set {s} (M0: accepted, no-op)", .{opt})),
            .theme => |name| try self.execTheme(name),
            .substitute => |sub| try self.execSubstitute(sub),
            .unknown => try self.setMsg(try self.alloc.dupe(u8, "E492: Not an editor command")),
        }
    }

    /// :theme [name] — switch the color theme. With no argument, list the
    /// available themes (Tab in the command line cycles suggestions).
    fn execTheme(self: *App, name: []const u8) !void {
        if (name.len == 0) {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(self.alloc);
            try out.appendSlice(self.alloc, "themes: ");
            for (theme.themes, 0..) |t, i| {
                if (i > 0) try out.appendSlice(self.alloc, ", ");
                try out.appendSlice(self.alloc, t.name);
            }
            try self.setMsg(try out.toOwnedSlice(self.alloc));
            return;
        }
        const t = theme.byName(name) orelse {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "unknown theme: {s} (see :theme)", .{name}));
            return;
        };
        self.theme = t;
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "theme: {s}", .{t.name}));
    }

    /// :s/pat/rep[/g] — literal substitution on the current line, the whole
    /// file (:%), or the visual selection (:'<,'>, M1: no regex). The
    /// replacement lands in one undo group.
    fn execSubstitute(self: *App, sub: anytype) !void {
        var start_line: u32 = undefined;
        var end_line: u32 = undefined;
        if (sub.visual) {
            const anchor = self.visual_anchor orelse return;
            const s = @min(anchor, self.curCursor().*);
            const e = @max(anchor, self.curCursor().*);
            start_line = self.cur().pt.lineOf(s);
            end_line = self.cur().pt.lineOf(e);
        } else if (sub.whole_file) {
            start_line = 0;
            end_line = self.cur().pt.lineCount() - 1;
        } else {
            start_line = self.cur().pt.lineOf(self.curCursor().*);
            end_line = start_line;
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        // The parser keeps an escaped separator `\/` verbatim; restore it so
        // literal matching sees the real slash (ex_command.unescapeSubSep).
        const pat = try editor.ex_command.unescapeSubSep(self.alloc, sub.pattern);
        defer self.alloc.free(pat);
        const rep = try editor.ex_command.unescapeSubSep(self.alloc, sub.replacement);
        defer self.alloc.free(rep);
        var changed: bool = false;
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const ll = self.cur().pt.lineLen(line);
            const ls = self.cur().pt.lineStart(line);
            const buf = try self.alloc.alloc(u8, ll);
            defer self.alloc.free(buf);
            self.cur().pt.copyRange(ls, buf);

            const n = replaceLiteral(&out, self.alloc, buf, pat, rep, sub.global);
            if (n > 0) changed = true;
            if (line < self.cur().pt.lineCount() - 1) try out.append(self.alloc, '\n');
        }

        if (!changed) {
            try self.setMsg(try self.alloc.dupe(u8, "E486: Pattern not found"));
            return;
        }
        const start = self.cur().pt.lineStart(start_line);
        var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
        if (end_line + 1 < self.cur().pt.lineCount()) end += 1;
        try self.applyEdit(start, end, out.items);
    }

    /// :ls — list buffers in the status message.
    fn listBuffers(self: *App) !void {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(self.alloc);
        for (self.buffers.items, 0..) |*buf, i| {
            if (i > 0) try list.append(self.alloc, ' ');
            const marker = if (buf.dirty) "+" else " ";
            const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
            const part = try std.fmt.allocPrint(self.alloc, "{s}{d} {s}", .{ marker, i + 1, name });
            defer self.alloc.free(part);
            try list.appendSlice(self.alloc, part);
        }
        try self.setMsg(try list.toOwnedSlice(self.alloc));
    }

    fn setMsg(self: *App, owned: []u8) !void {
        if (self.msg) |m| self.alloc.free(m);
        self.msg = owned;
    }

    // ---- buffer search (/ ? n N) ----

    /// Execute a '/' / '?' search: plain substring (no regex, like :s), from
    /// just after (forward) or before (backward) the cursor, wrapping around
    /// the buffer edges like vim. The query is remembered for n/N.
    fn execSearch(self: *App, query: []const u8, backward: bool) !void {
        if (query.len == 0) return;
        // remember for n/N (dupes — `query` borrows the cmdline buffer)
        if (self.last_search) |q| self.alloc.free(q);
        self.last_search = try self.alloc.dupe(u8, query);
        self.last_search_bwd = backward;
        try self.searchOnce(query, backward);
    }

    /// n / N: repeat the remembered search; `flip` inverts the direction.
    fn repeatSearch(self: *App, flip: bool) !void {
        const q = self.last_search orelse {
            try self.setMsg(try self.alloc.dupe(u8, "no previous search"));
            return;
        };
        try self.searchOnce(q, self.last_search_bwd != flip);
    }

    fn searchOnce(self: *App, query: []const u8, backward: bool) !void {
        const len = self.cur().pt.len();
        if (len == 0) return;
        const text = try self.curText();
        defer self.alloc.free(text);
        const cursor = self.curCursor().*;
        var hit: ?usize = null;
        if (backward) {
            // last match starting before the cursor, else wrap to the file end
            hit = std.mem.lastIndexOf(u8, text[0..@min(cursor, len)], query);
            if (hit == null) {
                const from = @min(cursor + 1, len);
                if (std.mem.lastIndexOf(u8, text[from..], query)) |i| hit = from + i;
            }
        } else {
            // first match starting after the cursor, else wrap to the top
            const from = @min(cursor + 1, len);
            if (std.mem.indexOf(u8, text[from..], query)) |i| {
                hit = from + i;
            } else {
                hit = std.mem.indexOf(u8, text[0..from], query);
            }
        }
        if (hit) |h| {
            self.curCursor().* = @intCast(h);
            self.clearHover();
        } else {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "pattern not found: {s}", .{query}));
        }
    }

    /// Leading spaces/tabs of `line` (owned copy) — used to auto-indent new
    /// lines opened with o/O.
    fn leadingIndent(self: *App, line: u32) ![]u8 {
        const pt = &self.cur().pt;
        const start = pt.lineStart(line);
        const len = pt.lineLen(line);
        var n: usize = 0;
        while (n < len) : (n += 1) {
            const c = pt.byteAt(start + @as(u32, @intCast(n)));
            if (c != ' ' and c != '\t') break;
        }
        const out = try self.alloc.alloc(u8, n);
        pt.copyRange(start, out);
        return out;
    }

    /// Drop stale inlay hints after any edit: their line/column offsets refer
    /// to the pre-edit text, so a leftover hint would render at the wrong spot
    /// (an inserted line pushes every hint down by one). The auto-refresh in
    /// the run loop re-requests hints for the new viewport.
    fn invalidateInlayHints(self: *App) void {
        for (self.inlay_hints.items) |*h| self.alloc.free(h.label);
        self.inlay_hints.clearRetainingCapacity();
        self.inlay_view_top = null;
        self.inlay_stale = true;
    }

    /// Shift inlay hints after inserting `text` at the pre-edit position
    /// (line, col). Same-line inserts shift later hints right; newline
    /// inserts push hints below down a line (and re-anchor those past the
    /// split point onto the new line). Kept hints stay aligned while typing,
    /// which is what keeps the insert-mode view from flickering.
    fn adjustInlayHintsInsert(self: *App, line: u32, col: u32, text: []const u8) void {
        if (self.inlay_hints.items.len == 0) return;
        const nl = std.mem.count(u8, text, "\n");
        if (nl == 0) {
            for (self.inlay_hints.items) |*h| {
                if (h.line == line and h.character >= col) {
                    h.character += @intCast(text.len);
                }
            }
            return;
        }
        // text contains newline(s): the tail after the last '\n' stays on the
        // current line past the split point
        const tail = text.len - (std.mem.lastIndexOfScalar(u8, text, '\n') orelse return) - 1;
        const tail_u32: u32 = @intCast(tail);
        for (self.inlay_hints.items) |*h| {
            if (h.line > line) {
                h.line += @intCast(nl);
            } else if (h.line == line and h.character >= col) {
                h.line += @intCast(nl);
                h.character = h.character - col + tail_u32;
            }
        }
    }

    /// Shift inlay hints after deleting `deleted` (the pre-edit bytes) from
    /// (line, col). Hints inside the deleted span are dropped; same-line
    /// deletes shift later hints left; multi-line deletes pull hints below up.
    fn adjustInlayHintsDelete(self: *App, line: u32, col: u32, deleted: []const u8) void {
        if (self.inlay_hints.items.len == 0) return;
        const nl = std.mem.count(u8, deleted, "\n");
        if (nl == 0) {
            // same-line delete: drop hints inside [col, col+len), shift the
            // rest left
            var write: usize = 0;
            for (self.inlay_hints.items) |*h| {
                if (h.line != line or h.character < col or h.character >= col + deleted.len) {
                    if (h.line == line and h.character >= col) h.character -= @intCast(deleted.len);
                    self.inlay_hints.items[write] = h.*;
                    write += 1;
                } else {
                    self.alloc.free(h.label); // inside the deleted span
                }
            }
            self.inlay_hints.shrinkRetainingCapacity(write);
            return;
        }
        // multi-line delete: the span covers the tail of `line` from `col`,
        // all of lines (line, line+nl), and the head of line (line+nl) up to
        // its end column E. Middle lines are dropped entirely; the last
        // line's surviving tail re-anchors onto `line` at col + offset.
        const last_nl = std.mem.lastIndexOfScalar(u8, deleted, '\n') orelse return;
        const end_col: u32 = @intCast(deleted.len - last_nl - 1);
        const last_line = line + nl;
        var write: usize = 0;
        for (self.inlay_hints.items) |*h| {
            if (h.line < line or (h.line == line and h.character < col)) {
                self.inlay_hints.items[write] = h.*;
                write += 1;
                continue;
            }
            if (h.line == last_line and h.character >= end_col) {
                h.line = line;
                h.character = col + (h.character - end_col);
                self.inlay_hints.items[write] = h.*;
                write += 1;
                continue;
            }
            if (h.line > last_line) {
                h.line -= @intCast(nl);
                self.inlay_hints.items[write] = h.*;
                write += 1;
                continue;
            }
            self.alloc.free(h.label); // inside the deleted span
        }
        self.inlay_hints.shrinkRetainingCapacity(write);
    }

    /// Inlay hints for one line, sorted by insertion column (ascending), as
    /// arena slices so they live for the frame. Hints with a character inside
    /// the line's text are kept at that column — the renderer splices them in.
    fn lineHints(self: *App, a: std.mem.Allocator, line: u32) ![]InlayHint {
        var out = std.ArrayList(InlayHint).empty;
        for (self.inlay_hints.items) |hint| {
            if (hint.line != line) continue;
            try out.append(a, hint);
        }
        std.mem.sort(InlayHint, out.items, {}, struct {
            fn lt(_: void, x: InlayHint, y: InlayHint) bool {
                return x.character < y.character;
            }
        }.lt);
        return out.toOwnedSlice(a);
    }

    /// Resolve `path` (possibly relative to the process cwd) into an absolute
    /// path. Returns a heap copy; the caller owns it. Falls back to a plain
    /// dupe on failure so file opening never breaks on a resolution error.
    fn absolutePath(self: *App, path: []const u8) ![]u8 {
        if (path.len > 0 and path[0] == '/') return self.alloc.dupe(u8, path);
        var cwd_buf: [4096:0]u8 = undefined;
        const cwd_len = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
        if (cwd_len == 0) return self.alloc.dupe(u8, path);
        // getcwd returns the buffer length INCLUDING the terminating NUL
        // (the raw syscall result); slicing with it embeds a \0 in the path,
        // which later fails as BadPathName on createFile/write (openat just
        // truncates at the NUL, so opening still works — the saved path is
        // silently corrupt). Trim to the C-string length.
        var n: usize = 0;
        while (n < cwd_buf.len and cwd_buf[n] != 0) : (n += 1) {}
        return std.Io.Dir.path.resolve(self.alloc, &.{ cwd_buf[0..n], path }) catch
            self.alloc.dupe(u8, path);
    }

    /// :w — write the current buffer. Returns false (with a status message)
    /// when there is no file name or the write fails, so callers like :wq
    /// must NOT proceed to quit on failure.
    fn writeBuffer(self: *App) !bool {
        const path = self.cur().path orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E32: No file name"));
            return false;
        };
        self.saveFile(path) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "write failed: {s}", .{@errorName(e)}));
            return false;
        };
        self.cur().dirty = false;
        // the file on disk changed: refresh git marks/branch (async)
        self.scheduleGitStatus();
        try self.setMsg(try std.fmt.allocPrint(self.alloc, "written: {s}", .{path}));
        return true;
    }

    fn saveFile(self: *App, path: []const u8) !void {
        var f = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer f.close(self.io);
        const len = self.cur().pt.len();
        const buf = try self.alloc.alloc(u8, len);
        defer self.alloc.free(buf);
        self.cur().pt.copyRange(0, buf);
        try f.writeStreamingAll(self.io, buf);
    }

    fn openFile(self: *App, path: []const u8) !void {
        // Multi-buffer semantics: open in a new buffer (or switch if open).
        try self.openInBuffer(path);
    }

    fn insertText(self: *App, text: []const u8) !void {
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const pos = self.curCursor().*;
        const line = self.cur().pt.lineOf(pos);
        const col = pos - self.cur().pt.lineStart(line);
        // record() snapshots the pre-edit state and applies the edit itself
        try self.cur().history.record(&self.cur().pt, pos, 0, text);
        self.curCursor().* += @intCast(text.len);
        // keep inlay hints aligned instead of clearing them (insert mode:
        // clearing + re-requesting on every keystroke makes the view flicker)
        self.adjustInlayHintsInsert(line, col, text);
        self.markDirty();
    }

    // ---- auto-pairs (insert mode): 括号/引号自动闭合与跳过 ----

    /// Matching closer for an opener; the quote chars pair with themselves.
    fn pairCloser(ch: u8) ?u8 {
        return switch (ch) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            '"', '\'', '`' => ch,
            else => null,
        };
    }

    /// Auto-pair handling for one typed character (insert mode, single
    /// cursor — multi-cursor edits go through handleMcInsertKey and stay
    /// literal). Returns true when the key was handled here:
    /// - opener: insert the pair, cursor ends up between the two
    /// - quote: same, but not right after a word char ("don't"), and typing
    ///   the quote again over an identical quote skips over it
    /// - closer: when the cursor sits on that same closer, skip over it
    ///   instead of inserting a duplicate
    fn autoPairInsert(self: *App, text: []const u8) !bool {
        if (text.len != 1) return false;
        const ch = text[0];
        const pos = self.curCursor().*;
        const len = self.cur().pt.len();
        switch (ch) {
            '(', '[', '{' => {
                try self.insertText(&[_]u8{ ch, pairCloser(ch).? });
                self.curCursor().* = pos + 1;
                return true;
            },
            '"', '\'', '`' => {
                if (pos < len and self.cur().pt.byteAt(pos) == ch) {
                    self.curCursor().* = pos + 1; // skip over
                    return true;
                }
                if (pos > 0 and isWordByte(self.cur().pt.byteAt(pos - 1))) return false;
                try self.insertText(&[_]u8{ ch, ch });
                self.curCursor().* = pos + 1;
                return true;
            },
            ')', ']', '}' => {
                if (pos < len and self.cur().pt.byteAt(pos) == ch) {
                    self.curCursor().* = pos + 1; // skip over
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Backspace between an empty pair (`(|)`, `"|"`, …) deletes both sides
    /// as one undo record. Returns true when it handled the keypress.
    fn autoPairBackspace(self: *App) !bool {
        const pos = self.curCursor().*;
        if (pos == 0 or pos >= self.cur().pt.len()) return false;
        const open = self.cur().pt.byteAt(pos - 1);
        const closer = pairCloser(open) orelse return false;
        if (self.cur().pt.byteAt(pos) != closer) return false;
        if (!self.in_insert) {
            self.cur().history.beginGroup();
            self.in_insert = true;
        }
        const start = pos - 1;
        const line = self.cur().pt.lineOf(start);
        const col = start - self.cur().pt.lineStart(line);
        try self.cur().history.record(&self.cur().pt, start, 2, "");
        self.curCursor().* = start;
        self.adjustInlayHintsDelete(line, col, &[_]u8{ open, closer });
        self.markDirty();
        return true;
    }

    /// Visual-selection end semantics: vim's character-wise selection includes
    /// the character under the cursor.
    const SelEnd = enum { exclusive_cursor, inclusive_cursor };

    /// Write [start, end) into the unnamed register (vim: y AND d/c all fill
    /// it — dd p is cut-paste). `linewise` is the register's type and decides
    /// how p/P puts the text (whole lines below/above vs inline).
    fn setRegister(self: *App, start: u32, end: u32, linewise: bool) !void {
        if (self.yank_buffer) |b| self.alloc.free(b);
        const buf = try self.alloc.alloc(u8, end - start);
        self.cur().pt.copyRange(start, buf);
        self.yank_buffer = buf;
        self.yank_linewise = linewise;
    }

    /// Apply an operator (d/c/y) over a range. `exclusive` trims the end char
    /// (vim exclusive motions); text objects and selections pass false with an
    /// already-exact range. `linewise` marks the register type (vim regtype).
    fn applyOpRange(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool, linewise: bool) !void {
        try self.applyOpRangeEx(op, from, to, exclusive, .exclusive_cursor, linewise);
    }

    fn applyOpRangeEx(self: *App, op: editor.KeyEvent.ActionId, from: u32, to: u32, exclusive: bool, sel: SelEnd, linewise: bool) !void {
        const start = @min(from, to);
        var end = @max(from, to);
        if (exclusive and end > start) end -= 1;
        if (sel == .inclusive_cursor and end < self.cur().pt.len()) end += 1;
        if (end <= start) {
            if (op == .change) {
                // empty range (e.g. cc on an empty line): enter insert with
                // the undo group already open so typing joins one session
                self.cur().history.beginGroup();
                self.state.mode = .insert;
                self.in_insert = true;
            }
            // yy on an empty line (incl. the phantom EOF line a trailing
            // newline creates): yanks an empty LINE, so p/P still put an
            // empty line instead of erroring E353
            if (op == .yank and linewise) try self.setRegister(start, start, true);
            return;
        }
        switch (op) {
            .delete => {
                try self.setRegister(start, end, linewise);
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, start, end - start, "");
                self.cur().history.endGroup();
                self.curCursor().* = start;
                // deleting the last real line lands on the phantom empty
                // line a trailing '\n' creates; nvim clamps the cursor to
                // the last REAL line (dd at EOF, then p/P pastes relative
                // to it)
                if (self.cur().pt.len() > 0 and self.curCursor().* >= self.cur().pt.len()) {
                    const lc = self.cur().pt.lineCount();
                    self.curCursor().* = self.cur().pt.lineStart(lc -| 2);
                }
                self.markDirty();
            },
            .change => {
                try self.setRegister(start, end, linewise);
                self.curCursor().* = start;
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, start, end - start, "");
                self.state.mode = .insert;
                self.in_insert = true; // keep the group open; exitInsert closes it
                self.markDirty();
                self.cur().syntax_revision = std.math.maxInt(u64);
            },
            .yank => {
                try self.setRegister(start, end, linewise);
                try self.setMsg(try std.fmt.allocPrint(self.alloc, "yanked {d} bytes", .{self.yank_buffer.?.len}));
            },
            else => {},
        }
    }

    // ---- surround (ys / ds / cs) ----

    fn execSurround(self: *App, s: anytype) !void {
        switch (s.op) {
            .add => {
                const rng = self.surroundRange(s.motion, s.args, s.count, s.text_object) orelse return;
                const res = try editor.surround.add(self.alloc, &self.cur().pt, .{ .start = rng.start, .end = rng.end }, s.ch);
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
            },
            .delete => {
                const res = (try editor.surround.delete(self.alloc, &self.cur().pt, self.curCursor().*)) orelse {
                    try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                    return;
                };
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
                self.curCursor().* = res.start;
            },
            .change => {
                const res = (try editor.surround.change(self.alloc, &self.cur().pt, self.curCursor().*, s.ch)) orelse {
                    try self.setMsg(try self.alloc.dupe(u8, "E54: Unmatched delimiter"));
                    return;
                };
                defer self.alloc.free(res.text);
                try self.applyEdit(res.start, res.end, res.text);
                self.curCursor().* = res.start;
            },
        }
    }

    /// Range covered by a surround-add motion/text object; trailing whitespace
    /// is trimmed so ysw wraps the word, not "word " (vim-surround behavior).
    fn surroundRange(self: *App, motion: ?editor.Motion.Motion, args: editor.Motion.Args, count: u32, text_object: ?editor.TextObject.Kind) ?editor.TextObject.Range {
        var rng: editor.TextObject.Range = undefined;
        if (text_object) |kind| {
            const r = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, count);
            rng = .{ .start = r.start, .end = r.end };
        } else if (motion) |m| {
            const target = editor.Motion.target(&self.cur().pt, m, args, self.curCursor().*, count);
            rng = .{ .start = @min(self.curCursor().*, target), .end = @max(self.curCursor().*, target) };
        } else return null;
        // trim trailing spaces/tabs (not newlines)
        while (rng.end > rng.start) {
            const c = self.cur().pt.byteAt(rng.end - 1);
            if (c != ' ' and c != '\t') break;
            rng.end -= 1;
        }
        return rng;
    }

    /// ga: align lines [start_line, end_line] on the first `char`.
    fn execAlign(self: *App, a: anytype) !void {
        var start_line: u32 = undefined;
        var end_line: u32 = undefined;
        if (a.selection) {
            const anchor = self.visual_anchor orelse return;
            const s = @min(anchor, self.curCursor().*);
            const e = @max(anchor, self.curCursor().*);
            start_line = self.cur().pt.lineOf(s);
            end_line = self.cur().pt.lineOf(e);
            self.exitVisual();
        } else {
            var rng: editor.TextObject.Range = undefined;
            if (a.text_object) |kind| {
                const r = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, a.count);
                rng = .{ .start = r.start, .end = r.end };
            } else if (a.motion) |m| {
                const target = editor.Motion.target(&self.cur().pt, m, a.args, self.curCursor().*, a.count);
                rng = .{ .start = @min(self.curCursor().*, target), .end = @max(self.curCursor().*, target) };
            } else return;
            start_line = self.cur().pt.lineOf(rng.start);
            end_line = self.cur().pt.lineOf(rng.end);
            if (rng.end > rng.start and rng.end == self.cur().pt.lineStart(rng.end)) end_line -|= 1;
        }
        const text = try editor.align_text.alignLines(self.alloc, &self.cur().pt, start_line, end_line, a.char);
        defer self.alloc.free(text);
        const start = self.cur().pt.lineStart(start_line);
        var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
        if (end_line + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
        try self.applyEdit(start, end, text);
        self.curCursor().* = start;
    }

    fn applyEdit(self: *App, start: u32, end: u32, text: []const u8) !void {
        self.cur().history.beginGroup();
        try self.cur().history.record(&self.cur().pt, start, end - start, text);
        self.cur().history.endGroup();
        self.markDirty();
    }

    fn isVisual(self: *const App) bool {
        return switch (self.state.mode) {
            .visual_char, .visual_line, .visual_block => true,
            else => false,
        };
    }

    /// gcc: comment/uncomment the current line (vim semantics: fully commented
    /// lines get uncommented, otherwise everything is commented).
    fn toggleCommentLine(self: *App) !void {
        const ft = filetypeOf(self.cur().path);
        const style = editor.comment.styleForFiletype(ft) orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E505: No comment style for filetype"));
            return;
        };
        // in visual mode the whole selection's lines are toggled; otherwise
        // just the cursor line
        const from_line: u32 = if (self.visual_anchor) |anchor|
            @min(self.cur().pt.lineOf(anchor), self.cur().pt.lineOf(self.curCursor().*))
        else
            self.cur().pt.lineOf(self.curCursor().*);
        const to_line: u32 = if (self.visual_anchor) |anchor|
            @max(self.cur().pt.lineOf(anchor), self.cur().pt.lineOf(self.curCursor().*))
        else
            from_line;
        const toggle = try editor.comment.toggleLines(self.alloc, &self.cur().pt, from_line, to_line, style);
        defer self.alloc.free(toggle.text);
        const start = self.cur().pt.lineStart(from_line);
        const end = self.cur().pt.lineStart(to_line) + self.cur().pt.lineLen(to_line); // toggleLines text excludes the trailing '\n'
        try self.applyEdit(start, end, toggle.text);
        self.curCursor().* = start;
    }

    fn exitVisual(self: *App) void {
        self.state.mode = .normal;
        self.visual_anchor = null;
    }

    /// Visual-mode d/c/y teardown: `.change` keeps the insert mode that
    /// applyOpRangeEx/applyBlockOp entered (vim: c on a selection types in
    /// insert); only the stale anchor is cleared. Other operators exit to
    /// normal.
    fn exitVisualAfterOp(self: *App, op: editor.KeyEvent.ActionId) void {
        if (op == .change) {
            self.visual_anchor = null;
        } else {
            self.exitVisual();
        }
    }

    /// Ctrl+n: first press selects the word under the cursor, later presses
    /// add the next matching word as another cursor.
    fn mcSelectNext(self: *App) !void {
        if (!self.mc_active) {
            self.mc.clear();
            _ = try self.mc.add(self.curCursor().*);
            self.mc_active = true;
        } else {
            const added = try self.mc.addNextMatch(&self.cur().pt);
            if (added) {
                // The main cursor follows the newest match (vim's multi-cursor
                // moves the cursor to each new selection as you press n); the
                // render pass keeps the cursor line on screen. `main` stays at
                // the FIRST cursor (the original word), so the newest match is
                // always the last slot.
                self.curCursor().* = self.mc.cursors.items[self.mc.cursors.items.len - 1];
            }
        }
    }

    /// 'c' with an active multi-cursor selection: delete the word under every
    /// cursor (right-to-left, so earlier positions stay valid) and enter
    /// insert mode with the cursors still on their word-start slots. Cursors
    /// at/after each deleted range shift back so every position stays valid
    /// (unlike the 'd' path — 'd' clears the cursors, 'c' keeps them for the
    /// synchronized insert session via handleMcInsertKey). The deletion is
    /// one undo group; typing opens the next one.
    fn mcChangeWords(self: *App) !void {
        const pt = &self.cur().pt;
        self.cur().history.beginGroup();
        var i = self.mc.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const pos = self.mc.cursors.items[i];
            const w = self.mc.wordRange(pt, pos);
            if (w.end <= w.start) continue; // no word at this cursor → skip it
            const wlen = w.end - w.start;
            try self.cur().history.record(pt, pos, wlen, "");
            // shift every other cursor at/after the deleted range back; the
            // cursor at `pos` (a word start) stays put
            for (self.mc.cursors.items, 0..) |*c, j| {
                if (j == i) continue;
                if (c.* >= pos + wlen) {
                    c.* -= wlen;
                } else if (c.* > pos) {
                    c.* = pos; // inside the deleted word — clamp (never happens)
                }
            }
        }
        self.cur().history.endGroup();
        self.mc_active = true; // stays active: the insert session is synchronized
        self.state.mode = .insert;
        // open the insert-session group immediately (deletes or typing first);
        // the word deletions above are their own group (undo reverts typing
        // first, then the deletions — same as before)
        self.cur().history.beginGroup();
        self.in_insert = true;
        self.prev_insert_key = null;
        self.mcSyncCursor();
        self.markDirty();
    }

    // ---- file tree (<leader>e / <leader>E) ----

    fn toggleFiletree(self: *App) !void {
        if (self.filetree_active) {
            self.filetree_active = false;
            return;
        }
        self.filetree_top = 0;
        self.filetree_sel = 0;
        self.focus = .filetree;
        if (self.filetree_root == null) {
            // Build the cwd node; only its first level is scanned — deeper
            // directories are walked lazily when expanded (snacks style).
            const root = try self.alloc.create(TreeNode);
            root.* = .{
                .name = try self.alloc.dupe(u8, ""),
                .path = try self.alloc.dupe(u8, ""),
                .is_dir = true,
                .expanded = true, // the cwd's own children are visible
                .children = .empty,
                .parent = null,
            };
            var dir = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
            defer dir.close(self.io);
            try self.walkTreeLevel(dir, root);
            self.sortTreeChildren(root);
            self.filetree_root = root;
        }
        try self.rebuildFiletreeRows();
        self.filetree_active = true;
    }

    /// Walk one directory level into `node.children` (lazy expansion).
    fn walkTreeLevel(self: *App, dir: std.Io.Dir, node: *TreeNode) !void {
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;
            if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
            const is_dir = (entry.kind == .directory);
            const child_path = try std.fmt.allocPrint(self.alloc, "{s}{s}{s}", .{ node.path, name, if (is_dir) "/" else "" });
            errdefer self.alloc.free(child_path);
            const child_name = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(child_name);
            const child = try self.alloc.create(TreeNode);
            errdefer self.alloc.destroy(child);
            child.* = .{
                .name = child_name,
                .path = child_path,
                .is_dir = is_dir,
                .expanded = false,
                .children = .empty,
                .parent = node,
            };
            try node.children.append(self.alloc, child);
        }
    }

    /// Directories first, then files; each group sorted by byte order.
    fn sortTreeChildren(self: *App, node: *TreeNode) void {
        _ = self;
        std.mem.sort(*TreeNode, node.children.items, {}, struct {
            fn lt(_: void, a: *TreeNode, b: *TreeNode) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }

    fn expandDir(self: *App, node: *TreeNode) !void {
        if (!node.is_dir or node.expanded) return;
        // Children are loaded exactly once, on first expand. A collapsed dir
        // KEEPS its loaded children (collapseDir only flips `expanded`), so a
        // re-expand must not walk the directory again — walkTreeLevel appends
        // to children, and re-walking after every h/l cycle duplicated every
        // entry (the tree grew on each toggle). Only a never-loaded dir
        // (children still empty) hits the filesystem.
        if (node.children.items.len == 0) {
            var dir = try std.Io.Dir.cwd().openDir(self.io, node.path, .{ .iterate = true });
            defer dir.close(self.io);
            try self.walkTreeLevel(dir, node);
            self.sortTreeChildren(node);
        }
        node.expanded = true;
        try self.rebuildFiletreeRows();
    }

    /// Collapse an expanded dir; its (already loaded) children stay in the
    /// tree but become invisible until re-expanded.
    fn collapseDir(self: *App, node: *TreeNode) !void {
        if (!node.is_dir or !node.expanded) return;
        node.expanded = false;
        try self.rebuildFiletreeRows();
    }

    /// DFS over the expanded subtree starting at the root's children.
    fn rebuildFiletreeRows(self: *App) !void {
        self.filetree_rows.clearRetainingCapacity();
        const root = self.filetree_root orelse return;
        try self.appendTreeRows(root, 0, &self.filetree_rows);
    }

    fn appendTreeRows(self: *App, node: *TreeNode, depth: usize, rows: *std.ArrayList(FiletreeRow)) !void {
        for (node.children.items) |child| {
            try rows.append(self.alloc, .{ .node = child, .depth = depth });
            if (child.is_dir and child.expanded) try self.appendTreeRows(child, depth + 1, rows);
        }
    }

    fn filetreeNodeAt(self: *App, idx: usize) ?*TreeNode {
        if (idx < self.filetree_rows.items.len) return self.filetree_rows.items[idx].node;
        return null;
    }

    /// Row index of `node` in the visible list, or null.
    fn rowIndexOf(self: *App, node: *TreeNode) ?usize {
        for (self.filetree_rows.items, 0..) |row, i| {
            if (row.node == node) return i;
        }
        return null;
    }

    fn locateInFiletree(self: *App) !void {
        if (self.filetree_root == null) {
            try self.toggleFiletree();
        } else {
            try self.rebuildFiletreeRows();
        }
        self.focus = .filetree;
        if (self.cur().path) |p| {
            // Reveal the file's ancestors (expanding any folded dirs on the
            // way) and select the matching row.
            if (try self.revealPath(p)) |node| {
                if (self.rowIndexOf(node)) |i| {
                    self.filetree_sel = i;
                    self.filetree_top = 0;
                }
            }
        }
        self.filetree_active = true;
    }

    /// Walk the tree along `path`'s components, expanding any ancestor dir,
    /// and return the node matching the final component (or null).
    fn revealPath(self: *App, path: []const u8) !?*TreeNode {
        const root = self.filetree_root orelse return null;
        var cur_node = root;
        var rest = path;
        while (rest.len > 0) {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const comp = rest[0..slash];
            var found: ?*TreeNode = null;
            for (cur_node.children.items) |child| {
                if (std.mem.eql(u8, child.name, comp)) {
                    found = child;
                    break;
                }
            }
            const child = found orelse return null;
            if (slash == rest.len) return child;
            if (child.is_dir and !child.expanded) try self.expandDir(child);
            cur_node = child;
            rest = rest[slash + 1 ..];
        }
        return null;
    }

    /// j/k/Enter/Esc/h/l for the tree; returns true if consumed.
    fn filetreeKey(self: *App, key: vaxis.Key) !bool {
        switch (key.codepoint) {
            'j', vaxis.Key.down => {
                if (self.filetree_sel + 1 < self.filetree_rows.items.len) self.filetree_sel += 1;
                return true;
            },
            'k', vaxis.Key.up => {
                if (self.filetree_sel > 0) self.filetree_sel -= 1;
                return true;
            },
            // h: fold the current dir; on an already-folded dir jump to its
            // parent's row. Files swallow h (no-op) so it never reaches the
            // buffer — pane switching is Ctrl-w hjkl.
            'h', vaxis.Key.left => {
                const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
                if (node.is_dir and node.expanded) {
                    try self.collapseDir(node);
                } else if (node.is_dir and !node.expanded) {
                    if (node.parent) |parent| {
                        if (parent != self.filetree_root) {
                            if (self.rowIndexOf(parent)) |i| self.filetree_sel = i;
                        }
                    }
                }
                return true;
            },
            // l: expand the current dir (swallowed on files / open dirs).
            'l', vaxis.Key.right => {
                const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
                if (node.is_dir and !node.expanded) try self.expandDir(node);
                return true;
            },
            vaxis.Key.enter => {
                const node = self.filetreeNodeAt(self.filetree_sel) orelse return true;
                if (node.is_dir) {
                    if (node.expanded) {
                        try self.collapseDir(node);
                    } else {
                        try self.expandDir(node);
                    }
                } else {
                    // open the file but keep the tree visible — only
                    // <space>e (toggleFiletree) or Esc closes it; focus moves
                    // back to the buffer so typing edits, not the tree
                    self.focus = .buffer;
                    try self.openFile(node.path);
                }
                return true;
            },
            vaxis.Key.escape => {
                self.filetree_active = false;
                self.focus = .buffer;
                return true;
            },
            else => return false,
        }
    }

    /// Free a node and its whole subtree (owned name/path/children).
    fn freeFiletreeNode(self: *App, node: *TreeNode) void {
        for (node.children.items) |child| self.freeFiletreeNode(child);
        node.children.deinit(self.alloc);
        self.alloc.free(node.name);
        self.alloc.free(node.path);
        self.alloc.destroy(node);
    }

    // ---- M3a git (async jobs + hunk/blame/lazygit actions) ----

    /// Spawn one async git job for `path`. One job at a time: when a job is
    /// already running, a status request is remembered (git_refresh_pending)
    /// and re-spawned after the current one lands; other kinds are queued
    /// with their full params (git_queued) and retried too.
    fn spawnGitJob(self: *App, kind: GitJobKind, path: []const u8, hunk_start: u32, op: GitApplyOp) !void {
        if (self.git_job != null) {
            if (kind == .status) {
                self.git_refresh_pending = true;
            } else {
                // blame/apply: keep the LATEST request (a stale queued blame
                // is superseded by a newer one; apply keeps the user's last
                // hunk action)
                if (self.git_queued) |q| self.alloc.free(q.path);
                self.git_queued = .{
                    .kind = kind,
                    .path = try self.alloc.dupe(u8, path),
                    .hunk_start = hunk_start,
                    .op = op,
                };
            }
            return;
        }
        const job = try self.alloc.create(GitJob);
        errdefer self.alloc.destroy(job);
        job.* = .{
            .kind = kind,
            .path = try self.alloc.dupe(u8, path),
            .hunk_start = hunk_start,
            .op = op,
            .alloc = self.alloc,
            .io = self.io,
        };
        errdefer self.alloc.free(job.path);
        job.wake_ctx = self;
        job.wake_fn = lspWake; // same trick as the LSP reader thread
        job.thread = try std.Thread.spawn(.{}, gitJobMain, .{job});
        self.git_job = job;
    }

    /// Main loop: consume a finished job (join the thread first), repaint.
    fn consumeGitJob(self: *App, job: *GitJob) void {
        job.thread.?.join();
        defer self.finishGitJob(job);
        switch (job.kind) {
            .status => {
                // replace the diff/branch state wholesale
                if (self.git_branch) |b| self.alloc.free(b);
                if (self.git_diff_path) |p| self.alloc.free(p);
                self.git_diff.deinit(self.alloc);
                self.git_diff = .{};
                self.git_diff_path = dupOrNull(self.alloc, job.path);
                self.git_branch = job.branch; // thread-owned → App-owned
                job.branch = null;
                if (job.out) |o| {
                    // parseDiff copies what it keeps — job.out stays owned by
                    // the job and finishGitJob frees it below
                    self.git_diff = git.parseDiff(self.alloc, o) catch git.FileDiff{};
                }
                // untracked must land even when the diff output is EMPTY
                // (git diff prints nothing for an untracked file — without
                // this the all-added marks never appeared)
                self.git_diff.untracked = job.untracked;
                // auto current-line blame (nvim current_line_blame=true):
                // the repo is confirmed now — load blame for this file
                self.maybeLoadBlame();
                if (self.git_preview_pending) {
                    self.git_preview_pending = false;
                    self.showHunkPreview();
                }
            },
            .blame => {
                if (self.git_blame) |*b| b.deinit(self.alloc);
                self.git_blame = null;
                // blame must describe the CURRENT file; a stale response
                // (buffer switched mid-job) is dropped
                if (job.out) |o| {
                    if (self.cur().path) |cp| {
                        if (std.mem.eql(u8, cp, job.path)) {
                            self.git_blame = git.parseBlame(self.alloc, o) catch null;
                            if (self.git_blame_path) |bp| self.alloc.free(bp);
                            self.git_blame_path = dupOrNull(self.alloc, job.path);
                        }
                    }
                    // job.out freed by finishGitJob (blame output is owned)
                }
            },
            .apply => {
                if (job.msg) |m| {
                    self.setMsg(m) catch {};
                    job.msg = null;
                } else if (dupOrNull(self.alloc, "git apply failed")) |m| {
                    self.setMsg(m) catch {};
                }
                // the working tree changed (staged/reset): refresh the marks
                if (self.cur().path) |p| self.spawnGitJob(.status, p, 0, .stage) catch {};
                // and the blame describes the old file — invalidate it so
                // the status refresh reloads blame for the new content
                if (self.blame_active) {
                    if (self.git_blame) |*b| b.deinit(self.alloc);
                    self.git_blame = null;
                    if (self.git_blame_path) |bp| self.alloc.free(bp);
                    self.git_blame_path = null;
                }
            },
        }
    }

    fn finishGitJob(self: *App, job: *GitJob) void {
        self.alloc.free(job.path);
        if (job.out) |o| self.alloc.free(o);
        if (job.branch) |b| self.alloc.free(b);
        if (job.msg) |m| self.alloc.free(m);
        self.alloc.destroy(job);
        self.git_job = null;
        // resume work requested while the slot was busy: a stale status
        // refresh first, then any queued non-status job (blame/apply)
        if (self.git_refresh_pending) {
            self.git_refresh_pending = false;
            if (self.cur().path) |p| self.spawnGitJob(.status, p, 0, .stage) catch {};
        } else if (self.git_queued) |q| {
            self.git_queued = null;
            defer self.alloc.free(q.path);
            if (q.kind == .blame) {
                // blame goes through the auto-loader: it re-checks
                // blame_active and the current buffer's path/staleness
                self.maybeLoadBlame();
            } else {
                self.spawnGitJob(q.kind, q.path, q.hunk_start, q.op) catch {};
            }
        }
    }

    /// Refresh branch + diff marks for the current buffer (async). Called on
    /// file open/switch and after save. The gutter only ever shows a diff of
    /// what's on disk — a dirty buffer hides the marks anyway.
    fn scheduleGitStatus(self: *App) void {
        const path = self.cur().path orelse return;
        self.spawnGitJob(.status, path, 0, .stage) catch {};
    }

    /// ]c / [c — jump to the next/previous hunk of the current file.
    fn gotoHunk(self: *App, forward: bool) void {
        const path = self.cur().path orelse return;
        if (self.cur().dirty) {
            if (dupOrNull(self.alloc, "save first (marks describe the file on disk)")) |m| self.setMsg(m) catch {};
            return;
        }
        if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
            if (dupOrNull(self.alloc, "git state loading…")) |m| self.setMsg(m) catch {};
            return;
        }
        const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
        const idx = if (forward)
            self.git_diff.hunkAtOrAfter(cursor_line + 1)
        else
            self.git_diff.hunkBefore(cursor_line);
        const i = idx orelse {
            if (dupOrNull(self.alloc, if (forward) "no more hunks" else "no previous hunks")) |m| self.setMsg(m) catch {};
            return;
        };
        const start = self.git_diff.hunks.items[i].start_line;
        const pt = &self.cur().pt;
        const line = @min(start, pt.lineCount() -| 1);
        self.curCursor().* = pt.lineStart(line);
        // scroll the target into view (same as the grep-picker jump)
        self.curViewTop().* = line;
    }

    /// <leader>hs / <leader>hr — stage / reset the hunk under the cursor.
    fn applyHunk(self: *App, op: GitApplyOp) void {
        const path = self.cur().path orelse return;
        if (self.cur().dirty) {
            if (dupOrNull(self.alloc, "save first (hunk ops apply to the file on disk)")) |m| self.setMsg(m) catch {};
            return;
        }
        if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
            if (dupOrNull(self.alloc, "git state loading…")) |m| self.setMsg(m) catch {};
            return;
        }
        const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
        const idx = self.git_diff.hunkAt(cursor_line) orelse {
            if (self.git_diff.untracked) {
                self.spawnGitJob(.apply, path, 0, op) catch {};
                return;
            }
            if (dupOrNull(self.alloc, "cursor not in a hunk")) |m| self.setMsg(m) catch {};
            return;
        };
        const start = self.git_diff.hunks.items[idx].start_line;
        self.spawnGitJob(.apply, path, start, op) catch {};
    }

    /// <leader>hp — show the hunk under the cursor in a floating window.
    fn previewHunk(self: *App) void {
        const path = self.cur().path orelse return;
        if (self.cur().dirty) {
            if (dupOrNull(self.alloc, "save first (the preview describes the file on disk)")) |m| self.setMsg(m) catch {};
            return;
        }
        if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) {
            self.git_preview_pending = true;
            self.spawnGitJob(.status, path, 0, .stage) catch {};
            return;
        }
        self.showHunkPreview();
    }

    fn showHunkPreview(self: *App) void {
        const path = self.cur().path orelse return;
        if (self.git_diff_path == null or !std.mem.eql(u8, self.git_diff_path.?, path)) return;
        if (self.git_diff.untracked) {
            if (dupOrNull(self.alloc, "untracked file — no diff to preview")) |m| self.setMsg(m) catch {};
            return;
        }
        const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
        const idx = self.git_diff.hunkAt(cursor_line) orelse {
            if (dupOrNull(self.alloc, "cursor not in a hunk")) |m| self.setMsg(m) catch {};
            return;
        };
        const patch = self.git_diff.hunks.items[idx].patch;
        const copy = dupOrNull(self.alloc, patch) orelse return;
        self.git_preview = .{ .text = copy, .top = 0 };
    }

    /// Keys while the hunk preview float is open. Returns true when consumed.
    fn gitPreviewKey(self: *App, key: vaxis.Key) bool {
        switch (key.codepoint) {
            vaxis.Key.escape, vaxis.Key.enter, 'q' => {
                self.closeGitPreview();
                return true;
            },
            'j', vaxis.Key.down => {
                if (self.git_preview) |*p| {
                    if (p.top + 1 < gitPreviewLineCount(p.text)) p.top += 1;
                }
                return true;
            },
            'k', vaxis.Key.up => {
                if (self.git_preview) |*p| {
                    if (p.top > 0) p.top -= 1;
                }
                return true;
            },
            else => return false,
        }
    }

    fn closeGitPreview(self: *App) void {
        if (self.git_preview) |p| self.alloc.free(p.text);
        self.git_preview = null;
    }

    /// <leader>tb — toggle the current-line blame ghost (end-of-line dim
    /// text on the cursor line, 1s CursorHold delay — nvim gitsigns style).
    /// ON by default, like the nvim config's current_line_blame = true.
    fn toggleBlame(self: *App) void {
        if (self.blame_active) {
            self.blame_active = false;
            return;
        }
        self.blame_active = true;
        self.maybeLoadBlame();
    }

    /// Load blame for the current file when current-line blame is active,
    /// the repo check has passed (git_branch set), the file is under the
    /// big-file limit, and the cached blame is stale/missing. No-op
    /// otherwise — this is the auto-behavior behind current_line_blame.
    fn maybeLoadBlame(self: *App) void {
        if (!self.blame_active) return;
        if (self.git_branch == null) return; // not a repo — no blame
        const path = self.cur().path orelse return;
        if (self.cur().pt.lineCount() > max_blame_lines) return; // degrade
        const stale = if (self.git_blame_path) |bp|
            !std.mem.eql(u8, bp, path)
        else
            true;
        if (stale) self.spawnGitJob(.blame, path, 0, .stage) catch {};
    }

    /// <leader>lg — launch lazygit in an external terminal emulator
    /// (design: "外部浮窗先行" — a real PTY pane is M3b). Uses $TERMINAL,
    /// falling back to x-terminal-emulator / xterm.
    fn launchLazygit(self: *App) void {
        const term = self.env_map.get("TERMINAL") orelse "x-terminal-emulator";
        var proc = std.process.spawn(self.io, .{
            .argv = &.{ term, "-e", "lazygit" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            const m = std.fmt.allocPrint(self.alloc, "lazygit: {s}", .{@errorName(e)}) catch return;
            self.setMsg(m) catch {};
            return;
        };
        // reap in a detached thread so a long-lived lazygit never blocks
        // deinit (a zombie child would linger until oz exits otherwise)
        const t = std.Thread.spawn(.{}, struct {
            fn reap(io: std.Io, p: std.process.Child) void {
                var c = p; // wait() needs a mutable Child
                _ = c.wait(io) catch {};
            }
        }.reap, .{ self.io, proc }) catch {
            proc.kill(self.io);
            return;
        };
        t.detach();
    }

    // ---- fuzzy picker (<leader>sf) ----

    fn openPicker(self: *App) !void {
        if (self.picker_files.items.len == 0) {
            // cwd() has fd == AT.FDCWD (-100), which the dir iterator can't
            // getdents on — open a real directory handle first.
            var root = try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
            defer root.close(self.io);
            try self.walkDir(root, "");
        }
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn walkDir(self: *App, dir: std.Io.Dir, prefix: []const u8) !void {
        try self.walkInto(dir, prefix, &self.picker_files);
    }

    fn walkInto(self: *App, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]u8)) !void {
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;
            if (std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or std.mem.eql(u8, name, "node_modules")) continue;
            const path = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, name });
            switch (entry.kind) {
                .directory => {
                    var sub = try dir.openDir(self.io, name, .{ .iterate = true });
                    defer sub.close(self.io);
                    const sub_prefix = try std.fmt.allocPrint(self.alloc, "{s}/", .{path});
                    try self.walkInto(sub, sub_prefix, out);
                    self.alloc.free(sub_prefix);
                    self.alloc.free(path);
                },
                .file => try out.append(self.alloc, path),
                else => self.alloc.free(path),
            }
        }
    }

    fn openBufferPicker(self: *App) !void {
        self.picker_mode = .buffers;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn openRecentPicker(self: *App) !void {
        self.picker_mode = .recent;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn openKeymapPicker(self: *App) !void {
        self.picker_mode = .keymaps;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    /// <leader>sp — theme picker with LIVE preview: remember the current
    /// theme (Esc restores it), then every selection change applies the
    /// highlighted theme to the whole UI until Enter confirms or Esc cancels.
    fn openThemePicker(self: *App) !void {
        self.theme_saved = self.theme;
        self.picker_mode = .themes;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        try self.pickerRefilter();
        self.picker_active = true;
    }

    fn bufferName(self: *const App, i: usize) []const u8 {
        const buf = &self.buffers.items[i];
        return if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
    }

    fn openGrepPicker(self: *App) !void {
        self.picker_mode = .grep;
        self.picker_input.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_top = 0;
        // fresh session: drop stale results (and their owned strings) from a
        // previous grep — an empty query must show "no matches", not the
        // last search's leftovers
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.clearRetainingCapacity();
        self.picker_active = true;
        self.refreshGrepPreview();
    }

    /// Run rg for the current query and store results (path:line:text).
    fn runGrep(self: *App) !void {
        for (self.grep_results.items) |g| {
            self.alloc.free(g.path);
            self.alloc.free(g.text);
        }
        self.grep_results.clearRetainingCapacity();

        const query = self.picker_input.items;
        if (query.len == 0) return;

        var child = std.process.spawn(self.io, .{
            // -F: the query is a literal string, not a regex; "--": a query
            // starting with '-' must not be parsed as an rg flag
            .argv = &.{ "rg", "--no-heading", "-n", "-F", "--", query },
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return;
        // Child.kill cleans up and nulls child.id, so wait() after a kill
        // would trip its `child.id != null` assert — track that.
        var child_killed = false;
        defer {
            if (!child_killed) _ = child.wait(self.io) catch {};
        }

        // Read ALL of rg's output until EOF — stopping early deadlocks: the
        // kernel pipe buffer fills, rg blocks writing, and wait() never
        // returns. Cap at ~1MB for sanity.
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var tmp: [4096]u8 = undefined;
        while (out.items.len < 1024 * 1024) {
            const n = child.stdout.?.readStreaming(self.io, &.{&tmp}) catch break;
            if (n == 0) break;
            try out.appendSlice(self.alloc, tmp[0..n]);
        }
        if (out.items.len >= 1024 * 1024) {
            _ = child.kill(self.io);
            child_killed = true;
        }
        var it = std.mem.splitScalar(u8, out.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            // path:line:text
            const c1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ':') orelse continue;
            const path = line[0..c1];
            const line_no = std.fmt.parseUnsigned(u32, line[c1 + 1 .. c2], 10) catch continue;
            const text = line[c2 + 1 ..];
            const path_c = try self.alloc.dupe(u8, path);
            errdefer self.alloc.free(path_c);
            const text_c = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(text_c);
            try self.grep_results.append(self.alloc, .{ .path = path_c, .line = line_no, .text = text_c });
            if (self.grep_results.items.len >= 50) break;
        }
        if (self.picker_sel >= self.grep_results.items.len) self.picker_sel = 0;
        self.refreshGrepPreview();
    }

    /// Drop the grep preview's file content / highlighter / path. Called on
    /// close, on empty results and whenever the selected path changes.
    fn freeGrepPreview(self: *App) void {
        if (self.preview_hl) |*h| h.deinit();
        self.preview_hl = null;
        if (self.preview_text) |t| self.alloc.free(t);
        self.preview_text = null;
        if (self.preview_path) |p| self.alloc.free(p);
        self.preview_path = null;
    }

    /// (Re)build the split-preview file + highlighter for the SELECTED grep
    /// result. No-op while the path is unchanged — this is what keeps the
    /// panel from re-reading files / re-parsing on every frame. Best-effort:
    /// a failed read or a file over syntax.SIZE_LIMIT leaves preview_text
    /// null and the renderer shows "preview unavailable".
    fn refreshGrepPreview(self: *App) void {
        if (self.picker_mode != .grep or !self.picker_active) return;
        if (self.grep_results.items.len == 0) {
            self.freeGrepPreview();
            return;
        }
        const r = self.grep_results.items[self.picker_sel];
        if (self.preview_path) |pp| {
            if (std.mem.eql(u8, pp, r.path)) return;
        }
        self.freeGrepPreview();
        self.preview_path = self.alloc.dupe(u8, r.path) catch return;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, r.path, self.alloc, .limited(syntax.SIZE_LIMIT)) catch return;
        self.preview_text = text;
        const ft = filetypeOf(r.path);
        if (syntax.languageFor(ft)) |lang| {
            var hl = syntax.Highlighter.init(self.alloc, lang) catch return;
            hl.reparse(text) catch {
                hl.deinit();
                return;
            };
            self.preview_hl = hl;
        }
    }

    /// Render one preview-column row of the grep split panel (k = 0 is the
    /// "basename:line" header; k > 0 a syntax-highlighted content line from
    /// the selected result's file, a ±(content_rows/2) window around the
    /// selected line). Every segment is arena-allocated so the text outlives
    /// vx.render(). The file itself is read / reparsed only in
    /// refreshGrepPreview — here we just run the (already built) highlighter
    /// over the visible byte range.
    fn renderGrepPreviewRow(
        self: *App,
        segs: *std.ArrayList(vaxis.Segment),
        a: std.mem.Allocator,
        win: vaxis.Window,
        k: usize,
        list_rows: usize,
        preview_w: u32,
    ) !void {
        const float_bg: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float } };
        const pw: usize = @intCast(preview_w);
        const r = self.grep_results.items[self.picker_sel];
        if (k == 0) {
            // header: basename (fg) + ":line" (fg_dim), then padding; widths
            // are cells (a CJK basename is 2 cells/char, 3-4 bytes)
            const base = std.fs.path.basename(r.path);
            const line_str = try std.fmt.allocPrint(a, ":{d}", .{r.line});
            const f1 = cellFitPrefix(win, base, pw);
            try segs.append(a, .{ .text = f1.slice, .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float } } });
            const f2 = cellFitPrefix(win, line_str, pw -| f1.cells);
            if (f2.slice.len > 0) try segs.append(a, .{ .text = f2.slice, .style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } } });
            if (f1.cells + f2.cells < pw) {
                const pad = try a.alloc(u8, pw - f1.cells - f2.cells);
                @memset(pad, ' ');
                try segs.append(a, .{ .text = pad, .style = float_bg });
            }
            return;
        }
        const text = self.preview_text orelse {
            // unavailable (>100KB / read failed): dim hint on the first
            // content row, blank rows below
            if (k == 1) {
                const hint = "preview unavailable";
                const ids = [_]u8{0} ** 64;
                try appendRowSegs(segs, a, win, hint, &ids, &[_]vaxis.Style{.{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = float_bg.bg }}, preview_w, float_bg);
            } else {
                try appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
            }
            return;
        };
        const sel_line: usize = r.line -| 1; // rg reports 1-based lines
        const line_count = std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0);
        if (sel_line >= line_count) {
            try appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
            return;
        }
        const content_rows = list_rows - 1;
        const ci = k - 1;
        const win_start = @min(@max(sel_line -| (content_rows / 2), 0), line_count -| content_rows);
        const file_line = win_start + ci;
        if (file_line >= line_count) {
            try appendRowSegs(segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, float_bg);
            return;
        }
        // gutter: relative offset from the selected line ("-4".." 0".."+4");
        // arena-allocated — Segment.text must outlive vx.render()
        const off: i32 = @as(i32, @intCast(file_line)) - @as(i32, @intCast(sel_line));
        const gutter = if (off < 0)
            try std.fmt.allocPrint(a, "-{d}", .{@as(u32, @intCast(-off))})
        else if (off > 0)
            try std.fmt.allocPrint(a, "+{d}", .{@as(u32, @intCast(off))})
        else
            try std.fmt.allocPrint(a, " 0", .{});
        const row_s = lineStartByte(text, file_line);
        const row_e = lineEndByte(text, file_line);
        // content width: gutter (2) + space (1) leaves the rest of the
        // column. Truncate in CELLS on grapheme boundaries — a byte count
        // overflows the column on CJK (2 cells/char) and pushes the row's
        // padding/border out of place.
        const fit = cellFitPrefix(win, text[row_s..row_e], pw -| 3);
        const n = fit.slice.len;
        // syntax spans for THIS line's byte range (O(visible) query; the
        // highlighter itself is only reparsed when the selection's path
        // changes, in refreshGrepPreview)
        var spans = std.ArrayList(syntax.Span).empty;
        if (self.preview_hl) |*hl| {
            var raw = std.ArrayList(syntax.Span).empty;
            hl.spansInRange(@intCast(row_s), @intCast(row_e), a, &raw) catch {};
            // merge overlaps like visibleSpansFor (later spans win)
            for (raw.items) |sp| {
                while (spans.items.len > 0) {
                    var last = &spans.items[spans.items.len - 1];
                    if (sp.start >= last.end) break;
                    if (sp.start <= last.start) {
                        _ = spans.pop();
                        continue;
                    }
                    last.end = sp.start;
                    break;
                }
                try spans.append(a, sp);
            }
        }
        // per-byte style ids: 0 = base fg, 1+ = syntax palette (Style ordinal
        // + 1), so spans map straight onto a per-frame palette
        var style_palette: [syntax_style_count]vaxis.Style = undefined;
        for (0..style_palette.len) |i| style_palette[i] = syntaxStyle(@enumFromInt(i), self.theme);
        const selected_line = (file_line == sel_line);
        const base_bg: vaxis.Style = if (selected_line)
            .{ .bg = .{ .rgb = self.theme.bg_sel } }
        else
            float_bg;
        const gutter_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = base_bg.bg };
        // per-byte ids for the visible prefix; arena-sized (a cell-capped
        // prefix can still be many bytes — up to ~4 per cell for CJK)
        const ids_buf = try a.alloc(u8, n);
        @memset(ids_buf, 0);
        for (spans.items) |sp| {
            if (sp.end <= row_s or sp.start >= row_e) continue;
            const cs = @max(sp.start, @as(u32, @intCast(row_s)));
            const ce = @min(sp.end, @as(u32, @intCast(row_e)));
            const sid: u8 = @intCast(@intFromEnum(sp.style) + 1);
            for (cs..ce) |bi| {
                if (bi - row_s >= n) break;
                ids_buf[bi - row_s] = sid;
            }
        }
        try segs.append(a, .{ .text = gutter, .style = gutter_style });
        try segs.append(a, .{ .text = " ", .style = gutter_style });
        const base_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = base_bg.bg };
        var i: usize = 0;
        while (i < n) {
            const sid = ids_buf[i];
            var j = i + 1;
            while (j < n and ids_buf[j] == sid) : (j += 1) {}
            const st: vaxis.Style = if (sid == 0)
                base_style
            else blk: {
                var s2 = style_palette[sid - 1];
                s2.bg = base_bg.bg;
                break :blk s2;
            };
            try segs.append(a, .{ .text = text[row_s + i .. row_s + j], .style = st });
            i = j;
        }
        const used = cellWidth(win, gutter) + 1 + fit.cells;
        if (used < pw) {
            const pad = try a.alloc(u8, pw - used);
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = base_bg });
        }
    }

    fn handlePickerKey(self: *App, key: vaxis.Key) !void {
        switch (key.codepoint) {
            vaxis.Key.escape => {
                // theme picker: Esc cancels the live preview — restore the
                // theme that was active when the picker opened
                if (self.picker_mode == .themes) {
                    if (self.theme_saved) |t| self.theme = t;
                }
                self.closePicker();
            },
            vaxis.Key.enter => {
                // Confirming jumps into the target file: leave the file-tree
                // navigation mode so j/k/↑↓ control the buffer afterwards
                // (vim: picker confirm drops focus back to the buffer).
                self.filetree_active = false;
                self.focus = .buffer;
                if (self.picker_mode == .keymaps) {
                    // keymap search has no jump target — Enter just closes
                    self.closePicker();
                    return;
                }
                if (self.picker_mode == .grep) {
                    if (self.grep_results.items.len > 0) {
                        const r = self.grep_results.items[self.picker_sel];
                        self.closePicker();
                        try self.openFile(r.path);
                        const line = @min(r.line - 1, self.cur().pt.lineCount() - 1);
                        self.curCursor().* = self.cur().pt.lineStart(line);
                        self.curViewTop().* = line;
                    }
                    return;
                }
                if (self.picker_mode == .recent) {
                    if (self.picker_matches.items.len > 0) {
                        const ri = self.picker_matches.items[self.picker_sel];
                        const path = self.recent_files.items[ri];
                        self.closePicker();
                        try self.openFile(path);
                    }
                    return;
                }
                if (self.picker_mode == .buffers) {
                    if (self.picker_matches.items.len > 0) {
                        const bi = self.picker_matches.items[self.picker_sel];
                        self.closePicker();
                        self.switchTo(bi);
                    }
                    return;
                }
                if (self.picker_mode == .themes) {
                    // Enter confirms the previewed theme: keep it, report it
                    // and close (the preview already applied it on move).
                    if (self.picker_matches.items.len > 0) {
                        const ti = self.picker_matches.items[self.picker_sel];
                        self.theme = theme.themes[ti];
                        try self.setMsg(try std.fmt.allocPrint(self.alloc, "theme: {s}", .{theme.themes[ti].name}));
                    }
                    self.closePicker();
                    return;
                }
                if (self.picker_matches.items.len > 0) {
                    const f = self.picker_files.items[self.picker_matches.items[self.picker_sel]];
                    self.closePicker();
                    try self.openFile(f);
                }
            },
            vaxis.Key.backspace => {
                if (self.picker_input.items.len > 0) {
                    _ = self.picker_input.pop();
                    self.picker_sel = 0;
                    if (self.picker_mode == .grep) {
                        try self.runGrep();
                    } else {
                        try self.pickerRefilter();
                    }
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            },
            vaxis.Key.down => {
                const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
                if (self.picker_sel + 1 < n) {
                    self.picker_sel += 1;
                    if (self.picker_mode == .grep) self.refreshGrepPreview();
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            },
            vaxis.Key.up => {
                if (self.picker_sel > 0) {
                    self.picker_sel -= 1;
                    if (self.picker_mode == .grep) self.refreshGrepPreview();
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            },
            else => {
                if (key.codepoint == 'n' and key.mods.ctrl) {
                    const n = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
                    if (self.picker_sel + 1 < n) {
                        self.picker_sel += 1;
                        if (self.picker_mode == .grep) self.refreshGrepPreview();
                        if (self.picker_mode == .themes) self.applyThemePreview();
                    }
                } else if (key.codepoint == 'p' and key.mods.ctrl) {
                    if (self.picker_sel > 0) {
                        self.picker_sel -= 1;
                        if (self.picker_mode == .grep) self.refreshGrepPreview();
                        if (self.picker_mode == .themes) self.applyThemePreview();
                    }
                } else if (key.text) |t| {
                    try self.picker_input.appendSlice(self.alloc, t);
                    self.picker_sel = 0;
                    if (self.picker_mode == .grep) {
                        try self.runGrep();
                    } else {
                        try self.pickerRefilter();
                    }
                    if (self.picker_mode == .themes) self.applyThemePreview();
                }
            },
        }
    }

    /// Theme picker live preview: apply the theme under the current
    /// selection to the whole UI (the next render repaints with it).
    fn applyThemePreview(self: *App) void {
        if (self.picker_mode != .themes or !self.picker_active) return;
        if (self.picker_matches.items.len == 0) return;
        const ti = self.picker_matches.items[self.picker_sel];
        self.theme = theme.themes[ti];
    }

    fn pickerRefilter(self: *App) !void {
        self.picker_matches.clearRetainingCapacity();
        if (self.picker_mode == .keymaps) {
            // match against "keys desc" via fzy; matches index into
            // keymap_list.entries (empty query hits every entry)
            const needle = self.picker_input.items;
            var ei: usize = 0;
            while (ei < keymap_list.entries.len) : (ei += 1) {
                if (try keymap_list.matches(self.alloc, keymap_list.entries[ei], needle)) {
                    try self.picker_matches.append(self.alloc, ei);
                    if (self.picker_matches.items.len >= 20) break;
                }
            }
            if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
            return;
        }
        if (self.picker_mode == .recent) {
            // match against recent-file paths; matches index into recent_files
            const needle = self.picker_input.items;
            var ri: usize = 0;
            while (ri < self.recent_files.items.len) : (ri += 1) {
                const path = self.recent_files.items[ri];
                if (needle.len == 0) {
                    try self.picker_matches.append(self.alloc, ri);
                    continue;
                }
                const m = try util.fzy.match(self.alloc, path, needle) orelse continue;
                defer self.alloc.free(m.positions);
                try self.picker_matches.append(self.alloc, ri);
                if (self.picker_matches.items.len >= 20) break;
            }
            if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
            return;
        }
        if (self.picker_mode == .buffers) {
            // match against buffer names; matches index into buffers
            const needle = self.picker_input.items;
            var bi: usize = 0;
            while (bi < self.buffers.items.len) : (bi += 1) {
                const name = self.bufferName(bi);
                if (needle.len == 0) {
                    try self.picker_matches.append(self.alloc, bi);
                    continue;
                }
                const m = try util.fzy.match(self.alloc, name, needle) orelse continue;
                defer self.alloc.free(m.positions);
                try self.picker_matches.append(self.alloc, bi);
                if (self.picker_matches.items.len >= 20) break;
            }
            if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
            return;
        }
        if (self.picker_mode == .themes) {
            // match against theme names; matches index into theme.themes
            // (empty query hits every theme)
            const needle = self.picker_input.items;
            var ti: usize = 0;
            while (ti < theme.themes.len) : (ti += 1) {
                const tname = theme.themes[ti].name;
                if (needle.len == 0) {
                    try self.picker_matches.append(self.alloc, ti);
                    continue;
                }
                const m = try util.fzy.match(self.alloc, tname, needle) orelse continue;
                defer self.alloc.free(m.positions);
                try self.picker_matches.append(self.alloc, ti);
                if (self.picker_matches.items.len >= 20) break;
            }
            if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
            return;
        }
        const needle = self.picker_input.items;
        if (needle.len == 0) {
            const n = @min(self.picker_files.items.len, 20);
            var i: usize = 0;
            while (i < n) : (i += 1) try self.picker_matches.append(self.alloc, i);
            return;
        }
        // top-20 by fzy score (small insertion-sort)
        var top: [20]struct { idx: usize, score: f64 } = undefined;
        var ntop: usize = 0;
        for (self.picker_files.items, 0..) |f, i| {
            const m = try util.fzy.match(self.alloc, f, needle) orelse continue;
            defer self.alloc.free(m.positions);
            var k = ntop;
            while (k > 0 and top[k - 1].score < m.score) : (k -= 1) {
                if (k < 20) top[k] = top[k - 1];
            }
            if (ntop < 20) ntop += 1;
            if (k < 20) top[k] = .{ .idx = i, .score = m.score };
        }
        var j: usize = 0;
        while (j < ntop) : (j += 1) try self.picker_matches.append(self.alloc, top[j].idx);
        if (self.picker_sel >= self.picker_matches.items.len) self.picker_sel = 0;
    }

    fn closePicker(self: *App) void {
        self.picker_active = false;
        self.picker_sel = 0;
        self.picker_mode = .files;
        self.freeGrepPreview();
    }

    // ---- dashboard ----

    fn isDashboard(self: *App) bool {
        return self.cur().path == null and self.cur().pt.len() == 0 and
            self.state.mode == .normal and !self.picker_active and !self.em_active;
    }

    /// j/k/Enter for the recent-files list; returns true if consumed.
    fn dashboardKey(self: *App, key: vaxis.Key) !bool {
        switch (key.codepoint) {
            'j' => {
                if (self.recent_sel + 1 < self.recent_files.items.len) self.recent_sel += 1;
                return true;
            },
            'k' => {
                if (self.recent_sel > 0) self.recent_sel -= 1;
                return true;
            },
            vaxis.Key.enter => {
                if (self.recent_files.items.len > 0) {
                    try self.openFile(self.recent_files.items[self.recent_sel]);
                    self.recent_sel = 0;
                }
                return true;
            },
            else => return false,
        }
    }

    fn addRecent(self: *App, path: []const u8) !void {
        for (self.recent_files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f, path)) {
                self.alloc.free(self.recent_files.orderedRemove(i));
                break;
            }
        }
        const copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(copy);
        try self.recent_files.insert(self.alloc, 0, copy);
        while (self.recent_files.items.len > 10) {
            if (self.recent_files.pop()) |f| self.alloc.free(f);
        }
    }

    // ---- multi-buffer ----

    /// Switch to the buffer at index `i` (clamped, wraps).
    fn switchTo(self: *App, i: usize) void {
        if (self.buffers.items.len == 0) return;
        self.current = i % self.buffers.items.len;
        // re-home the buffer the focused pane is leaving: if another pane
        // still shows it, its tab moves to THAT pane ("displayed in which
        // pane, the tab belongs to which pane"); hidden from every pane, it
        // keeps this one — the pane that last showed it
        const leaving = self.windows.items[self.current_win].buf;
        if (leaving != self.current) {
            for (self.windows.items, 0..) |w, wi| {
                if (wi != self.current_win and w.buf == leaving) {
                    self.buffers.items[leaving].last_win = wi;
                    break;
                }
            }
        }
        // the focused window follows the switch; other split windows keep
        // showing whatever buffer they had. This must happen BEFORE
        // ensureLsp: cur() resolves through the window's buf index, so with
        // the old order the server was started/retargeted against the
        // PREVIOUS buffer — files opened via the tree / :e / the picker got
        // no LSP session at all.
        self.windows.items[self.current_win].buf = self.current;
        // the buffer's tab belongs to the pane now showing it
        self.buffers.items[self.current].last_win = self.current_win;
        self.ensureLsp();
        self.state.mode = .normal;
        // leaving the buffer invalidates any visual selection from it
        // (gt / :bn / :e / picker-enter all land here, some without the
        // command-line exitVisual fallback)
        self.visual_anchor = null;
        self.in_insert = false;
        self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
        // per-buffer state from the previous buffer must not leak onto the
        // new one: stale inlay hints would render at wrong positions, stale
        // diagnostics would point at wrong files, hover/nav/completion would
        // linger.
        self.invalidateInlayHints();
        self.clearDiagnostics();
        self.clearHover();
        self.nav_list_active = false;
        self.closeCompletion();
        self.closeGitPreview();
        // git branch + diff marks describe the newly focused buffer; blame
        // stays ON (current_line_blame) — the path check on the cached
        // blame prevents a stale ghost from the previous buffer
        self.scheduleGitStatus();
    }

    /// Move `delta` buffers (wrapping). gt / gT.
    fn switchBuffer(self: *App, delta: i32) !void {
        const n = self.buffers.items.len;
        if (n == 0) return;
        var next = @as(i32, @intCast(self.current)) + delta;
        if (next < 0) next += @as(i32, @intCast(n));
        self.switchTo(@intCast(@mod(next, @as(i32, @intCast(n)))));
    }

    /// <leader>bh/bl workspace model: with a split open, a buffer opened
    /// from outside (:e, file tree, pickers, gd/gr into another file) lands
    /// in the LEFT window — the panes then hold distinct buffers by default
    /// and bh/bl shuttles them. A buffer already shown in a window is
    /// focused THERE instead (never duplicate it into both panes).
    /// No-op without a split.
    fn targetWindowForOpen(self: *App, buf_idx: ?usize) void {
        if (self.windows.items.len <= 1) return;
        if (buf_idx) |b| {
            for (self.windows.items, 0..) |w, wi| {
                if (w.buf == b) {
                    self.current_win = wi;
                    return;
                }
            }
        }
        const root = self.win_root orelse return;
        self.current_win = self.firstLeaf(root);
    }

    /// Open `path` in a new buffer unless it is already open (then switch).
    /// The stored path is ABSOLUTE (like the CLI arg path): LSP uri building,
    /// filetype detection and recent-file dedupe all assume absolute paths, so
    /// a relative path here (file tree, :e, picker) would silently kill LSP
    /// for the opened file.
    fn openInBuffer(self: *App, path: []const u8) !void {
        const abs = try self.absolutePath(path);
        defer self.alloc.free(abs);
        for (self.buffers.items, 0..) |*buf, i| {
            if (buf.path) |p| {
                if (std.mem.eql(u8, p, abs)) {
                    self.targetWindowForOpen(i);
                    self.switchTo(i);
                    return;
                }
            }
        }
        // load the file
        var file = std.Io.Dir.cwd().openFile(self.io, abs, .{ .mode = .read_only }) catch |e| {
            try self.setMsg(try std.fmt.allocPrint(self.alloc, "E484: cannot open {s}: {s}", .{ abs, @errorName(e) }));
            return;
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        // u32-addressed piece table: refuse >= 4 GiB instead of panicking on
        // the @intCast below (see main()'s CLI open for the same guard).
        if (size >= std.math.maxInt(u32)) {
            try self.setMsg(try self.alloc.dupe(u8, "file too large (>4GiB)"));
            return;
        }
        const bytes = try self.alloc.alloc(u8, @intCast(size));
        defer self.alloc.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);

        try self.buffers.append(self.alloc, .{
            .pt = try buffer.PieceTable.init(self.alloc, bytes),
            .history = buffer.History.init(self.alloc),
            .path = try self.alloc.dupe(u8, abs),
        });
        try self.addRecent(abs);
        self.targetWindowForOpen(null);
        self.switchTo(self.buffers.items.len - 1);
    }

    /// Drop the LSP client and all LSP-derived state. `died` reports whether
    /// the server exited on its own (reader EOF) — then the user is told,
    /// because pending requests will never resolve.
    fn teardownLsp(self: *App, died: bool) void {
        if (self.lsp_client) |c| {
            c.deinit();
            self.lsp_client = null;
        }
        // clear every LSP response slot so stale results are not applied
        if (self.nav_slot) |*v| json_rpc.freeValue(self.alloc, v);
        self.nav_slot = null;
        if (self.completion_slot) |*v| json_rpc.freeValue(self.alloc, v);
        self.completion_slot = null;
        if (self.format_slot) |*v| json_rpc.freeValue(self.alloc, v);
        self.format_slot = null;
        if (self.inlay_slot) |*v| json_rpc.freeValue(self.alloc, v);
        self.inlay_slot = null;
        if (self.outline_slot) |*v| json_rpc.freeValue(self.alloc, v);
        self.outline_slot = null;
        self.invalidateInlayHints();
        self.clearDiagnostics();
        self.clearHover();
        self.closeCompletion();
        if (died) {
            const msg = self.alloc.dupe(u8, "LSP server exited") catch return;
            self.setMsg(msg) catch {};
        }
    }

    /// Close the buffer at `buf_idx`; every window showing it points at the
    /// next buffer. The last buffer stays. Used by :bd and the single-window
    /// :q path.
    fn closeBufferAt(self: *App, buf_idx: usize) void {
        if (self.buffers.items.len <= 1) return;
        if (self.lsp_client) |c| {
            c.deinit();
            self.lsp_client = null;
        }
        var buf = self.buffers.orderedRemove(buf_idx);
        buf.history.deinit();
        buf.pt.deinit();
        buf.folds.deinit(self.alloc);
        if (buf.hl) |*h| h.deinit();
        if (buf.path) |p| self.alloc.free(p);
        if (self.current >= self.buffers.items.len) self.current = self.buffers.items.len - 1;
        if (buf_idx < self.current) self.current -= 1;
        // point every window at the surviving buffer, fixing up shifted indices
        for (self.windows.items) |*w| {
            if (w.buf > buf_idx) {
                w.buf -= 1;
            } else if (w.buf == buf_idx) {
                w.buf = self.current;
            }
        }
        self.winTreeSanity();
        // tab ownership: a displayed buffer owns its displaying pane
        for (self.windows.items, 0..) |w, wi| {
            self.buffers.items[w.buf].last_win = wi;
        }
        self.state.mode = .normal;
        // closing the buffer also discards a visual selection anchored in it
        self.visual_anchor = null;
        self.in_insert = false;
        // the surviving buffer may need its own server (or a retarget)
        self.invalidateInlayHints();
        self.clearDiagnostics();
        self.ensureLsp();
    }

    /// :bd — close the focused window's buffer; the window shows the next one.
    fn closeCurrentBuffer(self: *App) void {
        const buf = self.windows.items[self.current_win].buf;
        self.closeBufferAt(buf);
        self.windows.items[self.current_win].buf = self.current;
        self.windows.items[self.current_win].cursor = @min(self.windows.items[self.current_win].cursor, self.cur().pt.len());
    }

    /// FNV-1a hash of the current buffer content (for dirty detection).
    fn contentHash(self: *App) u64 {
        var h: u64 = 0xcbf29ce484222325;
        var buf: [4096]u8 = undefined;
        var off: u32 = 0;
        const len = self.cur().pt.len();
        while (off < len) {
            const n: u32 = @intCast(@min(buf.len, len - off));
            self.cur().pt.copyRange(off, buf[0..n]);
            for (buf[0..n]) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            off += n;
        }
        return h;
    }

    /// Called when an insert session begins (all entry paths).
    fn beginInsertSession(self: *App) void {
        self.insert_base_hash = self.contentHash();
        self.insert_was_dirty = self.cur().dirty;
    }

    /// Called when an insert session ends (exitInsert / exitMcInsert): a
    /// session with zero net change clears the dirty flag.
    fn endInsertSession(self: *App) void {
        const now = self.contentHash();
        if (!self.insert_was_dirty and now == self.insert_base_hash) {
            self.cur().dirty = false;
        }
    }

    // ---- M2 diagnostics UI ----

    /// ]d / [d: jump to the next/previous diagnostic line (current file).
    fn gotoDiagnostic(self: *App, next: bool) void {
        if (self.lsp_diagnostics.items.len == 0) return;
        const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
        const idx: ?usize = if (next)
            lsp_diag.nextAtOrAfter(self.lsp_diagnostics.items, cursor_line + 1)
        else
            lsp_diag.prevAtOrBefore(self.lsp_diagnostics.items, cursor_line -| 1);
        const i = idx orelse return;
        const target_line = self.lsp_diagnostics.items[i].range.start.line;
        self.curCursor().* = self.cur().pt.lineStart(@min(target_line, self.cur().pt.lineCount() - 1));
    }

    /// gl: show the cursor line's diagnostics in the status bar.
    fn showLineDiagnostics(self: *App) void {
        const line = self.cur().pt.lineOf(self.curCursor().*);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        for (self.lsp_diagnostics.items) |d| {
            if (d.range.start.line != line) continue;
            if (buf.items.len > 0) buf.append(self.alloc, ';') catch return;
            buf.appendSlice(self.alloc, d.message) catch return;
        }
        if (buf.items.len == 0) {
            const m = self.alloc.dupe(u8, "no diagnostics on this line") catch return;
            self.setMsg(m) catch return;
            return;
        }
        const m = buf.toOwnedSlice(self.alloc) catch return;
        self.setMsg(m) catch return;
    }

    /// <leader>sd: toggle the diagnostics list overlay.
    fn toggleDiagnosticsList(self: *App) void {
        if (self.diag_list_active) {
            self.diag_list_active = false;
            return;
        }
        if (self.lsp_diagnostics.items.len == 0) {
            const m = self.alloc.dupe(u8, "no diagnostics") catch return;
            self.setMsg(m) catch return;
            return;
        }
        self.diag_list_active = true;
        self.diag_list_sel = 0;
        self.diag_list_top = 0;
    }

    /// j/k/Enter/Esc while the diagnostics list is open; returns true if
    /// consumed.
    fn diagnosticsListKey(self: *App, key: vaxis.Key) bool {
        switch (key.codepoint) {
            vaxis.Key.escape => {
                self.diag_list_active = false;
                return true;
            },
            'j', vaxis.Key.down => {
                if (self.diag_list_sel + 1 < self.lsp_diagnostics.items.len) self.diag_list_sel += 1;
                return true;
            },
            'k', vaxis.Key.up => {
                if (self.diag_list_sel > 0) self.diag_list_sel -= 1;
                return true;
            },
            vaxis.Key.enter => {
                if (self.diag_list_sel < self.lsp_diagnostics.items.len) {
                    const line = self.lsp_diagnostics.items[self.diag_list_sel].range.start.line;
                    self.curCursor().* = self.cur().pt.lineStart(@min(line, self.cur().pt.lineCount() - 1));
                    self.diag_list_active = false;
                }
                return true;
            },
            else => return false,
        }
    }

    // ---- LSP navigation (K / gd / gD / gr / gI / gs) ----

    /// Send a textDocument request for the cursor position. The response
    /// lands in `nav_slot`; `processNav` (called every frame after drain)
    /// consumes it. No-op when the client is absent.
    fn requestNav(self: *App, method: []const u8, action: NavAction) !void {
        const client = self.lsp_client orelse {
            return;
        };
        if (self.nav_slot != null) {
            return;
        }
        // A new navigation request replaces any stale overlay (hover window,
        // location list) from a previous request. Concurrent requests share
        // nav_slot; the client's drain frees a stale slot value on overwrite.
        self.clearNavOverlays();
        const uri = lsp_types.pathToFileUri(self.alloc, self.cur().path orelse return) catch return;
        defer self.alloc.free(uri);
        const line = self.cur().pt.lineOf(self.curCursor().*);
        const col = self.utf16Column(line, self.curCursor().* - self.cur().pt.lineStart(line));
        // references needs ReferenceParams (mandatory `context`) — a bare
        // position params is a ParseError for strict servers (zls exits!)
        var params = if (action == .references)
            lsp_nav.buildReferencesParams(self.alloc, uri, line, col) catch return
        else
            lsp_nav.buildTextDocPositionParams(self.alloc, uri, line, col) catch return;
        defer lsp_nav.freeTextDocPositionParams(self.alloc, &params);
        client.request(method, params, &self.nav_slot) catch return;
        self.nav_action = action;
    }

    /// Consume a completed navigation response (called after drain each
    /// frame). Frees the slot either way. Returns true when a response was
    /// consumed (caller renders immediately — the event loop may otherwise
    /// block in pollEvent before the new hover/list can be drawn).
    fn processNav(self: *App) bool {
        var result = self.nav_slot orelse return false;
        defer {
            json_rpc.freeValue(self.alloc, &result);
            self.nav_slot = null;
            self.nav_action = .none;
        }
        switch (self.nav_action) {
            .hover, .signature => {
                const text = if (self.nav_action == .hover)
                    lsp_nav.parseHoverText(self.alloc, result) catch null
                else
                    lsp_nav.parseSignature(self.alloc, result) catch null;
                if (self.nav_hover_text) |t| self.alloc.free(t);
                self.nav_hover_text = text;
            },
            .definition, .declaration => {
                self.clearNavOverlays();
                var locs = std.ArrayList(lsp_nav.NavLocation).empty;
                defer {
                    for (locs.items) |*l| self.alloc.free(l.uri);
                    locs.deinit(self.alloc);
                }
                lsp_nav.parseLocations(self.alloc, result, &locs) catch {};
                if (locs.items.len > 0) self.jumpToLocation(locs.items[0]);
            },
            .references, .implementation => {
                self.clearNavOverlays();
                for (self.nav_locations.items) |*l| self.alloc.free(l.uri);
                self.nav_locations.clearRetainingCapacity();
                lsp_nav.parseLocations(self.alloc, result, &self.nav_locations) catch {};
                self.nav_list_sel = 0;
                self.nav_loc_top = 0;
                self.nav_list_active = self.nav_locations.items.len > 0;
                self.nav_list_title = if (self.nav_action == .implementation) " Implementations " else " References ";
            },
            .none => {},
        }
        return true;
    }

    /// Drop the hover window and location-list overlay (used when starting a
    /// new navigation request or jumping).
    fn clearNavOverlays(self: *App) void {
        self.clearHover();
        self.nav_list_active = false;
    }

    /// Drop only the hover/signature floating window — used when the cursor
    /// moves (nvim hides the hover window as soon as the cursor leaves the
    /// annotated token).
    fn clearHover(self: *App) void {
        if (self.nav_hover_text) |t| self.alloc.free(t);
        self.nav_hover_text = null;
    }

    /// Move to a nav location: jump within the current buffer, or open the
    /// file (new buffer) when the URI points elsewhere. Lands on the exact
    /// definition column (clamped to the line length), like nvim's gd —
    /// not the line start.
    fn jumpToLocation(self: *App, loc: lsp_nav.NavLocation) void {
        const path = lsp_types.fileUriToPath(self.alloc, loc.uri) catch {
            // URI unparseable: fall back to a clamped position in the
            // current buffer
            const pt = &self.cur().pt;
            const line = @min(loc.line, pt.lineCount() -| 1);
            self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineLen(line));
            return;
        };
        defer self.alloc.free(path);
        const current = self.cur().path;
        if (current == null or !std.mem.eql(u8, current.?, path)) {
            // switching buffers: the target must be computed on the NEW
            // buffer, whose lengths differ (a stale offset from the old
            // buffer could exceed it and crash the next render)
            self.openInBuffer(path) catch return;
        }
        const pt = &self.cur().pt;
        const line = @min(loc.line, pt.lineCount() -| 1);
        self.curCursor().* = pt.lineStart(line) + @min(loc.character, pt.lineLen(line));
    }

    /// Keys while the gr/gI location list is open. Returns true when consumed.
    fn navListKey(self: *App, key: vaxis.Key) bool {
        switch (key.codepoint) {
            vaxis.Key.escape => {
                self.nav_list_active = false;
                return true;
            },
            'j', vaxis.Key.down => {
                if (self.nav_list_sel + 1 < self.nav_locations.items.len) self.nav_list_sel += 1;
                return true;
            },
            'k', vaxis.Key.up => {
                if (self.nav_list_sel > 0) self.nav_list_sel -= 1;
                return true;
            },
            vaxis.Key.enter => {
                if (self.nav_list_sel < self.nav_locations.items.len) {
                    const loc = self.nav_locations.items[self.nav_list_sel];
                    self.jumpToLocation(loc);
                    self.nav_list_active = false;
                }
                return true;
            },
            else => return false,
        }
    }

    // ---- LSP (M2) ----

    /// Lazily (re)start the LSP client for the current buffer's filetype.
    /// Returns without action when the filetype has no configured server or
    /// the spawn/handshake failed — LSP is strictly optional.
    fn ensureLsp(self: *App) void {
        const ft = filetypeOf(self.cur().path);
        if (self.lsp_client) |c| {
            if (std.mem.eql(u8, c.lang, ft)) {
                // Same filetype but a different document (buffer switch):
                // retarget the client, or every request would carry the
                // stale URI — hover/gd/completion/diagnostics silently die.
                const path = self.cur().path orelse return;
                const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
                defer self.alloc.free(uri);
                if (!std.mem.eql(u8, c.uri, uri)) {
                    const text = self.curText() catch return;
                    defer self.alloc.free(text);
                    c.switchDocument(uri, text) catch {};
                }
                return;
            }
            // filetype changed: close the old server
            c.deinit();
            self.lsp_client = null;
        }
        if (ft.len == 0) return;
        const path = self.cur().path orelse return;
        if (path.len == 0) return;
        const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
        defer self.alloc.free(uri);
        const text = self.curText() catch return;
        defer self.alloc.free(text);
        const start_result = lsp.Client.start(self.alloc, self.io, self.env_map, ft, uri, text);
        self.lsp_client = start_result catch |err| {
            // Tell the user why LSP features are silent: the configured
            // server binary is missing or failed to spawn (e.g. no zls
            // installed for Zig files). On OOM there is nothing to say —
            // never hand a static "" to setMsg (it would be freed later).
            const msg = std.fmt.allocPrint(self.alloc, "LSP {s}: {s}", .{ ft, @errorName(err) }) catch return;
            self.setMsg(msg) catch {};
            return;
        };
        // Wire the reader thread's wake callback to our event loop: any
        // incoming LSP message posts an event so the main loop (blocked in
        // pollEvent) wakes up and drains it without waiting for a keypress.
        if (self.lsp_client) |c| {
            c.wake_ctx = self;
            c.wake_fn = lspWake;
        }
    }

    /// Called from the LSP reader thread when a message arrives: post a
    /// (harmless) event so pollEvent wakes up. Only thread-safe state is
    /// touched; the event is consumed as `else => {}` by the main loop.
    fn lspWake(ctx: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        const r = app.loop.tryPostEvent(.focus_in) catch false;
        _ = r;
    }

    /// Current buffer text (owned copy) — for didOpen/didChange payloads.
    fn curText(self: *App) ![]u8 {
        const len = self.cur().pt.len();
        const buf = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(buf);
        self.cur().pt.copyRange(0, buf);
        return buf;
    }

    /// Free every diagnostic message and empty the list. Messages are dupe'd
    /// in parseDiagnostics — a bare clearRetainingCapacity() leaks them.
    fn clearDiagnostics(self: *App) void {
        for (self.lsp_diagnostics.items) |*d| self.alloc.free(d.message);
        self.lsp_diagnostics.clearRetainingCapacity();
    }

    /// LSP notification handler (main thread, called from drain each frame).
    fn lspHandler(self: *App, client: *lsp.Client, msg: *json_rpc.Message) void {
        _ = client;
        const method = msg.method orelse return;
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            if (msg.params) |params| {
                // Parse diagnostics for the CURRENT file into lsp_diagnostics
                // (sorted by line). Diagnostics for other documents are
                // dropped — the editor tracks one buffer at a time.
                self.clearDiagnostics();
                self.diag_dirty = true;
                const path = self.cur().path orelse return;
                const uri = lsp_types.pathToFileUri(self.alloc, path) catch return;
                defer self.alloc.free(uri);
                lsp_diag.parseDiagnostics(self.alloc, params, uri, &self.lsp_diagnostics) catch {};
                lsp_diag.sortByLine(self.lsp_diagnostics.items);
            }
        }
    }

    fn markDirty(self: *App) void {
        self.cur().dirty = true;
        self.edit_seq += 1;
        // Any edit drops this buffer's fold set (all folds re-open): edit
        // line shifts would otherwise leave the closed-fold start lines
        // pointing at stale text, and shifting ranges per edit is not worth
        // it — re-folding with zM costs one indent scan.
        self.cur().folds.clearRetainingCapacity();
        // Editing normally invalidates inlay hints: their offsets refer to the
        // pre-edit text. During an insert session we skip that and instead
        // shift the hints for the edit (see adjustInlayHintsInsert/Delete) so
        // the screen doesn't flicker on every keystroke; exitInsert forces a
        // fresh request once the session ends. One-shot normal-mode ops
        // (dd, x, o…) still invalidate here and let the auto-refresh re-request.
        if (!self.in_insert) self.invalidateInlayHints();
        // LSP text sync: push the new document content to the server. Cheap
        // enough per keystroke for now (debounce lands with the M2 UI work).
        if (self.lsp_client) |c| {
            const text = self.curText() catch return;
            defer self.alloc.free(text);
            c.didChange(text) catch {};
        }
    }

    // ---- tree-sitter syntax highlighting ----

    /// Merged non-overlapping spans for the visible byte range of `buf`
    /// (later spans win overlaps), arena-allocated. Empty when highlighting
    /// is inactive (no grammar for the filetype / over the size limit).
    ///
    /// Every buffer owns its highlighter (`Buffer.hl`), so ANY window —
    /// focused or not, showing the current buffer or another — gets real
    /// tree-sitter highlighting for what it displays. Reparse policy: a
    /// single recorded edit since the last parse takes the incremental path
    /// (tree.edit + parse); everything else (undo/redo, multi-edit ops, first
    /// parse, forced full reparses) falls back to a full reparse — the
    /// incremental bookkeeping must never guess.
    fn visibleSpansFor(self: *App, buf: *Buffer, arena: std.mem.Allocator, view_top: u32, content_rows: u32) ![]syntax.Span {
        if (buf.hl == null) {
            const ft = filetypeOf(buf.path);
            const lang = syntax.languageFor(ft) orelse return &.{};
            if (buf.pt.len() > syntax.SIZE_LIMIT) return &.{};
            buf.hl = syntax.Highlighter.init(self.alloc, lang) catch null;
        }
        const hl = &buf.hl.?;
        const hist = &buf.history;
        const rev = hist.revision;
        const parsed = hl.tree != null;
        if (!(parsed and rev == buf.syntax_revision)) {
            const len = buf.pt.len();
            const text = try self.alloc.alloc(u8, len);
            defer self.alloc.free(text);
            buf.pt.copyRange(0, text);
            const incremental = parsed and
                rev > buf.syntax_revision and
                rev - buf.syntax_revision == 1 and
                hist.last_record != null;
            if (incremental) {
                const e = hist.last_record.?;
                try hl.reparseEdit(e.pos, e.pos + @as(u32, @intCast(e.before.len)), e.pos + @as(u32, @intCast(e.after.len)), text);
            } else {
                try hl.reparse(text);
            }
            buf.syntax_revision = rev;
        }
        const line_count = buf.pt.lineCount();
        // view_top comes from a (possibly unfocused) window and can exceed
        // this buffer's line count after edits elsewhere shrank it — clamp
        // to the last line: lineStart asserts line < lineCount.
        const start = buf.pt.lineStart(@min(view_top, line_count -| 1));
        const vbottom = @min(view_top + content_rows, line_count);
        // lineStart has no EOF sentinel: the last visible line's end is pt.len()
        const end: u32 = if (vbottom >= line_count) buf.pt.len() else buf.pt.lineStart(vbottom);
        var raw = std.ArrayList(syntax.Span).empty;
        try hl.spansInRange(@intCast(start), @intCast(end), arena, &raw);
        var out = std.ArrayList(syntax.Span).empty;
        for (raw.items) |sp| {
            while (out.items.len > 0) {
                var last = &out.items[out.items.len - 1];
                if (sp.start >= last.end) break; // disjoint
                if (sp.start <= last.start) {
                    _ = out.pop(); // covers the previous span wholly
                    continue;
                }
                last.end = sp.start; // later span wins the overlap
                break;
            }
            try out.append(arena, sp);
        }
        return out.items;
    }

    /// Load recent files from ~/.cache/oz/recent (one path per line).
    fn loadRecent(self: *App) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = self.env_map.get("HOME") orelse return;
        const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch return;
        defer dir.close(self.io);
        const file = dir.openFile(self.io, "recent", .{ .mode = .read_only }) catch return;
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size == 0) return;
        const content = try self.alloc.alloc(u8, @intCast(size));
        defer self.alloc.free(content);
        _ = try file.readPositionalAll(self.io, content, 0);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const copy = try self.alloc.dupe(u8, line);
            errdefer self.alloc.free(copy);
            self.recent_files.append(self.alloc, copy) catch {};
        }
    }

    /// Persist recent files to ~/.cache/oz/recent.
    fn saveRecent(self: *App) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = self.env_map.get("HOME") orelse return;
        const dir_path = try std.fmt.bufPrint(&buf, "{s}/.cache/oz", .{home});
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch blk: {
            try std.Io.Dir.cwd().createDirPath(self.io, dir_path);
            break :blk try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        };
        defer dir.close(self.io);
        const file = try dir.createFile(self.io, "recent", .{ .truncate = true });
        defer file.close(self.io);
        for (self.recent_files.items) |f| {
            try file.writeStreamingAll(self.io, f);
            try file.writeStreamingAll(self.io, "\n");
        }
    }

    /// Execute an operator + motion combo over the current buffer/cursor.
    /// Shared by normal-mode dispatch and the '.' repeat (which replays the
    /// same motion from wherever the cursor now sits).
    fn execOpMotion(self: *App, m: editor.OpMotion) !void {
        // dd / cc / yy: motion == .line_start + exclusive_end == false is
        // the whole-line sentinel (see mode.zig Result docs; d^ is
        // .line_start with exclusive_end == true, so unambiguous). Must
        // delete/change/yank `count` whole lines, not [cursor, line start).
        if (m.motion == .line_start and !m.exclusive_end) {
            const line = self.cur().pt.lineOf(self.curCursor().*);
            const n = @max(m.count, 1);
            const start_line = @min(line, self.cur().pt.lineCount() - 1);
            const end_line = @min(start_line + n - 1, self.cur().pt.lineCount() - 1);
            const start = self.cur().pt.lineStart(start_line);
            var end = self.cur().pt.lineStart(end_line) + self.cur().pt.lineLen(end_line);
            // dd/yy take the trailing newline (the line is gone from the
            // buffer); cc keeps it — vim's change clears the line's TEXT and
            // puts the cursor on the (now empty) line, not on the next one
            if (m.op != .change and end_line + 1 < self.cur().pt.lineCount()) end += 1;
            try self.applyOpRange(m.op, start, end, false, true); // whole-line → linewise register
            return;
        }
        // text object (diw / ci( / yaw …): resolve at the cursor; the count
        // follows vim (2ciw = two words, 2i( = second nesting level)
        if (m.text_object) |kind| {
            const rng = editor.TextObject.range(&self.cur().pt, kind, self.curCursor().*, m.count);
            try self.applyOpRange(m.op, rng.start, rng.end, false, false);
            return;
        }
        // visual mode: the operator acts on the selection
        if (self.isVisual()) {
            if (self.visual_anchor) |anchor| {
                if (self.state.mode == .visual_block) {
                    try self.applyBlockOp(m.op);
                } else {
                    try self.applyOpRangeEx(m.op, anchor, self.curCursor().*, false, .inclusive_cursor, self.state.mode == .visual_line);
                }
            }
            self.exitVisualAfterOp(m.op);
            return;
        }
        // linewise motions (j/k/G/gg/{/}) with an operator from
        // mid-line: the range covers WHOLE lines from the cursor
        // line through the target line (the dd sentinel above already
        // handled the pure line_start case). Deleting a partial
        // byte range across lines would shred the text.
        if (!m.exclusive_end) {
            const from_line = self.cur().pt.lineOf(self.curCursor().*);
            // H/M/L are linewise viewport motions: Motion.target can't
            // resolve them (no viewport), so take the line from the window.
            const to_line = if (self.viewMotionTargetLine(m.motion)) |l|
                l
            else
                self.cur().pt.lineOf(editor.Motion.target(&self.cur().pt, m.motion, m.args, self.curCursor().*, m.count));
            const lo = @min(from_line, to_line);
            const hi = @max(from_line, to_line);
            const start = self.cur().pt.lineStart(lo);
            var end = self.cur().pt.lineStart(hi) + self.cur().pt.lineLen(hi);
            if (hi + 1 < self.cur().pt.lineCount()) end += 1; // include trailing '\n'
            try self.applyOpRange(m.op, start, end, false, true); // linewise motion → linewise register
            return;
        }
        // normal mode: d/c/y over [cursor, target). vim semantics:
        // naturally-exclusive motions (w/b/h/l/t/^) yield a half-open
        // range [cursor, target) as-is; inclusive motions ($/e/f/%)
        // include the character at the target (add one). We therefore
        // pass exclusive=false and pre-adjust the target, instead of
        // the old unconditional end-=1 that broke dl/dh/d$/de/dw.
        var target_pos = editor.Motion.target(&self.cur().pt, m.motion, m.args, self.curCursor().*, m.count);
        if (m.inclusive and target_pos < self.cur().pt.len()) target_pos += 1;
        try self.applyOpRange(m.op, self.curCursor().*, target_pos, false, false);
    }

    fn execAction(self: *App, action: editor.KeyEvent.ActionId, count: u32) !void {
        switch (action) {
            .repeat_last => {
                // '.' — replay the last repeatable edit from the current
                // cursor. An operator+motion re-resolves its range; a plain
                // action re-runs with its stored count. Nothing to replay
                // (or the last edit was undo/redo) → no-op, like vim.
                const rep = self.state.last_repeat orelse return;
                switch (rep) {
                    .action => |a| try self.execAction(a.action, a.count),
                    .op => |o| try self.execOpMotion(o),
                }
            },
            .undo => {
                if (self.in_insert) {
                    self.cur().history.endGroup();
                    self.in_insert = false;
                }
                _ = self.cur().history.undo(&self.cur().pt);
                self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
                // the document changed: keep LSP/inlay in sync (markDirty
                // also touches the dirty flag — acceptable for undo, vim
                // marks the buffer modified after an undo too)
                self.markDirty();
            },
            .redo => {
                _ = self.cur().history.redo(&self.cur().pt);
                self.curCursor().* = @min(self.curCursor().*, self.cur().pt.len());
                self.markDirty();
            },
            .insert_mode => {
                // open the undo group immediately so the whole insert session
                // (deletes first or not) is one undo step
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .append => {
                // a: insert after the character under the cursor
                const line = self.cur().pt.lineOf(self.curCursor().*);
                const end = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                if (self.curCursor().* < end) {
                    var i = self.curCursor().* + 1;
                    while (i < end and (self.cur().pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                    self.curCursor().* = i;
                }
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .insert_before => {
                // I: first non-blank of the line
                const line = self.cur().pt.lineOf(self.curCursor().*);
                const ls = self.cur().pt.lineStart(line);
                const end = ls + self.cur().pt.lineLen(line);
                var pos = ls;
                while (pos < end) {
                    const c = self.cur().pt.byteAt(pos);
                    if (c != ' ' and c != '\t') break;
                    pos += 1;
                }
                self.curCursor().* = pos;
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .append_end => {
                // A: end of the line
                const line = self.cur().pt.lineOf(self.curCursor().*);
                self.curCursor().* = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                self.in_insert = true;
                self.state.mode = .insert;
            },
            .insert_line_after => {
                // o: new line below, cursor on it. The inserted '\n' joins the
                // insert-session undo group (left open until exitInsert), so
                // one undo reverts the whole o+typing session.
                const line = self.cur().pt.lineOf(self.curCursor().*);
                const pos = self.cur().pt.lineStart(line) + self.cur().pt.lineLen(line);
                const col = pos - self.cur().pt.lineStart(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                // Auto-indent: copy the current line's leading whitespace onto
                // the new line so typing continues at the same indent level.
                const indent = try self.leadingIndent(line);
                defer self.alloc.free(indent);
                try self.cur().history.record(&self.cur().pt, pos + 1, 0, indent);
                self.curCursor().* = pos + 1 + @as(u32, @intCast(indent.len));
                self.in_insert = true;
                self.state.mode = .insert;
                // keep inlay hints aligned (the newline + indent shift lines)
                self.adjustInlayHintsInsert(line, col, "\n");
                self.adjustInlayHintsInsert(line + 1, 0, indent);
                // structural edit (newline): force a full reparse next frame —
                // incremental parsing of a newline is where highlight drift
                // shows up ("o then type then jk leaves gray chars")
                self.cur().syntax_revision = std.math.maxInt(u64);
                // Notify LSP (the new line + indent changed the document).
                self.markDirty();
            },
            .insert_line_before => {
                // O: new line above, cursor on it (same open-group semantics)
                const line = self.cur().pt.lineOf(self.curCursor().*);
                const pos = self.cur().pt.lineStart(line);
                self.beginInsertSession();
                self.cur().history.beginGroup();
                try self.cur().history.record(&self.cur().pt, pos, 0, "\n");
                const indent = try self.leadingIndent(line);
                defer self.alloc.free(indent);
                try self.cur().history.record(&self.cur().pt, pos, 0, indent);
                self.curCursor().* = pos + @as(u32, @intCast(indent.len));
                self.in_insert = true;
                self.state.mode = .insert;
                // keep inlay hints aligned (a line was inserted above)
                self.adjustInlayHintsInsert(line, 0, "\n");
                self.adjustInlayHintsInsert(line, 0, indent);
                // structural edit (newline): force a full reparse next frame
                self.cur().syntax_revision = std.math.maxInt(u64);
                self.markDirty();
            },
            .visual_char => {
                // mode.zig already set state.mode, so isVisual() can't tell a
                // fresh entry from a sub-mode switch; the anchor can: it is
                // null on entry and non-null while a selection exists. Keep
                // the selection when switching v -> V / Ctrl+v.
                if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
                self.state.mode = .visual_char;
            },
            .visual_line => {
                if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
                self.state.mode = .visual_line;
            },
            .visual_block => {
                if (self.visual_anchor == null) self.visual_anchor = self.curCursor().*;
                self.state.mode = .visual_block;
            },
            // visual 'o': swap the anchor and the cursor (flip the selection
            // end) — handled by mode.handleVisual and dispatched here
            .flip_visual => {
                if (self.visual_anchor) |a| {
                    const c = self.curCursor().*;
                    self.visual_anchor = c;
                    self.curCursor().* = a;
                }
            },
            .delete, .change, .yank => {
                // multi-cursor: d deletes the selected word at every cursor
                if (self.mc_active and action == .delete and self.state.mode == .normal) {
                    // delete the WORD at each cursor (cursors sit on word
                    // starts): [pos, word_end), not the bytes before the
                    // cursor — and through history so it is undoable
                    const pt = &self.cur().pt;
                    self.cur().history.beginGroup();
                    var i = self.mc.cursors.items.len;
                    while (i > 0) {
                        i -= 1;
                        const pos = self.mc.cursors.items[i];
                        const w = self.mc.wordRange(pt, pos);
                        if (w.end <= w.start) continue;
                        try self.cur().history.record(pt, w.start, w.end - w.start, "");
                        for (self.mc.cursors.items, 0..) |*c, j| {
                            if (j == i) continue;
                            if (c.* >= w.end) c.* -= w.end - w.start;
                        }
                    }
                    self.cur().history.endGroup();
                    self.mc.clear();
                    self.mc_active = false;
                    self.markDirty();
                    return;
                }
                // visual mode: the operator acts on the selection directly.
                // A visual-block selection is a rectangle — d/c/y apply to
                // every covered line's column slice, not one byte range.
                if (self.isVisual()) {
                    if (self.visual_anchor) |anchor| {
                        if (self.state.mode == .visual_block) {
                            try self.applyBlockOp(action);
                        } else if (self.state.mode == .visual_line) {
                            // V selects whole lines: the range spans from the
                            // anchor line's start to the cursor line's end
                            // (including the trailing newline when present),
                            // not just anchor..cursor bytes — otherwise the
                            // last selected line survives a d/c.
                            const pt = &self.cur().pt;
                            const al = pt.lineOf(anchor);
                            const cl = pt.lineOf(self.curCursor().*);
                            const start = pt.lineStart(al);
                            var end = pt.lineStart(cl) + pt.lineLen(cl);
                            if (end < pt.len()) end += 1; // include the newline
                            // exclusive_cursor: the range already ends exactly
                            // after the last selected line's newline.
                            try self.applyOpRangeEx(action, start, end, false, .exclusive_cursor, true);
                        } else {
                            try self.applyOpRangeEx(action, anchor, self.curCursor().*, false, .inclusive_cursor, false);
                        }
                    }
                    self.exitVisualAfterOp(action);
                }
            },
            .mc_add => try self.mcSelectNext(),
            .increment, .decrement => {
                // Ctrl+a / Ctrl+x: a visual selection increments every number
                // in every selected line; otherwise the number at/after the
                // cursor. `count` is the delta (vim: 5<C-a> adds 5).
                const delta: i64 = if (action == .increment) @as(i64, count) else -@as(i64, count);
                if (self.isVisual()) {
                    try self.execSelectionNumberDelta(delta);
                    self.exitVisual();
                } else {
                    try self.execNumberDeltaAtCursor(delta);
                }
            },
            .increment_visual, .decrement_visual => {
                // g Ctrl+a / g Ctrl+x: visual column increment — each line's
                // first number gets ±(count + line offset, 1-based). Normal
                // mode g Ctrl+a is plain Ctrl+a (vim).
                const delta: i64 = if (action == .increment_visual) @as(i64, count) else -@as(i64, count);
                if (self.isVisual()) {
                    try self.execSelectionNumberColumn(delta);
                    self.exitVisual();
                } else {
                    try self.execNumberDeltaAtCursor(delta);
                }
            },
            .next_buffer => try self.switchBuffer(1),
            .prev_buffer => try self.switchBuffer(-1),
            .picker_file => try self.openPicker(),
            .picker_grep => try self.openGrepPicker(),
            .picker_buffers => try self.openBufferPicker(),
            .picker_recent => try self.openRecentPicker(),
            .picker_keymaps => try self.openKeymapPicker(),
            .picker_themes => try self.openThemePicker(),
            .diagnostic_next => self.gotoDiagnostic(true),
            .diagnostic_prev => self.gotoDiagnostic(false),
            .search_next => try self.repeatSearch(false),
            .search_prev => try self.repeatSearch(true),
            .diagnostic_line => self.showLineDiagnostics(),
            .diagnostics_list => self.toggleDiagnosticsList(),
            .hover => try self.requestNav("textDocument/hover", .hover),
            .definition => try self.requestNav("textDocument/definition", .definition),
            .declaration => try self.requestNav("textDocument/declaration", .declaration),
            .references => try self.requestNav("textDocument/references", .references),
            .implementation => try self.requestNav("textDocument/implementation", .implementation),
            .signature_help => try self.requestNav("textDocument/signatureHelp", .signature),
            .rename_symbol => try self.requestRename(),
            .format_document => try self.requestFormat(),
            .inlay_hints => try self.requestInlayHints(),
            .document_outline => try self.requestOutline(),
            .close_buffer => self.closeCurrentBuffer(),
            .buffer_to_left_win => self.moveBufferToWindow(.left),
            .buffer_to_right_win => self.moveBufferToWindow(.right),
            .filetree_toggle => try self.toggleFiletree(),
            .filetree_locate => try self.locateInFiletree(),
            // M3 git
            .hunk_next => self.gotoHunk(true),
            .hunk_prev => self.gotoHunk(false),
            .hunk_stage => self.applyHunk(.stage),
            .hunk_reset => self.applyHunk(.reset),
            .hunk_preview => self.previewHunk(),
            .blame_toggle => self.toggleBlame(),
            .git_lazygit => self.launchLazygit(),
            .paste => try self.pasteBuffer(false, count),
            .paste_before => try self.pasteBuffer(true, count),
            .delete_char => {
                // x: vim dl — delete `count` characters under the cursor. At
                // the end of a line the newline is deleted (joining the next
                // line), like vim; at EOF nothing happens. One undo group.
                // The deleted text fills the unnamed register (charwise) —
                // vim's xp char-swap depends on it. Capture BEFORE deleting:
                // setRegister reads the live piece table.
                const c0 = self.curCursor().*;
                var reg_end = c0;
                var i: u32 = 0;
                while (i < @max(count, 1)) : (i += 1) {
                    if (reg_end >= self.cur().pt.len()) break;
                    const seq = self.charLenAt(&self.cur().pt, reg_end);
                    reg_end = @min(reg_end + seq, self.cur().pt.len());
                }
                if (reg_end > c0) try self.setRegister(c0, reg_end, false);
                self.cur().history.beginGroup();
                i = 0;
                while (i < @max(count, 1)) : (i += 1) {
                    const c = self.curCursor().*;
                    if (c >= self.cur().pt.len()) break;
                    const pt = &self.cur().pt;
                    const seq = self.charLenAt(pt, c);
                    const end = @min(c + seq, pt.len());
                    if (end <= c) break;
                    try self.cur().history.record(pt, c, end - c, "");
                }
                self.cur().history.endGroup();
                self.markDirty();
            },
            .delete_char_before => {
                // X: vim dh — delete `count` chars before the cursor (the
                // deleted text fills the unnamed register, charwise; capture
                // BEFORE deleting — setRegister reads the live piece table)
                const c0 = self.curCursor().*;
                var reg_start = c0;
                var i: u32 = 0;
                while (i < @max(count, 1)) : (i += 1) {
                    if (reg_start == 0) break;
                    reg_start -= 1;
                    while (reg_start > 0 and (self.cur().pt.byteAt(reg_start) & 0xC0) == 0x80) reg_start -= 1;
                }
                if (reg_start < c0) try self.setRegister(reg_start, c0, false);
                self.cur().history.beginGroup();
                i = 0;
                while (i < @max(count, 1)) : (i += 1) {
                    const c = self.curCursor().*;
                    if (c == 0) break;
                    const pt = &self.cur().pt;
                    // walk back to the start of the previous UTF-8 character
                    var start = c - 1;
                    while (start > 0 and (pt.byteAt(start) & 0xC0) == 0x80) start -= 1;
                    try self.cur().history.record(pt, start, c - start, "");
                    self.curCursor().* = start;
                }
                self.cur().history.endGroup();
                self.markDirty();
            },
            .delete_to_eol => {
                // D: delete to end of line (d$), keeping the newline so the
                // line is emptied, not removed. vim count: `count` lines
                // from the cursor (3D = delete to EOL on three lines). The
                // deleted text fills the unnamed register (charwise).
                const c = self.curCursor().*;
                const pt = &self.cur().pt;
                const line = pt.lineOf(c);
                const end_line = @min(line + @max(count, 1) - 1, pt.lineCount() - 1);
                const end = pt.lineStart(end_line) + pt.lineLen(end_line);
                if (end > c) {
                    try self.setRegister(c, end, false);
                    self.cur().history.beginGroup();
                    try self.cur().history.record(pt, c, end - c, "");
                    self.cur().history.endGroup();
                    self.curCursor().* = c;
                    self.markDirty();
                }
            },
            .change_to_eol => {
                // C: change to end of line (c$) — vim count: `count` lines
                // (3C = change to EOL on three lines). Delete the tail and
                // enter insert with the undo group open, like applyOpRangeEx.
                const c = self.curCursor().*;
                const pt = &self.cur().pt;
                const line = pt.lineOf(c);
                const end_line = @min(line + @max(count, 1) - 1, pt.lineCount() - 1);
                const end = pt.lineStart(end_line) + pt.lineLen(end_line);
                self.cur().history.beginGroup();
                if (end > c) {
                    try self.cur().history.record(pt, c, end - c, "");
                }
                self.state.mode = .insert;
                self.in_insert = true; // group stays open until exitInsert
                self.markDirty();
                self.cur().syntax_revision = std.math.maxInt(u64);
            },
            .change_line => {
                // S: change the whole line (cc) — delete the line's CONTENT
                // (the newline stays, like vim cc) and enter insert with the
                // cursor on the emptied line.
                const pt = &self.cur().pt;
                const line = pt.lineOf(self.curCursor().*);
                const start = pt.lineStart(line);
                const end = start + pt.lineLen(line);
                self.curCursor().* = start;
                self.cur().history.beginGroup();
                try self.cur().history.record(pt, start, end - start, "");
                self.state.mode = .insert;
                self.in_insert = true;
                self.markDirty();
                self.cur().syntax_revision = std.math.maxInt(u64);
            },
            .replace_char => {
                // r{char}: arm the pending-replace capture; the next plain
                // key (handled before the mode dispatch) replaces the char
                // under the cursor via replaceCharsAtCursor. `count` chars
                // are replaced (vim 3rx).
                self.pending_replace = .{ .count = count };
            },
            .toggle_case => {
                // ~: swap the case of `count` chars under the cursor,
                // advancing (vim ~). One undo group.
                self.cur().history.beginGroup();
                var i: u32 = 0;
                while (i < @max(count, 1)) : (i += 1) {
                    const c = self.curCursor().*;
                    const pt = &self.cur().pt;
                    if (c >= pt.len()) break;
                    const seq = self.charLenAt(pt, c);
                    if (seq != 1) break; // multi-byte: not ASCII, leave alone
                    var buf: [1]u8 = undefined;
                    pt.copyRange(c, buf[0..1]);
                    var swapped: ?u8 = null;
                    if (buf[0] >= 'a' and buf[0] <= 'z') {
                        swapped = buf[0] - 32;
                    } else if (buf[0] >= 'A' and buf[0] <= 'Z') {
                        swapped = buf[0] + 32;
                    }
                    if (swapped) |ch| {
                        try self.cur().history.record(pt, c, 1, &.{ch});
                        self.curCursor().* = c + seq;
                    } else {
                        self.curCursor().* = c + seq;
                    }
                }
                self.cur().history.endGroup();
                self.markDirty();
            },
            .join_lines => {
                // J: join the current line with the next: remove the newline,
                // trim the next line's leading whitespace to one space (vim
                // joins with a single space when the first line is non-empty).
                const pt = &self.cur().pt;
                const line = pt.lineOf(self.curCursor().*);
                if (line + 1 >= pt.lineCount()) return;
                const cur_end = pt.lineStart(line) + pt.lineLen(line);
                const next_start = pt.lineStart(line + 1);
                const next_len = pt.lineLen(line + 1);
                var next_indent: u32 = 0;
                while (next_indent < next_len) : (next_indent += 1) {
                    const b = pt.byteAt(next_start + next_indent);
                    if (b != ' ' and b != '\t') break;
                }
                self.cur().history.beginGroup();
                // remove the newline (cur_end, one byte)
                try self.cur().history.record(pt, cur_end, 1, "");
                // collapse leading whitespace of the next line
                if (next_indent > 0) {
                    try self.cur().history.record(pt, next_start - 1, next_indent, "");
                }
                // join with a single space unless the first line is empty.
                // The next line's first char now sits at next_start - 1 (the
                // newline is gone); inserting BEFORE it glues the lines.
                if (cur_end > pt.lineStart(line)) {
                    try self.cur().history.record(pt, next_start - 1, 0, " ");
                }
                self.cur().history.endGroup();
                self.curCursor().* = @min(self.curCursor().*, pt.len());
                self.markDirty();
            },
            .indent_line, .dedent_line => {
                // >> / <<: add / remove one indent unit (4 spaces, matching
                // the insert-mode tab) at the start of each line the count
                // covers, starting at the cursor line.
                const pt = &self.cur().pt;
                const start_line = pt.lineOf(self.curCursor().*);
                const n = @max(count, 1);
                const end_line = @min(start_line + n - 1, pt.lineCount() - 1);
                const indent = if (action == .indent_line) "    " else "";
                self.cur().history.beginGroup();
                var l = start_line;
                while (l <= end_line) : (l += 1) {
                    const ls = pt.lineStart(l);
                    if (action == .indent_line) {
                        try self.cur().history.record(pt, ls, 0, indent);
                    } else {
                        // remove up to 4 leading spaces/tabs
                        var removed: u32 = 0;
                        while (removed < 4) : (removed += 1) {
                            if (ls >= pt.len()) break;
                            const b = pt.byteAt(ls);
                            if (b == ' ' or b == '\t') {
                                try self.cur().history.record(pt, ls, 1, "");
                            } else break;
                        }
                    }
                }
                self.cur().history.endGroup();
                self.curCursor().* = @min(self.curCursor().*, pt.len());
                self.markDirty();
            },
            .toggle_comment_line => try self.toggleCommentLine(),
            .easymotion, .leader_find => {
                // start the EasyMotion capture flow
                self.em_active = true;
                self.em_labels = false;
                self.em_query = .{ 0, 0, 0, 0 };
                self.em_query_len = 0;
            },
            .enter_command_mode => {},
            // zz/zt/zb — view-only scrolls of the focused window
            .scroll_cursor_center => self.scrollCursorTo(.center),
            .scroll_cursor_top => self.scrollCursorTo(.top),
            .scroll_cursor_bottom => self.scrollCursorTo(.bottom),
            // za/zo/zc/zR/zM — buffer fold state (not edits; no markDirty)
            .fold_toggle, .fold_open, .fold_close, .fold_open_all, .fold_close_all => try self.execFold(action),
            else => {},
        }
    }

    /// r{char}: replace the character under the cursor with `ch` (a single
    /// byte; multi-byte replacements keep the original sequence length).
    /// Like vim, the cursor stays on the replaced char (it does not move).
    /// r{char} with a vim count (3rx): replace `count` characters under the
    /// cursor with `ch`, one undo group. The cursor stays on the LAST
    /// replaced character (vim r: 3rx leaves it on the third replacement).
    fn replaceCharsAtCursor(self: *App, ch: u8, count: u32) !void {
        const pt = &self.cur().pt;
        self.cur().history.beginGroup();
        var c = self.curCursor().*;
        var i: u32 = 0;
        while (i < @max(count, 1)) : (i += 1) {
            if (c >= pt.len()) break;
            const seq = self.charLenAt(pt, c);
            if (seq != 1) break; // only replace single-byte chars
            if (pt.byteAt(c) != ch) {
                try self.cur().history.record(pt, c, 1, &.{ch});
            }
            c += 1;
        }
        self.cur().history.endGroup();
        self.curCursor().* = c -| 1;
        self.markDirty();
    }

    // ---- number increment/decrement (Ctrl+a / Ctrl+x / g Ctrl+a / g Ctrl+x) ----

    /// One number occurrence in the document: byte range plus parsed value.
    const Number = struct {
        start: u32,
        end: u32, // exclusive
        value: i64,
    };

    fn isDigitByte(b: u8) bool {
        return b >= '0' and b <= '9';
    }

    /// Expand the digit run containing `digit_pos` into the whole number.
    /// A '-' immediately before the run is included as the sign, unless it is
    /// itself glued to a preceding digit ("1-5" with the cursor on 5 is the
    /// number 5, while "-5" is -5). Returns null when the digits do not fit
    /// i64 (the number is then left untouched).
    fn numberAtDigit(self: *App, digit_pos: u32) ?Number {
        const pt = &self.cur().pt;
        const len = pt.len();
        var start = digit_pos;
        while (start > 0 and isDigitByte(pt.byteAt(start - 1))) start -= 1;
        if (start > 0 and pt.byteAt(start - 1) == '-' and
            (start == 1 or !isDigitByte(pt.byteAt(start - 2))))
        {
            start -= 1;
        }
        var end = digit_pos + 1;
        while (end < len and isDigitByte(pt.byteAt(end))) end += 1;
        var v: i64 = 0;
        var i = start;
        const neg = if (i < end and pt.byteAt(i) == '-') blk: {
            i += 1;
            break :blk true;
        } else false;
        while (i < end) : (i += 1) {
            const d = pt.byteAt(i) - '0';
            if (v > @divTrunc(std.math.maxInt(i64) - @as(i64, d), 10)) return null; // overflow
            v = v * 10 + @as(i64, d);
        }
        return .{ .start = start, .end = end, .value = if (neg) -v else v };
    }

    /// The first number at or after `pos` (vim Ctrl+a semantics): the digit
    /// run under the cursor, else the next digit run (optionally '-' signed)
    /// scanning forward. Returns null when no number exists at/after `pos`.
    fn numberAtOrAfter(self: *App, pos: u32) ?Number {
        const pt = &self.cur().pt;
        const len = pt.len();
        if (pos >= len) return null;
        if (isDigitByte(pt.byteAt(pos))) return self.numberAtDigit(pos);
        var i = pos;
        while (i < len) : (i += 1) {
            const b = pt.byteAt(i);
            if (isDigitByte(b)) return self.numberAtDigit(i);
            if (b == '-' and i + 1 < len and isDigitByte(pt.byteAt(i + 1))) {
                return self.numberAtDigit(i + 1);
            }
        }
        return null;
    }

    /// The first number in [ls, le) (column-increment target), if any.
    fn firstNumberInLine(self: *App, ls: u32, le: u32) ?Number {
        var p = ls;
        while (p < le) {
            const b = self.cur().pt.byteAt(p);
            if (isDigitByte(b)) return self.numberAtDigit(p);
            if (b == '-' and p + 1 < le and isDigitByte(self.cur().pt.byteAt(p + 1))) {
                return self.numberAtDigit(p + 1);
            }
            p += 1;
        }
        return null;
    }

    /// Replace one number with value+delta; returns the byte end of the new
    /// text (the number may have grown or shrunk).
    fn replaceNumber(self: *App, n: Number, delta: i64) !u32 {
        const new = try std.fmt.allocPrint(self.alloc, "{d}", .{n.value + delta});
        defer self.alloc.free(new);
        try self.cur().history.record(&self.cur().pt, n.start, n.end - n.start, new);
        return n.start + @as(u32, @intCast(new.len));
    }

    /// Normal-mode Ctrl+a/x: increment the number at/after the cursor and
    /// place the cursor just after it (vim). One undo step.
    fn execNumberDeltaAtCursor(self: *App, delta: i64) !void {
        const n = self.numberAtOrAfter(self.curCursor().*) orelse return;
        self.cur().history.beginGroup();
        const new_end = try self.replaceNumber(n, delta);
        self.cur().history.endGroup();
        self.curCursor().* = new_end;
        self.markDirty();
    }

    /// Visual-mode Ctrl+a/x: increment every number in every line covered by
    /// the selection. One undo group; edits are applied right-to-left so the
    /// earlier offsets stay valid.
    fn execSelectionNumberDelta(self: *App, delta: i64) !void {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.curCursor().*);
        const e = @max(anchor, self.curCursor().*);
        const pt = &self.cur().pt;
        const start_line = pt.lineOf(s);
        const end_line = pt.lineOf(e);
        self.cur().history.beginGroup();
        var numbers = std.ArrayList(Number).empty;
        defer numbers.deinit(self.alloc);
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const ls = pt.lineStart(line);
            const le = ls + pt.lineLen(line);
            var p = ls;
            while (p < le) {
                const b = pt.byteAt(p);
                if (isDigitByte(b)) {
                    const n = self.numberAtDigit(p) orelse {
                        p += 1;
                        continue;
                    };
                    try numbers.append(self.alloc, n);
                    p = n.end;
                } else if (b == '-' and p + 1 < le and isDigitByte(pt.byteAt(p + 1))) {
                    const n = self.numberAtDigit(p + 1) orelse {
                        p += 1;
                        continue;
                    };
                    try numbers.append(self.alloc, n);
                    p = n.end;
                } else {
                    p += 1;
                }
            }
        }
        var i = numbers.items.len;
        while (i > 0) {
            i -= 1;
            _ = try self.replaceNumber(numbers.items[i], delta);
        }
        self.cur().history.endGroup();
        self.markDirty();
    }

    /// Visual-mode g Ctrl+a/x (vim column increment): each selected line's
    /// FIRST number gets ±(count + line offset), the i-th selected line (i
    /// starting at 1) getting ±i with count 1. A visual-BLOCK selection
    /// restricts the numbers to the block's column range (vim: only numbers
    /// inside the block are touched). One undo group; lines are processed
    /// bottom-up so earlier lines keep valid offsets.
    fn execSelectionNumberColumn(self: *App, delta: i64) !void {
        const anchor = self.visual_anchor orelse return;
        const s = @min(anchor, self.curCursor().*);
        const e = @max(anchor, self.curCursor().*);
        const pt = &self.cur().pt;
        const start_line = pt.lineOf(s);
        const end_line = pt.lineOf(e);
        // visual block: the numbers must overlap the block's column range;
        // other visual modes take each line's first number
        const block_cols: ?BlockRect = if (self.state.mode == .visual_block) self.blockRect() else null;
        self.cur().history.beginGroup();
        var line = end_line;
        while (true) {
            const ls = pt.lineStart(line);
            const le = ls + pt.lineLen(line);
            var num: ?Number = null;
            if (block_cols) |br| {
                // first number whose digits overlap the block columns
                var p = @min(ls + br.left, le);
                const right = @min(ls + br.right + 1, le);
                while (p < right) {
                    if (isDigitByte(pt.byteAt(p))) {
                        num = self.numberAtDigit(p);
                        break;
                    }
                    p += 1;
                }
            } else {
                num = self.firstNumberInLine(ls, le);
            }
            if (num) |n| {
                const offset: i64 = @intCast(line - start_line + 1);
                _ = try self.replaceNumber(n, delta * offset);
            }
            if (line == start_line) break;
            line -= 1;
        }
        self.cur().history.endGroup();
        self.markDirty();
    }

    /// p / P: put the unnamed register exactly like nvim. A LINEWISE register
    /// (yy, dd, V{y,d}, yG, …) puts whole lines below (p) / above (P) the
    /// cursor line and leaves the cursor on the first non-blank of the first
    /// pasted line. A charwise register (yw, vey, …) pastes inline after (p)
    /// / at (P) the cursor and leaves the cursor on the last pasted char.
    /// `count` pastes that many times (vim 5p), one undo group.
    fn pasteBuffer(self: *App, before: bool, count: u32) !void {
        const buf = self.yank_buffer orelse {
            try self.setMsg(try self.alloc.dupe(u8, "E353: Nothing in register"));
            return;
        };
        if (buf.len == 0 and !self.yank_linewise) return;
        const pt = &self.cur().pt;
        const n = @max(count, 1);
        if (self.yank_linewise) {
            // normalize: the register must end with '\n' so every copy lands
            // as complete lines (yy on a final line without a trailing
            // newline yanks none; yy on an empty line yanks zero bytes —
            // both paste as one empty line).
            var norm = try self.alloc.alloc(u8, buf.len + 1);
            defer self.alloc.free(norm);
            @memcpy(norm[0..buf.len], buf);
            const text: []const u8 = if (buf.len == 0) blk: {
                norm[0] = '\n';
                break :blk norm[0..1];
            } else if (buf[buf.len - 1] == '\n') norm[0..buf.len] else blk: {
                norm[buf.len] = '\n';
                break :blk norm;
            };
            const line = pt.lineOf(self.curCursor().*);
            self.cur().history.beginGroup();
            var content_start: u32 = undefined; // first pasted byte (for the cursor)
            if (before) {
                var pos = pt.lineStart(line);
                content_start = pos;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try self.cur().history.record(pt, pos, 0, text);
                    pos += @intCast(text.len);
                }
            } else if (line + 1 < pt.lineCount()) {
                var pos = pt.lineStart(line + 1);
                content_start = pos;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try self.cur().history.record(pt, pos, 0, text);
                    pos += @intCast(text.len);
                }
            } else {
                // cursor on the last line: terminate it first when the buffer
                // doesn't end with a newline, then the copies follow as
                // whole lines
                var pos = pt.len();
                if (pos > 0 and pt.byteAt(pos - 1) != '\n') {
                    try self.cur().history.record(pt, pos, 0, "\n");
                    pos += 1;
                }
                content_start = pos;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try self.cur().history.record(pt, pos, 0, text);
                    pos += @intCast(text.len);
                }
            }
            self.cur().history.endGroup();
            // cursor on the first non-blank of the first pasted line (an
            // all-blank line leaves it at the line start)
            var c = content_start;
            while (c < pt.len() and (pt.byteAt(c) == ' ' or pt.byteAt(c) == '\t')) c += 1;
            if (c < pt.len() and pt.byteAt(c) == '\n') c = content_start;
            self.curCursor().* = c;
        } else {
            var pos = self.curCursor().*;
            if (!before) {
                // p: after the character under the cursor (or at line end)
                const line = pt.lineOf(self.curCursor().*);
                const line_end = pt.lineStart(line) + pt.lineLen(line);
                if (self.curCursor().* < line_end) {
                    var i = self.curCursor().* + 1;
                    while (i < line_end and (pt.byteAt(i) & 0xC0) == 0x80) : (i += 1) {}
                    pos = i;
                }
            }
            self.cur().history.beginGroup();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try self.cur().history.record(pt, pos, 0, buf);
                pos += @as(u32, @intCast(buf.len));
            }
            self.cur().history.endGroup();
            // nvim: the cursor lands ON the last pasted character (not past
            // it) — back up over UTF-8 continuation bytes
            var c = pos - 1;
            const paste_begin = pos - @as(u32, @intCast(buf.len));
            while (c > paste_begin and (pt.byteAt(c) & 0xC0) == 0x80) c -= 1;
            self.curCursor().* = c;
        }
        // markDirty is the single entry point for dirty flag / edit_seq /
        // LSP didChange / inlay invalidation — paste must go through it or
        // the server keeps an outdated document and hints stay stale.
        self.markDirty();
    }

    // ---- rendering ----

    const filetree_width: u32 = 25;

    /// Tab-bar rows: one per column-overlap layer of the pane layout.
    /// Panes whose column spans overlap (horizontal splits stack
    /// full-width panes) draw their tabs on separate rows so tabs never
    /// overwrite each other; vertical splits share a row (their spans are
    /// disjoint). Column spans don't depend on the split heights, so a
    /// nominal content height is fine here.
    fn tabBarRows(self: *App, a: std.mem.Allocator) u32 {
        if (self.windows.items.len <= 1) return 1;
        const height: u32 = self.vx.window().height;
        if (height <= status_row_count) return 1;
        const layout = self.layoutWindows(a, 1, height - status_row_count - 1, self.contentCol(), self.vx.window().width) catch return 1;
        const leaves = layout.leaves;
        // greedy interval coloring: assign each pane to the lowest layer
        // whose rightmost pane ends at or before this pane's column start
        var order: std.ArrayList(usize) = .empty;
        defer order.deinit(a);
        for (0..leaves.len) |i| order.append(a, i) catch return 1;
        std.mem.sort(usize, order.items, TabSort{ .leaves = leaves }, TabSort.lt);
        var layer_end: std.ArrayList(u32) = .empty;
        defer layer_end.deinit(a);
        var layers: u32 = 0;
        for (order.items) |oi| {
            const lr = leaves[oi];
            var li: usize = 0;
            while (li < layers and layer_end.items[li] > lr.col) li += 1;
            if (li == layers) {
                layer_end.append(a, lr.col + lr.width) catch return 1;
                layers += 1;
            } else {
                layer_end.items[li] = lr.col + lr.width;
            }
        }
        return layers;
    }

    /// Sort panes by column for tab streaming: left to right, wider first
    /// when spans start at the same column (stable per pane index).
    const TabSort = struct {
        leaves: []LeafRect,
        fn lt(ctx: TabSort, x: usize, y: usize) bool {
            const ax = ctx.leaves[x];
            const ay = ctx.leaves[y];
            if (ax.col != ay.col) return ax.col < ay.col;
            return ax.width > ay.width;
        }
    };

    /// Row where the editor content starts (below the tab bar).
    fn contentTop(self: *App, a: std.mem.Allocator) u32 {
        return self.tabBarRows(a);
    }

    fn contentCol(self: *const App) u32 {
        return if (self.filetree_active) filetree_width else 0;
    }

    /// Width of the relative-line-number gutter in cells: digits of the
    /// largest possible relative number (≤ the file's line count, since a
    /// relative number is a line offset) + one trailing space. Adaptive —
    /// narrow for small files (vim's relativenumber fits the digits).
    fn gutterWidth(self: *const App, line_count: u32) u32 {
        _ = self;
        var digits: u32 = 1;
        var n: u32 = line_count;
        while (n >= 10) : (n /= 10) digits += 1;
        return digits + 1;
    }

    /// Display column (in cells) of `byte_pos` within `line`. vaxis renders a
    /// multi-byte grapheme as one or two cells, so anything positioned from a
    /// byte offset (the text cursor, the completion menu, ghost text) must be
    /// converted — otherwise the cursor appears stuck mid-text on lines that
    /// contain non-ASCII characters (e.g. after accepting a suggestion that
    /// inserted text before/after CJK characters).
    fn lineCellCol(self: *App, win: vaxis.Window, line: u32, byte_pos: u32) u32 {
        const pt = &self.cur().pt;
        const line_start = pt.lineStart(line);
        var p = line_start;
        var col: u32 = 0;
        while (p < byte_pos) {
            const b = pt.byteAt(p);
            // A tab occupies `tab_width` cells (the renderer expands it), not
            // the 0 vaxis reports — otherwise cursor/ghost/menu columns would
            // disagree with the drawn line on files containing tabs.
            if (b == '\t') {
                col += tab_width;
                p += 1;
                continue;
            }
            const seq_len: usize = if (b < 0x80)
                1
            else
                (std.unicode.utf8ByteSequenceLength(b) catch 1);
            const avail = @min(seq_len, @as(usize, @intCast(byte_pos - p)));
            var ch_buf: [4]u8 = undefined;
            pt.copyRange(p, ch_buf[0..avail]);
            col += win.gwidth(ch_buf[0..avail]);
            p += @intCast(avail);
        }
        return col;
    }

    /// Display width (cells) of `text` — the same per-grapheme gwidth the
    /// renderer uses. Used to shift columns past inlay hints: they occupy
    /// screen cells but no buffer bytes, so a plain text column understates
    /// the on-screen position by their combined width.
    fn textWidth(self: *App, win: vaxis.Window, text: []const u8) u32 {
        _ = self;
        var col: u32 = 0;
        var p: usize = 0;
        while (p < text.len) {
            const b = text[p];
            if (b == '\t') {
                col += tab_width;
                p += 1;
                continue;
            }
            const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
            const avail = @min(seq_len, text.len - p);
            col += win.gwidth(text[p .. p + avail]);
            p += avail;
        }
        return col;
    }

    /// LSP positions are in UTF-16 code units, not bytes. Convert a byte
    /// column within `line` (BMP chars = 1 unit, supplementary = 2). Without
    /// this, hover/gd/completion/rename land at the wrong column on any line
    /// containing CJK/emoji before the cursor.
    fn utf16Column(self: *App, line: u32, byte_col: u32) u32 {
        const pt = &self.cur().pt;
        const ls = pt.lineStart(line);
        var p = ls;
        var units: u32 = 0;
        while (p < ls + byte_col) {
            const b = pt.byteAt(p);
            const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
            units += if (seq_len >= 4) 2 else 1;
            p += @intCast(seq_len);
        }
        return units;
    }

    /// Inverse of utf16Column: the byte offset within `line` of the
    /// character at UTF-16 column `utf16_col` (LSP positions are UTF-16
    /// code units). Clamped to the line end when the column runs past the
    /// text (some servers report a hint at the token end == line end).
    fn byteColumnFromUtf16(self: *App, line: u32, utf16_col: u32) u32 {
        const pt = &self.cur().pt;
        const ls = pt.lineStart(line);
        const end = ls + pt.lineLen(line);
        var p = ls;
        var units: u32 = 0;
        while (p < end) {
            if (units >= utf16_col) break;
            const b = pt.byteAt(p);
            const seq_len: usize = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
            units += if (seq_len >= 4) 2 else 1;
            p += @intCast(seq_len);
        }
        return p - ls;
    }

    /// On-screen cell column of `byte_pos` within `line`: the text column
    /// plus the width of every inlay hint spliced before it.
    fn screenCellCol(self: *App, win: vaxis.Window, line: u32, byte_pos: u32) u32 {
        const text_col = self.lineCellCol(win, line, byte_pos);
        var col = text_col;
        // hints anchored before the cursor widen the cursor's cell column.
        // hint.character is a byte column (see processInlay), so compare it
        // with the cursor's byte offset within the line — not a cell column.
        const ls = self.cur().pt.lineStart(line);
        const in_line = if (byte_pos >= ls) byte_pos - ls else 0;
        for (self.inlay_hints.items) |hint| {
            if (hint.line == line and hint.character <= in_line) {
                col += self.textWidth(win, hint.label);
            }
        }
        return col;
    }

    /// true when buffer line `l` has no non-whitespace content.
    fn isBlankLine(self: *App, buf: *Buffer, l: u32) bool {
        _ = self;
        const ls = buf.pt.lineStart(l);
        const ll = buf.pt.lineLen(l);
        var i: u32 = 0;
        while (i < ll) : (i += 1) {
            const b = buf.pt.byteAt(ls + i);
            if (b != ' ' and b != '\t') return false;
        }
        return true;
    }

    /// Expanded indent levels (columns / tab_width) of buffer line `l`.
    fn lineIndentLevels(self: *App, buf: *Buffer, l: u32) u32 {
        _ = self;
        const ls = buf.pt.lineStart(l);
        const ll = buf.pt.lineLen(l);
        var cols: u32 = 0;
        var i: u32 = 0;
        while (i < ll) : (i += 1) {
            const b = buf.pt.byteAt(ls + i);
            if (b == ' ') {
                cols += 1;
            } else if (b == '\t') {
                cols += tab_width;
            } else break;
        }
        return cols / tab_width;
    }

    /// Render one split window's lines into `rect` (content-area coordinates).
    /// The highlighter is bound to the current buffer, so only the focused
    /// window gets syntax highlighting and the (single) visual selection.
    fn renderWindowLines(self: *App, a: std.mem.Allocator, rect: LeafRect, is_focused: bool) !void {
        const win = self.vx.window();
        const w = &self.windows.items[rect.win];
        const buf = &self.buffers.items[w.buf];

        // A buffer edited through ANOTHER window may have shrunk under this
        // window's cursor/viewport (e.g. delete at EOF while a split window's
        // cursor sat there) — clamp before any line math, which asserts on
        // out-of-range positions (lineOf / lineStart).
        if (w.cursor > buf.pt.len()) w.cursor = buf.pt.len();
        if (w.view_top > buf.pt.lineCount() -| 1) w.view_top = buf.pt.lineCount() -| 1;

        // Fold backstop: the cursor must never sit on a hidden line. Every
        // fold-aware motion snaps already; this catches the paths that don't
        // go through them (search jumps, LSP goto, :N, splits' stale cursors).
        w.cursor = foldSnapPos(buf, w.cursor);

        const cursor_line = buf.pt.lineOf(w.cursor);
        const line_count = buf.pt.lineCount();
        // relative-number gutter: computed once per frame per window
        const gutter = self.gutterWidth(line_count);
        const gutter_digits = gutter - 1;

        // keep cursor line visible (per-window viewport). Fold-aware: a
        // closed fold occupies ONE screen row, so screen distances are
        // counted by walking visible lines, not by line-number arithmetic.
        // view_top itself must be a visible line — snap it up out of any
        // closed fold it fell into.
        if (foldCovering(buf, w.view_top)) |f| w.view_top = f.start;
        if (cursor_line < w.view_top) {
            w.view_top = cursor_line;
        }
        // rows between view_top and the cursor line (cursor inclusive of
        // itself, view_top row counts as row 0)
        var rows_to_cursor: u32 = 0;
        {
            var l = w.view_top;
            while (l < cursor_line) : (rows_to_cursor += 1) l = foldNextLine(buf, l);
        }
        while (rows_to_cursor >= rect.height and w.view_top < cursor_line) {
            w.view_top = foldNextLine(buf, w.view_top);
            rows_to_cursor -= 1;
        }
        // don't scroll past the end leaving blank rows: pull view_top up
        // while fewer than `height` visible rows remain below it (without
        // pushing the cursor off-screen)
        {
            var below: u32 = rows_to_cursor + 1; // + the cursor row itself
            var l = cursor_line;
            while (l + 1 < line_count) {
                l = foldNextLine(buf, l);
                below += 1;
            }
            while (below < rect.height and w.view_top > 0 and rows_to_cursor + 1 < rect.height) {
                w.view_top = foldPrevLine(buf, w.view_top);
                below += 1;
                rows_to_cursor += 1;
            }
        }

        // syntax spans covering the visible byte range — every window uses
        // its own buffer's highlighter, so splits showing different buffers
        // each get real tree-sitter highlighting. With closed folds the
        // visible rows span MORE document lines than rect.height (hidden
        // bodies are skipped), so walk the actual last visible line first.
        var last_visible = w.view_top;
        {
            var vr: u32 = 1;
            while (vr < rect.height and last_visible + 1 < line_count) : (vr += 1) {
                last_visible = foldNextLine(buf, last_visible);
            }
        }
        const merged = try self.visibleSpansFor(buf, a, w.view_top, last_visible - w.view_top + 1);

        // scope highlight (nvim snacks.indent.scope): the byte range of the
        // block containing this window's cursor, converted to a line range.
        // Skipped when the buffer has no highlighter (no grammar for the
        // filetype / over the size limit) — scopeAt also returns null for
        // empty files, top-level code and before the first parse.
        var scope_start_line: u32 = 0;
        var scope_end_line: u32 = 0;
        var scope_indent_col: u32 = 0;
        var has_scope = false;
        if (buf.hl) |*hl| {
            if (hl.scopeAt(w.cursor)) |sc| {
                scope_start_line = buf.pt.lineOf(sc.start_byte);
                // end_byte is exclusive — the last byte inside the scope is
                // end_byte - 1 (lineOf maps pos == len to the last line, so
                // either clamp would work; -| guards the empty edge case)
                scope_end_line = buf.pt.lineOf(sc.end_byte -| 1);
                // the scope's own guide column: the expanded indent of its
                // starting line (snacks.indent renders the scope line at
                // `scope.indent`)
                scope_indent_col = sc.indent_col;
                has_scope = true;
            }
        }
        // ---- scope highlight animation (snacks.indent.animate "out") ----
        // The focused window's guides spread from the cursor line to the
        // scope edges over ~500ms whenever the scope block changes; the run
        // loop polls while animating so the frame advances on its own.
        // Non-focused windows get the full scope immediately (no animation).
        var anim_from: u32 = 0;
        var anim_to: u32 = 0;
        var scope_animating = false;
        if (is_focused) {
            if (!has_scope) {
                self.scope_anim = null;
            } else {
                const now = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms);
                if (self.scope_anim) |*anim| {
                    if (anim.start_line != scope_start_line or anim.end_line != scope_end_line) {
                        anim.* = .{ .start_line = scope_start_line, .end_line = scope_end_line, .cursor_line = cursor_line, .start_ms = now };
                    }
                } else {
                    self.scope_anim = .{ .start_line = scope_start_line, .end_line = scope_end_line, .cursor_line = cursor_line, .start_ms = now };
                }
                const anim = &self.scope_anim.?;
                const elapsed = now - anim.start_ms;
                if (elapsed >= ScopeAnim.duration_ms) {
                    anim_from = scope_start_line;
                    anim_to = scope_end_line;
                } else {
                    scope_animating = true;
                    const p: f64 = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ScopeAnim.duration_ms));
                    const up: u32 = @intFromFloat(p * @as(f64, @floatFromInt(anim.cursor_line -| anim.start_line)));
                    const down: u32 = @intFromFloat(p * @as(f64, @floatFromInt(anim.end_line -| anim.cursor_line)));
                    anim_from = anim.cursor_line -| up;
                    anim_to = anim.cursor_line + down;
                }
            }
        }

        var span_i: usize = 0;
        var row: u32 = rect.row;
        var line = w.view_top;
        while (row < rect.row + rect.height and line < line_count) : ({
            // skip a closed fold's body: it shares its header's screen row
            line = foldNextLine(buf, line);
            row += 1;
        }) {
            const rel: u32 = if (line == cursor_line)
                line + 1
            else if (line > cursor_line)
                line - cursor_line
            else
                cursor_line - line;
            // allocPrint's width is comptime-only, so pad by hand: digits
            // right-aligned in the numeric field plus one trailing space
            const num_raw = try std.fmt.allocPrint(a, "{d}", .{rel});
            const num_str = try a.alloc(u8, gutter);
            @memset(num_str[0..gutter], ' ');
            @memcpy(num_str[gutter_digits - num_raw.len .. gutter_digits], num_raw);
            num_str[gutter - 1] = ' ';

            // LSP diagnostic mark in the gutter's last column (this window
            // shows the current buffer → marks the current file's
            // diagnostics). Nerd Font icons (spec: 图标体系 = Nerd Font),
            // like nvim's diagnostic gutter: ✖ for errors, ⚠ warnings, ℹ
            // info. A bare letter (E/W/I) read as noise/errors to users.
            // Marks render in EVERY mode (nvim behavior): hiding them during
            // insert made a pre-existing mark "appear" on exit, which read as
            // a bug; the diag_dirty repaint keeps them live while typing.
            var diag_mark: []const u8 = " ";
            var diag_mark_fg: ?vaxis.Style = null;
            if (w.buf == self.current and self.lsp_diagnostics.items.len > 0) {
                for (self.lsp_diagnostics.items) |d| {
                    if (d.range.start.line == line) {
                        diag_mark = switch (d.severity) {
                            .err => "\u{f467}", // nf-fa-times_circle ✖
                            .warning => "\u{f071}", // nf-fa-warning ⚠
                            else => "\u{f05a}", // nf-fa-info_circle ℹ
                        };
                        diag_mark_fg = switch (d.severity) {
                            .err => .{ .fg = .{ .rgb = self.theme.diag_error } },
                            .warning => .{ .fg = .{ .rgb = self.theme.diag_warn } },
                            else => .{ .fg = .{ .rgb = self.theme.diag_info } },
                        };
                        break;
                    }
                }
            }

            // Git sign (M3a) for the same last gutter cell, when the line
            // carries no diagnostic mark. Only for a CLEAN buffer: the diff
            // describes the file on disk, and while dirty the marks would
            // lie about the visible text (they return after :w refreshes).
            // Also only when the diff was computed for THIS buffer's path.
            var git_mark: ?git.LineKind = null;
            var git_mark_fg: ?vaxis.Style = null;
            if (w.buf == self.current and !buf.dirty) {
                if (self.git_diff_path) |dp| {
                    if (buf.path) |cp| {
                        if (std.mem.eql(u8, dp, cp)) {
                            if (self.git_diff.markAt(line)) |k| {
                                git_mark = k;
                                git_mark_fg = switch (k) {
                                    .added => .{ .fg = .{ .rgb = self.theme.git_add } },
                                    .modified => .{ .fg = .{ .rgb = self.theme.git_mod } },
                                    .removed_above, .removed_below => .{ .fg = .{ .rgb = self.theme.git_del } },
                                };
                            }
                        }
                    }
                }
            }

            const line_len = buf.pt.lineLen(line);
            const line_start = buf.pt.lineStart(line);
            // the row also carries the gutter (rect.col + gutter), so the
            // content width is rect.width minus the gutter — otherwise long
            // lines are clipped on the right by the gutter width
            var n: u32 = @min(line_len, rect.width -| gutter);
            // don't cut a multibyte char in half at the line end — a lone
            // UTF-8 continuation byte renders as U+FFFD ("box with ?")
            while (n > 0 and n < line_len and (buf.pt.byteAt(line_start + n) & 0xC0) == 0x80) {
                n -= 1;
            }
            const text = try a.alloc(u8, n);
            buf.pt.copyRange(line_start, text);

            // visual selection bounds as local columns (both = n if absent);
            // only the focused window carries the selection
            var sel_s: u32 = n;
            var sel_e: u32 = n;
            if (is_focused) {
                if (self.visual_anchor) |anchor| {
                    var sel_start = @min(anchor, w.cursor);
                    var sel_end = @max(anchor, w.cursor);
                    // V (visual_line) selects whole lines
                    if (self.state.mode == .visual_line) {
                        sel_start = buf.pt.lineStart(buf.pt.lineOf(sel_start));
                        sel_end = buf.pt.lineStart(buf.pt.lineOf(sel_end)) + buf.pt.lineLen(buf.pt.lineOf(sel_end));
                    }
                    // Ctrl+v (visual_block) selects a rectangle
                    if (self.state.mode == .visual_block) {
                        if (self.blockRect()) |br| {
                            if (line >= br.top and line <= br.bottom) {
                                sel_s = @min(br.left, line_len);
                                sel_e = @min(br.right + 1, line_len);
                            }
                        }
                    } else {
                        const line_end = line_start + line_len;
                        if (sel_start < line_end and sel_end > line_start) {
                            sel_s = @max(sel_start, line_start) - line_start;
                            sel_e = @min(sel_end, line_end) - line_start;
                        }
                    }
                }
            }

            // split the line into styled runs: syntax fg from the merged
            // spans, cursorline bg on the cursor's row, selection bg wins
            const is_cur_line = line == cursor_line;
            var segs = std.ArrayList(vaxis.Segment).empty;
            // gutter: always painted (bg_alt), cursor line slightly brighter
            const cursorline_style: vaxis.Style = if (is_cur_line)
                .{ .bg = .{ .rgb = self.theme.bg_curline }, .fg = .{ .rgb = self.theme.fg } }
            else
                .{ .bg = .{ .rgb = self.theme.bg_alt }, .fg = .{ .rgb = self.theme.fg_faint } };
            try segs.append(a, .{ .text = num_str[0 .. gutter - 1], .style = cursorline_style });
            try segs.append(a, .{ .text = num_str[gutter - 1 .. gutter], .style = cursorline_style });
            // Inlay hints for this line, sorted by insertion column: each hint
            // is spliced into the text at its character offset (the token it
            // annotates ends there), so `const x = foo()` renders as
            // `const x: i32 = foo()` like nvim — not moved to end of line.
            // Hints render in insert mode too (vim shows them while typing);
            // the data is shift-maintained per edit so it stays at the right
            // column. `inlay_stale` only hides them for the brief window
            // after a buffer switch / invalidation until a fresh response
            // lands — NOT on insert exit (that caused the jk vanish flash).
            const line_hints = if (self.inlay_stale)
                &.{}
            else
                try self.lineHints(a, line);
            var hint_i: usize = 0;
            // scope membership for this line: focused windows use the
            // animation spread range, others the full scope
            const in_scope = if (is_focused)
                has_scope and line >= anim_from and line <= anim_to
            else
                has_scope and line >= scope_start_line and line <= scope_end_line;

            // ---- indent guides (nvim snacks.indent) ----
            // The line's leading whitespace renders as one "│" (U+2502) per
            // 4-column indent level (tab_width). Guides outside the cursor's
            // scope block are dim gray (snacks links SnacksIndent to NonText);
            // inside the scope they take the rainbow indent[level % 8] ramp
            // (snacks' SnacksIndent1..8) — with the outwards spread animation
            // filling the scope from the cursor line. The scope's FIRST line
            // (its declaration/opening line) gets an underline in the text
            // (snacks.indent.scope underline). A "│" occupies exactly one
            // cell, so the region keeps the expanded width of the whitespace
            // it replaces (tab = tab_width cells) — byte columns, cursor
            // placement, selection bounds and every existing row/column
            // assertion stay unchanged. Empty lines and indent < 4 columns
            // ("不足 4 列的部分") draw nothing (the spaces still render).
            var indent_end: u32 = 0;
            while (indent_end < n and (text[indent_end] == ' ' or text[indent_end] == '\t')) indent_end += 1;
            // expanded column count of the indent region (space = 1 col,
            // tab = tab_width cols) — also needed by the blank-line
            // continuation below, so computed here for both paths
            var indent_cols: u32 = 0;
            var ib: u32 = 0;
            while (ib < indent_end) : (ib += 1) indent_cols += if (text[ib] == '\t') tab_width else 1;
            if (indent_end > 0) {
                const indent_levels: u32 = indent_cols / tab_width;
                // hints anchored at/inside the indent region render before it
                // (normally none: hints annotate tokens, which start past the
                // indent) — keeps the hint-before-text ordering of the main loop
                while (hint_i < line_hints.len and line_hints[hint_i].character <= indent_end) {
                    const hint = line_hints[hint_i];
                    if (hint.label.len > 0) {
                        try segs.append(a, .{
                            .text = hint.label,
                            .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                        });
                    }
                    hint_i += 1;
                }
                var gcol: u32 = 0; // expanded column of the current indent cell
                ib = 0;
                while (ib < indent_end) : (ib += 1) {
                    const cell_w: u32 = if (text[ib] == '\t') tab_width else 1;
                    var j: u32 = 0;
                    while (j < cell_w) : (j += 1) {
                        const level: u32 = gcol / tab_width;
                        const is_guide = gcol % tab_width == 0 and gcol < indent_levels * tab_width;
                        var gstyle: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
                        if (is_cur_line) gstyle.bg = .{ .rgb = self.theme.bg_curline };
                        if (ib >= sel_s and ib < sel_e) gstyle.bg = .{ .rgb = self.theme.bg_sel };
                        if (is_guide) {
                            // Only the scope's OWN guide column (its starting
                            // line's indent, snacks: `i > indent` rows) is
                            // highlighted; every other level's guides stay dim
                            // gray — entering a nested scope must NOT keep the
                            // outer scopes' lines lit.
                            const is_scope_guide = in_scope and
                                gcol == scope_indent_col and
                                indent_cols > scope_indent_col;
                            gstyle.fg = .{ .rgb = if (is_scope_guide) self.theme.indent[level % 8] else self.theme.fg_dim };
                            try segs.append(a, .{ .text = "│", .style = gstyle });
                        } else {
                            try segs.append(a, .{ .text = " ", .style = gstyle });
                        }
                        gcol += 1;
                    }
                }
            }
            // Blank / whitespace-only lines: the indent guides continue
            // through them (snacks.indent draws blank rows too), so the
            // guides never break across empty lines. The gray levels
            // come from the nearest non-blank line (above, else below);
            // inside the cursor's scope the scope's own guide column is
            // highlighted (rainbow). NOTE: only ACTUALLY blank lines
            // reach this — a content line at column 0 (fn header,
            // closing brace) has indent_end == 0 but indent_end != n, so
            // the scope's vertical never extends onto those rows.
            if (indent_end == n) {
                var ctx_levels: u32 = 0;
                {
                    var ctx: i64 = @as(i64, @intCast(line)) - 1;
                    var dir: i64 = -1;
                    var scanned: usize = 0;
                    const lc: i64 = @as(i64, @intCast(line_count));
                    while (scanned < 500) : (scanned += 1) {
                        if (ctx < 0) {
                            if (dir == -1) {
                                ctx = @as(i64, @intCast(line)) + 1;
                                dir = 1;
                                continue;
                            }
                            break;
                        }
                        if (ctx >= lc) break;
                        const cl: u32 = @intCast(ctx);
                        if (!self.isBlankLine(buf, cl)) {
                            ctx_levels = self.lineIndentLevels(buf, cl);
                            break;
                        }
                        ctx += dir;
                    }
                }
                const start_col: u32 = indent_cols;
                const ctx_cols: u32 = @min(ctx_levels * tab_width, rect.width -| gutter);
                // the scope's highlighted guide column (only when it lies
                // past the line's own indent — deeper whitespace-only
                // lines already got it from the loop above); sentinel
                // rect.width when absent / off-screen
                const scope_col: u32 = if (in_scope and scope_indent_col >= indent_cols and
                    scope_indent_col < rect.width -| gutter)
                    scope_indent_col
                else
                    rect.width;
                const end_col: u32 = @max(ctx_cols, if (scope_col < rect.width) scope_col + 1 else ctx_cols);
                if (end_col > start_col) {
                    const n_cells = end_col - start_col;
                    const row_buf = try a.alloc(u8, n_cells);
                    @memset(row_buf, ' ');
                    var gc: u32 = start_col;
                    while (gc < end_col) : (gc += 1) {
                        // guide cells use a 1-byte marker; the real glyph
                        // is the 3-byte "│", emitted per cell below
                        if (gc % tab_width == 0 and gc != scope_col) row_buf[gc - start_col] = 0x01;
                    }
                    const gstyle: vaxis.Style = .{
                        .bg = .{ .rgb = if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                        .fg = .{ .rgb = self.theme.fg_dim },
                    };
                    // emit runs, converting markers to "│", splitting
                    // around the scope cell so it gets its own color
                    const off = if (scope_col >= start_col and scope_col < end_col) scope_col - start_col else n_cells;
                    var run_start: usize = 0;
                    var k: usize = 0;
                    while (k < n_cells) : (k += 1) {
                        if (k == off) {
                            if (k > run_start) try segs.append(a, .{ .text = row_buf[run_start..k], .style = gstyle });
                            const level: u32 = scope_col / tab_width;
                            try segs.append(a, .{ .text = "│", .style = .{
                                .bg = gstyle.bg,
                                .fg = .{ .rgb = self.theme.indent[level % 8] },
                            } });
                            run_start = k + 1;
                        } else if (row_buf[k] == 0x01) {
                            if (k > run_start) try segs.append(a, .{ .text = row_buf[run_start..k], .style = gstyle });
                            try segs.append(a, .{ .text = "│", .style = gstyle });
                            run_start = k + 1;
                        }
                    }
                    if (run_start < n_cells) try segs.append(a, .{ .text = row_buf[run_start..], .style = gstyle });
                }
            }
            var col: u32 = indent_end; // text starts after the indent region
            while (col < n) {
                // emit any hint whose insertion column is at/just passed col
                // (before the next text segment, so it reads token+hint)
                while (hint_i < line_hints.len and line_hints[hint_i].character <= col) {
                    const hint = line_hints[hint_i];
                    if (hint.label.len > 0) {
                        try segs.append(a, .{
                            .text = hint.label,
                            .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                        });
                    }
                    hint_i += 1;
                }
                while (span_i < merged.len and merged[span_i].end <= line_start + col) span_i += 1;
                var next: u32 = n;
                var fg: ?vaxis.Style = null;
                if (span_i < merged.len) {
                    const sp = merged[span_i];
                    if (sp.start < line_start + n and sp.end > line_start + col) {
                        fg = syntaxStyle(sp.style, self.theme);
                        const sp_start: u32 = if (sp.start > line_start) sp.start - line_start else 0;
                        const sp_end: u32 = if (sp.end < line_start + n) sp.end - line_start else n;
                        next = if (sp_start > col) sp_start else sp_end;
                    }
                }
                if (sel_s > col and sel_s < next) next = sel_s;
                if (sel_e > col and sel_e < next) next = sel_e;
                // stop the text segment at the next hint's insertion column so
                // the hint is spliced between tokens (hints sorted ascending)
                if (hint_i < line_hints.len) {
                    const hc = line_hints[hint_i].character;
                    if (hc > col and hc < next) next = hc;
                }
                const in_sel = col >= sel_s and col < sel_e;
                var style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg } };
                if (is_cur_line) style.bg = .{ .rgb = self.theme.bg_curline };
                if (in_sel) style.bg = .{ .rgb = self.theme.bg_sel };
                // syntaxStyle returns a full vaxis.Style (e.g. Boolean is
                // bold) — merge the whole thing, not just the fg
                if (fg) |f| {
                    style.fg = f.fg;
                    style.bold = f.bold;
                    style.italic = f.italic;
                }
                // snacks.indent.scope underline: the scope's FIRST line (its
                // declaration/opening line) is underlined from the text start
                // to end of line, once the animation spread has covered it
                // (snacks draws it when scope.from == from), in the scope's
                // own guide color. The e2e grid parses SGR colors only, so
                // this is cosmetic, never asserted.
                if (is_focused and in_scope and line == scope_start_line and anim_from <= scope_start_line) {
                    style.ul = .{ .rgb = self.theme.indent[(scope_indent_col / tab_width) % 8] };
                    style.ul_style = .single;
                }
                const seg_text = text[col..next];
                if (std.mem.indexOfScalar(u8, seg_text, '\t') != null) {
                    // Expand tabs to `tab_width` spaces so they render (vaxis
                    // skips 0-width chars) and their drawn width matches
                    // lineCellCol/textWidth — otherwise the cursor column and
                    // the visible line disagree on tab-containing files.
                    var expanded = std.ArrayList(u8).empty;
                    for (seg_text) |b| {
                        if (b == '\t') {
                            var k: u32 = 0;
                            while (k < tab_width) : (k += 1) try expanded.append(a, ' ');
                        } else {
                            try expanded.append(a, b);
                        }
                    }
                    try segs.append(a, .{ .text = expanded.items, .style = style });
                } else {
                    try segs.append(a, .{ .text = seg_text, .style = style });
                }
                col = next;
            }
            // trailing hints past the visible text (still inside the line)
            while (hint_i < line_hints.len) {
                const hint = line_hints[hint_i];
                if (hint.label.len > 0) {
                    try segs.append(a, .{
                        .text = hint.label,
                        .style = .{ .dim = true, .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg } },
                    });
                }
                hint_i += 1;
            }

            // closed fold header: snacks-style dim "… N lines" marker after
            // the line text; the body's rows are skipped by the loop's
            // foldNextLine continuation
            if (foldAt(buf, line)) |f| {
                const marker = try std.fmt.allocPrint(a, " … {d} lines", .{f.hiddenCount()});
                try segs.append(a, .{ .text = marker, .style = .{
                    .dim = true,
                    .fg = .{ .rgb = self.theme.fg_dim },
                    .bg = .{ .rgb = if (is_cur_line) self.theme.bg_curline else self.theme.bg },
                } });
            }

            _ = win.print(segs.items, .{
                .row_offset = @intCast(row),
                .col_offset = @intCast(rect.col),
                .wrap = .none,
            });
            // diagnostic mark: writeCell AFTER the line print so the glyph is
            // not overwritten by the gutter segment
            if (diag_mark.len > 1) { // Nerd Font icon (multi-byte); " " = none
                var mark_style = cursorline_style;
                if (diag_mark_fg) |f| mark_style.fg = f.fg;
                win.writeCell(@intCast(rect.col + gutter - 1), @intCast(row), .{
                    .char = .{ .grapheme = diag_mark, .width = 1 },
                    .style = mark_style,
                });
            } else if (git_mark) |k| {
                // git sign in the same cell (diagnostics win the priority).
                // Glyphs: ▎ for added/modified, ▁/▔ half-blocks for deleted
                // (signify-style markers on the neighbor lines).
                var mark_style = cursorline_style;
                if (git_mark_fg) |f| mark_style.fg = f.fg;
                const glyph: []const u8 = switch (k) {
                    .added, .modified => "\u{258e}", // ▎ left half block
                    .removed_above => "\u{2581}", // ▁ lower eighth block
                    .removed_below => "\u{2594}", // ▔ upper eighth block
                };
                win.writeCell(@intCast(rect.col + gutter - 1), @intCast(row), .{
                    .char = .{ .grapheme = glyph, .width = 1 },
                    .style = mark_style,
                });
            }
        }
    }

    /// One fenced-code line: the fence markers (```lang / ```) render dim;
    /// the panel stays a solid bg_float block.
    fn hoverFenceSegs(self: *App, a: std.mem.Allocator, line: []const u8, cols: u32) ![]vaxis.Segment {
        var segs = std.ArrayList(vaxis.Segment).empty;
        const style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } };
        const shown = @min(line.len, @as(usize, @intCast(cols)));
        if (shown > 0) try segs.append(a, .{ .text = line[0..shown], .style = style });
        if (shown < cols) {
            const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(shown))));
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = style });
        }
        return segs.items;
    }

    /// One code-block row inside the hover window: token colors from the
    /// block's merged tree-sitter spans (each span clipped to this line,
    /// syntaxStyle fg on bg_float), then padding to `cols` so the panel
    /// stays solid. `line_start`/`line_end` are byte offsets into `block`.
    fn hoverCodeLineSegs(self: *App, a: std.mem.Allocator, block: []const u8, line_start: u32, line_end: u32, spans: []const syntax.Span, cols: u32) ![]vaxis.Segment {
        var segs = std.ArrayList(vaxis.Segment).empty;
        const base: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
        var pos = line_start;
        var si: usize = 0;
        var consumed: usize = 0;
        while (si < spans.len and pos < line_end) {
            const sp = spans[si];
            if (sp.end <= pos) {
                si += 1;
                continue;
            }
            if (sp.start >= line_end) break;
            if (sp.start > pos) {
                const gap = @min(sp.start, line_end) - pos;
                try segs.append(a, .{ .text = block[pos .. pos + gap], .style = base });
                consumed += gap;
                pos = sp.start;
            }
            const s = @max(sp.start, pos);
            const e = @min(sp.end, line_end);
            if (e > s) {
                var st = syntaxStyle(sp.style, self.theme);
                st.bg = .{ .rgb = self.theme.bg_float };
                try segs.append(a, .{ .text = block[s..e], .style = st });
                consumed += e - s;
                pos = e;
            }
            si += 1;
        }
        if (pos < line_end) {
            const tail = block[pos..line_end];
            try segs.append(a, .{ .text = tail, .style = base });
            consumed += line_end - pos;
        }
        if (consumed < cols) {
            const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(consumed))));
            @memset(pad, ' ');
            try segs.append(a, .{ .text = pad, .style = base });
        }
        return segs.items;
    }

    /// Minimal markdown-ish token styling for LSP hover/signature text:
    /// `` `code` `` spans get the string color, `**bold**` bold, `*emphasis*`
    /// dim+italic, `#`-prefixed headings accent+bold, bare http(s) URLs the
    /// function color; everything else stays fg. The row is padded to `cols`
    /// with bg_float so the floating panel remains a solid block (e2e asserts
    /// rowAllBg on hover rows). The text slices reference the caller's owned
    /// hover buffer, and the padding is allocator-owned — both outlive the
    /// render call.
    fn hoverLineSegs(self: *App, a: std.mem.Allocator, line: []const u8, cols: u32) ![]vaxis.Segment {
        var segs = std.ArrayList(vaxis.Segment).empty;
        const base: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
        const shown = @min(line.len, @as(usize, @intCast(cols)));
        // heading line: 1-6 '#' followed by a space
        var heading = false;
        if (shown >= 2 and line[0] == '#') {
            var h: usize = 0;
            while (h < shown and h < 6 and line[h] == '#') h += 1;
            heading = h < shown and line[h] == ' ';
        }
        if (heading) {
            const hstyle: vaxis.Style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
            if (shown > 0) try segs.append(a, .{ .text = line[0..shown], .style = hstyle });
            if (shown < cols) {
                const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(shown))));
                @memset(pad, ' ');
                try segs.append(a, .{ .text = pad, .style = base });
            }
        } else {
            var consumed: usize = 0;
            var i: usize = 0;
            while (i < shown) {
                var style = base;
                var end: usize = shown;
                if (line[i] == '`') {
                    // inline code span: up to the next backtick
                    style = .{ .fg = .{ .rgb = self.theme.string }, .bg = .{ .rgb = self.theme.bg_float } };
                    i += 1;
                    end = if (std.mem.indexOfScalar(u8, line[i..shown], '`')) |ci| i + ci else shown;
                } else if (line[i] == '*' and i + 1 < shown and line[i + 1] == '*') {
                    style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_float }, .bold = true };
                    i += 2;
                    end = if (std.mem.indexOf(u8, line[i..shown], "**")) |ci| i + ci else shown;
                } else if (line[i] == '*') {
                    style = .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float }, .italic = true };
                    i += 1;
                    end = if (std.mem.indexOfScalar(u8, line[i..shown], '*')) |ci| i + ci else shown;
                } else if (shown - i >= 4 and std.mem.eql(u8, line[i .. i + 4], "http")) {
                    // bare URL: to the next whitespace / punctuation
                    var ue = i;
                    while (ue < shown and line[ue] != ' ' and line[ue] != '\t' and
                        line[ue] != ',' and line[ue] != ')' and line[ue] != ']') ue += 1;
                    end = ue;
                    style = .{ .fg = .{ .rgb = self.theme.function }, .bg = .{ .rgb = self.theme.bg_float } };
                }
                if (end <= i) end = shown;
                if (end > i) {
                    try segs.append(a, .{ .text = line[i..end], .style = style });
                    consumed += end - i;
                }
                i = end;
            }
            if (consumed < cols) {
                const pad = try a.alloc(u8, @intCast(cols - @as(u32, @intCast(consumed))));
                @memset(pad, ' ');
                try segs.append(a, .{ .text = pad, .style = base });
            }
        }
        return segs.items;
    }

    fn render(self: *App) !void {
        // vaxis cells reference the text slices passed to print, so all text
        // must stay alive until vx.render(); a per-frame arena handles that.
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const win = self.vx.window();
        win.clear();
        // Editor background: paint the whole screen with the theme's bg so
        // the palette is consistent (like nvim), not terminal-transparent.
        win.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg } } });

        const height: u32 = win.height;
        if (height <= status_row_count) return;
        // Content area rows: below the tab bar, above the status bar.
        const content_rows = height - status_row_count - self.tabBarRows(a);

        // Clamp the focused window's cursor/viewport BEFORE any lineOf /
        // column math below: switching windows or buffers can leave a stale
        // cursor past the end of the current buffer (e.g. both splits show
        // the same buffer and the other window deleted everything), and
        // piece_table.lineOf asserts pos <= len in Debug builds.
        const fw = &self.windows.items[self.current_win];
        if (fw.cursor > self.cur().pt.len()) fw.cursor = self.cur().pt.len();
        if (fw.view_top > self.cur().pt.lineCount() -| 1) fw.view_top = self.cur().pt.lineCount() -| 1;

        const cursor_line = self.cur().pt.lineOf(self.curCursor().*);
        const line_count = self.cur().pt.lineCount();
        // relative-number gutter: computed once per frame, reused by the
        // cursor offset, mc highlight and easymotion labels
        const gutter = self.gutterWidth(line_count);

        // tab bar. Single window: one entry per buffer, current highlighted,
        // + dirty marker — solid blocks separated by a 1-cell base-bg gap.
        // Split windows: each buffer's tab appears EXACTLY ONCE, in the pane
        // that last showed it (last_win) — a buffer displayed in a pane
        // belongs to that pane, a buffer hidden from every pane keeps its
        // tab in the pane it was last in. The pane's OWN buffer carries the
        // active style, so a buffer moving panes (<leader>bh/bl) is visible
        // on the tab bar.
        if (self.windows.items.len <= 1) {
            var tab_i: usize = 0;
            // the tab bar belongs to the BUFFER area: with the file tree
            // open it starts at the content column (right of the sidebar),
            // not glued above the tree at x=0
            var col: u16 = @intCast(self.contentCol());
            while (tab_i < self.buffers.items.len) : (tab_i += 1) {
                const buf = &self.buffers.items[tab_i];
                const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
                const dirty = if (buf.dirty) "\u{25cf}" else " ";
                const label = try std.fmt.allocPrint(a, " {s}{s} ", .{ name, dirty });
                const tab_style: vaxis.Style = if (tab_i == self.current)
                    // bg_status, NOT bg_sel: tests (and the eye) read bg_sel
                    // as an editor selection — the tab bar must not emit it
                    .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true }
                else
                    .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                // file icon in the tab's own semantic color (devicons style);
                // the name keeps the plain tab style
                const icon = icons.forPath(if (buf.path) |p| p else "", false);
                const icon_style: vaxis.Style = .{
                    .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) },
                    .bg = tab_style.bg,
                    .bold = (tab_i == self.current),
                };
                const segs = [_]vaxis.Segment{
                    .{ .text = icon.glyph, .style = icon_style },
                    .{ .text = label, .style = tab_style },
                    .{ .text = " ", .style = .{ .bg = .{ .rgb = self.theme.bg } } },
                };
                _ = win.print(&segs, .{ .row_offset = 0, .col_offset = col, .wrap = .none });
                col +|= @intCast(1 + label.len + 1);
                if (col >= win.width) break;
            }
        } else if (self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), win.width)) |tab_layout| {
            // each buffer's tab appears EXACTLY ONCE, owned by the pane that
            // displays it (the focused pane wins when several panes show the
            // same buffer); a buffer hidden from every pane keeps its tab in
            // the pane that last showed it. Panes whose column spans overlap
            // (horizontal splits) draw on separate tab-bar rows so tabs never
            // overwrite each other; within a row, tabs stream left to right
            // from each pane's column, borrowing space to the right when a
            // pane is too narrow to fit its tabs (labels clip only at the
            // row's right edge). The pane's displayed buffer carries the
            // active style, so <leader>bh/bl visibly moves the tab.
            const leaves = tab_layout.leaves;
            const pane_layer = a.alloc(u32, leaves.len) catch return;
            var order: std.ArrayList(usize) = .empty;
            for (0..leaves.len) |i| order.append(a, i) catch return;
            std.mem.sort(usize, order.items, TabSort{ .leaves = leaves }, TabSort.lt);
            var layer_end: std.ArrayList(u32) = .empty;
            var layers: u32 = 0;
            for (order.items) |oi| {
                const lr = leaves[oi];
                var lli: usize = 0;
                while (lli < layers and layer_end.items[lli] > lr.col) lli += 1;
                if (lli == layers) {
                    layer_end.append(a, lr.col + lr.width) catch return;
                    layers += 1;
                } else {
                    layer_end.items[lli] = lr.col + lr.width;
                }
                pane_layer[oi] = @intCast(lli);
            }
            var lli: u32 = 0;
            while (lli < layers) : (lli += 1) {
                // right edge of the layer's widest span: tabs clip here
                var right: u32 = 0;
                for (order.items) |oi| {
                    if (pane_layer[oi] == lli) right = @max(right, leaves[oi].col + leaves[oi].width);
                }
                var pos: u32 = 0;
                for (order.items) |oi| {
                    if (pane_layer[oi] != lli) continue;
                    const lr = leaves[oi];
                    // start at the pane's own column, or right after the
                    // previous pane's tabs when they overflow this span
                    pos = @max(pos, lr.col);
                    const own = self.windows.items[lr.win].buf;
                    var tab_i: usize = 0;
                    var col = pos;
                    while (tab_i < self.buffers.items.len) : (tab_i += 1) {
                        // owner: the pane showing the buffer (the focused
                        // pane wins when several panes show it); a hidden
                        // buffer keeps the pane that last showed it
                        var owner: usize = self.buffers.items[tab_i].last_win;
                        if (owner >= self.windows.items.len) owner = self.windows.items.len - 1;
                        if (self.windows.items[self.current_win].buf == tab_i) owner = self.current_win;
                        if (owner != lr.win) continue;
                        const buf = &self.buffers.items[tab_i];
                        const name = if (buf.path) |p| std.fs.path.basename(p) else "[No Name]";
                        const dirty = if (buf.dirty) "\u{25cf}" else " ";
                        const label = try std.fmt.allocPrint(a, " {s}{s} ", .{ name, dirty });
                        const active = tab_i == own;
                        const tab_style: vaxis.Style = if (active)
                            .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status }, .bold = true }
                        else
                            .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                        const icon = icons.forPath(if (buf.path) |p| p else "", false);
                        const icon_style: vaxis.Style = .{
                            .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) },
                            .bg = tab_style.bg,
                            .bold = active,
                        };
                        // clip only at the row's right edge: tabs may borrow
                        // space right of their own (too narrow) pane span
                        const fit = cellFitPrefix(win, label, right -| col -| 1);
                        if (fit.cells == 0) break;
                        const segs = [_]vaxis.Segment{
                            .{ .text = icon.glyph, .style = icon_style },
                            .{ .text = fit.slice, .style = tab_style },
                        };
                        _ = win.print(&segs, .{ .row_offset = @intCast(lli), .col_offset = @intCast(col), .wrap = .none });
                        col += @intCast(1 + fit.cells + 1); // icon + label + gap
                        if (col >= right) break;
                    }
                    pos = col;
                }
            }
        } else |_| {}

        // dashboard (no file open): title + recent files + hints
        if (self.isDashboard()) {
            const title_seg = [_]vaxis.Segment{.{
                .text = " oz  ",
                .style = .{ .fg = .{ .rgb = self.theme.accent }, .bold = true },
            }};
            _ = win.print(&title_seg, .{ .row_offset = @intCast(self.contentTop(a) + 2), .col_offset = 2, .wrap = .none });
            // key-hint line, segmented so the bindings get token colors while
            // the prose stays faint (the text content is unchanged, so e2e
            // `contains` assertions on the line still hold)
            const hint_segs = [_]vaxis.Segment{
                .{ .text = " 终端文本编辑器  —  ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
                .{ .text = "j/k", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
                .{ .text = " 选择 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
                .{ .text = "Enter", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
                .{ .text = " 打开 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
                .{ .text = "<leader>", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
                .{ .text = "sf", .style = .{ .fg = .{ .rgb = self.theme.keyword } } },
                .{ .text = " 找文件 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
                .{ .text = ":e", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
                .{ .text = " 打开 · ", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
                .{ .text = ":q", .style = .{ .fg = .{ .rgb = self.theme.accent } } },
                .{ .text = " 退出", .style = .{ .fg = .{ .rgb = self.theme.fg_faint } } },
            };
            _ = win.print(&hint_segs, .{ .row_offset = @intCast(self.contentTop(a) + 3), .col_offset = 2, .wrap = .none });
            var ri: usize = 0;
            while (ri < @min(self.recent_files.items.len, 8)) : (ri += 1) {
                const fname = self.recent_files.items[ri];
                const row: u32 = 5 + @as(u32, @intCast(ri));
                const sel = (ri == self.recent_sel);
                const bg: vaxis.Color = if (sel) .{ .rgb = self.theme.bg_sel } else .default;
                const fg: vaxis.Color = if (sel) .default else .{ .rgb = self.theme.function };
                const icon = icons.forPath(fname, false);
                const segs = [_]vaxis.Segment{
                    .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = bg } },
                    .{ .text = " ", .style = .{ .bg = bg } },
                    .{ .text = fname, .style = .{ .fg = fg, .bg = bg } },
                };
                _ = win.print(&segs, .{ .row_offset = @intCast(self.contentTop(a) + row), .col_offset = 2, .wrap = .none });
            }
            self.vx.screen.cursor = .{
                .row = @intCast(self.contentTop(a) + 5 + @as(u32, @intCast(@min(self.recent_sel, 7)))),
                .col = 2,
            };
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // split windows: every leaf gets a rectangle and renders its buffer;
        // the focused window carries syntax highlighting and the selection
        const layout = try self.layoutWindows(a, self.contentTop(a), content_rows, self.contentCol(), win.width);
        const leaves = layout.leaves;
        var cur_rect: LeafRect = .{ .win = self.current_win, .row = 0, .col = 0, .height = 0, .width = 0 };
        var li: usize = 0;
        while (li < leaves.len) : (li += 1) {
            const lr = leaves[li];
            if (lr.win == self.current_win) cur_rect = lr;
            try self.renderWindowLines(a, lr, lr.win == self.current_win);
        }

        // window separators (vim statusline semantics): one "─" row per
        // horizontal split, one "│" column per vertical split, drawn OVER the
        // buffers so the panes read as distinct windows without changing the
        // layout math. The separator adjacent to the focused window (the
        // split path from the root to the current leaf) is bright; the rest
        // are dim. The bg is the editor background so the line fully hides
        // whatever buffer text it covers — no ghosting from the window below.
        for (layout.seps) |sep| {
            const sep_style: vaxis.Style = .{
                .fg = .{ .rgb = if (sep.active) self.theme.win_sep_active else self.theme.win_sep },
                .bg = .{ .rgb = self.theme.bg },
            };
            if (sep.horizontal) {
                var xs: u32 = 0;
                while (xs < sep.len) : (xs += 1) {
                    win.writeCell(@intCast(sep.col + xs), @intCast(sep.row), .{
                        .char = .{ .grapheme = "─", .width = 1 },
                        .style = sep_style,
                    });
                }
            } else {
                var ys: u32 = 0;
                while (ys < sep.len) : (ys += 1) {
                    win.writeCell(@intCast(sep.col), @intCast(sep.row + ys), .{
                        .char = .{ .grapheme = "│", .width = 1 },
                        .style = sep_style,
                    });
                }
            }
        }

        // file tree sidebar (nvim neo-tree style: the panel shares the
        // EDITOR background — Normal bg, not a float — so sidebar and text
        // area read as one surface; only the fg_faint border separates them)
        if (self.filetree_active) {
            const ft_col: u32 = 0;
            const ft_width = filetree_width;
            const ft_top = self.contentTop(a);
            const ft_bottom = height - status_row_count; // above the status bar
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg } };
            // Paint the whole panel with the editor background first — without
            // this only the border columns and the text-width of each item
            // got the bg, leaving the interior terminal-default (patchy).
            const panel = win.child(.{
                .x_off = @intCast(ft_col),
                .y_off = @intCast(ft_top),
                .width = @intCast(ft_width),
                .height = @intCast(ft_bottom - ft_top),
            });
            panel.fill(.{ .style = .{ .bg = .{ .rgb = self.theme.bg } } });
            // left border column and panel background
            const left_col = ft_col;
            const inner_left = ft_col + 1;
            const inner_w = ft_width -| 1;
            var brow: u32 = ft_top;
            while (brow < ft_bottom) : (brow += 1) {
                const border_seg = [_]vaxis.Segment{.{
                    .text = "│",
                    .style = border_style,
                }};
                _ = win.print(&border_seg, .{ .row_offset = @intCast(brow), .col_offset = @intCast(left_col), .wrap = .none });
            }
            // title row: " files " with a top border (╭─ files ────╮)
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭─ files ", .style = border_style });
                // inner_w cells between the borders; "╭─ files " is 9 cells
                var cx: u32 = 9;
                while (cx < inner_w) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(ft_top), .col_offset = @intCast(left_col), .wrap = .none });
            }
            // vim-style scroll window (same semantics as the picker)
            const ft_len = self.filetree_rows.items.len;
            // clamp the selection when the tree shrank (collapse) BEFORE the
            // scroll math, or a stale sel >= len would drive ft_top past the
            // end of the visible list (out of bounds on the row loop below)
            if (ft_len == 0) {
                self.filetree_sel = 0;
            } else if (self.filetree_sel >= ft_len) {
                self.filetree_sel = ft_len - 1;
            }
            const ft_vis = @min(ft_len, @as(usize, ft_bottom - ft_top - 2));
            if (ft_len > ft_vis) {
                if (self.filetree_top + ft_vis > ft_len) self.filetree_top = ft_len - ft_vis;
                if (self.filetree_sel < self.filetree_top) self.filetree_top = self.filetree_sel;
                if (self.filetree_sel >= self.filetree_top + ft_vis) self.filetree_top = self.filetree_sel - ft_vis + 1;
            } else self.filetree_top = 0;
            const ft_top_i = self.filetree_top;
            var k: usize = 0;
            while (k < ft_vis) : (k += 1) {
                const ri = ft_top_i + k;
                const frow = self.filetree_rows.items[ri];
                const node = frow.node;
                const indent = frow.depth * 2;
                // content = indent + icon (1 cell) + space + name; a
                // too-wide name is truncated from the RIGHT with "…" (never
                // head-truncated). The name budget excludes the right-border
                // column (the last inner cell), which the border draws over
                // afterwards, and the gap cell between icon and name — the
                // gap keeps the glyph from crowding the text (a Nerd Font
                // icon right against a name reads as a tiny broken glyph).
                const icon = if (node.is_dir) icons.folder(node.expanded) else icons.forPath(node.path, false);
                const avail = (inner_w -| 1) -| @as(usize, indent) -| 1 -| 1;
                var name = node.name;
                var ellipsized = false;
                if (name.len > avail) {
                    name = name[0..avail -| 1];
                    ellipsized = true;
                }
                const style: vaxis.Style = if (ri == self.filetree_sel)
                    .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } }
                else
                    .{ .bg = .{ .rgb = self.theme.bg }, .fg = .{ .rgb = self.theme.fg } };
                // Pad to the full inner width: the row background (plain and
                // selected alike) must span the panel edge to edge. NOTE:
                // vaxis cells REFERENCE the segment text — it must outlive
                // vx.render() — so the padding is arena-allocated, never a
                // stack buffer (a stack row_buf made every row render the
                // LAST file's name).
                var segs = std.ArrayList(vaxis.Segment).empty;
                if (indent > 0) {
                    const pad = try a.alloc(u8, indent);
                    @memset(pad, ' ');
                    try segs.append(a, .{ .text = pad, .style = style });
                }
                try segs.append(a, .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = style.bg } });
                if (name.len > 0) {
                    try segs.append(a, .{ .text = " ", .style = style });
                    try segs.append(a, .{ .text = name, .style = style });
                }
                if (ellipsized) try segs.append(a, .{ .text = "…", .style = style });
                // count cells: indent spaces + icon (1) + gap (1) + name + "…"
                const content_len = indent + 2 + name.len + @as(usize, if (ellipsized) 1 else 0);
                const pads = try a.alloc(u8, inner_w -| @min(content_len, inner_w));
                @memset(pads, ' ');
                if (pads.len > 0) try segs.append(a, .{ .text = pads, .style = style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(ft_top + 1 + k), .col_offset = @intCast(inner_left), .wrap = .none });
            }
            // right border column — mirrors the left one so the panel is a
            // closed box. The title row's "╮" and the bottom row's "╯"
            // already cap the two corners, so only the interior rows need the
            // "│" (the item rows' trailing padding is what it covers).
            {
                const right_col = ft_col + ft_width - 1;
                var rrow: u32 = ft_top + 1;
                const rlast = ft_bottom - 1; // bottom border row
                while (rrow < rlast) : (rrow += 1) {
                    const border_seg = [_]vaxis.Segment{.{
                        .text = "│",
                        .style = border_style,
                    }};
                    _ = win.print(&border_seg, .{ .row_offset = @intCast(rrow), .col_offset = @intCast(right_col), .wrap = .none });
                }
            }
            // bottom border
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                // inner_w - 1 dashes: "╰" takes the left border column and
                // "╯" must land ON the right border column (ft_width-1) —
                // inner_w dashes would push it one cell past the edge
                var cx: u32 = 0;
                while (cx < inner_w -| 1) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(ft_bottom - 1), .col_offset = @intCast(left_col), .wrap = .none });
            }
        }

        // multi-cursor word highlights (overlay)
        if (self.mc_active) {
            for (self.mc.cursors.items) |cpos| {
                const w = self.mc.wordRange(&self.cur().pt, cpos);
                if (w.end <= w.start) continue;
                const wline = self.cur().pt.lineOf(w.start);
                if (wline < self.curViewTop().* or wline >= self.curViewTop().* + content_rows) continue;
                var p = w.start;
                while (p < w.end) {
                    // byte offset -> cell column (CJK word = 3 bytes/2 cells)
                    const col = self.lineCellCol(win, wline, p);
                    if (col >= @as(u32, win.width) - gutter) break;
                    var clen: u32 = 1;
                    while (p + clen < w.end and (self.cur().pt.byteAt(p + clen) & 0xC0) == 0x80) : (clen += 1) {}
                    var char_buf: [4]u8 = undefined;
                    self.cur().pt.copyRange(p, char_buf[0..clen]);
                    const g = try a.dupe(u8, char_buf[0..clen]);
                    win.writeCell(@intCast(cur_rect.col + gutter + col), @intCast(cur_rect.row + wline - self.curViewTop().*), .{
                        .char = .{ .grapheme = g, .width = 1 },
                        .style = .{ .bg = .{ .rgb = self.theme.bg_sel } },
                    });
                    p += clen;
                }
            }
        }

        // easymotion labels: overwrite the matched cells with jump labels
        if (self.em_labels) {
            for (self.em_matches) |m| {
                const mline = self.cur().pt.lineOf(m.pos);
                if (mline < self.curViewTop().* or mline >= self.curViewTop().* + content_rows) continue;
                // byte offset -> cell column: a CJK char before the match is
                // 3 bytes but 2 cells, so a raw byte column would paint the
                // label on the wrong cell
                const col_in_line = self.lineCellCol(win, mline, m.pos);
                const label = try a.dupe(u8, &[_]u8{m.label});
                win.writeCell(@intCast(cur_rect.col + gutter + col_in_line), @intCast(cur_rect.row + mline - self.curViewTop().*), .{
                    .char = .{ .grapheme = label, .width = 1 },
                    .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_sel } },
                });
            }
        }

        // fuzzy picker overlay (telescope/snacks style: a solid bg_float
        // floating window with a border, a title and an in-panel input row,
        // centered on the screen instead of pinned to the bottom-left corner)
        if (self.picker_active) {
            const total = if (self.picker_mode == .grep) self.grep_results.items.len else self.picker_matches.items.len;
            // grep keeps at least one row ("no matches" hint) so the
            // fixed-size panel never collapses to a sliver while the query
            // has no hits yet
            var list_rows = @min(@as(usize, 10), total);
            if (self.picker_mode == .grep) list_rows = @max(list_rows, 1);
            // vim-style scroll window: the selection moves freely inside the
            // window; the window scrolls only when the selection crosses an
            // edge (persisted in picker_top so it doesn't jump around).
            if (total > list_rows) {
                if (self.picker_top + list_rows > total) self.picker_top = total - list_rows;
                if (self.picker_sel < self.picker_top) self.picker_top = self.picker_sel;
                if (self.picker_sel >= self.picker_top + list_rows) self.picker_top = self.picker_sel - list_rows + 1;
            } else self.picker_top = 0;
            const top = self.picker_top;
            // measure the widest label for the box width (capped); file /
            // recent / buffer rows carry a leading icon + space, keymap rows
            // are "keys + 2 + desc". Skipped for grep: its panel is a fixed
            // size, independent of the result set.
            var max_w: usize = 0;
            if (self.picker_mode != .grep) {
                var mk: usize = 0;
                while (mk < list_rows) : (mk += 1) {
                    const ri = top + mk;
                    const label: []const u8 = if (self.picker_mode == .grep) blk: {
                        const r = self.grep_results.items[ri];
                        break :blk std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ r.path, r.line, r.text }) catch "…";
                    } else if (self.picker_mode == .buffers) blk: {
                        const bi = self.picker_matches.items[ri];
                        break :blk std.fmt.allocPrint(a, "{d} {s}", .{ bi + 1, self.bufferName(bi) }) catch "…";
                    } else if (self.picker_mode == .recent) blk: {
                        const ri2 = self.picker_matches.items[ri];
                        break :blk self.recent_files.items[ri2];
                    } else if (self.picker_mode == .keymaps) blk: {
                        const ei = self.picker_matches.items[ri];
                        const e = keymap_list.entries[ei];
                        break :blk std.fmt.allocPrint(a, "{s}  {s}", .{ e.keys, e.desc }) catch "…";
                    } else if (self.picker_mode == .themes) blk: {
                        const ti = self.picker_matches.items[ri];
                        break :blk theme.themes[ti].name;
                    } else self.picker_files.items[self.picker_matches.items[ri]];
                    const icon_len: usize = switch (self.picker_mode) {
                        .files, .recent, .buffers => 2,
                        // themes rows lead with a 3-cell color swatch + space
                        .themes => 4,
                        else => 0,
                    };
                    max_w = @max(max_w, label.len + icon_len);
                }
                max_w = @min(max_w, 60);
            }
            var inner_w: u32 = @intCast(@max(max_w, 12));
            var box_w: u32 = undefined;
            if (self.picker_mode == .grep) {
                // fixed-size panel: width is independent of the result count
                // (no small→big pop when results arrive); 70% of the screen,
                // min 44 inner columns (≈54 on an 80-col pty)
                inner_w = @max(win.width * 7 / 10 -| 2, 44);
                box_w = @min(inner_w + 2, win.width * 7 / 10);
            } else {
                // box width capped at 60% of the screen so a very wide label
                // never spans the whole terminal (telescope/snacks feel)
                box_w = @min(inner_w + 2, win.width * 3 / 5);
            }
            inner_w = box_w - 2;
            const title = switch (self.picker_mode) {
                .grep => " Grep ",
                .buffers => " Buffers ",
                .recent => " Recent ",
                .keymaps => " Keymaps ",
                .themes => " Themes ",
                else => " Files ",
            };
            // centered floating window: title + input row + list + bottom
            // border; start_row biased slightly upward (1/3 down the screen)
            // so the list reads closer to eye level, clamped against tiny
            // terminals like the completion menu's overflow guard
            const box_h: u32 = @as(u32, @intCast(list_rows)) + 3;
            var start_row = (height -| box_h) / 3;
            if (start_row < 1) start_row = 1;
            if (start_row + box_h >= height) start_row = height -| box_h;
            const start_col = (win.width -| box_w) / 2;
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
            const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
            // grep split: left = result list, then a " │ " separator (1 cell
            // plus a bg_float space each side so text never touches the
            // line), right = preview (inner*2/5 ≈ 21 cols on an 80-col pty,
            // left ≈ 30)
            const preview_w: u32 = if (self.picker_mode == .grep) inner_w * 2 / 5 else 0;
            const left_w: u32 = inner_w -| 3 -| preview_w;
            const sep_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.win_sep }, .bg = .{ .rgb = self.theme.bg_float } };
            const sep_pad_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float } };
            // top border + title
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭", .style = border_style });
                try segs.append(a, .{ .text = title, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
                var cx: u32 = 1 + @as(u32, @intCast(title.len));
                while (cx < inner_w + 1) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // input row: "❯ " prompt (accent) + the query, on the panel's
            // own bg_float (telescope/snacks style — no status-bar row at
            // the bottom of the screen). The whole interior row is bg_float
            // so the panel stays a solid block.
            var input_cells: usize = 0; // cells of the shown query (cursor col)
            {
                const input_cap: usize = @intCast(inner_w -| 2);
                // cell-truncate (grapheme-aligned): a byte count can split a
                // UTF-8 sequence or overflow the row on CJK input
                const input_fit = cellFitPrefix(win, self.picker_input.items, input_cap);
                input_cells = input_fit.cells;
                // buffer size = text bytes + remaining pad CELLS (the text's
                // byte length can exceed its cell count on CJK input)
                const input_row = try a.alloc(u8, input_fit.slice.len + (input_cap - input_fit.cells));
                @memset(input_row, ' ');
                @memcpy(input_row[0..input_fit.slice.len], input_fit.slice);
                const seg = [_]vaxis.Segment{
                    .{ .text = "│", .style = border_style },
                    .{ .text = "❯ ", .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } },
                    .{ .text = input_row, .style = row_style },
                    .{ .text = "│", .style = border_style },
                };
                _ = win.print(&seg, .{ .row_offset = @intCast(start_row + 1), .col_offset = @intCast(start_col), .wrap = .none });
            }
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const ri = top + k;
                const selected = (ri == self.picker_sel);
                const rs: vaxis.Style = if (selected) sel_style else row_style;
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "│", .style = border_style });
                if (self.picker_mode == .keymaps) {
                    // segmented keymap row: keys tokens split on spaces —
                    // "space" / "ctrl-*" / ":*" prefixes render accent, the
                    // rest keyword; then "  " + desc in fg. The selected row
                    // keeps the token colors and only swaps the bg.
                    const ei = self.picker_matches.items[ri];
                    const entry = keymap_list.entries[ei];
                    var it = std.mem.splitScalar(u8, entry.keys, ' ');
                    var first = true;
                    while (it.next()) |tok| {
                        if (tok.len == 0) continue;
                        if (!first) try segs.append(a, .{ .text = " ", .style = rs });
                        const is_prefix = first and (std.mem.eql(u8, tok, "space") or std.mem.startsWith(u8, tok, "ctrl-") or tok[0] == ':');
                        const tok_style: vaxis.Style = if (is_prefix)
                            .{ .fg = .{ .rgb = self.theme.accent }, .bg = rs.bg }
                        else
                            .{ .fg = .{ .rgb = self.theme.keyword }, .bg = rs.bg };
                        try segs.append(a, .{ .text = tok, .style = tok_style });
                        first = false;
                    }
                    try segs.append(a, .{ .text = "  ", .style = rs });
                    try segs.append(a, .{ .text = entry.desc, .style = rs });
                    // truncate the desc (the last segment) when the row
                    // overflows the interior width. Widths are CELLS (a CJK
                    // desc is 2 cells/char), and segs[0] is the border — the
                    // interior starts at index 1.
                    var content_cells: usize = 0;
                    for (segs.items[1..]) |s| content_cells += cellWidth(win, s.text);
                    if (content_cells > inner_w) {
                        const over = content_cells - inner_w;
                        const last = &segs.items[segs.items.len - 1];
                        const last_cells = cellWidth(win, last.text);
                        if (last_cells > over) {
                            last.text = cellFitPrefix(win, last.text, last_cells - over).slice;
                            content_cells = inner_w;
                        }
                    }
                    const pad = try a.alloc(u8, inner_w -| content_cells);
                    @memset(pad, ' ');
                    if (pad.len > 0) try segs.append(a, .{ .text = pad, .style = rs });
                } else if (self.picker_mode == .grep) {
                    // grep split panel: left column = the result row, then
                    // the " │ " separator, then the highlighted preview column
                    if (self.grep_results.items.len == 0) {
                        // "no matches" hint (dim); the preview column stays a
                        // blank bg_float block so the panel is continuous
                        const hint = "no matches";
                        const ids = [_]u8{0} ** 64;
                        try appendRowSegs(&segs, a, win, hint, &ids, &[_]vaxis.Style{.{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } }}, left_w, .{ .bg = .{ .rgb = self.theme.bg_float } });
                        try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                        try segs.append(a, .{ .text = "│", .style = sep_style });
                        try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                        try appendRowSegs(&segs, a, win, "", &.{}, &[_]vaxis.Style{}, preview_w, .{ .bg = .{ .rgb = self.theme.bg_float } });
                    } else {
                        const r = self.grep_results.items[ri];
                        // "path:line:" prefix (dim) + " text" (fg); fzy match
                        // chars render keyword. The selected row keeps these
                        // colors and only swaps the bg to bg_sel. Truncation
                        // eats the match text's tail first (suffixed "…"),
                        // then the path's head ("…tail" keeps the meaningful
                        // end): path:line and the start of the match always
                        // stay visible. Tabs in the match text expand to
                        // spaces (tab_width, same as the renderer) so the
                        // cell math holds.
                        const lw: usize = @intCast(left_w);
                        const text_exp = try std.mem.replaceOwned(u8, a, r.text, "\t", "    ");
                        const line_tag = try std.fmt.allocPrint(a, ":{d}:", .{r.line});
                        // the path gets what ":line:" + the separator space +
                        // ≥1 text cell leave; overflow keeps the tail
                        const path_cap = lw -| cellWidth(win, line_tag) -| 2;
                        const path_disp: []const u8 = if (cellWidth(win, r.path) > path_cap)
                            try std.fmt.allocPrint(a, "…{s}", .{cellFitSuffix(win, r.path, path_cap -| 1).slice})
                        else
                            r.path;
                        const prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ path_disp, line_tag });
                        const text_cap = lw -| cellWidth(win, prefix) -| 1;
                        const text_disp: []const u8 = if (cellWidth(win, text_exp) > text_cap)
                            try std.fmt.allocPrint(a, "{s}…", .{cellFitPrefix(win, text_exp, text_cap -| 1).slice})
                        else
                            text_exp;
                        const label = try std.fmt.allocPrint(a, "{s} {s}", .{ prefix, text_disp });
                        const ids = try a.alloc(u8, label.len);
                        for (0..label.len) |i| ids[i] = if (i < prefix.len) 1 else 0;
                        if (self.picker_input.items.len > 0) {
                            if (try util.fzy.match(self.alloc, label, self.picker_input.items)) |m| {
                                defer self.alloc.free(m.positions);
                                for (m.positions) |p| {
                                    if (p >= label.len) continue;
                                    const cs = utf8CharStart(label, p);
                                    if (cs >= label.len) continue;
                                    const ce = @min(cs + utf8CharLenAt(label, cs), label.len);
                                    for (cs..ce) |j| ids[j] = 2;
                                }
                            }
                        }
                        const styles = [_]vaxis.Style{
                            .{ .fg = .{ .rgb = self.theme.fg }, .bg = rs.bg },
                            .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = rs.bg },
                            .{ .fg = .{ .rgb = self.theme.keyword }, .bg = rs.bg },
                        };
                        try appendRowSegs(&segs, a, win, label, ids, &styles, left_w, .{ .bg = rs.bg });
                        try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                        try segs.append(a, .{ .text = "│", .style = sep_style });
                        try segs.append(a, .{ .text = " ", .style = sep_pad_style });
                        try self.renderGrepPreviewRow(&segs, a, win, k, list_rows, preview_w);
                    }
                } else if (self.picker_mode == .themes) {
                    // color-swatch row: 3 cells painted with the theme's OWN
                    // bg / fg / accent — a preview of what the theme looks
                    // like — then a space + the theme name. The swatch cells
                    // keep the theme's own colors even on the selected row
                    // (bg_sel must NOT cover them: the swatch IS the preview);
                    // the name + trailing padding take the normal row style.
                    const ti = self.picker_matches.items[ri];
                    const t = theme.themes[ti];
                    try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.bg } } });
                    try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.fg } } });
                    try segs.append(a, .{ .text = " ", .style = .{ .bg = .{ .rgb = t.accent } } });
                    try segs.append(a, .{ .text = " ", .style = rs });
                    try segs.append(a, .{ .text = t.name, .style = rs });
                    const content_len = 4 + t.name.len;
                    const pad = try a.alloc(u8, inner_w -| @min(content_len, @as(usize, @intCast(inner_w))));
                    @memset(pad, ' ');
                    if (pad.len > 0) try segs.append(a, .{ .text = pad, .style = rs });
                } else {
                    const label: []const u8 = if (self.picker_mode == .buffers) blk: {
                        const bi = self.picker_matches.items[ri];
                        break :blk std.fmt.allocPrint(a, "{d} {s}", .{ bi + 1, self.bufferName(bi) }) catch "…";
                    } else if (self.picker_mode == .recent) blk: {
                        const ri2 = self.picker_matches.items[ri];
                        break :blk self.recent_files.items[ri2];
                    } else self.picker_files.items[self.picker_matches.items[ri]];
                    // file/recent/buffer rows: leading icon + space, then the
                    // label
                    const icon_path: ?[]const u8 = switch (self.picker_mode) {
                        .files => self.picker_files.items[self.picker_matches.items[ri]],
                        .recent => self.recent_files.items[self.picker_matches.items[ri]],
                        .buffers => blk: {
                            const bi = self.picker_matches.items[ri];
                            break :blk if (self.buffers.items[bi].path) |p| p else "";
                        },
                        else => null,
                    };
                    const prefix_len: usize = if (icon_path != null) 2 else 0;
                    // pad the label region to its width so the bg stays
                    // continuous across the row (icon cell + space + label)
                    const content_w = inner_w -| prefix_len;
                    const row = try a.alloc(u8, content_w);
                    @memset(row, ' ');
                    const n = @min(label.len, @as(usize, @intCast(content_w)));
                    @memcpy(row[0..n], label[0..n]);
                    if (icon_path) |p| {
                        const icon = icons.forPath(p, false);
                        try segs.append(a, .{ .text = icon.glyph, .style = .{ .fg = .{ .rgb = icons.rgbOf(self.theme, icon.color) }, .bg = rs.bg } });
                        try segs.append(a, .{ .text = " ", .style = rs });
                    }
                    try segs.append(a, .{ .text = row, .style = rs });
                }
                try segs.append(a, .{ .text = "│", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 2 + k), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // bottom border
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner_w) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 2 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // the block cursor sits in the input row, right after the query:
            // 1 (left border) + 2 ("❯ " prompt) + the query's display cells
            // (input_cells, not the byte length — that lands the cursor
            // mid-row on CJK queries)
            self.vx.screen.cursor = .{
                .row = @intCast(start_row + 1),
                .col = @intCast(start_col + 3 + input_cells),
            };
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // status bar (or command line in command mode)
        if (self.state.mode == .command) {
            const prompt_char: []const u8 = switch (self.cmdline_kind) {
                .ex => ":",
                .search_fwd => "/",
                .search_bwd => "?",
            };
            const prompt = try std.fmt.allocPrint(a, "{s}{s}", .{ prompt_char, self.cmdline.items });
            const cmd_seg = [_]vaxis.Segment{.{
                .text = prompt,
                .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status } },
            }};
            _ = win.print(&cmd_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
            self.vx.screen.cursor = .{
                .row = @intCast(height - 1),
                .col = @intCast(1 + self.cmdline.items.len),
            };
            self.vx.screen.cursor_vis = true;
            self.vx.screen.cursor_shape = .block;
            try self.vx.render(self.tty.writer());
            return;
        }

        // diagnostics list overlay (<leader>sd): bottom list like the picker
        if (self.diag_list_active) {
            const total = self.lsp_diagnostics.items.len;
            const list_rows = @min(@as(usize, 8), total);
            if (total > list_rows) {
                if (self.diag_list_top + list_rows > total) self.diag_list_top = total - list_rows;
                if (self.diag_list_sel < self.diag_list_top) self.diag_list_top = self.diag_list_sel;
                if (self.diag_list_sel >= self.diag_list_top + list_rows) self.diag_list_top = self.diag_list_sel - list_rows + 1;
            } else self.diag_list_top = 0;
            const dtop = self.diag_list_top;
            const start_row = height - 1 - @as(u32, @intCast(list_rows)) - 1;
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const ri = dtop + k;
                const d = self.lsp_diagnostics.items[ri];
                const label = try std.fmt.allocPrint(a, "{d}: {s}", .{ d.range.start.line + 1, d.message });
                const seg = [_]vaxis.Segment{.{
                    .text = label,
                    .style = if (ri == self.diag_list_sel)
                        .{ .bg = .{ .rgb = self.theme.bg_sel } }
                    else
                        .{},
                }};
                _ = win.print(&seg, .{ .row_offset = @intCast(start_row + k), .wrap = .none });
            }
        }

        // LSP navigation location list overlay (gr / gI / <leader>o outline):
        // a floating window in the same visual language as the pickers
        // (solid bg_float panel, fg_faint border, accent title, bg_sel
        // selection, centered on screen) — not a bare bottom list.
        if (self.nav_list_active) {
            const total = self.nav_locations.items.len;
            const list_rows = @min(@as(usize, 10), total);
            if (total > list_rows) {
                if (self.nav_loc_top + list_rows > total) self.nav_loc_top = total - list_rows;
                if (self.nav_list_sel < self.nav_loc_top) self.nav_loc_top = self.nav_list_sel;
                if (self.nav_list_sel >= self.nav_loc_top + list_rows) self.nav_loc_top = self.nav_list_sel - list_rows + 1;
            } else self.nav_loc_top = 0;
            const ntop = self.nav_loc_top;
            // measure the widest label for the box width (capped like the
            // picker; a huge outline name never spans the whole terminal)
            var max_w: usize = 0;
            {
                var mk: usize = 0;
                while (mk < list_rows) : (mk += 1) {
                    const loc = self.nav_locations.items[ntop + mk];
                    const label = if (std.mem.indexOfScalar(u8, loc.uri, 0)) |z|
                        try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, loc.uri[0..z] })
                    else
                        try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, std.fs.path.basename(loc.uri) });
                    max_w = @max(max_w, label.len);
                }
            }
            max_w = @min(max_w, 60);
            const inner_w: u32 = @intCast(@max(max_w, 12));
            const box_w = @min(inner_w + 2, win.width * 3 / 5);
            const inner = box_w - 2;
            // title row + list rows + bottom border (no input row — the list
            // is navigated with j/k, not filtered)
            const box_h: u32 = @as(u32, @intCast(list_rows)) + 2;
            var start_row = (height -| box_h) / 3;
            if (start_row < 1) start_row = 1;
            if (start_row + box_h >= height) start_row = height -| box_h;
            const start_col = (win.width -| box_w) / 2;
            self.nav_float_row = start_row;
            self.nav_float_col = start_col;
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
            const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
            // top border + title
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭", .style = border_style });
                try segs.append(a, .{ .text = self.nav_list_title, .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
                var cx: u32 = 1 + @as(u32, @intCast(self.nav_list_title.len));
                while (cx < inner + 1) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
            }
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                const ri = ntop + k;
                const loc = self.nav_locations.items[ri];
                const label = if (std.mem.indexOfScalar(u8, loc.uri, 0)) |z|
                    try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, loc.uri[0..z] })
                else
                    try std.fmt.allocPrint(a, "{d}: {s}", .{ loc.line + 1, std.fs.path.basename(loc.uri) });
                const rs: vaxis.Style = if (ri == self.nav_list_sel) sel_style else row_style;
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "│", .style = border_style });
                // cell-truncate the label to the interior width so a long
                // outline name never overflows the panel
                const fit = cellFitPrefix(win, label, inner -| 1);
                const row = try a.alloc(u8, fit.slice.len + (inner -| 1 -| fit.cells));
                @memset(row, ' ');
                @memcpy(row[0..fit.slice.len], fit.slice);
                try segs.append(a, .{ .text = row, .style = rs });
                try segs.append(a, .{ .text = "│", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // bottom border
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
            }
        }

        // Hunk preview float (<leader>hp): the hunk's raw patch in a
        // floating window — same visual language as the pickers. '+' lines
        // green, '-' lines red, hunk headers accent, context dim.
        if (self.git_preview) |*pv| {
            const total_lines = gitPreviewLineCount(pv.text);
            const list_rows = @min(@as(usize, 12), total_lines);
            if (pv.top + list_rows > total_lines) pv.top = total_lines -| list_rows;
            // width: 70% of the screen like the grep panel (patch lines are
            // long); the panel has no input row: title + rows + bottom border
            const box_w = @min(win.width * 7 / 10, win.width -| 4);
            const inner = box_w - 2;
            const box_h: u32 = @as(u32, @intCast(list_rows)) + 2;
            var start_row = (height -| box_h) / 3;
            if (start_row < 1) start_row = 1;
            if (start_row + box_h >= height) start_row = height -| box_h;
            const start_col = (win.width -| box_w) / 2;
            const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
            const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
            // top border + title
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╭", .style = border_style });
                try segs.append(a, .{ .text = " Hunk ", .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } } });
                var cx: u32 = 1 + 6;
                while (cx < inner + 1) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╮", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // split the patch into lines (the stored text ends with '\n')
            var line_it = std.mem.splitScalar(u8, pv.text, '\n');
            var k: usize = 0;
            while (k < list_rows) : (k += 1) {
                var line = line_it.next() orelse "";
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                const rs: vaxis.Style = if (line.len > 0)
                    switch (line[0]) {
                        '+' => .{ .fg = .{ .rgb = self.theme.git_add }, .bg = .{ .rgb = self.theme.bg_float } },
                        '-' => .{ .fg = .{ .rgb = self.theme.git_del }, .bg = .{ .rgb = self.theme.bg_float } },
                        '@' => .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_float } },
                        else => .{ .fg = .{ .rgb = self.theme.fg_dim }, .bg = .{ .rgb = self.theme.bg_float } },
                    }
                else
                    row_style;
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "│", .style = border_style });
                const fit = cellFitPrefix(win, line, inner -| 1);
                const row = try a.alloc(u8, @intCast(fit.cells));
                @memset(row, ' ');
                @memcpy(row[0..fit.slice.len], fit.slice);
                try segs.append(a, .{ .text = row, .style = rs });
                try segs.append(a, .{ .text = "│", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(start_col), .wrap = .none });
            }
            // bottom border
            {
                var segs = std.ArrayList(vaxis.Segment).empty;
                try segs.append(a, .{ .text = "╰", .style = border_style });
                var cx: u32 = 0;
                while (cx < inner) : (cx += 1) {
                    try segs.append(a, .{ .text = "─", .style = border_style });
                }
                try segs.append(a, .{ .text = "╯", .style = border_style });
                _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(start_col), .wrap = .none });
            }
        }

        // insert-mode completion menu (Ctrl+n / auto-suggest): a floating
        // window like nvim's blink.cmp — rounded border, solid bg_float
        // panel, selected row in bg_sel with a Nerd Font kind icon column.
        // The buffer cursor is left untouched.
        if (self.completion_active) {
            const total = self.completion_words.items.len;
            if (total > 0) {
                const list_rows = @min(@as(usize, 8), total);
                var top: usize = 0;
                if (self.completion_sel >= list_rows) top = self.completion_sel - list_rows + 1;
                const c_line = self.cur().pt.lineOf(self.curCursor().*);
                const c_col = self.screenCellCol(win, c_line, self.curCursor().*);
                // box width in cells: borders + icon + pad + longest label
                var max_label: usize = 0;
                var k: usize = 0;
                while (k < list_rows) : (k += 1) {
                    max_label = @max(max_label, self.completion_words.items[top + k].text.len);
                }
                max_label = @min(max_label, 46);
                const inner_cells: u32 = @intCast(2 + max_label);
                const box_w = inner_cells + 2;
                var start_row = c_line - self.curViewTop().* + cur_rect.row + 1;
                if (start_row + list_rows + 2 > height) {
                    // near the bottom: show the menu above the cursor; the
                    // saturating minus keeps short terminals from underflowing
                    // (a 4.29e9 row would draw the menu off-screen silently)
                    start_row = (c_line - self.curViewTop().* + cur_rect.row) -| (list_rows + 2);
                }
                // anchor the menu at the cursor column (not pinned left)
                var box_col = cur_rect.col + gutter + c_col;
                if (box_col + box_w > win.width) box_col = win.width -| box_w;
                const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                const sel_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_sel }, .fg = .{ .rgb = self.theme.fg } };
                const row_style: vaxis.Style = .{ .bg = .{ .rgb = self.theme.bg_float }, .fg = .{ .rgb = self.theme.fg } };
                // top border ╭───╮
                {
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = "╭", .style = border_style });
                    try segs.append(a, .{ .text = "─", .style = border_style });
                    // the remaining top edge (inner_cells - 1 cells)
                    var cx: u32 = 1;
                    while (cx < inner_cells) : (cx += 1) {
                        try segs.append(a, .{ .text = "─", .style = border_style });
                    }
                    try segs.append(a, .{ .text = "╮", .style = border_style });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(box_col), .wrap = .none });
                }
                k = 0;
                while (k < list_rows) : (k += 1) {
                    const item = self.completion_words.items[top + k];
                    const style = if (top + k == self.completion_sel) sel_style else row_style;
                    const icon = if (item.kind != 0) kindGlyph(item.kind) else " ";
                    const shown = @min(item.text.len, max_label);
                    // byte layout: icon(≤3) + ' ' pad + label + spaces to fill
                    const row = try a.alloc(u8, inner_cells + 2);
                    @memset(row, ' ');
                    @memcpy(row[0..icon.len], icon);
                    if (shown > 0) @memcpy(row[icon.len + 1 .. icon.len + 1 + shown], item.text[0..shown]);
                    const segs = [_]vaxis.Segment{
                        .{ .text = "│", .style = border_style },
                        .{ .text = row, .style = style },
                        .{ .text = "│", .style = border_style },
                    };
                    _ = win.print(&segs, .{ .row_offset = @intCast(start_row + 1 + k), .col_offset = @intCast(box_col), .wrap = .none });
                }
                // bottom border ╰───╯
                {
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = "╰", .style = border_style });
                    var cx: u32 = 0;
                    while (cx < inner_cells) : (cx += 1) {
                        try segs.append(a, .{ .text = "─", .style = border_style });
                    }
                    try segs.append(a, .{ .text = "╯", .style = border_style });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + list_rows), .col_offset = @intCast(box_col), .wrap = .none });
                }
            }

            // Ghost text: the suffix of the selected item beyond the typed
            // prefix, shown dimmed right after the cursor (VS Code style).
            // Only when the item actually extends the typed prefix.
            if (self.state.mode == .insert and self.completion_sel < total) {
                const item = self.completion_words.items[self.completion_sel].text;
                const typed_len = self.curCursor().* - self.completion_pos;
                const ghost_line = self.cur().pt.lineOf(self.curCursor().*);
                const ghost_col = self.screenCellCol(win, ghost_line, self.curCursor().*);
                if (item.len > typed_len and typed_len > 0 and typed_len < 256) {
                    var prefix_buf: [256]u8 = undefined;
                    self.cur().pt.copyRange(self.completion_pos, prefix_buf[0..typed_len]);
                    if (std.mem.startsWith(u8, item, prefix_buf[0..typed_len])) {
                        const ghost = item[typed_len..];
                        // the ghost starts right after the cursor (which sits
                        // after the typed prefix) — NOT offset by typed_len,
                        // which would push it away from the word when the
                        // word has a prefix like "b." (b.stand + ghost had a
                        // gap that made the completion look broken)
                        if (ghost.len > 0 and ghost_col + ghost.len < win.width) {
                            const seg = [_]vaxis.Segment{.{
                                .text = ghost,
                                .style = .{ .dim = true },
                            }};
                            _ = win.print(&seg, .{
                                .row_offset = @intCast(ghost_line - self.curViewTop().* + cur_rect.row),
                                .col_offset = @intCast(cur_rect.col + gutter + ghost_col),
                                .wrap = .none,
                            });
                        }
                    }
                }
            }
        }

        // Current-line blame ghost (<leader>tb, nvim gitsigns style): the
        // blame of the CURSOR line renders as dim end-of-line virtual
        // text — "<author>, HH:MM - <summary>" — 1s after the cursor
        // settles (CursorHold), hidden again while it moves. Mirrors the
        // nvim config: current_line_blame virt_text at eol, formatter
        // '<author>, <author_time:%R> - <summary>'.
        {
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
            if (self.curCursor().* != self.blame_last_cursor) {
                self.blame_last_cursor = self.curCursor().*;
                self.blame_move_ms = now_ms;
            }
            if (self.blame_active and self.state.mode == .normal and
                self.git_blame != null and now_ms - self.blame_move_ms >= blame_hold_ms)
            {
                const fbuf = self.cur();
                const blame_line = fbuf.pt.lineOf(self.curCursor().*);
                if (self.git_blame_path) |bp| {
                    if (fbuf.path == null or !std.mem.eql(u8, bp, fbuf.path.?)) {
                        // cached blame is for another file — no ghost
                    } else if (self.git_blame.?.at(blame_line)) |e| {
                    var hm_buf: [5]u8 = undefined;
                    const hm = formatHm(&hm_buf, e.author_time);
                    const label = try std.fmt.allocPrint(a, " {s}, {s} - {s}", .{ e.author, hm, e.summary });
                    // anchor at the END of the line's RENDERED text:
                    // screenCellCol (not lineCellCol) counts the inlay hints
                    // spliced into the line — anchoring at the raw text end
                    // would draw the ghost ON TOP of hinted text
                    const line_end = fbuf.pt.lineStart(blame_line) + fbuf.pt.lineLen(blame_line);
                    const end_col = self.screenCellCol(win, blame_line, line_end);
                    var start_col = cur_rect.col + gutter + end_col;
                    // a closed fold's " … N lines" marker also renders after
                    // the text — shift the ghost past it
                    if (foldAt(fbuf, blame_line)) |f| {
                        const marker = try std.fmt.allocPrint(a, " … {d} lines", .{f.hiddenCount()});
                        start_col += self.textWidth(win, marker);
                    }
                    if (start_col < win.width) {
                        const fit = cellFitPrefix(win, label, win.width - start_col);
                        if (fit.cells > 0) {
                            const seg = [_]vaxis.Segment{.{
                                .text = fit.slice,
                                .style = .{ .dim = true },
                            }};
                            _ = win.print(&seg, .{
                                .row_offset = @intCast(blame_line - self.curViewTop().* + cur_rect.row),
                                .col_offset = @intCast(start_col),
                                .wrap = .none,
                            });
                        }
                    }
                }
                }
            }
        }

        // LSP hover / signature floating window: a small box below the
        // cursor line (≤6 rows, ≤60 cols) showing nav_hover_text, wrapping
        // on newlines so multi-line hover (markdown blocks etc.) is readable.
        // Styled like nvim's floating windows: rounded border, title bar.
        // Every cell inside the box carries bg_float (including the border
        // and the padding after short lines) so the panel is a solid,
        // theme-colored block — never gaps of the editor background.
        if (self.nav_hover_text) |htext| {
            if (htext.len > 0) {
                const h_line = self.cur().pt.lineOf(self.curCursor().*);
                const hcols: u32 = 60;
                // the box hugs the text: its height is the number of wrapped
                // lines, capped at 6 so a huge hover never covers the buffer
                var hrows: u32 = 1;
                for (htext) |c| {
                    if (c == '\n') hrows += 1;
                }
                hrows = @min(hrows, 6);
                var start_row = h_line - self.curViewTop().* + cur_rect.row + 1;
                if (start_row + hrows >= height) {
                    start_row = (h_line - self.curViewTop().* + cur_rect.row) -| hrows;
                }
                const col0 = cur_rect.col + gutter + 1;
                const border_style: vaxis.Style = .{ .fg = .{ .rgb = self.theme.fg_faint }, .bg = .{ .rgb = self.theme.bg_float } };
                const border = "│";
                const tl = "╭";
                const tr = "╮";
                const bl = "╰";
                const br = "╯";
                // top border
                {
                    const seg = [_]vaxis.Segment{
                        .{ .text = tl, .style = border_style },
                        .{ .text = "─", .style = border_style },
                    };
                    _ = win.print(&seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0), .wrap = .none });
                    var cx: u32 = 1;
                    while (cx <= hcols) : (cx += 1) {
                        const hseg = [_]vaxis.Segment{.{
                            .text = "─",
                            .style = border_style,
                        }};
                        _ = win.print(&hseg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0 + cx), .wrap = .none });
                    }
                    const rseg = [_]vaxis.Segment{.{
                        .text = tr,
                        .style = border_style,
                    }};
                    _ = win.print(&rseg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(col0 + hcols + 1), .wrap = .none });
                }
                // Split the text into up to hrows lines; fence off ```lang
                // code blocks and syntax-highlight their content with
                // tree-sitter (hoverCodeLineSegs); prose lines get markdown-
                // ish token colors (hoverLineSegs). Fence lines render dim.
                // Every cell keeps bg_float — the panel stays a solid block.
                const HoverBlock = struct {
                    start: usize,
                    end: usize, // line indices, end exclusive
                    lang: ?[]const u8,
                    text: []u8, // lines joined with '\n' (arena)
                    offsets: []u32, // byte offset of each line in text
                    spans: []syntax.Span, // merged spans over text
                };
                var lines = std.ArrayList([]const u8).empty;
                var kinds = std.ArrayList(u8).empty; // 0 prose, 1 fence, 2 code
                var blocks = std.ArrayList(HoverBlock).empty;
                {
                    var remaining = htext;
                    var r: u32 = 0;
                    var in_fence: ?[]const u8 = null;
                    var block_start: usize = 0;
                    while (r < hrows) : (r += 1) {
                        const nl = std.mem.indexOfScalar(u8, remaining, '\n');
                        const line_len = if (nl) |i| i else remaining.len;
                        try lines.append(a, remaining[0..line_len]);
                        if (in_fence == null) {
                            if (isFenceLine(remaining[0..line_len])) |flang| {
                                try kinds.append(a, 1);
                                in_fence = flang;
                                block_start = lines.items.len;
                            } else {
                                try kinds.append(a, 0);
                            }
                        } else {
                            if (isFenceLine(remaining[0..line_len]) != null) {
                                try kinds.append(a, 1);
                                try blocks.append(a, .{ .start = block_start, .end = lines.items.len, .lang = in_fence, .text = &.{}, .offsets = &.{}, .spans = &.{} });
                                in_fence = null;
                            } else {
                                try kinds.append(a, 2);
                            }
                        }
                        if (nl) |i| {
                            remaining = remaining[@min(i + 1, remaining.len)..];
                        } else {
                            remaining = remaining[remaining.len..];
                        }
                    }
                    if (in_fence != null) {
                        try blocks.append(a, .{ .start = block_start, .end = lines.items.len, .lang = in_fence, .text = &.{}, .offsets = &.{}, .spans = &.{} });
                    }
                }
                // Build each block: joined text, per-line byte offsets, and
                // merged tree-sitter spans (all arena — the highlighter lives
                // only for this frame). The fence language wins; a bare or
                // unknown fence falls back to the current file's language.
                for (blocks.items) |*blk| {
                    if (blk.start >= blk.end) continue;
                    var text = std.ArrayList(u8).empty;
                    var offsets = std.ArrayList(u32).empty;
                    var bli = blk.start;
                    while (bli < blk.end) : (bli += 1) {
                        try offsets.append(a, @intCast(text.items.len));
                        try text.appendSlice(a, lines.items[bli]);
                        try text.append(a, '\n');
                    }
                    blk.text = try text.toOwnedSlice(a);
                    blk.offsets = try offsets.toOwnedSlice(a);
                    var hl: ?syntax.Highlighter = null;
                    if (blk.lang) |l| {
                        if (l.len > 0) {
                            if (syntax.languageFor(l)) |ln| hl = syntax.Highlighter.init(a, ln) catch null;
                        }
                    }
                    if (hl == null) {
                        const ft = filetypeOf(self.cur().path);
                        if (syntax.languageFor(ft)) |ln| hl = syntax.Highlighter.init(a, ln) catch null;
                    }
                    if (hl) |*h| {
                        h.reparse(blk.text) catch {};
                        var raw = std.ArrayList(syntax.Span).empty;
                        h.spansInRange(0, @intCast(blk.text.len), a, &raw) catch {};
                        var merged = std.ArrayList(syntax.Span).empty;
                        for (raw.items) |sp| {
                            while (merged.items.len > 0) {
                                var last = &merged.items[merged.items.len - 1];
                                if (sp.start >= last.end) break; // disjoint
                                if (sp.start <= last.start) {
                                    _ = merged.pop(); // covered wholly
                                    continue;
                                }
                                last.end = sp.start; // later span wins
                                break;
                            }
                            try merged.append(a, sp);
                        }
                        blk.spans = try merged.toOwnedSlice(a);
                    }
                }
                // Render each row: code lines use their block's spans, fence
                // lines dim, prose lines the markdown tokenizer.
                var r: u32 = 0;
                var cur_block: usize = 0;
                while (r < hrows) : (r += 1) {
                    const line = lines.items[r];
                    var inner: []vaxis.Segment = undefined;
                    switch (kinds.items[r]) {
                        1 => inner = try self.hoverFenceSegs(a, line, hcols),
                        2 => {
                            while (cur_block < blocks.items.len and blocks.items[cur_block].end <= r) cur_block += 1;
                            if (cur_block < blocks.items.len and blocks.items[cur_block].start <= r) {
                                const blk = &blocks.items[cur_block];
                                const bi = r - blk.start;
                                const ls = blk.offsets[bi];
                                const shown = @min(line.len, @as(usize, @intCast(hcols)));
                                inner = try self.hoverCodeLineSegs(a, blk.text, ls, ls + shown, blk.spans, hcols);
                            } else {
                                inner = try self.hoverLineSegs(a, line, hcols);
                            }
                        },
                        else => inner = try self.hoverLineSegs(a, line, hcols),
                    }
                    var segs = std.ArrayList(vaxis.Segment).empty;
                    try segs.append(a, .{ .text = border, .style = border_style });
                    try segs.appendSlice(a, inner);
                    try segs.append(a, .{ .text = border, .style = border_style });
                    _ = win.print(segs.items, .{ .row_offset = @intCast(start_row + 1 + r), .col_offset = @intCast(col0), .wrap = .none });
                }
                // bottom border
                {
                    const bseg = [_]vaxis.Segment{.{
                        .text = bl,
                        .style = border_style,
                    }};
                    _ = win.print(&bseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0), .wrap = .none });
                    var cx: u32 = 1;
                    while (cx <= hcols) : (cx += 1) {
                        const hseg = [_]vaxis.Segment{.{
                            .text = "─",
                            .style = border_style,
                        }};
                        _ = win.print(&hseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0 + cx), .wrap = .none });
                    }
                    const rseg = [_]vaxis.Segment{.{
                        .text = br,
                        .style = border_style,
                    }};
                    _ = win.print(&rseg, .{ .row_offset = @intCast(start_row + 1 + hrows), .col_offset = @intCast(col0 + hcols + 1), .wrap = .none });
                }
            }
        }

        const mode_str = switch (self.state.mode) {
            .normal => " NORMAL ",
            .insert => " INSERT ",
            .visual_char, .visual_line, .visual_block => " VISUAL ",
            .command => " COMMAND ",
        };
        const status_col = self.screenCellCol(win, cursor_line, self.curCursor().*);
        // a completion request is in flight (zls can take many seconds on
        // build.zig while its build_runner analyses the project) — show "…"
        // so a slow response isn't mistaken for a dead completion that
        // silently turns the next Enter into a newline.
        const status = if (self.completion_slot != null)
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}  …",
                .{ mode_str, cursor_line + 1, line_count, status_col },
            )
        else if (self.msg) |m|
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}  {s}",
                .{ mode_str, cursor_line + 1, line_count, status_col, m },
            )
        else
            try std.fmt.allocPrint(
                a,
                "{s} line {d}/{d} col {d}",
                .{ mode_str, cursor_line + 1, line_count, status_col },
            );
        const status_seg = [_]vaxis.Segment{.{
            .text = status,
            .style = .{ .fg = .{ .rgb = self.theme.fg }, .bg = .{ .rgb = self.theme.bg_status } },
        }};
        _ = win.print(&status_seg, .{ .row_offset = @intCast(height - 1), .wrap = .none });
        // git branch (M3a): "  ⎇ main" right after the mode/message text, in
        // the accent color — the design's StatusLine git component.
        if (self.git_branch) |b| {
            const branch_seg = [_]vaxis.Segment{.{
                .text = try std.fmt.allocPrint(a, "  ⎇ {s}", .{std.mem.trim(u8, b, " \t\r\n")}),
                .style = .{ .fg = .{ .rgb = self.theme.accent }, .bg = .{ .rgb = self.theme.bg_status } },
            }};
            _ = win.print(&branch_seg, .{ .row_offset = @intCast(height - 1), .col_offset = @intCast(status.len), .wrap = .none });
        }

        // cursor position — in the file tree when the tree has focus,
        // otherwise in the buffer
        if (self.filetree_active and self.focus == .filetree) {
            // Items render at contentTop()+1+k (below the "╭─ files" title
            // row) with text starting at column 1 (after the left border) —
            // the cursor must land on the same row/column as the highlight.
            const sel_row: u32 = self.contentTop(a) + 1 + @as(u32, @intCast(self.filetree_sel -| self.filetree_top));
            self.vx.screen.cursor = .{
                .row = @intCast(sel_row),
                .col = 1,
            };
        } else if (self.nav_list_active) {
            // The location-list float (gr/gI/<leader>o) is navigated with
            // j/k: the block cursor sits on the selected row of the float
            // (start_col + 1 = after the left border), like the file tree.
            self.vx.screen.cursor = .{
                .row = @intCast(self.nav_float_row + 1 + @as(u32, @intCast(self.nav_list_sel -| self.nav_loc_top))),
                .col = @intCast(self.nav_float_col + 1),
            };
        } else {
            const cursor_col = self.screenCellCol(win, cursor_line, self.curCursor().*);
            // screen row = count of VISIBLE lines between view_top and the
            // cursor (a closed fold's hidden body occupies zero rows)
            var cursor_row: u32 = cur_rect.row;
            {
                const fbuf = self.cur();
                var l = self.curViewTop().*;
                while (l < cursor_line) : (cursor_row += 1) l = foldNextLine(fbuf, l);
            }
            self.vx.screen.cursor = .{
                .row = @intCast(cursor_row),
                .col = @intCast(cur_rect.col + gutter + cursor_col), // window offset + gutter
            };
        }
        self.vx.screen.cursor_vis = true;
        self.vx.screen.cursor_shape = if (self.state.mode == .insert) .beam else .block;

        try self.vx.render(self.tty.writer());
    }

    /// True while the current-line blame's 1s CursorHold window is still
    /// counting (the loop then polls instead of blocking, so the ghost
    /// appears without a keypress).
    fn blameHoldActive(self: *App) bool {
        if (!self.blame_active or self.git_blame == null) return false;
        const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
        return now - self.blame_move_ms < blame_hold_ms;
    }

    /// True while the scope highlight animation is still spreading: the run
    /// loop then polls instead of blocking in pollEvent, so the spread
    /// advances frame by frame without keypresses.
    fn scopeAnimActive(self: *App) bool {
        const a = self.scope_anim orelse return false;
        const now = @divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms);
        return now - a.start_ms < ScopeAnim.duration_ms;
    }

    fn run(self: *App) !void {
        try self.vx.enterAltScreen(self.tty.writer());
        try self.loop.start();
        defer self.loop.stop();

        while (!self.quit) {
            // LSP messages first: responses fill request slots, notifications
            // reach the handler before the frame renders; then consume any
            // completed navigation request before the frame is drawn.
            if (self.lsp_client) |c| c.drain(self, App.lspHandler);
            // Server exited/crashed (stdout EOF or read error): nothing more
            // will ever arrive — drop the dead client, clear its state and
            // tell the user, instead of letting pending requests hang forever.
            if (self.lsp_client) |c| {
                if (c.server_died.load(.acquire)) {
                    self.teardownLsp(true);
                }
            }
            // Consume async LSP responses (navigation, completion) and render
            // immediately — otherwise the loop would block in pollEvent below
            // before the new hover window / completion menu is drawn.
            const nav_ready = self.processNav();
            const comp_ready = self.processCompletion();
            const fmt_ready = self.processFormat();
            const inlay_ready = self.processInlay();
            const outline_ready = self.processOutline();
            const diag_changed = self.diag_dirty;
            self.diag_dirty = false;
            // Consume a completed git job (status refresh / blame / hunk
            // apply): gutter marks, branch and floats update without a
            // keypress, same as the LSP slots.
            var git_ready = false;
            if (self.git_job) |job| {
                if (job.done.load(.acquire)) {
                    self.consumeGitJob(job);
                    git_ready = true;
                }
            }
            if (nav_ready or comp_ready or fmt_ready or inlay_ready or outline_ready or diag_changed or git_ready) {
                try self.render();
                continue;
            }
            // Auto-refresh inlay hints when the view scrolls (LSP available
            // and the visible top line changed since the last request).
            if (self.lsp_client != null) {
                const top = self.curViewTop().*;
                if (self.inlay_view_top == null or self.inlay_view_top.? != top) {
                    self.inlay_view_top = top;
                    try self.requestInlayHints();
                }
            }
            // poll + drain: block until an event arrives (keypress OR an
            // LSP wake posted by the reader thread), then handle the whole
            // batch and render once. While the scope highlight is animating,
            // poll instead of blocking so the spread advances frame by frame
            // without keypresses (16ms ≈ 60fps; vaxis diffs the output).
            if (self.scopeAnimActive() or self.blameHoldActive()) {
                std.Io.sleep(self.io, .fromMilliseconds(16), .real) catch {};
            } else {
                try self.loop.pollEvent();
            }
            while (try self.loop.tryEvent()) |event| {
                switch (event) {
                    .key_press => |key| try self.handleKey(key),
                    .paste => |text| {
                        if (self.state.mode == .insert) {
                            if (self.mc_active) try self.mcInsertText(text) else try self.insertText(text);
                        }
                    },
                    .winsize => |ws| {
                        try self.vx.resize(self.alloc, self.tty.writer(), ws);
                    },
                    else => {},
                }
            }
            try self.render();
        }

        try self.vx.exitAltScreen(self.tty.writer());
    }
};

// ---- M3a git worker thread (file scope — not App methods) ----

/// Worker thread entry: run the job, publish the result, then wake the main
/// loop (which may be blocked in pollEvent).
fn gitJobMain(job: *GitJob) void {
    switch (job.kind) {
        .status => runStatus(job),
        .blame => runBlame(job),
        .apply => runApply(job),
    }
    job.done.store(true, .release);
    if (job.wake_fn) |f| {
        if (job.wake_ctx) |ctx| f(ctx);
    }
}

const CmdResult = struct { out: ?[]u8, err: ?[]u8, ok: bool };

/// Run one git command to completion (blocking — worker thread only),
/// capturing stdout/stderr. Returns owned buffers (null when empty or on
/// spawn failure).
fn runGit(self: *GitJob, argv: []const []const u8, stdin_data: ?[]const u8) CmdResult {
    var proc = std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return .{ .out = null, .err = null, .ok = false };
    if (stdin_data) |data| {
        if (proc.stdin) |in| {
            std.Io.File.writeStreamingAll(in, self.io, data) catch {};
            // close our write end so the child sees EOF on its stdin (git
            // apply - reads until EOF), then null the handle so wait()'s
            // cleanup doesn't double-close it (EBADF → panic)
            std.Io.File.close(in, self.io);
            proc.stdin = null;
        }
    }
    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(self.alloc);
    var err_buf = std.ArrayList(u8).empty;
    defer err_buf.deinit(self.alloc);
    if (proc.stdout) |out| gitReadAll(self, out, &out_buf);
    if (proc.stderr) |err| gitReadAll(self, err, &err_buf);
    const term = proc.wait(self.io) catch return .{ .out = null, .err = null, .ok = false };
    const ok = term == .exited and term.exited == 0;
    return .{
        .out = if (out_buf.items.len > 0) out_buf.toOwnedSlice(self.alloc) catch null else null,
        .err = if (err_buf.items.len > 0) err_buf.toOwnedSlice(self.alloc) catch null else null,
        .ok = ok,
    };
}

/// Drain a pipe into `buf` until EOF, then close it (worker thread).
fn gitReadAll(self: *GitJob, file: std.Io.File, buf: *std.ArrayList(u8)) void {
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = file.readStreaming(self.io, &.{tmp[0..]}) catch break;
        if (n == 0) break;
        buf.appendSlice(self.alloc, tmp[0..n]) catch break;
    }
    // NOT closed here: child.wait() closes the child's pipes; closing them
    // early makes its cleanup hit EBADF (recoverableOsBugDetected panics).
}

fn freeCmdResult(self: *GitJob, r: CmdResult) void {
    if (r.out) |o| self.alloc.free(o);
    if (r.err) |e| self.alloc.free(e);
}

fn dupOrNull(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    return alloc.dupe(u8, s) catch null;
}

/// status: branch + untracked flag + working-tree diff for `path`.
fn runStatus(self: *GitJob) void {
    var branch_r = runGit(self, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, null);
    defer freeCmdResult(self, branch_r);
    if (!branch_r.ok) return; // not a git repo — everything stays empty
    if (branch_r.out) |o| {
        // take ownership of the original buffer (branch output is "main\n";
        // the renderer trims). NEVER hand out a shorter slice of the
        // allocation — DebugAllocator's free validates the size.
        self.branch = o;
        branch_r.out = null;
    }
    const status_r = runGit(self, &.{ "git", "status", "--porcelain", "--", self.path }, null);
    defer freeCmdResult(self, status_r);
    if (status_r.ok) {
        if (status_r.out) |o| {
            self.untracked = std.mem.startsWith(u8, o, "??");
        }
    }
    var diff_r = runGit(self, &.{ "git", "diff", "--no-color", "--no-ext-diff", "--", self.path }, null);
    defer freeCmdResult(self, diff_r);
    if (diff_r.ok) {
        self.out = diff_r.out;
        diff_r.out = null;
    }
}

/// blame: `git blame --line-porcelain` output for `path`.
fn runBlame(self: *GitJob) void {
    var r = runGit(self, &.{ "git", "blame", "--line-porcelain", "--", self.path }, null);
    defer freeCmdResult(self, r);
    if (r.ok) {
        self.out = r.out;
        r.out = null;
    }
}

/// apply: re-diff in-thread (the user's hunk index must map onto a diff
/// computed at apply time, or a stale index could touch the wrong hunk),
/// then stage (git apply --cached) or reset (git apply -R) that hunk.
/// Untracked files stage whole-file via `git add`.
fn runApply(self: *GitJob) void {
    const d = runGit(self, &.{ "git", "diff", "--no-color", "--no-ext-diff", "--", self.path }, null);
    defer freeCmdResult(self, d);
    if (!d.ok) {
        self.msg = dupOrNull(self.alloc, "git diff failed");
        return;
    }
    var diff = git.parseDiff(self.alloc, d.out orelse "") catch {
        self.msg = dupOrNull(self.alloc, "git diff parse failed");
        return;
    };
    defer diff.deinit(self.alloc);
    if (diff.untracked) {
        if (self.op == .stage) {
            const add_r = runGit(self, &.{ "git", "add", "--", self.path }, null);
            defer freeCmdResult(self, add_r);
            self.msg = if (add_r.ok)
                dupOrNull(self.alloc, "file staged")
            else
                dupOrNull(self.alloc, std.mem.trim(u8, add_r.err orelse "", " \t\r\n"));
        } else {
            self.msg = dupOrNull(self.alloc, "untracked: nothing to reset");
        }
        return;
    }
    const target = self.hunk_start;
    const found = for (diff.hunks.items, 0..) |*h, i| {
        if (h.start_line == target) break i;
    } else null;
    const hi = found orelse {
        self.msg = dupOrNull(self.alloc, "hunk gone (file changed?)");
        return;
    };
    const patch = diff.hunks.items[hi].patch;
    const apply_r = if (self.op == .stage)
        runGit(self, &.{ "git", "apply", "--cached", "-" }, patch)
    else
        runGit(self, &.{ "git", "apply", "-R", "-" }, patch);
    defer freeCmdResult(self, apply_r);
    self.msg = if (apply_r.ok)
        dupOrNull(self.alloc, if (self.op == .stage) "hunk staged" else "hunk reset")
    else
        dupOrNull(self.alloc, std.mem.trim(u8, apply_r.err orelse "", " \t\r\n"));
}

/// "HH:MM" (24h) from an epoch-seconds timestamp — the nvim formatter's
/// author_time:%R equivalent (gitsigns current_line_blame_formatter).
fn formatHm(buf: *[5]u8, epoch_secs: i64) []const u8 {
    const secs: u64 = if (epoch_secs > 0) @intCast(epoch_secs) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    const h = ds.getHoursIntoDay();
    const m = ds.getMinutesIntoHour();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ h, m }) catch "??:??";
}

/// Number of lines in a hunk patch (for the preview's scroll window).
fn gitPreviewLineCount(text: []const u8) usize {
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Append `haystack` with every occurrence of `pat` replaced by `rep`
/// (all if `global`, else only the first). Returns the replacement count.
fn replaceLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, haystack: []const u8, pat: []const u8, rep: []const u8, global: bool) usize {
    if (pat.len == 0) {
        out.appendSlice(allocator, haystack) catch {};
        return 0;
    }
    var count: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, i, pat)) |pos| {
            out.appendSlice(allocator, haystack[i..pos]) catch return count;
            out.appendSlice(allocator, rep) catch return count;
            count += 1;
            i = pos + pat.len;
            if (!global) {
                out.appendSlice(allocator, haystack[i..]) catch return count;
                return count;
            }
        } else {
            out.appendSlice(allocator, haystack[i..]) catch return count;
            return count;
        }
    }
    return count;
}

/// Number of syntax.Style variants — sizes the per-frame style palette used
/// by the grep picker preview (styles keyed by the enum's ordinal).
const syntax_style_count = @typeInfo(syntax.Style).@"enum".fields.len;

/// Snap a byte offset back to the start of the UTF-8 char containing it.
/// fzy match positions are byte indices that can land on a continuation byte
/// when the query contains multi-byte chars; segment splits must only happen
/// at char boundaries or vaxis's grapheme iterator emits garbage.
fn utf8CharStart(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

/// Byte length of the UTF-8 char starting at `pos` (must be a char start).
fn utf8CharLenAt(s: []const u8, pos: usize) usize {
    const b = s[pos];
    if (b < 0x80) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// Byte offset where 0-based `line` starts in `text` (text.len when the line
/// doesn't exist).
fn lineStartByte(text: []const u8, line: usize) usize {
    var pos: usize = 0;
    var l: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return text.len;
        pos = nl + 1;
    }
    return @min(pos, text.len);
}

/// Byte offset of 0-based `line`'s end (the '\n' position, or text.len for a
/// final line without a trailing newline). Line content is text[start..end].
fn lineEndByte(text: []const u8, line: usize) usize {
    const s = lineStartByte(text, line);
    return std.mem.indexOfScalarPos(u8, text, s, '\n') orelse text.len;
}

/// Display width (terminal cells) of `text`, measured the way Window.print
/// lays text out: per grapheme cluster via gwidth (CJK = 2 cells, combining
/// marks and zero-width joiners = 0). A byte length is NOT a width —
/// truncating/padding by bytes overflows the row and shifts box borders on
/// any non-ASCII text.
fn cellWidth(win: vaxis.Window, text: []const u8) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: usize = 0;
    while (iter.next()) |g| cells += win.gwidth(g.bytes(text));
    return cells;
}

/// A grapheme-aligned slice of a string plus its display width in cells.
const CellFit = struct { slice: []const u8, cells: usize };

/// Longest prefix of `text` whose display width fits in `max_cells` cells.
/// Grapheme-aligned: never splits a UTF-8 sequence or cluster, and a wide
/// grapheme that would straddle the limit is dropped whole (a half-drawn
/// CJK char corrupts the row anyway).
fn cellFitPrefix(win: vaxis.Window, text: []const u8, max_cells: usize) CellFit {
    var iter = vaxis.unicode.graphemeIterator(text);
    var cells: usize = 0;
    var len: usize = 0;
    while (iter.next()) |g| {
        const w: usize = win.gwidth(g.bytes(text));
        if (cells + w > max_cells) break;
        cells += w;
        len = g.start + g.len;
    }
    return .{ .slice = text[0..len], .cells = cells };
}

/// Shortest suffix of `text` whose display width fits in `max_cells` cells
/// (grapheme-aligned), for left-truncated paths ("…tail" keeps the
/// informative end).
fn cellFitSuffix(win: vaxis.Window, text: []const u8, max_cells: usize) CellFit {
    const total = cellWidth(win, text);
    if (total <= max_cells) return .{ .slice = text, .cells = total };
    var iter = vaxis.unicode.graphemeIterator(text);
    var dropped: usize = 0;
    var start: usize = 0;
    while (total - dropped > max_cells) {
        const g = iter.next() orelse break;
        dropped += win.gwidth(g.bytes(text));
        start = g.start + g.len;
    }
    return .{ .slice = text[start..], .cells = total - dropped };
}

/// Append one picker row's colored segments: `text` (truncated to `total_w`
/// CELLS, grapheme-aligned) split into runs by the per-byte style ids in
/// `ids` (`styles[id]` per run), then space-padded to `total_w` cells with
/// `pad_style`. `text`/`ids`/`styles` must outlive vx.render() — pass arena
/// strings (or App-owned preview_text). `ids` is indexed by BYTE offset and
/// must cover the whole of `text`.
fn appendRowSegs(
    segs: *std.ArrayList(vaxis.Segment),
    a: std.mem.Allocator,
    win: vaxis.Window,
    text: []const u8,
    ids: []const u8,
    styles: []const vaxis.Style,
    total_w: usize,
    pad_style: vaxis.Style,
) !void {
    const fit = cellFitPrefix(win, text, total_w);
    const n = @min(fit.slice.len, ids.len);
    const cells = if (n == fit.slice.len) fit.cells else cellWidth(win, text[0..n]);
    var i: usize = 0;
    while (i < n) {
        const id = ids[i];
        var j = i + 1;
        while (j < n and ids[j] == id) : (j += 1) {}
        try segs.append(a, .{ .text = text[i..j], .style = styles[id] });
        i = j;
    }
    if (cells < total_w) {
        const pad = try a.alloc(u8, total_w - cells);
        @memset(pad, ' ');
        try segs.append(a, .{ .text = pad, .style = pad_style });
    }
}

/// Filetype from a file path's extension ("src/main.zig" → "zig").
fn filetypeOf(path: ?[]const u8) []const u8 {
    const p = path orelse return "";
    const base = std.fs.path.basename(p);
    const ext = std.fs.path.extension(base);
    if (ext.len <= 1) return "";
    return ext[1..];
}

/// "```" or "~~~" markdown code fence opener: returns the language after the
/// fence ("" for a bare fence with no language); null when the line isn't a
/// fence. Bare fences still count so the closing fence is recognized.
fn isFenceLine(line: []const u8) ?[]const u8 {
    if (line.len < 3) return null;
    const c = line[0];
    if (c != '`' and c != '~') return null;
    if (line[1] != c or line[2] != c) return null;
    var i: usize = 3;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return "";
    return line[i..];
}

/// Theme palette for the tree-sitter capture groups (src/syntax.zig Style).
/// One dedicated semantic color per token class (theme.Theme), so distinct
/// token kinds no longer collapse onto a shared color — and rainbow brackets
/// (bracket0..bracket6) map to the theme's 7-color rainbow by ordinal.
fn syntaxStyle(style: syntax.Style, t: theme.Theme) vaxis.Style {
    return switch (style) {
        .default => .{ .fg = .{ .rgb = t.fg } },
        .comment => .{ .fg = .{ .rgb = t.comment } },
        .keyword => .{ .fg = .{ .rgb = t.keyword } }, // gold
        .string => .{ .fg = .{ .rgb = t.string } }, // green
        .number => .{ .fg = .{ .rgb = t.number } },
        .constant => .{ .fg = .{ .rgb = t.constant } },
        // kanagawa's Boolean links to Constant; bold sets it apart
        .boolean => .{ .fg = .{ .rgb = t.boolean }, .bold = true },
        .character => .{ .fg = .{ .rgb = t.character } },
        .function => .{ .fg = .{ .rgb = t.function } },
        .tag => .{ .fg = .{ .rgb = t.tag } },
        .namespace => .{ .fg = .{ .rgb = t.namespace } },
        .constructor => .{ .fg = .{ .rgb = t.constructor } },
        .type => .{ .fg = .{ .rgb = t.type } },
        .label => .{ .fg = .{ .rgb = t.label } },
        .operator => .{ .fg = .{ .rgb = t.operator } },
        .variable => .{ .fg = .{ .rgb = t.variable } },
        .parameter => .{ .fg = .{ .rgb = t.parameter } },
        .property => .{ .fg = .{ .rgb = t.property } },
        .attribute => .{ .fg = .{ .rgb = t.attribute } },
        .builtin => .{ .fg = .{ .rgb = t.builtin } },
        .punctuation => .{ .fg = .{ .rgb = t.punctuation } },
        // rainbow brackets: bracketN -> rainbow[N] (ordinal offset from
        // bracket0, exactly the bracket depth % 7 the highlighter assigned)
        .bracket0, .bracket1, .bracket2, .bracket3, .bracket4, .bracket5, .bracket6 => blk: {
            const idx: usize = @as(usize, @intFromEnum(style)) - @as(usize, @intFromEnum(syntax.Style.bracket0));
            break :blk .{ .fg = .{ .rgb = t.rainbow[idx] } };
        },
    };
}

fn parseLineArg(arg: []const u8) ?u32 {
    if (std.mem.indexOfScalar(u8, arg, ':')) |idx| {
        return std.fmt.parseUnsigned(u32, arg[idx + 1 ..], 10) catch null;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var app = try App.create(init);
    defer app.destroy();

    // args: oz [file[:line]] ...
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    var target_line: u32 = 0;
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        const content = arg[0 .. arg.len - 0];
        if (parseLineArg(content)) |ln| {
            target_line = ln;
        }
        const file_path = if (parseLineArg(content) != null) content[0..std.mem.lastIndexOfScalar(u8, content, ':').?] else content;
        if (file_path.len > 0) {
            var file = std.Io.Dir.cwd().openFile(app.io, file_path, .{ .mode = .read_only }) catch |e| {
                switch (e) {
                    // vim semantics: a path that does not exist yet opens as
                    // an empty buffer with the path set — :w creates the file
                    // (saveFile uses createFile). No status message; this is
                    // the normal "edit a new file" flow, not the dashboard.
                    error.FileNotFound => {
                        app.cur().pt.deinit();
                        app.cur().pt = try buffer.PieceTable.init(app.alloc, "");
                        if (app.cur().path) |p| app.alloc.free(p);
                        app.cur().path = try app.absolutePath(file_path);
                    },
                    // a directory is not a file — refuse it with a message
                    // instead of dying deep in the read path below.
                    error.IsDir => try app.setMsg(try std.fmt.allocPrint(app.alloc, "E17: {s} is a directory", .{file_path})),
                    // exists but unreadable (permissions etc.): say so on the
                    // status bar, don't silently drop into the dashboard.
                    else => try app.setMsg(try std.fmt.allocPrint(app.alloc, "E484: cannot open {s}: {s}", .{ file_path, @errorName(e) })),
                }
                break;
            };
            defer file.close(app.io);
            const size = (try file.stat(app.io)).size;
            // The piece table addresses the document with u32 offsets; a file
            // at/over 4 GiB would overflow (@intCast panics). Refuse it
            // cleanly instead of crashing: syntax highlighting already
            // degrades past SIZE_LIMIT, and editing multi-GiB files with a
            // u32-based buffer is unsupported.
            if (size >= std.math.maxInt(u32)) {
                try app.setMsg(try app.alloc.dupe(u8, "file too large (>4GiB)"));
                continue;
            }
            const bytes = try app.alloc.alloc(u8, @intCast(size));
            defer app.alloc.free(bytes);
            _ = try file.readPositionalAll(app.io, bytes, 0);
            app.cur().pt.deinit();
            app.cur().pt = try buffer.PieceTable.init(app.alloc, bytes);
            if (app.cur().path) |p| app.alloc.free(p);
            // Store an absolute path so LSP (uri building, server matching)
            // works for relative CLI args like `oz build.zig` — filetypeOf
            // and ensureLsp both consume this.
            app.cur().path = try app.absolutePath(file_path);
            // recent history must hold the same (absolute) form every other
            // entry uses, or the dashboard's relative entries break after a
            // cwd change (and dedupe against absolute entries fails).
            try app.addRecent(app.cur().path.?);
        }
        break; // M0: first file only
    }
    if (target_line > 0) {
        app.curCursor().* = app.cur().pt.lineStart(@min(target_line - 1, app.cur().pt.lineCount() - 1));
    }

    // the CLI arg path edits cur() directly (no openInBuffer/switchTo), so
    // kick the LSP client and the git status refresh for the opened filetype
    // here.
    app.ensureLsp();
    app.scheduleGitStatus();
    try app.loadRecent();
    defer app.saveRecent() catch {};
    try app.run();
}
