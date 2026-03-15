const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const block_mod = @import("../ledger/block.zig");
const tx_mod = @import("../ledger/transaction.zig");
const chainsync = @import("../network/chainsync.zig");
const peer_mod = @import("../network/peer.zig");
const protocol = @import("../network/protocol.zig");
const chunk_reader_mod = @import("chunk_reader.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Result of a bootstrap sync operation.
pub const BootstrapSyncResult = struct {
    snapshot_tip_slot: u64,
    snapshot_tip_block: u64,
    headers_synced_forward: u64,
    network_tip_slot: u64,
    network_tip_block: u64,
    blocks_parsed: u64,
    txs_parsed: u64,
    rollbacks: u64,
};

/// Run a full bootstrap sync:
/// 1. Read the snapshot tip from the ImmutableDB
/// 2. Connect to a peer
/// 3. FindIntersect at the snapshot tip
/// 4. Sync forward, parsing each block
pub fn bootstrapSync(
    allocator: Allocator,
    immutable_path: []const u8,
    peer_host: []const u8,
    peer_port: u16,
    network_magic: u32,
    max_blocks: u64,
) !BootstrapSyncResult {
    var result = std.mem.zeroes(BootstrapSyncResult);

    // Step 1: Read the snapshot tip
    std.debug.print("Reading snapshot tip from {s}...\n", .{immutable_path});
    var reader = chunk_reader_mod.ChunkReader.init(immutable_path) catch {
        std.debug.print("No snapshot found. Use 'kassadin bootstrap --download' first.\n", .{});
        return error.NoSnapshot;
    };

    const tip_result = try reader.readTip(allocator) orelse {
        std.debug.print("Empty snapshot.\n", .{});
        return error.EmptySnapshot;
    };
    defer allocator.free(tip_result.raw);

    const tip_block = tip_result.block;
    result.snapshot_tip_slot = tip_block.header.slot;
    result.snapshot_tip_block = tip_block.header.block_no;

    // Compute the block hash for FindIntersect
    // Cardano block hash = Blake2b-256 of the FULL header CBOR [header_body, kes_sig]
    // This matches Haskell's headerHash = extractHash . hashAnnotated
    const block_hash = tip_block.hash();

    std.debug.print("Snapshot tip: block={}, slot={}\n", .{
        result.snapshot_tip_block,
        result.snapshot_tip_slot,
    });

    // Step 2: Connect to peer
    std.debug.print("Connecting to {s}:{}...\n", .{ peer_host, peer_port });
    var peer = peer_mod.Peer.connect(allocator, peer_host, peer_port, network_magic) catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return err;
    };
    defer peer.close();
    std.debug.print("Connected (v{})\n", .{peer.negotiated_version.?});

    // Step 3: FindIntersect at snapshot tip
    const intersect_point = chainsync.Point{
        .slot = tip_block.header.slot,
        .hash = block_hash,
    };

    std.debug.print("FindIntersect at slot {}...\n", .{intersect_point.slot});
    const intersect_msg = try peer.chainSyncFindIntersect(&[_]chainsync.Point{intersect_point});

    switch (intersect_msg) {
        .intersect_found => |isf| {
            result.network_tip_slot = isf.tip.slot;
            result.network_tip_block = isf.tip.block_no;
            std.debug.print("Intersect found! Network tip: slot={}, block={}\n", .{
                result.network_tip_slot,
                result.network_tip_block,
            });

            const gap = result.network_tip_block - result.snapshot_tip_block;
            std.debug.print("Gap to sync: ~{} blocks\n", .{gap});
        },
        .intersect_not_found => |inf| {
            result.network_tip_slot = inf.tip.slot;
            result.network_tip_block = inf.tip.block_no;
            std.debug.print("Intersect NOT found — snapshot may be too old or wrong network\n", .{});
            return error.IntersectNotFound;
        },
        else => return error.UnexpectedMessage,
    }

    // Step 4: Sync forward, parsing each block
    std.debug.print("Syncing forward (max {} blocks)...\n", .{max_blocks});
    var synced: u64 = 0;

    while (synced < max_blocks) {
        const msg = peer.chainSyncRequestNext() catch |err| {
            std.debug.print("Sync error: {}\n", .{err});
            break;
        };

        switch (msg) {
            .roll_forward => |rf| {
                synced += 1;
                result.headers_synced_forward = synced;
                result.network_tip_slot = rf.tip.slot;
                result.network_tip_block = rf.tip.block_no;

                // N2N chain-sync sends headers, not full blocks
                // But we can still count and report progress
                if (synced <= 5 or synced % 100 == 0) {
                    std.debug.print("  Block {}: tip_slot={}, tip_block={}\n", .{
                        synced, rf.tip.slot, rf.tip.block_no,
                    });
                }
            },
            .await_reply => {
                std.debug.print("At tip! Synced {} blocks forward.\n", .{synced});
                break;
            },
            .roll_backward => {
                result.rollbacks += 1;
                std.debug.print("  Rollback\n", .{});
            },
            else => break,
        }
    }

    return result;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "bootstrap_sync: read snapshot tip" {
    const allocator = std.testing.allocator;

    var reader = chunk_reader_mod.ChunkReader.init("db/preprod/immutable") catch return;
    const tip_result = try reader.readTip(allocator) orelse return;
    defer allocator.free(tip_result.raw);

    try std.testing.expect(tip_result.block.header.slot > 100_000_000);
    try std.testing.expect(tip_result.block.header.block_no > 4_000_000);
    try std.testing.expectEqual(block_mod.Era.conway, tip_result.block.era);
}
