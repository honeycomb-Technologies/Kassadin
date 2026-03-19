# Spec 04: Storage — ImmutableDB, VolatileDB, LedgerDB, ChainDB

## Overview

Cardano's storage layer is designed for crash safety, efficient random access, and minimal memory usage. It consists of three databases unified by ChainDB.

**Critical design principle:** Use mmap for all persistent data. The OS manages the page cache. Never load the entire UTxO set or block database into heap memory.

---

## 1. ImmutableDB

### Purpose
Append-only storage for finalized blocks (deeper than k=2160 from tip).

### On-Disk Layout
```
db/
├── immutable/
│   ├── 00000.chunk        # Block data for epoch 0
│   ├── 00000.primary      # Primary index (slot → offset)
│   ├── 00000.secondary    # Secondary index (hash → slot)
│   ├── 00001.chunk
│   ├── 00001.primary
│   ├── 00001.secondary
│   └── ...
```

### Chunk File Format
- Concatenated CBOR-encoded blocks
- Current Kassadin-written chunks use a 4-byte big-endian length prefix per block
- Mithril/Haskell snapshots remain raw concatenated CBOR and are currently read via `ChunkReader`
- Epoch Boundary Blocks (EBBs) stored at offset 0 in their epoch's chunk

### Primary Index
- Fixed-size entries: `[relative_slot: u32, offset: u64, is_ebb: bool]`
- Allows O(1) lookup by slot within an epoch
- Slot 0 in each epoch may be an EBB

### Secondary Index
- Maps `HeaderHash → (slot, offset, block_size, header_offset, header_size, is_ebb)`
- Used for hash-based lookups

### API
```zig
pub const ImmutableDB = struct {
    pub fn open(path: []const u8, allocator: Allocator) !ImmutableDB;
    pub fn close(self: *ImmutableDB) void;

    pub fn getTip(self: *ImmutableDB) ?Tip;
    pub fn appendBlock(self: *ImmutableDB, block: []const u8) !void;
    pub fn getBlock(self: *ImmutableDB, point: Point) !?[]const u8;
    pub fn getBlockBySlot(self: *ImmutableDB, slot: SlotNo) !?[]const u8;
    pub fn getHeader(self: *ImmutableDB, point: Point) !?[]const u8;

    pub fn stream(self: *ImmutableDB, from: StreamFrom, to: StreamTo) !Iterator;

    pub const Iterator = struct {
        pub fn next(self: *Iterator) !?[]const u8;
        pub fn close(self: *Iterator) void;
    };
};
```

### Crash Recovery
1. On startup, check the last chunk file for truncation
2. Verify CRC of last block in last chunk
3. If CRC fails, truncate to last valid block
4. Rebuild primary/secondary indices if corrupted

Current implementation note:
- Kassadin-written ImmutableDB chunks rebuild the in-memory tip/hash index on reopen
- Snapshot/Haskell ImmutableDB chunks are read via `ChunkReader`; for bootstrap, `ChainDB` can now load restored Mithril ancillary ledger state locally and replay the immutable tail to the snapshot tip before forward validation

### Memory Strategy
- mmap chunk files for reading (OS manages page cache)
- Small write buffer for appending (flush on sync)
- Index files are small enough to hold in memory

---

## 2. VolatileDB

### Purpose
Store recent blocks within k=2160 slots of the current tip. Supports multiple forks.

### On-Disk Layout
```
db/
├── volatile/
│   ├── blocks-0.dat       # Block data file
│   ├── blocks-1.dat       # Rotated when previous fills up
│   └── ...
```

### In-Memory State
```zig
pub const VolatileDB = struct {
    /// Maps block hash → block info (for all known recent blocks)
    block_info: HashMap(HeaderHash, BlockInfo),

    /// Successor map: parent hash → set of child hashes
    /// Used to construct candidate chains
    successors: HashMap(ChainHash, HashSet(HeaderHash)),

    /// Maximum slot seen
    max_slot: SlotNo,
};

pub const BlockInfo = struct {
    hash: HeaderHash,
    slot: SlotNo,
    block_no: BlockNo,
    prev_hash: ChainHash,
    is_ebb: bool,
    header_offset: u16,
    header_size: u16,
    file_offset: u64,        // offset in blocks-N.dat
    file_id: u32,            // which blocks-N.dat file
};
```

