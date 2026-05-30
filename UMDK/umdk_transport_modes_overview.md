# UB transport modes: the two axes (trans_mode × tp_type) and how they compose

_Last updated: 2026-05-30._

A URMA connection is described by **two orthogonal enums** that are constantly
conflated. This doc is the overview that ties them together; it cross-references
the deep docs rather than duplicating them.

- **`trans_mode`** — `enum ubcore_transport_mode` — the **jetty semantic**
  (reliability + connection model). Values **RM / RC / UM**. IB analogue: RD / RC
  / UD. Deep doc: [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md).
- **`tp_type`** — `enum ubcore_tp_type` — the **transport-path reliability
  flavor** (who provides reliability on the path). Values **RTP / CTP / UTP**.
  Deep doc: [`umdk_jetty_tp_binding_kernel.md`](umdk_jetty_tp_binding_kernel.md),
  spec §6.3 in [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md).

```c
/* /Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h */
enum ubcore_transport_mode {            /* :379 */
    UBCORE_TP_RM = 0x1,   /* Reliable message    */
    UBCORE_TP_RC = 0x1<<1,/* Reliable connection */
    UBCORE_TP_UM = 0x1<<2 /* Unreliable message  */
};
enum ubcore_tp_type { UBCORE_RTP, UBCORE_CTP, UBCORE_UTP }; /* :1495  (0,1,2) */
```

> Naming trap: **CTP = Compact Transport** (spec §6.3.2). The "control TP" gloss
> elsewhere only comes from ubmgr's keepalive *using* CTP — it is not what the C
> stands for.

| | governs | values | the question it answers |
|---|---|---|---|
| `trans_mode` | jetty API + addressing model | RM / RC / UM | "do I bind to one peer, or address many per-WR?" |
| `tp_type` | path reliability provider | RTP / CTP / UTP | "who guarantees delivery — TP layer, link layer, or nobody?" |

---

## 1. tp_type: RTP vs CTP vs UTP

Taking **TP = RTP** (Reliable Transport, the default).

**Essence:** RTP = full TP-layer reliability (PSN + ACK/NAK/SACK + retransmit),
exactly-once, multipath + congestion control. CTP = keeps a TP channel (PSN
context) but **delegates reliability to the link layer**; no TP-layer acks or
retransmit; minimal state; skips CM. UTP = connectionless, no reliability at all.

### 1a. Protocol semantics (spec §6.3 / §6.4 / §7)

| Dimension | **RTP** | **CTP** | **UTP** |
|---|---|---|---|
| Spec section | §6.3.1 p.159 | §6.3.2 p.160 | §6.3.3 p.160 |
| Reliability provided by | **TP layer** | **lower (data-link) layer** | **nobody** (best-effort) |
| Delivery guarantee | **exactly-once** | reliable iff link layer is; no TP dedup | at-most-once |
| Connection model | connection-oriented | connection-oriented but compact | **connectionless** |
| PSN (24-bit) | yes, full EPSN window | yes (tx/rx_psn programmed) | no |
| TP-layer ACK/NAK/SACK | TPACK + TPNAK + TPSACK | **none** | none |
| TP-layer retransmit | yes (GoBackN / Selective × fast/no-fast) | **no** | no |
| RTO machinery | yes (static or exp-backoff) | no (link layer owns it) | no |
| OOO receive window {128…2048} | **yes** — multipath enabler | n/a | n/a |
| Multipath LB | yes, per-TP-channel (§6.5.1) | coarse (§6.5.2) | no |
| Congestion control | full (§6.6.1, C-AQM) | coarse (§6.6.2) | none |
| Transaction slicing (§7.3.1.1) | slices spread across TP channels (anti-HoL) | one slice = one packet | one slice = one packet |
| TAACK piggyback | yes (`RTPH.RSPST`+`RSPINFO`) | limited; `No_TAACK=1` can skip | no acks |
| Allowed txn service modes (§7.3.3) | ROI/ROT/ROL | ROI/ROT/ROL **+ UNO** | **UNO only** (≤1 MTU) |
| Per-connection state cost | heavy | light | near-zero |

### 1b. Kernel realization (OLK-6.6 `drivers/ub/urma/`)

