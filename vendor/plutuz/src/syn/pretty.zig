//! Pretty printer for UPLC terms.
//! Converts AST back to source code format.

const std = @import("std");
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;
const Version = @import("../ast/program.zig").Version;
const Constant = @import("../ast/constant.zig").Constant;
const Value = @import("../ast/constant.zig").Value;
const Type = @import("../ast/typ.zig").Type;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;
const blst = @import("../crypto/blst.zig");

/// Pretty print a program to a writer.
pub fn printProgram(comptime Binder: type, program: *const Program(Binder), writer: anytype, allocator: std.mem.Allocator) !void {
    try writer.writeAll("(program ");
    try program.version.writeTo(writer);
    try writer.writeAll(" ");
    try printTerm(Binder, program.term, writer, allocator);
    try writer.writeAll(")");
}

/// Pretty print a term to a writer.
pub fn printTerm(comptime Binder: type, term: *const Term(Binder), writer: anytype, allocator: std.mem.Allocator) !void {
    switch (term.*) {
        .var_ => |binder_val| {
            try binder_val.writeTo(writer);
        },
        .lambda => |lam| {
            try writer.writeAll("(lam ");
            try lam.parameter.writeTo(writer);
            try writer.writeAll(" ");
            try printTerm(Binder, lam.body, writer, allocator);
            try writer.writeAll(")");
        },
        .apply => |app| {
            try writer.writeAll("[");
            try printTerm(Binder, app.function, writer, allocator);
            try writer.writeAll(" ");
            try printTerm(Binder, app.argument, writer, allocator);
            try writer.writeAll("]");
        },
        .delay => |inner| {
            try writer.writeAll("(delay ");
            try printTerm(Binder, inner, writer, allocator);
            try writer.writeAll(")");
        },
        .force => |inner| {
            try writer.writeAll("(force ");
            try printTerm(Binder, inner, writer, allocator);
            try writer.writeAll(")");
        },
        .case => |c| {
            try writer.writeAll("(case ");
            try printTerm(Binder, c.constr, writer, allocator);
            for (c.branches) |branch| {
                try writer.writeAll(" ");
                try printTerm(Binder, branch, writer, allocator);
            }
            try writer.writeAll(")");
        },
        .constr => |c| {
            try writer.print("(constr {d}", .{c.tag});
            for (c.fields) |field| {
                try writer.writeAll(" ");
                try printTerm(Binder, field, writer, allocator);
            }
            try writer.writeAll(")");
        },
        .constant => |con| {
            try writer.writeAll("(con ");
            try printConstant(con, writer, allocator);
            try writer.writeAll(")");
        },
        .builtin => |b| {
            try writer.writeAll("(builtin ");
            try printBuiltinName(b, writer);
            try writer.writeAll(")");
        },
        .err => {
            try writer.writeAll("(error)");
        },
    }
}

/// Pretty print a constant value.
/// Print a constant's value without the type prefix, used inside proto_list/proto_pair
/// where the type is already declared in the container. For data constants this means
/// printing just the PlutusData value directly (e.g. `I 0`) instead of `data (I 0)`.
fn printConstantInner(constant: *const Constant, writer: anytype, allocator: std.mem.Allocator) (@TypeOf(writer).Error || error{OutOfMemory})!void {
    switch (constant.*) {
        .data => |d| try printPlutusData(d, writer, allocator),
        else => try printConstant(constant, writer, allocator),
    }
}

