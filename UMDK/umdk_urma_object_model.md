# URMA object model: EID, FE/VFE, jetty, TP — and the transport / order axes

_Last updated: 2026-05-06._

A consolidated reference for what URMA's objects are and how they relate, plus the two orthogonal axes (transport mode + order type) that constrain what each combination is allowed to do. Written to be the primer-level companion to the cache and warmup docs in this directory.

Companions:
- [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) — kernel ubcore-level cache analysis
- [`umdk_userspace_tp_cache_interface.md`](umdk_userspace_tp_cache_interface.md) — TLV wire format ↔ cache key
- [`umdk_ubse_peer_eid_discovery.md`](umdk_ubse_peer_eid_discovery.md) — where peer EIDs live
- [`umdk_udma_warmup_deployment.md`](umdk_udma_warmup_deployment.md) — deployment script for warmup peer EIDs

Source citations:
- User-space URMA: `git@atomgit.com:ray-yang0218/umdk.git` at `/Volumes/KernelDev/umdk/src/urma/lib/urma/core/include/`
- Kernel UB core: `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h`
- UBSE: `git@atomgit.com:ray-yang0218/ubs-engine.git`

---

## 1. Layered relationship

Bottom-up. Each layer addresses or contains the one above it.

```
   EID ───────────────────── 16-byte IPv6-style identifier (network address)
    │
    │ each FE/VFE owns one;
    │ a bonding device aggregates several into one bonding_eid
    ▼
 FE / VFE ──── physical or virtual UB port (HW endpoint)
    │
    │ 2× FE bond into one user-facing URMA device (urma0)
    │ multiple VFE share one physical FE (SR-IOV-style)
    ▼
URMA bonding device ─── what /dev/uburma* exposes; has bonding_eid
    │
    │ each device hosts many jettys, scoped by (uasid, id)
    ▼
 Jetty ──── user-facing endpoint object (analog of IB QP)
    │
    │ at least one TP underneath to carry traffic
    │ (1:1 in RC mode; many jettys share one TP in RM mode)
    ▼
  TP ─────── transport-pair state on the wire
             variants: RTP (reliable), CTP (connectionless reliable), UTP (unreliable)
             keyed on (local_eid, peer_eid, trans_mode, trans_type, ...)
```

## 2. Each object

### EID — Endpoint Identifier
Pure 16-byte address. From `urma_types.h`:
```c
union urma_eid {
    uint8_t raw[URMA_EID_SIZE];                                       /* network order */
    struct { uint64_t reserved; uint32_t prefix; uint32_t addr; } in4;
    struct { ... } in6;
};
```
Display form: IPv6-ish — `4245:4944:0000:0000:0000:0000:0100:0000`. Every higher object that needs identity carries one. The kernel-internal form is the same; UDMA endian-swaps with `udma_swap_endian` before sending on the ctrlq (`udma_ctrlq_tp.c:424`).

### FE — Front End (physical UB port)
Physical UB port on a chip — `pfe0`, `pfe1`. Carries traffic on the wire. Has its own `fe_eid`. From `ubse_mti_def.h`:
```c
PHYSICAL_TYPE = 0, // pfe0, 物理类型FE用于集群通信
```
Two FEs typically bond into one user-facing device for HA / multipath.

### VFE — Virtual Front End
Virtualized FE — SR-IOV-style. Multiple VFEs share one physical FE; each VM, container, or process can be assigned its own. From the same enum:
```c
VIRTUAL_TYPE = 1, // vfe1, 虚拟类型VFE
```
The newer `ubs_urma_dev_alloc` returns `vfe_path[UBS_VFE_PATH_NUM]`; the application sees the VFE paths, not the underlying pFE. IB analog: SR-IOV VF on an HCA.

### Bonding device (the "URMA device" the user opens)
Single character device wrapping two FEs/VFEs. Returned by `ubs_urma_dev_alloc` as:
```c
typedef struct {
    char bonding_path[UBS_MAX_URMA_PATH_LENGTH];                /* /dev/uburma... */
    char bonding_eid[UBS_MAX_URMA_PATH_LENGTH];                 /* user-facing EID */
    char fe_path[UBS_FE_PATH_NUM][UBS_MAX_URMA_PATH_LENGTH];    /* underlying FE/VFE */
} ubs_urma_dev_info_t;
```
This is what `urma_context_t.eid` refers to — the bonding EID, *not* an FE EID. `ubsectl display cluster`'s `bonding-eid` column shows this exact value.

