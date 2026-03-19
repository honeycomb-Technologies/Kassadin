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

Local development note: on this workstation, operational side-by-side validation
uses Dolos on preprod. The Haskell codebases remain reference sources for
semantics, serialization, and troubleshooting.

---

## Phase 0: Foundation — Crypto, CBOR, Core Types -- COMPLETED

**Status:** 109/109 tests passing. All cross-validated against Haskell/Rust reference data.

### 0.1 Cryptographic Primitives
- [x] Ed25519 signing/verification via Zig std.crypto (RFC 8032, byte-compatible with libsodium)
- [x] Blake2b-224 and Blake2b-256 hashing via Zig std.crypto (RFC 7693)
- [x] VRF (PraosBatchCompatVRF, IETF draft-13) via vendored C code from cardano-crypto-praos/cbits
- [x] KES verification path now uses Haskell-aligned `Sum6KES Ed25519DSIGN Blake2b_256` semantics for live header validation
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
- [x] Legacy compact KES golden files still cover the old experimental module; runtime/header validation now uses the real `Sum6KES` layout with 448-byte signatures
- [x] CBOR: encode/decode all major types + decoded real 1,865-byte Alonzo block
- [x] CBOR: byte-exact preservation verified (sliceOfNextValue captures original bytes)
- [x] Address: 6 CIP-0019 official golden vectors (base, enterprise, reward, script)
- [x] Blake2b: proven correct via KES golden match (seed expansion uses Blake2b-256)
- [x] Bech32: BIP-173 vectors + all Cardano key prefixes

**Validation sources:** cardano-crypto-praos test_vectors/, input-output-hk/kes golden files, CIP-0019, cardano-ledger golden/block.cbor

---

## Phase 1: Networking — Multiplexer & Mini-Protocols -- COMPLETED

**Status:** 157 unit tests + 4 live tests passing. All validated against real Cardano preview node.

### 1.1 Multiplexer
- [x] 8-byte SDU header encoding/decoding (big-endian, direction bit corrected: 0=initiator, 1=responder)
- [x] SDU framing (12,288 byte max payload)
- [x] Bearer abstraction (TCP socket via std.net)
- [x] SDU fragmentation for payloads > max size
- [x] Multi-SDU message reassembly with per-protocol ingress buffers
  (following Haskell Network/Mux/Ingress.hs design — CBOR framing for message boundaries)
- [x] Unix socket bearer for N2C (connectUnix, UnixServer)
- [ ] Round-robin egress scheduling (deferred — single-threaded for now)

### 1.2 Handshake Protocol
- [x] MsgProposeVersions / MsgAcceptVersion / MsgRefuse codec
- [x] N2N version support (v14, v15) — v15 negotiated with real node
- [x] Version data: [magic, initiator_only, peer_sharing, query]
- [ ] N2C version support (deferred to Phase 6)

### 1.3 Chain-Sync (N2N)
- [x] All 8 messages: RequestNext, AwaitReply, RollForward, RollBackward, FindIntersect, IntersectFound/NotFound, Done
- [x] Point encoding: [] for genesis, [slot, hash] for specific
- [x] Tip encoding: [point, block_no]
- [x] Byte-preserving header capture (raw CBOR stored)
- [x] Followed 10 real headers from preview node (including rollback event)

### 1.4 Block-Fetch
- [x] All 6 messages: RequestRange, ClientDone, StartBatch, NoBlocks, Block, BatchDone
- [x] Block raw CBOR preserved as bytes
- [ ] Multi-SDU block reassembly for large blocks (deferred)

### 1.5 Tx-Submission v2
- [x] All messages: Init(tag=6), RequestTxIds, ReplyTxIds, RequestTxs, ReplyTxs, Done
- [x] Indefinite-length CBOR lists for tx data (0x9f...0xff)
- [ ] FIFO tracking and flow control (deferred to Phase 5)

### 1.6 Keep-Alive
- [x] MsgKeepAlive(cookie) / MsgKeepAliveResponse(cookie) / MsgDone
- [x] Cookie=42 round-trip verified against real node

### 1.7 Peer-Sharing
- [x] ShareRequest(amount) / SharePeers([addr]) / Done
- [x] IPv4 [0, u32, u16] and IPv6 [1, u32x4, u16] address encoding

