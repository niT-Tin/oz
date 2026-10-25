# oz 编辑器设计文档

> 目标：用 Zig 实现一个**只满足自己需求**的 TUI 编辑器（需求来源：`~/.config/nvim/editor-spec.md`，多年 Neovim 配置提炼）。
> 参考仓库：`~/sources/flow`（Flow Control，成熟的 Zig TUI 编辑器，本设计大量借鉴其架构决策）。
> 状态：**设计阶段**（v1，待评审）。本文档是架构与路线图的唯一权威来源，随实现演进。

---

## 0. 决策记录（ADR 摘要）

| # | 决策 | 结论 | 理由 |
|---|------|------|------|
| D1 | 终端层 | **用 vaxis**（flow 同款，neurocyte fork，Zig 0.17） | 纯 Zig、静态链接；自带 kitty 键盘协议、鼠标、24bit 色、屏幕 diff 渲染。省下数月工作量，把精力放在编辑核心 |
| D2 | 依赖策略 | **允许精选第三方库**，业务核心自研 | tree-sitter 绑定、JSON 解析等成熟组件直接用；buffer/undo/模式系统/LSP 状态机自己写 |
| D3 | 文档存储 | **PieceTable**（参考 flow 的 hybrid rope/piece-table） | 大文件友好、编辑 O(1) 局部更新、undo 记录片段级操作代价小 |
| D4 | Undo | 线性栈 + 操作合并，预留 undo tree | spec 只要求"无限 undo/redo + `.` 重复"，不做 vim 式分支撤销 |
| D5 | 并发模型 | **线程 + 消息队列**（不用 actor 框架） | flow 用 thespian actor，对 oz 过重；LSP 读线程 + 主循环 drain 队列足够 |
| D6 | 模糊匹配 | 自研 fzy 风格 matcher（~200 行，接口化） | 可换 fuzzig；自己写符合"自研编辑器"精神且极易测试 |
| D7 | 剪贴板 | 写：OSC 52；读：wl-paste/xclip/pbpaste 子进程回退 | 终端内实现 unnamedplus 的标准做法 |
| D8 | 内嵌终端 | 自研 PTY + 迷你 VT 仿真（参考 flow `terminal/` 模块） | 最大工程项，M3 拆分实施（见路线图 M3） |
| D9 | 配置 | 配置即代码（Zig 编译期键位表 + 少量启动期常量） | spec §0 明确要求，不做运行时脚本 |
| D10 | 模式集 | **六模式**：在 spec 五模式上补充 vim 命令模式（`:` 命令行） | 用户补充：命令模式是 vim 工作流支柱（:w/:q/:s/:e/…），历史+补全+替换预览是效率关键 |
| D11 | 测试 | **四层**：L1 纯逻辑单测 + L2 Cell 网格快照 + L3 pty E2E + L4 外部 mock；golden 显式更新 | 解决 TUI "看不见结果"的验证问题（nvim Screen expectation 同款思路，见 §12） |
| D12 | workspace | **workspace = 运行时 buffer+窗口分组**，swap-on-switch（App 的 buffers/windows/win_root/current/current_win 字段即"当前 workspace"，其余槽位存完整状态）；纯运行时、不落盘 | 不属于 §1.2 排除的 "session 持久化/项目管理"；Doom Emacs 风格多 workspace 视图分组（见 §6.8） |

---

## 1. 目标与范围

### 1.1 必须达成（摘自 spec）

- Modal 编辑，六模式：Normal / Insert / Visual / Visual Line / Visual Block / **Command**（vim `:` 命令模式，用户补充，见 §6.7）
- Leader = `Space`，Insert 下 `jk` 退回 Normal，相对行号，块/beam 光标
- Insert 的 `Esc` 退出 Insert 并同时关闭补全菜单（一次按键）：不再有"第一次 Esc 只关菜单、仍留在 Insert"的半插入状态；`Ctrl+e` 只隐藏菜单并留在 Insert（对应 blink.cmp 的 hide）
- 无限 undo/redo、`.` 重复、数字前缀 count
- 文本对象、surround、注释切换、对齐、自动配对、多光标
- easymotion 等价物（`s` / `<leader>f`）
- tree-sitter 高亮（parser 全部内嵌，单静态二进制）
- LSP（8 个 server）+ 补全（LSP>snippet>path>buffer）+ ghost text + snippet
- 文件树、统一 fuzzy picker、符号大纲、buffer/tab 管理（bufferline 式 tab 栏）
- 系统剪贴板互通 + yank 历史
- 内嵌终端（3 种布局）+ lazygit 集成
- Git gutter / hunk 操作 / 行内 blame
- UI：状态栏、折叠、zen、markdown 渲染、颜色预览、kanagawa-wave 默认主题、dashboard
- AI 辅助（第二阶段）：行内补全（限 3 条）、chat 浮窗、外部 LLM API 调用

### 1.2 明确不做（摘自 spec §11）

DAP、插件系统/运行时脚本、宏与寄存器（用 yank 历史替代）、session 持久化/项目管理、非模态输入、鼠标之外 GUI。

> 补充：§6.8 的 Workspace 是纯运行时的 buffer+窗口分组（不落盘），不属于此处排除的 "session 持久化/项目管理"；后者指跨启动恢复会话状态。

### 1.3 非功能约束

- **帧率**：主循环目标 ≤8ms/帧（flow 为 ≤6ms），输入零感知延迟
- **大文件**：>2MB 或 >50k 行自动降级（关高亮/关 LSP/停 blame），不卡死
- **崩溃安全**：`noswapfile`/`nowritebackup` 已排除写盘负担；退出时可靠恢复终端状态
- **终端兼容**：kitty 协议缺失时降级到标准转义序列；16 色可用（语义色槽保证无彩色也可用，见 §4.6）

---

## 2. 技术选型

| 组件 | 选择 | 说明 |
|------|------|------|
| 语言/工具链 | Zig 0.17.0 | `std.Io` API；vaxis 走 0.17 兼容的 vendor |
| 终端层 | `vaxis` 0.6（neurocyte fork） | 屏幕网格、diff 渲染、kitty 键盘协议、鼠标、resize、光标形状 |
| 语法高亮 | tree-sitter C runtime + vendored parsers | 集成方式参考 flow 的 `flow-syntax` 模块与 build 选项 `use_tree_sitter` |
| JSON | `std.json`（Zig 内置） | LSP JSON-RPC、配置 |
| 模糊匹配 | 自研 `util/fzy.zig` | fzy 算法（score + 子序列匹配），接口与 fuzzig 对齐 |
| 正则（grep 用） | 外部 ripgrep 二进制（spec 要求"ripgrep 级别速度"） | `leader st` 全文检索走子进程；不内嵌 |
| 剪贴板 | OSC 52 写 + 子进程读 | 见 D7 |
| PTY/终端仿真 | 自研 `sys/Terminal.zig` | M3；参考 flow `terminal/`（Terminal.zig / xterm.zig / Parser.zig） |
| HTTP（AI 阶段） | 自研最小 HTTP/1.1 + SSE 客户端 | 仅 M4 AI 需要，不引入 libcurl |
| 文件树/索引 | 自研（`std.fs` 遍历 + gitignore 过滤） | 参考 flow `walk_tree.zig` / `gitignore/` |

### 2.1 build 集成

```
build.zig
├── vaxis      → b.dependency("vaxis")            // 终端
├── syntax     → b.dependency("tree-sitter") + C 源 parser 列表
│                 (zig/rust/go/python/ts/js/json/toml/yaml/html/css/lua/vim/bash/c/cpp/markdown)
└── exe oz     → imports: vaxis, syntax, oz-lib
```

- 全部 parser 以 C 源码编译进单二进制（`addCSourceFiles`），满足"单静态二进制"
- `-Duse-tree-sitter` build 选项（默认开），Debug 构建可关掉加速迭代

---

## 3. 总体架构

```
┌────────────────────────────── oz 主进程 ──────────────────────────────┐
│                                                                        │
│  ┌─────────────────────────── main.zig（事件循环）───────────────────┐ │
│  │  loop: vaxis.nextEvent() → dispatch → mutate → renderFrame       │ │
│  │  每 100ms: CursorHold 任务（单词高亮/blame）                      │ │
│  └──────────────────────────────┬───────────────────────────────────┘ │
│                                 │                                     │
│  ┌───────────── App.zig（全局状态）────────────────────────────────┐  │
│  │  buffers: []BufferView    tabs / windows   mode 状态机           │  │
│  │  theme / keymaps / picker 会话 / 消息队列（跨线程入队）          │  │
│  └──┬─────────┬──────────┬──────────┬──────────┬───────────────────┘  │
│     │         │          │          │          │                       │
│  ┌──▼───┐ ┌───▼────┐ ┌───▼────┐ ┌──▼─────┐ ┌──▼──────┐               │
│  │buffer│ │ editor │ │  ui    │ │ syntax │ │  lsp    │               │
│  │      │ │        │ │        │ │        │ │         │               │
│  │PT/Csr│ │Mode    │ │Screen  │ │HL/Indent│ │Client   │── 线程 ──▶ LSP│
│  │Hist  │ │Action  │ │TabBar  │ │Fold    │ │Features │  读管道      │
│  │utf8  │ │Motion  │ │Status  │ │c/parsers│ │json_rpc │               │
│  │      │ │Op/Repeat│ │Gutter  │ │        │ │         │               │
│  │      │ │EasyMove│ │Picker  │ │        │ │         │               │
│  │      │ │MultiCur│ │FileTree│ │        │ │         │               │
│  └──────┘ └────────┘ └───┬────┘ └────────┘ └─────────┘               │
│                          │                                            │
│  ┌───────────────────────▼─────────────────────────────────────────┐  │
│  │  sys/：Clipboard · Terminal(PTY+VT) · Git · Grep · Http          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  ┌──────────────────────── vaxis（终端抽象）─────────────────────────┐ │
│  │  Screen(Cell 网格) · diff 渲染 · kitty 键盘 · mouse · resize     │ │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

**分层原则**（对齐 tui-design skill）：
- `buffer/`、`editor/` 为**纯逻辑层**：不感知终端，全部可单测
- `ui/` 只消费 buffer/editor 暴露的状态，不直接改文档
- `sys/` 是副作用隔离层（进程/管道/网络），全部经消息队列回主循环
- 依赖方向：`main → App → {buffer, editor, ui, syntax, lsp, sys}`，禁止反向

---

## 4. 核心数据结构

### 4.1 PieceTable（`buffer/PieceTable.zig`）

```
origin: []u8            // 初始文件内容（只读段）
add:    ArrayList(u8)   // 追加段（所有编辑插入的字节）
pieces: ArrayList(Piece) // 有序片段链表
Piece = { source: enum{origin, add}, start: u32, len: u32 }
```

- 读：`charAt(byte_offset)` → 定位 piece（二分 + 缓存最后访问 piece）
- 写：`replace(pos, len, bytes)` → 分裂/插入 piece，返回 `Edit {pos, before_len, after_bytes}`
- **行索引**：`line_starts: ArrayList(u32)` 缓存每行起始字节偏移，增量维护（编辑只影响后缀，标记脏区间后惰性重建）
- 大文件：piece 数量与编辑次数成正比，定期 `compact()` 合并相邻同源 piece
- 多光标：所有光标共享同一 PieceTable，编辑批量合并为一个 undo 组

### 4.2 Cursor / Selection（`buffer/`）

```
Cursor = { byte: u32,  // 字节偏移
           col: u32 }  // 显示列（tab 展开、CJK 宽度），渲染时换算
Selection = { anchor: u32, cursor: u32, kind: enum{char, line, block} }
```

- 光标位置用**字节偏移**存储，显示列惰性计算（`buffer/utf8.zig` 处理 grapheme/宽度）
- Visual Block 的列矩形：`anchor_col .. cursor_col` 跨行交集，编辑时按块语义展开

### 4.3 Undo / Redo（`buffer/History.zig`）

```
UndoGroup = []Edit        // 一次用户操作 = 一组 Edit（原子撤销）
undo_stack: ArrayList(UndoGroup)
redo_stack: ArrayList(UndoGroup)
```

- 合并规则：同一 Insert 会话的连续插入合并为同组（按超时/模式切换/光标跳变切分，对齐 vim 的 undo join 直觉）
- 撤销 = 逆序应用逆 Edit；重做 = 正序重放
- "无限" = 内存上限；提供 `u` 撤销 / `Ctrl+r` 重做
- **`.` 重复**：记录最后一次顶层命令的 `(action, count, motion)` 闭包，重放动作函数（见 §6.3）

### 4.4 KeyEvent（`editor/`）

vaxis 提供规范化的 `Key`（含 modifiers、kitty flags）。oz 在其上加一层：

```
KeyCombo = struct { key: vaxis.Key, mods: vaxis.Key.Modifiers }
```

键位表 = 编译期静态表：`KeyMap = []const struct{ combo: KeyCombo, action: Action }`，按模式分表。查表顺序：精确匹配 → 前缀（count/operator 待定状态）→ 模式默认动作。

### 4.5 渲染模型（`ui/Screen.zig`）

- vaxis `Screen` 提供 `Cell` 网格 + 行 diff；oz 负责把**区域**（tabbar/editor/gutter/statusline/popup）绘制进网格
- 每帧只 emit diff（vaxis 内部处理）；批写入一次 `write()`
- 光标形状：kitty 协议（block/beam），不支持时降级为普通光标 + 状态栏模式色
- 相对行号：Normal 模式渲染 `N-2 N-1 0 1 2`，当前行显示绝对号；Visual 模式可切换为绝对（vim 行为）

### 4.6 主题语义色槽（`ui/Theme.zig`，对齐 tui-design）

| 槽位 | 用途 | kanagawa-wave 映射 |
|------|------|-------------------|
| `fg.default` | 正文 | #c0caf5 |
| `fg.muted` / `fg.emphasis` | 次要/强调 | #565f89 / #e0e0e0 |
| `bg.base` / `bg.surface` / `bg.overlay` | 背景分层 | #1f2335 / #24283b / #414868 |
| `bg.selection` | 选区/高亮 | #364a82 |
| `accent.primary` / `accent.secondary` | 交互焦点 | #7aa2f7 / #bb9af7 |
| `status.error/warning/success/info` | 诊断/状态 | #f7768e / #e0af68 / #9ece6a / #7dcfff |

- 组件代码**只引用语义槽**，永不硬编码 hex（spec 支持多主题切换）
- 语法高亮色同样走语义槽映射（tree-sitter capture → 语义色），主题 = 槽位到具体色的映射表

---

## 5. 主事件循环与渲染管线

```
main(init):
  a = init.gpa; io = init.io
  raw 模式（vaxis 初始化时处理）
  app = App.init(a, io, args)          // args: files, +line, file:123
  defer app.deinit()                   // 恢复终端、写日志

  loop:
    event = vaxis.nextEvent(≈16ms timeout)   // key / mouse / resize / 超时
    app.drainMessageQueue()                  // LSP/后台线程消息（每帧）
    if key: app.dispatch(event.key)          // 模式状态机 → 动作 → 改 buffer
    if resize: app.relayout()
    if app.dirty or 定时任务到期:
      app.renderFrame()                      // 区域绘制 → vaxis diff 输出
    if 100ms tick 到期:
      app.cursorHold()                       // 单词高亮 / blame / CursorHold 驱动
```

关键点：
- **输入优先**：渲染不阻塞输入；vaxis 事件循环天然支持
- **dirty 标记**：buffer 编辑、消息入队、超时任务都会触发重绘；无变化不重绘
- 平滑滚动（flow 的动画滚动）列为 M4 增强项，MVP 用瞬时滚动保证 ≤8ms

---

## 6. 模式系统（`editor/`）

### 6.1 状态机

```
          i / a / o ...                  v / V / Ctrl+v
 Normal ───────────────▶ Insert ──jk / Esc──▶ Normal ◀──▶ Visual(char/line/block)
    ▲        │  :            │                   │ Esc
    │        ▼              Esc                 │
    │   Command ── Enter 执行 ──▶ Normal ◀──────┘
    └────────── Esc / Ctrl+c 取消 ─────────────┘
```

- `Mode = enum { normal, insert, visual_char, visual_line, visual_block, command }`
- 模式切换时：保存/恢复光标形状（vaxis）、记录 visual anchor、切换键位表；进入 Command 模式时快照光标位置（`Esc` 取消后原样返回）

### 6.2 输入解析管线

```
原始 key → 模式键位表查表
  ├─ 数字 → count 累加器（支持 `5j`、`3dw`）
  ├─ operator（d/c/y/g~）→ pending_operator 状态，等待 motion
  ├─ motion → 执行位移 → 若有 pending_operator 则执行操作
  ├─ `:` → 进入 Command 模式（`/` `?` 搜索复用同一 cmdline 组件，见 §6.7）
  └─ action → 立即执行
