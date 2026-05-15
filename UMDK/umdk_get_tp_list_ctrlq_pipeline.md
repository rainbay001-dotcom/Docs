# `get_tp_list` — ubcore → UDMA → ubase ctrlq pipeline

_Created 2026-05-14. Pins the four functions that show up when reading a stack trace around `get_tp_list`: `ubcore_get_tp_list`, `udma_get_tp_list`, and the ubase ctrlq send/complete primitives that are commonly (mis-)remembered as `udma_ctrlq_send` / `udma_ctrlq_complete`._

## 0. Scope and companions

Covers what executes from `ubcore_get_tp_list` down to the firmware doorbell and back up through the CRQ ISR. Pairs with:

- [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) — the **userspace → ubcore** half (cold-call mitigation, TP-node hash, prewarm strategy).
- [`umdk_urma_jetty_kernel_call_trace.md`](umdk_urma_jetty_kernel_call_trace.md) — broader ubcore call trace; §4.7 and §4.11 cite this pipeline by reference.
- [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) — UDMA hot path overview; ctrlq is the slow/control plane counterpart.
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) — first-RPC link setup; §10.30 identifies firmware ctrlq as the bottleneck this pipeline bottoms out at.

Source tree (canonical for kernel work): `/Volumes/KernelDev/kernel/drivers/ub/`.

---

## 1. The four names

| Name | Real symbol? | File:line | Role |
|---|---|---|---|
| `ubcore_get_tp_list` | yes, EXPORT_SYMBOL | `urma/ubcore/ubcore_tp.c:26` | Generic ubcore entry; arg validation + timing wrapper around `dev->ops->get_tp_list`. |
| `udma_get_tp_list` | yes | `urma/hw/udma/udma_ctrlq_tp.c:652` | UDMA driver's `dev->ops->get_tp_list`. Three-line wrapper into the TP cache. |
| `udma_ctrlq_send` | **no** | n/a | Shorthand for `ubase_ctrlq_send_msg` (`ubase/ubase_ctrlq.c:926`, EXPORT_SYMBOL) and its `__ubase_ctrlq_send` / `ubase_ctrlq_send_real` internals. |
| `udma_ctrlq_complete` | **no** | n/a | Shorthand for the CRQ-side completion notifier `ubase_ctrlq_notify_completed` (`ubase/ubase_ctrlq.c:1057`), called from `ubase_ctrlq_handle_crq_msg` (`:1131`). |

The send/complete primitives are **not** UDMA-owned — UDMA is one consumer of `ubase_ctrlq_send_msg`. ubdevshm, ubmempfd, qos_hw and others use the same primitive.

---

## 2. The pipeline

```
caller (uburma ioctl / ubcore_connect_adapter / ub_mad)
        │
        ▼
ubcore_get_tp_list                          ubcore_tp.c:26
  • NULL-check dev/ops/cfg/tp_cnt/tp_list
  • ubcore_check_trans_mode_valid(cfg->trans_mode)
  • ktime_get_ns() bracket
  • ret = dev->ops->get_tp_list(dev, cfg, tp_cnt, tp_list, udata);
  • log "[DRV_INFO]get_tp_list consumes: %llu" if duration > UBCORE_DRV_TP_THRESHOLD_MS
        │       (function-pointer dispatch via ops table)
        ▼
udma_get_tp_list                            udma_ctrlq_tp.c:652
  return udma_tp_cache_get_or_fetch(udev, cfg, tp_cnt, tp_list, udata);
        │
        ▼
udma_tp_cache_get_or_fetch                  udma_tp_cache.c:516
   → udma_tp_cache_get_or_fetch_owner       udma_tp_cache.c:372
  • build cache key; hash lookup under cache->lock
  • HIT (entry && !expired)                 ─► udma_tp_cache_finish_entry → return  (fast path)
  • singleflight (entry->filling)           ─► wait on entry->fill_done, then finish
  • MISS                                    ─► allocate entry, drop lock, ↓
        │
        ▼
udma_tp_cache_fetch_rsp                     udma_tp_cache.c:245
   → udma_ctrlq_fetch_tpid_list             udma_ctrlq_tp.c:606
  • msg.opcode = UDMA_CMD_CTRLQ_GET_TP_LIST
  • udma_ctrlq_set_tp_msg(&msg, req, sizeof(req), rsp, sizeof(rsp))
  • ret = ubase_ctrlq_send_msg(udev->comdev.adev, &msg);   ◄── "udma_ctrlq_send"
        │
        ▼
ubase_ctrlq_send_msg                        ubase_ctrlq.c:926   (EXPORT_SYMBOL)
   → __ubase_ctrlq_send                     ubase_ctrlq.c:884
   → ubase_ctrlq_send_real                  ubase_ctrlq.c:820
  • alloc seq under csq->lock
  • addto_msg_queue(udev, seq, msg, ue_info)  — ctx = &msg_queue[seq % depth]
  • init/reinit ctx->done; ctx->out, ctx->out_size, ctx->is_sync
  • fill base block; ubase_ctrlq_send_msg_to_sq()           ─► doorbell firmware
  • if sync_req:
      ret = ubase_ctrlq_wait_completed(udev, seq, msg);
              └─ wait_for_completion_timeout(&ctx->done, …) ─► BLOCKS here
  • retry loop on -ETIMEDOUT (up to UBASE_CTRLQ_RETRY_TIMES)
                       ▲
                       │ (firmware posts response onto CRQ; CRQ ISR fires)
                       │
ubase_ctrlq_handle_crq_msg                  ubase_ctrlq.c:1131
  • is_pushed bit / seq lookup
  • ctx = &msg_queue[seq % depth]; check ctx->valid + ctx->is_sync
  • if sync → ubase_ctrlq_notify_completed(...)
   └─ ubase_ctrlq_notify_completed          ubase_ctrlq.c:1057   ◄── "udma_ctrlq_complete"
        ctx->result = head->ret
        memcpy(ctx->out, msg, min(msg_len, ctx->out_size))
        complete(&ctx->done)
                       │
                       ▼
        (sender wakes, returns up the stack;
         UDMA stores tpid list via udma_ctrlq_store_tpid_list,
         caches the response, hands tp_list back to ubcore_get_tp_list)
```

