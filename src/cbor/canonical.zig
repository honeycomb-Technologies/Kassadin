const std = @import("std");
const Allocator = std.mem.Allocator;
const enc = @import("encoder.zig");
const Encoder = enc.Encoder;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

/// RFC 7049 deterministic encoding for Cardano script_data_hash.
///
/// Rules:
/// 1. Integers use smallest possible encoding (already done by Encoder).
/// 2. All lengths are definite (no indefinite-length encoding).
/// 3. Map keys are sorted by: (a) serialized byte length ascending,
///    then (b) lexicographic byte order.

/// A pre-serialized key-value pair for canonical map encoding.
const SerializedEntry = struct {
    key_bytes: []const u8,
    value_bytes: []const u8,
};

/// Comparison function for canonical CBOR map key ordering (RFC 7049 Section 3.9).
/// Shorter serialized keys sort first; ties broken lexicographically.
fn canonicalKeyOrder(context: void, a: SerializedEntry, b: SerializedEntry) bool {
    _ = context;
    if (a.key_bytes.len != b.key_bytes.len) {
        return a.key_bytes.len < b.key_bytes.len;
    }
    return std.mem.order(u8, a.key_bytes, b.key_bytes) == .lt;
}

/// Encode a CBOR integer key and arbitrary pre-encoded value into a canonical map.
/// Keys are unsigned integers; values are pre-serialized CBOR byte slices.
///
/// `entries` is a slice of {key, value_bytes} pairs.
/// The output is a definite-length CBOR map with keys sorted canonically.
pub fn canonicalEncodeMap(
    allocator: Allocator,
    keys: []const u64,
    values: []const []const u8,
) ![]u8 {
    std.debug.assert(keys.len == values.len);

    // Serialize each key, pair with its value
    var serialized = try allocator.alloc(SerializedEntry, keys.len);
    defer {
        for (serialized) |entry| {
            allocator.free(@constCast(entry.key_bytes));
        }
        allocator.free(serialized);
    }

    for (keys, values, 0..) |key, value, i| {
        var key_enc = Encoder.init(allocator);
        errdefer key_enc.deinit();
        try key_enc.encodeUint(key);
        serialized[i] = .{
            .key_bytes = try key_enc.toOwnedSlice(),
            .value_bytes = value,
        };
    }

    // Sort by canonical key order
    std.mem.sort(SerializedEntry, serialized, {}, canonicalKeyOrder);

    // Build the output map
    var out = Encoder.init(allocator);
    errdefer out.deinit();

    try out.encodeMapLen(keys.len);
    for (serialized) |entry| {
        try out.writeRaw(entry.key_bytes);
        try out.writeRaw(entry.value_bytes);
    }

    return out.toOwnedSlice();
}

/// Encode a CBOR map from pre-serialized key-value byte pairs, sorted canonically.
/// Both keys and values are raw CBOR byte slices.
pub fn canonicalEncodeRawMap(
    allocator: Allocator,
    entries: []const SerializedEntry,
) ![]u8 {
    // Copy so we can sort without modifying the caller's slice
    const sorted = try allocator.alloc(SerializedEntry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);

    std.mem.sort(SerializedEntry, sorted, {}, canonicalKeyOrder);

    var out = Encoder.init(allocator);
    errdefer out.deinit();

    try out.encodeMapLen(entries.len);
    for (sorted) |entry| {
        try out.writeRaw(entry.key_bytes);
        try out.writeRaw(entry.value_bytes);
    }

    return out.toOwnedSlice();
}

/// Plutus language versions for cost model encoding.
pub const Language = enum(u8) {
    plutus_v1 = 0,
    plutus_v2 = 1,
    plutus_v3 = 2,
};

