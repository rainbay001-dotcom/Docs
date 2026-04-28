# How `umdk` interfaces with the UDMA TP-cache mitigation

_Last updated: 2026-04-28._

The codex `udma-tp-cache` mitigation lives entirely in the kernel UDMA provider. The user-space URMA stack (`umdk`) is a **transparent client** of the cached interface — no `umdk` patches are needed to benefit from the cache. This doc traces the end-to-end call path, identifies where the cache boundary sits, validates that the cache key matches the wire-format contract, and lays out the perftest-driven test matrix.

Companions:
- [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) — ubcore-level cold-call analysis
- [`umdk_get_tp_list_mitigation_plan.md`](../UMDK-codex/umdk_get_tp_list_mitigation_plan.md) — codex's full plan (in `UMDK-codex/`)
- [`umdk_ubse_peer_eid_discovery.md`](umdk_ubse_peer_eid_discovery.md) — feeding peer EIDs into warmup

Sources:
- `umdk` user-space: `git@atomgit.com:ray-yang0218/umdk.git` (cloned to `/Volumes/KernelDev/umdk`)
- `kernel` with codex patch: `/Volumes/KernelDev/kernel/`, branch `codex/udma-tp-cache`

---

## 1. End-to-end call path

```
APP (e.g. urma_perftest)
  │
  ▼
urma_get_tp_list(ctx, cfg, *tp_cnt, tp_list)         umdk: src/urma/lib/urma/core/urma_cp_api.c:3053
  │  arg validation, dispatches via provider ops
  ▼
ops->get_tp_list                                     umdk: src/urma/hw/udma/udma_u_ops.c:85
  │
  ▼
udma_u_ctrlq_get_tp_list(ctx, cfg, *tp_cnt, list)    umdk: src/urma/hw/udma/udma_u_ctrlq_tp.c:14
  │  thin pass-through, udata = {} (no user data)
  ▼
urma_cmd_get_tp_list(...)                            umdk: src/urma/lib/urma/core/urma_cmd.c:2931
  │  packs urma_cmd_get_tp_list_t.in:
  │    flag, trans_mode, local_eid, peer_eid, tp_cnt, udata
  ▼
urma_ioctl_get_tp_list(dev_fd, &arg)                 umdk: src/urma/lib/urma/core/urma_cmd_tlv.c:1421
  │  TLV-encodes 6 IN attrs, issues URMA_CMD_GET_TP_LIST
  │  ioctl on /dev/ub_uburma*
  ▼
============================== USER ↔ KERNEL ==============================
  ▼
[uburma → ubcore → udma]
  ▼
udma_get_tp_list()                                   kernel: drivers/ub/urma/hw/udma/udma_ctrlq_tp.c
  │  AFTER codex's patch the body is reduced to:
  ▼
udma_tp_cache_get_or_fetch(udev, cfg, tp_cnt,        kernel: drivers/ub/urma/hw/udma/udma_tp_cache.c
                           list, udata)
```

The cache replaces the hot body of the kernel `udma_get_tp_list`. Everything above the dotted line in `umdk` is unchanged and unaware.

## 2. What this design tells us

### 2.1 No user-space changes required

`urma_get_tp_list`'s ABI and the TLV ioctl wire format are unchanged. Existing `liburma` builds, third-party apps, and `urma_perftest` binaries keep working. Cache hits become invisibly faster; cache misses match current behavior. The kernel module-param `udma_tp_cache_enable=0` default makes deployment a sysfs toggle, not a recompile.

### 2.2 The cache key exactly mirrors the TLV IN attrs (plus two kernel-derived dimensions)

Compare the wire-format IN attributes (`urma_cmd_tlv.h:1238-1244`) with `struct udma_tp_cache_key` in `udma_tp_cache.c`:

