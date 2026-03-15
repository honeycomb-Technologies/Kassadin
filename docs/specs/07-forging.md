# Spec 07: Block Production & Mempool

## Overview

Block production involves the mempool (pending transaction pool), leader election check, block assembly, and block announcement. This spec defines the exact process.

---

## 1. Mempool

### Data Structure
```zig
pub const Mempool = struct {
    /// Validated transactions, ordered by arrival time
    txs: OrderedMap(TxId, ValidatedTx),

    /// Current mempool capacity and usage
    capacity_bytes: u32,
    current_bytes: u32,
    current_ex_units: ExUnits,

    /// Ledger state that mempool txs are validated against
    ledger_state: *LedgerState,

    /// Snapshot slot (for validity interval checks)
    snapshot_slot: SlotNo,
};

pub const ValidatedTx = struct {
    tx: Transaction,
    tx_id: TxId,
    size_bytes: u32,
    ex_units: ExUnits,
    fee: Coin,
    arrival_time: i64,
};
```

### Operations

#### Add Transaction
```
1. Validate tx against current ledger state + existing mempool txs
2. Check: mempool has capacity (bytes and ExUnits)
3. Check: tx validity interval includes current slot
4. If valid: add to mempool, update usage counters
5. If invalid: return rejection reason
```

#### Remove Transaction
```
1. When tx is included in a block: remove from mempool
2. When tx expires (validity interval passed): remove
3. When tx conflicts with a newly applied block: remove
```

#### Re-validation on Tip Change
```
On rollforward(block):
  1. Remove all txs included in the block
  2. Re-validate remaining txs against new ledger state
  3. Remove any newly-invalid txs

On rollback(point):
  1. Roll back ledger state
  2. Txs that were in rolled-back blocks may re-enter mempool
  3. Re-validate all txs against rolled-back ledger state
```

### Capacity Management
```
capacity_bytes = min(2 × maxBlockBodySize, maxMempoolCapacity)
// Default: ~2 × 90,112 = ~180,224 bytes

max_ex_units = 2 × maxBlockExUnits
// Allows 2 blocks worth of scripts in mempool
```

---

## 2. Block Forging

### Leader Check (Per Slot)
```
fn checkForLeadership(slot: SlotNo, pools: []PoolConfig, praos_state: PraosState, ledger_view: LedgerView) ?ForgeCredentials {
    for (pools) |pool| {
        if (checkLeaderVRF(praos_state.epoch_nonce, slot, pool.vrf_sk, ledger_view.getRelativeStake(pool.id), ledger_view.active_slot_coeff)) |vrf_result| {
            return ForgeCredentials{
                .pool = pool,
                .vrf_proof = vrf_result.proof,
                .vrf_output = vrf_result.output,
                .slot = slot,
            };
        }
    }
    return null;
}

pub const ForgeCredentials = struct {
    pool: PoolConfig,
    vrf_proof: VRF.Proof,
    vrf_output: VRF.Output,
    slot: SlotNo,
};

pub const PoolConfig = struct {
    id: KeyHash,
    cold_sk: Ed25519.SignKey,
    cold_vk: Ed25519.VerKey,
    kes_sk: KES.SignKey,
    kes_vk: KES.VerKey,
    vrf_sk: VRF.SignKey,
    vrf_vk: VRF.VerKey,
    ocert: OperationalCert,
};
```

### Transaction Selection
```
fn selectTransactions(mempool: *Mempool, max_body_size: u32, max_ex_units: ExUnits) []ValidatedTx {
    var selected: ArrayList(ValidatedTx) = .{};
    var total_size: u32 = 0;
    var total_ex: ExUnits = .{};

    // Greedy: take transactions in fee-density order (fee/size)
    var sorted = mempool.txsByFeeDensity();

    for (sorted) |vtx| {
        if (total_size + vtx.size_bytes > max_body_size) continue;
        if (total_ex.mem + vtx.ex_units.mem > max_ex_units.mem) continue;
        if (total_ex.cpu + vtx.ex_units.cpu > max_ex_units.cpu) continue;

        selected.append(vtx);
        total_size += vtx.size_bytes;
        total_ex = total_ex.add(vtx.ex_units);
    }

    return selected.items;
}
```

