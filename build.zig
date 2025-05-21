const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const rfutures = b.addModule("rfutures", .{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });


    // Path to the directory you want to iterate over
    const dir_path = "src/examples";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch unreachable;
    defer dir.close();

    var it = dir.iterate();

    while (it.next() catch unreachable) |entry| {
        if (entry.kind != .file) continue;

        const filename = entry.name;

        const exe = b.addExecutable(.{ 
            .name = b.fmt("Example {s}", .{filename}), 
            .root_source_file = b.path(b.fmt("src/examples/{s}", .{filename})),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("rfutures", rfutures);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(b.fmt("run.{s}", .{filename}), b.fmt("Run {s} example", .{filename}));

        run_step.dependOn(&run_cmd.step);
    }
    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".

    // const exe_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_exe_unit_tests.step);
}
