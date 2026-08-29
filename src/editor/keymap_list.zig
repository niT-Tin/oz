//! Compile-time keymap reference table for the <leader>sk keymap-search
//! picker (DESIGN.md §10: 配置即代码). One flat list of human-readable
//! bindings, grouped by function; the picker renders `keys` and filters on
//! "keys desc" via fzy.
//!
//! Display conventions (the renderer parses `keys` as space-separated tokens):
//! - plain keys: "h" "K" "gd" "gcc" "jk"
//! - Ctrl keys: "ctrl-u" "ctrl-w h" "ctrl-v" "ctrl-n"
//! - leader chords: first token is "space": "space e" "space sf" "space sk"
//! - Ex commands start with ':': ":w" ":vs" ":q"
//!   ("space" / "ctrl-*" / ":*" tokens render with the prefix color; the
//!   rest with the key color.)
//!
//! Every entry below was verified against the live keymaps / mode state
//! machine / ex-command parser before being written (see keymaps.zig,
//! mode.zig, ex_command.zig, main.zig). Nothing speculative is listed.
const std = @import("std");
const fzy = @import("../util/fzy.zig");
const KeyEvent = @import("key_event.zig");

/// 一条键位：keys 是显示串，desc 是中文描述，group 是分组名。
pub const Entry = struct {
    keys: []const u8,
    desc: []const u8,
    group: []const u8,
};

