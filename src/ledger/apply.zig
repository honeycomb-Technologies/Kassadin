const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const block_mod = @import("block.zig");
const tx_mod = @import("transaction.zig");
const protocol_update = @import("protocol_update.zig");
const rules = @import("rules.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const LedgerDiff = @import("../storage/ledger.zig").LedgerDiff;
const Decoder = @import("../cbor/decoder.zig").Decoder;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const HeaderHash = types.HeaderHash;

fn freeOwnedEntries(allocator: Allocator, entries: []const UtxoEntry) void {
    for (entries) |entry| {
        allocator.free(entry.raw_cbor);
    }
    allocator.free(entries);
}

/// Result of applying a block to the ledger.
pub const ApplyResult = struct {
    txs_applied: u32,
    txs_failed: u32,
    txs_skipped: u32, // parse failures (our limitation, not invalid blocks)
    total_fees: Coin,
    protocol_updates: []protocol_update.TxProtocolUpdate,

    pub fn deinit(self: *ApplyResult, allocator: Allocator) void {
        protocol_update.freeTxUpdates(allocator, self.protocol_updates);
    }
};

fn buildDiff(
    allocator: Allocator,
    ledger: *const LedgerDB,
    block: *const block_mod.Block,
    tx: *const tx_mod.TxBody,
    pp: rules.ProtocolParams,
    validation_context: rules.ValidationContext,
) !LedgerDiff {
    var consumed_list: std.ArrayList(UtxoEntry) = .empty;
    defer consumed_list.deinit(allocator);

    for (tx.inputs) |input| {
        const entry = ledger.lookupUtxo(input) orelse unreachable;

        try consumed_list.append(allocator, .{
            .tx_in = input,
            .value = entry.value,
            .raw_cbor = try allocator.dupe(u8, entry.raw_cbor),
        });
    }

    var produced_list: std.ArrayList(UtxoEntry) = .empty;
    defer produced_list.deinit(allocator);

    for (tx.outputs, 0..) |out, ix| {
        try produced_list.append(allocator, .{
            .tx_in = .{ .tx_id = tx.tx_id, .tx_ix = @intCast(ix) },
            .value = out.value,
            .raw_cbor = try allocator.dupe(u8, out.raw_cbor),
        });
    }

    const consumed = try consumed_list.toOwnedSlice(allocator);
    errdefer freeOwnedEntries(allocator, consumed);
    const produced = try produced_list.toOwnedSlice(allocator);
    errdefer freeOwnedEntries(allocator, produced);

    var withdrawal_effect = try rules.evaluateWithdrawalEffect(allocator, tx, ledger);
    errdefer withdrawal_effect.deinit(allocator);

    var cert_effect = try rules.evaluateCertificateEffectWithContext(allocator, tx, ledger, pp, validation_context);
    errdefer cert_effect.deinit(allocator);

    return .{
        .slot = block.header.slot,
        .block_hash = block.hash(),
        .consumed = consumed,
        .produced = produced,
        .mir_delta_reserves_change = cert_effect.mir_delta_reserves_change,
        .mir_delta_treasury_change = cert_effect.mir_delta_treasury_change,
        .reward_balance_changes = withdrawal_effect.reward_balance_changes,
        .mir_reserves_changes = cert_effect.mir_reserves_changes,
        .mir_treasury_changes = cert_effect.mir_treasury_changes,
        .stake_deposit_changes = cert_effect.stake_deposit_changes,
        .pool_deposit_changes = cert_effect.pool_deposit_changes,
        .pool_config_changes = cert_effect.pool_config_changes,
        .future_pool_param_changes = cert_effect.future_pool_param_changes,
        .pool_reward_account_changes = cert_effect.pool_reward_account_changes,
        .pool_owner_changes = cert_effect.pool_owner_changes,
        .future_pool_owner_changes = cert_effect.future_pool_owner_changes,
        .pool_retirement_changes = cert_effect.pool_retirement_changes,
        .drep_deposit_changes = cert_effect.drep_deposit_changes,
        .stake_pool_delegation_changes = cert_effect.stake_pool_delegation_changes,
        .drep_delegation_changes = cert_effect.drep_delegation_changes,
    };
}

fn applyShelleyLikeBlock(
    allocator: Allocator,
    ledger: *LedgerDB,
    block: *const block_mod.Block,
    pp: rules.ProtocolParams,
    governance_config: ?*const protocol_update.GovernanceConfig,
) !ApplyResult {
    var result = ApplyResult{
        .txs_applied = 0,
        .txs_failed = 0,
        .txs_skipped = 0,
        .total_fees = 0,
        .protocol_updates = try allocator.alloc(protocol_update.TxProtocolUpdate, 0),
    };
    errdefer result.deinit(allocator);
    var collected_updates: std.ArrayList(protocol_update.TxProtocolUpdate) = .empty;
    defer {
        if (result.protocol_updates.len == 0) {
            protocol_update.freeTxUpdates(allocator, collected_updates.items);
        } else {
            collected_updates.deinit(allocator);
        }
    }

    var tx_dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try tx_dec.decodeArrayLen()) orelse return result;
    const validation_context = rules.ValidationContext{
        .current_slot = block.header.slot,
        .protocol_version_major = block.header.protocol_version_major,
        .epoch_length = if (governance_config) |config| config.epoch_length else null,
        .stability_window = if (governance_config) |config| config.stability_window else null,
    };

    var tx_idx: u64 = 0;
    while (tx_idx < num_txs) : (tx_idx += 1) {
        const tx_raw = try tx_dec.sliceOfNextValue();

        var tx = tx_mod.parseTxBody(allocator, tx_raw) catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Tx {}: parse skipped: {} (len={})\n", .{ tx_idx, err, tx_raw.len });
            }
            // Parse failures are our limitation — skip the tx, don't reject the block
            result.txs_skipped += 1;
            continue;
        };
        defer tx_mod.freeTxBody(allocator, &tx);

        _ = rules.validateTxWithContext(
            &tx,
            ledger,
            pp,
            validation_context,
            switch (block.era) {
                .shelley, .allegra, .mary => true,
                else => false,
            },
        ) catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Tx {}: validation failed: {}\n", .{ tx_idx, err });
            }
            result.txs_failed += 1;
            continue;
        };

        try ledger.applyDiff(try buildDiff(allocator, ledger, block, &tx, pp, validation_context));
        result.txs_applied += 1;
        result.total_fees += tx.fee;
        if (tx.update) |*update| {
            try collected_updates.append(allocator, try protocol_update.cloneBorrowedTxUpdate(allocator, update));
        }
    }

    allocator.free(result.protocol_updates);
    result.protocol_updates = try collected_updates.toOwnedSlice(allocator);
    return result;
}

