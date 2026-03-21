//! Type definitions for UPLC constants.
//! Types are used to annotate constant values in the AST.

const std = @import("std");

/// Represents types in Untyped Plutus Core.
/// These are used to annotate constant values.
pub const Type = union(enum) {
    /// Boolean type
    bool,
    /// Arbitrary-precision integer type
    integer,
    /// UTF-8 string type
    string,
    /// Byte string (raw bytes) type
    byte_string,
    /// Unit type (single value)
    unit,
    /// Homogeneous list type
    list: *const Type,
    /// Homogeneous array type (fixed-size list)
    array: *const Type,
    /// Pair of two values
    pair: struct {
        fst: *const Type,
        snd: *const Type,
    },
    /// Plutus Data type
    data,
    /// BLS12-381 G1 curve element
    bls12_381_g1_element,
    /// BLS12-381 G2 curve element
    bls12_381_g2_element,
    /// BLS12-381 Miller loop result
    bls12_381_ml_result,
    /// Multi-asset value type
    value,

    /// Create an integer type.
    pub fn int(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .integer;
        return t;
    }

    /// Create a bool type.
    pub fn boolean(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .bool;
        return t;
    }

    /// Create a string type.
    pub fn str(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .string;
        return t;
    }

    /// Create a byte string type.
    pub fn byteString(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .byte_string;
        return t;
    }

    /// Create a unit type.
    pub fn unt(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .unit;
        return t;
    }

    /// Create a data type.
    pub fn dat(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .data;
        return t;
    }

    /// Create a list type with the given element type.
    pub fn listOf(allocator: std.mem.Allocator, inner: *const Type) !*const Type {
        const t = try allocator.create(Type);
        t.* = .{ .list = inner };
        return t;
    }

    /// Create an array type with the given element type.
    pub fn arrayOf(allocator: std.mem.Allocator, inner: *const Type) !*const Type {
        const t = try allocator.create(Type);
        t.* = .{ .array = inner };
        return t;
    }

    /// Create a pair type.
    pub fn pairOf(allocator: std.mem.Allocator, fst: *const Type, snd: *const Type) !*const Type {
        const t = try allocator.create(Type);
        t.* = .{ .pair = .{ .fst = fst, .snd = snd } };
        return t;
    }

    /// Create a BLS12-381 G1 element type.
    pub fn g1(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .bls12_381_g1_element;
        return t;
    }

    /// Create a BLS12-381 G2 element type.
    pub fn g2(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .bls12_381_g2_element;
        return t;
    }

    /// Create a BLS12-381 Miller loop result type.
    pub fn mlResult(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .bls12_381_ml_result;
        return t;
    }

    /// Create a value type.
    pub fn val(allocator: std.mem.Allocator) !*const Type {
        const t = try allocator.create(Type);
        t.* = .value;
        return t;
    }

    /// Write the type to a writer.
    pub fn writeTo(self: Type, writer: anytype) !void {
        switch (self) {
            .bool => try writer.writeAll("bool"),
            .integer => try writer.writeAll("integer"),
            .string => try writer.writeAll("string"),
            .byte_string => try writer.writeAll("bytestring"),
            .unit => try writer.writeAll("unit"),
            .data => try writer.writeAll("data"),
            .bls12_381_g1_element => try writer.writeAll("bls12_381_G1_element"),
            .bls12_381_g2_element => try writer.writeAll("bls12_381_G2_element"),
            .bls12_381_ml_result => try writer.writeAll("bls12_381_mlresult"),
            .value => try writer.writeAll("value"),
            .list => |inner| {
                try writer.writeAll("(list ");
                try inner.writeTo(writer);
                try writer.writeByte(')');
            },
            .array => |inner| {
                try writer.writeAll("(array ");
                try inner.writeTo(writer);
                try writer.writeByte(')');
            },
            .pair => |p| {
                try writer.writeAll("(pair ");
                try p.fst.writeTo(writer);
                try writer.writeByte(' ');
                try p.snd.writeTo(writer);
                try writer.writeByte(')');
            },
        }
    }
};

test "type creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const int_type = try Type.int(allocator);
    defer allocator.destroy(int_type);

    try testing.expect(int_type.* == .integer);
}

test "type writeTo" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const int_type = try Type.int(allocator);
    defer allocator.destroy(int_type);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try int_type.writeTo(stream.writer());
    try testing.expectEqualStrings("integer", stream.getWritten());
}
