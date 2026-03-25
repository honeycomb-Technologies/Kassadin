const std = @import("std");
const bundle = @import("bundle.zig");
const network = @import("network.zig");
const state_mod = @import("state.zig");
const mithril = @import("../node/mithril.zig");
const snapshot_restore = @import("../node/snapshot_restore.zig");
const node_config = @import("../node/config.zig");
const topology_mod = @import("../node/topology.zig");
const bootstrap_sync = @import("../node/bootstrap_sync.zig");
const runner = @import("../node/runner.zig");
const runtime_control = @import("../node/runtime_control.zig");

pub const TipSummary = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
};

pub fn ensureBootstrap(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile) !bool {
    try bundle.ensureProfileBundle(allocator, profile);
    if (profile.bootstrap_strategy != .mithril) return false;

    const info = network.get(profile.network);
    if (info.mithril_aggregator_url == null) return false;

    const snapshot_state = try snapshot_restore.scanSnapshotDir(allocator, profile.db_path);
    if (snapshot_state.immutable_file_count > 0) return true;

    std.debug.print("Fetching latest {s} Mithril snapshot info...\n", .{info.display_name});
    const snapshot = try mithril.fetchLatestSnapshot(allocator, info.mithril_aggregator_url.?);
    defer snapshot.deinit(allocator);
    try mithril.downloadAndExtract(allocator, snapshot, profile.db_path);
    return true;
}

pub fn runProfile(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile) !void {
    try bundle.ensureProfileBundle(allocator, profile);

    const net = network.get(profile.network);
    if (net.availability != .active) return error.NetworkComingSoon;

    runtime_control.resetStopRequested();
    runtime_control.installSignalHandlers();

    const snapshot_state = try snapshot_restore.scanSnapshotDir(allocator, profile.db_path);
    if (profile.bootstrap_completed and snapshot_state.immutable_file_count > 0) {
        try runBootstrapSync(allocator, profile, net);
    } else {
        try runSync(allocator, profile, net);
    }
}

pub fn lastKnownTip(allocator: std.mem.Allocator, db_path: []const u8) !?TipSummary {
    const candidates = [_][]const u8{
        "ledger.tip.resume.anchor",
        "ledger.resume.anchor",
    };

    for (candidates) |filename| {
        const path = try std.fs.path.join(allocator, &.{ db_path, filename });
        defer allocator.free(path);
        const data = std.fs.cwd().readFileAlloc(allocator, path, 52) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(data);
        if (data.len != 52) continue;
        return .{
            .slot = std.mem.readInt(u64, data[4..12], .big),
            .hash = data[12..44].*,
            .block_no = std.mem.readInt(u64, data[44..52], .big),
        };
    }

    return null;
}

const OwnedPeers = struct {
    peers: []topology_mod.Peer,

    pub fn deinit(self: *OwnedPeers, allocator: std.mem.Allocator) void {
        for (self.peers) |*peer| allocator.free(peer.host);
        allocator.free(self.peers);
    }
};

fn runBootstrapSync(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile, net: *const network.NetworkInfo) !void {
    var peers = try resolvePeers(allocator, profile);
    defer peers.deinit(allocator);
    const primary = try choosePrimaryPeer(profile, net, peers.peers);

    var parsed = try node_config.parseCardanoNodeConfig(allocator, profile.config_path);
    defer parsed.deinit(allocator);

    const result = try bootstrap_sync.bootstrapSync(
        allocator,
        profile.db_path,
        primary.host,
        primary.port,
        if (peers.peers.len > 0) peers.peers else null,
        net.network_magic,
        0,
        parsed.shelley_genesis_path,
        null,
    );

    std.debug.print("Kassadin — Managed Bootstrap Sync\n\n", .{});
    std.debug.print("Snapshot tip: block={}, slot={}\n", .{ result.snapshot_tip_block, result.snapshot_tip_slot });
    std.debug.print("Headers synced forward: {}\n", .{result.headers_synced_forward});
    std.debug.print("Blocks added to chain: {}\n", .{result.blocks_added_to_chain});
    std.debug.print("Invalid blocks: {}\n", .{result.invalid_blocks});
    std.debug.print("Stopped by signal: {}\n", .{result.stopped_by_signal});
}

