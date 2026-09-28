//! `uerust doctor` —— 本机环境自检。
//!
//! 目标是回答一个问题：这台机器现在能不能编译 Rust 写 UE 插件？
//! 只看机器环境（Rust 工具链、Unreal 安装、Xcode、.NET），不看具体项目。

const std = @import("std");
const builtin = @import("builtin");
const out = @import("out.zig");
const cargo = @import("cargo.zig");

const Status = enum { ok, warn, fail };

fn tag(s: Status) []const u8 {
    return switch (s) {
        .ok => "[OK]",
        .warn => "[ !]",
        .fail => "[X!]",
    };
}

fn worse(a: Status, b: Status) Status {
    return if (statusRank(a) >= statusRank(b)) a else b;
}

fn statusRank(x: Status) u8 {
    return switch (x) {
        .ok => 0,
        .warn => 1,
        .fail => 2,
    };
}

const Row = struct {
    section: []const u8,
    name: []const u8,
    status: Status,
    detail: []const u8,
    hint: ?[]const u8 = null,
};

const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    rows: std.ArrayList(Row) = .empty,

    fn add(self: *Ctx, section: []const u8, name: []const u8, status: Status, detail: []const u8) !void {
        try self.rows.append(self.arena, .{
            .section = section,
            .name = name,
            .status = status,
            .detail = detail,
        });
    }

    fn addHint(self: *Ctx, section: []const u8, name: []const u8, status: Status, detail: []const u8, hint: []const u8) !void {
        try self.rows.append(self.arena, .{
            .section = section,
            .name = name,
            .status = status,
            .detail = detail,
            .hint = hint,
        });
    }
};

pub fn run(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    var ctx = Ctx{ .io = io, .arena = arena, .env = env };

    try checkRust(&ctx);
    try checkUnreal(&ctx);
    try checkHostTools(&ctx);
    try checkCiRunner(&ctx);

    try print(&ctx);
}

// ---------------------------------------------------------------- Rust

