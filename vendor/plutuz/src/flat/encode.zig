//! Flat binary encoder for UPLC programs.
//!
//! Encodes DeBruijn-indexed UPLC programs into the flat binary format
//! used on-chain for Plutus scripts. This is the exact mirror of decode.zig.

const std = @import("std");
const Managed = std.math.big.int.Managed;
const zigzag_mod = @import("zigzag.zig");
const cbor_encode = @import("../data/cbor/encode.zig");

const DeBruijn = @import("../binder/debruijn.zig").DeBruijn;
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;
const Constant = @import("../ast/constant.zig").Constant;
const Type = @import("../ast/typ.zig").Type;
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;

const DeBruijnTerm = Term(DeBruijn);
const DeBruijnProgram = Program(DeBruijn);

pub const EncodeError = error{OutOfMemory};

/// Flat bit-level encoder state.
pub const Encoder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    current_byte: u8,
    used_bits: u3,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .buffer = .empty,
            .current_byte = 0,
            .used_bits = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }

    /// Write a single bit.
    pub fn bit(self: *Encoder, val: bool) EncodeError!void {
        if (val) {
            self.current_byte |= @as(u8, 128) >> self.used_bits;
        }
        if (self.used_bits == 7) {
            try self.buffer.append(self.allocator, self.current_byte);
            self.current_byte = 0;
            self.used_bits = 0;
        } else {
            self.used_bits += 1;
        }
    }

    /// Write n bits from the low bits of val (MSB first).
    pub fn bits(self: *Encoder, n: u4, val: u8) EncodeError!void {
        var i: u4 = n;
        while (i > 0) {
            i -= 1;
            try self.bit((val & (@as(u8, 1) << @intCast(i))) != 0);
        }
    }

    /// Write 8 bits.
    pub fn byte8(self: *Encoder, val: u8) EncodeError!void {
        try self.bits(8, val);
    }

    /// Write a variable-length unsigned integer (7-bit chunks, MSB = continuation).
    pub fn word(self: *Encoder, val: usize) EncodeError!void {
        var v = val;
        while (true) {
            const chunk: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                try self.byte8(chunk);
                break;
            } else {
                try self.byte8(chunk | 0x80);
            }
        }
    }

    /// Write an arbitrary-precision variable-length unsigned integer.
    pub fn bigWord(self: *Encoder, value: Managed) EncodeError!void {
        const c = value.toConst();
        if (c.eqlZero()) {
            try self.byte8(0);
            return;
        }

        // Extract 7-bit chunks from the big integer
        var temp = Managed.init(self.allocator) catch return error.OutOfMemory;
        defer temp.deinit();
        temp.copy(c) catch return error.OutOfMemory;

        var chunks: std.ArrayList(u8) = .empty;
        defer chunks.deinit(self.allocator);

        while (!temp.toConst().eqlZero()) {
            // Get lowest 7 bits
            const limb = if (temp.toConst().limbs.len > 0) temp.toConst().limbs[0] else 0;
            const chunk: u8 = @intCast(limb & 0x7f);
            chunks.append(self.allocator, chunk) catch return error.OutOfMemory;
            temp.shiftRight(&temp, 7) catch return error.OutOfMemory;
        }

        // Write chunks with continuation bits
        for (chunks.items, 0..) |chunk, i| {
            if (i < chunks.items.len - 1) {
                try self.byte8(chunk | 0x80);
            } else {
                try self.byte8(chunk);
            }
        }
    }

    /// Write a signed arbitrary-precision integer (zigzag + bigWord).
    pub fn integer(self: *Encoder, value: Managed) EncodeError!void {
        var encoded = zigzag_mod.zigzag(self.allocator, value) catch return error.OutOfMemory;
        defer encoded.deinit();
        try self.bigWord(encoded);
    }

    /// Write a chunked byte array (255-byte chunks, 0-length sentinel).
    pub fn byteArray(self: *Encoder, data: []const u8) EncodeError!void {
        // Filler to byte-align
        try self.filler();

        var offset: usize = 0;
        while (offset < data.len) {
            const remaining = data.len - offset;
            const chunk_len: u8 = @intCast(@min(remaining, 255));
            try self.buffer.append(self.allocator, chunk_len);
            try self.buffer.appendSlice(self.allocator, data[offset..][0..chunk_len]);
            offset += chunk_len;
        }
        // 0-length sentinel
        try self.buffer.append(self.allocator, 0);
    }

    /// Write filler bits to align to byte boundary.
    pub fn filler(self: *Encoder) EncodeError!void {
        // Write 0-bits until we can write the 1-bit at a byte boundary
        // The pattern is: 0...01 to reach the next byte boundary
        if (self.used_bits == 0) {
            // Already aligned, write a full padding byte
            try self.buffer.append(self.allocator, 0x01);
        } else {
            // Write remaining bits: 0s then 1
            const remaining = @as(u4, 8) - @as(u4, self.used_bits);
            // Write (remaining-1) zeros then a 1
            for (0..remaining - 1) |_| {
                try self.bit(false);
            }
            try self.bit(true);
        }
    }

    /// Finalize and return the encoded bytes.
    pub fn toOwnedSlice(self: *Encoder) EncodeError![]const u8 {
        return self.buffer.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }
};

