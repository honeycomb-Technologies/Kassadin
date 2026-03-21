//! Zigzag encoding for signed ↔ unsigned integer conversion.
//!
//! Used by the flat codec to encode arbitrary-precision signed integers
//! as unsigned values: non-negative values map to even numbers, negative
//! values map to odd numbers.

const std = @import("std");
const Managed = std.math.big.int.Managed;

/// Zigzag-encode a signed big integer to unsigned.
/// n >= 0  →  n * 2
/// n < 0   →  -(2 * n) - 1
pub fn zigzag(allocator: std.mem.Allocator, n: Managed) !Managed {
    const c = n.toConst();
    if (c.positive or c.eqlZero()) {
        // n << 1
        var result = try Managed.init(allocator);
        errdefer result.deinit();
        try result.copy(c);
        try result.shiftLeft(&result, 1);
        return result;
    } else {
        // -(2*n) - 1
        var result = try Managed.init(allocator);
        errdefer result.deinit();
        try result.copy(c);
        // result = n (negative), shift left = 2*n (still negative)
        try result.shiftLeft(&result, 1);
        // negate: result = -2*n (positive)
        result.negate();
        // subtract 1
        try result.addScalar(&result, -1);
        return result;
    }
}

/// Zigzag-decode an unsigned big integer to signed.
/// (n >> 1) ^ -(n & 1)
pub fn unzigzag(allocator: std.mem.Allocator, n: Managed) !Managed {
    const c = n.toConst();

    // Check if lowest bit is set
    const is_odd = blk: {
        if (c.eqlZero()) break :blk false;
        break :blk (c.limbs[0] & 1) != 0;
    };

    // n >> 1
    var result = try Managed.init(allocator);
    errdefer result.deinit();
    try result.copy(c);
    try result.shiftRight(&result, 1);

    if (is_odd) {
        // -(result) - 1
        result.negate();
        try result.addScalar(&result, -1);
    }

    return result;
}

// --- Tests ---

const testing = std.testing;

fn expectManagedEqual(expected: i64, actual: Managed) !void {
    const val = try actual.toConst().toInt(i64);
    try testing.expectEqual(expected, val);
}

test "zigzag encode 0" {
    var n = try Managed.init(testing.allocator);
    defer n.deinit();
    try n.set(0);

    var result = try zigzag(testing.allocator, n);
    defer result.deinit();
    try expectManagedEqual(0, result);
}

test "zigzag encode positive" {
    var n = try Managed.init(testing.allocator);
    defer n.deinit();
    try n.set(1);

    var result = try zigzag(testing.allocator, n);
    defer result.deinit();
    try expectManagedEqual(2, result);
}

test "zigzag encode negative" {
    var n = try Managed.init(testing.allocator);
    defer n.deinit();
    try n.set(-1);

    var result = try zigzag(testing.allocator, n);
    defer result.deinit();
    try expectManagedEqual(1, result);
}

test "zigzag encode -2" {
    var n = try Managed.init(testing.allocator);
    defer n.deinit();
    try n.set(-2);

    var result = try zigzag(testing.allocator, n);
    defer result.deinit();
    try expectManagedEqual(3, result);
}

test "zigzag roundtrip" {
    const values = [_]i64{ 0, 1, -1, 2, -2, 127, -128, 1000, -1000, 2147483647, -2147483648 };
    for (values) |v| {
        var n = try Managed.init(testing.allocator);
        defer n.deinit();
        try n.set(v);

        var encoded = try zigzag(testing.allocator, n);
        defer encoded.deinit();

        var decoded = try unzigzag(testing.allocator, encoded);
        defer decoded.deinit();

        try expectManagedEqual(v, decoded);
    }
}
