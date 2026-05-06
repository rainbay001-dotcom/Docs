# URMA TP lifecycle: link setup, advise-is-noop, and CTP

_Last updated: 2026-05-06._

How URMA actually creates the wire-level link between two nodes for RM mode, why `urma_advise_jetty` is a no-op on UB, and what CTP is *for* — including the IPoURMA evidence that pins down its purpose. Builds on the URMA primer and the RM/RC code-level reference.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer (EID, FE/VFE, jetty, TP)
- [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) — exact RM vs RC differences
- [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) — the kernel cold-call analysis
- [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md) — UMQ's IO/FC pair on top

---

## 1. The question this doc answers

> "If RM is connectionless, do I just put the request in JFS with target EID and the system creates the link?"

Short answer: **no**. RM is connectionless at the *API model* (one local jetty can address many peers), but not at the wire layer — the per-peer link state has to be established explicitly first. What's surprising is *which* call does the work and which doesn't.

## 2. The full RM setup sequence on UB/UDMA

Six steps before you can `urma_post_send` to a new peer:

### Step 1 — Out-of-band exchange of peer info

The local node must somehow learn the peer's jetty identity:

```c
struct urma_rjetty {
    urma_jetty_id_t jetty_id;     /* (peer_eid, uasid, id) */
    urma_transport_mode_t trans_mode;
    urma_import_jetty_flag_t flag;
    urma_tp_type_t tp_type;
};
```

