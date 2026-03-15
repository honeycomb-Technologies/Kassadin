const std = @import("std");
const types = @import("../types.zig");
const transaction = @import("transaction.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;

pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const TxBody = transaction.TxBody;

/// Validation errors that can occur when applying a transaction.
pub const ValidationError = error{
    // UTxO rule violations
    InputNotInUtxo,
    InsufficientFee,
    ValueNotPreserved,
    NoInputs,
    OutputTooSmall,

    // Validity interval
    Expired,
    NotYetValid,

    // Size limits
    TxTooLarge,
};

/// Protocol parameters relevant to transaction validation.
pub const ProtocolParams = struct {
    min_fee_a: u64, // fee per byte
    min_fee_b: u64, // fixed fee component
    min_utxo_value: Coin, // minimum lovelace per UTxO
    max_tx_size: u32, // maximum transaction size in bytes
    key_deposit: Coin, // deposit for stake key registration
    pool_deposit: Coin, // deposit for pool registration
    max_block_body_size: u32,

    /// Mainnet defaults (approximate, for testing)
    pub const mainnet_defaults = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 1_000_000,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
    };
};

/// Calculate the minimum fee for a transaction.
/// fee = min_fee_b + (tx_size * min_fee_a)
pub fn calculateMinFee(pp: ProtocolParams, tx_size: usize) Coin {
    return pp.min_fee_b + (@as(u64, @intCast(tx_size)) * pp.min_fee_a);
}

/// Validate a transaction against the UTxO set and protocol parameters.
/// Returns the total consumed value on success.
pub fn validateTx(
    tx: *const TxBody,
    utxo: *const LedgerDB,
    pp: ProtocolParams,
    current_slot: u64,
) ValidationError!Coin {
    // 1. Must have at least one input
    if (tx.inputs.len == 0) return error.NoInputs;

    // 2. All inputs must exist in UTxO
    var consumed_value: Coin = 0;
    for (tx.inputs) |input| {
        const entry = utxo.lookupUtxo(input) orelse return error.InputNotInUtxo;
        consumed_value += entry.value;
    }

    // 3. Fee must meet minimum
    const min_fee = calculateMinFee(pp, tx.raw_cbor.len);
    if (tx.fee < min_fee) return error.InsufficientFee;

    // 4. Validity interval
    if (tx.ttl) |ttl| {
        if (current_slot >= ttl) return error.Expired;
    }
    if (tx.validity_start) |vs| {
        if (current_slot < vs) return error.NotYetValid;
    }

    // 5. Transaction size limit
    if (tx.raw_cbor.len > pp.max_tx_size) return error.TxTooLarge;

    // 6. All outputs must have minimum value
    for (tx.outputs) |output| {
        if (output.value < pp.min_utxo_value) return error.OutputTooSmall;
    }

    // 7. Preservation of value: consumed = produced + fee
    // consumed = sum of input values
    // produced = sum of output values + fee (+ deposits - refunds, simplified)
    const produced_value = tx.totalOutputValue() + tx.fee;
    if (consumed_value != produced_value) return error.ValueNotPreserved;

    return consumed_value;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "rules: minimum fee calculation" {
    const pp = ProtocolParams.mainnet_defaults;

    // 200-byte tx: 155381 + (200 * 44) = 155381 + 8800 = 164181
    const fee = calculateMinFee(pp, 200);
    try std.testing.expectEqual(@as(Coin, 164181), fee);

    // 0-byte tx: just the fixed component
    try std.testing.expectEqual(@as(Coin, 155381), calculateMinFee(pp, 0));
}

test "rules: validate simple tx — preservation of value" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules1");
    defer ledger.deinit();

    // Seed the UTxO set with one entry: 10 ADA
    const input_txin = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{
        .tx_in = input_txin,
        .value = 10_000_000,
        .raw_cbor = "seed_utxo",
    };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
        .produced = produced,
    });

    // Create a valid tx: spend 10 ADA → 8 ADA output + 2 ADA fee
    // (fee is very high but keeps the example simple)
    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input_txin},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xbb} ** 28),
                .value = 8_000_000,
                .datum_hash = null,
                .raw_cbor = "output",
            },
        },
        .fee = 2_000_000,
        .ttl = null,
        .validity_start = null,
        .raw_cbor = &[_]u8{0} ** 200, // fake 200-byte tx
    };

    const pp = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 1_000_000,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
    };

    const consumed = try validateTx(&tx, &ledger, pp, 100);
    try std.testing.expectEqual(@as(Coin, 10_000_000), consumed);
}

test "rules: reject tx with missing input" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules2");
    defer ledger.deinit();

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{.{ .tx_id = [_]u8{0xff} ** 32, .tx_ix = 0 }},
        .outputs = &[_]transaction.TxOut{},
        .fee = 200_000,
        .ttl = null,
        .validity_start = null,
        .raw_cbor = &[_]u8{0} ** 100,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100);
    try std.testing.expectError(error.InputNotInUtxo, result);
}

test "rules: reject tx with no inputs" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules3");
    defer ledger.deinit();

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .fee = 200_000,
        .ttl = null,
        .validity_start = null,
        .raw_cbor = &[_]u8{0} ** 100,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100);
    try std.testing.expectError(error.NoInputs, result);
}

test "rules: reject expired tx" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules4");
    defer ledger.deinit();

    // Seed UTxO
    const input = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = input, .value = 10_000_000, .raw_cbor = "x" };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
        .produced = produced,
    });

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input},
        .outputs = &[_]transaction.TxOut{},
        .fee = 10_000_000,
        .ttl = 50, // expires at slot 50
        .validity_start = null,
        .raw_cbor = &[_]u8{0} ** 200,
    };

    // Current slot = 100, TTL = 50 → expired
    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100);
    try std.testing.expectError(error.Expired, result);
}

test "rules: reject value not preserved" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules5");
    defer ledger.deinit();

    const input = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = input, .value = 10_000_000, .raw_cbor = "x" };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
        .produced = produced,
    });

    // Try to create 20 ADA from 10 ADA input
    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xbb} ** 28),
                .value = 19_000_000, // trying to create value
                .datum_hash = null,
                .raw_cbor = "bad_output",
            },
        },
        .fee = 1_000_000,
        .ttl = null,
        .validity_start = null,
        .raw_cbor = &[_]u8{0} ** 200,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100);
    try std.testing.expectError(error.ValueNotPreserved, result);
}
