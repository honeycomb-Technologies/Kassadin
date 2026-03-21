const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const BuiltinError = h.BuiltinError;

pub const INTEGER_TO_BYTE_STRING_MAXIMUM_OUTPUT_LENGTH: usize = 8192;

pub fn shiftByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const shift_int = try h.unwrapInteger(Binder, args[1]);

    const total_bits = bytes.len * 8;
    const result = allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
    @memset(result, 0);

    if (bytes.len == 0) return h.byteStringResult(Binder, allocator, result);

    const c_val = shift_int.toConst();
    const shift_i64 = c_val.toInt(i64) catch {
        // Shift exceeds range → all zeros
        return h.byteStringResult(Binder, allocator, result);
    };

    if (shift_i64 == 0) {
        @memcpy(result, bytes);
        return h.byteStringResult(Binder, allocator, result);
    }

    const abs_shift: usize = if (shift_i64 == std.math.minInt(i64))
        @as(usize, std.math.maxInt(i64)) + 1
    else
        @intCast(@abs(shift_i64));
    if (abs_shift >= total_bits) return h.byteStringResult(Binder, allocator, result);

    // Work in MSB0 bit order: bit i is byte[i/8] bit (7 - i%8)
    // Positive = left shift (toward MSB), negative = right shift
    for (0..total_bits) |i| {
        // Source bit index in original
        const src: usize = if (shift_i64 > 0)
            i + abs_shift // left shift: read from further right
        else
            i -| abs_shift; // right shift: read from further left

        // For right shift, skip dest bits that have no source
        if (shift_i64 < 0 and i < abs_shift) continue;
        if (src >= total_bits) continue;

        const src_byte = src / 8;
        const src_bit: u3 = @intCast(7 - (src % 8));
        if (bytes[src_byte] & (@as(u8, 1) << src_bit) != 0) {
            const dst_bit: u3 = @intCast(7 - (i % 8));
            result[i / 8] |= @as(u8, 1) << dst_bit;
        }
    }

    return h.byteStringResult(Binder, allocator, result);
}

pub fn rotateByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const shift_int = try h.unwrapInteger(Binder, args[1]);

    if (bytes.len == 0) return h.byteStringResult(Binder, allocator, &.{});

    const total_bits: i64 = std.math.cast(i64, std.math.mul(usize, bytes.len, 8) catch return error.OutOfRange) orelse return error.OutOfRange;

    // Normalize shift to [0, total_bits) via modulo
    const shift_const = shift_int.toConst();
    const shift_i64 = shift_const.toInt(i64) catch {
        // Very large value — compute mod via big int
        var tb = Integer.init(allocator) catch return error.OutOfMemory;
        tb.set(total_bits) catch return error.OutOfMemory;
        var mod = Integer.init(allocator) catch return error.OutOfMemory;
        var unused = Integer.init(allocator) catch return error.OutOfMemory;
        unused.divFloor(&mod, shift_int, &tb) catch return error.OutOfMemory;
        const m = mod.toConst().toInt(i64) catch return error.OutOfMemory;
        return rotateByteStringImpl(Binder, allocator, bytes, m, total_bits);
    };

    return rotateByteStringImpl(Binder, allocator, bytes, shift_i64, total_bits);
}

fn rotateByteStringImpl(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    shift_i64: i64,
    total_bits: i64,
) BuiltinError!*const Value(Binder) {
    // Normalize to [0, total_bits)
    var normalized = @mod(shift_i64, total_bits);
    if (normalized < 0) normalized += total_bits;

    const result = allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;

    if (normalized == 0) {
        @memcpy(result, bytes);
        return h.byteStringResult(Binder, allocator, result);
    }

    const shift_val: usize = @intCast(normalized);
    const byte_shift = shift_val / 8;
    const bit_shift: u3 = @intCast(shift_val % 8);

    for (0..bytes.len) |i| {
        const src_index = (i + byte_shift) % bytes.len;
        const next_index = (src_index + 1) % bytes.len;

        if (bit_shift == 0) {
            result[i] = bytes[src_index];
        } else {
            const anti: u3 = @intCast(8 - @as(u4, bit_shift));
            result[i] = (bytes[src_index] << bit_shift) | (bytes[next_index] >> anti);
        }
    }

    return h.byteStringResult(Binder, allocator, result);
}

