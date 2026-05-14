# URMA jetty — end-to-end call trace (userspace → ubcore kernel → driver)

_Created 2026-05-14. Self-contained reference combining the userspace + ubturbo plugin walkthrough with the OLK-6.6 ubcore kernel internals._

## 0. Scope and companions

This doc traces what actually executes in the URMA stack when an application creates, imports, posts on, and tears down a jetty — focusing on **function-level call chains with `file:line` citations**.

It pairs with:
- [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md) — concept-level treatment of public/well-known jetty (UDMA reservation + UBMAD/UBCM consumer).
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — jetty / EID / JFS / JFR primer.
- [`umdk_urma_kernel_mode_jetty.md`](umdk_urma_kernel_mode_jetty.md) — in-kernel mode jetty usage.
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — TP / vTP setup (this doc references but doesn't duplicate).
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) — first-RPC link setup.

Source trees referenced:
- Userspace UMDK: `~/Documents/Repo/ub-stack/umdk/`
- In-kernel UB driver (richer copy): `/Volumes/KernelDev/kernel/drivers/ub/`
- Reference kernel-mode consumer: `~/Documents/Repo/ubturbo/plugins/ubdma/`
- UBSE userspace: `/Volumes/KernelDev/ubs-engine/`

---

## 1. What a jetty is, and what "public / well-known jetty" means

A **jetty** is a URMA transport endpoint = `JFS (send queue) + JFR (recv queue) + JFC (completion queue)`. Analogous to an IB QP, but identified by `(eid, uasid, id)` where `id` is a numeric handle.

Two transport flavors:
- **RM mode** — Reliable Multipath, CTP transport, no pre-binding, survives single-path failure. Used by hot-migration and HCOM bootstrap.
- **RC mode** — Reliable Connection, TP transport, must call `urma_bind_jetty()` after import. Used by URPC, dlock, regular HCOM.

A **well-known / public jetty** has its `id` taken from a reserved low range so both ends can derive the target without prior handshake (analogue: TCP port 22).

Two layers of reservation in tree:

| Layer | Range | Identifier in source | File:line |
|---|---|---|---|
| UDMA HW provider cap | `well_known_jetty_start .. start+num` | `caps.public_jetty`, `well_known_jetty_start / well_known_jetty_num` | `~/Documents/Repo/ub-stack/umdk/...udma_cmd.h:199-200`; ubase `public_jetty_cnt` field in `ubase_comm_dev_cap` |
| UMDK bondp ceiling | `[0, 1024)` | `BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024` | `~/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/bondp_types.h:35` |
| UBMAD/UBCM control plane | `id = 1, 2` (link-setup MAD) | `UBMAD_WK_JETTY_ID_0/1` | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:20-21` |
| UBSE listen jetty | `id = 999` | `URMA_LISTEN_JETTY` | `/Volumes/KernelDev/ubs-engine/src/include/ubse_common_def.h:77` |

Application jetties get IDs above the cap reservation; typical app code starts at `1024+`. The UBSE `--client_jetty_id=1000` (`sys_sentry_module.cpp:265`) is itself a control-plane caller jetty.

---

## 2. Data model (kernel side)

### Local jetty — `struct ubcore_jetty`

Allocated by driver via `dev->ops->create_jetty`, extended by ubcore. Key fields:

- `jetty_id.{eid, id}` — set from `dev->eid_table.eid_entries[cfg->eid_index].eid` at `ubcore_jetty.c:2155`
- `jetty_cfg` — frozen copy of `ubcore_jetty_cfg` via `check_and_fill_jetty_attr()` (`ubcore_jetty.c:1686-1711`)
- `ub_dev` — backpointer (line 2140)
- `tptable` — `struct ubcore_hash_table *`, allocated only if `trans_mode == UBCORE_TP_RC` (line 2157), else NULL (line 2165)
- `use_cnt` (atomic), `ref_cnt` (kref), `comp` (completion) — init lines 2168-2170
- `jetty_opt.is_actived` — set true on full success (line 2187)
- `hnode` — registered into `dev->ht[UBCORE_HT_JETTY]` (line 2173)

### Remote jetty — `struct ubcore_tjetty`

Result of `ubcore_import_jetty`. Key fields:

- `cfg` — copy of `ubcore_tjetty_cfg` with `{remote_eid, remote_jetty_id, token, trans_mode}` (line 2504)
- `vtpn` — `struct ubcore_vtpn *`, lazily set up for RM/UM/RC modes (line 2530)
- `tp` — set to NULL for non-vTP modes (line 2533)
- `use_cnt`, `lock` — atomic + mutex (lines 2508-2509)

### Virtual TP — `struct ubcore_vtpn`

The connection bookkeeping behind a tjetty. Built by `ubcore_alloc_vtpn` (`ubcore_vtp.c:797`):

- `trans_mode`, `local_eid`, `peer_eid`, `eid_index`, `local_jetty`, `peer_jetty` — copied from `ubcore_vtp_param` (lines 816-821)
- `state` — state machine: `UBCORE_VTPS_RESET → UBCORE_VTPS_READY` (lines 822, 1109) or `UBCORE_VTPS_WAIT_DESTROY` on failure (line 1111)
- `state_lock` — mutex (line 823)
- `list`, `disconnect_list` — async wait/callback lists (line 824)

### TP table — `struct ubcore_hash_table`

Per-jetty (RC mode only) map from `ubcore_tp_key` → `ubcore_tp_node`. Each node:

- `key` (copy of caller key), `tp` (TP reference), `ref_cnt` (kref), `lock`, `comp`
  — `ubcore_tp_table.c:183-188`
- Insert / lookup are spin-locked over `ht->lock` and call the generic `ubcore_hash_table_{add,lookup}_nolock` helpers (lines 190-210).

---

## 3. Kernel-mode jetty example — ubturbo `ubdma` plugin

Cleanest in-tree consumer of jetty from kernel context. Path: `~/Documents/Repo/ubturbo/plugins/ubdma/src/urma.c`.

### 3.1 Server-side init — `init_urma_mem_trans()` @ urma.c:335

```
init_urma_mem_trans()                                            [urma.c:335]
  → ubcore_register_client(&urma_ubcore_client)                  [urma.c:347]
    ↳ kernel enumerates UB devices → urma_add_device()           [urma.c:302]
  → get_trans_entity(g_urma_jetty)                               [urma.c:372]
    ↳ picks dev + EID via ubcore_get_eid_list()
  → create_jfc(g_urma_jetty, NULL)        → server_jfc           [urma.c:379]
  → create_jfc(g_urma_jetty, jfce_handler)→ client_jfc           [urma.c:386]
    ↳ ubcore_create_jfc(dev, cfg, jfce_handler, NULL, NULL)
    ↳ ubcore_rearm_jfc(client_jfc, false)                        [urma.c:392]
  → create_client_jfs(g_urma_jetty)                              [urma.c:242]
    ↳ ubcore_create_jfs(dev, &cfg, NULL, NULL)
       cfg.depth = UB_DMA_JETTY_DEPTH (1024)   [urma.h:13, urma.c:48]
       cfg.jfc   = client_jfc
  → create_server_jfr(g_urma_jetty)                              [urma.c:251]
    ↳ ubcore_create_jfr(dev, &cfg, NULL, NULL)
       cfg.jfc = server_jfc
  → import_server_jfr(g_urma_jetty)                              [urma.c:260]
    ↳ build ubcore_tjetty_cfg from server_jfr attrs
    ↳ ubcore_import_jfr(dev, &cfg, NULL)
       → dev->ops->import_jetty(dev, cfg, udata)
       → if RM/UM, ubcore_connect_vtp() lazily builds vTP
       → returns ubcore_tjetty * → g_urma_jetty->tjetty
