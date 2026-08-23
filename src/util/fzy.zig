//! fzy-style fuzzy matcher for the pickers (DESIGN.md D6).
//! Subsequence matching with the classic fzy bonus scoring; ASCII
//! case-insensitive. Pure logic.
//!
//! This is a faithful port of the classic fzy algorithm
//! (github.com/jhawthorn/fzy, src/match.c + src/bonus.h): the same
//! gap/match constants, the same per-character bonus table (word
//! boundaries `/-_.`, camelCase), and the same D/M dynamic program with
//! position backtracking. Deviations from upstream: no MATCH_MAX_LEN cap
//! (pickert haystacks are short file paths) and no SCORE_MAX shortcut for
//! equal-length matches (the DP yields equivalent finite scores).
const std = @import("std");

const Score = f64;

const score_min: Score = -std.math.inf(Score);

// Classic fzy constants (src/config.h).
const gap_leading: Score = -0.005;
const gap_trailing: Score = -0.005;
const gap_inner: Score = -0.01;
const match_consecutive: Score = 1.0;
const match_slash: Score = 0.9;
const match_word: Score = 0.8;
const match_capital: Score = 0.7;
const match_dot: Score = 0.6;

/// ASCII case-insensitive equality.
inline fn eqIgnoreCase(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Bonus for matching haystack[j], derived from haystack[j-1] ("/" slash
/// boundary, "-_ " word boundary, "." dot boundary) and from haystack[j]
/// being uppercase after lowercase (camelCase boundary). Mirrors fzy's
/// bonus_states/bonus_index tables.
fn matchBonus(haystack: []const u8, j: usize) Score {
    const prev: u8 = if (j == 0) '/' else haystack[j - 1];
    const ch = haystack[j];
    // fzy bonus_index: uppercase -> 2, lowercase/digit -> 1, else 0
    const state: u8 = if (std.ascii.isUpper(ch))
        2
    else if (std.ascii.isLower(ch) or std.ascii.isDigit(ch))
        1
    else
        0;
    if (state == 0) return 0;
    const boundary_bonus: Score = switch (prev) {
        '/' => match_slash,
        '-', '_', ' ' => match_word,
        '.' => match_dot,
        else => 0,
    };
    if (boundary_bonus != 0) return boundary_bonus;
    // camelCase: an uppercase char following a lowercase char.
    return if (state == 2 and std.ascii.isLower(prev)) match_capital else 0;
}

/// Score a needle-in-haystack match. Returns null when `needle` is not a
/// subsequence of `haystack` (case-insensitively). Higher is better.
/// `positions` (needle.len entries, allocated with `allocator`) holds the
/// matched haystack indices. Callers must free it with
/// `allocator.free(result.?.positions)`.
pub fn match(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
) !?struct { score: f64, positions: []u32 } {
    const n = needle.len;
    const m = haystack.len;

    // Classic fzy returns SCORE_MIN for an empty needle (never a match).
    if (n == 0) return null;
    if (n > m) return null;

    // D[i*m+j]: best score of matching needle[0..i] with needle[i] matched
    // to haystack[j]. M[i*m+j]: best score of matching needle[0..i] within
    // haystack[0..j]. (Classic fzy's D/M tables.)
    const D = try allocator.alloc(Score, n * m);
    defer allocator.free(D);
    const M = try allocator.alloc(Score, n * m);
    defer allocator.free(M);

    // First needle row: cost = leading gaps up to the match + position bonus.
    {
        var prev_score: Score = score_min;
        const gap: Score = if (n == 1) gap_trailing else gap_inner;
        for (0..m) |j| {
            if (eqIgnoreCase(needle[0], haystack[j])) {
                const score = @as(Score, @floatFromInt(j)) * gap_leading + matchBonus(haystack, j);
                D[j] = score;
                prev_score = @max(score, prev_score + gap);
                M[j] = prev_score;
            } else {
                D[j] = score_min;
                prev_score = prev_score + gap;
                M[j] = prev_score;
            }
        }
    }

    for (1..n) |i| {
        const gap: Score = if (i == n - 1) gap_trailing else gap_inner;
        var prev_score: Score = score_min;
        for (0..m) |j| {
            const di = i * m + j;
            if (eqIgnoreCase(needle[i], haystack[j])) {
                var score: Score = score_min;
                if (j > 0) {
                    // Continue an existing match (gap) or extend a consecutive run.
                    const pm = M[(i - 1) * m + (j - 1)];
                    const pd = D[(i - 1) * m + (j - 1)];
                    score = @max(pm + matchBonus(haystack, j), pd + match_consecutive);
                }
                D[di] = score;
                prev_score = @max(score, prev_score + gap);
                M[di] = prev_score;
            } else {
                D[di] = score_min;
                prev_score = prev_score + gap;
                M[di] = prev_score;
            }
        }
    }

    const result = M[(n - 1) * m + (m - 1)];
    if (result == score_min) return null;

    const positions = try allocator.alloc(u32, n);
    // NOTE: the caller owns `positions`; it must NOT be freed here.

    // Backtrack through D/M to recover the matched haystack positions
    // (same walk as fzy's match_positions).
    var match_required = false;
    var i: i64 = @intCast(n - 1);
    var j: i64 = @intCast(m - 1);
    while (i >= 0) : (i -= 1) {
        while (j >= 0) {
            const ii: usize = @intCast(i);
            const jj: usize = @intCast(j);
            const di = ii * m + jj;
            if (D[di] != score_min and (match_required or D[di] == M[di])) {
                // If this score came from a consecutive match, the previous
                // needle char MUST match the previous haystack char.
                match_required = ii > 0 and jj > 0 and
                    M[di] == D[(ii - 1) * m + (jj - 1)] + match_consecutive;
                positions[ii] = @intCast(jj);
                j -= 1;
                break;
            }
            j -= 1;
        }
    }

    return .{ .score = result, .positions = positions };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectMatch(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    expected_positions: []const u32,
) !void {
    const m = (try match(allocator, haystack, needle)) orelse return error.ExpectedMatch;
    defer allocator.free(m.positions);
    try std.testing.expectEqual(needle.len, m.positions.len);
    try std.testing.expectEqualSlices(u32, expected_positions, m.positions);
}

fn expectNoMatch(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect((try match(allocator, haystack, needle)) == null);
}

fn scoreOf(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) !Score {
    const m = (try match(allocator, haystack, needle)) orelse return error.NoMatch;
    defer allocator.free(m.positions);
    return m.score;
}

test "fzy match basic" {
    const a = std.testing.allocator;

    // exact match
    try expectMatch(a, "abc", "abc", &.{ 0, 1, 2 });
    // plain subsequence
    try expectMatch(a, "axbxc", "abc", &.{ 0, 2, 4 });
    // match at the end
    try expectMatch(a, "xxabc", "abc", &.{ 2, 3, 4 });
    // single char: ties resolve to the latest occurrence (classic fzy backtrace)
    try expectMatch(a, "hello", "l", &.{3});
    // empty haystack
    try expectNoMatch(a, "", "a");
    // needle longer than haystack
    try expectNoMatch(a, "ab", "abc");
    // wrong order
    try expectNoMatch(a, "acb", "abc");
    // missing character
    try expectNoMatch(a, "xyz", "abc");
    // repeated character that cannot be satisfied
    try expectNoMatch(a, "aba", "abba");
    // empty needle: classic fzy never matches it
    try expectNoMatch(a, "anything", "");
}

test "fzy case insensitive" {
    const a = std.testing.allocator;
    try expectMatch(a, "aXbXc", "AbC", &.{ 0, 2, 4 });
    try expectMatch(a, "abc", "ABC", &.{ 0, 1, 2 });
    try expectMatch(a, "ABC", "abc", &.{ 0, 1, 2 });
    try expectMatch(a, "FooBar", "fb", &.{ 0, 3 });
}

test "fzy score ordering" {
    const a = std.testing.allocator;
    // matches starting earlier score higher
    try std.testing.expect((try scoreOf(a, "ab", "ab")) > (try scoreOf(a, "xab", "ab")));
    try std.testing.expect((try scoreOf(a, "abc", "abc")) > (try scoreOf(a, "xabc", "abc")));
    // consecutive matches beat gapped ones
    try std.testing.expect((try scoreOf(a, "ab", "ab")) > (try scoreOf(a, "axb", "ab")));
    // camelCase boundary bonus
    try std.testing.expect((try scoreOf(a, "fooBar", "fb")) > (try scoreOf(a, "foobar", "fb")));
    // word boundary (snake_case) bonus
    try std.testing.expect((try scoreOf(a, "foo_bar", "fb")) > (try scoreOf(a, "foobar", "fb")));
    // path separator bonus
    try std.testing.expect((try scoreOf(a, "foo/bar", "fb")) > (try scoreOf(a, "fooxbar", "fb")));
    // the first character of the haystack is a boundary (initial '/')
    try std.testing.expect((try scoreOf(a, "fb", "fb")) > (try scoreOf(a, "xfb", "fb")));
}

test "fzy positions form a subsequence" {
    const a = std.testing.allocator;
    const pairs = [_][2][]const u8{
        .{ "alarm clock", "am" },
        .{ "src/util/fzy.zig", "fzy" },
        .{ "CamelCaseFile", "ccf" },
        .{ "README.md", "rm" },
        .{ "zzzabcxyz", "abc" },
        .{ "src/buffer/utf8.zig", "utf8" },
    };
    for (pairs) |p| {
        const haystack = p[0];
        const needle = p[1];
        const m = (try match(a, haystack, needle)) orelse return error.ExpectedMatch;
        defer a.free(m.positions);

        try std.testing.expectEqual(needle.len, m.positions.len);
        var prev: u32 = 0;
        for (m.positions, 0..) |pos, k| {
            if (k > 0) try std.testing.expect(pos > prev);
            prev = pos;
            try std.testing.expect(@as(usize, pos) < haystack.len);
            try std.testing.expectEqual(
                std.ascii.toLower(needle[k]),
                std.ascii.toLower(haystack[pos]),
            );
        }
    }
}
