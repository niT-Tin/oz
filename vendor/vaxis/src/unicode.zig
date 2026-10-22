const std = @import("std");
const uucode = @import("uucode");

// Old API-compatible Grapheme value
pub const Grapheme = struct {
    start: usize,
    len: usize,

    pub fn bytes(self: Grapheme, str: []const u8) []const u8 {
        return str[self.start .. self.start + self.len];
    }
};

// Old API-compatible iterator that yields Grapheme with .len and .bytes()
pub const GraphemeIterator = struct {
    str: []const u8,
    inner: uucode.grapheme.Iterator(uucode.utf8.Iterator),

    pub fn init(str: []const u8) GraphemeIterator {
        return .{
            .str = str,
            .inner = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str)),
        };
    }

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        const g = self.inner.nextGrapheme() orelse return null;
        return .{ .start = g.start, .len = g.end - g.start };
    }
};

/// creates a grapheme iterator based on str
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return GraphemeIterator.init(str);
}

test "graphemeIterator clusters valid utf8" {
    const str = "a" ++ "e\u{0301}" ++ "👩🏽‍🚀";
    var it = graphemeIterator(str);
    for ([_]usize{ 1, 3, 15 }) |expected_len| {
        const g = it.next().?;
        try std.testing.expectEqual(expected_len, g.len);
    }
    try std.testing.expectEqual(@as(?Grapheme, null), it.next());
}

test "graphemeIterator stays in bounds on invalid utf8" {
    const cases = [_][]const u8{
        "\xA0\xCC\x81", // lone continuation byte, then a combining mark
        "\xFF\xFF\xFF",
        "\xC3\x28", // truncated two-byte sequence
        "\xF0\x9F", // truncated emoji
        "a\xE2\x98", // ascii, then a truncated sequence
    };
    for (cases) |str| {
        var it = graphemeIterator(str);
        var covered: usize = 0;
        while (it.next()) |g| {
            try std.testing.expect(g.len > 0);
            try std.testing.expectEqual(covered, g.start);
            try std.testing.expect(g.start + g.len <= str.len);
            covered = g.start + g.len;
        }
        try std.testing.expectEqual(str.len, covered);
    }
}

test {
    std.testing.refAllDecls(@This());
}