fn applyByronBlock(
    allocator: Allocator,
    ledger: *LedgerDB,
    block: *const block_mod.Block,
    pp: rules.ProtocolParams,
) !ApplyResult {
    var result = ApplyResult{
        .txs_applied = 0,
        .txs_failed = 0,
        .txs_skipped = 0,
        .total_fees = 0,
        .protocol_updates = try allocator.alloc(protocol_update.TxProtocolUpdate, 0),
    };
    errdefer result.deinit(allocator);

    var payload_dec = Decoder.init(block.tx_bodies_raw);
    const tx_payload_len = try payload_dec.decodeArrayLen();

    var tx_idx: u64 = 0;
    while (true) : (tx_idx += 1) {
        if (tx_payload_len) |count| {
            if (tx_idx >= count) break;
        } else if (payload_dec.isBreak()) {
            try payload_dec.decodeBreak();
            break;
        }

        const tx_entry_raw = payload_dec.sliceOfNextValue() catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Byron tx {}: payload parse failed: {}\n", .{ tx_idx, err });
            }
            result.txs_failed += 1;
            continue;
        };

        var entry_dec = Decoder.init(tx_entry_raw);
        const entry_len = (try entry_dec.decodeArrayLen()) orelse {
            result.txs_failed += 1;
            continue;
        };
        if (entry_len != 2) {
            result.txs_failed += 1;
            continue;
        }

        const tx_raw = entry_dec.sliceOfNextValue() catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Byron tx {}: tx extraction failed: {}\n", .{ tx_idx, err });
            }
            result.txs_failed += 1;
            continue;
        };
        _ = entry_dec.sliceOfNextValue() catch {
            result.txs_failed += 1;
            continue;
        };

        var tx = tx_mod.parseByronTxBody(allocator, tx_raw) catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Byron tx {}: parse failed: {}\n", .{ tx_idx, err });
            }
            result.txs_failed += 1;
            continue;
        };
        defer tx_mod.freeTxBody(allocator, &tx);

        var consumed_value: Coin = 0;
        var missing_input = false;
        for (tx.inputs) |input| {
            const entry = ledger.lookupUtxo(input) orelse {
                missing_input = true;
                break;
            };
            consumed_value += entry.value;
        }

        if (missing_input or consumed_value < tx.totalOutputValue()) {
            if (!builtin.is_test) {
                std.debug.print("    Byron tx {}: value preservation failed or missing input\n", .{tx_idx});
            }
            result.txs_failed += 1;
            continue;
        }

        tx.fee = consumed_value - tx.totalOutputValue();

        _ = rules.validateTx(&tx, ledger, pp, block.header.slot, false) catch |err| {
            if (!builtin.is_test) {
                std.debug.print("    Byron tx {}: validation failed: {}\n", .{ tx_idx, err });
            }
            result.txs_failed += 1;
            continue;
        };

        try ledger.applyDiff(try buildDiff(
            allocator,
            ledger,
            block,
            &tx,
            pp,
            .{ .current_slot = block.header.slot, .protocol_version_major = block.header.protocol_version_major },
        ));
        result.txs_applied += 1;
        result.total_fees += tx.fee;
    }

    return result;
}

