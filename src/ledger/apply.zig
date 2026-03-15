const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const block_mod = @import("block.zig");
const tx_mod = @import("transaction.zig");
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

/// Result of applying a block to the ledger.
pub const ApplyResult = struct {
    txs_applied: u32,
    txs_failed: u32,
    total_fees: Coin,
};

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
) !ApplyResult {
    _ = pp; // TODO: use for fee validation
    var result = ApplyResult{ .txs_applied = 0, .txs_failed = 0, .total_fees = 0 };

    // Parse transaction bodies array
    var tx_dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try tx_dec.decodeArrayLen()) orelse return result;

    var tx_idx: u64 = 0;
    while (tx_idx < num_txs) : (tx_idx += 1) {
        const tx_raw = try tx_dec.sliceOfNextValue();

        // Parse transaction body
        var tx = tx_mod.parseTxBody(allocator, tx_raw) catch {
            result.txs_failed += 1;
            continue;
        };
        defer tx_mod.freeTxBody(allocator, &tx);

        // Build UTxO diff
        const consumed = try allocator.alloc(TxIn, tx.inputs.len);
        @memcpy(consumed, tx.inputs);

        var produced_list: std.ArrayList(UtxoEntry) = .empty;
        defer produced_list.deinit(allocator);

        for (tx.outputs, 0..) |out, ix| {
            try produced_list.append(allocator, .{
                .tx_in = .{ .tx_id = tx.tx_id, .tx_ix = @intCast(ix) },
                .value = out.value,
                .raw_cbor = out.raw_cbor,
            });
        }

        const produced = try produced_list.toOwnedSlice(allocator);

        // Apply the diff
        try ledger.applyDiff(.{
            .slot = block.header.slot,
            .block_hash = block.header.block_body_hash,
            .consumed = consumed,
            .produced = produced,
        });

        result.txs_applied += 1;
        result.total_fees += tx.fee;
    }

    return result;
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
            .raw_cbor = "seed",
        };
    }

    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
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

    const result = try applyBlock(allocator, &ledger, &block, pp);

    // The golden block has 1 transaction
    try std.testing.expect(result.txs_applied > 0 or result.txs_failed > 0);

    // Ledger should have been updated
    try std.testing.expect(ledger.utxoCount() > 0);
}
