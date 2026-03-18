# Spec 09: Mithril Bootstrap & Integration

## Overview

Fast sync via Mithril snapshot download, plus genesis sync fallback, node configuration, and full integration.

Current implementation note:
- `bootstrap --download` restores under `db/<network>/`, downloads Mithril ancillary data when local ledger state is absent, and validates that immutable chunks exist before reporting success
- `bootstrap-sync` resolves the snapshot root from `db/<network>/`, reads the snapshot tip, loads the latest local ledger snapshot from `ledger/<slot>/tables/tvar`, hydrates reward balances, stake deposits, current/future pool params, current/future pool owner memberships, pool reward accounts, pool retirements, chain-account pots, fee pots, rollback-safe pending MIR state, Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`), and Haskell-shaped mark/set/go stake snapshots from `ledger/<slot>/state`, replays the immutable tail to the immutable tip, anchors `ChainDB` there, and fetches/parses real forward blocks with local validation enabled
- `bootstrap-sync --validate-dolos` remains available as an optional comparison/fallback path via Dolos gRPC `ReadTx`
- Bootstrap/runtime local validation now load Shelley genesis protocol params from configured/local genesis JSON when available, and the CLI can resolve those genesis files from official cardano-node config JSON
- Byron genesis parsing now loads protocol constants and initial AVVM/non-AVVM balance distributions from official/local genesis JSON, Byron fee/size parameters can seed origin-side validation, and Kassadin now derives Byron genesis UTxOs locally from non-AVVM base58 addresses plus AVVM redeem keys, seeds empty-chain ledger state before `FindIntersectGenesis`, switches to Shelley genesis protocol params on the first post-Byron block, and parses/applies Byron regular/EBB block/header golden data; fresh-db preprod origin runs now validate the first 5 blocks locally from genesis and also validate across the Byron-to-Shelley transition, while general Byron/bootstrap address validation outside the genesis seeding path is still pending
- The CLI can also load relay peers from official topology JSON (`Producers`, `bootstrapPeers`, `localRoots`, `publicRoots`) and use the first resolved access point for `sync` / `bootstrap-sync`
- `sync` and `bootstrap-sync` now run until stopped by default, and both exit cleanly on `SIGINT`/`SIGTERM`
- Shelley-era tx-body protocol-parameter updates are now parsed, staged by epoch, adopted on quorum at epoch boundaries, and kept rollback-safe in `ChainDB`
- Tx-body withdrawals now parse into reward accounts, `LedgerDB` can roll back tracked reward-balance withdrawals locally, and tracked withdrawals now follow the Haskell exact-drain rule once local reward state is loaded
- Bootstrap/runtime snapshot state now hydrates reward balances, stake deposits, current/future pool state, current/future pool owner memberships, chain-account pots, fee pots, rollback-safe pending MIR state, Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`), and modern Haskell `SnapShots = [mark,set,go,fee]` stake snapshots before immutable-tail replay; observed 9-field pool entries are handled compatibly by deriving active stake from the outer active-stake maps, mark/set/go now retain credential-level active stake plus the snapshot-era pool reward account and self-delegated owner state locally, pool re-registration now stages future params and future owner sets locally instead of mutating live pool state immediately, those staged values activate at epoch processing, MIR now realizes-or-drops against local pots and registered reward credentials at epoch boundaries, and the current epoch reward path now uses imported/rotated `BlocksMade`, Shelley genesis `activeSlotsCoeff`, and a Shelley `maxPool'`-style pool-pot calculation to credit delegator reward accounts as well as pool reward accounts while excluding self-delegated owners from member rewards, enforcing snapshot-era pledge coverage, and using Shelley genesis reward parameters during immutable replay and live epoch-boundary processing
- Block fees now accumulate locally during replay/forward sync, pool retirements are reaped locally at epoch boundaries with rollback-safe deposit refunds, treasury routing for unclaimed refunds, and delegation clearing, and sync-point resume via `db/<network>/sync.resume` remains active
- Modern-era governance/Conway parameter changes, modern min-ADA/cost-model handling, full epoch reward/state maintenance, and final ledger snapshot/checkpoint persistence on shutdown are still pending

---

## 1. Mithril Snapshot Bootstrap

### Protocol
Mithril uses Stake-based Threshold Multi-signatures (STM) to certify snapshots of the Cardano chain state.