### Jetty
User-facing endpoint object. IB QP analog for bidirectional; `jfs_id`/`jfr_id` for split-direction half-jettys. From `urma_types.h`:
```c
struct urma_jetty_id {
    urma_eid_t eid;     /* the URMA device's bonding_eid */
    uint32_t uasid;     /* User Address Space ID — process/container isolation */
    uint32_t id;        /* jetty number, unique within (eid, uasid) */
};
typedef struct urma_jetty_id urma_jfs_id_t;
typedef struct urma_jetty_id urma_jfr_id_t;
typedef struct urma_jetty_id urma_jfc_id_t;
```
Many jettys exist per URMA device: same `eid` + same `uasid`, differing `id`.

### TP — Transport Pair
The wire-level connection-state object. Keyed at the device level: `(local_eid, peer_eid, trans_mode, flag)`. `urma_get_tp_list` is the call that creates / fetches them; codex's `udma-tp-cache` wraps that path with a per-device cache.

The mapping from jetty → TP depends on transport mode (see §3).

### TP variants: RTP / CTP / UTP
Three sub-types of TP, encoded as bits in `union urma_tp_type_en` (`urma_types.h`):
```c
union urma_tp_type_en {
    struct {
        uint32_t rtp : 1;     /* Reliable Transport Pair */
        uint32_t ctp : 1;     /* Connectionless Transport Pair */
        uint32_t utp : 1;     /* Unreliable Transport Pair */
        uint32_t reserved : 29;
    } bs;
    uint32_t value;
};
typedef enum urma_tp_type { URMA_RTP, URMA_CTP, URMA_UTP } urma_tp_type_t;
```
Kernel mirror: `enum ubcore_tp_type { UBCORE_RTP, UBCORE_CTP, UBCORE_UTP }` at `ubcore_types.h:1495`.

| Variant | Reliable? | Connection model | Per-peer initiator state | Allowed `trans_mode` |
| --- | :-: | --- | --- | --- |
| **RTP** | ✅ | Connection-oriented (RC) or message-oriented (RM) | Dedicated state per remote endpoint | RM, RC |
| **CTP** | ✅ | **Connectionless** — destination per-WR | Shared / pooled across destinations | RM only |
| **UTP** | ❌ | Datagram (1-to-many) | Minimal | UM only |

CTP is the interesting one: same reliability as RTP, but no per-peer state on the initiator. One CTP serves many destinations. IB's closest analog is DC (Dynamically Connected), but URMA states "no per-peer initiator state" more strongly. Codex's warmup forces `trans_mode = URMA_TM_RM` whenever `flag.bs.ctp = 1` (`udma_tp_cache.c:733`) — RC connection semantics don't apply to CTP.

## 3. Transport modes (RM / RC / UM)

```c
typedef enum urma_transport_mode {
    URMA_TM_RM = 0x1,        /* Reliable Message */
    URMA_TM_RC = 0x1 << 1,   /* Reliable Connection */
    URMA_TM_UM = 0x1 << 2,   /* Unreliable Message */
} urma_transport_mode_t;
```

Reliable wire vs unreliable wire is the obvious axis. The less obvious one: **URMA decouples reliability from connection-orientation** — IB conflates them in RC. So URMA gets:

- **RC** (reliable + connection): IB RC analog. `urma_bind_jetty(local, remote)` ties one local jetty to **exactly one** remote. Per-peer dedicated TP. State cost O(N) for N peers.
- **RM** (reliable + connectionless): no IB equivalent. `urma_advise_jetty(local, remote)` lets one local jetty **address several** remotes. TP can be shared. State cost O(1) shareable.
- **UM** (unreliable + datagram): IB UD analog.
- (No UC — URMA dropped the unused unreliable-connection design point.)

Direct evidence in `urma_api.h`:
```
urma_advise_jetty: A local jetty can be advised with several remote jetties.
                   A connectionless jetty is free to call the advise API.
urma_bind_jetty:   A local jetty can be binded with only one remote jetty.
                   Only supported by jetty under URMA_TM_RC.
```

Direct evidence in `urma_perftest`'s `tp_reuse` short-circuit (`perftest_resources.c:1050`):
```c
if (cfg->tp_reuse && cfg->trans_mode == URMA_TM_RM && i > 0) {
    ctx->tp_info[i] = ctx->tp_info[0];   /* share TP across jettys — RM only */
    continue;
}
```
RC mode would fail this share — each jetty would need its own TP.

Other RM-only privileges: shared JFR (`shared.jfr->jfr_cfg.trans_mode != URMA_TM_RM` is rejected), out-of-order completion semantics, the `urma_advise_jetty` API surface itself.

For a code-level breakdown of every place RM and RC differ in the source — the per-WR destination addressing line, the API-surface partition, the object-composition restrictions, the bonding fast-paths — see [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md).

### Trans-mode × TP-variant legality

