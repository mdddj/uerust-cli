const std = @import("std");
const t = @import("templates.zig");
const out = @import("out.zig");

const Sub = struct { needle: []const u8, value: []const u8 };

const FileSpec = struct {
    /// 相对插件根目录的路径，里面的占位符也会被替换
    path: []const u8,
    tmpl: []const u8,
};

/// 生成一个完整的 UE 插件目录。
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    out_root: []const u8,
    force: bool,
) !void {
    try validateName(name);

    const lower = try mapAscii(gpa, name, .lower);
    defer gpa.free(lower);
    const upper = try mapAscii(gpa, name, .upper);
    defer gpa.free(upper);

    const rust_dir = try std.fmt.allocPrint(gpa, "{s}-dylib", .{lower});
    defer gpa.free(rust_dir);
    const lib_name = try std.fmt.allocPrint(gpa, "{s}_dylib", .{lower});
    defer gpa.free(lib_name);

    const subs = [_]Sub{
        .{ .needle = "@@PLUGIN@@", .value = name },
        .{ .needle = "@@LOWER@@", .value = lower },
        .{ .needle = "@@UPPER@@", .value = upper },
        .{ .needle = "@@RUST_DIR@@", .value = rust_dir },
        .{ .needle = "@@LIB@@", .value = lib_name },
    };

    const specs = [_]FileSpec{
        .{ .path = "@@PLUGIN@@.uplugin", .tmpl = t.uplugin },
        .{ .path = "README.md", .tmpl = t.plugin_readme },
        .{ .path = ".gitignore", .tmpl = t.gitignore },
        .{ .path = ".agent/skills/rust-ue-plugin/SKILL.md", .tmpl = t.skill_rust_ue_plugin },
        .{ .path = ".agent/skills/@@LOWER@@-plugin/SKILL.md", .tmpl = t.skill_plugin_manual },
        .{ .path = "Source/@@PLUGIN@@/@@PLUGIN@@.Build.cs", .tmpl = t.build_cs },
        .{ .path = "Source/@@PLUGIN@@/Public/@@PLUGIN@@.h", .tmpl = t.module_h },
        .{ .path = "Source/@@PLUGIN@@/Private/@@PLUGIN@@.cpp", .tmpl = t.module_cpp },
        .{ .path = "Source/@@PLUGIN@@/Public/@@PLUGIN@@Library.h", .tmpl = t.library_h },
        .{ .path = "Source/@@PLUGIN@@/Private/@@PLUGIN@@Library.cpp", .tmpl = t.library_cpp },
        .{ .path = "Source/@@RUST_DIR@@/Cargo.toml", .tmpl = t.cargo_toml },
        .{ .path = "Source/@@RUST_DIR@@/build.rs", .tmpl = t.build_rs },
        .{ .path = "Source/@@RUST_DIR@@/src/lib.rs", .tmpl = t.lib_rs },
    };

    const path = std.Io.Dir.path;
    const cwd = std.Io.Dir.cwd();

    const root = try path.join(gpa, &.{ out_root, name });
    defer gpa.free(root);

    const root_exists = blk: {
        cwd.access(io, root, .{}) catch |e| switch (e) {
            error.FileNotFound => break :blk false,
            else => return e,
        };
        break :blk true;
    };
    if (root_exists and !force) {
        out.fail(
            "目录已存在：{s}\n想覆盖里面的文件就加 --force，或者换个 --out",
            .{root},
        );
    }

    out.print(io, "生成 {s}\n\n", .{root});

    for (specs) |spec| {
        const rel = try render(gpa, spec.path, &subs);
        defer gpa.free(rel);
        const body = try render(gpa, spec.tmpl, &subs);
        defer gpa.free(body);

        const full = try path.join(gpa, &.{ root, rel });
        defer gpa.free(full);

        if (path.dirname(full)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = full, .data = body });

        out.print(io, "  {s}\n", .{rel});
    }

    out.print(io, "\n下一步：\n", .{});
    out.print(io, "  1. cd {s} && uerust build .    # cargo build --release + 拷库到 Binaries/\n", .{root});
    out.print(io, "  2. 把 {s}/ 拷进 <你的项目>/Plugins/ 下（UE 会自动发现，uproject 不用改）\n", .{name});
    out.print(io, "     想显式启用就在 .uproject 里补一条，数组已存在就插进去、别整段替换：\n", .{});
    out.print(io, "       \"Plugins\": [ {{ \"Name\": \"{s}\", \"Enabled\": true }} ]\n", .{name});
    out.print(io, "  3. 重新生成项目文件 + 编译，编辑器里「编辑 > 插件」确认已启用\n", .{});
    out.print(io, "  4. 蓝图搜 \"Fetch Markdown From Url\"\n", .{});
    out.print(io, "  5. 给 AI 助手用：.agent/skills/ 下已带 2 个 skill\n", .{});
    out.print(io, "       rust-ue-plugin          通用「Rust 核心 + UE5 插件」流程\n", .{});
    out.print(io, "       {s}-plugin  这个插件的维护手册\n", .{lower});
    out.print(io, "     想让 skill 覆盖整个 UE 项目而不只是插件目录，把 .agent/ 拷到 <项目>/ 根下\n", .{});
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) out.fail("插件名不能为空", .{});
    if (!std.ascii.isAlphabetic(name[0])) {
        out.fail("插件名必须以字母开头：{s}", .{name});
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            out.fail(
                "插件名只能有字母、数字、下划线（UE 和 C++ 标识符的限制），这里是 '{c}'：{s}",
                .{ c, name },
            );
        }
    }
}

/// 单趟扫描替换所有占位符。不用 std.fmt 是因为模板里有大量花括号。
fn render(gpa: std.mem.Allocator, tmpl: []const u8, subs: []const Sub) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    var i: usize = 0;
    outer: while (i < tmpl.len) {
        for (subs) |s| {
            if (std.mem.startsWith(u8, tmpl[i..], s.needle)) {
                try buf.appendSlice(gpa, s.value);
                i += s.needle.len;
                continue :outer;
            }
        }
        try buf.append(gpa, tmpl[i]);
        i += 1;
    }
    return buf.toOwnedSlice(gpa);
}

fn mapAscii(
    gpa: std.mem.Allocator,
    s: []const u8,
    comptime dir: enum { upper, lower },
) ![]u8 {
    const result = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = switch (dir) {
            .upper => std.ascii.toUpper(c),
            .lower => std.ascii.toLower(c),
        };
    }
    return result;
}
