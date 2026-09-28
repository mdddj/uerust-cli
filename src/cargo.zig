const std = @import("std");
const builtin = @import("builtin");
const out = @import("out.zig");

const Platform = struct {
    binaries_dir: []const u8,
    lib_prefix: []const u8,
    lib_suffix: []const u8,
};

pub fn currentPlatform() Platform {
    return switch (builtin.os.tag) {
        .windows => .{ .binaries_dir = "Win64", .lib_prefix = "", .lib_suffix = ".dll" },
        .macos => .{ .binaries_dir = "Mac", .lib_prefix = "lib", .lib_suffix = ".dylib" },
        else => .{ .binaries_dir = "Linux", .lib_prefix = "lib", .lib_suffix = ".so" },
    };
}

/// 一个可能的 cargo。不预先判断它是否存在 —— 直接试跑，
/// 因为 access() 对断链软链的返回值不可靠，而"能不能跑起来"才是唯一标准。
pub const Candidate = struct {
    exe: []const u8,
    /// true 表示要把 exe 所在的 bin 目录插到子进程 PATH 最前面。
    /// cargo 是用 PATH 找 rustc 的，只给绝对路径不够。
    fix_path: bool,
};

/// 为候选可执行文件准备子进程环境：把它的 bin 目录插到 PATH 最前，
/// 这样它能找到同目录的 rustc。
///
/// `slot` 必须由调用方持有（存活的变量），cloned map 写进 slot，
/// 返回值指向 slot。返回 null 表示不需要改环境。
pub fn childEnvFor(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cand: Candidate,
    slot: *std.process.Environ.Map,
) !?*const std.process.Environ.Map {
    if (!cand.fix_path) return null;
    const bin_dir = std.Io.Dir.path.dirname(cand.exe) orelse return null;
    if (bin_dir.len == 0) return null;

    const old_path = env.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
        bin_dir, std.Io.Dir.path.delimiter, old_path,
    });
    slot.* = try env.clone(arena);
    try slot.*.put("PATH", new_path);
    return slot;
}