```

`g_urma_jetty` (`urma.c:29`, `urma.h:38`) is the global handle holding `dev`, `eid_info`, paired CQs, one SQ, one RQ, and the `tjetty` post target.

### 3.2 Datapath — `urma_run_send()` @ urma.c:220

```
urma_run_send(src_va, dst_va, src_seg, dst_seg, len)             [urma.c:220]
  → mutex_lock(&g_urma_jetty->mutex_lock)
  → post_client_jfs(...)                                          [urma.c:156]
    ↳ init_wr_list(tjetty, src_seg, dst_seg, &wr, ...)            [urma.c:107]
        wr.opcode  = UBCORE_OPC_WRITE
        wr.tjetty  = g_urma_jetty->tjetty
        SGEs filled from pre-imported segs
    ↳ ubcore_post_jfs_wr(client_jfs, wr, &fail_wr)               [ubcore_dp.c:64-78]
        → dev->ops->post_jfs_wr(jfs, wr, bad_wr)
            (provider, e.g. hns3_udma): encode SQE, bump PI, MMIO doorbell
  → mutex_unlock(&g_urma_jetty->mutex_lock)

completion:
  HW finishes → CQE on client_jfc → jfce_handler() (registered at urma.c:386)
    ↳ drain via ubcore_poll_jfc()                                 [ubcore_dp.c:98-110]
```

Segments are imported separately from jetties: `init_segment` (urma.c:186) + `ubcore_import_seg` (urma.c:199) at registration time produce the `ubcore_target_seg`s consumed by WRs.

### 3.3 Teardown — `release_urma_mem_trans()` @ urma.c:442

```
release_urma_mem_trans()                                         [urma.c:442]
  → ubcore_unimport_jfr(tjetty)
      ↳ if RM/UM: ubcore_disconnect_vtp(tjetty->vtpn)
      ↳ dev->ops->unimport_jetty(tjetty)
  → ubcore_delete_jfr(server_jfr)
  → ubcore_delete_jfs(client_jfs)
  → ubcore_delete_jfc(client_jfc) ; ubcore_delete_jfc(server_jfc)
  → ubcore_unregister_client(&urma_ubcore_client)               [urma.c:458]
```

---

## 4. ubcore kernel internals (OLK-6.6)

All paths below are relative to `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/`.

### 4.1 `ubcore_create_jetty()` — `ubcore_jetty.c:2118`

Signature (exported at line 2198):

```c
struct ubcore_jetty *ubcore_create_jetty(
    struct ubcore_device *dev,
    struct ubcore_jetty_cfg *cfg,
    ubcore_event_callback_t jfae_handler,
    struct ubcore_udata *udata);
