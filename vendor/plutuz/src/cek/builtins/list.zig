const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Constant = h.Constant;
const Value = h.Value;
const BuiltinError = h.BuiltinError;

pub fn ifThenElse(
    comptime Binder: type,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const cond = try h.unwrapBool(Binder, args[0]);

    return if (cond) args[1] else args[2];
}

pub fn chooseUnit(
    comptime Binder: type,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    try h.unwrapUnit(Binder, args[0]);

    return args[1];
}

pub fn trace(
    comptime Binder: type,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    // Validate first arg is string (the trace message)
    _ = try h.unwrapString(Binder, args[0]);

    // TODO: actually log the message somewhere
    return args[1];
}

pub fn fstPair(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const pair = try h.unwrapPair(Binder, args[0]);

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = pair.fst };

    return val;
}

pub fn sndPair(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const pair = try h.unwrapPair(Binder, args[0]);

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = pair.snd };

    return val;
}

pub fn chooseList(
    comptime Binder: type,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const list = try h.unwrapList(Binder, args[0]);

    return if (list.len == 0) args[1] else args[2];
}

pub fn mkCons(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const elem = try h.unwrapConstant(Binder, args[0]);
    const list_data = try h.unwrapListWithType(Binder, args[1]);

    // Verify element type matches list element type
    const elem_type = elem.typeOf(allocator) catch return error.OutOfMemory;
    if (!h.typeEql(elem_type, list_data.typ)) return error.TypeMismatch;

    // Create new list with element prepended
    const new_values = allocator.alloc(*const Constant, list_data.values.len + 1) catch return error.OutOfMemory;
    new_values[0] = elem;
    @memcpy(new_values[1..], list_data.values);

    const new_list = allocator.create(Constant) catch return error.OutOfMemory;
    new_list.* = .{ .proto_list = .{ .typ = list_data.typ, .values = new_values } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = new_list };

    return val;
}

pub fn headList(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const list = try h.unwrapList(Binder, args[0]);

    if (list.len == 0) return error.OutOfRange;

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = list[0] };

    return val;
}

pub fn tailList(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const list_data = try h.unwrapListWithType(Binder, args[0]);

    if (list_data.values.len == 0) return error.OutOfRange;

    const new_list = allocator.create(Constant) catch return error.OutOfMemory;
    new_list.* = .{ .proto_list = .{ .typ = list_data.typ, .values = list_data.values[1..] } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = new_list };

    return val;
}

pub fn dropList(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const n_int = try h.unwrapInteger(Binder, args[0]);
    const list_data = try h.unwrapListWithType(Binder, args[1]);

    // Negative n treated as 0 (return list unchanged)
    const n: usize = if (!n_int.isPositive())
        0
    else
        std.math.cast(usize, n_int.toConst().toInt(i64) catch std.math.maxInt(i64)) orelse list_data.values.len;

    const start = @min(n, list_data.values.len);

    const new_list = allocator.create(Constant) catch return error.OutOfMemory;
    new_list.* = .{ .proto_list = .{ .typ = list_data.typ, .values = list_data.values[start..] } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = new_list };

    return val;
}

pub fn lengthOfArray(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arr = try h.unwrapArray(Binder, args[0]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.set(arr.len) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn listToArray(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const list_data = try h.unwrapListWithType(Binder, args[0]);

    const c = allocator.create(Constant) catch return error.OutOfMemory;
    c.* = .{ .proto_array = .{ .typ = list_data.typ, .values = list_data.values } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = c };

    return val;
}

pub fn indexArray(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arr = try h.unwrapArray(Binder, args[0]);
    const idx_int = try h.unwrapInteger(Binder, args[1]);

    const idx = std.math.cast(usize, idx_int.toConst().toInt(i64) catch return error.EvaluationFailure) orelse return error.EvaluationFailure;
    if (idx >= arr.len) return error.EvaluationFailure;

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = arr[idx] };

    return val;
}

pub fn nullList(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const list = try h.unwrapList(Binder, args[0]);

    return h.boolResult(Binder, allocator, list.len == 0);
}
