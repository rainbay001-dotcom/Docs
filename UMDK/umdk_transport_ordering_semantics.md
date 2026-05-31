# UB transport ordering semantics: the three scopes, RM vs RC vs CTP

_Last updated: 2026-05-30._

Ordering in UB/URMA is the part most easily confused, because "ordering" is
asked at **three different scopes** that have different — sometimes opposite —
answers. This doc consolidates the full model across `trans_mode` (RM/RC) and
`tp_type` (RTP/CTP), and is the deep companion to
[`umdk_transport_modes_overview.md`](umdk_transport_modes_overview.md) §4.

Headline conclusion: **`tp_type` (RTP/CTP) is the reliability *mechanism* — how
reliably bytes move; `trans_mode` (RM/RC) is the *semantics* — what delivery
means.** Same RTP under RM and RC ⇒ identical wire plumbing, **different
application contract.** The contract that actually differs is the **cross-
transaction ordering at the target.**

---

## 1. Where ordering work happens — TP is *below* URMA

```
  Application / RPC  (URPC, UMQ, app)        ← consumes whole, ordered messages
  ─────────────────────────────────────
  Function layer:  URMA               §8    ← the API (jetty, JFS/JFR/JFC); references a TP by handle
  ─────────────────────────────────────
  Transaction layer                   §7    ← slicing/TASSN, NO/RO/SO, TCO, ROI/ROT/ROL/UNO, TAACK
  ─────────────────────────────────────
  Transport layer:  TP = RTP/CTP/UTP  §6    ★ PSN, OOO window, retransmit — REORDER/RETRANSMIT HAPPENS HERE
  ─────────────────────────────────────
  Network (NPI) → Data Link → Physical
```

The reorder/retransmit machinery is a **transport-layer (TP)** function and
executes in **hardware** (NPU transport engine / MUE). URMA only *sets up* the TP
(`active_tp_cfg` → ctrlq → MUE) and then holds it by `tp_handle`; it does not
reorder in software. Neither URMA nor the RPC layer above it touches loose
packets — they consume an already-reassembled, in-order stream. `ubcore_tp.c` /
`ubcore_vtp.c` / `ubcore_tpg.c` are URMA's *control-plane* TP management, not the
datapath reorder.

---

## 2. The three ordering scopes

| Scope | Ordered? | Mechanism | Differs by mode? |
|---|---|---|---|
| **A. Packets within a flow** | yes (reassembled) | PSN, TP layer (HW) | RTP recovers vs CTP relies on link |
| **B. Slices within one transaction** | **layout yes / temporal no** | TASSN + offset; atomic at TAACK | **no — same for all** |
| **C. Between transactions at target** | **RM no / RC yes** | order_type / service mode | **yes — the real divergence** |

---

## 3. Scope A — packets within a flow

- **RTP:** receiver EPSN window (in-order / out-of-order / duplicate / invalid
  regions; OOO window ∈ {128,256,512,1024,2048}, §6.4.1) **+ selective-retransmit
  BitMap** (§6.4.2.3). It *accepts* OOO packets and recovers gaps — which is what
  lets RTP spray one flow across paths (per-packet multipath).
- **CTP:** **no TP-layer ack/retransmit** (§6.3.2); relies on the lower data-link
  layer's point-to-point retransmit + in-order delivery. Keeps a flow on one path
  (multipath is *per-destination*, not per-packet spray), so no reorder arises.

Both deliver complete, correct data upward. RTP **recovers** from wire reorder;
CTP **avoids** it.

> Inference flag: that CTP forgoes the OOO-window machinery is a structural
> deduction from its documented "no TP-layer retransmit" (§6.3.2) — the spec does
> not spell out CTP receiver EPSN behavior. To confirm, read CTP's receive path in
> `udma_ctrlq_tp.c`.

---

## 4. Scope B — inside one transaction (atomic; same for ALL modes)

A transaction (one Write / Send / Read / Atomic) is the **atomic unit of
ordering**, regardless of RM/RC or RTP/CTP. "Order inside a transaction" splits:

- **Final data layout: correct.** Each slice carries its **offset** and **TASSN**
  (§7.3.1.1); reassembled and complete when **TAACK/CQE** fires. A sliced 1 MB
  Write ends up as exactly the right bytes.
- **Temporal order between slices: undefined.** Slices are independent, applied as
  they arrive — *that is why* RTP may spread them across TP channels (anti-HoL).
  No "first 64 KB before last 64 KB" guarantee.

Practical consequences (true for RM+RTP, RM+CTP, **and** RC+RTP):