## 3. Key relationships

### 3.1 `ubcore_get_tp_list` is the ops-table trampoline

Owns no per-driver state. Three jobs only: validate args, time the dispatch, and call `dev->ops->get_tp_list`. The ops table is populated at driver attach — for UDMA at `urma/hw/udma/udma_main.c:333` (`.get_tp_list = udma_get_tp_list`).

Callers in the kernel tree (all go through this exact validation):

| Caller | File:line | Context |
|---|---|---|
| `uburma_cmd_get_tp_list` | `urma/uburma/uburma_cmd.c:4545` | UAPI ioctl from urma_admin / urma_perftest |
| `ubcore_send_create_tp_req` flow | `urma/ubcore/ubcore_connect_adapter.c:679` | Cold-create path in `ubcore_advise_tp` |
| `ubcore_connect_adapter` | `:732, :1133, :1184, :1307` | TP create / migrate / restore paths |
| `ubmad_post_send` cold path | `urma/ubcore/ubcm/ub_mad.c:550` | UBMAD-side TP resolve for WK jetty link setup |

Same trampoline, same firmware round-trip cost — only the trigger differs.

### 3.2 `udma_get_tp_list` is a 3-line shim into the TP cache

```c
int udma_get_tp_list(struct ubcore_device *dev, struct ubcore_get_tp_cfg *tpid_cfg,
                     uint32_t *tp_cnt, struct ubcore_tp_info *tp_list,
                     struct ubcore_udata *udata)
{
    struct udma_dev *udev = to_udma_dev(dev);
    return udma_tp_cache_get_or_fetch(udev, tpid_cfg, tp_cnt, tp_list, udata);
}
```

All UDMA-specific logic — singleflight TTL cache, build_key, fetch_rsp, copy_rsp, store_tpid_list — lives one layer deeper in `udma_tp_cache.c`. The cache is the only thing that distinguishes a fast call from a slow call; with `udma_tp_cache_enable=0` or no cache attached, every call short-circuits to `udma_tp_cache_fetch_uncached` and pays full firmware round-trip cost.

### 3.3 Send and complete are **not** in UDMA — they live in ubase

UDMA formats a `struct ubase_ctrlq_msg` (opcode `UDMA_CMD_CTRLQ_GET_TP_LIST`, `in_addr/in_size = req`, `out_addr/out_size = rsp`) and hands it to `ubase_ctrlq_send_msg`. Everything from that point on — sequence-number allocation, CSQ ring post, doorbell, sleeper bookkeeping, retry loop, ISR-side response demux, completion firing — lives in `drivers/ub/ubase/ubase_ctrlq.c`.

This is why `udma_ctrlq_send` / `udma_ctrlq_complete` aren't symbols: there's no UDMA layer for them. UDMA is a *user* of the ubase ctrlq bus, alongside ubdevshm, ubmempfd, ubase_qos_hw, etc. Search hits for `ubase_ctrlq_send_msg` in `urma/hw/udma/`:

```
udma_ctrlq_tp.c   13 call sites  (get_tp_list, active_tp, modify_tp, …)
udma_eq.c          2 call sites  (eid_update_response, eid_guid_response)
udma_main.c        ⟨ via ops registration only ⟩
```

### 3.4 Send ↔ complete rendezvous on `ctx->done`

`ubase_ctrlq_msg_ctx` is a slot in `udev->ctrlq.msg_queue[]`, keyed by `seq % depth`:

```c
struct ubase_ctrlq_msg_ctx {
    struct completion done;
    void *out;
    u16   out_size;
    int   result;
    u8    is_sync;
    u8    valid;
    /* … */
};
```

