const std = @import("std");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const TxId = types.TxId;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const Hash32 = types.Hash32;
pub const Hash28 = types.Hash28;

/// A parsed transaction output (simplified for Phase 3).
pub const TxOut = struct {
    address_raw: []const u8, // raw address bytes
    value: Coin, // lovelace amount (multi-asset deferred)
    datum_hash: ?Hash32, // Alonzo+ datum hash
    raw_cbor: []const u8, // original CBOR for byte-preserving hashing
};

/// A parsed transaction body (common fields across eras).
pub const TxBody = struct {
    tx_id: TxId, // Blake2b-256 of raw CBOR body
    inputs: []const TxIn,
    outputs: []const TxOut,
    fee: Coin,
    ttl: ?u64, // Shelley time-to-live
    validity_start: ?u64, // Allegra+ validity interval start
    raw_cbor: []const u8, // original CBOR for hashing

    /// Total output value.
    pub fn totalOutputValue(self: *const TxBody) Coin {
        var total: Coin = 0;
        for (self.outputs) |out| {
            total += out.value;
        }
        return total;
    }
};

/// Parse a transaction body from CBOR (map-encoded, Shelley+ format).
/// Transaction bodies are CBOR maps with integer keys.
pub fn parseTxBody(allocator: std.mem.Allocator, data: []const u8) !TxBody {
    const tx_id = Blake2b256.hash(data);
    var dec = Decoder.init(data);

    const map_len = try dec.decodeMapLen() orelse return error.InvalidCbor;

    var inputs: std.ArrayList(TxIn) = .empty;
    defer inputs.deinit(allocator);
    var outputs: std.ArrayList(TxOut) = .empty;
    defer outputs.deinit(allocator);
    var fee: Coin = 0;
    var ttl: ?u64 = null;
    var validity_start: ?u64 = null;

    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        const key = try dec.decodeUint();

        switch (key) {
            0 => {
                // Inputs: set/array of [tx_hash, tx_ix]
                const input_container = try dec.peekMajorType();
                var num_inputs: u64 = 0;

                if (input_container == 6) {
                    // Tagged set (#6.258)
                    _ = try dec.decodeTag();
                    num_inputs = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
                } else {
                    num_inputs = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
                }

                var j: u64 = 0;
                while (j < num_inputs) : (j += 1) {
                    _ = try dec.decodeArrayLen(); // [txid, ix]
                    const txid_bytes = try dec.decodeBytes();
                    if (txid_bytes.len != 32) return error.InvalidCbor;
                    var txid: TxId = undefined;
                    @memcpy(&txid, txid_bytes);
                    const ix = @as(u16, @intCast(try dec.decodeUint()));
                    try inputs.append(allocator, .{ .tx_id = txid, .tx_ix = ix });
                }
            },
            1 => {
                // Outputs: array of outputs
                const num_outputs = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
                var j: u64 = 0;
                while (j < num_outputs) : (j += 1) {
                    const out_raw = try dec.sliceOfNextValue();
                    const out = try parseOutput(out_raw);
                    try outputs.append(allocator, .{
                        .address_raw = out.address_raw,
                        .value = out.value,
                        .datum_hash = out.datum_hash,
                        .raw_cbor = out_raw,
                    });
                }
            },
            2 => {
                // Fee
                fee = try dec.decodeUint();
            },
            3 => {
                // TTL (Shelley)
                ttl = try dec.decodeUint();
            },
            8 => {
                // Validity interval start (Allegra+)
                validity_start = try dec.decodeUint();
            },
            else => {
                // Skip unknown fields (certificates, withdrawals, etc.)
                try dec.skipValue();
            },
        }
    }

    return .{
        .tx_id = tx_id,
        .inputs = try inputs.toOwnedSlice(allocator),
        .outputs = try outputs.toOwnedSlice(allocator),
        .fee = fee,
        .ttl = ttl,
        .validity_start = validity_start,
        .raw_cbor = data,
    };
}

/// Parse a single transaction output.
fn parseOutput(data: []const u8) !TxOut {
    var dec = Decoder.init(data);
    const first = try dec.peekMajorType();

    if (first == 4) {
        // Array format: [address, value] or [address, value, datum_hash]
        const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
        const address_raw = try dec.decodeBytes();
        const value = try parseValue(&dec);
        var datum_hash: ?Hash32 = null;
        if (arr_len >= 3) {
            const dh = try dec.decodeBytes();
            if (dh.len == 32) {
                datum_hash = dh[0..32].*;
            }
        }
        return .{
            .address_raw = address_raw,
            .value = value,
            .datum_hash = datum_hash,
            .raw_cbor = data,
        };
    } else if (first == 5) {
        // Map format (Babbage+): {0: address, 1: value, ?2: datum, ?3: script_ref}
        const map_len = (try dec.decodeMapLen()) orelse return error.InvalidCbor;
        var address_raw: []const u8 = &[_]u8{};
        var value: Coin = 0;
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const k = try dec.decodeUint();
            switch (k) {
                0 => address_raw = try dec.decodeBytes(),
                1 => value = try parseValue(&dec),
                2 => try dec.skipValue(), // datum option
                3 => try dec.skipValue(), // script ref
                else => try dec.skipValue(),
            }
        }
        return .{
            .address_raw = address_raw,
            .value = value,
            .datum_hash = null,
            .raw_cbor = data,
        };
    }

    return error.InvalidCbor;
}

/// Parse a Value — either Coin (uint) or [Coin, MultiAsset].
fn parseValue(dec: *Decoder) !Coin {
    const major = try dec.peekMajorType();
    if (major == 0) {
        // Simple coin
        return try dec.decodeUint();
    } else if (major == 4) {
        // [coin, multi_asset] — extract coin, skip multi-asset
        _ = try dec.decodeArrayLen();
        const coin = try dec.decodeUint();
        try dec.skipValue(); // multi-asset map
        return coin;
    }
    return error.InvalidCbor;
}

