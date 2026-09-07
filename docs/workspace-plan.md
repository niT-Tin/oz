# Workspace 支持实施计划（Doom Emacs 风格）

> 状态：**待执行**（2026-09-07 整理，供后续 agent 按步实施；本文件是唯一执行依据）
> 关联文档：`DESIGN.md`（实施时需同步更新，见 §6）

## 1. 需求

像 Doom Emacs 的 workspace：每个 workspace 独立持有自己的 buffer 集合和窗口布局，互不打扰，可随时切换。键位完全按 Doom 默认（oz 的 `<leader>` 就是 Space）：

| 键位 | 动作 |
|------|------|
| `SPC TAB n` | 新建 workspace |
| `SPC TAB .` | picker 选择切换 workspace |
| `SPC TAB r` | 重命名 workspace |
| `SPC TAB d` | 删除当前 workspace |
| `SPC TAB x` | 清空当前 session（杀掉所有 workspace 和 buffer，回到全新状态） |
| `SPC TAB [` | 前一个 workspace |
| `SPC TAB ]` | 后一个 workspace |

leader 族键位走 mode.zig 的 pending 状态机，与现有 `pending_leader_s/b/r/l/t/h`（见 `src/editor/mode.zig:193-203`）完全同款：`SPC` → `pending_leader`，`TAB` → 新增 `pending_leader_tab`，再分发第三键。

## 2. 核心设计决策：swap-on-switch 数据模型

**App 现有的 `buffers` / `windows` / `win_root` / `current` / `current_win` 字段保持不动，它们就是"当前 workspace"的状态**；每个非当前 workspace 把这五个字段存在自己的槽位里。切换 = 把 App 字段存回旧槽位、从目标槽位装入。这样 App 里几百处 `self.buffers` / `self.windows` 引用一行都不用改（tab 栏、H/M/L、picker buffers 模式等自动只作用于当前 workspace）。

```zig
pub const Workspace = struct {
    name: []u8,                        // owned
    buffers: std.ArrayList(Buffer),    // 非当前槽位有效；当前槽位是 moved-from 空壳
    windows: std.ArrayList(Window),
    win_root: ?*WinNode,
    current: usize,
    current_win: usize,
};
```

App 新增字段：`workspaces: std.ArrayList(Workspace)`（恒 ≥1，启动槽位名 "main"）、`current_ws: usize`。

**不变式**：槽位 `current_ws` 持有 moved-from 空容器 + 名字；其余槽位持有完整状态。每次切换：App 字段 → 存回槽位[cur]（覆盖空壳，无泄漏）；槽位[target] → 装入 App（槽位置为 moved-from / win_root=null）。`std.ArrayList` 按值移动即可。

### 2.1 状态分类（切换时的处理）

| 类别 | 内容 | 处理 |
|------|------|------|
| 每 workspace | buffers、windows、win_root、current/current_win | 随 swap 走 |
| 切换时重置 | visual_anchor、in_insert、state.mode→normal、mc_active、easymotion、picker/completion/hover/nav_list/diag_list、inlay、diagnostics、scope_anim/scope_cache | 全部关闭/失效 |
| LSP/git | 单 client 绑定当前 buffer | teardownLsp(false) + ensureLsp()；git diff/blame 由 scheduleGitStatus 重算（路径检查天然防串） |
| 全局共享 | yank_buffer、cmd 历史、recent_files、搜索历史、主题、filetree（cwd 维度）、内嵌终端面板、picker_files 缓存 | 不动 |

### 2.2 两条保护规则

- **防双开**：`openInBuffer`（`src/app/buffers.zig:110`）只查当前 workspace；文件已在其他 workspace 打开 → `setMsg("已在 workspace '<name>' 中打开")` 拒绝。两份 piece table 编辑同一文件会破坏 undo/dirty/LSP 同步；doom 的 buffer 移动语义留作后续。
- **dirty 保护**：`SPC TAB d` / `SPC TAB x` 时任一 dirty buffer → 拒绝并提示数量（vim E37 风格），不做强杀。

