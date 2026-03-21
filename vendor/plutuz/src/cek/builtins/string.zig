const std = @import("std");
const h = @import("helpers.zig");
const Value = h.Value;
const BuiltinError = h.BuiltinError;

pub fn appendString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapString(Binder, args[0]);
    const arg2 = try h.unwrapString(Binder, args[1]);

    const result = allocator.alloc(u8, arg1.len + arg2.len) catch return error.OutOfMemory;
    @memcpy(result[0..arg1.len], arg1);
    @memcpy(result[arg1.len..], arg2);

    return h.stringResult(Binder, allocator, result);
}

pub fn equalsString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapString(Binder, args[0]);
    const arg2 = try h.unwrapString(Binder, args[1]);

    return h.boolResult(Binder, allocator, std.mem.eql(u8, arg1, arg2));
}

pub fn encodeUtf8(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const s = try h.unwrapString(Binder, args[0]);

    // String is already UTF-8, just return as bytestring
    const result = allocator.dupe(u8, s) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn decodeUtf8(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    // Validate UTF-8
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return error.DecodeError;
    }

    const result = allocator.dupe(u8, bytes) catch return error.OutOfMemory;

    return h.stringResult(Binder, allocator, result);
}
