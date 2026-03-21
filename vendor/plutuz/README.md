# plutuz

A [UPLC](https://github.com/IntersectMBO/plutus) (Untyped Plutus Core) implementation in Zig.

UPLC is the core language that runs on the Cardano blockchain. Every Plutus smart contract compiles
down to UPLC before it is submitted on-chain. This project provides a parser, pretty printer,
and CEK machine evaluator for UPLC programs.

## Requirements

- [Zig 0.15.2](https://ziglang.org/download/)

## Build

```sh
zig build
```

This produces the `plutuz` CLI at `zig-out/bin/plutuz`. Mostly for testing and playing.

## Usage

Evaluate a UPLC program:

```sh
./zig-out/bin/plutuz program.uplc
```

Pretty print without evaluating:

```sh
./zig-out/bin/plutuz -p program.uplc
```

## Testing

Unit tests:

```sh
zig build test --summary all
```

Conformance tests (991 tests from the [Plutus conformance test suite](https://github.com/IntersectMBO/plutus)):

```sh
zig build conformance --summary all
```

The conformance step automatically generates `conformance/tests.zig` from the test data in
`conformance/tests/` before compiling and running. No manual generation step is needed.

## Project structure

```
src/
  root.zig             Library entry point
  main.zig             CLI entry point
  ast/                 AST types (Term, Constant, Type, Builtin, Value)
  binder/              Variable binding representations (Name, DeBruijn, NamedDeBruijn)
  cek/                 CEK machine evaluator and builtin implementations
  convert/             Name to DeBruijn index conversion
  crypto/              Cryptographic primitives (BLS12-381, RIPEMD-160)
  data/                PlutusData and CBOR encoding
  syn/                 Lexer, parser, and pretty printer

conformance/
  tests.zig            Auto-generated conformance test file
  generate.zig         Test generator (walks tests/ and emits tests.zig)
  tests/               Conformance test data (.uplc and .uplc.expected files)
```

## Supported builtins

All 101 Plutus builtins are implemented (0-100), including:

- Integer arithmetic and comparison
- ByteString operations (append, slice, index, bitwise, shift, rotate)
- String operations and UTF-8 encoding
- Cryptographic hashes (SHA2-256, SHA3-256, Blake2b-224/256, Keccak-256, RIPEMD-160)
- Signature verification (Ed25519, ECDSA secp256k1, Schnorr secp256k1)
- BLS12-381 curve operations (G1/G2 add, negate, scalar multiply, multi-scalar multiply, compress, uncompress, hash to group, Miller loop, final verify)
- Data constructors and destructors
- List and array operations
- Pair operations
- Value operations (multi-asset ledger values)
