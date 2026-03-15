const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bech32 encoding/decoding per BIP-173.
pub const Bech32 = struct {
    pub const Error = error{
        InvalidCharacter,
        InvalidChecksum,
        InvalidHrp,
        MixedCase,
        TooLong,
        InvalidPadding,
        InvalidSeparator,
        OutOfMemory,
    };

    const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    const generator = [5]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };

    fn charsetRevLookup(c: u8) ?u5 {
        for (charset, 0..) |ch, i| {
            if (ch == c) return @intCast(i);
        }
        return null;
    }

    fn polymod(values: []const u8) u32 {
        var chk: u32 = 1;
        for (values) |v| {
            const b: u32 = chk >> 25;
            chk = ((chk & 0x1ffffff) << 5) ^ @as(u32, v);
            for (0..5) |i| {
                if ((b >> @intCast(i)) & 1 == 1) {
                    chk ^= generator[i];
                }
            }
        }
        return chk;
    }

    fn hrpExpand(allocator: Allocator, hrp: []const u8) Error![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        for (hrp) |c| {
            try result.append(@intCast(c >> 5));
        }
        try result.append(0);
        for (hrp) |c| {
            try result.append(@intCast(c & 31));
        }
        return result.toOwnedSlice() catch return Error.OutOfMemory;
    }

    fn verifyChecksum(allocator: Allocator, hrp: []const u8, data: []const u8) Error!bool {
        const expanded = try hrpExpand(allocator, hrp);
        defer allocator.free(expanded);

        var values = std.ArrayList(u8).init(allocator);
        defer values.deinit();
        values.appendSlice(expanded) catch return Error.OutOfMemory;
        values.appendSlice(data) catch return Error.OutOfMemory;

        return polymod(values.items) == 1;
    }

    fn createChecksum(allocator: Allocator, hrp: []const u8, data: []const u8) Error![6]u8 {
        const expanded = try hrpExpand(allocator, hrp);
        defer allocator.free(expanded);

        var values = std.ArrayList(u8).init(allocator);
        defer values.deinit();
        values.appendSlice(expanded) catch return Error.OutOfMemory;
        values.appendSlice(data) catch return Error.OutOfMemory;
        values.appendSlice(&[_]u8{ 0, 0, 0, 0, 0, 0 }) catch return Error.OutOfMemory;

        const poly = polymod(values.items) ^ 1;
        var result: [6]u8 = undefined;
        for (0..6) |i| {
            result[i] = @intCast((poly >> @intCast(5 * (5 - i))) & 31);
        }
        return result;
    }

    /// Convert between bit widths. from_bits/to_bits are 1-8.
    pub fn convertBits(allocator: Allocator, data: []const u8, comptime from_bits: u4, comptime to_bits: u4, pad: bool) Error![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var acc: u32 = 0;
        var bits: u32 = 0;

        for (data) |value| {
            acc = (acc << from_bits) | @as(u32, value);
            bits += from_bits;
            while (bits >= to_bits) {
                bits -= to_bits;
                result.append(@intCast((acc >> @intCast(bits)) & ((1 << to_bits) - 1))) catch return Error.OutOfMemory;
            }
        }

        if (pad) {
            if (bits > 0) {
                result.append(@intCast((acc << @intCast(to_bits - bits)) & ((1 << to_bits) - 1))) catch return Error.OutOfMemory;
            }
        } else {
            if (bits >= from_bits) return Error.InvalidPadding;
            if ((acc << @intCast(to_bits - bits)) & ((1 << to_bits) - 1) != 0) return Error.InvalidPadding;
        }

        return result.toOwnedSlice() catch return Error.OutOfMemory;
    }

    /// Encode data with a human-readable prefix.
    pub fn encode(allocator: Allocator, hrp: []const u8, data: []const u8) Error![]u8 {
        if (hrp.len == 0 or hrp.len > 83) return Error.InvalidHrp;

        // Convert 8-bit data to 5-bit groups
        const converted = try convertBits(allocator, data, 8, 5, true);
        defer allocator.free(converted);

        const checksum = try createChecksum(allocator, hrp, converted);

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        // HRP (lowercase)
        for (hrp) |c| {
            result.append(std.ascii.toLower(c)) catch return Error.OutOfMemory;
        }
        // Separator
        result.append('1') catch return Error.OutOfMemory;
        // Data
        for (converted) |v| {
            result.append(charset[v]) catch return Error.OutOfMemory;
        }
        // Checksum
        for (checksum) |v| {
            result.append(charset[v]) catch return Error.OutOfMemory;
        }

        const total = result.items.len;
        if (total > 90) {
            result.deinit();
            return Error.TooLong;
        }

        return result.toOwnedSlice() catch return Error.OutOfMemory;
    }

    /// Decode a bech32 string. Returns HRP and data.
    pub fn decode(allocator: Allocator, input: []const u8) Error!struct { hrp: []u8, data: []u8 } {
        if (input.len > 90) return Error.TooLong;

        // Find separator (last '1')
        var sep_pos: ?usize = null;
        var has_lower = false;
        var has_upper = false;
        for (input, 0..) |c, i| {
            if (c == '1') sep_pos = i;
            if (std.ascii.isLower(c)) has_lower = true;
            if (std.ascii.isUpper(c)) has_upper = true;
        }
        if (has_lower and has_upper) return Error.MixedCase;

        const sep = sep_pos orelse return Error.InvalidSeparator;
        if (sep == 0) return Error.InvalidHrp;
        if (sep + 7 > input.len) return Error.InvalidChecksum; // need at least 6 checksum chars

        // Extract HRP (lowercase)
        const hrp = allocator.alloc(u8, sep) catch return Error.OutOfMemory;
        errdefer allocator.free(hrp);
        for (input[0..sep], 0..) |c, i| {
            hrp[i] = std.ascii.toLower(c);
        }

        // Extract data part (after separator, including checksum)
        var data_with_checksum = std.ArrayList(u8).init(allocator);
        defer data_with_checksum.deinit();
        for (input[sep + 1 ..]) |c| {
            const lower = std.ascii.toLower(c);
            const val = charsetRevLookup(lower) orelse return Error.InvalidCharacter;
            data_with_checksum.append(val) catch return Error.OutOfMemory;
        }

        // Verify checksum
        if (!try verifyChecksum(allocator, hrp, data_with_checksum.items)) {
            return Error.InvalidChecksum;
        }

        // Strip 6-byte checksum, convert 5-bit to 8-bit
        const data_5bit = data_with_checksum.items[0 .. data_with_checksum.items.len - 6];
        const data = try convertBits(allocator, data_5bit, 5, 8, false);

        return .{ .hrp = hrp, .data = data };
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "bech32: encode and decode round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    const encoded = try Bech32.encode(allocator, "test", &data);
    defer allocator.free(encoded);

    const decoded = try Bech32.decode(allocator, encoded);
    defer allocator.free(decoded.hrp);
    defer allocator.free(decoded.data);

    try std.testing.expectEqualSlices(u8, "test", decoded.hrp);
    try std.testing.expectEqualSlices(u8, &data, decoded.data);
}

