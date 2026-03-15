# Spec 02: Core Cardano Types

## Overview

These are the fundamental data types shared across all eras and subsystems. Every type includes its exact CBOR encoding and Zig representation.

---

## 1. Slot, Epoch, Block Numbers

```zig
pub const SlotNo = u64;       // 0-indexed absolute slot number
pub const EpochNo = u64;      // 0-indexed epoch number
pub const BlockNo = u64;      // 0-indexed block number
pub const EpochSize = u64;    // slots per epoch
pub const EpochInterval = u32; // relative epoch count

// CBOR: all encoded as uint
```

### Constants (Mainnet)
```
slots_per_epoch = 432_000         // 5 days at 1 slot/sec
security_param_k = 2160           // max rollback depth
active_slot_coeff_f = 1/20        // ~5% of slots produce blocks
slots_per_kes_period = 129_600    // 36 hours
max_kes_evolutions = 62           // ~93 days
```

### Time Conversion
```zig
pub const SystemStart = i64; // Unix timestamp (seconds) of slot 0

pub fn slotToTime(system_start: SystemStart, slot: SlotNo) i64 {
    return system_start + @as(i64, @intCast(slot));
}

pub fn slotToEpoch(slot: SlotNo) EpochNo {
    return slot / slots_per_epoch;
}

pub fn epochFirstSlot(epoch: EpochNo) SlotNo {
    return epoch * slots_per_epoch;
}
```

---

## 2. Hash Types

```zig
/// 32-byte hash (Blake2b-256). Used for block hashes, tx hashes, script hashes.
pub const Hash32 = [32]u8;

/// 28-byte hash (Blake2b-224). Used for key hashes, credential hashes.
pub const Hash28 = [28]u8;

/// CBOR: encoded as bytes (major type 2)
/// hash32 = bytes .size 32
/// hash28 = bytes .size 28
```

### Type Aliases for Clarity
```zig
pub const HeaderHash = Hash32;
pub const TxHash = Hash32;       // = TxId
pub const ScriptHash = Hash28;
pub const KeyHash = Hash28;      // Credential hash (Blake2b-224 of VK)
pub const VRFKeyHash = Hash32;
pub const DataHash = Hash32;
pub const AuxiliaryDataHash = Hash32;
pub const PoolMetadataHash = Hash32;
pub const GenesisHash = Hash28;
pub const GenesisDelegateHash = Hash28;
```

---

## 3. Transaction Identifiers

```zig
pub const TxId = Hash32;    // Blake2b-256 of the CBOR-encoded transaction body
pub const TxIx = u16;       // Transaction output index (0-65535)

pub const TxIn = struct {
    tx_id: TxId,
    tx_ix: TxIx,

    // CBOR: [tx_id, tx_ix] — 2-element array
    pub fn encodeCbor(self: TxIn, enc: *Encoder) void {
        enc.encodeArrayLen(2);
        enc.encodeBytes(&self.tx_id);
        enc.encodeUint(self.tx_ix);
    }
};
```

---

## 4. Coin and Value

```zig
/// Lovelace amount. 1 ADA = 1,000,000 Lovelace.
pub const Coin = u64;
pub const DeltaCoin = i64;

/// CBOR: coin = uint (up to 2^64-1)

/// Multi-asset value (Mary+ eras)
pub const MultiAsset = std.HashMap(ScriptHash, std.HashMap([32]u8, i64));

pub const Value = union(enum) {
    coin_only: Coin,                              // Shelley/Allegra: just lovelace
    coin_and_assets: struct { coin: Coin, assets: MultiAsset },  // Mary+

    // CBOR:
    //   coin_only: uint
    //   coin_and_assets: [coin, {*policy_id => {+asset_name => quantity}}]
};

/// PolicyId = ScriptHash (28 bytes, Blake2b-224 of minting script)
pub const PolicyId = ScriptHash;

/// AssetName = bytes, max 32 bytes
pub const AssetName = struct {
    data: [32]u8,
    len: u5, // 0-32
};
```

---

## 5. Credentials and Addresses

