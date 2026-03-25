const std = @import("std");
const home = @import("home.zig");
const network = @import("network.zig");

pub const state_version: u32 = 1;
pub const default_profile_id = "default";

pub const RelayMode = enum {
    official_only,
    official_plus_custom,
    custom_only,
};

pub const BootstrapStrategy = enum {
    mithril,
    genesis_only,
};

pub const ServiceBackend = enum {
    none,
    systemd_user,
    launchagent,
};

pub const CustomRelay = struct {
    host: []const u8,
    port: u16,
};

pub const ManagedProfile = struct {
    id: []const u8,
    network: network.NetworkId,
    availability: network.Availability,
    db_path: []const u8,
    socket_path: []const u8,
    network_bundle_dir: []const u8,
    config_path: []const u8,
    topology_path: []const u8,
    relay_mode: RelayMode,
    custom_relays: []CustomRelay,
    bootstrap_strategy: BootstrapStrategy,
    bootstrap_completed: bool,
    service_backend: ServiceBackend,
    service_installed: bool,
};

pub const ManagedState = struct {
    version: u32,
    default_profile: []const u8,
    profiles: []ManagedProfile,
};

pub const LoadedState = struct {
    parsed: std.json.Parsed(ManagedState),

    pub fn deinit(self: *LoadedState) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const LoadedState) *const ManagedState {
        return &self.parsed.value;
    }

    pub fn defaultProfile(self: *const LoadedState) ?*const ManagedProfile {
        for (self.parsed.value.profiles) |*profile| {
            if (std.mem.eql(u8, profile.id, self.parsed.value.default_profile)) return profile;
        }
        return null;
    }
};

pub const InitOptions = struct {
    network: network.NetworkId = .preprod,
    relay_mode: RelayMode = .official_only,
    custom_relays: []CustomRelay = &.{},
    bootstrap_strategy: BootstrapStrategy = .mithril,
    db_path: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    service_backend: ServiceBackend = .none,
    service_installed: bool = false,
};

pub fn load(allocator: std.mem.Allocator, layout: *const home.Layout) !?LoadedState {
    const content = std.fs.cwd().readFileAlloc(allocator, layout.state_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    return .{
        .parsed = try std.json.parseFromSlice(ManagedState, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }),
    };
}

pub fn createDefault(allocator: std.mem.Allocator, layout: *const home.Layout, options: InitOptions) !ManagedState {
    const network_dir = try home.defaultNetworkDir(allocator, layout, default_profile_id);
    errdefer allocator.free(network_dir);
    const config_path = try std.fs.path.join(allocator, &.{ network_dir, "config.json" });
    errdefer allocator.free(config_path);
    const topology_path = try std.fs.path.join(allocator, &.{ network_dir, "topology.json" });
    errdefer allocator.free(topology_path);
    const db_path = if (options.db_path) |path|
        try allocator.dupe(u8, path)
    else
        try home.defaultDbPath(allocator, layout, default_profile_id);
    errdefer allocator.free(db_path);
    const socket_path = if (options.socket_path) |path|
        try allocator.dupe(u8, path)
    else
        try home.defaultSocketPath(allocator, layout, default_profile_id);
    errdefer allocator.free(socket_path);
    const default_profile = try allocator.dupe(u8, default_profile_id);
    errdefer allocator.free(default_profile);
    const profiles = try allocator.alloc(ManagedProfile, 1);
    errdefer allocator.free(profiles);
    profiles[0] = .{
        .id = try allocator.dupe(u8, default_profile_id),
        .network = options.network,
        .availability = network.get(options.network).availability,
        .db_path = db_path,
        .socket_path = socket_path,
        .network_bundle_dir = network_dir,
        .config_path = config_path,
        .topology_path = topology_path,
        .relay_mode = options.relay_mode,
        .custom_relays = try cloneCustomRelays(allocator, options.custom_relays),
        .bootstrap_strategy = options.bootstrap_strategy,
        .bootstrap_completed = false,
        .service_backend = options.service_backend,
        .service_installed = options.service_installed,
    };

    return .{
        .version = state_version,
        .default_profile = default_profile,
        .profiles = profiles,
    };
}

