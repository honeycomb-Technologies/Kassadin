const std = @import("std");
const Blake2b256 = @import("crypto/hash.zig").Blake2b256;
const Blake2b224 = @import("crypto/hash.zig").Blake2b224;

// ── 1. Numeric Types ──

pub const SlotNo = u64;
pub const EpochNo = u64;
pub const BlockNo = u64;
pub const EpochSize = u64;
pub const EpochInterval = u32;

// ── 2. Hash Types ──

pub const Hash32 = [32]u8;
pub const Hash28 = [28]u8;

pub const HeaderHash = Hash32;
pub const TxHash = Hash32;
pub const ScriptHash = Hash28;
pub const KeyHash = Hash28;
pub const VRFKeyHash = Hash32;
pub const DataHash = Hash32;
pub const AuxiliaryDataHash = Hash32;
pub const PoolMetadataHash = Hash32;
pub const GenesisHash = Hash28;
pub const GenesisDelegateHash = Hash28;

/// Compute a key hash (Blake2b-224) from a verification key.
pub fn hashKey(vk: []const u8) KeyHash {
    return Blake2b224.hash(vk);
}

/// Compute a 32-byte hash (Blake2b-256).
pub fn hashBlake2b256(data: []const u8) Hash32 {
    return Blake2b256.hash(data);
}

// ── 3. Transaction Identifiers ──

pub const TxId = Hash32;
pub const TxIx = u16;

pub const TxIn = struct {
    tx_id: TxId,
    tx_ix: TxIx,

    pub fn eql(a: TxIn, b: TxIn) bool {
        return std.mem.eql(u8, &a.tx_id, &b.tx_id) and a.tx_ix == b.tx_ix;
    }

    pub fn lessThan(_: void, a: TxIn, b: TxIn) bool {
        const cmp = std.mem.order(u8, &a.tx_id, &b.tx_id);
        if (cmp == .lt) return true;
        if (cmp == .gt) return false;
        return a.tx_ix < b.tx_ix;
    }
};

// ── 4. Coin and Value ──

pub const Coin = u64;
pub const DeltaCoin = i64;

pub const PolicyId = ScriptHash;

pub const AssetName = struct {
    data: [32]u8 = [_]u8{0} ** 32,
    len: u6 = 0,

    pub fn fromSlice(s: []const u8) !AssetName {
        if (s.len > 32) return error.AssetNameTooLong;
        var an = AssetName{};
        @memcpy(an.data[0..s.len], s);
        an.len = @intCast(s.len);
        return an;
    }

    pub fn toSlice(self: *const AssetName) []const u8 {
        return self.data[0..self.len];
    }
};

/// Simplified Value for Phase 0. Full MultiAsset support comes in Phase 3.
pub const Value = union(enum) {
    coin_only: Coin,
    coin_and_assets: struct {
        coin: Coin,
        assets_raw: []const u8, // raw CBOR of multi-asset map (byte-preserving)
    },

    pub fn getCoin(self: Value) Coin {
        return switch (self) {
            .coin_only => |c| c,
            .coin_and_assets => |v| v.coin,
        };
    }
};

// ── 5. Credentials and Addresses ──

pub const CredentialType = enum(u1) {
    key_hash = 0,
    script_hash = 1,
};

pub const Credential = struct {
    cred_type: CredentialType,
    hash: Hash28,

    pub fn eql(a: Credential, b: Credential) bool {
        return a.cred_type == b.cred_type and std.mem.eql(u8, &a.hash, &b.hash);
    }
};

pub const Network = enum(u4) {
    testnet = 0,
    mainnet = 1,
    _,
};

pub const StakeReference = union(enum) {
    base: Credential,
    pointer: Pointer,
    null: void,
};

pub const Pointer = struct {
    slot: u64,
    tx_ix: u64,
    cert_ix: u64,
};

pub const AddressType = enum(u4) {
    base_key_key = 0,
    base_script_key = 1,
    base_key_script = 2,
    base_script_script = 3,
    pointer_key = 4,
    pointer_script = 5,
    enterprise_key = 6,
    enterprise_script = 7,
    bootstrap = 8,
    reward_key = 14,
    reward_script = 15,
    _,
};

