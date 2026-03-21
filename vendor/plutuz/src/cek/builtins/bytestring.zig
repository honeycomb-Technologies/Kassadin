const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const BuiltinError = h.BuiltinError;
const SemanticsVariant = @import("../semantics.zig").SemanticsVariant;

pub fn appendByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapByteString(Binder, args[0]);
    const arg2 = try h.unwrapByteString(Binder, args[1]);

    const result = allocator.alloc(u8, arg1.len + arg2.len) catch return error.OutOfMemory;
    @memcpy(result[0..arg1.len], arg1);
    @memcpy(result[arg1.len..], arg2);

    return h.byteStringResult(Binder, allocator, result);
}

pub fn consByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    semantics: SemanticsVariant,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const int_arg = try h.unwrapInteger(Binder, args[0]);
    const bytes = try h.unwrapByteString(Binder, args[1]);

    // Convert to i64
    const int_val = int_arg.toConst().toInt(i64) catch return error.OutOfRange;

    // Apply semantics-dependent byte conversion
    const byte_val: u8 = switch (semantics) {
        .a, .b => blk: {
            // V1/V2: Use floored modulo to wrap to 0-255
            var wrapped = @mod(int_val, 256);
            if (wrapped < 0) wrapped += 256;
            break :blk @intCast(wrapped);
        },
        .c => blk: {
            // V3+: Require strict 0-255 range
            if (int_val < 0 or int_val > 255) return error.OutOfRange;
            break :blk @intCast(int_val);
        },
    };

    const result = allocator.alloc(u8, bytes.len + 1) catch return error.OutOfMemory;
    result[0] = byte_val;
    @memcpy(result[1..], bytes);

    return h.byteStringResult(Binder, allocator, result);
}

pub fn sliceByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const skip_arg = try h.unwrapInteger(Binder, args[0]);
    const take_arg = try h.unwrapInteger(Binder, args[1]);
    const bytes = try h.unwrapByteString(Binder, args[2]);

    // Convert to i64, clamping large values (large positive -> maxInt, negative/0 handled below)
    const skip_i64 = h.toI64Clamped(skip_arg);
    const take_i64 = h.toI64Clamped(take_arg);

    // Negative values become 0
    const skip: usize = if (skip_i64 <= 0) 0 else @min(std.math.cast(usize, skip_i64) orelse bytes.len, bytes.len);
    const take: usize = if (take_i64 <= 0) 0 else @min(std.math.cast(usize, take_i64) orelse bytes.len, bytes.len -| skip);

    const result = allocator.dupe(u8, bytes[skip..][0..take]) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn lengthOfByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.set(@as(i64, @intCast(bytes.len))) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn equalsByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapByteString(Binder, args[0]);
    const arg2 = try h.unwrapByteString(Binder, args[1]);

    return h.boolResult(Binder, allocator, std.mem.eql(u8, arg1, arg2));
}

pub fn lessThanEqualsByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapByteString(Binder, args[0]);
    const arg2 = try h.unwrapByteString(Binder, args[1]);

    const ord = std.mem.order(u8, arg1, arg2);
    return h.boolResult(Binder, allocator, ord == .lt or ord == .eq);
}

pub fn lessThanByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapByteString(Binder, args[0]);
    const arg2 = try h.unwrapByteString(Binder, args[1]);

    return h.boolResult(Binder, allocator, std.mem.order(u8, arg1, arg2) == .lt);
}
