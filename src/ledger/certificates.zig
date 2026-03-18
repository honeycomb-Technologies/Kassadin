const std = @import("std");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");

pub const KeyHash = types.KeyHash;
pub const Hash28 = types.Hash28;
pub const Hash32 = types.Hash32;
pub const Coin = types.Coin;
pub const EpochNo = types.EpochNo;
pub const Credential = types.Credential;
pub const CredentialType = types.CredentialType;
pub const RewardAccount = types.RewardAccount;

/// Parsed certificate (Shelley through Conway).
pub const Certificate = union(enum) {
    // Shelley (tags 0-6)
    stake_registration: Credential, // tag 0
    stake_deregistration: Credential, // tag 1
    stake_delegation: struct { cred: Credential, pool: KeyHash }, // tag 2
    pool_registration: PoolParams, // tag 3
    pool_retirement: struct { pool: KeyHash, epoch: EpochNo }, // tag 4
    genesis_delegation: struct { genesis: Hash28, delegate: Hash28, vrf: Hash32 }, // tag 5
    mir: void, // tag 6 (MIR, simplified)

    // Conway (tags 7-18)
    reg_deposit: struct { cred: Credential, deposit: Coin }, // tag 7
    unreg_deposit: struct { cred: Credential, refund: Coin }, // tag 8
    vote_delegation: struct { cred: Credential, drep: DRep }, // tag 9
    stake_vote_delegation: struct { cred: Credential, pool: KeyHash, drep: DRep }, // tag 10
    stake_reg_delegation: struct { cred: Credential, pool: KeyHash, deposit: Coin }, // tag 11
    vote_reg_delegation: struct { cred: Credential, drep: DRep, deposit: Coin }, // tag 12
    stake_vote_reg_delegation: struct { cred: Credential, pool: KeyHash, drep: DRep, deposit: Coin }, // tag 13
    committee_auth: struct { cold: Credential, hot: Credential }, // tag 14
    committee_resign: struct { cold: Credential }, // tag 15
    drep_registration: struct { cred: Credential, deposit: Coin }, // tag 16
    drep_deregistration: struct { cred: Credential, refund: Coin }, // tag 17
    drep_update: struct { cred: Credential }, // tag 18
};

pub const DRep = union(enum) {
    key_hash: KeyHash,
    script_hash: Hash28,
    always_abstain: void,
    always_no_confidence: void,
};

pub const PoolParams = struct {
    operator: KeyHash,
    vrf_keyhash: Hash32,
    pledge: Coin,
    cost: Coin,
    margin: types.UnitInterval,
    reward_account: RewardAccount,
    owners: []const KeyHash,
};

/// Parse a credential from CBOR: [0, keyhash] or [1, scripthash]
fn parseCredential(dec: *Decoder) !Credential {
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();
    const hash_bytes = try dec.decodeBytes();
    if (hash_bytes.len != 28) return error.InvalidCbor;
    var hash: Hash28 = undefined;
    @memcpy(&hash, hash_bytes);
    return .{
        .cred_type = if (tag == 0) .key_hash else .script_hash,
        .hash = hash,
    };
}

/// Parse a DRep from CBOR: [0, keyhash] | [1, scripthash] | [2] | [3]
fn parseDRep(dec: *Decoder) !DRep {
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();
    switch (tag) {
        0 => {
            const h = try dec.decodeBytes();
            if (h.len != 28) return error.InvalidCbor;
            return .{ .key_hash = h[0..28].* };
        },
        1 => {
            const h = try dec.decodeBytes();
            if (h.len != 28) return error.InvalidCbor;
            return .{ .script_hash = h[0..28].* };
        },
        2 => return .always_abstain,
        3 => return .always_no_confidence,
        else => return error.InvalidCbor,
    }
}

fn parseUnitInterval(dec: *Decoder) !types.UnitInterval {
    const raw = try dec.sliceOfNextValue();
    var inner = Decoder.init(raw);

    if (raw.len > 0 and (raw[0] & 0xe0) == 0xc0) {
        const tag = try inner.decodeTag();
        if (tag != 30) return error.InvalidCbor;
    }

    const len = (try inner.decodeArrayLen()) orelse return error.InvalidCbor;
    if (len != 2) return error.InvalidCbor;

    const interval = types.UnitInterval{
        .numerator = try inner.decodeUint(),
        .denominator = try inner.decodeUint(),
    };
    if (!interval.isValid()) return error.InvalidCbor;
    return interval;
}

fn parsePoolOwners(
    allocator: Allocator,
    dec: *Decoder,
) ![]const KeyHash {
    var owner_count: u64 = 0;
    const major = try dec.peekMajorType();
    if (major == 6) {
        const tag = try dec.decodeTag();
        if (tag != 258) return error.InvalidCbor;
        owner_count = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    } else {
        owner_count = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    }

    const owners = try allocator.alloc(KeyHash, owner_count);
    errdefer allocator.free(owners);

    var i: u64 = 0;
    while (i < owner_count) : (i += 1) {
        const owner_bytes = try dec.decodeBytes();
        if (owner_bytes.len != 28) return error.InvalidCbor;
        @memcpy(&owners[i], owner_bytes);
    }

    return owners;
}