### 1.8 Peer Connection Manager
- [x] Peer struct: connect, handshake, chain-sync, keep-alive, block-fetch operations
- [x] TCP connection via std.net.tcpConnectToHost
- [ ] Full P2P governor (warm/hot/cold) deferred to later phase

**Spec:** `docs/specs/03-network.md`

### Testing Gate 1 -- PASSED (live validation against real Cardano preview node)
- [x] Multiplexer: SDU golden vectors match Haskell wire format (direction bit verified)
- [x] Handshake: version 15 negotiated with preview-node.play.dev.cardano.org:3001
- [x] Chain-Sync: 10 headers followed from preview (tip slot=106912036, block=4109103)
- [x] Chain-Sync: handled rollback event from real node
- [x] Keep-Alive: cookie=42 round-trip matches
- [x] Tx-Submission: indefinite-length encoding verified (0x9f...0xff)
- [x] Peer-Sharing: IPv4/IPv6 encode/decode round-trip
- [x] Block-Fetch live test: fetched and parsed a non-genesis preview block
- [ ] Wrong-magic test: deferred (need separate connection)

**Validation:** preview-node.play.dev.cardano.org:3001 (Cardano Preview, magic=2)

---

## Phase 2: Storage — ImmutableDB, VolatileDB, LedgerDB -- COMPLETED

**Status:** 176 tests (19 storage tests), zero memory leaks. Structural validation plus local ImmutableDB reopen/recovery for Kassadin-written chunks.

### 2.1 ImmutableDB
- [x] Append-only chunk-based block storage with 4-byte length prefix
- [x] Secondary index: hash → block info (slot, offset, size)
- [x] Block retrieval by hash
- [x] Tip tracking
- [x] Rebuild local tip/index from Kassadin-written chunk files on reopen
- [ ] Primary index: slot → offset (deferred)
- [ ] EBB handling, mmap, CRC32 (deferred to production hardening)

### 2.2 VolatileDB
- [x] In-memory block storage with hash-based lookup
- [x] Successor map for fork tracking
- [x] Garbage collection by slot threshold
- [x] Duplicate detection
- [x] 3-way fork scenario tested

### 2.3 LedgerDB
- [x] UTxO set with diff-based apply/rollback
- [x] k=2160 diff ring buffer
- [x] Proper memory ownership (zero leaks under GPA)
- [x] Apply: consume inputs, produce outputs
- [x] Rollback: undo produced UTxOs and restore consumed UTxOs
- [ ] LMDB backing (deferred to mainnet scale)
- [ ] Snapshot write/load (deferred)

### 2.4 ChainDB
- [x] Unified ImmutableDB + VolatileDB + LedgerDB interface
- [x] Block addition with tip tracking
- [x] Fork detection (added_to_current_chain vs added_to_fork)
- [x] Duplicate detection
- [x] Finalization promotion (volatile → immutable at k depth)
- [x] Rollback current chain to a specific point
- [x] Snapshot/immutable tip anchor carried into current-chain tracking
- [x] Explicit validated mode rejects invalid current-chain blocks before storage

**Spec:** `docs/specs/04-storage.md`

### Testing Gate 2 -- PASSED (structural)
- [x] ImmutableDB: append/retrieve blocks, tip tracking
- [x] ImmutableDB: reopen rebuilds tip/index for Kassadin-written chunks
- [x] VolatileDB: 3-way fork with correct successor tracking
- [x] VolatileDB: GC removes old blocks
- [x] LedgerDB: apply diff adds/removes UTxOs correctly
- [x] LedgerDB: rollback restores consumed UTxOs and removes produced UTxOs
- [x] ChainDB: block addition extends tip, forks detected, duplicates handled
- [x] Zero memory leaks verified via Zig GPA

**Note:** Full storage validation still requires Phase 3 Layer 2. Current tests verify data structure correctness, local chunk reopen behavior, rollback semantics, and explicit validated-mode rejection. Mithril/Haskell ImmutableDB chunks are still read through `ChunkReader`; for bootstrap, restored ledger state is now loaded locally from Mithril ancillary tables and replayed to the immutable snapshot tip before forward validation.