fn printConstant(constant: *const Constant, writer: anytype, allocator: std.mem.Allocator) !void {
    switch (constant.*) {
        .integer => |int_val| {
            try writer.writeAll("integer ");
            const str = try int_val.toConst().toStringAlloc(allocator, 10, .lower);
            defer allocator.free(str);
            try writer.writeAll(str);
        },
        .byte_string => |bytes| {
            try writer.writeAll("bytestring #");
            for (bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
        .string => |s| {
            try writer.writeAll("string \"");
            try writeEscapedString(s, writer);
            try writer.writeAll("\"");
        },
        .boolean => |b| {
            try writer.writeAll("bool ");
            try writer.writeAll(if (b) "True" else "False");
        },
        .unit => {
            try writer.writeAll("unit ()");
        },
        .data => |d| {
            try writer.writeAll("data (");
            try printPlutusData(d, writer, allocator);
            try writer.writeAll(")");
        },
        .proto_list => |list| {
            try writer.writeAll("(list ");
            try list.typ.writeTo(writer);
            try writer.writeAll(") [");
            for (list.values, 0..) |val, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try printConstantInner(val, writer, allocator);
            }
            try writer.writeAll("]");
        },
        .proto_array => |arr| {
            try writer.writeAll("(array ");
            try arr.typ.writeTo(writer);
            try writer.writeAll(") [");
            for (arr.values, 0..) |val, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try printConstantInner(val, writer, allocator);
            }
            try writer.writeAll("]");
        },
        .proto_pair => |pair_val| {
            try writer.writeAll("(pair ");
            try pair_val.fst_type.writeTo(writer);
            try writer.writeAll(" ");
            try pair_val.snd_type.writeTo(writer);
            try writer.writeAll(") (");
            try printConstantInner(pair_val.fst, writer, allocator);
            try writer.writeAll(", ");
            try printConstantInner(pair_val.snd, writer, allocator);
            try writer.writeAll(")");
        },
        .bls12_381_g1_element => |point| {
            try writer.writeAll("bls12_381_G1_element 0x");
            const bytes = blst.compressG1(&point);
            for (bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
        .bls12_381_g2_element => |point| {
            try writer.writeAll("bls12_381_G2_element 0x");
            const bytes = blst.compressG2(&point);
            for (bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
        .bls12_381_ml_result => |_| {
            try writer.writeAll("bls12_381_mlresult ...");
        },
        .value => |v| {
            try writer.writeAll("value [");
            for (v.entries, 0..) |entry, cidx| {
                if (cidx > 0) try writer.writeAll(", ");
                try writer.writeAll("(#");
                for (entry.currency) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                try writer.writeAll(", [");
                for (entry.tokens, 0..) |token, tidx| {
                    if (tidx > 0) try writer.writeAll(", ");
                    try writer.writeAll("(#");
                    for (token.name) |byte| {
                        try writer.print("{x:0>2}", .{byte});
                    }
                    try writer.writeAll(", ");
                    const qty_str = try token.quantity.toConst().toStringAlloc(allocator, 10, .lower);
                    defer allocator.free(qty_str);
                    try writer.writeAll(qty_str);
                    try writer.writeAll(")");
                }
                try writer.writeAll("])");
            }
            try writer.writeAll("]");
        },
    }
}

/// Pretty print a PlutusData value.
fn printPlutusData(d: *const PlutusData, writer: anytype, allocator: std.mem.Allocator) !void {
    switch (d.*) {
        .integer => |int_val| {
            try writer.writeAll("I ");
            const str = try int_val.toConst().toStringAlloc(allocator, 10, .lower);
            defer allocator.free(str);
            try writer.writeAll(str);
        },
        .byte_string => |bytes| {
            try writer.writeAll("B #");
            for (bytes) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
        .list => |items| {
            try writer.writeAll("List [");
            for (items, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try printPlutusData(item, writer, allocator);
            }
            try writer.writeAll("]");
        },
        .map => |pairs| {
            try writer.writeAll("Map [");
            for (pairs, 0..) |pair, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writer.writeAll("(");
                try printPlutusData(pair.key, writer, allocator);
                try writer.writeAll(", ");
                try printPlutusData(pair.value, writer, allocator);
                try writer.writeAll(")");
            }
            try writer.writeAll("]");
        },
        .constr => |c| {
            try writer.print("Constr {d} [", .{c.tag});
            for (c.fields, 0..) |field, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try printPlutusData(field, writer, allocator);
            }
            try writer.writeAll("]");
        },
    }
}

/// Write a string with proper escaping for special characters.
fn writeEscapedString(s: []const u8, writer: anytype) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            '\x07' => try writer.writeAll("\\a"), // bell
            '\x08' => try writer.writeAll("\\b"), // backspace
            '\x0c' => try writer.writeAll("\\f"), // form feed
            '\x0b' => try writer.writeAll("\\v"), // vertical tab
            0x7f => try writer.writeAll("\\DEL"),
            else => {
                if (c < 0x20) {
                    // Other control characters - use hex escape
                    try writer.print("\\x{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Pretty print a builtin function name in camelCase.
fn printBuiltinName(builtin_val: anytype, writer: anytype) !void {
    const name = @tagName(builtin_val);
    var first = true;
    var capitalize_next = false;

    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else if (capitalize_next) {
            try writer.writeByte(std.ascii.toUpper(c));
            capitalize_next = false;
        } else if (first) {
            try writer.writeByte(c);
            first = false;
        } else {
            try writer.writeByte(c);
        }
    }
}

test "pretty print boolean constant" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const c = try Constant.boolVal(allocator, true);
    defer allocator.destroy(c);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try printConstant(c, stream.writer(), allocator);

    try testing.expectEqualStrings("bool True", stream.getWritten());
}

test "pretty print builtin name" {
    const testing = std.testing;
    const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;

    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try printBuiltinName(DefaultFunction.add_integer, stream.writer());
    try testing.expectEqualStrings("addInteger", stream.getWritten());
}