```

Call walk:

```
ubcore_create_jetty(dev, cfg, jfae_handler, udata)               [ubcore_jetty.c:2118]
  ── argument & ops validation                                    [2126-2129]
       dev / cfg / dev->ops / ops->create_jetty / ops->destroy_jetty
       ubcore_eid_valid(dev, cfg->eid_index, udata)
  ── ubcore_jetty_pre_check(dev, cfg)                             [2131 → 2095]
        check_jetty_cfg(dev, cfg)                                 [2099]   ; trans_mode, jfc, jfr compat
        check_jetty_cfg_with_jetty_grp(cfg)                       [2104]   ; jetty group constraints
        check_jetty_check_dev_cap(dev, cfg)                       [2109]   ; device-cap matching
  ── driver allocation
        jetty = dev->ops->create_jetty(dev, cfg, udata)           [2134]
        UBCORE_CHECK_RETURN_ERR_PTR(...)                          [2137]
  ── jetty metadata
        jetty->ub_dev = dev                                       [2140]
        if (cfg->jetty_grp)
            ubcore_add_jetty_to_jetty_grp(jetty, cfg->jetty_grp)  [2143]
        check_and_fill_jetty_attr(&jetty->jetty_cfg, cfg)         [2148 → 1686-1711]
        jetty->uctx          = ubcore_get_uctx(udata)             [2153]
        jetty->jfae_handler  = jfae_handler                       [2154]
        jetty->jetty_id.eid  = dev->eid_table.eid_entries[idx].eid [2155]
  ── tptable (RC only)
        if (trans_mode == UBCORE_TP_RC)
            jetty->tptable = ubcore_create_tptable()              [2157 → tp_table.c:97-118]
        else
            jetty->tptable = NULL                                 [2165]
  ── refcount + register
        atomic_set(&jetty->use_cnt, 0)                            [2168]
        kref_init(&jetty->ref_cnt)                                [2169]
        init_completion(&jetty->comp)                             [2170]
        ubcore_hash_table_find_add(&dev->ht[UBCORE_HT_JETTY],
                                   &jetty->hnode, jetty->jetty_id.id)  [2173]
  ── bump JFC / JFR use counts                                    [2179-2183]
        atomic_inc(&cfg->send_jfc->use_cnt)
        atomic_inc(&cfg->recv_jfc->use_cnt)
        if (cfg->jfr) atomic_inc(&cfg->jfr->use_cnt)
  ── success                                                       [2185-2188]
        jetty->jetty_opt.is_actived = true
        return jetty;

  ── error unwind labels                                           [2189-2197]
        destroy_tptable: ubcore_destroy_tptable(&jetty->tptable)
        delete_jetty_to_grp: ubcore_remove_jetty_from_jetty_grp(jetty, cfg->jetty_grp)
        destroy_jetty: dev->ops->destroy_jetty(jetty)
        return ERR_PTR(ret)
```

Notable: ubcore registers the jetty into its own per-device hash table *after* the driver returns the handle but *before* refcounts are bumped on JFC/JFR — concurrent lookup is possible the moment the hashtable add returns.

### 4.2 `ubcore_import_jetty()` — `ubcore_jetty.c:2476`

Signature (exported at line 2539):

```c
struct ubcore_tjetty *ubcore_import_jetty(
    struct ubcore_device *dev,
    struct ubcore_tjetty_cfg *cfg,
    struct ubcore_udata *udata);
```

Call walk:

```
ubcore_import_jetty(dev, cfg, udata)                              [ubcore_jetty.c:2476]
  ── validate                                                      [2484-2496]
        ubcore_have_ops(dev) ; ops->unimport_jetty ; cfg != NULL
        cfg->eid_index < dev->attr.dev_cap.max_eid_cnt
        if ubcore_check_ctrlplane_compat(ops->import_jetty)
            return ubcore_import_jetty_compat(dev, cfg, udata)    [2488]
        if bonding dev
            ubcore_connect_exchange_udata_when_import_jetty(...)  [2491-2496]
  ── driver import
        tjetty = dev->ops->import_jetty(dev, cfg, udata)          [2498]
        UBCORE_CHECK_RETURN_ERR_PTR(...)                          [2502]
  ── metadata
        tjetty->cfg     = *cfg                                    [2504]
        tjetty->ub_dev  = dev                                     [2505]
        tjetty->uctx    = ubcore_get_uctx(udata)                  [2506]
        atomic_set(&tjetty->use_cnt, 0)                           [2508]
        mutex_init(&tjetty->lock)                                 [2509]
  ── conditional vTP setup                                         [2511-2534]
        if (!bonding && trans=UB && mode ∈ {RM, UM, RC-shared}):
            ubcore_set_vtp_param(dev, NULL, cfg, &vtp_param)
            mutex_lock(&tjetty->lock)
            vtpn = ubcore_connect_vtp(dev, &vtp_param)            [2520 → vtp.c:1068]
            if error: unlock, destroy mutex,
                      ops->unimport_jetty(tjetty), return err     [2521-2528]
            tjetty->vtpn = vtpn                                   [2530]
            mutex_unlock(&tjetty->lock)
        else
            tjetty->tp = NULL                                     [2533]
  ── success
        return tjetty;                                            [2537]
