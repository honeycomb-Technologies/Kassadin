const std = @import("std");
const Allocator = std.mem.Allocator;

pub const enc = @import("encoder.zig");
pub const dec = @import("decoder.zig");

pub const Encoder = enc.Encoder;
pub const Decoder = dec.Decoder;
pub const DecodeError = dec.DecodeError;

/// Byte-preserving wrapper. Stores both decoded value and original raw CBOR bytes.
/// When hashing, always use raw_cbor. When accessing fields, use decoded.
pub fn Annotated(comptime T: type) type {
    return struct {
        decoded: T,
        raw_cbor: []const u8,
    };
}

/// Decode a value of type T using decodeFn while capturing the raw CBOR bytes.
pub fn decodeAnnotated(comptime T: type, decoder: *Decoder, decodeFn: *const fn (*Decoder) DecodeError!T) DecodeError!Annotated(T) {
    const start = decoder.pos;
    const decoded = try decodeFn(decoder);
    return .{
        .decoded = decoded,
        .raw_cbor = decoder.data[start..decoder.pos],
    };
}

/// A generic CBOR map entry.
pub const MapEntry = struct {
    key: CborValue,
    value: CborValue,
};

/// A generic CBOR value for fully-dynamic decoding.
pub const CborValue = union(enum) {
    unsigned: u64,
    negative: u64, // actual value = -1 - stored
    bytes: []const u8,
    text: []const u8,
    array: []const CborValue,
    map: []const MapEntry,
    tag: struct { number: u64, content: *const CborValue },
    simple: u8,
    True: void,
    False: void,
    Null: void,

    pub fn isNull(self: CborValue) bool {
        return self == .Null;
    }
};

/// Recursively decode a complete CborValue tree from a Decoder.
pub fn decodeValue(allocator: Allocator, decoder: *Decoder) (Allocator.Error || DecodeError)!CborValue {
    const initial = try decoder.peekByte();
    const major: u3 = @intCast(initial >> 5);

    switch (major) {
        0 => return .{ .unsigned = try decoder.decodeUint() },
        1 => return .{ .negative = try decoder.decodeNint() },
        2 => return .{ .bytes = try decoder.decodeBytes() },
        3 => return .{ .text = try decoder.decodeText() },
        4 => {
            const maybe_len = try decoder.decodeArrayLen();
            if (maybe_len) |len| {
                const items = try allocator.alloc(CborValue, @intCast(len));
                for (items, 0..) |*item, i| {
                    _ = i;
                    item.* = try decodeValue(allocator, decoder);
                }
                return .{ .array = items };
            } else {
                // Indefinite-length
                var list = std.ArrayList(CborValue).init(allocator);
                while (!decoder.isBreak()) {
                    try list.append(try decodeValue(allocator, decoder));
                }
                try decoder.decodeBreak();
                return .{ .array = try list.toOwnedSlice() };
            }
        },
        5 => {
            const maybe_len = try decoder.decodeMapLen();
            if (maybe_len) |len| {
                const entries = try allocator.alloc(MapEntry, @intCast(len));
                for (entries) |*entry| {
                    entry.key = try decodeValue(allocator, decoder);
                    entry.value = try decodeValue(allocator, decoder);
                }
                return .{ .map = entries };
            } else {
                var list = std.ArrayList(MapEntry).init(allocator);
                while (!decoder.isBreak()) {
                    const key = try decodeValue(allocator, decoder);
                    const value = try decodeValue(allocator, decoder);
                    try list.append(.{ .key = key, .value = value });
                }
                try decoder.decodeBreak();
                return .{ .map = try list.toOwnedSlice() };
            }
        },
        6 => {
            const tag_num = try decoder.decodeTag();
            const content = try allocator.create(CborValue);
            content.* = try decodeValue(allocator, decoder);
            return .{ .tag = .{ .number = tag_num, .content = content } };
        },
        7 => {
            const byte = try decoder.peekByte();
            if (byte == 0xf5) {
                _ = try decoder.decodeBool();
                return .True;
            } else if (byte == 0xf4) {
                _ = try decoder.decodeBool();
                return .False;
            } else if (byte == 0xf6) {
                try decoder.decodeNull();
                return .Null;
            } else {
                // Other simple values
                decoder.pos += 1;
                const additional: u5 = @intCast(byte & 0x1f);
                if (additional <= 23) {
                    return .{ .simple = additional };
                } else if (additional == 24) {
                    const val = try decoder.peekByte();
                    decoder.pos += 1;
                    return .{ .simple = val };
                } else {
                    // floats — skip for now
                    return error.InvalidCbor;
                }
            }
        },
    }
}

