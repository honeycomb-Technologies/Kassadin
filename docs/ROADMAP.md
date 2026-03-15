# Kassadin Development Roadmap

## Challenge Requirements Summary

A spec-compliant Cardano block-producing node that:
- Supports all node-to-node mini-protocols (chain-sync, block-fetch, tx-submission v2, keep-alive, peer-sharing)
- Supports all node-to-client mini-protocols (local chain-sync, local tx-submission, local state-query, local tx-monitor)
- Matches or beats Haskell node in average memory usage across 10 days
- Agrees on tip selection within 2160 slots for 10 days
- Recovers from power-loss without human intervention
- Agrees with Haskell node on all block/transaction validity and chain-tip selection
- Can sync from Mithril snapshot or genesis to tip
- Can produce valid blocks accepted by other nodes on preview/preprod
- Can operate in private testnet with 2 Haskell nodes

---

## Phase 0: Foundation — Crypto, CBOR, Core Types -- COMPLETED

**Status:** 109/109 tests passing. All cross-validated against Haskell/Rust reference data.

### 0.1 Cryptographic Primitives
- [x] Ed25519 signing/verification via Zig std.crypto (RFC 8032, byte-compatible with libsodium)
- [x] Blake2b-224 and Blake2b-256 hashing via Zig std.crypto (RFC 7693)
- [x] VRF (PraosBatchCompatVRF, IETF draft-13) via vendored C code from cardano-crypto-praos/cbits
- [x] KES (CompactSumKES depth-6 over Ed25519) pure Zig implementation
- [x] Operational certificate creation and validation
- [x] Bech32 encoding/decoding (BIP-173) for key serialization

