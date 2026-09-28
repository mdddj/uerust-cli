const std = @import("std");

/// 往 stdout 打一段文本。Io.Writer 自己会按需把缓冲刷到文件，buffer 大小只是批量粒度。
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const file = std.Io.File.stdout();
    var w = file.writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// 打印错误然后退出，退出码 1。
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.process.fatal(fmt, args);
}