fn checkRust(ctx: *Ctx) !void {
    const S = "Rust";

    // 用和 `uerust build` 完全相同的顺序找一个真能跑的 cargo，
    // 而不是假设 ~/.cargo/bin/cargo 是好的。
    var found: ?[]const u8 = null;
    var version: []const u8 = "";
    var slot: std.process.Environ.Map = undefined;
    const all = try cargo.candidates(ctx.io, ctx.arena, ctx.env);

    for (all) |cand| {
        const argv = [_][]const u8{ cand.exe, "--version" };
        var opts: std.process.SpawnOptions = .{ .argv = &argv, .stdout = .pipe, .stderr = .ignore };
        if (try cargo.childEnvFor(ctx.arena, ctx.env, cand, &slot)) |m| opts.environ_map = m;

        var child = std.process.spawn(ctx.io, opts) catch continue;
        const text = readChild(ctx, &child);
        const term = std.process.Child.wait(&child, ctx.io) catch continue;
        switch (term) {
            .exited => |code| if (code != 0) continue,
            else => continue,
        }
        found = cand.exe;
        version = firstLine(text);
        break;
    }

    if (found == null) {
        try ctx.addHint(S, "cargo", .fail, "找不到任何能运行的 cargo", "装：curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh");
    } else {
        try ctx.add(S, "cargo", .ok, try std.fmt.allocPrint(ctx.arena, "{s}  ({s})", .{ found.?, version }));
    }

    // rustc 必须是 cargo 的同目录兄弟，否则 cargo 会报 "could not execute process rustc"
    if (found) |exe| {
        const dir = std.Io.Dir.path.dirname(exe) orelse ".";
        const suffix = if (builtin.os.tag == .windows) ".exe" else "";
        const rustc_path = try std.fmt.allocPrint(ctx.arena, "{s}/rustc{s}", .{ dir, suffix });

        var slot2: std.process.Environ.Map = undefined;
        const cand = cargo.Candidate{ .exe = rustc_path, .fix_path = true };
        const argv = [_][]const u8{ rustc_path, "--version" };
        var opts: std.process.SpawnOptions = .{ .argv = &argv, .stdout = .pipe, .stderr = .ignore };
        if (try cargo.childEnvFor(ctx.arena, ctx.env, cand, &slot2)) |m| opts.environ_map = m;

        if (std.process.spawn(ctx.io, opts)) |spawned| {
            var child = spawned;
            const text = readChild(ctx, &child);
            const term = std.process.Child.wait(&child, ctx.io) catch std.process.Child.Term{ .unknown = 0 };
            const good = switch (term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (good) {
                try ctx.add(S, "rustc", .ok, firstLine(text));
            } else {
                try ctx.addHint(S, "rustc", .fail, try std.fmt.allocPrint(ctx.arena, "{s} 存在但跑不起来", .{rustc_path}), "rustc 和 cargo 必须来自同一个 toolchain 目录");
            }
        } else |_| {
            try ctx.addHint(S, "rustc", .fail, try std.fmt.allocPrint(ctx.arena, "{s} 不存在", .{rustc_path}), "重装工具链：rustup toolchain install stable");
        }
    } else {
        try ctx.add(S, "rustc", .fail, "跳过（没有 cargo 就没法定位 rustc）");
    }

    try checkRustupShims(ctx, S);
    try checkCargoOnPath(ctx, S);
}

/// 这一项是专门为踩过的坑加的：~/.cargo/bin 里那批是**相对**软链，
/// 全部指向同目录的 rustup。rustup 本体一丢，13 个 shim 集体变断链，
/// cargo / rustc 就从机器上"消失"了 —— 但 toolchain 本身完好无损。
fn checkRustupShims(ctx: *Ctx, S: []const u8) !void {
    const home = ctx.env.get("HOME") orelse ctx.env.get("USERPROFILE") orelse {
        try ctx.add(S, "rustup", .warn, "HOME 环境变量读不到，跳过检查");
        return;
    };
    const cwd = std.Io.Dir.cwd();
    const bin_dir = try std.fmt.allocPrint(ctx.arena, "{s}/.cargo/bin", .{home});

    var total: usize = 0;
    var broken: usize = 0;

    if (cwd.openDir(ctx.io, bin_dir, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(ctx.io);
        var it = d.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (entry.kind != .sym_link) continue;
            total += 1;
            const full = try std.Io.Dir.path.join(ctx.arena, &.{ bin_dir, entry.name });
            if (cwd.statFile(ctx.io, full, .{})) |_| {} else |_| {
                broken += 1;
            }
        }
    } else |_| {
        try ctx.add(S, "rustup", .warn, try std.fmt.allocPrint(ctx.arena, "{s} 不存在", .{bin_dir}));
        return;
    }

    // rustup 本体在不在，决定了所有 shim 有没有目标
    const rustup_bin = try std.fmt.allocPrint(ctx.arena, "{s}/rustup", .{bin_dir});
    const has_rustup = if (cwd.statFile(ctx.io, rustup_bin, .{})) |_| true else |_| false;

    if (!has_rustup) {
        try ctx.addHint(
            S,
            "rustup shim",
            .fail,
            try std.fmt.allocPrint(ctx.arena, "rustup 本体丢了 —— {d} 个软链是断的", .{if (broken > 0) broken else total}),
            "curl -fsSL https://rsproxy.cn/rustup/dist/aarch64-apple-darwin/rustup-init -o /tmp/ri && cp /tmp/ri ~/.cargo/bin/rustup && chmod +x ~/.cargo/bin/rustup",
        );
    } else if (broken > 0) {
        try ctx.addHint(
            S,
            "rustup shim",
            .warn,
            try std.fmt.allocPrint(ctx.arena, "{d}/{d} 个软链断了", .{ broken, total }),
            "rustup component add <缺失的组件>，或者忽略（rls / cargo-miri 这种本来就没装）",
        );
    } else {
        try ctx.add(S, "rustup shim", .ok, try std.fmt.allocPrint(ctx.arena, "{d}/{d} 个软链全部可解析", .{ total, total }));
    }
}

fn checkCargoOnPath(ctx: *Ctx, S: []const u8) !void {
    const home = ctx.env.get("HOME") orelse return;
    const path_var = ctx.env.get("PATH") orelse {
        try ctx.add(S, "PATH", .warn, "PATH 环境变量读不到");
        return;
    };
    const want = try std.fmt.allocPrint(ctx.arena, "{s}/.cargo/bin", .{home});

    if (std.mem.indexOf(u8, path_var, want) != null) {
        try ctx.add(S, "PATH", .ok, try std.fmt.allocPrint(ctx.arena, "{s} 在 PATH 里", .{want}));
    } else {
        try ctx.addHint(S, "PATH", .warn, try std.fmt.allocPrint(ctx.arena, "{s} 不在 PATH 里", .{want}), "在 shell 配置里加：export PATH=\"$PATH:$HOME/.cargo/bin\"");
    }

    // 顺手抓一个很常见、很难自己想明白的坑
    const alias_hint = "别名会盖住真命令。用 \\cargo 绕过别名试试";
    const zshrc = try std.fmt.allocPrint(ctx.arena, "{s}/.zshrc", .{home});
    if (readFile(ctx, zshrc, 1 << 20)) |text| {
        if (std.mem.indexOf(u8, text, "alias cargo=")) |_| {
            try ctx.addHint(S, "cargo 别名", .warn, "~/.zshrc 里有 alias cargo=…，交互式终端里 cargo 会被它接管", alias_hint);
        }
    } else |_| {}
}

// ---------------------------------------------------------------- Unreal

fn checkUnreal(ctx: *Ctx) !void {
    const S = "Unreal Engine";
    const cwd = std.Io.Dir.cwd();

    var installs: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "/Users/Shared/Epic Games", "/Applications/Epic Games" }) |root| {
        if (cwd.openDir(ctx.io, root, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(ctx.io);
            var it = d.iterate();
            while (it.next(ctx.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (!std.mem.startsWith(u8, entry.name, "UE_")) continue;
                try installs.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ root, entry.name }));
            }
        } else |_| {}
    }

    if (installs.items.len == 0) {
        try ctx.addHint(S, "安装", .fail, "没找到任何 UE_* 安装目录", "Epic Games Launcher → 虚幻引擎 → 安装 5.8，然后装 C++ 编译组件");
        return;
    }

    // 版本高的排前面
    std.mem.sort([]const u8, installs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.lt);

    for (installs.items) |install| {
        const name = std.Io.Dir.path.basename(install);
        var status: Status = .ok;
        var problems: std.ArrayList([]const u8) = .empty;
        var version_text: []const u8 = "";

        const version_file = try std.Io.Dir.path.join(ctx.arena, &.{ install, "Engine/Build/Build.version" });
        if (readFile(ctx, version_file, 64 * 1024)) |text| {
            const major = jsonNumber(text, "MajorVersion");
            const minor = jsonNumber(text, "MinorVersion");
            const patch = jsonNumber(text, "PatchVersion");
            if (major != null and minor != null and patch != null) {
                version_text = try std.fmt.allocPrint(ctx.arena, "{d}.{d}.{d}", .{ major.?, minor.?, patch.? });
            } else {
                version_text = "版本号解析失败";
                status = worse(status, .warn);
            }
        } else |_| {
            version_text = "缺 Engine/Build/Build.version";
            status = .fail;
            try problems.append(ctx.arena, "安装残缺");
        }

        // 装好引擎才有这两个
        const editor = try std.Io.Dir.path.join(ctx.arena, &.{ install, "Engine/Binaries/Mac/UnrealEditor.app" });
        if (!fileExists(ctx, editor)) {
            try problems.append(ctx.arena, "缺 UnrealEditor.app");
            status = worse(status, .warn);
        }

        const build_sh = try std.Io.Dir.path.join(ctx.arena, &.{ install, "Engine/Build/BatchFiles/Mac/Build.sh" });
        const ubt = try std.Io.Dir.path.join(ctx.arena, &.{ install, "Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll" });
        if (!fileExists(ctx, build_sh) or !fileExists(ctx, ubt)) {
            try problems.append(ctx.arena, "UBT 不全");
            status = worse(status, .fail);
        }

        if (!hasDotnet(ctx, install)) {
            try problems.append(ctx.arena, "缺自带 dotnet");
            status = worse(status, .warn);
        }

        if (problems.items.len == 0) {
            try ctx.add(S, name, .ok, try std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{ version_text, install }));
        } else {
            var joined: std.ArrayList(u8) = .empty;
            for (problems.items, 0..) |p, i| {
                if (i > 0) try joined.appendSlice(ctx.arena, "、");
                try joined.appendSlice(ctx.arena, p);
            }
            const hint = if (status == .fail)
                "Epic Games Launcher → 库 → 该版本 → 验证/重新安装"
            else
                "引擎能跑，但 C++ 编译可能不完整：Launcher → 验证";
            try ctx.addHint(S, name, status, try std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{ version_text, joined.items }), hint);
        }
    }
}

