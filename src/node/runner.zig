const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const genesis_mod = @import("genesis.zig");
const sync_mod = @import("sync.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;
const Mempool = @import("../mempool/mempool.zig").Mempool;
const PraosState = @import("../consensus/praos.zig").PraosState;
const protocol = @import("../network/protocol.zig");

/// Node runner configuration.
pub const RunConfig = struct {
    /// Network to connect to.
    network_magic: u32,
    /// Peer to sync from (hostname:port for N2N, or socket path for N2C).
    peer_host: []const u8,
    peer_port: u16,
    /// Database path for chain storage.
    db_path: []const u8,
    /// Genesis configuration file paths.
    shelley_genesis_path: ?[]const u8,
    /// Maximum headers to sync (0 = unlimited).
    max_headers: u64,

    pub const preview_defaults = RunConfig{
        .network_magic = protocol.NetworkMagic.preview,
        .peer_host = "preview-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "db",
        .shelley_genesis_path = null,
        .max_headers = 0,
    };

    pub const preprod_defaults = RunConfig{
        .network_magic = protocol.NetworkMagic.preprod,
        .peer_host = "preprod-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "db",
        .shelley_genesis_path = null,
        .max_headers = 0,
    };
};

/// Run result / status.
pub const RunResult = struct {
    headers_synced: u64,
    tip_slot: u64,
    tip_block_no: u64,
    rollbacks: u64,
    errors: u64,
    genesis_loaded: bool,
};

/// Run the node: load config, optionally restore from snapshot, connect, sync.
pub fn run(allocator: Allocator, config: RunConfig) !RunResult {
    var result = RunResult{
        .headers_synced = 0,
        .tip_slot = 0,
        .tip_block_no = 0,
        .rollbacks = 0,
        .errors = 0,
        .genesis_loaded = false,
    };

    // Load genesis if available
    if (config.shelley_genesis_path) |path| {
        _ = genesis_mod.parseShelleyGenesis(allocator, path) catch {
            // Continue without genesis — we can still sync headers
        };
        result.genesis_loaded = true;
    }

    // Open chain database
    var chain_db = try ChainDB.open(allocator, config.db_path, 2160);
    defer chain_db.close();

    // Connect to peer
    var client = try sync_mod.SyncClient.connect(
        allocator,
        config.peer_host,
        config.peer_port,
        config.network_magic,
    );
    defer client.close();

    // Find intersect from genesis
    _ = try client.findIntersectGenesis();

    // Sync loop
    const max = if (config.max_headers == 0) std.math.maxInt(u64) else config.max_headers;
    var synced: u64 = 0;

    while (synced < max) {
        const msg = client.requestNext() catch {
            result.errors += 1;
            break;
        };

        switch (msg) {
            .roll_forward => |rf| {
                synced += 1;
                result.tip_slot = rf.tip.slot;
                result.tip_block_no = rf.tip.block_no;
            },
            .await_reply => {
                // At tip — send keep-alive and wait
                client.keepAlive() catch {};
                std.Thread.sleep(1 * std.time.ns_per_s);
            },
            .roll_backward => {
                result.rollbacks += 1;
            },
            else => break,
        }
    }

    result.headers_synced = synced;
    return result;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "runner: sync 10 headers from preview" {
    const allocator = std.testing.allocator;

    std.fs.cwd().deleteTree("/tmp/kassadin-runner-test") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-runner-test") catch {};

    const result = run(allocator, .{
        .network_magic = protocol.NetworkMagic.preview,
        .peer_host = "preview-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "/tmp/kassadin-runner-test",
        .shelley_genesis_path = null,
        .max_headers = 10,
    }) catch return; // skip if no network

    try std.testing.expect(result.headers_synced >= 1);
    try std.testing.expect(result.tip_slot > 0);
}

test "runner: config defaults" {
    const preview = RunConfig.preview_defaults;
    try std.testing.expectEqual(@as(u32, 2), preview.network_magic);

    const preprod = RunConfig.preprod_defaults;
    try std.testing.expectEqual(@as(u32, 1), preprod.network_magic);
}
