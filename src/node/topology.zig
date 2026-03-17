const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PeerSource = enum {
    legacy_producer,
    bootstrap_peer,
    local_root,
    public_root,
};

pub const Peer = struct {
    host: []u8,
    port: u16,
    source: PeerSource,

    fn deinit(self: *Peer, allocator: Allocator) void {
        allocator.free(self.host);
    }
};

pub const Topology = struct {
    peers: []Peer,

    pub fn deinit(self: *Topology, allocator: Allocator) void {
        for (self.peers) |*peer| peer.deinit(allocator);
        allocator.free(self.peers);
    }
};

const LegacyProducer = struct {
    addr: []const u8,
    port: u16,
};

const AccessPoint = struct {
    address: []const u8,
    port: u16,
};

const BootstrapPeer = struct {
    address: []const u8,
    port: u16,
};

const LocalRoot = struct {
    accessPoints: []const AccessPoint = &.{},
};

const PublicRoot = struct {
    accessPoints: []const AccessPoint = &.{},
};

const TopologyJson = struct {
    Producers: []const LegacyProducer = &.{},
    bootstrapPeers: []const BootstrapPeer = &.{},
    localRoots: []const LocalRoot = &.{},
    publicRoots: []const PublicRoot = &.{},
};

pub fn parseTopology(allocator: Allocator, path: []const u8) !Topology {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(TopologyJson, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var peers: std.ArrayList(Peer) = .empty;
    defer peers.deinit(allocator);

    for (parsed.value.Producers) |producer| {
        try appendPeer(allocator, &peers, producer.addr, producer.port, .legacy_producer);
    }
    for (parsed.value.bootstrapPeers) |producer| {
        try appendPeer(allocator, &peers, producer.address, producer.port, .bootstrap_peer);
    }
    for (parsed.value.localRoots) |root| {
        for (root.accessPoints) |producer| {
            try appendPeer(allocator, &peers, producer.address, producer.port, .local_root);
        }
    }
    for (parsed.value.publicRoots) |root| {
        for (root.accessPoints) |producer| {
            try appendPeer(allocator, &peers, producer.address, producer.port, .public_root);
        }
    }

    if (peers.items.len == 0) return error.NoPeersConfigured;

    return .{
        .peers = try peers.toOwnedSlice(allocator),
    };
}

pub fn firstPeer(topology: Topology) Peer {
    return topology.peers[0];
}

fn appendPeer(
    allocator: Allocator,
    peers: *std.ArrayList(Peer),
    host: []const u8,
    port: u16,
    source: PeerSource,
) !void {
    if (host.len == 0) return;

    for (peers.items) |peer| {
        if (peer.port == port and std.mem.eql(u8, peer.host, host)) return;
    }

    try peers.append(allocator, .{
        .host = try allocator.dupe(u8, host),
        .port = port,
        .source = source,
    });
}

test "topology: parse legacy Producers file" {
    const allocator = std.testing.allocator;

    var topology = parseTopology(
        allocator,
        "reference-node/scripts/lite/configuration/topology-node-1.json",
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer topology.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), topology.peers.len);
    try std.testing.expectEqual(PeerSource.legacy_producer, topology.peers[0].source);
    try std.testing.expectEqualStrings("127.0.0.1", topology.peers[0].host);
    try std.testing.expectEqual(@as(u16, 3002), topology.peers[0].port);
}

test "topology: parse modern bootstrap peers file" {
    const allocator = std.testing.allocator;

    var topology = parseTopology(
        allocator,
        "reference-node/configuration/cardano/mainnet-topology.json",
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer topology.deinit(allocator);

    try std.testing.expect(topology.peers.len >= 3);
    try std.testing.expectEqual(PeerSource.bootstrap_peer, topology.peers[0].source);
    try std.testing.expectEqualStrings("backbone.cardano.iog.io", topology.peers[0].host);
    try std.testing.expectEqual(@as(u16, 3001), topology.peers[0].port);
}