| Dimension | **RTP** | **CTP** | **UTP** |
|---|---|---|---|
| API entry | `urma_bind_jetty`→`ubcore_bind_jetty` (`ubcore_jetty.c:2758`) | `urma_bind_jetty_ex`→`ubcore_bind_jetty_ex` (`:2909`), or no-bind RM path | datapath posts |
| TP params from | **in-kernel CM** `ubcore_send_create_vtp_req` (UBCM/UBMAD) | **caller-supplied OOB** `ubcore_active_tp_cfg{tp_handle,tx_psn,rx_psn}` | n/a |
| vtpn allocator | `ubcore_connect_vtp` (`ubcore_vtp.c:1068`) | `ubcore_connect_rc_vtp_ctrlplane` (`:1353`) | — |
| HW program | inside CM completion | direct `ubcore_active_tp`→`udma_active_tp`→`udma_ctrlq_set_active_tp_ex` (`udma_ctrlq_tp.c:981`) | — |
| Peer round-trip on setup | **yes** | **no** | no |
| **Cold-start wall-clock** | **tens of ms** (CM RTT) | **< 1 ms** (activation only) | minimal |
| flag selector | `cfg.flag.bs.rtp=1` | `.ctp=1` | `.utp=1` |
| Typical users | classic perftest, ubsocket default | perftest `--ctp`, ubmgr keepalive, OOB-orchestrated | discovery, in-band conn bootstrap |

`udma_tp_cache.c:741` pre-warms one RTP + one CTP + one UTP per `(local_eid,
peer_eid)` — confirms the three are first-class siblings.

**Setup cost is the headline.** RTP `bind` = *bind + negotiate* (a CM REQ/RESP
round-trip, tens of ms — the UMDK#7 cold-start pain). CTP `bind_ex` = *activate
only* (caller already has the peer's `tp_handle` via OOB, e.g. perftest's OOB-TCP
`exchange_tp_info`) → one ctrlq message, sub-ms. This is the entire reason CTP
exists. See [`umdk_urma_perftest_ctp.md`](umdk_urma_perftest_ctp.md).

**Gotchas.** CTP reliability is *borrowed* from the link layer — don't deploy it
on a lossy multi-hop path expecting RTP semantics. UNO (unreliable, unordered
transaction mode) is **UTP/CTP-only**, ≤1 MTU — RTP is "too reliable" to host it.

---

## 2. trans_mode: RC vs RM

**Core insight:** URMA **decoupled reliability from connection-orientation** (IB
conflates them in RC). Both RM and RC are equally reliable on the wire; they
differ only in the **API model** and **where state lives**.

- **RC** = reliable wire + connection-oriented API. One jetty bound to **exactly
  one** remote. IB RC, almost verbatim.
- **RM** = reliable wire + connectionless, message-oriented API. One jetty
  addresses **many** remotes. "What IB never quite shipped" (deprecated RD / DC
  come closest).

**The smoking gun** — `udma_u_jfs.c:849` (post-send hot path):
```c
if (sq->trans_mode == URMA_TM_RC)
    tjetty = &sq->tjetty->urma_tjetty;   /* RC: destination fixed at bind time */
else
    tjetty = wr->tjetty;                  /* RM: destination per-WR */
```
That one branch makes RM 1-to-N and RC 1-to-1 at the wire-format level. WQE-fill
afterward is identical.

### 2a. Runtime differences

| Dimension | **RC** | **RM** |
|---|---|---|
| Per-WR destination | queue's bound peer (`sq->tjetty`); `wr->tjetty` ignored | `wr->tjetty`, per call |
| jetty ↔ remote cardinality | **1:1** dedicated | **1:N** |
| TP cardinality / sharing | dedicated 1:1 per pair | shareable across jettys (RTP) or peers (CTP) |
| `jetty->remote_jetty` | set after bind | always NULL |
| Allowed order types | `OT` (target), `OL` (low-layer) | `OI` (initiator) |
| Initiator state for N peers | **O(N)** | O(N) RTP, **O(1) CTP** |

### 2b. Object / API partitions

| | **RC** | **RM** | Source |
|---|:-:|:-:|---|
| Setup primitive | `urma_bind_jetty`/`_ex` | `urma_advise_jetty` (no-op on UB) | `urma_cp_api.c:1990 / 2060` |
| `unbind`/`flush`/`modify_state` | ✅ RC-only | ❌ | `urma_cp_api.c:2018/2167/2045` |
| `advise`/`advise_jfr` | ❌ | ✅ RM-only | `urma_cp_api.c:2060/2845` |
| Bare send-only `jfs` (no jfr) | rejected | allowed | `udma_u_jfs.c:258` |
| Shared JFR | ❌ | ✅ | `urma_cp_api.c:1560` |
| `jetty_grp` (multipath/LAG) | ❌ | ✅ RM-only | `udma_u_jetty.c:128` |
| TP variants | **RTP only** | **RTP or CTP** | `udma_tp_cache.c:733` |
| Bonding ACTIVE_BACKUP failover | migrate per-pair conn | **state-free** | `bondp_api.c:1545` |

**Scaling — why RM is the default.** RC's per-pair state is the classic IB
**O(N²M²)** pressure. RM's many-to-many jetty collapses it to **O(NM)** (Bojie Li
framing), and RM+CTP drops initiator state to **O(1)** (one shared connectionless
TP serves many peers). UMQ, IPoURMA, ubmgr-ping all use RM for this reason.

