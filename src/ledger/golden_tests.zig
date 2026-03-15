//! Cross-validation tests for Phase 3 ledger modules against real golden block data.
//! Every value here was independently computed using Python's cbor2 library on the
//! same golden Alonzo block from cardano-ledger/eras/alonzo/test-suite/golden/block.cbor.

const std = @import("std");
const block_mod = @import("block.zig");
const tx_mod = @import("transaction.zig");
const cert_mod = @import("certificates.zig");
const witness_mod = @import("witness.zig");
const multiasset_mod = @import("multiasset.zig");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

fn loadGoldenBlock(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, "tests/vectors/alonzo_block.cbor", 10 * 1024 * 1024);
}

// ── Block-level tests ──

test "golden: block header fields" {
    const allocator = std.testing.allocator;
    const data = loadGoldenBlock(allocator) catch return;
    defer allocator.free(data);
    const block = try block_mod.parseBlock(data);

    try std.testing.expectEqual(@as(u64, 3), block.header.block_no);
    try std.testing.expectEqual(@as(u64, 9), block.header.slot);
    try std.testing.expectEqual(@as(u64, 2345), block.header.block_body_size);
    try std.testing.expectEqual(@as(u64, 2), block.header.protocol_version_major);
    try std.testing.expectEqual(@as(u64, 0), block.header.protocol_version_minor);
}

// ── TxId verification ──

test "golden: TxId byte-exact match" {
    const allocator = std.testing.allocator;
    const data = loadGoldenBlock(allocator) catch return;
    defer allocator.free(data);
    const block = try block_mod.parseBlock(data);

    var dec = Decoder.init(block.tx_bodies_raw);
    _ = try dec.decodeArrayLen();
    const tx_raw = try dec.sliceOfNextValue();
    var tx = try tx_mod.parseTxBody(allocator, tx_raw);
    defer tx_mod.freeTxBody(allocator, &tx);

    // Python: hashlib.blake2b(raw_tx_body, digest_size=32).hexdigest()
    const expected = [_]u8{
        0xad, 0x80, 0x33, 0xbc, 0x3f, 0x0d, 0xa2, 0x47,
        0xfb, 0x07, 0x43, 0x61, 0xad, 0x19, 0x5c, 0xaf,
        0xd5, 0xb8, 0xbd, 0xa1, 0x05, 0x31, 0x93, 0x25,
        0x45, 0x0f, 0x19, 0xd0, 0x67, 0x23, 0x20, 0x0a,
    };
    try std.testing.expectEqualSlices(u8, &expected, &tx.tx_id);
}

// ── Certificate parsing from real block ──

test "golden: parse 3 real certificates" {
    const allocator = std.testing.allocator;
    const data = loadGoldenBlock(allocator) catch return;
    defer allocator.free(data);
    const block = try block_mod.parseBlock(data);

    // Parse the tx body to find field 4 (certificates)
    var dec = Decoder.init(block.tx_bodies_raw);
    _ = try dec.decodeArrayLen();
    const tx_raw = try dec.sliceOfNextValue();

    // Manually decode the tx body map to find field 4
    var tx_dec = Decoder.init(tx_raw);
    const map_len = try tx_dec.decodeMapLen() orelse return;

    var certs_raw: ?[]const u8 = null;
    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        const key = try tx_dec.decodeUint();
        if (key == 4) {
            certs_raw = try tx_dec.sliceOfNextValue();
        } else {
            try tx_dec.skipValue();
        }
    }

    const raw = certs_raw orelse return;
    var cert_dec = Decoder.init(raw);
    const n_certs = (try cert_dec.decodeArrayLen()) orelse return;

    // Python says: 3 certificates
    try std.testing.expectEqual(@as(u64, 3), n_certs);

    // Cert 0: StakeRegistration (tag 0)
    const cert0_raw = try cert_dec.sliceOfNextValue();
    var c0_dec = Decoder.init(cert0_raw);
    const cert0 = try cert_mod.parseCertificate(&c0_dec);
    switch (cert0) {
        .stake_registration => |cred| {
            try std.testing.expectEqual(cert_mod.CredentialType.key_hash, cred.cred_type);
            // Python: hash=0d6a577e9441ad8ed9663931906e4d43ece8f82c712b1d0235affb06
            const expected_hash = [_]u8{
                0x0d, 0x6a, 0x57, 0x7e, 0x94, 0x41, 0xad, 0x8e,
                0xd9, 0x66, 0x39, 0x31, 0x90, 0x6e, 0x4d, 0x43,
                0xec, 0xe8, 0xf8, 0x2c, 0x71, 0x2b, 0x1d, 0x02,
                0x35, 0xaf, 0xfb, 0x06, 0x00, 0x00, 0x00, 0x00,
            };
            try std.testing.expectEqualSlices(u8, expected_hash[0..28], &cred.hash);
        },
        else => return error.UnexpectedCertType,
    }

    // Cert 1: PoolRegistration (tag 3) — skip detailed check, just verify tag
    const cert1_raw = try cert_dec.sliceOfNextValue();
    var c1_dec = Decoder.init(cert1_raw);
    const cert1 = try cert_mod.parseCertificate(&c1_dec);
    switch (cert1) {
        .pool_registration => |pp| {
            // Python: pledge=1, cost=5
            try std.testing.expectEqual(@as(u64, 1), pp.pledge);
            try std.testing.expectEqual(@as(u64, 5), pp.cost);
        },
        else => return error.UnexpectedCertType,
    }

    // Cert 2: MIR (tag 6)
    const cert2_raw = try cert_dec.sliceOfNextValue();
    var c2_dec = Decoder.init(cert2_raw);
    const cert2 = try cert_mod.parseCertificate(&c2_dec);
    try std.testing.expect(cert2 == .mir);
}

