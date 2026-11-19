"""Build static bilingual benchmark pages from the published measurements."""
import csv
from html import escape
import json
import math
from pathlib import Path
import shutil
from statistics import median
from string import Template

SITE = Path(__file__).resolve().parent
DATA = SITE / "benchmark"
VIEWER = SITE.parent / ".bench/perf_report.html"
EDITORS = {"final": "oz", "nvim_clean": "nvim --clean"}
METRICS = {
    "open_ms": ("First frame", "首屏可见"), "jump_ms": ("First G", "首屏后立即 G"),
    "line_ms": (":81", ":81 跳行"), "search_ms": ("Search to first hit", "搜索至首次命中"),
    "top_ms": ("gg to start", "gg 回到开头"), "insert_ms": ("First edit", "首次编辑"),
    "scroll_ms": ("Scroll 80j", "滚动 80j"), "undo_ms": ("Undo", "撤销"),
    "repeat_jump_ms": ("G after undo", "撤销后再次 G"), "switch_ms": (":e next.txt", ":e next.txt"),
    "switch_zig_ms": (":e second.zig", ":e second.zig"),
    "open_jump": ("First frame + first G", "首屏与首次 G 耗时之和"),
    "pss_kib": ("Final process tree PSS (GiB)", "结束时进程树 PSS（GiB）"),
}


def read_timings(study):
    with (DATA / f"{study}-timings.csv").open() as f:
        return list(csv.DictReader(f))


def values(rows, editor, key):
    selected = [row for row in rows if row["editor"] == editor]
    if key == "open_jump":
        samples = [float(row["open_ms"]) + float(row["jump_ms"]) for row in selected]
    else:
        scale = 1048576 if key == "pss_kib" else 1
        samples = [float(row[key]) / scale for row in selected]
    return median(samples), sorted(samples)[math.ceil(len(samples) * .9) - 1]


def table(rows, locale):
    choose = lambda pair: pair[locale]
    caption = choose(("Median / P90 in ms, except where noted.", "中位数 / P90，时间单位为毫秒。"))
    op = choose(("Operation", "操作"))
    bits = [f'<div class="table-wrap" role="region" tabindex="0" aria-label="{caption}"><table>',
            f'<caption>{caption}</caption><thead><tr><th scope="col">{op}</th>']
    bits.extend(f'<th scope="col">{label}</th>' for label in EDITORS.values())
    bits.append("</tr></thead><tbody>")
    for key, label in METRICS.items():
        if key not in rows[0] and not (key == "open_jump" and "repeat_jump_ms" in rows[0]):
            continue
        bits.append(f'<tr data-metric="{key}"><th scope="row">{choose(label)}</th>')
        for ed in EDITORS:
            p50, p90 = values(rows, ed, key)
            bits.append(f'<td>{p50:,.2f}<small> / {p90:,.2f}</small></td>')
        bits.append("</tr>")
    return "\n".join([*bits, "</tbody></table></div>"])