**What does NOT differ:** atomics, max sizes (sge/inline), congestion-control
algorithms, token/rkey semantics, segment registration, JFC/completion behavior,
EID format. Even the Send/Write/Read WQE format — only the `tjetty` source differs.

Full 9-axis breakdown: [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md);
cheat-sheet: [`umdk_urma_rm_vs_rc_summary.md`](umdk_urma_rm_vs_rc_summary.md).

---

## 3. How the two axes compose

The axes are orthogonal *in principle* but only four combinations are legal:

| trans_mode × tp_type | Valid? | What it is |
|---|:-:|---|
| **RC + RTP** | ✅ | IB-RC-equivalent: reliable, connected, target ordering, O(N) state |
| **RM + RTP** | ✅ | connectionless reliable, per-peer state, O(N) |
| **RM + CTP** | ✅ | connectionless reliable, **O(1)** state — the scale play |
| **UM + UTP** | ✅ | unreliable datagram |
| RC + CTP / UTP | ❌ | CTP/UTP aren't connection-oriented; CTP is RM-only by construction |
| RM + UTP | ❌ | UTP requires UM; RTP/CTP can't be UM |

Why CTP is RM-only: CTP's whole point — one TP, many destinations, no per-peer
state — contradicts RC's 1:1 binding. Enforced at `udma_tp_cache.c:733` (CTP
implicitly uses RM regardless of caller-supplied mode).

---

## 4. Ordering — how both axes touch the 3-layer model

Three independent ordering layers (full detail in
[`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §6.4.1, §7.3.2–7.3.3):

1. **Transport OOO window** (§6.4.1) — EPSN regions; window ∈ {128,256,512,1024,
   2048}; selective-retransmit BitMap. **Only RTP** participates → it is what lets
   packets spray across paths and reassemble.
2. **Transaction execution order** (§7.3.2) — per-transaction markers **NO / RO /
   SO** (no-order / relaxed / strong).
3. **Completion order (TCO)** (§7.3.2.3) — initiator-CQE and target-CQE each
   independently in-order or out-of-order.

Plus **service modes** (§7.3.3) = *who enforces*: **ROI** (initiator), **ROT**
(target), **ROL** (lower layer), **UNO** (none, ≤1 MTU, UTP/CTP-only).

trans_mode-level order types (`urma_cp_api.c:627`):

| Order type | Meaning | RC | RM |
|---|---|:-:|:-:|
| `OT` (target) | receiver memory **and** CQ in submission order | ✅ | ❌ |
| `OL` (low-layer) | best-effort, multipath-friendly | ✅ | ❌ |
| `OI` (initiator) | sender CQ in order; remote may reorder | ❌ | ✅ |
| `DEF_ORDER` | driver picks strongest legal | ✅ | ✅ |

**Key consequence:** "write payload, then write flag, receiver observes in that
order" needs **RC + OT**. RM cannot give target-side ordering (no per-peer
receiver state to serialize against) — relaxed/OOO delivery is RM's natural
habitat. "Send in order / receive out of order" = RTP (OOO window on) + NO markers
+ OOO TCO, typically ROT/ROL.

---

## 5. Consolidated decision guide

| Workload | trans_mode + tp_type |
|---|---|
| Long-lived high-throughput stream to **one** peer (shuffle, model-state sync) | **RC + RTP** (+ OT/OL ordering) |
| **Many** peers: collectives / KV-store / fan-out RPC | **RM + RTP** |
| **Very many** peers, reliability required (IPoURMA, ubmgr ping, broadcast) | **RM + CTP** (O(1) state) |
| Lowest setup latency on a low-loss / direct link, OOB-provisioned TP | **CTP** leg |
| Target-side ordering ("payload then flag") | **RC + OT** — RM can't |
| Fire-and-forget datagram / discovery | **UM + UTP** |

---

## Sources & companions

- `trans_mode` / `tp_type` enums — `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h:379, 1495` (verified 2026-05-30).
- Spec §6.3 (modes), §6.4 (PSN/retransmit), §7.3 (slicing, NO/RO/SO, TCO, ROI/ROT/ROL/UNO) — [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md), [`umdk_spec_survey.md`](umdk_spec_survey.md) §4.
- RTP/CTP kernel bind/activate — [`umdk_jetty_tp_binding_kernel.md`](umdk_jetty_tp_binding_kernel.md).
- RC/RM code-level (9 axes) — [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md); summary — [`umdk_urma_rm_vs_rc_summary.md`](umdk_urma_rm_vs_rc_summary.md).
- CTP cold-start measurements — [`umdk_urma_perftest_ctp.md`](umdk_urma_perftest_ctp.md).