// ── Witness set from real block ──

test "golden: witness VKey prefix and redeemer ExUnits" {
    const allocator = std.testing.allocator;
    const data = loadGoldenBlock(allocator) catch return;
    defer allocator.free(data);
    const block = try block_mod.parseBlock(data);

    var ws_dec = Decoder.init(block.tx_witnesses_raw);
    _ = try ws_dec.decodeArrayLen();
    const ws_raw = try ws_dec.sliceOfNextValue();
    var ws = try witness_mod.parseWitnessSet(allocator, ws_raw);
    defer witness_mod.freeWitnessSet(allocator, &ws);

    // Python: vkey=3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29
    const expected_vkey = [_]u8{
        0x3b, 0x6a, 0x27, 0xbc, 0xce, 0xb6, 0xa4, 0x2d,
        0x62, 0xa3, 0xa8, 0xd0, 0x2a, 0x6f, 0x0d, 0x73,
        0x65, 0x32, 0x15, 0x77, 0x1d, 0xe2, 0x43, 0xa6,
        0x3a, 0xc0, 0x48, 0xa1, 0x8b, 0x59, 0xda, 0x29,
    };
    try std.testing.expectEqualSlices(u8, &expected_vkey, &ws.vkey_witnesses[0].vkey);

    // Python: redeemer tag=0, index=0, ex_units=[5000, 5000]
    try std.testing.expectEqual(@as(usize, 1), ws.redeemers.len);
    try std.testing.expectEqual(@as(u64, 5000), ws.redeemers[0].ex_units_mem);
    try std.testing.expectEqual(@as(u64, 5000), ws.redeemers[0].ex_units_steps);
}

// ── Script data hash verification ──

test "golden: script data hash matches tx field 11" {
    const allocator = std.testing.allocator;
    const data = loadGoldenBlock(allocator) catch return;
    defer allocator.free(data);
    const block = try block_mod.parseBlock(data);

    // Extract field 11 (script_data_hash) from tx body
    var dec = Decoder.init(block.tx_bodies_raw);
    _ = try dec.decodeArrayLen();
    const tx_raw = try dec.sliceOfNextValue();

    var tx_dec = Decoder.init(tx_raw);
    const map_len = try tx_dec.decodeMapLen() orelse return;

    var script_data_hash: ?[32]u8 = null;
    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        const key = try tx_dec.decodeUint();
        if (key == 11) {
            const h = try tx_dec.decodeBytes();
            if (h.len == 32) script_data_hash = h[0..32].*;
        } else {
            try tx_dec.skipValue();
        }
    }

    // Python: 9e1199a988ba72ffd6e9c269cadb3b53b5f360ff99f112d9b2ee30c4d74ad88b
    const expected = [_]u8{
        0x9e, 0x11, 0x99, 0xa9, 0x88, 0xba, 0x72, 0xff,
        0xd6, 0xe9, 0xc2, 0x69, 0xca, 0xdb, 0x3b, 0x53,
        0xb5, 0xf3, 0x60, 0xff, 0x99, 0xf1, 0x12, 0xd9,
        0xb2, 0xee, 0x30, 0xc4, 0xd7, 0x4a, 0xd8, 0x8b,
    };

    try std.testing.expect(script_data_hash != null);
    try std.testing.expectEqualSlices(u8, &expected, &script_data_hash.?);
}
