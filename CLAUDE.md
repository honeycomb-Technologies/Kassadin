# Kassadin — Cardano Node in Zig

## Project Overview

Kassadin is a spec-compliant Cardano block-producing node written in Zig. It must interoperate with the Haskell cardano-node on mainnet, matching or beating it in memory usage.

**GitHub:** https://github.com/honeycomb-Technologies/Kassadin

## Current Status

**~14,000 lines, local test suite passing, Zig 0.15.2 + plutuz**

**Phase 0: COMPLETE** — Crypto, CBOR, Core Types (109 tests, all byte-exact vs Haskell)
**Phase 1: COMPLETE** — Networking + multi-SDU mux (48 tests + live preview + Dolos N2C handshake)
**Phase 2: COMPLETE** — Storage (19 tests, zero memory leaks)
**Phase 3: LAYER 1 COMPLETE** — Parsing + Plutus (265 tests, 999/999 plutuz conformance)
**Phase 4: LAYER 1 COMPLETE** — Consensus algorithms (VRF leader, chain selection, nonce evolution)
**Phase 5: INDEPENDENT DONE** — Mempool + key file management
**Phase 6: CODECS DONE** — All 5 N2C protocols + Unix socket + N2C handshake
**Phase 7: IN PROGRESS** — Preview sync fetches real blocks, stores them through `ChainDB`, and resumes from a sync-point checkpoint (`db/<network>/sync.resume`); `bootstrap-sync` now restores real Mithril main + ancillary snapshots under `db/<network>/`, loads the latest local ledger snapshot into `LedgerDB`, replays the immutable tail to the snapshot tip, hydrates reward balances, stake deposits, current/future pool params, current/future pool owner memberships, pool reward accounts, pool retirement schedules, chain-account pots, fee pots, rollback-safe pending MIR state (`iRReserves` / `iRTreasury` / `deltaReserves` / `deltaTreasury`), Haskell-shaped `BlocksMade` (`nesBprev` / `nesBcur`), and Haskell-shaped mark/set/go stake snapshots from the ancillary `state` payload, and validates forward preprod blocks locally without Dolos; normal runtime `sync` now uses that same restored snapshot/ledger path when available, and both paths load real Shelley genesis protocol params from local config when present. The CLI can now parse official `cardano-node` config JSON to resolve genesis files, load relay peers from official topology JSON, parse Byron genesis protocol constants and initial balance distributions from official/local genesis JSON, load Byron fee/size params when starting from origin, derive Byron genesis UTxOs locally from non-AVVM base58 addresses plus AVVM redeem keys, seed empty-chain ledger state from Byron genesis before `FindIntersectGenesis`, switch from Byron to Shelley protocol parameters on the first post-Byron block, and parse/apply Byron regular-block transactions plus Byron regular/EBB block headers from ouroboros-consensus golden data. Fresh-db preprod origin runs now validate the first 5 blocks from genesis locally and also validate across the Byron-to-Shelley transition (46 Byron blocks, then the first Shelley block at block 46 / slot 86400) with 0 invalid blocks. Shelley-era protocol-parameter update parsing/staging is now wired through tx bodies, `ChainDB` keeps rollback-safe epoch-scoped PPUP state, tx-body withdrawals now parse into reward accounts, and tracked reward withdrawals now follow the Haskell exact-drain rule once local reward state is loaded; `LedgerDB` now has rollback-safe reward-balance diffs, local fee-pot accumulation, rollback-safe treasury/reserves/snapshot-fee state, rollback-safe pending MIR state and epoch-boundary MIR realization/drop semantics, current pool config state, staged future pool params, rollback-safe current/future pool owner state, and rollback-safe previous/current epoch block-production maps that activate or rotate at epoch processing. Delegation certificates now consult tracked stake-key, pool, and DRep registration state instead of passing unchecked, MIR certificates now stage instantaneous rewards and pot transfers with Haskell-style protocol-version/stability-window gating, immutable-tail replay now runs the same epoch-boundary reward/MIR/snapshot/fee/pool/block-count effects as live `ChainDB`, and epoch-boundary pool processing now activates staged future pool params before reaping scheduled retirements, refunding pool deposits to tracked reward accounts when the stake credential is registered, routing unclaimed refunds to treasury, clearing delegations rollback-safely, and shifting `bcur -> bprev` exactly once per epoch. The modern Haskell `SnapShots = [mark,set,go,fee]` / `StakePoolSnapShot` shape is now the primary ancillary import path, with compatibility handling for observed 9-field pool entries that derives active stake from the outer active-stake maps instead of zeroing it; mark/set/go now retain credential-level active stake, snapshot-era pool reward accounts, and snapshot-era self-delegated owner sets/stake locally. The current epoch reward path no longer hardcodes fake performance: it now reads Haskell-shaped `BlocksMade`, derives expected blocks from Shelley genesis `activeSlotsCoeff`, uses a Shelley `maxPool'`-style pool-pot calculation against circulating stake plus active stake, credits both pool reward accounts and delegator reward accounts from the `go` snapshot, excludes self-delegated pool owners from member rewards, filters payouts against the currently registered reward-account set at epoch boundaries, routes unclaimable rewards to treasury, and uses Shelley genesis reward parameters during epoch-boundary replay/live sync instead of hardcoded mainnet defaults. Live preprod snapshot-backed runs now load 3,959,612 UTxOs plus 13,336 reward accounts and 30,968 stake deposits from the local Mithril snapshot before replaying the immutable tail and validating forward blocks. `sync` and `bootstrap-sync` now run until stopped by default, and both runtime paths exit cleanly on `SIGINT`/`SIGTERM`; full reward/state maintenance semantics beyond the current `BlocksMade` + `maxPool'` follower accounting, modern-era governance/Conway parameter changes, modern min-ADA/cost-model handling, general Byron/bootstrap address validation outside the genesis seeding path, and final ledger snapshot/checkpoint persistence on shutdown are still pending

