//! DefaultFunction enum representing all 92 UPLC builtin functions.
//! Each builtin has associated arity and force count metadata.

const std = @import("std");

/// All builtin functions available in Untyped Plutus Core.
/// The enum values match the FLAT encoding tags from the Plutus specification.
pub const DefaultFunction = enum(u8) {
    // Integer functions (0-9)
    add_integer = 0,
    subtract_integer = 1,
    multiply_integer = 2,
    divide_integer = 3,
    quotient_integer = 4,
    remainder_integer = 5,
    mod_integer = 6,
    equals_integer = 7,
    less_than_integer = 8,
    less_than_equals_integer = 9,

    // ByteString functions (10-17)
    append_byte_string = 10,
    cons_byte_string = 11,
    slice_byte_string = 12,
    length_of_byte_string = 13,
    index_byte_string = 14,
    equals_byte_string = 15,
    less_than_byte_string = 16,
    less_than_equals_byte_string = 17,

    // Cryptography and hash functions
    sha2_256 = 18,
    sha3_256 = 19,
    blake2b_256 = 20,
    verify_ed25519_signature = 21,

    // String functions (22-25)
    append_string = 22,
    equals_string = 23,
    encode_utf8 = 24,
    decode_utf8 = 25,

    // Bool function
    if_then_else = 26,

    // Unit function
    choose_unit = 27,

    // Tracing function
    trace = 28,

    // Pairs functions
    fst_pair = 29,
    snd_pair = 30,

    // List functions
    choose_list = 31,
    mk_cons = 32,
    head_list = 33,
    tail_list = 34,
    null_list = 35,

    // Data functions
    choose_data = 36,
    constr_data = 37,
    map_data = 38,
    list_data = 39,
    i_data = 40,
    b_data = 41,
    un_constr_data = 42,
    un_map_data = 43,
    un_list_data = 44,
    un_i_data = 45,
    un_b_data = 46,
    equals_data = 47,

    // Misc constructors
    mk_pair_data = 48,
    mk_nil_data = 49,
    mk_nil_pair_data = 50,

    // Serialisation
    serialise_data = 51,

    // ECDSA/Schnorr
    verify_ecdsa_secp256k1_signature = 52,
    verify_schnorr_secp256k1_signature = 53,

    // BLS12-381 G1
    bls12_381_g1_add = 54,
    bls12_381_g1_neg = 55,
    bls12_381_g1_scalar_mul = 56,
    bls12_381_g1_equal = 57,
    bls12_381_g1_compress = 58,
    bls12_381_g1_uncompress = 59,
    bls12_381_g1_hash_to_group = 60,

    // BLS12-381 G2
    bls12_381_g2_add = 61,
    bls12_381_g2_neg = 62,
    bls12_381_g2_scalar_mul = 63,
    bls12_381_g2_equal = 64,
    bls12_381_g2_compress = 65,
    bls12_381_g2_uncompress = 66,
    bls12_381_g2_hash_to_group = 67,

    // BLS12-381 pairing
    bls12_381_miller_loop = 68,
    bls12_381_mul_ml_result = 69,
    bls12_381_final_verify = 70,

    // Additional hash functions
    keccak_256 = 71,
    blake2b_224 = 72,

    // Bitwise operations
    integer_to_byte_string = 73,
    byte_string_to_integer = 74,
    and_byte_string = 75,
    or_byte_string = 76,
    xor_byte_string = 77,
    complement_byte_string = 78,
    read_bit = 79,
    write_bits = 80,
    replicate_byte = 81,
    shift_byte_string = 82,
    rotate_byte_string = 83,
    count_set_bits = 84,
    find_first_set_bit = 85,

    // RIPEMD-160
    ripemd_160 = 86,

    // Modular exponentiation
    exp_mod_integer = 87,

    // Array/List operations
    drop_list = 88,
    length_of_array = 89,
    list_to_array = 90,
    index_array = 91,
    bls12_381_g1_multi_scalar_mul = 92,
    bls12_381_g2_multi_scalar_mul = 93,
    insert_coin = 94,
    lookup_coin = 95,
    union_value = 96,
    value_contains = 97,
    value_data = 98,
    un_value_data = 99,
    scale_value = 100,

    /// Returns the number of `force` operations required before this builtin
    /// can be applied to arguments.
    pub fn forceCount(self: DefaultFunction) usize {
        return switch (self) {
            .add_integer,
            .subtract_integer,
            .multiply_integer,
            .divide_integer,
            .quotient_integer,
            .remainder_integer,
            .mod_integer,
            .equals_integer,
            .less_than_integer,
            .less_than_equals_integer,
            .append_byte_string,
            .cons_byte_string,
            .slice_byte_string,
            .length_of_byte_string,
            .index_byte_string,
            .equals_byte_string,
            .less_than_byte_string,
            .less_than_equals_byte_string,
            .sha2_256,
            .sha3_256,
            .blake2b_224,
            .blake2b_256,
            .keccak_256,
            .verify_ed25519_signature,
            .verify_ecdsa_secp256k1_signature,
            .verify_schnorr_secp256k1_signature,
            .append_string,
            .equals_string,
            .encode_utf8,
            .decode_utf8,
            .constr_data,
            .map_data,
            .list_data,
            .i_data,
            .b_data,
            .un_constr_data,
            .un_map_data,
            .un_list_data,
            .un_i_data,
            .un_b_data,
            .equals_data,
            .serialise_data,
            .mk_pair_data,
            .mk_nil_data,
            .mk_nil_pair_data,
            .bls12_381_g1_add,
            .bls12_381_g1_neg,
            .bls12_381_g1_scalar_mul,
            .bls12_381_g1_equal,
            .bls12_381_g1_compress,
            .bls12_381_g1_uncompress,
            .bls12_381_g1_hash_to_group,
            .bls12_381_g2_add,
            .bls12_381_g2_neg,
            .bls12_381_g2_scalar_mul,
            .bls12_381_g2_equal,
            .bls12_381_g2_compress,
            .bls12_381_g2_uncompress,
            .bls12_381_g2_hash_to_group,
            .bls12_381_miller_loop,
            .bls12_381_mul_ml_result,
            .bls12_381_final_verify,
            .integer_to_byte_string,
            .byte_string_to_integer,
            .and_byte_string,
            .or_byte_string,
            .xor_byte_string,
            .complement_byte_string,
            .read_bit,
            .write_bits,
            .replicate_byte,
            .shift_byte_string,
            .rotate_byte_string,
            .count_set_bits,
            .find_first_set_bit,
            .ripemd_160,
            .exp_mod_integer,
            .insert_coin,
            .lookup_coin,
            .union_value,
            .value_contains,
            .value_data,
            .un_value_data,
            .scale_value,
            .bls12_381_g1_multi_scalar_mul,
            .bls12_381_g2_multi_scalar_mul,
            => 0,

            .if_then_else,
            .choose_unit,
            .trace,
            .mk_cons,
            .head_list,
            .tail_list,
            .null_list,
            .choose_data,
            .drop_list,
            .length_of_array,
            .list_to_array,
            .index_array,
            => 1,

            .fst_pair,
            .snd_pair,
            .choose_list,
            => 2,
        };
    }

    /// Returns the number of term arguments this builtin expects.
    pub fn arity(self: DefaultFunction) usize {
        return switch (self) {
            .sha2_256,
            .sha3_256,
            .blake2b_224,
            .blake2b_256,
            .keccak_256,
            .length_of_byte_string,
            .encode_utf8,
            .decode_utf8,
            .fst_pair,
            .snd_pair,
            .head_list,
            .tail_list,
            .null_list,
            .map_data,
            .list_data,
            .i_data,
            .b_data,
            .un_constr_data,
            .un_map_data,
            .un_list_data,
            .un_i_data,
            .un_b_data,
            .serialise_data,
            .mk_nil_data,
            .mk_nil_pair_data,
            .bls12_381_g1_neg,
            .bls12_381_g1_compress,
            .bls12_381_g1_uncompress,
            .bls12_381_g2_neg,
            .bls12_381_g2_compress,
            .bls12_381_g2_uncompress,
            .complement_byte_string,
            .count_set_bits,
            .find_first_set_bit,
            .ripemd_160,
            .length_of_array,
            .list_to_array,
            .value_data,
            .un_value_data,
            => 1,

            .add_integer,
            .subtract_integer,
            .multiply_integer,
            .divide_integer,
            .quotient_integer,
            .remainder_integer,
            .mod_integer,
            .equals_integer,
            .less_than_integer,
            .less_than_equals_integer,
            .append_byte_string,
            .cons_byte_string,
            .index_byte_string,
            .equals_byte_string,
            .less_than_byte_string,
            .less_than_equals_byte_string,
            .append_string,
            .equals_string,
            .choose_unit,
            .trace,
            .mk_cons,
            .constr_data,
            .equals_data,
            .mk_pair_data,
            .bls12_381_g1_add,
            .bls12_381_g1_scalar_mul,
            .bls12_381_g1_equal,
            .bls12_381_g1_hash_to_group,
            .bls12_381_g2_add,
            .bls12_381_g2_scalar_mul,
            .bls12_381_g2_equal,
            .bls12_381_g2_hash_to_group,
            .bls12_381_miller_loop,
            .bls12_381_mul_ml_result,
            .bls12_381_final_verify,
            .byte_string_to_integer,
            .read_bit,
            .replicate_byte,
            .shift_byte_string,
            .rotate_byte_string,
            .drop_list,
            .index_array,
            .union_value,
            .value_contains,
            .scale_value,
            .bls12_381_g1_multi_scalar_mul,
            .bls12_381_g2_multi_scalar_mul,
            => 2,

            .slice_byte_string,
            .if_then_else,
            .choose_list,
            .verify_ed25519_signature,
            .verify_ecdsa_secp256k1_signature,
            .verify_schnorr_secp256k1_signature,
            .integer_to_byte_string,
            .and_byte_string,
            .or_byte_string,
            .xor_byte_string,
            .write_bits,
            .exp_mod_integer,
            .lookup_coin,
            => 3,

            .insert_coin => 4,

            .choose_data => 6,
        };
    }

    /// Parse a builtin function name from a string.
    pub fn fromName(builtin_name: []const u8) ?DefaultFunction {
        return name_map.get(builtin_name);
    }

    /// Get the canonical name of this builtin function.
    pub fn getName(self: DefaultFunction) []const u8 {
        return @tagName(self);
    }

    const name_map = std.StaticStringMap(DefaultFunction).initComptime(.{
        .{ "addInteger", .add_integer },
        .{ "subtractInteger", .subtract_integer },
        .{ "multiplyInteger", .multiply_integer },
        .{ "divideInteger", .divide_integer },
        .{ "quotientInteger", .quotient_integer },
        .{ "remainderInteger", .remainder_integer },
        .{ "modInteger", .mod_integer },
        .{ "equalsInteger", .equals_integer },
        .{ "lessThanInteger", .less_than_integer },
        .{ "lessThanEqualsInteger", .less_than_equals_integer },
        .{ "appendByteString", .append_byte_string },
        .{ "consByteString", .cons_byte_string },
        .{ "sliceByteString", .slice_byte_string },
        .{ "lengthOfByteString", .length_of_byte_string },
        .{ "indexByteString", .index_byte_string },
        .{ "equalsByteString", .equals_byte_string },
        .{ "lessThanByteString", .less_than_byte_string },
        .{ "lessThanEqualsByteString", .less_than_equals_byte_string },
        .{ "sha2_256", .sha2_256 },
        .{ "sha3_256", .sha3_256 },
        .{ "blake2b_256", .blake2b_256 },
        .{ "verifyEd25519Signature", .verify_ed25519_signature },
        .{ "appendString", .append_string },
        .{ "equalsString", .equals_string },
        .{ "encodeUtf8", .encode_utf8 },
        .{ "decodeUtf8", .decode_utf8 },
        .{ "ifThenElse", .if_then_else },
        .{ "chooseUnit", .choose_unit },
        .{ "trace", .trace },
        .{ "fstPair", .fst_pair },
        .{ "sndPair", .snd_pair },
        .{ "chooseList", .choose_list },
        .{ "mkCons", .mk_cons },
        .{ "headList", .head_list },
        .{ "tailList", .tail_list },
        .{ "nullList", .null_list },
        .{ "chooseData", .choose_data },
        .{ "constrData", .constr_data },
        .{ "mapData", .map_data },
        .{ "listData", .list_data },
        .{ "iData", .i_data },
        .{ "bData", .b_data },
        .{ "unConstrData", .un_constr_data },
        .{ "unMapData", .un_map_data },
        .{ "unListData", .un_list_data },
        .{ "unIData", .un_i_data },
        .{ "unBData", .un_b_data },
        .{ "equalsData", .equals_data },
        .{ "mkPairData", .mk_pair_data },
        .{ "mkNilData", .mk_nil_data },
        .{ "mkNilPairData", .mk_nil_pair_data },
        .{ "serialiseData", .serialise_data },
        .{ "verifyEcdsaSecp256k1Signature", .verify_ecdsa_secp256k1_signature },
        .{ "verifySchnorrSecp256k1Signature", .verify_schnorr_secp256k1_signature },
        .{ "bls12_381_G1_add", .bls12_381_g1_add },
        .{ "bls12_381_G1_neg", .bls12_381_g1_neg },
        .{ "bls12_381_G1_scalarMul", .bls12_381_g1_scalar_mul },
        .{ "bls12_381_G1_equal", .bls12_381_g1_equal },
        .{ "bls12_381_G1_compress", .bls12_381_g1_compress },
        .{ "bls12_381_G1_uncompress", .bls12_381_g1_uncompress },
        .{ "bls12_381_G1_hashToGroup", .bls12_381_g1_hash_to_group },
        .{ "bls12_381_G2_add", .bls12_381_g2_add },
        .{ "bls12_381_G2_neg", .bls12_381_g2_neg },
        .{ "bls12_381_G2_scalarMul", .bls12_381_g2_scalar_mul },
        .{ "bls12_381_G2_equal", .bls12_381_g2_equal },
        .{ "bls12_381_G2_compress", .bls12_381_g2_compress },
        .{ "bls12_381_G2_uncompress", .bls12_381_g2_uncompress },
        .{ "bls12_381_G2_hashToGroup", .bls12_381_g2_hash_to_group },
        .{ "bls12_381_millerLoop", .bls12_381_miller_loop },
        .{ "bls12_381_mulMlResult", .bls12_381_mul_ml_result },
        .{ "bls12_381_finalVerify", .bls12_381_final_verify },
        .{ "keccak_256", .keccak_256 },
        .{ "blake2b_224", .blake2b_224 },
        .{ "integerToByteString", .integer_to_byte_string },
        .{ "byteStringToInteger", .byte_string_to_integer },
        .{ "andByteString", .and_byte_string },
        .{ "orByteString", .or_byte_string },
        .{ "xorByteString", .xor_byte_string },
        .{ "complementByteString", .complement_byte_string },
        .{ "readBit", .read_bit },
        .{ "writeBits", .write_bits },
        .{ "replicateByte", .replicate_byte },
        .{ "shiftByteString", .shift_byte_string },
        .{ "rotateByteString", .rotate_byte_string },
        .{ "countSetBits", .count_set_bits },
        .{ "findFirstSetBit", .find_first_set_bit },
        .{ "ripemd_160", .ripemd_160 },
        .{ "expModInteger", .exp_mod_integer },
        .{ "dropList", .drop_list },
        .{ "lengthOfArray", .length_of_array },
        .{ "listToArray", .list_to_array },
        .{ "indexArray", .index_array },
        .{ "insertCoin", .insert_coin },
        .{ "lookupCoin", .lookup_coin },
        .{ "unionValue", .union_value },
        .{ "valueContains", .value_contains },
        .{ "valueData", .value_data },
        .{ "unValueData", .un_value_data },
        .{ "scaleValue", .scale_value },
        .{ "bls12_381_G1_multiScalarMul", .bls12_381_g1_multi_scalar_mul },
        .{ "bls12_381_G2_multiScalarMul", .bls12_381_g2_multi_scalar_mul },
    });
};

test "builtin name parsing" {
    const testing = std.testing;

    try testing.expectEqual(DefaultFunction.add_integer, DefaultFunction.fromName("addInteger").?);
    try testing.expectEqual(DefaultFunction.if_then_else, DefaultFunction.fromName("ifThenElse").?);
    try testing.expectEqual(DefaultFunction.bls12_381_g1_add, DefaultFunction.fromName("bls12_381_G1_add").?);
    try testing.expect(DefaultFunction.fromName("notABuiltin") == null);
}

test "builtin arity" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 2), DefaultFunction.add_integer.arity());
    try testing.expectEqual(@as(usize, 3), DefaultFunction.if_then_else.arity());
    try testing.expectEqual(@as(usize, 6), DefaultFunction.choose_data.arity());
    try testing.expectEqual(@as(usize, 1), DefaultFunction.sha2_256.arity());
}

test "builtin force count" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), DefaultFunction.add_integer.forceCount());
    try testing.expectEqual(@as(usize, 1), DefaultFunction.if_then_else.forceCount());
    try testing.expectEqual(@as(usize, 2), DefaultFunction.fst_pair.forceCount());
    try testing.expectEqual(@as(usize, 2), DefaultFunction.choose_list.forceCount());
}