pub fn freeCertificate(allocator: Allocator, cert: *const Certificate) void {
    switch (cert.*) {
        .pool_registration => |pool| {
            if (pool.owners.len > 0) allocator.free(pool.owners);
        },
        else => {},
    }
}

/// Parse a certificate from CBOR.
pub fn parseCertificate(allocator: Allocator, dec: *Decoder) !Certificate {
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .{ .stake_registration = try parseCredential(dec) },
        1 => .{ .stake_deregistration = try parseCredential(dec) },
        2 => {
            const cred = try parseCredential(dec);
            const pool_bytes = try dec.decodeBytes();
            if (pool_bytes.len != 28) return error.InvalidCbor;
            return .{ .stake_delegation = .{ .cred = cred, .pool = pool_bytes[0..28].* } };
        },
        3 => {
            // Pool registration: (operator, vrf, pledge, cost, margin, reward, owners, relays, metadata)
            const op_bytes = try dec.decodeBytes();
            if (op_bytes.len != 28) return error.InvalidCbor;
            const vrf_bytes = try dec.decodeBytes();
            if (vrf_bytes.len != 32) return error.InvalidCbor;
            const pledge = try dec.decodeUint();
            const cost = try dec.decodeUint();
            const margin = try parseUnitInterval(dec);
            const reward_bytes = try dec.decodeBytes();
            if (reward_bytes.len != 29) return error.InvalidCbor;
            var reward_raw: [29]u8 = undefined;
            @memcpy(&reward_raw, reward_bytes);
            const owners = try parsePoolOwners(allocator, dec);
            errdefer allocator.free(owners);
            while (!dec.isComplete()) {
                try dec.skipValue();
            }
            return .{ .pool_registration = .{
                .operator = op_bytes[0..28].*,
                .vrf_keyhash = vrf_bytes[0..32].*,
                .pledge = pledge,
                .cost = cost,
                .margin = margin,
                .reward_account = try RewardAccount.fromBytes(reward_raw),
                .owners = owners,
            } };
        },
        4 => {
            const pool_bytes = try dec.decodeBytes();
            if (pool_bytes.len != 28) return error.InvalidCbor;
            const epoch = try dec.decodeUint();
            return .{ .pool_retirement = .{ .pool = pool_bytes[0..28].*, .epoch = epoch } };
        },
        5 => {
            const g = try dec.decodeBytes();
            const d = try dec.decodeBytes();
            const v = try dec.decodeBytes();
            return .{ .genesis_delegation = .{
                .genesis = g[0..28].*,
                .delegate = d[0..28].*,
                .vrf = v[0..32].*,
            } };
        },
        6 => {
            try dec.skipValue(); // MIR details
            return .mir;
        },
        7 => {
            const cred = try parseCredential(dec);
            const deposit = try dec.decodeUint();
            return .{ .reg_deposit = .{ .cred = cred, .deposit = deposit } };
        },
        8 => {
            const cred = try parseCredential(dec);
            const refund = try dec.decodeUint();
            return .{ .unreg_deposit = .{ .cred = cred, .refund = refund } };
        },
        9 => {
            const cred = try parseCredential(dec);
            const drep = try parseDRep(dec);
            return .{ .vote_delegation = .{ .cred = cred, .drep = drep } };
        },
        10 => {
            const cred = try parseCredential(dec);
            const pool_bytes = try dec.decodeBytes();
            if (pool_bytes.len != 28) return error.InvalidCbor;
            const drep = try parseDRep(dec);
            return .{ .stake_vote_delegation = .{
                .cred = cred,
                .pool = pool_bytes[0..28].*,
                .drep = drep,
            } };
        },
        11 => {
            const cred = try parseCredential(dec);
            const pool_bytes = try dec.decodeBytes();
            if (pool_bytes.len != 28) return error.InvalidCbor;
            const deposit = try dec.decodeUint();
            return .{ .stake_reg_delegation = .{
                .cred = cred,
                .pool = pool_bytes[0..28].*,
                .deposit = deposit,
            } };
        },
        12 => {
            const cred = try parseCredential(dec);
            const drep = try parseDRep(dec);
            const deposit = try dec.decodeUint();
            return .{ .vote_reg_delegation = .{
                .cred = cred,
                .drep = drep,
                .deposit = deposit,
            } };
        },
        13 => {
            const cred = try parseCredential(dec);
            const pool_bytes = try dec.decodeBytes();
            if (pool_bytes.len != 28) return error.InvalidCbor;
            const drep = try parseDRep(dec);
            const deposit = try dec.decodeUint();
            return .{ .stake_vote_reg_delegation = .{
                .cred = cred,
                .pool = pool_bytes[0..28].*,
                .drep = drep,
                .deposit = deposit,
            } };
        },
        14 => {
            const cold = try parseCredential(dec);
            const hot = try parseCredential(dec);
            return .{ .committee_auth = .{ .cold = cold, .hot = hot } };
        },
        15 => {
            const cold = try parseCredential(dec);
            try dec.skipValue(); // anchor
            return .{ .committee_resign = .{ .cold = cold } };
        },
        16 => {
            const cred = try parseCredential(dec);
            const deposit = try dec.decodeUint();
            try dec.skipValue(); // anchor
            return .{ .drep_registration = .{ .cred = cred, .deposit = deposit } };
        },
        17 => {
            const cred = try parseCredential(dec);
            const refund = try dec.decodeUint();
            return .{ .drep_deregistration = .{ .cred = cred, .refund = refund } };
        },
        18 => {
            const cred = try parseCredential(dec);
            try dec.skipValue(); // anchor
            return .{ .drep_update = .{ .cred = cred } };
        },
        else => return error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "certificates: parse stake registration" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // (0, [0, keyhash])
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // stake registration tag
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // key hash credential
    try enc.encodeBytes(&([_]u8{0xab} ** 28));

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .stake_registration => |cred| {
            try std.testing.expectEqual(CredentialType.key_hash, cred.cred_type);
        },
        else => return error.InvalidCbor,
    }
}

