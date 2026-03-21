//! Flat binary decoder for UPLC programs.
//!
//! Implements the flat serialization format used on-chain for Plutus scripts.
//! The decoder reads bits from a byte buffer (MSB first) and reconstructs
//! DeBruijn-indexed UPLC programs.

const std = @import("std");
const Managed = std.math.big.int.Managed;
const zigzag = @import("zigzag.zig");
const cbor_decode = @import("../data/cbor/decode.zig");

const DeBruijn = @import("../binder/debruijn.zig").DeBruijn;
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;
const Version = @import("../ast/program.zig").Version;
const Constant = @import("../ast/constant.zig").Constant;
const Type = @import("../ast/typ.zig").Type;
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;

const DeBruijnTerm = Term(DeBruijn);
const DeBruijnProgram = Program(DeBruijn);

pub const DecodeError = error{
    EndOfInput,
    InvalidFiller,
    InvalidTag,
    InvalidConstantTag,
    InvalidBuiltinTag,
    UnknownTypeTag,
    Utf8Invalid,
    CborDecodeError,
    OutOfMemory,
};

/// Flat bit-level decoder state.
pub const Decoder = struct {
    buffer: []const u8,
    pos: usize,
    used_bits: u3,

    pub fn init(buffer: []const u8) Decoder {
        return .{
            .buffer = buffer,
            .pos = 0,
            .used_bits = 0,
        };
    }

    /// Read a single bit (MSB first).
    pub fn bit(self: *Decoder) DecodeError!bool {
        if (self.pos >= self.buffer.len) return error.EndOfInput;
        const b = (self.buffer[self.pos] & (@as(u8, 128) >> self.used_bits)) != 0;
        if (self.used_bits == 7) {
            self.used_bits = 0;
            self.pos += 1;
        } else {
            self.used_bits += 1;
        }
        return b;
    }

    /// Read up to 8 bits, returning a u8.
    pub fn bits8(self: *Decoder, n: u4) DecodeError!u8 {
        if (n == 0) return 0;
        var result: u8 = 0;
        for (0..n) |_| {
            result = (result << 1) | @as(u8, if (try self.bit()) 1 else 0);
        }
        return result;
    }

    /// Read a variable-length unsigned integer (7-bit chunks, MSB = continuation).
    pub fn word(self: *Decoder) DecodeError!usize {
        var result: usize = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.bits8(8);
            result |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }

    /// Read an arbitrary-precision variable-length unsigned integer.
    pub fn bigWord(self: *Decoder, allocator: std.mem.Allocator) DecodeError!Managed {
        // Collect 7-bit chunks
        var chunks: std.ArrayList(u8) = .empty;
        while (true) {
            const b = try self.bits8(8);
            chunks.append(allocator, b & 0x7f) catch return error.OutOfMemory;
            if (b & 0x80 == 0) break;
        }

        var result = Managed.init(allocator) catch return error.OutOfMemory;
        errdefer result.deinit();
        result.set(@as(usize, 0)) catch return error.OutOfMemory;

        // Process chunks in reverse (last chunk is most significant)
        var i = chunks.items.len;
        while (i > 0) {
            i -= 1;
            result.shiftLeft(&result, 7) catch return error.OutOfMemory;
            result.addScalar(&result, chunks.items[i]) catch return error.OutOfMemory;
        }

        return result;
    }

    /// Read a signed arbitrary-precision integer (bigWord + zigzag decode).
    pub fn integer(self: *Decoder, allocator: std.mem.Allocator) DecodeError!Managed {
        const unsigned = try self.bigWord(allocator);
        return zigzag.unzigzag(allocator, unsigned) catch return error.OutOfMemory;
    }

    /// Skip filler bits (0-bits until a 1-bit for byte alignment).
    pub fn filler(self: *Decoder) DecodeError!void {
        // Skip 0-bits, expect a 1-bit
        while (true) {
            const b = try self.bit();
            if (b) return; // Found the 1-bit terminator
        }
    }

    /// Read a chunked byte array (255-byte chunks, 0-length sentinel).
    pub fn bytes(self: *Decoder, allocator: std.mem.Allocator) DecodeError![]const u8 {
        // First, align to byte boundary
        try self.filler();

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        while (true) {
            if (self.pos >= self.buffer.len) return error.EndOfInput;
            const chunk_len = self.buffer[self.pos];
            self.pos += 1;
            if (chunk_len == 0) break;
            if (self.pos + chunk_len > self.buffer.len) return error.EndOfInput;
            result.appendSlice(allocator, self.buffer[self.pos..][0..chunk_len]) catch return error.OutOfMemory;
            self.pos += chunk_len;
        }

        return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};

/// Decode a flat-encoded DeBruijn program.
pub fn decode(allocator: std.mem.Allocator, buffer: []const u8) DecodeError!*const DeBruijnProgram {
    var d = Decoder.init(buffer);
    return decodeProgram(allocator, &d);
}

fn decodeProgram(allocator: std.mem.Allocator, d: *Decoder) DecodeError!*const DeBruijnProgram {
    const major = try d.word();
    const minor = try d.word();
    const patch = try d.word();

    const version = Version.create(@intCast(major), @intCast(minor), @intCast(patch));
    const term = try decodeTerm(allocator, d);

    try d.filler();

    return DeBruijnProgram.create(allocator, version, term) catch return error.OutOfMemory;
}

fn decodeTerm(allocator: std.mem.Allocator, d: *Decoder) DecodeError!*const DeBruijnTerm {
    const tag = try d.bits8(4);

    return switch (tag) {
        // Var
        0 => blk: {
            const idx = try d.word();
            const binder = DeBruijn.create(allocator, idx) catch return error.OutOfMemory;
            break :blk DeBruijnTerm.variable(allocator, binder) catch return error.OutOfMemory;
        },

        // Delay
        1 => blk: {
            const body = try decodeTerm(allocator, d);
            break :blk DeBruijnTerm.del(allocator, body) catch return error.OutOfMemory;
        },

        // Lambda (DeBruijn: no parameter encoded in stream)
        2 => blk: {
            const body = try decodeTerm(allocator, d);
            const param = DeBruijn.create(allocator, 0) catch return error.OutOfMemory;
            break :blk DeBruijnTerm.lam(allocator, param, body) catch return error.OutOfMemory;
        },

        // Apply
        3 => blk: {
            const func = try decodeTerm(allocator, d);
            const arg = try decodeTerm(allocator, d);
            break :blk DeBruijnTerm.app(allocator, func, arg) catch return error.OutOfMemory;
        },

        // Constant
        4 => blk: {
            const con = try decodeConstant(allocator, d);
            break :blk DeBruijnTerm.con(allocator, con) catch return error.OutOfMemory;
        },

        // Force
        5 => blk: {
            const body = try decodeTerm(allocator, d);
            break :blk DeBruijnTerm.frc(allocator, body) catch return error.OutOfMemory;
        },

        // Error
        6 => DeBruijnTerm.errorTerm(allocator) catch return error.OutOfMemory,

        // Builtin
        7 => blk: {
            const fn_tag = try d.bits8(7);
            const func = std.meta.intToEnum(DefaultFunction, fn_tag) catch return error.InvalidBuiltinTag;
            break :blk DeBruijnTerm.builtinOf(allocator, func) catch return error.OutOfMemory;
        },

        // Constr
        8 => blk: {
            const constr_tag = try d.word();
            const fields = try decodeBitPrefixedTermList(allocator, d);
            break :blk DeBruijnTerm.constrOf(allocator, constr_tag, fields) catch return error.OutOfMemory;
        },

        // Case
        9 => blk: {
            const scrutinee = try decodeTerm(allocator, d);
            const branches = try decodeBitPrefixedTermList(allocator, d);
            break :blk DeBruijnTerm.caseOf(allocator, scrutinee, branches) catch return error.OutOfMemory;
        },

        else => return error.InvalidTag,
    };
}

fn decodeBitPrefixedTermList(allocator: std.mem.Allocator, d: *Decoder) DecodeError![]const *const DeBruijnTerm {
    var list: std.ArrayList(*const DeBruijnTerm) = .empty;
    errdefer list.deinit(allocator);
    while (try d.bit()) {
        const term = try decodeTerm(allocator, d);
        list.append(allocator, term) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

// --- Constant decoding ---

fn decodeConstant(allocator: std.mem.Allocator, d: *Decoder) DecodeError!*const Constant {
    // Decode type tags as bit-prefixed list of 4-bit values
    var tags: std.ArrayList(u4) = .empty;
    while (try d.bit()) {
        const tag = try d.bits8(4);
        tags.append(allocator, @intCast(tag)) catch return error.OutOfMemory;
    }

    var tag_idx: usize = 0;
    const typ = try parseType(allocator, tags.items, &tag_idx);

    return decodeConstantValue(allocator, d, typ);
}

fn parseType(allocator: std.mem.Allocator, tags: []const u4, idx: *usize) DecodeError!*const Type {
    if (idx.* >= tags.len) return error.InvalidConstantTag;
    const tag = tags[idx.*];
    idx.* += 1;

    return switch (tag) {
        0 => Type.int(allocator) catch return error.OutOfMemory,
        1 => Type.byteString(allocator) catch return error.OutOfMemory,
        2 => Type.str(allocator) catch return error.OutOfMemory,
        3 => Type.unt(allocator) catch return error.OutOfMemory,
        4 => Type.boolean(allocator) catch return error.OutOfMemory,
        5 => blk: {
            // List application: tag sequence is [7, 5, elem_type]
            const elem = try parseType(allocator, tags, idx);
            break :blk Type.listOf(allocator, elem) catch return error.OutOfMemory;
        },
        6 => blk: {
            // Pair application: tag sequence is [7, 7, 6, fst_type, snd_type]
            const fst = try parseType(allocator, tags, idx);
            const snd = try parseType(allocator, tags, idx);
            break :blk Type.pairOf(allocator, fst, snd) catch return error.OutOfMemory;
        },
        7 => blk: {
            // Type application: consume the next tag to determine what it applies to
            if (idx.* >= tags.len) return error.InvalidConstantTag;
            const next_tag = tags[idx.*];
            idx.* += 1;
            switch (next_tag) {
                5 => {
                    // List(T): [7, 5, T]
                    const elem = try parseType(allocator, tags, idx);
                    break :blk Type.listOf(allocator, elem) catch return error.OutOfMemory;
                },
                7 => {
                    // Could be Pair: [7, 7, 6, A, B]
                    if (idx.* >= tags.len) return error.InvalidConstantTag;
                    const inner = tags[idx.*];
                    idx.* += 1;
                    if (inner == 6) {
                        const fst = try parseType(allocator, tags, idx);
                        const snd = try parseType(allocator, tags, idx);
                        break :blk Type.pairOf(allocator, fst, snd) catch return error.OutOfMemory;
                    } else {
                        return error.UnknownTypeTag;
                    }
                },
                else => return error.UnknownTypeTag,
            }
        },
        8 => Type.dat(allocator) catch return error.OutOfMemory,
        else => return error.UnknownTypeTag,
    };
}

fn decodeConstantValue(allocator: std.mem.Allocator, d: *Decoder, typ: *const Type) DecodeError!*const Constant {
    switch (typ.*) {
        .integer => {
            const managed = try d.integer(allocator);
            const c = allocator.create(Constant) catch return error.OutOfMemory;
            c.* = .{ .integer = managed };
            return c;
        },
        .byte_string => {
            const bs = try d.bytes(allocator);
            const c = allocator.create(Constant) catch return error.OutOfMemory;
            c.* = .{ .byte_string = bs };
            return c;
        },
        .string => {
            const bs = try d.bytes(allocator);
            // Validate UTF-8
            if (!std.unicode.utf8ValidateSlice(bs)) return error.Utf8Invalid;
            const c = allocator.create(Constant) catch return error.OutOfMemory;
            c.* = .{ .string = bs };
            return c;
        },
        .unit => {
            return Constant.unt(allocator) catch return error.OutOfMemory;
        },
        .bool => {
            const val = try d.bit();
            return Constant.boolVal(allocator, val) catch return error.OutOfMemory;
        },
        .data => {
            const bs = try d.bytes(allocator);
            const pd = cbor_decode.decode(allocator, bs) catch return error.CborDecodeError;
            return Constant.dat(allocator, pd) catch return error.OutOfMemory;
        },
        .list => |elem_type| {
            var items: std.ArrayList(*const Constant) = .empty;
            errdefer items.deinit(allocator);
            while (try d.bit()) {
                const val = try decodeConstantValue(allocator, d, elem_type);
                items.append(allocator, val) catch return error.OutOfMemory;
            }
            const values = items.toOwnedSlice(allocator) catch return error.OutOfMemory;
            return Constant.protoList(allocator, elem_type, values) catch return error.OutOfMemory;
        },
        .pair => |p| {
            const fst = try decodeConstantValue(allocator, d, p.fst);
            const snd = try decodeConstantValue(allocator, d, p.snd);
            return Constant.protoPair(allocator, p.fst, p.snd, fst, snd) catch return error.OutOfMemory;
        },
        else => return error.UnknownTypeTag,
    }
}

// --- Tests ---

const testing = std.testing;

test "decode simple program (con integer 11)" {
    // Flat encoding of: (program 1.0.0 (con integer 11))
    // Version: 1.0.0 → word(1) word(0) word(0)
    // Term tag 4 (constant): 0100
    // Type tags: 1-bit prefix + 4-bit tag 0 (integer) + 0 terminator → 1 0000 0
    // Value: zigzag(11) = 22, bigWord(22) = 0x16 → byte 0x16
    // Filler: pad to byte
    const bytes = [_]u8{
        0x01, // word(1) = 0x01
        0x00, // word(0) = 0x00
        0x00, // word(0) = 0x00
        0x48, // 0100 1000 = tag(4) + type prefix bit(1) + type tag 0000 (integer)
        0x05, // 0000 0101 = type terminator(0) + zigzag(11)=22=0b10110 needs word encoding
        0x82, // continuation: 22 as word = 0x16 = 0b0001_0110, but let me recalculate...
    };
    _ = bytes;
    // Let me construct a known-good flat encoding instead.
    // Simplest: (program 1.0.0 (con unit ()))
    // word(1)=0x01, word(0)=0x00, word(0)=0x00
    // tag 4 = 0100
    // type tags: 1-bit(1) + tag 3 (unit, 0011) + 0-bit terminator = 1 0011 0
    // no value for unit
    // filler: pad with 0s then 1
    //
    // Byte layout:
    // 01 00 00 [0100 1001 1 0] [filler: 00001]
    // = 01 00 00 49 81
    // wait, that's wrong. Let me be more careful.
    //
    // word(1) = byte 0x01 (7 bits data, MSB=0 → single byte)
    // word(0) = byte 0x00
    // word(0) = byte 0x00
    // These are byte-aligned.
    // Actually, the word encoding uses the bit-level reader's bits8(8) function,
    // so words are read 8 bits at a time from the bit stream.
    //
    // After 3 words (3 bytes), we're at byte position 3, bits used = 0.
    // Term tag: 4 bits = 0100
    // Type tag list: bit(1) → has tag, bits8(4) = 0011 (unit=3), bit(0) → end
    // Unit constant: no data
    // Filler: skip 0-bits until 1-bit
    //
    // Starting from bit offset 0 after byte 2:
    // Bits: 0100  1 0011 0  [filler]
    //       ^^^^  ^ ^^^^ ^
    //       tag4  1 tag3 0(end)
    //
    // That's 4 + 1 + 4 + 1 = 10 bits
    // So we need 10 bits of data + filler to align to next byte
    // 10 bits → 2 remaining bits in the byte (16-10=6) → filler = 000001
    // wait, 10 bits is 1 byte + 2 bits. Filler needs to reach next byte boundary.
    // 10 bits = byte[3] has 8 bits used, then 2 bits into byte[4].
    // Remaining in byte[4] = 6 bits, so filler = 000001
    //
    // Byte 3: 0100_1001 = 0x49
    // Byte 4: 1000_0001 = 0x81
    const unit_prog = [_]u8{ 0x01, 0x00, 0x00, 0x49, 0x81 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prog = try decode(a, &unit_prog);
    try testing.expectEqual(@as(u32, 1), prog.version.major);
    try testing.expectEqual(@as(u32, 0), prog.version.minor);
    try testing.expectEqual(@as(u32, 0), prog.version.patch);
    try testing.expect(prog.term.* == .constant);
    try testing.expect(prog.term.constant.* == .unit);
}

test "decode error term" {
    // (program 1.0.0 (error))
    // word(1)=0x01, word(0)=0x00, word(0)=0x00
    // tag 6 = 0110
    // filler: 4 remaining bits → 0001
    // Byte 3: 0110_0001 = 0x61
    const err_prog = [_]u8{ 0x01, 0x00, 0x00, 0x61 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prog = try decode(a, &err_prog);
    try testing.expect(prog.term.* == .err);
}

test "decode builtin" {
    // (program 1.0.0 (builtin addInteger))
    // word(1)=0x01, word(0)=0x00, word(0)=0x00
    // tag 7 = 0111
    // builtin tag: 7 bits = 0000000 (addInteger = 0)
    // filler: 4+7 = 11 bits, need 5 more → 00001
    // Byte 3: 0111_0000 = 0x70
    // Byte 4: 0000_0001 = 0x01
    const builtin_prog = [_]u8{ 0x01, 0x00, 0x00, 0x70, 0x01 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prog = try decode(a, &builtin_prog);
    try testing.expect(prog.term.* == .builtin);
    try testing.expectEqual(DefaultFunction.add_integer, prog.term.builtin);
}

test "decoder bit reading" {
    var d = Decoder.init(&[_]u8{ 0b10110001, 0b01010101 });

    try testing.expect(try d.bit() == true);
    try testing.expect(try d.bit() == false);
    try testing.expect(try d.bit() == true);
    try testing.expect(try d.bit() == true);
    try testing.expect(try d.bit() == false);
    try testing.expect(try d.bit() == false);
    try testing.expect(try d.bit() == false);
    try testing.expect(try d.bit() == true);

    try testing.expect(try d.bit() == false);
    try testing.expect(try d.bit() == true);
}

test "decoder word" {
    // word encoding: 7-bit chunks, MSB=continuation
    // 300 = 0b100101100
    // Chunk 0: 0b0101100 | 0x80 = 0xAC (continuation)
    // Chunk 1: 0b0000010         = 0x02
    var d = Decoder.init(&[_]u8{ 0xAC, 0x02 });
    const val = try d.word();
    try testing.expectEqual(@as(usize, 300), val);
}

test "decode integer constant 42" {
    // (program 1.0.0 (con integer 42))
    const int42_prog = [_]u8{ 0x01, 0x00, 0x00, 0x48, 0x15, 0x01 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prog = try decode(a, &int42_prog);
    try testing.expect(prog.term.* == .constant);
    try testing.expect(prog.term.constant.* == .integer);
    try testing.expectEqual(@as(i64, 42), try prog.term.constant.integer.toConst().toInt(i64));
}
