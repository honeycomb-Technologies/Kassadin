# Spec 03: Networking — Multiplexer & Mini-Protocols

## Overview

The Ouroboros network layer runs multiple typed state-machine protocols over a single TCP connection using a byte-level multiplexer. This spec defines the exact wire format, message encodings, and state machines.

---

## 1. Multiplexer (network-mux)

### SDU Wire Format (8 bytes, big-endian)
```
Byte 0-3: transmission_time (u32, microseconds, monotonic clock lower 32 bits)
Byte 4-5: protocol_info (u16)
           Bit 15: direction (0=Initiator, 1=Responder)
           Bits 14-0: mini_protocol_num (0-16383)
Byte 6-7: payload_length (u16, 0-65535)
Byte 8+:  payload (payload_length bytes)
```

### Zig Types
```zig
pub const MuxHeader = packed struct(u64) {
    transmission_time: u32,
    direction: u1,        // 1=initiator, 0=responder
    protocol_num: u15,
    payload_length: u16,
};

pub const MiniProtocolNum = enum(u15) {
    handshake = 0,
    chain_sync_n2n = 2,
    block_fetch = 3,
    tx_submission = 4,
    chain_sync_n2c = 5,
    local_tx_submission = 6,
    local_state_query = 7,
    keep_alive = 8,
    local_tx_monitor = 9,
    peer_sharing = 10,
};

pub const Direction = enum(u1) {
    initiator = 0,    // bit 15 clear on wire
    responder = 1,    // bit 15 set (ORed with 0x8000)
};
```

### SDU Constraints
| Bearer | Max SDU Size | Batch Size |
|--------|-------------|------------|
| TCP Socket | 12,288 bytes | 131,072 bytes |
| Unix Socket | 12,288 bytes | 131,072 bytes |
| Named Pipe (Windows) | 24,576 bytes | — |

### Ingress Buffer Sizes (N2N)
| Protocol | Buffer Size |
|----------|------------|
| Chain-Sync | 462,000 bytes |
| Block-Fetch | 230,686,940 bytes |
| Tx-Submission | 721,424 bytes |
| Keep-Alive | 1,408 bytes |
| Peer-Sharing | 5,760 bytes |

### N2C Ingress Buffer
4,294,967,295 bytes (effectively unlimited)

### Scheduling
- Round-robin egress across all active mini-protocols
- Each mini-protocol has a one-message buffer between protocol egress and mux ingress
- Protocol blocks when buffer is full (backpressure)

---

## 2. Handshake Protocol (Protocol Num 0)

### Purpose
Version negotiation. Runs before multiplexer is fully active. Each handshake message is a single MUX segment.

### State Machine
```
StPropose (Client) ──MsgProposeVersions──> StConfirm (Server)
StConfirm (Server) ──MsgAcceptVersion───> StDone
                   ──MsgRefuse──────────> StDone
```

### Messages (CBOR)
```
MsgProposeVersions = [0, {*version => version_data}]
  version: uint (e.g., 14, 15 for N2N)
  version_data: varies by version

MsgAcceptVersion = [1, version, version_data]

MsgRefuse = [2, reason]
  reason = [0, [*version]]           // VersionMismatch
         / [1, version, text]        // DecodeError
         / [2, version, text]        // Refused

MsgQueryReply = [3, {*version => version_data}]
```

### N2N Versions
- **v14:** initiatorOnlyDiffusionMode, peerSharing, query, PeerSharingV1
- **v15:** Same as v14 with updates

### N2N Version Data
```
version_data = [network_magic: u32, initiator_only: bool, peer_sharing: u8, query: bool]
// peer_sharing: 0=NoPeerSharing, 1=PeerSharingV1
// network_magic: 764824073 (mainnet), 2 (preview), 1 (preprod)
```

### N2C Versions: 16-21
```
version_data = network_magic: u32
```

---

## 3. Chain-Sync Protocol

