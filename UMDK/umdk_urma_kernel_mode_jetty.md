# Creating jettys inside the Linux kernel (incl. public-known IDs)

_Last updated: 2026-05-06._

URMA's jetty API has both a userspace surface (`urma_create_jetty` via `liburma`) and a kernel-mode surface (`ubcore_create_jetty` exported from `ubcore`). This doc covers the kernel-mode path: who uses it today, the recipe for a new in-kernel client, what's different from userspace, and how it interacts with public-known/well-known jetty IDs.

Companions:
- [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md) — the public-known ID concept itself
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer on jetty / EID / TP
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — the full setup sequence (kernel-mode follows the same six steps)

---

## 1. The API

Exported from `ubcore` (`kernel/include/ub/urma/ubcore_uapi.h`, `EXPORT_SYMBOL` at `ubcore_jetty.c:2198`):

```c
struct ubcore_jetty *ubcore_create_jetty(struct ubcore_device *dev,
                                         struct ubcore_jetty_cfg *cfg,
                                         ubcore_event_callback_t jfae_handler,
                                         struct ubcore_udata *udata);
```

Two key differences from the userspace `urma_create_jetty`:
- **`udata` is `NULL`** for kernel callers — that field carries user-context for ioctl-driven creates; kernel-mode has no userspace process attached.
- **No ioctl involved** — direct function call into ubcore. Validation runs in the same place (`udma_verify_jetty_type_urma_normal` in `udma_jetty.c:298+`), but reached without the user-kernel boundary crossing.

For a public-known/well-known ID, just put your reserved ID in `cfg.id` — the validation accepts it if it falls in `caps.public_jetty.range`.

## 2. Three live consumers — all in-tree

### IPoURMA (`kernel/drivers/ub/urma/ulp/ipourma/`)

`ipourma_res.c`:
```c
priv->jetty[eid_idx] = ipourma_create_jetty(dev,
                            IPOURMA_WELL_KNOWN_JETTY_ID + eid_idx, eid_idx);
```

The thin wrapper:
```c
static struct ubcore_jetty *ipourma_create_jetty(struct net_device *dev,
        u32 jetty_id, u32 eid_index)
{
    struct ubcore_jetty_cfg jetty_cfg = {0};
    ...
    jetty_cfg.id = jetty_id;                /* well-known ID */
    jetty_cfg.flag.bs.share_jfr = 1;
    ...
    return ubcore_create_jetty(priv->urma_dev, &jetty_cfg, NULL, NULL);
}
```

Pure kernel-mode. No userspace component. Canonical model.

### ubmgr ping (`kernel/drivers/ub/urma/ubcore/ubmgr/ubmgr_ping.c:537`)

```c
ctx->jetty = ubcore_create_jetty(dev, &jetty_cfg, NULL, NULL);
```

Cluster-wide health-probe protocol. Lives entirely in ubcore.

### UB MAD (`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c:420`)

```c
return ubcore_create_jetty(dev_priv->device, &jetty_cfg, NULL, NULL);
```