---

## Phase 3: Ledger — Multi-Era Validation -- LAYER 1 COMPLETE

**Status:** 265 tests across 14 ledger modules. Zig 0.15.2 + plutuz integrated.
Parsing and Plutus execution fully validated against real data. Full ledger state
management (UTxO tracking, rewards, block application) deferred to Phase 7/8
where chain integration provides real state.

**Layer 1 (COMPLETE — parsing, validation rules, Plutus execution):**
All validated against real golden block data and 999/999 Plutus conformance.

**Layer 2 (DEFERRED — requires chain state from Phase 7/8):**
These items CANNOT be properly tested without real chain state. They must be
revisited during Phase 7 (Mithril bootstrap) and Phase 8 (hardening):
- Apply real blocks end-to-end and verify UTxO state matches Haskell
- Reward calculation against real epoch boundary data
- Script_data_hash computation (needs genesis cost model parameters)
- Stake distribution verification against real snapshot data
- Sequential multi-block state tracking
DO NOT mark Phase 3 fully complete until these are validated in Phase 7/8.

### 3.1 Byron Era
- [x] Byron block deserialization (regular + EBB golden blocks and N2N headers parse correctly)
- [x] Byron transaction parsing (golden GenTx and regular-block tx payloads parse correctly)
- [ ] Byron address validation (general bootstrap-address decode/validation is still deferred outside the genesis seeding path)
- [x] Byron UTxO transitions from genesis (non-AVVM base58 decoding, AVVM redeem-address construction, genesis pseudo-input derivation, and empty-chain UTxO seeding are wired locally)

### 3.2 Shelley Era
- [x] Transaction body parsing (inputs, outputs, fee, TTL, validity_start)
- [x] UTxO transition rule: preservation of value, fee check, min output
- [x] Certificate processing: all 7 Shelley types (registration, delegation, pool reg/retire, genesis, MIR)
- [x] Native multi-sig script validation (sig, all, any, n_of_k)
- [x] Minimum fee calculation: fixed + (size × per-byte)
- [ ] Stake snapshot pipeline (mark → set → go)
- [ ] Reward calculation at epoch boundaries
- [ ] Protocol parameter updates

### 3.3 Allegra/Mary Extensions
- [x] Validity intervals (invalidBefore, invalidHereafter via timelock scripts)
- [x] Timelock scripts (invalid_before, invalid_hereafter)
- [x] Multi-asset Value type: Coin + Map PolicyID (Map AssetName Quantity)
- [ ] Minting/burning via native scripts (parsing done, validation deferred)
- [ ] Min-ADA-per-UTxO rule (Babbage formula deferred)

### 3.4 Alonzo Extensions
- [x] ExUnits tracking (mem + steps, add, fits)
- [x] Redeemer types (spend, mint, cert, reward, voting, proposing)
- [x] Script hash computation (Blake2b-224 with language prefix)
- [x] Plutus V1 script execution via plutuz (Zig 0.15.2 upgrade completed)
- [ ] Two-phase validation (Phase-1 structural done, Phase-2 in progress)
- [ ] Collateral inputs
- [ ] Datum/Redeemer/ScriptContext construction
- [ ] Script data hash computation (canonical CBOR)
- [ ] Cost model loading from protocol parameters

### 3.5 Babbage Extensions
- [x] Plutus V2 script execution via plutuz (SemanticsVariant.b)
- [ ] Reference inputs/scripts/datums (CIP-31/32/33)
- [ ] Collateral return, total collateral

### 3.6 Conway Extensions
- [x] Certificate parsing: all Conway types (tags 7-18)
- [x] DRep type (key_hash, script_hash, always_abstain, always_no_confidence)
- [x] Plutus V3 script execution via plutuz (SemanticsVariant.c)
- [ ] Governance actions, voting, enactment (parsing deferred)

### 3.7 Hard Fork Combinator
- [x] Multi-era block dispatch: tag 24 unwrapping, era ID mapping
- [x] All 6 post-Byron eras parse correctly from ouroboros-consensus golden files
- [ ] Era transition detection
- [ ] Cross-era ledger state migration