/// UE 在 Mac 上用自带的 .NET 跑 UBT，路径随架构不同。
fn hasDotnet(ctx: *Ctx, install: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const dotnet_root = std.Io.Dir.path.join(ctx.arena, &.{ install, "Engine/Binaries/ThirdParty/DotNet" }) catch return false;

    const arch_dir = switch (builtin.cpu.arch) {
        .aarch64 => "mac-arm64",
        else => "mac-x64",
    };

    var dir = cwd.openDir(ctx.io, dotnet_root, .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const exe = std.Io.Dir.path.join(ctx.arena, &.{ dotnet_root, entry.name, arch_dir, "dotnet" }) catch continue;
        if (fileExists(ctx, exe)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- 宿主工具

fn checkHostTools(ctx: *Ctx) !void {
    const S = "宿主工具";

    if (builtin.os.tag == .macos) {
        if (runCapture(ctx, "xcodebuild", &.{ "-version" })) |text| {
            const line = firstLine(text);
            if (line.len > 0) {
                try ctx.add(S, "Xcode", .ok, try std.fmt.allocPrint(ctx.arena, "{s}  ({s})", .{ line, secondLine(text) }));
            } else {
                try ctx.add(S, "Xcode", .warn, "xcodebuild 没输出");
            }
        } else |_| {
            try ctx.addHint(S, "Xcode", .fail, "xcodebuild 跑不起来", "xcode-select --install  或者从 App Store 装完整 Xcode");
        }

        if (runCapture(ctx, "xcode-select", &.{"-p"})) |text| {
            try ctx.add(S, "工具链路径", .ok, firstLine(text));
        } else |_| {}
    }

    // zig 自己（uerust 是 zig 写的，但用户可能想改）
    if (runCapture(ctx, "zig", &.{"version"})) |text| {
        try ctx.add(S, "zig", .ok, try std.fmt.allocPrint(ctx.arena, "{s}（改 uerust 需要）", .{firstLine(text)}));
    } else |_| {
        try ctx.add(S, "zig", .warn, "没装，只影响你自己改 uerust 源码");
    }
}

// ---------------------------------------------------------------- CI runner

/// 这台机器上装了一个 GitHub Actions 自托管 runner。如果它和本地用户共用
/// `~/.cargo` + `~/.rustup`，CI 每次跑的 `rustup toolchain install/default`
/// 就会直接改你本地的工具链 —— 包括把 `~/.cargo/bin/rustup` 换掉。
/// 已经因此被坑过一次（rustup 被删、13 个 shim 断链）。
/// 这台机器上装了 GitHub Actions 自托管 runner。如果它和本地用户共用
/// `~/.cargo` + `~/.rustup`，CI 每次跑的 `rustup toolchain install/default`
/// 就会直接改你本地的工具链 —— 包括把 `~/.cargo/bin/rustup` 换掉。
/// 已经因此被坑过一次（rustup 被删、13 个 shim 断链）。
///
/// 注意：`~/actions-runner/.env` 在服务模式下**是不读的**。runsvc.sh 只认 `.path`
/// （用它覆盖 PATH），其他变量得写在 launchd plist 里。这里查的就是这两个真正生效的位置。
fn checkCiRunner(ctx: *Ctx) !void {
    const S = "CI Runner";
    const join = std.Io.Dir.path.join;
    const cwd = std.Io.Dir.cwd();

    const home = ctx.env.get("HOME") orelse return;
    const runner_dir = try join(ctx.arena, &.{ home, "actions-runner" });
    const path_file = try join(ctx.arena, &.{ runner_dir, ".path" });
    if (!fileExists(ctx, path_file)) return; // 没装 runner 就不显示这一节

    const user_cargo_bin = try join(ctx.arena, &.{ home, ".cargo/bin" });

    // 1) PATH：runsvc.sh 里 `export PATH=$(cat .path)`
    var path_has_user_cargo = false;
    if (readFile(ctx, path_file, 1 << 20)) |text| {
        path_has_user_cargo = std.mem.indexOf(u8, text, user_cargo_bin) != null;
    } else |_| {}

    // 2) CARGO_HOME / RUSTUP_HOME：只在 launchd plist 的 EnvironmentVariables 里生效
    var owned_home = false;
    const launch_agents = try join(ctx.arena, &.{ home, "Library/LaunchAgents" });
    if (cwd.openDir(ctx.io, launch_agents, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(ctx.io);
        var it = d.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "actions.runner.")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".plist")) continue;

            const plist = try join(ctx.arena, &.{ launch_agents, entry.name });
            const text = readFile(ctx, plist, 1 << 20) catch continue;
            if (std.mem.indexOf(u8, text, "CARGO_HOME") != null and
                std.mem.indexOf(u8, text, "RUSTUP_HOME") != null)
            {
                owned_home = true;
            }
        }
    } else |_| {}

    if (!path_has_user_cargo and owned_home) {
        try ctx.add(S, "工具链隔离", .ok, "runner 用自己的 CARGO_HOME / RUSTUP_HOME，PATH 里也没有你的 ~/.cargo/bin");
        return;
    }

    var what: std.ArrayList(u8) = .empty;
    if (path_has_user_cargo) try what.appendSlice(ctx.arena, "PATH 里有你的 ~/.cargo/bin");
    if (!owned_home) {
        if (what.items.len > 0) try what.appendSlice(ctx.arena, "，");
        try what.appendSlice(ctx.arena, "没设自己的 CARGO_HOME / RUSTUP_HOME");
    }
    try ctx.addHint(
        S,
        "工具链隔离",
        .warn,
        try std.fmt.allocPrint(ctx.arena, "runner 会和你的本地工具链打架（{s}）", .{what.items}),
        "改 ~/actions-runner/.path 里的 ~/.cargo/bin 为 runner 自己的 bin，并在 launchd plist 的 EnvironmentVariables 加 CARGO_HOME / RUSTUP_HOME（.env 在服务模式下不生效）",
    );
}

