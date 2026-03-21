//! Default cost model parameters for all builtin functions.
//! Values match the Cardano mainnet PlutusV3 (Conway era) cost model.

const costing = @import("costing.zig");
const BuiltinCosts = costing.BuiltinCosts;
const BuiltinCostModel = costing.BuiltinCostModel;

// Helpers for concise definitions
const one_const = oneConst;
const two_const = twoConst;
const three_const = threeConst;
const six_const = sixConst;

fn oneConst(mem: i64, cpu: i64) BuiltinCostModel {
    return .{ .one = .{
        .mem = .{ .constant = mem },
        .cpu = .{ .constant = cpu },
    } };
}

fn twoConst(mem: i64, cpu: i64) BuiltinCostModel {
    return .{ .two = .{
        .mem = .{ .constant = mem },
        .cpu = .{ .constant = cpu },
    } };
}

fn threeConst(mem: i64, cpu: i64) BuiltinCostModel {
    return .{ .three = .{
        .mem = .{ .constant = mem },
        .cpu = .{ .constant = cpu },
    } };
}

fn sixConst(mem: i64, cpu: i64) BuiltinCostModel {
    return .{ .six = .{
        .mem = .{ .constant = mem },
        .cpu = .{ .constant = cpu },
    } };
}

/// Default builtin costs for PlutusV3 (Conway era / semantics variant C).
pub const default_builtin_costs: BuiltinCosts = init: {
    var costs: BuiltinCosts = undefined;

    // ===== Integer operations =====

    // addInteger: CPU max_size, MEM max_size
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.add_integer)] = .{ .two = .{
        .mem = .{ .max_size = .{ .intercept = 1, .slope = 1 } },
        .cpu = .{ .max_size = .{ .intercept = 100788, .slope = 420 } },
    } };

    // subtractInteger: CPU max_size, MEM max_size
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.subtract_integer)] = .{ .two = .{
        .mem = .{ .max_size = .{ .intercept = 1, .slope = 1 } },
        .cpu = .{ .max_size = .{ .intercept = 100788, .slope = 420 } },
    } };

    // multiplyInteger: CPU multiplied_sizes, MEM added_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.multiply_integer)] = .{ .two = .{
        .mem = .{ .added_sizes = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .multiplied_sizes = .{ .intercept = 90434, .slope = 519 } },
    } };

    // divideInteger: CPU const_above_diagonal, MEM subtracted_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.divide_integer)] = .{ .two = .{
        .mem = .{ .subtracted_sizes = .{ .intercept = 0, .slope = 1, .minimum = 1 } },
        .cpu = .{ .const_above_diagonal = .{
            .constant = 85848,
            .model = .{
                .minimum = 85848,
                .coeff_00 = 123203,
                .coeff_10 = 1716,
                .coeff_01 = 7305,
                .coeff_20 = 57,
                .coeff_11 = 549,
                .coeff_02 = -900,
            },
        } },
    } };

    // quotientInteger: CPU const_above_diagonal, MEM subtracted_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.quotient_integer)] = .{ .two = .{
        .mem = .{ .subtracted_sizes = .{ .intercept = 0, .slope = 1, .minimum = 1 } },
        .cpu = .{ .const_above_diagonal = .{
            .constant = 85848,
            .model = .{
                .minimum = 85848,
                .coeff_00 = 123203,
                .coeff_10 = 1716,
                .coeff_01 = 7305,
                .coeff_20 = 57,
                .coeff_11 = 549,
                .coeff_02 = -900,
            },
        } },
    } };

    // remainderInteger: CPU const_above_diagonal, MEM linear_in_y
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.remainder_integer)] = .{ .two = .{
        .mem = .{ .linear_in_y = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .const_above_diagonal = .{
            .constant = 85848,
            .model = .{
                .minimum = 85848,
                .coeff_00 = 123203,
                .coeff_10 = 1716,
                .coeff_01 = 7305,
                .coeff_20 = 57,
                .coeff_11 = 549,
                .coeff_02 = -900,
            },
        } },
    } };

    // modInteger: CPU const_above_diagonal, MEM linear_in_y
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.mod_integer)] = .{ .two = .{
        .mem = .{ .linear_in_y = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .const_above_diagonal = .{
            .constant = 85848,
            .model = .{
                .minimum = 85848,
                .coeff_00 = 123203,
                .coeff_10 = 1716,
                .coeff_01 = 7305,
                .coeff_20 = 57,
                .coeff_11 = 549,
                .coeff_02 = -900,
            },
        } },
    } };

    // equalsInteger: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.equals_integer)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 51775, .slope = 558 } },
    } };

    // lessThanInteger: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.less_than_integer)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 44749, .slope = 541 } },
    } };

    // lessThanEqualsInteger: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.less_than_equals_integer)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 43285, .slope = 552 } },
    } };

    // ===== ByteString operations =====

    // appendByteString: CPU added_sizes, MEM added_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.append_byte_string)] = .{ .two = .{
        .mem = .{ .added_sizes = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .added_sizes = .{ .intercept = 1000, .slope = 173 } },
    } };

    // consByteString: CPU linear_in_y, MEM added_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.cons_byte_string)] = .{ .two = .{
        .mem = .{ .added_sizes = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_y = .{ .intercept = 72010, .slope = 178 } },
    } };

    // sliceByteString: CPU linear_in_z, MEM linear_in_z
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.slice_byte_string)] = .{ .three = .{
        .mem = .{ .linear_in_z = .{ .intercept = 4, .slope = 0 } },
        .cpu = .{ .linear_in_z = .{ .intercept = 20467, .slope = 1 } },
    } };

    // lengthOfByteString: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.length_of_byte_string)] = one_const(10, 22100);

    // indexByteString: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.index_byte_string)] = two_const(4, 13169);

    // equalsByteString: CPU linear_on_diagonal, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.equals_byte_string)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .linear_on_diagonal = .{ .intercept = 29498, .slope = 38, .constant = 24548 } },
    } };

    // lessThanByteString: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.less_than_byte_string)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 28999, .slope = 74 } },
    } };

    // lessThanEqualsByteString: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.less_than_equals_byte_string)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 28999, .slope = 74 } },
    } };

    // ===== Cryptography and hash functions =====

    // sha2_256: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.sha2_256)] = .{ .one = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear = .{ .intercept = 270652, .slope = 22588 } },
    } };

    // sha3_256: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.sha3_256)] = .{ .one = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear = .{ .intercept = 1457325, .slope = 64566 } },
    } };

    // blake2b_256: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.blake2b_256)] = .{ .one = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear = .{ .intercept = 201305, .slope = 8356 } },
    } };

    // blake2b_224: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.blake2b_224)] = .{ .one = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear = .{ .intercept = 207616, .slope = 8310 } },
    } };

    // keccak_256: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.keccak_256)] = .{ .one = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear = .{ .intercept = 2261318, .slope = 64571 } },
    } };

    // verifyEd25519Signature: CPU linear_in_y, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.verify_ed25519_signature)] = .{ .three = .{
        .mem = .{ .constant = 10 },
        .cpu = .{ .linear_in_y = .{ .intercept = 53384111, .slope = 14333 } },
    } };

    // verifyEcdsaSecp256k1Signature: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.verify_ecdsa_secp256k1_signature)] = three_const(10, 43053543);

    // verifySchnorrSecp256k1Signature: CPU linear_in_y, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.verify_schnorr_secp256k1_signature)] = .{ .three = .{
        .mem = .{ .constant = 10 },
        .cpu = .{ .linear_in_y = .{ .intercept = 43574283, .slope = 26308 } },
    } };

    // ripemd_160: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.ripemd_160)] = .{ .one = .{
        .mem = .{ .constant = 3 },
        .cpu = .{ .linear = .{ .intercept = 1964219, .slope = 24520 } },
    } };

    // ===== String operations =====

    // appendString: CPU added_sizes, MEM added_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.append_string)] = .{ .two = .{
        .mem = .{ .added_sizes = .{ .intercept = 4, .slope = 1 } },
        .cpu = .{ .added_sizes = .{ .intercept = 1000, .slope = 59957 } },
    } };

    // equalsString: CPU linear_on_diagonal, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.equals_string)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .linear_on_diagonal = .{ .intercept = 1000, .slope = 60594, .constant = 39184 } },
    } };

    // encodeUtf8: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.encode_utf8)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 4, .slope = 2 } },
        .cpu = .{ .linear = .{ .intercept = 1000, .slope = 42921 } },
    } };

    // decodeUtf8: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.decode_utf8)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 4, .slope = 2 } },
        .cpu = .{ .linear = .{ .intercept = 91189, .slope = 769 } },
    } };

    // ===== Control flow =====

    // ifThenElse: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.if_then_else)] = three_const(1, 76049);

    // chooseUnit: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.choose_unit)] = two_const(4, 61462);

    // trace: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.trace)] = two_const(32, 59498);

    // ===== Pair operations =====

    // fstPair: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.fst_pair)] = one_const(32, 141895);

    // sndPair: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.snd_pair)] = one_const(32, 141992);

    // ===== List operations =====

    // chooseList: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.choose_list)] = three_const(32, 132994);

    // mkCons: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.mk_cons)] = two_const(32, 72362);

    // headList: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.head_list)] = one_const(32, 83150);

    // tailList: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.tail_list)] = one_const(32, 81663);

    // nullList: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.null_list)] = one_const(32, 74433);

    // ===== Data operations =====

    // chooseData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.choose_data)] = six_const(32, 94375);

    // constrData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.constr_data)] = two_const(32, 22151);

    // mapData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.map_data)] = one_const(32, 68246);

    // listData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.list_data)] = one_const(32, 33852);

    // iData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.i_data)] = one_const(32, 15299);

    // bData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.b_data)] = one_const(32, 11183);

    // unConstrData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_constr_data)] = one_const(32, 24588);

    // unMapData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_map_data)] = one_const(32, 24623);

    // unListData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_list_data)] = one_const(32, 25933);

    // unIData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_i_data)] = one_const(32, 20744);

    // unBData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_b_data)] = one_const(32, 20142);

    // equalsData: CPU min_size, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.equals_data)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .min_size = .{ .intercept = 898148, .slope = 27279 } },
    } };

    // mkPairData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.mk_pair_data)] = two_const(32, 11546);

    // mkNilData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.mk_nil_data)] = one_const(32, 7243);

    // mkNilPairData: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.mk_nil_pair_data)] = one_const(32, 7391);

    // serialiseData: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.serialise_data)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 0, .slope = 2 } },
        .cpu = .{ .linear = .{ .intercept = 955506, .slope = 213312 } },
    } };

    // ===== BLS12-381 G1 =====

    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_add)] = two_const(18, 962335);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_neg)] = one_const(18, 267929);

    // bls12_381_g1_scalar_mul: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_scalar_mul)] = .{ .two = .{
        .mem = .{ .constant = 18 },
        .cpu = .{ .linear_in_x = .{ .intercept = 76433006, .slope = 8868 } },
    } };

    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_equal)] = two_const(1, 442008);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_compress)] = one_const(6, 2780678);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_uncompress)] = one_const(18, 52948122);

    // bls12_381_g1_hash_to_group: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_hash_to_group)] = .{ .two = .{
        .mem = .{ .constant = 18 },
        .cpu = .{ .linear_in_x = .{ .intercept = 52538055, .slope = 3756 } },
    } };

    // bls12_381_g1_multi_scalar_mul: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g1_multi_scalar_mul)] = .{ .two = .{
        .mem = .{ .constant = 18 },
        .cpu = .{ .linear_in_x = .{ .intercept = 321837444, .slope = 25087669 } },
    } };

    // ===== BLS12-381 G2 =====

    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_add)] = two_const(36, 1995836);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_neg)] = one_const(36, 284546);

    // bls12_381_g2_scalar_mul: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_scalar_mul)] = .{ .two = .{
        .mem = .{ .constant = 36 },
        .cpu = .{ .linear_in_x = .{ .intercept = 158221314, .slope = 26549 } },
    } };

    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_equal)] = two_const(1, 901022);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_compress)] = one_const(12, 3227919);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_uncompress)] = one_const(36, 74698472);

    // bls12_381_g2_hash_to_group: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_hash_to_group)] = .{ .two = .{
        .mem = .{ .constant = 36 },
        .cpu = .{ .linear_in_x = .{ .intercept = 166917843, .slope = 4307 } },
    } };

    // bls12_381_g2_multi_scalar_mul: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_g2_multi_scalar_mul)] = .{ .two = .{
        .mem = .{ .constant = 36 },
        .cpu = .{ .linear_in_x = .{ .intercept = 617887431, .slope = 67302824 } },
    } };

    // ===== BLS12-381 pairing =====

    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_miller_loop)] = two_const(72, 254006273);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_mul_ml_result)] = two_const(72, 2174038);
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.bls12_381_final_verify)] = two_const(1, 333849714);

    // ===== Byte/Integer conversion =====

    // integerToByteString: CPU quadratic_in_z, MEM literal_in_y_or_linear_in_z
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.integer_to_byte_string)] = .{ .three = .{
        .mem = .{ .literal_in_y_or_linear_in_z = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .quadratic_in_z = .{ .coeff_0 = 1293828, .coeff_1 = 28716, .coeff_2 = 63 } },
    } };

    // byteStringToInteger: CPU quadratic_in_y, MEM linear_in_y
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.byte_string_to_integer)] = .{ .two = .{
        .mem = .{ .linear_in_y = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .quadratic_in_y = .{ .coeff_0 = 1006041, .coeff_1 = 43623, .coeff_2 = 251 } },
    } };

    // ===== Bitwise operations =====

    // andByteString: CPU linear_in_y_and_z, MEM linear_in_max_yz
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.and_byte_string)] = .{ .three = .{
        .mem = .{ .linear_in_max_yz = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_y_and_z = .{ .intercept = 100181, .slope_y = 726, .slope_z = 719 } },
    } };

    // orByteString: CPU linear_in_y_and_z, MEM linear_in_max_yz
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.or_byte_string)] = .{ .three = .{
        .mem = .{ .linear_in_max_yz = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_y_and_z = .{ .intercept = 100181, .slope_y = 726, .slope_z = 719 } },
    } };

    // xorByteString: CPU linear_in_y_and_z, MEM linear_in_max_yz
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.xor_byte_string)] = .{ .three = .{
        .mem = .{ .linear_in_max_yz = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_y_and_z = .{ .intercept = 100181, .slope_y = 726, .slope_z = 719 } },
    } };

    // complementByteString: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.complement_byte_string)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear = .{ .intercept = 107878, .slope = 680 } },
    } };

    // readBit: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.read_bit)] = two_const(1, 95336);

    // writeBits: CPU linear_in_y, MEM linear_in_x
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.write_bits)] = .{ .three = .{
        .mem = .{ .linear_in_x = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_y = .{ .intercept = 281145, .slope = 18848 } },
    } };

    // replicateByte: CPU linear_in_x, MEM linear_in_x
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.replicate_byte)] = .{ .two = .{
        .mem = .{ .linear_in_x = .{ .intercept = 1, .slope = 1 } },
        .cpu = .{ .linear_in_x = .{ .intercept = 180194, .slope = 159 } },
    } };

    // shiftByteString: CPU linear_in_x, MEM linear_in_x
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.shift_byte_string)] = .{ .two = .{
        .mem = .{ .linear_in_x = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_x = .{ .intercept = 158519, .slope = 8942 } },
    } };

    // rotateByteString: CPU linear_in_x, MEM linear_in_x
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.rotate_byte_string)] = .{ .two = .{
        .mem = .{ .linear_in_x = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .linear_in_x = .{ .intercept = 159378, .slope = 8813 } },
    } };

    // countSetBits: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.count_set_bits)] = .{ .one = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .linear = .{ .intercept = 107490, .slope = 3298 } },
    } };

    // findFirstSetBit: CPU linear, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.find_first_set_bit)] = .{ .one = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .linear = .{ .intercept = 106057, .slope = 655 } },
    } };

    // ===== Modular exponentiation =====

    // expModInteger: CPU exp_mod, MEM linear_in_z
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.exp_mod_integer)] = .{ .three = .{
        .mem = .{ .linear_in_z = .{ .intercept = 0, .slope = 1 } },
        .cpu = .{ .exp_mod = .{ .coeff_00 = 607153, .coeff_11 = 231697, .coeff_12 = 53144 } },
    } };

    // ===== Array/List operations =====

    // dropList: CPU linear_in_x, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.drop_list)] = .{ .two = .{
        .mem = .{ .constant = 4 },
        .cpu = .{ .linear_in_x = .{ .intercept = 116711, .slope = 1957 } },
    } };

    // lengthOfArray: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.length_of_array)] = one_const(10, 231883);

    // listToArray: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.list_to_array)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 7, .slope = 1 } },
        .cpu = .{ .linear = .{ .intercept = 1000, .slope = 24838 } },
    } };

    // indexArray: constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.index_array)] = two_const(32, 232010);

    // ===== Value operations (V4 — using real protocol values from JSON) =====

    // insertCoin: CPU linear, MEM linear
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.insert_coin)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 45, .slope = 21 } },
        .cpu = .{ .linear = .{ .intercept = 356924, .slope = 18413 } },
    } };

    // lookupCoin: CPU linear_in_z, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.lookup_coin)] = .{ .three = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .linear_in_z = .{ .intercept = 219951, .slope = 9444 } },
    } };

    // unionValue: CPU with_interaction, MEM added_sizes
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.union_value)] = .{ .two = .{
        .mem = .{ .added_sizes = .{ .intercept = 24, .slope = 21 } },
        .cpu = .{ .with_interaction = .{ .c00 = 1000, .c10 = 172116, .c01 = 183150, .c11 = 6 } },
    } };

    // valueContains: CPU const_above_diagonal, MEM constant
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.value_contains)] = .{ .two = .{
        .mem = .{ .constant = 1 },
        .cpu = .{ .const_above_diagonal = .{
            .constant = 213283,
            .model = .{
                .minimum = 0,
                .coeff_00 = 618401,
                .coeff_10 = 1998,
                .coeff_01 = 28258,
                .coeff_20 = 0,
                .coeff_11 = 0,
                .coeff_02 = 0,
            },
        } },
    } };

    // valueData: CPU linear, MEM linear
    // From builtinCostModelC.json in IntersectMBO/plutus
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.value_data)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 2, .slope = 22 } },
        .cpu = .{ .linear = .{ .intercept = 1000, .slope = 38159 } },
    } };

    // unValueData: CPU quadratic, MEM linear
    // From builtinCostModelC.json in IntersectMBO/plutus
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.un_value_data)] = .{ .one = .{
        .mem = .{ .linear = .{ .intercept = 1, .slope = 11 } },
        .cpu = .{ .quadratic = .{ .coeff_0 = 1000, .coeff_1 = 95933, .coeff_2 = 1 } },
    } };

    // scaleValue: CPU linear_in_y, MEM linear_in_y
    costs[@intFromEnum(@import("../ast/builtin.zig").DefaultFunction.scale_value)] = .{ .two = .{
        .mem = .{ .linear_in_y = .{ .intercept = 12, .slope = 21 } },
        .cpu = .{ .linear_in_y = .{ .intercept = 1000, .slope = 277577 } },
    } };

    break :init costs;
};
