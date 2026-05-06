# RM vs RC: quick summary

_Last updated: 2026-05-06._

A tight cheat-sheet on URMA's two reliable transport modes. For full code-level breakdown with file:line citations across 9 axes, see [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md).

---

## The core insight

URMA **decoupled reliability from connection-orientation** — IB conflates them in RC. Both RM and RC are reliable on the wire; the difference is the API model.

- **RC (Reliable Connection)** = reliable wire + connection-oriented API. One local jetty bound to **exactly one** remote. IB RC analog.
- **RM (Reliable Message)** = reliable wire + connectionless message-oriented API. One local jetty addresses **many** remotes. No clean IB analog (deprecated RD or Mellanox DC come closest).

Both deliver reliably (acks, retransmit, ordered within a message). They diverge on what state lives where and how you address destinations.

## Differences at runtime

| | RC | RM |
| --- | --- | --- |
| Local jetty ↔ remote jetty cardinality | **1:1** | **1:N** |
| Setup primitive | `urma_bind_jetty(local, remote)` | `urma_advise_jetty(local, remote)` (no-op on UB) |
| Per-WR destination | from queue's bound peer (`sq->tjetty`) | from `wr->tjetty` (per-call) |
| TP under the jetty | dedicated 1:1 per-peer | shareable across many jettys (RTP) or shared across many peers (CTP) |
| `jetty->remote_jetty` pointer | set | always NULL |
| Order types allowed | `URMA_OT` (target order), `URMA_OL` (low-layer) | `URMA_OI` (initiator order) |
| Initiator state cost for N peers | O(N) | O(N) for RTP, **O(1) for CTP** |

## The smoking gun

`udma_u_jfs.c:849` (post-send hot path):
```c
if (sq->trans_mode == URMA_TM_RC)
    tjetty = &sq->tjetty->urma_tjetty;   /* fixed at bind time */
else
    tjetty = wr->tjetty;                  /* per-WR */
```
That single line is what makes RM 1-to-N and RC 1-to-1 at the wire-format level.

## Object-composition partitions

| | RC | RM |
| --- | --- | --- |
| Bare `urma_jfs_t` (without jfr) | rejected (`udma_u_jfs.c:258`) | allowed |
| Bidi `urma_jetty_t` | allowed | allowed |
| Shared JFR (`flag.bs.share_jfr`) | rejected | allowed |
| `urma_jetty_grp_t` membership | rejected | allowed |
| TP variants | RTP only | RTP or CTP |
| Bonding ACTIVE_BACKUP fast path | per-pair connection migrate | per-peer state-free |

## When to pick which

| Workload | Pick |
| --- | --- |
| Long-lived high-throughput streaming to **one** peer (shuffle, model-state-sync) | **RC** — strongest ordering (OT/OL), lower per-WR overhead |
| **Many** short-lived peers (collectives, KV-store, fan-out RPC) | **RM + RTP** — multi-target API, per-peer state |
| **Very many** peers and reliability still required (IPoURMA, ubmgr ping, broadcast RPC) | **RM + CTP** — O(1) initiator state, reliable, shared TP |
| Datagram / fire-and-forget | UM + UTP (out of scope here, but for completeness) |
| Need target-side ordering ("write payload, then write flag") | **RC** with OT — RM can't give you target ordering |

## Concrete consequences

- **`urma_perftest --tp_reuse=1`** is hardcoded to RM (`perftest_resources.c:1050`). RC would clobber per-jetty bindings if you tried to share TPs.
- **Codex's `udma-tp-cache`** wins are concentrated on RM workloads with many jettys to the same peer — same TP serves all. RC repeats within a single jetty's lifecycle also benefit.
- **UMQ uses RM** because its multi-target reliable RPC pattern doesn't fit RC's 1:1 binding (see [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md)).
- **CTP** is RM-only — the connectionless-state design that lets one TP serve many destinations contradicts RC's 1:1 binding (see [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md)).

## What does NOT differ

Identical across both modes:
- Atomic operations.
- Max sizes (max_send_sge, max_recv_sge, max_inline_data, etc.).
- Congestion-control algorithms (DCQCN, LDCP, HC3, ACC).
- Token semantics (`urma_token_id_t` — IB rkey analog).
- Segment registration.
- JFC / completion-queue behavior.
- EID format and resolution.

The two modes only diverge along the axes above.

## Mental model

Think of **RC as "the IB RC QP, almost verbatim"**: one local endpoint, one remote, dedicated state, send WRs use the implicit destination, target-side ordering guaranteed.

Think of **RM as "what IB never quite shipped"**: reliable wire + connectionless multi-target API. Each WR addresses a destination explicitly. State is shared or pooled. Initiator-ordering is the strongest guarantee that's meaningful across many peers.

## Companion docs

- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer on EID / FE / VFE / jetty / TP layering
- [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) — exhaustive code-level breakdown across 9 axes with full file:line citations
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — link setup sequence, advise no-op on UB, CTP design
- [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md) — UMQ's IO + FC jetty pattern on top of RM
