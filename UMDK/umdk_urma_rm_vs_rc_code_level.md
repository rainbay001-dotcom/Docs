# RM vs RC in URMA: code-level differences

_Last updated: 2026-05-06._

The conceptual difference between Reliable Message (RM) and Reliable Connection (RC) is "RM is connectionless / multi-target, RC is point-to-point / connection-oriented." This doc says what that *exactly* means at the code level — every place in the umdk + ubcore source where the two modes diverge, with line citations. Nine axes; four matter at runtime, the rest are object-composition or API-surface partitions.

Companion to [`umdk_urma_object_model.md`](umdk_urma_object_model.md). Source paths assume the workspace layout in [`reference_kerneldev_volume.md`](../UMDK/) — `/Volumes/KernelDev/umdk/` and `/Volumes/KernelDev/kernel/`.

---

## The four axes that matter at runtime

These are the differences any RM/RC code path actually executes during data-plane traffic.

### 1. Per-WR destination addressing — the core mechanical difference

`udma_u_jfs.c:849` (the post-send hot path):
```c
if (sq->trans_mode == URMA_TM_RC)
    tjetty = &sq->tjetty->urma_tjetty;   /* destination is fixed at bind_jetty time */
else
    tjetty = wr->tjetty;                  /* destination is taken per WR */
```

- **RC**: each post-send takes the destination from the **queue's bound peer**. `wr->tjetty` is *ignored*. The SQ "knows" who it talks to from `urma_bind_jetty`.
- **RM**: each post-send takes the destination from the **WR struct itself** — `wr->tjetty`. So each WR may target a different remote, and the application sets that field per-call.

That single line is what makes RM 1-to-N and RC 1-to-1 at the wire-format level. The HW WQE filling logic afterwards is identical; just the source of `tjetty` differs.

### 2. TP cardinality and sharing

| | RC | RM |
| --- | --- | --- |
| TPs per `(local_jetty, remote)` pair | dedicated 1:1 | shareable across many jettys to same remote |
| TPs per local jetty | 1 (the bound peer) | varies — one per RTP `(local-eid, remote-eid)`, or one shared CTP for many remotes |
| `tp_reuse` perftest pattern | impossible — would clobber RC bindings | enabled, hardcoded to RM (`perftest_resources.c:1050`) |

`perftest_resources.c:1049-1053`:
```c
for (uint32_t i = 0; i < ctx->jetty_num; i++) {
    if (cfg->tp_reuse && cfg->trans_mode == URMA_TM_RM && i > 0) {
        ctx->tp_info[i] = ctx->tp_info[0];   /* share TP across jettys — RM only */
        continue;
    }
    ...
    int ret = urma_get_tp_list(ctx->urma_ctx, &tp_cfg, &tp_cnt, &ctx->tp_info[i]);
}
```

### 3. State on `urma_jetty_t`

RC jettys carry a `remote_jetty` pointer (the bound destination); RM jettys leave it NULL. Cleanup paths check it:

`urma_cp_api.c:1728, 1762, 1819`:
```c
if (jetty->jetty_cfg.jfs_cfg.trans_mode == URMA_TM_RC && jetty->remote_jetty != NULL) {
    /* RC-specific cleanup: the jetty has a bound remote, must unbind */
}
```

So RC has per-jetty state (the bound remote pointer) that must be tracked through the entire jetty lifecycle. RM has none.

### 4. Order types allowed

`urma_cp_api.c:627-630`:
```c
if ((trans_mode != URMA_TM_RC && order_type == URMA_OT) ||
    (trans_mode != URMA_TM_RC && order_type == URMA_OL) ||
    (trans_mode != URMA_TM_RM && order_type == URMA_OI) ||
    (trans_mode == URMA_TM_RM && order_type == URMA_NO))
    return -1;
```

| Order type | What it means | RC | RM |
| --- | --- | :-: | :-: |
| `URMA_OT` (target) | Receiver memory + receiver CQ in submission order | ✅ | ❌ |
| `URMA_OL` (low-layer) | Lowest-layer best-effort, multipath-friendly | ✅ | ❌ |
| `URMA_OI` (initiator) | Sender CQ in submission order; remote may reorder | ❌ | ✅ |
| `URMA_NO` (none) | None | ❌ | ❌ |
| `URMA_DEF_ORDER` | Driver picks strongest legal | ✅ | ✅ |

Why: target-ordering needs receiver-side serialization, only RC has the per-peer state to provide it. Initiator-ordering is what RM can offer across multi-target sends.

## The five axes that are object-composition or API-surface partitions

These differ at object-creation or call-dispatch time, not on every data-plane WR.

### 5. RC requires a paired jetty; bare jfs is rejected

`udma_u_jfs.c:258`:
```c
urma_jfs_t *udma_u_create_jfs(urma_context_t *ctx, urma_jfs_cfg_t *cfg)
{
    ...
    if (cfg->trans_mode == URMA_TM_RC) {
        UDMA_LOG_ERR("jfs not support RC transmode.\n");
        return NULL;
    }
    ...
}
```

Why: an RC binding is bidirectional — the connection state has to terminate somewhere on the receive side. A bare `urma_jfs_t` has no associated jfr. Use `urma_create_jetty()` (which contains both jfs + jfr) for RC. RM accepts both forms.

### 6. API surface partition: `bind` vs `advise`