## 3. 需求拆分（写入 DESIGN.md §13 作为 M5）

- **W1 核心模型**：Workspace 结构 + App 字段 + 切换/新建/前后切换 + 内存管理（create/deinit）+ 键位管线（mode/key_event/execAction）。
- **W2 交互**：workspace picker（`SPC TAB .`）、重命名（cmdline 预填）、状态栏 `[name]`、keymap_list 条目。
- **W3 生命周期**：`SPC TAB d` 删除（dirty/最后一个拒绝）、`SPC TAB x` 清空 session。
- **W4 测试与文档**：e2e + 单测 + DESIGN.md 更新。

一次交付 W1–W4。

## 4. 实现步骤

### 4.1 `src/app.zig`
- `Window` 定义（app.zig:190 附近）后加 `Workspace` 结构。
- App 字段加 `workspaces`、`current_ws`、`pending_ws_rename: bool = false`。
- `create()`（app.zig:1160 附近）：push "main" 槽位（moved-from 空壳 + dupe 名字）。
- `deinit()`（app.zig:1223 附近）：遍历非当前槽位 deinit buffers（复用 4.2 提取的 `deinitBuffer`）/windows/win_root；所有槽位 free name；`workspaces.deinit`。
- re-export 块（app.zig:1317 之后）加 `app/workspace.zig` 的方法别名。

### 4.2 新文件 `src/app/workspace.zig`
- `deinitBuffer(self, *Buffer)`：从 `closeBufferAt`（`src/app/buffers.zig:187`）提取 per-buffer 释放逻辑（history/pt/folds/spans_cache/hl/span_cache/decors_cache/path）；buffers.zig 改为调用它。
- `wsSwitchTo(self, idx)`：关瞬态 UI → 存当前字段回槽位 → 装目标槽位 → 全局清理（参照 `switchTo` 的清理序列 `src/app/buffers.zig:38-60`，外加 teardownLsp(false)、scope_anim/scope_cache=null）。
- `wsNew(self)`：名字取第一个空闲 `ws{N}`（N 从 2 起）；构造 1 空 Buffer + 1 Window + leaf WinNode（照 `create()` app.zig:1201-1209），append 后切过去。
- `wsSwitchDelta(self, delta: i32)`：wrap 切换。
- `wsRenameStart(self)` / `execWsRename(self)`：cmdline 预填 + `pending_ws_rename`，照抄 `requestRename`/`execRename` 的 cmdline 部分（`src/app/lsp_edit.zig:17-43`）。
- `wsDelete(self)`：最后一个 → 拒绝；当前 workspace 任一 dirty → 拒绝；否则 deinit App 字段里的全部状态 + free 槽位名 + orderedRemove 槽位 + 装入相邻槽位（idx-1 或 0）。
- `wsKillSession(self)`：全部槽位 + 当前状态任一 dirty → 拒绝（报数量）；否则全量 deinit + teardownLsp + 重置为单个 "main" 空 workspace + `setMsg("session cleared")`。
- `curWsName(self) []const u8`。

### 4.3 键位管线
- `src/editor/key_event.zig`：ActionId 加 `workspace_new / workspace_pick / workspace_rename / workspace_delete / workspace_kill_session / workspace_prev / workspace_next`（带注释，参照现有风格 key_event.zig:91-99）。
- `src/editor/mode.zig`：
  - State 加 `pending_leader_tab: bool = false`；`resetPending`（mode.zig:1166-1172）清理。
  - `pending_leader` 分支（mode.zig:464-504）加 `vaxis.Key.tab => { state.pending_leader_tab = true; return .pending; }`。
  - 新增 `pending_leader_tab` 分发块（放在其它族块旁，mode.zig:303-410 区域）：`n`/`.`/`r`/`d`/`x`/`[`/`]` → emitAction；Esc/其他 → resetPending。
  - `.` 重复排除清单（mode.zig:1042 附近）加入这 7 个 action（视图/会话操作，不可重复）。
  - 补单测（仿 mode.zig:1400-1410 的 leader 族测试）。