- **Sender** (in `ubase_ctrlq_send_real`, `ubase_ctrlq.c:820-882`):
  1. `ubase_ctrlq_alloc_seq()` under `csq->lock` → unique 16-bit seq.
  2. `ubase_ctrlq_addto_msg_queue()` populates `ctx = &msg_queue[seq % depth]` (`ctx->out`, `ctx->is_sync`, `init_completion(&ctx->done)`).
  3. `ubase_ctrlq_send_msg_to_sq()` writes the request blocks into CSQ ring, rings doorbell.
  4. If sync request → `ubase_ctrlq_wait_completed(udev, seq, msg)` → `wait_for_completion_timeout(&ctx->done, …)` (`ubase_ctrlq.c:662`). **Blocks the calling thread.**
  5. Retry loop on `-ETIMEDOUT`, up to `UBASE_CTRLQ_RETRY_TIMES`.

- **Completer** (CRQ ISR path, `ubase_ctrlq.c:1057,1131`):
  1. CRQ ISR drains response blocks → `ubase_ctrlq_handle_self_msg` → `ubase_ctrlq_handle_crq_msg`.
  2. Decode `seq` from response head; `ctx = &msg_queue[seq % depth]`.
  3. Sanity-check `ctx->valid`; if `ctx->is_sync`, call `ubase_ctrlq_notify_completed`.
  4. Notifier copies `head->ret` into `ctx->result`, `memcpy(ctx->out, msg, min(msg_len, ctx->out_size))`, then `complete(&ctx->done)`.

That's the one-to-one send↔complete rendezvous; everything around it (CSQ ring management, retry, error mapping) is dressing.

### 3.5 Where time goes — and why this matters

Every cost in the chain bottoms out at `wait_for_completion_timeout` in `ubase_ctrlq_send_real:865`. That's firmware queue depth + firmware processing time + CRQ ISR latency. Cache hits avoid this entirely; cache misses serialize on it.

Implications:

- A `[DRV_INFO]get_tp_list consumes: …ms` log line is the smoke; the fire is firmware ctrlq backlog.
- The `udma_tp_cache` TTL/singleflight machinery in `udma_tp_cache.c` is the *only* lever inside UDMA to reduce firmware ctrlq traffic for `get_tp_list`. The prewarm path (`umdk_udma_warmup_deployment.md`, `umdk_get_tp_list_prewarm.md`) populates this cache before user workload arrives.
- Concurrent `get_tp_list` callers on different keys all queue on the same `ctrlq.csq` ring; per-call latency degrades with concurrency even when each call is independent. This is the smoking gun §10.30 of `umdk_link_setup_timing.md` flagged.

### 3.6 Symmetric path you'll see in the same traces

`udma_ctrlq_set_active_tp_ex`, `udma_ctrlq_modify_tpc`, EID-add/EID-guid responses (`udma_eq.c`), and several others follow the same pattern: build `ubase_ctrlq_msg`, set opcode, call `ubase_ctrlq_send_msg`, block on `wait_for_completion_timeout`, complete from CRQ ISR via `ubase_ctrlq_notify_completed`. Only the opcode and req/rsp payload structs differ. There are **13** such call sites in `udma_ctrlq_tp.c` alone.

---

## 4. Quick reference — what each frame in a stack trace means

When you see a stack trace like:

```
[<...>] wait_for_completion_timeout
[<...>] ubase_ctrlq_wait_completed
[<...>] ubase_ctrlq_send_real
[<...>] __ubase_ctrlq_send
[<...>] ubase_ctrlq_send_msg
[<...>] udma_ctrlq_fetch_tpid_list
[<...>] udma_tp_cache_fetch_rsp
[<...>] udma_tp_cache_get_or_fetch_owner
[<...>] udma_tp_cache_get_or_fetch
[<...>] udma_get_tp_list
[<...>] ubcore_get_tp_list
[<...>] uburma_cmd_get_tp_list                  (or ub_mad / connect_adapter)
[<...>] uburma_ioctl
```

interpret it as:

| Top → bottom | Meaning |
|---|---|
| `wait_for_completion_timeout` | Blocked on firmware response. |
| `ubase_ctrlq_*` (4 frames) | Ubase ctrlq send + sleep. |
| `udma_ctrlq_fetch_tpid_list` | Built the GET_TP_LIST request, handed it to ubase. |
| `udma_tp_cache_*` (3 frames) | TP cache miss path — `udma_tp_cache_get_or_fetch_owner` is where the lock dance + entry allocation happens. |
| `udma_get_tp_list` | Driver's ops entry — 3-line shim. |
| `ubcore_get_tp_list` | Generic ubcore entry — validation + timing. |
| Caller | One of the four trampoline call sites in §3.1. |

If `udma_tp_cache_*` is absent from the trace, the cache short-circuited: `udma_tp_cache_finish_entry` returns directly from a HIT. That's the desired state for steady-state perftest.