### N2N: Protocol Num 2 (headers only)
### N2C: Protocol Num 5 (full blocks)

### State Machine
```
StIdle (Client agency)
  ├─ MsgRequestNext ──────> StNext(CanAwait) [Server]
  ├─ MsgFindIntersect ────> StIntersect [Server]
  └─ MsgDone ─────────────> StDone

StNext(CanAwait) [Server agency]
  ├─ MsgAwaitReply ────────> StNext(MustReply) [Server]
  ├─ MsgRollForward ──────> StIdle [Client]
  └─ MsgRollBackward ─────> StIdle [Client]

StNext(MustReply) [Server agency]
  ├─ MsgRollForward ──────> StIdle [Client]
  └─ MsgRollBackward ─────> StIdle [Client]

StIntersect [Server agency]
  ├─ MsgIntersectFound ───> StIdle [Client]
  └─ MsgIntersectNotFound > StIdle [Client]
```

### CBOR Message Encoding
```
MsgRequestNext       = [0]
MsgAwaitReply        = [1]
MsgRollForward       = [2, header_or_block, tip]
MsgRollBackward      = [3, point, tip]
MsgFindIntersect     = [4, [*point]]       // indefinite-length list
MsgIntersectFound    = [5, point, tip]
MsgIntersectNotFound = [6, tip]
MsgDone              = [7]
```

### Timeouts (N2N)
| State | Timeout |
|-------|---------|
| StIdle | 3673s |
| StCanAwait | 10s |
| StMustReply | 601-911s (random) |
| StIntersect | 10s |

### Size Limits (N2N)
All states: 65,535 bytes

---

## 4. Block-Fetch Protocol (Protocol Num 3)

### State Machine
```
BFIdle (Client agency)
  ├─ MsgRequestRange ─────> BFBusy [Server]
  └─ MsgClientDone ────────> BFDone

BFBusy [Server agency]
  ├─ MsgStartBatch ────────> BFStreaming [Server]
  └─ MsgNoBlocks ──────────> BFIdle [Client]

BFStreaming [Server agency]
  ├─ MsgBlock ─────────────> BFStreaming [Server]
  └─ MsgBatchDone ─────────> BFIdle [Client]
```

### CBOR Message Encoding
```
MsgRequestRange(from, to) = [0, from, to]   // from, to are Points
MsgClientDone             = [1]
MsgStartBatch             = [2]
MsgNoBlocks               = [3]
MsgBlock(block)           = [4, block]       // full serialized block
MsgBatchDone              = [5]
```

### Size Limits
| State | Max Size |
|-------|---------|
| BFIdle | 65,535 bytes |
| BFBusy | 65,535 bytes |
| BFStreaming | 2,500,000 bytes |

### Timeouts
| State | Timeout |
|-------|---------|
| BFBusy | 60s |
| BFStreaming | 60s |

---

## 5. Tx-Submission v2 Protocol (Protocol Num 4)

### State Machine
```
StInit (Client agency)
  └─ MsgInit ──────────────> StIdle [Server]

StIdle (Server agency)
  ├─ MsgRequestTxIds(blocking) ──> StTxIds(Blocking) [Client]
  ├─ MsgRequestTxIds(nonblocking) > StTxIds(NonBlocking) [Client]
  └─ MsgRequestTxs ────────> StTxs [Client]

StTxIds(Blocking) (Client agency)
  ├─ MsgReplyTxIds ────────> StIdle [Server]
  └─ MsgDone ──────────────> StDone

StTxIds(NonBlocking) (Client agency)
  └─ MsgReplyTxIds ────────> StIdle [Server]

StTxs (Client agency)
  └─ MsgReplyTxs ──────────> StIdle [Server]
```

### CBOR Message Encoding
```
MsgInit                              = [6]
MsgRequestTxIds(blocking, ack, req)  = [0, bool, u16, u16]
MsgReplyTxIds(ids)                   = [1, [*[txid, u32_size]]]  // indef list
MsgRequestTxs(ids)                   = [2, [*txid]]              // indef list
MsgReplyTxs(txs)                     = [3, [*tx]]                // indef list
MsgDone                              = [4]
```

