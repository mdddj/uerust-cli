const std = @import("std");
const gen = @import("gen.zig");
const cargo = @import("cargo.zig");
const doctor = @import("doctor.zig");
const out = @import("out.zig");

const usage =
    \\uerust —— UE5 + Rust 插件脚手架
    \\
    \\用法
    \\  uerust new <PluginName> [--out <目录>] [--force]
    \\      生成完整 UE 插件目录：
    \\        <PluginName>.uplugin
    \\        Source/<PluginName>/         C++ 模块 + 蓝图异步节点
    \\        Source/<小写名>-dylib/       Rust cdylib crate（含 cbindgen）
    \\      默认生成到 ./<PluginName>
    \\
    \\  uerust build <插件目录>
    \\      在插件的 Rust crate 里跑 cargo build --release，
    \\      并把产物拷到 <插件目录>/Binaries/<平台>/
    \\
    \\  uerust doctor
    \\      检查本机环境能不能编译 Rust UE 插件：
    \\      Rust 工具链 / Unreal 安装 / Xcode / .NET，逐项给结论和修法
    \\
    \\  uerust help
    \\
    \\例子
    \\  uerust new UEHtml2Md
    \\  cd UEHtml2Md && uerust build .
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.next(); // argv0

    const cmd = args.next() orelse {
        out.print(io, "{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, cmd, "new")) {
        const plugin_name = args.next() orelse {
            out.fail("new 后面要跟插件名，例如：uerust new UEHtml2Md", .{});
        };

        var out_root: []const u8 = ".";
        var force = false;
        while (args.next()) |flag| {
            if (std.mem.eql(u8, flag, "--out")) {
                out_root = args.next() orelse {
                    out.fail("--out 后面要跟目录", .{});
                };
            } else if (std.mem.eql(u8, flag, "--force")) {
                force = true;
            } else {
                out.fail("不认识的参数：{s}", .{flag});
            }
        }

        try gen.run(io, arena, plugin_name, out_root, force);
    } else if (std.mem.eql(u8, cmd, "build")) {
        const plugin_dir = args.next() orelse {
            out.fail("build 后面要跟插件目录，例如：uerust build ./UEHtml2Md", .{});
        };
        try cargo.build(io, arena, init.environ_map, plugin_dir);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try doctor.run(io, arena, init.environ_map);
    } else if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        out.print(io, "{s}", .{usage});
    } else {
        out.fail("不认识的命令：{s}\n\n{s}", .{ cmd, usage });
    }
}