| API | RC | RM | Source |
| --- | :-: | :-: | --- |
| `urma_bind_jetty(local, remote)` / `_ex` / `_async` | ✅ | ❌ | `urma_cp_api.c:1990` |
| `urma_unbind_jetty` | ✅ | ❌ | `urma_cp_api.c:2018` |
| `urma_flush_jetty` | ✅ | ❌ | `urma_cp_api.c:2167` |
| `urma_modify_jetty_state` (state-machine analog) | ✅ | ❌ | `urma_cp_api.c:2045` |
| `urma_advise_jetty(local, remote_target)` | ❌ | ✅ | `urma_cp_api.c:2060-2061` |
| `urma_unadvise_jetty` | ❌ | ✅ | (mirror of above) |
| `urma_advise_jfr` / `urma_unadvise_jfr` | ❌ | ✅ | `urma_cp_api.c:2845, 2892` |

Each call validates `trans_mode != URMA_TM_RC` (or `!= URMA_TM_RM`) and rejects mismatches with `URMA_EINVAL`.

The split tracks the API-model difference: `bind` is the RC-only "establish a connection" call; `advise` is the RM-only "tell the local jetty about a remote target it may send to" call.

`urma_api.h` doc-comment for `urma_bind_jetty`:
> Note: A local jetty can be binded with only one remote jetty. Only supported by jetty under URMA_TM_RC.

`urma_api.h` doc-comment for `urma_advise_jetty`:
> Note: A local jetty can be advised with several remote jetties. A connectionless jetty is free to call the advise API.

URMA documents RM as "connectionless" *at the API layer* even though the wire is reliable.

### 7. Object-composition restrictions

| Composition | RC | RM | Source |
| --- | :-: | :-: | --- |
| Send-only `urma_jfs_t` (without jfr) | ❌ | ✅ | `udma_u_jfs.c:258` |
| Bidi `urma_jetty_t` | ✅ | ✅ | (general) |
| Shared JFR (`flag.bs.share_jfr`) | ❌ | ✅ | `urma_cp_api.c:1560, 1567` |
| `urma_jetty_grp_t` membership (multipath/LAG) | ❌ | ✅ | `udma_u_jetty.c:128` |

`udma_u_jetty.c:128`:
```c
if (jetty->sq.trans_mode != URMA_TM_RM) {
    UDMA_LOG_ERR("jetty must be RM model, if assigned grp.\n");
    return EINVAL;
}
```

Multipath/LAG groups (`urma_jetty_grp_t`) require RM because the group's job is to spread WRs across multiple paths to multiple peers — the RC 1:1 binding is incompatible.

### 8. TP variants allowed

Cross-check at `urma_cp_api.c` (`UTP requires UM, RTP cannot be UM`); CTP-RM-only is enforced by codex's warmup at `udma_tp_cache.c:733` (CTP TPs implicitly use RM regardless of caller-supplied mode).

| TP variant | RC | RM |
| --- | :-: | :-: |
| **RTP** (Reliable Transport Pair) | ✅ | ✅ |
| **CTP** (Connectionless Transport Pair) | ❌ | ✅ |

RC always uses RTP. RM can use either RTP (per-peer state) or CTP (no per-peer state, multi-target reliable).

### 9. Bonding behavior

`bondp_api.c:1545, 1571, 1801` — bonding ACTIVE_BACKUP mode has **RM-specific paths**:

```c
if (rjetty->trans_mode == URMA_TM_RM &&
    bdp_ctx->bonding_mode == BONDP_BONDING_MODE_ACTIVE_BACKUP) {
    /* RM-specific failover path */
}
```

RM jettys with bonding can switch active port without re-establishing per-peer state. RC's per-peer connection state means failover requires migrating the connection; the RM fast-paths exist because the no-per-peer-state nature of RM makes failover effectively free.

## What does *not* differ

Everything below is identical across RM and RC and behaves the same regardless of mode:

- **Atomic operations** (compare-and-swap, fetch-and-add, etc.) — `urma_atomic_feature_t` is mode-agnostic.
- **Send/RDMA-Write/RDMA-Read opcodes** — same WQE format aside from where `tjetty` comes from (axis #1).
- **Max sizes** — `max_send_sge`, `max_recv_sge`, `max_inline_data` etc. are device-cap-driven, not mode-driven.
- **Congestion-control algorithms** (DCQCN, LDCP, HC3, etc.) — selected per-TP via `urma_tp_cc_alg`, orthogonal to RM/RC.
- **Token semantics** (`urma_token_id_t`, the rkey analog) — segment registration and revocation work the same.
- **JFC / completion-queue semantics** — completion polling, JFC events, JFC inline are independent of trans_mode.
- **EID format and resolution** — same EIDs in cache keys, same routing.

## Summary by axis

```
                                   RC                    RM
Per-WR destination       sq->tjetty (queue-bound)  wr->tjetty (per-WR)
TP cardinality           1:1 dedicated             N:1 shareable across jettys
Jetty.remote_jetty       set after bind            always NULL
Order types              OT, OL                    OI
Bare jfs creation        rejected                  allowed
bind/unbind/flush        allowed (only RC)         rejected
advise/unadvise          rejected                  allowed (only RM)
Shared JFR               rejected                  allowed
jetty_grp                rejected                  allowed (only RM)
TP variants              RTP only                  RTP or CTP
Bonding failover         per-peer state migrate    no per-peer state — free
```

Everything else — atomics, sizes, CC, tokens, JFC — is identical across the two modes.

## Mental model

Think of RC as "the IB RC QP, almost verbatim": one local endpoint, one remote endpoint, dedicated state for the pair, send WRs use the implicit destination, target-side ordering guaranteed.

Think of RM as "what IB never quite shipped" — reliable wire + connectionless multi-target API. Each WR addresses a destination explicitly. State is shared or pooled. Initiator-ordering is the strongest guarantee that's meaningful.

The four runtime differences (#1–4) are the ones that show up in profiling and debugging. The remaining five (#5–9) are static partitions you trip over at object creation or API call time, not in the data-plane hot path.
