# Kassadin — Cardano Node in Zig

## Project Overview

Kassadin is a spec-compliant Cardano block-producing node written in Zig. It must interoperate with the Haskell cardano-node on mainnet, matching or beating it in memory usage.

## Language & Tooling

- **Language:** Zig 0.15.2+
- **External dependencies:** libsodium (VRF/KES/Ed25519), blst (BLS12-381 via plutuz)
- **UPLC evaluator:** plutuz (https://github.com/utxo-company/plutuz) — used as a Zig dependency for Plutus script execution

## Key Constraints

1. **Memory efficiency is a pass/fail requirement.** Must match or beat the Haskell node's RSS over 10 days on mainnet. Use mmap'd storage (LMDB or custom) for UTxO set. Never hold the full UTxO set in heap memory.
2. **Byte-exact CBOR round-tripping.** Cardano hashes raw CBOR bytes. Our CBOR codec must preserve original encoding for hash verification. Never re-encode when hashing.
3. **All commits must include model and prompt in commit message** with a `Co-Authored-By` tag from the model. This is a challenge requirement.
4. **Every subsystem must have conformance tests** against the Haskell node's behavior before being considered complete.

## Architecture Principles

- Translate Haskell semantics, not Haskell code structure. Use Zig idioms (comptime generics, tagged unions, explicit allocators).
- Prefer arena allocators for request-scoped work (block validation, tx validation).
- Use mmap for persistent storage (ImmutableDB, UTxO set).
- No global state. All subsystem state passed explicitly.

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

All detailed specifications are in `docs/specs/`. Each spec maps 1:1 to a subsystem and contains:
- Exact type definitions with sizes
- CBOR encoding format with tag numbers
- State machine transitions (for protocols)
- Validation rules (for ledger)
- Test requirements

## Development Workflow

1. Read the relevant spec in `docs/specs/` before implementing
2. Write tests FIRST (test-driven development)
3. Implement the subsystem
4. Run conformance tests against Haskell reference data
5. Only move to next phase when all tests pass

## Phase Dependencies

```
Phase 0 (Crypto + CBOR + Types) ──┐
                                   ├── Phase 1 (Networking)
                                   ├── Phase 2 (Storage)
                                   └── Phase 3 (Ledger) ──┐
                                                           ├── Phase 4 (Consensus)
Phase 1 + Phase 4 ────────────────────────────────────────── Phase 5 (Block Production)
Phase 5 ──────────────────────────────────────────────────── Phase 6 (N2C Protocols)
Phase 6 ──────────────────────────────────────────────────── Phase 7 (Mithril + Integration)
Phase 7 ──────────────────────────────────────────────────── Phase 8 (Hardening)
```

## Testing Strategy

- **Unit tests:** Per-function, per-module (`zig test`)
- **CBOR round-trip tests:** Encode → decode → compare against known vectors from Haskell node
- **Protocol tests:** Mock peer, verify state machine transitions and message encoding
- **Ledger conformance:** Apply known blocks, compare resulting ledger state hash
- **Consensus tests:** Feed known block sequences, verify tip selection matches Haskell
- **Integration tests:** Run alongside Haskell node on devnet, compare behavior
- **Memory benchmarks:** Track RSS over time, compare against Haskell baseline