```

The control-plane-aware variant `ubcore_import_jetty_ex` (`ubcore_jetty.c:2542-2606`) takes an `active_tp_cfg` and routes through `ubcore_connect_vtp_ctrlplane` (line 2584) or `ubcore_connect_rm_svrtp_ctrlplane` (lines 2577-2582) for share_tp RM+RTP.

### 4.3 vTP connect — `ubcore_connect_vtp()` @ `ubcore_vtp.c:1068`

Lazy vTP allocation + remote-side create-request handshake:

```
ubcore_connect_vtp(dev, param)                                    [ubcore_vtp.c:1068-1127]
  ── reuse path
        vtpn = ubcore_find_get_vtpn(dev, param)                   [1081]
        if vtpn:  return ubcore_reuse_vtpn(dev, vtpn)             [1083]
  ── allocate
        vtpn = ubcore_alloc_vtpn(dev, param)                      [1086 → 797]
          dev->ops->alloc_vtpn(dev)                               [805]   ; driver-side alloc
          vtpn->{ub_dev, use_cnt, ref_cnt, comp}                  [812-815]
          copy {trans_mode, local_eid, peer_eid, eid_index,
                local_jetty, peer_jetty}                          [816-821]
          vtpn->state = UBCORE_VTPS_RESET                         [822]
          mutex_init(state_lock); INIT_LIST_HEAD(list,disc_list)  [823-824]
  ── register
        ubcore_find_add_vtpn(dev, vtpn, &exist_vtpn, param)       [1093]
          if EEXIST: reuse existing, free new                     [1094-1098]
  ── send create-vtp request
        mutex_lock(&vtpn->state_lock)                             [1105]
        ubcore_send_create_vtp_req(dev, param, vtpn)              [1106 → 249]
          builds struct ubcore_create_vtp_req
          msg.type = UBCORE_MSG_CREATE_VTP                        [260]
          payload {vtpn id, trans_mode, eids, jetty ids, dev_name} [264-272]
        on OK: atomic_inc(use_cnt); state = UBCORE_VTPS_READY     [1108-1109]
        on err: state = UBCORE_VTPS_WAIT_DESTROY                  [1111]
        mutex_unlock(&vtpn->state_lock)                           [1113]
  ── rollback on send error                                        [1116-1122]
        ubcore_hash_table_rmv_vtpn(dev, vtpn)
        free vtpn ; return err
```

The control-plane variant `ubcore_connect_vtp_ctrlplane` (lines 1201-1260) keys lookup by `active_tp_cfg->tp_handle` and ends with `ubcore_active_tp` (line 1129-1155) which calls `dev->ops->active_tp(dev, active_cfg)` (line 1143) to flip a pre-built TP into RTS.

**Gap:** the actual wire send for `UBCORE_MSG_CREATE_VTP` is not in `ubcore_vtp.c:249` — the function builds the request and frees it. Send is in `ubcore_msg.c` (not walked here). Response demux feeds back through `ubcore_wait_connect_vtp_resp_intime` (line 332 declaration) — full path TBD.

### 4.4 Datapath — `ubcore_dp.c`

`ubcore_post_jfs_wr` (lines 64-78):

```c
int ubcore_post_jfs_wr(struct ubcore_jfs *jfs, struct ubcore_jfs_wr *wr,
                       struct ubcore_jfs_wr **bad_wr)
{
    if (jfs == NULL || jfs->ub_dev == NULL || jfs->ub_dev->ops == NULL ||
        jfs->ub_dev->ops->post_jfs_wr == NULL || wr == NULL || bad_wr == NULL)
        return -EINVAL;
    return jfs->ub_dev->ops->post_jfs_wr(jfs, wr, bad_wr);  /* line 77 */
}
```

`ubcore_poll_jfc` (lines 98-110): mirror structure, dispatches to `dev->ops->poll_jfc(jfc, cr_cnt, cr)` at line 109.

**No locking** in the ubcore layer — the driver owns synchronization. Hot-path overhead is one null-chain check + one indirect call.

### 4.5 TP table — `ubcore_tp_table.c`

```
ubcore_create_tptable()                                           [tp_table.c:97-118]
  kzalloc(sizeof(ubcore_hash_table), GFP_KERNEL)                  [109]
  configure: size = UBCORE_TP_TABLE_SIZE, key_size, key/node offsets
  return *ubcore_hash_table

ubcore_add_tp_node(ht, hash, key, tp, ...)                        [tp_table.c:170-212]
  new = kzalloc(sizeof(ubcore_tp_node), GFP_KERNEL)               [179]
  copy key, tp                                                    [183-184]
  mutex_init, kref_init, init_completion                          [186-188]
  spin_lock(&ht->lock)                                            [190]
  existing = ubcore_hash_table_lookup_nolock(ht, hash, key)       [197]
  if existing: kref_get; spin_unlock; return existing             [199-203]
  ubcore_hash_table_add_nolock(ht, &new->hnode, hash)             [206]
  tp->priv = new                                                  [208]
  kref_init / get                                                 [209]
  spin_unlock                                                     [210]
  return new                                                      [211]

ubcore_lookup_tpnode(ht, hash, key)                               [tp_table.c:214-226]
  spin_lock ; ubcore_hash_table_lookup_nolock ; kref_get          [221-223]
```

Keys are constructed via `ubcore_init_tp_key_jetty_id` (`tp_table.c:34`) — keyed by `key_type` + jetty id triple.

### 4.6 UBMAD well-known jetty (IDs 1 and 2)

Path: `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/`.

```c
/* ub_mad_priv.h:20-21 */
#define UBMAD_WK_JETTY_ID_0  1U
#define UBMAD_WK_JETTY_ID_1  2U

/* ub_mad.c:23-28 */
#define WK_JETTY_ID_INITIALIZER { UBMAD_WK_JETTY_ID_0, UBMAD_WK_JETTY_ID_1 }
static const uint32_t g_ubmad_wk_jetty_id[UBMAD_WK_JETTY_NUM]
    = WK_JETTY_ID_INITIALIZER;
