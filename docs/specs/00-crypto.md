# Spec 00: Cryptographic Primitives

## Overview

All cryptographic operations in Cardano are performed via libsodium (Ed25519, VRF, Blake2b) and a custom KES scheme built on top of Ed25519. This spec defines the exact algorithms, key sizes, and APIs required.

## Dependencies

- libsodium (system library, linked via Zig's C interop)
- No other external crypto dependencies

---

## 1. Ed25519 Digital Signatures

**Algorithm:** Ed25519 (RFC 8032)
**Library:** libsodium `crypto_sign_ed25519_*`

### Key Sizes
| Component | Size (bytes) |
|-----------|-------------|
| Seed | 32 |
| Signing key (internal) | 64 (seed + public key packed) |
| Signing key (serialized) | 32 (seed only) |
| Verification key | 32 |
| Signature | 64 |

### FFI Functions
```
crypto_sign_ed25519_seed_keypair(pk: *[32]u8, sk: *[64]u8, seed: *[32]u8) -> c_int
crypto_sign_ed25519_detached(sig: *[64]u8, sig_len: *c_ulonglong, msg: [*]u8, msg_len: c_ulonglong, sk: *[64]u8) -> c_int
crypto_sign_ed25519_verify_detached(sig: *[64]u8, msg: [*]u8, msg_len: c_ulonglong, pk: *[32]u8) -> c_int
crypto_sign_ed25519_sk_to_pk(pk: *[32]u8, sk: *[64]u8) -> c_int
crypto_sign_ed25519_sk_to_seed(seed: *[32]u8, sk: *[64]u8) -> c_int
```

### Zig Interface
```zig
pub const Ed25519 = struct {
    pub const seed_len = 32;
    pub const vk_len = 32;
    pub const sk_len = 64;
    pub const sig_len = 64;

    pub const VerKey = [vk_len]u8;
    pub const SignKey = [sk_len]u8;
    pub const Signature = [sig_len]u8;
    pub const Seed = [seed_len]u8;

    pub fn keyFromSeed(seed: Seed) -> struct { sk: SignKey, vk: VerKey };
    pub fn sign(msg: []const u8, sk: SignKey) -> Signature;
    pub fn verify(msg: []const u8, sig: Signature, vk: VerKey) -> bool;
    pub fn vkFromSk(sk: SignKey) -> VerKey;
};
```

### Usage in Cardano
- Payment key signing (transaction witnesses)
- Stake key signing (delegation certificates)
- Cold key signing (operational certificates)
- Genesis key signing

---

## 2. VRF (Verifiable Random Function)

**Algorithm:** ECVRF-ED25519-SHA512-Elligator2 (IETF draft-irtf-cfrg-vrf-03)
**Library:** libsodium `crypto_vrf_ietfdraft03_*`

### Key Sizes
| Component | Size (bytes) |
|-----------|-------------|
| Seed | 32 |
| Signing key | 64 |
| Verification key | 32 |
| Proof (certificate) | 80 |
| Output (hash) | 64 |

### FFI Functions
```
crypto_vrf_ietfdraft03_keypair_from_seed(pk: *[32]u8, sk: *[64]u8, seed: *[32]u8) -> c_int
crypto_vrf_ietfdraft03_prove(proof: *[80]u8, sk: *[64]u8, msg: [*]u8, msg_len: c_ulonglong) -> c_int
crypto_vrf_ietfdraft03_verify(output: *[64]u8, pk: *[32]u8, proof: *[80]u8, msg: [*]u8, msg_len: c_ulonglong) -> c_int
crypto_vrf_ietfdraft03_proof_to_hash(output: *[64]u8, proof: *[80]u8) -> c_int
crypto_vrf_ietfdraft03_sk_to_pk(pk: *[32]u8, sk: *[64]u8) -> c_int
crypto_vrf_ietfdraft03_sk_to_seed(seed: *[32]u8, sk: *[64]u8) -> c_int
```

### Zig Interface
```zig
pub const VRF = struct {
    pub const seed_len = 32;
    pub const vk_len = 32;
    pub const sk_len = 64;
    pub const proof_len = 80;
    pub const output_len = 64;

    pub const VerKey = [vk_len]u8;
    pub const SignKey = [sk_len]u8;
    pub const Proof = [proof_len]u8;
    pub const Output = [output_len]u8;

    pub fn keyFromSeed(seed: [seed_len]u8) -> struct { sk: SignKey, vk: VerKey };
    pub fn prove(msg: []const u8, sk: SignKey) -> struct { proof: Proof, output: Output };
    pub fn verify(msg: []const u8, vk: VerKey, proof: Proof) -> ?Output;
    pub fn proofToHash(proof: Proof) -> Output;
};
```

### Usage in Cardano
Two VRF evaluations per slot:
1. **Leader VRF:** Input = `epochNonce ++ slotNumber`. Output compared to stake threshold for leader election.
2. **Nonce VRF:** Input = `epochNonce ++ slotNumber`. Output XOR'd into evolving epoch nonce.

The certified natural (leader value) is derived by interpreting the first 8 bytes of the VRF output as a big-endian u64, then comparing: `leaderValue / 2^512 ≤ 1 - (1-f)^σ`.

---

## 3. KES (Key Evolving Signature)

**Algorithm:** CompactSumKES (binary tree of Ed25519, depth 6)
**No external library** — implemented using Ed25519 primitives.

### Structure

KES is a tree-based forward-secure signature scheme. At depth d, it supports 2^d time periods. Cardano mainnet uses depth 6 = 64 periods.

```
CompactSumKES = recursive binary tree:
  Level 0: CompactSingleKES (1 period, wraps Ed25519)
  Level n: CompactSumKES (2^n periods, two Level-(n-1) subtrees)
```

### CompactSingleKES (Base Case)
```
VerKey = Ed25519.VerKey (32 bytes)
SignKey = Ed25519.SignKey (64 bytes, but stored as 32-byte seed)
Signature = Ed25519.Signature ++ Ed25519.VerKey (64 + 32 = 96 bytes)
```

### CompactSumKES (Recursive Case)
```
VerKey = Blake2b-256(vk_left ++ vk_right) (32 bytes — compact!)
SignKey = (sk_current, seed_other, vk_current, vk_other)
Signature = (inner_sig, vk_other)
```

### Key Sizes at Depth 6
| Component | Size (bytes) |
|-----------|-------------|
| Verification key | 32 (single hash) |
| Signing key | 32 (seed) + 32 (seed) + 32 (vk) + 32 (vk) × depth = varies |
| Signature | (64 + 32) × (depth + 1) + 32 × depth |

### Period Management
- **Total periods:** 64 (2^6)
- **Period duration on mainnet:** 129,600 slots = 36 hours
- **Total KES lifetime:** 64 × 36 hours ≈ 96 days
- **Key evolution:** At period boundary, advance to next period. Old signing material is erased (forward security).

### Algorithm: Sign at Period t
```
fn signKES(depth, period, msg, sk) -> Signature:
    if depth == 0:
        sig = Ed25519.sign(msg, sk.ed_sk)
        return (sig, sk.ed_vk)

    half = 2^(depth-1)
    if period < half:
        inner_sig = signKES(depth-1, period, msg, sk.left)
        return (inner_sig, sk.vk_right)
    else:
        inner_sig = signKES(depth-1, period - half, msg, sk.right)
        return (inner_sig, sk.vk_left)
```

### Algorithm: Verify at Period t
```
fn verifyKES(depth, vk, period, msg, sig) -> bool:
    if depth == 0:
        (ed_sig, ed_vk) = sig
        if Blake2b256(ed_vk) != vk: return false
        return Ed25519.verify(msg, ed_sig, ed_vk)

    (inner_sig, vk_other) = sig
    half = 2^(depth-1)
    if period < half:
        expected_vk = Blake2b256(inner_vk ++ vk_other)
        // inner_vk extracted from inner_sig recursively
    else:
        expected_vk = Blake2b256(vk_other ++ inner_vk)

    if expected_vk != vk: return false
    return verifyKES(depth-1, inner_vk, period mod half, msg, inner_sig)
```

### Algorithm: Evolve Key to Next Period
```
fn updateKES(depth, sk, period) -> ?SignKey:
    if depth == 0:
        return null  // Single-period key cannot evolve

    half = 2^(depth-1)
    if period + 1 < half:
        new_left = updateKES(depth-1, sk.left, period)
        return (new_left, sk.seed_right, sk.vk_left, sk.vk_right)
    elif period + 1 == half:
        // Crossing to right subtree — generate right key from seed
        new_right = genKeyKES(depth-1, sk.seed_right)
        return (new_right, zeroed_seed, sk.vk_left, sk.vk_right)
    else:
        new_right = updateKES(depth-1, sk.right, period - half)
        return (sk.left_zeroed, sk.seed_zeroed, sk.vk_left, sk.vk_right)
```

### Zig Interface
```zig
pub const KES = struct {
    pub const depth = 6;
    pub const total_periods = 64; // 2^6

    pub const VerKey = [32]u8;
    pub const SignKey = struct { /* recursive, depth-dependent */ };
    pub const Signature = struct { /* recursive, depth-dependent */ };

    pub fn generate(seed: [32]u8) -> struct { sk: SignKey, vk: VerKey };
    pub fn sign(period: u32, msg: []const u8, sk: SignKey) -> ?Signature;
    pub fn verify(vk: VerKey, period: u32, msg: []const u8, sig: Signature) -> bool;
    pub fn evolve(sk: *SignKey, period: u32) -> bool; // returns false if at max period
    pub fn currentPeriod(sk: SignKey) -> u32;
};
```

---

## 4. Operational Certificates

An operational certificate binds a pool's cold key to a KES hot key.

### Structure
```
operational_cert = [
    hot_vkey: KES.VerKey (32 bytes),
    sequence_number: u64,
    kes_period: u32,          // Starting KES period for this cert
    cold_key_signature: Ed25519.Signature (64 bytes)
]
```

### Validation Rules
1. `cold_key_signature` must be a valid Ed25519 signature by the pool's cold key over `(hot_vkey ++ sequence_number ++ kes_period)`
2. `sequence_number` must be strictly greater than the last seen sequence number for this pool
3. Current KES period must be in range `[kes_period, kes_period + maxKESEvolutions)`

### CBOR Encoding
```
[vkey_bytes, uint, uint, signature_bytes]
4-element CBOR array
```

---

## 5. Hash Functions

### Blake2b-256
- **Output:** 32 bytes
- **Usage:** Block hashes, transaction hashes, script hashes, VRF output hashing
- **FFI:** `crypto_generichash_blake2b(out, 32, in, in_len, NULL, 0)`
- **Incremental:** `crypto_generichash_blake2b_init/update/final`

### Blake2b-224
- **Output:** 28 bytes
- **Usage:** Verification key hashes (credentials), address hashes
- **FFI:** `crypto_generichash_blake2b(out, 28, in, in_len, NULL, 0)`

### Zig Interface
```zig
pub const Blake2b256 = struct {
    pub const digest_len = 32;
    pub const Digest = [digest_len]u8;

    pub fn hash(data: []const u8) -> Digest;

    // Incremental
    pub const State = struct { /* libsodium state */ };
    pub fn init() -> State;
    pub fn update(state: *State, data: []const u8) -> void;
    pub fn final(state: *State) -> Digest;
};

pub const Blake2b224 = struct {
    pub const digest_len = 28;
    pub const Digest = [digest_len]u8;
    pub fn hash(data: []const u8) -> Digest;
};
```

---

## 6. Bech32 Encoding

Cardano uses Bech32 (BIP-173) for human-readable key/address encoding.

### Key Prefixes
| Type | Prefix |
|------|--------|
| Payment verification key | `addr_vk` |
| Payment signing key | `addr_sk` |
| Stake verification key | `stake_vk` |
| Stake signing key | `stake_sk` |
| VRF verification key | `vrf_vk` |
| VRF signing key | `vrf_sk` |
| KES verification key | `kes_vk` |
| KES signing key | `kes_sk` |
| Pool ID | `pool` |

### Implementation
Pure Zig implementation (no external dependency):
- `encode(hrp: []const u8, data: []const u8) -> []u8`
- `decode(bech32: []const u8) -> struct { hrp: []u8, data: []u8 }`

---

## Test Requirements

### Test Vectors (from cardano-base test suite)
1. Ed25519 sign/verify with 10 known message/key/signature triples
2. VRF prove/verify with 5 known inputs producing expected outputs
3. KES sign/verify/evolve through all 64 periods, verifying at each
4. KES forward security: signature at period N cannot verify at period N+1 with evolved key
5. Blake2b-256 and Blake2b-224 against known input/output pairs
6. Operational certificate: parse and validate a real mainnet OCert
7. Bech32 round-trip for all key types