### Flow Control
- Server (downstream) pulls TxIds from client (upstream)
- Acknowledge processed TxIds in FIFO order
- Max outstanding TxIds: configurable (default 10)
- Blocking request: must reply non-empty or MsgDone
- Non-blocking request: may reply empty

### Size Limits
| State | Max Size |
|-------|---------|
| StInit | 5,760 bytes |
| StIdle | 5,760 bytes |
| StTxIds | 2,500,000 bytes |
| StTxs | 2,500,000 bytes |

---

## 6. Keep-Alive Protocol (Protocol Num 8)

### State Machine
```
StClient (Client agency)
  ├─ MsgKeepAlive(cookie) ──> StServer [Server]
  └─ MsgDone ───────────────> StDone

StServer (Server agency)
  └─ MsgKeepAliveResponse(cookie) ──> StClient [Client]
```

### CBOR Message Encoding
```
MsgKeepAlive(cookie)         = [0, u16]
MsgKeepAliveResponse(cookie) = [1, u16]
MsgDone                      = [2]
```

### Rules
- Cookie in response MUST match request cookie (protocol error otherwise)
- StClient timeout: 97s
- StServer timeout: 60s

---

## 7. Peer-Sharing Protocol (Protocol Num 10)

### State Machine
```
StIdle (Client agency)
  ├─ MsgShareRequest(amount) ──> StBusy [Server]
  └─ MsgDone ──────────────────> StDone

StBusy (Server agency)
  └─ MsgSharePeers(peers) ────> StIdle [Client]
```

### CBOR Message Encoding
```
MsgShareRequest(n)  = [0, u8]               // request up to n peers
MsgSharePeers(addrs) = [1, [*peer_addr]]    // indef list
MsgDone             = [2]

peer_addr:
  IPv4 = [0, u32, u16]           // [tag, ip4_as_word32, port]
  IPv6 = [1, u32, u32, u32, u32, u16]  // [tag, 4x word32, port]
```

### Size Limit: 5,760 bytes all states
### Timeout: StBusy = 60s

---

## 8. Local Chain-Sync (Protocol Num 5)

Same state machine as N2N Chain-Sync but:
- Transfers **full blocks** instead of headers
- No size limits
- No timeouts
- Runs over Unix domain socket

---

## 9. Local Tx-Submission (Protocol Num 6)

### State Machine
```
StIdle (Client agency)
  ├─ MsgSubmitTx(tx) ──> StBusy [Server]
  └─ MsgDone ──────────> StDone

StBusy (Server agency)
  ├─ MsgAcceptTx ──────> StIdle [Client]
  └─ MsgRejectTx(reason) > StIdle [Client]
```

### CBOR Encoding
```
MsgSubmitTx(tx)     = [0, tx]
MsgAcceptTx         = [1]
MsgRejectTx(reason) = [2, reason]   // reason is era-specific
MsgDone             = [3]
```

---

## 10. Local State Query (Protocol Num 7)

### State Machine
```
StIdle (Client)
  ├─ MsgAcquire(target) ──> StAcquiring [Server]
  ├─ MsgDone ──────────────> StDone

StAcquiring [Server]
  ├─ MsgAcquired ──────────> StAcquired [Client]
  └─ MsgFailure(reason) ──> StIdle [Client]

StAcquired (Client)
  ├─ MsgQuery(query) ─────> StQuerying [Server]
  ├─ MsgReAcquire(target) > StAcquiring [Server]
  └─ MsgRelease ──────────> StIdle [Client]

StQuerying [Server]
  └─ MsgResult(result) ───> StAcquired [Client]
```

