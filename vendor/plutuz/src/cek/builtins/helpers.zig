const std = @import("std");
const constant_mod = @import("../../ast/constant.zig");
pub const Constant = constant_mod.Constant;
pub const Integer = constant_mod.Integer;
pub const Value = @import("../value.zig").Value;
pub const Type = @import("../../ast/typ.zig").Type;
pub const PlutusData = @import("../../data/plutus_data.zig").PlutusData;
pub const blst = @import("../../crypto/blst.zig");
pub const AstValue = @import("../../ast/value.zig").Value;
pub const cbor = @import("../../data/cbor.zig");

pub const BuiltinError = error{
    TypeMismatch,
    OutOfMemory,
    OutOfBudget,
    DivisionByZero,
    OutOfRange,
    DecodeError,
    EvaluationFailure,
};

// ===== Unwrap Helpers =====

pub fn unwrapInteger(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const Integer {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .integer => |*int_val| return @constCast(int_val),
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn toI64Clamped(int: *const Integer) i64 {
    const max_i64: i64 = std.math.maxInt(i64);
    const min_i64: i64 = std.math.minInt(i64);
    return int.toConst().toInt(i64) catch {
        return if (int.isPositive()) max_i64 else min_i64;
    };
}

pub fn unwrapByteString(comptime Binder: type, value: *const Value(Binder)) BuiltinError![]const u8 {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .byte_string => |bytes| return bytes,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapString(comptime Binder: type, value: *const Value(Binder)) BuiltinError![]const u8 {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .string => |s| return s,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapBool(comptime Binder: type, value: *const Value(Binder)) BuiltinError!bool {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .boolean => |b| return b,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapUnit(comptime Binder: type, value: *const Value(Binder)) BuiltinError!void {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .unit => return,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub const PairData = struct {
    fst: *const Constant,
    snd: *const Constant,
};

pub fn unwrapPair(comptime Binder: type, value: *const Value(Binder)) BuiltinError!PairData {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .proto_pair => |pair| return .{ .fst = pair.fst, .snd = pair.snd },
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapArray(comptime Binder: type, value: *const Value(Binder)) BuiltinError![]const *const Constant {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .proto_array => |arr| return arr.values,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapList(comptime Binder: type, value: *const Value(Binder)) BuiltinError![]const *const Constant {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .proto_list => |list| return list.values,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub const ListData = struct {
    typ: *const Type,
    values: []const *const Constant,
};

pub fn unwrapListWithType(comptime Binder: type, value: *const Value(Binder)) BuiltinError!ListData {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .proto_list => |list| return .{ .typ = list.typ, .values = list.values },
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn typeEql(a: *const Type, b: *const Type) bool {
    const tag_a = std.meta.activeTag(a.*);
    const tag_b = std.meta.activeTag(b.*);
    if (tag_a != tag_b) return false;
    return switch (a.*) {
        .list => |inner_a| typeEql(inner_a, b.list),
        .array => |inner_a| typeEql(inner_a, b.array),
        .pair => |pa| typeEql(pa.fst, b.pair.fst) and typeEql(pa.snd, b.pair.snd),
        else => true,
    };
}

pub fn unwrapConstant(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const Constant {
    switch (value.*) {
        .constant => |c| return c,
        else => return error.TypeMismatch,
    }
}

pub fn unwrapG1Element(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const blst.P1 {
    const val = switch (value.*) {
        .constant => |c| c,
        else => return error.TypeMismatch,
    };
    return switch (val.*) {
        .bls12_381_g1_element => |*p| p,
        else => error.TypeMismatch,
    };
}

pub fn unwrapG2Element(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const blst.P2 {
    const val = switch (value.*) {
        .constant => |cc| cc,
        else => return error.TypeMismatch,
    };
    return switch (val.*) {
        .bls12_381_g2_element => |*p| p,
        else => error.TypeMismatch,
    };
}

pub fn unwrapMlResult(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const blst.Fp12 {
    const val = switch (value.*) {
        .constant => |cc| cc,
        else => return error.TypeMismatch,
    };
    return switch (val.*) {
        .bls12_381_ml_result => |*p| p,
        else => error.TypeMismatch,
    };
}

pub fn unwrapData(comptime Binder: type, value: *const Value(Binder)) BuiltinError!*const PlutusData {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .data => |d| return d,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

pub fn unwrapValue(comptime Binder: type, value: *const Value(Binder)) BuiltinError!AstValue {
    switch (value.*) {
        .constant => |c| {
            switch (c.*) {
                .value => |v| return v,
                else => return error.TypeMismatch,
            }
        },
        else => return error.TypeMismatch,
    }
}

// ===== Result Helpers =====

pub fn integerResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: Integer,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .integer = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn boolResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: bool,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .boolean = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn byteStringResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: []const u8,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .byte_string = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn stringResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: []const u8,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .string = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn dataResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: *const PlutusData,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .data = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn g1Result(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    point: blst.P1,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .bls12_381_g1_element = point };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn g2Result(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    point: blst.P2,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .bls12_381_g2_element = point };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn mlResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    fp12: blst.Fp12,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .bls12_381_ml_result = fp12 };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}

pub fn valueResult(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    result: AstValue,
) BuiltinError!*const Value(Binder) {
    const constant = allocator.create(Constant) catch return error.OutOfMemory;
    constant.* = .{ .value = result };

    const val = allocator.create(Value(Binder)) catch return error.OutOfMemory;
    val.* = .{ .constant = constant };

    return val;
}
