//! ExMem size measurement helpers.
//! Convert runtime values to cost-model input sizes.

const std = @import("std");
const constant_mod = @import("../ast/constant.zig");
const Constant = constant_mod.Constant;
const Integer = constant_mod.Integer;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;
const AstValue = @import("../ast/value.zig").Value;

/// Measure the size of a big integer in 64-bit words.
pub fn integerExMem(i: *const Integer) i64 {
    const bits = i.toConst().bitCountAbs();
    if (bits == 0) return 1;
    return @divFloor(@as(i64, @intCast(bits)) - 1, 64) + 1;
}

/// Measure the size of a byte string in 8-byte chunks.
/// Empty byte strings have size 1 (matching Haskell/Plutigo reference).
pub fn byteStringExMem(bs: []const u8) i64 {
    if (bs.len == 0) return 1;
    return @divFloor(@as(i64, @intCast(bs.len)) - 1, 8) + 1;
}

/// Measure the size of a string as raw byte length (character count).
pub fn stringExMem(s: []const u8) i64 {
    return @intCast(s.len);
}

/// Bool always costs 1.
pub fn boolExMem() i64 {
    return 1;
}

/// Unit always costs 1.
pub fn unitExMem() i64 {
    return 1;
}

/// Measure the size of PlutusData by recursive traversal summing node costs.
/// Uses an iterative stack-based approach to avoid stack overflow.
pub fn dataExMem(d: *const PlutusData) i64 {
    var total: i64 = 0;
    // Use a simple stack for iterative traversal
    var stack: std.ArrayListUnmanaged(*const PlutusData) = .{};
    defer stack.deinit(std.heap.page_allocator);
    stack.append(std.heap.page_allocator, d) catch return 4;

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        total += 4; // Base cost per node
        switch (current.*) {
            .constr => |c| {
                for (c.fields) |field| {
                    stack.append(std.heap.page_allocator, field) catch return total;
                }
            },
            .map => |pairs| {
                for (pairs) |pair| {
                    stack.append(std.heap.page_allocator, pair.key) catch return total;
                    stack.append(std.heap.page_allocator, pair.value) catch return total;
                }
            },
            .list => |items| {
                for (items) |item| {
                    stack.append(std.heap.page_allocator, item) catch return total;
                }
            },
            .integer => |*int_val| {
                total += integerExMem(int_val);
            },
            .byte_string => |bs| {
                total += byteStringExMem(bs);
            },
        }
    }

    return total;
}

/// Measure ExMem size of an integer value (not word count).
/// Used for cost model inputs that need the integer's byte size.
pub fn sizeExMem(value: i64) i64 {
    if (value <= 0) return 0;
    return @divFloor(value - 1, 8) + 1;
}

/// Compute recursive ExMem for any Constant value.
/// Matches the Haskell/Plutigo `iconstantExMem` implementation.
pub fn constantExMem(c: *const Constant) i64 {
    return switch (c.*) {
        .integer => |*int_val| integerExMem(int_val),
        .byte_string => |bs| byteStringExMem(bs),
        .string => |s| stringExMem(s),
        .boolean => 1,
        .unit => 1,
        .data => |d| dataExMem(d),
        .proto_list => |l| fullListExMem(l.values),
        .proto_array => |a| fullListExMem(a.values),
        .proto_pair => |p| 1 + constantExMem(p.fst) + constantExMem(p.snd),
        .bls12_381_g1_element => g1ExMem(),
        .bls12_381_g2_element => g2ExMem(),
        .bls12_381_ml_result => mlResultExMem(),
        .value => |v| @intCast(v.size),
    };
}

/// Compute full recursive ExMem for a list of constants.
/// NilCost = 1, ConsCost = 3 per element, plus recursive ExMem of each element.
pub fn fullListExMem(values: []const *const Constant) i64 {
    var total: i64 = 1; // NilCost
    for (values) |item| {
        total += constantExMem(item) + 3; // ConsCost = 3
    }
    return total;
}