pub fn clone(allocator: std.mem.Allocator, src: *const ManagedState) !ManagedState {
    const profiles = try allocator.alloc(ManagedProfile, src.profiles.len);
    errdefer allocator.free(profiles);
    for (src.profiles, 0..) |*profile, idx| {
        profiles[idx] = try cloneProfile(allocator, profile);
    }
    return .{
        .version = src.version,
        .default_profile = try allocator.dupe(u8, src.default_profile),
        .profiles = profiles,
    };
}

pub fn deinitOwned(allocator: std.mem.Allocator, state: *ManagedState) void {
    allocator.free(state.default_profile);
    for (state.profiles) |*profile| deinitProfile(allocator, profile);
    allocator.free(state.profiles);
}

pub fn save(layout: *const home.Layout, state: *const ManagedState) !void {
    try home.ensureBaseDirs(layout);
    {
        var state_file = try std.fs.cwd().createFile(layout.state_path, .{ .truncate = true });
        defer state_file.close();
        var buf: [4096]u8 = undefined;
        var writer = state_file.writer(&buf);
        try std.json.Stringify.value(state.*, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.flush();
    }

    for (state.profiles) |profile| {
        const profile_root = try home.profileRootPath(std.heap.page_allocator, layout, profile.id);
        defer std.heap.page_allocator.free(profile_root);
        try std.fs.cwd().makePath(profile_root);

        const profile_path = try home.profileFilePath(std.heap.page_allocator, layout, profile.id);
        defer std.heap.page_allocator.free(profile_path);
        var profile_file = try std.fs.cwd().createFile(profile_path, .{ .truncate = true });
        defer profile_file.close();
        var buf: [4096]u8 = undefined;
        var writer = profile_file.writer(&buf);
        try std.json.Stringify.value(profile, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.flush();
    }
}

pub fn parseRelaySpec(allocator: std.mem.Allocator, raw: []const u8) !CustomRelay {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return error.InvalidRelaySpec;
    const host = std.mem.trim(u8, trimmed[0..colon], " \t\r\n");
    if (host.len == 0) return error.InvalidRelaySpec;
    const port = try std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10);
    return .{
        .host = try allocator.dupe(u8, host),
        .port = port,
    };
}

pub fn parseRelayList(allocator: std.mem.Allocator, raw: []const u8) ![]CustomRelay {
    var list: std.ArrayList(CustomRelay) = .empty;
    defer list.deinit(allocator);

    var iter = std.mem.tokenizeScalar(u8, raw, ',');
    while (iter.next()) |entry| {
        try list.append(allocator, try parseRelaySpec(allocator, entry));
    }

    return list.toOwnedSlice(allocator);
}

pub fn deinitRelayList(allocator: std.mem.Allocator, relays: []CustomRelay) void {
    for (relays) |relay| allocator.free(relay.host);
    allocator.free(relays);
}

fn cloneCustomRelays(allocator: std.mem.Allocator, relays: []const CustomRelay) ![]CustomRelay {
    const out = try allocator.alloc(CustomRelay, relays.len);
    errdefer allocator.free(out);
    for (relays, 0..) |relay, idx| {
        out[idx] = .{
            .host = try allocator.dupe(u8, relay.host),
            .port = relay.port,
        };
    }
    return out;
}

fn cloneProfile(allocator: std.mem.Allocator, src: *const ManagedProfile) !ManagedProfile {
    return .{
        .id = try allocator.dupe(u8, src.id),
        .network = src.network,
        .availability = src.availability,
        .db_path = try allocator.dupe(u8, src.db_path),
        .socket_path = try allocator.dupe(u8, src.socket_path),
        .network_bundle_dir = try allocator.dupe(u8, src.network_bundle_dir),
        .config_path = try allocator.dupe(u8, src.config_path),
        .topology_path = try allocator.dupe(u8, src.topology_path),
        .relay_mode = src.relay_mode,
        .custom_relays = try cloneCustomRelays(allocator, src.custom_relays),
        .bootstrap_strategy = src.bootstrap_strategy,
        .bootstrap_completed = src.bootstrap_completed,
        .service_backend = src.service_backend,
        .service_installed = src.service_installed,
    };
}

fn deinitProfile(allocator: std.mem.Allocator, profile: *ManagedProfile) void {
    allocator.free(profile.id);
    allocator.free(profile.db_path);
    allocator.free(profile.socket_path);
    allocator.free(profile.network_bundle_dir);
    allocator.free(profile.config_path);
    allocator.free(profile.topology_path);
    deinitRelayList(allocator, profile.custom_relays);
}
