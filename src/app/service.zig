const builtin = @import("builtin");
const std = @import("std");
const home = @import("home.zig");
const state_mod = @import("state.zig");

pub const Status = enum {
    not_installed,
    stopped,
    running,
    unknown,
};

pub fn detectDefaultBackend() state_mod.ServiceBackend {
    return switch (builtin.os.tag) {
        .linux => .systemd_user,
        .macos => .launchagent,
        else => .none,
    };
}

pub fn install(allocator: std.mem.Allocator, layout: *const home.Layout, profile: *const state_mod.ManagedProfile) !state_mod.ServiceBackend {
    const backend = if (profile.service_backend == .none) detectDefaultBackend() else profile.service_backend;
    if (backend == .none) return .none;

    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const log_path = try home.defaultLogPath(allocator, layout);
    defer allocator.free(log_path);
    const profile_root = try home.profileRootPath(allocator, layout, profile.id);
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(layout.service_dir);

    switch (backend) {
        .systemd_user => {
            const unit_path = try home.systemdUnitPath(allocator);
            defer allocator.free(unit_path);
            const managed_copy = try std.fs.path.join(allocator, &.{ layout.service_dir, "kassadin.service" });
            defer allocator.free(managed_copy);
            try writeTextFile(allocator, managed_copy, try renderSystemdUnit(allocator, exe, profile.id, profile_root, log_path));
            try writeTextFile(allocator, unit_path, try renderSystemdUnit(allocator, exe, profile.id, profile_root, log_path));
            try runChecked(allocator, &.{ "systemctl", "--user", "daemon-reload" });
        },
        .launchagent => {
            const plist_path = try home.launchAgentPath(allocator);
            defer allocator.free(plist_path);
            const managed_copy = try std.fs.path.join(allocator, &.{ layout.service_dir, "io.kassadin.daemon.plist" });
            defer allocator.free(managed_copy);
            try writeTextFile(allocator, managed_copy, try renderLaunchAgent(allocator, exe, profile.id, profile_root, log_path));
            try writeTextFile(allocator, plist_path, try renderLaunchAgent(allocator, exe, profile.id, profile_root, log_path));
        },
        .none => {},
    }

    return backend;
}

pub fn uninstall(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend) !void {
    switch (backend) {
        .systemd_user => {
            _ = runIgnoreFailure(allocator, &.{ "systemctl", "--user", "disable", "--now", "kassadin.service" });
            _ = runIgnoreFailure(allocator, &.{ "systemctl", "--user", "daemon-reload" });
            const unit_path = try home.systemdUnitPath(allocator);
            defer allocator.free(unit_path);
            std.fs.cwd().deleteFile(unit_path) catch {};
        },
        .launchagent => {
            const uid = std.posix.getuid();
            const plist_path = try home.launchAgentPath(allocator);
            defer allocator.free(plist_path);
            const target = try std.fmt.allocPrint(allocator, "gui/{d}/io.kassadin.daemon", .{uid});
            defer allocator.free(target);
            _ = runIgnoreFailure(allocator, &.{ "launchctl", "bootout", target, plist_path });
            std.fs.cwd().deleteFile(plist_path) catch {};
        },
        .none => {},
    }
}

pub fn start(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend) !void {
    switch (backend) {
        .systemd_user => try runChecked(allocator, &.{ "systemctl", "--user", "enable", "--now", "kassadin.service" }),
        .launchagent => {
            const uid = std.posix.getuid();
            const plist_path = try home.launchAgentPath(allocator);
            defer allocator.free(plist_path);
            const target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
            defer allocator.free(target);
            _ = runIgnoreFailure(allocator, &.{ "launchctl", "bootout", target, plist_path });
            try runChecked(allocator, &.{ "launchctl", "bootstrap", target, plist_path });
        },
        .none => return error.UnsupportedPlatform,
    }
}

pub fn stop(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend) !void {
    switch (backend) {
        .systemd_user => try runChecked(allocator, &.{ "systemctl", "--user", "stop", "kassadin.service" }),
        .launchagent => {
            const uid = std.posix.getuid();
            const plist_path = try home.launchAgentPath(allocator);
            defer allocator.free(plist_path);
            const target = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
            defer allocator.free(target);
            try runChecked(allocator, &.{ "launchctl", "bootout", target, plist_path });
        },
        .none => return error.UnsupportedPlatform,
    }
}