/// Encode a DeBruijn program to flat bytes.
pub fn encode(allocator: std.mem.Allocator, program: *const DeBruijnProgram) EncodeError![]const u8 {
    var e = Encoder.init(allocator);
    errdefer e.deinit();

    try encodeProgram(&e, program);

    return e.toOwnedSlice();
}

fn encodeProgram(e: *Encoder, program: *const DeBruijnProgram) EncodeError!void {
    try e.word(program.version.major);
    try e.word(program.version.minor);
    try e.word(program.version.patch);
    try encodeTerm(e, program.term);
    try e.filler();
}

fn encodeTerm(e: *Encoder, term: *const DeBruijnTerm) EncodeError!void {
    switch (term.*) {
        .var_ => |binder| {
            try e.bits(4, 0); // tag 0
            try e.word(binder.index);
        },
        .delay => |body| {
            try e.bits(4, 1); // tag 1
            try encodeTerm(e, body);
        },
        .lambda => |lam| {
            try e.bits(4, 2); // tag 2
            // DeBruijn: no parameter encoded in stream
            try encodeTerm(e, lam.body);
        },
        .apply => |app| {
            try e.bits(4, 3); // tag 3
            try encodeTerm(e, app.function);
            try encodeTerm(e, app.argument);
        },
        .constant => |con| {
            try e.bits(4, 4); // tag 4
            try encodeConstant(e, con);
        },
        .force => |body| {
            try e.bits(4, 5); // tag 5
            try encodeTerm(e, body);
        },
        .err => {
            try e.bits(4, 6); // tag 6
        },
        .builtin => |func| {
            try e.bits(4, 7); // tag 7
            try e.bits(7, @intFromEnum(func));
        },
        .constr => |constr| {
            try e.bits(4, 8); // tag 8
            try e.word(constr.tag);
            try encodeBitPrefixedTermList(e, constr.fields);
        },
        .case => |cas| {
            try e.bits(4, 9); // tag 9
            try encodeTerm(e, cas.constr);
            try encodeBitPrefixedTermList(e, cas.branches);
        },
    }
}

fn encodeBitPrefixedTermList(e: *Encoder, terms: []const *const DeBruijnTerm) EncodeError!void {
    for (terms) |term| {
        try e.bit(true);
        try encodeTerm(e, term);
    }
    try e.bit(false);
}

fn encodeConstant(e: *Encoder, con: *const Constant) EncodeError!void {
    // Encode type tags
    switch (con.*) {
        .integer => {
            try encodeTypeTag(e, 0);
            try encodeTypeEnd(e);
            try e.integer(con.integer);
        },
        .byte_string => {
            try encodeTypeTag(e, 1);
            try encodeTypeEnd(e);
            try e.byteArray(con.byte_string);
        },
        .string => {
            try encodeTypeTag(e, 2);
            try encodeTypeEnd(e);
            try e.byteArray(con.string);
        },
        .unit => {
            try encodeTypeTag(e, 3);
            try encodeTypeEnd(e);
            // no value
        },
        .boolean => {
            try encodeTypeTag(e, 4);
            try encodeTypeEnd(e);
            try e.bit(con.boolean);
        },
        .data => {
            try encodeTypeTag(e, 8);
            try encodeTypeEnd(e);
            const cbor_bytes = cbor_encode.encode(e.allocator, con.data) catch return error.OutOfMemory;
            try e.byteArray(cbor_bytes);
        },
        .proto_list => |list| {
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 5);
            try encodeTypeTags(e, list.typ);
            try encodeTypeEnd(e);
            for (list.values) |val| {
                try e.bit(true);
                try encodeConstantValue(e, list.typ, val);
            }
            try e.bit(false);
        },
        .proto_pair => |pair| {
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 6);
            try encodeTypeTags(e, pair.fst_type);
            try encodeTypeTags(e, pair.snd_type);
            try encodeTypeEnd(e);
            try encodeConstantValue(e, pair.fst_type, pair.fst);
            try encodeConstantValue(e, pair.snd_type, pair.snd);
        },
        else => {
            // BLS types, value, array — not typically found in on-chain flat encoding
            // Encode as error for now
            return error.OutOfMemory;
        },
    }
}