test "certificates: parse stake delegation" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // (2, [0, keyhash], pool_keyhash)
    try enc.encodeArrayLen(3);
    try enc.encodeUint(2);
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0);
    try enc.encodeBytes(&([_]u8{0xcc} ** 28));
    try enc.encodeBytes(&([_]u8{0xdd} ** 28)); // pool hash

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .stake_delegation => |sd| {
            try std.testing.expectEqual(CredentialType.key_hash, sd.cred.cred_type);
            try std.testing.expectEqual(@as(u8, 0xdd), sd.pool[0]);
        },
        else => return error.InvalidCbor,
    }
}

test "certificates: parse pool registration" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    const reward = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xa4} ** 28,
        },
    };
    const reward_bytes = reward.toBytes();

    try enc.encodeArrayLen(9);
    try enc.encodeUint(3);
    try enc.encodeBytes(&([_]u8{0xa1} ** 28));
    try enc.encodeBytes(&([_]u8{0xa2} ** 32));
    try enc.encodeUint(1_000_000);
    try enc.encodeUint(500_000);
    try enc.encodeArrayLen(2); // margin
    try enc.encodeUint(1);
    try enc.encodeUint(2);
    try enc.encodeBytes(&reward_bytes);
    try enc.encodeArrayLen(0); // owners
    try enc.encodeArrayLen(0); // relays
    try enc.encodeNull(); // metadata

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .pool_registration => |pool| {
            try std.testing.expectEqual(@as(Coin, 1_000_000), pool.pledge);
            try std.testing.expectEqual(@as(Coin, 500_000), pool.cost);
            try std.testing.expectEqual(types.UnitInterval{ .numerator = 1, .denominator = 2 }, pool.margin);
            try std.testing.expectEqual(reward, pool.reward_account);
            try std.testing.expectEqual(@as(usize, 0), pool.owners.len);
        },
        else => return error.InvalidCbor,
    }
}

test "certificates: parse pool retirement" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // (4, pool_keyhash, epoch)
    try enc.encodeArrayLen(3);
    try enc.encodeUint(4);
    try enc.encodeBytes(&([_]u8{0xee} ** 28));
    try enc.encodeUint(100); // retire at epoch 100

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .pool_retirement => |pr| {
            try std.testing.expectEqual(@as(EpochNo, 100), pr.epoch);
        },
        else => return error.InvalidCbor,
    }
}

test "certificates: parse Conway DRep registration" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // (16, [0, keyhash], deposit, null_anchor)
    try enc.encodeArrayLen(4);
    try enc.encodeUint(16);
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0);
    try enc.encodeBytes(&([_]u8{0xff} ** 28));
    try enc.encodeUint(500_000_000); // deposit
    try enc.encodeNull(); // no anchor

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .drep_registration => |dr| {
            try std.testing.expectEqual(@as(Coin, 500_000_000), dr.deposit);
        },
        else => return error.InvalidCbor,
    }
}

test "certificates: parse vote delegation" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // (9, [0, keyhash], [2]) — delegate to always_abstain
    try enc.encodeArrayLen(3);
    try enc.encodeUint(9);
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0);
    try enc.encodeBytes(&([_]u8{0xaa} ** 28));
    try enc.encodeArrayLen(1);
    try enc.encodeUint(2); // always_abstain

    var dec = Decoder.init(enc.getWritten());
    var cert = try parseCertificate(allocator, &dec);
    defer freeCertificate(allocator, &cert);

    switch (cert) {
        .vote_delegation => |vd| {
            try std.testing.expect(vd.drep == .always_abstain);
        },
        else => return error.InvalidCbor,
    }
}
