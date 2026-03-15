# Kassadin — Cardano Node in Zig

## Project Overview

Kassadin is a spec-compliant Cardano block-producing node written in Zig. It must interoperate with the Haskell cardano-node on mainnet, matching or beating it in memory usage.

**GitHub:** https://github.com/honeycomb-Technologies/Kassadin

## Current Status

**Phase 0: COMPLETE** (109/109 tests, all cross-validated against Haskell/Rust)
**Phase 1: COMPLETE** (157 unit tests + 4 live tests against real Cardano preview node)
**Phase 2: COMPLETE** (175 tests, zero memory leaks, structural validation)
**Phase 3: NEXT** (Ledger — multi-era transaction/block validation)

## Language & Tooling

- **Language:** Zig 0.13.0
- **External dependencies:** libsodium (system), vendored VRF C code from cardano-crypto-praos
- **UPLC evaluator:** plutuz (https://github.com/utxo-company/plutuz) — for Plutus script execution in Phase 3

## Key Constraints

1. **Memory efficiency is a pass/fail requirement.** Must match or beat the Haskell node's RSS over 10 days on mainnet. Use mmap'd storage for UTxO set. Never hold the full UTxO set in heap memory.
2. **Byte-exact CBOR round-tripping.** Cardano hashes raw CBOR bytes. Our CBOR codec preserves original encoding via `Annotated(T)`. Never re-encode when hashing.
3. **All commits must include model and prompt in commit message** with a `Co-Authored-By` tag from the model. This is a challenge requirement.
4. **MANDATORY: No internal-only tests.** Every module must be validated against Haskell reference data, Rust golden files, CDDL specs, or live node behavior. Internal round-trip tests alone are insufficient. A test must prove byte-compatibility with the Haskell node, not just self-consistency.

## Phase 0 Completion Summary

| Module | Tests | Validated Against |
|--------|:---:|:---|
| Ed25519 | 6 | RFC 8032 (Zig std), proven via KES golden match |
| Blake2b | 5 | RFC 7693, proven via KES golden match |
| VRF | 8 | 5 Haskell test vectors (vrf_ver13_*), byte-exact. Uses vendored C code from cardano-crypto-praos/cbits — same code as Haskell node |
| KES | 16 | 5 Rust golden files (compactkey6.bin family), byte-exact SK/sig/evolution |
| OpCert | 4 | Depends on Ed25519+KES (both cross-validated) |
| Bech32 | 6 | BIP-173 standard vectors |
| CBOR | 36 | Real Alonzo block from cardano-ledger golden test suite |
| Types/Addresses | 19 | 6 CIP-0019 official golden address vectors |

## Architecture Principles

- Translate Haskell semantics, not Haskell code structure. Use Zig idioms (comptime generics, tagged unions, explicit allocators).
- Prefer arena allocators for request-scoped work (block validation, tx validation).
- Use mmap for persistent storage (ImmutableDB, UTxO set).
- No global state. All subsystem state passed explicitly.
- VRF uses the exact same C code as the Haskell node (vendored in `vendor/vrf/`). This guarantees byte-level compatibility including the Cardano-specific Elligator2 sign bit quirk.
- Dolos nodes can be used for testing (same Ouroboros protocols, same blocks). Haskell node required only for final conformance.

## Reference Repositories

Cloned under `reference-*/` (gitignored):
- `reference-node` — cardano-node orchestration
- `reference-cardano-ledger` — all era specs, CDDL, validation rules
- `reference-ouroboros-consensus` — Praos consensus, ChainDB, HFC
- `reference-ouroboros-network` — multiplexer, mini-protocols, P2P
- `reference-cardano-base` — VRF, KES, Ed25519, crypto primitives
- `reference-cardano-api` — high-level API layer
- `reference-plutus` — Plutus Core evaluator (Haskell reference)
- `reference-plutuz` — Plutus UPLC evaluator (Zig, used as dependency)

## Spec Documents

All detailed specifications are in `docs/specs/`. Each spec maps 1:1 to a subsystem and contains exact type definitions, CBOR encoding formats, state machine transitions, validation rules, and test requirements.

## Development Workflow

1. Read the relevant spec in `docs/specs/` before implementing
2. Identify Haskell reference data or live node tests for validation
3. Write tests FIRST — tests must validate against external reference, not just internal consistency
4. Implement the subsystem
5. Run conformance tests
6. Only move to next phase when ALL tests pass and ALL are externally validated

## Phase Dependencies

```
Phase 0 (Crypto + CBOR + Types) ── COMPLETED
  ├── Phase 1 (Networking) ── COMPLETED
  ├── Phase 2 (Storage)
  └── Phase 3 (Ledger) ──┐
                          ├── Phase 4 (Consensus)
Phase 1 + Phase 4 ─────────── Phase 5 (Block Production)
Phase 5 ───────────────────── Phase 6 (N2C Protocols)
Phase 6 ───────────────────── Phase 7 (Mithril + Integration)
Phase 7 ───────────────────── Phase 8 (Hardening)
```

## Testing Strategy

- **Crypto tests:** Validated against Haskell test vectors, Rust golden files, or IETF RFCs
- **CBOR tests:** Decoded real blocks from cardano-ledger golden test suite
- **Protocol tests:** Connect to real Cardano preview node (preview-node.play.dev.cardano.org:3001)
- **Ledger conformance:** Apply known blocks, compare resulting state against Haskell
- **Integration tests:** Run alongside Haskell nodes on devnet
- **Memory benchmarks:** Track RSS over time, compare against Haskell baseline
- **Live network tests:** Gated behind `zig build test-live` (requires internet)

## Build Commands

```bash
zig build          # Build kassadin binary
zig build test     # Run all unit tests (109 currently)
zig build run      # Run the node
zig build test-live # Run live network tests (requires internet) [Phase 1+]
```