### Bootstrap Process
```
1. Contact Mithril aggregator (https://aggregator.release-mainnet.api.mithril.network/aggregator)
2. List available snapshots (GET /artifact/snapshots)
3. Select most recent snapshot
4. Download snapshot archive (.tar.zst, ~100+ GB compressed for mainnet)
5. Download ancillary archive when available (ledger state + any extra immutable files)
6. Verify certificate chain:
   a. Fetch certificate for this snapshot
   b. Verify STM multi-signature against computed message digest
   c. Follow certificate chain back to genesis certificate
7. Extract archives:
   a. ImmutableDB files → db/<network>/immutable/
   b. Ledger state snapshot(s) → db/<network>/ledger/<slot>/{meta,state,tables/tvar}
8. Load the latest local ledger snapshot at or before the immutable tip
9. Hydrate UTxOs from `tables/tvar` plus reward balances / stake deposits / current+future pool state / chain-account pots / fee pots from `state`
10. Replay immutable tail blocks from the ledger snapshot slot to the immutable tip, including staged future-pool activation, epoch-boundary pool reaping, and local fee-pot accumulation
11. Start node, which continues syncing from snapshot tip
```

### Snapshot Contents
```
snapshot.tar.zst/
└── immutable/
    ├── 00000.chunk
    ├── 00000.primary
    ├── 00000.secondary
    ├── ...
    ├── NNNNN.chunk         # Last complete immutable file
    ├── NNNNN.primary
    └── NNNNN.secondary

snapshot.ancillary.tar.zst/
├── immutable/
│   └── NNNNN.chunk         # Extra immutable file when present
├── ledger/
│   └── SLOT_NUMBER/
│       ├── meta
│       ├── state
│       └── tables/
│           └── tvar
└── ancillary_manifest.json
```

### Certificate Verification
```zig
pub fn verifyMithrilCertificate(cert: MithrilCertificate) !void {
    // 1. Verify the multi-signature
    //    STM verification using aggregate verification key
    // 2. Verify message digest matches snapshot content hash
    // 3. If cert has a previous_hash, fetch and verify parent cert
    // 4. If cert is genesis cert, verify against known genesis params
}
```

### Snapshot Integrity
After extraction, verify:
1. ImmutableDB chunk files are complete (last chunk may be partial)
2. Primary/secondary indices are consistent
3. Ledger state snapshot loads successfully from `ledger/<slot>/`
4. Ledger state hash matches expected value from certificate
5. The extracted archive resolves to a usable `db/<network>/immutable/` layout
6. The loaded ledger snapshot can replay the immutable tail to the immutable tip

---

## 2. Genesis Sync (Fallback)

### Configuration Files Required
```
mainnet-config.yaml          # Node configuration
mainnet-byron-genesis.json   # Byron era genesis
mainnet-shelley-genesis.json # Shelley era genesis
mainnet-alonzo-genesis.json  # Alonzo era genesis
mainnet-conway-genesis.json  # Conway era genesis
mainnet-topology.json        # Network topology
```

### Byron Genesis
```json
{
    "protocolConsts": { "k": 2160, "protocolMagic": 764824073 },
    "startTime": "2017-09-23T21:44:51Z",
    "blockVersionData": { ... },
    "avvmDistr": { ... },           // Initial AVVM distribution
    "nonAvvmBalances": { ... },     // Non-AVVM initial balances
    "bootStakeholders": { ... },    // Bootstrap stakeholders
    "heavyDelegation": { ... },     // Initial delegation certs
    "genesisKeyHashes": [ ... ]     // Genesis key hashes
}
```

### Shelley Genesis
```json
{
    "activeSlotsCoeff": 0.05,
    "epochLength": 432000,
    "genDelegs": { ... },
    "initialFunds": { ... },
    "maxLovelaceSupply": 45000000000000000,
    "networkId": "Mainnet",
    "networkMagic": 764824073,
    "protocolParams": {
        "a0": 0.3,
        "decentralisationParam": 0,
        "eMax": 18,
        "keyDeposit": 2000000,
        "maxBlockBodySize": 65536,
        "maxBlockHeaderSize": 1100,
        "maxTxSize": 16384,
        "minFeeA": 44,
        "minFeeB": 155381,
        "minPoolCost": 340000000,
        "minUTxOValue": 1000000,
        "nOpt": 500,
        "poolDeposit": 500000000,
        "rho": 0.003,
        "tau": 0.2
    },
    "securityParam": 2160,
    "slotLength": 1,
    "slotsPerKESPeriod": 129600,
    "staking": { ... },
    "systemStart": "2017-09-23T21:44:51Z",
    "updateQuorum": 5
}
```