```

- pending 状态有超时/`Esc` 清除
- `.` 重复：顶层命令执行前快照 `(count, action, args)`，`.` 重放

### 6.3 动作表（`editor/Action.zig`）

每个动作是 `fn(ctx: *ActionCtx) void`，`ActionCtx` 暴露：`buffer 视图、光标、count、visual 状态、剪贴板`。动作分三类：

| 类 | 例子 |
|----|------|
| 光标移动 | `hjkl w W b B e ^ $ gg G { } % f F t T ; ,` `Ctrl+u/d/f/b` |
| 文本对象 | `iw aw i( a( i[ a[ i{ a{ i< a< i' a' i" a" i` a`` |
| 编辑操作 | `d c y p P x s S r > < gcc gc ga ys ds cs`、`Ctrl+n` 多光标、`=`(后续可选) |
| 模式/命令 | `i a o v V Ctrl+v`、`u Ctrl+r .`、`/ ?`、`<leader>*` 家族 |

- Operator + Motion 组合统一在 `Operator.zig`：`apply(op, motion, count)`
- 文本对象返回 `Selection`，与 Operator 正交组合

### 6.4 位移增强：EasyMotion（`editor/EasyMotion.zig`）

- `s` 输入 1~2 字符 → 当前窗口所有匹配位置打标签（`a-z A-Z`）→ 按标签跳转
- `<leader>f` 同逻辑跨窗口
- 实现：全 buffer 扫描匹配 → 渲染标签浮层（tui-design 的 Overlay/Popup 模式）→ 收集按键，两字符时二次过滤

### 6.5 多光标（`editor/MultiCursor.zig`）

- `Ctrl+n`：选中光标下单词 → 再次 `Ctrl+n` 扩选下一匹配 → `Ctrl+n` 编辑
- Visual Block 模式下用 `j/k` 上下加光标
- 数据结构：`[]Cursor` 排序去重；编辑 = 从后往前应用，合并为一个 undo 组
- 与自动配对/补全的交互：Insert 模式下所有光标同步插入/删除

### 6.6 键盘层级（tui-design 的 L0-L3）

| 层 | 内容 | 呈现 |
|----|------|------|
| L0 通用 | 方向键/Enter/Esc | 状态栏常驻提示 |
| L1 vim | hjkl / f / gg / G / `/` | 无需提示 |
| L2 Leader 动作 | `<leader>sf/st/sb/...` | `<leader>sk` 键位搜索（spec 3.2 自学工具）+ `?` 帮助浮层 |
| L3 组合 | count + operator + motion | 文档 |

### 6.7 命令模式（Command Mode）

vim 的 `:` 命令行是工作流的支柱（保存/退出/替换/跳转），用户补充进 oz 模式集。

- **入口**：Normal 下 `:` 进入；`/` 与 `?`（搜索）复用同一 cmdline 组件，历史各自独立
- **输入**：左右移动、退格、`Ctrl+w` 删词、`Ctrl+u` 清行；`Enter` 执行，`Esc`/`Ctrl+c` 取消（光标原样返回）
- **历史**：按类别（ex 命令/搜索/替换）环形保存最近 N 条；`↑/↓` 遍历，`Ctrl+r` 增量反向搜索历史（vim `<C-r>/`）
- **补全**（Tab 循环）：命令名 → 参数类型感知（`:e`/`:w` 走路径补全=目录遍历；`:set` 走选项名补全；`:s` 走历史替换式）
- **实时预览**：`:s/pat/rep/g` 默认开 `inccommand` 式实时预览（替换结果高亮显示，`Enter` 才落盘且进入 undo）

#### MVP ex 命令集（只做自己用的子集，范围见风险表）

| 类别 | 命令 |
|------|------|
| 文件 | `:w` `:wq` `:q` `:q!` `:e <file>` `:enew` `:saveas <file>` |
| buffer | `:bn` `:bp` `:ls` `:bd` `:bd!`（与 `<leader>bk` 同逻辑） |
| 替换 | `:s/pat/rep/gc`（`%` 前缀全文件；`c` 逐处确认） |
| 范围 | 行号范围 `:1,5d`、`:%d`、`:'<,'>s`（Visual 选区自动注入范围） |
| 显示 | `:noh` `:set <opt>`（tabstop/shiftwidth/expandtab/relativenumber…，与 config.zig 打通） |
| 终端 | `:term`（M3 后，等价 `<M-r>`） |

---

### 6.8 Workspace（Doom Emacs 风格）

像 Doom Emacs 的 workspace：每个 workspace 独立持有自己的 buffer 集合与窗口布局，互不打扰、随时切换。键位走 `<leader>`（Space）的 pending 状态机（`SPC` → `TAB` → 第三键）：

| 键位 | 动作 |
|------|------|
| `SPC TAB n` | 新建 workspace |
| `SPC TAB .` | picker 选择切换 workspace |
| `SPC TAB r` | 重命名 workspace（cmdline 预填当前名） |
| `SPC TAB d` | 删除当前 workspace |
| `SPC TAB x` | 清空当前 session（杀所有 workspace 和 buffer，回到全新状态） |
| `SPC TAB [` | 前一个 workspace |
| `SPC TAB ]` | 后一个 workspace |

**语义（swap-on-switch）**：App 的 `buffers`/`windows`/`win_root`/`current`/`current_win` 字段即"当前 workspace"的实时状态；每个非当前 workspace 把这五个字段存在自己的槽位里。切换 = 把 App 字段存回旧槽位、从目标槽位装入。因此 App 里所有 `self.buffers`/`self.windows` 引用（tab 栏、H/M/L、picker buffers 模式等）自动只作用于当前 workspace。槽位 `current_ws` 恒为 moved-from 空壳（仅名字）；其余槽位持有完整状态。启动槽位名 `main`，新建取第一个空闲 `ws{N}`（N 从 2 起）。

| 状态分类 | 内容 | 切换时处理 |
|---------|------|-----------|
| 每 workspace | buffers、windows、win_root、current/current_win | 随 swap 走 |
| 切换时重置 | visual_anchor、in_insert、state.mode→normal、mc_active、easymotion、picker/completion/hover/nav_list/diag_list、inlay、diagnostics、scope_anim/scope_cache | 全部关闭/失效 |
| LSP/git | 单 client 绑定当前 buffer | teardownLsp(false) + ensureLsp()；git diff/blame 由 scheduleGitStatus 重算（路径检查天然防串） |
| 全局共享 | yank_buffer、cmd、内嵌终端面板、picker_files 缓存 | 不动 |

**保护规则**：① 防双开——`openInBuffer` 只查当前 workspace，文件已在其他 workspace 打开则拒绝（`已在 workspace '<name>' 中打开`）；② dirty 保护——`SPC TAB d`/`SPC TAB x` 时任一 dirty buffer 拒绝并报数量（vim E37 风格）。

> 本里程碑不做：session 落盘持久化（§1.2 排除）；workspace 间移动/共享 buffer（以防双开拒绝代替）。

---

## 7. UI 布局（`ui/`，对齐 tui-design）

### 7.1 布局范式：IDE Three-Panel

```
┌─ TabBar（bufferline 式，图标+文件名+修改标记+诊断计数）─────────┐
├─ FileTree ┬ 编辑区（可多窗口 split，MVP 先单窗口）──┬ scrollbar │
│ (leader e)│  行号 gutter │ 内容 │                    │           │
├───────────┴──────────────────────────────────────────────┴──────────┤
│ StatusLine：模式 · 文件 · git 分支 · 诊断 · LSP · 行列 · 时间         │
└──────────────────────────────────────────────────────────────────────┘
  popup 层：picker / completion / hover / 浮窗终端 / chat（浮于上方）
```

- 布局 = 矩形区域树（`ui/Screen.zig` 分配 rect），resize 时按比例重排（tui-design 响应式策略）
- 焦点管理：Tab 在 文件树/编辑区/picker 间切换；弹窗为焦点陷阱
- 最小尺寸 80×24 以下显示 resize 提示，不崩溃

### 7.2 组件清单

| 组件 | 关键行为 | 对应 spec |
|------|---------|-----------|
| `TabBar` | 图标/文件名/修改标记/诊断计数红黄；鼠标可点选关闭；`gt/gT` 切换 | §4 |
| `Gutter` | 相对行号、git diff 符号、诊断图标（LSP/错误分级）、fold 标记 | §1.1/§2.2/§7/§8 |
| `StatusLine` | 模式（配色区分）、文件、git 分支、诊断、LSP 状态、行列、时间 | §8 |
| `FileTree` | leader e/E；树内增删改文件、回车打开；打开时定位当前文件目录 | §3.1 |
| `Picker` | 统一模糊匹配交互（Ctrl+n/p、Enter、Esc）；数据源：文件/grep/buffer/诊断/键位/主题/符号/yank 历史 | §3.2/§5 |
| `Popup` | hover 文档、signature help、completion 菜单、浮窗终端；圆角边框（可降级） | §2 |
| `CmdLine` | 命令模式输入行（复用为 `/` `?` 搜索）：历史 `↑/↓`、Tab 补全、`Ctrl+w` 删词 | §6.7 |
| `Dashboard` | 最近文件 + 快捷入口 | §8 |
| 折叠/zen/彩虹括号/sticky | M4 UI 打磨 | §8 |

### 7.3 渲染管线（每帧）

```
renderFrame:
  rect = app.layout()                     // 区域树
  tabbar.draw(rect.tabbar)                // 各组件把语义内容写入 Cell
  filetree.draw(rect.sidebar)             // 网格，颜色一律查 Theme
  editor.draw(rect.editor)                // 行号+gutter+高亮文本+selection
  statusline.draw(rect.status)
  popup_stack.draw()                      // 浮层覆盖
  screen.render()                         // vaxis diff + 单次 write
```

---

## 8. 开发工作流与效率

> 原则：编辑器要融入"打开 → 阅读 → 编辑 → 构建 → 修错 → 提交"的一般开发流程；
> 每个环节都有 ≤3 键的键盘路径，等待零感知，任何状态可 Esc 回 Normal。

### 8.1 场景 → 键位路径

| 场景 | 路径（全部键盘可达） |
|------|---------------------|
| 打开项目/文件 | `oz <dir>` 进入项目，或 `<leader>sf`（fuzzy 文件）→ `<leader>e` 文件树；命令行 `oz main.zig:123` 定位；最近文件进 dashboard |
| 阅读/导航 | `gd` 定义、`gr` 引用、`gI` 实现、`K` hover、`<leader>o` 符号大纲、`<leader>st` 全文 grep、`s` easymotion、`{/}/%`、`<C-u/d/f/b>` 翻页 |
| 编辑 | 文本对象 `ciw`/`ci(`/`ci"`、surround `ys`/`cs`/`ds`、注释 `gcc`/`gc`、对齐 `ga`、多光标 `<C-n>`、`:s` 替换预览、`.` 重复上一步 |
| 构建/运行/测试 | `<M-r>` 浮动终端（保持项目 cwd、可复用会话）、`:term`；输出直接看，不切窗口 |
| 修错 | `]d`/`[d` 诊断跳转、`<leader>sd` 诊断列表、`gl` 行内诊断、`<leader>rn` 重命名、`<leader>lf` 格式化 |
| Git 日常 | gutter diff 符号、`]c`/`[c` hunk 跳转、`<leader>hs` stage / `<leader>hr` reset / `<leader>hp` 预览、`<leader>lg` lazygit（commit/branch/stash） |
| 收尾 | `:w`、`:q`/`:wq` |

### 8.2 效率原则（约束实现）

1. **键盘优先**：mouse 仅增强（点 tab/滚动），从不必要；Shift+点击保持终端原生选择
2. **高频 ≤3 键**：count + 文本对象 + leader 组合消灭重复按键；`<leader>sk` 键位搜索保证可发现性
3. **异步一切**：LSP/ripgrep/git 全部后台化，主循环 ≤8ms/帧；结果经消息队列到达，绝不阻塞输入
4. **上下文感知**：状态栏/帮助/补全只显示当前模式可用的动作（tui-design 第 6 原则）
5. **可逆性**：任何操作（含 `:s`、ex 命令的修改）都进 undo；Esc 在任何模式都可回 Normal
6. **零摩擦收尾**：`:w`/`:q`/`:wq` 一进一出，保存路径永远最短

---

## 9. LSP 与补全（`lsp/`）

### 9.1 客户端

```
Client = {
  proc: std.process.Child          // 服务器进程
  reader_thread: std.Thread        // 阻塞读 stdout → 消息队列
  writer: pipe                    // 主线程写请求（加锁）
  pending: IdMap(请求id → 回调)    // 请求-响应关联
  state: enum{stopped, starting, running, crashed}
}
```

- **JSON-RPC 帧**：`Content-Length` 头 + `std.json` 解析（`util/json_rpc.zig`）
- **消息队列**：无锁 SPSC 或 mutex+condvar；主循环每帧 drain（§5）
- 生命周期：按 filetype 懒启动；buffer 关闭且无引用时关闭进程
- **debounce**：`didChange` 150ms 合并；诊断异步到达，不阻塞主循环

### 9.2 Server 配置表（`lsp/ServerConfig.zig`，编译期常量）

| 语言 | 命令 | 备注 |
|------|------|------|
| Go | gopls | |
| Lua | lua_ls | 需识别 `vim` 全局（args 注入） |
| Python | pylsp | |
| TS/JS | ts_ls | |
| JSON | jsonls | |
| C/C++ | clangd | |
| Zig | zls | |
| Rust | rust-analyzer | |

### 9.3 功能映射（spec §2.2 键位）

| 键位 | LSP 方法 | 呈现 |
|------|---------|------|
| `K` | hover | 浮窗文档 |
| `gd` / `gD` | definition / declaration | 跳转；`gr`/`gI`（references/implementation）→ picker 列表 |
| `gs` | signatureHelp | 浮窗 + 当前参数高亮 |
| `gl` | publishDiagnostics | 行诊断浮窗 |
| `<leader>rn` | rename | 输入新名 + 预览确认 |
| `<leader>lf` | formatting | 全文档格式化 |
| `<leader>ti` | inlayHint | 开关 |
| 诊断 | publishDiagnostics | gutter 图标 + 行内 + `]d/[d` 跳转 + `<leader>sd` 列表 |

### 9.4 补全管线（`ui/Completion.zig` + `lsp/Features.zig`）

```
触发：输入字符 / Ctrl+Space
  1. 收集源：LSP completion → snippet（语法片段表）→ path → buffer 词频
  2. 排序去重（来源优先级 LSP > snippet > path > buffer）
  3. 呈现：popup 列表 + ghost text（行内灰字预览，不写 buffer）
  4. 交互：Ctrl+n/p 或方向键、CR 确认、Ctrl+e 关闭、Ctrl+b/f 滚动文档
  5. 确认后：snippet 展开（{1:占位} 模型）→ Tab 跳占位符（无占位符则插入字面 Tab）
```

- 文档浮窗延迟 ~500ms 自动显示（spec §2.1）
- ghost text 与 completion 菜单、诊断、拼写候选共用同一"行内叠加渲染"机制

---

## 10. 并发模型

```
主线程（事件循环）←── SPSC 队列 ──┬── LSP reader 线程（每 server 一个）
                                ├── git 状态线程（diff/blame，M3）
                                ├── grep 子进程（picker 全文件搜索）
                                └── 文件 watcher（后续可选）
```

- 跨线程只传**不可变消息**（copy 或 owned 分配），主线程独占所有可变状态 → 无锁主体
- 子进程（git/grep/ripgrep/lazygit）：`std.process.Child` + 非阻塞管道轮询，输出分块入队
- 原则（tui-design）：**异步一切**，UI 永不阻塞；耗时操作有进度反馈，Esc 可取消

---

## 11. 配置即代码

- **键位表**：`editor/Keymaps.zig` 编译期生成（每个模式一张静态表），改键 = 改 Zig 代码
- **编辑器常量**：tabstop=2 shiftwidth=2 expandtab、updatetime=100ms、主题默认 kanagawa-wave、注释符按 filetype 映射表 —— 全部集中在 `config.zig`（编译期常量 + 少量启动期探测）
- **不提供**：配置文件解析、热重载、运行时脚本

---

## 12. 测试策略

> 目标：让每个行为都有**脚本化断言**——不依赖人眼看终端。
> nvim 的做法：`test/unit`（纯函数单测）+ `test/functional`（启动真实二进制，用 **Screen expectations** 把输出字节流解析成网格逐字符断言）+ fuzz/bench。
> oz 的等价物：四层测试 + 两条铁律。

### 12.1 两条铁律

1. **不靠肉眼验证 UI**：任何 UI 行为必须有脚本化断言（L2/L3）；实现者（含 AI 代理）迭代时只读 `zig build test` / `zig build e2e` 的 stdout 判定对错——**不知道结果就不算完成，不做无断言的手工猜测**
2. **golden 显式更新**：快照只有带 `-Dupdate-golden`（或 `OZ_UPDATE_GOLDEN=1`）才能重写，防止漂移掩盖回归

### 12.2 四层测试

| 层 | 范围 | 形式 | nvim 对应 |
|----|------|------|-----------|
| **L1 纯逻辑单测** | buffer/ editor/ util/ 全部纯函数：PieceTable、undo、motions、文本对象、operator、easymotion、fzy、snippet、JSON-RPC 编解码 | `test "..."` 块，`zig build test` | test/unit |
| **L2 渲染快照** | ui/ 渲染进**纯数据 Cell 网格**（不经真实终端），断言文本/语义色槽/光标位置；golden = ASCII 画面 fixture；多尺寸 80×24 / 120×40 / 200×60 + resize | golden 比对 | Screen expectations |
| **L3 E2E** | openpty spawn 真实 oz 二进制，脚本化按键写入 master，读回字节流 → 解析成网格断言 + 退出码 | `zig build e2e` | test/functional |
| **L4 外部集成** | mock LSP server（JSON-RPC over stdio，可编程响应）、固定 commit 的临时 git 仓库、fake `wl-paste` 注入 PATH | 子进程 + fixture | — |

### 12.3 具体形态

- **L1**：flow 模式——`test/tests.zig` 用 `refAllDecls` 聚合各模块测试文件（`tests_buffer.zig`、`tests_editor.zig`…）；纯逻辑与终端零耦合（§3 分层原则保证可测性）
- **L2 golden fixture**（Zig 版 nvim Screen expectation）：

  ```
  ┌─ fixture: tabbar 渲染 ─────────────────┐
  │ main.zig●  util.zig   DESIGN.md        │  ● = 修改标记
  │ 1  fn main() {                         │
  │ 2    ^print("hi");                     │  ^ = 光标位置
  │ ~                                      │
  └────────────────────────────────────────┘
  ```

- **L3**：`test/e2e/run.zig`——`openpty` + fork/exec（链接 libc），keys fixture 驱动（如 `"ggd2d:w\n"`），输出用自研/复用 ANSI 解析器还原网格；断言含退出码、末帧画面、关键转义序列
- **L4**：`test/mock_lsp.zig` 可编程响应脚本（handshake/didOpen/诊断/补全…），LSP 客户端状态机确定性测试；git 测试用固定 commit 的小临时仓库

### 12.4 随机不变量测试（buffer/undo 专属）

种子化 RNG 生成随机编辑序列，断言不变量：

- 文档字节守恒（片段总长 == 逻辑文档长）
- `undo ∘ edit == identity`（随机序列后全部撤销 == 初始内容）
- 行索引与逐行扫描结果一致
- 每轮换种子（`--seed`），CI 固定种子保证可复现

### 12.5 里程碑对齐

每个 M 的**验收标准 = 该里程碑测试清单**（见 §13 路线图各表）。M0 交付时同时交付测试骨架：

- `zig build test`（L1+L2）与 `zig build e2e`（L3）本地可跑
- M0 起"先写测试再实现"：纯逻辑 L1 先行，渲染行为 L2 快照先行，端到端流程 L3 场景先行

### 12.6 实现者工作方式约束（防"乱尝试浪费时间"）

- 迭代闭环 = 改代码 → 跑 `zig build test` / `zig build e2e` → 读 stdout 判定 → 继续
- 无法在真实终端肉眼看效果时，一律以 L2/L3 断言为准；真机冒烟仅作为发布前最后一步（可由用户在真实终端确认）

### 12.7 性能契约（终端编辑器性能调查报告.md 的落实）

> 背景调查：`~/sources/myFFmpeg/src/cabac.zig`（124KB，token 极密）在 nvim 里滚动/输入卡顿。
> 根因 = **token 密度 × 装饰系统数**：tree-sitter 高亮 + rainbow + semantic tokens 三个系统
> 各自给同一批 token 建对象（extmark），成本随**全文件 token 数**线性增长，与可见区域无关。
> Zed 快在 GPU + 增量解析 + 只渲染可见区域。调查产物在 /tmp（重启丢失），核心结论归档于此。

**铁律：渲染成本必须 O(可见区域)，与文件大小解耦。** 具体落实（已实现，2026-08）：

| 环节 | 实现 | 实测 |
|------|------|------|
| 语法高亮 query | `ts_query_cursor_set_byte_range` 限定视口；产出一张扁平 `[]Span`（src/syntax.zig），无 per-token 对象 | 可见区 query ~9ms/帧（24 行）；全文件 query 303ms（**从不执行**） |
| 增量解析 | 单编辑走 `tree.edit` + old_tree 增量路径（history.revision/last_record 判定）；多编辑/undo/切换 buffer 回退全量 | 90KB 文件打字 48ms/键 → **~3ms/键** |
| 大文件降级 | >100KB 完全跳过语法 pass（与 nvim 缓解报告同阈值） | cabac.zig(124KB) 零语法开销 |
| 行索引 | 每编辑后全量重建（O(文件) 字节扫描，M1 现状）；B-tree 缓存行偏移是 M2+ 优化项 | 12MB 打字 ~30ms/键；源码级 <1MB 时 <3ms/键 |
| 渲染 | vaxis diff 渲染只发变更 cell + 颜色连续段合并 SGR | 滚动 30 屏任意文件 <50ms |
| markdown injection（M4） | 双 grammar（block + markdown_inline/fence 语言）经 `setIncludedRanges` 注入；**子树解析限定在视口相交的 inline/fence 节点**（编辑会使后续所有注入区间位移，全文 included ranges 会让增量复用失效）；子树与主树用同一 InputEdit 保持增量有效 | 90KB md 打字：全量 included ranges 274ms/键 → 视口限定后 **~10ms/键**（ReleaseFast；block parser 本身偏慢是 tree-sitter-markdown 已知问题）；视口 span/decor query ~1.5ms |

**验证方式**（防退化）：`zig build e2e` 含两条语法契约测试——zig 文件关键字/注释颜色断言（Grid 解析器记录 SGR fg），以及 >100KB 文件零颜色断言。markdown 渲染有专门 e2e（标题/粗体/code span/链接/fence 注入/checkbox 图标 + 光标行 anti-conceal）。人工基准：造 ~90KB zig 文件跑 `script` 会话测打字/滚动墙钟。

---

## 13. 分阶段路线图

> 对齐 spec §12 的实施顺序，拆成可验收的 Milestone。每个 Milestone 独立可运行、可日常使用。

### M0 — 地基（≈2-3 周）

| 项 | 验收标准 |
|----|---------|
| vaxis 集成 + raw 模式 + 事件循环 + resize | 打开/关闭编辑器终端状态干净；resize 不崩 |
| PieceTable + 行索引 + 文件 open/save | 编辑 1000 行真实文件流畅；支持 `file:123`、`+123` |
| 六模式骨架（Normal/Insert/Visual/Visual Line/Visual Block/Command）+ 基础移动（hjkl w/W/b/B/e ^/$ gg/G {/} % f/F/t/T）+ count | 键位与 vim 一致 |
| 命令模式最小集 | `:` 进入；`:w` `:q` `:wq` `:e` `:bn` `:bd` `:ls` `:noh` `:set`；`↑/↓` 历史、`Esc` 取消 |
| Insert：jk 退出、自动配对（基础）、退格/回车 | |
| 相对行号 + block/beam 光标 | |
| 线性 undo/redo + `.` 重复 | 撤销/重做原子正确 |
| yank/put + 系统剪贴板（OSC52 + 回退） | y/p 与终端外互通 |
| 状态栏（模式/文件名/行列） | |
| 测试骨架 | `zig build test`（L1+L2）与 `zig build e2e`（L3）可跑；buffer/undo 随机不变量测试通过 |

**M0 通过 = 可编辑真实文件不丢数据。**

### M1 — MVP（spec §12 第一段，≈4-6 周）

- [x] 文本对象 `iw/aw/i(/a(...` + d/c/y/v 组合
- [x] surround（ys/ds/cs）、注释（gcc/gc）、对齐（ga）
- [x] EasyMotion（s / leader f）
- [x] 多光标（Ctrl+n + Visual Block 加光标）
- [x] tree-sitter 高亮（首批：zig/rust/go/python/ts/js/json/c/cpp/bash/lua/toml/yaml，视口 query + 增量解析 + 100KB 降级，见 §12.7）
- [x] TabBar（图标/修改标记）+ buffer 管理（leader bb/bn/bj/bk、gt/gT、:bn/:bp/:bd/:ls）
- [x] 文件树（leader e/E）
- [x] 统一 fuzzy picker：文件（sf）/ grep（st，ripgrep）/ buffer（sb）/ 最近文件（sr）
- [x] 命令模式增强：历史（会话内）+ Tab 补全（路径）+ `:s` 替换 + `:'<,'>s` 视觉范围注入
- [x] Dashboard（最近文件持久化 `~/.cache/oz/recent`）
- [x] 多窗口 split：`:vs`/`:sp` 分割 + Ctrl-w h/j/k/l 几何切换 + `:q` 关窗口 + `:qa` 全退（窗口独立 cursor/viewport，同 buffer 可多窗口）

**M1 通过 = 日常写代码主流程可替代 vim。**

### M2 — LSP + 补全（≈4-6 周）

- LSP 客户端 + 8 server 配置（§9.2）
- K / gd / gD / gr / gI / gs / gl；诊断 gutter + ]d/[d + 列表
- 补全菜单 + ghost text + signature help + 文档浮窗
- snippet 展开 + Tab 占位符
- <leader>rn 重命名 / <leader>lf 格式化 / <leader>ti inlay hints / <leader>o 符号大纲

**M2 通过 = Go/Rust/Zig/TS 项目可完整走 LSP 工作流。**

### M3 — Git + 终端（≈4-6 周）

- **M3a**：git gutter（diff 符号）、]c/[c hunk 跳转、hunk stage/reset/preview、行内 blame（1s 延迟，leader tb 开关）、leader lg 起 lazygit（外部浮窗）
- **M3b**：内嵌终端（改用 vaxis `widgets/terminal`：PTY + VT 仿真 + scrollback 骨架），<M-r> 浮动 / <M-w> 底部 / <M-e> 右侧三种布局；终端内 Esc 退回 Normal；lazygit 改跑内嵌浮动终端

> 风险标注：~~M3b（内嵌终端仿真）是全项目最大工程项~~ 已交付（vaxis 自带 widgets/terminal 大幅降低工程量；自研 scrollback 仍为 TODO）。

### M4 — UI 打磨 + AI（≈3-4 周）

- sticky context、折叠（缩进驱动 + 摘要行，ts 精化为可选优化）、zen 模式
- [x] 彩虹括号 + indent guide/scope 高亮动画（M4 前已落地）
- [x] markdown 内联渲染（块级+行内高亮走 markdown/markdown_inline 双 grammar injection；fence 代码按 fence 语言注入上色；conceal 隐藏 `**`/`` ` ``/链接骨架/标题 `#` 前缀，光标行 anti-conceal，Insert/Visual/多光标/easymotion 时禁用；checkbox → Nerd Font 图标；标题/代码块整行背景带；表格仅上色，strikethrough 不做）
- 颜色预览（#rrggbb）、TODO/FIXME 高亮 + leader tt 列表
- CursorHold 单词自动高亮（120ms）、多主题切换（kanagawa-wave 默认）
- 大文件降级策略落地
- AI（spec §9）：行内补全源（Copilot/兼容 API，限 3 条与补全菜单合并）、chat 浮窗（选区提问）、外部 LLM API（DeepSeek 等）滚动翻译等内置能力
  - [x] M1 chat 已提前落地（`<leader>a`、流式 OpenAI 兼容 API、选区上下文、取消/错误降级；详见 §17）

**M4 通过 = spec 全量功能落地。**

### M5 — Workspace（Doom Emacs 风格，≈1 周）

- **W1 核心模型**：Workspace 结构 + App 字段 + swap-on-switch 切换/新建/前后切换 + 内存管理（create/deinit）+ 键位管线（mode/key_event/execAction）
- **W2 交互**：workspace picker（`SPC TAB .`）、重命名（cmdline 预填）、状态栏 `[name]`、keymap_list 条目
- **W3 生命周期**：`SPC TAB d` 删除（dirty/最后一个拒绝）、`SPC TAB x` 清空 session
- **W4 测试与文档**：e2e + 单测 + 本节文档

**M5 通过 = Doom 风格多 workspace 日常可用。**

---

## 14. 风险与取舍

| 风险 | 影响 | 缓解 |
|------|------|------|
| 内嵌终端 scrollback / 迷你 VT 边界 | M3b 滚动/OSC 子集不完整 | 采用 vaxis `widgets/terminal`（PTY+VT 已内置）；scrollback 为 vaxis TODO，暂禁用以保滚动正确 |
| tree-sitter parser 编译时间/体积 | 构建变慢 | `-Duse-tree-sitter` 开关；parser 按需增量添加 |
| LSP 协议面广、边界情况多 | M2 延期 | 每个方法配 mock server 测试；先用 zls/gopls 实测闭环 |
| kitty 键盘协议缺失的旧终端 | 部分键位失效 | vaxis 自动降级；确保 16 色 + 标准转义可用 |
| undo 合并语义与 vim 直觉不一致 | 手感偏差 | M0 就建立操作合并测试集，与 vim 行为对照 |
| 多光标 + 补全/自动配对交互复杂 | 状态爆炸 | 编辑统一走"从后往前应用 + 单 undo 组"；复杂组合先禁用再逐步放开 |
| 命令模式范围膨胀 | vim ex 命令上千条，全做不现实 | 只做自己用的子集（§6.7 命令集表），按需增量添加；`<leader>sk` 键位搜索兜底可发现性 |

---

## 15. flow 参考索引（实现时查阅）

| oz 模块 | flow 参考文件 | 借鉴点 |
|---------|--------------|--------|
| buffer/ | `src/buffer/Buffer.zig` `Manager.zig` `Cursor.zig` `View.zig` `reflow.zig` `unicode.zig` | piece table 细节、光标/视图模型、宽字符处理 |
| 终端集成 | `src/renderer/vaxis/` `renderer.zig` `input.zig` | vaxis 封装方式、输入归一化 |
| ui/ | `src/tui/tui.zig` `editor.zig` `Widget.zig` `status/` | widget 体系、区域绘制 |
| lsp/ | `src/LSP.zig` `LSPClient.zig` `lsp_config.zig` | 客户端状态机、server 配置 |
| 补全 | `src/completion.zig` `snippet.zig` | 补全源排序、snippet 模型 |
| keybind | `src/keybind/keybind.zig` `parse_vim.zig` `builtin/` | 键位表结构与 vim 绑定 |
| 命令模式 | `src/command.zig` `command_line.zig` `tui/InputBox.zig` `inputview.zig` | cmdline 编辑、补全、历史 |
| 测试 | `test/tests.zig` `tests_buffer.zig` `tests_buffer_input.txt`/`tests_buffer_output.txt` | refAllDecls 聚合、golden 文件对模式 |
| git | `src/VcsStatus.zig` `VcsBlame.zig` `git.zig` | diff 解析、blame 线程化 |
| grep | `src/ripgrep.zig` | rg 子进程封装 |
| 终端仿真 | `src/terminal/`（Terminal.zig、Parser.zig、Screen.zig、xterm.zig） | M3b 迷你 VT 仿真 |
| 文件树/遍历 | `src/walk_tree.zig` `src/gitignore/` | 目录遍历 + gitignore 过滤 |

---

## 16. 下一步

1. 评审本设计（重点：§2 选型、§3 架构、§13 顺序）
2. 确认后开始 **M0**：先搭 build（vaxis 依赖）+ 事件循环骨架，把当前 `src/main.zig` 的 kilo 风格代码迁移进新结构
3. 每个 Milestone 结束提交一次可运行版本（git tag）

---

## 17. AI Chat（M1，`feat/ai-chat`）

> 目标：先交付一个可日常使用的 **chat-first** 面板；tools / 自动改文件 / inline assistant 留到 M2/M3。与 spec §9 的"AI 能力"相比，本节只覆盖 M1 范围。

### 17.1 模块划分

```
src/ai/
  sse.zig      增量 SSE 解析（data: 多行、CRLF/LF、[DONE]、任意字节切分）
  openai.zig   request JSON 构造、delta 解析、API error body 解析
  context.zig  有界编辑器上下文（路径 / 选区 / 光标窗口，UTF-8 安全截断）
  config.zig   纯环境变量解析（OZ_AI_*）
  client.zig   单条在飞流：后台线程 + Mutex 队列 + 原子取消
  panel.zig   模态面板按键分类（纯函数，可单测）
src/app/ai.zig  会话状态 / 键处理 / 请求生命周期 / 渲染
```

- `src/ai/*` 不依赖 App，全部可单测；`app/ai.zig` 通过 App 字段方法组接入（`Aliases` 在 `app.zig`）。
- 会话状态 `App.ai` 是 **session 级**（不随 workspace 切换）：关闭面板保留会话，workspace 切换不动 AI thread。
- UI：居中 float，宽 `min(96, cols-4)`、高 `min(28, rows-4)`；圆角边框 + ` AI ` 标题 + 一行状态（model + idle/streaming…/cancelled/error）+ transcript + 底部 `❯ ` prompt。所有面板 cell 统一 `bg_float`，逐行按 **cell** 补齐，边框复用 filetree/picker 的宽度对齐经验。

### 17.2 Provider 协议

- `POST {OZ_AI_BASE_URL}/chat/completions`，body：
  `{"model": ..., "stream": true, "messages":[{"role":"system"|"user"|"assistant","content":...}]}`。
- SSE：只消费 `data:` 行；`[DONE]` 或 `choices[0].finish_reason` 结束；解析 `choices[0].delta.content`；malformed JSON 忽略（不让一条坏 chunk 终止整条流）。
- 非 2xx：优先解析 `{"error":{"message":...}}`，否则用响应体前 8 KiB，面板显示一行 `HTTP <code>: <message>`。
- TLS：`std.http.Client` + 标准 CA bundle（`rescan`），**不关闭证书校验**。API key 仅存在于 request 头 / 进程内存，不写日志、不落盘。
- 每帧由 `App.run` 的 `drainAi()` 排空事件；后台 worker 只把 **owned bytes**（job spec / delta / error）跨线程传递，UI 线程永不阻塞。

### 17.3 取消与上下文

- Ctrl+c：主线程立刻置 `cancelled` 并 `client.requestCancel()`；此后排空到的事件全部丢弃，worker 在下一个 chunk 边界退出。Ctrl+n 清空会话并同样取消。
- 上下文：始终 `Current file: <path>`；有 visual 选区时 `Selected lines A-B:` + 选中文本；否则 `Cursor line: N` + `Context (lines A-B):`（光标 ±10 行）。总输出 ≤8 KiB，按 UTF-8 边界截断，追加 `… [truncated]`。
- 自动滚动：streaming 时跟随底部；Ctrl+j/k 或 PageUp/PageDown 手动滚动后关闭自动跟随，下一次发送重新开启。

### 17.4 测试接缝（test-only，不对外文档化）

`OZ_AI_MOCK_DIR=<dir>`：client 完全跳过 HTTP，改为

1. 把**原始 request body** 原子写入 `<dir>/request.json`（temp + rename）；
2. 若 `<dir>/error.txt` 存在，推送该文本为 error 事件并结束；
3. 以 32 B / ~8 ms 的节奏回放 `<dir>/stream.sse`，让 e2e 能观察到真正的增量帧。

该接缝用于 `zig build e2e` 的确定性断言（request body 含 model/prompt/选区、流式增量、取消、error）；生产路径仍是真实 HTTP。

### 17.5 Roadmap

- **M1（已完成）**：centered chat 面板、流式 SSE、上下文、取消、错误降级、mock e2e。
- **M2**：workspace 化布局（右侧 Agent Rail + Workbox、Notes/Navigator、线程管理）与 inline assistant/diff。
- **M3**：agent tools（read/search/apply edit，带权限确认）、tool cards、调用次数/平均耗时折线图、ACP client、MCP server 接入。

---

## 18. AI Workspace 布局（M2/M3，2026-10-25 已确认）

参考可交互原型：`.demo/ai-workspace/`（local only，untracked）。原型不是生产代码，只用于确认布局与交互。

### 18.1 布局原则

```text
[左侧 navigator] [中间 editor / notes] [右侧 Agent Rail + Workbox]
```

- 不使用“四栏并排”；右侧 rail 是第二个工作面，不是第三个侧栏。
- Notes 是 **buffer**，不是固定特殊侧栏；Files/Notes/Agents 是左侧 navigator 的 tab。
- Agent 是 **thread**，不是 pane：可以 attach/detach，关闭 pane 不删除 thread。
- 线程列表默认按 workspace 分组、扁平排列；只有 parent/child subagent 缩进一层。
- Workbox 是右侧单主视图 + tab：`Chat / Changes / Tools / Terminal`，避免同时铺开四块内容。

### 18.2 宽度行为

| 宽度 | 行为 |
|---|---|
| ≥ 110 列 | 三栏：navigator + editor + rail（rail 38–42 列） |
| 90–109 列 | 三栏：rail 34 列，navigator 可收窄 |
| < 90 列 | editor 单栏；rail 作为右侧 overlay drawer，Esc/`a` 关闭 |

Narrow drawer 必须有遮罩/焦点陷阱，不能挤压编辑器到不可用宽度。所有宽度按 cell 计算，不能出现横向溢出。

### 18.3 区域职责

- **Navigator**：`Files / Notes / Agents` 三个 tab；Files 复用现有文件树，Notes 是 note 列表，Agents 是紧凑线程列表。
- **Agent Rail**：按 workspace 分组的线程；状态点（streaming / waiting approval / idle / error）、未读/待批准 badge、new thread、archive。
- **Workbox Chat**：M1 的流式对话与输入；tool cards / approval cards 后续内联。
- **Workbox Changes**：待审 diff / 文件变更，Approve/Reject 与 Chat approval、badge 联动。
- **Workbox Tools**：M3 工具卡片 + 调用次数 + 平均耗时折线图；空状态不能伪造数据。
- **Workbox Terminal**：agent 启动的终端输出（M3 后期）。

### 18.4 里程碑拆分

- **M2a（layout shell，已完成）**：右侧 dock rail / narrow drawer；线程模型与 thread rail；workbox Chat + Changes（空状态）+ Tools/Terminal 诚实占位；现有 `<leader>a` 改为打开/聚焦 rail；保留 M1 streaming/cancel/error。实现状态见 §18.7。
- **M2b1（navigator + notes，已完成，2026-10-25）**：左侧 navigator 三 tab（files/notes/agents）、真实 note 文件 + 普通 buffer、Notes 列表、Agents 真实线程视图、tab/行 hint 目标；实现状态见 §18.8。
- **M2b2（已完成，2026-10-25）**：visual 选区 inline assistant；紧凑 prompt；真实 diff；Changes 中显式 Approve/Reject + 单 undo group；`<leader>i`、hint 目标与 80 列适配。实现状态见 §18.9。
- **M3a（tools）**：tool protocol、权限确认、tool cards、read/list/grep/edit/apply_patch；agent loop。
- **M3b（metrics）**：per-tool count/avg/success/fail；最近 N 次耗时 ring buffer；braille/线条折线图；窄屏 sparkline fallback。

### 18.5 焦点与按键（草案）

> M2a 已按 §18.7 落地；下面保留最初的草案，实际策略以 §18.7 为准。

- `<leader>a`：打开 rail 并聚焦 workbox 输入；再按 toggle/`Esc` 返回 editor（rail 保持可见）。
- `Ctrl+w` 在 editor / navigator / rail 之间切换；`Tab` 在 workbox tab 间切换。
- rail 聚焦时：`j/k` 选 thread，`Enter` attach，`n` new thread，`x` archive，`c/d/t` 切 Chat/Changes/Tools。
- 输入框聚焦时，所有 editor 快捷键失效（沿用 M1 的 modal input guard）。
- narrow 模式：`Esc` 关闭 drawer；`a` 重新打开。

### 18.6 验收与测试

- 所有布局在 80/100/120 列下边框/背景对齐，无 cell 溢出。
- 线程创建/切换/流式隔离；切换线程不会把 A 的 delta 写进 B 的 transcript。
- Chat/Changes badge 联动；空状态真实，不显示假工具/假数据。
- 现有 e2e + 单测全绿（M2a 完成后：136 个 e2e、343 个单测）；新增 M2a e2e 覆盖 dock/drawer、thread 切换、focus guard。

### 18.7 M2a 实现状态（已完成，2026-10-25）

**布局（cell 精确，单一来源 `src/ai/workspace.zig: layout()`）**

| 终端宽度 | rail | editor 可用宽度 |
|---|---|---|
| ≥ 110 | dock 38 列（含 1 列左边框） | `cols - 38` |
| 90–109 | dock 34 列 | `cols - 34` |
| < 90 | overlay drawer `min(34, cols - 8)` | `cols`（rail 覆盖在上层） |

- rail 从第 0 行画到状态栏上方；状态栏始终全宽。dock 模式 rail 左边界即 editor 右边界，`layoutWindows` / tab bar / dashboard / split 全部改用 `aiEditorWidth()`，不会把 editor 画到 rail 上。
- drawer 模式不挤压 editor，也不画假遮罩；左侧 editor 保持可见，Esc 关闭 drawer。rail 内部全部 cell 填 `bg_float`，左边界聚焦时 accent、失焦时 `fg_faint`。
- rail 上方为紧凑线程栏：`▥ agents N +`、workspace 分组、线程状态点 + 标题 + 状态；下方为 Workbox：活动线程 header、tabs、body、Chat 的 prompt 行。

**焦点策略（实际实现）**

- `<leader>a` 是可见性 toggle：关闭 → 打开 rail 并聚焦 **prompt**（Workbox 切到 Chat）；已打开（editor 或线程列表聚焦时）→ 关闭 rail 并把焦点还给 editor。prompt 聚焦时所有可打印输入都归 prompt，因此不能在 prompt 内用 leader 关闭；先 Esc（回 editor，rail 保持）再 `<leader>a` 关闭，或 Tab 到线程列表再 `<leader>a`。
- `<Ctrl-w> a`：从 editor 重新进入 rail 的**线程列表**（rail 关闭时也会打开）。这是 editor → rail 的固定回入口；Ctrl-w hjkl 不变。
- prompt：Enter 发送，Ctrl+c 取消，Ctrl+n 新建线程，Tab → 线程列表（prompt 是单行，不接收 tab 字符），Ctrl+j/k 单行滚动，PageUp/PageDown 翻页，Esc → editor（narrow：关闭 drawer）。
- 线程列表 / workbox：`j/k` 移动线程光标，Enter attach 并聚焦 prompt（切回 Chat），`n`/`+` 新建线程并聚焦其 prompt，`c/d/t/r` 切 Chat/Changes/Tools/Terminal，Tab/Shift+Tab 循环 tab，`q`/Esc → editor（narrow 关闭 drawer）。
- dock 且 editor 聚焦时 rail 非模态：所有 editor 快捷键、pickers、command mode、宏录制、文件树、终端焦点均照旧；rail/prompt 聚焦时按键先在 AI 层消费，终端焦点仍最优先。
- 焦点可见性：rail 左边框 accent（rail/prompt 聚焦）/ `fg_faint`（editor 聚焦）；prompt 显示 beam cursor，线程列表显示 block cursor。

**线程切换策略（实际实现）**

- `src/ai/workspace.zig: Threads` 持有 session 级 `items` / `active` / `next_number`；`src/app/ai.zig: Session` 另持有一一对应的 `clients`。线程标题由 `next_number` 生成（`thread 1`、`thread 2`…）。
- 每个线程独立保存 messages、prompt draft、status、error、scroll/auto-scroll、view 尺寸和 cancel_requested；client 与线程索引一一对应。
- 切换（`select`）离开一个 `streaming` 线程时：该线程 `status = cancelled`、`cancel_requested = true`，App 调 `client.requestCancel()`；transcript 冻结。迟到的 delta 在 `drainAi` 中按线程丢弃（`cancel_requested` 时直接 free，不写入任何 transcript），`applyDelta` 也拒绝非 streaming/已取消线程。
- 同一时刻最多一个 streaming 线程：新建线程、Ctrl+n、以及 aiSend 的防御性循环都会取消其他 live stream。
- 切回已取消线程显示冻结的 transcript（含 `[stream cancelled]` 标记），不会被后续事件修改；各线程的请求体只包含自己的 messages（验证见 e2e `thread B streams while A is frozen`）。
- 关闭 rail 不删除线程、不取消流；workspace 切换也不动 `App.ai`；不落盘。

**范围与限制**

- 仅 M2a：不做 tools、真实文件编辑、diff/Approve、Notes/Navigator tab、inline assistant、工具计数/耗时图、agent shell。Changes 显示 `no pending changes`（badge 0）；Tools 显示 `tools arrive in M3`；Terminal 显示 `agent terminal arrives in M3` 并提示现有 `Alt+r`。
- 线程 archive 未实现；鼠标操作见 §21（线程行可点击 attach、滚轮移动选择）。
- 现有 `[stream cancelled]` 是 UI 标记，不是协议消息。

**文件**

- `src/ai/workspace.zig`：布局/焦点/线程模型 + 单测。
- `src/ai/panel.zig`：prompt / rail 按键分类。
- `src/app/ai.zig`：Session、每线程 client、drain、焦点路由、rail/Workbox 渲染。
- `src/app/input.zig`、`src/app/render.zig`、`src/app.zig`：焦点路由、editor 宽度、状态栏与 cursor。
- `test/e2e.zig`：M2a pty 测试（120 dock / 80 drawer / A-B 线程隔离 / tabs / M1 选区、取消、错误）。

**验证**

- `zig build test`：343/343 通过。
- `zig build e2e`：136 个 pty 测试全部通过（exit 0，无失败输出）。

---

### 18.8 M2b1 实现状态（navigator tabs + notes，2026-10-25）

**布局（cell 精确）**

- 侧栏宽度不变（`filetree_width = 30`，`contentCol()` 仍为 30），因此 editor/split/rail 的全部宽度计算不变；80/100/120 列都没有横向溢出。
- 顶栏即原 `╭─ files` 标题行，改为 tab strip：`╭─ files ─ notes ─ agents────╮`（30 cells 内精确放下）。active tab 用 `bg_sel` + bold，非 active 用 `fg_dim`；`files` 子串与面板左上 `╭` 保持原位，既有 `findBoxByTitle("files")`/row-2 几何断言继续成立。hint mode 下三个 tab 都是 target（label 覆盖 tab 首字符），因此 hints 场景用「30-cell box at column 0」而不是标题文本定位面板。
- 内容区沿用原 filetree 几何：`contentTop()+1 .. status bar-1`，底部仍有闭合边框；每个 tab 的列表在该区域内滚动。

**焦点与按键（实际实现）**

- App focus 由 `Focus.filetree` 改名为 `Focus.navigator`（语义更新，行为沿用 Ctrl-w h/l + `<leader>e`）。
- `<leader>e`：关闭 → 打开 navigator 并固定落在 **files**（`<leader>E` 同样落 files 并 reveal 当前文件）；已打开 → 关闭并把焦点还给 editor。
- navigator 聚焦时：`Tab` 下一个 tab、`Shift-Tab` 上一个、`1/2/3` 直接 files/notes/agents（`src/app/navigator.zig` 纯模型）。这些按键先于 per-tab handler 消费，所以 files tab 的 `h/l` 仍是折叠/父目录，不与 tab 切换冲突。
- Files：原 filetree keys 完全不变（j/k/Enter/h/l/Esc）。
- Notes：`j/k`（含方向键）选择、Enter 打开、`n` 新建、`r` 刷新、Esc 关闭 navigator。
- Agents：`j/k` 选择、Enter `aiSelectThread`（必要时先打开 rail）、`n` `aiNewThread`、Esc 关闭。选择光标复用 `ai.thread_cursor`，不是第二份线程光标；Enter 后键盘属于 rail prompt。
- hint 动作新增 `navigator_tab` / `note_open`；`agent_thread_select` 现在会先把 rail 打开，保证从 navigator 触发时 attach 可见。切换 navigator tab / 打开 note 时把 AI focus 置回 editor（rail 可保持可见），避免 rail 模态吞掉后续导航键。

**Notes 持久化（实际实现，`src/app/note_store.zig`）**

- 路径优先级：`OZ_NOTES_DIR`（文档化的用户覆盖 + e2e seam）→ `$XDG_DATA_HOME/oz/notes` → `$HOME/.local/share/oz/notes`；任一为空则继续 fallback，全部缺失时 Notes tab 显示 `! notes unavailable`（不崩溃）。解析结果缓存，`OZ_NOTES_DIR` 相对路径会规范化成绝对路径。
- 目录惰性创建：启动/打开 editor 不创建；首次进入 Notes tab（list）或首次 `n`（create）时才 `createDirPath`。`OZ_NOTES_DIR` 不可用时只在 tab 内显示错误与 status message。
- 新建：`note-<N>.md` 取最小未占用 N（`noteNameNumber` 只识别这个窄格式），`O_EXCL` 创建，内容精确为 `# Untitled note\n\n`；绝不覆盖已有文件。打开走既有 `openFile`/`openInBuffer`，`:w` 走既有原子保存。
- 列表：每篇 note 读前 8 KiB 提取 title（首个 ATX heading，否则文件名）与 snippet（首个非空、非 heading 行，去掉 `>`/列表符，最多 160 bytes 且不切断 UTF-8）。排序 = mtime 降序，mtime 相同按 filename 降序（确定性；刚创建的 note 在最上）。相对年龄 `now/Nm/Nh/Nd` 每帧只取一次时钟。
- 缓存/刷新：`Store.items` 是缓存，只在 **tab 进入 / 新建后 / `:w` 保存了 note / `r`** 时重建；渲染只读缓存，不逐帧 scan。刷新按 path 保留选择；保存 note 后立即刷新（`notesDidSave`，仅当路径在 notes 目录内）。
- notes 是全局/项目无关：`openInBuffer` 对 notes 路径跳过 `setProjectRoot`，所以打开 note 不会把 workspace 文件树/picker 根到数据目录。

**范围与限制**

- 仅 M2b1：没有 inline assistant、diff、Approve/Reject、tool cards；Changes/Tools/Terminal 仍是 M2a 的空状态/占位。
- Notes 没有删除/重命名（破坏性操作需要单独设计）；没有 note 搜索/标签/附件；不做 notes 目录 watch（刷新是显式路径）。
- 单行 snippet；超长标题按 cell 截断；时间只有相对粒度。
- Agents tab 是线程模型的视图：线程本身仍是 session 级、不落盘、随 rail 关闭/workspace 切换保留；navigator 不新增线程状态。
- hint target 仍受 128 容量限制；Notes 列表只注册可见行。

**文件**

- `src/app/navigator.zig`：Tab 模型 + 单测。
- `src/app/note_store.zig`：路径解析、扫描、title/snippet、命名/创建、排序、age + 单测。
- `src/app/notes.zig`：App 缓存/刷新/创建/打开/tab/keys/Agents 动作/cursor 行。
- `src/app/render.zig`：navigator tab strip + files/notes/agents 渲染；hint targets。
- `src/app.zig`、`src/app/input.zig`、`src/app/filetree.zig`、`src/app/hints.zig`、`src/app/hint_ui.zig`：类型/焦点/路由/动作接线。
- `src/app/buffers.zig`、`src/app/search.zig`：notes 路径不改变项目根；保存后刷新缓存。
- `test/e2e.zig` + TESTING.md：navigator/notes/agents/hints/80 列/错误路径 e2e 与 `@navigator`/`@notes` scenario。

**验证**

- `zig build test`：376/376 通过（新增 navigator/note_store 单测，未改动既有断言）。
- `zig build e2e`：151/151 通过（原 145 + 6 个 M2b1 pty 测试），新增 scenario `navigator notes 120x30` / `navigator agents 100x30`。
- 无 golden 变更（golden 帧不含 navigator）。

---

### 18.9 M2b2 实现状态（inline assistant + pending diff，2026-10-25）

**入口与 prompt**

- editor/visual/visual-line 有选区时 `<leader>i` 打开 **inline edit** prompt；`visual_block` 也按 anchor→cursor 的连续区间处理。没有选区时只在状态栏提示 `inline edit: select lines first`，不改变任何状态。已有 pending edit 时提示 `inline edit: reject the pending change first`（one-pending policy，绝不静默替换）。
- prompt 是居中 float：宽 `min(64, cols-4)`、高 6、精确圆角边框；标题 `inline edit`。内部 4 行：model + 状态（`ready` / `streaming…` / `error`）、`❯ ` 输入行（beam cursor）、`Enter generate · Esc cancel`（错误时显示 `error: …`）、`lines A-B · N bytes · file`。80/100/120 列都不越界，也不覆盖状态栏。
- 输入支持 UTF-8（vaxis 的完整 `key.text`）与 bracketed paste；换行/tab 在单行 prompt 中折叠为空格（tab → 4 spaces）。Enter 生成、Esc/Ctrl+c 取消、Ctrl+w 删除最后一个词。prompt 打开期间按键在 `handleKey` 最前被截获，editor/AI/tab/leader 快捷键与普通 vim 序列都不可达；visual 选区保持可见。
- 只有 prompt 自身（及其流式状态）拥有键盘；`<leader>i` 之外的普通编辑键不会进入 buffer。

**请求（独立于 chat thread）**

- 新增独立 client `App.inline_edit.client`（`src/ai/client.zig` 复用，不复制 HTTP/SSE）；同一时刻最多一个 inline 流。chat/thread transcript 不读不写，请求体只有固定 system prompt + 一条 inline user message。
- system prompt 要求只返回选区替换文本，不要 fences/解释；user message 含文件路径、1-based 行范围、instruction、选区文本。选区文本最多 16 KiB 且只按 UTF-8 边界截断；完整选区仍保存在 snapshot 中用于 diff/approval。
- `OZ_AI_MOCK_DIR` 仍走同一 client seam（写 `request.json`、回放 `stream.sse`），e2e 用它验证请求体与流式行为。
- Esc/Ctrl+c 调 `requestCancel()` 并立即关闭 prompt；之后到达的 delta/done 全部丢弃。错误（配置/启动/流）留在 prompt 的 `error:` 行，buffer/历史不变；可修改 instruction 后重试。

**Pending edit 与 diff**

- 流完成时（`done`）把 streamed text 经 `stripFences` 处理（仅当首行是 ```[lang]、末行是闭合 ``` 时剥离，其他情况逐字节保留），构造 `Pending`：buffer index、path、原始 byte range、原始文本、replacement、生成时 `history.revision`、1-based 行范围、缓存的 diff 行与统计。
- diff 在完成时计算一次（行级 LCS；两侧超过 400 行时退化为“全部删除 + 全部添加”，仍真实），渲染只遍历可见行；不逐帧重建。context 行原样、`- ` 用 `diag_error`、`+ ` 用 `string`，行超宽按 cell 截断。
- 完成即：必要时打开 rail、切到 **Changes**、badge 变 `changes 1`、焦点落在 workbox。Changes 固定显示 `path · lines A-B`、`-N +M`（stale 时追加 `stale selection`）、`[a] approve  [r] reject`、空白行和 diff 行；diff 不足时剩余行仍画左/右边框，空状态仍是 `no pending changes`。
- 长 diff 可用 `j/k` 滚动（只改 `pending_scroll`，不重新 diff）。

**Approve / Reject / undo**

- Approve（`a` 或 Enter，或 hint 标签）先验证：buffer 仍存在（有 path 时按 path 重新定位）、`history.revision` 等于生成时值、range 在界内、`[start,end)` 当前字节等于 original。任一失败 → `stale selection`，pending 保留并标 stale，绝不应用到移动后的文本。
- 验证通过后 `switchTo`（若需要）+ `applyEdit(start, end, replacement)`：`applyEdit` 内部 `beginGroup/record/endGroup`，因此整个替换是 **一个 undo group**；`u` 一次恢复原文。随后 dirty、cursor 落在 range start、清除 pending（badge 0）、焦点回 editor、状态栏 toast `inline edit applied · u to undo`。
- Reject（`r`/`d` 或 hint 标签）只释放 pending、badge 0、焦点回 editor，不触碰 buffer/history/revision；toast `inline edit rejected`。不存在“静默 auto-apply”。
- Changes 的 review 键只在“tab=Changes 且存在 pending”时覆盖：`a`/Enter approve、`r`/`d` reject、`j`/`k` scroll；无 pending 时 `r`/`d` 仍是原来的 Terminal/Changes tab 切换。hint action 新增 `inline_approve` / `inline_reject`，按钮 rect 在渲染时注册，`<leader>j` 可激活；这些键在输入框中不可达（prompt 先消费所有按键）。

**与 chat/rail 的关系 / 限制**

- inline 有独立 client 和独立状态；chat 线程仍各自一份 client/transcript，两者可并存流式，互不写入。inline 完成会打开 rail 并抢占焦点，但不会 attach/修改 thread。
- 只支持一个 pending、一个 inline 流；不提供多文件/多 hunk 队列或“替换为第二个候选”。block 选区按连续区间处理，不做矩形替换。
- diff 是行级 LCS（上限 400 行/侧），没有 word-level diff、语法高亮或 hunk 折叠；长行截断而非软换行。
- pending 不存在 workspace 隔离：切换 workspace 后 pending 仍显示，approve 会因找不到对应 path/revision 而 stale，必须 Reject；这是安全失败而非静默丢失。
- 不自动保存：approve 只改 buffer（dirty），写盘仍由用户 `:w`。

**文件**

- `src/app/inline.zig`：纯选区映射、bounded UTF-8、fence 剥离、行 LCS diff、snapshot/pending/one-pending policy + 单测。
- `src/app/inline_ui.zig`：prompt、独立 client、stream drain、approve/reject、Changes 渲染、hint 按钮。
- `src/app.zig`、`src/app/input.zig`、`src/app/render.zig`、`src/app/ai.zig`、`src/app/hints.zig`、`src/app/hint_ui.zig`：状态/路由/rail badge/diff/hint 接线。
- `src/editor/key_event.zig`、`src/editor/mode.zig`、`src/editor/keymap_list.zig`：`<leader>i`。
- `test/e2e.zig` + TESTING.md：approve/undo、reject/one-pending、stale、cancel、80 列/hint、`@inline` scenario。

**验证**

- `zig build test`：389/389 通过（原 376 + 13 个 inline 纯模型单测，未改动既有断言）。
- `zig build e2e`：156/156 通过（原 151 + 5 个 inline pty 测试），新增 scenario `inline edit 120x30` 与 required tag `@inline`。
- 无 golden 变更（inline prompt/diff 不进入固定 golden 帧）。

---

### 18.10 UI chrome clarity（feat/ui-chrome，2026-10-25）

只改视觉层次，不改键位、行为、数据或提示目标；goldens 因布局变化显式重建。目标是让 TUI 的四个工作面（navigator / editor / rail / workbox）和底部状态区一眼可分，接近批准原型的清晰度。active tab / separator 的具体颜色随后在 §18.10.1 全部主题化，本节中写死的 accent/fg_dim 描述由该节取代。

- **状态带**：`status_row_count` 从 1 改为 2（一行 `─` 规则 + 一行状态）。编辑器、rail、floats 的高度计算统一走该常量，因此内容不会画进状态带；编辑器与 rail 各让出一行。状态行分 `[workspace] │ [MODE] │ line/col │ ⎇ branch`，右侧 `agent … │ dock/drawer`；80 列仍走 compact/mini fallback，不横向溢出。`[MODE]` 用 accent 背景的 badge，普通行保持 bg_status。
- **Agent Rail**：`AGENTS  N` header band（bg_status）+ workspace `name / workspace`；active thread 用 ASCII `>` + bold，非 active 状态用 `o/*/x/!`。thread list 与 workbox header、tab strip 与 body 之间各一条 `├──` rule；active tab 同时有 `>`、accent 与 bg_sel（monochrome 下仍可区分）。38-cell rail 的 tabs 使用带呼吸感的 `>chat│ changes N │ tools │ terminal`（35 cells 内精确放下），34-cell rail（100 dock / 80 drawer）继续用紧凑 `>chat│changes N│tools│terminal`；hint target 随 label 起点移动。rail 左侧固定留 1 列空白 gutter：dock 模式不计入 editor 宽度，drawer 模式在 editor 之后覆盖最后一列，因此 text/blame 均不触碰 `│`。`▥`、`●/○/◌/✖`、`▸/▾` 等易 tofu 的装饰字形不再用于 AI/nav chrome；tool card 状态图标也改为 ASCII。rail 左边界未聚焦时用 `fg_dim`（原来 `fg_faint` 太容易消失在 bg_float 里）。
- **Navigator**：top strip 为 `╭─ files │ notes │ agents ───╮`（精确 30 cells），active tab accent + bg_sel + bold，inactive dim，`│` 明确分隔；标签起始列仍为 3/11/19，hint target 不变。box 与 editor 之间固定 1 列空白 gutter（`contentCol()` 从 30 变为 31），editor text/cursor/tab 都不再贴住 `╮`。Notes/Agents 的 selected row 保留 bg_sel fill；Notes 选中标记与 Agents active thread 标记改为 ASCII `>`，Agents 的组标题去掉 `▾`。
- **Blame ghost**：仍在 editor content pane 内绘制；rail 打开时（dock 或 drawer）额外 clip 到 `rail_col - rail_gutter`，即 rail 前固定保留一个空格，不触碰 agent 列。rail/workbox 仍最后绘制，因此 ghost 永远不能覆盖 rail 文本；放不下时直接截断/丢弃，绝不画一列进 rail。
- **性能**：规则行用 `writeCell` 写静态 `─`，状态文本使用栈 buffer，不新增普通帧堆分配；rail header count 沿用 frame arena（vaxis 在 render 前引用文本）。
- **测试**：491 unit / 178 e2e（主题化后为 493 unit / 179 e2e，见 §18.10.1）。新增 120 dock 与 80 drawer 的 chrome e2e（header band、两条 rule、tab 分隔/active 样式、status 规则行与 section 分隔、禁止 glyph 扫描、nav/rail 空白 gutter）和 blame/rail 裁剪 e2e；goldens 仅通过 `OZ_UPDATE_GOLDEN=1` 重建（最终 gutter 轮只改 120 dock 的 tab 行：38-cell rail 的 separator 呼吸空间；80 drawer 的短行从未占用新 gutter，故 cell 不变）。

#### 18.10.1 Theme-aware chrome（feat/theme-chrome，2026-10-25）

用户反馈 active tab 与部分分隔线在所有主题下都读成同一种灰色。本节把 active tab / rule / panel border 的颜色从 renderer 里零散的 `theme.*` 取值提升为 `src/app/chrome.zig` 的纯风格函数，navigator、buffer tab bar、workbox 共用，避免三处漂移。

- **active tab**（navigator / buffer / workbox）：`bg_sel` 软选择底 + `fg` 加粗文字 + `accent_alt` 单下划线（SGR 4 + 58 真彩色，等价 demo 的蓝色 inset underline）；workbox 的 `>` marker 与 active buffer icon 同用 `accent_alt`。不是灰色，也不是整块饱和 accent 填充；monochrome 下仍靠 bold + `>` + underline 区分。catppuccin-latte / flexoki-light 等浅色主题同样成立（单测检查 `fg`/`bg_sel` 对比度 ≥3:1，16 个主题实测最低 3.61:1，即 catppuccin-frappe）。
- **separators / rules**：`separatorStyle(theme, emphasis)` 统一取 `accent_alt`：minor（navigator tab `│`、workbox tab `│`、status section `│`）加 `.dim=true`；major（workbox 两条 `├──` rule、status 顶部通栏 `─`）保持全亮。panel border 走 `panelBorderStyle(theme, focused)`：未聚焦 `win_sep`，聚焦 `win_sep_active`（主题 accent），navigator 与 rail 一致。
- **active thread row**：`>` marker 使用 `accent_alt`；prompt/rail 聚焦时整行仍是 `bg_sel`，否则落在 `bg_float` rail 底上，不再只有灰色。
- **scope/性能**：只映射样式，无键位、行为、hint target 或布局改动；helper 返回 `vaxis.Style` 值，无每帧分配。`fg_faint` 仅保留给非 active 的次要文字。
- **测试**：493 unit / 179 e2e。单测覆盖全部 16 个主题（active tab = `bg_sel`/`fg`/bold/`accent_alt` underline；minor/major/panel 均非 `fg_faint` 且跨主题不同；浅色主题有效）；新增 `ui chrome: theme matrix ...` e2e，用临时 HOME + `~/.cache/oz/theme`（生产 `loadTheme` seam）分别加载 kanagawa-wave / catppuccin-mocha / flexoki-light，逐 cell 校验 nav/buffer/workbox active tab 的 fg/bg/underline、tab/rule/status 分隔线的 accent、focused rail/navigator border，并断言三种主题的实际渲染色两两不同。goldens 通过 `OZ_UPDATE_GOLDEN=1` 重建：只有 fg/bg style run 变化（active buffer tab 底色、workbox marker/underline、rule/status 颜色），row text 未变。

#### 18.11 Two-row buffer strip（feat/ui-polish，2026-10-25）

用户反馈顶部 buffer tabs 太小、不像批准 demo 的 `.buffer-bar`。本节只放大/重组 buffer strip，不改键位、buffer 模型、关闭语义或其它工作面；内容整体下移一行，goldens 因布局变化显式重建。

- **两行结构**：第 0 行是 tab labels，第 1 行是编辑器区域通栏 `─` rule + active tab 的 `accent_alt` inset underline segment；内容从两行之下开始。split 时每个 column-overlap layer 各占一个 label row，所有 layer 共享同一条 rule row（`tabBarRows = layers + 1`），因此 stacked pane 不会重复画 rule，也不会让内容画进 strip。高度极小时 `tabBarRows` clamp 到可用行数，dashboard/空 buffer 仍保留 strip 与 rule，不塌陷。
- **tab 几何**（纯模块 `src/app/tabstrip.zig`）：body 最小 20、最大 26 cells；固定 2-cell 左侧内边距 + devicon + 空格 + filename + 保留的 dirty 列（`●`）+ 空格 + close `×` + 2-cell 右内边距；tab 之间一条 `│`。dirty 列即使 clean 也保留，输入时 tab 宽度不跳动；close 位置固定在 body 右端，hint target 与之同源。粗算：`fixed_cells = 9`，name region = body - 9（11..17 cells）。
- **宽度/滚动**：filename 超宽时 middle-ellipsis（保留可读前缀 + `…` + 8-cell 后缀），比 CSS 的尾部省略更能在窄 cell 中保留扩展名/尾标识；`plan()` 在总宽超限时以 active tab 为锚，先向右再向左填充可见邻居，返回每个可见 tab 的 x/width/name 区/close 列。80/100/120 下切换 buffer 始终完整显示 active tab；不可见邻居由 `hidden_left/right` 表示，不画越界内容，也无额外滚动键位。
- **样式**：label row 底色 `bg_status`（bar 层级），inactive tab 用 `fg_dim`（diff/note 未 active 时仍用 `constant`/`type` 语义色），active tab 保持 §18.10.1 的 `bg_sel` + `fg` bold + `accent_alt` underline；active icon/marker 同 accent。rule row 用 `win_sep` 的 dim hairline（demo `.buffer-bar` 的 border），active segment 用亮 `accent_alt`，因此 rule 与 active inset 在 cell 层面可区分。split 的每个 pane 各自按自己的 active buffer 画 underline。
- **hint / 关闭**：tab 的 select target 从 icon（左内边距之后）开始且覆盖 tab body；clean/dirty 均可注册 close target。新增 `hints.Action.buffer_close`，动作直接调用既有 `closeBufferAt`（`:bd` / `<leader>bk` 同一条路径，最后一个 buffer 不注册 target，无第二套破坏性逻辑）。关闭 dirty buffer 仍是既有语义，不新增确认框。
- **性能/测试**：plan 为 O(tabs)、固定可见槽位、零分配；renderer 复用 frame arena 的 spec 映射，无每帧堆分配增长。单测覆盖 min/max width、icon/name/dirty/close 几何、middle-ellipsis 分配、active 可见性（80/100/120）、>64 visible 的截断、空/单 tab/clamp；e2e 新增 `ui buffer strip:` 三尺寸（120x30/100x30/80x24）和 split shared-rule 测试：逐 cell 校验 two-row 高度、rule/underline、`bg_sel` active、`×` 与 close hint 动作、内容首行、无水平溢出。
- **测试计数**：510 unit / 185 e2e。

#### 18.12 Motion（feat/ui-polish，2026-10-25）

目标是把 demo 的 `dot-pulse` / `running-pulse` / `badge-pop` 语言带进 TUI，但只在有真实活动时动；空闲编辑器没有任何 timer 或逐帧重绘。纯函数在 `src/app/animation.zig`，不依赖 App/vaxis/分配。

- **streaming pulse**：thread 的 dot/status 颜色在 `accent` ↔ `accent_alt` 之间按 `stream_pulse_ms = 900` 三角波插值（`pulseColor`），只对 `.streaming` 状态生效；idle/cancelled/error 保持静态语义色。rail thread row 与 workbox header 的 status 文案同步脉冲，active marker 仍可读。
- **running tool spinner/pulse**：running card 的 icon 每 `spinner_step_ms = 120` 循环 ASCII `| / - \`，status 文案与 icon 颜色同步 pulse；ok/err/approval 等终态立即回到静态 icon/颜色。终态后不再有状态变化。
- **Changes badge flash**：workbox 的 `changes N` 在 pending count 真正变化时获得 `badge_flash_ms = 420` 的颜色脉冲 + bold；`review_flash_start_ms` 是显式 deadline，`reviewFlashActive()` 到期即 false。首次打开 rail 初始化基线，不误闪。
- **run loop / idle safety**：`animationActive() = aiStreaming() or inlineStreaming() or reviewFlashActive()`；tool-only batch 已被 `aiStreaming()` 的 tool_jobs 分支覆盖。loop 仅在该谓词为真时进入 1ms poll slice（16ms 渲染节流），谓词为假后回到阻塞 `pollEvent`；flash 到期不需要额外 wake。`frame_now_ms` 每帧只取一次，所有元素同相。
- **可测性**：`wrapMs`/`triangle`/`spinnerGlyph`/`flashActive`/`flashProgress`/`blend`/`pulseColor`/`caretVisible` 全部纯函数并单测负时钟、端点、deadline 与 0 周期；内部 e2e seam `OZ_AI_TOOL_DELAY_MS`（默认未设）让 running card 在测试中停留数帧。e2e `animation:` 用长 SSE 流与带 delay 的 tool mock 各抓多帧，断言 status fg / spinner glyph 至少出现两种值；完成后断言 300ms 内 PTY 零输出、cell 不再变化（idle 无 churn）。
- **限制**：TUI 无 opacity/transform，pulse 用 RGB 插值；badge flash 只有单测 deadline 与渲染路径，没有单独 e2e（不计入“至少两种动画”的验收）；caret blink helper 已就绪但硬件光标保持现状。

---

## 19. Keyboard Hints（qutebrowser 风格，M2.6）

参考：[qutebrowser quickstart](https://www.qutebrowser.org/doc/quickstart.html) 的 hint mode：按 `f` 给所有可点击目标加标签，输入标签直接触发，不需要鼠标。oz 是 TUI，没有 DOM，但所有“可点击/可聚焦”的区域（文件树行、buffer tab、agent thread、workbox tab、审批按钮）都可以注册成 target。

### 19.1 为什么需要

AI workspace 把目标分散到 navigator、editor、agent rail、workbox 四处。只用 `j/k` + `Tab` 到达某个具体 tab/thread/approval 的路径太长；hint mode 把“找到目标”变成一次视觉扫描 + 1–2 个字符，适合键盘用户。

### 19.2 键位（避免与 vim 冲突）

- `<leader>j`：进入 **primary hint mode**（jump）。
- `<leader>J`：进入 **secondary hint mode**（后续：在新 split/新 thread 打开；M2.6b）。
- 不占用 plain `f`：normal mode 的 `f{char}` 是 vim 查找，必须保留。
- hint mode 内：可打印标签字符输入、Backspace 删除、Esc 取消；不进入 insert/command/picker。
- 激活后当前模式/焦点不变；动作完成后回到原焦点（除非动作本身要求切换）。
- 后续可加 `gi` 风格“聚焦第一个输入框”，但 M2.6a 先用 `<leader>a` / `<Ctrl-w>a`。

### 19.3 标签算法

- 字符集 `asdfghjkl`（9 个）：1 个目标 1 字符；10–81 个目标 2 字符；82–729 个目标 3 字符；超过 729 截断并显示 `+N more`。
- **固定长度**，不做“唯一前缀自动触发”，避免输入到一半误触；输入长度 == label 长度时执行。
- 目标按 **从上到下、从左到右** 的屏幕位置排序；同位置按注册顺序，保证确定性。
- 标签唯一；前缀输入只高亮匹配目标；无匹配时清空输入并 flash。
- 目标不可见/被裁剪时不注册；注册 rect 必须 clamp 到屏幕内。
- 标签绘制在 target rect 的左上角（覆盖 1–3 个 cell），使用 accent bg + 深色 fg；不做半透明。

### 19.4 Target 注册与动作

新增纯模块 `src/app/hints.zig`：

```zig
pub const Action = union(enum) {
    filetree_select: usize,
    filetree_activate: usize,
    buffer_select: usize,
    agent_thread_select: usize,
    workbox_tab: WorkboxTab,
    agent_new,
    // M2.6b: change_accept/reject, tool_approve/deny, ...
};

pub const Target = struct { rect: Rect, action: Action };
```

- `Hints.beginFrame()`：hint mode 激活时清空；普通帧零开销。
- 各渲染函数在绘制目标时调用 `self.hints.add(rect, action)`。
- 渲染最后 `drawOverlay()`：计算/绘制标签、当前前缀高亮。
- 输入路由在 `handleKey` 最前（在 macro/picker/editor 之前）；动作由 App 的 `execHintAction` 映射到现有方法，不复制业务逻辑。
- 初始 target：文件树行、buffer tab、agent thread 行、workbox tab、`+` 新建线程、navigator tab（M2b 后）。
- 审批/工具卡片在 M3 注册同一 API，不另造点击系统。

### 19.5 性能

- 只有 hint mode 激活的帧才收集 target；普通编辑/流式帧不增加 O(n) 以上的固定开销。
- 固定容量数组（例如 128 targets），不每帧分配；标签在栈上/复用 buffer 生成。
- overlay 绘制 O(targets)，最后一遍，不触发额外 layout pass。
- 目标注册使用已有 Rect，不做 DOM/树遍历；不确定/离屏目标直接跳过。
- 输入每次最多触发一次 render；流式 AI 仍可继续 drain，不阻塞。

### 19.6 里程碑

- **M2.6a（已完成，2026-10-25）**：`<leader>j`、标签生成、tint 覆盖层、文件树/buffer/agent/workbox tab 的目标与动作、Esc/Backspace、单元 + e2e。实现状态见 §19.8。
- **M2.6b**：`<leader>J` secondary actions（split 打开、新 thread）、approval/diff/tool 按钮、`gi` 聚焦输入、目标优先级/去重。
- **M3**：工具卡片、审批、metrics 的按钮自动注册为 hint target；不引入第二套键盘导航。M3a 已注册 Chat tool card（展开/收起）与既有 Workbox tab；审批按钮留到 M3b。

### 19.7 测试

- 单元：0/1/9/10/81/82 targets 的标签长度/唯一性/顺序；前缀匹配/回退/无效；动作 payload；rect clamp；容量截断。
- e2e：120 dock 打开 hint mode，断言覆盖标签、输入文件树标签打开/展开、输入 buffer tab 标签切换、Esc 取消无副作用；80 drawer 输入 workbox/agent 标签；标签不越界、不覆盖 status bar；普通 `f` 仍是 find-char。
- 新增 required scenario tag `@hints`；golden 增加 `hints-120x30`（可选）。
- 性能：微基准只测纯标签生成/匹配（固定 128 targets），不在 e2e 中用墙钟断言。

### 19.8 M2.6a 实现状态（已完成，2026-10-25）

**入口**：`<leader>j`。editor normal / dashboard / 文件树聚焦 / AI 线程列表聚焦均可用。AI rail 聚焦时会先消费所有可打印键，因此线程列表的 `<leader>j` 在 `src/app/ai.zig:handleAiRailKey` 里识别（`rail_pending_leader`）；prompt 聚焦时空格属于输入文本，hint 不从输入框触发（先 Esc/Tab 离开输入框）。文件树聚焦时，pending leader 期间文件树不再吃掉序列尾键（`Mode.leaderPending`），否则 `<leader>j` 的 `j` 会变成移动文件树光标。

**目标（当前约 20 个，取决于布局）**

| 目标 | Action | 复用方法 |
|---|---|---|
| 文件树可见行 | `filetree_activate` | `activateFiletreeSelection`（Enter 抽出的同一函数） |
| buffer tab（单窗口 / split tab bar） | `buffer_select` | `switchTo` |
| AI 线程行 | `agent_thread_select` | `aiSelectThread`（Enter attach 语义） |
| Workbox Chat/Changes/Tools/Terminal | `workbox_tab` | `aiSetWorkboxTab` |
| 新建线程 `+` | `agent_new` | `aiNewThread` |
| AI 输入框行 | `agent_prompt_focus` | `aiFocusPrompt` |

`Action.filetree_select` 保留在 union 中（API 完整性），M2.6a 不注册——单独的“只选中”没有可观察效果。dashboard 的 `[No Name]` 空 tab 不注册（动作不可观察）。审批/tool 卡片留给 M3 通过同一个 `addHintTarget` API 注册。

**动作与焦点**：`src/app/hint_ui.zig:execHintAction` 只调用上表的既有方法，先做越界检查；动作抛错时 `catch` 转成状态消息，不 panic。焦点由动作本身决定：文件树展开留在文件树、打开文件回 editor（Enter 语义）；buffer 切换回 editor；线程 attach/`+`/输入框聚焦 prompt；Workbox tab 保持当前焦点。Esc/Backspace/无效前缀不修改任何业务状态。

**标签与绘制**：纯模型 `src/app/hints.zig` 不 import App/vaxis：固定 128 容量、comptime 静态标签表（O(1) 生成、零分配）、稳定 row-major 排序（同位置按注册顺序）、前缀/回退/无效前缀/flash、`statusText` 写入 State 自带 buffer（vaxis cell 引用文本直到 `vx.render()`，不能放栈上）。标签画在目标内容区左上角（不盖边框），靠近右边界时整体左移 clamp，且永不绘制终端最后一列；匹配前缀为 accent bg + 深色 fg，其余 dim。状态文字替换状态栏右侧的 AI 状态块：`HINTS · N targets · Esc cancel` / `HINTS · no match · Esc cancel` / `HINTS · no targets`。

**性能**：普通帧只有 `beginFrame` 的一次布尔判断；target 收集只在 hint 帧；排序 n≤128 插入排序；每键前缀匹配 O(n)；overlay 在 `vx.render()` 前一遍绘制，O(targets)，无额外 layout pass。标签生成/匹配的复杂度在模块头注释与单测中固定（729 标签 O(n) 不变量）。

**与最初设计的差异 / 限制**

- 在 §19.2 的 editor/dashboard 之外，额外支持线程列表入口；否则 80 列 drawer 下 prompt 聚焦会吞掉空格，hint 不可达。
- 容量 128 < 729，`+N more` 在 App 中不可达；纯模型与单测覆盖该分支。
- target 集合每帧重建。若帧间 target 数变化（resize / rail 开关等），已输入前缀会被清空，避免指向重排后的标签；目标动作本身不改变目标集。
- 没有 golden：标签会覆盖目标文本，target 数还依赖仓库根目录条目；语义断言（从画面读出标签、状态文字、边框、水平溢出）比整帧 golden 更稳定，见 `test/e2e.zig` 的 hints 测试与 `@hints` scenario。
- 鼠标支持见 §21：hint target 同时作为命中区域，鼠标与键盘共享同一批动作方法，没有第二套业务逻辑。
- M2b1 追加 `navigator_tab`（复用 `navigatorSetTab`）与 `note_open`（复用 `openNoteAt`）两个动作；`agent_thread_select` 现在先打开 rail，保证从 navigator 的 Agents tab 触发时 attach 可见。navigator 的 tab strip 与 Notes 行都注册为 target，e2e 从画面读取标签后激活。
- M2b2 追加 `inline_approve` / `inline_reject`：Changes 的 pending diff 渲染 `[a] approve  [r] reject` 两行按钮时注册矩形，动作分别复用 `inlineApprove` / `inlineReject`，与键盘 `a`/Enter、`r`/`d` 是同一条路径。
- M3b1 追加 `agent_approve` / `agent_reject`：通用 Changes review 渲染器（`inline_ui.drawDiffReview`）把按钮动作作为参数传入，agent edit 走 `agentEditApprove` / `agentEditReject`，与键盘路径一致。

---

## 20. Agent Tools 与 Metrics（M3）

### 20.1 目标

M3 把 chat 从“只会说话”升级为“能安全调用工具、需要时请求批准、并把调用过程可视化”。M3a 先做只读工具；M3b 再做写入/补丁审批和完整 metrics 图表。任何工具都不得绕过 workspace 边界或用户批准。

### 20.2 工具协议

- 复用 OpenAI-compatible `tools` + `tool_choice:"auto"`；工具定义与流式 `delta.tool_calls[]` 解析在 `src/ai/tools.zig`（M3 core）。
- 支持并行 tool calls；按 index 累积 arguments 片段，finalize 后校验 JSON object。
- 工具结果用 `role:"tool"` + `tool_call_id` 回填，content bounded（≤64 KiB），UTF-8 安全。
- 一轮最多 N 次工具调用（例如 8）和最多 M 轮（例如 6），超限停止并显示原因；避免无限 agent loop。
- 取消：与 chat 共用取消路径；取消后丢弃未完成的 tool calls，不执行。

### 20.3 只读工具（M3a）

`read_file` / `list_directory` / `grep`：

- 路径必须限制在 workspace root 内：拒绝绝对路径、`..`、NUL、指向 root 外的 symlink；输出只显示相对路径。
- 读取上限 64 KiB / 2000 行；目录最多 500 项；grep 最多 200 个匹配、单文件 1 MiB、深度 8；超出显示 truncation marker。
- grep 为字面量匹配（不引入正则执行风险），可带简单 glob；跳过二进制。
- 执行在后台线程/现有 worker 中，不阻塞 UI；结果回到对应 thread，不能串线。

### 20.4 权限与审批

- 读工具默认 allow；`edit_file` / `apply_patch` / terminal 默认 confirm；未知工具 deny。
- 审批卡片出现在 Chat 内联，并同步到 Workbox Changes/Approval badge；`<leader>j` hint target 可选中 Allow/Deny。
- M3a 的写入工具只返回 `approval_required`/未实现，不落盘；M3b1 已把 `edit_file` 接到 pending diff/apply 路径（§20.9），M3b2 把 `apply_patch` 接到同一审批路径（§20.10）；terminal 仍不执行。
- 审批决定绑定 stage 时的 tool card/参数摘要；approve 时重新校验路径、整文件文本与 `history.revision`，参数/内容变化不得复用旧批准。

### 20.5 Tool cards 与 metrics

- Chat 中每个 tool call 显示紧凑卡片：name、参数摘要、状态（running/ok/error/denied）、耗时、结果摘要；失败不能伪装成功。
- Workbox `Tools` tab：按工具聚合
  - calls / ok / error / denied
  - average / max（该工具全部真实执行样本）
  - **p95**（该工具最近至多 32 次真实执行样本的整数 nearest-rank：`ceil(0.95*n)-1`，clamp 到 `[0, n-1]`；n=0 时没有值，显示 `no latency samples`，绝不伪造 0ms）
  - 最近 32 次耗时 ring buffer（每工具固定 `recent_capacity = 32`；p95 和图表共用这同一批真实样本）
  - Tools tab 顶栏的聚合 p95 汇总每个工具各自的 recent window（每工具 ≤32，最多 8 工具 = ≤256 个真实样本，仍为 nearest-rank）；per-tool 卡片则只统计该工具的窗口。两者语义在 §20.11 固定。
  - 折线图使用 `src/chart.zig`（M3a 已接入 Tools tab），窄屏 fallback sparkline；没有数据时显示真实空状态。
- Metrics 只统计真实调用；mock/e2e 数据不得进入发布 UI。
- 图表只在数据变化时重算，按 workbox 尺寸缓存；普通帧 O(visible cards)，不每帧重跑 diff/chart。
- Chat tool card 通过同一 `<leader>j` target API 选中，激活 = 展开/收起结果详情（真实动作；不 invent 无效果目标）。

### 20.6 里程碑

- **M3a（已完成，2026-10-25）**：只读 executor + tool loop + Chat tool cards + Tools tab 真实统计 + chart 接入 + 审批占位；e2e mock。实现状态见 §20.8。
- **M3b1（已完成，2026-10-25）**：`edit_file` staged diff + 人工 approve/reject + buffer-only apply/undo、审批按钮 hint、`approved`/`rejected` 卡片与 decision metrics。实现状态见 §20.9。
- **M3b2（已完成，2026-10-25）**：`apply_patch` 单文件 unified diff 解析/校验/整文件 staged 替换 + 同一 approve/reject/undo 路径；多文件与 terminal 仍不支持。实现状态见 §20.10。
- **M3c（已完成，2026-10-26）**：每工具 recent-window p95（整数 nearest-rank，≤32 个真实样本）+ Tools tab 卡片/顶栏展示与 80/100/120 紧凑 fallback。实现状态见 §20.11。
- **M3b 余下**：terminal 沙箱/明确确认、跨会话 metrics 持久化、性能基准。
- **后续**：terminal tool（独立沙箱/明确确认）、MCP/ACP、跨会话 metrics 持久化。

### 20.7 测试

- Core：tools 协议/accumulator（已有 26 单测）、executor 路径逃逸/大小上限/二进制/错误、chart（已有 17 单测）。
- E2E：只读 tool call 一轮/多轮、并行 calls、错误工具、超轮次、取消、审批 deny/allow（M3b）、卡片 stats、Tools tab 空/有数据、80/100/120 布局、hint 选中。
- 每个工具调用必须能在 mock 请求体/响应中复现；不能依赖真实网络。
- 性能：executor 在 worker，UI 帧不等待；metrics/chart 重算次数可断言（例如只在数据变化时）。

### 20.8 M3a 实现状态（已完成，2026-10-25）

**Transport（`src/ai/client.zig` + `src/ai/openai.zig` + `src/ai/tools.zig`）**

- 每个 chat client worker 持有一个 `ai.tools.Accumulator`：每个有效 JSON chunk 在保留 `openai.parseDelta` 文本 delta 的同时喂给 accumulator；流结束（`finish_reason`/`[DONE]`/EOF）时 `finalize` 并按 index 顺序 push 一个 `Event.tool_calls`（owned），随后才 push `Event.done`。纯文本流零行为变化。
- 并行 calls/交错 fragments/文本+calls 都由 accumulator 处理；`invalid index`、缺 id/name、非法 arguments 等**有效 JSON 内的协议错误** push `tool call protocol: <Error>` 聊天错误，不 panic、不执行半截调用。语法非法的 JSON chunk 仍按 M1 策略忽略（网关 keep-alive/metadata 兼容）。
- 请求：`turn.buildMessages` 把 thread transcript 映射为 OpenAI messages（user/assistant/tool 保持原顺序，空 assistant 占位跳过，带 tool_calls 的空文本 assistant 保留）；`tools.appendTools` 追加 `tools` + `tool_choice:"auto"`。assistant tool-call turn 用 `tools.buildAssistantToolCallsJson` 序列化，tool result 用 `tools.buildToolResultContent`（≤64 KiB、UTF-8 安全、`error: ` 前缀）；OpenAI writer 对带 tool_calls 的空 content 写 `null`。
- 测试 seam（仅 `OZ_AI_MOCK_DIR`）：第 n 个请求写 `request.json`（最新）+ `request-<n>.json`，优先回放 `stream-<n>.sse`/`error-<n>.txt`，否则 fallback `stream.sse`/`error.txt`。既有测试不受影响。

**Agent loop（`src/app/ai.zig`）**

- 每 thread 一个 `ToolThreadState`（与 `threads.items` 平行）：捕获当轮 workspace root（`currentRootDir`，绝对、无 trailing slash）、round/call 计数、in-flight batch、stream terminal、follow-up 状态、generation、当前 batch 的 card message indices、transcript note、`agent.Metrics`。
- 一轮 user turn：首个请求带 tools；响应结束时若有 tool calls：把 calls 附到本轮 assistant message，为每个 call 建 card（running），按 `agent.planBatch` admission（prefix）：前 N 个交给 worker；超限的立即写为 `unsupported` + `error: ... limit ...; not executed`，并写回一条真实的 `role:"tool"` 结果。`rounds` 按 batch 计，`calls` 按实际 admitted 计。
- worker 完成后：填 card 的 status/content/duration（`ok`/`error`/`unsupported`；M3a 的 `edit_file` 占位为 `approval required`，M3b1 起改由 App 层 stage，见 §20.9），记录 metrics，然后自动 follow-up；follow-up 仍是同一 thread 的 client（`joinAfterTerminal` 消除 done/worker 重用的 Busy race），消息序列为 assistant(tool_calls) → tool results → 下一条 assistant。
- **限制**：最多 4 个 tool batch（`agent.max_tool_rounds`）、最多 8 个执行调用（`agent.max_tool_calls_per_turn`）。到达任一上限后下一请求 **不带 tools**（最终 no-tools turn），保证仍能拿到最终文本；若模型在最终轮仍返回 tool calls，只生成 `unsupported` card/结果并停止。超限时 Chat transcript 显示 `tool loop stopped: max rounds/calls (N) ...`；Tools tab 的计数仍是真实值。
- `edit_file`/`apply_patch` 只走 executor 的 `approval_required`（不落盘），`terminal`/未知工具 `unsupported`；`ai/tool_exec.zig` 内没有任何写 syscall。（M3b1 起 `edit_file` 在 App 层 stage，executor 的 fallback 仍不写；见 §20.9。）
- 取消/切线程：现有 `cancelClient` 同时 requestCancel transport、`generation += 1`、冻结 running cards 为 `cancelled`、requestCancel worker；随后 worker 的结果因 generation/`cancel_requested` 不匹配被丢弃，绝不写入任何 transcript。`Ctrl+c` 在 stream 已结束但 tool/follow-up 仍活动时也会停止 loop。

**Worker（`src/app/tool_job.zig`）**

- 每 thread 最多一个 `Job`（后台 `std.Thread`），在 worker 内构造一次 `tool_exec.Executor`（realpath 一次），顺序执行 batch；调用之间检查 cancel。结果数组由 worker 写好，`done` release 发布；run loop 的 `drainToolJobs` acquire 消费，UI 帧从不读取文件/不等待 IO。
- 每 call 用 monotonic `awake` ms 计时；`read_file` 64 KiB/2000 行、list 500、grep 200/1 MiB/深度 8 等上限仍在 executor 内。`aiStreaming()` 把未消费 job 也视为 active，run loop 以 1ms slice poll（不阻塞按键）。

**UI**

- Chat tool card：2–4 行紧凑卡片（icon + name + 右对齐状态；args summary；结果 excerpt / `not executed` / `⋯ working`），running/ok/error/approval/unsupported/cancelled 有不同 icon/颜色/文案；卡片是 transcript 行，随 Chat 滚动。`<leader>j` target 注册在可见卡片首行，激活切换 `tool_expanded`（最多 8 行真实结果 + `…`）。不伪造结果。
- Tools tab：无 metrics 显示 `no tool calls yet`（空状态真实）；有数据时第一行 `tools · N calls · avg Xms · p95 Yms`（窄栏按 34/38 cells 与 80 drawer 依次退化为 `N calls · avg Xms · p95 Yms` → `avg Xms · p95 Yms` → `p95 Yms`），每个工具 3 行 `name · calls N` / `ok · err [· appr · unsup]` / `avg Xms · p95 Yms · max Zms`（放不下时先掉 max，再退化为 `p95 Yms`；没有执行样本时 `no latency samples`）；工具多时显示 `+N more tools`。
- Chart：有执行样本时用 `chart.render`（≥24×4 braille，否则 sparkline）渲染所有工具最近 32 个真实 duration，legend 为工具名，轴为 `0ms`/y_max + `older`/`now`。`ChartCache` 以 (thread, metrics.revision, width, height) 为 key；只有 metrics 变化或布局变化才重算，画布 cell 直接复制到 vaxis。颜色取主题 syntax palette（最多 8 series）。
- 状态：thread list/workbench header/status bar 在 batch 或 follow-up pending 时显示 `tools…`（不是 `idle`/`streaming…`）；完成后恢复正常状态。
- 80x24 drawer：按 body_rows 预算 visible cards + chart 高度（chart 最小 2 行，否则省略），所有行由 `drawRailRow` 精确填满，不越界；hint label 只画在 panel 内。card 名称/状态/arguments 在 80 列下按 cell 截断。

**只读边界与限制**

- 只执行 `read_file`/`list_directory`/`grep`；写入工具在 M3a 永远返回 approval/unsupported，不创建 pending diff、不写盘。没有 terminal/shell/网络工具。（M3b1 扩展见 §20.9：`edit_file` 在 App 层 staged，executor 仍然只读。）
- `read_file`/`grep` 只读 workspace root（拒绝绝对路径、`..`、NUL、越界 symlink；输出 workspace-relative）。这是 best-effort confinement，不声称 TOCTOU 安全（与 §20.3 一致）。
- metrics 是 per-thread、session 级、不持久化；被取消/被 generation 丢弃的 in-flight 调用不计数（只统计真正应用回该 thread 的结果）。p95（§20.11）只覆盖每工具最近 ≤32 个真实样本；没有跨会话图表、没有 mock 数据注入发布 UI。
- tool card 展开通过 hint 或鼠标点击（见 §21）；M3b 再加审批按钮与完整 hint 覆盖。
- 最终 no-tools turn 由 `agent.max_*` 常量触发；如果 provider 忽略无 tools 请求仍返回 tool_calls，只记录 unsupported 后停止（有界）。
- 未新增 terminal/MCP/ACP；`ai/tool_exec.zig` 的 caps 与 §20.3 一致。

**文件**

- `src/ai/agent.zig`：loop bounds、card 文案/args summary/excerpt、metrics/ring/chart key + 单测。
- `src/ai/turn.zig`：transcript → OpenAI request messages（assistant tool_calls / role tool）+ 单测。
- `src/ai/client.zig`、`src/ai/openai.zig`、`src/ai/tools.zig`：streaming tool_calls、request writer、assistant JSON/content builder + 单测。
- `src/ai/workspace.zig`：tool role/message/card 字段与 thread helpers + 单测。
- `src/app/ai.zig`：Session sidecars、request/follow-up、drain、cards/tools tab/chart cache、hints/status。
- `src/app/tool_job.zig`：后台 read-only worker。
- `src/app/render.zig`、`src/app.zig`、`src/app/hints.zig`、`src/app/hint_ui.zig`：run-loop drain、alias、hint action/wiring。
- `test/e2e.zig` + TESTING.md：9 个 M3a pty 测试、`@tools` scenario、mock 轮次 fixture。

**验证**

- `zig build test`：466/466 通过（原 449 + 17 个 M3a 单测，未改动既有断言）。
- `zig build e2e`：165/165 通过（原 156 + 9 个 M3a pty 测试；scenario matrix 新增 `ai tools read 120x30`）。
- 无 golden 变更（tool cards/metrics 不进入固定 golden 帧）；`tools arrive in M3` 的旧空状态测试更新为 `no tool calls yet`（产品要求变化，断言不回退）。

---

### 20.9 M3b1 实现状态（staged edit approval，2026-10-25）

**范围与策略**

- M3b1 只实现 `edit_file` 的人工审批；`apply_patch`/`terminal`/未知工具仍不执行（本地 `unsupported`）。这是 M3b 的第一个切片，不含 patch 解析、terminal 沙箱、审批队列/持久化。（M3b2 在此之后接入 `apply_patch`，见 §20.10；本节保留为 M3b1 当时的状态。）
- 工具调用不再到达 executor：`src/app/ai.zig:aiHandleToolCalls` 按 `ai.tools.classify` 分流。只有 `read_file`/`list_directory`/`grep` 进入后台 worker；`edit_file` 在 App 线程 stage；`apply_patch`/`terminal`/未知立即生成真实的 unsupported 卡片与 `role:"tool"` 结果，不启动 worker。
- stage 只读目标：优先使用已打开 buffer 的当前文本（含未保存修改），否则 `readFileAlloc` 上限 256 KiB；**不打开新 buffer、不写临时文件、不改 dirty**。路径复用 `ai/tool_exec.zig` 的 `normalizeWorkspacePath` / `isWithin`：拒绝绝对路径、`..`、NUL、越界 symlink；canonical path 必须位于**当轮捕获**的 workspace root 内（不是当前可见 workspace）。
- `old_string` 必须非空；未设 `replace_all` 时必须恰好出现一次；`replace_all` 至少一次且最多 512 次。任何失败返回真实 `error:` 卡片，不 stage。
- diff 复用 `inline.buildDiff`（行级 LCS），不实现第二套 diff 引擎。为避免大文件整文件 diff，预览按“变更行 ±3 行上下文”合并 hunk，总预览 ≤240 行 / ≤16 hunks；超出时显示真实的 `… N more occurrence(s) not shown` 或 `preview truncated`，stats 行标记 `preview`。`-N +M` 是实际展示 hunk 的行级统计。完整 snapshot 只用于 staleness/apply，不逐帧重算。
- 同一时刻只允许一个 review（agent 或 inline）：agent stage 在 inline prompt/stream/pending 存在时返回 `resolve the pending edit first`；inline start 在 agent pending 存在时同样拒绝。第二笔 `edit_file` 卡片为 `.err` + `error: resolve the pending edit first; not executed`，不排队。

**Pending 与 UI**

- `PendingAgentEdit`（`src/app/agent_edit.zig`）保存 thread/card index、canonical/relative path、完整 target snapshot、old/new、replace_all、单 span `[span_start, span_end)` + `span_replacement`、缓存 diff/stats、staged-from-buffer 的 buffer index + `history.revision`、以及 `stale` 标志。
- 卡片状态：stage 成功 → `approval required` + `-N +M · staged · review in Changes`；approve → `approved` + `-N +M · applied · u to undo`；reject → `rejected` + `-N +M · discarded`；stale 仍为 `approval required` + `stale edit`。`api_text`（发给模型的 tool result）始终保持 stage 时的 `approval required: edit_file staged for review; not applied`，不篡改历史。
- stage 成功自动打开 rail、切 **Changes**、badge `changes 1`、焦点 rail。Changes 使用新增的通用 `inline_ui.drawDiffReview(ReviewView)`（inline 与 agent 共用同一渲染/截断/闭合逻辑），`[a] approve  [r] reject` 注册 `agent_approve` / `agent_reject` hint target；`j/k` 滚动缓存 diff。无可见 pending 时 `a/r/d/j/k` 不被消费，`r`/`d` 仍是 Terminal/Changes tab 切换。
- approve：target 未打开时先重新 canonicalize（必须仍是 captured root 内的同一路径）、只读重读校验，再 `openInBuffer`；已打开则按绝对 path 定位。随后校验 staged-from-buffer 的 `history.revision` 完全相等、当前整个文本与 snapshot 逐字节相等、`old_string` 出现次数仍等于 stage 时数量。任一失败 → toast/stats `stale edit`，pending 保留可 reject，buffer/history 不变。
- 通过后 `switchTo` + `applyEdit(span_start, span_end, span_replacement)`：整个替换（包括 `replace_all` 的多处）是**一个 undo group**，`u` 一次恢复。dirty 由 `markDirtyRange` 设置；**不调用 save**，`:w` 仍是用户动作。approve 后焦点回 editor，toast `agent edit approved · u to undo`。reject toast `agent edit rejected`，不碰 buffer/history/dirty。
- pending 线程隔离：badge/review 只在 `pending.thread_index == threads.active` 时可见；切线程隐藏但保留，approve/reject 在别的线程拒绝执行（提示切回）。pending 是 session 级、单实例；退出即丢弃（不持久化）。
- metrics：stage 记录一次 `approval_required`；approve 通过 `recordDecision(approved)` 计入 `ok`（不增加 calls、不产生 latency sample），reject 计入 `denied`；Tools tab 显示 `appr` / `denied`。只统计真实 stage/decision。

**限制**

- 只支持单文件、单个连续 span 的 `edit_file`；`replace_all` 的多处被合并为一个 span 以便一次 undo，不生成 per-hunk undo。
- `apply_patch` 仍未实现；terminal/未知工具不执行。没有跨会话/重启的 approval 队列；pending 绑定当前进程的 thread/card index。
- 预览是有界 hunk，不是整文件 unified diff；超过 256 KiB 的文件拒绝 stage；没有 word-level diff、hunk 折叠或软换行。
- stage 后自动 follow-up 已把 “staged/not applied” 结果发给模型；之后 approve 只更新本地卡片，模型 transcript 不会追认该批准（M3b 后续可加通知）。这是本切片的明确限制，不是假成功。
- 路径校验是 best-effort（与 executor 相同，不声称 TOCTOU 安全）；符号链接别名可能被当作不同路径处理。
- 鼠标见 §21；hint、键盘与鼠标共用同一 approve/reject 方法。

**文件**

- `src/app/agent_edit.zig`：纯参数校验、occurrence/span、bounded hunk diff、pending/staleness、one-review policy + 单测。
- `src/app/agent_edit_ui.zig`：workspace 只读加载、stage/approve/reject、Changes 渲染、按键/hint、thread 可见性。
- `src/app/ai.zig`：工具调用分流（read-only worker / edit stage / unsupported）、卡片文案/状态、badge、Changes 路由、Tools tab denied。
- `src/app/inline_ui.zig`：抽取通用 `drawDiffReview` + `ReviewView`；inline 行为不变。
- `src/ai/agent.zig`、`src/ai/workspace.zig`：`approved`/`rejected` 卡片状态、decision metrics/`denied`、`setToolDecision`。
- `src/app/hints.zig`、`src/app/hint_ui.zig`：`agent_approve` / `agent_reject`。
- `src/ai/tool_exec.zig`：公开 workspace path 规则；`apply_patch` 防御性返回 `unsupported`；`edit_file` 的 executor fallback 仍不写。
- `test/e2e.zig` + TESTING.md：6 个 M3b1 pty 测试、`@approval` scenario。

**验证**

- `zig build test`：474/474 通过（新增 7 个 `agent_edit` 纯模型单测 + 1 个 decision metrics 单测）。
- `zig build e2e`：170/170 通过（原 M3a 的 edit_file 占位测试替换为 6 个 M3b1 pty 测试；scenario matrix 新增 `ai approval 120x30` 与 required tag `@approval`）。
- 无 golden 变更（approval diff/卡片不进入固定 golden 帧）。

---

### 20.10 M3b2 实现状态（staged `apply_patch` approval，2026-10-25）

**范围与策略**

- M3b2 只实现 `apply_patch` 的人工审批；`terminal`/未知工具仍不执行（本地 `unsupported`）。不含 terminal 沙箱、审批队列/持久化、多文件 patch、add/delete/rename/binary/mode 变更。
- `src/app/ai.zig:aiHandleToolCalls` 把 `edit_file` 与 `apply_patch` 都分流到 App 层 stage（`agent_edit_ui.stageToolCall` / `stagePatchToolCall`），executor/worker 仍只看到只读调用；任何工具执行路径都没有写 syscall。
- `agent_patch.parse` 只接受**单文件 unified diff**：`diff --git`/`index`/`---`/`+++`/`@@` 头可选，但必须至少有一个路径来源；支持同一文件多个 hunk、省略 count（默认 1）、`\ No newline at end of file`、以及后续 hunk 的行号漂移。Markdown 代码围栏与 CRLF 传输会被规范化。`a/`/`b/` 前缀只在 old/new 拼写确实构成 git 前缀对时才剥离；`--no-prefix` 下真实路径以 `a/`/`b/` 开头的文件不会被误改。
- 明确拒绝（typed error，真实 error card，不 stage、不部分应用）：多文件、增删文件（`/dev/null`/`new file mode`/`deleted file mode`）、binary、rename/copy、mode 变更、malformed header/hunk/counts、context/removal 不匹配、hunk 越界或乱序、`new_start` 与实际应用结果不一致、路径 absolute/`..`/NUL/符号链接逃逸/越出 captured root、文件缺失、patch >256 KiB、>256 hunks、>16K hunk 行、结果 >256 KiB。
- 路径与目标复用 M3b1 的 confinement：`tool_exec.normalizeWorkspacePath` + `isWithin`，canonical path 必须位于**当轮捕获**的 workspace root；stage 只读，优先使用已打开 buffer（含未保存修改），否则读盘（≤256 KiB）。
- `agent_patch.apply` 以旧全文为基准，按顺序复制未变行、校验 context/removal、应用全部 hunk，构造新全文；任一 hunk 不匹配即整体失败，绝不部分应用。
- 新全文通过既有 `PendingAgentEdit`/approval 路径 stage：pending 是整文件 span `[0, old_len)`，`span_replacement` 为新全文；approve 仍是**一次 `applyEdit` = 一个 undo group**。没有第二套 review 组件。

**Pending 与 UI**

- `Pending` 新增 `kind: edit_file | apply_patch` 与保留的 `patch`（供 approve 时重新执行 hunk 校验）。stale 文案按 kind 为 `stale edit` / `stale patch`；卡片与 metrics 使用真实工具名。
- stage 成功：不碰 buffer/history/dirty/file；自动打开 rail、Changes、badge `changes 1`；卡片 `approval required` + `-N +M · staged · review in Changes`（`-N +M` 是实际展示 hunk 的行级统计）；`role:"tool"` 结果固定为 `approval required: apply_patch staged for review; not applied`。
- approve：重新 canonicalize 路径（必要时重新打开 buffer）、校验 buffer revision、整文件文本逐字节相等，并**重新应用保留的 patch** 要求结果与 stage 时完全一致；任一项失败 → `stale patch`，保留 review，buffer/history 不变。通过后整文件替换写入 buffer（dirty），不 save；卡片 `approved` + `-N +M · applied · u to undo`，metrics 记 ok，焦点回 editor。`:w` 仍是用户动作。
- reject：丢弃 pending，卡片 `rejected`，metrics 记 denied；buffer/history/dirty/file 全部不变。
- 同一时刻只有一个 review（agent 或 inline）：第二笔 `apply_patch`（或 `edit_file`）返回 `resolve the pending edit first`；pending 线程隔离，切线程隐藏 badge/review 但保留，必须回到 staging thread 才能 apply/reject。
- 80x24 drawer 复用通用 `inline_ui.drawDiffReview`：diff/buttons 不横向溢出，`agent_approve`/`agent_reject` hint 与键盘路径一致。

**限制**

- 只支持**单文件** patch；多文件 patch 需要拆成多次调用。没有 add/delete/rename/copy、binary 或 mode 变更；没有 partial apply。
- 整文件替换：一个 patch 是一个 undo group，不提供 per-hunk undo。`apply_patch` 与 `edit_file` 共享同一 pending 槽位。
- 预览直接来自解析后的 hunk 行（本身就是 diff），有界（≤240 行 / ≤16 hunks）；不是整文件 unified diff，也不是 word-level diff。
- 上限：patch/目标/结果 ≤256 KiB、≤256 hunks、≤16K hunk 行；超出即拒绝，不静默截断应用。
- stage 后的自动 follow-up 已把 “staged/not applied” 发给模型；之后 approve 只更新本地卡片，模型 transcript 不会追认（与 M3b1 相同）。
- 路径校验是 best-effort（与 executor 相同，不声称 TOCTOU 安全）；符号链接别名可能被当作不同路径。
- 无 terminal/shell/网络；鼠标见 §21；pending 不跨进程持久化。

**文件**

- `src/app/agent_patch.zig`：参数解析、单文件 unified diff 解析、hunk 应用/重建全文、bounded preview + 单测。
- `src/app/agent_edit.zig`：`Kind`、patch pending（整文件 span）、`verifyPatch`、stale 文案 + 单测。
- `src/app/agent_edit_ui.zig`：共享目标解析/加载 helper、`stagePatchToolCall`、kind-aware 卡片/决策/apply。
- `src/app/ai.zig`：`edit_file`/`apply_patch` 统一 stage 分流、真实 tool result、terminal/unknown unsupported。
- `src/app/inline.zig`：公开 `dupeDisplayLine` 供 patch preview 复用（无行为变化）。
- `src/ai/tools.zig`：`apply_patch` schema 描述明确为 single-file（参数/策略不变）。
- `test/e2e.zig` + TESTING.md：5 个 M3b2 pty 测试、`ai patch approval 120x30` scenario、`@approval`。

**验证**

- `zig build test`：491/491 通过（新增 17 个 `agent_patch`/`agent_edit` 纯模型单测）。
- `zig build e2e`：175/175 通过（新增 5 个 M3b2 pty 测试；scenario matrix 新增 `ai patch approval 120x30`）。
- 无 golden 变更（approval diff/卡片不进入固定 golden 帧）。

---

### 20.11 M3c 实现状态（recent-window p95，2026-10-26）

**语义（唯一事实来源）**

- `agent.Stats.p95RecentMs() ?u32`：只统计该工具 **最近至多 32 次真实执行**（ok/error；approval_required/unsupported/denied 没有耗时样本）的 `recent` ring。整数 nearest-rank：升序排序后取 0-based `ceil(0.95*n)-1`，并 clamp 到 `[0, n-1]`；n=0 → `null`，绝不返回伪造的 `0ms`。
- `agent.Metrics.p95RecentMs() ?u32`：Tools tab **顶栏**使用，按工具收集各自的 recent window（每工具 ≤32、最多 8 个工具 = ≤256 个真实样本）后做同一 nearest-rank；它不是“全局最近 32 次调用”的另一种定义，DESIGN/README 都明确这一点。per-tool 卡片只用 `Stats.p95RecentMs()`。
- **不变量**：p95 与图表/avg/max 使用同一批真实 duration；不新增计时、不改 `duration_count`/`total_ms`/`max_ms`/`recent`/`revision`，也不改 chart samples。读取 p95 是纯函数：在固定栈数组 `[recent_capacity]u32` 上排序副本，无堆分配、无锁、无 IO。
- 与 avg/max 的域不同且已标注：avg/max 覆盖该工具全部执行样本，p95 只覆盖 recent 32；n<20 时 p95 是窗口最大值（nearest-rank 的自然结果，不是 bug）。

**UI**

- per-tool latency 行：`avg Xms · p95 Yms · max Zms`；34/38-cell rail、80 drawer 放不下时先掉 `max` → `avg Xms · p95 Yms`，再退化为 `p95 Yms`，最后由 `drawRailTextRow` 做 grapheme-safe clip（不横向溢出）。无执行样本仍是 `no latency samples`。
- 顶栏：`tools · N calls · avg Xms · p95 Yms`；窄栏依次退化 `N calls · avg Xms · p95 Yms` → `avg Xms · p95 Yms` → `p95 Yms`，保证 34/38 cells 与 80 drawer 仍显示 p95 标签。
- 不新增 golden 帧；空态（`no tool calls yet`）与 approval-only（`no latency samples`）不出现 p95。

**实现与文件**

- `src/ai/agent.zig`：`nearestRankP95`（固定栈副本 + `std.sort.insertion`，O(32²) 最坏）、`Stats.p95RecentMs`、`Metrics.p95RecentMs` + 单测（1/2/20/21/32 样本、重复值、全相等、乱序、ring 回绕、empty→null、revision/ring/counters 不变）。
- `src/app/ai.zig`：Tools tab summary/latency 候选串按 cell 宽度选择；字符串沿用既有 frame allocator（vaxis 在 frame flush 前保留 grapheme slice，栈缓冲会被提前复用），p95 的采样/排序本身只在固定栈数组上进行、不增加堆分配。
- `test/e2e.zig`：`tools:` 80/100/120 mock loop 断言 `p95 ` 标签、解析真实值并在合理范围（单样本时 `avg == p95`）；空态/approval-only 断言不出现 p95；scenario matrix 的 `ai tools read 120x30` 也断言标签。

**验证**

- `zig build test`：531/531 通过（新增 2 个 p95 单测；既有 529 不变）。
- `zig build e2e`：195/195 通过（不新增 pty 测试块；扩展既有 `tools:` 断言与空态/approval 反断言，scenario matrix 新增 `ai tools read 100x30` 并加强 120x30 期望）。
- 无 golden 变更（goldens 不渲染 Tools tab）。

---

## 21. Mouse 支持（feat/mouse，2026-10-26）

### 21.1 范围与不变量

- **v1 目标**：鼠标左键点击窗口/标签/行/按钮，滚轮滚动编辑器与列表。点击必须真正执行既有动作，不新增第二套业务逻辑。
- **不变量**：鼠标只能调用键盘/hint 已经存在的 App 方法（`execHintAction`、`switchWindowTo`、`closeBufferAt`、`aiSelectThread`、`aiSetWorkboxTab`、`aiFocusPrompt`、approve/reject…）。审批、stale 校验、dirty 语义、workspace 边界与 `:w` 仍是用户动作，鼠标不能绕过。
- **v1 不做**：拖拽、分隔线 resize、右键/中键菜单、文本拖选、终端内鼠标转发、精确 grapheme/soft-wrap 逐 cell 反查。
- **布局**：80/100/120 列均使用同一套目标矩形；鼠标不改变任何布局、golden 或状态栏几何。

### 21.2 生命周期（vaxis）

- `src/app/render.zig:run` 在 enter alt screen + bracketed paste 之后调用 `enableMouse`：
  - 强制 `caps.sgr_pixels = false`，即使终端宣告 SGR pixel 模式也使用 **cell 坐标**（命中矩形都是 cell）；`setMouseMode(true)` 失败只关闭鼠标功能，应用继续以键盘模式启动。
  - 启用后 `defer disableMouse`；正常退出在 `exitAltScreen` 之前显式关闭，错误路径由 defer 兜底。
  - `disableMouse` 幂等：成功后清 `vx.state.mouse`，避免 `Vaxis.deinit` 再发一次 reset；失败则保留状态让 deinit 重试。e2e 断言退出后 reset 恰好一次、且在 enable 之后。
- vaxis 的 `mouse_set` 同时打开 1002/1003/1004/1006（cell）。loop 只处理 **left press** 与 **wheel press**；motion/drag/release/未绑定按键返回 false，不会触发渲染，也不会接管终端自身的拖选。
- **复制/选择**：应用无法阻止终端上报鼠标；常规终端用 **Shift+拖拽** 绕过 mouse reporting 做本地选择/复制（终端相关）。若终端仍上报带 Shift 的事件，oz 直接忽略，交给终端语义。
- `Alt+r/w/e` 终端键位不受影响；鼠标报告的增强不会改变键盘路径。1b47588 的 vaxis 日志抑制仍由 `src/main.zig` 的 scope levels 保证。

### 21.3 命中测试（`src/app/mouse.zig` + `mouse_ui.zig`）

- **单一几何来源**：hint 渲染路径本来就在绘制时注册每个可点击目标（buffer tab、close ×、filetree/notes/agents 行、navigator tab、AI thread、workbox tab、`+`、prompt、tool card、Approve/Reject）。鼠标帧把 `if (self.hints.collecting)` 放宽为 `mouseTargetsCollecting()`，`addHintTarget` 同时写入鼠标 registry，因此矩形/action 不会与 hint 漂移；**hint 标签仍只在 hint mode 绘制**（overlay 仍以 `hints.active` 为门）。
- **mouse-only 目标**：
  - 每个 split leaf：点击聚焦 + 定位光标，滚轮移动该窗口光标；
  - 分隔线：1 cell 厚的显式 no-op（v1 不 resize），按面积优先于相邻 pane；
  - 滚轮区域：编辑器 pane、navigator 列表（按当前 tab）、AI thread list、workbox body。
- **优先级**：命中所有包含该 cell 的目标，取 **面积最小** 者；面积相同取后注册（绘制更上层）者。因此 close `×`(1×1) > tab、按钮(整段标签) > card/行、分隔线 > pane。
- **容量/分配**：`max_targets = 256` 固定数组，每帧 `beginFrame` O(1) 清零，无堆分配；越界/屏幕外矩形裁剪或丢弃。
- **模态隔离**：hint mode、picker、diag/nav list、git preview、inline prompt、command mode 下鼠标完全忽略；drawer rail 覆盖编辑器时，rail 外的目标不会从抽屉下方“穿透”接收点击/滚轮。
- **空区域**：编辑器 pane 空白处只聚焦/定位；状态栏、面板空白、无目标 body 全部 no-op，不伪造动作。

### 21.4 点击动作

- 所有 hint action 直接调用 `execHintAction`，与 `<leader>j` 完全同一路径；指针点击前会：
  - 若处于 Insert，先执行 `exitInsert()`（保留文本、结束 undo group）；
  - 清 pending leader/operator/replace、multi-cursor 与旧 status message；
  - 终端若持有焦点且点击发生在终端外，先取消终端焦点；
  - buffer/tree/notes/navigator 目标把键盘焦点交回 editor；AI thread/workbox/prompt 目标保留 AI focus，由既有方法决定。
- terminal overlay 优先命中：点击终端矩形聚焦子进程；点击其他位置回到编辑器。wheel 在终端聚焦或位于终端矩形上时 **不抢**（vaxis terminal widget 无鼠标转发）。
- 点击 tab 的 `×` 仍走 `closeBufferAt`（与 `:bd`/`<leader>bk` 相同；最后一个 buffer 不注册 close 目标）；点击 Approve/Reject 仍走 `inlineApprove`/`agentEditApprove` 等，stale/one-pending/线程隔离规则不变。

### 21.5 编辑器 pane 定位

- 点击 leaf 后先按 **该窗口** 的当前渲染状态反查：
  - gutter 宽度（相对行号 digits+1）；点击 gutter 落在行首；
  - 从 `view_top` 起按 `lineDisplayRows`（fold 折叠 + soft wrap + inlay hint 宽度）累加，得到目标 line 与 wrap chunk；
  - 文本 cell → byte：按 UTF-8 codepoint 逐个累加 `vaxis.gwidth`，tab = `tab_width`，并插入排序后的 inlay hint 宽度；宽字符第二格映射回该字符起点；行尾之后映射到行尾（Normal 模式再回退到最后一个 codepoint 起点，类似 `$`）。
- **安全限制**：单行只拷贝/映射前 256 KiB；soft wrap 的 chunk 起点按 `chunk * content_width` 近似（渲染在宽字符处可能提前换行）；grapheme cluster/emoji ZWJ 按 codepoint 近似。非折行 ASCII/CJK 的常见情况精确，单元测试覆盖。
- 点击 pane 不触发编辑、不改变文本；随后 `switchWindowTo` 执行既有 buffer/LSP/inlay/diag/hover 失效策略。

### 21.6 滚轮

- 每个 notch = **3 行**；无平滑滚动/加速。
- 编辑器：移动该 pane 的 cursor（fold-aware，保持列），不是独立于 cursor 的 viewport —— 渲染器本就保持 cursor 可见，这样行为与 `j/k` 一致且不会下一帧被拉回。Insert 中滚轮仍只移动光标，不退出 Insert。
- filetree/notes/agents：移动同一 selection（与 `j/k` 共用 helper，clamp 到 `[0,len-1]`），不改变 tab/focus。
- AI thread list：移动 `thread_cursor`（clamp）；workbox：Chat 滚动 transcript（`aiScroll`），Changes 滚动 inline/agent diff（既有 `j/k` 的 scroll clamp），Tools/Terminal 无滚动状态则 no-op。
- 终端聚焦/覆盖时滚轮完全不处理；所有滚动都 clamp，不产生 overflow，不启动 busy loop（只有成功改变状态的事件返回 true，触发正常渲染）。

### 21.7 文件与测试

- `src/app/mouse.zig`：纯 hit-test 优先级/边界、scroll clamp、display-row→line、cell→byte、inlay hint 插入；14 个 L1 单测。
- `src/app/mouse_ui.zig`：生命周期、目标收集入口、点击/滚轮分发、pane 映射、rail/terminal 覆盖规则。
- `src/app/hint_ui.zig`、`src/app/hints.zig`：hint target 同时喂鼠标 registry；label 绘制/匹配行为不变。
- `src/app/{render,ai,inline_ui}.zig`：mouse-only pane/separator/scroll 注册 + 目标收集条件；`app/{ai,notes,filetree,inline_ui,agent_edit_ui}.zig` 公开既有 scroll/selection helper。
- `test/e2e.zig`：6 个 `mouse:` pty 测试（tab 点击/关闭 + 80/100/120、navigator、split/光标映射/分隔线、AI thread/tab/prompt/transcript、approve/reject 真安全、mouse 生命周期 + Alt+r + 终端点击/滚轮），SGR 1006 序列由 `sendMouseButton` 注入；`@mouse` scenario tag。
- 验证：`./tools/verify.sh` PASS（最终计数见 TESTING.md）。

### 21.8 明确限制

- **CJK/折行精确性**：wide-grapheme 的 wrap 边界与 emoji ZWJ 的 cell 归属是近似；非折行 ASCII/CJK 精确。
- **终端转发**：vaxis terminal widget 不支持鼠标输入；点击只聚焦，wheel no-op，不伪造 child 点击。
- **选择/复制**：mouse reporting 会接管默认拖选；依赖终端的 Shift 拖选绕过；无法从应用侧强制。
- **无拖拽**：不做 tab 拖拽、分隔线 resize、文本拖选、右键菜单、双击选词。
- **pixel 模式**：强制 cell 坐标，不使用像素级 offset（v1 不需要）。
