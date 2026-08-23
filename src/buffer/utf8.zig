//! UTF-8 decoding, character boundaries and display widths.
//! Pure logic — no terminal. DESIGN.md §4.2.
const std = @import("std");

pub const Decoded = struct {
    cp: u21,
    len: u8,
};

/// True for UTF-8 continuation bytes (10xxxxxx).
inline fn isCont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Decode the codepoint starting at bytes[i]. Assumes `i < bytes.len`.
/// Invalid sequences decode to U+FFFD with len 1.
pub fn decodeAt(bytes: []const u8, i: usize) Decoded {
    const b0 = bytes[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };

    // Expected sequence length, from the leading byte.
    const n: usize = switch (b0) {
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        // 0x80..0xBF (lone continuation byte) and 0xF5..0xFF are never valid leads.
        else => return .{ .cp = 0xFFFD, .len = 1 },
    };
    if (i + n > bytes.len) return .{ .cp = 0xFFFD, .len = 1 };

    var cp: u21 = switch (n) {
        2 => @as(u21, @intCast(b0 & 0x1F)),
        3 => @as(u21, @intCast(b0 & 0x0F)),
        else => @as(u21, @intCast(b0 & 0x07)),
    };
    for (1..n) |k| {
        const b = bytes[i + k];
        if (!isCont(b)) return .{ .cp = 0xFFFD, .len = 1 };
        cp = (cp << 6) | @as(u21, @intCast(b & 0x3F));
    }

    // Reject overlong encodings and UTF-16 surrogate halves.
    const bad = switch (n) {
        2 => cp < 0x80,
        3 => cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF),
        else => cp < 0x10000 or cp > 0x10FFFF,
    };
    if (bad) return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = @intCast(n) };
}