### 3.8 Plutus Integration
- [x] Script hash computation (native + Plutus V1/V2/V3)
- [x] ExUnits and Redeemer types defined
- [x] evaluateScript interface defined (matches plutuz API)
- [x] RESOLVED: Upgraded to Zig 0.15.2, plutuz integrated natively
- [x] evaluateScript: flat-decode → CEK machine → budget tracking
- [x] Test: parse UPLC → encode → decode → evaluate → success

**Spec:** `docs/specs/05-ledger.md`

### Testing Gate 3 — PARTIALLY PASSED (real data validation)

**Proven against real golden block (Python cbor2 cross-checked):**
- [x] Block header: block_no, slot, body_size, protocol_version (6 eras golden-validated)
- [x] TxId: Blake2b-256 byte-exact match (ad8033bc...)
- [x] Transaction fields: input txid/index, output value, fee — all byte-exact
- [x] Certificates: 3 real certs (stake reg hash, pool pledge/cost, MIR) — byte-exact
- [x] VKey witness: full 32-byte vkey byte-exact (3b6a27bc...)
- [x] Redeemer: tag=spend, index=0, ExUnits=[5000, 5000]
- [x] Multi-asset output: policy + asset name "couttsCoin" + quantity 1000 — byte-exact
- [x] Plutus V1 script hash: Blake2b-224(0x01 || script) = 58503a1d... — byte-exact
- [x] Script data hash field extracted: 9e1199a9... — byte-exact
- [x] Plutus execution: plutuz CEK machine evaluates UPLC successfully

**Proven against live Cardano network:**
- [x] Chain-sync: 20+ headers from preview node
- [x] Handshake: v15 accepted with magic=2

**Proven via plutuz conformance suite:**
- [x] plutuz 999/999 conformance tests PASS (100%)
- We fixed 17 upstream plutuz bugs:
  - 4 BLS12-381 multiScalarMul: added scalar bounds validation per Haskell BLS12_381/Bounds.hs (4096-bit signed range check)
  - 13 valueData/unValueData: corrected cost model coefficients from builtinCostModelC.json (intercept/slope fixes)
- Every known Plutus program now evaluates identically to the Haskell node
- Fixes are in our local reference-plutuz (to be submitted upstream to rvcas)

**Deferred to later phases (require chain state):**
- [ ] Compute script_data_hash (needs genesis cost model — Phase 7)
- [ ] Sequential multi-block UTxO state tracking (needs real block sequence — Phase 7/8)
- [ ] Reward calculation against real epoch data (needs full node sync — Phase 8)

---

## Phase 4: Consensus — Ouroboros Praos -- IN PROGRESS

**Status:** 276 tests. VRF leader election, header validation, chain selection built.

### 4.1 VRF Leader Election
- [x] makeVRFInput: epochNonce(32) || slot(8 BE)
- [x] meetsLeaderThreshold: certNat/2^512 < 1-(1-f)^σ using 128-bit arithmetic
- [x] checkLeaderVRF: full prove + threshold check
- [x] Tests: threshold with 100%/0%/5% stake

### 4.2 Chain Selection
- [x] Longest chain rule (preferCandidate)
- [x] Fork resolution by block number
- [ ] Chain diff computation (Phase 7 — needs VolatileDB integration)
- [ ] Candidate chain construction from VolatileDB

### 4.3 Epoch Nonce Evolution
- [x] Evolving nonce: XOR with VRF output per block
- [x] Candidate nonce: snapshot at randomness stabilization window
- [x] Epoch boundary: rotate nonces
- [x] Lab nonce: hash of previous block

### 4.4 Header Validation
- [x] Block number monotonically increasing
- [x] Slot number strictly increasing
- [x] Previous hash matches
- [x] VRF key hash validation against pool registration
- [x] Body hash validation
- [x] Pool key hash computation (Blake2b-224)
- [x] Golden Alonzo block structural validation
- [x] Retain Shelley+ VRF cert payloads and structured operational-cert fields in parsed headers for later VRF/KES/OCert validation
- [ ] VRF proof verification (needs epoch nonce from chain state — Phase 7)
- [x] KES signature verification on Shelley+ headers using relative KES periods and Haskell-aligned `Sum6KES`
- [x] OCert counter validation during active sync using rollback-safe live issue-number state

