const std = @import("std");
const builtin = @import("builtin");

const optimize_deps = .ReleaseFast;

/// Struct for all configuration options for building the application.
/// When adding new build options, please add them to this struct rather than
/// extending function parameters directly. This helps maintain clean function signatures
/// and makes it easier to pass configuration throughout the build process.
const BuildOptions = struct {
    // Core build steps
    run_step: *std.Build.Step,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
    lint_step: *std.Build.Step,

    // Build configuration
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    exe_install_options: std.Build.Step.InstallArtifact.Options = .{},

    // Feature flags
    tracy_enabled: bool = false,
    use_tree_sitter: bool = false,
    strip: bool = false,
    use_llvm: bool = false,
    pie: bool = false,
    gui: bool = false,

    // Set user config file path
    config: []const u8 = "",
};

pub fn build(b: *std.Build) void {
    const release = b.option(bool, "package_release", "Build all release targets") orelse false;

    const options = BuildOptions{
        // Core build steps
        .run_step = b.step("run", "Run the app"),
        .check_step = b.step("check", "Check the app"),
        .test_step = b.step("test", "Run unit tests"),
        .lint_step = b.step("lint", "Run lints"),

        // Build options
        .tracy_enabled = b.option(bool, "enable_tracy", "Enable tracy client library (default: no)") orelse false,
        .use_tree_sitter = b.option(bool, "use_tree_sitter", "Enable tree-sitter (default: yes)") orelse true,
        .strip = b.option(bool, "strip", "Disable debug information (default: no)"),
        .use_llvm = b.option(bool, "use_llvm", "Enable llvm backend (default: none)"),
        .pie = b.option(bool, "pie", "Produce an executable with position independent code (default: none)"),
        .gui = b.option(bool, "gui", "Standalone GUI mode") orelse false,
        .config = b.option(
            []const u8,
            "config",
            "Set path to a config file",
        ) orelse "",
    };

    return (if (release) &build_release else &build_development)(b, options);
}

fn build_development(
    b: *std.Build,
    opt: BuildOptions,
) void {
    opt.target = b.standardTargetOptions(.{
        .default_target = .{ .abi = if (builtin.os.tag == .linux and !opt.tracy_enabled) .musl else null },
    });

    opt.optimize = b.standardOptimizeOption(.{});

    return build_exe(b, opt);
}

fn build_release(
    b: *std.Build,
    opt: BuildOptions,
) void {
    opt.optimize = .ReleaseFast;
    opt.strip = true;

    var version = std.ArrayList(u8).init(b.allocator);
    defer version.deinit();
    gen_version(b, version.writer()) catch unreachable;

    const write_file_step = b.addWriteFiles();
    const version_file = write_file_step.add("version", version.items);
    b.getInstallStep().dependOn(&b.addInstallFile(version_file, "version").step);

    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        opt.target = b.resolveTargetQuery(t);
        const target_path = blk: {
            var triple = std.mem.splitScalar(u8, t.zigTriple(b.allocator) catch unreachable, '-');
            const arch = triple.next() orelse unreachable;
            const os = triple.next() orelse unreachable;

            break :blk std.mem.join(b.allocator, "-", &[_][]const u8{ os, arch }) catch unreachable;
        };

        opt.exe_install_options = .{
            .dest_dir = .{
                .override = .{
                    .custom = target_path,
                },
            },
        };

        if (t.os_tag == .windows) {
            opt.gui = true;
        }

        build_exe(b, opt);
    }
}