pub const entries: []const Entry = &.{
    // ---- 移动 ----
    .{ .keys = "h", .desc = "左移一个字符", .group = "移动" },
    .{ .keys = "j", .desc = "下移一行", .group = "移动" },
    .{ .keys = "k", .desc = "上移一行", .group = "移动" },
    .{ .keys = "l", .desc = "右移一个字符", .group = "移动" },
    .{ .keys = "w", .desc = "下一个词首", .group = "移动" },
    .{ .keys = "e", .desc = "下一个词尾", .group = "移动" },
    .{ .keys = "b", .desc = "上一个词首", .group = "移动" },
    .{ .keys = "ge", .desc = "上一个词尾", .group = "移动" },
    .{ .keys = "^", .desc = "行首（第一个非空白字符）", .group = "移动" },
    .{ .keys = "0", .desc = "行首（第 0 列）", .group = "移动" },
    .{ .keys = "$", .desc = "行尾", .group = "移动" },
    .{ .keys = "{", .desc = "上一段落", .group = "移动" },
    .{ .keys = "}", .desc = "下一段落", .group = "移动" },
    .{ .keys = "%", .desc = "跳到匹配的括号", .group = "移动" },
    .{ .keys = "gg", .desc = "跳转到第一行", .group = "移动" },
    .{ .keys = "G", .desc = "跳转到最后一行", .group = "移动" },
    .{ .keys = "H", .desc = "光标到窗口首行", .group = "移动" },
    .{ .keys = "M", .desc = "光标到窗口中间行", .group = "移动" },
    .{ .keys = "L", .desc = "光标到窗口末行", .group = "移动" },
    .{ .keys = "zz", .desc = "当前行滚到屏幕中间", .group = "移动" },
    .{ .keys = "zt", .desc = "当前行滚到屏幕顶部", .group = "移动" },
    .{ .keys = "zb", .desc = "当前行滚到屏幕底部", .group = "移动" },

    // ---- 折叠 ----
    .{ .keys = "za", .desc = "切换光标处的折叠", .group = "折叠" },
    .{ .keys = "zo", .desc = "打开光标处的折叠", .group = "折叠" },
    .{ .keys = "zc", .desc = "关闭光标处的折叠", .group = "折叠" },
    .{ .keys = "zR", .desc = "打开全部折叠", .group = "折叠" },
    .{ .keys = "zM", .desc = "关闭全部折叠", .group = "折叠" },
    .{ .keys = "f", .desc = "向右查找字符 f{char}", .group = "移动" },
    .{ .keys = "F", .desc = "向左查找字符 F{char}", .group = "移动" },
    .{ .keys = "t", .desc = "向右查到字符前 t{char}", .group = "移动" },
    .{ .keys = "T", .desc = "向左查到字符前 T{char}", .group = "移动" },
    .{ .keys = ";", .desc = "重复上一次 f/t 查找", .group = "移动" },
    .{ .keys = ",", .desc = "反向重复上一次 f/t 查找", .group = "移动" },
    .{ .keys = "s", .desc = "EasyMotion 跳转（输入目标字符后选标签）", .group = "移动" },
    .{ .keys = "ctrl-u", .desc = "向上翻半页", .group = "移动" },
    .{ .keys = "ctrl-d", .desc = "向下翻半页", .group = "移动" },
    .{ .keys = "ctrl-b", .desc = "向上翻一页", .group = "移动" },
    .{ .keys = "ctrl-f", .desc = "向下翻一页", .group = "移动" },

    // ---- 编辑 ----
    .{ .keys = "u", .desc = "撤销", .group = "编辑" },
    .{ .keys = "ctrl-r", .desc = "重做", .group = "编辑" },
    .{ .keys = ".", .desc = "重复上一次编辑", .group = "编辑" },
    .{ .keys = "p", .desc = "粘贴到光标后", .group = "编辑" },
    .{ .keys = "P", .desc = "粘贴到光标前", .group = "编辑" },
    .{ .keys = "d", .desc = "删除（操作符，接动作如 dw/dd）", .group = "编辑" },
    .{ .keys = "c", .desc = "修改（操作符，接动作如 cw/cc）", .group = "编辑" },
    .{ .keys = "y", .desc = "复制（操作符，接动作如 yw/yy）", .group = "编辑" },
    .{ .keys = "x", .desc = "删除光标处字符", .group = "编辑" },
    .{ .keys = "X", .desc = "删除光标前字符", .group = "编辑" },
    .{ .keys = "D", .desc = "删除到行尾", .group = "编辑" },
    .{ .keys = "C", .desc = "修改到行尾", .group = "编辑" },
    .{ .keys = "S", .desc = "修改整行", .group = "编辑" },
    .{ .keys = "r", .desc = "替换光标处字符 r{char}", .group = "编辑" },
    .{ .keys = "~", .desc = "切换光标处字符大小写", .group = "编辑" },
    .{ .keys = "J", .desc = "合并下一行", .group = "编辑" },
    .{ .keys = ">>", .desc = "缩进当前行", .group = "编辑" },
    .{ .keys = "<<", .desc = "取消缩进", .group = "编辑" },
    .{ .keys = "ctrl-a", .desc = "光标处数字加 1（可视模式整选区）", .group = "编辑" },
    .{ .keys = "ctrl-x", .desc = "光标处数字减 1（可视模式整选区）", .group = "编辑" },
    .{ .keys = "g ctrl-a", .desc = "可视块列增量：每行首个数字 + 行号", .group = "编辑" },
    .{ .keys = "g ctrl-x", .desc = "可视块列减量：每行首个数字 - 行号", .group = "编辑" },
    .{ .keys = "gcc", .desc = "注释/取消注释当前行（可视模式 gc 注释选区）", .group = "编辑" },
    .{ .keys = "gc", .desc = "可视模式注释/取消注释选中行", .group = "编辑" },
    .{ .keys = "ga", .desc = "按分隔符对齐 ga{motion}{char}", .group = "编辑" },
    .{ .keys = "ys ds cs", .desc = "包围操作：ys{motion}{char} 添加 / ds{char} 删除 / cs{old}{new} 更改", .group = "编辑" },
    .{ .keys = "ctrl-n", .desc = "多光标：选中单词 / 添加下一个匹配", .group = "编辑" },
    .{ .keys = "( [ { \" ' `", .desc = "自动配对：输入开括号/引号自动补全闭合符，成对退格删除", .group = "编辑" },

    // ---- 模式 ----
    .{ .keys = "i", .desc = "光标前进入插入模式", .group = "模式" },
    .{ .keys = "I", .desc = "行首进入插入模式", .group = "模式" },
    .{ .keys = "a", .desc = "光标后进入插入模式", .group = "模式" },
    .{ .keys = "A", .desc = "行尾进入插入模式", .group = "模式" },
    .{ .keys = "o", .desc = "下方插入新行并进入插入模式", .group = "模式" },
    .{ .keys = "O", .desc = "上方插入新行并进入插入模式", .group = "模式" },
    .{ .keys = "v", .desc = "进入字符可视模式", .group = "模式" },
    .{ .keys = "V", .desc = "进入行可视模式", .group = "模式" },
    .{ .keys = "ctrl-v", .desc = "进入块可视模式", .group = "模式" },
    .{ .keys = "esc", .desc = "返回普通模式 / 取消待定序列", .group = "模式" },
    .{ .keys = "ctrl-c", .desc = "退出插入模式", .group = "模式" },
    .{ .keys = ":", .desc = "进入命令行模式", .group = "模式" },
    .{ .keys = "jk", .desc = "插入模式快速退出（jk 不落字）", .group = "模式" },

    // ---- 搜索 ----
    .{ .keys = "/", .desc = "向前搜索", .group = "搜索" },
    .{ .keys = "?", .desc = "向后搜索", .group = "搜索" },
    .{ .keys = "n", .desc = "下一个搜索匹配", .group = "搜索" },
    .{ .keys = "N", .desc = "上一个搜索匹配", .group = "搜索" },
    .{ .keys = ":s", .desc = "行内替换 :s/模式/替换/g（:%s 全文件）", .group = "搜索" },
    .{ .keys = ":noh", .desc = "清除搜索高亮", .group = "搜索" },

    // ---- Leader ----
    .{ .keys = "space", .desc = "Leader 前缀", .group = "Leader" },
    .{ .keys = "space f", .desc = "跨窗口 EasyMotion 跳转", .group = "Leader" },
    .{ .keys = "space e", .desc = "文件树开关", .group = "Leader" },
    .{ .keys = "space E", .desc = "文件树中定位当前文件", .group = "Leader" },
    .{ .keys = "space o", .desc = "LSP 符号大纲", .group = "Leader" },
    .{ .keys = "space sf", .desc = "模糊查找文件", .group = "Leader" },
    .{ .keys = "space st", .desc = "全文 grep 搜索", .group = "Leader" },
    .{ .keys = "space sb", .desc = "Buffer 列表", .group = "Leader" },
    .{ .keys = "space sr", .desc = "最近文件列表", .group = "Leader" },
    .{ .keys = "space sd", .desc = "诊断列表", .group = "Leader" },
    .{ .keys = "space sk", .desc = "键位搜索（本表）", .group = "Leader" },
    .{ .keys = "space bb", .desc = "上一个 Buffer", .group = "Leader" },
    .{ .keys = "space bn", .desc = "下一个 Buffer", .group = "Leader" },
    .{ .keys = "space bj", .desc = "挑选 Buffer", .group = "Leader" },
    .{ .keys = "space bk", .desc = "关闭当前 Buffer", .group = "Leader" },
    .{ .keys = "space rn", .desc = "LSP 重命名符号", .group = "Leader" },
    .{ .keys = "space lf", .desc = "LSP 格式化文档", .group = "Leader" },
    .{ .keys = "space ti", .desc = "LSP inlay hints 开关", .group = "Leader" },

    // ---- Git ----
    .{ .keys = "]c [c", .desc = "下一个 / 上一个 Git hunk", .group = "Git" },
    .{ .keys = "space hs", .desc = "Stage 当前 hunk", .group = "Git" },
    .{ .keys = "space hr", .desc = "Reset 当前 hunk", .group = "Git" },
    .{ .keys = "space hp", .desc = "预览当前 hunk 的 diff", .group = "Git" },
    .{ .keys = "space tb", .desc = "行内 blame 开关", .group = "Git" },
    .{ .keys = "space lg", .desc = "外部终端启动 lazygit", .group = "Git" },

    // ---- 窗口 ----
    .{ .keys = "ctrl-w h l", .desc = "窗口焦点向左/右（有文件树时切换树焦点）", .group = "窗口" },
    .{ .keys = "ctrl-w j k", .desc = "窗口焦点向下/上", .group = "窗口" },
    .{ .keys = "gt gT", .desc = "下一个/上一个标签页（Buffer）", .group = "窗口" },

    // ---- LSP ----
    .{ .keys = "K", .desc = "Hover 悬停文档", .group = "LSP" },
    .{ .keys = "gd", .desc = "跳转到定义", .group = "LSP" },
    .{ .keys = "gD", .desc = "跳转到声明", .group = "LSP" },
    .{ .keys = "gr", .desc = "查找引用", .group = "LSP" },
    .{ .keys = "gI", .desc = "查找实现", .group = "LSP" },
    .{ .keys = "gs", .desc = "签名帮助", .group = "LSP" },
    .{ .keys = "gl", .desc = "当前行诊断", .group = "LSP" },
    .{ .keys = "]d", .desc = "下一个诊断", .group = "LSP" },
    .{ .keys = "[d", .desc = "上一个诊断", .group = "LSP" },

    // ---- 命令 ----
    .{ .keys = ":w", .desc = "保存文件", .group = "命令" },
    .{ .keys = ":q", .desc = "退出（有未保存修改时拒绝）", .group = "命令" },
    .{ .keys = ":q!", .desc = "强制退出不保存", .group = "命令" },
    .{ .keys = ":wq", .desc = "保存并退出", .group = "命令" },
    .{ .keys = ":qa", .desc = "全部退出", .group = "命令" },
    .{ .keys = ":e", .desc = "打开文件 :e 路径", .group = "命令" },
    .{ .keys = ":vs", .desc = "垂直分屏", .group = "命令" },
    .{ .keys = ":sp", .desc = "水平分屏", .group = "命令" },
    .{ .keys = ":bn", .desc = "下一个 Buffer", .group = "命令" },
    .{ .keys = ":bp", .desc = "上一个 Buffer", .group = "命令" },
    .{ .keys = ":bd", .desc = "删除 Buffer", .group = "命令" },
    .{ .keys = ":ls", .desc = "列出 Buffers", .group = "命令" },
    .{ .keys = ":set", .desc = "设置选项 :set 选项", .group = "命令" },
    .{ .keys = ":theme", .desc = "切换主题 :theme 名字（无参列出）", .group = "命令" },

    // ---- 文本对象 ----
    .{ .keys = "iw aw", .desc = "单词内 / 单词含周围空白", .group = "文本对象" },
    .{ .keys = "i( a(", .desc = "圆括号内 / 含括号", .group = "文本对象" },
    .{ .keys = "i[ a[", .desc = "方括号内 / 含括号", .group = "文本对象" },
    .{ .keys = "i{ a{", .desc = "花括号内 / 含括号", .group = "文本对象" },
    .{ .keys = "i< a<", .desc = "尖括号内 / 含括号", .group = "文本对象" },
    .{ .keys = "i' a'", .desc = "单引号内 / 含引号", .group = "文本对象" },
    .{ .keys = "i\" a\"", .desc = "双引号内 / 含引号", .group = "文本对象" },
    .{ .keys = "i` a`", .desc = "反引号内 / 含引号", .group = "文本对象" },

    // ---- 补全 ----
    .{ .keys = "ctrl-n ctrl-p", .desc = "插入模式补全：下一个 / 上一个候选", .group = "补全" },
};

