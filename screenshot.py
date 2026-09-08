#!/usr/bin/env python3
"""Generate oz README screenshots: drive the real binary in a pty, replay its
ANSI stream through a terminal emulator (pyte), and rasterize the screen to
PNG with a Nerd Font (Maple Mono NF CN, covers CJK + icons + box drawing)."""
import os, pty, struct, fcntl, termios, time, select, re, sys
import pyte
from PIL import Image, ImageDraw, ImageFont

OZ = "./zig-out/bin/oz"
FONT = "/home/leoz/.local/share/fonts/MapleMono-NF-CN-Regular.ttf"
FONT_SIZE = 36

# ANSI named colors (pyte maps the 16 basic colors to names) → RGB.
NAMED = {
    "black": (0x26, 0x26, 0x26), "red": (0xd7, 0x00, 0x5f),
    "green": (0x87, 0xaf, 0x5f), "brown": (0xd7, 0xaf, 0x5f),
    "blue": (0x5f, 0x87, 0xd7), "magenta": (0xaf, 0x5f, 0xd7),
    "cyan": (0x5f, 0xd7, 0xd7), "white": (0xe4, 0xe4, 0xe4),
    "brightblack": (0x8a, 0x8a, 0x8a), "brightred": (0xd7, 0x5f, 0x87),
    "brightgreen": (0xaf, 0xd7, 0x5f), "brightbrown": (0xff, 0xff, 0x87),
    "brightblue": (0x87, 0xaf, 0xff), "brightmagenta": (0xff, 0x87, 0xff),
    "brightcyan": (0x87, 0xff, 0xff), "brightwhite": (0xff, 0xff, 0xff),
}
DEFAULT_FG = (0xdc, 0xd7, 0xba)  # kanagawa fg
DEFAULT_BG = (0x1f, 0x1f, 0x28)  # kanagawa bg


def resolve(color, default):
    if color == "default":
        return default
    if color in NAMED:
        return NAMED[color]
    if re.fullmatch(r"[0-9a-fA-F]{6}", color):
        return tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))
    return default


def normalize_sgr(data: bytes) -> bytes:
    """vaxis emits truecolor as `38:2:r:g:b` (colon); pyte only parses the
    semicolon form. Rewrite ':' to ';' inside every SGR (`m`) sequence."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        if data[i:i + 2] == b"\x1b[":
            j = i + 2
            while j < n and not (0x40 <= data[j] <= 0x7E):
                j += 1
            if j < n:
                seg = bytes(data[i:j + 1])
                if seg.endswith(b"m"):
                    seg = seg.replace(b":", b";")
                out += seg
                i = j + 1
                continue
        out.append(data[i])
        i += 1
    return bytes(out)


class Session:
    def __init__(self, rows, cols, args):
        self.rows, self.cols = rows, cols
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
            env = dict(os.environ, TERM="xterm-256color", HOME="/tmp")
            os.execve(OZ, [OZ] + args, env)
        os.close(slave)
        self.pid = pid

    def pump(self, timeout=0.3):
        """Read available output, feeding the emulator; returns bytes read."""
        got = b""
        end = time.time() + timeout
        while True:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    return got
                if not chunk:
                    return got
                got += chunk
                self.stream.feed(normalize_sgr(chunk))
                continue
            if time.time() >= end:
                break
        return got

    def text(self):
        return "\n".join(self.screen.display)

    def wait_for(self, needle, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.3)
            if needle in self.text():
                return True
        return False

    def send(self, s):
        os.write(self.master, s.encode())

    def close(self):
        try:
            os.kill(self.pid, 9)
        except OSError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass


def render(screen, out_path):
    cols, rows = screen.columns, screen.lines
    font = ImageFont.truetype(FONT, FONT_SIZE)
    # monospace advance + font line height
    tmp = Image.new("RGB", (8, 8)); d = ImageDraw.Draw(tmp)
    cw = int(round(font.getlength("M"))) or 1
    asc, desc = font.getmetrics()
    ch = asc + desc
    img = Image.new("RGB", (cols * cw, rows * ch), DEFAULT_BG)
    d = ImageDraw.Draw(img)
    buf = screen.buffer
    for y in range(rows):
        row = buf[y] if y in buf else {}
        for x in range(cols):
            cell = row.get(x)
            if cell is None:
                fg, bg, chch = DEFAULT_FG, DEFAULT_BG, " "
            else:
                fg = resolve(cell.fg, DEFAULT_FG)
                bg = resolve(cell.bg, DEFAULT_BG)
                chch = cell.data or " "
            px, py = x * cw, y * ch
            if bg != DEFAULT_BG:
                d.rectangle([px, py, px + cw - 1, py + ch - 1], fill=bg)
            if chch != " ":
                d.text((px, py), chch, font=font, fill=fg)
    img.save(out_path)
    print("wrote", out_path, img.size)


def seed_recent():
    """Pre-populate $HOME/.cache/oz/recent so the dashboard shows files."""
    d = "/tmp/.cache/oz"
    os.makedirs(d, exist_ok=True)
    paths = [
        "/home/leoz/sources/oz/src/main.zig",
        "/home/leoz/sources/oz/src/app/filetree.zig",
        "/home/leoz/sources/oz/build.zig",
        "/home/leoz/sources/oz/README.md",
    ]
    with open(d + "/recent", "w") as f:
        f.write("\n".join(paths) + "\n")


def shot_dashboard():
    seed_recent()
    s = Session(30, 100, [])
    if not s.wait_for("Find File", 6.0):
        print("dashboard not found:", s.text())
    s.pump(0.4)
    render(s.screen, "docs/screenshots/dashboard.png")
    s.close()


def shot_workspace_picker():
    s = Session(30, 100, ["build.zig"])
    s.wait_for("build.zig", 6.0)
    s.send(" \tn")      # SPC TAB n — new workspace ws2
    s.wait_for("Find File", 6.0)  # ws2 shows the dashboard
    s.send(" \t[")      # SPC TAB [ — back to main (build.zig)
    s.wait_for("build.zig", 6.0)
    s.send(" \t.")      # SPC TAB . — workspace picker over the file
    s.wait_for("Workspaces", 6.0)
    s.pump(0.4)
    render(s.screen, "docs/screenshots/workspace.png")
    s.close()


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "dashboard"):
        shot_dashboard()
    if which in ("all", "workspace"):
        shot_workspace_picker()
