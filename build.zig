const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "uerust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.17 去掉了 Build.args（`zig build run -- <args>` 的转发），0.16 还有。
    // 用 @hasField 做条件编译，两个版本都能编过；0.17 上 run 不再转发参数。
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run uerust");
    run_step.dependOn(&run_cmd.step);
}
