# `urma_get_tp_list` cold-call mitigation

_Last updated: 2026-04-28._

The first user-space `urma_get_tp_list()` call against a never-before-seen `(local_eid, peer_eid, trans_mode)` tuple is slow. Once the kernel `ubcore` TP-node hash is populated, subsequent calls short-circuit cheaply. This doc explains why, and lays out the prewarm strategy for the case where peer EIDs are known at kernel-module init.

Sources:
- User-space URMA: `~/Documents/Repo/ub-stack/umdk/src/urma/`
- Kernel UB core: `~/Documents/Repo/ub-stack/kernel-ub/drivers/ub/urma/ubcore/`

Companion to [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md).

---

## 1. Call path

User → kernel:

| Layer | File:line | What happens |
| --- | --- | --- |
| Public API | `lib/urma/core/urma_cp_api.c:3053` | `urma_get_tp_list()` validates args + `trans_mode`, dispatches via provider ops |
| Provider hook | `lib/urma/core/include/urma_provider.h:133` | `ops->get_tp_list` function pointer |
| UDMA backend | `hw/udma/udma_u_ctrlq_tp.c:14` | `udma_u_ctrlq_get_tp_list` forwards to cmd layer |
| Cmd layer | `lib/urma/core/urma_cmd.c:2931` | Packs `urma_cmd_get_tp_list_t` (see `urma_cmd.h:1230`), issues ioctl, caps at `URMA_CMD_MAX_TP_NUM` = 128 |
| Ioctl | `lib/urma/core/urma_cmd_tlv.c:1421` | `urma_ioctl_get_tp_list` syscall into `uburma` |
| Kernel hot work | `kernel-ub/drivers/ub/urma/ubcore/ubcore_tp.c` | See §2 |

## 2. What actually costs on a cold call

In `ubcore_advise_tp` (`ubcore_tp.c:883`, `EXPORT_SYMBOL`), the cold path is:

1. `ubcore_lookup_tpnode(advice->meta.ht, advice->meta.hash, &advice->meta.key)` — hash miss on first call.
2. `ubcore_query_initiator_tp_cfg` → `ubcore_create_tp` allocates the local-side `struct ubcore_tp`.
3. `ubcore_add_tp_node` inserts it into the hash.
4. `ubcore_send_create_tp_req` (`ubcore_tp.c:599`) packs an `UBCORE_MSG_CREATE_VTP` payload and calls **`ubcore_send_fe2tpf_msg`** (`ubcore_tp.c:635`). This is the synchronous **FE → TPF (uvs/TPSA) → remote-TPF → remote-FE** netlink round-trip, plus HW QP allocate and INIT/RTR/RTS-equivalent state walk. Round-trip latency dominates everything else on this code path.

Once step 3 has run, the next call lands at `ubcore_tp.c:897-901`:

```c
tp_node = ubcore_lookup_tpnode(advice->meta.ht, advice->meta.hash, &advice->meta.key);
if (tp_node != NULL && tp_node->tp != NULL && !tp_node->tp->flag.bs.target) {
    ubcore_tpnode_kref_put(tp_node);
    return 0;          /* short-circuit — no FE→TPF round-trip */
}
```

So the slowness is purely a cold-cache problem.

## 3. Mitigation, ranked

### 3.1 Prewarm at module init via `ubcore_advise_tp`  *(recommended)*

You know the peer EIDs at module init. Spawn a workqueue that, for each peer, calls `ubcore_advise_tp(dev, remote_eid, advice, udata=NULL)`. By the time user code calls `urma_get_tp_list`, the `tp_node` hash is populated and the first call hits the §2 short-circuit.

