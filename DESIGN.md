# oz 编辑器设计文档

> 目标：用 Zig 实现一个**只满足自己需求**的 TUI 编辑器（需求来源：`~/.config/nvim/editor-spec.md`，多年 Neovim 配置提炼）。
> 参考仓库：`~/sources/flow`（Flow Control，成熟的 Zig TUI 编辑器，本设计大量借鉴其架构决策）。
> 状态：**设计阶段**（v1，待评审）。本文档是架构与路线图的唯一权威来源，随实现演进。

---

## 0. 决策记录（ADR 摘要）

| # | 决策 | 结论 | 理由 |
|---|------|------|------|
| D1 | 终端层 | **用 vaxis**（flow 同款，neurocyte fork，Zig 0.16） | 纯 Zig、静态链接；自带 kitty 键盘协议、鼠标、24bit 色、屏幕 diff 渲染。省下数月工作量，把精力放在编辑核心 |
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

---

## 1. 目标与范围

### 1.1 必须达成（摘自 spec）

- Modal 编辑，六模式：Normal / Insert / Visual / Visual Line / Visual Block / **Command**（vim `:` 命令模式，用户补充，见 §6.7）
- Leader = `Space`，Insert 下 `jk` 退回 Normal，相对行号，块/beam 光标
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

### 1.3 非功能约束

- **帧率**：主循环目标 ≤8ms/帧（flow 为 ≤6ms），输入零感知延迟
- **大文件**：>2MB 或 >50k 行自动降级（关高亮/关 LSP/停 blame），不卡死
- **崩溃安全**：`noswapfile`/`nowritebackup` 已排除写盘负担；退出时可靠恢复终端状态
- **终端兼容**：kitty 协议缺失时降级到标准转义序列；16 色可用（语义色槽保证无彩色也可用，见 §4.6）

---

## 2. 技术选型

| 组件 | 选择 | 说明 |
|------|------|------|
| 语言/工具链 | Zig 0.16.0 | 与 flow 同版本，`std.Io` API |
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

- 文本对象 `iw/aw/i(/a(...` + d/c/y/v 组合
- surround（ys/ds/cs）、注释（gcc/gc）、对齐（ga）
- EasyMotion（s / leader f）
- 多光标（Ctrl+n + Visual Block 加光标）
- tree-sitter 高亮（首批：zig/rust/go/python/ts/js/json/markdown，其余随用随加）
- TabBar（图标/修改标记/诊断计数）+ buffer 管理（leader bb/bn/bj/bk）
- 文件树（leader e/E）
- 统一 fuzzy picker：文件（git 仓库含 hidden）/ grep（ripgrep）/ buffer / 最近文件
- 命令模式增强：历史持久（会话内）+ Tab 补全（命令名/路径/选项）+ `:s` 替换（inccommand 实时预览）+ Visual 选区范围注入（`:'<,'>s`）
- Dashboard

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
- **M3b**：PTY + 迷你 VT 仿真（参考 flow `terminal/`），<M-r>/<M-w>/<M-e> 三种终端布局；终端内 Esc 退回 Normal

> 风险标注：M3b（内嵌终端仿真）是全项目最大工程项。若受阻，M3a 独立交付，M3b 可后置为 M4。

### M4 — UI 打磨 + AI（≈3-4 周）

- sticky context、彩虹括号、折叠（ts 驱动 + 摘要行）、zen 模式
- markdown 内联渲染、颜色预览（#rrggbb）、TODO/FIXME 高亮 + leader tt 列表
- CursorHold 单词自动高亮（120ms）、多主题切换（kanagawa-wave 默认）
- 大文件降级策略落地
- AI（spec §9）：行内补全源（Copilot/兼容 API，限 3 条与补全菜单合并）、chat 浮窗（选区提问）、外部 LLM API（DeepSeek 等）滚动翻译等内置能力

**M4 通过 = spec 全量功能落地。**

---

## 14. 风险与取舍

| 风险 | 影响 | 缓解 |
|------|------|------|
| 内嵌终端仿真工程量巨大 | M3b 延期 | 拆 M3a/M3b；参考 flow `terminal/` 直接移植思路；lazygit 走外部浮窗先行 |
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
