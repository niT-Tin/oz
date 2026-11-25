//! Render Markdown diagrams with Mermaid CLI. The worker
//! owns the input and scratch directory; only the UI thread talks to the TTY.
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

pub const max_source_bytes = 64 * 1024;
const max_png_bytes = 2 * 1024 * 1024;
const render_timeout_ms = 20_000;
const Digest = [std.crypto.hash.Blake3.digest_length]u8;

pub const Diagram = struct {
    source: []const u8,
    digest: Digest,

    pub fn init(source: []const u8) Diagram {
        var digest: Digest = undefined;
        std.crypto.hash.Blake3.hash(source, &digest, .{});
        return .{ .source = source, .digest = digest };
    }
};

const Entry = struct { digest: Digest, image: ?vaxis.Image, last_frame: u64 };

pub const State = struct {
    // Bound both the terminal's image memory and cached failures.
    entries: [16]Entry = undefined,
    len: usize = 0,
    frame: u64 = 0,
    job: ?*Job = null,

    fn find(self: *const State, digest: Digest) ?usize {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (std.mem.eql(u8, &entry.digest, &digest)) return i;
        }
        return null;
    }

    pub fn image(self: *const State, diagram: Diagram) ?vaxis.Image {
        const index = self.find(diagram.digest) orelse return null;
        return self.entries[index].image;
    }

    pub fn request(app: *App, diagram: Diagram) void {
        const state = &app.mermaid;
        if (state.find(diagram.digest)) |index| {
            state.entries[index].last_frame = state.frame;
            return;
        }
        if (state.job != null or state.cacheSlot() == null) return;
        const command = app.env_map.get("OZ_MERMAID_CMD") orelse "mmdc";
        if (command.len == 0) return;
        state.job = Job.start(app, command, diagram) catch return;
    }

    pub fn poll(app: *App) bool {
        const state = &app.mermaid;
        const job = state.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        state.job = null;
        defer job.destroy();
        const slot = state.cacheSlot() orelse return false;
        const img = if (job.png) |png| transmitPng(app, png) catch null else null;
        if (slot == state.len) state.len += 1 else if (state.entries[slot].image) |old| {
            app.vx.freeImage(app.tty.writer(), old.id);
        }
        state.entries[slot] = .{ .digest = job.digest, .image = img, .last_frame = state.frame };
        return true;
    }

    fn cacheSlot(self: *const State) ?usize {
        if (self.len < self.entries.len) return self.len;
        var oldest: usize = 0;
        for (self.entries[1..], 1..) |entry, i| {
            if (entry.last_frame < self.entries[oldest].last_frame) oldest = i;
        }
        return if (self.entries[oldest].last_frame < self.frame) oldest else null;
    }

    pub fn deinit(app: *App) void {
        const state = &app.mermaid;
        if (state.job) |job| job.destroy();
        for (state.entries[0..state.len]) |entry| {
            if (entry.image) |img| app.vx.freeImage(app.tty.writer(), img.id);
        }
    }
};

fn transmitPng(app: *App, png: []const u8) !vaxis.Image {
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or
        !std.mem.eql(u8, png[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, png[16..20], .big);
    const height = std.mem.readInt(u32, png[20..24], .big);
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.InvalidPngSize;
    const encoder = std.base64.standard.Encoder;
    const encoded = try app.alloc.alloc(u8, encoder.calcSize(png.len));
    defer app.alloc.free(encoded);
    return app.vx.transmitPreEncodedImage(app.tty.writer(), encoder.encode(encoded, png), @intCast(width), @intCast(height), .png);
}

const Job = struct {
    app: *App,
    alloc: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    source: []const u8,
    digest: Digest,
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    child_done: std.atomic.Value(bool) = .init(false),
    png: ?[]u8 = null,

    fn start(app: *App, command: []const u8, diagram: Diagram) !*Job {
        const alloc = app.alloc;
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const exe = try alloc.dupe(u8, command);
        errdefer alloc.free(exe);
        const source = try alloc.dupe(u8, diagram.source);
        errdefer alloc.free(source);
        job.* = .{
            .app = app,
            .alloc = alloc,
            .io = app.io,
            .command = exe,
            .source = source,
            .digest = diagram.digest,
            .thread = undefined,
        };
        job.thread = try std.Thread.spawn(.{}, run, .{job});
        return job;
    }

    fn destroy(self: *Job) void {
        self.cancelled.store(true, .release);
        self.thread.join();
        const alloc = self.alloc;
        if (self.png) |png| alloc.free(png);
        alloc.free(self.command);
        alloc.free(self.source);
        alloc.destroy(self);
    }

    fn run(self: *Job) void {
        self.png = self.renderPng() catch null;
        self.done.store(true, .release);
        @import("lsp.zig").lspWake(self.app);
    }

    fn renderPng(self: *Job) ![]u8 {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/oz-mermaid-{x}", .{&random});
        const cwd = std.Io.Dir.cwd();
        try cwd.createDir(self.io, path, .fromMode(0o700));
        defer cwd.deleteTree(self.io, path) catch {};
        var dir = try cwd.openDir(self.io, path, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = "diagram.mmd", .data = self.source });
        try dir.writeFile(self.io, .{
            .sub_path = "config.json",
            .data = "{\"securityLevel\":\"strict\",\"maxTextSize\":65536,\"maxEdges\":500}",
        });
        if (self.cancelled.load(.acquire)) return error.Canceled;

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.command, "-i", "diagram.mmd", "-o", "diagram.png", "-c", "config.json", "-b", "white" },
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        defer child.kill(self.io);
        const pid = child.id.?;
        const timer = std.Thread.spawn(.{}, watchChild, .{ self, pid }) catch |err| {
            std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
            return err;
        };
        const result = child.wait(self.io);
        self.child_done.store(true, .release);
        timer.join();
        if (!(try result).success()) return error.MermaidRenderFailed;
        return dir.readFileAlloc(self.io, "diagram.png", self.alloc, .limited(max_png_bytes));
    }

    fn watchChild(self: *Job, pid: std.posix.pid_t) void {
        const end = std.Io.Timestamp.now(self.io, .awake).nanoseconds + render_timeout_ms * std.time.ns_per_ms;
        while (!self.child_done.load(.acquire)) {
            if (self.cancelled.load(.acquire) or std.Io.Timestamp.now(self.io, .awake).nanoseconds >= end) {
                // Let Puppeteer handle SIGTERM and close its browser before
                // forcing an unresponsive renderer to exit.
                std.posix.kill(-pid, std.posix.SIG.TERM) catch return;
                for (0..10) |_| {
                    if (self.child_done.load(.acquire)) return;
                    std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
                }
                if (self.child_done.load(.acquire)) return;
                std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
                return;
            }
            std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
        }
    }
};