### API
```zig
pub fn open(path: []const u8, allocator: Allocator) !VolatileDB;
pub fn close(self: *VolatileDB) void;

pub fn putBlock(self: *VolatileDB, block: []const u8) !void;
pub fn getBlock(self: *VolatileDB, hash: HeaderHash) !?[]const u8;
pub fn getBlockInfo(self: *VolatileDB, hash: HeaderHash) ?BlockInfo;
pub fn getSuccessors(self: *VolatileDB, hash: ChainHash) HashSet(HeaderHash);
pub fn garbageCollect(self: *VolatileDB, slot: SlotNo) !void;
pub fn getMaxSlot(self: *VolatileDB) SlotNo;
```

### Garbage Collection
- Called when immutable tip advances
- Removes blocks with `slot < new_immutable_tip_slot`
- Uses strict `<` (not `<=`) to preserve blocks at the immutable tip slot
- Rebuilds successor map after removal

### Crash Recovery
- On startup, scan all block data files
- Rebuild in-memory indices (block_info, successors)
- Discard partially written blocks (detect via CBOR parsing)

---

## 3. LedgerDB

### Purpose
Maintain ledger state (UTxO set, stake distribution, protocol parameters) with k-deep rollback capability.

### Design: LMDB-Backed UTxO
```
db/
├── ledger/
│   ├── snapshots/
│   │   ├── 12345678.snapshot   # Ledger state at slot 12345678
│   │   └── 12345000.snapshot   # Previous snapshot
│   └── utxo.lmdb              # LMDB database for UTxO set
```

### UTxO Storage (LMDB)
```zig
// LMDB key-value store
// Key: TxIn (34 bytes: 32-byte TxId + 2-byte TxIx)
// Value: CBOR-encoded TxOut (variable size)

pub const UtxoStore = struct {
    env: *lmdb.MDB_env,
    dbi: lmdb.MDB_dbi,

    pub fn open(path: []const u8) !UtxoStore;
    pub fn get(self: *UtxoStore, txin: TxIn) !?TxOut;
    pub fn put(self: *UtxoStore, txin: TxIn, txout: TxOut) !void;
    pub fn delete(self: *UtxoStore, txin: TxIn) !void;

    // Batch operations for block application
    pub fn applyDiff(self: *UtxoStore, consumed: []const TxIn, produced: []const struct { TxIn, TxOut }) !void;
};
```

### Ledger State Snapshots
```zig
pub const LedgerState = struct {
    tip: Point,
    utxo_hash: Hash32,               // Hash of UTxO set (for verification)
    stake_distribution: StakeDistribution,
    protocol_params: ProtocolParams,
    epoch_state: EpochState,
    governance_state: GovernanceState, // Conway
    // ... per-era fields
};
```

### Snapshot Strategy
- Take snapshot every 2000 slots (configurable)
- Keep last 2 snapshots
- On startup, load most recent valid snapshot
- Replay blocks from snapshot tip to current tip

### Rollback Support
```zig
pub const LedgerDB = struct {
    current: LedgerState,
    /// Ring buffer of recent diffs for rollback
    diffs: RingBuffer(LedgerDiff, 2160),

    pub fn applyBlock(self: *LedgerDB, block: Block) !void;
    pub fn rollback(self: *LedgerDB, n: usize) !void;
    pub fn takeSnapshot(self: *LedgerDB) !void;
    pub fn restore(self: *LedgerDB, snapshot_path: []const u8) !void;
};

pub const LedgerDiff = struct {
    consumed: []const TxIn,           // UTxOs consumed
    produced: []const struct { TxIn, TxOut },  // UTxOs produced
    // Additional state changes...
};
```

