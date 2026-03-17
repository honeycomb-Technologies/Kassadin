const std = @import("std");
const kassadin = @import("kassadin");

const runner = kassadin.node.runner;
const protocol = kassadin.network.protocol;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const db_path = "/tmp/kassadin-origin-sync-test";

    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    const result = runner.run(allocator, .{
        .network_magic = protocol.NetworkMagic.preprod,
        .peer_host = "preprod-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = db_path,
        .byron_genesis_path = "byron.json",
        .shelley_genesis_path = "shelley.json",
        .max_headers = 5,
    }) catch |err| {
        std.debug.print("Origin sync failed: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("=== Origin Sync Test ===\n", .{});
    std.debug.print("Genesis loaded: {}\n", .{result.genesis_loaded});
    std.debug.print("Validation enabled: {}\n", .{result.validation_enabled});
    std.debug.print("Base UTxOs primed: {}\n", .{result.base_utxos_primed});
    std.debug.print("Headers synced: {}\n", .{result.headers_synced});
    std.debug.print("Blocks added: {}\n", .{result.blocks_added_to_chain});
    std.debug.print("Invalid blocks: {}\n", .{result.invalid_blocks});
    std.debug.print("Tip block: {}\n", .{result.tip_block_no});
    std.debug.print("Tip slot: {}\n", .{result.tip_slot});

    if (!result.genesis_loaded) {
        std.debug.print("Expected genesis to be loaded for origin sync\n", .{});
        std.process.exit(1);
    }
    if (!result.validation_enabled) {
        std.debug.print("Expected local validation to be enabled for origin sync\n", .{});
        std.process.exit(1);
    }
    if (result.base_utxos_primed == 0) {
        std.debug.print("Expected Byron genesis UTxOs to be primed\n", .{});
        std.process.exit(1);
    }
    if (result.blocks_added_to_chain == 0) {
        std.debug.print("Expected origin sync to add blocks to the chain\n", .{});
        std.process.exit(1);
    }
    if (result.invalid_blocks != 0) {
        std.debug.print("Expected origin sync to avoid invalid blocks\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Origin sync path validated from a fresh empty DB.\n", .{});
}