/// cargo build --release，然后把产物拷到 <Plugin>/Binaries/<Platform>/。
pub fn build(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    plugin_dir: []const u8,
) !void {
    const path = std.Io.Dir.path;
    const cwd = std.Io.Dir.cwd();

    var plugin = cwd.openDir(io, plugin_dir, .{ .iterate = true }) catch |e| {
        out.fail("打不开插件目录 {s}：{s}", .{ plugin_dir, @errorName(e) });
    };
    defer plugin.close(io);

    // 在 Source/ 下找带 Cargo.toml 的那个目录，不假设它叫什么
    var source = plugin.openDir(io, "Source", .{ .iterate = true }) catch |e| {
        out.fail("{s}/Source 打不开：{s}\n这看起来不是 uerust 生成的插件目录", .{ plugin_dir, @errorName(e) });
    };
    defer source.close(io);

    var rust_dir: ?[]const u8 = null;
    var iter = source.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const probe = try path.join(arena, &.{ entry.name, "Cargo.toml" });
        source.access(io, probe, .{}) catch continue;
        rust_dir = try arena.dupe(u8, entry.name);
        break;
    }

    const rust_dir_name = rust_dir orelse out.fail(
        "{s}/Source 下找不到带 Cargo.toml 的子目录。\n应该有个 <插件名小写>-dylib 的 Rust crate",
        .{plugin_dir},
    );

    // crate 目录名是 kebab-case，库名和产物文件名是 snake_case
    const lib_name = try arena.dupe(u8, rust_dir_name);
    std.mem.replaceScalar(u8, lib_name, '-', '_');

    const platform = currentPlatform();
    const library_file = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        platform.lib_prefix, lib_name, platform.lib_suffix,
    });
    const manifest_path = try path.join(arena, &.{ plugin_dir, "Source", rust_dir_name, "Cargo.toml" });
    const artifact = try path.join(arena, &.{ plugin_dir, "Source", rust_dir_name, "target", "release", library_file });
    const destination = try path.join(arena, &.{ plugin_dir, "Binaries", platform.binaries_dir, library_file });

    const all = try candidates(io, arena, env);

    var tried: std.ArrayList([]const u8) = .empty;
    var child: ?std.process.Child = null;
    var used: []const u8 = "";
    var child_env: std.process.Environ.Map = undefined;

    var argv = [_][]const u8{ "", "build", "--release", "--manifest-path", manifest_path };

    for (all) |cand| {
        var opts: std.process.SpawnOptions = .{ .argv = &argv };
        argv[0] = cand.exe;

        if (try childEnvFor(arena, env, cand, &child_env)) |m| opts.environ_map = m;

        child = std.process.spawn(io, opts) catch {
            try tried.append(arena, cand.exe);
            continue;
        };
        used = cand.exe;
        break;
    }

    const running = child orelse {
        var msg: std.ArrayList(u8) = .empty;
        try msg.appendSlice(arena, "找不到可用的 cargo。试过这些位置：\n");
        for (tried.items) |p| {
            try msg.appendSlice(arena, "  ");
            try msg.appendSlice(arena, p);
            try msg.appendSlice(arena, "\n");
        }
        try msg.appendSlice(arena, "\n装一个：https://rustup.rs");
        out.fail("{s}", .{try msg.toOwnedSlice(arena)});
    };

    out.print(io, "cargo: {s}\n", .{used});
    out.print(io, "crate: {s}\n\n", .{rust_dir_name});

    var run_child = running;
    const term = try std.process.Child.wait(&run_child, io);
    switch (term) {
        .exited => |code| if (code != 0) {
            out.fail("cargo build 失败，退出码 {d}", .{code});
        },
        else => out.fail("cargo 异常结束：{any}", .{term}),
    }

    cwd.access(io, artifact, .{}) catch {
        out.fail(
            "编译过了但没找到产物：\n  {s}\n检查 Cargo.toml：crate-type 必须是 [\"cdylib\"]，[lib] name 要跟上面对上",
            .{artifact},
        );
    };

    try cwd.createDirPath(io, path.dirname(destination).?);
    try cwd.copyFile(artifact, cwd, destination, io, .{ .make_path = true });

    out.print(io, "\n产物就位：\n  {s}\n", .{destination});
    out.print(io, "\n重启 UE 编辑器（或热重载）让插件重新 dlopen 一次。\n", .{});
}

/// 按可能性从高到低列出候选 cargo。
pub fn candidates(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]const Candidate {
    var list: std.ArrayList(Candidate) = .empty;

    if (env.get("CARGO_HOME")) |home| {
        try list.append(arena, .{
            .exe = try std.fmt.allocPrint(arena, "{s}/bin/cargo", .{home}),
            .fix_path = true,
        });
    }

    const home = env.get("HOME") orelse env.get("USERPROFILE");
    if (home) |h| {
        try list.append(arena, .{
            .exe = try std.fmt.allocPrint(arena, "{s}/.cargo/bin/cargo", .{h}),
            .fix_path = true,
        });

        // rustup 的 shim 坏掉时（~/.cargo/bin/cargo 是指向 rustup 的断链），
        // 直接进 toolchain 目录把真 cargo 挖出来。
        const toolchains = try std.fmt.allocPrint(arena, "{s}/.rustup/toolchains", .{h});
        try list.append(arena, .{
            .exe = try std.fmt.allocPrint(arena, "{s}/stable-{s}/bin/cargo", .{ toolchains, hostTriple() }),
            .fix_path = true,
        });

        if (std.Io.Dir.cwd().openDir(io, toolchains, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                try list.append(arena, .{
                    .exe = try std.fmt.allocPrint(arena, "{s}/{s}/bin/cargo", .{ toolchains, entry.name }),
                    .fix_path = true,
                });
            }
        } else |_| {}
    }

    // 最后才回退到 PATH
    try list.append(arena, .{ .exe = "cargo", .fix_path = false });

    return list.toOwnedSlice(arena);
}

pub fn hostTriple() []const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            else => "aarch64-apple-darwin",
        },
        .windows => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-pc-windows-msvc",
            else => "x86_64-pc-windows-msvc",
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => "x86_64-unknown-linux-gnu",
        },
        else => "aarch64-apple-darwin",
    };
}
