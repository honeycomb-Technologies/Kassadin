const std = @import("std");
const Allocator = std.mem.Allocator;
const block_mod = @import("../ledger/block.zig");
const tx_mod = @import("../ledger/transaction.zig");
const chainsync = @import("../network/chainsync.zig");
const dolos_grpc_mod = @import("../network/dolos_grpc_client.zig");
const peer_mod = @import("../network/peer.zig");
const protocol = @import("../network/protocol.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const chunk_reader_mod = @import("chunk_reader.zig");
const genesis_mod = @import("genesis.zig");
const ledger_snapshot = @import("ledger_snapshot.zig");
const runtime_control = @import("runtime_control.zig");
const snapshot_restore = @import("snapshot_restore.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Result of a bootstrap sync operation.
pub const BootstrapSyncResult = struct {
    snapshot_tip_slot: u64,
    snapshot_tip_block: u64,
    headers_synced_forward: u64,
    network_tip_slot: u64,
    network_tip_block: u64,
    blocks_parsed: u64,
    blocks_added_to_chain: u64,
    txs_parsed: u64,
    validation_enabled: bool,
    base_utxos_primed: u64,
    local_ledger_snapshot_slot: u64,
    immutable_blocks_replayed: u64,
    invalid_blocks: u64,
    rollbacks: u64,
    stopped_by_signal: bool,
};

/// Run a full bootstrap sync:
/// 1. Resolve and validate the restored snapshot layout
/// 2. Read the snapshot tip from the ImmutableDB
/// 2. Connect to a peer
/// 3. FindIntersect at the snapshot tip
/// 4. Sync forward, fetching and parsing each block
pub fn bootstrapSync(
    allocator: Allocator,
    db_path: []const u8,
    peer_host: []const u8,
    peer_port: u16,
    network_magic: u32,
    max_blocks: u64,
    shelley_genesis_path: ?[]const u8,
    validation_endpoint: ?[]const u8,
) !BootstrapSyncResult {
    var result = std.mem.zeroes(BootstrapSyncResult);
    const max = if (max_blocks == 0) std.math.maxInt(u64) else max_blocks;
    var loaded_governance_config: ?protocol_update.GovernanceConfig = null;
    defer {
        if (loaded_governance_config) |*config| config.deinit(allocator);
    }

    // Step 1: Resolve the extracted snapshot layout
    var layout = snapshot_restore.resolveSnapshotLayout(allocator, db_path) catch {
        std.debug.print("No snapshot found under {s}. Use 'kassadin bootstrap --download' first.\n", .{db_path});
        return error.NoSnapshot;
    };
    defer layout.deinit(allocator);

    const snapshot_state = try snapshot_restore.scanSnapshotDir(allocator, db_path);
    if (snapshot_state.immutable_file_count == 0) {
        std.debug.print("Snapshot layout resolved, but no immutable chunk files were found under {s}.\n", .{layout.immutable_path});
        return error.EmptySnapshot;
    }

    // Step 2: Read the snapshot tip
    std.debug.print("Reading snapshot tip from {s}...\n", .{layout.immutable_path});
    var reader = try chunk_reader_mod.ChunkReader.init(layout.immutable_path);

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

    var chain_db = try ChainDB.open(allocator, db_path, 2160);
    defer chain_db.close();

    if (shelley_genesis_path) |path| {
        if (genesis_mod.loadLedgerProtocolParams(allocator, path) catch null) |protocol_params| {
            chain_db.setProtocolParams(protocol_params);
        }
        if (genesis_mod.loadShelleyGovernanceConfig(allocator, path) catch null) |governance_config| {
            loaded_governance_config = governance_config;
        }
    }
    if (loaded_governance_config) |governance_config| {
        try chain_db.configureShelleyGovernanceTracking(governance_config);
        loaded_governance_config = null;
    }

    var validation_client: ?dolos_grpc_mod.Client = null;
    defer {
        if (validation_client) |*client| {
            client.deinit();
        }
    }

    var local_validation_ready = false;
    if (layout.ledger_path) |ledger_path| {
        if (try ledger_snapshot.findLatestSnapshotAtOrBefore(allocator, ledger_path, tip_block.header.slot)) |snapshot| {
            defer {
                var owned = snapshot;
                owned.deinit(allocator);
            }

            std.debug.print("Loading local ledger snapshot at slot {}...\n", .{snapshot.slot});
            const load_result = ledger_snapshot.loadSnapshotIntoLedger(allocator, &chain_db.ledger, snapshot) catch |err| switch (err) {
                error.Interrupted => {
                    result.stopped_by_signal = true;
                    return result;
                },
                else => return err,
            };
            result.base_utxos_primed = load_result.utxos_loaded;
            result.local_ledger_snapshot_slot = load_result.slot;

            std.debug.print("Replaying immutable tail from slot {} to snapshot tip...\n", .{load_result.slot});
            const replay = ledger_snapshot.replayImmutableFromSlot(
                allocator,
                &chain_db.ledger,
                layout.immutable_path,
                load_result.slot,
                chain_db.getProtocolParams(),
            ) catch |err| switch (err) {
                error.Interrupted => {
                    result.stopped_by_signal = true;
                    return result;
                },
                else => return err,
            };
            result.immutable_blocks_replayed = replay.blocks_replayed;
            local_validation_ready = true;
            result.validation_enabled = true;
            std.debug.print(
                "Local ledger validation ready: {} UTxOs loaded, {} immutable blocks replayed.\n",
                .{ result.base_utxos_primed, result.immutable_blocks_replayed },
            );
        }
    }

    chain_db.attachSnapshotTip(.{
        .slot = tip_block.header.slot,
        .hash = block_hash,
    }, tip_block.header.block_no) catch |err| switch (err) {
        error.ChainNotEmpty => {},
        else => return err,
    };

    if (local_validation_ready) {
        try chain_db.enableLedgerValidation();
    } else if (validation_endpoint) |endpoint| {
        if (tip_block.era == .byron) {
            std.debug.print("Skipping Dolos validation bootstrap: Byron snapshot tips are not supported.\n", .{});
        } else {
            std.debug.print("Connecting to Dolos gRPC endpoint at {s}...\n", .{endpoint});
            var client = try dolos_grpc_mod.Client.init(allocator, endpoint);
            errdefer client.deinit();
            try chain_db.enableLedgerValidation();
            validation_client = client;
            result.validation_enabled = true;
            std.debug.print("Dolos validation enabled at snapshot point.\n", .{});
        }
    }

    const intersect_point = chainsync.Point{
        .slot = tip_block.header.slot,
        .hash = block_hash,
    };

    // Step 3: Connect to peer
    std.debug.print("Connecting to {s}:{}...\n", .{ peer_host, peer_port });
    var peer = peer_mod.Peer.connect(allocator, peer_host, peer_port, network_magic) catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return err;
    };
    defer peer.close();
    std.debug.print("Connected (v{})\n", .{peer.negotiated_version.?});

    // Step 4: FindIntersect at snapshot tip
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

            const gap = result.network_tip_block -| result.snapshot_tip_block;
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

    // Step 5: Sync forward, fetching and parsing each block
    if (max_blocks == 0) {
        std.debug.print("Syncing forward until stopped...\n", .{});
    } else {
        std.debug.print("Syncing forward (max {} blocks)...\n", .{max_blocks});
    }
    var synced: u64 = 0;

    while (synced < max) {
        if (runtime_control.stopRequested()) {
            result.stopped_by_signal = true;
            break;
        }

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

                const point = block_mod.pointFromHeader(rf.header_raw) catch {
                    std.debug.print("  Header {}: failed to derive point\n", .{synced});
                    continue;
                };

                const block_raw = try peer.blockFetchSingle(point) orelse {
                    std.debug.print("  Header {}: no block returned for slot {}\n", .{ synced, point.slot });
                    continue;
                };
                defer allocator.free(block_raw);

                const block = block_mod.parseBlock(block_raw) catch |err| {
                    std.debug.print("  Header {}: block parse failed: {}\n", .{ synced, err });
                    continue;
                };

                result.blocks_parsed += 1;
                if (validation_client) |*client| {
                    const primed = try hydrateMissingSnapshotInputs(allocator, client, &chain_db, &block);
                    result.base_utxos_primed += primed;
                }

                const add_result = try chain_db.addBlock(
                    block.hash(),
                    block_raw,
                    block.header.slot,
                    block.header.block_no,
                    block.header.prev_hash,
                );
                switch (add_result) {
                    .added_to_current_chain => {
                        result.blocks_added_to_chain += 1;
                    },
                    .invalid => {
                        result.invalid_blocks += 1;
                        std.debug.print("  Block {}: invalid under current ledger rules\n", .{synced});
                        break;
                    },
                    else => {},
                }

                var tx_dec = Decoder.init(block.tx_bodies_raw);
                const num_txs = (tx_dec.decodeArrayLen() catch null) orelse 0;
                result.txs_parsed += num_txs;

                if (synced <= 5 or synced % 100 == 0) {
                    std.debug.print("  Block {}: slot={} block={} txs={}\n", .{
                        synced,
                        block.header.slot,
                        block.header.block_no,
                        num_txs,
                    });
                }
            },
            .await_reply => {
                if (runtime_control.stopRequested()) {
                    result.stopped_by_signal = true;
                    break;
                }
                std.debug.print("At tip! Synced {} blocks forward.\n", .{synced});
                const cookie: u16 = @truncate(synced);
                _ = peer.keepAlivePing(cookie) catch {};
                std.Thread.sleep(1 * std.time.ns_per_s);
            },
            .roll_backward => |rb| {
                result.rollbacks += 1;
                _ = chain_db.rollbackToPoint(rb.point) catch 0;
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

    var layout = snapshot_restore.resolveSnapshotLayout(allocator, "db/preprod") catch return;
    defer layout.deinit(allocator);

    var reader = chunk_reader_mod.ChunkReader.init(layout.immutable_path) catch return;
    const tip_result = try reader.readTip(allocator) orelse return;
    defer allocator.free(tip_result.raw);

    try std.testing.expect(tip_result.block.header.slot > 100_000_000);
    try std.testing.expect(tip_result.block.header.block_no > 4_000_000);
    try std.testing.expectEqual(block_mod.Era.conway, tip_result.block.era);
}

fn hydrateMissingSnapshotInputs(
    allocator: Allocator,
    client: *dolos_grpc_mod.Client,
    chain_db: *ChainDB,
    block: *const block_mod.Block,
) !u32 {
    if (!chain_db.isLedgerValidationEnabled()) return 0;

    var missing_inputs = std.AutoHashMap(tx_mod.TxIn, void).init(allocator);
    defer missing_inputs.deinit();

    var tx_dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try tx_dec.decodeArrayLen()) orelse return 0;

    var tx_index: u64 = 0;
    while (tx_index < num_txs) : (tx_index += 1) {
        const tx_raw = try tx_dec.sliceOfNextValue();
        var tx = tx_mod.parseTxBody(allocator, tx_raw) catch continue;
        defer tx_mod.freeTxBody(allocator, &tx);

        for (tx.inputs) |input| {
            if (chain_db.ledger.lookupUtxo(input) != null) continue;
            try missing_inputs.put(input, {});
        }
    }

    if (missing_inputs.count() == 0) return 0;

    const txins = try allocator.alloc(tx_mod.TxIn, missing_inputs.count());
    defer allocator.free(txins);

    var i: usize = 0;
    var it = missing_inputs.iterator();
    while (it.next()) |entry| : (i += 1) {
        txins[i] = entry.key_ptr.*;
    }

    const base_entries = try client.readHistoricalUtxos(allocator, txins);
    defer dolos_grpc_mod.freeReadUtxos(allocator, base_entries);

    return chain_db.primeBaseUtxos(base_entries);
}
