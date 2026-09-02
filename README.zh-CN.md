# oz

[English](README.md) | 中文

终端文本编辑器，使用 Zig 编写。

## 功能

**编辑（vim 系）**

- Normal / Insert / Visual / Visual Line / Visual Block / Command 六种模式
- 完整移动与 count：hjkl、w/e/b/ge、^/0/$、gg/G、{/}、%、f/F/t/T、Ctrl-u/d/f/b
- 文本对象、surround、注释、对齐、EasyMotion（s / `<leader>f`）、多光标（Ctrl+n）
- 撤销/重做（分组 + 分支语义）、寄存器语义（linewise/charwise yank & put）
- 分屏（:sp/:vs + Ctrl-w 系列）、buffer 标签栏、相对行号、代码折叠

**语法与界面**

- tree-sitter 语法高亮（内置多种语言 grammar）、彩虹括号、indent guide + scope 高亮动画
- 多主题（`OZ_THEME` 环境变量 + `<leader>sp` 主题选择器，实时预览）
- 大文件降级：超过 100KB 自动关闭高亮，保证流畅

![语法高亮、indent guide、inlay hints](docs/screenshots/editor.png)

**LSP**

- 异步接入（不阻塞启动），支持 zls 等常见 server（自动探测 mason 安装路径）
- hover（K）、定义/声明/引用/实现跳转（gd/gD/gr/gI）、signature help（gs）
- 诊断 gutter 标记 + `]d`/`[d` 跳转 + 诊断列表（`<leader>sd`）
- 自动补全菜单 + ghost text（`<C-n>`/触发字符）、inlay hints（`<leader>ti`）
- 重命名（`<leader>rn`）、格式化（`<leader>lf`）、文档大纲（`<leader>o`）

![LSP 补全菜单](docs/screenshots/completion.png)

**导航与查找**

- 模糊查找 picker：文件（`<leader>sf`）、grep（`<leader>st`）、buffer（`<leader>sb`）、最近文件（`<leader>sr`）、快捷键（`<leader>sk`）
- 文件树（`<leader>e` 开关，`<leader>E` 定位当前文件）
- buffer 内搜索（`/`、`?`、n/N）

![模糊查找文件（leader sf）](docs/screenshots/picker.png)

![grep 搜索（leader st，带实时预览）](docs/screenshots/grep.png)

![文件树](docs/screenshots/filetree.png)

**Git**

- gutter diff 标记、`]c`/`[c` hunk 跳转、`<leader>hs`/`<leader>hr` stage/reset、`<leader>hp` hunk 预览
- 当前行 blame 幽灵文本（光标停 1s 后显示，`<leader>tb` 开关）、`<leader>lg` 浮动窗口 lazygit
- 状态栏显示分支名

![gutter diff 标记 + 当前行 blame](docs/screenshots/git.png)

**终端**

- 内嵌终端（Linux / macOS）：`Alt+r` 浮动 / `Alt+w` 底部 / `Alt+e` 右侧，终端内 Esc 退回 Normal

![内嵌终端（Alt+r 浮动布局）](docs/screenshots/terminal.png)

## 构建与运行

需要 Zig 0.16.0：

```sh
zig build                                    # 开发构建
zig build -Doptimize=ReleaseFast -Dstrip     # 发布构建（日常用这个）
zig build test                               # 单元测试
zig build e2e                                # pty 端到端测试（目前仅 Linux）
```

运行：`oz [file[:line]]`

## 性能

基准方法：pty 驱动 + 屏幕重建，同机（Apple Silicon, macOS）同文件，取 3 次中位数。

| 场景 | oz | nvim --clean |
|---|---|---|
| 启动（小文件） | 66 ms | 115 ms |
| 启动（5 MB / 10 万行） | 65 ms | 118 ms |
| 启动（.zig，zls 已安装） | 52 ms | 117 ms |
| G 跳到文件尾（10 万行） | 54 ms | 65 ms |
| 100× Ctrl-F 翻页 | 54 ms | 100 ms |
| 500× j 光标移动 | 53 ms | 100 ms |
| 输入 100 字符 | 64 ms | 66 ms |
| 10 万行文件尾部输入 30 字符 | 71 ms | 56 ms |
| 全文搜索（10 万行） | 58 ms | 66 ms |
| 带 LSP 连续输入 60 字符 | 60 ms | 56 ms |

全部场景与 nvim 持平或更快。关键设计：mmap 惰性加载文件、PieceTable 增量行索引、tree-sitter 增量解析、LSP 异步握手 + 写入线程 + 增量同步、原子化保存（temp+rename）。