pub fn replicateByte(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const size_int = try h.unwrapInteger(Binder, args[0]);
    const byte_val_int = try h.unwrapInteger(Binder, args[1]);

    const size_const = size_int.toConst();
    if (!size_const.positive and !size_const.eqlZero()) return error.TypeMismatch;
    const size = size_const.toInt(usize) catch return error.OutOfRange;
    if (size > INTEGER_TO_BYTE_STRING_MAXIMUM_OUTPUT_LENGTH) return error.OutOfRange;

    const byte_i64 = byte_val_int.toConst().toInt(i64) catch return error.TypeMismatch;
    if (byte_i64 < 0 or byte_i64 > 255) return error.TypeMismatch;
    const byte_val: u8 = @intCast(byte_i64);

    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    @memset(result, byte_val);
    return h.byteStringResult(Binder, allocator, result);
}

pub fn countSetBits(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    var count: i64 = 0;
    for (bytes) |b| {
        count += @popCount(b);
    }
    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.set(count) catch return error.OutOfMemory;
    return h.integerResult(Binder, allocator, result);
}

pub fn findFirstSetBit(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    // Iterate from last byte (LSB) to first
    var byte_index: usize = bytes.len;
    while (byte_index > 0) {
        byte_index -= 1;
        const val = bytes[byte_index];
        if (val == 0) continue;
        // Find lowest set bit in this byte
        const pos: i64 = @ctz(val);
        const byte_offset = std.math.mul(usize, bytes.len - 1 - byte_index, 8) catch return error.OutOfRange;
        const bit_index = pos + (std.math.cast(i64, byte_offset) orelse return error.OutOfRange);
        var result = Integer.init(allocator) catch return error.OutOfMemory;
        result.set(bit_index) catch return error.OutOfMemory;
        return h.integerResult(Binder, allocator, result);
    }
    // No bits set → return -1
    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.set(@as(i64, -1)) catch return error.OutOfMemory;
    return h.integerResult(Binder, allocator, result);
}

pub fn readBit(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const bit_index_int = try h.unwrapInteger(Binder, args[1]);

    if (bytes.len == 0) return error.TypeMismatch;

    const c_val = bit_index_int.toConst();
    if (!c_val.positive and !c_val.eqlZero()) return error.TypeMismatch;

    const bit_index = c_val.toInt(usize) catch return error.TypeMismatch;
    if (bit_index >= bytes.len * 8) return error.TypeMismatch;

    // Bit 0 is LSB of last byte
    const byte_index = bytes.len - 1 - bit_index / 8;
    const bit_offset: u3 = @intCast(bit_index % 8);
    const bit_set = (bytes[byte_index] >> bit_offset) & 1 == 1;

    return h.boolResult(Binder, allocator, bit_set);
}

pub fn writeBits(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const indices_list = try h.unwrapList(Binder, args[1]);
    const set_bit = try h.unwrapBool(Binder, args[2]);

    // Clone bytes
    const result = allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
    @memcpy(result, bytes);

    // Process each bit index
    for (indices_list) |index_const| {
        const bit_index_int = switch (index_const.*) {
            .integer => |*v| v,
            else => return error.TypeMismatch,
        };

        const c_val = bit_index_int.toConst();
        if (!c_val.positive and !c_val.eqlZero()) return error.TypeMismatch;

        const bit_index = c_val.toInt(usize) catch return error.TypeMismatch;
        if (bit_index >= bytes.len * 8) return error.TypeMismatch;

        const byte_index = bytes.len - 1 - bit_index / 8;
        const bit_offset: u3 = @intCast(bit_index % 8);
        const mask: u8 = @as(u8, 1) << bit_offset;

        if (set_bit) {
            result[byte_index] |= mask;
        } else {
            result[byte_index] &= ~mask;
        }
    }

    return h.byteStringResult(Binder, allocator, result);
}

const BitwiseOp = enum { @"and", @"or", xor };

fn bitwiseByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
    op: BitwiseOp,
) BuiltinError!*const Value(Binder) {
    const should_pad = try h.unwrapBool(Binder, args[0]);
    const bytes1 = try h.unwrapByteString(Binder, args[1]);
    const bytes2 = try h.unwrapByteString(Binder, args[2]);

    const pad_byte: u8 = switch (op) {
        .@"and" => 0xFF,
        .@"or", .xor => 0x00,
    };

    const out_len = if (should_pad) @max(bytes1.len, bytes2.len) else @min(bytes1.len, bytes2.len);
    const result = allocator.alloc(u8, out_len) catch return error.OutOfMemory;

    for (0..out_len) |i| {
        const b1 = if (i < bytes1.len) bytes1[i] else pad_byte;
        const b2 = if (i < bytes2.len) bytes2[i] else pad_byte;
        result[i] = switch (op) {
            .@"and" => b1 & b2,
            .@"or" => b1 | b2,
            .xor => b1 ^ b2,
        };
    }

    return h.byteStringResult(Binder, allocator, result);
}

