# Kassadin — Cardano Node in Zig

## Project Overview

Kassadin is a spec-compliant Cardano block-producing node written in Zig. It must interoperate with the Haskell cardano-node on mainnet, matching or beating it in memory usage.

**GitHub:** https://github.com/honeycomb-Technologies/Kassadin

## Current Status

**52 commits, 50 files, ~12,000 lines, 301 tests, Zig 0.15.2 + plutuz**

**Phase 0: COMPLETE** — Crypto, CBOR, Core Types (109 tests, all byte-exact vs Haskell)
**Phase 1: COMPLETE** — Networking + multi-SDU mux (48 tests + live preview + Dolos N2C handshake)
**Phase 2: COMPLETE** — Storage (18 tests, zero memory leaks)
**Phase 3: LAYER 1 COMPLETE** — Parsing + Plutus (265 tests, 999/999 plutuz conformance)
**Phase 4: LAYER 1 COMPLETE** — Consensus algorithms (VRF leader, chain selection, nonce evolution)
**Phase 5: INDEPENDENT DONE** — Mempool + key file management
**Phase 6: CODECS DONE** — All 5 N2C protocols + Unix socket + N2C handshake
**Phase 7: MAJOR MILESTONE** — Full pipeline: Mithril → FindIntersect → block-fetch → parse txs on LIVE preview

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
| N2N chain-sync | 10+ real headers from preview |
| N2C handshake | Real Dolos node (preprod) accepted |
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
zig build test           # 301 unit tests
zig build test-live      # Live N2N test against preview relay
zig build test-dolos     # N2C handshake with local Dolos
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