### Genesis Sync Process
```
1. Parse genesis configurations
2. Initialize ledger state from genesis (initial UTxO, stake distribution)
3. Connect to peers
4. Chain-sync from origin
5. Process all blocks through all era transitions
6. This is SLOW (days/weeks for mainnet) — Mithril is strongly preferred
```

---

## 3. Node Configuration

### Config File (YAML)
```yaml
Protocol: Cardano
RequiresNetworkMagic: RequiresNoMagic  # mainnet
                                        # RequiresMagic for testnets

# Genesis files
ByronGenesisFile: mainnet-byron-genesis.json
ShelleyGenesisFile: mainnet-shelley-genesis.json
AlonzoGenesisFile: mainnet-alonzo-genesis.json
ConwayGenesisFile: mainnet-conway-genesis.json

# Database path
DatabasePath: db/

# Socket path (for N2C)
SocketPath: node.socket

# Network
EnableP2P: true
TargetNumberOfRootPeers: 60
TargetNumberOfKnownPeers: 100
TargetNumberOfEstablishedPeers: 50
TargetNumberOfActivePeers: 20

# Logging
minSeverity: Info

# Consensus
LastKnownBlockVersion-Major: 10
LastKnownBlockVersion-Minor: 0
```

### Topology File
```json
{
    "bootstrapPeers": [
        { "address": "backbone.cardano.iog.io", "port": 3001 }
    ],
    "localRoots": [
        { "accessPoints": [
            { "address": "relays.example.com", "port": 3001 }
        ],
        "advertise": false,
        "trustable": false,
        "valency": 1
        }
    ],
    "publicRoots": [
        { "accessPoints": [
            { "address": "backbone.cardano.iog.io", "port": 3001 }
        ],
        "advertise": false
        }
    ]
}
```

---

## 4. CLI Interface

### Commands
```
kassadin run
    --config <config.yaml>
    --topology <topology.json>
    --database-path <db/>
    --socket-path <node.socket>
    --port <3001>
    [--host <0.0.0.0>]

kassadin bootstrap
    --config <config.yaml>
    --database-path <db/>
    [--mithril-aggregator <url>]

kassadin version
kassadin --help
```

---

## 5. Graceful Shutdown

### On SIGTERM/SIGINT
```
1. Stop accepting new connections
2. Complete in-progress block validation
3. Flush mempool state (optional, txs can be re-fetched)
4. Take LedgerDB snapshot
5. Close all peer connections
6. Sync ImmutableDB to disk
7. Close LMDB environment
8. Remove socket file
9. Exit 0
```

### On Power Loss (Crash Recovery)
```
1. Detect incomplete writes in ImmutableDB (truncate partial blocks)
2. Rebuild VolatileDB index from block files
3. Load most recent valid LedgerDB snapshot
4. Replay blocks from snapshot to ImmutableDB tip
5. Resume normal operation
```

---

## 6. Logging

### Structured Logging
```zig
pub const LogLevel = enum { debug, info, notice, warning, error, critical };

pub const LogEvent = union(enum) {
    node_startup: struct { version: []const u8, config_path: []const u8 },
    peer_connected: struct { addr: []const u8 },
    peer_disconnected: struct { addr: []const u8, reason: []const u8 },
    block_received: struct { slot: SlotNo, hash: HeaderHash },
    block_adopted: struct { slot: SlotNo, block_no: BlockNo },
    block_forged: struct { slot: SlotNo, block_no: BlockNo, tx_count: u32 },
    chain_sync_tip: struct { slot: SlotNo, block_no: BlockNo },
    mempool_add: struct { tx_id: TxId, size: u32 },
    mempool_reject: struct { tx_id: TxId, reason: []const u8 },
    epoch_transition: struct { from: EpochNo, to: EpochNo },
    kes_expiry_warning: struct { periods_remaining: u64 },
    snapshot_taken: struct { slot: SlotNo },
    // ...
};
```

---

## Test Requirements

1. **Mithril:** Download preview snapshot, verify, restore, sync to tip
2. **Genesis:** Sync preview from genesis to slot 1000
3. **Config parsing:** Load official mainnet/preview/preprod configs
4. **Topology:** Parse and connect using official topology files
5. **Crash recovery:** Kill node mid-operation, restart, verify no data loss
6. **Graceful shutdown:** SIGTERM, verify clean exit and final checkpoint/snapshot persistence
7. **CLI:** All command-line options work as documented
8. **Integration:** Run alongside Dolos on preprod/devnet for 24 hours
9. **Reference check:** Use the Haskell sources for troubleshooting and semantic diffing where Dolos behavior is ambiguous
