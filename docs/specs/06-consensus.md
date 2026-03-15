# Spec 06: Ouroboros Praos Consensus

## Overview

Ouroboros Praos is the proof-of-stake consensus protocol used by Cardano from the Shelley era onward. It determines which stakeholder may produce a block in each slot and how nodes select the best chain among forks.

**Primary reference:** IACR ePrint 2017/573 "Ouroboros Praos"

---

## 1. Slot Leader Election

### Parameters
```
k = 2160                      // security parameter (max rollback)
f = 1/20                      // active slot coefficient
epoch_length = 10k/f = 432,000 slots = 5 days
slot_duration = 1 second
```

### VRF Leader Check
```
For each slot s in the pool's assigned epoch:
  1. Compute input = epochNonce || slotNumberBytes(s)
     where slotNumberBytes is big-endian u64

  2. (proof, output) = VRF.prove(input, vrfSignKey)

  3. certifiedNatural = bytesToNatural(output)
     // Interpret 64-byte VRF output as big-endian unsigned integer

  4. denominator = 2^512
     // VRF output space is 64 bytes = 512 bits

  5. threshold = 1 - (1 - f)^σ
     where σ = pool_active_stake / total_active_stake
     and f = activeSlotCoeff (1/20 on mainnet)

  6. isLeader = (certifiedNatural / denominator) < threshold

  Note: To avoid floating-point, use the equivalent:
    isLeader = certifiedNatural < denominator × (1 - (1-f)^σ)
    Or better: use the natural log approximation from the Haskell implementation
```

### Zig Implementation
```zig
pub fn checkLeaderVRF(
    epoch_nonce: Nonce,
    slot: SlotNo,
    vrf_sk: VRF.SignKey,
    relative_stake: UnitInterval,  // σ
    active_slot_coeff: UnitInterval,  // f
) ?struct { proof: VRF.Proof, output: VRF.Output } {
    // Construct VRF input
    var input: [40]u8 = undefined;
    @memcpy(input[0..32], &epoch_nonce.hash);
    std.mem.writeInt(u64, input[32..40], slot, .big);

    // Evaluate VRF
    const result = VRF.prove(&input, vrf_sk);

    // Check threshold
    if (meetsThreshold(result.output, relative_stake, active_slot_coeff)) {
        return result;
    }
    return null;
}

fn meetsThreshold(
    vrf_output: VRF.Output,
    sigma: UnitInterval,
    f: UnitInterval,
) bool {
    // certNat = big-endian interpretation of vrf_output (64 bytes)
    // threshold = 1 - (1 - f)^sigma
    // check: certNat < 2^512 × threshold
    //
    // Using the Haskell approach:
    // The check is equivalent to: certNat < 2^512 × (1 - (1-f)^sigma)
    // Which avoids floating point via rational arithmetic
    // or the Taylor series approximation
    //
    // For exact match with Haskell: use the same rational computation
    // that cardano-ledger uses in Shelley.Rules.Overlay
}
```

---

## 2. Chain Selection Rule

### Basic Rule: Longest Chain Wins
```
prefer(chain_a, chain_b) =
  if blockNo(tip(chain_a)) > blockNo(tip(chain_b)) then chain_a
  elif blockNo(tip(chain_a)) < blockNo(tip(chain_b)) then chain_b
  else tiebreaker(chain_a, chain_b)
```

### Tiebreaker
For equal-length chains, use the VRF tiebreaker:
```
tiebreaker(a, b) =
  compare VRF leader value of tip(a) vs tip(b)
  smaller VRF value wins (more "random luck")
```

### Chain Diff and Switching
```zig
pub const ChainDiff = struct {
    rollback: u64,           // blocks to roll back from current tip
    suffix: []const Header,  // new blocks to apply after rollback

    pub fn preferOver(self: ChainDiff, current_tip: BlockNo) bool {
        const new_tip_block_no = current_tip - self.rollback + self.suffix.len;
        return new_tip_block_no > current_tip;
    }
};
```