fn runSync(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile, net: *const network.NetworkInfo) !void {
    var peers = try resolvePeers(allocator, profile);
    defer peers.deinit(allocator);
    const primary = try choosePrimaryPeer(profile, net, peers.peers);

    var config = switch (profile.network) {
        .preview => runner.RunConfig.preview_defaults,
        .preprod => runner.RunConfig.preprod_defaults,
        .mainnet => return error.NetworkComingSoon,
    };
    config.db_path = profile.db_path;
    config.peer_host = primary.host;
    config.peer_port = primary.port;
    config.peer_endpoints = if (peers.peers.len > 0) peers.peers else null;
    config.socket_path = profile.socket_path;

    var parsed = try node_config.parseCardanoNodeConfig(allocator, profile.config_path);
    defer parsed.deinit(allocator);
    if (parsed.byron_genesis_path) |path| {
        config.byron_genesis_path = try allocator.dupe(u8, path);
    }
    if (parsed.shelley_genesis_path) |path| {
        config.shelley_genesis_path = try allocator.dupe(u8, path);
    }
    config.hard_fork_epoch = parsed.shelley_hard_fork_epoch;

    const result = try runner.run(allocator, config);
    std.debug.print("Kassadin — Managed Sync\n\n", .{});
    std.debug.print("Headers synced: {}\n", .{result.headers_synced});
    std.debug.print("Blocks fetched: {}\n", .{result.blocks_fetched});
    std.debug.print("Blocks added: {}\n", .{result.blocks_added_to_chain});
    std.debug.print("Invalid blocks: {}\n", .{result.invalid_blocks});
    std.debug.print("Tip block: {}\n", .{result.tip_block_no});
    std.debug.print("Tip slot: {}\n", .{result.tip_slot});
    std.debug.print("Stopped by signal: {}\n", .{result.stopped_by_signal});
}

fn resolvePeers(allocator: std.mem.Allocator, profile: *const state_mod.ManagedProfile) !OwnedPeers {
    var out: std.ArrayList(topology_mod.Peer) = .empty;
    defer out.deinit(allocator);

    if (profile.relay_mode != .custom_only) {
        var parsed = try topology_mod.parseTopology(allocator, profile.topology_path);
        defer parsed.deinit(allocator);
        for (parsed.peers) |peer| {
            try appendPeer(allocator, &out, peer.host, peer.port, peer.source);
        }
    }

    if (profile.relay_mode != .official_only) {
        for (profile.custom_relays) |relay| {
            try appendPeer(allocator, &out, relay.host, relay.port, .local_root);
        }
    }

    return .{ .peers = try out.toOwnedSlice(allocator) };
}

fn appendPeer(allocator: std.mem.Allocator, peers: *std.ArrayList(topology_mod.Peer), host: []const u8, port: u16, source: topology_mod.PeerSource) !void {
    for (peers.items) |peer| {
        if (peer.port == port and std.mem.eql(u8, peer.host, host)) return;
    }
    try peers.append(allocator, .{
        .host = try allocator.dupe(u8, host),
        .port = port,
        .source = source,
    });
}

const PrimaryPeer = struct {
    host: []const u8,
    port: u16,
};

fn choosePrimaryPeer(profile: *const state_mod.ManagedProfile, net: *const network.NetworkInfo, peers: []const topology_mod.Peer) !PrimaryPeer {
    if (peers.len > 0) {
        return .{
            .host = peers[0].host,
            .port = peers[0].port,
        };
    }
    if (profile.relay_mode == .custom_only) return error.NoRelaysConfigured;
    return .{
        .host = net.default_peer_host,
        .port = net.default_peer_port,
    };
}
