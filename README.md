# oz

自己实现、自己用的终端文本编辑器，使用 Zig 编写。

需求来源：`~/.config/nvim/editor-spec.md`（多年 Neovim 配置提炼）；架构参考：`~/sources/flow`。

## 构建与运行

需要 Zig 0.16.0：

```sh
zig build
zig build run
```

## 文档

- [DESIGN.md](DESIGN.md) — 架构设计与分阶段路线图（v1）
- [docs/architecture.excalidraw](docs/architecture.excalidraw) — 架构图（可用 Excalidraw / VS Code 打开）

## 当前进度

- [x] 设计文档 v1.1（架构、命令模式、工作流、测试策略、路线图）
- [x] **M0 地基（核心已落地）**：
  - vaxis 集成：raw 模式、kitty 键盘协议、alt screen、resize、diff 渲染
  - PieceTable + 行索引（含随机不变量测试）、undo/redo（组 + 分支语义）
  - 六模式状态机骨架：Normal/Insert/Visual/Visual Line/Visual Block/Command（解析层已实现）
  - 基础移动（hjkl w/e/b/ge ^/0/$ gg/G {/} % f/F/t/T ctrl-u/d/f/b）+ count
  - 文件加载（含 `file:NN` 定位）、相对行号、状态栏、插入模式编辑（含 jk 退出）
  - 测试：`zig build test`（83 个单测）+ `zig build e2e`（pty 端到端：渲染/插入/退出）
- [ ] M0 收尾：命令模式 `:` 执行（:w/:q/:e/:bn/…）、yank/put + 系统剪贴板、undo 键位接线
- [ ] M1 MVP：文本对象/surround/注释/对齐/easymotion/多光标/tree-sitter/文件树/picker/tab 栏/命令历史补全替换
- [ ] M2 LSP + 补全：8 个 server、completion/ghost text/snippet、诊断
- [ ] M3 Git + 终端：git gutter/hunk/blame、PTY + VT 仿真、lazygit
- [ ] M4 UI 打磨 + AI：折叠/zen/markdown 渲染、主题、AI 补全与 chat
