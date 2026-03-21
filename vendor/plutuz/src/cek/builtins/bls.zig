const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const BuiltinError = h.BuiltinError;
const blst = h.blst;

pub fn bls12381G1Add(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG1Element(Binder, args[0]);
    const b = try h.unwrapG1Element(Binder, args[1]);

    const result = blst.addG1(a, b);
    return h.g1Result(Binder, allocator, result);
}

pub fn bls12381G1Equal(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG1Element(Binder, args[0]);
    const b = try h.unwrapG1Element(Binder, args[1]);

    return h.boolResult(Binder, allocator, blst.equalG1(a, b));
}

pub fn bls12381G1Uncompress(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    if (bytes.len != blst.BLST_P1_COMPRESSED_SIZE) return error.TypeMismatch;

    const point = blst.uncompressG1(bytes[0..blst.BLST_P1_COMPRESSED_SIZE]) catch return error.TypeMismatch;
    return h.g1Result(Binder, allocator, point);
}

pub fn bls12381G1Neg(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG1Element(Binder, args[0]);
    return h.g1Result(Binder, allocator, blst.negG1(a));
}

pub fn bls12381G1ScalarMul(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const scalar = try h.unwrapInteger(Binder, args[0]);
    const point = try h.unwrapG1Element(Binder, args[1]);
    const result = scalarMulPoint(scalar, blst.P1, point, blst.scalarMulG1, blst.negG1);
    return h.g1Result(Binder, allocator, result);
}

pub fn bls12381G1Compress(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const point = try h.unwrapG1Element(Binder, args[0]);
    const compressed = blst.compressG1(point);
    const result = allocator.alloc(u8, blst.BLST_P1_COMPRESSED_SIZE) catch return error.OutOfMemory;
    @memcpy(result, &compressed);
    return h.byteStringResult(Binder, allocator, result);
}

pub fn bls12381G1HashToGroup(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const msg = try h.unwrapByteString(Binder, args[0]);
    const dst = try h.unwrapByteString(Binder, args[1]);
    if (dst.len > 255) return error.TypeMismatch;
    return h.g1Result(Binder, allocator, blst.hashToG1(msg, dst));
}

pub fn bls12381G2Add(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG2Element(Binder, args[0]);
    const b = try h.unwrapG2Element(Binder, args[1]);
    return h.g2Result(Binder, allocator, blst.addG2(a, b));
}

pub fn bls12381G2Neg(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG2Element(Binder, args[0]);
    return h.g2Result(Binder, allocator, blst.negG2(a));
}

pub fn bls12381G2ScalarMul(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const scalar = try h.unwrapInteger(Binder, args[0]);
    const point = try h.unwrapG2Element(Binder, args[1]);
    const result = scalarMulPoint(scalar, blst.P2, point, blst.scalarMulG2, blst.negG2);
    return h.g2Result(Binder, allocator, result);
}

pub fn bls12381G2Equal(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapG2Element(Binder, args[0]);
    const b = try h.unwrapG2Element(Binder, args[1]);
    return h.boolResult(Binder, allocator, blst.equalG2(a, b));
}

pub fn bls12381G2Compress(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const point = try h.unwrapG2Element(Binder, args[0]);
    const compressed = blst.compressG2(point);
    const result = allocator.alloc(u8, blst.BLST_P2_COMPRESSED_SIZE) catch return error.OutOfMemory;
    @memcpy(result, &compressed);
    return h.byteStringResult(Binder, allocator, result);
}

pub fn bls12381G2Uncompress(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    if (bytes.len != blst.BLST_P2_COMPRESSED_SIZE) return error.TypeMismatch;
    const point = blst.uncompressG2(bytes[0..blst.BLST_P2_COMPRESSED_SIZE]) catch return error.TypeMismatch;
    return h.g2Result(Binder, allocator, point);
}

pub fn bls12381G2HashToGroup(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const msg = try h.unwrapByteString(Binder, args[0]);
    const dst = try h.unwrapByteString(Binder, args[1]);
    if (dst.len > 255) return error.TypeMismatch;
    return h.g2Result(Binder, allocator, blst.hashToG2(msg, dst));
}

