const std = @import("std");
const kassadin = @import("kassadin");

const block_mod = kassadin.ledger.block;
const chainsync = kassadin.network.chainsync;
const peer_mod = kassadin.network.peer;
const protocol = kassadin.network.protocol;
const genesis_mod = kassadin.node.genesis;
const ChainDB = kassadin.storage.chaindb.ChainDB;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const db_path = "/tmp/kassadin-origin-transition-test";
    const max_headers: u64 = 200;

    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    var chain_db = try ChainDB.open(allocator, db_path, 2160);
    defer chain_db.close();

    const byron_pp = try genesis_mod.loadByronLedgerProtocolParams(allocator, "byron.json");
    const shelley_pp = try genesis_mod.loadLedgerProtocolParams(allocator, "shelley.json");
    var governance_config = try genesis_mod.loadShelleyGovernanceConfig(allocator, "shelley.json");
    var governance_config_owned = true;
    defer if (governance_config_owned) governance_config.deinit(allocator);
    chain_db.setProtocolParams(byron_pp);
    try chain_db.configureShelleyGovernanceTracking(governance_config);
    governance_config_owned = false;

    var genesis = try genesis_mod.parseByronGenesis(allocator, "byron.json");
    defer genesis.deinit(allocator);
    const utxos = try genesis_mod.buildByronGenesisUtxos(allocator, &genesis);
    defer genesis_mod.freeGenesisUtxos(allocator, utxos);

    const primed = try chain_db.primeBaseUtxos(utxos);
    try chain_db.enableLedgerValidation();

    var peer = try peer_mod.Peer.connect(
        allocator,
        "preprod-node.play.dev.cardano.org",
        3001,
        protocol.NetworkMagic.preprod,
    );
    defer peer.close();

    _ = try peer.chainSyncFindIntersect(&[_]chainsync.Point{});

    var headers_seen: u64 = 0;
    var byron_blocks: u64 = 0;
    var post_byron_blocks: u64 = 0;
    var switched_to_shelley = false;
    var transition_block_no: u64 = 0;
    var transition_slot: u64 = 0;

    while (headers_seen < max_headers and post_byron_blocks == 0) {
        const msg = try peer.chainSyncRequestNext();
        switch (msg) {
            .roll_forward => |rf| {
                headers_seen += 1;

                const point = try block_mod.pointFromHeader(rf.header_raw);
                const block_raw = try peer.blockFetchSingle(point) orelse return error.NoBlock;
                defer allocator.free(block_raw);

                const block = try block_mod.parseBlock(block_raw);
                if (!switched_to_shelley and block.era != .byron) {
                    chain_db.setProtocolParams(shelley_pp);
                    switched_to_shelley = true;
                    transition_block_no = block.header.block_no;
                    transition_slot = block.header.slot;
                }

                const add_result = try chain_db.addBlock(
                    block.hash(),
                    block_raw,
                    block.header.slot,
                    block.header.block_no,
                    block.header.prev_hash,
                );
                if (add_result == .invalid) {
                    std.debug.print("Transition test saw invalid block era={} block={} slot={} vrf_len={} leader_len={}\n", .{
                        block.era,
                        block.header.block_no,
                        block.header.slot,
                        block.header.vrf_result_raw.len,
                        if (block.header.leader_vrf_raw) |leader_raw| leader_raw.len else @as(usize, 0),
                    });
                    std.process.exit(1);
                }

                switch (block.era) {
                    .byron => byron_blocks += 1,
                    else => post_byron_blocks += 1,
                }
            },
            .roll_backward => |rb| {
                _ = try chain_db.rollbackToPoint(rb.point);
            },
            .await_reply => {
                std.Thread.sleep(250 * std.time.ns_per_ms);
            },
            else => {},
        }
    }

    std.debug.print("=== Origin Transition Test ===\n", .{});
    std.debug.print("Genesis UTxOs primed: {}\n", .{primed});
    std.debug.print("Headers seen: {}\n", .{headers_seen});
    std.debug.print("Byron blocks validated: {}\n", .{byron_blocks});
    std.debug.print("Post-Byron blocks validated: {}\n", .{post_byron_blocks});
    if (switched_to_shelley) {
        std.debug.print("First post-Byron block: {} at slot {}\n", .{ transition_block_no, transition_slot });
    }

    if (!switched_to_shelley or post_byron_blocks == 0) {
        std.debug.print("Did not reach a post-Byron block within {} headers\n", .{max_headers});
        std.process.exit(1);
    }

    std.debug.print("Origin path validated across the Byron-to-Shelley transition.\n", .{});
}