/// 键位搜索匹配：对 "keys desc" 组合串做 fzy 模糊匹配（util/fzy.zig 的
/// match），或输入为空时全部匹配。返回 true 表示命中。
pub fn matches(a: std.mem.Allocator, entry: Entry, query: []const u8) !bool {
    if (query.len == 0) return true; // fzy never matches an empty needle
    const hay = try std.fmt.allocPrint(a, "{s} {s}", .{ entry.keys, entry.desc });
    defer a.free(hay);
    const m = try fzy.match(a, hay, query) orelse return false;
    a.free(m.positions);
    return true;
}

// ---- tests ----

const testing = std.testing;

test "entries include K / space st / space sk / :w" {
    var has_k = false;
    var has_st = false;
    var has_sk = false;
    var has_w = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.keys, "K")) has_k = true;
        if (std.mem.eql(u8, e.keys, "space st")) has_st = true;
        if (std.mem.eql(u8, e.keys, "space sk")) has_sk = true;
        if (std.mem.eql(u8, e.keys, ":w")) has_w = true;
    }
    try testing.expect(has_k);
    try testing.expect(has_st);
    try testing.expect(has_sk);
    try testing.expect(has_w);
}

test "all entries have non-empty keys / desc / group" {
    for (entries) |e| {
        try testing.expect(e.keys.len > 0);
        try testing.expect(e.desc.len > 0);
        try testing.expect(e.group.len > 0);
    }
}