test "bech32: 32-byte key round-trip with cardano prefix" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x42} ** 32;
    const encoded = try Bech32.encode(allocator, "addr_vk", &key);
    defer allocator.free(encoded);

    const decoded = try Bech32.decode(allocator, encoded);
    defer allocator.free(decoded.hrp);
    defer allocator.free(decoded.data);

    try std.testing.expectEqualSlices(u8, "addr_vk", decoded.hrp);
    try std.testing.expectEqualSlices(u8, &key, decoded.data);
}

test "bech32: empty data" {
    const allocator = std.testing.allocator;
    const encoded = try Bech32.encode(allocator, "a", &[_]u8{});
    defer allocator.free(encoded);

    const decoded = try Bech32.decode(allocator, encoded);
    defer allocator.free(decoded.hrp);
    defer allocator.free(decoded.data);

    try std.testing.expectEqualSlices(u8, "a", decoded.hrp);
    try std.testing.expectEqual(@as(usize, 0), decoded.data.len);
}

test "bech32: invalid checksum" {
    const allocator = std.testing.allocator;
    const encoded = try Bech32.encode(allocator, "test", &[_]u8{0x01});
    defer allocator.free(encoded);

    // Corrupt last character
    var corrupted = try allocator.alloc(u8, encoded.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, encoded);
    corrupted[corrupted.len - 1] = 'z';

    const result = Bech32.decode(allocator, corrupted);
    try std.testing.expectError(Bech32.Error.InvalidChecksum, result);
}

test "bech32: mixed case rejection" {
    const allocator = std.testing.allocator;
    const result = Bech32.decode(allocator, "Test1qqqqqfhkw0n");
    try std.testing.expectError(Bech32.Error.MixedCase, result);
}

test "bech32: various cardano hrp prefixes" {
    const allocator = std.testing.allocator;
    const prefixes = [_][]const u8{ "addr_vk", "addr_sk", "stake_vk", "stake_sk", "vrf_vk", "vrf_sk", "kes_vk", "kes_sk", "pool" };
    const data = [_]u8{0xab} ** 28;

    for (prefixes) |hrp| {
        const encoded = try Bech32.encode(allocator, hrp, &data);
        defer allocator.free(encoded);

        const decoded = try Bech32.decode(allocator, encoded);
        defer allocator.free(decoded.hrp);
        defer allocator.free(decoded.data);

        try std.testing.expectEqualSlices(u8, hrp, decoded.hrp);
        try std.testing.expectEqualSlices(u8, &data, decoded.data);
    }
}
