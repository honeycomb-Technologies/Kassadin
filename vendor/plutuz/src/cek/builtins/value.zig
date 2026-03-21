const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const AstValue = h.AstValue;
const BuiltinError = h.BuiltinError;

pub fn insertCoinBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const ccy = try h.unwrapByteString(Binder, args[0]);
    const tok = try h.unwrapByteString(Binder, args[1]);
    const qty_ptr = try h.unwrapInteger(Binder, args[2]);
    const v = try h.unwrapValue(Binder, args[3]);

    // Validate quantity in 128-bit signed range: -(2^127) to (2^127 - 1)
    if (!qty_ptr.eqlZero()) {
        const bits = qty_ptr.bitCountAbs();
        if (bits > 128) return error.EvaluationFailure;
        if (bits == 128) {
            if (qty_ptr.isPositive()) return error.EvaluationFailure;
            // Negative with 128 bits: only -(2^127) is valid
            // Check that absolute value is exactly 2^127 (only bit 127 set)
            const limbs = qty_ptr.toConst().limbs;
            const limb_bits = @bitSizeOf(std.math.big.Limb);
            const target_limb = 127 / limb_bits;
            const target_bit: std.math.Log2Int(std.math.big.Limb) = @intCast(127 % limb_bits);
            for (limbs, 0..) |limb, idx| {
                if (idx == target_limb) {
                    if (limb != (@as(std.math.big.Limb, 1) << target_bit)) return error.EvaluationFailure;
                } else {
                    if (limb != 0) return error.EvaluationFailure;
                }
            }
        }
    }

    // Validate key lengths (> 32 only allowed when qty=0, which is a no-op)
    if (ccy.len > 32 or tok.len > 32) {
        if (qty_ptr.eqlZero()) {
            // qty=0 with long key is a no-op — return the value unchanged
            return h.valueResult(Binder, allocator, v);
        }
        return error.EvaluationFailure;
    }

    // Create a copy of the quantity as Managed for storage
    var qty_copy = Integer.init(allocator) catch return error.OutOfMemory;
    qty_copy.copy(qty_ptr.toConst()) catch return error.OutOfMemory;

    const result = AstValue.insertCoin(allocator, ccy, tok, qty_copy, v) catch return error.OutOfMemory;
    return h.valueResult(Binder, allocator, result);
}

pub fn lookupCoinBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const ccy = try h.unwrapByteString(Binder, args[0]);
    const tok = try h.unwrapByteString(Binder, args[1]);
    const v = try h.unwrapValue(Binder, args[2]);

    const qty = v.lookupCoin(ccy, tok);

    // Copy the result
    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.copy(qty.toConst()) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn unionValueBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const v1 = try h.unwrapValue(Binder, args[0]);
    const v2 = try h.unwrapValue(Binder, args[1]);

    const result = AstValue.unionValue(allocator, v1, v2) catch return error.EvaluationFailure;
    return h.valueResult(Binder, allocator, result);
}

pub fn valueContainsBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const v1 = try h.unwrapValue(Binder, args[0]);
    const v2 = try h.unwrapValue(Binder, args[1]);

    const result = AstValue.valueContains(v1, v2) catch return error.EvaluationFailure;
    return h.boolResult(Binder, allocator, result);
}

pub fn valueDataBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const v = try h.unwrapValue(Binder, args[0]);

    const result = AstValue.valueData(allocator, v) catch return error.OutOfMemory;
    return h.dataResult(Binder, allocator, result);
}

pub fn unValueDataBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const d = try h.unwrapData(Binder, args[0]);

    const result = AstValue.unValueData(allocator, d) catch return error.EvaluationFailure;
    return h.valueResult(Binder, allocator, result);
}

pub fn scaleValueBuiltin(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const scalar = try h.unwrapInteger(Binder, args[0]);
    const v = try h.unwrapValue(Binder, args[1]);

    const result = AstValue.scaleValue(allocator, scalar, v) catch return error.EvaluationFailure;
    return h.valueResult(Binder, allocator, result);
}