fn encodeTypeTag(e: *Encoder, tag: u4) EncodeError!void {
    try e.bit(true);
    try e.bits(4, tag);
}

fn encodeTypeEnd(e: *Encoder) EncodeError!void {
    try e.bit(false);
}

fn encodeTypeTags(e: *Encoder, typ: *const Type) EncodeError!void {
    switch (typ.*) {
        .integer => try encodeTypeTag(e, 0),
        .byte_string => try encodeTypeTag(e, 1),
        .string => try encodeTypeTag(e, 2),
        .unit => try encodeTypeTag(e, 3),
        .bool => try encodeTypeTag(e, 4),
        .data => try encodeTypeTag(e, 8),
        .list => |inner| {
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 5);
            try encodeTypeTags(e, inner);
        },
        .pair => |p| {
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 7);
            try encodeTypeTag(e, 6);
            try encodeTypeTags(e, p.fst);
            try encodeTypeTags(e, p.snd);
        },
        else => {},
    }
}

fn encodeConstantValue(e: *Encoder, typ: *const Type, con: *const Constant) EncodeError!void {
    switch (typ.*) {
        .integer => try e.integer(con.integer),
        .byte_string => try e.byteArray(con.byte_string),
        .string => try e.byteArray(con.string),
        .unit => {},
        .bool => try e.bit(con.boolean),
        .data => {
            const cbor_bytes = cbor_encode.encode(e.allocator, con.data) catch return error.OutOfMemory;
            try e.byteArray(cbor_bytes);
        },
        .list => |elem_type| {
            if (con.* == .proto_list) {
                for (con.proto_list.values) |val| {
                    try e.bit(true);
                    try encodeConstantValue(e, elem_type, val);
                }
                try e.bit(false);
            }
        },
        .pair => |p| {
            if (con.* == .proto_pair) {
                try encodeConstantValue(e, p.fst, con.proto_pair.fst);
                try encodeConstantValue(e, p.snd, con.proto_pair.snd);
            }
        },
        else => {},
    }
}

// --- Tests ---

const testing = std.testing;

test "encode error term" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const term = try DeBruijnTerm.errorTerm(a);
    const prog = try DeBruijnProgram.create(a, .{ .major = 1, .minor = 0, .patch = 0 }, term);

    const result = try encode(a, prog);
    // Should match: 01 00 00 61
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x61 }, result);
}

test "encode unit constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const con = try Constant.unt(a);
    const term = try DeBruijnTerm.con(a, con);
    const prog = try DeBruijnProgram.create(a, .{ .major = 1, .minor = 0, .patch = 0 }, term);

    const result = try encode(a, prog);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x49, 0x81 }, result);
}

test "encode builtin addInteger" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const term = try DeBruijnTerm.builtinOf(a, .add_integer);
    const prog = try DeBruijnProgram.create(a, .{ .major = 1, .minor = 0, .patch = 0 }, term);

    const result = try encode(a, prog);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x70, 0x01 }, result);
}

test "encode-decode roundtrip error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat_decode = @import("decode.zig");

    const term = try DeBruijnTerm.errorTerm(a);
    const prog = try DeBruijnProgram.create(a, .{ .major = 1, .minor = 0, .patch = 0 }, term);

    const encoded = try encode(a, prog);
    const decoded = try flat_decode.decode(a, encoded);

    try testing.expectEqual(@as(u32, 1), decoded.version.major);
    try testing.expect(decoded.term.* == .err);
}

test "encode-decode roundtrip unit constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat_decode = @import("decode.zig");

    const con = try Constant.unt(a);
    const term = try DeBruijnTerm.con(a, con);
    const prog = try DeBruijnProgram.create(a, .{ .major = 1, .minor = 0, .patch = 0 }, term);

    const encoded = try encode(a, prog);
    const decoded = try flat_decode.decode(a, encoded);

    try testing.expect(decoded.term.* == .constant);
    try testing.expect(decoded.term.constant.* == .unit);
}
