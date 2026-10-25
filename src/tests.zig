//! L1 unit + L2 render-snapshot test root (DESIGN.md §12.2).
//!
//! Each module file is imported directly (not via the module roots) so its
//! `test` blocks are collected by the runner; refAllDecls forces analysis of
//! every public decl (flow's pattern, adapted: test root lives in src/ so
//! relative imports stay inside the module path).
const std = @import("std");

pub const piece_table = @import("buffer/piece_table.zig");
pub const utf8 = @import("buffer/utf8.zig");
pub const history = @import("buffer/history.zig");
pub const ops = @import("buffer/ops.zig");
pub const fzy = @import("util/fzy.zig");
pub const json_rpc = @import("util/json_rpc.zig");
pub const key_event = @import("editor/key_event.zig");
pub const keymaps = @import("editor/keymaps.zig");
pub const mode = @import("editor/mode.zig");
pub const motion = @import("editor/motion.zig");
pub const ex_command = @import("editor/ex_command.zig");
pub const text_object = @import("editor/text_object.zig");
pub const surround = @import("editor/surround.zig");
pub const comment = @import("editor/comment.zig");
pub const align_text = @import("editor/align.zig");
pub const multicursor = @import("editor/multicursor.zig");
pub const easymotion = @import("editor/easymotion.zig");
pub const fold = @import("editor/fold.zig");
pub const keymap_list = @import("editor/keymap_list.zig");
pub const syntax = @import("syntax.zig");
pub const lsp_server_config = @import("lsp/server_config.zig");
pub const lsp_types = @import("lsp/types.zig");
pub const lsp_client = @import("lsp/client.zig");
pub const lsp_mock = @import("lsp/mock_lsp.zig");
pub const lsp_diagnostics = @import("lsp/diagnostics.zig");
pub const lsp_navigation = @import("lsp/navigation.zig");
pub const icons = @import("icons.zig");
pub const git = @import("git.zig");
pub const term = @import("term.zig");
pub const app_macro = @import("app/macro.zig");
// M2.6a keyboard hints (pure label/target model; app/hint_ui.zig is e2e-tested)
pub const app_hints = @import("app/hints.zig");
// M2b1 navigator tabs + note store (pure; app/notes.zig is e2e-tested)
pub const app_navigator = @import("app/navigator.zig");
pub const app_note_store = @import("app/note_store.zig");
// M2b2 inline assistant (pure request/diff/pending model; app/inline_ui.zig is e2e-tested)
pub const app_inline = @import("app/inline.zig");
// M3b1 staged agent edits (pure args/occurrence/preview/pending model)
pub const app_agent_edit = @import("app/agent_edit.zig");
// M3b tool-metrics chart (pure cell renderer; no App/vaxis dependency)
pub const chart = @import("chart.zig");
// M1 AI chat (pure modules; app/ai.zig is exercised by e2e)
pub const ai_sse = @import("ai/sse.zig");
pub const ai_openai = @import("ai/openai.zig");
pub const ai_context = @import("ai/context.zig");
pub const ai_config = @import("ai/config.zig");
pub const ai_client = @import("ai/client.zig");
pub const ai_panel = @import("ai/panel.zig");
pub const ai_workspace = @import("ai/workspace.zig");
// M3 tool protocol (pure; no execution or App wiring)
pub const ai_tools = @import("ai/tools.zig");
// M3a safe read-only tool executor (filesystem-confined; no App wiring)
pub const ai_tool_exec = @import("ai/tool_exec.zig");
// M3a agent policy/metrics + request-message assembly (pure)
pub const ai_agent = @import("ai/agent.zig");
pub const ai_turn = @import("ai/turn.zig");
// M3a background tool worker (App-side but independent from the editor)
pub const app_tool_job = @import("app/tool_job.zig");

test {
    std.testing.refAllDecls(@This());
}
