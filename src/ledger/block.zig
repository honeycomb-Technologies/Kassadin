const std = @import("std");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;
pub const Hash32 = types.Hash32;

/// Cardano era identifier (from Hard Fork Combinator wrapping).
pub const Era = enum(u8) {
    byron = 0,
    shelley = 1,
    allegra = 2,
    mary = 3,
    alonzo = 4,
    babbage = 5,
    conway = 6,
    _,
};

/// Parsed block header fields (common across Shelley+ eras).
pub const BlockHeader = struct {
    block_no: BlockNo,
    slot: SlotNo,
    prev_hash: ?HeaderHash, // null for genesis
    issuer_vkey: [32]u8,
    vrf_vkey: [32]u8,
    block_body_size: u64,
    block_body_hash: Hash32,
    protocol_version_major: u64,
    protocol_version_minor: u64,

    // Raw CBOR of the full header body (for KES signature verification)
    header_body_raw: []const u8,
    // Raw CBOR of the KES signature
    kes_signature_raw: []const u8,
};

/// A parsed Cardano block (era-tagged).
pub const Block = struct {
    era: Era,
    header: BlockHeader,
    // Raw CBOR of the full header [header_body, kes_sig] — for block hash computation
    // Cardano block hash = Blake2b-256 of these bytes (hashAnnotated pattern)
    header_raw: []const u8,
    // Raw CBOR slices for the block components
    tx_bodies_raw: []const u8,
    tx_witnesses_raw: []const u8,
    auxiliary_data_raw: []const u8,
    invalid_txs_raw: ?[]const u8, // Alonzo+ only

    /// Compute the block hash (Blake2b-256 of the full header CBOR).
    /// This matches the Haskell headerHash = extractHash . hashAnnotated
    pub fn hash(self: *const Block) HeaderHash {
        return Blake2b256.hash(self.header_raw);
    }
};

