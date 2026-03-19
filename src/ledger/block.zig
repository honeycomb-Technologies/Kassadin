const std = @import("std");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;
pub const Hash32 = types.Hash32;

const byron_epoch_slots: u64 = 21_600;
const empty_cbor_list = &[_]u8{0x80};

const UnwrappedHeader = struct {
    era: ?Era,
    raw: []const u8,
    hash_tag: ?u8,
};

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
    vrf_result_raw: []const u8 = empty_cbor_list,
    leader_vrf_raw: ?[]const u8 = null,
    block_body_size: u64,
    block_body_hash: Hash32,
    opcert_hot_vkey: ?[32]u8 = null,
    opcert_sequence_no: ?u64 = null,
    opcert_kes_period: ?u64 = null,
    opcert_sigma: ?[64]u8 = null,
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
    hash_tag: ?u8 = null,

    /// Compute the block hash (Blake2b-256 of the full header CBOR).
    /// This matches the Haskell headerHash = extractHash . hashAnnotated
    pub fn hash(self: *const Block) HeaderHash {
        if (self.hash_tag) |tag| {
            return hashByronHeaderRaw(self.header_raw, tag);
        }
        return Blake2b256.hash(self.header_raw);
    }
};

fn mapEraId(era_id: u64) !Era {
    return switch (era_id) {
        0 => .byron,
        1 => .shelley,
        2 => .shelley, // N2N Shelley can be tagged as 2
        3 => .allegra,
        4 => .mary,
        5 => .alonzo,
        6 => .babbage,
        7 => .conway,
        else => error.InvalidCbor,
    };
}

fn unwrapHeader(data: []const u8) !UnwrappedHeader {
    var dec = Decoder.init(data);
    const first_byte = try dec.peekByte();

    if (first_byte == 0xd8) {
        const tag = try dec.decodeTag();
        if (tag != 24) return error.InvalidCbor;
        return unwrapHeader(try dec.decodeBytes());
    }

    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 2) return error.InvalidCbor;

    const first_major = try dec.peekMajorType();
    if (first_major == 0) {
        const era_id = try dec.decodeUint();
        if (era_id == 0) {
            const nested = try dec.sliceOfNextValue();
            return unwrapByronHeader(nested);
        }

        const inner_header_raw = try dec.sliceOfNextValue();
        var inner_dec = Decoder.init(inner_header_raw);
        const inner_major = try inner_dec.peekMajorType();

        const inner_header = switch (inner_major) {
            2 => try inner_dec.decodeBytes(),
            6 => blk: {
                const tag = try inner_dec.decodeTag();
                if (tag != 24) return error.InvalidCbor;
                break :blk try inner_dec.decodeBytes();
            },
            else => inner_header_raw,
        };

        return .{
            .era = try mapEraId(era_id),
            .raw = inner_header,
            .hash_tag = null,
        };
    }

    return .{
        .era = null,
        .raw = data,
        .hash_tag = null,
    };
}

fn unwrapByronHeader(data: []const u8) !UnwrappedHeader {
    var dec = Decoder.init(data);
    const outer_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (outer_len != 2) return error.InvalidCbor;

    const ctx_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (ctx_len != 2) return error.InvalidCbor;

    const tag = try dec.decodeUint();
    if (tag > 1) return error.InvalidCbor;
    _ = try dec.decodeUint(); // block size hint

    const header_raw = switch (try dec.peekMajorType()) {
        2 => try dec.decodeBytes(),
        6 => blk: {
            const cbor_tag = try dec.decodeTag();
            if (cbor_tag != 24) return error.InvalidCbor;
            break :blk try dec.decodeBytes();
        },
        else => try dec.sliceOfNextValue(),
    };

    return .{
        .era = .byron,
        .raw = header_raw,
        .hash_tag = @intCast(tag),
    };
}

