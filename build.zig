const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.17 has no @cImport: C headers are translated by the build system
    // and imported as the "c" module.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("x11", .{});
    translate_c.linkSystemLibrary("dbus-1", .{});
    const c_mod = translate_c.createModule();

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    root_module.linkSystemLibrary("x11", .{});
    root_module.linkSystemLibrary("dbus-1", .{});

    const exe = b.addExecutable(.{ .name = "pixx", .root_module = root_module });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run pixx").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