// ---------------------------------------------------------------- 工具函数

fn readChild(ctx: *Ctx, child: *std.process.Child) []const u8 {
    const f = child.stdout orelse return "";
    var buf: [4096]u8 = undefined;
    var r = f.reader(ctx.io, &buf);
    const text = r.interface.allocRemaining(ctx.arena, std.Io.Limit.limited(256 * 1024)) catch return "";
    return text;
}

/// 起一个进程把 stdout 收进来。任何一步失败都返回 error。
fn runCapture(ctx: *Ctx, exe: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try ctx.arena.alloc([]const u8, args.len + 1);
    argv[0] = exe;
    @memcpy(argv[1..], args);

    const opts: std.process.SpawnOptions = .{ .argv = argv, .stdout = .pipe, .stderr = .ignore };
    var child = try std.process.spawn(ctx.io, opts);
    const text = readChild(ctx, &child);
    const term = try std.process.Child.wait(&child, ctx.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.NonZeroExit,
        else => return error.AbnormalExit,
    }
    if (text.len == 0) return error.NoOutput;
    return text;
}

fn readFile(ctx: *Ctx, abs_path: []const u8, limit: usize) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(ctx.io, abs_path, .{});
    defer f.close(ctx.io);
    var buf: [4096]u8 = undefined;
    var r = f.reader(ctx.io, &buf);
    return try r.interface.allocRemaining(ctx.arena, std.Io.Limit.limited(limit));
}