### CBOR Encoding
```
MsgAcquire(point)    = [0, point]   // specific point
                     / [8]          // immutable tip (v2+)
                     / [10]         // volatile tip (v3+)
MsgAcquired          = [1]
MsgFailure(reason)   = [2, reason]  // 0=PointTooOld, 1=PointNotOnChain
MsgQuery(query)      = [3, query]   // era-specific query
MsgResult(result)    = [4, result]  // era-specific result
MsgRelease           = [5]
MsgReAcquire(point)  = [6, point]
                     / [9]          // immutable tip (v2+)
                     / [11]         // volatile tip (v3+)
MsgDone              = [7]
```

---

## 11. Local Tx-Monitor (Protocol Num 9)

### State Machine
```
StIdle (Client)
  ├─ MsgAcquire ────────────> StAcquiring [Server]
  └─ MsgDone ───────────────> StDone

StAcquiring [Server]
  ├─ MsgAcquired(slot) ────> StAcquired [Client]
  └─ MsgAwaitAcquire ──────> StAcquiring [Server]  // wait for change

StAcquired (Client)
  ├─ MsgNextTx ────────────> StBusy(NextTx) [Server]
  ├─ MsgHasTx(txid) ───────> StBusy(HasTx) [Server]
  ├─ MsgGetSizes ──────────> StBusy(GetSizes) [Server]
  ├─ MsgGetMeasures ───────> StBusy(GetMeasures) [Server]  // v2+
  └─ MsgRelease ───────────> StIdle [Client]

StBusy(NextTx) [Server]
  └─ MsgReplyNextTx(tx?) ──> StAcquired [Client]

StBusy(HasTx) [Server]
  └─ MsgReplyHasTx(bool) ──> StAcquired [Client]

StBusy(GetSizes) [Server]
  └─ MsgReplyGetSizes(cap, size, count) ──> StAcquired [Client]

StBusy(GetMeasures) [Server]
  └─ MsgReplyGetMeasures(count, measures) ──> StAcquired [Client]
```

### CBOR Encoding
```
MsgDone                        = [0]
MsgAcquire / MsgAwaitAcquire   = [1]
MsgAcquired(slot)              = [2, u64]
MsgRelease                     = [3]
MsgNextTx                      = [5]
MsgReplyNextTx(null)           = [6]
MsgReplyNextTx(tx)             = [6, tx]
MsgHasTx(txid)                 = [7, txid]
MsgReplyHasTx(bool)            = [8, bool]
MsgGetSizes                    = [9]
MsgReplyGetSizes(cap,used,cnt) = [10, [u32, u32, u32]]
MsgGetMeasures                 = [11]
MsgReplyGetMeasures(n, m)      = [12, u32, {*text => [int, int]}]
```

---

## 12. Connection Manager (P2P Governor)

### Peer States
```
Cold → Warm → Hot (promotion)
Hot → Warm → Cold (demotion)
```

### Peer Targets (configurable)
```
target_root_peers: 60-100
target_known_peers: 100
target_established_peers: 50
target_active_peers: 20
```

### Peer Selection
1. Discover peers (topology file, peer-sharing, DNS)
2. Promote cold → warm (TCP connect, handshake)
3. Promote warm → hot (start mini-protocols)
4. Demote on: timeout, protocol error, too many hot peers
5. GC unused cold peers

---

## Test Requirements

1. **MUX:** Encode/decode SDU headers with known byte sequences
2. **Handshake:** Connect to a live preview relay, negotiate the current N2N version
3. **Chain-Sync:** Follow 100+ headers from a live preview relay
4. **Block-Fetch:** Download 100 real blocks, decode them
5. **Tx-Submission:** Exchange TxIds with a live reference node (empty mempool is fine)
6. **Keep-Alive:** Maintain connection for 5+ minutes with periodic pings
7. **Peer-Sharing:** Request and decode peer addresses
8. **State machine:** Verify every transition, reject invalid transitions
9. **All messages:** CBOR encoding matches byte-for-byte with Haskell output
