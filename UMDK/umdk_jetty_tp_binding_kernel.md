# Jetty ↔ TP/CTP binding — kernel-side mechanism

_Last updated: 2026-05-27._

How a URMA jetty gets associated with a transport path (TP) on the kernel side, with file:line citations against `drivers/ub/urma/` in openEuler OLK-6.6. Covers both modes used in practice — **RTP** (CM-negotiated, classic) and **CTP** (caller-supplied tp_handle, ctrlplane) — and the question that always follows: *how can one jetty drive multiple TPs?*

This doc is the kernel-side companion to [`umdk_ubsocket_umq_urma_stack.md`](umdk_ubsocket_umq_urma_stack.md) (which traces the user-space chain ending at `urma_bind_jetty`) and complements [`umdk_urma_perftest_ctp.md`](umdk_urma_perftest_ctp.md) (which measures the CTP cold-start saving). Where the latter explains *why* CTP exists, this explains *how* the kernel actually implements the bind step.

Companions:
- [`umdk_ubsocket_umq_urma_stack.md`](umdk_ubsocket_umq_urma_stack.md) — userspace → urma_bind_jetty
- [`umdk_urma_perftest_ctp.md`](umdk_urma_perftest_ctp.md) — CTP cold-start measurements
- [`umdk_urma_jetty_kernel_call_trace.md`](umdk_urma_jetty_kernel_call_trace.md) — broader kernel call trace
- [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) — RM vs RC differences
- [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md) — UMQ paired IO+FC jetty design

---

## 1. TL;DR

Two API entry points, both gated by `trans_mode == UBCORE_TP_RC`:

```
userspace                              kernel ioctl dispatch
─────────────────────────              ─────────────────────────────────────
urma_bind_jetty(jetty, tjetty)      →  URMA_CMD_BIND_JETTY    → uburma_cmd_bind_jetty
                                                                  → ubcore_bind_jetty
                                                                    ↓ legacy / RTP path

urma_bind_jetty_ex(jetty,           →  URMA_CMD_BIND_JETTY_EX → uburma_cmd_bind_jetty_ex
                  tjetty,                                         → ubcore_bind_jetty_ex
                  active_tp_cfg)                                    ↓ CTP / ctrlplane path
```

Both produce the same end state — local jetty bound to remote target jetty, vtpn allocated, hardware TP active. They differ in **where the TP parameters come from**:

- **RTP**: in-kernel CM exchange (`ubcore_send_create_vtp_req`) negotiates the TP with the peer.
- **CTP**: caller supplies a fully-populated `ubcore_active_tp_cfg` with `tp_handle`, `peer_tp_handle`, `tx_psn`, `rx_psn`; the driver programs it into hardware directly via `active_tp`.