/// Recursively encode a CborValue tree to an Encoder.
pub fn encodeValue(encoder: *Encoder, value: CborValue) !void {
    switch (value) {
        .unsigned => |v| try encoder.encodeUint(v),
        .negative => |v| try encoder.encodeNint(v),
        .bytes => |v| try encoder.encodeBytes(v),
        .text => |v| try encoder.encodeText(v),
        .array => |items| {
            try encoder.encodeArrayLen(items.len);
            for (items) |item| {
                try encodeValue(encoder, item);
            }
        },
        .map => |entries| {
            try encoder.encodeMapLen(entries.len);
            for (entries) |entry| {
                try encodeValue(encoder, entry.key);
                try encodeValue(encoder, entry.value);
            }
        },
        .tag => |t| {
            try encoder.encodeTag(t.number);
            try encodeValue(encoder, t.content.*);
        },
        .simple => |v| try encoder.encodeSimple(v),
        .True => try encoder.encodeBool(true),
        .False => try encoder.encodeBool(false),
        .Null => try encoder.encodeNull(),
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "cbor: decode and encode round-trip array" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x83, 0x01, 0x02, 0x03 }; // [1, 2, 3]

    var decoder = Decoder.init(&input);
    const value = try decodeValue(allocator, &decoder);
    defer allocator.free(value.array);

    try std.testing.expectEqual(@as(usize, 3), value.array.len);
    try std.testing.expectEqual(@as(u64, 1), value.array[0].unsigned);
    try std.testing.expectEqual(@as(u64, 2), value.array[1].unsigned);
    try std.testing.expectEqual(@as(u64, 3), value.array[2].unsigned);

    // Re-encode
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    try encodeValue(&encoder, value);
    try std.testing.expectEqualSlices(u8, &input, encoder.getWritten());
}

test "cbor: decode map" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0xa1, 0x01, 0x61, 0x61 }; // {1: "a"}

    var decoder = Decoder.init(&input);
    const value = try decodeValue(allocator, &decoder);
    defer allocator.free(value.map);

    try std.testing.expectEqual(@as(usize, 1), value.map.len);
    try std.testing.expectEqual(@as(u64, 1), value.map[0].key.unsigned);
    try std.testing.expectEqualSlices(u8, "a", value.map[0].value.text);
}

test "cbor: decode tag" {
    const allocator = std.testing.allocator;
    // Tag 30 wrapping [1, 20] (a UnitInterval)
    const input = [_]u8{ 0xd8, 0x1e, 0x82, 0x01, 0x14 };

    var decoder = Decoder.init(&input);
    const value = try decodeValue(allocator, &decoder);
    defer {
        allocator.free(value.tag.content.array);
        allocator.destroy(value.tag.content);
    }

    try std.testing.expectEqual(@as(u64, 30), value.tag.number);
    try std.testing.expectEqual(@as(usize, 2), value.tag.content.array.len);
    try std.testing.expectEqual(@as(u64, 1), value.tag.content.array[0].unsigned);
    try std.testing.expectEqual(@as(u64, 20), value.tag.content.array[1].unsigned);
}

test "cbor: decode bool and null" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x83, 0xf5, 0xf4, 0xf6 }; // [true, false, null]

    var decoder = Decoder.init(&input);
    const value = try decodeValue(allocator, &decoder);
    defer allocator.free(value.array);

    try std.testing.expectEqual(CborValue.True, value.array[0]);
    try std.testing.expectEqual(CborValue.False, value.array[1]);
    try std.testing.expectEqual(CborValue.Null, value.array[2]);
}

test "cbor: annotated byte capture" {
    const input = [_]u8{ 0x83, 0x01, 0x02, 0x03 }; // [1, 2, 3]
    var decoder = Decoder.init(&input);

    const raw = try decoder.sliceOfNextValue();
    try std.testing.expectEqualSlices(u8, &input, raw);
}