- `src/app/highlight.zig` `execAction`（highlight.zig:270）：7 个 case 调到 workspace.zig 方法，放在 scroll_cursor_*（highlight.zig:791-793）附近的非编辑动作区。

### 4.4 Picker（`SPC TAB .`）
- `src/app.zig:347` picker_mode 枚举加 `workspaces`。
- `src/app/picker.zig`：`wsOpenPicker`（名字 dupe 进 picker_files、refilter、active，照 `openBufferPicker` picker.zig:60）；accept 分支照 `.buffers`（picker.zig:566 附近）→ `wsSwitchTo(idx)`。
- `src/app/render.zig` picker 渲染（render.zig:1934-1980 的 label/icon/title switch）加 `.workspaces` 分支：title ` Workspaces `，label = 名字（可拼 ` (N buffers)`）。

### 4.5 状态栏（`src/app/render.zig:2854-2880`）
- status 字符串前加 `[{curWsName()}] `（branch 段按 status.len 定位，自动跟随）。

### 4.6 cmdline Enter 分发（`src/app/cmdline.zig:30-39`）
- `pending_rename` 分支旁加 `pending_ws_rename` 分支 → `execWsRename()`；Esc 取消路径（cmdline.zig:21 附近）两处都清。

### 4.7 `src/editor/keymap_list.zig`
- 新增 "Workspace" 分组 7 条，显示串如 `"space tab n"`（显示约定见文件头注释 keymap_list.zig:6-11）。

## 5. 测试

- `src/editor/mode.zig` 单测：7 个 `SPC TAB x` 序列 → 对应 ActionId。
- `test/e2e.zig`（Linux-only，macOS 跑不了，靠 CI）：新建→状态栏名字变化；ws1 开文件、ws2 tab 栏隔离；`[`/`]` 往返；重命名；删除；清空 session；dirty 拒绝。
- 本地 macOS 验证：python pty 冒烟脚本（`os.openpty` + `TIOCSCTTY`，参考此前 wrap/paste/zz 的验证方式）驱动完整流程。
- `zig build` + `zig build test` 必须全绿。

## 6. DESIGN.md 更新（随实施一并提交）

- §0 ADR 表加 **D12**：workspace = 运行时 buffer+窗口分组，swap-on-switch（App 字段即当前 workspace），纯运行时不落盘——不属于 §1.2 排除的 "session 持久化/项目管理"。
- §1.2 后补一句上述说明。
- 新增 **§6.8 Workspace（Doom 风格）**：键位表、语义、§2.1 状态分类表、§2.2 保护规则。
- §13 加 **M5 — Workspace**，列 W1–W4 拆分。

## 7. 明确不做（本里程碑）

- session 落盘持久化（DESIGN.md §1.2 排除；如需以后单独立项）。
- workspace 间移动/共享 buffer（以防双开拒绝代替）。
- 每 workspace 独立 filetree 根 / 独立终端面板（当前全局共享，文档注明）。

## 8. 易踩的坑（给执行者）

1. **moved-from 空壳**：槽位[current_ws] 的 ArrayList 是 moved-from（items 空、cap 0），deinit 安全；但**绝不能**对它 append——任何读写当前 workspace 状态的代码必须走 App 字段。
2. **win_root 指针**：装入 App 后槽位的 win_root 必须置 null，否则 deinit 双重释放。
3. **切换顺序**：`wsSwitchTo` 必须先关 picker/completion 等瞬态 UI 再 swap（它们的索引指向旧 buffer 列表）；LSP 必须 teardown 再 ensureLsp（单 client 模型，参照 `switchWindowTo` app.zig:1056-1077）。
4. **`openInBuffer` 防双开检查**要在 `absolutePath` 之后、load 之前做全 workspace 扫描。
5. **mc_active 重置**：多光标游标是旧 buffer 的字节位置，切换前必须清。
6. **新 workspace 的空 buffer** 会命中 isDashboard 逻辑（与启动时一致）——这是期望行为，不要规避。