```

Per-device init: `ubmad_init_jetty_rsrc()` in `ub_mad.c:792-880`:

```
ubmad_init_jetty_rsrc(dev_priv, rsrc, …)                          [ub_mad.c:792]
  ── CQs and RQ
        jfc_s = ubmad_create_jfc_s(device)                        [804]
        jfc_r = ubmad_create_jfc_r(device)                        [812]
        jfr   = ubmad_create_jfr(dev_priv, jfc_r)                 [821]
  ── jetty with explicit id
        jetty = ubmad_create_jetty(dev_priv, jfc_s, jfc_r, jfr,
                                   rsrc->jetty_id)                [830]
            (cfg: jfs_depth=UBMAD_JFS_DEPTH, max_send_sge=UBMAD_JFS_MAX_SGE_NUM,
                  jfr_depth=UBMAD_JFR_DEPTH, trans_mode+flag for UBMAD) [406-445]
        log: "well-known jetty id %u eid …"                       [839]
  ── segments
        ubmad_create_seg(rsrc, device)                            [845-850]
  ── pre-post recv ring
        for i in [0, UBMAD_JFR_DEPTH):
            ubmad_post_recv(rsrc)                                 [855-861]
  ── tjetty tracker
        INIT_HLIST_HEAD(&rsrc->tjetty_hlist[idx])                 [864-866]
```

Two of these resources are stood up per ubcore device — one per well-known ID. Incoming MAD messages on ID 1 carry link-setup; ID 2 is reserved for additional control flows (refinement TBD against `ubcm/`).

### 4.7 Driver registration — `ubcore_device.c`

```
ubcore_register_device(dev)                                       [ubcore_device.c:1223-1289]
  validate dev / dev->ops / dev->dev_name                         [1228-1234]
  ubcore_find_device_with_name(dev->dev_name)  -- duplicate check [1236]
  init_ubcore_device(dev)                                         [1243]
  ubcore_create_main_device(dev)                                  [1248]
  ubcore_config_device_in_register(dev)                           [1255]   ; cgroup, sysfs attrs
  add to global list under rwsem                                  [1262-1276]
```

Ops contract for jetty operations (`include/ub/urma/ubcore_types.h`):

| Op | Field line | Returns |
|---|---|---|
| `create_jetty(dev, cfg, udata)` | 2604-2606 | `struct ubcore_jetty *` |
| `destroy_jetty(jetty)` | 2641 | int |
| `import_jetty(dev, cfg, udata)` | 2658-2660 | `struct ubcore_tjetty *` |
| `import_jetty_ex(dev, cfg, active_tp_cfg, udata)` | 2670-2673 | `struct ubcore_tjetty *` |
| `unimport_jetty(tjetty)` | 2680 | int |
| `bind_jetty(jetty, tjetty, udata)` | 2688-2690 | int |
| `bind_jetty_ex(jetty, tjetty, active_tp_cfg, udata)` | 2700-2703 | int |
| `unbind_jetty(jetty)` | 2710 | int |
| `post_jfs_wr(jfs, wr, bad_wr)` | 3080-3081 | int |
| `post_jfr_wr(jfr, wr, bad_wr)` | 3089-3090 | int |
| `post_jetty_send_wr(jetty, wr, bad_wr)` | 3098-3100 | int |
| `post_jetty_recv_wr(jetty, wr, bad_wr)` | 3108-3110 | int |
| `poll_jfc(jfc, cr_cnt, cr)` | 3117-3118 | int |

UDMA HW driver (in `drivers/ub/urma/hw/udma/`) populates the ops struct with UDMA-specific `udma_create_jetty`, `udma_post_jfs_wr`, `udma_poll_jfc`, etc.

### 4.8 vTP create-req wire send + response infrastructure — `ubcore_msg.c` / `ubcore_vtp.c`

The §4.3 `ubcore_connect_vtp()` walk pinned the ctrlplane TP activation but stopped at a request builder that built a message and freed it without sending. That builder (`ubcore_send_create_vtp_req()` at `ubcore_vtp.c:249-275`) is **dead code** — the live path goes through a parallel function and a separate dispatch flow.

#### Live send path

```
ubcore_connect_vtp_async(dev, param, vtpn, para, timeout)         [ubcore_vtp.c:1469-1563]
  1. ubcore_find_add_vtpn(dev, vtpn, &exist_vtpn, param)          [:1491]      ; vtpn dedup, may reuse
  2. ubcore_queue_wait_connect_vtp_resp_task(dev, param, timeout) [:1505 → :451-489]
        wait_work = kzalloc(struct ubcore_wait_vtpn_resp_work)    [:458]
        INIT_DELAYED_WORK(&wait_work->delay_work,
                          ubcore_wait_connect_vtp_resp_timeout)    [:478]
        ubcore_queue_delayed_work(UBCORE_CONNECT_VTP_ASYNC_WQ,
                                  &wait_work->delay_work,
                                  msecs_to_jiffies(timeout))       [:480]      ; safety-net timer
  3. ubcore_create_async_connect_vtp_req(dev, param, vtpn)        [:1514 → :491-522]
        req = kzalloc(sizeof(ubcore_req) + create_vtp_req_len)
        req->opcode = UBCORE_MSG_CREATE_VTP                       [:504]
        memcpy(create-vtp-req payload: vtpn / trans_mode / EIDs / jettys / dev_name)
        s = ubcore_create_ue2mue_session(req, vtpn)               [:518 → ubcore_msg.c:158-171]
            req->msg_id = ubcore_get_msg_seq()                     [:162]      ; atomic seq
            s = ubcore_create_msg_session(req)                     [:163 → :75-99]
                kzalloc(struct ubcore_msg_session)
                s->is_async = false initially → set to true [:168]
                s->vtpn = vtpn                                     [:169]
                init_completion(&s->comp)
                kref_init(&s->kref); kref_get(&s->kref)
                spin_lock(g_msg_session_lock)
                list_add_tail(&s->node, &g_msg_session_list)       [:96]
        wait_work->s      = s                                      [:1521]
        wait_work->msg_id = s->req->msg_id                         [:1522]     ; correlate timeout to msg_id
        ubcore_add_async_wait_list(vtpn, para, wait_work)          [:1523]     ; per-vtpn callback queue
  4. ubcore_send_req(dev, s->req)                                 [:1526 → ubcore_msg.c:118-135]
        validate dev / dev->ops / dev->ops->send_req / req->len    [:122-126]
        return dev->ops->send_req(dev, req)                        [:128]      ; ★ driver-provided
        ubcore_log_err if non-zero
  5. on send error: ubcore_set_session_finish(s); kfree(s->req);
                    ubcore_destroy_msg_session(s); cancel wait_work [:1531-1545]
