//! Zig bindings for the blst BLS12-381 library.
//! Used for validating BLS curve points during parsing.

const c = @cImport({
    @cInclude("blst.h");
});

pub const BLST_ERROR = c.BLST_ERROR;
pub const BLST_SUCCESS = c.BLST_SUCCESS;
pub const BLST_BAD_ENCODING = c.BLST_BAD_ENCODING;
pub const BLST_POINT_NOT_ON_CURVE = c.BLST_POINT_NOT_ON_CURVE;
pub const BLST_POINT_NOT_IN_GROUP = c.BLST_POINT_NOT_IN_GROUP;

pub const P1Affine = c.blst_p1_affine;
pub const P1 = c.blst_p1;
pub const P2Affine = c.blst_p2_affine;
pub const P2 = c.blst_p2;

pub const Fp12 = c.blst_fp12;

pub const BLST_P1_COMPRESSED_SIZE: usize = 48;
pub const BLST_P2_COMPRESSED_SIZE: usize = 96;

/// Error type for BLS operations
pub const BlsError = error{
    BadEncoding,
    PointNotOnCurve,
    PointNotInGroup,
};

/// Convert BLST_ERROR to Zig error
fn toError(err: BLST_ERROR) BlsError {
    return switch (err) {
        BLST_BAD_ENCODING => BlsError.BadEncoding,
        BLST_POINT_NOT_ON_CURVE => BlsError.PointNotOnCurve,
        BLST_POINT_NOT_IN_GROUP => BlsError.PointNotInGroup,
        else => BlsError.BadEncoding,
    };
}

/// Decompress and validate a G1 point from 48 bytes.
/// Returns error if the point is not on the curve or not in the G1 subgroup.
pub fn uncompressG1(bytes: *const [BLST_P1_COMPRESSED_SIZE]u8) BlsError!P1 {
    var affine: P1Affine = undefined;
    var point: P1 = undefined;

    // Decompress the point
    const err = c.blst_p1_uncompress(&affine, bytes);
    if (err != BLST_SUCCESS) {
        return toError(err);
    }

    // Convert from affine to projective coordinates
    c.blst_p1_from_affine(&point, &affine);

    // Check if point is in G1 subgroup
    if (!c.blst_p1_in_g1(&point)) {
        return BlsError.PointNotInGroup;
    }

    return point;
}

/// Decompress and validate a G2 point from 96 bytes.
/// Returns error if the point is not on the curve or not in the G2 subgroup.
pub fn uncompressG2(bytes: *const [BLST_P2_COMPRESSED_SIZE]u8) BlsError!P2 {
    var affine: P2Affine = undefined;
    var point: P2 = undefined;

    // Decompress the point
    const err = c.blst_p2_uncompress(&affine, bytes);
    if (err != BLST_SUCCESS) {
        return toError(err);
    }

    // Convert from affine to projective coordinates
    c.blst_p2_from_affine(&point, &affine);

    // Check if point is in G2 subgroup
    if (!c.blst_p2_in_g2(&point)) {
        return BlsError.PointNotInGroup;
    }

    return point;
}

/// Compress a G1 point to 48 bytes.
pub fn compressG1(point: *const P1) [BLST_P1_COMPRESSED_SIZE]u8 {
    var out: [BLST_P1_COMPRESSED_SIZE]u8 = undefined;
    c.blst_p1_compress(&out, point);
    return out;
}

/// Compress a G2 point to 96 bytes.
pub fn compressG2(point: *const P2) [BLST_P2_COMPRESSED_SIZE]u8 {
    var out: [BLST_P2_COMPRESSED_SIZE]u8 = undefined;
    c.blst_p2_compress(&out, point);
    return out;
}

/// Check if two G1 points are equal.
pub fn equalG1(a: *const P1, b: *const P1) bool {
    return c.blst_p1_is_equal(a, b);
}

/// Add two G1 points.
pub fn addG1(a: *const P1, b: *const P1) P1 {
    var out: P1 = undefined;
    c.blst_p1_add_or_double(&out, a, b);
    return out;
}

/// Negate a G1 point.
pub fn negG1(point: *const P1) P1 {
    var out: P1 = point.*;
    c.blst_p1_cneg(&out, true);
    return out;
}

/// Scalar multiply a G1 point. Scalar is in little-endian byte order.
pub fn scalarMulG1(point: *const P1, scalar: []const u8, nbits: usize) P1 {
    var out: P1 = undefined;
    c.blst_p1_mult(&out, point, scalar.ptr, nbits);
    return out;
}

/// Hash to G1 curve point.
pub fn hashToG1(msg: []const u8, dst: []const u8) P1 {
    var out: P1 = undefined;
    c.blst_hash_to_g1(
        &out,
        msg.ptr,
        msg.len,
        dst.ptr,
        dst.len,
        null,
        0,
    );
    return out;
}

/// Add two G2 points.
pub fn addG2(a: *const P2, b: *const P2) P2 {
    var out: P2 = undefined;
    c.blst_p2_add_or_double(&out, a, b);
    return out;
}

/// Negate a G2 point.
pub fn negG2(point: *const P2) P2 {
    var out: P2 = point.*;
    c.blst_p2_cneg(&out, true);
    return out;
}

/// Scalar multiply a G2 point. Scalar is in little-endian byte order.
pub fn scalarMulG2(point: *const P2, scalar: []const u8, nbits: usize) P2 {
    var out: P2 = undefined;
    c.blst_p2_mult(&out, point, scalar.ptr, nbits);
    return out;
}

/// Check if two G2 points are equal.
pub fn equalG2(a: *const P2, b: *const P2) bool {
    return c.blst_p2_is_equal(a, b);
}

/// Hash to G2 curve point.
pub fn hashToG2(msg: []const u8, dst: []const u8) P2 {
    var out: P2 = undefined;
    c.blst_hash_to_g2(
        &out,
        msg.ptr,
        msg.len,
        dst.ptr,
        dst.len,
        null,
        0,
    );
    return out;
}

/// Compute Miller loop pairing.
pub fn millerLoop(p1: *const P1, p2: *const P2) Fp12 {
    var p1_affine: P1Affine = undefined;
    var p2_affine: P2Affine = undefined;
    c.blst_p1_to_affine(&p1_affine, p1);
    c.blst_p2_to_affine(&p2_affine, p2);
    var out: Fp12 = undefined;
    c.blst_miller_loop(&out, &p2_affine, &p1_affine);
    return out;
}

/// Multiply two Miller loop results.
pub fn mulFp12(a: *const Fp12, b: *const Fp12) Fp12 {
    var out: Fp12 = undefined;
    c.blst_fp12_mul(&out, a, b);
    return out;
}

/// Final verification of two Miller loop results.
pub fn finalVerify(a: *const Fp12, b: *const Fp12) bool {
    return c.blst_fp12_finalverify(a, b);
}

test "G1 zero point" {
    // The compressed zero point for G1 (infinity)
    const zero: [48]u8 = .{0xc0} ++ .{0} ** 47;
    _ = uncompressG1(&zero) catch {
        // Zero point should be valid
        return error.UnexpectedError;
    };
}