/// Terminal display width of a codepoint: 0 (combining/control),
/// 1 (narrow), 2 (wide/CJK). East Asian Wide/Fullwidth => 2.
///
/// Pragmatic width tables (per the task contract, not full Unicode):
/// - zero-width: C0/C1 controls, the wcwidth combining-mark ranges,
///   variation selectors, zero-width format characters, Hangul Jamo
///   medial/final vowels and emoji skin tones;
/// - wide: CJK ideographs (+Ext A..G), kana, hangul, CJK symbols and
///   punctuation, fullwidth forms, vertical forms and the emoji planes.
pub fn charWidth(cp: u21) u8 {
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return 0; // C0/C1 controls, DEL
    if (isZeroWidth(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// Zero-width: combining marks, variation selectors and zero-width format
/// characters. Derived from the classic wcwidth combining table plus Cf
/// format chars; a pragmatic subset of Unicode Mn/Me/Cf — missing exotic
/// marks fall back to width 1 (acceptable per the task contract).
fn isZeroWidth(cp: u21) bool {
    return (cp == 0x00AD) or // soft hyphen
        (cp == 0x034F) or // combining grapheme joiner
        (cp == 0x061C) or // arabic letter mark
        (cp == 0xFEFF) or // BOM / zero width no-break space
        (cp >= 0x0300 and cp <= 0x036F) or // combining diacritical marks
        (cp >= 0x0483 and cp <= 0x0489) or // combining cyrillic
        (cp >= 0x0591 and cp <= 0x05C7) or // hebrew points (pragmatic merge)
        (cp >= 0x0610 and cp <= 0x061A) or
        (cp >= 0x064B and cp <= 0x065F) or // arabic harakat
        (cp >= 0x0670 and cp <= 0x0670) or
        (cp >= 0x06D6 and cp <= 0x06ED) or // arabic small signs (pragmatic merge)
        (cp >= 0x0711 and cp <= 0x0711) or
        (cp >= 0x0730 and cp <= 0x074A) or // syriac
        (cp >= 0x07A6 and cp <= 0x07B0) or
        (cp >= 0x07EB and cp <= 0x07F3) or
        (cp >= 0x0816 and cp <= 0x082D) or // samaritan (pragmatic merge)
        (cp >= 0x0859 and cp <= 0x085B) or
        (cp >= 0x08D3 and cp <= 0x0902) or // arabic ext-a + devanagari signs (pragmatic merge)
        (cp >= 0x093A and cp <= 0x093A) or
        (cp >= 0x093C and cp <= 0x093C) or
        (cp >= 0x0941 and cp <= 0x0948) or
        (cp >= 0x094D and cp <= 0x094D) or
        (cp >= 0x0951 and cp <= 0x0957) or
        (cp >= 0x0962 and cp <= 0x0963) or
        (cp >= 0x0981 and cp <= 0x0981) or
        (cp >= 0x09BC and cp <= 0x09BC) or
        (cp >= 0x09C1 and cp <= 0x09C4) or
        (cp >= 0x09CD and cp <= 0x09CD) or
        (cp >= 0x09E2 and cp <= 0x09E3) or
        (cp >= 0x0A01 and cp <= 0x0A02) or
        (cp >= 0x0A3C and cp <= 0x0A3C) or
        (cp >= 0x0A41 and cp <= 0x0A42) or
        (cp >= 0x0A47 and cp <= 0x0A48) or
        (cp >= 0x0A4B and cp <= 0x0A4D) or
        (cp >= 0x0A51 and cp <= 0x0A51) or
        (cp >= 0x0A70 and cp <= 0x0A71) or
        (cp >= 0x0A75 and cp <= 0x0A75) or
        (cp >= 0x0A81 and cp <= 0x0A82) or
        (cp >= 0x0ABC and cp <= 0x0ABC) or
        (cp >= 0x0AC1 and cp <= 0x0AC5) or
        (cp >= 0x0AC7 and cp <= 0x0AC8) or
        (cp >= 0x0ACD and cp <= 0x0ACD) or
        (cp >= 0x0AE2 and cp <= 0x0AE3) or
        (cp >= 0x0AFA and cp <= 0x0AFF) or
        (cp >= 0x0B01 and cp <= 0x0B01) or
        (cp >= 0x0B3C and cp <= 0x0B3C) or
        (cp >= 0x0B3F and cp <= 0x0B3F) or
        (cp >= 0x0B41 and cp <= 0x0B44) or
        (cp >= 0x0B4D and cp <= 0x0B4D) or
        (cp >= 0x0B55 and cp <= 0x0B56) or
        (cp >= 0x0B62 and cp <= 0x0B63) or
        (cp >= 0x0B82 and cp <= 0x0B82) or
        (cp >= 0x0BC0 and cp <= 0x0BC0) or
        (cp >= 0x0BCD and cp <= 0x0BCD) or
        (cp >= 0x0C00 and cp <= 0x0C00) or
        (cp >= 0x0C04 and cp <= 0x0C04) or
        (cp >= 0x0C3E and cp <= 0x0C40) or
        (cp >= 0x0C46 and cp <= 0x0C48) or
        (cp >= 0x0C4A and cp <= 0x0C4D) or
        (cp >= 0x0C55 and cp <= 0x0C56) or
        (cp >= 0x0C62 and cp <= 0x0C63) or
        (cp >= 0x0C81 and cp <= 0x0C81) or
        (cp >= 0x0CBC and cp <= 0x0CBC) or
        (cp >= 0x0CBF and cp <= 0x0CBF) or
        (cp >= 0x0CC6 and cp <= 0x0CC6) or
        (cp >= 0x0CCC and cp <= 0x0CCD) or
        (cp >= 0x0CE2 and cp <= 0x0CE3) or
        (cp >= 0x0D00 and cp <= 0x0D01) or
        (cp >= 0x0D3B and cp <= 0x0D3C) or
        (cp >= 0x0D41 and cp <= 0x0D44) or
        (cp >= 0x0D4D and cp <= 0x0D4D) or
        (cp >= 0x0D62 and cp <= 0x0D63) or
        (cp >= 0x0D81 and cp <= 0x0D81) or
        (cp >= 0x0DCA and cp <= 0x0DCA) or
        (cp >= 0x0DD2 and cp <= 0x0DD4) or
        (cp >= 0x0DD6 and cp <= 0x0DD6) or
        (cp >= 0x0E31 and cp <= 0x0E31) or
        (cp >= 0x0E34 and cp <= 0x0E3A) or
        (cp >= 0x0E47 and cp <= 0x0E4E) or
        (cp >= 0x0EB1 and cp <= 0x0EB1) or
        (cp >= 0x0EB4 and cp <= 0x0EBC) or
        (cp >= 0x0EC8 and cp <= 0x0ECD) or
        (cp >= 0x0F18 and cp <= 0x0F19) or
        (cp >= 0x0F35 and cp <= 0x0F35) or
        (cp >= 0x0F37 and cp <= 0x0F37) or
        (cp >= 0x0F39 and cp <= 0x0F39) or
        (cp >= 0x0F71 and cp <= 0x0F7E) or
        (cp >= 0x0F80 and cp <= 0x0F84) or
        (cp >= 0x0F86 and cp <= 0x0F87) or
        (cp >= 0x0F8D and cp <= 0x0F97) or
        (cp >= 0x0F99 and cp <= 0x0FBC) or
        (cp >= 0x0FC6 and cp <= 0x0FC6) or
        (cp >= 0x102D and cp <= 0x1030) or
        (cp >= 0x1032 and cp <= 0x1037) or
        (cp >= 0x1039 and cp <= 0x103A) or
        (cp >= 0x103D and cp <= 0x103E) or
        (cp >= 0x1058 and cp <= 0x1059) or
        (cp >= 0x105E and cp <= 0x1060) or
        (cp >= 0x1071 and cp <= 0x1074) or
        (cp >= 0x1082 and cp <= 0x1082) or
        (cp >= 0x1085 and cp <= 0x1086) or
        (cp >= 0x108D and cp <= 0x108D) or
        (cp >= 0x109D and cp <= 0x109D) or
        (cp >= 0x1160 and cp <= 0x11FF) or // hangul jamo medial/final (zero per wcwidth)
        (cp >= 0x135D and cp <= 0x135F) or
        (cp >= 0x1712 and cp <= 0x1714) or
        (cp >= 0x1732 and cp <= 0x1733) or
        (cp >= 0x1752 and cp <= 0x1753) or
        (cp >= 0x1772 and cp <= 0x1773) or
        (cp >= 0x17B4 and cp <= 0x17B5) or
        (cp >= 0x17B7 and cp <= 0x17BD) or
        (cp >= 0x17C6 and cp <= 0x17C6) or
        (cp >= 0x17C9 and cp <= 0x17D3) or
        (cp >= 0x17DD and cp <= 0x17DD) or
        (cp >= 0x180B and cp <= 0x180F) or // mongolian free variation selectors
        (cp >= 0x1885 and cp <= 0x1886) or
        (cp >= 0x18A9 and cp <= 0x18A9) or
        (cp >= 0x1920 and cp <= 0x1922) or
        (cp >= 0x1927 and cp <= 0x1928) or
        (cp >= 0x1932 and cp <= 0x1932) or
        (cp >= 0x1939 and cp <= 0x193B) or
        (cp >= 0x1A17 and cp <= 0x1A18) or
        (cp >= 0x1A1B and cp <= 0x1A1B) or
        (cp >= 0x1A56 and cp <= 0x1A56) or
        (cp >= 0x1A58 and cp <= 0x1A5E) or
        (cp >= 0x1A60 and cp <= 0x1A60) or
        (cp >= 0x1A62 and cp <= 0x1A62) or
        (cp >= 0x1A65 and cp <= 0x1A6C) or
        (cp >= 0x1A73 and cp <= 0x1A7C) or
        (cp >= 0x1A7F and cp <= 0x1A7F) or
        (cp >= 0x1AB0 and cp <= 0x1AC0) or
        (cp >= 0x1B00 and cp <= 0x1B03) or
        (cp >= 0x1B34 and cp <= 0x1B34) or
        (cp >= 0x1B36 and cp <= 0x1B3A) or
        (cp >= 0x1B3C and cp <= 0x1B3C) or
        (cp >= 0x1B42 and cp <= 0x1B42) or
        (cp >= 0x1B6B and cp <= 0x1B73) or
        (cp >= 0x1B80 and cp <= 0x1B81) or
        (cp >= 0x1BA2 and cp <= 0x1BA5) or
        (cp >= 0x1BA8 and cp <= 0x1BA9) or
        (cp >= 0x1BAB and cp <= 0x1BAD) or
        (cp >= 0x1BE6 and cp <= 0x1BE6) or
        (cp >= 0x1BE8 and cp <= 0x1BE9) or
        (cp >= 0x1BED and cp <= 0x1BED) or
        (cp >= 0x1BEF and cp <= 0x1BF1) or
        (cp >= 0x1C2C and cp <= 0x1C33) or
        (cp >= 0x1C36 and cp <= 0x1C37) or
        (cp >= 0x1CD0 and cp <= 0x1CD2) or
        (cp >= 0x1CD4 and cp <= 0x1CE0) or
        (cp >= 0x1CE2 and cp <= 0x1CE8) or
        (cp >= 0x1CED and cp <= 0x1CED) or
        (cp >= 0x1CF4 and cp <= 0x1CF4) or
        (cp >= 0x1CF8 and cp <= 0x1CF9) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or // combining diacritical marks supplement
        (cp >= 0x20D0 and cp <= 0x20F0) or // combining marks for symbols
        (cp >= 0x200B and cp <= 0x200F) or // zero width space/joiner + bidi marks
        (cp >= 0x2028 and cp <= 0x202E) or // line/paragraph separators + bidi controls
        (cp >= 0x2060 and cp <= 0x2069) or // word joiner + bidi isolates
        (cp >= 0x2CEF and cp <= 0x2CF1) or
        (cp >= 0x2D7F and cp <= 0x2D7F) or
        (cp >= 0x2DE0 and cp <= 0x2DFF) or
        (cp >= 0x302A and cp <= 0x302D) or // CJK ideographic tone marks
        (cp >= 0x3099 and cp <= 0x309A) or // kana voicing marks
        (cp >= 0x3164 and cp <= 0x3164) or // hangul filler
        (cp >= 0xA66F and cp <= 0xA672) or
        (cp >= 0xA674 and cp <= 0xA67D) or
        (cp >= 0xA69E and cp <= 0xA69F) or
        (cp >= 0xA6F0 and cp <= 0xA6F1) or
        (cp >= 0xA802 and cp <= 0xA802) or
        (cp >= 0xA806 and cp <= 0xA806) or
        (cp >= 0xA80B and cp <= 0xA80B) or
        (cp >= 0xA825 and cp <= 0xA826) or
        (cp >= 0xA8C4 and cp <= 0xA8C4) or
        (cp >= 0xA8E0 and cp <= 0xA8F1) or
        (cp >= 0xA926 and cp <= 0xA92D) or
        (cp >= 0xA947 and cp <= 0xA951) or
        (cp >= 0xA980 and cp <= 0xA982) or
        (cp >= 0xA9B3 and cp <= 0xA9B3) or
        (cp >= 0xA9B6 and cp <= 0xA9B9) or
        (cp >= 0xA9BC and cp <= 0xA9BD) or
        (cp >= 0xA9E5 and cp <= 0xA9E5) or
        (cp >= 0xAA29 and cp <= 0xAA2E) or
        (cp >= 0xAA31 and cp <= 0xAA32) or
        (cp >= 0xAA35 and cp <= 0xAA36) or
        (cp >= 0xAA43 and cp <= 0xAA43) or
        (cp >= 0xAA4C and cp <= 0xAA4C) or
        (cp >= 0xAA7C and cp <= 0xAA7C) or
        (cp >= 0xAAB0 and cp <= 0xAAB0) or
        (cp >= 0xAAB2 and cp <= 0xAAB4) or
        (cp >= 0xAAB7 and cp <= 0xAAB8) or
        (cp >= 0xAABE and cp <= 0xAABF) or
        (cp >= 0xAAC1 and cp <= 0xAAC1) or
        (cp >= 0xAAEC and cp <= 0xAAED) or
        (cp >= 0xAAF6 and cp <= 0xAAF6) or
        (cp >= 0xABE5 and cp <= 0xABE5) or
        (cp >= 0xABE8 and cp <= 0xABE8) or
        (cp >= 0xABED and cp <= 0xABED) or
        (cp >= 0xFB1E and cp <= 0xFB1E) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or // variation selectors
        (cp >= 0xFE20 and cp <= 0xFE2F) or // combining half marks
        (cp >= 0xFFA0 and cp <= 0xFFA0) or // halfwidth hangul filler
        (cp >= 0xFFF9 and cp <= 0xFFFB) or // interlinear annotation anchors
        (cp >= 0x101FD and cp <= 0x101FD) or
        (cp >= 0x102E0 and cp <= 0x102E0) or
        (cp >= 0x10376 and cp <= 0x1037A) or
        (cp >= 0x10A01 and cp <= 0x10A0F) or
        (cp >= 0x10A38 and cp <= 0x10A3A) or
        (cp >= 0x10A3F and cp <= 0x10A3F) or
        (cp >= 0x10AE5 and cp <= 0x10AE6) or
        (cp >= 0x11001 and cp <= 0x11001) or
        (cp >= 0x11038 and cp <= 0x11046) or
        (cp >= 0x1107F and cp <= 0x11081) or
        (cp >= 0x110B3 and cp <= 0x110B6) or
        (cp >= 0x110B9 and cp <= 0x110BA) or
        (cp >= 0x11100 and cp <= 0x11102) or
        (cp >= 0x11127 and cp <= 0x1112B) or
        (cp >= 0x1112D and cp <= 0x11134) or
        (cp >= 0x11173 and cp <= 0x11173) or
        (cp >= 0x11180 and cp <= 0x11181) or
        (cp >= 0x111B6 and cp <= 0x111BE) or
        (cp >= 0x111C9 and cp <= 0x111CC) or
        (cp >= 0x1122F and cp <= 0x11231) or
        (cp >= 0x11234 and cp <= 0x11234) or
        (cp >= 0x11236 and cp <= 0x11237) or
        (cp >= 0x1123E and cp <= 0x1123E) or
        (cp >= 0x112DF and cp <= 0x112DF) or
        (cp >= 0x112E3 and cp <= 0x112EA) or
        (cp >= 0x11300 and cp <= 0x11301) or
        (cp >= 0x1133C and cp <= 0x1133C) or
        (cp >= 0x11340 and cp <= 0x11340) or
        (cp >= 0x11366 and cp <= 0x1136C) or
        (cp >= 0x11370 and cp <= 0x11374) or
        (cp >= 0x11438 and cp <= 0x1143F) or
        (cp >= 0x11442 and cp <= 0x11444) or
        (cp >= 0x11446 and cp <= 0x11446) or
        (cp >= 0x114B3 and cp <= 0x114B8) or
        (cp >= 0x114BA and cp <= 0x114BA) or
        (cp >= 0x114BF and cp <= 0x114C0) or
        (cp >= 0x114C2 and cp <= 0x114C3) or
        (cp >= 0x115B2 and cp <= 0x115B5) or
        (cp >= 0x115BC and cp <= 0x115BD) or
        (cp >= 0x115BF and cp <= 0x115C0) or
        (cp >= 0x115DC and cp <= 0x115DD) or
        (cp >= 0x11633 and cp <= 0x1163A) or
        (cp >= 0x1163D and cp <= 0x1163D) or
        (cp >= 0x1163F and cp <= 0x11640) or
        (cp >= 0x116AB and cp <= 0x116AB) or
        (cp >= 0x116AD and cp <= 0x116AD) or
        (cp >= 0x116B0 and cp <= 0x116B5) or
        (cp >= 0x116B7 and cp <= 0x116B7) or
        (cp >= 0x1171D and cp <= 0x1171F) or
        (cp >= 0x11722 and cp <= 0x11725) or
        (cp >= 0x11727 and cp <= 0x1172B) or
        (cp >= 0x1182F and cp <= 0x11837) or
        (cp >= 0x11839 and cp <= 0x1183A) or
        (cp >= 0x11A01 and cp <= 0x11A0A) or
        (cp >= 0x11A33 and cp <= 0x11A38) or
        (cp >= 0x11A3B and cp <= 0x11A3E) or
        (cp >= 0x11A47 and cp <= 0x11A47) or
        (cp >= 0x11A51 and cp <= 0x11A56) or
        (cp >= 0x11A59 and cp <= 0x11A5B) or
        (cp >= 0x11A8A and cp <= 0x11A96) or
        (cp >= 0x11A98 and cp <= 0x11A99) or
        (cp >= 0x11C30 and cp <= 0x11C36) or
        (cp >= 0x11C38 and cp <= 0x11C3D) or
        (cp >= 0x11C3F and cp <= 0x11C3F) or
        (cp >= 0x11C92 and cp <= 0x11CA7) or
        (cp >= 0x11CAA and cp <= 0x11CB0) or
        (cp >= 0x11CB2 and cp <= 0x11CB3) or
        (cp >= 0x11CB5 and cp <= 0x11CB6) or
        (cp >= 0x11D31 and cp <= 0x11D36) or
        (cp >= 0x11D3A and cp <= 0x11D3A) or
        (cp >= 0x11D3C and cp <= 0x11D3D) or
        (cp >= 0x11D3F and cp <= 0x11D45) or
        (cp >= 0x11D47 and cp <= 0x11D47) or
        (cp >= 0x11D90 and cp <= 0x11D91) or
        (cp >= 0x11D95 and cp <= 0x11D95) or
        (cp >= 0x11D97 and cp <= 0x11D97) or
        (cp >= 0x11EF3 and cp <= 0x11EF4) or
        (cp >= 0x16AF0 and cp <= 0x16AF4) or
        (cp >= 0x16B30 and cp <= 0x16B36) or
        (cp >= 0x16F8F and cp <= 0x16F92) or
        (cp >= 0x1BC9D and cp <= 0x1BC9E) or
        (cp >= 0x1D165 and cp <= 0x1D169) or
        (cp >= 0x1D16D and cp <= 0x1D172) or
        (cp >= 0x1D17B and cp <= 0x1D182) or
        (cp >= 0x1D185 and cp <= 0x1D18B) or
        (cp >= 0x1D1AA and cp <= 0x1D1AD) or
        (cp >= 0x1D242 and cp <= 0x1D244) or
        (cp >= 0x1DA00 and cp <= 0x1DA36) or
        (cp >= 0x1DA3B and cp <= 0x1DA6C) or
        (cp >= 0x1DA75 and cp <= 0x1DA75) or
        (cp >= 0x1DA84 and cp <= 0x1DA84) or
        (cp >= 0x1DA9B and cp <= 0x1DA9F) or
        (cp >= 0x1DAA1 and cp <= 0x1DAAF) or
        (cp >= 0x1E000 and cp <= 0x1E02A) or
        (cp >= 0x1E8D0 and cp <= 0x1E8D6) or
        (cp >= 0x1E944 and cp <= 0x1E94A) or
        (cp >= 0x1F3FB and cp <= 0x1F3FF) or // emoji skin tone modifiers
        (cp >= 0xE0100 and cp <= 0xE01EF); // variation selectors supplement
}

/// East Asian Wide / Fullwidth codepoints => 2 columns. Pragmatic:
/// mirrors the classic wcwidth wide table plus the newer emoji planes and
/// CJK Extensions B..G.
fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or // hangul jamo (initial consonants)
        (cp >= 0x2329 and cp <= 0x232A) or // 〈 〉
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK radicals, kangxi, symbols, punctuation
        (cp >= 0x3041 and cp <= 0x33FF) or // hiragana, katakana, CJK symbols, enclosed
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK unified ideographs extension A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK unified ideographs
        (cp >= 0xA000 and cp <= 0xA4CF) or // yi
        (cp >= 0xA960 and cp <= 0xA97F) or // hangul jamo extended-A
        (cp >= 0xAC00 and cp <= 0xD7A3) or // hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compatibility ideographs
        (cp >= 0xFE10 and cp <= 0xFE19) or // vertical forms
        (cp >= 0xFE30 and cp <= 0xFE52) or
        (cp >= 0xFE54 and cp <= 0xFE66) or
        (cp >= 0xFE68 and cp <= 0xFE6B) or // CJK compatibility forms / small forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // fullwidth forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // fullwidth signs
        (cp >= 0x1F000 and cp <= 0x1FAFF) or // mahjong/cards/enclosed/regional indicators/emoji
        (cp >= 0x20000 and cp <= 0x2FA1F) or // CJK ext B..F + compatibility supplement
        (cp >= 0x30000 and cp <= 0x3134F); // CJK extension G
}

/// Display width of the codepoint at bytes[i].
pub fn charWidthAt(bytes: []const u8, i: usize) u8 {
    return charWidth(decodeAt(bytes, i).cp);
}

/// Start offset of the character containing byte position `p` (0 <= p < len).
/// Robust for invalid bytes: a run of continuation bytes that is not consumed
/// by a valid leading byte is treated as one character.
fn charStart(bytes: []const u8, p: usize) usize {
    var s = p;
    while (s > 0 and isCont(bytes[s])) s -= 1;
    if (isCont(bytes[s])) return 0; // bytes[0..p] is one run of continuation bytes
    const end = s + decodeAt(bytes, s).len;
    // If p sits beyond the character at `s`, it belongs to the orphan
    // continuation run that starts at `end`.
    return if (end > p) s else end;
}

/// End offset (exclusive) of the character containing byte position `p`.
fn charEnd(bytes: []const u8, p: usize) usize {
    const s = charStart(bytes, p);
    if (!isCont(bytes[s])) return s + decodeAt(bytes, s).len;
    // Orphan continuation run: extend to the last consecutive continuation byte.
    var j = s;
    while (j < bytes.len and isCont(bytes[j])) j += 1;
    return j;
}

/// Index of the previous character boundary strictly before `i`.
/// Returns 0 when none. `i` must be <= bytes.len.
pub fn prevBoundary(bytes: []const u8, i: usize) usize {
    if (i == 0) return 0;
    return charStart(bytes, i - 1);
}

/// Index of the next character boundary strictly after `i`.
/// Returns bytes.len when none. `i` must be <= bytes.len.
pub fn nextBoundary(bytes: []const u8, i: usize) usize {
    if (i >= bytes.len) return bytes.len;
    return charEnd(bytes, i);
}

/// Number of codepoints in bytes[0..len].
pub fn count(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        i = nextBoundary(bytes, i);
        n += 1;
    }
    return n;
}

/// True if `i` is on a character boundary (0 and bytes.len always are).
pub fn isBoundary(bytes: []const u8, i: usize) bool {
    if (i == 0 or i == bytes.len) return true;
    return charStart(bytes, i) == i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "utf8 decode ascii and multibyte" {
    const a = decodeAt("abc", 0);
    try std.testing.expectEqual(@as(u21, 'a'), a.cp);
    try std.testing.expectEqual(@as(u8, 1), a.len);

    // é = U+00E9 (2 bytes)
    const e = decodeAt("\xC3\xA9", 0);
    try std.testing.expectEqual(@as(u21, 0xE9), e.cp);
    try std.testing.expectEqual(@as(u8, 2), e.len);

    // € = U+20AC (3 bytes)
    const euro = decodeAt("\xE2\x82\xAC", 0);
    try std.testing.expectEqual(@as(u21, 0x20AC), euro.cp);
    try std.testing.expectEqual(@as(u8, 3), euro.len);

    // 中 = U+4E2D (3 bytes)
    const zh = decodeAt("\xE4\xB8\xAD", 0);
    try std.testing.expectEqual(@as(u21, 0x4E2D), zh.cp);
    try std.testing.expectEqual(@as(u8, 3), zh.len);

    // 𝄞 = U+1D11E (4 bytes)
    const mus = decodeAt("\xF0\x9D\x84\x9E", 0);
    try std.testing.expectEqual(@as(u21, 0x1D11E), mus.cp);
    try std.testing.expectEqual(@as(u8, 4), mus.len);

    // non-zero offset
    const zh2 = decodeAt("a\xE4\xB8\xADb", 1);
    try std.testing.expectEqual(@as(u21, 0x4E2D), zh2.cp);
    try std.testing.expectEqual(@as(u8, 3), zh2.len);
}

test "utf8 decode invalid sequences" {
    // lone continuation byte
    const d1 = decodeAt("\x80", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d1.cp);
    try std.testing.expectEqual(@as(u8, 1), d1.len);

    // invalid leading byte 0xFF
    const d2 = decodeAt("\xFF", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d2.cp);

    // overlong 2-byte (C0 AF would decode to U+002F)
    const d3 = decodeAt("\xC0\xAF", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d3.cp);

    // overlong 3-byte (E0 80 80)
    const d4 = decodeAt("\xE0\x80\x80", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d4.cp);

    // UTF-16 surrogate half (ED A0 80 = U+D800)
    const d5 = decodeAt("\xED\xA0\x80", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d5.cp);

    // above U+10FFFF (F4 90 80 80 = U+110000)
    const d6 = decodeAt("\xF4\x90\x80\x80", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d6.cp);

    // truncated sequence at the end of the buffer
    const d7 = decodeAt("\xE4\xB8", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d7.cp);
    try std.testing.expectEqual(@as(u8, 1), d7.len);

    // non-continuation byte where a continuation is expected
    const d8 = decodeAt("\xE4\x41", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d8.cp);
    try std.testing.expectEqual(@as(u8, 1), d8.len);

    // the last surrogate half (ED BF BF = U+DFFF) is also invalid
    const d9 = decodeAt("\xED\xBF\xBF", 0);
    try std.testing.expectEqual(@as(u21, 0xFFFD), d9.cp);
}

test "utf8 char width" {
    // narrow
    try std.testing.expectEqual(@as(u8, 1), charWidth('a'));
    try std.testing.expectEqual(@as(u8, 1), charWidth('Z'));
    try std.testing.expectEqual(@as(u8, 1), charWidth('0'));
    try std.testing.expectEqual(@as(u8, 1), charWidth(' '));
    try std.testing.expectEqual(@as(u8, 1), charWidth(0xA0)); // NBSP
    try std.testing.expectEqual(@as(u8, 1), charWidth(0xFF61)); // halfwidth ｡

    // wide (CJK / kana / hangul / fullwidth)
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x4E2D)); // 中
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x3000)); // ideographic space
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x3001)); // 、
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x3042)); // あ
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x30A2)); // ア
    try std.testing.expectEqual(@as(u8, 2), charWidth(0xAC00)); // 가
    try std.testing.expectEqual(@as(u8, 2), charWidth(0xFF01)); // ！
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x20000)); // CJK ext B
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x1F600)); // emoji 😀

    // zero width: controls, combining, zero-width formats, jamo, skin tones
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x09)); // tab (control)
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x0A)); // newline (control)
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x7F)); // DEL
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x80)); // C1 control
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x200B)); // zero width space
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x200D)); // zero width joiner
    try std.testing.expectEqual(@as(u8, 0), charWidth(0xFE0F)); // variation selector-16
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x3099)); // kana combining dakuten
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x1160)); // hangul jamo medial
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x1F3FB)); // emoji skin tone

    // charWidthAt over "e" + U+0301 + 中: 1 + 0 + 2 columns
    const s = "e\xCC\x81\xE4\xB8\xAD";
    try std.testing.expectEqual(@as(u8, 1), charWidthAt(s, 0));
    try std.testing.expectEqual(@as(u8, 0), charWidthAt(s, 1));
    try std.testing.expectEqual(@as(u8, 2), charWidthAt(s, 3));
}