**Operational validation target:** Dolos on preprod for side-by-side testing.
The Haskell trees in `reference-*` are used as semantic/reference sources and for troubleshooting.

## CRITICAL: Deferred Layer 2 Items (Phase 7/8)

The following items from Phases 3 and 4 MUST be completed during Phase 7/8.
They are architecturally blocked — they require real chain state from genesis
config loading, Mithril bootstrap, and block-by-block application.
DO NOT mark them done until validated against real chain data.

**Phase 3 Layer 2:**
- Apply real blocks end-to-end and verify UTxO state matches Haskell
- Reward calculation validated against real epoch boundary data
- Script_data_hash computed and verified (needs genesis cost model)
- Stake distribution verified against real snapshot data
- Sequential multi-block state tracking

**Phase 4 Layer 2:**
- VRF proof verification on real headers (needs epoch nonce from chain)
- KES signature verification on real headers (needs KES period)
- OCert counter validation against real counter map
- Full chain sync maintaining tip within 2160 slots

## Language & Tooling

- **Language:** Zig 0.15.2
- **External dependencies:** libsodium (system), vendored VRF C code from cardano-crypto-praos
- **UPLC evaluator:** plutuz (local path dependency, 999/999 conformance)
  - We fixed 17 upstream bugs: 4 BLS scalar bounds, 13 cost model coefficients
  - Fixes in local reference-plutuz, to be submitted to rvcas

## Key Constraints

1. **Memory efficiency is pass/fail.** Use mmap'd storage for UTxO set.
2. **Byte-exact CBOR round-tripping.** Preserve original encoding via `Annotated(T)`.
3. **All commits include AI co-author tag.** Challenge requirement.
4. **MANDATORY: No internal-only tests for critical modules.** Every module validated against Haskell reference data, Rust golden files, CDDL specs, or live node behavior.

## What's Proven Against Real Data

| Category | Evidence |
|:---|:---|
| VRF | 5 Haskell vectors, byte-exact (same C code) |
| KES | 5 Rust golden files, byte-exact |
| TxId hash | Blake2b-256 byte-exact vs Python |
| Block parsing | 6 eras from ouroboros-consensus golden files |
| Tx fields | Inputs, outputs, fee — byte-exact vs Python |
| Certificates | 3 real certs from golden block |
| Multi-asset | Policy + "couttsCoin" + quantity byte-exact |
| VKey witness | Full 32 bytes byte-exact |
| Redeemer | tag/index/ExUnits exact match |
| Plutus script hash | Blake2b-224 byte-exact |
| Plutus execution | 999/999 official conformance tests |
| N2N handshake | Real preview node v15 accepted |
| N2N chain-sync | Real preview sync from genesis with fetched blocks and sync-point resume (`sync.resume`) |
| N2N block-fetch | Real preview non-genesis block fetched and parsed |
| Byron block parsing | ouroboros-consensus golden regular + EBB block/header parsing and point/hash derivation |
| Byron tx parsing/apply | golden Byron GenTx parsing plus regular-block UTxO application using Byron fee policy |
| N2C handshake | Real Dolos node (preprod) accepted |
| Mithril restore | Real preprod main + ancillary snapshot restored under `db/preprod/` |
| Bootstrap local validation | 100 forward preprod blocks validated locally from restored ledger snapshot |
| Snapshot ancillary state | Live preprod Mithril snapshot loads 13,336 reward accounts + 30,968 stake deposits and also hydrates current/future pool params, pool / chain-account / fee-pot state from ancillary `state` |
| Signal-aware follower runtime | Real preprod `sync` exits cleanly on `SIGINT` while loading/restoring snapshot-backed state |
| Genesis parsing | Real mainnet-shelley-genesis.json |
| Addresses | 6 CIP-0019 golden vectors |

## Architecture

- Translate Haskell semantics, not code structure. Use Zig idioms.
- VRF uses exact same C code as Haskell node (vendor/vrf/).
- Multi-SDU mux reassembly follows Haskell Network/Mux/Ingress.hs design.
- Dolos nodes work for N2C testing (same Ouroboros protocols).
- Dolos socket: `dolos.socket` (preprod, magic=1, Mithril-bootstrapped).

## Build Commands

```bash
zig build test           # unit + live-gated tests
zig build test-live      # Live N2N test against preview relay
zig build test-dolos     # N2C handshake smoke test with local Dolos
zig build run            # Run the node
```

Note: Use `/home/burgess/.local/share/mise/installs/zig/0.15.2/zig` if
mise doesn't resolve to 0.15.2 automatically.

## Phase Dependencies

```
Phase 0 (Crypto) ── COMPLETE
Phase 1 (Networking) ── COMPLETE (multi-SDU mux fixed)
Phase 2 (Storage) ── COMPLETE
Phase 3 L1 (Ledger parsing/Plutus) ── COMPLETE
Phase 4 L1 (Consensus algorithms) ── COMPLETE
Phase 5 (Mempool/Keys) ── Independent parts DONE
Phase 6 (N2C protocols) ── Codecs DONE
Phase 7 (Integration) ── NEXT ← This is where Layer 2 gets validated
Phase 8 (Hardening) ── After Phase 7
```
