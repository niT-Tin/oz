//! buffer/ — document storage and editing primitives (pure logic, no terminal).
pub const PieceTable = @import("piece_table.zig").PieceTable;
pub const History = @import("history.zig").History;
pub const utf8 = @import("utf8.zig");
pub const ops = @import("ops.zig");
