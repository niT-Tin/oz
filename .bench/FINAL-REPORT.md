# oz 性能优化最终报告（vs nvim --clean）

日期：2026-09-02 · 环境：pty 120×40，TERM=xterm-256color，ReleaseFast -Dstrip
方法：同一 pty 驱动两个编辑器（oz / `nvim --clean`），按键→首个输出字节的墙钟延迟，中位数；语料 `.bench/corpus/`（生成式）。

## 结果总览（中位数）

| 指标 | 优化前 | 优化后 | Δ | nvim --clean | 对比 |
|---|---|---|---|---|---|
| 启动（空文件） | 124 ms | 124 ms | — | 227 ms | oz 快 1.8× |
| 打开 90KB zig | 201 ms | 201 ms | — | 227 ms | oz 快 |
| 打开 12MB 文件 | 130 ms | 128 ms | — | 235 ms | oz 快 1.8× |
| 打开 50MB 文件 | 146 ms | 140 ms | — | 252 ms | oz 快 1.8× |
| 内存：12MB 文件 | 29.7 MB | **18.7 MB** | **-37%** | 9.9 MB | mmap 零拷贝 |
| 内存：50MB 文件 | 58.4 MB | 58.7 MB | 0% | 10 MB | 无堆拷贝；映射页随行索引触碰 |
| **打字 12MB（无语法）** | **3.8 ms/键** | **0.2 ms/键** | **-95%** | 0.1 ms/键 | 差距 38× → 2× |
| j（90KB 语法文件） | 6.1 ms/键 | **0.2 ms/键** | **-97%** | ~0.1 ms/键 | 差距 60× → 2× |
| k/G 底部（90KB） | 25.2 ms/键 | **1.2 ms/键** | **-95%** | ~0.1 ms/键 | 21× 提升 |
| w/e/b/f/{}（90KB） | 0.4–0.8 ms | **0.1 ms** | -75~88% | ~0.1 ms | 持平 |
| 搜索 12MB（/ 与 n） | 0.4 ms/键 | **0.2 ms/键** | -50% | 0.1–0.2 ms | 持平 |
| gg / G / ctrl-f（12MB） | 0.2–0.3 | 0.2–0.3 | — | 0.1–0.5 | 持平 |

所有按键延迟 ≤1.2ms（60fps 预算 16ms），人眼不可感知。剩余 G-k 的 1.2ms 是整帧重绘成本（oz 默认相对行号、作用域高亮等特性，nvim --clean 光标移动只写光标转义）。

## 修复的热点（按贡献排序）

### 1. PieceTable 行索引：全量重建 → 增量维护（打字 3.8→0.2 ms）
`src/buffer/piece_table.zig`（Agent A，e7578fc）
- `replace()` 后不再全文件扫描重建 `line_starts`：前缀不变、删除区间的行起始摘除、插入字节的 '\n' 生成新起始、后缀整体平移 delta，一次 splice 完成（O(本地)）。
- `replace()` 不再每次编辑新建+释放整个 piece 列表：持久化 scratch 列表复用（常规按键零分配）；失败语义保持（表不变）。
- `byteAt` 加最后访问 piece 提示（顺序访问摊还 O(1)）。
- 随机不变量测试（500 步 vs 镜像）全绿。

### 2. 渲染管线：空行扫描/分配/诊断索引（j 6.1→0.2，G-k 25→1.2 ms）
`src/main.zig`（Agent B，d40bbcc + dbd12bc）
- 空行"上下文扫描"从每行最多 500 行×逐字符 byteAt 改为**每个连续空行段只扫一次**、isBlankLine/lineIndentLevels 单次 copyRange 进栈缓冲。
- 每行 3 次堆分配（行号×2+文本）→ 每帧 4 次（栈缓冲 + 复用）。
- LSP 诊断 gutter O(行×诊断) → 排序后移动指针 O(行+诊断)。
- scopeAt 结果按（光标, revision）缓存；blame ghost label 缓存。
- **1ms 轮询切片 + 16ms 渲染节流**：动画/blame 保持期按键延迟从 ≤16ms 降到 ≤1ms。
- 视口 span 缓存（SpanRangeCache）：未滚动按键的 tree-sitter query 从每帧执行变为指针取用。
- 光标下方向 EOF 行数循环加视口高度上限（135k 行文件每帧不再扫到 EOF）。