/// Encode cost model parameters for a single language into CBOR.
///
/// Per the Alonzo spec:
/// - PlutusV1: parameters encoded as an indefinite-length integer list,
///   then wrapped as a CBOR byte string (the byte string contains the
///   serialized indefinite-length list).
/// - PlutusV2/V3: parameters encoded as a definite-length integer list
///   (NOT wrapped in a byte string).
pub fn encodeCostModelParams(
    allocator: Allocator,
    language: Language,
    params: []const i64,
) ![]u8 {
    switch (language) {
        .plutus_v1 => {
            // Encode as indefinite-length array of integers
            var inner = Encoder.init(allocator);
            defer inner.deinit();

            try inner.encodeArrayIndef();
            for (params) |p| {
                try inner.encodeInt(p);
            }
            try inner.encodeBreak();

            // Wrap the serialized list as a CBOR byte string
            var out = Encoder.init(allocator);
            errdefer out.deinit();
            try out.encodeBytes(inner.getWritten());
            return out.toOwnedSlice();
        },
        .plutus_v2, .plutus_v3 => {
            // PlutusV2, PlutusV3: definite-length array of integers (no byte-string wrapping)
            var out = Encoder.init(allocator);
            errdefer out.deinit();

            try out.encodeArrayLen(params.len);
            for (params) |p| {
                try out.encodeInt(p);
            }
            return out.toOwnedSlice();
        },
    }
}

/// Encode the full language_views CBOR map for script_data_hash computation.
///
/// The language_views map is: { language_tag => cost_model_encoding }
/// Keys are sorted canonically (by serialized length, then lexicographic).
///
/// `cost_models` maps Language -> parameter slice. Only languages present
/// in the transaction's scripts are included.
pub fn encodeLanguageViews(
    allocator: Allocator,
    cost_models: []const LanguageCostModel,
) ![]u8 {
    if (cost_models.len == 0) {
        // Empty map
        var out = Encoder.init(allocator);
        errdefer out.deinit();
        try out.encodeMapLen(0);
        return out.toOwnedSlice();
    }

    var keys = try allocator.alloc(u64, cost_models.len);
    defer allocator.free(keys);

    var values = try allocator.alloc([]const u8, cost_models.len);
    defer {
        for (values[0..cost_models.len]) |v| {
            allocator.free(v);
        }
        allocator.free(values);
    }

    for (cost_models, 0..) |cm, i| {
        keys[i] = @intFromEnum(cm.language);
        values[i] = try encodeCostModelParams(allocator, cm.language, cm.params);
    }

    return canonicalEncodeMap(allocator, keys, values);
}

pub const LanguageCostModel = struct {
    language: Language,
    params: []const i64,
};