pub fn build_exe(
    b: *std.Build,
    opt: BuildOptions,
) void {
    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", opt.tracy_enabled);
    options.addOption(bool, "use_tree_sitter", opt.use_tree_sitter);
    options.addOption(bool, "strip", opt.strip);
    options.addOption(bool, "gui", opt.gui);

    const options_mod = options.createModule();

    std.fs.cwd().makeDir(".cache") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache\") failed: {any}", .{e}),
    };
    std.fs.cwd().makeDir(".cache/cdb") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("makeDir(\".cache/cdb\") failed: {any}", .{e}),
    };

    var version_info = std.ArrayList(u8).init(b.allocator);
    defer version_info.deinit();
    gen_version_info(b, opt.target, version_info.writer(), opt.optimize) catch {
        version_info.clearAndFree();
        version_info.appendSlice("unknown") catch {};
    };

    const wf = b.addWriteFiles();
    const version_info_file = wf.add("version", version_info.items);

    const vaxis_dep = b.dependency("vaxis", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const flags_dep = b.dependency("flags", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const dizzy_dep = b.dependency("dizzy", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const fuzzig_dep = b.dependency("fuzzig", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const thespian_dep = b.dependency("thespian", .{
        .target = opt.target,
        .optimize = opt.optimize_deps,
        .enable_tracy = opt.tracy_enabled,
    });

    const thespian_mod = thespian_dep.module("thespian");
    const cbor_mod = thespian_dep.module("cbor");

    const tracy_dep = if (opt.tracy_enabled) thespian_dep.builder.dependency("tracy", .{
        .target = opt.target,
        .optimize = opt.optimize,
    }) else undefined;
    const tracy_mod = if (opt.tracy_enabled) tracy_dep.module("tracy") else b.createModule(.{
        .root_source_file = b.path("src/tracy_noop.zig"),
    });

    const zg_dep = vaxis_dep.builder.dependency("zg", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });

    const zeit_dep = b.dependency("zeit", .{
        .target = opt.target,
        .optimize = opt.optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const themes_dep = b.dependency("themes", .{});

    const syntax_dep = b.dependency("syntax", .{
        .target = opt.target,
        .optimize = opt.optimize_deps,
        .use_tree_sitter = opt.use_tree_sitter,
    });
    const syntax_mod = syntax_dep.module("syntax");

    const help_mod = b.createModule(.{
        .root_source_file = b.path("help.md"),
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const gui_config_mod = b.createModule(.{
        .root_source_file = b.path("src/gui_config.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const log_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const command_mod = b.createModule(.{
        .root_source_file = b.path("src/command.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const EventHandler_mod = b.createModule(.{
        .root_source_file = b.path("src/EventHandler.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const color_mod = b.createModule(.{
        .root_source_file = b.path("src/color.zig"),
    });

    const Buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/buffer/Buffer.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "CaseData", .module = zg_dep.module("CaseData") },
        },
    });

    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/vaxis/input.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });

    const tui_renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderer/vaxis/renderer.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "color", .module = color_mod },
        },
    });

    const renderer_mod = blk: {
        if (opt.gui) switch (opt.target.result.os.tag) {
            .windows => {
                const win32_dep = b.lazyDependency("win32", .{}) orelse break :blk tui_renderer_mod;
                const win32_mod = win32_dep.module("win32");
                const gui_mod = b.createModule(.{
                    .root_source_file = b.path("src/win32/gui.zig"),
                    .imports = &.{
                        .{ .name = "build_options", .module = options_mod },
                        .{ .name = "win32", .module = win32_mod },
                        .{ .name = "cbor", .module = cbor_mod },
                        .{ .name = "thespian", .module = thespian_mod },
                        .{ .name = "input", .module = input_mod },
                        // TODO: we should be able to work without these modules
                        .{ .name = "vaxis", .module = vaxis_mod },
                        .{ .name = "color", .module = color_mod },
                        .{ .name = "gui_config", .module = gui_config_mod },
                        .{ .name = "tracy", .module = tracy_mod },
                    },
                });
                gui_mod.addIncludePath(b.path("src/win32"));

                const mod = b.createModule(.{
                    .root_source_file = b.path("src/renderer/win32/renderer.zig"),
                    .imports = &.{
                        .{ .name = "theme", .module = themes_dep.module("theme") },
                        .{ .name = "win32", .module = win32_mod },
                        .{ .name = "cbor", .module = cbor_mod },
                        .{ .name = "thespian", .module = thespian_mod },
                        .{ .name = "input", .module = input_mod },
                        .{ .name = "gui", .module = gui_mod },
                        // TODO: we should be able to work without these modules
                        .{ .name = "tuirenderer", .module = tui_renderer_mod },
                        .{ .name = "vaxis", .module = vaxis_mod },
                    },
                });
                break :blk mod;
            },
            else => |tag| {
                std.log.err("OS '{s}' does not support -Dgui mode", .{@tagName(tag)});
                std.process.exit(0xff);
            },
        };
        break :blk tui_renderer_mod;
    };

    const keybind_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/keybind.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
        },
    });

    const keybind_test_run_cmd = blk: {
        const tests = b.addTest(.{
            .root_source_file = b.path("src/keybind/keybind.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        });
        tests.root_module.addImport("cbor", cbor_mod);
        tests.root_module.addImport("command", command_mod);
        tests.root_module.addImport("EventHandler", EventHandler_mod);
        tests.root_module.addImport("input", input_mod);
        tests.root_module.addImport("thespian", thespian_mod);
        tests.root_module.addImport("log", log_mod);
        tests.root_module.addImport("Buffer", Buffer_mod);
        // b.installArtifact(tests);
        break :blk b.addRunArtifact(tests);
    };

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/shell.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
        },
    });

    const ripgrep_mod = b.createModule(.{
        .root_source_file = b.path("src/ripgrep.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "log", .module = log_mod },
        },
    });

    const location_history_mod = b.createModule(.{
        .root_source_file = b.path("src/location_history.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
        },
    });

    const project_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/project_manager.zig"),
        .imports = &.{
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
        },
    });

    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/diff.zig"),
        .imports = &.{
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "dizzy", .module = dizzy_dep.module("dizzy") },
            .{ .name = "log", .module = log_mod },
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const text_manip_mod = b.createModule(.{
        .root_source_file = b.path("src/text_manip.zig"),
        .imports = &.{},
    });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/tui.zig"),
        .imports = &.{
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "thespian", .module = thespian_mod },
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "gui_config", .module = gui_config_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "command", .module = command_mod },
            .{ .name = "EventHandler", .module = EventHandler_mod },
            .{ .name = "location_history", .module = location_history_mod },
            .{ .name = "project_manager", .module = project_manager_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "text_manip", .module = text_manip_mod },
            .{ .name = "Buffer", .module = Buffer_mod },
            .{ .name = "keybind", .module = keybind_mod },
            .{ .name = "shell", .module = shell_mod },
            .{ .name = "ripgrep", .module = ripgrep_mod },
            .{ .name = "theme", .module = themes_dep.module("theme") },
            .{ .name = "themes", .module = themes_dep.module("themes") },
            .{ .name = "tracy", .module = tracy_mod },
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "color", .module = color_mod },
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "help.md", .module = help_mod },
            .{ .name = "fuzzig", .module = fuzzig_dep.module("fuzzig") },
            .{ .name = "zeit", .module = zeit_mod },
        },
    });

    const exe_name = if (opt.gui) "flow-gui" else "flow";

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
        .strip = opt.strip,
        .win32_manifest = b.path("src/win32/flow.manifest"),
    });

    if (opt.use_llvm) |value| {
        exe.use_llvm = value;
        exe.use_lld = value;
    }
    if (opt.pie) |value| exe.pie = value;
    exe.root_module.addImport("build_options", options_mod);
    exe.root_module.addImport("flags", flags_dep.module("flags"));
    exe.root_module.addImport("cbor", cbor_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("Buffer", Buffer_mod);
    exe.root_module.addImport("tui", tui_mod);
    exe.root_module.addImport("thespian", thespian_mod);
    exe.root_module.addImport("log", log_mod);
    exe.root_module.addImport("tracy", tracy_mod);
    exe.root_module.addImport("renderer", renderer_mod);
    exe.root_module.addImport("input", input_mod);
    exe.root_module.addImport("syntax", syntax_mod);
    exe.root_module.addImport("color", color_mod);
    exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));

    if (opt.target.result.os.tag == .windows) {
        exe.addWin32ResourceFile(.{
            .file = b.path("src/win32/flow.rc"),
        });
        if (opt.gui) {
            exe.subsystem = .Windows;
        }
    }

    const exe_install = b.addInstallArtifact(exe, opt.exe_install_options);
    b.getInstallStep().dependOn(&exe_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    opt.run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
    });

    check_exe.root_module.addImport("build_options", options_mod);
    check_exe.root_module.addImport("flags", flags_dep.module("flags"));
    check_exe.root_module.addImport("cbor", cbor_mod);
    check_exe.root_module.addImport("config", config_mod);
    check_exe.root_module.addImport("Buffer", Buffer_mod);
    check_exe.root_module.addImport("tui", tui_mod);
    check_exe.root_module.addImport("thespian", thespian_mod);
    check_exe.root_module.addImport("log", log_mod);
    check_exe.root_module.addImport("tracy", tracy_mod);
    check_exe.root_module.addImport("renderer", renderer_mod);
    check_exe.root_module.addImport("input", input_mod);
    check_exe.root_module.addImport("syntax", syntax_mod);
    check_exe.root_module.addImport("color", color_mod);
    check_exe.root_module.addImport("version_info", b.createModule(.{ .root_source_file = version_info_file }));
    opt.check_step.dependOn(&check_exe.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("test/tests.zig"),
        .target = opt.target,
        .optimize = opt.optimize,
        .use_llvm = opt.use_llvm,
        .use_lld = opt.use_llvm,
        .strip = opt.strip,
    });

    tests.pie = opt.pie;
    tests.root_module.addImport("build_options", options_mod);
    tests.root_module.addImport("log", log_mod);
    tests.root_module.addImport("Buffer", Buffer_mod);
    tests.root_module.addImport("color", color_mod);
    // b.installArtifact(tests);

    const test_run_cmd = b.addRunArtifact(tests);

    opt.test_step.dependOn(&test_run_cmd.step);
    opt.test_step.dependOn(&keybind_test_run_cmd.step);

    const lints = b.addFmt(.{
        .paths = &.{ "src", "test", "build.zig" },
        .check = true,
    });

    opt.lint_step.dependOn(&lints.step);
    b.default_step.dependOn(opt.lint_step);
}