### 3. 语法高亮：spans 9.48→0.29 ms/视口；scopeAt 5.4ms→45µs
`src/syntax.zig` + `visibleSpansFor`（Agent D，c0045e9 + 9f1f60a）
- bracketDepth 的 `ts_node_parent` 逐级从根重扫（O(N²)≈7.4ms）→ 单遍 tree-cursor DFS（O(可见)）。
- `ts_node_child(i)` O(i) 索引扫描（911 子节点≈1.5ms）→ walkVisible 单遍游标。
- 修 treez 的 TSTreeCursor 尺寸错误（24 vs 28 字节，编辑后 SEGFAULT）—— 用自己的 extern 声明。
- 每 buffer 按 (revision, byte range) 缓存合并 spans；Query.Cursor 复用。

### 4. Motion：w/e/b/f/t/% 从 O(字符×pieces) → O(行)（≤1µs/步）
`src/editor/motion.zig`（Agent C，dee6072）
- 4KiB 滑动窗口（DocScan）经 copyRange 一次取行，本地切片扫描；跨行继续取下一行。
- 10.7MB/8404-pieces 文档上逐 motion：4.6–11.9µs → 0.80–0.83µs（ReleaseFast）。

### 5. 内存/搜索/LSP 同步（mmap、零拷贝搜索、增量 didChange）
`src/main.zig` + `src/lsp/*` + `piece_table.initMapped`（Agent E，50f2dfd）
- 文件加载 mmap（PROT.READ, MAP.PRIVATE）零拷贝进 PieceTable（`initMapped`，deinit munmap）；失败回退 read+dupe；`saveFile` 改临时文件+rename（mmap 下原地截断会 SIGBUS）。
- 搜索不再整文档拷贝：逐 piece `indexOf` + 边界重叠窗口；`/` 与 `n` 共享。
- LSP didChange 增量同步（contentChanges=[{range,text}]，UTF-16 位置）；切换回未改文档零拷贝（lsp_synced_rev 跳过 didOpen）。
- 12MB 文件 RSS 29.6→18.5MB。

### 6. 事件循环最终帧修复（合并时发现的回归，ebe6385）
- 根因：1ms 轮询模式（scope 动画/blame 保持）结束时，16ms 渲染节流可能跳过最终帧，随后 `pollEvent` 阻塞 → blame ghost（1s CursorHold 到期）或动画最后一帧永远不绘制（e2e git 测试 ~2/3 概率失败）。
- 修复：poll→block 转换点强制渲染一次（`poll_mode_active` 标志）。
- 验证：e2e 连跑 8/8 全绿（修复前 ~2/3 失败）。

## 验证

- `zig build test`：全绿（含 500 步随机不变量、motion 位置、mock LSP range 编辑测试）。
- `zig build e2e`：109/109 全绿（3 次连续全绿 + 修复后 8/8）。已知环境性 flake 说明：并发构建共享 zig 缓存时会偶发陈旧 mock_lsp 二进制导致 LSP 测试误报（清 `find .zig-cache/o -name mock_lsp -delete && rm -rf .zig-cache/h` 解决）。
- 分支：`perf/a-piece`、`perf/b-render`、`perf/c-motion`、`perf/d-syntax`、`perf/e-startup` 已合入 master。

## 复现

```sh
python3 .bench/corpus/gen.py            # 生成语料（gitignored）
python3 .bench/run_bench.py --iters 5   # 全量基准 → .bench/results/final.md
python3 .bench/diff_reports.py .bench/results/baseline.md .bench/results/final.md
```
