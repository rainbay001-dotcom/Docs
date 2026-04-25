# UnifiedBus 2.0 spec — deep readings of §6 / §7 / §10 / §11

_Last updated: 2026-04-25._

Targeted readings of the four chapters that the English preview only had ToCs for: **§6 Transport Layer**, **§7 Transaction Layer**, **§10 Resource Management**, **§11 Security**. Source: `~/Documents/docs/unifiedbus/UB-Base-Specification-2.0-zh.pdf` (518 pp, Chinese, release 2025-09; license: per Huawei "灵衢规范许可协议 V1.0").

> **Quote discipline.** All passages paraphrased; verbatim ≤15 words; no long paragraphs reproduced. Spec citations as `(§N.M p.P)`.

---

## 1. §6 Transport Layer — concrete protocol details

### 1.1 Three transport modes (§6.3)

**RTP — Reliable Transport** (§6.3.1 p. 159).

- Operates between Transport Endpoints (TPEPs).
- Provides **exactly-once** delivery to the transaction layer.
- Uses **PSN** (Packet Sequence Number) + retransmit (§6.4).
- TP Channel must be established between sender and receiver first (specific establishment protocol left to other specs).
- Three ack types: **TPACK** (positive), **TPNAK** (negative), **TPSACK** (selective).
- RTP supports **piggybacking transaction-layer responses** (TAACK, RNR, Page Fault) — response type encoded jointly by `RTPH.RSPST` + `RTPH.RSPINFO` fields. Useful for ROI/ROT/ROL modes.
- RTP supports per-TP-Channel multipath load balancing (§6.5.1) and congestion control (§6.6.1).
- One TP Channel can be **shared across different (Initiator, Target) pairs** for distinct transactions.

**CTP — Compact Transport** (§6.3.2 p. 160).

- Relies on lower layers (typically data link layer point-to-point retransmit) for reliability.
- **No TP-layer ack packets, no TP-layer retransmit.**
- Suited for direct-connect or low-loss link scenarios.
- Provides coarse congestion management (§6.5.2, §6.6.2).

**UTP — Unreliable Transport** (§6.3.3 p. 160). Connectionless, no ack, no retransmit.

### 1.2 PSN mechanism (§6.4.1 p. 160-162)

- **PSN width: 24 bits** — range 0 ~ 16M-1.
- **Send window**: max sendable PSN minus min unacked PSN ≤ **8M-1**.
- Receiver maintains **EPSN** (Expected PSN). Three regions:
  - In-order: PSN == EPSN → accept, increment EPSN.
  - Duplicate region: `[EPSN-8M, EPSN-1]` → drop.
  - Out-of-order region: `EPSN+1 .. EPSN+window`, window configurable from **{128, 256, 512, 1024, 2048}** → if enabled, accept; else drop.
  - Invalid region: rest → drop.
- **PSN init value**: random in `[0, 16M-1]` at TP-Channel establishment.
- TP-layer ack packets (TPACK / TPNAK) **don't consume PSN**.

### 1.3 Retransmission algorithms (§6.4.2 p. 162-164)

Two retransmit mechanisms × two trigger conditions = four algorithms; recommended use case (Table 6-7 p. 163):

| Algorithm | Suitable for | Loss rate |
|---|---|---|
| GoBackN + fast retransmit | Single-path TP (e.g. flow-LB) | Very low |
| GoBackN + no fast retransmit | Multi-path TP (per-pkt LB) | Very low |
| Selective + fast retransmit | Single-path TP | Low |
| Selective + no fast retransmit | Multi-path TP (per-pkt LB) | Low |

**Timeout retransmit must always be enabled** as the safety net; fast retransmit is optional.

### 1.4 RTO computation — exponential backoff (§6.4.2.1 p. 163-164)

Two RTO modes:

- **Static RTO**: configured at TP-Channel establishment from {512µs, 16ms, 128ms, 4s}.
- **Dynamic RTO** (exponential backoff): `RTO = Base_time × 2^(N×Times)`. `Base_time` ∈ [4 µs, 2,097,152 µs], usually set ~RTT. `N` is user-config; `Times` is current retry count.

Default backoff table (N=3, Base=20 µs, max retries=7) at Table 6-8 p. 164:

