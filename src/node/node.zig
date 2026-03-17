const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;
const Mempool = @import("../mempool/mempool.zig").Mempool;
const PraosState = @import("../consensus/praos.zig").PraosState;
const praos = @import("../consensus/praos.zig");
const Peer = @import("../network/peer.zig").Peer;
const block_mod = @import("../ledger/block.zig");

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;

/// Node configuration.
pub const NodeConfig = struct {
    network_magic: u32,
    db_path: []const u8,
    security_param: u64,
    mempool_capacity: u32,

    pub const preview_defaults = NodeConfig{
        .network_magic = 2,
        .db_path = "db",
        .security_param = praos.security_param_k,
        .mempool_capacity = 2 * 90112, // 2x max block body size
    };

    pub const mainnet_defaults = NodeConfig{
        .network_magic = 764824073,
        .db_path = "db",
        .security_param = praos.security_param_k,
        .mempool_capacity = 2 * 90112,
    };
};

/// The Kassadin node — orchestrates all subsystems.
pub const Node = struct {
    allocator: Allocator,
    config: NodeConfig,
    chain_db: ChainDB,
    mempool: Mempool,
    praos_state: PraosState,

    pub fn init(allocator: Allocator, config: NodeConfig) !Node {
        return .{
            .allocator = allocator,
            .config = config,
            .chain_db = try ChainDB.open(allocator, config.db_path, config.security_param),
            .mempool = Mempool.init(allocator, config.mempool_capacity),
            .praos_state = PraosState.init(),
        };
    }

    pub fn deinit(self: *Node) void {
        self.chain_db.close();
        self.mempool.deinit();
    }

    /// Get current chain tip info.
    pub fn getTip(self: *const Node) struct { slot: SlotNo, block_no: BlockNo } {
        const tip = self.chain_db.getTip();
        return .{ .slot = tip.slot, .block_no = tip.block_no };
    }

    /// Process a received block from the network.
    /// Returns true if the block was accepted and extended the chain.
    pub fn processBlock(self: *Node, block_data: []const u8) !bool {
        // Parse the block header
        const block = block_mod.parseBlock(block_data) catch return false;

        // Add to chain DB
        const result = try self.chain_db.addBlock(
            block.hash(),
            block_data,
            block.header.slot,
            block.header.block_no,
            block.header.prev_hash,
        );

        return result == .added_to_current_chain;
    }

    /// Get node status summary.
    pub fn status(self: *const Node) NodeStatus {
        const tip = self.chain_db.getTip();
        return .{
            .tip_slot = tip.slot,
            .tip_block_no = tip.block_no,
            .total_blocks = self.chain_db.totalBlocks(),
            .mempool_txs = self.mempool.count(),
            .mempool_bytes = self.mempool.sizeBytes(),
        };
    }
};

pub const NodeStatus = struct {
    tip_slot: SlotNo,
    tip_block_no: BlockNo,
    total_blocks: usize,
    mempool_txs: usize,
    mempool_bytes: u32,
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "node: init and deinit" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-node") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-node") catch {};

    var node = try Node.init(allocator, .{
        .network_magic = 2,
        .db_path = "/tmp/kassadin-test-node",
        .security_param = 2160,
        .mempool_capacity = 100_000,
    });
    defer node.deinit();

    const tip = node.getTip();
    try std.testing.expectEqual(@as(SlotNo, 0), tip.slot);

    const st = node.status();
    try std.testing.expectEqual(@as(usize, 0), st.total_blocks);
    try std.testing.expectEqual(@as(usize, 0), st.mempool_txs);
}

test "node: preview defaults" {
    try std.testing.expectEqual(@as(u32, 2), NodeConfig.preview_defaults.network_magic);
    try std.testing.expectEqual(@as(u64, 2160), NodeConfig.preview_defaults.security_param);
}
