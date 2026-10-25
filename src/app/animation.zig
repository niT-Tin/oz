//! Pure time-based animation primitives (DESIGN.md §18.12).
//!
//! The TUI animates only while something is actually happening: an AI thread
//! is streaming, a tool batch is running, or a short badge flash is still
//! inside its deadline. There is no idle timer and no unconditional redraw.
//! All functions here take an explicit monotonic `now_ms` and return values
//! by value, so their behaviour is unit-testable without a terminal, clock,
//! or allocation, and a frame can compute one timestamp for every animated
//! element.
//!
//! The visual language mirrors the approved web demo's `dot-pulse`,
//! `running-pulse`, `badge-pop` and `caret-blink`, translated to terminal
//! cells: colour is interpolated between two palette slots (no opacity), the
//! running-tool glyph cycles `| / - \`, and short flashes have a hard
//! deadline that the run loop can query to stop polling.
//!
//! Negative wall-clock values (a clock adjustment) are wrapped with
//! `@divFloor`/`@mod` so a phase is always in range; animation never panics
//! on a hostile clock.

const std = @import("std");
const theme = @import("../theme.zig");

/// One `| / - \` spinner step. 120ms matches the demo's compact running
/// indicator and stays readable at the 16ms render cadence.
pub const spinner_step_ms: i64 = 120;
pub const spinner_glyphs = [_][]const u8{ "|", "/", "-", "\\" };

/// Streaming status pulse. Slow enough to read (`dot-pulse` is 1.4–1.6s in
/// the demo), fast enough that two adjacent frames can differ for tests.
pub const stream_pulse_ms: i64 = 900;

/// Badge flash after a Changes count changes (demo `badge-pop`, 240ms;
/// terminal colour needs a little longer to be perceptible).
pub const badge_flash_ms: i64 = 420;

/// Caret blink period (hardware cursor stays as-is; this is for any future
/// soft caret). 1.05s mirrors the demo.
pub const caret_blink_ms: i64 = 1050;

/// Non-negative remainder of `now_ms` modulo `period_ms`. Returns 0 for a
/// non-positive period instead of dividing by zero.
pub fn wrapMs(now_ms: i64, period_ms: i64) i64 {
    if (period_ms <= 0) return 0;
    return @mod(now_ms, period_ms);
}

/// Triangle wave 0..255: 0 at phase 0, 255 at the half period, back to 0.
/// Integer-only, symmetric, and independent of the absolute clock.
pub fn triangle(now_ms: i64, period_ms: i64) u8 {
    const period = if (period_ms <= 1) 1 else period_ms;
    const p = wrapMs(now_ms, period);
    const half = @divTrunc(period, 2);
    if (half == 0) return 0;
    const up = if (p <= half) p else period - p;
    return @intCast(@divTrunc(up * 255, half));
}

/// Square pulse: true for the first half of the period. Useful when a
/// visibility toggle reads better than a colour interpolation.
pub fn pulseOn(now_ms: i64, period_ms: i64) bool {
    if (period_ms <= 0) return false;
    return wrapMs(now_ms, period_ms) < @divTrunc(period_ms, 2);
}

/// `| / - \` spinner glyph for `now_ms`. Deterministic, one cell, ASCII.
pub fn spinnerGlyph(now_ms: i64) []const u8 {
    const step = @divFloor(now_ms, spinner_step_ms);
    const idx: usize = @intCast(@mod(step, @as(i64, spinner_glyphs.len)));
    return spinner_glyphs[idx];
}

/// True while `now_ms` is inside `[start_ms, start_ms + duration_ms)`.
/// A negative duration, or a start sentinel <= 0, is inactive. Callers use
/// this to stop polling after a flash: once it returns false, no frame needs
/// to be drawn for it.
pub fn flashActive(start_ms: i64, now_ms: i64, duration_ms: i64) bool {
    if (duration_ms <= 0 or start_ms <= 0) return false;
    if (now_ms < start_ms) return false;
    return now_ms - start_ms < duration_ms;
}

/// Linear 0..255 progress through a flash deadline (0 outside the window).
/// The first flash frames can tint the badge, then it settles to the normal
/// style without a second timer.
pub fn flashProgress(start_ms: i64, now_ms: i64, duration_ms: i64) u8 {
    if (!flashActive(start_ms, now_ms, duration_ms)) return 0;
    const elapsed = now_ms - start_ms;
    return @intCast(@divTrunc(elapsed * 255, duration_ms));
}

/// Blend two RGB values. `t = 0` is `a`, `t = 255` is `b`; integer math keeps
/// the result deterministic across hosts.
pub fn blend(a: theme.Rgb, b: theme.Rgb, t: u8) theme.Rgb {
    const tt: u32 = t;
    const inv: u32 = 255 - tt;
    return .{
        @intCast((@as(u32, a[0]) * inv + @as(u32, b[0]) * tt) / 255),
        @intCast((@as(u32, a[1]) * inv + @as(u32, b[1]) * tt) / 255),
        @intCast((@as(u32, a[2]) * inv + @as(u32, b[2]) * tt) / 255),
    };
}

