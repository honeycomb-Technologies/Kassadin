const std = @import("std");
const h = @import("helpers.zig");
const Integer = h.Integer;
const Value = h.Value;
const BuiltinError = h.BuiltinError;

pub fn sha2_256(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var hash_val: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn sha3_256(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var hash_val: [32]u8 = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn blake2b_256(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var hash_val: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn blake2b_224(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    const Blake2b224 = std.crypto.hash.blake2.Blake2b(224);
    var hash_val: [28]u8 = undefined;
    Blake2b224.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn ripemd_160(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var hash_val: [20]u8 = undefined;
    @import("../../crypto/ripemd160.zig").Ripemd160.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn verifyEd25519Signature(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const public_key = try h.unwrapByteString(Binder, args[0]);
    const message = try h.unwrapByteString(Binder, args[1]);
    const signature = try h.unwrapByteString(Binder, args[2]);

    // Validate lengths
    if (public_key.len != 32) return error.TypeMismatch;
    if (signature.len != 64) return error.TypeMismatch;

    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key[0..32].*) catch {
        return h.boolResult(Binder, allocator, false);
    };
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*);

    sig.verify(message, pk) catch {
        return h.boolResult(Binder, allocator, false);
    };

    return h.boolResult(Binder, allocator, true);
}

pub fn keccak_256(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);

    var hash_val: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(bytes, &hash_val, .{});
    const result = allocator.dupe(u8, &hash_val) catch return error.OutOfMemory;

    return h.byteStringResult(Binder, allocator, result);
}

pub fn indexByteString(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const bytes = try h.unwrapByteString(Binder, args[0]);
    const index_arg = try h.unwrapInteger(Binder, args[1]);

    const index_i64 = h.toI64Clamped(index_arg);
    if (index_i64 < 0 or index_i64 >= bytes.len) return error.OutOfRange;

    const byte_val = bytes[@intCast(index_i64)];

    var result = Integer.init(allocator) catch return error.OutOfMemory;
    result.set(@as(i64, byte_val)) catch return error.OutOfMemory;

    return h.integerResult(Binder, allocator, result);
}

pub fn verifyEcdsaSecp256k1Signature(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const public_key = try h.unwrapByteString(Binder, args[0]);
    const message = try h.unwrapByteString(Binder, args[1]);
    const signature = try h.unwrapByteString(Binder, args[2]);

    // Validate lengths
    if (public_key.len != 33) return error.TypeMismatch;
    if (message.len != 32) return error.TypeMismatch;
    if (signature.len != 64) return error.TypeMismatch;

    const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

    // Parse public key (compressed SEC1 format) — invalid key is an evaluation failure
    const pk = Ecdsa.PublicKey.fromSec1(public_key) catch {
        return error.EvaluationFailure;
    };

    // Validate r and s are in range [1, n-1] where n is the group order
    // Group order for secp256k1: FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    const group_order = [32]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };
    const zero = [_]u8{0} ** 32;
    const r_bytes = signature[0..32];
    const s_bytes = signature[32..64];

    // r and s must be in [1, n-1] — out of range is an evaluation failure
    if (std.mem.eql(u8, r_bytes, &zero) or std.mem.order(u8, r_bytes, &group_order) != .lt) {
        return error.EvaluationFailure;
    }
    if (std.mem.eql(u8, s_bytes, &zero) or std.mem.order(u8, s_bytes, &group_order) != .lt) {
        return error.EvaluationFailure;
    }

    // Check s is not over half order (BIP-146 low-s requirement)
    // Half order for secp256k1: 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
    const half_order = [32]u8{
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    };
    if (std.mem.order(u8, s_bytes, &half_order) == .gt) {
        return h.boolResult(Binder, allocator, false);
    }

    // Verify ECDSA signature (message is pre-hashed)
    const sig = Ecdsa.Signature.fromBytes(signature[0..64].*);
    sig.verifyPrehashed(message[0..32].*, pk) catch {
        return h.boolResult(Binder, allocator, false);
    };

    return h.boolResult(Binder, allocator, true);
}

pub fn verifySchnorrSecp256k1Signature(
    comptime Binder: type,
    allocator: std.mem.Allocator,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const public_key = try h.unwrapByteString(Binder, args[0]);
    const message = try h.unwrapByteString(Binder, args[1]);
    const signature = try h.unwrapByteString(Binder, args[2]);

    // Validate lengths
    if (public_key.len != 32) return error.TypeMismatch;
    if (signature.len != 64) return error.TypeMismatch;

    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Fe = Secp256k1.Fe;
    const Sha256 = std.crypto.hash.sha2.Sha256;

    // Parse x-only public key (lift_x with even y) — invalid key is an evaluation failure
    const pk_x = Fe.fromBytes(public_key[0..32].*, .big) catch {
        return error.EvaluationFailure;
    };
    const pk_y = Secp256k1.recoverY(pk_x, false) catch {
        return error.EvaluationFailure;
    };
    const P = Secp256k1{ .x = pk_x, .y = pk_y };

    // Extract r and s from signature
    const r_bytes = signature[0..32];
    const s_bytes = signature[32..64];

    // Compute tagged hash for challenge: SHA256(tag || tag || r || P || m)
    // where tag = SHA256("BIP0340/challenge")
    // Pre-computed: SHA256("BIP0340/challenge")
    const tag_hash = [32]u8{
        0x7b, 0xb5, 0x2d, 0x7a, 0x9f, 0xef, 0x58, 0x32,
        0x3e, 0xb1, 0xbf, 0x7a, 0x40, 0x7d, 0xb3, 0x82,
        0xd2, 0xf3, 0xf2, 0xd8, 0x1b, 0xb1, 0x22, 0x4f,
        0x49, 0xfe, 0x51, 0x8f, 0x6d, 0x48, 0xd3, 0x7c,
    };

    var challenge_hash: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(&tag_hash);
    hasher.update(&tag_hash);
    hasher.update(r_bytes);
    hasher.update(public_key);
    hasher.update(message);
    hasher.final(&challenge_hash);

    // e = challenge mod n
    const e = Secp256k1.scalar.Scalar.fromBytes(challenge_hash, .big) catch {
        return h.boolResult(Binder, allocator, false);
    };

    // s as scalar
    const s = Secp256k1.scalar.Scalar.fromBytes(s_bytes.*, .big) catch {
        return h.boolResult(Binder, allocator, false);
    };

    // R = s*G - e*P
    const sG = Secp256k1.basePoint.mul(s.toBytes(.little), .little) catch {
        return h.boolResult(Binder, allocator, false);
    };
    const eP = P.mul(e.toBytes(.little), .little) catch {
        return h.boolResult(Binder, allocator, false);
    };
    const R = sG.sub(eP);

    // Get affine coordinates
    const R_affine = R.affineCoordinates();

    // Verify R.y is even and R.x == r
    if (R_affine.y.isOdd()) {
        return h.boolResult(Binder, allocator, false);
    }

    const R_x_bytes = R_affine.x.toBytes(.big);
    if (!std.mem.eql(u8, &R_x_bytes, r_bytes)) {
        return h.boolResult(Binder, allocator, false);
    }

    return h.boolResult(Binder, allocator, true);
}