fn parseDirectHeader(data: []const u8) !BlockHeader {
    var dec = Decoder.init(data);
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 2) return error.InvalidCbor;

    const header_body_raw = try dec.sliceOfNextValue();
    var hb_dec = Decoder.init(header_body_raw);
    const hb_len = try hb_dec.decodeArrayLen() orelse return error.InvalidCbor;
    if (hb_len < 10) return error.InvalidCbor;

    const block_no = try hb_dec.decodeUint();
    const slot = try hb_dec.decodeUint();

    var prev_hash: ?HeaderHash = null;
    const ph_major = try hb_dec.peekMajorType();
    if (ph_major == 2) {
        const ph_bytes = try hb_dec.decodeBytes();
        if (ph_bytes.len == 32) {
            prev_hash = ph_bytes[0..32].*;
        }
    } else {
        try hb_dec.skipValue();
    }

    const issuer_vkey_bytes = try hb_dec.decodeBytes();
    if (issuer_vkey_bytes.len != 32) return error.InvalidCbor;
    var issuer_vkey: [32]u8 = undefined;
    @memcpy(&issuer_vkey, issuer_vkey_bytes);

    const vrf_vkey_bytes = try hb_dec.decodeBytes();
    if (vrf_vkey_bytes.len != 32) return error.InvalidCbor;
    var vrf_vkey: [32]u8 = undefined;
    @memcpy(&vrf_vkey, vrf_vkey_bytes);

    const vrf_result_raw = try hb_dec.sliceOfNextValue();
    var leader_vrf_raw: ?[]const u8 = null;
    if (hb_len >= 15) {
        leader_vrf_raw = try hb_dec.sliceOfNextValue(); // pre-Babbage leader VRF cert
    }

    const body_size = try hb_dec.decodeUint();

    const body_hash_bytes = try hb_dec.decodeBytes();
    if (body_hash_bytes.len != 32) return error.InvalidCbor;
    var body_hash: Hash32 = undefined;
    @memcpy(&body_hash, body_hash_bytes);

    var opcert_hot_vkey: ?[32]u8 = null;
    var opcert_sequence_no: ?u64 = null;
    var opcert_kes_period: ?u64 = null;
    var opcert_sigma: ?[64]u8 = null;
    if (hb_len <= 10) {
        if (try parseOperationalCertArray(&hb_dec)) |opcert| {
            opcert_hot_vkey = opcert.hot_vkey;
            opcert_sequence_no = opcert.sequence_no;
            opcert_kes_period = opcert.kes_period;
            opcert_sigma = opcert.sigma;
        }
    } else {
        const opcert = try parseOperationalCertTuple(&hb_dec);
        opcert_hot_vkey = opcert.hot_vkey;
        opcert_sequence_no = opcert.sequence_no;
        opcert_kes_period = opcert.kes_period;
        opcert_sigma = opcert.sigma;
    }

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

    const kes_sig_raw = try dec.sliceOfNextValue();

    return .{
        .block_no = block_no,
        .slot = slot,
        .prev_hash = prev_hash,
        .issuer_vkey = issuer_vkey,
        .vrf_vkey = vrf_vkey,
        .vrf_result_raw = vrf_result_raw,
        .leader_vrf_raw = leader_vrf_raw,
        .block_body_size = body_size,
        .block_body_hash = body_hash,
        .opcert_hot_vkey = opcert_hot_vkey,
        .opcert_sequence_no = opcert_sequence_no,
        .opcert_kes_period = opcert_kes_period,
        .opcert_sigma = opcert_sigma,
        .protocol_version_major = pv_major,
        .protocol_version_minor = pv_minor,
        .header_body_raw = header_body_raw,
        .kes_signature_raw = kes_sig_raw,
    };
}

const OperationalCert = struct {
    hot_vkey: [32]u8,
    sequence_no: u64,
    kes_period: u64,
    sigma: [64]u8,
};

fn parseOperationalCertArray(dec: *Decoder) !?OperationalCert {
    const len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (len == 0) return null;
    if (len != 4) return error.InvalidCbor;
    return try parseOperationalCertFields(dec);
}

fn parseOperationalCertTuple(dec: *Decoder) !OperationalCert {
    return parseOperationalCertFields(dec);
}

