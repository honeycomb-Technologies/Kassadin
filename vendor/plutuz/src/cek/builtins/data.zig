const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Constant = h.Constant;
const Value = h.Value;
const Type = h.Type;
const PlutusData = h.PlutusData;
const BuiltinError = h.BuiltinError;
const cbor = h.cbor;

pub fn chooseData(
    comptime Binder: type,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    return switch (data.*) {
        .constr => args[1],
        .map => args[2],
        .list => args[3],
        .integer => args[4],
        .byte_string => args[5],
    };
}

pub fn constrData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const tag_int = try h.unwrapInteger(Binder, args[0]);
    const fields_list = try h.unwrapList(Binder, args[1]);

    // Tag must be non-negative
    if (!tag_int.isPositive() and !tag_int.eqlZero()) return error.OutOfRange;

    // Convert tag to u64
    const tag = tag_int.toConst().toInt(u64) catch return error.OutOfRange;

    // Convert list of Data constants to PlutusData pointers
    const fields = allocator.alloc(*const PlutusData, fields_list.len) catch return error.OutOfMemory;
    for (fields_list, 0..) |item, i| {
        switch (item.*) {
            .data => |d| fields[i] = d,
            else => return error.TypeMismatch,
        }
    }

    const data = allocator.create(PlutusData) catch return error.OutOfMemory;
    data.* = .{ .constr = .{ .tag = tag, .fields = fields } };

    return h.dataResult(Binder, allocator, data);
}

pub fn mapData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const pairs_list = try h.unwrapList(Binder, args[0]);

    const PlutusDataPair = @import("../../data/plutus_data.zig").PlutusDataPair;

    // Convert list of pairs to PlutusDataPair slice
    const pairs = allocator.alloc(PlutusDataPair, pairs_list.len) catch return error.OutOfMemory;
    for (pairs_list, 0..) |item, i| {
        switch (item.*) {
            .proto_pair => |pair| {
                const key = switch (pair.fst.*) {
                    .data => |d| d,
                    else => return error.TypeMismatch,
                };
                const value = switch (pair.snd.*) {
                    .data => |d| d,
                    else => return error.TypeMismatch,
                };
                pairs[i] = .{ .key = key, .value = value };
            },
            else => return error.TypeMismatch,
        }
    }

    const data = allocator.create(PlutusData) catch return error.OutOfMemory;
    data.* = .{ .map = pairs };

    return h.dataResult(Binder, allocator, data);
}

pub fn listData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const items_list = try h.unwrapList(Binder, args[0]);

    // Convert list of Data constants to PlutusData pointers
    const items = allocator.alloc(*const PlutusData, items_list.len) catch return error.OutOfMemory;
    for (items_list, 0..) |item, i| {
        switch (item.*) {
            .data => |d| items[i] = d,
            else => return error.TypeMismatch,
        }
    }

    const data = allocator.create(PlutusData) catch return error.OutOfMemory;
    data.* = .{ .list = items };

    return h.dataResult(Binder, allocator, data);
}

pub fn iData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const int_arg = try h.unwrapInteger(Binder, args[0]);

    // Clone the integer for the PlutusData
    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.copy(int_arg.toConst()) catch return error.OutOfMemory;

    const data = allocator.create(PlutusData) catch return error.OutOfMemory;
    data.* = .{ .integer = result };

    return h.dataResult(Binder, allocator, data);
}

pub fn bData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    const data = allocator.create(PlutusData) catch return error.OutOfMemory;
    data.* = .{ .byte_string = bytes };

    return h.dataResult(Binder, allocator, data);
}

pub fn unListData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    switch (data.*) {
        .list => |items| {
            const data_type = allocator.create(Type) catch return error.OutOfMemory;
            data_type.* = .data;

            const item_consts = allocator.alloc(*const Constant, items.len) catch return error.OutOfMemory;
            for (items, 0..) |item, i| {
                const c = allocator.create(Constant) catch return error.OutOfMemory;
                c.* = .{ .data = item };
                item_consts[i] = c;
            }

            const list_const = allocator.create(Constant) catch return error.OutOfMemory;
            list_const.* = .{ .proto_list = .{ .typ = data_type, .values = item_consts } };

            const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
            val.* = .{ .constant = list_const };

            return val;
        },
        else => return error.TypeMismatch,
    }
}

pub fn unIData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    switch (data.*) {
        .integer => |int| {
            var result = Integer.init(allocator) catch return error.OutOfMemory;
            result.copy(int.toConst()) catch return error.OutOfMemory;

            return h.integerResult(Binder, allocator, result);
        },
        else => return error.TypeMismatch,
    }
}

pub fn mkPairData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapData(Binder, args[0]);
    const arg2 = try h.unwrapData(Binder, args[1]);

    const data_type = allocator.create(Type) catch return error.OutOfMemory;
    data_type.* = .data;

    const fst = allocator.create(Constant) catch return error.OutOfMemory;
    fst.* = .{ .data = arg1 };
    const snd = allocator.create(Constant) catch return error.OutOfMemory;
    snd.* = .{ .data = arg2 };

    const pair_const = allocator.create(Constant) catch return error.OutOfMemory;
    pair_const.* = .{ .proto_pair = .{
        .fst_type = data_type,
        .snd_type = data_type,
        .fst = fst,
        .snd = snd,
    } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = pair_const };

    return val;
}