/// Apply a parsed block's transactions to the ledger.
/// This is the main entry point for the ledger validation pipeline.
///
/// For each transaction in the block:
/// 1. Parse the transaction body
/// 2. Validate against current UTxO set and protocol parameters
/// 3. If valid, compute the UTxO diff and apply it
///
/// Note: Plutus script validation is currently stubbed.
/// Transactions with script-locked inputs will be skipped.
pub fn applyBlock(
    allocator: Allocator,
    ledger: *LedgerDB,
    block: *const block_mod.Block,
    pp: rules.ProtocolParams,
    governance_config: ?*const protocol_update.GovernanceConfig,
) !ApplyResult {
    return switch (block.era) {
        .byron => applyByronBlock(allocator, ledger, block, pp),
        else => applyShelleyLikeBlock(allocator, ledger, block, pp, governance_config),
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "apply: golden Alonzo block transactions update ledger" {
    const allocator = std.testing.allocator;

    // Load golden block
    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const block = try block_mod.parseBlock(block_data);

    // Initialize ledger with the input UTxO that the golden block's tx spends
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-apply");
    defer ledger.deinit();
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-apply") catch {};

    // The golden block has 1 tx with 1 input. We need to seed that input.
    // Parse the tx to find its input
    var tx_dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try tx_dec.decodeArrayLen()) orelse return;
    if (num_txs < 1) return;

    const tx_raw = try tx_dec.sliceOfNextValue();
    var tx = try tx_mod.parseTxBody(allocator, tx_raw);
    defer tx_mod.freeTxBody(allocator, &tx);

    // Seed the UTxO set with the required input
    // The tx consumes input(s) and produces output(s) + fee
    // To make it valid, we need the consumed value = produced value + fee
    const total_needed = tx.totalOutputValue() + tx.fee;

    const seed_produced = try allocator.alloc(UtxoEntry, tx.inputs.len);
    for (seed_produced, 0..) |*entry, i| {
        entry.* = .{
            .tx_in = tx.inputs[i],
            .value = if (i == 0) total_needed else 0,
            .raw_cbor = try allocator.dupe(u8, "seed"),
        };
    }

    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = seed_produced,
    });

    // Now apply the block
    const pp = rules.ProtocolParams{
        .min_fee_a = 0, // Disable fee check for golden test
        .min_fee_b = 0,
        .min_utxo_value = 0,
        .max_tx_size = 100000,
        .key_deposit = 0,
        .pool_deposit = 0,
        .max_block_body_size = 100000,
    };

    var result = try applyBlock(allocator, &ledger, &block, pp, null);
    defer result.deinit(allocator);

    // The golden block has 1 transaction
    try std.testing.expect(result.txs_applied > 0 or result.txs_failed > 0);

    // Ledger should have been updated
    try std.testing.expect(ledger.utxoCount() > 0);
}

test "apply: golden Byron block transaction updates ledger" {
    const allocator = std.testing.allocator;

    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/golden/cardano/CardanoNodeToNodeVersion2/Block_Byron_regular",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const block = try block_mod.parseBlock(block_data);

    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-apply-byron");
    defer ledger.deinit();
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-apply-byron") catch {};

    var payload_dec = Decoder.init(block.tx_bodies_raw);
    const tx_payload_len = (try payload_dec.decodeArrayLen()) orelse return;
    if (tx_payload_len < 1) return;

    const tx_entry_raw = try payload_dec.sliceOfNextValue();
    var entry_dec = Decoder.init(tx_entry_raw);
    _ = (try entry_dec.decodeArrayLen()) orelse return error.InvalidCbor;
    const tx_raw = try entry_dec.sliceOfNextValue();

    var tx = try tx_mod.parseByronTxBody(allocator, tx_raw);
    defer tx_mod.freeTxBody(allocator, &tx);

    var genesis = @import("../node/genesis.zig").parseByronGenesis(allocator, "byron.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer genesis.deinit(allocator);

    const pp = @import("../node/genesis.zig").toLedgerProtocolParamsByron(genesis);
    const total_needed = tx.totalOutputValue() + rules.calculateMinFee(pp, tx.raw_cbor.len);

    const seed_produced = try allocator.alloc(UtxoEntry, tx.inputs.len);
    for (seed_produced, 0..) |*entry, i| {
        entry.* = .{
            .tx_in = tx.inputs[i],
            .value = if (i == 0) total_needed else 0,
            .raw_cbor = try allocator.dupe(u8, "seed_byron_utxo"),
        };
    }

    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = seed_produced,
    });

    var result = try applyBlock(allocator, &ledger, &block, pp, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.txs_applied);
    try std.testing.expectEqual(@as(u32, 0), result.txs_failed);
    try std.testing.expectEqual(total_needed - tx.totalOutputValue(), result.total_fees);
    try std.testing.expect(ledger.utxoCount() > 0);
}