fn parseOperationalCertFields(dec: *Decoder) !OperationalCert {
    const hot_vkey_bytes = try dec.decodeBytes();
    if (hot_vkey_bytes.len != 32) return error.InvalidCbor;
    var hot_vkey: [32]u8 = undefined;
    @memcpy(&hot_vkey, hot_vkey_bytes);

    const sequence_no = try dec.decodeUint();
    const kes_period = try dec.decodeUint();

    const sigma_bytes = try dec.decodeBytes();
    if (sigma_bytes.len != 64) return error.InvalidCbor;
    var sigma: [64]u8 = undefined;
    @memcpy(&sigma, sigma_bytes);

    return .{
        .hot_vkey = hot_vkey,
        .sequence_no = sequence_no,
        .kes_period = kes_period,
        .sigma = sigma,
    };
}

fn parseByronRegularHeader(data: []const u8) !BlockHeader {
    var dec = Decoder.init(data);
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 5) return error.InvalidCbor;

    _ = try dec.decodeUint(); // protocol magic

    const prev_hash_bytes = try dec.decodeBytes();
    if (prev_hash_bytes.len != 32) return error.InvalidCbor;
    const prev_hash = prev_hash_bytes[0..32].*;

    const body_proof_raw = try dec.sliceOfNextValue();

    const consensus_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (consensus_len != 4) return error.InvalidCbor;

    const slot_id_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (slot_id_len != 2) return error.InvalidCbor;
    const epoch = try dec.decodeUint();
    const slot_in_epoch = try dec.decodeUint();
    const slot = byronSlotNumber(epoch, slot_in_epoch);

    try dec.skipValue(); // genesis key
    const difficulty = try decodeByronChainDifficulty(&dec);
    try dec.skipValue(); // block signature

    const extra_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (extra_len != 4) return error.InvalidCbor;

    const protocol_version_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (protocol_version_len != 3) return error.InvalidCbor;
    const pv_major = try dec.decodeUint();
    const pv_minor = try dec.decodeUint();
    _ = try dec.decodeUint(); // alt

    try dec.skipValue(); // software version
    try dec.skipValue(); // attributes
    try dec.skipValue(); // extra proof

    return makeByronHeader(
        difficulty,
        slot,
        prev_hash,
        Blake2b256.hash(body_proof_raw),
        pv_major,
        pv_minor,
        data,
    );
}

fn parseByronBoundaryHeader(data: []const u8) !BlockHeader {
    var dec = Decoder.init(data);
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 5) return error.InvalidCbor;

    _ = try dec.decodeUint(); // protocol magic

    const prev_hash_bytes = try dec.decodeBytes();
    if (prev_hash_bytes.len != 32) return error.InvalidCbor;
    const prev_hash = prev_hash_bytes[0..32].*;

    const body_hash_bytes = try dec.decodeBytes();
    if (body_hash_bytes.len != 32) return error.InvalidCbor;
    const body_hash = body_hash_bytes[0..32].*;

    const consensus_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (consensus_len != 2) return error.InvalidCbor;
    const epoch = try dec.decodeUint();
    const difficulty = try decodeByronChainDifficulty(&dec);
    const has_genesis_prev = try parseByronBoundaryExtraData(&dec);

    return makeByronHeader(
        difficulty,
        byronBoundarySlot(epoch),
        if (has_genesis_prev or epoch == 0) null else prev_hash,
        body_hash,
        0,
        0,
        data,
    );
}

fn makeByronHeader(
    block_no: BlockNo,
    slot: SlotNo,
    prev_hash: ?HeaderHash,
    body_hash: Hash32,
    pv_major: u64,
    pv_minor: u64,
    raw: []const u8,
) BlockHeader {
    return .{
        .block_no = block_no,
        .slot = slot,
        .prev_hash = prev_hash,
        .issuer_vkey = [_]u8{0} ** 32,
        .vrf_vkey = [_]u8{0} ** 32,
        .block_body_size = 0,
        .block_body_hash = body_hash,
        .protocol_version_major = pv_major,
        .protocol_version_minor = pv_minor,
        .header_body_raw = raw,
        .kes_signature_raw = empty_cbor_list,
    };
}

fn decodeByronChainDifficulty(dec: *Decoder) !u64 {
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 1) return error.InvalidCbor;
    return dec.decodeUint();
}