### Block Assembly
```
fn forgeBlock(
    creds: ForgeCredentials,
    txs: []ValidatedTx,
    prev_hash: HeaderHash,
    block_no: BlockNo,
    protocol_version: ProtVer,
) Block {
    // 1. Build transaction arrays
    const tx_bodies = txs.map(|vtx| vtx.tx.body);
    const tx_witnesses = txs.map(|vtx| vtx.tx.witness_set);
    const tx_auxiliary = buildAuxiliaryDataMap(txs);
    const invalid_txs = identifyPhase2Failures(txs);

    // 2. Serialize body
    const body_bytes = cborEncode([tx_bodies, tx_witnesses, tx_auxiliary, invalid_txs]);
    const body_hash = Blake2b256.hash(body_bytes);
    const body_size = body_bytes.len;

    // 3. Build header body
    const header_body = HeaderBody{
        .block_number = block_no,
        .slot = creds.slot,
        .prev_hash = prev_hash,
        .issuer_vkey = creds.pool.cold_vk,
        .vrf_vkey = creds.pool.vrf_vk,
        .vrf_result = .{
            .output = creds.vrf_output,
            .proof = creds.vrf_proof,
        },
        .block_body_size = body_size,
        .block_body_hash = body_hash,
        .operational_cert = creds.pool.ocert,
        .protocol_version = protocol_version,
    };

    // 4. Sign header body with KES
    const header_body_bytes = cborEncode(header_body);
    const kes_period = creds.slot / slots_per_kes_period;
    const relative_period = kes_period - creds.pool.ocert.kes_period;
    const kes_sig = KES.sign(relative_period, header_body_bytes, creds.pool.kes_sk);

    // 5. Combine
    return Block{
        .header = .{
            .body = header_body,
            .signature = kes_sig,
        },
        .body = body_bytes,
    };
}
```

### Block Announcement
After forging:
1. Add block to local ChainDB (triggers chain selection)
2. Chain-sync servers will pick up the new tip
3. Connected peers receive MsgRollForward with new header
4. Peers fetch full block via block-fetch

---

## 3. Key Management

### Key Files (Compatible with cardano-cli)
```
cold.skey       — Ed25519 signing key (cold, kept offline)
cold.vkey       — Ed25519 verification key
kes.skey        — KES signing key (hot, rotated every ~90 days)
kes.vkey        — KES verification key
vrf.skey        — VRF signing key
vrf.vkey        — VRF verification key
node.cert       — Operational certificate
```

### Key File Format (TextEnvelope)
```json
{
    "type": "StakePoolSigningKey_ed25519",
    "description": "Stake Pool Operator Signing Key",
    "cborHex": "5820<32-byte-seed-hex>"
}
```

### KES Key Rotation
```
Every maxKESEvolutions × slotsPerKESPeriod slots (~90 days):
  1. Generate new KES key pair
  2. Create new operational certificate (increment counter)
  3. Sign OCert with cold key
  4. Load new KES key and OCert
  5. Old KES key is securely erased
```

### KES Period Tracking
```
fn getCurrentKESPeriod(slot: SlotNo) u64 {
    return slot / slots_per_kes_period;  // 129,600 on mainnet
}

fn getKESPeriodsRemaining(ocert: OCert, slot: SlotNo, max_evo: u64) u64 {
    const current = getCurrentKESPeriod(slot);
    const start = ocert.kes_period;
    const end = start + max_evo;
    if (current >= end) return 0;
    return end - current;
}
```

---

## Test Requirements

1. **Mempool add/remove:** Add 100 valid txs, remove 50, verify state
2. **Mempool re-validation:** Apply block with conflicting tx, verify removal
3. **Mempool capacity:** Fill to capacity, verify rejection of excess
4. **Block forging:** Produce a valid block, verify header hash
5. **Block accepted by Haskell:** Forge block on devnet, submit to Haskell node, verify acceptance
6. **Transaction selection:** Verify fee-maximizing selection within size limits
7. **KES rotation:** Rotate KES key, verify blocks still valid with new key
8. **Key file parsing:** Load keys from cardano-cli format