fn fileExists(ctx: *Ctx, abs_path: []const u8) bool {
    return if (std.Io.Dir.cwd().statFile(ctx.io, abs_path, .{})) |_| true else |_| false;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

fn secondLine(text: []const u8) []const u8 {
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    const rest = text[first_end + 1 ..];
    return firstLine(rest);
}

/// 极简 JSON 数字取值 —— 只够解析 Build.version，不引依赖、不分配。
fn jsonNumber(text: []const u8, key: []const u8) ?i64 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, key)) |at| {
        search_from = at + 1;

        // 确认 key 真的被引号包着，避免匹配到 "CompatibleChangelist" 这类前缀重叠
        if (at == 0 or text[at - 1] != '"') continue;
        const key_end = at + key.len;
        if (key_end >= text.len or text[key_end] != '"') continue;

        var i = key_end + 1;
        while (i < text.len and text[i] != ':') : (i += 1) {}
        if (i >= text.len) return null;
        i += 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}

        const start = i;
        while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '-')) : (i += 1) {}
        if (i == start) return null;
        return std.fmt.parseInt(i64, text[start..i], 10) catch null;
    }
    return null;
}
// ---------------------------------------------------------------- 输出

fn print(ctx: *Ctx) !void {
    const io = ctx.io;
    out.print(io, "\nuerust doctor —— 本机环境自检\n", .{});

    var section: []const u8 = "";
    var ok_count: usize = 0;
    var warn_count: usize = 0;
    var fail_count: usize = 0;

    for (ctx.rows.items) |row| {
        if (!std.mem.eql(u8, section, row.section)) {
            out.print(io, "\n{s}\n", .{row.section});
            section = row.section;
        }
        out.print(io, "  {s} {s:<16} {s}\n", .{ tag(row.status), row.name, row.detail });
        if (row.hint) |h| out.print(io, "       → {s}\n", .{h});

        switch (row.status) {
            .ok => ok_count += 1,
            .warn => warn_count += 1,
            .fail => fail_count += 1,
        }
    }

    out.print(io, "\n{d} 项通过", .{ok_count});
    if (warn_count > 0) out.print(io, "，{d} 项警告", .{warn_count});
    if (fail_count > 0) out.print(io, "，{d} 项失败", .{fail_count});
    out.print(io, "\n", .{});

    if (fail_count > 0) {
        out.print(io, "有阻塞项，先修失败的再动别的。\n\n", .{});
        std.process.exit(1);
    }
    out.print(io, "环境可编译 Rust UE 插件。\n\n", .{});
}
