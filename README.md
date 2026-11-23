# oz

A Vim-style terminal editor written in Zig. Edit in splits, look up symbols with LSP, and work alongside Codex, Kimi Code or DeepSeek Harness through ACP.

[Download](https://github.com/niT-Tin/oz/releases/latest) · [Website](https://nit-tin.github.io/oz/?lang=en) · [中文](README.zh-CN.md)

![oz editing its own chart renderer with the project tree open](website/assets/editor.png)

## Open your first file

Download the archive for Linux or macOS (x86_64 or arm64), extract it, then run:

```sh
./oz path/to/file
```

Press `i` to edit, `Esc` to return to Normal mode, and `:wq` to save and quit. `Space e` opens the file tree. `F1` shows the full keymap.

Files shows two Git status columns, index then worktree. `M.` means staged, `.M` means modified on disk, and `MM` means both. The letters follow Git porcelain status (`A` added, `D` deleted, `R` renamed, `UU` both modified in a conflict). `??` marks an untracked file and `*` a directory with changes.

Open Git Review with `Space g v` or `:GitReview`. Press `Tab` to switch between Changes and History, `Enter` to read a patch, and `o` to open the corresponding source line.

[Connect a coding agent](https://nit-tin.github.io/oz/?lang=en#agents) · [Build from source](https://nit-tin.github.io/oz/?lang=en#download) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)