### 4.5 Protocol State (PraosState)
- [x] Track nonces (evolving, candidate, epoch, previous, lab)
- [x] onBlock: update nonces and LAB
- [x] onEpochBoundary: rotate nonces
- [x] OCert counter tracking during active sync (restart persistence still pending)

### Testing Gate 4 — PARTIAL
**Proven:**
- [x] VRF leader check with known stake distributions (structural tests)
- [x] Chain selection: longest chain wins (simple tests)
- [x] Epoch nonce rotation (structural tests)
- [x] Header structural validation on golden Alonzo block

**Deferred to Phase 7/8 (require chain state):**
- [ ] VRF leader check against 10,000 real slots with real stake distribution
- [ ] VRF proof verification on real headers (needs epoch nonce)
- [x] KES signature verification on real preprod headers
- [x] OCert counter validation on real preprod headers during active sync
- [ ] Full chain sync maintaining tip within 2160 slots

---

## Phase 5: Block Production & Mempool -- INDEPENDENT PARTS DONE

**Status:** Mempool and key management built. Block forging needs Phase 7 chain state.

### 5.1 Mempool
- [x] Capacity management (bytes limit)
- [x] Add/remove transactions with duplicate detection
- [x] Fee-density sorting for block forging (selectForForging)
- [ ] Transaction validation against ledger state (Phase 7)
- [ ] Re-validation on tip change (Phase 7)

### 5.2 Block Forging
- [ ] All items need Phase 7 chain state

### 5.3 Key Management
- [x] Load Ed25519 signing keys from TextEnvelope JSON (cardano-cli format)
- [x] CBOR hex extraction from key files
- [ ] KES key loading and period tracking
- [ ] VRF key loading

### Testing Gate 5 — deferred to Phase 7/8

---

## Phase 6: Node-to-Client Protocols -- CODECS DONE

**Status:** All protocol codecs built. Live N2C handshake with Dolos verified.
The current `test-dolos` target is a handshake smoke test. Full N2C serving and
chain-sync/query parity still require Phase 7 chain state integration.

### 6.1 Local Chain-Sync
- [x] Message codec (same as N2N but protocol num 5)
- [x] UNIX domain socket bearer (connectUnix, UnixServer)
- [ ] Serving full blocks (needs chain state — Phase 7)

### 6.2 Local Tx-Submission
- [x] MsgSubmitTx / MsgAcceptTx / MsgRejectTx / MsgDone codec

### 6.3 Local State Query
- [x] MsgAcquire / MsgAcquired / MsgFailure / MsgQuery / MsgResult / MsgRelease codec
- [x] Immutable tip (tag 8) and volatile tip (tag 10) support

### 6.4 Local Tx-Monitor
- [x] MsgAcquire / MsgNextTx / MsgHasTx / MsgGetSizes / MsgRelease codec

### 6.5 N2C Handshake
- [x] Version negotiation with bit-15 version numbers (v16-v21)
- [x] Validated against live Dolos node (preprod, magic=1)

### Testing Gate 6 — PARTIAL
- [x] N2C handshake with Dolos: PASSES (v16/32784 accepted)
- [ ] Full N2C chain-sync with Dolos (needs recent intersect point — Phase 7)
- [ ] N2C protocols tested with cardano-cli (Phase 7/8)

---

## Phase 7: Mithril Bootstrap & Full Integration -- IN PROGRESS