pub fn andByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    return bitwiseByteString(Binder, allocator, args, .@"and");
}

pub fn orByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    return bitwiseByteString(Binder, allocator, args, .@"or");
}

pub fn xorByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    return bitwiseByteString(Binder, allocator, args, .xor);
}

pub fn complementByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const result = allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
    for (0..bytes.len) |i| {
        result[i] = bytes[i] ^ 0xFF;
    }
    return h.byteStringResult(Binder, allocator, result);
}

pub fn integerToByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const endianness = try h.unwrapBool(Binder, args[0]); // true = big-endian
    const size_int = try h.unwrapInteger(Binder, args[1]);
    const input = try h.unwrapInteger(Binder, args[2]);

    // Negative input is an error
    const input_const = input.toConst();
    if (!input_const.positive and !input_const.eqlZero()) return error.TypeMismatch;

    // Convert size to usize
    const size_i64 = size_int.toConst().toInt(i64) catch return error.OutOfRange;
    if (size_i64 < 0) return error.OutOfRange;
    const requested_size: usize = std.math.cast(usize, size_i64) orelse return error.OutOfRange;
    if (requested_size > INTEGER_TO_BYTE_STRING_MAXIMUM_OUTPUT_LENGTH) return error.OutOfRange;

    // Zero input → zero-filled bytes of requested size
    if (input_const.eqlZero()) {
        const result = allocator.alloc(u8, requested_size) catch return error.OutOfMemory;
        @memset(result, 0);
        return h.byteStringResult(Binder, allocator, result);
    }

    // Check unbounded (size=0) doesn't exceed max
    if (requested_size == 0) {
        const bit_len = input_const.bitCountAbs();
        if (bit_len > 0 and (bit_len - 1) >= 8 * INTEGER_TO_BYTE_STRING_MAXIMUM_OUTPUT_LENGTH) {
            return error.OutOfRange;
        }
    }

    // Convert integer limbs to big-endian bytes
    const limbs = input_const.limbs;
    const limb_count = limbs.len;
    const limb_size = @sizeOf(std.math.big.Limb);
    const total_bytes = limb_count * limb_size;

    // Build big-endian byte representation
    const be_buf = allocator.alloc(u8, total_bytes) catch return error.OutOfMemory;
    for (0..limb_count) |i| {
        const limb = limbs[limb_count - 1 - i];
        const start = i * limb_size;
        std.mem.writeInt(std.math.big.Limb, be_buf[start..][0..limb_size], limb, .big);
    }

    // Strip leading zeros
    var start: usize = 0;
    while (start < be_buf.len and be_buf[start] == 0) : (start += 1) {}
    const significant = be_buf[start..];

    // Check bounded size
    if (requested_size != 0 and significant.len > requested_size) return error.TypeMismatch;

    const output_size = if (requested_size > 0) requested_size else significant.len;
    const result = allocator.alloc(u8, output_size) catch return error.OutOfMemory;

    if (endianness) {
        // Big-endian: padding then bytes
        const padding = output_size - significant.len;
        @memset(result[0..padding], 0);
        @memcpy(result[padding..], significant);
    } else {
        // Little-endian: reverse significant bytes, then padding
        for (0..significant.len) |i| {
            result[i] = significant[significant.len - 1 - i];
        }
        @memset(result[significant.len..], 0);
    }

    return h.byteStringResult(Binder, allocator, result);
}

pub fn byteStringToInteger(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const endianness = try h.unwrapBool(Binder, args[0]); // true = big-endian
    const bytes = try h.unwrapByteString(Binder, args[1]);

    var result = Integer.init(allocator) catch return error.OutOfMemory;

    if (bytes.len == 0) {
        result.set(0) catch return error.OutOfMemory;
        return h.integerResult(Binder, allocator, result);
    }

    // Build integer from bytes
    if (endianness) {
        // Big-endian: most significant byte first
        for (bytes) |byte| {
            result.shiftLeft(&result, 8) catch return error.OutOfMemory;
            result.addScalar(&result, byte) catch return error.OutOfMemory;
        }
    } else {
        // Little-endian: least significant byte first
        var i: usize = bytes.len;
        while (i > 0) {
            i -= 1;
            result.shiftLeft(&result, 8) catch return error.OutOfMemory;
            result.addScalar(&result, bytes[i]) catch return error.OutOfMemory;
        }
    }

    return h.integerResult(Binder, allocator, result);
}