/// Check if a scalar is within the bounds for multiScalarMul.
/// Per the Haskell reference (BLS12_381/Bounds.hs):
/// msmMaxScalarBits = 4096 (64 words * 64 bits)
/// Valid range: -(2^4095) <= s <= 2^4095 - 1
/// i.e., the scalar must fit in 512 bytes as a signed integer.
fn msmScalarOutOfBounds(scalar: *const Integer) bool {
    const c_val = scalar.toConst();
    if (c_val.eqlZero()) return false;

    // Count significant bits (excluding sign)
    const limbs = c_val.limbs;
    const top_limb = limbs[limbs.len - 1];
    const top_bits = @bitSizeOf(std.math.big.Limb) - @clz(top_limb);
    const nbits = (limbs.len - 1) * @bitSizeOf(std.math.big.Limb) + top_bits;

    // For signed representation: positive values need nbits <= 4095
    // Negative values need nbits <= 4095 (since -(2^4095) is the min)
    // Actually: |s| must have at most 4095 bits for positive,
    // and for negative, -2^4095 has exactly 4096 bits in absolute value but is the min
    if (c_val.positive) {
        // Upper bound: 2^4095 - 1 → at most 4095 bits
        return nbits > 4095;
    } else {
        // Lower bound: -(2^4095) → absolute value is exactly 2^4095 (4096 bits)
        // But that's only valid if the value is exactly -(2^4095)
        // For any |value| > 2^4095, it's out of bounds
        if (nbits > 4096) return true;
        if (nbits < 4096) return false;
        // Exactly 4096 bits: check if it's exactly 2^4095 (power of 2)
        // Top limb should be a power of 2 and all lower limbs should be 0
        if (@popCount(top_limb) != 1) return true; // not a power of 2
        for (limbs[0 .. limbs.len - 1]) |limb| {
            if (limb != 0) return true;
        }
        return false; // exactly -(2^4095), which is the minimum
    }
}

pub fn bls12381G1MultiScalarMul(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const scalars = try h.unwrapList(Binder, args[0]);
    const points = try h.unwrapList(Binder, args[1]);

    // Validate scalar bounds (per Haskell BLS12_381/Bounds.hs)
    for (scalars) |s| {
        const si = switch (s.*) {
            .integer => |*i| i,
            else => return error.TypeMismatch,
        };
        if (msmScalarOutOfBounds(si)) return error.EvaluationFailure;
    }

    // Use min length (extra entries in either list are ignored)
    const n = @min(scalars.len, points.len);

    // Empty → return identity (zero) point
    if (n == 0) {
        const zero_compressed = [_]u8{0xc0} ++ [_]u8{0} ** 47;
        const identity = blst.uncompressG1(&zero_compressed) catch return error.EvaluationFailure;
        return h.g1Result(Binder, allocator, identity);
    }

    // Compute first: scalar[0] * point[0]
    const s0 = switch (scalars[0].*) {
        .integer => |*i| i,
        else => return error.TypeMismatch,
    };
    const p0 = switch (points[0].*) {
        .bls12_381_g1_element => |*e| e,
        else => return error.TypeMismatch,
    };
    var acc = scalarMulPoint(s0, blst.P1, p0, blst.scalarMulG1, blst.negG1);

    // Accumulate remaining: acc += scalar[i] * point[i]
    for (1..n) |i| {
        const si = switch (scalars[i].*) {
            .integer => |*ii| ii,
            else => return error.TypeMismatch,
        };
        const pi = switch (points[i].*) {
            .bls12_381_g1_element => |*e| e,
            else => return error.TypeMismatch,
        };
        const term = scalarMulPoint(si, blst.P1, pi, blst.scalarMulG1, blst.negG1);
        acc = blst.addG1(&acc, &term);
    }

    return h.g1Result(Binder, allocator, acc);
}

