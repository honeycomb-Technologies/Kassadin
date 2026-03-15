const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const peer_mod = @import("../network/peer.zig");
const chainsync = @import("../network/chainsync.zig");
const protocol = @import("../network/protocol.zig");
const block_mod = @import("../ledger/block.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;

/// Sync statistics.
pub const SyncStats = struct {
    headers_received: u64,
    blocks_applied: u64,
    rollbacks: u64,
    tip_slot: SlotNo,
    tip_block_no: BlockNo,
    errors: u64,
};

/// Chain sync client that connects to a peer and follows the chain.
pub const SyncClient = struct {
    allocator: Allocator,
    peer: peer_mod.Peer,
    stats: SyncStats,

    pub fn connect(allocator: Allocator, host: []const u8, port: u16, magic: u32) !SyncClient {
        const peer = try peer_mod.Peer.connect(allocator, host, port, magic);
        return .{
            .allocator = allocator,
            .peer = peer,
            .stats = std.mem.zeroes(SyncStats),
        };
    }

    pub fn close(self: *SyncClient) void {
        self.peer.close();
    }

    /// Start chain sync from genesis (empty intersect points).
    pub fn findIntersectGenesis(self: *SyncClient) !chainsync.ChainSyncMsg {
        return self.peer.chainSyncFindIntersect(&[_]chainsync.Point{});
    }

    /// Start chain sync from known points.
    pub fn findIntersect(self: *SyncClient, points: []const chainsync.Point) !chainsync.ChainSyncMsg {
        return self.peer.chainSyncFindIntersect(points);
    }

    /// Request the next header/block and process it.
    /// Returns the chain-sync message received.
    pub fn requestNext(self: *SyncClient) !chainsync.ChainSyncMsg {
        const msg = try self.peer.chainSyncRequestNext();

        switch (msg) {
            .roll_forward => |rf| {
                self.stats.headers_received += 1;
                self.stats.tip_slot = rf.tip.slot;
                self.stats.tip_block_no = rf.tip.block_no;
            },
            .roll_backward => {
                self.stats.rollbacks += 1;
            },
            else => {},
        }

        return msg;
    }

    /// Send keep-alive to maintain connection.
    pub fn keepAlive(self: *SyncClient) !void {
        _ = try self.peer.keepAlivePing(42);
    }

    /// Sync N headers from the current position.
    /// Returns number of headers actually received.
    pub fn syncHeaders(self: *SyncClient, count: u64) !u64 {
        var received: u64 = 0;
        while (received < count) {
            const msg = try self.requestNext();
            switch (msg) {
                .roll_forward => received += 1,
                .await_reply => break, // at tip
                .roll_backward => {},
                else => break,
            }
        }
        return received;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "sync: connect to preview and follow headers" {
    const allocator = std.testing.allocator;

    // This test requires network access — skip in CI
    var client = SyncClient.connect(
        allocator,
        "preview-node.play.dev.cardano.org",
        3001,
        protocol.NetworkMagic.preview,
    ) catch return; // skip if no network
    defer client.close();

    // Find intersect from genesis
    const intersect = try client.findIntersectGenesis();
    switch (intersect) {
        .intersect_not_found => |inf| {
            try std.testing.expect(inf.tip.slot > 0);
        },
        .intersect_found => {},
        else => return error.UnexpectedMessage,
    }

    // Sync 5 headers
    const received = try client.syncHeaders(5);
    try std.testing.expect(received >= 1);
    try std.testing.expect(client.stats.headers_received >= 1);
    try std.testing.expect(client.stats.tip_slot > 0);

    // Keep-alive
    try client.keepAlive();
}