### Chain Selection Algorithm
```
fn chainSelection(current: AnchoredFragment, candidates: []ChainDiff, ledger: *LedgerDB) ?ChainDiff {
    var best: ?ChainDiff = null;
    var best_block_no: BlockNo = current.tipBlockNo();

    for (candidates) |candidate| {
        const new_block_no = current.tipBlockNo() - candidate.rollback + candidate.suffix.len;
        if (new_block_no <= best_block_no) continue;

        // Validate candidate
        var test_ledger = ledger.fork();
        defer test_ledger.deinit();

        test_ledger.rollback(candidate.rollback) catch continue;

        var valid = true;
        for (candidate.suffix) |header| {
            if (test_ledger.validateHeader(header)) |_| {} else |_| {
                valid = false;
                break;
            }
        }

        if (valid) {
            best = candidate;
            best_block_no = new_block_no;
        }
    }

    return best;
}
```

---

## 3. Praos Protocol State

### State Structure
```zig
pub const PraosState = struct {
    last_slot: ?SlotNo,

    /// Operational certificate counter per pool (prevents cert replay)
    ocert_counters: HashMap(KeyHash, u64),

    /// Nonces for leader election
    evolving_nonce: Nonce,          // XOR'd with VRF outputs as blocks arrive
    candidate_nonce: Nonce,         // Snapshot of evolving_nonce at stability window
    epoch_nonce: Nonce,             // Used for VRF evaluation this epoch
    previous_epoch_nonce: Nonce,    // Previous epoch's nonce
    lab_nonce: Nonce,               // Last Applied Block's prev-hash as nonce
    last_epoch_block_nonce: Nonce,  // Nonce from the last block of previous epoch
};
```

### State Transitions

#### On New Block
```
fn updateOnBlock(state: *PraosState, header: Header, slot: SlotNo) void {
    // 1. Update last slot
    state.last_slot = slot;

    // 2. Update LAB nonce (prev hash of this block)
    state.lab_nonce = prevHashToNonce(header.prev_hash);

    // 3. Update evolving nonce with VRF output
    const eta = vrfNonceValue(header.vrf_result);
    state.evolving_nonce = state.evolving_nonce.xor(eta);

    // 4. Snapshot candidate nonce at randomness stabilization window
    //    (at slot = 3k/f from epoch start = 3 × 2160 / (1/20) = 129,600 from epoch start)
    if (isAtStabilizationWindow(slot)) {
        state.candidate_nonce = state.evolving_nonce;
    }

    // 5. Update OCert counter
    const pool_hash = blake2b224(header.issuer_vkey);
    state.ocert_counters.put(pool_hash, header.ocert.seq_number);
}
```

#### On Epoch Transition
```
fn updateOnEpochBoundary(state: *PraosState) void {
    state.previous_epoch_nonce = state.epoch_nonce;
    state.epoch_nonce = state.candidate_nonce.xor(state.last_epoch_block_nonce);
    state.evolving_nonce = .neutral;
    state.last_epoch_block_nonce = state.lab_nonce;
}
```

### Randomness Stabilization Window
```
window = 3 × k / f = 3 × 2160 / (1/20) = 3 × 2160 × 20 = 129,600 slots
// This means the candidate nonce is fixed 129,600 slots into the epoch
// (3 days out of 5-day epochs)
// After this point, no new blocks can influence the next epoch's nonce
```

---

## 4. Header Validation

### Validation Steps (in order)
```
fn validateHeader(cfg: PraosConfig, header: Header, state: Ticked(PraosState)) !void {
    const slot = header.slot;
    const pool_hash = blake2b224(header.issuer_vkey);

    // 1. Slot must be strictly increasing
    if (state.last_slot) |ls| {
        if (slot <= ls) return error.SlotNotIncreasing;
    }

    // 2. VRF key must be registered for this pool
    const expected_vrf_hash = state.ledger_view.pool_vrf_keys.get(pool_hash)
        orelse return error.VRFKeyUnknown;

    // 3. VRF key in header must match registered key
    if (blake2b256(header.vrf_vkey) != expected_vrf_hash)
        return error.VRFKeyMismatch;

    // 4. Verify VRF proof
    const vrf_input = makeVRFInput(state.epoch_nonce, slot);
    const vrf_output = VRF.verify(vrf_input, header.vrf_vkey, header.vrf_proof)
        orelse return error.VRFBadProof;

    // 5. Check VRF leader threshold
    const pool_stake = state.ledger_view.pool_distribution.get(pool_hash)
        orelse return error.PoolNotRegistered;
    if (!meetsThreshold(vrf_output, pool_stake.relative_stake, cfg.active_slot_coeff))
        return error.VRFLeaderValueTooBig;

    // 6. Validate operational certificate
    try validateOCert(cfg, header.ocert, header.issuer_vkey, state.ocert_counters, slot);

    // 7. Verify KES signature
    try validateKES(cfg, header, slot);
}
```