pub fn restart(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend) !void {
    switch (backend) {
        .systemd_user => try runChecked(allocator, &.{ "systemctl", "--user", "restart", "kassadin.service" }),
        .launchagent => {
            try stop(allocator, backend);
            try start(allocator, backend);
        },
        .none => return error.UnsupportedPlatform,
    }
}

pub fn status(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend, installed: bool) !Status {
    if (!installed or backend == .none) return .not_installed;
    return switch (backend) {
        .systemd_user => blk: {
            const result = try runAllowFailure(allocator, &.{ "systemctl", "--user", "is-active", "kassadin.service" });
            defer freeRunResult(allocator, result);
            if (result.exit_code == 0 and std.mem.indexOf(u8, result.stdout, "active") != null) break :blk .running;
            if (result.exit_code == 3 or std.mem.indexOf(u8, result.stdout, "inactive") != null) break :blk .stopped;
            break :blk .unknown;
        },
        .launchagent => blk: {
            const uid = std.posix.getuid();
            const target = try std.fmt.allocPrint(allocator, "gui/{d}/io.kassadin.daemon", .{uid});
            defer allocator.free(target);
            const result = try runAllowFailure(allocator, &.{ "launchctl", "print", target });
            defer freeRunResult(allocator, result);
            if (result.exit_code == 0) break :blk .running;
            break :blk .stopped;
        },
        .none => .not_installed,
    };
}

pub fn streamLogs(allocator: std.mem.Allocator, backend: state_mod.ServiceBackend, log_path: []const u8) !void {
    const argv: []const []const u8 = if (fileExists(log_path))
        &.{ "tail", "-n", "100", "-f", log_path }
    else switch (backend) {
        .systemd_user => &.{ "journalctl", "--user", "-u", "kassadin.service", "-n", "100", "-f" },
        else => return error.FileNotFound,
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

fn renderSystemdUnit(allocator: std.mem.Allocator, exe: []const u8, profile_id: []const u8, workdir: []const u8, log_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description=Kassadin managed daemon
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} daemon run --profile {s}
        \\WorkingDirectory={s}
        \\Restart=always
        \\RestartSec=5
        \\StandardOutput=append:{s}
        \\StandardError=append:{s}
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ exe, profile_id, workdir, log_path, log_path });
}

fn renderLaunchAgent(allocator: std.mem.Allocator, exe: []const u8, profile_id: []const u8, workdir: []const u8, log_path: []const u8) ![]u8 {
    const exe_xml = try xmlEscape(allocator, exe);
    defer allocator.free(exe_xml);
    const profile_xml = try xmlEscape(allocator, profile_id);
    defer allocator.free(profile_xml);
    const workdir_xml = try xmlEscape(allocator, workdir);
    defer allocator.free(workdir_xml);
    const log_xml = try xmlEscape(allocator, log_path);
    defer allocator.free(log_xml);

    return std.fmt.allocPrint(
        allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>io.kassadin.daemon</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>daemon</string>
        \\    <string>run</string>
        \\    <string>--profile</string>
        \\    <string>{s}</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\  <key>WorkingDirectory</key>
        \\  <string>{s}</string>
        \\  <key>StandardOutPath</key>
        \\  <string>{s}</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ exe_xml, profile_xml, workdir_xml, log_xml, log_xml });
}

fn xmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (input) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeTextFile(allocator: std.mem.Allocator, path: []const u8, content: []u8) !void {
    defer allocator.free(content);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

const RunResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
};

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 64 * 1024,
    });
    return .{
        .exit_code = switch (result.term) {
            .Exited => |code| @intCast(code),
            else => -1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runAllowFailure(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return run(allocator, argv);
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runAllowFailure(allocator, argv);
    defer freeRunResult(allocator, result);
    if (result.exit_code == 0) return;

    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
    } else if (result.stdout.len > 0) {
        std.debug.print("{s}", .{result.stdout});
    }
    return error.CommandFailed;
}

fn runIgnoreFailure(allocator: std.mem.Allocator, argv: []const []const u8) RunResult {
    return runAllowFailure(allocator, argv) catch .{
        .exit_code = -1,
        .stdout = allocator.dupe(u8, "") catch unreachable,
        .stderr = allocator.dupe(u8, "") catch unreachable,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