test "utf8 boundaries ascii" {
    const s = "abc";
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 2), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 2), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), count(s));
    try std.testing.expectEqual(@as(usize, 0), count(""));
    try std.testing.expect(isBoundary(s, 0));
    try std.testing.expect(isBoundary(s, 1));
    try std.testing.expect(isBoundary(s, 2));
    try std.testing.expect(isBoundary(s, 3));
}

test "utf8 boundaries multibyte" {
    // "a中b": 61 E4 B8 AD 62
    const s = "a\xE4\xB8\xADb";
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 5), nextBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 5), nextBoundary(s, 5));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 4), prevBoundary(s, 5));
    try std.testing.expectEqual(@as(usize, 3), count(s));
    try std.testing.expect(isBoundary(s, 0));
    try std.testing.expect(isBoundary(s, 1));
    try std.testing.expect(!isBoundary(s, 2));
    try std.testing.expect(!isBoundary(s, 3));
    try std.testing.expect(isBoundary(s, 4));
    try std.testing.expect(isBoundary(s, 5));

    // moving from inside a valid multibyte char is robust: next/prev still
    // land on the enclosing character's boundaries
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
}

test "utf8 boundaries invalid bytes" {
    // orphan continuation run: "a" + 80 80 + "b" is 3 characters:
    // 'a' [0,1), the run [1,3), 'b' [3,4)
    const s = "a\x80\x80b";
    try std.testing.expectEqual(@as(usize, 3), count(s));
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1)); // run end
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 2)); // mid-run
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 2)); // run start
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(s, 4));
    try std.testing.expect(isBoundary(s, 1));
    try std.testing.expect(!isBoundary(s, 2));
    try std.testing.expect(isBoundary(s, 3));

    // leading continuation run
    const t = "\x80\x80x";
    try std.testing.expectEqual(@as(usize, 2), count(t));
    try std.testing.expectEqual(@as(usize, 2), nextBoundary(t, 0));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(t, 1));
    try std.testing.expect(isBoundary(t, 2));
    try std.testing.expect(!isBoundary(t, 1));

    // truncated valid lead: E4 B8 (missing third byte) => FFFD + orphan cont
    const u = "\xE4\xB8";
    try std.testing.expectEqual(@as(usize, 2), count(u));
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(u, 0));
    try std.testing.expectEqual(@as(usize, 2), nextBoundary(u, 1));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(u, 1));
    try std.testing.expect(isBoundary(u, 1));

    // invalid lead followed by a valid multibyte char
    const v = "\xFF\xE4\xB8\xAD";
    try std.testing.expectEqual(@as(usize, 2), count(v));
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(v, 0));
    try std.testing.expectEqual(@as(usize, 4), nextBoundary(v, 1));
}

