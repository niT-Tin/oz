# oz

一个从零开始实现的终端文本编辑器，使用 Zig 编写（学习项目，灵感来自 [kilo](https://viewsourcecode.org/snaptoken/kilo/)）。

## 构建与运行

需要 Zig 0.16.0：

```sh
zig build
zig build run
```

## 当前进度

- [x] 终端 raw mode（termios：关闭 ICANON / ECHO / ISIG 等）
- [x] 从 stdin 逐字节读取按键，区分控制字符与可打印字符
- [ ] 转义序列解析（方向键、功能键）
- [ ] 屏幕绘制与光标控制
- [ ] 文本缓冲与编辑