The CTP path skips a multi-millisecond CM round-trip, which is the cold-start saving measured in [UMDK#7](https://github.com/rainbay001-dotcom/UMDK/issues/7).

And: in RC mode, **one jetty binds to exactly one tjetty**. The illusion of "one jetty → many TPs" comes from `share_tp + OT` semantics that coerce the vtpn layer to RM-style keying, and from CTP itself running over what is effectively RM at the trans_mode layer. The bind validation is never relaxed.

---

## 2. The shared validation

Both `ubcore_bind_jetty` (`ubcore_jetty.c:2758-2793`) and `ubcore_bind_jetty_ex` (`ubcore_jetty.c:2909-…`) run the same gate:

```c
if (!jetty || !tjetty || !ubcore_have_ops(jetty->ub_dev)) return -EINVAL;
if (jetty->jetty_cfg.trans_mode != UBCORE_TP_RC ||
    tjetty->cfg.trans_mode      != UBCORE_TP_RC)
    return -EINVAL;                            /* bind only allowed in RC mode */
if (jetty->remote_jetty == tjetty) return 0;   /* re-bind to same target = idempotent */
if (jetty->remote_jetty)                       /* one local jetty -> one tjetty */
    return -EINVAL;
if (tjetty->vtpn && !is_create_rc_shared_tp(...))
    return -EINVAL;                            /* can't double-bind a non-shared tjetty */
return ubcore_inner_bind_jetty(jetty, tjetty, udata);
```

A jetty binding is **1:1** unless `share_tp` is set on the tjetty's cfg.

`is_create_rc_shared_tp` predicate (`ubcore_priv.h:115-124`):

```c
static inline bool is_create_rc_shared_tp(trans_mode, order_type, share_tp) {
    return trans_mode == UBCORE_TP_RC && order_type == UBCORE_OT && share_tp == 1;
}
```

So sharing is gated on **RC + OT (ordered traffic) + explicit share_tp flag**.

---

## 3. RTP path — `bind_jetty` (CM-negotiated)

`ubcore_inner_bind_ub_jetty` (`ubcore_jetty.c:2664-2722`):

```c
ret = dev->ops->bind_jetty(jetty, tjetty, udata);            /* driver bookkeeping */
if (ret) return ret;
atomic_inc(&jetty->use_cnt);

if (!is_create_rc_shared_tp(...)) {
    ubcore_set_vtp_param(dev, jetty, &tjetty->cfg, &vtp_param);
    ...
    vtpn = ubcore_connect_vtp(dev, &vtp_param);              /* ← the heavy step */
    if (IS_ERR_OR_NULL(vtpn)) goto unbind;
    tjetty->vtpn = vtpn;
}
```

`ubcore_connect_vtp` (`ubcore_vtp.c:1068-1127`) does five things:

1. **Try to reuse vtpn** — find by `(local_eid, peer_eid, trans_mode)`.
2. **Allocate new vtpn** — kalloc, init mutex, state=`UBCORE_VTPS_WAIT_CREATE`.
3. **Add vtpn to hashtable** — atomic insert; on `-EEXIST`, reuse the existing entry.
4. **`ubcore_send_create_vtp_req(dev, param, vtpn)`** — sends a `CREATE_VTP` request via UBCM/UBMAD to the peer. The peer responds with TP parameters; both sides program the TP into HW.
5. **On success** → `vtpn->state = UBCORE_VTPS_READY`.

So `bind_jetty` in the RTP path is **bind + negotiate**. The negotiation is the multi-millisecond cost that shows up in perftest traces as the `bondp_import_jetty` ~50-90 ms numbers in cold-start RTP measurements (see [`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md) §3.3).

---

## 4. CTP path — `bind_jetty_ex` + `active_tp`

`ubcore_bind_jetty_ex` (`ubcore_jetty.c:2909-…`) takes an extra `ubcore_active_tp_cfg *` arg carrying the **already-known TP**:

```c
struct ubcore_active_tp_cfg {
    union ubcore_tp_handle tp_handle;        /* bs.tpid becomes vtpn->vtpn */
    union ubcore_tp_handle peer_tp_handle;
    struct ubcore_tp_attr  tp_attr;          /* tx_psn, rx_psn, mtu, etc. */
    ...
};
```

Path through `ubcore_inner_bind_ub_jetty_ctrlplane` (`ubcore_jetty.c:2812-2874`):

```c
ret = dev->ops->bind_jetty_ex(jetty, tjetty, active_tp_cfg, udata);  /* driver bookkeeping */
if (ret) return ret;
atomic_inc(&jetty->use_cnt);

if (!is_create_rc_shared_tp(...)) {
    ubcore_set_vtp_param(dev, jetty, &tjetty->cfg, &vtp_param);
    ...
    vtpn = ubcore_connect_rc_vtp_ctrlplane(dev, &vtp_param,
                                           active_tp_cfg, udata);    /* ← activation step */
    if (IS_ERR_OR_NULL(vtpn)) goto unbind;
    tjetty->vtpn = vtpn;
}
```

`ubcore_connect_rc_vtp_ctrlplane` (`ubcore_vtp.c:1353-1413`) replaces step 4 of the RTP path:

```c
/* 1. try to reuse vtpn       (find by active_tp_cfg.tp_handle) */
/* 2. alloc new vtpn */
/* 3. add vtpn to hashtable */
/* 4. ubcore_active_tp(dev, active_tp_cfg, vtpn)     ← NO CM REQ; direct hw program */
/*       → dev->ops->active_tp(dev, active_tp_cfg) = udma_active_tp */
/*         → udma_ctrlq_set_active_tp_ex(udma_dev, active_cfg)         */
/* 5. vtpn->vtpn = active_tp_cfg->tp_handle.bs.tpid */
/*    vtpn->state = UBCORE_VTPS_READY */
```

CTP **skips CM negotiation entirely** — the caller (uvs / ubmad / user-supplied OOB protocol; for urma_perftest it's the OOB TCP `exchange_tp_info`) is responsible for supplying matching `tp_handle` / `peer_tp_handle` / `tx_psn` / `rx_psn` on both sides. The kernel just programs the hardware ctrlq with those values via:

`udma_active_tp` (`udma_ctrlq_tp.c:981-991`):

```c
int udma_active_tp(struct ubcore_device *dev, struct ubcore_active_tp_cfg *active_cfg)
{
    struct udma_dev *udma_dev = to_udma_dev(dev);
    int ret = udma_ctrlq_set_active_tp_ex(udma_dev, active_cfg);
    if (ret) dev_err(udma_dev->dev, "Failed to set active tp msg, ret %d.\n", ret);
    return ret;
}
```

— a single ctrlq message into the hardware. No peer round-trip. That's the entire wall-clock saving over RTP.

---

## 5. The driver-side bind is just bookkeeping

People expect `bind_jetty` to "do the work." It doesn't:

```c
/* udma_jetty.c:1517-1527 */
int udma_bind_jetty_ex(struct ubcore_jetty *jetty,
                       struct ubcore_tjetty *tjetty,
                       struct ubcore_active_tp_cfg *active_tp_cfg,
                       struct ubcore_udata *udata)
{
    struct udma_jetty *udma_jetty = to_udma_jetty(jetty);
    udma_jetty->sq.rc_tjetty = tjetty;          /* the entire body of work */
    return 0;
}
```

**All `udma_bind_jetty_ex` does is store a pointer.** Same shape for the legacy `udma_bind_jetty` op — driver-side bind is bookkeeping; the hardware TP setup happens via the separate `active_tp` op.

The separation is deliberate: the same `active_tp_cfg` may be activated multiple times for different jetty pairs (when sharing). Decoupling "associate this jetty with this remote target" from "program a TP into hardware" lets the kernel batch / reuse the latter.

---

## 6. The state graph after a successful bind

```
local fd N (user side)
   │
   ▼
struct ubcore_jetty                struct ubcore_tjetty
  jetty_id (local)        ┌──────►   cfg.id (remote jetty_id)
  remote_jetty  ──────────┘          vtpn ──────────────────┐
  jetty_cfg.trans_mode = RC          cfg.trans_mode  = RC   │
  use_cnt                            use_cnt                ▼
                                                   struct ubcore_vtpn
                                                     vtpn  = tp_handle.bs.tpid
                                                     trans_mode = RC
                                                     state = UBCORE_VTPS_READY
                                                     use_cnt (refcount; shared if share_tp)

driver state:
  struct udma_jetty {
      ubcore_jetty;
      sq.rc_tjetty = tjetty;     ← only thing the driver remembers about the binding
  };

hardware state (programmed via udma_ctrlq_set_active_tp_ex):
  TP table entry indexed by tp_handle.bs.tpid:
      tx_psn, rx_psn, peer_eid, peer_tp_handle, mtu, retry params, …
```

---

## 7. VTP reuse — many jetty pairs can share one vtpn

`ubcore_find_get_vtpn` (RTP) and `ubcore_find_get_vtpn_ctrlplane` (CTP) both **try reuse before allocating**. The lookup key is essentially `(local_eid, peer_eid, trans_mode)` plus a `share_tp` flag bit. When matched:

```c
atomic_inc(&vtpn->use_cnt);      /* refcount++ */
return vtpn;                     /* same vtpn for the new binding */
```

That's why a machine can have thousands of bound jetty pairs but only tens of vtpns — and tens of hardware TPs.

`is_create_rc_shared_tp(trans_mode, order_type, share_tp)` is the predicate that decides whether to allocate a vtpn at all in the `share_tp` case — in the shared path, the vtpn is owned by some other (earlier) binding and this one just rides on top without its own allocation.

---

## 8. Unbind / disconnect

Symmetric:

```
urma_unbind_jetty()
  → uburma_cmd_unbind_jetty
  → ubcore_unbind_jetty
  → dev->ops->unbind_jetty(jetty)               /* clear sq.rc_tjetty */
  → ubcore_disconnect_vtp(vtpn)                  /* if use_cnt drops to 0: */
        → dev->ops->deactive_tp(tp_handle, udata)
        → udma_k_ctrlq_deactive_tp              /* hardware TP teardown */
        → free vtpn struct
```

Only when the vtpn refcount hits 0 does the hardware TP actually go away. Same dual-mode: RTP path sends a destroy CM req; CTP path skips CM and just deactivates.

---

## 9. RTP vs CTP — side-by-side

| | RTP (`urma_bind_jetty`) | CTP (`urma_bind_jetty_ex`) |
| --- | --- | --- |
| Required trans_mode | UBCORE_TP_RC | UBCORE_TP_RC (often coerced from RM at vtp_param level) |
| Caller passes `tp_handle`? | No | Yes (in `ubcore_active_tp_cfg`) |
| CM exchange with peer? | **Yes** — `ubcore_send_create_vtp_req` via UBCM/UBMAD | **No** — peer's `tp_handle` arrived OOB |
| Driver op for binding | `bind_jetty` | `bind_jetty_ex` |
| Driver op for TP activation | bundled into `bind_jetty` callbacks | separate `active_tp` op |
| Wall-clock cold start | tens of ms (CM round trip) | < 1 ms (activation only) |
| vtpn allocator | `ubcore_connect_vtp` (`ubcore_vtp.c:1068`) | `ubcore_connect_rc_vtp_ctrlplane` (`ubcore_vtp.c:1353`) |
| vtpn hashtable | main vtpn table | ctrlplane vtpn table (separate) |
| Hardware program | inside CM completion path | `udma_active_tp` → `udma_ctrlq_set_active_tp_ex` (`udma_ctrlq_tp.c:981`) |
| Used by | classic urma_perftest, ubsocket default | urma_perftest `--ctp`, externally-orchestrated TP setup |

---

## 10. "How can one jetty be bound to 2 CTPs?" — the answer is layered

The strict RC bind says no. But there are three different things this question can mean.

### 10.1 Literal RC bind: still 1:1

In pure RC mode (`trans_mode == UBCORE_TP_RC`, non-OT ordering, `share_tp = 0`), `ubcore_bind_jetty` and `ubcore_bind_jetty_ex` *both* enforce:

```c
if (jetty->remote_jetty)               /* ubcore_jetty.c:2776 */
    return -EINVAL;   /* "The same jetty, different tjetty, prevent duplicate bind." */
```

After the first successful bind, `jetty->remote_jetty` is set; a second bind to a different tjetty is rejected. So in the textbook RC model, **you cannot bind one jetty to 2 different remotes**.

### 10.2 The escape hatch: `share_tp + OT` rewrites RC → RM at the vtpn layer

`ubcore_set_vtp_param` (`ubcore_vtp.c:2089-2120`) — called during every bind path — contains the single line:

```c
vtp_param->trans_mode = cfg->trans_mode;
if (is_create_rc_shared_tp(cfg->trans_mode, cfg->flag.bs.order_type,
                           cfg->flag.bs.share_tp))
    vtp_param->trans_mode = UBCORE_TP_RM;       /* ← coercion */
```

When this fires, the vtpn lookup/allocation happens in **the RM hashtable, indexed by `(local_eid, peer_eid)` only** — not by `(local_jetty, peer_jetty)`. Two consequences:

1. **Many jetty pairs sharing one TP.** If you bind `(local_jettyA, tjettyX)` and `(local_jettyB, tjettyX)` with the same EIDs and `share_tp=1+OT`, both bindings reuse the same vtpn → same underlying CTP.
2. **One jetty *appearing* to be associated with multiple TPs at the post-WR layer.** In RM-keyed lookup, the kernel doesn't care which local jetty did the bind, so the jetty's SQ can issue work requests against different peer EIDs and each goes to the vtpn registered for that peer pair.

But the strict `jetty->remote_jetty` check still runs. So the **bind API** still rejects a second bind from the same local jetty struct. The multi-TP-per-jetty effect comes from RM semantics taking over the *vtpn layer underneath*, not from the bind being relaxed.

### 10.3 The clean answer for CTP/ubsocket: there's no bind at all

ubsocket/urma_perftest with `--ctp` doesn't go through `urma_bind_jetty` on the data path. Looking at the ubsocket trace ([`umdk_ubsocket_umq_urma_stack.md`](umdk_ubsocket_umq_urma_stack.md) §5.2), `umq_ub.c:511-515`:

```c
if (queue->tp_mode != URMA_TM_RC) {
    return tjetty;                             /* RM mode: skip urma_bind_jetty entirely */
}
urma_status_t status = umq_symbol_urma()->urma_bind_jetty(queue->jetty[i], tjetty);
```

CTP-mode UMQs (since `cfg->trans_mode == URMA_TM_RM` after the share_tp/OT coercion family) **never call bind_jetty**.

What happens instead: each `urma_post_jetty_send_wr(jetty, wr, &bad_wr)` carries `wr->tjetty` pointing at a target jetty. For each new `(local_eid, peer_eid)` pair the kernel sees on the SQ, it lazily looks up — or activates via `ubcore_active_tp` for CTP — a vtpn for that pair. The same `urma_jetty_t *jetty` handle can post to N different peers; the kernel allocates N vtpns, one per peer.

So the literal answer is:

> **The jetty isn't "bound" to anything in the RC-bind sense. In CTP mode, the underlying transport is RM. The jetty's SQ is the issuer; each post WR names its own target jetty; the kernel creates/reuses a vtpn per (local_eid, peer_eid) the SQ posts to. N peers → N vtpns → N active CTPs sharing this one local jetty.**

### 10.4 Concrete state diagram (1 jetty → N CTPs in RM/CTP mode)

```
                                      kernel TP table (per dev)
                                      ─────────────────────────────
                                       vtpn ──► CTP_1 (peer_eid=P1, tp_handle=H1)
                                                ▲
                                                │ active_tp_cfg, programmed via
                                                │ ubcore_active_tp → udma_active_tp
                                                │ → udma_ctrlq_set_active_tp_ex
                                                │
struct ubcore_jetty           vtpn hashtable    vtpn ──► CTP_2 (peer_eid=P2, tp_handle=H2)
  jetty_id (local)             (RM-indexed by    ▲
  trans_mode = RM              local_eid +       │
  /* no remote_jetty! */       peer_eid)         │
  SQ ─── post WR (tjetty=T1) ──┘                 │
  SQ ─── post WR (tjetty=T2) ────────────────────┘
  SQ ─── post WR (tjetty=T3) ──► vtpn ──► CTP_3 (peer_eid=P3, tp_handle=H3)
```

The same `struct ubcore_jetty` issues posts; each new peer EID it touches triggers `ubcore_connect_rc_vtp_ctrlplane` (CTP) or `ubcore_connect_vtp` (RTP) to land a vtpn for that peer. The "binding" is implicit in the per-WR target pointer.

---

## 11. Adjacent mechanisms that look like "1 jetty → N TPs" but aren't

Easy to confuse with §10 if you go looking — flagging them so the distinction stays clean:

### 11.1 Multi-path bonding

A *bonding device* has N physical sub-paths. One logical TP gets striped across those sub-paths by the driver below the jetty/vtpn layer. At the URMA API there's still one vtpn / one TP per peer; the multi-path nature is invisible at the ubcore level. The `--single_path` flag in perftest disables striping; with it the multi-path layer is exercised but doesn't change the binding model. References: `ubcore_get_path_set`, `multi_path` field, the `bondp_*` types in udma.

### 11.2 TP-cache pre-warming for multiple TP types

`udma_tp_cache_schedule_pair_direct` (`udma_tp_cache.c:741-`) pre-warms multiple TP *types* for the same `(local_eid, peer_eid)` pair:

```c
static const enum ubcore_transport_mode trans_modes[] = {
    UBCORE_TP_RM, UBCORE_TP_RC, UBCORE_TP_UM,
};
if (tp_type_mask & UDMA_TP_WARMUP_TP_CTP) cfg.flag.bs.ctp = 1;
if (tp_type_mask & UDMA_TP_WARMUP_TP_RTP) cfg.flag.bs.rtp = 1;
if (tp_type_mask & UDMA_TP_WARMUP_TP_UTP) cfg.flag.bs.utp = 1;
```

This is one CTP + one RTP + one UTP per peer pair — different *transport types*, not "two CTPs". The pre-warmup makes driver state hot for whichever a future bind might pick.

### 11.3 Jetty groups

`udma_jetty.c:403` `alloc_jetty_id(... jetty_grp)`. A `ubcore_jetty_group` aggregates *multiple struct ubcore_jetty objects* sharing some resource (typically RX JFC). The group has multiple jettys, each bound separately, each with its own TP. That's "N jettys → N TPs" inside one group, not "1 jetty → N TPs".

---

## 12. Summary table

| Scenario | One jetty → N TPs? | Mechanism |
| --- | --- | --- |
| Pure RC, no share_tp | **No** — strict 1:1 | `jetty->remote_jetty` check at `ubcore_jetty.c:2776` blocks rebind |
| RC + OT + share_tp=1 | **Yes, effectively** | `is_create_rc_shared_tp` triggers RM-style vtpn keying; bind still 1:1 at jetty struct level but vtpn layer indexes by `(local_eid, peer_eid)` |
| Pure RM (incl. CTP via ubsocket) | **Yes, natively** | No bind step; per-WR `tjetty` targeting; vtpn auto-allocated per `(local_eid, peer_eid)`; SQ drives arbitrary number of TPs |
| UM | **Yes** | Same as RM but unreliable |
| Bonding | "Multi-path within one TP" | Invisible to ubcore; below the abstraction |
| Jetty group | N jettys, each with one TP | Grouping, not 1→N |

For ubsocket / urma_perftest `--ctp`, the operative answer is **the third row**: an RM-keyed jetty whose SQ has posted to multiple peers, with the kernel activating a CTP-style TP for each one via `ubcore_active_tp` from the OOB-supplied tp_handles. The "binding" is per-WR, not per-jetty.

---

## 13. Quick reference — file:line index

| Topic | File:line |
| --- | --- |
| `ubcore_bind_jetty` (RTP API entry) | `drivers/ub/urma/ubcore/ubcore_jetty.c:2758` |
| `ubcore_bind_jetty_ex` (CTP API entry) | `drivers/ub/urma/ubcore/ubcore_jetty.c:2909` |
| Strict 1:1 rebind check | `drivers/ub/urma/ubcore/ubcore_jetty.c:2776` |
| `ubcore_inner_bind_ub_jetty` (RTP inner) | `drivers/ub/urma/ubcore/ubcore_jetty.c:2664` |
| `ubcore_inner_bind_ub_jetty_ctrlplane` (CTP inner) | `drivers/ub/urma/ubcore/ubcore_jetty.c:2812` |
| `ubcore_connect_vtp` (RTP allocator + CM send) | `drivers/ub/urma/ubcore/ubcore_vtp.c:1068` |
| `ubcore_connect_rc_vtp_ctrlplane` (CTP allocator + activate) | `drivers/ub/urma/ubcore/ubcore_vtp.c:1353` |
| `ubcore_active_tp` (HW program wrapper) | `drivers/ub/urma/ubcore/ubcore_vtp.c:1129` |
| `udma_active_tp` (driver impl) | `drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:981` |
| `udma_bind_jetty_ex` (driver bookkeeping) | `drivers/ub/urma/hw/udma/udma_jetty.c:1517` |
| `udma_main.c` ops table | `drivers/ub/urma/hw/udma/udma_main.c:323` (`bind_jetty_ex`), `:336` (`active_tp`) |
| `is_create_rc_shared_tp` (share predicate) | `drivers/ub/urma/ubcore/ubcore_priv.h:115` |
| `ubcore_set_vtp_param` (RC→RM coercion) | `drivers/ub/urma/ubcore/ubcore_vtp.c:2089-2104` |
| TP-cache pre-warming (multi-type per pair) | `drivers/ub/urma/hw/udma/udma_tp_cache.c:741-` |
| ubsocket-side skip when not RC | `src/hcom/umq/src/umq_ub/core/private/umq_ub.c:511-515` |