pub fn bls12381G2MultiScalarMul(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const scalars = try h.unwrapList(Binder, args[0]);
    const points = try h.unwrapList(Binder, args[1]);

    // Validate scalar bounds (per Haskell BLS12_381/Bounds.hs)
    for (scalars) |s| {
        const si = switch (s.*) {
            .integer => |*i| i,
            else => return error.TypeMismatch,
        };
        if (msmScalarOutOfBounds(si)) return error.EvaluationFailure;
    }

    // Use min length (extra entries in either list are ignored)
    const n = @min(scalars.len, points.len);

    // Empty → return identity (zero) point
    if (n == 0) {
        const zero_compressed = [_]u8{0xc0} ++ [_]u8{0} ** 95;
        const identity = blst.uncompressG2(&zero_compressed) catch return error.EvaluationFailure;
        return h.g2Result(Binder, allocator, identity);
    }

    // Compute first: scalar[0] * point[0]
    const s0 = switch (scalars[0].*) {
        .integer => |*i| i,
        else => return error.TypeMismatch,
    };
    const p0 = switch (points[0].*) {
        .bls12_381_g2_element => |*e| e,
        else => return error.TypeMismatch,
    };
    var acc = scalarMulPoint(s0, blst.P2, p0, blst.scalarMulG2, blst.negG2);

    // Accumulate remaining: acc += scalar[i] * point[i]
    for (1..n) |i| {
        const si = switch (scalars[i].*) {
            .integer => |*ii| ii,
            else => return error.TypeMismatch,
        };
        const pi = switch (points[i].*) {
            .bls12_381_g2_element => |*e| e,
            else => return error.TypeMismatch,
        };
        const term = scalarMulPoint(si, blst.P2, pi, blst.scalarMulG2, blst.negG2);
        acc = blst.addG2(&acc, &term);
    }

    return h.g2Result(Binder, allocator, acc);
}

pub fn bls12381MillerLoop(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const g1 = try h.unwrapG1Element(Binder, args[0]);
    const g2 = try h.unwrapG2Element(Binder, args[1]);
    return h.mlResult(Binder, allocator, blst.millerLoop(g1, g2));
}

pub fn bls12381MulMlResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapMlResult(Binder, args[0]);
    const b = try h.unwrapMlResult(Binder, args[1]);
    return h.mlResult(Binder, allocator, blst.mulFp12(a, b));
}

pub fn bls12381FinalVerify(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const a = try h.unwrapMlResult(Binder, args[0]);
    const b = try h.unwrapMlResult(Binder, args[1]);
    return h.boolResult(Binder, allocator, blst.finalVerify(a, b));
}

/// Convert a big integer to little-endian bytes and multiply a curve point.
/// Handles negative scalars by negating the point and using absolute value.
fn scalarMulPoint(
    scalar: *const Integer,
    comptime Point: type,
    point: *const Point,
    mulFn: *const fn (*const Point, []const u8, usize) Point,
    negFn: *const fn (*const Point) Point,
) Point {
    const c_val = scalar.toConst();

    // Zero scalar → identity point (multiply by 1-bit zero scalar)
    if (c_val.eqlZero()) {
        const zero_byte = [_]u8{0};
        return mulFn(point, &zero_byte, 1);
    }

    // Convert limbs to bytes (little-endian)
    const limbs = c_val.limbs;
    const limb_bytes = @as([*]const u8, @ptrCast(limbs.ptr))[0 .. limbs.len * @sizeOf(std.math.big.Limb)];

    // Count significant bits
    const nbits = blk: {
        const top_limb = limbs[limbs.len - 1];
        const top_bits = @bitSizeOf(std.math.big.Limb) - @clz(top_limb);
        break :blk (limbs.len - 1) * @bitSizeOf(std.math.big.Limb) + top_bits;
    };

    // If negative, negate point and use absolute value
    if (!c_val.positive) {
        const neg_point = negFn(point);
        return mulFn(&neg_point, limb_bytes, nbits);
    }

    return mulFn(point, limb_bytes, nbits);
}