1. **Don't poll an in-buffer byte to detect arrival.** Under multipath the slice
   carrying the last byte may land first. Use the **completion (CQE/TAACK)**.
2. **"X before Y" must be *separate* transactions** — you cannot get an internal
   order by packing them into one transaction. Then it becomes a Scope-C problem.

---

## 5. Scope C — between transactions at the target (the real divergence)

URMA order_type validation (`urma_cp_api.c:627`) — note RM and RC are nearly
complementary:

| order_type | meaning | RM | RC |
|---|---|:-:|:-:|
| `OI` (initiator) | initiator CQE in submission order; **target may reorder** | ✅ | ❌ |
| `OT` (target) | **receiver memory + receiver CQ in submission order** | ❌ | ✅ |
| `OL` (low-layer) | ordered by lower layer, multipath-friendly | ❌ | ✅ |
| `DEF_ORDER` | driver picks strongest legal | ✅ (→OI) | ✅ (→OT/OL) |

- **RM (RTP *or* CTP) = OI:** the target may apply/complete separate transactions
  out of submission order. **Nobody serializes the target — by design.** That is
  the cost paid for cheap scaling.
- **RC+RTP = OT/OL:** the **target serializes**, using its dedicated **per-
  connection Sequence Context (SC)**. Transaction N is visible before N+1.