Cross-check the constraint at `urma_cp_api.c`:
```c
if ((trans_mode != URMA_TM_UM && tp_type == URMA_UTP) ||
    (trans_mode == URMA_TM_UM && tp_type == URMA_RTP))
    return -1;
```
So UTP requires UM, RTP cannot be UM. CTP is RM-only by separate constraint (codex enforces in warmup).

## 4. Order types

```c
typedef enum urma_order_type {
    URMA_DEF_ORDER,    /* default, auto-config by driver */
    URMA_OT,           /* target ordering */
    URMA_OI,           /* initiator ordering */
    URMA_OL,           /* low-layer ordering */
    URMA_NO            /* unreliable non-ordering */
} urma_order_type_t;
```
Kernel mirror: `enum ubcore_order_type { UBCORE_DEF_ORDER, UBCORE_OT, UBCORE_OI, UBCORE_OL, UBCORE_NO }`.

Two distinct levels of ordering exist:
1. **Local-completion order** — the order entries appear on the local CQ when polled.
2. **Remote-effect order** — the order writes/atomics become visible at the target.

| Mode | Local CQ order | Remote-effect order | Notes |
| --- | :-: | :-: | --- |
| **OT** (target) | yes | **yes** | Strongest. Receiver memory + receiver CQ see WRs in submission order. Classic IB-RC behavior. |
| **OI** (initiator) | **yes** | no | Sender CQ in order; remote may observe out-of-order. Multi-target reliable. |
| **OL** (low-layer) | partial | partial | Only the lowest HW layer preserves what's natural for it (per-flow / per-path). Multipath-friendly. |
| **NO** (none) | no | no | Datagram. UM only. |

Cross-check at `urma_cp_api.c`:
```c
if ((trans_mode != URMA_TM_RC && order_type == URMA_OT) ||
    (trans_mode != URMA_TM_RC && order_type == URMA_OL) ||
    (trans_mode != URMA_TM_RM && order_type == URMA_OI) ||
    (trans_mode == URMA_TM_RM && order_type == URMA_NO))
    return -1;
```

Decoded:
- **OT and OL require RC.** Both depend on receiver-side serialization, which only RC's per-peer connection state provides.
- **OI requires RM.** Initiator-only ordering is exactly the strongest guarantee RM can give across multiple peers.
- **NO requires UM.** Reliable transports are not allowed to silently drop ordering.

### When to pick what

- **OT / RC** — protocols that need release-style sync ("write payload, then write flag"). Most ports of IB-RC code want this.
- **OL / RC** — high-throughput streaming where target ordering is reconstructed at the application level (sequence numbers). Multipath-friendly.
- **OI / RM** — collectives, shuffle, KV-store. Local order is enough; the cross-peer step provides cross-peer ordering separately.
- **NO / UM** — telemetry, multicast-like, fire-and-forget.

`URMA_DEF_ORDER` (`flag.bs.order_type = 0`) lets the driver pick the strongest legal mode for your trans_mode (typically OT for RC, OI for RM, NO for UM).

## 5. Concrete 3-jetty example

A process opens `urma0` (bonding_eid `0x4245...0100...`), creates 3 jettys (id=1, 2, 3) under the same uasid, talks to a peer at `0x4245...0200...` in RM mode.

```
Local URMA device "urma0"     bonding_eid = 0x4245...0100...
  ├── pfe0  (fe1_eid = ...)   ┐
  └── pfe1  (fe2_eid = ...)   ├── bonded
                               │
                               │  exposes:
                               │   /dev/uburma_urma0
                               │   urma_context_t.eid = bonding_eid
                               │
        ┌─ jetty 1 ──┐
        ├─ jetty 2 ──┤── all live under (local_eid, uasid, id ∈ {1,2,3})
        └─ jetty 3 ──┘
              │
              │  RM + tp_reuse → all three share one TP
              ▼
           TP (RTP)  ── (local_eid = 0x4245...0100..., peer_eid = 0x4245...0200..., RM)

If they used CTP instead, the same single TP could also reach:
              0x4245...0200..., 0x4245...0300..., 0x4245...0400..., …
              (per-WR destination, no per-peer state)
```

In RC mode, each jetty would need its own TP (`tp_info[i]` allocated separately).

## 6. Why this matters for the codex `udma-tp-cache` work

The cache key in `udma_tp_cache.c` includes both `trans_mode` and a derived `trans_type` (the canonicalized RTP/CTP/UTP encoding) plus `pid_key` and the canonicalized `link_mode`:

```c
struct udma_tp_cache_key {
    u32 pid_key;
    u32 flag_value;
    u32 trans_mode;
    u32 trans_type;     /* canonicalized: CTP→TYPE_CTP, else from get_trans_type() */
    u32 link_mode;
    u8  local_eid[UDMA_EID_SIZE];
    u8  peer_eid[UDMA_EID_SIZE];
};
```

