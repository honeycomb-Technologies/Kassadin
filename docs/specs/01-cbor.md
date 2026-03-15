# Spec 01: CBOR Codec

## Overview

Every piece of data on the Cardano blockchain — blocks, transactions, protocol messages, ledger state — is CBOR-encoded (RFC 8949). Our codec must handle:

1. Standard CBOR encoding/decoding
2. **Byte-preserving round-trips** (hash raw CBOR, never re-encode)
3. Canonical encoding for script data hashes (RFC 7049 deterministic rules)
4. Indefinite-length sequences
5. CBOR tags (especially #6.24, #6.30, #6.121-#6.127, #6.102)
6. Big integers (#6.2 unsigned, #6.3 negative)

---

## 1. CBOR Major Types

| Major | Type | Header byte |
|-------|------|-------------|
| 0 | Unsigned integer | 0x00-0x1b |
| 1 | Negative integer | 0x20-0x3b |
| 2 | Byte string | 0x40-0x5f |
| 3 | Text string | 0x60-0x7f |
| 4 | Array | 0x80-0x9f |
| 5 | Map | 0xa0-0xbf |
| 6 | Tag | 0xc0-0xdb |
| 7 | Simple/float/break | 0xe0-0xff |

### Length encoding
- 0-23: value in lower 5 bits
- 24: 1-byte length follows
- 25: 2-byte length follows (big-endian)
- 26: 4-byte length follows (big-endian)
- 27: 8-byte length follows (big-endian)
- 31: indefinite length (terminated by 0xff break)

---

## 2. Zig Interface Design

### Core Types
```zig
pub const CborValue = union(enum) {
    unsigned: u64,
    negative: u64,      // actual value = -1 - stored
    bytes: []const u8,
    text: []const u8,
    array: []const CborValue,
    map: []const MapEntry,
    tag: struct { number: u64, content: *const CborValue },
    simple: u8,         // true=21, false=20, null=22, undefined=23
    float16: f16,
    float32: f32,
    float64: f64,
    break_: void,       // indefinite-length terminator (internal)

    // Big integers (via tag)
    // #6.2(bytes) = positive bignum
    // #6.3(bytes) = negative bignum
};

pub const MapEntry = struct {
    key: CborValue,
    value: CborValue,
};
```

### Byte-Preserving Wrapper
```zig
/// Stores both the decoded value AND the original raw CBOR bytes.
/// When hashing, use raw_cbor. When accessing fields, use decoded.
pub fn Annotated(comptime T: type) type {
    return struct {
        decoded: T,
        raw_cbor: []const u8,  // original bytes, never re-encoded
    };
}
```

### Encoder
```zig
pub const Encoder = struct {
    buffer: std.ArrayList(u8),

    pub fn encodeUint(self: *Encoder, value: u64) void;
    pub fn encodeNint(self: *Encoder, value: u64) void;  // -1 - value
    pub fn encodeBytes(self: *Encoder, data: []const u8) void;
    pub fn encodeText(self: *Encoder, text: []const u8) void;
    pub fn encodeArrayLen(self: *Encoder, len: u64) void;
    pub fn encodeArrayLenIndef(self: *Encoder) void;
    pub fn encodeMapLen(self: *Encoder, len: u64) void;
    pub fn encodeMapLenIndef(self: *Encoder) void;
    pub fn encodeTag(self: *Encoder, tag: u64) void;
    pub fn encodeBool(self: *Encoder, value: bool) void;
    pub fn encodeNull(self: *Encoder) void;
    pub fn encodeBreak(self: *Encoder) void;

    // Convenience
    pub fn encodeListLen(self: *Encoder, len: usize) void;  // alias for encodeArrayLen
    pub fn encodeWord8(self: *Encoder, v: u8) void;         // alias for encodeUint
    pub fn encodeWord16(self: *Encoder, v: u16) void;
    pub fn encodeWord32(self: *Encoder, v: u32) void;
    pub fn encodeWord64(self: *Encoder, v: u64) void;
    pub fn encodeInt(self: *Encoder, v: i64) void;          // picks uint or nint

    pub fn toOwnedSlice(self: *Encoder) []u8;
};
```

### Decoder
```zig
pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    pub fn decodeUint(self: *Decoder) !u64;
    pub fn decodeNint(self: *Decoder) !i64;
    pub fn decodeInt(self: *Decoder) !i64;
    pub fn decodeBytes(self: *Decoder) ![]const u8;
    pub fn decodeBytesAlloc(self: *Decoder, allocator: Allocator) ![]u8;
    pub fn decodeText(self: *Decoder) ![]const u8;
    pub fn decodeArrayLen(self: *Decoder) !?u64;     // null = indefinite
    pub fn decodeMapLen(self: *Decoder) !?u64;
    pub fn decodeTag(self: *Decoder) !u64;
    pub fn decodeBool(self: *Decoder) !bool;
    pub fn decodeNull(self: *Decoder) !void;
    pub fn peekMajor(self: *Decoder) !u3;             // peek at major type
    pub fn isBreak(self: *Decoder) bool;              // check for 0xff
    pub fn skipValue(self: *Decoder) !void;           // skip one CBOR value

    /// Returns a slice of the raw CBOR bytes for the next complete value
    /// WITHOUT consuming them. Used for byte-preserving wrappers.
    pub fn rawValue(self: *Decoder) ![]const u8;

    /// Decode with raw byte capture
    pub fn decodeAnnotated(self: *Decoder, comptime T: type, decodeFn: fn(*Decoder) !T) !Annotated(T);
};
```

---

## 3. Cardano-Specific CBOR Patterns

### Tagged Rational Numbers
```
unit_interval = #6.30([numerator: uint, denominator: uint])
// Tag 30 wraps a 2-element array
// Constraint: numerator <= denominator
// Example: 1/20 = #6.30([1, 20])
```

### CBOR-in-CBOR (Tag 24)
```
script_ref = #6.24(bytes .cbor script)
inline_datum = #6.24(bytes .cbor plutus_data)
// Tag 24 wraps bytes that themselves contain valid CBOR
// The inner CBOR is the actual data; outer is envelope
```

### PlutusData Constructors (Tags 121-127, 102)
```
constr<a> = #6.121([*a])     // Constructor 0
          / #6.122([*a])     // Constructor 1
          / #6.123([*a])     // Constructor 2
          / #6.124([*a])     // Constructor 3
          / #6.125([*a])     // Constructor 4
          / #6.126([*a])     // Constructor 5
          / #6.127([*a])     // Constructor 6
          / #6.102([uint, [*a]])  // Constructor n (general case)
```

### Big Integers
```
big_uint = #6.2(bytes)   // bytes encode unsigned big-endian integer
big_nint = #6.3(bytes)   // value = -1 - (big-endian unsigned interpretation of bytes)
```

### Set Encoding
Cardano uses sets in CBOR. They are encoded as either:
- `#6.258([*element])` — tagged set (newer eras)
- `[*element]` — plain array (older eras, compatibility)

---

## 4. Canonical Encoding Rules

For **script data hash** computation, Cardano uses RFC 7049 deterministic encoding:

1. **Integers:** Smallest possible encoding (0-23 in 1 byte, 24-255 in 2 bytes, etc.)
2. **Lengths:** Definite-length encoding for all strings, arrays, maps
3. **Map keys:** Sorted by:
   - First by serialized key length (shorter first)
   - Then lexicographically by serialized key bytes
4. **No indefinite-length encoding** in canonical form

### Implementation
```zig
pub const CanonicalEncoder = struct {
    // Same API as Encoder but enforces:
    // - Minimal integer encoding
    // - Definite-length only
    // - Sorted map keys
    pub fn encodeMapSorted(self: *CanonicalEncoder, entries: []const MapEntry) void;
};
```

---

## 5. Protocol Message Encoding Pattern

All Ouroboros mini-protocol messages use tagged arrays:

```
message = [tag: uint, ...params]
```

The tag identifies the message type. For example:
- ChainSync MsgRequestNext = `[0]`
- ChainSync MsgRollForward = `[2, header, tip]`
- BlockFetch MsgBlock = `[4, block]`

### Encoding Pattern in Zig
```zig
fn encodeChainSyncMsg(encoder: *Encoder, msg: ChainSyncMsg) void {
    switch (msg) {
        .request_next => {
            encoder.encodeArrayLen(1);
            encoder.encodeUint(0);
        },
        .roll_forward => |rf| {
            encoder.encodeArrayLen(3);
            encoder.encodeUint(2);
            encodeHeader(encoder, rf.header);
            encodeTip(encoder, rf.tip);
        },
        // ...
    }
}
```

---

## 6. Indefinite-Length List Pattern

Several protocol messages use indefinite-length CBOR lists:

```
// Start: 0x9f (major 4, additional 31)
// Elements: encoded normally
// End: 0xff (break code)

ChainSync MsgFindIntersect points:
  encoder.encodeArrayLenIndef();
  for (points) |point| encodePoint(encoder, point);
  encoder.encodeBreak();

TxSubmission2 MsgReplyTxIds, MsgRequestTxs, MsgReplyTxs:
  Same indefinite-length pattern
```

---

## Test Requirements

1. **Primitive round-trips:** Encode/decode every CBOR major type
2. **Known vectors:** Decode real Cardano blocks (extract from mainnet via Haskell node)
3. **Byte preservation:** Decode a block, re-extract raw CBOR for each field, verify hashes match
4. **Canonical encoding:** Encode script data, verify hash matches Haskell-computed hash
5. **Tag handling:** Encode/decode all Cardano-specific tags (#6.24, #6.30, #6.121-127, #6.102)
6. **Big integers:** Encode/decode values > 2^64
7. **Indefinite-length:** Encode/decode indefinite lists and maps
8. **Edge cases:** Empty arrays, empty maps, zero-length byte strings, nested tags