```c
struct prewarm_ctx {
    struct work_struct       ws;
    struct ubcore_device    *dev;
    union ubcore_eid         eid;
    enum ubcore_transport_mode mode;
};

static void prewarm_one(struct work_struct *w)
{
    struct prewarm_ctx *c = container_of(w, struct prewarm_ctx, ws);
    struct ubcore_tp_advice advice = {0};

    /* meta.ht must be the same hash table the user-path will look up against;
       meta.key must be derived from (eid, mode) the way the user-path derives it.
       See ubcore_set_jetty_for_tp_param() for what fields TP creation actually
       reads, and ubcore_advise_tp() callers in uburma for the meta.* construction. */
    build_advice(&advice, c->dev, &c->eid, c->mode);
    (void)ubcore_advise_tp(c->dev, &c->eid, &advice, NULL);
}

static int __init mod_init(void)
{
    wq = alloc_workqueue("ub_prewarm", WQ_UNBOUND, 16);   /* parallelism */
    for_each_known_peer(p) {
        INIT_WORK(&ctx[p].ws, prewarm_one);
        queue_work(wq, &ctx[p].ws);
    }
    return 0;        /* don't block init — see §3.3 */
}
```

### 3.2 Parallelize the warm

Per-peer cost is dominated by the FE→TPF round-trip. Serializing N peers gives N × RTT. Use ≥8–16 workers. Cap N at the TPF concurrency budget; check `uvs` config if you push past 16.

### 3.3 Per-peer completions instead of blocking init

Don't `wait_for_completion` in `mod_init`. Hold one `struct completion` per peer. If a real `urma_get_tp_list` lands before its peer is warm, it waits on that single completion instead of itself doing a cold call. Worst case = unchanged; best case = zero wait.

### 3.4 Pre-resolve EID → net-addr only

If full TP create at init is too heavy (memory pinning, link-flap risk on early-boot networks), warm just the path cache via the `query` / `get_net_addr_list` ops in `kernel-ub/drivers/ub/urma/ubcore/ubcore_genl_admin.c` and `urma_cp_api`. Cuts cold-call cost by the path-lookup share, leaves TP create on the user's first send.

### 3.5 User-space TP-info cache

Even after the kernel hash is warm, every `urma_get_tp_list` still pays an ioctl + 128-entry `memcpy` (`urma_cmd.c:2954`). A thin shim around `urma_get_tp_list` keyed on `(local_eid, peer_eid, trans_mode, flag)` saves the syscall. Worth it when many user-space callers share the same tuple.

### 3.6 Bigger `tp_cnt` per call

`URMA_CMD_MAX_TP_NUM = 128` (`urma_cmd.h:1228`). If your workload needs multiple TPs per peer, one fat call beats N round-trips. Free win when applicable.

### 3.7 Skip the ioctl entirely for kernel consumers

If your module is *also* the consumer (data path stays kernel-side), drive `ubcore_advise_tp` / `ubcore_bind_tp` directly — no syscall, no `copy_from_user`, no per-call validation. No-op if your data path is user-space.

## 4. Don't bother

- **Extending the TLV protocol to batch peers in one ioctl.** The cost is the per-peer FE→TPF round-trip, not the syscall. Invasive change for negligible win.
- **"Skip `modify_tp` to RTS at init to save time."** You'd just pay it on the first send. Net zero.

## 5. Practical caveats

- **Device must be live.** `ubcore_send_create_tp_req` bails at `ubcore_tp.c:611` if `ubcore_check_dev_is_exist(dev->dev_name) == false`. If your module loads before the UB device is up, register a `ubcore_register_client` callback and prewarm from `add()`.
- **`udata == NULL` may not be enough for `advise_tp`.** The comment at `ubcore_tp.c:908-910` says "advise tp requires the user to pass in the pin memory operation and cannot be used in the uvs context ioctl to create tp." For a kernel-init prewarm without a real jetty, build a synthetic `meta.ht`/`meta.key`/`ta` matching what the user-path will later use, or fall back to lower-level `ubcore_create_tp` + `ubcore_add_tp_node` directly with a hash table you also expose to your data-path code.
- **Hash table identity.** The §2 short-circuit only fires if `advice->meta.ht` is the *same* hash table the user-path consults. Get this wrong and you populate a private cache that nothing reads. Verify by tracing a real user-path call and confirming it lands on the entry your prewarm inserted.

## 6. TL;DR

Prewarm a parallel workqueue calling `ubcore_advise_tp` per known peer EID at module init (or on the `ubcore` device-add callback). Don't block init — let real requests block on per-peer completions if they race. The first user `urma_get_tp_list` then becomes a hash hit at `ubcore_tp.c:898`.