fn gen_version_info(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    writer: anytype,
    optimize: std.builtin.OptimizeMode,
) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .Ignore);
    const date_ = try b.runAllowFail(&[_][]const u8{ "git", "show", "-s", "--format=%ci", "HEAD" }, &code, .Ignore);
    const branch_ = try b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, &code, .Ignore);
    const branch = std.mem.trimRight(u8, branch_, "\r\n ");
    const tracking_branch_ = blk: {
        var buf = std.ArrayList(u8).init(b.allocator);
        defer buf.deinit();
        try buf.appendSlice(branch);
        try buf.appendSlice("@{upstream}");
        break :blk (b.runAllowFail(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", buf.items }, &code, .Ignore) catch "");
    };
    const tracking_remote_name = if (std.mem.indexOfScalar(u8, tracking_branch_, '/')) |pos| tracking_branch_[0..pos] else "";
    const tracking_remote_ = if (tracking_remote_name.len > 0) blk: {
        var remote_config_path = std.ArrayList(u8).init(b.allocator);
        defer remote_config_path.deinit();
        try remote_config_path.writer().print("remote.{s}.url", .{tracking_remote_name});
        break :blk b.runAllowFail(&[_][]const u8{ "git", "config", remote_config_path.items }, &code, .Ignore) catch "(remote not found)";
    } else "";
    const remote_ = b.runAllowFail(&[_][]const u8{ "git", "config", "remote.origin.url" }, &code, .Ignore) catch "(origin not found)";
    const log_ = b.runAllowFail(&[_][]const u8{ "git", "log", "--pretty=oneline", "@{u}..." }, &code, .Ignore) catch "";
    const diff_ = b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .Ignore) catch "(git diff failed)";
    const version = std.mem.trimRight(u8, describe, "\r\n ");
    const date = std.mem.trimRight(u8, date_, "\r\n ");
    const tracking_branch = std.mem.trimRight(u8, tracking_branch_, "\r\n ");
    const tracking_remote = std.mem.trimRight(u8, tracking_remote_, "\r\n ");
    const remote = std.mem.trimRight(u8, remote_, "\r\n ");
    const log = std.mem.trimRight(u8, log_, "\r\n ");
    const diff = std.mem.trimRight(u8, diff_, "\r\n ");
    const target_triple = try target.result.zigTriple(b.allocator);

    try writer.print("Flow Control: a programmer's text editor\n\nversion: {s}{s}\ncommitted: {s}\ntarget: {s}\n", .{
        version,
        if (diff.len > 0) "-dirty" else "",
        date,
        target_triple,
    });

    if (branch.len > 0) if (tracking_branch.len > 0)
        try writer.print("branch: {s} tracking {s} at {s}\n", .{ branch, tracking_branch, tracking_remote })
    else
        try writer.print("branch: {s} at {s}\n", .{ branch, remote });

    try writer.print("built with: zig {s} ({s})\n", .{ builtin.zig_version_string, @tagName(builtin.zig_backend) });
    try writer.print("build mode: {s}\n", .{@tagName(optimize)});

    if (log.len > 0)
        try writer.print("\nwith the following diverging commits:\n{s}\n", .{log});

    if (diff.len > 0)
        try writer.print("\nwith the following uncommited changes:\n\n{s}\n", .{diff});
}

fn gen_version(b: *std.Build, writer: anytype) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .Ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .Ignore);
    const diff = std.mem.trimRight(u8, diff_, "\r\n ");
    const version = std.mem.trimRight(u8, describe, "\r\n ");

    try writer.print("{s}{s}", .{ version, if (diff.len > 0) "-dirty" else "" });
}