pub const Address = union(enum) {
    shelley: ShelleyAddress,
    bootstrap: BootstrapAddress,

    /// Decode an address from raw bytes.
    pub fn fromBytes(bytes: []const u8) !Address {
        if (bytes.len == 0) return error.InvalidAddress;
        const header = bytes[0];
        const addr_type: AddressType = @enumFromInt(header >> 4);
        const network: Network = @enumFromInt(header & 0x0f);

        switch (addr_type) {
            .base_key_key, .base_script_key, .base_key_script, .base_script_script => {
                if (bytes.len != 57) return error.InvalidAddress;
                const payment_type: CredentialType = if (@intFromEnum(addr_type) & 1 == 0) .key_hash else .script_hash;
                const stake_type: CredentialType = if (@intFromEnum(addr_type) & 2 == 0) .key_hash else .script_hash;
                return .{ .shelley = .{
                    .network = network,
                    .payment = .{ .cred_type = payment_type, .hash = bytes[1..29].* },
                    .stake = .{ .base = .{ .cred_type = stake_type, .hash = bytes[29..57].* } },
                    .addr_type = addr_type,
                } };
            },
            .enterprise_key, .enterprise_script => {
                if (bytes.len != 29) return error.InvalidAddress;
                const payment_type: CredentialType = if (addr_type == .enterprise_key) .key_hash else .script_hash;
                return .{ .shelley = .{
                    .network = network,
                    .payment = .{ .cred_type = payment_type, .hash = bytes[1..29].* },
                    .stake = .null,
                    .addr_type = addr_type,
                } };
            },
            .reward_key, .reward_script => {
                if (bytes.len != 29) return error.InvalidAddress;
                const cred_type: CredentialType = if (addr_type == .reward_key) .key_hash else .script_hash;
                return .{ .shelley = .{
                    .network = network,
                    .payment = .{ .cred_type = cred_type, .hash = bytes[1..29].* },
                    .stake = .null,
                    .addr_type = addr_type,
                } };
            },
            .bootstrap => {
                return .{ .bootstrap = .{ .raw = bytes } };
            },
            else => return error.InvalidAddress,
        }
    }
};

pub fn stakeCredentialFromAddressBytes(bytes: []const u8) !?Credential {
    const address = try Address.fromBytes(bytes);
    return switch (address) {
        .bootstrap => null,
        .shelley => |shelley| switch (shelley.stake) {
            .base => |credential| credential,
            .pointer => null,
            .null => null,
        },
    };
}

pub const ShelleyAddress = struct {
    network: Network,
    payment: Credential,
    stake: StakeReference,
    addr_type: AddressType,
};

pub const BootstrapAddress = struct {
    raw: []const u8,
};

pub const RewardAccount = struct {
    network: Network,
    credential: Credential,

    pub fn fromBytes(bytes: [29]u8) !RewardAccount {
        const header = bytes[0];
        const addr_type: AddressType = @enumFromInt(header >> 4);
        if (addr_type != .reward_key and addr_type != .reward_script) return error.NotRewardAddress;
        const cred_type: CredentialType = if (addr_type == .reward_key) .key_hash else .script_hash;
        return .{
            .network = @enumFromInt(header & 0x0f),
            .credential = .{ .cred_type = cred_type, .hash = bytes[1..29].* },
        };
    }

    pub fn toBytes(self: RewardAccount) [29]u8 {
        var buf: [29]u8 = undefined;
        const type_nibble: u8 = if (self.credential.cred_type == .key_hash) 0xe0 else 0xf0;
        buf[0] = type_nibble | @intFromEnum(self.network);
        @memcpy(buf[1..29], &self.credential.hash);
        return buf;
    }
};

pub const PoolOwnerMembership = struct {
    pool: KeyHash,
    owner: KeyHash,
};

// ── 6. Protocol Version and Nonce ──

pub const ProtVer = struct {
    major: u64,
    minor: u64,
};

pub const Nonce = union(enum) {
    neutral: void,
    hash: Hash32,

    /// XOR two nonces. Neutral is the identity element.
    pub fn xorOp(a: Nonce, b: Nonce) Nonce {
        switch (a) {
            .neutral => return b,
            .hash => |ha| switch (b) {
                .neutral => return a,
                .hash => |hb| {
                    var result: Hash32 = undefined;
                    for (&result, ha, hb) |*r, x, y| {
                        r.* = x ^ y;
                    }
                    return .{ .hash = result };
                },
            },
        }
    }

    pub fn eql(a: Nonce, b: Nonce) bool {
        switch (a) {
            .neutral => return b == .neutral,
            .hash => |ha| switch (b) {
                .neutral => return false,
                .hash => |hb| return std.mem.eql(u8, &ha, &hb),
            },
        }
    }
};

