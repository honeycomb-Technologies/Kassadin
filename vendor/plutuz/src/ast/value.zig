//! Value type for Plutus multi-asset ledger values.
//! A Value is a sorted map of maps: CurrencySymbol(ByteString) -> TokenName(ByteString) -> Quantity(Integer).

const std = @import("std");
const PlutusData = @import("../data/plutus_data.zig").PlutusData;
const PlutusDataPair = @import("../data/plutus_data.zig").PlutusDataPair;
const Integer = std.math.big.int.Managed;
const Limb = std.math.big.Limb;

/// Multi-asset value: a sorted map of currency symbols to sorted maps of token names to quantities.
pub const Value = struct {
    entries: []const CurrencyEntry,
    size: usize, // total number of unique (currency, token) pairs

    pub const CurrencyEntry = struct {
        currency: []const u8, // <= 32 bytes
        tokens: []const TokenEntry,
    };

    pub const TokenEntry = struct {
        name: []const u8, // <= 32 bytes
        quantity: Integer, // signed 128-bit range, non-zero
    };

    /// The empty value.
    pub fn empty() Value {
        return .{ .entries = &.{}, .size = 0 };
    }

    /// Look up a quantity by currency symbol and token name. Returns 0 if not found.
    pub fn lookupCoin(self: Value, ccy: []const u8, tok: []const u8) Integer {
        for (self.entries) |entry| {
            const cmp = compareBytes(entry.currency, ccy);
            if (cmp == .eq) {
                for (entry.tokens) |token| {
                    const tcmp = compareBytes(token.name, tok);
                    if (tcmp == .eq) return token.quantity;
                    if (tcmp == .gt) break;
                }
                return zeroInteger();
            }
            if (cmp == .gt) break;
        }
        return zeroInteger();
    }

    /// Insert/update a coin in the value. qty=0 means delete that entry.
    pub fn insertCoin(allocator: std.mem.Allocator, ccy: []const u8, tok: []const u8, qty: Integer, v: Value) !Value {
        var currency_entries: std.ArrayListUnmanaged(CurrencyEntry) = .empty;
        defer currency_entries.deinit(allocator);

        var found_ccy = false;
        for (v.entries) |entry| {
            const cmp = compareBytes(entry.currency, ccy);
            if (cmp == .lt) {
                try currency_entries.append(allocator, entry);
            } else if (cmp == .eq) {
                found_ccy = true;
                // Insert/update token in this currency
                var token_entries: std.ArrayListUnmanaged(TokenEntry) = .empty;
                defer token_entries.deinit(allocator);

                var found_tok = false;
                for (entry.tokens) |token| {
                    const tcmp = compareBytes(token.name, tok);
                    if (tcmp == .lt) {
                        try token_entries.append(allocator, token);
                    } else if (tcmp == .eq) {
                        found_tok = true;
                        if (!qty.eqlZero()) {
                            try token_entries.append(allocator, .{ .name = tok, .quantity = qty });
                        }
                    } else {
                        // tcmp == .gt: insert before this one if not found yet
                        if (!found_tok) {
                            found_tok = true;
                            if (!qty.eqlZero()) {
                                try token_entries.append(allocator, .{ .name = tok, .quantity = qty });
                            }
                        }
                        try token_entries.append(allocator, token);
                    }
                }
                if (!found_tok and !qty.eqlZero()) {
                    try token_entries.append(allocator, .{ .name = tok, .quantity = qty });
                }

                const tokens = try token_entries.toOwnedSlice(allocator);
                if (tokens.len > 0) {
                    try currency_entries.append(allocator, .{ .currency = entry.currency, .tokens = tokens });
                }
            } else {
                // cmp == .gt: insert new currency before this one if not found yet
                if (!found_ccy) {
                    found_ccy = true;
                    if (!qty.eqlZero()) {
                        const tokens = try allocator.alloc(TokenEntry, 1);
                        tokens[0] = .{ .name = tok, .quantity = qty };
                        try currency_entries.append(allocator, .{ .currency = ccy, .tokens = tokens });
                    }
                }
                try currency_entries.append(allocator, entry);
            }
        }

        if (!found_ccy and !qty.eqlZero()) {
            const tokens = try allocator.alloc(TokenEntry, 1);
            tokens[0] = .{ .name = tok, .quantity = qty };
            try currency_entries.append(allocator, .{ .currency = ccy, .tokens = tokens });
        }

        const entries = try currency_entries.toOwnedSlice(allocator);
        var total_size: usize = 0;
        for (entries) |e| {
            total_size += e.tokens.len;
        }
        return .{ .entries = entries, .size = total_size };
    }

    /// Merge two values by adding quantities. Removes zero entries. Fails on overflow.
    pub fn unionValue(allocator: std.mem.Allocator, v1: Value, v2: Value) !Value {
        var currency_entries: std.ArrayListUnmanaged(CurrencyEntry) = .empty;
        defer currency_entries.deinit(allocator);

        var i: usize = 0;
        var j: usize = 0;

        while (i < v1.entries.len and j < v2.entries.len) {
            const cmp = compareBytes(v1.entries[i].currency, v2.entries[j].currency);
            if (cmp == .lt) {
                try currency_entries.append(allocator, v1.entries[i]);
                i += 1;
            } else if (cmp == .gt) {
                try currency_entries.append(allocator, v2.entries[j]);
                j += 1;
            } else {
                // Same currency - merge token maps
                const merged = try mergeTokens(allocator, v1.entries[i].tokens, v2.entries[j].tokens);
                if (merged.len > 0) {
                    try currency_entries.append(allocator, .{ .currency = v1.entries[i].currency, .tokens = merged });
                }
                i += 1;
                j += 1;
            }
        }

        // Remaining from v1
        while (i < v1.entries.len) : (i += 1) {
            try currency_entries.append(allocator, v1.entries[i]);
        }
        // Remaining from v2
        while (j < v2.entries.len) : (j += 1) {
            try currency_entries.append(allocator, v2.entries[j]);
        }

        const entries = try currency_entries.toOwnedSlice(allocator);
        var total_size: usize = 0;
        for (entries) |e| {
            total_size += e.tokens.len;
        }
        return .{ .entries = entries, .size = total_size };
    }

    /// Check that v1 >= v2 componentwise (both must have non-negative quantities).
    /// Returns error if either value has negative quantities.
    pub fn valueContains(v1: Value, v2: Value) !bool {
        // Check that v1 has no negatives
        for (v1.entries) |entry| {
            for (entry.tokens) |token| {
                if (token.quantity.isPositive() == false and !token.quantity.eqlZero()) {
                    return error.EvaluationFailure;
                }
            }
        }
        // Check that v2 has no negatives
        for (v2.entries) |entry| {
            for (entry.tokens) |token| {
                if (token.quantity.isPositive() == false and !token.quantity.eqlZero()) {
                    return error.EvaluationFailure;
                }
            }
        }

        // For each asset in v2, check v1 has >= that amount
        for (v2.entries) |v2_entry| {
            for (v2_entry.tokens) |v2_token| {
                const v1_qty = v1.lookupCoin(v2_entry.currency, v2_token.name);
                if (v1_qty.toConst().order(v2_token.quantity.toConst()) == .lt) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Multiply all quantities by a scalar. scalar=0 → empty value. Fails on overflow.
    pub fn scaleValue(allocator: std.mem.Allocator, scalar: *const Integer, v: Value) !Value {
        if (scalar.eqlZero()) {
            return empty();
        }

        try checkQuantityRange(scalar);

        var currency_entries: std.ArrayListUnmanaged(CurrencyEntry) = .empty;
        defer currency_entries.deinit(allocator);

        for (v.entries) |entry| {
            var token_entries: std.ArrayListUnmanaged(TokenEntry) = .empty;
            defer token_entries.deinit(allocator);

            for (entry.tokens) |token| {
                var qty = token.quantity;
                var result = Integer.init(allocator) catch return error.OutOfMemory;
                result.mul(&qty, scalar) catch return error.OutOfMemory;

                try checkQuantityRange(&result);

                if (!result.eqlZero()) {
                    try token_entries.append(allocator, .{ .name = token.name, .quantity = result });
                }
            }

            const tokens = try token_entries.toOwnedSlice(allocator);
            if (tokens.len > 0) {
                try currency_entries.append(allocator, .{ .currency = entry.currency, .tokens = tokens });
            }
        }

        const entries = try currency_entries.toOwnedSlice(allocator);
        var total_size: usize = 0;
        for (entries) |e| {
            total_size += e.tokens.len;
        }
        return .{ .entries = entries, .size = total_size };
    }

    /// Encode a Value as PlutusData: Map [(B ccy, Map [(B tok, I qty)])]
    pub fn valueData(allocator: std.mem.Allocator, v: Value) !*const PlutusData {
        var outer_pairs: std.ArrayListUnmanaged(PlutusDataPair) = .empty;
        defer outer_pairs.deinit(allocator);

        for (v.entries) |entry| {
            const ccy_data = try PlutusData.byteString(allocator, entry.currency);

            var inner_pairs: std.ArrayListUnmanaged(PlutusDataPair) = .empty;
            defer inner_pairs.deinit(allocator);

            for (entry.tokens) |token| {
                const tok_data = try PlutusData.byteString(allocator, token.name);
                const qty_data = try allocator.create(PlutusData);
                var qty_copy = try Integer.init(allocator);
                try qty_copy.copy(token.quantity.toConst());
                qty_data.* = .{ .integer = qty_copy };

                try inner_pairs.append(allocator, .{ .key = tok_data, .value = qty_data });
            }

            const inner_map = try PlutusData.mapOf(allocator, try inner_pairs.toOwnedSlice(allocator));
            try outer_pairs.append(allocator, .{ .key = ccy_data, .value = inner_map });
        }

        return PlutusData.mapOf(allocator, try outer_pairs.toOwnedSlice(allocator));
    }

    /// Decode PlutusData into a Value. Validates sorted order, no zeros, no empty inner maps,
    /// keys <= 32 bytes, quantities in 128-bit range.
    pub fn unValueData(allocator: std.mem.Allocator, d: *const PlutusData) !Value {
        const outer_map = switch (d.*) {
            .map => |m| m,
            else => return error.DecodeError,
        };

        var currency_entries: std.ArrayListUnmanaged(CurrencyEntry) = .empty;
        defer currency_entries.deinit(allocator);

        var prev_ccy: ?[]const u8 = null;
        var total_size: usize = 0;

        for (outer_map) |pair| {
            const ccy = switch (pair.key.*) {
                .byte_string => |bs| bs,
                else => return error.DecodeError,
            };

            if (ccy.len > 32) return error.DecodeError;

            // Check sorted order (strictly ascending)
            if (prev_ccy) |prev| {
                if (compareBytes(prev, ccy) != .lt) return error.DecodeError;
            }
            prev_ccy = ccy;

            const inner_map = switch (pair.value.*) {
                .map => |m| m,
                else => return error.DecodeError,
            };

            if (inner_map.len == 0) return error.DecodeError;

            var token_entries: std.ArrayListUnmanaged(TokenEntry) = .empty;
            defer token_entries.deinit(allocator);

            var prev_tok: ?[]const u8 = null;

            for (inner_map) |inner_pair| {
                const tok = switch (inner_pair.key.*) {
                    .byte_string => |bs| bs,
                    else => return error.DecodeError,
                };

                if (tok.len > 32) return error.DecodeError;

                // Check sorted order (strictly ascending)
                if (prev_tok) |prev| {
                    if (compareBytes(prev, tok) != .lt) return error.DecodeError;
                }
                prev_tok = tok;

                const qty_managed = switch (inner_pair.value.*) {
                    .integer => |int_val| int_val,
                    else => return error.DecodeError,
                };

                if (qty_managed.eqlZero()) return error.DecodeError;

                try checkQuantityRange(&qty_managed);

                try token_entries.append(allocator, .{ .name = tok, .quantity = qty_managed });
            }

            const tokens = try token_entries.toOwnedSlice(allocator);
            total_size += tokens.len;
            try currency_entries.append(allocator, .{ .currency = ccy, .tokens = tokens });
        }

        return .{
            .entries = try currency_entries.toOwnedSlice(allocator),
            .size = total_size,
        };
    }

    pub const ValueError = error{
        OutOfMemory,
        EvaluationFailure,
        DecodeError,
    };
};

/// Merge two sorted token slices by adding quantities. Removes zeros.
fn mergeTokens(allocator: std.mem.Allocator, t1: []const Value.TokenEntry, t2: []const Value.TokenEntry) ![]const Value.TokenEntry {
    var result: std.ArrayListUnmanaged(Value.TokenEntry) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    var j: usize = 0;

    while (i < t1.len and j < t2.len) {
        const cmp = compareBytes(t1[i].name, t2[j].name);
        if (cmp == .lt) {
            try result.append(allocator, t1[i]);
            i += 1;
        } else if (cmp == .gt) {
            try result.append(allocator, t2[j]);
            j += 1;
        } else {
            // Same token - add quantities
            var a = t1[i].quantity;
            var b = t2[j].quantity;
            var sum = Integer.init(allocator) catch return error.OutOfMemory;
            sum.add(&a, &b) catch return error.OutOfMemory;

            try checkQuantityRange(&sum);

            if (!sum.eqlZero()) {
                try result.append(allocator, .{ .name = t1[i].name, .quantity = sum });
            }
            i += 1;
            j += 1;
        }
    }

    while (i < t1.len) : (i += 1) {
        try result.append(allocator, t1[i]);
    }
    while (j < t2.len) : (j += 1) {
        try result.append(allocator, t2[j]);
    }

    return result.toOwnedSlice(allocator);
}

/// Compare two byte slices lexicographically.
fn compareBytes(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Return a zero integer (static, no allocation needed).
fn zeroInteger() Integer {
    return .{
        .allocator = undefined,
        .limbs = @constCast(&[_]Limb{0}),
        .metadata = 0 | (1 << @bitSizeOf(usize) - 1),
    };
}

/// Check that a quantity is within the 128-bit signed range: -(2^127) to (2^127 - 1).
fn checkQuantityRange(int: *const Integer) !void {
    const bits = int.bitCountAbs();
    if (bits <= 127) return; // Fits in 127 bits + sign, always valid

    if (bits > 128) return error.EvaluationFailure;

    // bits == 128: only valid if negative and exactly -(2^127)
    if (int.isPositive()) return error.EvaluationFailure;

    // Check that absolute value is exactly 2^127 (bit 127 set, all others zero)
    const limbs = int.toConst().limbs;
    const limb_bits = @bitSizeOf(Limb);
    const target_limb = 127 / limb_bits;
    const target_bit: std.math.Log2Int(Limb) = @intCast(127 % limb_bits);
    for (limbs, 0..) |limb, idx| {
        if (idx == target_limb) {
            if (limb != (@as(Limb, 1) << target_bit)) return error.EvaluationFailure;
        } else {
            if (limb != 0) return error.EvaluationFailure;
        }
    }
}

test "empty value" {
    const v = Value.empty();
    try std.testing.expectEqual(@as(usize, 0), v.entries.len);
    try std.testing.expectEqual(@as(usize, 0), v.size);
}

test "insertCoin and lookupCoin" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var qty = try Integer.init(alloc);
    try qty.set(100);

    const v = try Value.insertCoin(alloc, &.{0xAA}, &.{0xBB}, qty, Value.empty());

    const found = v.lookupCoin(&.{0xAA}, &.{0xBB});
    const found_str = try found.toConst().toStringAlloc(alloc, 10, .lower);
    try std.testing.expectEqualStrings("100", found_str);

    const not_found = v.lookupCoin(&.{0xCC}, &.{0xDD});
    try std.testing.expect(not_found.eqlZero());
}