```zig
pub const CredentialType = enum(u8) {
    key_hash = 0,
    script_hash = 1,
};

pub const Credential = struct {
    cred_type: CredentialType,
    hash: Hash28,

    // CBOR: [0, hash28] or [1, hash28]
};

pub const StakeReference = union(enum) {
    base: Credential,       // StakeRefBase
    pointer: Pointer,       // StakeRefPtr (deprecated but valid)
    null: void,             // StakeRefNull (enterprise address)
};

pub const Pointer = struct {
    slot: u32,
    tx_ix: u16,
    cert_ix: u16,
};

pub const Address = union(enum) {
    shelley: ShelleyAddress,
    bootstrap: ByronAddress,
};

pub const ShelleyAddress = struct {
    network: Network,
    payment: Credential,
    stake: StakeReference,
};

pub const Network = enum(u4) {
    testnet = 0,
    mainnet = 1,
};

pub const RewardAccount = struct {
    network: Network,
    credential: Credential,
    // CBOR: 29 bytes — 1 header byte + 28 credential hash
};
```

### Address Binary Format
```
Header byte (8 bits):
  Bits 7-4: Address type
    0000 = Base (keyhash, keyhash)
    0001 = Base (scripthash, keyhash)
    0010 = Base (keyhash, scripthash)
    0011 = Base (scripthash, scripthash)
    0100 = Pointer (keyhash, pointer)
    0101 = Pointer (scripthash, pointer)
    0110 = Enterprise (keyhash, no stake)
    0111 = Enterprise (scripthash, no stake)
    1000 = Byron bootstrap
    1110 = Reward (keyhash)
    1111 = Reward (scripthash)
  Bits 3-0: Network ID

Base address: [header | payment_hash(28) | stake_hash(28)] = 57 bytes
Enterprise:   [header | payment_hash(28)] = 29 bytes
Reward:       [header | stake_hash(28)] = 29 bytes
Byron:        [header | CBOR-encoded bootstrap data]
```

---

## 6. Certificates (Shelley)

```zig
pub const Certificate = union(enum) {
    stake_registration: Credential,                      // tag 0
    stake_deregistration: Credential,                    // tag 1
    stake_delegation: struct { cred: Credential, pool: KeyHash },  // tag 2
    pool_registration: PoolParams,                       // tag 3
    pool_retirement: struct { pool: KeyHash, epoch: EpochNo },     // tag 4
    genesis_delegation: struct { genesis: Hash28, delegate: Hash28, vrf: Hash32 }, // tag 5
    mir: MoveInstantaneousReward,                        // tag 6

    // Conway additions (tags 7-18)
    reg_deposit: struct { cred: Credential, deposit: Coin },       // tag 7
    unreg_deposit: struct { cred: Credential, refund: Coin },      // tag 8
    vote_delegation: struct { cred: Credential, drep: DRep },      // tag 9
    stake_vote_delegation: struct { cred: Credential, pool: KeyHash, drep: DRep }, // tag 10
    stake_reg_delegation: struct { cred: Credential, pool: KeyHash, deposit: Coin }, // tag 11
    vote_reg_delegation: struct { cred: Credential, drep: DRep, deposit: Coin }, // tag 12
    stake_vote_reg_delegation: struct { cred: Credential, pool: KeyHash, drep: DRep, deposit: Coin }, // tag 13
    committee_auth: struct { cold: Credential, hot: Credential },  // tag 14
    committee_resign: struct { cold: Credential, anchor: ?Anchor }, // tag 15
    drep_reg: struct { cred: Credential, deposit: Coin, anchor: ?Anchor }, // tag 16
    drep_unreg: struct { cred: Credential, refund: Coin },         // tag 17
    drep_update: struct { cred: Credential, anchor: ?Anchor },     // tag 18
};
```

---

## 7. Pool Parameters