/// Compute the script_data_hash as defined in the Alonzo ledger spec:
///
///   script_data_hash = Blake2b-256(redeemers_cbor || datums_cbor || language_views_cbor)
///
/// All three inputs are pre-serialized CBOR byte slices.
/// - redeemers_cbor: CBOR encoding of the redeemers
/// - datums_cbor: CBOR encoding of the datums (or empty array 0x80 if none)
/// - language_views_cbor: canonically-encoded language views map
pub fn computeScriptDataHash(
    redeemers_cbor: []const u8,
    datums_cbor: []const u8,
    language_views_cbor: []const u8,
) [32]u8 {
    var state = Blake2b256.State.init();
    state.update(redeemers_cbor);
    state.update(datums_cbor);
    state.update(language_views_cbor);
    return state.final();
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "canonical: map keys sorted by length then lexicographic" {
    const allocator = std.testing.allocator;

    // Keys: 256 (2-byte encoding), 1 (1-byte), 1000 (2-byte encoding)
    // Sorted by serialized length:
    //   1 -> 0x01 (1 byte)
    //   256 -> 0x19 0x01 0x00 (3 bytes)
    //   1000 -> 0x19 0x03 0xe8 (3 bytes)
    // Among 3-byte keys: 0x19 0x01 0x00 < 0x19 0x03 0xe8 lexicographically
    const keys = [_]u64{ 256, 1, 1000 };
    const val_a = [_]u8{0xf5}; // true
    const val_b = [_]u8{0xf4}; // false
    const val_c = [_]u8{0xf6}; // null
    const values = [_][]const u8{ &val_a, &val_b, &val_c };

    const result = try canonicalEncodeMap(allocator, &keys, &values);
    defer allocator.free(result);

    // Expected: map(3) { 1: false, 256: true, 1000: null }
    // a3            map(3)
    // 01 f4         key=1, value=false
    // 19 01 00 f5   key=256, value=true
    // 19 03 e8 f6   key=1000, value=null
    const expected = [_]u8{
        0xa3, // map(3)
        0x01, 0xf4, // 1 -> false
        0x19, 0x01, 0x00, 0xf5, // 256 -> true
        0x19, 0x03, 0xe8, 0xf6, // 1000 -> null
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "canonical: single-entry map" {
    const allocator = std.testing.allocator;

    const keys = [_]u64{42};
    const val = [_]u8{ 0x63, 0x66, 0x6f, 0x6f }; // text "foo"
    const values = [_][]const u8{&val};

    const result = try canonicalEncodeMap(allocator, &keys, &values);
    defer allocator.free(result);

    // map(1) { 42: "foo" }
    // a1 18 2a 63 666f6f
    const expected = [_]u8{
        0xa1, // map(1)
        0x18, 0x2a, // key = 42
        0x63, 0x66, 0x6f, 0x6f, // value = "foo"
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "canonical: empty map" {
    const allocator = std.testing.allocator;

    const keys = [_]u64{};
    const values = [_][]const u8{};

    const result = try canonicalEncodeMap(allocator, &keys, &values);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, result);
}

test "canonical: integers are minimally encoded" {
    // The existing Encoder already uses minimal encoding.
    // Verify: 0 -> 1 byte, 23 -> 1 byte, 24 -> 2 bytes, 255 -> 2 bytes, 256 -> 3 bytes
    const allocator = std.testing.allocator;

    var e = Encoder.init(allocator);
    defer e.deinit();

    try e.encodeUint(0);
    try std.testing.expectEqual(@as(usize, 1), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(23);
    try std.testing.expectEqual(@as(usize, 1), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(24);
    try std.testing.expectEqual(@as(usize, 2), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(255);
    try std.testing.expectEqual(@as(usize, 2), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(256);
    try std.testing.expectEqual(@as(usize, 3), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(65535);
    try std.testing.expectEqual(@as(usize, 3), e.getWritten().len);

    e.data.clearRetainingCapacity();
    try e.encodeUint(65536);
    try std.testing.expectEqual(@as(usize, 5), e.getWritten().len);
}

test "canonical: PlutusV1 cost model encoded as indefinite list in byte string" {
    const allocator = std.testing.allocator;

    const params = [_]i64{ 10, -20, 300 };
    const result = try encodeCostModelParams(allocator, .plutus_v1, &params);
    defer allocator.free(result);

    // Inner: indefinite array [10, -20, 300]
    //   9f          begin indefinite array
    //   0a          uint 10
    //   33          nint 19 (i.e. -20 = -1 - 19)
    //   19 01 2c    uint 300
    //   ff          break
    // Outer: byte string of length 7 wrapping the above
    //   47          bytes(7)
    //   9f 0a 33 19 01 2c ff
    const expected = [_]u8{
        0x47, // bytes(7)
        0x9f, // begin indefinite array
        0x0a, // 10
        0x33, // -20 (nint: -1 - 19)
        0x19, 0x01, 0x2c, // 300
        0xff, // break
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "canonical: PlutusV2 cost model encoded as definite-length list" {
    const allocator = std.testing.allocator;

    const params = [_]i64{ 5, 10 };
    const result = try encodeCostModelParams(allocator, .plutus_v2, &params);
    defer allocator.free(result);

    // definite array of 2 integers, NOT wrapped in byte string
    //   82 05 0a
    const expected = [_]u8{
        0x82, // array(2)
        0x05, // 5
        0x0a, // 10
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "canonical: PlutusV3 cost model encoded as definite-length list" {
    const allocator = std.testing.allocator;

    const params = [_]i64{42};
    const result = try encodeCostModelParams(allocator, .plutus_v3, &params);
    defer allocator.free(result);

    const expected = [_]u8{
        0x81, // array(1)
        0x18, 0x2a, // 42
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

test "canonical: language views map ordering" {
    const allocator = std.testing.allocator;

    // PlutusV2 (key=1) and PlutusV1 (key=0)
    // Both keys serialize to 1 byte (0x00, 0x01), so they sort lexicographically.
    const v1_params = [_]i64{100};
    const v2_params = [_]i64{200};

    const cost_models = [_]LanguageCostModel{
        .{ .language = .plutus_v2, .params = &v2_params },
        .{ .language = .plutus_v1, .params = &v1_params },
    };

    const result = try encodeLanguageViews(allocator, &cost_models);
    defer allocator.free(result);

    // Map should have key 0 before key 1
    // Decode to verify ordering
    const cbor = @import("cbor.zig");
    var d = cbor.Decoder.init(result);
    const map_len = try d.decodeMapLen();
    try std.testing.expectEqual(@as(?u64, 2), map_len);

    // First key should be 0 (PlutusV1)
    const k0 = try d.decodeUint();
    try std.testing.expectEqual(@as(u64, 0), k0);
    // PlutusV1 value is a byte string
    _ = try d.decodeBytes();

    // Second key should be 1 (PlutusV2)
    const k1 = try d.decodeUint();
    try std.testing.expectEqual(@as(u64, 1), k1);
    // PlutusV2 value is a definite array
    const arr_len = try d.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 1), arr_len);
}

test "canonical: computeScriptDataHash basic" {
    // Verify that computeScriptDataHash produces a valid 32-byte Blake2b-256 hash
    // of the concatenation of its three inputs.

    // Simple inputs: redeemers = empty array, datums = empty array, lang views = empty map
    const redeemers = [_]u8{0x80}; // []
    const datums = [_]u8{0x80}; // []
    const lang_views = [_]u8{0xa0}; // {}

    const hash = computeScriptDataHash(&redeemers, &datums, &lang_views);

    // Verify it matches Blake2b-256 of the concatenation
    const concat = redeemers ++ datums ++ lang_views;
    const expected = Blake2b256.hash(&concat);

    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "canonical: computeScriptDataHash matches manual blake2b" {
    // Build a more realistic example and verify hash matches manual computation
    const allocator = std.testing.allocator;

    // Redeemers: array of 1 redeemer [tag=0, index=0, data=42, ex_units=[1000,2000]]
    var r_enc = Encoder.init(allocator);
    defer r_enc.deinit();
    try r_enc.encodeArrayLen(1);
    try r_enc.encodeArrayLen(4);
    try r_enc.encodeUint(0); // tag: spend
    try r_enc.encodeUint(0); // index
    try r_enc.encodeUint(42); // data (simplified)
    try r_enc.encodeArrayLen(2);
    try r_enc.encodeUint(1000); // mem
    try r_enc.encodeUint(2000); // steps

    // Datums: empty array
    const datums = [_]u8{0x80};

    // Language views: PlutusV2 with some params
    const v2_params = [_]i64{ 100, 200, 300 };
    const cost_models = [_]LanguageCostModel{
        .{ .language = .plutus_v2, .params = &v2_params },
    };
    const lang_views = try encodeLanguageViews(allocator, &cost_models);
    defer allocator.free(lang_views);

    const hash = computeScriptDataHash(r_enc.getWritten(), &datums, lang_views);

    // Verify via manual Blake2b-256
    var state = Blake2b256.State.init();
    state.update(r_enc.getWritten());
    state.update(&datums);
    state.update(lang_views);
    const expected = state.final();

    try std.testing.expectEqualSlices(u8, &expected, &hash);
    // And verify it's 32 bytes
    try std.testing.expectEqual(@as(usize, 32), hash.len);
}

test "canonical: map keys with same length sorted lexicographically" {
    const allocator = std.testing.allocator;

    // Keys 5, 3, 4 all encode to 1 byte. Should sort as 3, 4, 5.
    const keys = [_]u64{ 5, 3, 4 };
    const val_a = [_]u8{0x01};
    const val_b = [_]u8{0x02};
    const val_c = [_]u8{0x03};
    const values = [_][]const u8{ &val_a, &val_b, &val_c };

    const result = try canonicalEncodeMap(allocator, &keys, &values);
    defer allocator.free(result);

    // Expected: map(3) { 3: 0x02, 4: 0x03, 5: 0x01 }
    const expected = [_]u8{
        0xa3, // map(3)
        0x03, 0x02, // 3 -> 0x02
        0x04, 0x03, // 4 -> 0x03
        0x05, 0x01, // 5 -> 0x01
    };
    try std.testing.expectEqualSlices(u8, &expected, result);
}