```

The driver `dev->ops->send_req` is the actual wire path. For UDMA it is wired in `drivers/ub/urma/hw/udma/` and ships the message to the local MUE/firmware ctrlq; the firmware in turn relays to UVS or the peer MUE depending on opcode. This op is **synchronous** in the sense that it returns once the firmware has accepted the request — it does not block waiting for a peer response.

#### Live response path — and the dormant `_intime` handler

Two response handlers are defined in `ubcore_vtp.c`:

| Handler | Location | Caller |
|---|---|---|
| `ubcore_wait_connect_vtp_resp_intime(s, dev, resp)` | `ubcore_vtp.c:332-381` | **none in kernel tree** |
| `ubcore_wait_connect_vtp_resp_timeout(work)` | `ubcore_vtp.c:420-448` | delayed-work callback queued at `:478` |

The `_intime` path is the documented success-arrival entry point. It looks up the session via the `s` argument, sanity-checks `s->req`, calls `ubcore_handle_create_vtp_resp(dev, resp, vtpn)` at `:369`, then (on success) `ubcore_handle_vtpn_wait_list(vtpn, dev, UBCORE_VTPS_READY, 0)` at `:378` to fire each per-vtpn callback queued in step 3.

**However:** `grep -rnE "wait_connect_vtp_resp_intime"` against the entire kernel tree (`drivers/ub/`, `include/ub/`) and the `umdk/src/` userspace tree returns **only the declaration (`vtp.h:164`) and the definition (`vtp.c:332`)**. There is no live caller. The dispatch hooks that would invoke it are missing in OLK-6.6:

- `ubcore_msg.c:299-309`:
  ```c
  int ubcore_recv_req(struct ubcore_device *dev, struct ubcore_req_host *req)  { return 0; }
  EXPORT_SYMBOL(ubcore_recv_req);
  int ubcore_recv_resp(struct ubcore_device *dev, struct ubcore_resp *resp)    { return 0; }
  EXPORT_SYMBOL(ubcore_recv_resp);
  ```
  Both are exported no-op stubs. Their declarations live in `include/ub/urma/ubcore_api.h:83 / :91` so drivers can link against them, but a driver that calls `ubcore_recv_resp(dev, resp)` will return 0 and the response will be dropped.

- The only caller of `ubcore_find_msg_session(seq)` (`ubcore_msg.c:51-68`) is the **timeout** handler (`vtp.c:429` for connect, `vtp.c:702` for disconnect). Nothing looks up the session by `msg_id` on success arrival.

Implication: in OLK-6.6 the vTP create flow operationally treats every send as fire-and-forget at the ubcore-msg layer. The wait-list callbacks fire **only via the timeout path** (with status set to either `ETIMEDOUT` or, when the firmware completes synchronously, by the driver invoking `ubcore_handle_vtpn_wait_list` directly through a different entry — to be confirmed in the UDMA driver source). The `_intime` plumbing is staged for a future wiring (likely a netlink or driver-callback hook) but is not yet active.

This matches the empirical observation in `umdk_link_setup_timing.md` §10.27: server-side `ubcore_session_wait` (a different abstraction; see below) is the only kernel-side wait that shows up in 100-process traces, and it serializes via `cancel_delayed_work_sync`, not via `_intime` dispatch.

#### Two parallel session abstractions — do not conflate

The OLK-6.6 ubcore tree carries **two distinct** session structs:

| Type | File | Keyed by | Used for | Wait/complete primitive |
|---|---|---|---|---|
| `struct ubcore_msg_session` | `ubcore_msg.c:75 + ubcore_msg.h:36` | `msg_id` (atomic seq) | UE↔MUE control (VTP create, EID discover) | `complete(&s->comp)` + `kref` |
| `struct ubcore_session` | `net/ubcore_session.c:17` | `session_id` (atomic seq) | Net-layer connection setup | `complete(&s->completion)` + own delayed_work |

The first is the one §4.3 / §4.8 walk; it is the layer with the dormant `_intime` handler. The second (`net/ubcore_session.c`) is what `umdk_link_setup_timing.md` references when discussing `ubcore_session_complete` / `ubcore_session_wait` — that one is fully wired and used by `net/ubcore_cm.c:100-128 ubcore_cm_recv()` → `net/ubcore_comm.c ubcore_net_handle_msg()` → `handle_create_resp()` → `ubcore_session_complete(session)`.

#### CM dispatch — `net/ubcore_cm.c`

The CM (Connection Manager) is the peer↔peer message bus. It is a separate plane from the UE↔MUE msg-session above:

```
ubcore_ubcm_send_to(dev, addr, msg)                               [net/ubcore_cm.c:168-225]
  send_buf = kcalloc(ubcore_cm_send_buf + MSG_HDR_SIZE + msg->len)
  send_buf->session_id = msg->session_id                          [:192]
  send_buf->msg_type = UBCORE_CM_CONN_REQ
                     | UBCORE_CM_CONN_RESP
                     | UBCORE_CM_SINGLE_REQ                       [:194-205]   ; demux on msg->type
  ubcore_call_cm_send_ops(dev, send_buf)                          [:218 → :63-73]
        if (!g_send) return -EINVAL                                            ; UBMAD registers via :94
        return g_send(dev, send_buf)                                           ; resolves to ubmad_ubc_send

