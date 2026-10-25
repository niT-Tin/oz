//! AI chat (M1): OpenAI-compatible streaming chat completions.
//!
//! Pure submodules have no App dependency:
//!   - sse.zig     incremental Server-Sent Events parser
//!   - openai.zig  request body / delta / error-body wire format
//!   - context.zig bounded editor context (path, selection, cursor window)
//!   - config.zig  environment configuration
//!   - client.zig  one in-flight background stream (HTTP or the test seam)
//!   - panel.zig   prompt/rail key classification
//!   - workspace.zig rail layout, focus policy, multi-thread session model
//!   - tools.zig   M3 tool definitions/streaming wire format + permission policy
pub const sse = @import("sse.zig");
pub const openai = @import("openai.zig");
pub const context = @import("context.zig");
pub const config = @import("config.zig");
pub const client = @import("client.zig");
pub const panel = @import("panel.zig");
pub const workspace = @import("workspace.zig");
pub const tools = @import("tools.zig");