Plus a token (`urma_token_t`) for the peer's protection. URMA itself doesn't define how this exchange happens; the application does (URPC's UMQ uses its own connect protocol; perftest uses TCP for bootstrap).

### Step 2 — `urma_get_tp_list()` — *this is where the link is created on the wire*

```c
urma_get_tp_cfg_t cfg = {
    .local_eid = ...,
    .peer_eid  = peer_bonding_eid,
    .trans_mode = URMA_TM_RM,
    .flag.bs.rtp = 1,            /* or bs.ctp = 1 */
};
uint32_t tp_cnt = 1;
urma_tp_info_t tp_info[1];
urma_get_tp_list(ctx, &cfg, &tp_cnt, tp_info);
```

This is the call codex's `udma-tp-cache` wraps. From the kernel ubcore side: `urma_get_tp_list` → `udma_get_tp_list` → ctrlq message to MUE → MUE allocates TPID(s) on both ends, configures the wire-level state, returns TPID handles. **This is where the cross-node link gets established** — the FE → TPF → remote-TPF → remote-FE round-trip on cold call, the slow path the cache mitigates. After this call, `tp_info[i].tp_handle` references real wire-level state.

### Step 3 — `urma_set_tp_attr()` — optional configuration

```c
urma_set_tp_attr(ctx, tp_handle, tp_attr_cnt, attr_bitmap, &attr_value);
```

For UBoE: sip/dip/sma/dma/dscp/etc. For native UB usually skippable.

### Step 4 — `urma_import_jetty_ex()` — bind a TP to a target_jetty handle

```c
urma_active_tp_cfg_t active_tp_cfg = { .tp = tp_info[0], ... };
urma_target_jetty_t *target = urma_import_jetty_ex(ctx, &rjetty, &token, &active_tp_cfg);
```

`udma_u_import_jetty_ex` (`udma_u_jetty.c:649`):
- Allocates `struct udma_u_target_jetty`
- Calls `urma_cmd_import_jetty_ex` (ioctl) with the active_tp_cfg
- Stamps the target_jetty with `tp.tpn`, the token, the endian-swapped EID
- Returns it

For RM, the TP is bound at this step. For RC there's a quirk (`udma_u_jetty.c:683`):
```c
if (rjetty->trans_mode == URMA_TM_RC)
    tjetty->urma_tjetty.tp.tpn = INVALID_TPN;
```
RC leaves `tpn` invalid here; the actual TP gets bound later by `urma_bind_jetty`.

### Step 5 — `urma_advise_jetty()` — **NO-OP on UB**

```c
urma_advise_jetty(jetty, target);
```

`urma_cp_api.c:2069`:
```c
if (urma_ctx->dev->type == URMA_TRANSPORT_UB) {
    return URMA_SUCCESS;     /* ← UB short-circuits here */
}
return ops->advise_jetty(jetty, tjetty);
```

**For UB transport, advise is a literal no-op.** The advisory state was already set up at step 4 (import_jetty_ex). The call is harmless to make and recommended for portability with non-UB transports, but on UDMA hardware it does nothing.

This is a common surprise. Reading the URMA API docs you'd think advise is the equivalent of "telling" the local jetty about a remote target. On UB, that information is conveyed via `import_jetty_ex` instead, which makes advise structurally redundant.

### Step 6 — Now you can post

```c
urma_jfs_wr_t wr = {
    .tjetty = target,                 /* per-WR destination */
    .opcode = URMA_OPC_SEND,
    .src    = {sgl, sgl_cnt},
    ...
};
urma_post_jfs_wr(jfs, &wr, &bad_wr);
```

The post-send hot path (`udma_u_jfs.c:849`) reads `wr->tjetty` (RM) and stamps the WQE with `tjetty->tp.tpn` and the peer's EID. HW takes it from there using the established TP.

To send to a *different* peer: don't post a different WR. Repeat steps 1-4 for that new peer to get a second `target_jetty`, then post WRs with `wr->tjetty = target2`.

## 3. Why the API model is "connectionless" but the wire still needs setup

RM is connectionless at the **API layer**:
- The local jetty is *not bound* to a single remote peer (unlike RC's `bind_jetty`).
- One local jetty can have multiple `urma_target_jetty_t` handles — each post chooses which one.
- One local jetty + N targets → N concurrent outbound flows.

But it's *not* connectionless at the **wire layer**:
- TPs are explicitly created via `get_tp_list` per `(local_eid, peer_eid)` pair.
- TPs hold reliability state (sequence numbers, retransmit buffers).
- HW credits are pairwise.

The "connectionless" framing means "no API-level connection object you create with explicit handshake." But the wire-level state has to exist somewhere. URMA hides it behind `get_tp_list` + `import_jetty_ex` so the app sees just "import a target, post WRs."

## 4. Setup-cost comparison across modes

| | RC | RM (RTP) | RM (CTP) | UM (UTP) |
| --- | --- | --- | --- | --- |
| Step 1 (peer info exchange) | required | required | required | required |
| Step 2 (`get_tp_list`) | required (RTP) | required, **per peer** | required, but TP state shared | required (one UTP per ctx) |
| Step 3 (`set_tp_attr`) | optional | optional | optional | optional |
| Step 4 (`import_jetty_ex`) | required, tpn left INVALID | required, tpn bound | required, tpn references shared CTP | required, UTP-shared |
| Step 5 (binding call) | **`urma_bind_jetty`** — required, real work | **`urma_advise_jetty`** — no-op on UB | no-op on UB | n/a |
| Step 6 (post WR addressing) | implicit (queue's bound peer) | explicit `wr->tjetty` per WR | explicit `wr->tjetty` per WR | explicit `wr->tjetty` per WR |
| TP cardinality | 1:1 dedicated per local jetty | 1:N — reusable across local jettys to same peer | 1:many-peers — single TP serves all destinations | one UTP shared |
| Initiator state cost (N peers) | O(N) | O(N) | **O(1)** | O(1) |

The standout: **CTP collapses the per-peer initiator-state cost to O(1)** while keeping reliability. That's its purpose.

## 5. CTP — what it is for

### CTP fills the missing slot in a 2×2 matrix

Before CTP, URMA had:

| | per-peer initiator state | shared / pooled state |
| --- | --- | --- |
| **Reliable wire** | RTP (with RM or RC) | **(missing)** |
| **Unreliable wire** | (no useful design point) | UTP |

If you had an endpoint that talks to *many* peers and wanted reliability, your only option was RTP — paying O(N) initiator state for N peers. UTP gave you cheap multi-peer but lost reliability. CTP fills the "reliable + cheap setup" cell.

### The IPoURMA evidence

`ipourma_ub.c:109-115` — the canonical CTP consumer:

```c
static inline void ipourma_build_tjetty_cfg(struct ubcore_tjetty_cfg *tjetty_cfg,
    union ubcore_eid *dst_eid, uint32_t jetty_id, uint32_t eid_idx, uint32_t ctp_en)
{
    tjetty_cfg->id.eid = *dst_eid;
    tjetty_cfg->id.id = jetty_id;
    tjetty_cfg->flag.bs.token_policy = UBCORE_TOKEN_NONE;
    tjetty_cfg->tp_type    = ctp_en ? UBCORE_CTP    : UBCORE_UTP;
    tjetty_cfg->trans_mode = ctp_en ? UBCORE_TP_RM  : UBCORE_TP_UM;
    ...
}
```

What this is doing:
- IPoURMA wants reliable IP traffic (TCP needs a reliable lower layer).
- IPoURMA talks to *many* peers (anyone on the IP network).
- If `ctp_en = 1` (HW supports CTP): use **RM + CTP** — reliable, shared.
- If `ctp_en = 0` (HW doesn't): fall back to **UM + UTP** — unreliable, shared.

The fallback is from RM to UM, *not* from CTP to RTP. That's the giveaway: IPoURMA cannot afford RTP's per-peer state. The cost of RTP at IP-stack scale (potentially thousands of peers) is so prohibitive that they'd rather lose reliability than pay it. CTP is what lets them keep both reliability *and* multi-peer scale.

`ubmgr_ping.c:68` does the same — `tp_type = UBCORE_CTP` for cluster health probes that touch every node.

### CTP vs RTP: the differences

**Initiator-side state cost.**
- RTP: dedicated state per `(local_eid, peer_eid, mode)` tuple. Per-peer sequence numbers, retransmit context, per-pair credit handshake. Linear in peer count.
- CTP: pooled/shared state across destinations. Closer to O(1).

**What `urma_get_tp_list` does.**
- RTP: per call, get a handle whose state is dedicated to `(local, peer)`. Calling for a fresh peer creates fresh state at MUE.
- CTP: each call still returns a TP handle, but the underlying state at MUE is shared across destinations. Codex's warmup acknowledges this: `/* UDMA_CTRLQ_TRANS_TYPE_CTP does not consume trans_mode. */` (`udma_tp_cache.c:761`) — CTP is its own trans_type that doesn't even use the regular RM/RC mode resolution.

**Wire-level reliability.**
- Same. Both deliver reliably (no message loss, automatic retransmit). The cost difference is *how that reliability is bookkept* — RTP is bookkeeping-per-peer, CTP is bookkeeping-coalesced.

**Setup constraints.**
- RTP: works with RM or RC.
- CTP: RM only. Forced by `udma_tp_cache.c:733` and the implicit constraint that connection-oriented + connectionless-state is contradictory.

**Multipath.**
- `ubcore_topo_info.c:1197`:
```c
if (multi_path && tp_type == UBCORE_CTP) {
    /* CTP-specific multipath handling */
}
```
- `route_list[i].flag.bs.ctp = 1` set in `ubcore_topo_info.c:630, 643` when generating route entries.
- CTP is multipath-aware as a first-class concept; one CTP can use multiple physical paths to its various destinations.

**Hardware requirement.**
- `ctp_en` is a device-capability bit — `urma_device_feature_t.bs.ctp_en` (`urma_types.h:203`).
- UDMA sets it conditionally (`udma_main.c:794`):
```c
udma_dev->caps.ctp_en = !(ubase_adev_ip_over_urma_utp_supported(udma_dev->comdev.adev));
```
- Consumers query the bit and pick CTP when available, fall back when not. RTP is always available; CTP is opt-in HW.

### CTP vs UTP — same shape on the surface, opposite ends of reliability

Both share state across destinations, but:

| | CTP | UTP |
| --- | --- | --- |
| Wire reliability | full (acks, retransmit) | none (datagram) |
| Loss visible to app | no | yes |
| Use case | reliable RPC / IP / many-peer | UD-style fire-and-forget |
| Pairs with | RM | UM |
| MTU | full message | UD-MTU bound |

Confusing them is easy because both "look connectionless." The functional difference is reliability — CTP gives the semantics, UTP requires the application to handle loss.

## 6. When to pick which TP variant

```
  Need many peers from one endpoint?
    Yes ─→ Need reliability?
            Yes ─→ HW supports CTP?
                    Yes ─→ CTP (one TP, many peers, reliable)
                    No  ─→ RTP (N TPs, expensive setup, reliable) — or fall back to UTP
            No  ─→ UTP (one TP, many peers, datagram)
    No  ─→ Need long-running connection-oriented stream?
            Yes ─→ RTP + RC (1:1 binding, OT/OL ordering)
            No  ─→ RTP + RM (per-peer state, OI ordering)
```

## 7. What CTP is actually new

Two things historically missing from RDMA-style fabrics:

1. **Reliable RDMA semantics with O(1) initiator-state cost across many peers.** IB's RC has reliability but O(N) cost; UD has O(1) cost but loses reliability. Mellanox added DC as an extension to bridge this; URMA codifies it as CTP, a first-class TP type.

2. **A network-stack-friendly reliable transport.** IP-over-RDMA traditionally uses UD because RC's per-peer cost makes IPoIB-with-RC unworkable at modest scale. CTP makes it possible to have IPoURMA with reliable semantics — preserving the "IP is best-effort but TCP makes it reliable" stack while giving TCP a reliable lower layer for free at the URMA hop.

Workloads that benefit:
- **IPoURMA** — the textbook case. IP networking inherently talks to many peers; can't afford per-peer state.
- **ubmgr ping / cluster health** — broadcast-style probes to all nodes in a cluster.
- **Many-target reliable RPC** — a single client serving requests to many backends.
- **Aggregate-EID / multipath-LAG patterns** — CTP's first-class multipath integration.

Workloads that don't benefit (use RTP instead):
- Long-lived RC-style streams to one peer.
- Workloads that need OT (target-side ordering) — CTP only gives OI.
- Workloads where N is small (< 8 peers): RTP overhead is negligible, no win from CTP.

## 8. Implications for codex's `udma-tp-cache`

The cache key includes `trans_type` (the canonicalized RTP/CTP/UTP encoding) precisely because the same `(local_eid, peer_eid, RM)` query produces a *different* TP-list depending on whether the caller asked for RTP-flagged or CTP-flagged TPs — they're different resource pools on the management side.

Codex's warmup expansion at `udma_tp_cache.c:725-775` walks `{RM, RC, UM} × {CTP, RTP, UTP} × {ub, uboe}` to populate cache entries for every legal combination. That's why a fresh module load with warmup enabled and N peers ends up queuing 7×N work items at most — one per legal combo per peer.

For workloads dominated by IPoURMA (which uses CTP), the cache wins are concentrated on a single trans_type per peer. For mixed RPC + IP workloads, the cache covers both flavors.

## 9. Summary

- **RM doesn't auto-create links.** The setup sequence is six steps; the link gets established at step 2 (`urma_get_tp_list`). Steps 4–5 are local bookkeeping that lets you *reference* the established link.
- **`urma_advise_jetty` is a no-op on UB.** The advise binding happens at `urma_import_jetty_ex` instead. Calling advise is harmless and recommended for portability, but on UDMA it does nothing.
- **CTP is the reliable-and-cheap TP variant.** Same wire reliability as RTP, but state pooled across destinations rather than dedicated per peer. RM-only, HW-gated.
- **CTP exists because IP-stack-style workloads (many peers, need reliability) need it.** IPoURMA prefers CTP > UTP; falls back from CTP to UM-with-UTP rather than to RM-with-RTP, because RTP's per-peer cost is unaffordable at IP scale.
- **For codex's cache:** warmup populates cache entries per-`(peer, trans_mode, tp_type)` — CTP and RTP entries are independent because they hit different resource pools on the management side.

## 10. References

- `src/urma/lib/urma/core/urma_cp_api.c:2069` — `urma_advise_jetty` UB short-circuit.
- `src/urma/lib/urma/core/urma_cp_api.c:3053` — `urma_get_tp_list` dispatcher.
- `src/urma/hw/udma/udma_u_jetty.c:649` — `udma_u_import_jetty_ex`.
- `src/urma/hw/udma/udma_u_jetty.c:683` — RC's `INVALID_TPN` quirk at import.
- `src/urma/hw/udma/udma_u_jfs.c:849` — post-send hot-path WR addressing.
- `kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:412` — `flag.bs.ctp` → `UDMA_CTRLQ_TRANS_TYPE_CTP`.
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:794` — `ctp_en` device-cap derivation.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c:109-115` — IPoURMA's CTP-or-UTP choice.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_res.c:815-820` — IPoURMA's RM-or-UM choice via ctp_en.
- `kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:1197, 630, 643` — CTP multipath handling.
- `kernel/drivers/ub/urma/ubcore/ubmgr/ubmgr_ping.c:68` — ubmgr ping using CTP.
- `kernel/drivers/ub/urma/hw/udma/udma_tp_cache.c:733, 761` — codex's CTP/RM enforcement and trans_type encoding.
- `src/urma/lib/urma/core/include/urma_types.h:203` — `urma_device_feature_t.bs.ctp_en`.