fn parseByronBoundaryExtraData(dec: *Decoder) !bool {
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 1) return error.InvalidCbor;

    const map_len = (try dec.decodeMapLen()) orelse return error.InvalidCbor;
    var has_genesis_tag = false;
    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        const key = try dec.decodeUint();
        const value = try dec.decodeBytes();
        if (key == 255 and std.mem.eql(u8, value, "Genesis")) {
            has_genesis_tag = true;
        }
    }

    return has_genesis_tag;
}

fn byronBoundarySlot(epoch: u64) u64 {
    return epoch * byron_epoch_slots;
}

fn byronSlotNumber(epoch: u64, slot_in_epoch: u64) u64 {
    return byronBoundarySlot(epoch) + slot_in_epoch;
}

fn hashByronHeaderRaw(raw: []const u8, tag: u8) HeaderHash {
    var state = Blake2b256.State.init();
    const prefix = [_]u8{ 0x82, tag };
    state.update(&prefix);
    state.update(raw);
    return state.final();
}

/// Parse a Shelley+ block header from raw header bytes.
/// Supports direct headers and HFC-wrapped headers as seen on chain-sync.
pub fn parseHeader(data: []const u8) !BlockHeader {
    const unwrapped = try unwrapHeader(data);
    if (unwrapped.era == .byron) {
        return switch (unwrapped.hash_tag orelse return error.InvalidCbor) {
            0 => parseByronBoundaryHeader(unwrapped.raw),
            1 => parseByronRegularHeader(unwrapped.raw),
            else => error.InvalidCbor,
        };
    }
    return parseDirectHeader(unwrapped.raw);
}

/// Compute the Cardano header hash for a chain-sync header payload.
pub fn hashHeader(data: []const u8) !HeaderHash {
    const unwrapped = try unwrapHeader(data);
    if (unwrapped.era == .byron) {
        return hashByronHeaderRaw(unwrapped.raw, unwrapped.hash_tag orelse return error.InvalidCbor);
    }
    return Blake2b256.hash(unwrapped.raw);
}

/// Convert a chain-sync header payload into a block point for block-fetch.
pub fn pointFromHeader(data: []const u8) !types.Point {
    const header = try parseHeader(data);
    return .{
        .slot = header.slot,
        .hash = try hashHeader(data),
    };
}

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
        const era_or_tag = try dec.decodeUint();
        const wrapped_raw = try dec.sliceOfNextValue();

        if (era_or_tag <= 1) {
            var byron_probe = Decoder.init(wrapped_raw);
            const byron_len = (try byron_probe.decodeArrayLen()) orelse return error.InvalidCbor;
            if (byron_len == 3) {
                return parseByronBlock(wrapped_raw, @intCast(era_or_tag));
            }
        }

        era = try mapEraId(era_or_tag);
        dec = Decoder.init(wrapped_raw);
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
    const header_raw = try dec.sliceOfNextValue();
    const header = try parseDirectHeader(header_raw);

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
        .header = header,
        .header_raw = header_raw,
        .tx_bodies_raw = tx_bodies_raw,
        .tx_witnesses_raw = tx_witnesses_raw,
        .auxiliary_data_raw = auxiliary_data_raw,
        .invalid_txs_raw = invalid_txs_raw,
        .hash_tag = null,
    };
}