### 0.2 CBOR Codec
- [x] CBOR encoder (all major types, definite + indefinite length, tags)
- [x] CBOR decoder with raw-bytes preservation (sliceOfNextValue)
- [x] Support for CBOR tags (#6.x) and big integers
- [x] Byte-preserving Annotated(T) wrapper type
- [x] Decoded real Alonzo block from cardano-ledger golden test suite
- [ ] CBOR canonical encoding (deferred to Phase 3 — needed for script data hash)

### 0.3 Core Cardano Types
- [x] SlotNo, EpochNo, BlockNo, Hash28, Hash32 with type aliases
- [x] TxId, TxIn, TxIx, Coin, Value (simplified for Phase 0)
- [x] Credential (KeyHash | ScriptHash)
- [x] Address encoding/decoding (base, enterprise, reward, script, pointer types)
- [x] ProtVer, Nonce (with XOR), UnitInterval, Point, Tip
- [x] StakeReference, RewardAccount, mainnet constants
- [x] Conway governance stubs (DRep, Anchor, Vote)

### Testing Gate 0 -- PASSED
- [x] Ed25519: sign/verify, indirectly proven byte-exact via KES golden match
- [x] VRF: 5 Haskell test vectors (vrf_ver13_*), byte-exact proof/output match. Same C code as Haskell node.
- [x] KES: 5 Rust golden files (compactkey6.bin family), byte-exact 608-byte SK, 288-byte signatures
- [x] CBOR: encode/decode all major types + decoded real 1,865-byte Alonzo block
- [x] CBOR: byte-exact preservation verified (sliceOfNextValue captures original bytes)
- [x] Address: 6 CIP-0019 official golden vectors (base, enterprise, reward, script)
- [x] Blake2b: proven correct via KES golden match (seed expansion uses Blake2b-256)
- [x] Bech32: BIP-173 vectors + all Cardano key prefixes

**Validation sources:** cardano-crypto-praos test_vectors/, input-output-hk/kes golden files, CIP-0019, cardano-ledger golden/block.cbor

---

## Phase 1: Networking — Multiplexer & Mini-Protocols

**Goal:** Establish peer-to-peer communication with Haskell nodes.

### 1.1 Multiplexer
- [ ] 8-byte SDU header encoding/decoding (timestamp, direction, protocol num, length)
- [ ] SDU framing (12,288 byte max payload for sockets)
- [ ] Round-robin egress scheduling across mini-protocols
- [ ] Ingress demultiplexing to per-protocol queues
- [ ] Bearer abstraction (TCP socket, Unix socket)

### 1.2 Handshake Protocol
- [ ] Version negotiation (propose/accept/refuse)
- [ ] N2N version support (v14, v15)
- [ ] N2C version support (v16-v21)
- [ ] CBOR message encoding per handshake CDDL

### 1.3 Chain-Sync (N2N)
- [ ] State machine: StIdle → StNext → StIntersect → StDone
- [ ] All messages: RequestNext, AwaitReply, RollForward, RollBackward, FindIntersect, IntersectFound/NotFound, Done
- [ ] CBOR encoding (tags 0-7)
- [ ] Header-only mode (N2N)
- [ ] Pipelining support

### 1.4 Block-Fetch
- [ ] State machine: BFIdle → BFBusy → BFStreaming → BFDone
- [ ] All messages: RequestRange, ClientDone, StartBatch, NoBlocks, Block, BatchDone
- [ ] CBOR encoding (tags 0-5)
- [ ] Large payload handling (2.5 MB max in streaming state)

### 1.5 Tx-Submission v2
- [ ] State machine: StInit → StIdle → StTxIds → StTxs → StDone
- [ ] All messages: Init, RequestTxIds (blocking/non-blocking), ReplyTxIds, RequestTxs, ReplyTxs, Done
- [ ] CBOR encoding (tags 0-6)
- [ ] FIFO outstanding TxId tracking
- [ ] Pull-based flow control

### 1.6 Keep-Alive
- [ ] State machine: StClient → StServer → StDone
- [ ] Messages: KeepAlive(cookie), KeepAliveResponse(cookie), Done
- [ ] 97s/60s timeout enforcement

### 1.7 Peer-Sharing
- [ ] State machine: StIdle → StBusy → StDone
- [ ] Messages: ShareRequest(amount), SharePeers([address]), Done
- [ ] IPv4/IPv6 address encoding

### 1.8 Connection Manager
- [ ] P2P peer governor (warm/hot/cold peer management)
- [ ] Connection lifecycle management
- [ ] Peer selection and rotation

**Spec:** `docs/specs/03-network.md`

### Testing Gate 1 (ALL require live node validation)
- [ ] Multiplexer: SDU encode/decode golden vectors matching Haskell wire format
- [ ] Handshake: complete version negotiation with preview-node.play.dev.cardano.org:3001 (magic=2)
- [ ] Chain-Sync: follow 10+ real headers from preview node, verify slots increase
- [ ] Block-Fetch: download and decode 5+ real blocks from preview
- [ ] Tx-Submission: init + handle RequestTxIds from real node
- [ ] Keep-Alive: ping with cookie, verify response cookie matches
- [ ] Peer-Sharing: request peers, decode valid IPv4/IPv6 addresses
- [ ] Wrong network magic: handshake refused by real node
- [ ] All protocol CBOR matches CDDL specs from ouroboros-network

---

## Phase 2: Storage — ImmutableDB, VolatileDB, LedgerDB

**Goal:** Persistent, crash-safe block and ledger state storage.

### 2.1 ImmutableDB
- [ ] Append-only, epoch-chunked block storage
- [ ] Primary index: slot → file offset
- [ ] Secondary index: hash → slot
- [ ] EBB (Epoch Boundary Block) handling
- [ ] Streaming iterator for block ranges
- [ ] mmap-based file access for memory efficiency
- [ ] CRC32 integrity checks

### 2.2 VolatileDB
- [ ] Recent blocks storage (within k=2160 of tip)
- [ ] In-memory successor map (ChainHash → Set HeaderHash)
- [ ] Garbage collection (remove blocks older than immutable tip)
- [ ] Block component extraction (header only, body only, full block)

### 2.3 LedgerDB
- [ ] Ledger state snapshots (periodic serialization to disk)
- [ ] In-memory last-k states for rollback
- [ ] Snapshot loading on startup (crash recovery)
- [ ] UTxO set backed by LMDB (mmap'd, not heap)
- [ ] Fork tracking (apply/rollback chain diffs)

### 2.4 ChainDB (Unified Interface)
- [ ] Combines ImmutableDB + VolatileDB + LedgerDB
- [ ] Block addition pipeline (validate → store → chain select)
- [ ] Current chain fragment (length ~k from immutable tip)
- [ ] Async block addition with promises

**Spec:** `docs/specs/04-storage.md`

### Testing Gate 2
- [ ] ImmutableDB: write 10,000 blocks, read back by slot and hash, verify integrity
- [ ] ImmutableDB: crash simulation (kill mid-write), recovery without data loss
- [ ] VolatileDB: fork simulation with 3 competing chains, correct successor tracking
- [ ] VolatileDB: GC removes exactly the right blocks
- [ ] LedgerDB: snapshot write/read round-trip, state matches
- [ ] LedgerDB: rollback to k-deep state produces correct UTxO
- [ ] Memory: UTxO set of 1M entries uses <500MB RSS via LMDB

---

## Phase 3: Ledger — Multi-Era Validation

**Goal:** Validate every transaction and block from Byron through Conway.

### 3.1 Byron Era
- [ ] Byron block deserialization (legacy CBOR format)
- [ ] Byron address validation
- [ ] Byron UTxO transitions
- [ ] Byron → Shelley hard fork boundary handling

### 3.2 Shelley Era
- [ ] Transaction body parsing (fields 0-7)
- [ ] UTxO transition rule (UTXOW): inputs consumed, outputs created, fees, deposits
- [ ] Preservation of value invariant
- [ ] Certificate processing: registration, delegation, pool reg/retire, MIR
- [ ] Stake snapshot pipeline (mark → set → go)
- [ ] Reward calculation at epoch boundaries
- [ ] Protocol parameter updates
- [ ] Native multi-sig script validation
- [ ] Minimum fee calculation: fixed + (size × per-byte)

### 3.3 Allegra/Mary Extensions
- [ ] Validity intervals (invalidBefore, invalidHereafter)
- [ ] Timelock scripts
- [ ] Multi-asset Value type: Coin + Map PolicyID (Map AssetName Quantity)
- [ ] Minting/burning via native scripts
- [ ] Min-ADA-per-UTxO rule

### 3.4 Alonzo Extensions
- [ ] Plutus V1 script execution (via plutuz)
- [ ] Two-phase validation: Phase-1 (structural) then Phase-2 (scripts)
- [ ] Collateral inputs (consumed on script failure)
- [ ] Datum/Redeemer/ScriptContext construction
- [ ] Script data hash computation (canonical CBOR)
- [ ] ExUnits tracking and validation
- [ ] Cost model application from protocol parameters

### 3.5 Babbage Extensions
- [ ] Plutus V2 script execution
- [ ] Reference inputs (CIP-31)
- [ ] Inline datums (CIP-32)
- [ ] Reference scripts (CIP-33)
- [ ] Collateral return output
- [ ] Total collateral field

### 3.6 Conway Extensions
- [ ] Plutus V3 script execution
- [ ] Governance actions (7 types): parameter change, hard fork, treasury withdrawal, no confidence, update committee, new constitution, info
- [ ] Voting procedures (DReps, Constitutional Committee, SPOs)
- [ ] DRep registration/delegation certificates (tags 9-18)
- [ ] Voting thresholds (pool: 5 params, DRep: 10 params)
- [ ] Guardrails scripts
- [ ] Treasury withdrawals
- [ ] Governance action enactment state machine

### 3.7 Hard Fork Combinator
- [ ] Multi-era block dispatch (tag 0=Byron, 1=Shelley, ..., 6=Conway)
- [ ] Era transition detection from protocol parameters
- [ ] Cross-era ledger state migration
- [ ] Cross-era forecast bounds

### 3.8 Plutus Integration
- [ ] plutuz dependency integration (build.zig.zon)
- [ ] ScriptContext construction from transaction data
- [ ] Cost model parameter loading from protocol parameters (V1, V2, V3)
- [ ] Script hash computation (language prefix + flat-encoded script)
- [ ] Phase-1 validation (well-formedness, version compatibility)
- [ ] Redeemer → Script matching
- [ ] Reference script resolution from UTxO

**Spec:** `docs/specs/05-ledger.md`

### Testing Gate 3
- [ ] Parse and validate 1000 real mainnet blocks from each era
- [ ] CBOR round-trip every block without byte changes
- [ ] UTxO state after applying block N matches Haskell node's UTxO hash
- [ ] Reward calculation at 10 epoch boundaries matches Haskell
- [ ] Plutus script execution matches plutuz conformance (991 tests pass)
- [ ] Script data hash computation matches Haskell for 100 Alonzo+ transactions
- [ ] Conway governance action processing matches Haskell for known proposals
- [ ] Hard fork transitions produce correct era-specific behavior

---

## Phase 4: Consensus — Ouroboros Praos

**Goal:** Correct chain selection and block validation per Ouroboros Praos.

### 4.1 VRF Leader Election
- [ ] Slot leader check: VRF(slot, epochNonce) → certified natural → compare with stake threshold
- [ ] Threshold: leaderValue ≤ 1 - (1 - f)^σ where f=1/20, σ=relative stake
- [ ] Two VRF evaluations: leader VRF + nonce VRF per slot

### 4.2 Chain Selection
- [ ] Longest chain rule (most blocks)
- [ ] Fork resolution: prefer chain with more blocks
- [ ] Chain diff computation (rollback count + new suffix)
- [ ] Candidate chain construction from VolatileDB successors
- [ ] Chain validation pipeline (header → ledger → protocol state)

### 4.3 Epoch Nonce Evolution
- [ ] Evolving nonce: XOR with VRF output for each block in first 2/3 of epoch
- [ ] Candidate nonce: snapshot of evolving nonce at randomness stabilization window
- [ ] Epoch nonce: candidateNonce XOR lastEpochBlockNonce at epoch transition
- [ ] Lab nonce: hash of previous block

### 4.4 Header Validation
- [ ] Block number monotonically increasing
- [ ] Slot number strictly increasing
- [ ] Previous hash matches
- [ ] VRF proof verification
- [ ] KES signature verification
- [ ] Operational certificate validation (counter, period, cold key signature)
- [ ] Protocol version check

### 4.5 Protocol State (PraosState)
- [ ] Track: lastSlot, OCert counters, evolving/candidate/epoch/previous/lab nonces
- [ ] Tick forward to slot (update nonces at epoch boundary)
- [ ] Update on block (add VRF output to nonces, record OCert counter)

**Spec:** `docs/specs/06-consensus.md`

### Testing Gate 4
- [ ] VRF leader check agrees with Haskell for 10,000 slots using known stake distribution
- [ ] Chain selection chooses same tip as Haskell given identical block sets
- [ ] Fork resolution: feed 3 competing forks, verify correct winner
- [ ] Epoch nonce matches Haskell at 10 epoch boundaries
- [ ] Header validation accepts all valid preview blocks, rejects crafted invalid ones
- [ ] OCert counter validation rejects replayed certificates
- [ ] Full chain sync on preview: tip within 2160 slots of Haskell node for 1 hour

---

## Phase 5: Block Production & Mempool

**Goal:** Forge valid blocks and manage the transaction mempool.

### 5.1 Mempool
- [ ] Transaction validation against current ledger state
- [ ] Capacity management (bytes + ExUnits)
- [ ] FIFO ordering with priority
- [ ] Re-validation on chain tip change (rollback/rollforward)
- [ ] Snapshot for block forging
- [ ] Timeout-based eviction

### 5.2 Block Forging
- [ ] Slot leader check for own pools
- [ ] Transaction selection from mempool (fee-maximizing, within limits)
- [ ] Block body assembly (ordered tx bodies, witness sets, auxiliary data)
- [ ] Block header construction (prev hash, VRF proofs, KES signature, OCert)
- [ ] Block CBOR encoding
- [ ] Block announcement via chain-sync to peers

### 5.3 Key Management
- [ ] Cold key loading (Ed25519)
- [ ] KES key loading and period tracking
- [ ] KES key evolution at period boundaries
- [ ] VRF key loading
- [ ] Operational certificate loading and validation

**Spec:** `docs/specs/07-forging.md`

### Testing Gate 5
- [ ] Mempool: add 100 valid txs, forge block, verify all included
- [ ] Mempool: reject invalid txs (insufficient funds, bad scripts)
- [ ] Mempool: re-validate after rollback
- [ ] Block forging: produce block accepted by Haskell node on devnet
- [ ] Block forging: produce block on preprod accepted by network
- [ ] Key management: KES evolution across period boundary, blocks still valid
- [ ] Block announcement: new block propagated to 3 Haskell peers

---

## Phase 6: Node-to-Client Protocols

**Goal:** Serve local clients (wallets, CLI, DApps).

### 6.1 Local Chain-Sync
- [ ] Same as N2N chain-sync but serving full blocks (not just headers)
- [ ] UNIX domain socket bearer
- [ ] No size limits or timeouts (trusted local client)

### 6.2 Local Tx-Submission
- [ ] Push-based: MsgSubmitTx → MsgAcceptTx / MsgRejectTx
- [ ] Validate against current ledger + mempool
- [ ] Return detailed rejection reasons

### 6.3 Local State Query
- [ ] Acquire ledger state at point (specific, immutable tip, volatile tip)
- [ ] Support all query types per era
- [ ] Release and re-acquire state at different points

### 6.4 Local Tx-Monitor
- [ ] Mempool snapshot acquisition
- [ ] NextTx iteration
- [ ] HasTx check
- [ ] GetSizes (capacity, size, count)

**Spec:** `docs/specs/08-n2c.md`

### Testing Gate 6
- [ ] Local chain-sync: cardano-cli can follow chain from node
- [ ] Local tx-submission: submit transaction via cardano-cli, see it in mempool
- [ ] Local state-query: query UTxO set, protocol parameters, stake distribution
- [ ] Local tx-monitor: iterate mempool contents via local client
- [ ] All N2C protocols tested with official cardano-cli binary

---

## Phase 7: Mithril Bootstrap & Full Integration

**Goal:** Fast sync from Mithril snapshot and full mainnet operation.

### 7.1 Mithril Snapshot Bootstrap
- [ ] Download snapshot from Mithril aggregator
- [ ] Verify certificate chain (STM multi-signatures)
- [ ] Unpack and restore ImmutableDB
- [ ] Restore ledger state snapshot
- [ ] Continue syncing from snapshot tip via normal chain-sync

### 7.2 Genesis Sync (Alternative)
- [ ] Parse Byron genesis configuration
- [ ] Parse Shelley/Alonzo/Conway genesis files
- [ ] Sync from genesis block through all eras
- [ ] Handle all hard fork transitions

### 7.3 Full Integration
- [ ] Node configuration file parsing (YAML/JSON)
- [ ] P2P topology configuration
- [ ] Logging and tracing system
- [ ] Graceful shutdown (save state, close connections)
- [ ] CLI interface (run, query, submit)

**Spec:** `docs/specs/09-bootstrap.md`

### Testing Gate 7
- [ ] Mithril: download, verify, restore mainnet snapshot in <30 minutes
- [ ] Mithril: node syncs from snapshot tip to current tip
- [ ] Genesis: sync preview from genesis to tip
- [ ] Config: parse official mainnet/preview/preprod config files
- [ ] Integration: run alongside 2 Haskell nodes in private devnet for 24 hours
- [ ] Integration: tip within 2160 slots of Haskell nodes for entire test
- [ ] Memory: average RSS ≤ Haskell node over 24 hours

---

## Phase 8: Hardening & Conformance

**Goal:** Production readiness.

### 8.1 Crash Recovery
- [ ] Power-loss at any point → clean restart
- [ ] ImmutableDB: detect and truncate partial writes
- [ ] VolatileDB: rebuild from ImmutableDB tip
- [ ] LedgerDB: restore from latest snapshot + replay

### 8.2 Adversarial Testing
- [ ] Malformed CBOR messages → graceful rejection
- [ ] Invalid blocks → reject without corruption
- [ ] Peer misbehavior → disconnect and penalize
- [ ] Memory exhaustion → bounded allocation, graceful degradation

### 8.3 Performance Optimization
- [ ] Profile and optimize hot paths (block validation, CBOR decoding)
- [ ] Memory audit (RSS tracking, leak detection)
- [ ] Throughput benchmarks (blocks/sec, txs/sec)

### 8.4 10-Day Mainnet Test
- [ ] Sync from Mithril snapshot to tip
- [ ] Run for 10 continuous days
- [ ] Average memory ≤ Haskell node
- [ ] Tip within 2160 slots at all times
- [ ] Produce valid blocks on preprod during this period
- [ ] No crashes, no human intervention

### Testing Gate 8 (FINAL)
- [ ] All Phase 0-7 gates still passing
- [ ] 10-day mainnet stability test passed
- [ ] Block production on preprod verified by external validators
- [ ] Private devnet with 2 Haskell nodes operational
- [ ] No validity disagreements found
- [ ] Memory requirement met

---

## Subsystem Count & Effort Estimates

| Phase | Subsystems | Complexity |
|-------|-----------|------------|
| 0: Foundation | 6 | Medium — well-defined, testable in isolation |
| 1: Networking | 8 | Medium — state machines, exact CBOR encoding |
| 2: Storage | 4 | High — crash safety, mmap, concurrent access |
| 3: Ledger | 8 | Very High — multi-era rules, Plutus integration |
| 4: Consensus | 5 | High — subtle correctness requirements |
| 5: Block Production | 3 | Medium — builds on Phase 3+4 |
| 6: N2C Protocols | 4 | Medium — similar to N2N but simpler |
| 7: Integration | 3 | Medium — glue code, configuration |
| 8: Hardening | 4 | High — adversarial testing, optimization |

**Total: ~45 subsystems across 9 phases**