**"Who reorders the target?"** — RM: nobody (intentionally). RC+OT: the **target**,
via per-connection SC (paid for with RC's O(N) per-peer state).

When you need an order under RM, it moves up and out: (1) you usually don't need
it (independent ops), (2) the **initiator serializes** (the meaning of OI — pace
op N+1 after op N completes), or (3) the **app sequences** it. CTP **cannot** even
escalate to OT (it is RM-only, never RC), so for CTP the only options are
initiator-serialize / app-sequence — or abandon CTP for RC+RTP.

---

## 6. The producer/consumer "flag" pattern — the concrete payoff of OT

Write payload (txn 1), then write a ready-flag (txn 2) as **separate transactions**:

| | result |
|---|---|
| **RM+RTP / RM+CTP (OI)** | ❌ unsafe — flag-txn may land before payload-txn; receiver can't trust the flag. Use completions or initiator-serialize. |
| **RC+RTP (OT)** | ✅ safe — target guarantees payload visible before flag; receiver may poll the flag. The canonical RDMA doorbell pattern. |

(The flag must be a *separate* transaction after the payload — Scope B means you
can't get this by polling a byte *inside* a single Write.)

### Why one-sided Write is hit hardest

The hazard is acute for **one-sided** ops because a one-sided Write **bypasses the
target CPU** — it lands in remote memory silently, with **no completion (CQE) at
the target.** The target's only way to learn the data arrived is to **poll its own
memory** for the flag — and that poll is correct only if the two Writes are
ordered. Under RM+RTP (OI) they are not, so the flag-Write can land first → target
reads `ready==1` → reads stale/partial payload → **silent data corruption** (no
error, no completion). Two scopes conspire: Scope B (intra-txn atomic) forces the
flag to be a *separate* transaction; Scope C (RM=OI) leaves it unordered. Only
RC+OT closes both.

**Two-sided Send/Recv barely cares:** a Send raises a **Recv-CQE at the target**,
so the target is in the software loop — it learns of arrival from the completion,
not from polling memory, and can sequence messages itself under OI. **Read/Atomic
are also less affected:** Read returns data to the *initiator* (who gets a
completion); Atomic is a single self-contained op.

| Workload | Mode |
|---|---|
| One-sided **Write + memory-flag signaling** (RDMA doorbell) | **RC+RTP+OT** — else latent corruption |
| Two-sided **Send/Recv** message passing | **RM+RTP** fine (target in the loop), keeps RM scaling |

Escape hatches if you must stay on RM for a one-sided Write: **don't use
memory-flag polling** — signal with a following **two-sided Send** (gives the
target a CQE), or **serialize at the initiator** (await the payload Write's
completion before issuing the flag, losing the overlap).

---

## 7. Retransmit & reliability — same contract, different guarantor

"Wire reliability is the same" is true as a **contract/class** (both RTP and CTP
are *reliable*, vs UTP unreliable), but the **guarantor** differs:

| | RTP | CTP |
|---|---|---|
| Reliable class? | ✅ | ✅ |
| Retransmit by | **the TP layer itself** (GoBackN / Selective, end-to-end) | **the lower data-link layer** (no TP-layer retransmit) |
| Holds on lossy / multi-hop fabric? | ✅ | ⚠️ only if the link layer is reliable (direct/low-loss) |

So CTP does not *lose* reliability — it **borrows** it from below. RTP **self-
recovers end-to-end** (works on any fabric); CTP's promise is only as good as its
link. Both still hand up a complete, correct transaction within their intended
deployments. Tell: IPoURMA falls back **CTP → UTP** (RM→UM, `ipourma_ub.c:115`),
*not* CTP → RTP — it would rather drop reliability than pay RTP's per-peer cost.

---

## 8. RM+RTP vs RM+CTP — ordering identical; mechanism + envelope differ

| | RM+RTP | RM+CTP |
|---|---|---|
| App-visible order (Scope C) | **OI** | **OI** — *same* |
| Target ordering | none | none — *same* |
| Escalate to target ordering | switch to RC+RTP | **impossible** (CTP ≠ RC) |
| Can go *more* unordered | no | **UNO** (≤1 MTU, UTP/CTP-only) |
| Scope-A reorder | recovers (OOO window) | avoids (in-order link) |
| Fabric | any (lossy/multi-hop ok) | low-loss/direct only |
| Max SEND | large | ≤ 4 KB |
| Peer scale | O(N), TPID wall ~4K | O(1) |

From the **user perspective** the difference is **not** ordering (identical) or
reliability (same contract) — it is **scale + fabric robustness + message size**.

---

## 9. RM+RTP vs RC+RTP — same RTP, different semantics

Same plumbing (PSN, retransmit, OOO reorder, intra-txn atomicity). Different
contract:

| Semantic | RM+RTP | RC+RTP |
|---|---|---|
| Connection model | connectionless, 1→N | connection-oriented, 1→1 |
| Destination | per-WR `wr->tjetty` | fixed at bind `sq->tjetty` |
| **Cross-txn target order** | **OI (none)** | **OT/OL (yes)** |
| Target serialized by | nobody | target Sequence Context |
| Flag pattern | unsafe | safe |
| API | `advise` (no-op on UB) | `urma_bind_jetty` |
| Composition | bare jfs / shared JFR / jetty_grp | paired jetty; none of those |
| CTP option | yes | no |

> **RTP determines how reliably bits move; RM/RC determines what delivery means.**
> RM+RTP and RC+RTP are not minor variants — they are one reliable transport
> carrying two different semantics, and the ordering guarantee at the target
> (OI vs OT) is the one that matters most.

---

## 10. The spec layer underneath (where these come from)

- **NO / RO / SO** — per-transaction *execution* markers (§7.3.2): no-order /
  relaxed (may run OOO but blocks later SO) / strong (waits for all prior).
- **TCO** — transaction completion order (§7.3.2.3): initiator-CQE and target-CQE
  each independently in-order or out-of-order.
- **Service modes** (§7.3.3) = *who enforces*: **ROI** (initiator), **ROT**
  (target, needs SC), **ROL** (lower layer), **UNO** (none, ≤1 MTU, UTP/CTP-only).
  These map onto the order_type column of §5 (OI↔ROI, OT↔ROT, OL↔ROL).

---

## 11. Decision guide

| Need | Use |
|---|---|
| Separate operations **ordered at the target** (doorbell/flag, in-order request processing) | **RC+RTP + OT** |
| Independent ops, **moderate peer count**, big messages or lossy fabric | **RM+RTP** |
| Independent ops, **many peers**, small reliable messages, good link | **RM+CTP** |
| Ordering needed but stuck on RM/CTP | serialize at initiator, or sequence in the app |

---

## Sources

- order_type validation — `urma_cp_api.c:627`; post-send addressing — `udma_u_jfs.c:849`; advise no-op — `urma_cp_api.c:2069`.
- Spec §6.3 (RTP/CTP/UTP), §6.4.1 (PSN/OOO window), §6.4.2.3 (selective retransmit), §7.3.1.1 (slicing/TASSN/TAACK), §7.3.2 (NO/RO/SO), §7.3.2.3 (TCO), §7.3.3 (ROI/ROT/ROL/UNO) — [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md).
- CTP RM-only — `udma_tp_cache.c:733`; IPoURMA CTP→UTP fallback — `ipourma_ub.c:109-115`.
- RM/RC code-level — [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md); TP lifecycle — [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md); per-connection memory cost — [`umdk_urma_tp_memory_cost.md`](umdk_urma_tp_memory_cost.md); two-axis overview — [`umdk_transport_modes_overview.md`](umdk_transport_modes_overview.md).