test "matches: empty query matches every entry" {
    const a = testing.allocator;
    for (entries) |e| {
        try testing.expect(try matches(a, e, ""));
    }
}

test "matches: hover hits K, grep hits space st, garbage hits nothing" {
    const a = testing.allocator;
    var k_hit = false;
    var st_hit = false;
    for (entries) |e| {
        if (try matches(a, e, "hover")) {
            if (std.mem.eql(u8, e.keys, "K")) k_hit = true;
        }
        if (try matches(a, e, "grep")) {
            if (std.mem.eql(u8, e.keys, "space st")) st_hit = true;
        }
        // garbage must not match anything
        try testing.expect(!(try matches(a, e, "zzzz")));
    }
    try testing.expect(k_hit);
    try testing.expect(st_hit);
}

test "<leader>sk dispatches picker_keymaps" {
    const Mode = @import("mode.zig");
    const Keymaps = @import("keymaps.zig");
    var s = Mode.State.init();
    _ = Mode.handle(&s, .{ .codepoint = ' ' }, Keymaps.normal); // space
    _ = Mode.handle(&s, .{ .codepoint = 's' }, Keymaps.normal); // <leader>s
    const r = Mode.handle(&s, .{ .codepoint = 'k' }, Keymaps.normal); // <leader>sk
    try testing.expectEqual(.action, std.meta.activeTag(r));
    try testing.expectEqual(KeyEvent.ActionId.picker_keymaps, r.action.action);
}