### Crash Recovery
1. Load most recent valid snapshot
2. Find corresponding block in ImmutableDB
3. Replay all blocks from snapshot to current immutable tip
4. Rebuild any volatile state

---

## 4. ChainDB (Unified Interface)

### Purpose
Combines ImmutableDB + VolatileDB + LedgerDB into a single interface for the consensus layer.

### Core Invariant
```
getCurrentChain returns a fragment of headers:
  - Anchored at the immutable tip
  - Length up to k (2160)
  - Represents the current best chain
```

### API
```zig
pub const ChainDB = struct {
    immutable: ImmutableDB,
    volatile: VolatileDB,
    ledger: LedgerDB,
    current_chain: AnchoredFragment,

    pub fn addBlock(self: *ChainDB, block: Block) !AddBlockResult;
    pub fn getCurrentChain(self: *ChainDB) AnchoredFragment;
    pub fn getTipPoint(self: *ChainDB) Point;
    pub fn getTipSlot(self: *ChainDB) SlotNo;
    pub fn getTipBlockNo(self: *ChainDB) BlockNo;

    pub fn getBlock(self: *ChainDB, point: Point) !?Block;
    pub fn getHeader(self: *ChainDB, point: Point) !?Header;

    pub fn stream(self: *ChainDB, from: StreamFrom, to: StreamTo) !Iterator;
};

pub const AnchoredFragment = struct {
    anchor: Point,          // immutable tip
    headers: []const Header, // up to k headers
};

pub const AddBlockResult = enum {
    added_to_current_chain,
    added_to_fork,
    already_known,
    invalid,
};
```

### Block Addition Pipeline
```
1. Check: block not older than immutable tip slot
2. Check: block not already in VolatileDB
3. If explicit validated mode is enabled, parse/apply the block before storing it
4. Reject invalid current-chain blocks without storing them
5. Store block in VolatileDB
6. Construct candidate chains from VolatileDB successors
7. For each candidate better than current chain:
   a. Roll back ledger to intersection
   b. Apply new blocks sequentially
   c. Validate each step
8. If valid candidate found:
   a. Switch current chain to candidate
   b. Update ledger state
9. Periodically: move blocks from VolatileDB to ImmutableDB (immutable tip advances)
```