/// Parse a Cardano block from raw CBOR bytes.
/// Supports:
/// - N2N format: tag(24) + bytes([era_id, block]) — ouroboros-consensus golden files
/// - HFC-wrapped: [era_id, block] — direct HFC encoding
/// - Raw block: array(4) or array(5) — era-specific block without wrapping
pub fn parseBlock(data: []const u8) !Block {
    var dec = Decoder.init(data);

    var era: Era = .shelley;

    // Check for CBOR tag 24 wrapping (N2N serialization)
    const first_byte = try dec.peekByte();
    if (first_byte == 0xd8) {
        // Tag follows — check if it's tag 24
        const tag = try dec.decodeTag();
        if (tag == 24) {
            // CBOR-in-CBOR: decode inner bytestring
            const inner_bytes = try dec.decodeBytes();
            // Recurse on the inner bytes
            return parseBlock(inner_bytes);
        }
        // Other tags — not supported yet
        return error.InvalidCbor;
    }

    if (first_byte == 0x82) {
        // array(2) — HFC wrapping: [era_id, era_block]
        _ = try dec.decodeArrayLen();
        const era_id = try dec.decodeUint();
        // N2N era IDs are offset: Byron=0, Shelley=1, Allegra=2, Mary=3, Alonzo=4, Babbage=5, Conway=6
        // But ouroboros-consensus uses: Shelley=2, Allegra=3, Mary=4, Alonzo=5, Babbage=6, Conway=7
        // Map to our internal Era enum
        if (era_id <= 7) {
            era = switch (era_id) {
                0 => .byron,
                1 => .shelley,
                2 => .shelley, // N2N Shelley can be tagged as 2
                3 => .allegra,
                4 => .mary,
                5 => .alonzo,
                6 => .babbage,
                7 => .conway,
                else => return error.InvalidCbor,
            };
        } else {
            return error.InvalidCbor;
        }
        // The remaining data is the era-specific block
    } else if (first_byte == 0x85) {
        era = .alonzo; // array(5) = Alonzo+
    } else if (first_byte == 0x84) {
        era = .shelley; // array(4) = pre-Alonzo
    }

    // Parse block structure: [header, tx_bodies, tx_witnesses, aux_data, ?invalid_txs]
    const block_arr_len = try dec.decodeArrayLen();
    const num_elements = block_arr_len orelse return error.InvalidCbor;

    if (num_elements < 4) return error.InvalidCbor;

    // Element 0: Header = [header_body, kes_signature]
    const header_start = dec.pos;
    _ = try dec.decodeArrayLen(); // array(2)

    // Header body
    const header_body_raw = try dec.sliceOfNextValue();

    // Parse header body fields
    var hb_dec = Decoder.init(header_body_raw);
    const hb_len = try hb_dec.decodeArrayLen() orelse return error.InvalidCbor;
    if (hb_len < 10) return error.InvalidCbor;

    const block_no = try hb_dec.decodeUint();
    const slot = try hb_dec.decodeUint();

    // prev_hash: bytes(32) or null
    var prev_hash: ?HeaderHash = null;
    const ph_major = try hb_dec.peekMajorType();
    if (ph_major == 2) {
        const ph_bytes = try hb_dec.decodeBytes();
        if (ph_bytes.len == 32) {
            prev_hash = ph_bytes[0..32].*;
        }
    } else {
        try hb_dec.skipValue(); // null or other
    }

    // issuer_vkey
    const issuer_vkey_bytes = try hb_dec.decodeBytes();
    if (issuer_vkey_bytes.len != 32) return error.InvalidCbor;
    var issuer_vkey: [32]u8 = undefined;
    @memcpy(&issuer_vkey, issuer_vkey_bytes);

    // vrf_vkey
    const vrf_vkey_bytes = try hb_dec.decodeBytes();
    if (vrf_vkey_bytes.len != 32) return error.InvalidCbor;
    var vrf_vkey: [32]u8 = undefined;
    @memcpy(&vrf_vkey, vrf_vkey_bytes);

    // VRF result(s) — pre-Babbage (15 fields) has 2 VRF results, Babbage+ (10 fields) has 1
    try hb_dec.skipValue(); // VRF result 1
    if (hb_len >= 15) {
        try hb_dec.skipValue(); // VRF result 2 (nonce VRF, pre-Babbage only)
    }

    // block_body_size
    const body_size = try hb_dec.decodeUint();

    // block_body_hash
    const body_hash_bytes = try hb_dec.decodeBytes();
    if (body_hash_bytes.len != 32) return error.InvalidCbor;
    var body_hash: Hash32 = undefined;
    @memcpy(&body_hash, body_hash_bytes);

    // Operational certificate — format varies by era:
    // Pre-Babbage (15 fields): 4 separate fields (vkey, seq, period, sig)
    // Babbage+ (10 fields): 1 array of 4 elements [vkey, seq, period, sig]
    if (hb_len <= 10) {
        // Babbage+: opcert is a single array
        try hb_dec.skipValue(); // [hot_vkey, seq, period, sig]
    } else {
        // Pre-Babbage: 4 separate fields
        try hb_dec.skipValue(); // hot_vkey
        try hb_dec.skipValue(); // seq_no
        try hb_dec.skipValue(); // kes_period
        try hb_dec.skipValue(); // cold_sig
    }

    // Protocol version — format varies:
    // Babbage+ (10 fields): array [major, minor]
    // Pre-Babbage (15 fields): 2 separate uint fields
    var pv_major: u64 = 0;
    var pv_minor: u64 = 0;
    const pv_peek = try hb_dec.peekMajorType();
    if (pv_peek == 4) {
        const pv_arr = try hb_dec.decodeArrayLen() orelse return error.InvalidCbor;
        if (pv_arr >= 2) {
            pv_major = try hb_dec.decodeUint();
            pv_minor = try hb_dec.decodeUint();
        }
    } else {
        pv_major = try hb_dec.decodeUint();
        pv_minor = try hb_dec.decodeUint();
    }

    // KES signature
    const kes_sig_raw = try dec.sliceOfNextValue();

    // Full header raw: from header_start to current position
    const header_raw = data[header_start..dec.pos];

    // Elements 1-3 (or 1-4): tx_bodies, tx_witnesses, aux_data, [invalid_txs]
    const tx_bodies_raw = try dec.sliceOfNextValue();
    const tx_witnesses_raw = try dec.sliceOfNextValue();
    const auxiliary_data_raw = try dec.sliceOfNextValue();

    var invalid_txs_raw: ?[]const u8 = null;
    if (num_elements >= 5) {
        invalid_txs_raw = try dec.sliceOfNextValue();
    }

    return .{
        .era = era,
        .header = .{
            .block_no = block_no,
            .slot = slot,
            .prev_hash = prev_hash,
            .issuer_vkey = issuer_vkey,
            .vrf_vkey = vrf_vkey,
            .block_body_size = body_size,
            .block_body_hash = body_hash,
            .protocol_version_major = pv_major,
            .protocol_version_minor = pv_minor,
            .header_body_raw = header_body_raw,
            .kes_signature_raw = kes_sig_raw,
        },
        .header_raw = header_raw,
        .tx_bodies_raw = tx_bodies_raw,
        .tx_witnesses_raw = tx_witnesses_raw,
        .auxiliary_data_raw = auxiliary_data_raw,
        .invalid_txs_raw = invalid_txs_raw,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "block: parse real Alonzo golden block" {
    // Load the golden block from cardano-ledger
    const block_data = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer std.testing.allocator.free(block_data);

    const block = try parseBlock(block_data);

    // Verify header fields
    try std.testing.expectEqual(@as(BlockNo, 3), block.header.block_no);
    try std.testing.expectEqual(@as(SlotNo, 9), block.header.slot);
    try std.testing.expect(block.header.prev_hash != null);
    try std.testing.expectEqual(@as(usize, 32), block.header.issuer_vkey.len);
    try std.testing.expectEqual(@as(usize, 32), block.header.vrf_vkey.len);

    // Verify components are present
    try std.testing.expect(block.tx_bodies_raw.len > 0);
    try std.testing.expect(block.tx_witnesses_raw.len > 0);
    try std.testing.expect(block.auxiliary_data_raw.len > 0);
    try std.testing.expect(block.invalid_txs_raw != null); // Alonzo has invalid_txs
}

test "block: era detection — raw Alonzo" {
    const block_data = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "tests/vectors/alonzo_block.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer std.testing.allocator.free(block_data);

    const block = try parseBlock(block_data);
    try std.testing.expectEqual(Era.alonzo, block.era);
}

test "block: parse N2N golden blocks from ouroboros-consensus" {
    const allocator = std.testing.allocator;
    const eras = [_]struct { file: []const u8, expected_era: Era }{
        .{ .file = "tests/vectors/golden_block_shelley.cbor", .expected_era = .shelley },
        .{ .file = "tests/vectors/golden_block_allegra.cbor", .expected_era = .allegra },
        .{ .file = "tests/vectors/golden_block_mary.cbor", .expected_era = .mary },
        .{ .file = "tests/vectors/golden_block_alonzo.cbor", .expected_era = .alonzo },
        .{ .file = "tests/vectors/golden_block_babbage.cbor", .expected_era = .babbage },
        .{ .file = "tests/vectors/golden_block_conway.cbor", .expected_era = .conway },
    };

    for (eras) |era_test| {
        const data = std.fs.cwd().readFileAlloc(allocator, era_test.file, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(data);

        const block = parseBlock(data) catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{ era_test.file, err });
            return err;
        };

        // Verify era detected correctly
        try std.testing.expectEqual(era_test.expected_era, block.era);

        // Verify basic header fields are populated
        try std.testing.expect(block.header.issuer_vkey.len == 32);
        try std.testing.expect(block.header.vrf_vkey.len == 32);
        try std.testing.expect(block.tx_bodies_raw.len > 0);
        try std.testing.expect(block.tx_witnesses_raw.len > 0);
    }
}
