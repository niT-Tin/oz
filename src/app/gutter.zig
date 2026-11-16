//! Shared line-number/sign geometry. Both sides of the sign stay blank,
//! including when diagnostics or git marks are present.
const std = @import("std");

pub const Layout = struct {
    number_columns: u32,
    sign_column: u32,
    show_sign: bool = true,
    width: u32,
};

pub fn forLineCount(line_count: u32) Layout {
    var digits: u32 = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    // [right-aligned digits][space][sign][space][source...]
    return .{ .number_columns = digits, .sign_column = digits + 1, .width = digits + 3 };
}

/// Keep at least one source cell in every nonempty pane. Full numbers are
/// never truncated: narrow panes drop signs/padding, then hide numbers.
/// A blank gutter remains when possible; separators own separate cells in
/// the window layout and never overwrite the numeric field.
pub fn forPane(line_count: u32, pane_width: u32) Layout {
    const full = forLineCount(line_count);
    if (pane_width > full.width) return full;
    const digits = full.number_columns;
    if (pane_width > digits + 1) return .{ .number_columns = digits, .sign_column = 0, .show_sign = false, .width = digits + 1 };
    if (pane_width > digits) return .{ .number_columns = digits, .sign_column = 0, .show_sign = false, .width = digits };
    return .{ .number_columns = 0, .sign_column = 0, .show_sign = false, .width = if (pane_width >= 2) 1 else 0 };
}

test "gutter geometry: numbers and signs have independent padding" {
    const t = std.testing;
    for ([_]u32{ 0, 9, 10, 99, 100, 15000, std.math.maxInt(u32) }, [_]u32{ 1, 1, 2, 2, 3, 5, 10 }) |count, digits| {
        const layout = forLineCount(count);
        try t.expectEqual(digits, layout.number_columns);
        try t.expectEqual(digits + 1, layout.sign_column);
        try t.expectEqual(digits + 3, layout.width);
        // The sign cannot take a digit cell or touch the first source cell.
        try t.expect(layout.sign_column > layout.number_columns);
        try t.expect(layout.sign_column + 1 < layout.width);
    }
}

test "gutter geometry: tiny panes reserve source cells without truncating digits" {
    const t = std.testing;
    for ([_]u32{ 1, 15000, std.math.maxInt(u32) }) |count| {
        for (0..41) |w| {
            const layout = forPane(count, @intCast(w));
            try t.expect(if (w == 0) layout.width == 0 else layout.width < w);
            try t.expect(layout.number_columns == 0 or layout.number_columns == forLineCount(count).number_columns);
            if (layout.show_sign) try t.expect(layout.sign_column + 1 < layout.width);
        }
    }
    try t.expectEqual(@as(u32, 2), forPane(1, 3).width);
    try t.expectEqual(@as(u32, 1), forPane(1, 2).width);
    try t.expectEqual(@as(u32, 0), forPane(1, 1).width);
    try t.expectEqual(@as(u32, 6), forPane(15000, 8).width);
    try t.expectEqual(@as(u32, 1), forPane(15000, 3).width);
    try t.expectEqual(@as(u32, 0), forPane(15000, 3).number_columns);
}
