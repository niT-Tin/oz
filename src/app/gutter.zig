//! Shared line-number/sign geometry. Both sides of the sign stay blank,
//! including when diagnostics or git marks are present.
const std = @import("std");

pub const Layout = struct {
    number_columns: u32,
    sign_column: u32,
    width: u32,
};

pub fn forLineCount(line_count: u32) Layout {
    var digits: u32 = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    // [right-aligned digits][space][sign][space][source...]
    return .{ .number_columns = digits, .sign_column = digits + 1, .width = digits + 3 };
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
