const std = @import("std");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const plutus = @import("plutus.zig");

pub const Hash32 = types.Hash32;

/// A VKey witness: [vkey(32), signature(64)]
pub const VKeyWitness = struct {
    vkey: [32]u8,
    signature: [64]u8,
};

/// Parsed redeemer from witness set.
pub const Redeemer = struct {
    tag: plutus.RedeemerTag,
    index: u32,
    data_raw: []const u8, // raw CBOR of PlutusData
    ex_units_mem: u64,
    ex_units_steps: u64,
};

/// Parsed transaction witness set.
pub const WitnessSet = struct {
    vkey_witnesses: []const VKeyWitness,
    native_scripts_raw: ?[]const u8, // raw CBOR
    plutus_v1_scripts: []const []const u8, // flat-encoded scripts
    plutus_data: []const []const u8, // datums as raw CBOR
    redeemers: []const Redeemer,
    plutus_v2_scripts: []const []const u8,
    plutus_v3_scripts: []const []const u8,
};

/// Skip an optional CBOR tag 258 (set encoding) wrapper.
/// Conway-era uses #6.258([...]) for witness arrays.
fn skipSetTag(dec: *Decoder) void {
    const pos = dec.pos;
    if (dec.peekByte()) |b| {
        if (b >> 5 == 6) { // major type 6 = tag
            _ = dec.decodeTag() catch {
                dec.pos = pos;
                return;
            };
            return;
        }
    } else |_| {}
}

/// Decode array length, handling both definite and indefinite-length arrays.
/// For indefinite-length, returns null (caller must read until break).
fn decodeArrayLenFlex(dec: *Decoder) !?u64 {
    skipSetTag(dec);
    return dec.decodeArrayLen();
}

/// Parse a witness set from CBOR (map format).
/// Handles both definite and indefinite-length maps (Conway compatibility).
pub fn parseWitnessSet(allocator: Allocator, data: []const u8) !WitnessSet {
    var dec = Decoder.init(data);
    const map_len = try dec.decodeMapLen(); // null = indefinite

    var vkey_witnesses: std.ArrayList(VKeyWitness) = .empty;
    defer vkey_witnesses.deinit(allocator);
    var redeemers: std.ArrayList(Redeemer) = .empty;
    defer redeemers.deinit(allocator);
    var plutus_v1: std.ArrayList([]const u8) = .empty;
    defer plutus_v1.deinit(allocator);
    var plutus_data: std.ArrayList([]const u8) = .empty;
    defer plutus_data.deinit(allocator);

    var i: u64 = 0;
    while (if (map_len) |len| i < len else true) : (i += 1) {
        // For indefinite-length maps, check for break byte
        if (map_len == null) {
            if ((try dec.peekByte()) == 0xff) {
                dec.pos += 1;
                break;
            }
        }
        const key = try dec.decodeUint();
        switch (key) {
            0 => {
                // VKey witnesses: [*[vkey, sig]] or #6.258([*[vkey, sig]])
                const n = try decodeArrayLenFlex(&dec);
                var j: u64 = 0;
                while (if (n) |len| j < len else true) : (j += 1) {
                    if (n == null and (try dec.peekByte()) == 0xff) {
                        dec.pos += 1;
                        break;
                    }
                    _ = try dec.decodeArrayLen(); // [vkey, sig]
                    const vkey_bytes = try dec.decodeBytes();
                    const sig_bytes = try dec.decodeBytes();
                    if (vkey_bytes.len != 32 or sig_bytes.len != 64) return error.InvalidCbor;
                    try vkey_witnesses.append(allocator, .{
                        .vkey = vkey_bytes[0..32].*,
                        .signature = sig_bytes[0..64].*,
                    });
                }
            },
            3, 6, 7 => {
                // Plutus scripts (V1=3, V2=6, V3=7)
                const n = try decodeArrayLenFlex(&dec);
                var j: u64 = 0;
                while (if (n) |len| j < len else true) : (j += 1) {
                    if (n == null and (try dec.peekByte()) == 0xff) {
                        dec.pos += 1;
                        break;
                    }
                    const script_bytes = try dec.decodeBytes();
                    if (key == 3) try plutus_v1.append(allocator, script_bytes);
                }
            },
            4 => {
                // Plutus data (datums)
                const n = try decodeArrayLenFlex(&dec);
                var j: u64 = 0;
                while (if (n) |len| j < len else true) : (j += 1) {
                    if (n == null and (try dec.peekByte()) == 0xff) {
                        dec.pos += 1;
                        break;
                    }
                    const datum_raw = try dec.sliceOfNextValue();
                    try plutus_data.append(allocator, datum_raw);
                }
            },
            5 => {
                // Redeemers: array format [*[tag, index, data, ex_units]] (Alonzo-Babbage)
                // or map format {[tag, index] => [data, ex_units]} (Conway)
                const major = try dec.peekMajorType();
                if (major == 4 or major == 6) {
                    // Array format (possibly with set tag)
                    const n = try decodeArrayLenFlex(&dec);
                    var j: u64 = 0;
                    while (if (n) |len| j < len else true) : (j += 1) {
                        if (n == null and (try dec.peekByte()) == 0xff) {
                            dec.pos += 1;
                            break;
                        }
                        _ = try dec.decodeArrayLen(); // [tag, index, data, ex_units]
                        const tag_val = try dec.decodeUint();
                        const index = @as(u32, @intCast(try dec.decodeUint()));
                        const data_raw = try dec.sliceOfNextValue();
                        _ = try dec.decodeArrayLen(); // [mem, steps]
                        const mem = try dec.decodeUint();
                        const steps = try dec.decodeUint();

                        try redeemers.append(allocator, .{
                            .tag = @enumFromInt(@as(u8, @intCast(tag_val))),
                            .index = index,
                            .data_raw = data_raw,
                            .ex_units_mem = mem,
                            .ex_units_steps = steps,
                        });
                    }
                } else {
                    // Map format (Conway) — skip for now
                    try dec.skipValue();
                }
            },
            else => try dec.skipValue(),
        }
    }

    return .{
        .vkey_witnesses = try vkey_witnesses.toOwnedSlice(allocator),
        .native_scripts_raw = null,
        .plutus_v1_scripts = try plutus_v1.toOwnedSlice(allocator),
        .plutus_data = try plutus_data.toOwnedSlice(allocator),
        .redeemers = try redeemers.toOwnedSlice(allocator),
        .plutus_v2_scripts = &[_][]const u8{},
        .plutus_v3_scripts = &[_][]const u8{},
    };
}