The TP variant matters for the key because the same `(local_eid, peer_eid, RM)` query produces a *different* TP-list depending on whether the caller asked for RTP-flagged or CTP-flagged TPs — they're different resource pools on the management side.

The trans-mode matters for cache hit rates:
- **RM lookups can correctly share results** across many local jettys talking to the same `(local_eid, peer_eid)` — because the same TP is reusable.
- **RC lookups are tied to specific jetty pairs** and cannot share — each `urma_get_tp_list` for a fresh RC binding is a fresh entry.

So workloads expected to benefit most from the cache are RM workloads with many jettys to the same peer — exactly what perftest's `--tp_reuse=1` already exploited manually for one mode. Codex's cache generalizes that win to all RM-mode applications and to RC repeats within a single jetty's lifecycle.

## 7. Comparison with IB / RDMA

| URMA | IB-verbs analog | Match quality |
| --- | --- | --- |
| **EID** | **GID** (Global Identifier) | exact — both 16 bytes, IPv6-style |
| **FE / pFE** | **HCA port** | exact |
| **VFE** | **SR-IOV VF on an HCA** | exact |
| **Bonding device** | **IB / RoCE bond** (`bond0` over `mlx5_0` + `mlx5_1`) | exact |
| **Jetty** | **QP (RC)** for bidi, or `ibv_qp send` + `ibv_srq` for split | URMA decouples send/recv (jfs/jfr) and re-couples as jetty |
| **`jetty_id` (eid, uasid, id)** | **(GID, qkey, QPN)**, with `uasid` replacing qkey for isolation | URMA uses uasid for process isolation; IB uses qkey for UD receive filtering |
| **TP** | (no separate object — IB conflates TP and QP) | URMA splits the connection-state out so multiple jettys can share one TP — what enables RM |
| **RTP** | the state machine inside an IB **RC QP** | exact (when used with URMA_TM_RC) |
| **CTP** | closest to **DC** (Mellanox Dynamically Connected) | conceptually similar; URMA's framing is stronger on "no per-peer initiator state" |
| **UTP** | the state inside an IB **UD QP** | exact |
| **URMA_TM_RC** | IB **RC** | exact |
| **URMA_TM_RM** | partial: closest to deprecated IB **RD** + XRC patterns | URMA RM is its own design; cleaner than anything that ever shipped widely in IB |
| **URMA_TM_UM** | IB **UD** | exact |
| (no URMA equivalent) | IB **UC** | URMA dropped UC as unused |
| **OT** | implicit guarantee of an IB **RC QP** | URMA makes it an explicit knob |
| **OI** | local CQ-order semantics (always there in IB) made explicit | URMA names it; IB doesn't expose a "remote can reorder" mode |
| **OL** | running RC over multipath/adaptive-routing fabric | IB doesn't have a verb to opt in; URMA does |
| **NO** | IB **UD** delivery semantics | exact |
| **`urma_token_id_t`** | **rkey** | URMA decouples token allocation from segment, enabling rotating-token-revocation (UB Spec §11.4.4) |
| **`urma_jetty_grp_t`** | (no IB analog) | multipath / LAG group, new in URMA |

URMA's design contributions, summarized:
- **TP as a first-class object** separate from jetty/QP.
- **Reliability orthogonal to connection-orientation** — gives RM as a real mode.
- **Order-type as an explicit programmer-visible knob** — performance trade-offs surfaced.
- **Token decoupled from segment** — rotating revocation possible.
- **uasid for process/container isolation** — replaces qkey-style filtering.

## 8. References

- `urma_types.h` — `union urma_eid`, `enum urma_transport_mode`, `union urma_tp_type_en`, `enum urma_order_type`, `struct urma_jetty_id`.
- `urma_api.h` — `urma_get_tp_list`, `urma_bind_jetty`, `urma_advise_jetty` (with the doc-comments quoted above).
- `urma_cp_api.c` — argument-validity cross-checks for `(trans_mode, tp_type)` and `(trans_mode, order_type)`.
- `ubcore_types.h:1495` — kernel-side mirror of the TP type enum.
- `udma_tp_cache.c:164-190` — how codex builds the cache key from the canonicalized fields.
- `urma_perftest/perftest_resources.c:1049-1053` — the `tp_reuse` short-circuit that demonstrates RM TP sharing.
- `ubse_mti_def.h` — `PHYSICAL_TYPE = pfe0`, `VIRTUAL_TYPE = vfe1` enum.
- `ubsectl_urma.md`, `libubse_urma.md` — bonding device + FE/VFE structure as exposed to users.