def build(output):
    output.mkdir()
    runs = {s: read_timings(s) for s in ("large", "daily")}
    profiles = {s: json.loads((DATA / f"{s}-stacks.json").read_text()) for s in runs}
    for s in runs:
        shutil.copy2(DATA / f"{s}-timings.csv", output)
    shutil.copy2(DATA / "benchmark.css", output)
    layout = Template((SITE / "benchmark.html").read_text())
    viewer = VIEWER.read_text()
    for locale, short, lang, page in [(0, "en", "en", "index.html"), (1, "zh", "zh-CN", "zh.html")]:
        def t(en, zh):
            return zh if locale else en

        large_tables = []
        for mib in (2048, 1024):
            for cache in ("warm", "cold"):
                file = f"{mib}-{cache}.log"
                selected = [r for r in runs["large"] if r["file"] == file]
                cache_name = t("warm file pages", "热文件页") if cache == "warm" else t("cold file pages", "冷文件页")
                title = f"{mib // 1024} GiB · {cache_name}"
                opened = " open" if not large_tables else ""
                large_tables.append(f'<details id="log-{mib}-{cache}"{opened}><summary>{title}</summary>'
                                    + table(selected, locale) + "</details>")
        warm = [r for r in runs["large"] if r["file"] == "2048-warm.log"]
        flame_links = {}
        for study, report in profiles.items():
            filename = f"{study}-flames-{short}.html"
            back = f'<p><a href="{page}#{study}">← {t("Benchmarks", "性能测试")}</a></p>'
            markup = viewer.replace('<html lang="zh-CN">', f'<html lang="{lang}">')
            payload = json.dumps(report, ensure_ascii=False, separators=(",", ":")).replace("<", r"\u003c")
            (output / filename).write_text(markup.replace("<!--report-navigation-->", back)
                                           .replace("PERF_REPORT_DATA", payload))
            flame_links[study] = filename
        methods = [
            t("AMD Ryzen 9 9950X, Linux x86_64, local NVMe with Btrfs, Zig 0.17.1 ReleaseFast and Neovim 0.12.6. Both macOS targets cross-compiled. All timings on this page were measured on Linux.",
              "AMD Ryzen 9 9950X，Linux x86_64，本机 NVMe / Btrfs，Zig 0.17.1 ReleaseFast，Neovim 0.12.6。两个 macOS 架构均通过交叉编译。此页所有耗时均来自 Linux。"),
            t("Each trial starts a fresh editor in a 120 × 40 tmux terminal. Timing includes key delivery and waiting for the first frame showing the target. The on-disk log fixtures contain numbered synthetic rows tracked in Git. Linux mincore verifies 0% or 100% of file pages resident before startup.",
              "每轮在 120 × 40 的 tmux 中启动新进程，从发键或启动计到目标文字可见。磁盘上的 1 和 2 GiB 日志由带编号的合成文本行组成，均受 Git 跟踪。启动前以 mincore 确认文件页驻留率为 0% 或 100%。"),
            t("Both columns use the same generated files, key sequences and screen checks, with alternating editor order. Neovim --clean loads its bundled runtime and skips user configuration and third-party plugins.",
              "两列使用同一份合成文件、按键和屏幕判定，并轮换编辑器顺序。nvim --clean 加载内置运行时，跳过用户配置与第三方插件。"),
            t("Timing and profiling use separate runs. Linux perf records user-space cycles with frame pointers at a period of two million cycles. Each log condition has three timing trials and two profiling trials. P90 is the largest of the three timing samples. Short operations can yield zero CPU samples.",
              "计时和采样分轮进行。Linux perf 每 200 万个用户态周期采一次，使用帧指针还原调用栈。每种日志条件独立计时三轮、采样两轮，P90 为三次计时中的最大值。较短的操作可能没有 CPU 样本。"),
        ]
        (output / page).write_text(layout.substitute(
            lang=lang, short=short, other_lang=t("zh-CN", "en"), other_url=t("zh.html", "./"),
            other=t("中文", "English"), skip=t("Skip to results", "跳到结果"), home=t("Editor", "编辑器"),
            title=t("Editor benchmarks", "编辑器性能测试"),
            intro=t("How long does it take to see a change after a keystroke? Measured on Git-tracked logs and a Zig source file in a terminal.",
                    "从按下一个键，到看见屏幕上的变化，要等多久？我们在终端里测了 Git 跟踪的大日志和日常编辑的 Zig 源文件。"),
            feature=t("First frame · 2 GiB log · warm pages", "首屏可见 · 2 GiB 日志 · 热文件页"),
            oz_time=f'{values(warm, "final", "open_ms")[0]:,.2f}',
            nvim_time=f'{values(warm, "nvim_clean", "open_ms")[0]:,.2f}',
            large=t("Large logs", "大日志"), large_tables="\n".join(large_tables),
            large_note=t("Each run opens the log, jumps to the end, visits line 81, searches, returns to the top, edits, undoes and jumps again.",
                         "每轮依次打开日志、跳到末行、跳到第 81 行、搜索、回到首行、编辑、撤销、再次跳到末行。"),
            tradeoff=t("oz defers building the full line index. On the warm 2 GiB fixture, clean Neovim wins the first G after the screen appears (1.92 vs 60.33 ms). Adding first frame and first G gives 1,104.89 ms for clean Neovim and 241.51 ms for oz. Background Git marks take longer to arrive than typed text (about 1.58 s in a separate 2 GiB check).",
                       "oz 按需补全行索引。2 GiB 热缓存下，首屏出现后马上按 G，默认 Neovim 耗时 1.92 ms，oz 耗时 60.33 ms。首屏和首次 G 两段相加，默认 Neovim 为 1,104.89 ms，oz 为 241.51 ms。输入先回显，Git 标记随后到达，2 GiB 专项测试中约为 1.58 秒。"),
            daily=t("Everyday Zig editing", "日常 Zig 编辑"),
            daily_note=t("33 KiB of Zig with warm file pages. Each editor ran the same navigation, search, edit, undo and buffer switches. Seven trials measured visible latency and seven separate trials sampled CPU cycles.",
                         "33 KiB Zig 源码，热文件页。两个编辑器执行相同的跳转、搜索、输入、撤销和切换文件操作，各独立计时七轮，另用七轮采样 CPU。"),
            daily_table=table(runs["daily"], locale),
            large_flame=flame_links["large"], daily_flame=flame_links["daily"],
            flame=t("Explore CPU flame graphs", "查看 CPU 火焰图"), csv=t("Download trial data (CSV)", "下载逐轮数据（CSV）"),
            method=t("Measurement conditions", "测试条件"), methods="\n".join(f"<li>{escape(m)}</li>" for m in methods),
            reproduce=t("Reproduce the measurements", "复现测试")))