// ── 7. Rational Types ──

pub const UnitInterval = struct {
    numerator: u64,
    denominator: u64,

    pub fn toFloat(self: UnitInterval) f64 {
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }

    pub fn isValid(self: UnitInterval) bool {
        return self.denominator > 0 and self.numerator <= self.denominator;
    }
};

pub const NonNegativeInterval = struct {
    numerator: u64,
    denominator: u64,

    pub fn isValid(self: NonNegativeInterval) bool {
        return self.denominator > 0;
    }
};

// ── 8. Chain Point and Tip ──

pub const Point = struct {
    slot: SlotNo,
    hash: HeaderHash,

    pub fn eql(a: Point, b: Point) bool {
        return a.slot == b.slot and std.mem.eql(u8, &a.hash, &b.hash);
    }
};

pub const ChainHash = union(enum) {
    genesis: void,
    block_hash: HeaderHash,
};

pub const Tip = struct {
    point: Point,
    block_no: BlockNo,
};

// ── 9. Mainnet Constants ──

pub const mainnet = struct {
    pub const slots_per_epoch: u64 = 432_000;
    pub const security_param_k: u64 = 2160;
    pub const active_slot_coeff_numerator: u64 = 1;
    pub const active_slot_coeff_denominator: u64 = 20;
    pub const slots_per_kes_period: u64 = 129_600;
    pub const max_kes_evolutions: u32 = 62;
    pub const network_magic: u32 = 764824073;
};

pub fn slotToEpoch(slot: SlotNo, slots_per_epoch: u64) EpochNo {
    return slot / slots_per_epoch;
}

pub fn epochFirstSlot(epoch: EpochNo, slots_per_epoch: u64) SlotNo {
    return epoch * slots_per_epoch;
}

// ── 10. Governance Types (Conway, minimal stubs) ──

pub const DRep = union(enum) {
    key_hash: KeyHash,
    script_hash: Hash28,
    always_abstain: void,
    always_no_confidence: void,
};

pub const Anchor = struct {
    url: []const u8,
    data_hash: Hash32,
};

pub const Vote = enum(u2) {
    no = 0,
    yes = 1,
    abstain = 2,
};

pub const GovActionId = struct {
    tx_id: TxId,
    gov_action_index: u16,
};

pub const VotingProcedure = struct {
    vote: Vote,
    anchor: ?Anchor,
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "nonce: xor identity" {
    const neutral = Nonce{ .neutral = {} };
    const h = Nonce{ .hash = [_]u8{0xab} ** 32 };
    try std.testing.expect(Nonce.eql(Nonce.xorOp(neutral, h), h));
    try std.testing.expect(Nonce.eql(Nonce.xorOp(h, neutral), h));
    try std.testing.expect(Nonce.eql(Nonce.xorOp(neutral, neutral), neutral));
}

test "nonce: xor commutativity" {
    const a = Nonce{ .hash = [_]u8{0x11} ** 32 };
    const b = Nonce{ .hash = [_]u8{0x22} ** 32 };
    try std.testing.expect(Nonce.eql(Nonce.xorOp(a, b), Nonce.xorOp(b, a)));
}

test "nonce: xor self is zero" {
    const a = Nonce{ .hash = [_]u8{0xff} ** 32 };
    const result = Nonce.xorOp(a, a);
    try std.testing.expect(Nonce.eql(result, Nonce{ .hash = [_]u8{0x00} ** 32 }));
}

test "unit interval: valid and invalid" {
    const valid = UnitInterval{ .numerator = 1, .denominator = 20 };
    try std.testing.expect(valid.isValid());
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), valid.toFloat(), 1e-10);

    const zero = UnitInterval{ .numerator = 0, .denominator = 1 };
    try std.testing.expect(zero.isValid());

    const one = UnitInterval{ .numerator = 1, .denominator = 1 };
    try std.testing.expect(one.isValid());

    const invalid = UnitInterval{ .numerator = 2, .denominator = 1 };
    try std.testing.expect(!invalid.isValid());

    const zero_denom = UnitInterval{ .numerator = 0, .denominator = 0 };
    try std.testing.expect(!zero_denom.isValid());
}

