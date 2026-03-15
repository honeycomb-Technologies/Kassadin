const std = @import("std");

pub const crypto = struct {
    pub const hash = @import("crypto/hash.zig");
    pub const ed25519 = @import("crypto/ed25519.zig");
    pub const vrf = @import("crypto/vrf.zig");
    pub const kes = @import("crypto/kes.zig");
    pub const opcert = @import("crypto/opcert.zig");
    pub const bech32 = @import("crypto/bech32.zig");
};

pub const cbor = @import("cbor/cbor.zig");
pub const types = @import("types.zig");

pub const network = struct {
    pub const protocol = @import("network/protocol.zig");
    pub const mux = @import("network/mux.zig");
    pub const handshake = @import("network/handshake.zig");
    pub const chainsync = @import("network/chainsync.zig");
    pub const blockfetch = @import("network/blockfetch.zig");
    pub const txsubmission = @import("network/txsubmission.zig");
    pub const keepalive = @import("network/keepalive.zig");
    pub const peersharing = @import("network/peersharing.zig");
    pub const peer = @import("network/peer.zig");
    pub const unix_bearer = @import("network/unix_bearer.zig");
    pub const n2c_handshake = @import("network/n2c_handshake.zig");
    pub const local_tx_submission = @import("network/local_tx_submission.zig");
    pub const local_tx_monitor = @import("network/local_tx_monitor.zig");
    pub const local_state_query = @import("network/local_state_query.zig");
};

pub const storage = struct {
    pub const immutable = @import("storage/immutable.zig");
    pub const volatile_db = @import("storage/volatile.zig");
    pub const ledger = @import("storage/ledger.zig");
    pub const chaindb = @import("storage/chaindb.zig");
};

pub const ledger = struct {
    pub const block = @import("ledger/block.zig");
    pub const transaction = @import("ledger/transaction.zig");
    pub const rules = @import("ledger/rules.zig");
    pub const multiasset = @import("ledger/multiasset.zig");
    pub const certificates = @import("ledger/certificates.zig");
    pub const scripts = @import("ledger/scripts.zig");
    pub const plutus = @import("ledger/plutus.zig");
    pub const script_context = @import("ledger/script_context.zig");
    pub const stake = @import("ledger/stake.zig");
    pub const apply = @import("ledger/apply.zig");
    pub const rewards = @import("ledger/rewards.zig");
    pub const witness = @import("ledger/witness.zig");
    pub const golden_tests = @import("ledger/golden_tests.zig");
};

pub const consensus = struct {
    pub const praos = @import("consensus/praos.zig");
    pub const leader = @import("consensus/leader.zig");
    pub const header_validation = @import("consensus/header_validation.zig");
};

pub const mempool = @import("mempool/mempool.zig");
pub const node = struct {
    pub const node_mod = @import("node/node.zig");
    pub const keys = @import("node/keys.zig");
    pub const genesis = @import("node/genesis.zig");
    pub const sync = @import("node/sync.zig");
    pub const runner = @import("node/runner.zig");
    pub const mithril = @import("node/mithril.zig");
    pub const snapshot_restore = @import("node/snapshot_restore.zig");
    pub const chunk_reader = @import("node/chunk_reader.zig");
    pub const bootstrap_sync = @import("node/bootstrap_sync.zig");
};

pub fn main() !void {

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "sync")) {
        // kassadin sync [--network preview|preprod] [--max-headers N]
        std.debug.print("Kassadin — Cardano Node in Zig\n", .{});
        std.debug.print("Syncing from preview network...\n\n", .{});

        const result = node.runner.run(std.heap.page_allocator, .{
            .network_magic = network.protocol.NetworkMagic.preview,
            .peer_host = "preview-node.play.dev.cardano.org",
            .peer_port = 3001,
            .db_path = "db",
            .shelley_genesis_path = null,
            .max_headers = 20,
        }) catch |err| {
            std.debug.print("Sync error: {}\n", .{err});
            return;
        };

        std.debug.print("Sync complete:\n", .{});
        std.debug.print("  Headers synced: {}\n", .{result.headers_synced});
        std.debug.print("  Tip slot: {}\n", .{result.tip_slot});
        std.debug.print("  Tip block: {}\n", .{result.tip_block_no});
        std.debug.print("  Rollbacks: {}\n", .{result.rollbacks});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "bootstrap")) {
        std.debug.print("Kassadin — Mithril Bootstrap\n", .{});
        std.debug.print("Fetching latest preprod snapshot info...\n\n", .{});

        const info = node.mithril.fetchLatestSnapshot(
            std.heap.page_allocator,
            node.mithril.aggregator_urls.preprod,
        ) catch |err| {
            std.debug.print("Failed to fetch snapshot: {}\n", .{err});
            return;
        };

        std.debug.print("Latest snapshot:\n", .{});
        std.debug.print("  Epoch: {}\n", .{info.epoch});
        std.debug.print("  Immutable file: {}\n", .{info.immutable_file_number});
        std.debug.print("  Size: {} MB\n", .{info.size / 1024 / 1024});
        std.debug.print("\nTo download and restore, run:\n", .{});
        std.debug.print("  kassadin bootstrap --download\n", .{});

        if (args.len > 2 and std.mem.eql(u8, args[2], "--download")) {
            std.debug.print("\nDownloading and extracting...\n", .{});
            node.mithril.downloadAndExtract(
                std.heap.page_allocator,
                info,
                "db",
            ) catch |err| {
                std.debug.print("Bootstrap failed: {}\n", .{err});
                return;
            };
            std.debug.print("Bootstrap complete! Run 'kassadin sync' to continue from tip.\n", .{});
        }
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "bootstrap-sync")) {
        // Sync forward from Mithril snapshot tip
        std.debug.print("Kassadin — Bootstrap Sync (preprod)\n\n", .{});

        const result = node.bootstrap_sync.bootstrapSync(
            std.heap.page_allocator,
            "db/preprod/immutable",
            "preprod-node.play.dev.cardano.org",
            3001,
            network.protocol.NetworkMagic.preprod,
            100, // max 100 blocks forward
        ) catch |err| {
            std.debug.print("Bootstrap sync failed: {}\n", .{err});
            return;
        };

        std.debug.print("\nBootstrap sync complete:\n", .{});
        std.debug.print("  Snapshot tip: block={}, slot={}\n", .{ result.snapshot_tip_block, result.snapshot_tip_slot });
        std.debug.print("  Headers synced forward: {}\n", .{result.headers_synced_forward});
        std.debug.print("  Network tip: block={}, slot={}\n", .{ result.network_tip_block, result.network_tip_slot });
        std.debug.print("  Rollbacks: {}\n", .{result.rollbacks});
    } else {
        std.debug.print("Kassadin — Cardano Node in Zig\n", .{});
        std.debug.print("Version: 0.1.0\n", .{});
        std.debug.print("\nUsage:\n", .{});
        std.debug.print("  kassadin bootstrap           Show latest Mithril snapshot info\n", .{});
        std.debug.print("  kassadin bootstrap --download Download and restore snapshot\n", .{});
        std.debug.print("  kassadin bootstrap-sync       Sync forward from Mithril snapshot\n", .{});
        std.debug.print("  kassadin sync                 Sync headers from preview network\n", .{});
        std.debug.print("  kassadin                      Show this help\n", .{});
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