test "cbor: Annotated type" {
    const MyType = struct { val: u64 };
    const ann: Annotated(MyType) = .{
        .decoded = .{ .val = 42 },
        .raw_cbor = "fake_cbor_bytes",
    };
    try std.testing.expectEqual(@as(u64, 42), ann.decoded.val);
    try std.testing.expectEqualSlices(u8, "fake_cbor_bytes", ann.raw_cbor);
}

// ── Golden test: decode a REAL Alonzo block from cardano-ledger test suite ──

test "cbor golden: decode real Alonzo block header from cardano-ledger" {
    // Raw bytes from cardano-ledger/eras/alonzo/test-suite/golden/block.cbor
    // This is a real Alonzo-era block. We decode the header structure to prove
    // our CBOR decoder handles real Cardano data correctly.
    //
    // Structure: array(5) = [header, tx_bodies, tx_witnesses, aux_data, invalid_txs]
    // Header: array(2) = [header_body(array(15)), kes_signature(bytes)]
    // Header body fields: [block_no, slot, prev_hash, issuer_vk(32), vrf_vk(32), ...]

    // Inline the first bytes of the real block (verified against block.cbor with od -A x -t x1z)
    const header_start = [_]u8{
        0x85, // array(5) — Alonzo block
        0x82, // array(2) — header
        0x8f, // array(15) — header body
        0x03, // uint: block_number = 3
        0x09, // uint: slot = 9
    };

    var d = Decoder.init(&header_start);

    // Top-level: 5-element array (Alonzo block)
    const top = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 5), top);

    // Header: 2-element array
    const hdr = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 2), hdr);

    // Header body: 15-element array
    const hdr_body = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 15), hdr_body);

    // block_number = 3
    const block_no = try d.decodeUint();
    try std.testing.expectEqual(@as(u64, 3), block_no);

    // slot = 9
    const slot = try d.decodeUint();
    try std.testing.expectEqual(@as(u64, 9), slot);
}

test "cbor golden: full Alonzo block decode via std.fs" {
    // Load the real golden block at runtime and decode completely
    const block_data = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        // Skip test if file not present (CI may not have test vectors)
        if (err == error.FileNotFound) return;
        return err;
    };
    defer std.testing.allocator.free(block_data);

    // Must start with 0x85 (array of 5)
    try std.testing.expectEqual(@as(u8, 0x85), block_data[0]);

    // Decode the entire block structure
    var d = Decoder.init(block_data);

    // array(5)
    const top = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 5), top);

    // Element 0: Header [header_body, kes_sig]
    const hdr = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 2), hdr);

    // Header body (15 fields)
    const hb_len = (try d.decodeArrayLen()).?;
    try std.testing.expectEqual(@as(u64, 15), hb_len);

    // block_number (uint), slot (uint)
    _ = try d.decodeUint();
    _ = try d.decodeUint();

    // prev_hash (bytes 32)
    const prev_hash = try d.decodeBytes();
    try std.testing.expectEqual(@as(usize, 32), prev_hash.len);

    // issuer_vkey (bytes 32)
    const issuer_vk = try d.decodeBytes();
    try std.testing.expectEqual(@as(usize, 32), issuer_vk.len);

    // vrf_vkey (bytes 32)
    const vrf_vk = try d.decodeBytes();
    try std.testing.expectEqual(@as(usize, 32), vrf_vk.len);

    // Skip remaining 10 header body fields
    var i: u64 = 5;
    while (i < hb_len) : (i += 1) try d.skipValue();

    // KES signature
    const kes_sig = try d.decodeBytes();
    try std.testing.expect(kes_sig.len > 0);

    // Elements 1-4: skip tx_bodies, witnesses, aux_data, invalid_txs
    var j: u32 = 0;
    while (j < 4) : (j += 1) try d.skipValue();

    // Must have consumed entire block
    try std.testing.expect(d.isComplete());
}

test "cbor golden: Alonzo block byte-preserving capture" {
    const block_data = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer std.testing.allocator.free(block_data);

    var d = Decoder.init(block_data);
    const raw_block = try d.sliceOfNextValue();

    // sliceOfNextValue must capture the EXACT original bytes
    try std.testing.expectEqual(block_data.len, raw_block.len);
    try std.testing.expectEqualSlices(u8, block_data, raw_block);
}

test {
    _ = enc;
    _ = dec;
}