test "utf8 boundary roundtrip" {
    const cases = [_][]const u8{
        "abc",
        "a\xE4\xB8\xADb",
        "\xE4\xB8\xAD\xE5\x9B\xBD\xE4\xBA\xBA", // 中国人
        "a\x80\x80b",
        "\x80\x80x",
        "\xE4\xB8",
        "\xC3\xA9e\xCC\x81", // é + e + combining acute
        "",
    };
    for (cases) |s| {
        // forward: on every boundary, prevBoundary(nextBoundary(i)) == i
        var i: usize = 0;
        while (i < s.len) {
            const nb = nextBoundary(s, i);
            try std.testing.expect(nb > i);
            try std.testing.expectEqual(i, prevBoundary(s, nb));
            i = nb;
        }
        // backward: on every boundary, nextBoundary(prevBoundary(j)) == j
        var j = s.len;
        while (true) {
            const pb = prevBoundary(s, j);
            try std.testing.expectEqual(j, nextBoundary(s, pb));
            if (pb == 0) break;
            j = pb;
        }
    }
}

test "utf8 count and total width" {
    // e + combining acute + 中 = 3 codepoints, 1 + 0 + 2 = 3 columns
    const s = "e\xCC\x81\xE4\xB8\xAD";
    try std.testing.expectEqual(@as(usize, 3), count(s));

    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i = nextBoundary(s, i)) {
        cols += charWidthAt(s, i);
    }
    try std.testing.expectEqual(@as(usize, 3), cols);
}
