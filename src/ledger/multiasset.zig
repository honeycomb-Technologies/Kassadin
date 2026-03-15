const std = @import("std");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const Encoder = @import("../cbor/encoder.zig").Encoder;
const types = @import("../types.zig");

pub const PolicyId = types.PolicyId; // 28-byte script hash
pub const Coin = types.Coin;

/// An asset name (0-32 bytes).
pub const AssetName = struct {
    data: [32]u8,
    len: u6,

    pub fn fromSlice(s: []const u8) !AssetName {
        if (s.len > 32) return error.AssetNameTooLong;
        var an = AssetName{ .data = [_]u8{0} ** 32, .len = @intCast(s.len) };
        @memcpy(an.data[0..s.len], s);
        return an;
    }

    pub fn toSlice(self: *const AssetName) []const u8 {
        return self.data[0..self.len];
    }
};

/// A single asset within a policy.
pub const Asset = struct {
    name: AssetName,
    quantity: i64, // positive for minting/outputs, negative for burning
};

/// Assets grouped under a single policy ID.
pub const PolicyAssets = struct {
    policy_id: PolicyId,
    assets: []const Asset,
};

/// Multi-asset value: Coin + optional multi-asset bundle.
/// Used from Mary era onwards.
pub const Value = struct {
    coin: Coin,
    multi_assets: []const PolicyAssets, // empty for coin-only

    /// Total lovelace in this value.
    pub fn lovelace(self: *const Value) Coin {
        return self.coin;
    }

    /// Check if this value contains only lovelace (no native tokens).
    pub fn isCoinOnly(self: *const Value) bool {
        return self.multi_assets.len == 0;
    }
};

/// Parse a Value from CBOR.
/// Coin-only: uint
/// Multi-asset: [coin, {policy_id => {asset_name => quantity}}]
pub fn parseValue(allocator: Allocator, dec: *Decoder) !Value {
    const major = try dec.peekMajorType();

    if (major == 0) {
        // Coin-only
        return .{
            .coin = try dec.decodeUint(),
            .multi_assets = &[_]PolicyAssets{},
        };
    } else if (major == 4) {
        // [coin, multi_asset_map]
        _ = try dec.decodeArrayLen(); // array(2)
        const coin = try dec.decodeUint();

        // Parse multi-asset map: {policy_id => {asset_name => quantity}}
        const num_policies = (try dec.decodeMapLen()) orelse return error.InvalidCbor;

        var policies = try allocator.alloc(PolicyAssets, @intCast(num_policies));
        var p_idx: usize = 0;

        var pi: u64 = 0;
        while (pi < num_policies) : (pi += 1) {
            // Policy ID: bytes(28)
            const pid_bytes = try dec.decodeBytes();
            if (pid_bytes.len != 28) return error.InvalidCbor;
            var policy_id: PolicyId = undefined;
            @memcpy(&policy_id, pid_bytes);

            // Assets map: {asset_name => quantity}
            const num_assets = (try dec.decodeMapLen()) orelse return error.InvalidCbor;
            var assets = try allocator.alloc(Asset, @intCast(num_assets));

            var ai: u64 = 0;
            while (ai < num_assets) : (ai += 1) {
                const name_bytes = try dec.decodeBytes();
                const name = try AssetName.fromSlice(name_bytes);
                const quantity = try dec.decodeInt();
                assets[ai] = .{
                    .name = name,
                    .quantity = @intCast(quantity),
                };
                ai = ai; // suppress unused
            }

            policies[p_idx] = .{
                .policy_id = policy_id,
                .assets = assets,
            };
            p_idx += 1;
        }

        return .{
            .coin = coin,
            .multi_assets = policies,
        };
    }

    return error.InvalidCbor;
}

/// Free a parsed Value's owned memory.
pub fn freeValue(allocator: Allocator, value: *Value) void {
    for (value.multi_assets) |pa| {
        allocator.free(pa.assets);
    }
    if (value.multi_assets.len > 0) {
        allocator.free(value.multi_assets);
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "multiasset: parse coin-only value" {
    const enc_alloc = std.testing.allocator;
    var enc = Encoder.init(enc_alloc);
    defer enc.deinit();
    try enc.encodeUint(5_000_000);

    var dec = Decoder.init(enc.getWritten());
    var val = try parseValue(std.testing.allocator, &dec);
    defer freeValue(std.testing.allocator, &val);

    try std.testing.expectEqual(@as(Coin, 5_000_000), val.coin);
    try std.testing.expect(val.isCoinOnly());
}

test "multiasset: parse coin + single policy with one asset" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // [2000000, {policy_id(28) => {"TokenA" => 100}}]
    try enc.encodeArrayLen(2);
    try enc.encodeUint(2_000_000);
    try enc.encodeMapLen(1);
    try enc.encodeBytes(&([_]u8{0xaa} ** 28)); // policy_id
    try enc.encodeMapLen(1);
    try enc.encodeBytes("TokenA"); // asset name
    try enc.encodeUint(100); // quantity

    var dec = Decoder.init(enc.getWritten());
    var val = try parseValue(allocator, &dec);
    defer freeValue(allocator, &val);

    try std.testing.expectEqual(@as(Coin, 2_000_000), val.coin);
    try std.testing.expect(!val.isCoinOnly());
    try std.testing.expectEqual(@as(usize, 1), val.multi_assets.len);
    try std.testing.expectEqual(@as(usize, 1), val.multi_assets[0].assets.len);
    try std.testing.expectEqualSlices(u8, "TokenA", val.multi_assets[0].assets[0].name.toSlice());
    try std.testing.expectEqual(@as(i64, 100), val.multi_assets[0].assets[0].quantity);
}

test "multiasset: parse multiple policies" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // [1000000, {pid1 => {"A" => 50}, pid2 => {"B" => 200, "C" => 300}}]
    try enc.encodeArrayLen(2);
    try enc.encodeUint(1_000_000);
    try enc.encodeMapLen(2);

    // Policy 1
    try enc.encodeBytes(&([_]u8{0x11} ** 28));
    try enc.encodeMapLen(1);
    try enc.encodeBytes("A");
    try enc.encodeUint(50);

    // Policy 2
    try enc.encodeBytes(&([_]u8{0x22} ** 28));
    try enc.encodeMapLen(2);
    try enc.encodeBytes("B");
    try enc.encodeUint(200);
    try enc.encodeBytes("C");
    try enc.encodeUint(300);

    var dec = Decoder.init(enc.getWritten());
    var val = try parseValue(allocator, &dec);
    defer freeValue(allocator, &val);

    try std.testing.expectEqual(@as(Coin, 1_000_000), val.coin);
    try std.testing.expectEqual(@as(usize, 2), val.multi_assets.len);
    try std.testing.expectEqual(@as(usize, 1), val.multi_assets[0].assets.len);
    try std.testing.expectEqual(@as(usize, 2), val.multi_assets[1].assets.len);
}
