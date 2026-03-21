const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const BuiltinError = h.BuiltinError;

pub fn addInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.add(arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn subtractInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.sub(arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn multiplyInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.mul(arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn divideInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    if (arg2.eqlZero()) return error.DivisionByZero;

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    var remainder = Integer.init(allocator) catch return error.OutOfMemory;
    result.divFloor(&remainder, arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn quotientInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    if (arg2.eqlZero()) return error.DivisionByZero;

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    var remainder = Integer.init(allocator) catch return error.OutOfMemory;
    result.divTrunc(&remainder, arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn remainderInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    if (arg2.eqlZero()) return error.DivisionByZero;

    var quotient = Integer.init(allocator) catch return error.OutOfMemory;
    var remainder = Integer.init(allocator) catch return error.OutOfMemory;
    quotient.divTrunc(&remainder, arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, remainder);
}

pub fn modInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    if (arg2.eqlZero()) return error.DivisionByZero;

    var quotient = Integer.init(allocator) catch return error.OutOfMemory;
    var remainder = Integer.init(allocator) catch return error.OutOfMemory;
    quotient.divFloor(&remainder, arg1, arg2) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, remainder);
}

pub fn expModInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const base_int = try h.unwrapInteger(Binder, args[0]);
    const exp_int = try h.unwrapInteger(Binder, args[1]);
    const mod_int = try h.unwrapInteger(Binder, args[2]);

    const base_c = base_int.toConst();
    const exp_c = exp_int.toConst();
    const mod_c = mod_int.toConst();

    // Modulus must be positive
    if (mod_c.positive == false or mod_c.eqlZero()) return error.EvaluationFailure;

    // Special case: modulus is 1 => result is always 0
    if (mod_c.orderAgainstScalar(1) == .eq) {
        var result = Integer.init(allocator) catch return error.OutOfMemory;
        result.set(0) catch return error.OutOfMemory;
        return h.integerResult(Binder, allocator, result);
    }

    // Exponent == 0 => result is 1
    if (exp_c.eqlZero()) {
        var result = Integer.init(allocator) catch return error.OutOfMemory;
        result.set(1) catch return error.OutOfMemory;
        return h.integerResult(Binder, allocator, result);
    }

    if (exp_c.positive) {
        // Positive exponent: standard modular exponentiation
        const result = modPow(allocator, base_c, exp_c, mod_c) catch return error.OutOfMemory;
        return h.integerResult(Binder, allocator, result);
    }

    // Negative exponent: need modular inverse
    // base == 0 with negative exponent is undefined
    if (base_c.eqlZero()) return error.EvaluationFailure;

    // Reduce base mod m
    var q_tmp = Integer.init(allocator) catch return error.OutOfMemory;
    var reduced_base = Integer.init(allocator) catch return error.OutOfMemory;
    q_tmp.divFloor(&reduced_base, base_int, mod_int) catch return error.OutOfMemory;

    // Check gcd(reduced_base, m) == 1
    var gcd_val = Integer.init(allocator) catch return error.OutOfMemory;
    gcd_val.gcd(&reduced_base, mod_int) catch return error.OutOfMemory;
    if (gcd_val.toConst().orderAgainstScalar(1) != .eq) return error.EvaluationFailure;

    // Compute modular inverse using extended GCD
    const inv = modInverse(allocator, reduced_base.toConst(), mod_c) catch return error.OutOfMemory;

    // Compute inv^|exp| mod m
    const abs_exp = exp_c.abs();
    const result = modPow(allocator, inv.toConst(), abs_exp, mod_c) catch return error.OutOfMemory;
    return h.integerResult(Binder, allocator, result);
}

/// Binary modular exponentiation: base^exp mod m (exp must be positive).
fn modPow(
    allocator: std.mem.Allocator,
    base: std.math.big.int.Const,
    exp: std.math.big.int.Const,
    m: std.math.big.int.Const,
) !Integer {
    var result = try Integer.init(allocator);
    try result.set(1);

    // Reduce base mod m first
    var q_tmp = try Integer.init(allocator);
    var b = try Integer.init(allocator);
    try q_tmp.divFloor(&b, &result, &result); // dummy to have initialized
    // Actually reduce base mod m
    var base_m = try Integer.initSet(allocator, 0);
    base_m.setMetadata(base.positive, base.limbs.len);
    if (base.limbs.len > 0) {
        try base_m.ensureCapacity(base.limbs.len);
        @memcpy(base_m.limbs[0..base.limbs.len], base.limbs);
        base_m.setMetadata(base.positive, base.limbs.len);
    }
    var base_managed = base_m;
    var mod_managed = try Integer.initSet(allocator, 0);
    mod_managed.setMetadata(m.positive, m.limbs.len);
    if (m.limbs.len > 0) {
        try mod_managed.ensureCapacity(m.limbs.len);
        @memcpy(mod_managed.limbs[0..m.limbs.len], m.limbs);
        mod_managed.setMetadata(m.positive, m.limbs.len);
    }

    try q_tmp.divFloor(&b, &base_managed, &mod_managed);
    // b is now base mod m (non-negative because divFloor with positive divisor)

    // Square-and-multiply, scanning bits from high to low
    const bit_count = exp.bitCountAbs();
    var i: usize = bit_count;
    while (i > 0) {
        i -= 1;

        // result = result * result mod m
        var sq = try Integer.init(allocator);
        try sq.mul(&result, &result);
        try q_tmp.divFloor(&result, &sq, &mod_managed);

        // Check if bit i is set
        const limb_idx = i / @bitSizeOf(std.math.big.Limb);
        const bit_idx: std.math.big.Log2Limb = @intCast(i % @bitSizeOf(std.math.big.Limb));
        if (limb_idx < exp.limbs.len and (exp.limbs[limb_idx] >> bit_idx) & 1 == 1) {
            // result = result * b mod m
            var prod = try Integer.init(allocator);
            try prod.mul(&result, &b);
            try q_tmp.divFloor(&result, &prod, &mod_managed);
        }
    }

    return result;
}

/// Compute modular inverse of a mod m using extended GCD.
/// Returns x such that a*x ≡ 1 (mod m).
fn modInverse(
    allocator: std.mem.Allocator,
    a: std.math.big.int.Const,
    m: std.math.big.int.Const,
) !Integer {
    // Extended Euclidean algorithm
    var old_r = try Integer.init(allocator);
    old_r.setMetadata(a.positive, a.limbs.len);
    if (a.limbs.len > 0) {
        try old_r.ensureCapacity(a.limbs.len);
        @memcpy(old_r.limbs[0..a.limbs.len], a.limbs);
        old_r.setMetadata(a.positive, a.limbs.len);
    }

    var r = try Integer.init(allocator);
    r.setMetadata(m.positive, m.limbs.len);
    if (m.limbs.len > 0) {
        try r.ensureCapacity(m.limbs.len);
        @memcpy(r.limbs[0..m.limbs.len], m.limbs);
        r.setMetadata(m.positive, m.limbs.len);
    }

    var old_s = try Integer.initSet(allocator, 1);
    var s = try Integer.initSet(allocator, 0);

    var q_tmp = try Integer.init(allocator);
    var r_tmp = try Integer.init(allocator);

    while (!r.eqlZero()) {
        // q = old_r / r (floor division)
        try q_tmp.divFloor(&r_tmp, &old_r, &r);

        // old_r, r = r, old_r - q * r  (but r_tmp already has the remainder)
        old_r.swap(&r);
        r.swap(&r_tmp);

        // old_s, s = s, old_s - q * s
        var prod = try Integer.init(allocator);
        try prod.mul(&q_tmp, &s);
        var new_s = try Integer.init(allocator);
        try new_s.sub(&old_s, &prod);
        old_s.swap(&s);
        s.swap(&new_s);
    }

    // old_s is the modular inverse, make sure it's positive
    if (!old_s.isPositive()) {
        var m_managed = try Integer.init(allocator);
        m_managed.setMetadata(m.positive, m.limbs.len);
        if (m.limbs.len > 0) {
            try m_managed.ensureCapacity(m.limbs.len);
            @memcpy(m_managed.limbs[0..m.limbs.len], m.limbs);
            m_managed.setMetadata(m.positive, m.limbs.len);
        }
        try old_s.add(&old_s, &m_managed);
    }

    return old_s;
}

pub fn equalsInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    return h.boolResult(Binder, allocator, arg1.toConst().order(arg2.toConst()) == .eq);
}

pub fn lessThanInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    return h.boolResult(Binder, allocator, arg1.toConst().order(arg2.toConst()) == .lt);
}

pub fn lessThanEqualsInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapInteger(Binder, args[0]);
    const arg2 = try h.unwrapInteger(Binder, args[1]);

    const ord = arg1.toConst().order(arg2.toConst());
    return h.boolResult(Binder, allocator, ord == .lt or ord == .eq);
}
