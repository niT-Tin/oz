#!/usr/bin/env python3
"""Generate benchmark corpus files for oz vs nvim comparisons.

- small.zig   : real dense Zig source (~90KB, syntax-heavy) — copy of DESIGN.md
                style text won't do; we synthesize zig-like token-dense code
- medium.zig  : ~90KB token-dense zig (viewport syntax query is exercised)
- large.log   : ~12MB / ~200k lines mixed line lengths (no syntax, no LSP)
- huge.txt    : ~50MB (pure load benchmark)
"""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))

random.seed(42)

KEYWORDS = ["fn", "const", "var", "if", "else", "while", "for", "return", "pub",
            "struct", "enum", "union", "switch", "case", "break", "continue",
            "defer", "errdefer", "try", "catch", "usingnamespace", "test",
            "comptime", "inline", "noinline", "export", "extern", "volatile",
            "align", "callconv", "linksection", "threadlocal", "suspend",
            "async", "await", "resume", "orelse", "and", "or", "not", "null",
            "undefined", "true", "false"]

IDENTS = ["allocator", "std", "io", "buf", "len", "index", "result", "error",
          "value", "item", "self", "ptr", "slice", "list", "map", "table",
          "count", "size", "offset", "capacity", "arena", "gpa", "c_allocator",
          "ArrayList", "HashMap", "StringHashMap", "AutoHashMap", "Allocator",
          "stdout", "stderr", "stdin", "writeAll", "print", "fmt", "parse",
          "bytes", "utf8", "eql", "indexOf", "contains", "trim", "split",
          "tokenize", "iterator", "next", "deinit", "init", "open", "close",
          "read", "readAll", "fini", "flush", "drain", "peek", "pop", "push",
          "swapRemove", "orderedRemove", "insert", "ensureTotalCapacity",
          "shrinkRetainingCapacity", "expand", "copyForwards", "copyBackwards"]


def zig_fn_body(rng, nlines):
    lines = []
    for _ in range(nlines):
        r = rng.random()
        if r < 0.30:
            kw = rng.choice(KEYWORDS)
            if kw in ("fn", "const", "var", "pub"):
                lines.append(f"    {kw} {rng.choice(IDENTS)}{rng.choice(['', '_2', '_3'])} = {rng.choice(['0', '1', 'null', 'undefined', 'true'])};")
            else:
                lines.append(f"    {kw} {rng.choice(IDENTS)} {{")
        elif r < 0.55:
            lines.append(f"    {rng.choice(IDENTS)}.{rng.choice(IDENTS)}({rng.choice(['a', 'b', 'buf', '&self', 'ptr', 'len', 'n', 'ctx', 'io', 'gpa'])}, {rng.choice(['1', '2', '10', '4096', 'size'])}) catch {rng.choice(['return', 'unreachable', 'continue', 'break', 'null'])};")
        elif r < 0.75:
            lines.append(f"    const {rng.choice(IDENTS)}{rng.choice(['', '_tmp', '_x'])}: [{rng.choice(['4', '8', '16', '32', '64', '256'])}]u8 = undefined;")
        elif r < 0.90:
            lines.append(f"    // {rng.choice(['TODO', 'FIXME', 'NOTE'])}: {rng.choice(IDENTS)} {rng.choice(['needs', 'must', 'should', 'can'])} {rng.choice(['be', 'not'])} {rng.choice(['handled', 'checked', 'fixed', 'freed', 'reset', 'parsed'])}")
        else:
            lines.append("}")
    return lines


def gen_zig(path, total_lines):
    rng = random.Random(7)
    with open(path, "w") as f:
        f.write("//! auto-generated benchmark corpus (zig, token-dense)\n")
        f.write("const std = @import(\"std\");\n\n")
        n = 0
        while n < total_lines:
            nfn = rng.randint(3, 12)
            f.write(f"pub fn {rng.choice(IDENTS)}{rng.randint(0, 99)}(alloc: std.mem.Allocator, {rng.choice(IDENTS)}: usize) !{rng.choice(['void', 'usize', '[]const u8', '!u32'])} {{\n")
            for line in zig_fn_body(rng, nfn):
                f.write(line + "\n")
                n += 1
            f.write("}\n\n")
            n += 1


def gen_log(path, total_bytes, max_line):
    rng = random.Random(11)
    with open(path, "w") as f:
        written = 0
        while written < total_bytes:
            r = rng.random()
            if r < 0.6:
                # short line
                n = rng.randint(10, 60)
            else:
                n = rng.randint(60, max_line)
            line = " ".join(rng.choice(IDENTS + [str(rng.randint(0, 9999))]) for _ in range(n // 6 + 1))
            f.write(line + "\n")
            written += len(line) + 1


def main():
    gen_zig(os.path.join(HERE, "medium.zig"), 2300)  # ~90KB
    # small = first 400 lines of medium
    with open(os.path.join(HERE, "medium.zig")) as f:
        lines = f.readlines()
    with open(os.path.join(HERE, "small.zig"), "w") as f:
        f.writelines(lines[:400])
    gen_log(os.path.join(HERE, "large.log"), 12 * 1024 * 1024, 200)
    gen_log(os.path.join(HERE, "huge.txt"), 50 * 1024 * 1024, 400)
    for name in ("small.zig", "medium.zig", "large.log", "huge.txt"):
        p = os.path.join(HERE, name)
        print(f"{name}: {os.path.getsize(p)/1024/1024:.2f} MiB, {sum(1 for _ in open(p))} lines")


if __name__ == "__main__":
    main()