```zig
pub const PoolParams = struct {
    operator: KeyHash,         // pool operator key hash
    vrf_keyhash: Hash32,       // VRF verification key hash
    pledge: Coin,              // pool pledge amount
    cost: Coin,                // fixed pool operating cost
    margin: UnitInterval,      // variable fee fraction
    reward_account: RewardAccount,
    owners: []const KeyHash,   // pool owner key hashes
    relays: []const Relay,
    metadata: ?PoolMetadata,

    // CBOR: (operator, vrf_keyhash, pledge, cost, margin, reward_account, [owners], [relays], metadata/nil)
};

pub const Relay = union(enum) {
    single_host_addr: struct { port: ?u16, ipv4: ?[4]u8, ipv6: ?[16]u8 },
    single_host_name: struct { port: ?u16, hostname: []const u8 },
    multi_host_name: struct { hostname: []const u8 },
};

pub const PoolMetadata = struct {
    url: []const u8,       // max 64 bytes
    hash: Hash32,
};
```

---

## 8. Protocol Version and Nonce

```zig
pub const ProtVer = struct {
    major: u64,
    minor: u64,
    // CBOR: [major, minor]
};

pub const Nonce = union(enum) {
    neutral: void,             // "NeutralNonce" — identity element
    hash: Hash32,              // "Nonce" — 32-byte hash value

    // XOR operation for nonce evolution
    pub fn xor(a: Nonce, b: Nonce) Nonce {
        switch (a) {
            .neutral => return b,
            .hash => |ha| switch (b) {
                .neutral => return a,
                .hash => |hb| {
                    var result: Hash32 = undefined;
                    for (0..32) |i| result[i] = ha[i] ^ hb[i];
                    return .{ .hash = result };
                },
            },
        }
    }

    // CBOR: [0] for neutral, [1, hash32] for hash
};
```

---

## 9. Rational Number Types

```zig
pub const UnitInterval = struct {
    numerator: u64,
    denominator: u64,
    // Invariant: numerator <= denominator, denominator > 0
    // CBOR: #6.30([numerator, denominator])

    pub fn toFloat(self: UnitInterval) f64 {
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
};

pub const NonNegativeInterval = struct {
    numerator: u64,
    denominator: u64,
    // Invariant: denominator > 0 (numerator can exceed denominator)
    // CBOR: #6.30([numerator, denominator])
};

pub const PositiveInterval = struct {
    numerator: u64,
    denominator: u64,
    // Invariant: numerator > 0, denominator > 0
    // CBOR: #6.30([numerator, denominator])
};
```

---

## 10. ChainHash and Point

```zig
/// Reference to a point on the chain (for chain-sync, block-fetch)
pub const Point = struct {
    slot: SlotNo,
    hash: HeaderHash,
    // CBOR: [slot, hash]
};

/// Either genesis (origin) or a specific block hash
pub const ChainHash = union(enum) {
    genesis: void,
    block: HeaderHash,
    // CBOR: genesis encoded differently per context
};

/// Tip information (current chain tip)
pub const Tip = struct {
    point: Point,
    block_no: BlockNo,
    // CBOR: [point, block_no] = [[slot, hash], block_no]
};
```

---

## 11. Governance Types (Conway)

```zig
pub const DRep = union(enum) {
    key_hash: KeyHash,      // [0, hash28]
    script_hash: Hash28,    // [1, hash28]
    always_abstain: void,   // [2]
    always_no_confidence: void, // [3]
};

pub const Anchor = struct {
    url: []const u8,
    data_hash: Hash32,
    // CBOR: [url, hash32]
};

pub const GovActionId = struct {
    tx_id: TxId,
    gov_action_index: u16,
    // CBOR: [tx_id, uint]
};

pub const Vote = enum(u8) {
    no = 0,
    yes = 1,
    abstain = 2,
};

pub const VotingProcedure = struct {
    vote: Vote,
    anchor: ?Anchor,
    // CBOR: [vote, anchor/nil]
};
```

---

## Test Requirements

1. Every type: CBOR encode → decode round-trip
2. Address: decode 10 real mainnet addresses (base, enterprise, reward, Byron)
3. Value: multi-asset with 5+ policies, encode/decode
4. Credential: both KeyHash and ScriptHash variants
5. Certificate: at least one of each Shelley type from real chain data
6. Nonce: XOR identity and commutativity properties
7. UnitInterval: boundary values (0/1, 1/1, 1/20)
8. Point/Tip: decode from real chain-sync messages