| TLV IN attr (user-space contract) | Cache key field | Source |
| --- | --- | --- |
| `GET_TP_LIST_IN_FLAG` | `flag_value` | `cfg->flag.value` |
| `GET_TP_LIST_IN_TRANS_MODE` | `trans_mode` | `cfg->trans_mode` |
| `GET_TP_LIST_IN_LOCAL_EID` | `local_eid[16]` | `cfg->local_eid` |
| `GET_TP_LIST_IN_PEER_EID` | `peer_eid[16]` | `cfg->peer_eid` |
| `GET_TP_LIST_IN_TP_CNT` | (capacity, not in key) | request size, copied into reply |
| `GET_TP_LIST_IN_UDATA` | (intentionally ignored) | `udma_u_ctrlq` always sends `{}` |
| — (kernel-only) | `pid_key` | `udma_ctrlq_get_owner_key()` from `current->tgid` |
| — (kernel-only) | `trans_type`, `link_mode` | `udma_ctrlq_prepare_get_tp_list_req` canonicalization |

Two kernel-only key fields:

- **`pid_key`** is derived inside the kernel from `current->tgid` — `umdk` doesn't and shouldn't send it. It's the right scoping boundary because user-space can't trustworthy-self-attest its tgid; the kernel must compute it. This is also why warmup running under `UDMA_DEFAULT_PID` may not satisfy user-space callers (the unresolved owner-semantics question; see prewarm doc §1).

- **`trans_type` / `link_mode`** are canonicalizations of the user-supplied `flag` + `trans_mode` (CTP override → `UBCORE_TP_RM`; UB vs UBOE link mode based on `flag.bs.uboe`). The cache builds these the same way the original slow path did, *before* keying. Without canonicalization, two requests that hash to different keys but produce the same MUE response would miss each other; with it, they correctly share a cache entry.

### 2.3 The `udata` ignore is sound for this provider

`udma_u_ctrlq_get_tp_list` always passes `urma_cmd_udrv_priv_t udata = {}` (no user data tunneled). The codex cache's `(void)udata` with the comment "Keep the cache key limited to fields packed into the ctrlq request" is correct given this provider. **Caveat for future providers:** if any future user-space provider tunnels meaningful data through `udata` that affects the MUE response, the cache key would need updating to include those bytes. Today, the only provider is UDMA, and it sends nothing.

### 2.4 No user-space cache exists today

`udma_u_ctrlq_get_tp_list` (`udma_u_ctrlq_tp.c:14`) is a thin wrapper:

```c
int udma_u_ctrlq_get_tp_list(urma_context_t *ctx, urma_get_tp_cfg_t *cfg,
                             uint32_t *tp_cnt, urma_tp_info_t *tp_list)
{
    urma_cmd_udrv_priv_t udata = {};
    int ret = urma_cmd_get_tp_list(ctx, cfg, tp_cnt, tp_list, &udata);
    if (ret)
        UDMA_LOG_ERR("urma get tp list failed, ret = %d.\n", ret);
    return ret;
}
```

Every user-space call still pays the ioctl + memcpy round-trip even with the kernel cache fully warm. A `liburma`-side wrapper cache keyed on the same tuple would eliminate that, but it would be **per-process** so it cannot replace the kernel cache — only stack on top. The codex plan flagged this in §3.5 ("Userspace TP-info cache"); still worth doing as a follow-up if `urma_get_tp_list` shows up in user-space profiles after the kernel cache is warm.

## 3. Existing user-space "mitigation": `urma_perftest --tp_reuse`

At `src/urma/tools/urma_perftest/perftest_resources.c:1049-1053`:

```c
for (uint32_t i = 0; i < ctx->jetty_num; i++) {
    if (cfg->tp_reuse && cfg->trans_mode == URMA_TM_RM && i > 0) {
        ctx->tp_info[i] = ctx->tp_info[0];
        continue;
    }
    ...
    int ret = urma_get_tp_list(ctx->urma_ctx, &tp_cfg, &tp_cnt, &ctx->tp_info[i]);
```

This is the prior art the codex plan flagged as narrow. Hard-coded to `URMA_TM_RM` and only after `i==0`. With the kernel cache enabled and `tp_reuse=0`, all `jetty_num` calls hit the same cache entry — same outcome as `tp_reuse=1`, but generalized to all transport modes (RC + UM benefit too) and applicable beyond perftest. Once the cache is on by default and proven, the perftest `tp_reuse` short-circuit becomes redundant for the cache-warm case but harmless when the cache is off.

## 4. Cache-invalidation triggers, viewed from the user-space side

