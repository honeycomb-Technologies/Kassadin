const std = @import("std");
const network = @import("network.zig");
const state_mod = @import("state.zig");
const node_config = @import("../node/config.zig");
const topology = @import("../node/topology.zig");

const bundle_files = [_]struct { remote: []const u8, local: []const u8 }{
    .{ .remote = "config.json", .local = "config.json" },
    .{ .remote = "topology.json", .local = "topology.json" },
    .{ .remote = "byron-genesis.json", .local = "byron-genesis.json" },
    .{ .remote = "shelley-genesis.json", .local = "shelley-genesis.json" },
    .{ .remote = "alonzo-genesis.json", .local = "alonzo-genesis.json" },
    .{ .remote = "conway-genesis.json", .local = "conway-genesis.json" },
};

pub fn ensureProfileBundle(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile) !void {
    const info = network.get(profile.network);
    if (info.availability != .active) return error.NetworkComingSoon;

    try std.fs.cwd().makePath(profile.network_bundle_dir);

    for (bundle_files) |file| {
        const dest = try std.fs.path.join(allocator, &.{ profile.network_bundle_dir, file.local });
        defer allocator.free(dest);
        if (fileExists(dest)) continue;

        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ info.bundle_base_url, file.remote });
        defer allocator.free(url);
        try downloadFile(allocator, url, dest);
    }

    var parsed = try node_config.parseCardanoNodeConfig(allocator, profile.config_path);
    defer parsed.deinit(allocator);

    var parsed_topology = try topology.parseTopology(allocator, profile.topology_path);
    defer parsed_topology.deinit(allocator);
}

pub fn bundlePresent(profile: *const state_mod.ManagedProfile) bool {
    for (bundle_files) |file| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ profile.network_bundle_dir, file.local }) catch return false;
        if (!fileExists(path)) return false;
    }
    return true;
}

fn downloadFile(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", "-o", dest, url },
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.DownloadFailed;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