For UB management-class traffic (similar role to IB's MAD layer), kernel-resident.

All three pass `jfae_handler = NULL` and `udata = NULL`.

## 3. Recipe for a new in-kernel client

```c
#include <ub/urma/ubcore_types.h>
#include <ub/urma/ubcore_uapi.h>

struct ubcore_jetty *jetty;
struct ubcore_jetty_cfg cfg = {0};

/* 1. Pick a well-known ID in your reserved range — see the well-known
 *    jetty doc for who owns which ranges (bondp 0..1024, IPoURMA 32+, etc.)
 *    Or skip this and let the driver allocate dynamically by leaving cfg.id
 *    out of the public-jetty range. */
cfg.id = MY_PROTOCOL_WELL_KNOWN_JETTY_ID + my_index;

/* 2. Fill in the cfg. Match what IPoURMA does for a starting point. */
cfg.eid_index    = my_eid_index;            /* which local EID */
cfg.trans_mode   = UBCORE_TP_RM;            /* or RC depending on design */
cfg.jfs_depth    = MY_TX_DEPTH;
cfg.max_send_sge = MY_MAX_SGE;
cfg.send_jfc     = my_send_completion_q;    /* via ubcore_create_jfc */
cfg.recv_jfc     = my_recv_completion_q;
cfg.jfr          = my_recv_queue;           /* via ubcore_create_jfr */
cfg.flag.bs.share_jfr = 1;                  /* IPoURMA-style shared JFR */

/* 3. Call ubcore_create_jetty with udata=NULL (kernel mode). */
jetty = ubcore_create_jetty(my_ubcore_dev, &cfg,
                            NULL,           /* jfae_handler — NULL or async-event cb */
                            NULL);          /* udata — must be NULL for kernel */

if (IS_ERR_OR_NULL(jetty)) {
    pr_err("ubcore_create_jetty(id=%u) failed: %ld\n",
           cfg.id, PTR_ERR(jetty));
    return PTR_ERR(jetty);
}

/* jetty->jetty_id.id will equal cfg.id — confirm it round-tripped. */
WARN_ON(jetty->jetty_id.id != cfg.id);
```

### Prerequisites before the call

- A bound `struct ubcore_device *`. Register your kernel module as a ubcore client via `ubcore_register_client(&my_client)` and bind in `add()`/unbind in `remove()`.
- A `struct ubcore_jfc` (completion queue) — usually one for send, one for recv — created via `ubcore_create_jfc`.
- A `struct ubcore_jfr` (receive queue) — created via `ubcore_create_jfr`. With `share_jfr=1` you can share one JFR across multiple jettys, IPoURMA-style.
- A valid `eid_index` corresponding to the local EID this jetty will serve. Get it from the device's EID table.

## 4. What's different from userspace

| | Userspace | Kernel mode |
| --- | --- | --- |
| Entry point | `urma_create_jetty()` (liburma) | `ubcore_create_jetty()` |
| Goes through ioctl? | yes (`urma_cmd_create_jetty`) | no — direct call |
| `udata` parameter | meaningful (user driver context) | **NULL** |
| Validation site | userspace lib + kernel ioctl handler | kernel directly |
| Doorbell mapping | mmap'd into user address space | not needed — kernel callers post via `ubcore_post_send` |
| Per-process isolation (`uasid`) | derived from `current->tgid` | gets a kernel-default value |
| Memory registration | user-pin path | `dma_alloc_coherent` + `ubcore_register_seg` |
| Posting | `urma_post_jfs_wr` | `ubcore_post_send` family |

The validation logic in `udma_verify_jetty_type_urma_normal` (`udma_jetty.c:298+`) runs identically for both — checks `cfg.id` against `caps.public_jetty.range` regardless of the API entry point.

## 5. Caveats specific to kernel-mode

### 5.1 Page-size constraint still applies

Public-known jetty IDs require 4KB pages by default on the system (`udma_jetty.c:316, 341`). `well_known_jetty_pgsz_check=0` module param overrides on 64K-page ARM64 kernels. Same constraint as userspace — the check is at the HW page-mapping layer, not at the API surface.

### 5.2 `udata=NULL` semantics

The driver's user-buffer paths (e.g., user-pin operations for memory regions) are skipped for kernel callers. If your module needs registered memory:
- Allocate buffers with `dma_alloc_coherent` (or `kmalloc` + `dma_map_*` for streaming DMA).
- Register via the kernel-side memory APIs (`ubcore_register_seg`, etc.) — not the user-pin path.

### 5.3 Default-PID owner key

When kernel-resident jettys send, `udma_get_tp_list` runs in kernel context:
```c
if (current->flags & PF_KTHREAD)
    tp_cfg_req.flag = UDMA_DEFAULT_PID;
else
    tp_cfg_req.flag = (uint32_t)current->tgid & UDMA_PID_MASK;
```

So in-kernel callers (kthread context) all share `UDMA_DEFAULT_PID` as their owner key. This intersects with the unresolved owner-semantics question codex flagged in `udma_tp_cache.c`:
- **Good for cluster control plane**: kernel-resident protocols (IPoURMA, ubmgr) all share the same owner namespace, so they share TP-cache entries cleanly.
- **Bad for satisfying userspace requests**: if MUE treats `flag` as process-isolation, a TP warmed up in kernel mode under `UDMA_DEFAULT_PID` doesn't satisfy a later userspace caller with a different `tgid`. See [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) §1 for the full story.

### 5.4 ID range conflicts

The well-known range is conventionally subdivided:
- **0..1024** — bondp (`BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024`)
- **32..32+N_eids** — IPoURMA (`IPOURMA_WELL_KNOWN_JETTY_ID = 32`)
- ubmgr ping picks unique IDs above these.

Pick a new range that doesn't conflict. Land a `#define` somewhere shared (or in a new header in your subtree) and document it in this Docs-repo so future kernel clients can see what's reserved.

### 5.5 Posting from kernel uses different APIs

Once you have the jetty, kernel callers post WRs via the `ubcore_post_send` family, not the userspace `urma_post_jfs_wr`. Same WQE format, different entry point.

## 6. When to build a kernel-mode jetty

The pattern fits when:

- **You're a network-stack lower layer.** IPoURMA is the canonical case — IP traffic has to be a peer of the kernel's networking pipeline; can't be userspace.
- **You're cluster control plane.** ubmgr / MAD / health probes need to be live before userspace comes up, and they want to talk to every node without per-pair handshake.
- **You need to avoid the user/kernel ioctl boundary on the hot path.** Kernel-mode posts are slightly cheaper and entirely synchronous with the kernel's own preemption model — no copy_from_user, no syscall return path.
- **You're building a kernel-only consumer.** E.g., a swap-over-URMA driver, a kernel-resident filesystem hook, or a probe path that must run from interrupt/softirq context.

When userspace is sufficient, **prefer userspace** — it's simpler, isolated, and easier to debug. Kernel-mode is for the things that genuinely can't live anywhere else.

## 7. Quick TL;DR

```c
ubcore_create_jetty(dev, &cfg_with_id_and_other_fields, NULL, NULL);
```

That's the call. Use a public-known ID in `cfg.id` if you want bootstrap-without-handshake; use a non-reserved ID if dynamic per-connection allocation is fine. IPoURMA, ubmgr ping, and UB MAD all use this exact pattern. Validation runs identically to the userspace path; the only differences are the API entry point and `udata=NULL` for kernel callers.

## 8. References

- `kernel/include/ub/urma/ubcore_uapi.h` — `ubcore_create_jetty` declaration.
- `kernel/drivers/ub/urma/ubcore/ubcore_jetty.c:2118-2198` — implementation + `EXPORT_SYMBOL`.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_res.c` — IPoURMA's `ipourma_create_jetty` wrapper.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_types.h:55` — `IPOURMA_WELL_KNOWN_JETTY_ID = 32`.
- `kernel/drivers/ub/urma/ubcore/ubmgr/ubmgr_ping.c:537` — ubmgr ping using ubcore_create_jetty.
- `kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c:420` — UB MAD using ubcore_create_jetty.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:298+` — validation `udma_verify_jetty_type_urma_normal` (shared user/kernel).
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:316, 341` — page-size constraint (`well_known_jetty_pgsz_check`).
- `umdk/src/urma/lib/urma/bond/bondp_types.h:35` — `BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024`.