Every user-space TP-lifecycle action that should invalidate the cache eventually crosses a kernel hook the codex patch wires up. There is no missing trigger from user-space that the cache would silently miss.

| User-space action | Crosses ioctl | Kernel cache hook |
| --- | --- | --- |
| `urma_modify_tp(ctx, tpn, ..., DEACTIVATE)` | `URMA_CMD_MODIFY_TP` | `udma_k_ctrlq_deactive_tp` → `udma_ctrlq_erase_one_tpid` → `udma_tp_cache_invalidate_tpid` |
| Process exit / `urma_delete_context` | `URMA_CMD_DELETE_CONTEXT` | `udma_free_ucontext` → `udma_tp_cache_flush_pid(ctx->tp_cache_owner_key)` |
| Device reset / module unload | (driver-side) | `udma_reset_down` / `udma_tp_cache_destroy` → `udma_tp_cache_flush` + `cancel_warmup` |
| TPID rollback during `store_tpid_list` failure | (in-kernel) | `udma_ctrlq_erase_one_tpid` → invalidate (same as deactivate path) |

## 5. Test matrix using `urma_perftest`

Easy validation matrix. Read the debugfs `tp_cache/stats` (added in codex commit `97bb32b4`) before and after each test to confirm expected behavior.

| perftest flags | What it exercises | Expected with cache enabled |
| --- | --- | --- |
| `--tp_reuse=0 -j 64 -m rm` | 64 identical RM `get_tp_list` calls | `ctrlq_fetch_cnt += 1`, `hit_cnt += 63`, `lookup_cnt += 64` |
| `--tp_reuse=1 -j 64 -m rm` | 1 actual call (existing optimization) | `ctrlq_fetch_cnt += 1`, `hit_cnt += 0` — behavior unchanged from today |
| `--tp_reuse=0 -j 64 -m rc` | 64 identical RC calls (outside perftest's prior optimization scope) | `ctrlq_fetch_cnt += 1`, `hit_cnt += 63` — **net new improvement over `tp_reuse`** |
| `--tp_reuse=0 -m rm`, then `urma_modify_tp ... DEACTIVATE` jetty 0, then `--tp_reuse=0 -j 64 -m rm` | invalidation + re-warm | `invalidate_tpid_cnt += 1`, then `ctrlq_fetch_cnt += 1`, then `hit_cnt += 63` |
| Two `urma_perftest` processes, same EID pair, same time | `pid_key` partitioning | `ctrlq_fetch_cnt += 2` (one per process), no cross-process sharing |
| Reset device while perftest running | reset path teardown | `flush_cnt += 1`, `warmup_cancel_cnt += 1` (if warmup was active), in-flight requests get `-EAGAIN` |

For each row, expected behavior is computable from the counters; no need to read kernel logs to verify.

## 6. Follow-up opportunities (neither blocking)

**6.1 User-space wrapper cache in `liburma`.** Add a thin per-process cache around `urma_cmd_get_tp_list` keyed on the same tuple as the kernel cache (minus `pid_key`, which is process-self by definition). Skips the ioctl entirely on warm calls. Worth doing if profiling after the kernel cache is on shows `urma_get_tp_list` still costing measurable user CPU time.

**6.2 Generalize perftest's `tp_reuse`.** Once the kernel cache is enabled by default and proven, either:
- Drop the `URMA_TM_RM` constraint in `perftest_resources.c:1050` so it covers RC and UM too, or
- Add an explicit `--no_tp_reuse` mode that disables the short-circuit so cache effects are observable in benchmarks (currently with `tp_reuse=1` the cache provides no speedup because the ioctl never runs).

## 7. Summary

`umdk` is the **read side** of the cache contract:

- ABI unchanged; no user-space patches needed.
- 6-attr TLV wire format is the contract; cache keys on those 6 plus 2 kernel-derived canonicalizations.
- All user-space TP-lifecycle actions that should invalidate the cache eventually trigger a kernel hook the codex patch wires up.
- `urma_perftest` provides ready-made validation paths for every cache behavior; debugfs `tp_cache/stats` makes the validation script-able.
- Two follow-ups (user-space wrapper, generalize `tp_reuse`) are clean small additions, not prerequisites.