/// Pulses between two palette slots over `period_ms` (triangle wave).
pub fn pulseColor(a: theme.Rgb, b: theme.Rgb, now_ms: i64, period_ms: i64) theme.Rgb {
    return blend(a, b, triangle(now_ms, period_ms));
}

/// Caret visibility for a soft caret (first half on, demo `caret-blink`).
pub fn caretVisible(now_ms: i64) bool {
    return pulseOn(now_ms, caret_blink_ms);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectRgb(actual: theme.Rgb, expected: theme.Rgb) !void {
    try std.testing.expectEqual(expected, actual);
}

test "animation: wrap handles negative clocks and zero periods" {
    try std.testing.expectEqual(@as(i64, 0), wrapMs(0, 100));
    try std.testing.expectEqual(@as(i64, 42), wrapMs(142, 100));
    try std.testing.expectEqual(@as(i64, 58), wrapMs(-42, 100));
    try std.testing.expectEqual(@as(i64, 0), wrapMs(42, 0));
    try std.testing.expectEqual(@as(i64, 0), wrapMs(42, -5));
}

test "animation: triangle pulses to 255 at half period and returns" {
    try std.testing.expectEqual(@as(u8, 0), triangle(0, 100));
    try std.testing.expectEqual(@as(u8, 127), triangle(25, 100));
    try std.testing.expectEqual(@as(u8, 255), triangle(50, 100));
    try std.testing.expectEqual(@as(u8, 127), triangle(75, 100));
    try std.testing.expectEqual(@as(u8, 0), triangle(100, 100));
    // Always in range, including a hostile negative timestamp.
    var t: i64 = -500;
    while (t <= 500) : (t += 7) try std.testing.expect(triangle(t, 90) <= 255);
}

test "animation: spinner cycles four ASCII glyphs deterministically" {
    try std.testing.expectEqualStrings("|", spinnerGlyph(0));
    try std.testing.expectEqualStrings("/", spinnerGlyph(spinner_step_ms));
    try std.testing.expectEqualStrings("-", spinnerGlyph(spinner_step_ms * 2));
    try std.testing.expectEqualStrings("\\", spinnerGlyph(spinner_step_ms * 3));
    try std.testing.expectEqualStrings("|", spinnerGlyph(spinner_step_ms * 4));
    // Negative times stay in the table and never index out of bounds.
    try std.testing.expectEqualStrings("\\", spinnerGlyph(-spinner_step_ms));
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const g = spinnerGlyph(@intCast(i * 33));
        try std.testing.expect(g.len == 1);
    }
}

test "animation: flash deadline is explicit and expires" {
    try std.testing.expect(!flashActive(0, 10, 100)); // sentinel
    try std.testing.expect(!flashActive(100, 99, 100)); // before start
    try std.testing.expect(flashActive(100, 100, 100));
    try std.testing.expect(flashActive(100, 199, 100));
    try std.testing.expect(!flashActive(100, 200, 100)); // exact deadline
    try std.testing.expect(!flashActive(100, 1000, 0));
    try std.testing.expectEqual(@as(u8, 0), flashProgress(100, 200, 100));
    try std.testing.expect(flashProgress(100, 150, 100) >= 126);
    try std.testing.expect(flashProgress(100, 101, 100) <= 3);
}

test "animation: colours blend by channel and clamp endpoints" {
    const a = theme.Rgb{ 0x10, 0x20, 0x30 };
    const b = theme.Rgb{ 0x20, 0x40, 0x60 };
    try expectRgb(a, blend(a, b, 0));
    try expectRgb(b, blend(a, b, 255));
    const mid = blend(a, b, 128);
    try std.testing.expect(mid[0] > a[0] and mid[0] < b[0]);
    try std.testing.expect(mid[1] > a[1] and mid[1] < b[1]);
    try std.testing.expect(mid[2] > a[2] and mid[2] < b[2]);
    // Pulse endpoints and midpoint derive from the same blend.
    try expectRgb(a, pulseColor(a, b, 0, 100));
    try expectRgb(b, pulseColor(a, b, 50, 100));
    try expectRgb(a, pulseColor(a, b, 100, 100));
}

test "animation: pulse and caret toggles are pure" {
    try std.testing.expect(pulseOn(0, 100));
    try std.testing.expect(!pulseOn(50, 100));
    try std.testing.expect(pulseOn(100, 100));
    try std.testing.expect(!pulseOn(10, 0));
    try std.testing.expect(caretVisible(0));
    try std.testing.expect(!caretVisible(caret_blink_ms / 2));
}