ubcore_cm_recv(dev, recv_cr)                                      [net/ubcore_cm.c:100-128]
  msg = (ubcore_net_msg *)recv_cr->payload                        [:116]
  ep = ubcore_cm_lookup_ep(dev, &recv_cr->local_eid)              [:121]
  if (ep && ep->recv_cb) ep->recv_cb(ep, dev, msg, &addr)         [:123]
  else                   ubcore_net_handle_msg(dev, msg, &addr)   [:125]
```

`g_send` is set via `ubcore_register_cm_send_ops()` (`:94`), invoked from `ubcm_init()` → `ub_cm.c:334-350` to register `ubmad_ubc_send`. So `ubcore_call_cm_send_ops()` ultimately calls into UBMAD's send path, which posts to a JFS WR on UBMAD WK jetty ID 1 — closing back to the deep-dive doc's call chain.

#### File:line index for §4.8

| Concept | File:line |
|---|---|
| Live req builder | `ubcore_vtp.c:491-522 ubcore_create_async_connect_vtp_req` |
| Dead req builder | `ubcore_vtp.c:249-275 ubcore_send_create_vtp_req` (no callers) |
| Caller (entry) | `ubcore_vtp.c:1469-1563 ubcore_connect_vtp_async` |
| Send op wrapper | `ubcore_msg.c:118-135 ubcore_send_req` → `dev->ops->send_req` |
| Async UE2MUE session | `ubcore_msg.c:157-171 ubcore_create_ue2mue_session` |
| Session table base | `ubcore_msg.c:28 g_msg_session_list` + `:51 ubcore_find_msg_session` |
| Dormant intime handler | `ubcore_vtp.c:332-381 ubcore_wait_connect_vtp_resp_intime` (zero callers) |
| Stub recv entries | `ubcore_msg.c:299-309 ubcore_recv_req / ubcore_recv_resp` (no-ops) |
| Live timeout handler | `ubcore_vtp.c:420-448 ubcore_wait_connect_vtp_resp_timeout` |
| Wait-list dispatch | `ubcore_vtp.c:278-330 ubcore_handle_vtpn_wait_list` |
| Net-layer session | `net/ubcore_session.c:17-230` (separate abstraction) |
| CM send entry | `net/ubcore_cm.c:168-225 ubcore_ubcm_send_to` |
| CM recv entry | `net/ubcore_cm.c:100-128 ubcore_cm_recv` |
| CM send-ops register | `net/ubcore_cm.c:94 ubcore_register_cm_send_ops` |
| CM send-ops definer | `ubcm/ub_cm.c:334-350 ubcm_init` (registers `ubmad_ubc_send`) |

---

## 5. UBSE syssentry — well-known jetty 999 in production

Path: `/Volumes/KernelDev/ubs-engine/src/adapter_plugins/syssentry/sys_sentry_module.cpp:244-281`.

```
SetSysSentryFaultReporter()                                       [:244]
  GetEids(clientEid, serverEids)                                  [:131]
      UbseMtiInterface::GetAllSocketComEid()
      partition local vs remote EIDs
  exec("sentryctl set sentry_remote_reporter --eid=<clientEid>")  [:262]
  exec("sentryctl set sentry_remote_reporter --cna=<CNA>")        [:263]
  exec("sentryctl set sentry_urma_comm                            [:264]
        --server_eid=<serverEids>
        --client_jetty_id=1000")
```

The constant `URMA_LISTEN_JETTY = 999` at `ubse_common_def.h:77` is the *destination* — the sentry daemon pre-creates a listening jetty at id 999 so cross-node fault reports have a fixed sink. UBSE's own source is wire-silent on the RPC payload; the handshake is delegated to `sentryctl` and the sentry daemon binary.

---

## 6. Bootstrap conceptual model (HCOM "自举建链公知 jetty")

From `~/Documents/Repo/ub-stack/umdk/RELEASE-NOTES.ch.md:12`: RM mode is for *hot migration and HCOM (self-establishing link via well-known jetty)*. Pattern:

1. Each node has a *listening* well-known jetty pre-created at boot in RM mode (one of: UBMAD ID 1, UBSE id 999, or a HCOM-specific reserved ID).
2. A peer computes target EID + agreed well-known ID and posts the first RPC straight to `<remote_eid, wk_id>` with its own caller-side (also reserved-range) jetty.
3. Inside the RPC payload the two sides negotiate "real" application jetty IDs (≥ 1024 outside the cap-reserved range) and exchange tokens.
4. Subsequent application traffic uses the negotiated jetty pair; the well-known jetty stays free for new peers.

The first-RPC kernel chain from memory (`reference_umdk_link_setup.md`): `find_primary_eid_in_ues` → `ubcore_get_main_primary_eid` → CM/MAD packet → server-side `post_wq`. The well-known jetty is the **destination** of that first MAD; everything else runs on top of it.

---

## 7. Lifetime-of-a-jetty pictograph (RC mode)

```
process                  ubcore                       driver               peer
  |                         |                            |                   |
  |--- create_jetty(cfg) -->|                            |                   |
  |                         |--- pre_check ------------->|                   |
  |                         |--- ops->create_jetty ----->|                   |
  |                         |<-- jetty *-----------------|                   |
  |                         |--- ubcore_create_tptable                       |
  |                         |--- ht_add(jetty) ; bump JFC/JFR refs           |
  |<--- jetty * ------------|                            |                   |
  |                         |                            |                   |
  |--- import_jetty(rcfg) ->|                            |                   |
  |                         |--- ops->import_jetty ----->|                   |
  |                         |<-- tjetty *----------------|                   |
  |                         |--- ubcore_connect_vtp                          |
  |                         |       alloc_vtpn → send UBCORE_MSG_CREATE_VTP ->|
  |                         |                            |<-- vtp_resp ------|
  |                         |       vtpn->state = READY                       |
  |<--- tjetty * -----------|                            |                   |
  |                         |                            |                   |
  |--- post_jfs_wr -------->|--- ops->post_jfs_wr ------>| -- HW SQE/Doorbell -+
  |                         |                            |                   |
  |<--- poll_jfc -----------|<-- ops->poll_jfc <---------| <-- CQE -----------+
  |                         |                            |                   |
  |--- unimport_jetty ----->|--- ubcore_disconnect_vtp                        |
  |                         |--- ops->unimport_jetty --->|                   |
  |                         |                            |                   |
  |--- destroy_jetty ------>|--- ops->destroy_jetty ---->|                   |
  |                         |--- ubcore_destroy_tptable                       |
```

---

## 8. Open items / things still to confirm

These are gaps the trace explicitly **did not** resolve:

1. ~~`ubcore_send_create_vtp_req` actual wire send.~~ **Resolved in §4.8.** That function is dead code; the live builder is `ubcore_create_async_connect_vtp_req` at `vtp.c:491`, sent via `ubcore_send_req` at `vtp.c:1526` → `dev->ops->send_req` (driver-provided, e.g. UDMA firmware ctrlq).
2. ~~vTP response demux.~~ **Partially resolved in §4.8 with surprising finding:** `ubcore_wait_connect_vtp_resp_intime` (`vtp.c:332`) has **zero callers** in the entire kernel tree, and `ubcore_recv_resp`/`ubcore_recv_req` (`msg.c:299/305`) are EXPORT_SYMBOL'd no-op stubs. The msg-session response demux is dormant in OLK-6.6. Open follow-up: confirm whether the UDMA driver invokes `ubcore_handle_vtpn_wait_list` directly via a non-intime path on firmware completion.
3. **UAPI ioctl boundary.** `ubcore_cdev_file.c` snippets shown were sysfs attribute handlers; the IOCTL dispatch (`UBCORE_CMD_CREATE_JETTY` etc.) lives further in the file or in `ubcore_uvs_cmd.c` — not pinned to a `case` line yet.
4. **Bonding flow specifics.** `ubcore_connect_exchange_udata_when_import_jetty` (called at `ubcore_jetty.c:2491-2496`) implementation is in `ubcore_connect_bonding.c` and was not walked.
5. **UBMAD ID 2 use.** Only ID 1 is documented in the existing well-known-jetty doc as carrying link-setup; the role of ID 2 (`UBMAD_WK_JETTY_ID_1`) was not pinned to a specific handler in `ubcm/`. (Partial: the deep-dive doc notes ID 2 is selected for `UBMAD_AUTHN_DATA`; the dispatch code path is still unwalked.)
6. **UDMA driver-side `udma_create_jetty` body.** Confirmed `dev->ops->create_jetty` resolves to a UDMA function via `register_device`, but the actual HW resource allocation (queue rings, doorbell mapping) was not walked.

Items #1 and #2 walked in §4.8 today (2026-05-14). Items #3–#6 are each a one-file follow-up; flag if any is needed in detail.

---

## 9. Quick file-index

| Concept | File | Function / symbol |
|---|---|---|
| WK range (UMDK) | `~/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/bondp_types.h:35` | `BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024` |
| WK range (UDMA cap) | `~/Documents/Repo/ub-stack/.../udma_cmd.h:199-200` | `well_known_jetty_start/num` |
| WK fixed ID (UBSE) | `/Volumes/KernelDev/ubs-engine/src/include/ubse_common_def.h:77` | `URMA_LISTEN_JETTY = 999` |
| WK fixed ID (UBMAD) | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:20-21` | `UBMAD_WK_JETTY_ID_0/1` |
| Kernel-mode example | `~/Documents/Repo/ubturbo/plugins/ubdma/src/urma.c` | `init_urma_mem_trans / urma_run_send / release_urma_mem_trans` |
| `ubcore_create_jetty` | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c:2118` | exported at 2198 |
| `ubcore_import_jetty` | `…/ubcore_jetty.c:2476` | exported at 2539 |
| `ubcore_post_jfs_wr` | `…/ubcore_dp.c:64-78` | direct ops dispatch |
| `ubcore_poll_jfc` | `…/ubcore_dp.c:98-110` | direct ops dispatch |
| `ubcore_create_tptable` | `…/ubcore_tp_table.c:97-118` | hash-table alloc |
| `ubcore_add_tp_node` | `…/ubcore_tp_table.c:170-212` | spin-locked insert |
| `ubcore_connect_vtp` | `…/ubcore_vtp.c:1068-1127` | alloc + create-vtp-req |
| `ubcore_alloc_vtpn` | `…/ubcore_vtp.c:797` | driver alloc + init |
| `ubcore_active_tp` | `…/ubcore_vtp.c:1129-1155` | ctrlplane TP activation |
| UBMAD init | `…/ubcm/ub_mad.c:792-880` | `ubmad_init_jetty_rsrc` |
| Device register | `…/ubcore_device.c:1223-1289` | `ubcore_register_device` |
| Ops contract | `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h:2604+, 3080+` | jetty + datapath ops |
