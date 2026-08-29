//! editor/ — modal editing state machine (pure logic; vaxis only for key types).
pub const KeyEvent = @import("key_event.zig");
pub const Keymaps = @import("keymaps.zig");
pub const Mode = @import("mode.zig");
pub const OpMotion = @import("mode.zig").OpMotion;
pub const Motion = @import("motion.zig");
pub const ex_command = @import("ex_command.zig");
pub const TextObject = @import("text_object.zig");
pub const surround = @import("surround.zig");
pub const comment = @import("comment.zig");
pub const align_text = @import("align.zig");
pub const MultiCursor = @import("multicursor.zig").MultiCursor;
pub const easymotion = @import("easymotion.zig");
pub const fold = @import("fold.zig");
