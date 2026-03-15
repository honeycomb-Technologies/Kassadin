const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = @import("../crypto/ed25519.zig").Ed25519;
const KES = @import("../crypto/kes.zig").KES;
const VRF = @import("../crypto/vrf.zig").VRF;

/// Cardano key file format (TextEnvelope JSON).
/// Example:
/// {
///     "type": "StakePoolSigningKey_ed25519",
///     "description": "...",
///     "cborHex": "5820<hex-encoded-key>"
/// }
pub const KeyFile = struct {
    key_type: []const u8,
    description: []const u8,
    cbor_hex: []const u8,
};

/// Pool operator keys needed for block production.
pub const PoolKeys = struct {
    cold_sk: Ed25519.SignKey,
    cold_vk: Ed25519.VerKey,
    kes_sk: KES.SignKey,
    kes_vk: KES.VerKey,
    vrf_sk: VRF.SignKey,
    vrf_vk: VRF.VerKey,
};

/// Decode a hex string to bytes.
fn hexDecode(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const result = try allocator.alloc(u8, hex.len / 2);
    for (0..result.len) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidHex;
    }
    return result;
}

/// Extract the raw key bytes from a cborHex field.
/// The cborHex contains CBOR-encoded bytes: "5820" prefix for 32-byte keys,
/// "5840" for 64-byte keys, etc.
fn extractKeyBytes(allocator: Allocator, cbor_hex: []const u8) ![]u8 {
    const cbor = try hexDecode(allocator, cbor_hex);
    defer allocator.free(cbor);

    // CBOR byte string: first byte indicates length encoding
    if (cbor.len < 2) return error.InvalidKeyFile;

    const major = cbor[0] >> 5;
    if (major != 2) return error.InvalidKeyFile; // must be byte string

    const additional = cbor[0] & 0x1f;
    var key_start: usize = 1;
    var key_len: usize = 0;

    if (additional <= 23) {
        key_len = additional;
    } else if (additional == 24) {
        if (cbor.len < 2) return error.InvalidKeyFile;
        key_len = cbor[1];
        key_start = 2;
    } else if (additional == 25) {
        if (cbor.len < 3) return error.InvalidKeyFile;
        key_len = std.mem.readInt(u16, cbor[1..3], .big);
        key_start = 3;
    } else {
        return error.InvalidKeyFile;
    }

    if (key_start + key_len > cbor.len) return error.InvalidKeyFile;

    const result = try allocator.alloc(u8, key_len);
    @memcpy(result, cbor[key_start .. key_start + key_len]);
    return result;
}

/// Load an Ed25519 signing key from a TextEnvelope JSON file.
pub fn loadEd25519SignKey(allocator: Allocator, path: []const u8) !Ed25519.SignKey {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024);
    defer allocator.free(content);

    // Simple JSON parsing — find "cborHex" field
    const cbor_hex = findJsonField(content, "cborHex") orelse return error.InvalidKeyFile;
    const key_bytes = try extractKeyBytes(allocator, cbor_hex);
    defer allocator.free(key_bytes);

    if (key_bytes.len == 32) {
        // It's a seed — derive the full signing key
        const kp = try Ed25519.keyFromSeed(key_bytes[0..32].*);
        return kp.sk;
    } else if (key_bytes.len == 64) {
        return key_bytes[0..64].*;
    }

    return error.InvalidKeyFile;
}

/// Find a JSON string field value (simplified parser).
fn findJsonField(json: []const u8, field_name: []const u8) ?[]const u8 {
    // Look for "field_name": "value"
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(search);

    const field_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_field = json[field_pos + search.len ..];

    // Skip whitespace and colon
    var pos: usize = 0;
    while (pos < after_field.len and (after_field[pos] == ' ' or after_field[pos] == ':' or after_field[pos] == '\n' or after_field[pos] == '\r' or after_field[pos] == '\t')) {
        pos += 1;
    }

    if (pos >= after_field.len or after_field[pos] != '"') return null;
    pos += 1; // skip opening quote

    const value_start = pos;
    while (pos < after_field.len and after_field[pos] != '"') {
        pos += 1;
    }

    return after_field[value_start..pos];
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "keys: hex decode" {
    const allocator = std.testing.allocator;
    const bytes = try hexDecode(allocator, "48656c6c6f");
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "Hello", bytes);
}

test "keys: extract key bytes from cborHex" {
    const allocator = std.testing.allocator;
    // CBOR bytes(32): "5820" + 32 bytes of hex
    const cbor_hex = "5820" ++ "aa" ** 32;
    const key = try extractKeyBytes(allocator, cbor_hex);
    defer allocator.free(key);
    try std.testing.expectEqual(@as(usize, 32), key.len);
    try std.testing.expectEqual(@as(u8, 0xaa), key[0]);
}

test "keys: extract 64-byte key" {
    const allocator = std.testing.allocator;
    // CBOR bytes(64): "5840" + 64 bytes of hex
    const cbor_hex = "5840" ++ "bb" ** 64;
    const key = try extractKeyBytes(allocator, cbor_hex);
    defer allocator.free(key);
    try std.testing.expectEqual(@as(usize, 64), key.len);
}

test "keys: find JSON field" {
    const json =
        \\{
        \\    "type": "StakePoolSigningKey_ed25519",
        \\    "description": "Stake Pool Operator Key",
        \\    "cborHex": "5820abcdef0123456789"
        \\}
    ;
    const val = findJsonField(json, "cborHex");
    try std.testing.expect(val != null);
    try std.testing.expectEqualSlices(u8, "5820abcdef0123456789", val.?);

    const type_val = findJsonField(json, "type");
    try std.testing.expect(type_val != null);
    try std.testing.expectEqualSlices(u8, "StakePoolSigningKey_ed25519", type_val.?);
}