pub fn freeWitnessSet(allocator: Allocator, ws: *WitnessSet) void {
    allocator.free(ws.vkey_witnesses);
    allocator.free(ws.redeemers);
    allocator.free(ws.plutus_v1_scripts);
    allocator.free(ws.plutus_data);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "witness: parse golden Alonzo witness set" {
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

    // Parse witness sets array
    var ws_dec = Decoder.init(block.tx_witnesses_raw);
    const n_ws = (try ws_dec.decodeArrayLen()) orelse return;
    try std.testing.expectEqual(@as(u64, 1), n_ws);

    const ws_raw = try ws_dec.sliceOfNextValue();
    var ws = try parseWitnessSet(allocator, ws_raw);
    defer freeWitnessSet(allocator, &ws);

    // From Python analysis:
    // 1 VKey witness: vkey=3b6a27bcceb6a42d..., sig=815671b581b4b02a...
    try std.testing.expectEqual(@as(usize, 1), ws.vkey_witnesses.len);
    // Verify first 8 bytes of VKey match Python
    const expected_vkey_prefix = [_]u8{ 0x3b, 0x6a, 0x27, 0xbc, 0xce, 0xb6, 0xa4, 0x2d };
    try std.testing.expectEqualSlices(u8, &expected_vkey_prefix, ws.vkey_witnesses[0].vkey[0..8]);

    // 1 redeemer: tag=0 (spend), index=0, ex_units=[5000, 5000]
    try std.testing.expectEqual(@as(usize, 1), ws.redeemers.len);
    try std.testing.expectEqual(plutus.RedeemerTag.spend, ws.redeemers[0].tag);
    try std.testing.expectEqual(@as(u32, 0), ws.redeemers[0].index);
    try std.testing.expectEqual(@as(u64, 5000), ws.redeemers[0].ex_units_mem);
    try std.testing.expectEqual(@as(u64, 5000), ws.redeemers[0].ex_units_steps);

    // 1 Plutus V1 script
    try std.testing.expectEqual(@as(usize, 1), ws.plutus_v1_scripts.len);

    // 1 Plutus datum
    try std.testing.expectEqual(@as(usize, 1), ws.plutus_data.len);
}