| Retry | Interval (µs) |
|---|---|
| 1 | 20 |
| 2 | 160 |
| 3 | 1,280 |
| 4 | 10,240 |
| 5 | 81,920 |
| 6 | 655,360 |
| 7 | 5,242,880 |

Three rationales given (§6.4.2.1 p. 164):

1. Small first interval enables fast tail-loss recovery (non-congestion case).
2. Larger later intervals avoid wasted bandwidth under congestion.
3. Reroute-induced reachability detection takes time; over-aggressive RTO would mis-judge a path as down.

Exceeding max retries → reports CQE error to transaction layer.

### 1.5 GoBackN + selective retransmission specifics (§6.4.2.2-3 pp. 164-178)

GoBackN (§6.4.2.2 p. 164): on TPNAK receive, sender retransmits all packets after the NAKed PSN. TPACK accumulates max in-order received PSN; TPNAK encodes EPSN.

Selective Retransmission (§6.4.2.3 p. 173-174): receiver maintains a BitMap of out-of-order received PSNs. TPSACK includes the BitMap (length = `SAETPH.BitMapSize`). Sender uses `MaxRcvPSN` (max received PSN seen in TPSACKs) to determine retransmit ranges. **MarkPSN mechanism** (§6.4.2.3.1 p. 175-178) optimizes non-first-loss retransmit by tracking "last new packet sent before each loss-retransmit phase" — avoids unnecessary duplicate retransmits in the per-packet load-balancing regime.

---

## 2. §7 Transaction Layer — services, ordering, types

### 2.1 Reliable transactions and slicing (§7.3.1.1 p. 213-214)

A reliable transaction = Initiator → Target → response (TAACK or read/atomic response).

**Transaction slicing** is first-class:

- One transaction can be split into multiple slices (each tagged with `TASSN`).
- **With RTP**: slices may be spread across different TP Channels to avoid HoL blocking; slice size configurable. Example: 1 MB Write split into multiple 64 KB slices.
- **With CTP / TP Bypass**: each slice corresponds to one packet.

**TAACK aggregation**: consecutive same-(Initiator, Target) TAACKs can be returned as one — `TAACKTASSN=N` with `ATAH.RSPST=3'b000` or `3'b101`, `ATAH.RSPINFO=9` means N..N+9 → 10 transaction responses acknowledged at once.

Special TAACK-piggybacking cases:

| Combination | What happens |
|---|---|
| RTP + ROL | TAACK can ride in TP-layer ack; no separate TAACK |
| RTP + ROI/ROT/ROL with target resource shortage | TA-status carried in TP-layer ack |
| CTP + ROL with `BTAH.No_TAACK=1` | Target skips TAACK return (only for very-reliable networks) |

**Reliability split:**

1. Lower layer guarantees lossless transport between Initiator and Target.
2. Transaction layer handles execution-side exceptions:
   - Recoverable (RNR, Page Fault): retransmit (Fig 7-17 p. 214).
   - Unrecoverable (memory length error, permission failure): pass to upper layer; transaction layer **does not retransmit**.

