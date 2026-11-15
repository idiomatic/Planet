const std = @import("std");

const app_name = "Uncanny Planet";
const swift_sources = [_][]const u8{
    "app/Sources/App.swift",
    "app/Sources/Benchmark.swift",
    "app/Sources/ContentView.swift",
    "app/Sources/FlightView.swift",
    "app/Sources/LaunchOptions.swift",
    "app/Sources/Math.swift",
    "app/Sources/ParameterPanel.swift",
    "app/Sources/Planet.swift",
    "app/Sources/Renderer.swift",
    "app/Sources/Shaders.swift",
    "app/Sources/Snapshot.swift",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
    } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });
    const coarse_level = b.option(u5, "coarse-level", "Stored global subdivision level (default 6)") orelse 6;

    const options = b.addOptions();
    options.addOption(u5, "coarse_level", coarse_level);

    const core = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addOptions("build_options", options);

    const lib = b.addLibrary(.{ .name = "uncanny", .linkage = .static, .root_module = core });
    lib.bundle_compiler_rt = true;

    const swiftc = b.addSystemCommand(&.{ "xcrun", "swiftc", "-wmo", "-parse-as-library" });
    swiftc.addArgs(&.{ "-target", "arm64-apple-macos15.0", "-swift-version", "6" });
    swiftc.addArgs(if (optimize == .debug) &.{ "-Onone", "-g" } else &.{"-O"});
    swiftc.addArg("-import-objc-header");
    swiftc.addFileArg(b.path("core/include/uncanny.h"));
    for (swift_sources) |source| swiftc.addFileArg(b.path(source));
    swiftc.addArtifactArg(lib);
    swiftc.addArg("-o");
    const exe = swiftc.addOutputFileArg(app_name);

    const contents = app_name ++ ".app/Contents";
    const install_exe = b.addInstallFileWithDir(exe, .{ .custom = contents ++ "/MacOS" }, app_name);
    const install_plist = b.addInstallFileWithDir(b.path("app/Info.plist"), .{ .custom = contents }, "Info.plist");
    b.getInstallStep().dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&install_plist.step);

    const run = b.addRunFile(b.graph.path(.install_prefix, contents ++ "/MacOS/" ++ app_name));
    run.addPassthruArgs();
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run core tests").dependOn(&b.addRunArtifact(tests).step);
}