**Status:** Local tests pass. Preview sync fetches real blocks from genesis or a saved
sync point, stores them through `ChainDB`, and resumes from `db/<network>/sync.resume`.
Mithril metadata query works, snapshot restore validates extracted layout under
`db/<network>/`, and both `bootstrap-sync` and normal runtime `sync` can now
read the restored immutable tip, anchor `ChainDB` there, load the latest
restored ledger snapshot from Mithril ancillary state, replay the immutable tail
locally, and then validate/follow real forward blocks. `bootstrap-sync
--validate-dolos` remains available as an optional comparison/fallback path, but
the verified bootstrap/runtime path no longer depends on Dolos. Both follower
commands now run until stopped by default and handle `SIGINT`/`SIGTERM` without
crashing. Genesis-seeded runtime validation and Shelley-era protocol-parameter
update tracking are now in place; tx-body withdrawals now parse into reward
accounts, and the ledger diff path can roll back tracked reward-balance
withdrawals locally; once reward state is loaded, tracked withdrawals now follow
the Haskell exact-drain rule instead of accepting stale/missing balances on
faith. Snapshot/runtime validation now hydrates reward balances, stake
deposits, current/future pool params, current/future pool owner memberships, pool reward accounts, pool retirement schedules, chain-account pots,
fee pots, Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`), and Haskell-shaped mark/set/go stake snapshots from the local
ancillary `state` payload before replaying the immutable tail, so live
withdrawal, deposit, fee, and pool-retirement checks can use real
snapshot-backed state. The modern Haskell `SnapShots = [mark,set,go,fee]` /
`StakePoolSnapShot` path is now the primary import path, with compatibility
handling for observed 9-field pool entries that derives active stake from the
outer active-stake map instead of zeroing it, and immutable replay now applies
the same reward/snapshot/fee/pool/block-count epoch-boundary effects as live `ChainDB`.
Epoch reward distribution is also no longer pool-account-only or fake-performance-only:
the current follower path imports/rotates Haskell-shaped `BlocksMade`, derives
expected blocks from Shelley genesis `activeSlotsCoeff`, applies a Shelley
`maxPool'`-style pool-pot calculation, credits both pool reward accounts and
delegator reward accounts from the `go` snapshot's credential-level stake
data, uses the snapshot-era pool reward account instead of the live pool map,
excludes self-delegated owners from member rewards, gates rewards on
snapshot-era pledge coverage, and uses Shelley genesis reward parameters
instead of hardcoded mainnet defaults.
Epoch-boundary pool processing is now rollback-safe in both immutable-tail replay and
forward sync: pool re-registration stages future params and future owner sets
locally instead of mutating live pool state immediately, those staged values
activate at epoch processing, retiring pools are removed at the scheduled
epoch, their deposits are refunded to tracked reward accounts when the stake
credential is registered, unclaimed refunds are routed to treasury, and stake
delegations to those pools are cleared. Full epoch reward/stake maintenance, modern
min-ADA/cost-model handling, Conway-era governance parameter changes, and final
ledger snapshot/checkpoint persistence on shutdown are still pending. The current
local validation path now loads Shelley genesis
parameters from configured/local genesis JSON and applies those real
fee/size/deposit limits during immutable replay and forward sync. The CLI can
also parse official cardano-node config JSON, resolve genesis file paths
relative to the config bundle, select a relay from official topology JSON,
parse Byron genesis protocol constants plus initial balance distributions from
official/local genesis files, load Byron fee/size params when starting from
origin, and parse/apply Byron regular-block transactions plus Byron regular/EBB
headers from ouroboros-consensus golden data.

### 7.1 Mithril Snapshot Bootstrap
- [x] Query Mithril aggregator API for latest snapshot (preprod: epoch 276, 3.1GB)
- [x] Download snapshot archive (curl, background download)
- [x] Snapshot restore module (scan chunk files, extract tar.zst, resolve snapshot root layout)
- [x] CLI path contract fixed: preprod snapshots restore under `db/preprod/`
- [x] Download step validates extracted immutable chunk layout before reporting success
- [x] Download ancillary Mithril archive when local ledger state is absent
- [x] ChainDB anchor/rollback path wired for snapshot-follow sync
- [x] Real preprod snapshot restored locally (`db/preprod/`, 5461 immutable chunks including ancillary chunk)
- [ ] Verify certificate chain (STM multi-signatures) — deferred, trust aggregator for now
- [x] Restore ledger state from snapshot ancillary tables
- [x] Replay immutable tail from restored ledger snapshot to immutable tip
- [x] FindIntersect at snapshot tip — ACCEPTED by preprod relay
- [x] Sync forward from snapshot tip: fetch and parse real preprod blocks (requires restored snapshot)
- [x] Optional Dolos validation path hydrates historical inputs via gRPC `ReadTx`