/// ValueMaxDepth: log2(outerSize)+1 + log2(maxInnerSize)+1.
/// Used by insertCoin and lookupCoin for costing map lookups.
pub fn valueMaxDepth(v: AstValue) i64 {
    const outer_size = v.entries.len;
    var max_inner: usize = 0;
    for (v.entries) |entry| {
        if (entry.tokens.len > max_inner) max_inner = entry.tokens.len;
    }
    const log_outer: i64 = if (outer_size > 0) @as(i64, @intCast(std.math.log2(outer_size))) + 1 else 0;
    const log_inner: i64 = if (max_inner > 0) @as(i64, @intCast(std.math.log2(max_inner))) + 1 else 0;
    return log_outer + log_inner;
}

/// IntegerCostedLiterally: ExMem = abs(n).
/// Used by dropList, shiftByteString, rotateByteString where cost depends on the actual integer value.
/// For values that don't fit in i64, returns maxInt(i64) (will exhaust budget).
pub fn integerCostedLiterally(i: *const Integer) i64 {
    // Try to get the absolute value as i64
    const c = i.toConst();
    // If it's negative, negate first
    if (c.positive) {
        return c.toInt(i64) catch std.math.maxInt(i64);
    } else {
        // For negative numbers, we need abs(n). toInt on negative might overflow for minInt.
        // Use the unsigned representation: try to convert the absolute value.
        return c.negate().toInt(i64) catch std.math.maxInt(i64);
    }
}

/// DataNodeCount: count total nodes in a PlutusData tree.
/// Used by unValueData where cost depends on the number of data nodes, not weighted size.
pub fn dataNodeCount(d: *const PlutusData) i64 {
    var total: i64 = 0;
    var stack: std.ArrayListUnmanaged(*const PlutusData) = .{};
    defer stack.deinit(std.heap.page_allocator);
    stack.append(std.heap.page_allocator, d) catch return 1;

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        total += 1;
        switch (current.*) {
            .constr => |c| {
                for (c.fields) |field| {
                    stack.append(std.heap.page_allocator, field) catch return total;
                }
            },
            .map => |pairs| {
                for (pairs) |pair| {
                    stack.append(std.heap.page_allocator, pair.key) catch return total;
                    stack.append(std.heap.page_allocator, pair.value) catch return total;
                }
            },
            .list => |items| {
                for (items) |item| {
                    stack.append(std.heap.page_allocator, item) catch return total;
                }
            },
            .integer, .byte_string => {},
        }
    }

    return total;
}

/// Measure size for a list (number of elements).
pub fn listExMem(len: usize) i64 {
    return @intCast(len);
}

/// G1 element constant size.
pub fn g1ExMem() i64 {
    return 18;
}

/// G2 element constant size.
pub fn g2ExMem() i64 {
    return 36;
}

/// Miller loop result constant size.
pub fn mlResultExMem() i64 {
    return 72;
}

// ===== Tests =====

test "integerExMem" {
    const testing = std.testing;

    // 0 → 1 word
    var zero = try Integer.init(testing.allocator);
    defer zero.deinit();
    try zero.set(0);
    try testing.expectEqual(@as(i64, 1), integerExMem(&zero));

    // 1 → 1 word (1 bit)
    var one = try Integer.init(testing.allocator);
    defer one.deinit();
    try one.set(1);
    try testing.expectEqual(@as(i64, 1), integerExMem(&one));

    // 2^63 → 1 word (64 bits)
    var big = try Integer.init(testing.allocator);
    defer big.deinit();
    try big.set(@as(i64, 1));
    try big.shiftLeft(&big, 63);
    try testing.expectEqual(@as(i64, 1), integerExMem(&big));

    // 2^64 → 2 words (65 bits)
    try big.shiftLeft(&big, 1);
    try testing.expectEqual(@as(i64, 2), integerExMem(&big));
}

test "byteStringExMem" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, 1), byteStringExMem(""));
    try testing.expectEqual(@as(i64, 1), byteStringExMem("a"));
    try testing.expectEqual(@as(i64, 1), byteStringExMem("abcdefgh"));
    try testing.expectEqual(@as(i64, 2), byteStringExMem("abcdefghi"));
}