test "slot/epoch conversion" {
    try std.testing.expectEqual(@as(u64, 0), slotToEpoch(0, mainnet.slots_per_epoch));
    try std.testing.expectEqual(@as(u64, 0), slotToEpoch(431_999, mainnet.slots_per_epoch));
    try std.testing.expectEqual(@as(u64, 1), slotToEpoch(432_000, mainnet.slots_per_epoch));
    try std.testing.expectEqual(@as(u64, 10), slotToEpoch(4_320_000, mainnet.slots_per_epoch));

    try std.testing.expectEqual(@as(u64, 0), epochFirstSlot(0, mainnet.slots_per_epoch));
    try std.testing.expectEqual(@as(u64, 432_000), epochFirstSlot(1, mainnet.slots_per_epoch));
}

test "txin: equality and ordering" {
    const a = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const b = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 1 };
    const c = TxIn{ .tx_id = [_]u8{0x02} ** 32, .tx_ix = 0 };

    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(TxIn.lessThan({}, a, b));
    try std.testing.expect(TxIn.lessThan({}, a, c));
    try std.testing.expect(TxIn.lessThan({}, b, c));
}

test "address: enterprise address decode" {
    // Enterprise key address on mainnet: header=0x61 (type 6, network 1)
    var addr_bytes: [29]u8 = undefined;
    addr_bytes[0] = 0x61; // enterprise key, mainnet
    @memset(addr_bytes[1..29], 0xab);

    const addr = try Address.fromBytes(&addr_bytes);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.enterprise_key, sa.addr_type);
            try std.testing.expectEqual(CredentialType.key_hash, sa.payment.cred_type);
        },
        .bootstrap => unreachable,
    }
}

test "address: base address decode" {
    var addr_bytes: [57]u8 = undefined;
    addr_bytes[0] = 0x01; // base key/key, mainnet
    @memset(addr_bytes[1..29], 0xaa); // payment
    @memset(addr_bytes[29..57], 0xbb); // stake

    const addr = try Address.fromBytes(&addr_bytes);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.base_key_key, sa.addr_type);
        },
        .bootstrap => unreachable,
    }
}

test "reward account: round-trip" {
    const ra = RewardAccount{
        .network = .mainnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xcc} ** 28 },
    };
    const bytes = ra.toBytes();
    const decoded = try RewardAccount.fromBytes(bytes);
    try std.testing.expectEqual(ra.network, decoded.network);
    try std.testing.expect(ra.credential.eql(decoded.credential));
}

test "address: extract base stake credential" {
    var addr_bytes: [57]u8 = undefined;
    addr_bytes[0] = 0x01; // base key/key, mainnet
    @memset(addr_bytes[1..29], 0xaa); // payment
    @memset(addr_bytes[29..57], 0xbb); // stake

    const credential = (try stakeCredentialFromAddressBytes(&addr_bytes)).?;
    try std.testing.expectEqual(CredentialType.key_hash, credential.cred_type);
    try std.testing.expectEqualSlices(u8, addr_bytes[29..57], &credential.hash);
}

test "address: extract enterprise stake credential is null" {
    var addr_bytes: [29]u8 = undefined;
    addr_bytes[0] = 0x61; // enterprise key, mainnet
    @memset(addr_bytes[1..29], 0xab);

    try std.testing.expect((try stakeCredentialFromAddressBytes(&addr_bytes)) == null);
}

test "asset name: from slice round-trip" {
    const an = try AssetName.fromSlice("MyToken");
    try std.testing.expectEqualSlices(u8, "MyToken", an.toSlice());
}

test "value: get coin" {
    const v1 = Value{ .coin_only = 1_000_000 };
    try std.testing.expectEqual(@as(u64, 1_000_000), v1.getCoin());
}