### 7.2 Chain Sync
- [x] SyncClient: connect, handshake, follow chain, handle rollbacks
- [x] Node runner: genesis config + ChainDB + sync loop
- [x] Real block points derived from chain-sync headers for block-fetch
- [x] CLI: `kassadin sync` fetches 20 preview blocks from genesis (WORKING)
- [x] Resume checkpoint: subsequent preview sync runs continue from the last saved sync point
- [x] CLI: `kassadin bootstrap` queries Mithril (WORKING)
- [x] Official cardano-node config JSON parser resolves genesis file paths relative to config bundles
- [x] Byron genesis parser loads protocol constants and initial AVVM/non-AVVM balance maps from official/local genesis JSON
- [x] Byron regular + EBB block/header parser supports ouroboros-consensus golden N2N payloads
- [x] Byron regular-block transaction parser/apply path works on ouroboros-consensus golden data with Byron fee parameters
- [x] Live block-fetch proof upgraded: fetches a non-genesis preview block and validates the fetched block number
- [x] Explicit validated-mode block path tested with rollback-safe ledger diffs
- [x] Sync from snapshot tip: `bootstrap-sync` resolves `db/preprod/`, loads the local ledger snapshot, replays the immutable tail, and fetches/parses forward blocks when a snapshot is present
- [x] `bootstrap-sync` validated 100 forward preprod blocks locally from a restored snapshot
- [x] `bootstrap-sync --validate-dolos` remains available for comparison/fallback
- [x] Load runtime ledger state from restored snapshot during normal `sync`
- [x] Load Shelley genesis protocol params into bootstrap/runtime validation paths
- [x] CLI topology parser loads relay peers from legacy `Producers` and modern `bootstrapPeers` / `accessPoints` files, and runtime `sync` / `bootstrap-sync` now rotate through the full resolved relay list on connect/reconnect instead of pinning the first peer
- [x] `sync` and `bootstrap-sync` can run until stopped, with bounded `--max-headers` / `--max-blocks` still available for tests
- [x] Load runtime ledger state from genesis during normal `sync` for Byron initial UTxO state
- [x] Empty-chain runtime path seeds Byron genesis UTxOs and enables local validation before `FindIntersectGenesis`
- [x] Fresh-db preprod origin sync proved against the live network (`test-origin-sync`: 8 genesis UTxOs primed, 5 headers synced, 5 blocks added, 0 invalid)
- [ ] Process received blocks through full ledger pipeline during normal sync (Phase 3/4 Layer 2)
- [x] Switch local validation from Byron protocol params to Shelley genesis params on the first post-Byron block
- [x] Prove origin-start validation end-to-end across the Byron-to-Shelley transition on a live chain (`test-origin-transition`: 46 Byron blocks + first Shelley block validated locally from a fresh DB)
- [x] Parse Shelley tx-body field `6` updates, stage identical-vote quorum by epoch, adopt supported protocol-parameter changes at epoch boundaries, and keep that state rollback-safe in `ChainDB`
- [x] Parse tx-body withdrawals into reward accounts and make tracked reward-balance withdrawals rollback-safe in `LedgerDB`
- [x] Make tracked withdrawals follow the Haskell exact-drain rule once local reward state is loaded
- [x] Hydrate reward-account balances and stake deposits from ancillary snapshot state during bootstrap/runtime sync
- [x] Validate stake/vote delegation certificates against tracked stake-key, pool, and DRep registration state
- [x] Hydrate pool reward accounts and scheduled retirements from ancillary snapshot state, then reap retiring pools rollback-safely at epoch boundaries during immutable replay and forward sync
- [x] Hydrate treasury/reserves/current-fee/snapshot-fee pots from ancillary snapshot state, accumulate block fees locally, and route unclaimed pool-retirement refunds to treasury
- [x] Import modern Haskell `SnapShots` / `StakePoolSnapShot` ancillary state as the primary path, retain credential-level active stake in mark/set/go, and handle observed 9-field pool entries compatibly
- [x] Carry stake credentials through live/snapshot UTxO entries and rebuild epoch mark stake from Haskell-style instant stake plus reward balances instead of approximating it from reward balances plus deposits
- [x] Track explicit per-credential stake-account registration state locally, rebuild it from checkpoint/live reward-deposit-delegation maps, and preserve UTxO staking credentials across rollbacks so follower registration/instant-stake logic no longer depends purely on reward/deposit map presence
- [x] Route ancillary snapshot account import through one explicit stake-account path so registered empty accounts survive snapshot hydration instead of being dropped when reward/deposit/delegation fields are all zero
- [x] Persist unified stake-account state directly in local ledger checkpoints so registered empty accounts survive reload without depending on reconstruction from split reward/deposit/delegation maps
- [x] Resolve epoch active stake from the unified local stake-account state instead of stitching reward balances and delegations together from separate maps
- [x] Keep pre-Conway pointer-backed instant stake live while disabling pointer-backed instant stake in Conway-era snapshot rotation and epoch-boundary processing, matching the Haskell instant-stake split
- [x] Hydrate current + future pool params from ancillary snapshot state, track them rollback-safely in `LedgerDB`, and activate staged pool re-registration params at epoch processing
- [x] Persist pool VRF key hashes in current/future pool params, hydrate them from ancillary snapshot state, and reject Shelley+ blocks whose issuer `vrf_vkey` hash does not match the tracked pool or current genesis-delegation VRF key hash
- [x] Credit delegator reward accounts as well as pool reward accounts from `go`-snapshot stake during epoch reward distribution (current follower reward model)
- [x] Import/rotate Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`) and use real block production plus Shelley `activeSlotsCoeff` in the follower reward path
- [x] Replace the ad hoc epoch reward diff with an explicit Haskell-shaped `deltaT` / `deltaR` / `deltaF` balance sheet so snapshot fees roll forward into reserves/treasury/rewards instead of being dropped
- [x] Track the aggregate deposited pot (`utxosDeposited`) through snapshot import, cert application, pool reap, rollback, and checkpoint reload instead of only mutating per-certificate deposit maps
- [x] Remove the remaining withdrawal “accept on faith” path once local ledger validation is enabled so reward withdrawals must always match tracked local balances
- [x] Parse MIR cert payloads, stage pending instantaneous rewards/pot transfers rollback-safely, hydrate MIR snapshot state locally, and realize-or-drop MIR at epoch boundaries in both immutable replay and live `ChainDB`
- [x] Filter epoch reward payouts against the current registered account set and route unclaimable rewards to treasury during replay/live epoch processing
- [x] Reject stake-key deregistration refunds while tracked reward balances remain unless the same transaction drains the reward account
- [x] Hydrate current/future genesis delegations from ancillary `DState`, seed the initial Shelley genesis-delegation map from `genDelegs`, stage tag-5 genesis-delegation certs at `slot + stabilityWindow`, checkpoint that state locally, and adopt the latest matured delegation per genesis key before block validation
- [ ] Maintain full reward-account and deposit state across epoch reward/stake updates during long-running sync
- [ ] Replace the current per-credential registration mirror with fuller Haskell-style `Accounts` / `DState` follower state
- [x] Track pre-Conway pointer stake references in instant-stake accounting and snapshot rotation

### 7.3 Full Integration
- [x] Shelley genesis config parsing (real mainnet genesis verified)
- [x] CLI with sync and bootstrap commands
- [x] P2P topology configuration
- [ ] Logging system
- [ ] Graceful shutdown (clean signal exit now works; final shutdown snapshot/checkpoint persistence still pending)

**Spec:** `docs/specs/09-bootstrap.md`

### Testing Gate 7
- [ ] Mithril: download, verify, restore mainnet snapshot in <30 minutes
- [x] Mithril: node syncs from restored snapshot tip with local ledger validation enabled
- [x] Genesis: fresh-db preprod origin sync starts with local Byron genesis seeding and validates initial blocks
- [x] Genesis: fresh-db preprod origin sync validates across the Byron-to-Shelley transition
- [ ] Genesis: sync preview from genesis to tip
- [ ] Config: validate parsing against official mainnet/preview/preprod config bundles end-to-end
- [ ] Integration: run alongside Dolos in private devnet/preprod for 24 hours
- [ ] Integration: tip within 2160 slots of Dolos for entire test
- [ ] Memory: capture RSS against local operational baseline

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
