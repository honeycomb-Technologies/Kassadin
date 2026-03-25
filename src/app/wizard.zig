const std = @import("std");
const home = @import("home.zig");
const network = @import("network.zig");
const state_mod = @import("state.zig");
const service = @import("service.zig");

pub const Result = struct {
    options: state_mod.InitOptions,
    bootstrap_now: bool,
    start_daemon: bool,
};

pub fn run(allocator: std.mem.Allocator, layout: *const home.Layout) !Result {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    try stdout.interface.print("Kassadin setup\n", .{});
    try stdout.interface.print("This wizard creates ~/.kassadin state, downloads the official preprod bundle, and can install a managed service.\n\n", .{});
    try stdout.interface.flush();

    const selected_network = try promptNetwork(allocator, &stdout);
    const db_path = try promptPath(allocator, "Database path", try home.defaultDbPath(allocator, layout, state_mod.default_profile_id));
    const socket_path = try promptPath(allocator, "Socket path", try home.defaultSocketPath(allocator, layout, state_mod.default_profile_id));
    const relay_mode = try promptRelayMode(allocator, &stdout);
    const custom_relays = switch (relay_mode) {
        .official_only => try allocator.alloc(state_mod.CustomRelay, 0),
        else => try promptCustomRelays(allocator, &stdout),
    };
    const bootstrap_strategy = try promptBootstrapStrategy(allocator, &stdout);
    const default_backend = service.detectDefaultBackend();
    const install_service = try promptYesNo(allocator, &stdout, "Install managed service wrapper?", default_backend != .none);
    const bootstrap_now = try promptYesNo(allocator, &stdout, "Bootstrap now?", true);
    const start_daemon = try promptYesNo(allocator, &stdout, "Start daemon after setup?", false);

    try stdout.interface.print("\nSummary\n", .{});
    try stdout.interface.print("  Network: {s}\n", .{@tagName(selected_network)});
    try stdout.interface.print("  DB path: {s}\n", .{db_path});
    try stdout.interface.print("  Socket path: {s}\n", .{socket_path});
    try stdout.interface.print("  Relay mode: {s}\n", .{@tagName(relay_mode)});
    try stdout.interface.print("  Bootstrap: {s}\n", .{@tagName(bootstrap_strategy)});
    try stdout.interface.print("  Service backend: {s}\n", .{@tagName(if (install_service) default_backend else state_mod.ServiceBackend.none)});
    try stdout.interface.flush();

    if (!try promptYesNo(allocator, &stdout, "Apply this configuration?", true)) return error.Aborted;

    return .{
        .options = .{
            .network = selected_network,
            .relay_mode = relay_mode,
            .custom_relays = custom_relays,
            .bootstrap_strategy = bootstrap_strategy,
            .db_path = db_path,
            .socket_path = socket_path,
            .service_backend = if (install_service) default_backend else .none,
            .service_installed = false,
        },
        .bootstrap_now = bootstrap_now,
        .start_daemon = start_daemon,
    };
}

fn promptNetwork(allocator: std.mem.Allocator, stdout: anytype) !network.NetworkId {
    while (true) {
        try stdout.interface.print("Select network:\n", .{});
        try stdout.interface.print("  1. preprod\n", .{});
        try stdout.interface.print("  2. preview (coming soon)\n", .{});
        try stdout.interface.print("  3. mainnet (coming soon)\n", .{});
        try stdout.interface.flush();
        const choice = try promptLine(allocator, "Choice [1]: ");
        defer allocator.free(choice);
        const trimmed = if (choice.len == 0) "1" else choice;
        if (std.mem.eql(u8, trimmed, "1")) return .preprod;
        if (std.mem.eql(u8, trimmed, "2") or std.mem.eql(u8, trimmed, "3")) {
            try stdout.interface.print("That network is visible in the UI, but preprod is the only active startup path in v1.\n\n", .{});
            continue;
        }
    }
}

fn promptRelayMode(allocator: std.mem.Allocator, stdout: anytype) !state_mod.RelayMode {
    while (true) {
        try stdout.interface.print("\nRelay mode:\n", .{});
        try stdout.interface.print("  1. official-only\n", .{});
        try stdout.interface.print("  2. official-plus-custom\n", .{});
        try stdout.interface.print("  3. custom-only\n", .{});
        try stdout.interface.flush();
        const choice = try promptLine(allocator, "Choice [1]: ");
        defer allocator.free(choice);
        const trimmed = if (choice.len == 0) "1" else choice;
        if (std.mem.eql(u8, trimmed, "1")) return .official_only;
        if (std.mem.eql(u8, trimmed, "2")) return .official_plus_custom;
        if (std.mem.eql(u8, trimmed, "3")) return .custom_only;
    }
}

fn promptBootstrapStrategy(allocator: std.mem.Allocator, stdout: anytype) !state_mod.BootstrapStrategy {
    while (true) {
        try stdout.interface.print("\nBootstrap strategy:\n", .{});
        try stdout.interface.print("  1. mithril\n", .{});
        try stdout.interface.print("  2. genesis-only\n", .{});
        try stdout.interface.flush();
        const choice = try promptLine(allocator, "Choice [1]: ");
        defer allocator.free(choice);
        const trimmed = if (choice.len == 0) "1" else choice;
        if (std.mem.eql(u8, trimmed, "1")) return .mithril;
        if (std.mem.eql(u8, trimmed, "2")) return .genesis_only;
    }
}

fn promptPath(allocator: std.mem.Allocator, label: []const u8, default_path: []u8) ![]const u8 {
    defer allocator.free(default_path);
    const prompt = try std.fmt.allocPrint(allocator, "{s} [{s}]: ", .{ label, default_path });
    defer allocator.free(prompt);
    const value = try promptLine(allocator, prompt);
    if (value.len == 0) {
        allocator.free(value);
        return allocator.dupe(u8, default_path);
    }
    return value;
}

fn promptCustomRelays(allocator: std.mem.Allocator, stdout: anytype) ![]state_mod.CustomRelay {
    try stdout.interface.print("Enter custom relays as comma-separated host:port values. Leave blank for none.\n", .{});
    try stdout.interface.flush();
    const raw = try promptLine(allocator, "Custom relays: ");
    defer allocator.free(raw);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return allocator.alloc(state_mod.CustomRelay, 0);
    return state_mod.parseRelayList(allocator, raw);
}

fn promptYesNo(allocator: std.mem.Allocator, stdout: anytype, label: []const u8, default_yes: bool) !bool {
    const suffix = if (default_yes) " [Y/n]: " else " [y/N]: ";
    const prompt = try std.fmt.allocPrint(allocator, "{s}{s}", .{ label, suffix });
    defer allocator.free(prompt);

    const raw = try promptLine(allocator, prompt);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_yes;
    if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes")) return true;
    if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "N") or std.mem.eql(u8, trimmed, "no")) return false;
    try stdout.interface.print("Please answer yes or no.\n", .{});
    try stdout.interface.flush();
    return promptYesNo(allocator, stdout, label, default_yes);
}

fn promptLine(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.print("{s}", .{prompt});
    try stdout.interface.flush();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var stdin_file = std.fs.File.stdin();
    while (input.items.len < 4096) {
        var byte: [1]u8 = undefined;
        const n = try stdin_file.read(&byte);
        if (n == 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] != '\r') try input.append(allocator, byte[0]);
    }
    return input.toOwnedSlice(allocator);
}