**Atomic special case** (§7.3.1.1 p. 215): cannot retransmit Atomic when Atomic Response generation throws RNR/Page Fault — would cause data inconsistency. But Atomic Request retransmit is safe (target hasn't yet executed). Example given in spec: Initiator sends `Atomic_fetch_add`, Target updates X 0→1 and returns 0 in Atomic Response, Page Fault occurs on response delivery. If Initiator retransmits, X becomes 2 and Initiator gets 1 — wrong. So Atomic is non-retransmittable on response-side fault.

### 2.2 Transaction execution order (§7.3.2 p. 215-216)

Three per-transaction ordering markers:

| Mark | Meaning |
|---|---|
| **NO** (No Order) | No ordering requirement; any order |
| **RO** (Relaxed Order) | Out-of-order OK, but blocks subsequent SO until completed |
| **SO** (Strong Order) | Must wait for all preceding RO/SO to complete before executing |

`Fence` and `Barrier` are implementation mechanisms (not spec-defined) that Initiator can use additionally.

Spec example (Table 7-13 p. 216): `[4:Read NO, 3:Write NO(FENCE), 2:Read NO, 1:Write SO, 0:Write RO]` — the Fence on transaction 3 blocks transaction 4's send (because 3 must wait for preceding Reads to complete and itself blocks 4 in the queue).

### 2.3 Transaction completion order (TCO) (§7.3.2.3 p. 217)

Send-completion order (Initiator-side CQE generation):

- **In-order**: CQE generation matches send order.
- **Out-of-order**: CQE order may not match send order.

Receive-completion order (Target-side CQE):

- **In-order**: CQE generation matches send order.
- **Out-of-order**: order independent.

When ordered Target completion is requested, the order marker rides in the transaction-layer header to Target.

### 2.4 Four transaction service modes (§7.3.3 pp. 217-222)

| Mode | Reliability | Ordering owned by | Key tradeoff |
|---|---|---|---|
| **ROI** | Yes | **Initiator** | Wait for prior responses before sending (one extra RTT) |
| **ROT** | Yes | **Target** | Save 1 RTT; needs SC (Sequence Context) resource on Target |
| **ROL** | Yes | **Lower layer** | Push ordering down to transport/network |
| **UNO** | No | None | Best effort; ≤ 1 MTU; UTP/CTP/TP-Bypass only |

ROT mode requires **SC (Sequence Context)** resource on Target. SC can be statically configured or dynamically allocated (§7.3.3.3 p. 219-220 + Fig 7-21):

```
Initiator sets BTAH.Alloc=1; Target allocates SCID=100, returns ATAH.SV=1, ATAH.INI_TASSN=100
Subsequent ops: BTAH.INI_RC_Type=SC, BTAH.INI_RC_ID=100 (the granted SCID)
Target responses: ATAH.INI_RC_ID=corresponding RCID
```

**Mode↔layer combination rules** (Tables 7-14 p. 221, 7-15 p. 222) for ordered vs unordered transactions, mapping to RTP/CTP/UTP × network LB × DL reliability requirements.

### 2.5 Transaction types (§7.4 pp. 222-239)

Four categories: memory transactions, message transactions, maintenance, management.

#### Memory transactions (§7.4.2)

| Sub-type | TAOpcode | Notes |
|---|---|---|
| **Write** | 0x3 | Slicing supported. With RTP, slice can be ≥1 packet; with CTP/TP-Bypass, slice = 1 packet. TAACK opcode 0x11. (Fig 7-23) |
| **Write_with_notify** | 0x5 | Write + notify on last packet. Notify written to a *different* address from Write. Different flows for ROI/ROT/ROL (Figs 7-24/25/26): ROI waits for all Write TAACKs before sending Notify; ROT can ship them together; ROL relies on lower-layer ordering. |
| **Write_with_be** | 0x14 | Write with Byte Enable (64/128/256/512/1024 bits) — byte-granular masking. Single packet. |
| **Writeback** | 0x17 | Write from local cache. Single packet. **Must execute non-blocking** to avoid deadlock with normal R/W. |
| **Writeback_with_be** | 0x18 | Same with BE. |
| **Read** | 0x6 | Slicing on **Request only**, not Response. Read Response = ATAH 0x12. Carries `TAIDETAH.TAID` + `OFSTETAH.Offset` for response routing. |
| **Atomic** | 0x7-0xF | 9 sub-types. All single-packet. Address must be naturally aligned. Operand sizes: 1/2/4/8/16/32/64 bytes. |

**Atomic sub-types** (Table 7-16 p. 231-232):

| TAOpcode | Sub-type | Behavior |
|---|---|---|
| 0x7 | `Atomic_compare_swap` | CAS — compare op1 with mem; swap to op2 if equal; return original |
| 0x8 | `Atomic_swap` | Swap op1 with mem; return original |
| 0x9 | `Atomic_store` | Compute then store, no return. UDETAH[23:20] sub-types: 0=ADD, 1=CLR(XOR), 2=EOR(NAND-style), 3=SET(OR), 4=SMAX, 5=SMIN, 6=UMAX, 7=UMIN |
| 0xA | `Atomic_load` | Same as store but returns pre-computation value |
| 0xB | `Atomic_fetch_add` | Mem += op1, return original |
| 0xC | `Atomic_fetch_sub` | Mem -= op1, return original |
| 0xD | `Atomic_fetch_and` | Mem &= op1, return original |
| 0xE | `Atomic_fetch_or` | Mem \|= op1, return original |
| 0xF | `Atomic_fetch_xor` | Mem ^= op1, return original |

Atomic supports ROI/ROT/ROL — but not UNO (atomicity needs reliability).

---

## 3. §10 Resource Management — UBFM, EID, UPI, interrupts

### 3.1 UBFM role (§10.1 p. 288)

UBFM = **UB Fabric Manager**. Owns UB Domain resources (interconnect, communication, compute). Identifies resources via **GUID**; schedules via **EID**. Multiple UBFM instances can split a large domain into Sub Domains; cooperation protocol left to implementation. Inside a single server, **UBFM duties may be borne by host system software** (§10.2.1 p. 289). Deployment must be reliable — but specific HA mechanism out of spec.

UB Controller required capabilities (§10.2.1 p. 289):

1. Accept UBFM management
2. Sync/async remote memory access + messaging
3. Network-layer routing
4. Resource pooling (memory pool, Entity pool)
5. Access isolation
6. Reset
7. Error handling
8. Interrupts
9. Virtualization
10. Vendor-defined functions

### 3.2 Configuration management model (§10.2.2 p. 290-291)

UB Controller and UB Switch share the same model: **Entity + Port** composition.

- Up to **65,536 Entities** per controller/switch (Entity 0 mandatory).
- Up to **16,384 Ports** (Port 0 mandatory).
- Each Entity has CFG0 / CFG1 spaces + up to 3 Resource Space segments.
- Entity 0 additionally holds CFG0_PORT_BASIC, CFG0_PORT_CAP, CFG0_ROUTE_TABLE.
- GUID assigned at production; Class Code describes function; EID assigned before use.

### 3.3 MUE — Management UB Entity (§10.2.3 p. 291) — KEY FINDING

> "MUE provides shared resources (TP Channels, etc.) for other Entities in its UBPU and provides their management interface." (§10.2.3 paraphrased)

This **resolves the `udma_mue.{c,h}` question definitively**. UE in udma_mue refers to **UB Entity** (the spec abstraction); MUE = **Management UB Entity** is the special leading Entity in each UBPU that holds shared TP Channel resources for the other Entities in the same UBPU. So `udma_mue` is the kernel side of MUE-to-managed-Entity communication: TP channel attribute get/set, activate/deactivate.

The earlier code-followup said "User Engine" which was an educated guess from message flow names — **the spec name is "Management UB Entity"** and "UE = (managed) UB Entity". In virtualization, MUE provides Jetty contexts as managed resources, reducing VM attack surface (§10.2.3 p. 291).

### 3.4 EID format — 128-bit total, 20-bit short form (§10.3.1 p. 291-292)

**EID is a 128-bit identifier** in a single ID address space:

```
[ Prefix (108 bits) ] [ Sub ID (20 bits) ] = 128-bit EID total
                       └─ also used as 20-bit short EID
```

- System administrator plans EID prefix per UB Domain.
- One UB Domain occupies one prefix's Sub ID address space.
- **Sub ID 0 is protocol-reserved** — must not be assigned.
- Packets can carry full 128-bit EID, **20-bit short-form EID**, or implicit (no EID).
- An Entity can have multiple network addresses (multi-port aggregation); EID binds to network address at topology location and rebinds on migration.

**Significance:** the 20-bit short form is what UMDK/userspace operates with most often (matches `urma_eid_t` in `umdk/src/urma/lib/uvs/core/uvs_types.h`). The 128-bit form is the canonical representation; software typically truncates to 20 bits inside a known prefix.

### 3.5 UB Partition (UPI) — Entity isolation (§10.3.2 p. 292)

UPI = UB Partition Identifier. Rules:

1. UPI supports trusted config + anti-spoof.
2. Default UPI = 0.
3. **Entities with UPI=0 cannot communicate with other Entities** — UPI=0 is reserved.
4. Sender attaches UPI; receiver checks; mismatch → drop.
5. UPI supports 15-bit and 24-bit lengths.

This is the spec-level partitioning that the earlier comparison doc mentions vs IB's P_Keys — but UPI is more flexible (15- or 24-bit) and managed by UBFM.

### 3.6 Function calls — three patterns (§10.3.3 p. 293-294)

1. **MMIO-based**: Entity a's resource space mmap'd into UBPU MMIO space. Processor R/W to MMIO invokes Entity a's functions. Authorized Entity b can DMA into Entity a's resource space.
2. **Message-based**: UBPU sends commands to Entity via UB Controller messaging interface.
3. **URPC**: When UB Controller supports URPC, function invocation goes through URPC.

### 3.7 USI — UB Signaled Interrupt (§10.3.4 p. 294-298)

**USI = UB-native MSI**. Uses Write-class transaction semantics. USI message has 4-byte Interrupt ID + 4-byte Interrupt Data (Fig 10-12 p. 298).

**Two interrupt register types**:

- **Type 1** (Table 10-1 p. 295): 8 register fields — Enable, Number, Enable Number, Data, Address, ID, Mask, Pending. Up to 32 vectors.
- **Type 2** (Table 10-2 p. 296): 4 capability registers + 3 indirection tables (Vector Table, Address Table, Pending Table). Address-table entries carry DEID + TokenID. More flexible — different vectors can share the same address; many more vectors possible.

`CFG1_CAP` Bitmap indicates which type (or both) the Entity supports.

### 3.8 Local + remote event notification (§10.3.5 p. 299-300)

Local notification through three queues:

- **Completion Queue** — Class A errors (transaction-specific exception).
- **Event Queue** — Class B errors when no corresponding CQ.
- **Error Message Queue** — Class C errors; reported by Entity 0 only.

Remote notification:

- **Inline Error**: response Status field carries error info; or `BTAH.Poison` flag marks data as poisoned (must not be treated as normal data on arrival).
- **Error Message**: Entity 0 sends to UBFM for Class C errors.

### 3.9 Configuration space slices (§10.4.1.3 p. 302-304)

Config space divided into **Slices** (Header + Body). Slice address space = 1 KB (most) or 1 GB (`CFG0_ROUTE_TABLE` only).

Concrete slice taxonomy (Table 10-6 p. 303-304):

```
CFG0_BASIC                                  0x0000_0000 - 0x0000_00FF
CFG0_CAP1..N                                0x0000_0100 - 0x0000_FFFF
   CFG0_CAP1_RSVD, CFG0_CAP2_SHP, CFG0_CAP3_DEVICE_ERR_RECORD,
   CFG0_CAP4_DEVICE_ERR_INFO, CFG0_CAP5_EMQ, ...
CFG1_BASIC                                  0x0001_0000 - 0x0001_00FF
CFG1_CAP1..N                                0x0001_0100 - 0x0001_FFFF
   CFG1_CAP1_DECODER, CFG1_CAP2_JETTY, CFG1_CAP3_INT_TYPE1,
   CFG1_CAP4_INT_TYPE2, CFG1_CAP5_RSVD, CFG1_CAP6_UB_MEM, ...
CFG0_PORT0_BASIC                            0x0002_0000 - 0x0002_00FF
CFG0_PORT0_CAP1..N                          0x0002_0100 - 0x0002_FFFF
   PORT_CAP1_LINK, _LOG, DATA_RATE1-9, EYE_MONITOR, QDLWS,
   SRIS, LINK_PERF, LINK_ERR_INJECTION, LTSM_ST, PORT_ERR_RECORD, ...
CFG0_PORT1_BASIC                            0x0003_0000 - ...
...
CFG0_ROUTE_TABLE                            0xF000_0000 - 0xFFFF_FFFF
```

**Register attributes** (Table 10-7 p. 305):

- `RO`, `RW`, `RW1C` (write-1-to-clear)
- `HwInit` (HW-initialized; read-only after boot; reset only on device reset)
- `ROS`, `RWS`, `RW1CS` — sticky variants (only device-level reset clears)
- `*_DE0_EO` — register has property * in Entity 0 only; doesn't exist elsewhere
- `*_DEN_RO` — has property * in Entity 0; RO in other Entities

### 3.10 Resource Space (§10.4.2 p. 306)

Each Entity has up to **3 Resource Space segments** (ERS0/ERS1/ERS2) configured via CFG1_BASIC's ERS register group.

For Type 2 interrupts, Resource Space 0 holds the Vector Table + Address Table + Pending Table directly (Fig 10-19 p. 306). Resource Space 1/2 are vendor-defined.

User maps Resource Space into MMIO via packets bearing `LPH.CFG=6`; UPI is checked on each access.

---

## 4. §11 Security — token rotation, CIP, TEE

### 4.1 Trust model and threats (§11.1 pp. 343-344)

**Assets to protect**: UBPU device identity + firmware + sw; memory data; bus-transmit data; sensitive material (keys, credentials, config).

**Assumptions**:

- UBPU is in a physically secure machine room (no physical attack).
- UBFM is trusted; admin operations are reliable.
- DoS / resource-exhaustion / UB Switch hijacking are **out of scope**.

**Threats addressed**:

| Threat | Mitigation |
|---|---|
| UBPU spoofing / firmware tamper / replacement | Device authentication |
| Unauthorized memory or Jetty data access | Resource partitioning + Access control |
| Packet eavesdrop / tamper / inject / replay / forge | Data path protection (CIP) |
| TEE-internal or inter-TEE comm-data unauthorized access | TEE extension |

### 4.2 Device authentication (§11.2 pp. 345-346)

Three flow flavors:

1. **UBFM directly authenticates UBPU** — challenge for digital cert; verify cert chain.
2. **Measured-boot + verification server** — UBPU generates measurement at boot; UBFM challenges + gets signed measurement digest; if matches an already-verified report, fast path; else fetches full report and submits to verification server. UBFM issues UBFM-signed credential on success. Steps in Fig 11-1 reference DSP0274 SPDM.
3. **Admin-asserted** — admin determines identity + trust state; registers in UBFM; UBFM issues credential.

UBFM can also generate cluster-level measurement reports (multiple UBFMs combine sub-cluster reports) for fast batch verification.

### 4.3 **Token rotation — §11.4.4 (THE MECHANISM)**

This is the spec section the earlier docs kept referring to without being able to read. Here it is in detail.

Two granularities of permission invalidation (§11.4.4 pp. 348-350):

**(a) Permission-group invalidation** — Home initiates. Home-side UMMU invalidates a TokenID and its corresponding TokenValue. **All Users** holding that TokenID/TokenValue lose access.

**(b) User-granularity invalidation** — Home wants to revoke *one* User's access while keeping the rest valid. User-initiated allocation, Home-driven rotation:

1. Multiple Users hold Home1's `(TokenID1, A-TokenValue)`.
2. Home1 generates a **B-TokenValue**; sends it only to Users still authorized (User2, User3 in the example); **does not send to revoked User1**. Transition window: Home1's permission-table holds both A-TokenValue (primary) and B-TokenValue (backup).
3. After transition, Home1 promotes B to primary; generates **C-TokenValue** as new backup. A-based access now fails → User1 is invalidated; User2 and User3 keep working with B.

Worked timeline (Fig 11-2 p. 349):

```
t1:  All three Users have A-TokenValue.
     Home1 perm-table: (TokenID1, A-TokenValue)

t2:  Home1 sends B-TokenValue to User2, User3 (NOT User1).
     Home1 perm-table: (TokenID1, B-TokenValue primary; A-TokenValue backup)
     Both A and B accepted during transition.

t3:  Home1 promotes B to primary, generates C as new backup.
     Home1 perm-table: (TokenID1, C-TokenValue backup; B-TokenValue primary)
     A-based access fails → User1 revoked.
```

This is what enables token-rotation revocation **without re-registering memory** — the spec primitive that several earlier docs cited as a URMA-vs-IB-verbs differentiator.

### 4.4 Access-control strategy choice (§11.4.3 p. 348)

Four operating points trading security vs perf:

| Strategy | Security | Cost |
|---|---|---|
| TokenID/TCID only (no TokenValue) | Lowest — relies on access-pattern obscurity | Highest perf |
| TokenID + TokenValue plaintext | Mid — mid-node can sniff TokenValue | Cheap |
| TokenID + TokenValue encrypted, PLD plaintext | Higher — TokenValue protected, PLD visible | Modest crypto cost |
| Both encrypted | Highest | HW overhead |

Notes (§11.4.2 p. 348):

- TokenValue can be true-random (HW RNG on UBPU) or pseudo-random.
- Home reboot → must immediately update TokenValue to invalidate stale credentials.
- Multiple Users with same `(TokenID, TokenValue)` → multi-User memory sharing; can be propagated by one User to others.

### 4.5 CIP — Confidentiality and Integrity Protection (§11.5 pp. 350-353)

For untrusted data path. Provides **end-to-end transaction-packet encryption + integrity** between source and destination Entity (not beyond — UBPU-internal data protected by UBPU itself).

**Channel establishment** — two flavors:

- **Centralized** (Fig 11-3 p. 351): UBFM authenticates each Entity → handshake → secure session → distributes CIP keys to TX + RX directions.
- **Distributed** (Fig 11-4 p. 352): Entities authenticate each other → handshake → session → exchange keys.

Steps 1-4 reference **DSP0274 SPDM**.

**Crypto parameters** (§11.5.2.2 p. 352):

- Algorithms: **AES-GCM** (per NIST SP 800-38D) **or SM4-GCM** (per GM/T 0002-2012, the Chinese national crypto standard SM4).
- AAD = CIP header + UPI + parts of transaction header.
- Plaintext = transaction-header sensitive fields + PLD.
- IV = 96-bit random.

**CIP extension header** (§11.5.2.3 p. 352):

- **CIP ID** — index into local CIP policies (per (DEID, EID-pair)). Receiver indexes by DEID into a policy table.
- **SN** — sequence number for replay protection.
- **NLP** (4 bits) — next-layer indicator. 0000 = full headers (32-bit UPI + 128-bit S/DEID); 0001 = compact (16-bit UPI + 20-bit S/DEID); 0010 = no headers.
- **RSVD**.

**ICV** — Integrity Check Value at packet end. 96 bits for AES-256-GCM and SM4-128-GCM (low 96 bits of the GMAC). Receiver buffers transaction packet until ICV verified, then releases. ICV mismatch → drop + recommend halting the requesting operation.

**Key update** (§11.5.2.6 p. 354): keys have lifetime; UBFM-config or peer-negotiated rotation.

### 4.6 TEE extension (§11.6 pp. 354-361)

Extending TEE from single-processor to **cross-UBPU** trusted compute clusters.

**Components** (Fig 11-5 p. 355):

| Component | Role |
|---|---|
| **UTEI** (User TEE Entity Instance) | TEE-protected Entity on User side; can be a TEE VM, TEE process, or whole TEE. Initiates TEE-extension requests. |
| **HTEI** (Home TEE Entity Instance) | Symmetric to UTEI on Home side. Responds to UTEI requests. |
| **UTM** (User TEE Manager) | TCB on User side; manages keys, certs, measurements, security policies. Interfaces to UBFM. |
| **HTM** (Home TEE Manager) | TCB on Home side. Symmetric. |
| **Trusted Extension Component** | Part of UB Controller + UMMU implementing TEE + EE_bits security. **Even UTM/HTM cannot bypass** this. |
| **UBFM** | Manages security state for all Entities. |
| **OS / Normal EI** | Non-TEE OS, non-TEE Entities. |

**Two operating modes**:

- **Basic mode**: assumes no physical attack. UBFM + UTM + HTM cooperate to set policy on Trusted Extension Components; UB packets get policy-based access control. Trusted measurement validates UTEI/HTEI state.
- **Enhanced mode**: assumes physical attacks (tamper / replace UBPU or UB Switch). Adds CIP for UTEI↔HTEI traffic.

**EE_bits in transactions** (§7.2.1 referenced; §11.6.4 p. 359):

- Up to **2 bits** of EE_bits per packet → up to **4 address spaces**: 1 non-TEE, 1 TEE, 2 reserved.
- UB address space splits into TEE-UBAS and Non-TEE-UBAS based on EE_bits. Same UB address can be either TEE or non-TEE depending on EE_bits.
- User attaches EE_bits on send; Home selects UMMU page table per EE_bits on receive.

**Configuration flow** (§11.6.5 p. 360 Fig 11-8): resource config → UTEI/HTEI creation (with optional CIP keys for enhanced mode) → measurement challenge to TEE → submit to verification server → start business flow.

---

## 5. Cross-corrections to earlier docs

These spec readings refine or correct several earlier docs:

### 5.1 To `umdk_code_followups.md` Q1 (UDMA MUE)

The agent expanded UE = "User Engine" (microcontroller). The **spec name is "Management UB Entity"** (`MUE` = the leading Entity per UBPU that owns shared TP-channel resources). UE = "(managed) UB Entity" in spec terms. Both readings co-exist: at the chip level a microcontroller may implement the MUE role; in spec/protocol terms the relationship is between Entities.

### 5.2 To `umdk_vs_ib_rdma_ethernet.md` §1.2 / §2.2

The "URMA token can be rotated independently of segment" claim now has a **direct spec citation** (§11.4.4 pp. 348-350) describing the exact two-granularity rotation protocol with the worked Fig 11-2 timeline.

### 5.3 To `umdk_spec_survey.md` §11

Open question about **CIP, EE_bits, partitions** is largely answered: §11.4 access control + §11.5 CIP + §11.6 TEE all read in detail above.

### 5.4 To the broader doc set

The 2023 essay's "(Entity ID, UASID, offset)" vs current spec's UBMD `(EID, TokenID, UBA)` rename is **confirmed in the 2025 spec** — UASID was renamed to TokenID, and the overall format is now part of UBMD.

---

## 6. Open questions remaining after this read

1. **§5 Network Layer** — not read in this round. NPI definition + check rules at §5.3.3.1 referenced from §11.3.2.
2. **§6.5 Multipath load balancing** + **§6.6 Congestion control** — not read; these explain C-AQM (referenced in Bojie Li 2023 talk).
3. **§8 Function Layer** (URMA + URPC + Multi-Entity Coordination + Entity Management) — not read; would clarify the API surface from spec side.
4. **§9 Memory Management** in detail — UMMU functions (§9.4) and UB Decoder (§9.5).
5. **§10.5 Virtualization** + **§10.6 RAS** — not read.
6. **Appendix B Packet Formats** + **Appendix D Configuration Space Registers** — bit-level layout reference; useful for HW-side dives but a lot of pages.
7. **Appendix G Hot-Plug** — needed for the hot-remove atomicity question in earlier docs.
8. **Appendix H URPC Message Format** — would deepen the URPC doc.

---

## 7. What changed in our understanding

| Area | Before | After this read |
|---|---|---|
| Token rotation | Concept named, mechanism opaque | Full two-granularity protocol with worked example |
| UE expansion | "User Engine" (educated guess) | "(managed) UB Entity"; MUE = Management UB Entity |
| EID format | "16-byte EID" generic | 128-bit total = 108-bit Prefix + 20-bit Sub ID; 20-bit short-form on wire |
| CIP details | Existed, no specifics | AES-GCM / SM4-GCM, 96-bit ICV, key rotation, SPDM-aligned setup |
| TEE | EE_bits + cross-device | Full UTEI/HTEI/UTM/HTM model + 2-bit EE_bits → 4 address spaces |
| RTO defaults | Unknown | Static {512µs, 16ms, 128ms, 4s}; dynamic exp-backoff with Base=20µs default |
| PSN width | Unknown | 24 bits, 8M-1 send window, OOO window {128..2048} configurable |
| Atomic ops | Knew "ATOMIC" verb existed | 9 sub-types: CAS, swap, store, load, fetch_{add,sub,and,or,xor}; 1/2/4/8/16/32/64 byte alignment |
| UBFM scope | "Logical fabric manager" | Multi-instance (Sub Domain partitioning), can be host system software in single server |
| MUE role | Mystery (`udma_mue` files) | Spec-defined: per-UBPU shared-resource owner, useful in virtualization to reduce VM attack surface |
| §11.4.4 | Cited but unread | Read in full — this is the rotating token revocation source of truth |

---

_Companion: [`umdk_spec_survey.md`](umdk_spec_survey.md), [`umdk_academic_papers.md`](umdk_academic_papers.md), [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md), [`umdk_code_followups.md`](umdk_code_followups.md)._