Current implementation note:
- Explicit validated mode remains opt-in, but runtime `sync` now enables it automatically when a restored Mithril snapshot + local ledger state are available
- Local validation now uses configured Shelley genesis protocol params when available, the empty-chain runtime path can seed Byron genesis UTxOs locally before enabling validation, `ChainDB` keeps Shelley-era protocol-parameter update state rollback-safe while adopting supported PPUP changes at epoch boundaries, and `LedgerDB` now has rollback-safe deposit-state, pool-state, delegation-state, explicit per-credential stake-account registration state, a unified stake-account snapshot import path, tracked reward-balance diffs, and scalar treasury/reserves/fee-pot state alongside UTxO changes; once local reward state is present, tracked withdrawals follow the Haskell exact-drain rule instead of accepting stale/missing balances on faith
- Snapshot/runtime paths now hydrate reward balances, stake deposits, the aggregate deposited pot (`utxosDeposited`), current/future pool params, current/future pool owner memberships, current/future genesis delegations from `DState`, pool reward accounts, pool retirements, chain-account pots, fee pots, rollback-safe pending MIR state (`iRReserves` / `iRTreasury` / `deltaReserves` / `deltaTreasury`), Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`), and Haskell-shaped mark/set/go stake snapshots from ancillary Mithril `state` before replaying the immutable tail; the modern `SnapShots` / `StakePoolSnapShot` layout is the primary path, observed 9-field pool entries are handled compatibly by deriving active stake from the outer active-stake map, ancillary pre-Conway account-state pointers now hydrate into local stake-account state, live/snapshot UTxO entries now retain either staking credentials or pointer refs, rollback preserves those stake refs, and epoch snapshot rotation now resolves active stake from the unified local stake-account state so pointer-backed stake and reward-account balances flow through the Haskell-style instant-stake path instead of being rebuilt from separate reward/delegation maps. Pre-Conway rotation still resolves pointer-backed stake from the local pointer map, while Conway-era rotation disables pointer-backed instant stake before epoch-boundary processing. Shelley genesis now seeds the initial genesis-delegation map locally, tag-5 genesis-delegation certs stage future delegations at `slot + stabilityWindow`, and slot ticking adopts the latest matured delegation per genesis key before block validation. Immutable-tail replay now applies the same reward/MIR/snapshot/fee/pool/block-count epoch-boundary effects as live `ChainDB`, staged pool re-registration params and owner sets now activate at epoch processing instead of mutating live pool state immediately, certificate deposits/refunds now adjust the deposited pot directly, pool reap decrements the deposited pot alongside removing pool deposits, and epoch reward distribution now uses `go`-snapshot credential-level stake plus the snapshot-era pool reward account to credit delegator reward accounts as well as pool reward accounts while importing/rotating real `BlocksMade`, deriving expected blocks from Shelley genesis `activeSlotsCoeff`, applying a Shelley `maxPool'`-style pool-pot calculation, carrying the epoch balance sheet through explicit `deltaT` / `deltaR` / `deltaF` updates, filtering payouts against currently registered reward credentials, routing unclaimable rewards to treasury, enforcing snapshot-era pledge coverage, and using Shelley genesis reward parameters during replay/live epoch-boundary processing
- Once ledger validation is enabled, reward balances are treated as authoritative local state: withdrawals must exactly drain the tracked reward account and no longer fall back to “accept on faith” behavior when local validation is active
- Sync-point resume via `db/<network>/sync.resume` remains active; final ledger snapshot/checkpoint persistence on shutdown is still pending. Full epoch reward/stake maintenance, fuller Haskell-style `Accounts` / `DState` parity beyond the current registration mirror, modern-era min-ADA/cost-model handling, and fuller ledger-state semantics are still pending

### Immutable Tip Advancement
```
When current chain has >k blocks past immutable tip:
  1. Take oldest block from volatile chain
  2. Append to ImmutableDB
  3. GC VolatileDB (remove blocks older than new immutable tip)
  4. Optionally take LedgerDB snapshot
```

---

## 5. Memory Budget

### Target: ≤ 8 GB RSS on mainnet

| Component | Memory Strategy | Expected RSS |
|-----------|----------------|-------------|
| ImmutableDB | mmap'd chunk files (OS page cache) | ~0 (kernel) |
| VolatileDB in-memory index | HashMap for ~10K recent blocks | ~50 MB |
| UTxO set (LMDB) | mmap'd, OS manages pages | ~0 (kernel) |
| LedgerDB diffs (k=2160) | Ring buffer of diffs | ~500 MB |
| Stake distribution | Compact in-memory map | ~200 MB |
| Protocol state | Small fixed-size structures | ~10 MB |
| Networking buffers | Per-peer, bounded | ~500 MB |
| Mempool | Bounded by capacity | ~500 MB |
| **Total** | | **~1.8 GB** |

The OS kernel will additionally use RAM for mmap page cache (ImmutableDB, LMDB), but this is shared memory and doesn't count toward RSS.

---

## Test Requirements

1. **ImmutableDB:** Write 10K blocks across 5 epochs, read back by slot and hash
2. **ImmutableDB crash:** Kill mid-write, restart, verify no corruption
3. **VolatileDB:** Insert blocks forming 3 forks, verify successor map
4. **VolatileDB GC:** Advance immutable tip, verify old blocks removed
5. **LedgerDB:** Apply 100 blocks, rollback 50, verify UTxO matches
6. **LedgerDB snapshot:** Write snapshot, restore, verify state matches
7. **ChainDB:** Full pipeline — add blocks, switch forks, advance immutable tip
8. **Memory:** UTxO set of 1M entries via LMDB, verify RSS < 500 MB