/// Free a parsed TxBody's owned memory.
pub fn freeTxBody(allocator: std.mem.Allocator, body: *TxBody) void {
    allocator.free(body.inputs);
    allocator.free(body.outputs);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "transaction: parse Alonzo golden tx body" {
    const allocator = std.testing.allocator;

    // Load the real Alonzo block and extract the first tx body
    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    // Parse block to get tx_bodies_raw
    const block_mod = @import("block.zig");
    const block = try block_mod.parseBlock(block_data);

    // tx_bodies_raw is an array of tx bodies
    var dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try dec.decodeArrayLen()) orelse return;

    try std.testing.expect(num_txs >= 1);

    // Parse first tx body
    const first_tx_raw = try dec.sliceOfNextValue();
    var tx = try parseTxBody(allocator, first_tx_raw);
    defer freeTxBody(allocator, &tx);

    // Verify tx has inputs and outputs
    try std.testing.expect(tx.inputs.len >= 1);
    try std.testing.expect(tx.outputs.len >= 1);
    try std.testing.expect(tx.fee > 0);

    // TxId should be 32 bytes (Blake2b-256 of body CBOR)
    try std.testing.expectEqual(@as(usize, 32), tx.tx_id.len);

    // CRITICAL: Verify TxId matches Python-computed value from original bytes
    // Python: hashlib.blake2b(raw_tx_body_bytes, digest_size=32).hexdigest()
    //       = "ad8033bc3f0da247fb074361ad195cafd5b8bda105319325450f19d06723200a"
    const expected_txid = [_]u8{
        0xad, 0x80, 0x33, 0xbc, 0x3f, 0x0d, 0xa2, 0x47,
        0xfb, 0x07, 0x43, 0x61, 0xad, 0x19, 0x5c, 0xaf,
        0xd5, 0xb8, 0xbd, 0xa1, 0x05, 0x31, 0x93, 0x25,
        0x45, 0x0f, 0x19, 0xd0, 0x67, 0x23, 0x20, 0x0a,
    };
    try std.testing.expectEqualSlices(u8, &expected_txid, &tx.tx_id);
}

test "transaction: golden Alonzo tx fields match Python analysis" {
    const allocator = std.testing.allocator;

    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const block_mod = @import("block.zig");
    const block = try block_mod.parseBlock(block_data);

    var dec = Decoder.init(block.tx_bodies_raw);
    const num_txs = (try dec.decodeArrayLen()) orelse return;
    try std.testing.expectEqual(@as(u64, 1), num_txs); // Golden block has exactly 1 tx

    const first_tx_raw = try dec.sliceOfNextValue();
    var tx = try parseTxBody(allocator, first_tx_raw);
    defer freeTxBody(allocator, &tx);

    // From Python analysis of the golden block:
    // Inputs: 1 input — [ee155ace9c40292074cb6aff8c9ccdd273c81648ff1149ef36bcea6ebb8a3e25, 0]
    try std.testing.expectEqual(@as(usize, 1), tx.inputs.len);
    const expected_input_txid = [_]u8{
        0xee, 0x15, 0x5a, 0xce, 0x9c, 0x40, 0x29, 0x20,
        0x74, 0xcb, 0x6a, 0xff, 0x8c, 0x9c, 0xcd, 0xd2,
        0x73, 0xc8, 0x16, 0x48, 0xff, 0x11, 0x49, 0xef,
        0x36, 0xbc, 0xea, 0x6e, 0xbb, 0x8a, 0x3e, 0x25,
    };
    try std.testing.expectEqualSlices(u8, &expected_input_txid, &tx.inputs[0].tx_id);
    try std.testing.expectEqual(@as(u16, 0), tx.inputs[0].tx_ix);

    // Outputs: 1 output with multi-asset value
    try std.testing.expectEqual(@as(usize, 1), tx.outputs.len);
    // The output value includes ADA (100 lovelace) + native token
    // Python shows: value=[100, {policy => {name => 1000}}]
    // Our parser extracts just the coin part for now
    try std.testing.expectEqual(@as(Coin, 100), tx.outputs[0].value);

    // Fee: 999
    try std.testing.expectEqual(@as(Coin, 999), tx.fee);
}

test "transaction: total output value" {
    const allocator = std.testing.allocator;

    // Construct a minimal tx body CBOR manually
    // {0: [[txid, 0]], 1: [[addr, 1000000], [addr, 2000000]], 2: 200000}
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    try enc.encodeMapLen(3);

    // Key 0: inputs
    try enc.encodeUint(0);
    try enc.encodeArrayLen(1);
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&([_]u8{0xaa} ** 32));
    try enc.encodeUint(0);

    // Key 1: outputs
    try enc.encodeUint(1);
    try enc.encodeArrayLen(2);
    // Output 1
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&([_]u8{0x61} ++ [_]u8{0xbb} ** 28)); // enterprise address
    try enc.encodeUint(1_000_000);
    // Output 2
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&([_]u8{0x61} ++ [_]u8{0xcc} ** 28));
    try enc.encodeUint(2_000_000);

    // Key 2: fee
    try enc.encodeUint(2);
    try enc.encodeUint(200_000);

    var tx = try parseTxBody(allocator, enc.getWritten());
    defer freeTxBody(allocator, &tx);

    try std.testing.expectEqual(@as(usize, 1), tx.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), tx.outputs.len);
    try std.testing.expectEqual(@as(Coin, 200_000), tx.fee);
    try std.testing.expectEqual(@as(Coin, 3_000_000), tx.totalOutputValue());
}