fn parseByronBlock(data: []const u8, tag: u8) !Block {
    var dec = Decoder.init(data);
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 3) return error.InvalidCbor;

    const header_raw = try dec.sliceOfNextValue();
    const body_raw = try dec.sliceOfNextValue();
    _ = try dec.sliceOfNextValue(); // extra body data / attributes

    var header = switch (tag) {
        0 => try parseByronBoundaryHeader(header_raw),
        1 => try parseByronRegularHeader(header_raw),
        else => return error.InvalidCbor,
    };
    header.block_body_size = body_raw.len;

    var tx_payload_raw: []const u8 = empty_cbor_list;
    if (tag == 1) {
        var body_dec = Decoder.init(body_raw);
        const body_len = (try body_dec.decodeArrayLen()) orelse return error.InvalidCbor;
        if (body_len != 4) return error.InvalidCbor;

        tx_payload_raw = try body_dec.sliceOfNextValue();
        try body_dec.skipValue();
        try body_dec.skipValue();
        try body_dec.skipValue();
    }

    return .{
        .era = .byron,
        .header = header,
        .header_raw = header_raw,
        .tx_bodies_raw = tx_payload_raw,
        .tx_witnesses_raw = empty_cbor_list,
        .auxiliary_data_raw = empty_cbor_list,
        .invalid_txs_raw = null,
        .hash_tag = tag,
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
    try std.testing.expect(block.header.vrf_result_raw.len > 0);
    try std.testing.expect(block.header.leader_vrf_raw != null);
    try std.testing.expect(block.header.opcert_hot_vkey != null);
    try std.testing.expect(block.header.opcert_sequence_no != null);
    try std.testing.expect(block.header.opcert_kes_period != null);
    try std.testing.expect(block.header.opcert_sigma != null);

    // Verify components are present
    try std.testing.expect(block.tx_bodies_raw.len > 0);
    try std.testing.expect(block.tx_witnesses_raw.len > 0);
    try std.testing.expect(block.auxiliary_data_raw.len > 0);
    try std.testing.expect(block.invalid_txs_raw != null); // Alonzo has invalid_txs
}

test "block: parse HFC-wrapped header point" {
    const allocator = std.testing.allocator;
    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/golden_block_conway.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const block = try parseBlock(block_data);

    var enc = @import("../cbor/encoder.zig").Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.encodeUint(7); // Conway HFC tag
    try enc.writeRaw(block.header_raw);

    const wrapped = try enc.toOwnedSlice();
    defer allocator.free(wrapped);

    const point = try pointFromHeader(wrapped);
    try std.testing.expectEqual(block.header.slot, point.slot);
    try std.testing.expectEqualSlices(u8, &block.hash(), &point.hash);
}

test "block: parse Byron regular block and matching header point" {
    const allocator = std.testing.allocator;

    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/golden/cardano/CardanoNodeToNodeVersion2/Block_Byron_regular",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const header_data = std.fs.cwd().readFileAlloc(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/golden/cardano/CardanoNodeToNodeVersion2/Header_Byron_regular",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(header_data);

    const block = try parseBlock(block_data);
    const point = try pointFromHeader(header_data);

    try std.testing.expectEqual(Era.byron, block.era);
    try std.testing.expect(block.header.block_no > 0);
    try std.testing.expect(block.header.slot > 0);
    try std.testing.expect(block.tx_bodies_raw.len > 1);
    try std.testing.expectEqual(block.header.slot, point.slot);
    try std.testing.expectEqualSlices(u8, &block.hash(), &point.hash);
}

test "block: parse Byron EBB block and matching header point" {
    const allocator = std.testing.allocator;

    const block_data = std.fs.cwd().readFileAlloc(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/golden/cardano/CardanoNodeToNodeVersion2/Block_Byron_EBB",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block_data);

    const header_data = std.fs.cwd().readFileAlloc(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/golden/cardano/CardanoNodeToNodeVersion2/Header_Byron_EBB",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(header_data);

    const block = try parseBlock(block_data);
    const point = try pointFromHeader(header_data);

    try std.testing.expectEqual(Era.byron, block.era);
    try std.testing.expectEqual(@as(BlockNo, 0), block.header.block_no);
    try std.testing.expectEqual(@as(SlotNo, 0), block.header.slot);
    try std.testing.expect(block.header.prev_hash == null);
    try std.testing.expectEqual(block.header.slot, point.slot);
    try std.testing.expectEqualSlices(u8, &block.hash(), &point.hash);
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
        try std.testing.expect(block.header.vrf_result_raw.len > 0);
        try std.testing.expect(block.header.opcert_hot_vkey != null);
        try std.testing.expect(block.header.opcert_sequence_no != null);
        try std.testing.expect(block.header.opcert_kes_period != null);
        try std.testing.expect(block.header.opcert_sigma != null);
        try std.testing.expect(block.tx_bodies_raw.len > 0);
        try std.testing.expect(block.tx_witnesses_raw.len > 0);
    }
}