test "point: equality" {
    const a = Point{ .slot = 100, .hash = [_]u8{0x01} ** 32 };
    const b = Point{ .slot = 100, .hash = [_]u8{0x01} ** 32 };
    const c = Point{ .slot = 101, .hash = [_]u8{0x01} ** 32 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "key hash: from verification key" {
    const vk = [_]u8{0x42} ** 32;
    const kh = hashKey(&vk);
    try std.testing.expectEqual(@as(usize, 28), kh.len);
}

// ── Golden address test vectors from CIP-0019 / cardano-ledger golden tests ──
// Payment key hash: 9493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e
// Stake key hash:   337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251
// Script hash:      c37b1b5dc0669f1d3c61a6fddb2e8fde96be87b881c60bce8e8d542f

fn hexDecode(comptime len: usize, hex: *const [len * 2]u8) [len]u8 {
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return result;
}

test "address golden: base key/key mainnet (CIP-19)" {
    // addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x
    const raw = hexDecode(57, "019493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
    const addr = try Address.fromBytes(&raw);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.base_key_key, sa.addr_type);
            try std.testing.expectEqual(CredentialType.key_hash, sa.payment.cred_type);
            const expected_payment = hexDecode(28, "9493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e");
            try std.testing.expectEqualSlices(u8, &expected_payment, &sa.payment.hash);
            switch (sa.stake) {
                .base => |stake_cred| {
                    const expected_stake = hexDecode(28, "337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
                    try std.testing.expectEqualSlices(u8, &expected_stake, &stake_cred.hash);
                },
                else => unreachable,
            }
        },
        .bootstrap => unreachable,
    }
}

test "address golden: enterprise key mainnet (CIP-19)" {
    // addr1vx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzers66hrl8
    const raw = hexDecode(29, "619493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e");
    const addr = try Address.fromBytes(&raw);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.enterprise_key, sa.addr_type);
            try std.testing.expectEqual(CredentialType.key_hash, sa.payment.cred_type);
            const expected_payment = hexDecode(28, "9493315cd92eb5d8c4304e67b7e16ae36d61d34502694657811a2c8e");
            try std.testing.expectEqualSlices(u8, &expected_payment, &sa.payment.hash);
        },
        .bootstrap => unreachable,
    }
}

test "address golden: reward key mainnet (CIP-19)" {
    // stake1uyehkck0lajq8gr28t9uxnuvgcqrc6070x3k9r8048z8y5gh6ffgw
    const raw = hexDecode(29, "e1337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
    const addr = try Address.fromBytes(&raw);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.reward_key, sa.addr_type);
            const expected_stake = hexDecode(28, "337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
            try std.testing.expectEqualSlices(u8, &expected_stake, &sa.payment.hash);
        },
        .bootstrap => unreachable,
    }
}

test "address golden: script enterprise mainnet (CIP-19)" {
    // addr1w8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtcyjy7wx
    const raw = hexDecode(29, "71c37b1b5dc0669f1d3c61a6fddb2e8fde96be87b881c60bce8e8d542f");
    const addr = try Address.fromBytes(&raw);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.enterprise_script, sa.addr_type);
            try std.testing.expectEqual(CredentialType.script_hash, sa.payment.cred_type);
            const expected_script = hexDecode(28, "c37b1b5dc0669f1d3c61a6fddb2e8fde96be87b881c60bce8e8d542f");
            try std.testing.expectEqualSlices(u8, &expected_script, &sa.payment.hash);
        },
        .bootstrap => unreachable,
    }
}

test "address golden: script+key base mainnet (CIP-19)" {
    // addr1z8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs9yc0hh
    const raw = hexDecode(57, "11c37b1b5dc0669f1d3c61a6fddb2e8fde96be87b881c60bce8e8d542f337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
    const addr = try Address.fromBytes(&raw);
    switch (addr) {
        .shelley => |sa| {
            try std.testing.expectEqual(Network.mainnet, sa.network);
            try std.testing.expectEqual(AddressType.base_script_key, sa.addr_type);
            try std.testing.expectEqual(CredentialType.script_hash, sa.payment.cred_type);
        },
        .bootstrap => unreachable,
    }
}

test "reward account golden: round-trip CIP-19" {
    const raw = hexDecode(29, "e1337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
    const ra = try RewardAccount.fromBytes(raw);
    try std.testing.expectEqual(Network.mainnet, ra.network);
    try std.testing.expectEqual(CredentialType.key_hash, ra.credential.cred_type);
    const expected_hash = hexDecode(28, "337b62cfff6403a06a3acbc34f8c46003c69fe79a3628cefa9c47251");
    try std.testing.expectEqualSlices(u8, &expected_hash, &ra.credential.hash);
    // Round-trip
    const encoded = ra.toBytes();
    try std.testing.expectEqualSlices(u8, &raw, &encoded);
}