### Operational Certificate Validation
```
fn validateOCert(cfg: PraosConfig, ocert: OCert, issuer_vk: Ed25519.VerKey, counters: HashMap, slot: SlotNo) !void {
    const pool_hash = blake2b224(issuer_vk);
    const current_kes_period = slot / cfg.slots_per_kes_period;

    // 1. OCert starting period must not be in the future
    if (ocert.kes_period > current_kes_period)
        return error.KESBeforeStartOCert;

    // 2. Current period must be within max evolutions
    if (current_kes_period >= ocert.kes_period + cfg.max_kes_evo)
        return error.KESAfterEndOCert;

    // 3. Counter must not decrease (prevents replay)
    if (counters.get(pool_hash)) |prev_counter| {
        if (ocert.seq_number < prev_counter)
            return error.CounterTooSmall;
        if (ocert.seq_number > prev_counter + 1)
            return error.CounterOverIncremented;
    }

    // 4. Cold key signature over OCert data is valid
    const ocert_data = serialize(ocert.hot_vkey ++ ocert.seq_number ++ ocert.kes_period);
    if (!Ed25519.verify(ocert_data, ocert.cold_sig, issuer_vk))
        return error.InvalidSignatureOCert;
}
```

### KES Signature Validation
```
fn validateKES(cfg: PraosConfig, header: Header, slot: SlotNo) !void {
    const kes_period = slot / cfg.slots_per_kes_period;
    const relative_period = kes_period - header.ocert.kes_period;

    // KES verification at the relative period
    const header_body_bytes = serializeHeaderBody(header.body);
    if (!KES.verify(header.ocert.hot_vkey, relative_period, header_body_bytes, header.kes_signature))
        return error.InvalidKESSignature;
}
```

---

## 5. Ledger View for Consensus

The consensus protocol needs a "view" of the ledger state:

```zig
pub const LedgerView = struct {
    /// Pool stake distribution (used for VRF threshold check)
    pool_distribution: HashMap(KeyHash, IndividualPoolStake),

    /// Pool VRF verification key hashes
    pool_vrf_keys: HashMap(KeyHash, Hash32),

    /// Active slot coefficient
    active_slot_coeff: UnitInterval,

    /// Maximum KES evolutions
    max_kes_evo: u64,

    /// Slots per KES period
    slots_per_kes_period: u64,
};

pub const IndividualPoolStake = struct {
    relative_stake: UnitInterval,  // pool_stake / total_stake
    vrf_hash: Hash32,
};
```

### Forecast
The ledger view must be available for future slots (within the current epoch and slightly beyond). The forecast function:

```zig
pub fn forecastLedgerView(current_state: LedgerState, target_slot: SlotNo) !LedgerView {
    // Can forecast within current epoch + stability window into next epoch
    // Beyond that: return error.OutsideForecastRange
    // Within range: use the "set" snapshot for the target epoch
}
```

---

## 6. Block Body Validation

After header validation, the block body is validated:

```
1. Verify body hash: Blake2b-256(body) == header.block_body_hash
2. Verify body size: serializedSize(body) == header.block_body_size
3. For each transaction in body:
   a. Apply UTXOW rule
   b. Apply DELEGS rule
   c. Track fees, deposits
4. Verify total ExUnits within block limits (Alonzo+)
```

---

## Test Requirements

1. **VRF leader check:** Given known stake distribution and epoch nonce, verify leader election for 10,000 slots matches Haskell
2. **Chain selection:** Feed 3 competing forks of different lengths, verify correct winner
3. **Equal-length fork resolution:** Verify tiebreaker uses VRF values
4. **Epoch nonce evolution:** Track nonces through 3 epoch transitions, compare with Haskell
5. **Header validation:** Accept 1000 valid preview headers, reject crafted invalid ones
6. **OCert validation:** Reject replayed certs, out-of-period certs, bad signatures
7. **KES validation:** Verify at multiple periods, reject expired KES
8. **Full sync test:** Follow preview chain for 1 hour, tip within 2160 slots
