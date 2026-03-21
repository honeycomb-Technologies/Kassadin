//! Constant values in UPLC.
//! These represent literal values that can appear in programs.

const std = @import("std");
const Type = @import("typ.zig").Type;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;
const blst = @import("../crypto/blst.zig");
const value_mod = @import("value.zig");
pub const Value = value_mod.Value;

/// Arbitrary-precision integer.
pub const Integer = std.math.big.int.Managed;

/// Constant values in Untyped Plutus Core.
pub const Constant = union(enum) {
    /// Arbitrary-precision integer
    integer: Integer,
    /// Raw byte string
    byte_string: []const u8,
    /// UTF-8 string
    string: []const u8,
    /// Boolean value
    boolean: bool,
    /// Plutus Data value
    data: *const PlutusData,
    /// Homogeneous list of constants
    proto_list: struct {
        typ: *const Type,
        values: []const *const Constant,
    },
    /// Homogeneous array of constants
    proto_array: struct {
        typ: *const Type,
        values: []const *const Constant,
    },
    /// Pair of two constants
    proto_pair: struct {
        fst_type: *const Type,
        snd_type: *const Type,
        fst: *const Constant,
        snd: *const Constant,
    },
    /// Unit value
    unit,
    /// BLS12-381 G1 curve element (uncompressed, projective coordinates)
    bls12_381_g1_element: blst.P1,
    /// BLS12-381 G2 curve element (uncompressed, projective coordinates)
    bls12_381_g2_element: blst.P2,
    /// BLS12-381 Miller loop result
    bls12_381_ml_result: blst.Fp12,
    /// Multi-asset value
    value: Value,

    /// Create an integer constant from an i64.
    pub fn int(allocator: std.mem.Allocator, value: i64) !*const Constant {
        const c = try allocator.create(Constant);
        var managed = try Integer.init(allocator);
        try managed.set(value);
        c.* = .{ .integer = managed };
        return c;
    }

    /// Create a byte string constant.
    pub fn byteString(allocator: std.mem.Allocator, bytes: []const u8) !*const Constant {
        const c = try allocator.create(Constant);
        const owned = try allocator.dupe(u8, bytes);
        c.* = .{ .byte_string = owned };
        return c;
    }

    /// Create a string constant.
    pub fn str(allocator: std.mem.Allocator, s: []const u8) !*const Constant {
        const c = try allocator.create(Constant);
        const owned = try allocator.dupe(u8, s);
        c.* = .{ .string = owned };
        return c;
    }

    /// Create a boolean constant.
    pub fn boolVal(allocator: std.mem.Allocator, value: bool) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .boolean = value };
        return c;
    }

    /// Create a unit constant.
    pub fn unt(allocator: std.mem.Allocator) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .unit;
        return c;
    }

    /// Create a value constant.
    pub fn val(allocator: std.mem.Allocator, v: Value) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .value = v };
        return c;
    }

    /// Create a data constant.
    pub fn dat(allocator: std.mem.Allocator, d: *const PlutusData) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .data = d };
        return c;
    }

    /// Create a proto list constant.
    pub fn protoList(
        allocator: std.mem.Allocator,
        typ: *const Type,
        values: []const *const Constant,
    ) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .proto_list = .{ .typ = typ, .values = values } };
        return c;
    }

    /// Create a proto array constant.
    pub fn protoArray(
        allocator: std.mem.Allocator,
        typ: *const Type,
        values: []const *const Constant,
    ) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .proto_array = .{ .typ = typ, .values = values } };
        return c;
    }

    /// Create a proto pair constant.
    pub fn protoPair(
        allocator: std.mem.Allocator,
        fst_type: *const Type,
        snd_type: *const Type,
        fst: *const Constant,
        snd: *const Constant,
    ) !*const Constant {
        const c = try allocator.create(Constant);
        c.* = .{ .proto_pair = .{
            .fst_type = fst_type,
            .snd_type = snd_type,
            .fst = fst,
            .snd = snd,
        } };
        return c;
    }

    /// Get the type of this constant.
    pub fn typeOf(self: *const Constant, allocator: std.mem.Allocator) !*const Type {
        return switch (self.*) {
            .integer => Type.int(allocator),
            .byte_string => Type.byteString(allocator),
            .string => Type.str(allocator),
            .boolean => Type.boolean(allocator),
            .data => Type.dat(allocator),
            .unit => Type.unt(allocator),
            .bls12_381_g1_element => Type.g1(allocator),
            .bls12_381_g2_element => Type.g2(allocator),
            .bls12_381_ml_result => Type.mlResult(allocator),
            .value => Type.val(allocator),
            .proto_list => |list| Type.listOf(allocator, list.typ),
            .proto_array => |arr| Type.arrayOf(allocator, arr.typ),
            .proto_pair => |pair| Type.pairOf(allocator, pair.fst_type, pair.snd_type),
        };
    }

    /// Free resources associated with this constant.
    pub fn deinit(self: *Constant, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .integer => |*i| i.deinit(),
            .byte_string => |bytes| allocator.free(bytes),
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

test "integer constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const c = try Constant.int(allocator, 42);
    defer {
        var mc = @constCast(c);
        mc.deinit(allocator);
        allocator.destroy(mc);
    }

    try testing.expect(c.* == .integer);
}

test "boolean constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const c = try Constant.boolVal(allocator, true);
    defer allocator.destroy(c);

    try testing.expectEqual(true, c.boolean);
}

test "unit constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const c = try Constant.unt(allocator);
    defer allocator.destroy(c);

    try testing.expect(c.* == .unit);
}