pub fn serialiseData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);
    const encoded = cbor.encode.encode(allocator, data) catch return error.OutOfMemory;
    return h.byteStringResult(Binder, allocator, encoded);
}

pub fn mkNilData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    _ = try h.unwrapUnit(Binder, args[0]);

    const data_type = allocator.create(Type) catch return error.OutOfMemory;
    data_type.* = .data;

    const empty = allocator.alloc(*const Constant, 0) catch return error.OutOfMemory;

    const list_const = allocator.create(Constant) catch return error.OutOfMemory;
    list_const.* = .{ .proto_list = .{ .typ = data_type, .values = empty } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = list_const };
    return val;
}

pub fn mkNilPairData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    _ = try h.unwrapUnit(Binder, args[0]);

    const data_type = allocator.create(Type) catch return error.OutOfMemory;
    data_type.* = .data;

    const pair_type = allocator.create(Type) catch return error.OutOfMemory;
    pair_type.* = .{ .pair = .{ .fst = data_type, .snd = data_type } };

    const empty = allocator.alloc(*const Constant, 0) catch return error.OutOfMemory;

    const list_const = allocator.create(Constant) catch return error.OutOfMemory;
    list_const.* = .{ .proto_list = .{ .typ = pair_type, .values = empty } };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = list_const };
    return val;
}

pub fn equalsData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const arg1 = try h.unwrapData(Binder, args[0]);
    const arg2 = try h.unwrapData(Binder, args[1]);

    return h.boolResult(Binder, allocator, arg1.eql(arg2));
}

pub fn unBData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    switch (data.*) {
        .byte_string => |bytes| {
            return h.byteStringResult(Binder, allocator, bytes);
        },
        else => return error.TypeMismatch,
    }
}

pub fn unMapData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    switch (data.*) {
        .map => |pairs| {
            const data_type = allocator.create(Type) catch return error.OutOfMemory;
            data_type.* = .data;

            // Pair type for list element type
            const pair_type = allocator.create(Type) catch return error.OutOfMemory;
            pair_type.* = .{ .pair = .{ .fst = data_type, .snd = data_type } };

            // Convert each map entry to a proto_pair constant
            const pair_consts = allocator.alloc(*const Constant, pairs.len) catch return error.OutOfMemory;
            for (pairs, 0..) |entry, i| {
                const fst = allocator.create(Constant) catch return error.OutOfMemory;
                fst.* = .{ .data = entry.key };
                const snd = allocator.create(Constant) catch return error.OutOfMemory;
                snd.* = .{ .data = entry.value };

                const pair_const = allocator.create(Constant) catch return error.OutOfMemory;
                pair_const.* = .{ .proto_pair = .{
                    .fst_type = data_type,
                    .snd_type = data_type,
                    .fst = fst,
                    .snd = snd,
                } };
                pair_consts[i] = pair_const;
            }

            const list_const = allocator.create(Constant) catch return error.OutOfMemory;
            list_const.* = .{ .proto_list = .{ .typ = pair_type, .values = pair_consts } };

            const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
            val.* = .{ .constant = list_const };

            return val;
        },
        else => return error.TypeMismatch,
    }
}

pub fn unConstrData(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const data = try h.unwrapData(Binder, args[0]);

    switch (data.*) {
        .constr => |constr| {
            // Create integer constant for the tag
            var tag_int = Integer.init(allocator) catch return error.OutOfMemory;
            tag_int.set(constr.tag) catch return error.OutOfMemory;
            const tag_const = allocator.create(Constant) catch return error.OutOfMemory;
            tag_const.* = .{ .integer = tag_int };

            // Create list of data constants for the fields
            const field_consts = allocator.alloc(*const Constant, constr.fields.len) catch return error.OutOfMemory;
            for (constr.fields, 0..) |field, i| {
                const fc = allocator.create(Constant) catch return error.OutOfMemory;
                fc.* = .{ .data = field };
                field_consts[i] = fc;
            }

            // Create the data type
            const data_type = allocator.create(Type) catch return error.OutOfMemory;
            data_type.* = .data;
            const int_type = allocator.create(Type) catch return error.OutOfMemory;
            int_type.* = .integer;
            const list_type = allocator.create(Type) catch return error.OutOfMemory;
            list_type.* = .{ .list = data_type };

            const fields_const = allocator.create(Constant) catch return error.OutOfMemory;
            fields_const.* = .{ .proto_list = .{ .typ = data_type, .values = field_consts } };

            // Create the pair
            const pair_const = allocator.create(Constant) catch return error.OutOfMemory;
            pair_const.* = .{ .proto_pair = .{
                .fst_type = int_type,
                .snd_type = list_type,
                .fst = tag_const,
                .snd = fields_const,
            } };

            const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
            val.* = .{ .constant = pair_const };

            return val;
        },
        else => return error.TypeMismatch,
    }
}
