# Public-known / well-known jetty in URMA

_Last updated: 2026-05-14._

URMA reserves a range of jetty IDs that any two nodes can use **without exchanging IDs first**. The codebase calls this reserved-ID family both `public_jetty` and `well_known_jetty`. UBCM/UBMAD then builds a concrete control-plane user on top of that idea: two fixed well-known jetty resources, ID 1 and ID 2, where ID 1 carries the link-setup connection messages.

This doc separates the two layers:
- **Provider reservation:** UDMA's `caps.public_jetty` range, sourced from `well_known_jetty_start` / `well_known_jetty_num`.
- **Control-plane consumer:** UBMAD's actual well-known jetty resources, `jetty_rsrc[0]` and `jetty_rsrc[1]`, used by UBCM.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer on jetty / EID
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — link setup; explains the chicken-and-egg this fixes
- [`umdk_urma_perftest_function_graph.md`](umdk_urma_perftest_function_graph.md) — `urma_perftest` setup and steady-state call graph

---

## 1. What it is

Normal URMA jettys are identified by `(eid, uasid, id)` where `id` is **driver-allocated** at create time. For peer-to-peer connect, both sides must know each other's full triple — meaning there's a chicken-and-egg problem at bootstrap: how do you exchange jetty IDs if you don't already have a side-channel?

A **well-known jetty** (== "public-known jetty") is one created with a **caller-specified jetty ID in a reserved range** that's known across the cluster ahead of time. Both sides compute the peer's jetty ID purely from public information (peer EID, an EID index, etc.) plus the well-known base — no handshake needed.

The two names in source:
- **`public_jetty`** — UDMA HW provider naming (`udma_dev->caps.public_jetty`)
- **`well_known_jetty`** — UDMA cmd struct + ubase comm_dev capability fields

`ubase_comm_dev.h:114`:
```c
struct ubase_comm_dev_cap {
    ...
    u32 public_jetty_cnt;     /* public jetty count */
    ...
};
```

`udma_cmd.h:199-200`:
```c
uint16_t well_known_jetty_start;
uint16_t well_known_jetty_num;
```

Same structural concept; just different naming traditions across layers.

## 2. Why it exists

Without a well-known jetty range, every URMA bootstrap requires:
1. Some non-URMA channel (TCP, shared file, KV store, …) to exchange `(eid, uasid, id)` triples.
2. Plus `urma_get_tp_list` to set up the TP.
3. Plus `urma_import_jetty_ex` etc. to wire up the local target_jetty.

Step 1 is the awkward one — applications that *are* the network stack (IPoURMA), or that need to talk to *every* node in the cluster (ubmgr health probes), can't depend on a higher-level transport for bootstrap. Well-known jettys make step 1 unnecessary.

This is the same pattern as:
- **IB well-known QPNs**: QP0 for SMP (Subnet Management Packets), QP1 for GMP/general management. Anyone connecting to an IB node can target QP1 without exchanging QP numbers.
- **TCP/UDP well-known ports**: 0–1023 reserved. Clients know where servers listen without asking — port 80 for HTTP, 22 for SSH, etc.

## 3. Implementation

```
HW reports its capability:           ubase_comm_dev.public_jetty_cnt = N
                                     cmd->well_known_jetty_start = base
                                     cmd->well_known_jetty_num = count
                                       │
                                       ▼
UDMA caches:                         udma_dev->caps.public_jetty = {
                                         .start_idx = base,
                                         .max_cnt = count,
                                     }
                                       │
                                       ▼
User app creates jetty with cfg_id:  if cfg_id ∈ [start_idx, start_idx + max_cnt - 1]
                                         driver accepts user-specified ID
                                     else
                                         driver allocates from normal pool
```

`udma_main.c:561-562` (driver wires HW cap into device caps):
```c
udma_dev->caps.public_jetty.start_idx = cmd->well_known_jetty_start;
udma_dev->caps.public_jetty.max_cnt   = cmd->well_known_jetty_num;
```

`udma_main.c:172` (capability exposed to userspace):
```c
attr->reserved_jetty_id_max = udma_dev->caps.public_jetty.max_cnt - 1;
```

`udma_jetty.c:232-245` (allocation fallback includes the public-jetty pool):
```c
ret = udma_alloc_jetty_id(udma_dev, idx, &udma_dev->caps.jetty);
...
ret = udma_alloc_jetty_id(udma_dev, idx, &udma_dev->caps.user_ctrl_normal_jetty);
...
ret = udma_alloc_jetty_id(udma_dev, idx, &udma_dev->caps.public_jetty);
```

`udma_jetty.c:298+` (validation at create time, function `udma_verify_jetty_type_urma_normal`):
```c
if (!(CFGID_CHECK(cfg_id, udma_dev->caps.public_jetty) ||
      CFGID_CHECK(cfg_id, udma_dev->caps.hdc_jetty) ||
      CFGID_CHECK(cfg_id, udma_dev->caps.jetty))) {
    dev_err(...,"user id %u error...");
    return -EINVAL;
}
```

User code that wants a well-known jetty just sets `cfg.id` in the reserved range; the driver routes the allocation to the public-jetty pool instead of the dynamic pool.

## 4. UBCM / UBMAD link setup consumer

The UBCM path is the code path behind the "where is the public known jetty and how is it involved in link setup?" question. It is more specific than the generic public-jetty range above.

### 4.1 Fixed IDs and message ownership

UBMAD defines two well-known jetty IDs:

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:18-21`:
```c
#define UBMAD_WK_JETTY_NUM 2
#define UBMAD_WK_JETTY_ID_0 1U
#define UBMAD_WK_JETTY_ID_1 2U
```

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c:22-28` then puts those IDs into `g_ubmad_wk_jetty_id[]`. Note the naming wrinkle: the comment says "well-known jetty 0 and 1", but the actual IDs are `1` and `2`; `0` and `1` are the array/resource indexes.

The `struct ubmad_jetty_resource` stores one local well-known jetty plus its send/recv JFCs, JFR, send/recv segments, and imported remote tjetty cache:

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:73-96`:
```c
struct ubmad_jetty_resource {
    uint32_t jetty_id;
    struct ubcore_jfc *jfc_s;
    struct ubcore_jfc *jfc_r;
    struct ubcore_jfr *jfr;
    struct ubcore_jetty *jetty; /* well-known jetty */
    ...
    struct hlist_head tjetty_hlist[UBMAD_MAX_TJETTY_NUM];
};
```

UBMAD message types intentionally line up with UBCM message types:

`kernel/drivers/ub/urma/ubcore/net/ubcore_cm.h:24-28`:
```c
UBCORE_CM_CONN_REQ  = 2, /* Consistent with UBMAD_UBC_CONN_REQ */
UBCORE_CM_CONN_RESP = 3, /* Consistent with UBMAD_UBC_CONN_RESP */
UBCORE_CM_SINGLE_REQ = 4,
```

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.h:20-29` maps those into:
- `UBMAD_UBC_CONN_REQ`
- `UBMAD_UBC_CONN_RESP`
- `UBMAD_UBC_SINGLE_REQ`
- `UBMAD_AUTHN_DATA`
- `UBMAD_CLOSE_REQ`

The selection rule is in `ubmad_post_send()`:

`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c:795-807`:
```c
case UBMAD_UBC_CONN_REQ:
case UBMAD_UBC_CONN_RESP:
case UBMAD_UBC_SINGLE_REQ:
    rsrc = &dev_priv->jetty_rsrc[0]; /* ID 1 */
    break;
case UBMAD_AUTHN_DATA:
    rsrc = &dev_priv->jetty_rsrc[1]; /* ID 2 */
    break;
```

So, for link setup: **UBCM create/destroy/single connection control messages use `jetty_rsrc[0]`, whose real jetty ID is 1.**

### 4.2 Well-known jetty resource creation path

The local well-known jettys are created per `ubcore_device` by UBMAD, not by `urma_perftest`.

```text
ubcm_init()
  -> ubmad_init()
     -> ubcore_register_client(&g_ubmad_client)
     -> ubcore_register_cm_eid_ops(ubmad_ubc_eid_ops)
  -> ubcm_base_init()
     -> ubcore_register_client(&g_ubcm_client)
  -> ubcore_register_cm_send_ops(ubmad_ubc_send)
```

Relevant code:
- `ubcm_init()` calls `ubmad_init()` and registers `ubmad_ubc_send` in `kernel/drivers/ub/urma/ubcore/ubcm/ub_cm.c:334-350`.
- `ubmad_init()` registers the UBMAD client and EID ops in `kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c:1272-1287`.
- `ubcm_add_device()` registers a UBMAD agent with `ubcm_send_handler` / `ubcm_recv_handler` in `kernel/drivers/ub/urma/ubcore/ubcm/ub_cm.c:171-202`.

Per-device resource creation:

```text
ubcore client add callback
  -> ubmad_add_device()
     -> ubmad_open_device()
        -> ubcore_register_event_handler(... ubmad_event_cb ...)
        -> ubmad_create_device_priv_resources()
           -> ubcore_get_eid_list()
           -> ubmad_init_jetty_rsrc_array()
              -> rsrc_array[0].jetty_id = 1
              -> rsrc_array[1].jetty_id = 2
              -> ubmad_init_jetty_rsrc()
                 -> ubmad_create_jfc_s()
                 -> ubmad_create_jfc_r()
                 -> ubmad_create_jfr()
                 -> ubmad_create_jetty()
                    -> ubcore_create_jetty()
                 -> ubmad_create_seg()
                 -> ubmad_post_recv() x UBMAD_JFR_DEPTH
```

Important lines:
- `ubmad_add_device()` -> `ubmad_open_device()` in `ub_mad.c:1237-1248`.
- `ubmad_open_device()` registers the event handler and calls `ubmad_create_device_priv_resources()` in `ub_mad.c:1113-1132`.
- If the device had no EID yet, the EID-add path later calls `ubmad_create_device_priv_resources()` from `ubmad_ubc_eid_ops_inner()` in `ub_mad.c:203-239`.
- `ubmad_create_jetty()` sets `jetty_cfg.id = jetty_id`, `share_jfr = 1`, `trans_mode = UBCORE_TP_UM`, JFC/JFR bindings, and calls `ubcore_create_jetty()` in `ub_mad.c:394-420`.
- `ubmad_init_jetty_rsrc_array()` assigns IDs 1 and 2, then initializes each resource in `ub_mad.c:947-963`.
- `ubmad_init_jetty_rsrc()` creates JFC/JFR/jetty/segments and preposts receive WRs in `ub_mad.c:791-868`.
- `ubmad_post_recv()` posts each receive WQE to the local well-known jetty with `ubcore_post_jetty_recv_wr()` in `ubmad_datapath.c:934-963`.

This means the UBCM well-known jetty is already listening before a remote link-setup request arrives.

### 4.3 Send-side link setup chain

For non-TP-aware or compatibility link setup, the initiator needs to exchange TP handle / PSN data with the peer. That exchange becomes a UBCM create message carried over the well-known jetty.

High-level chain:

```text
URMA import/bind path needing TP exchange
  -> ubcore_get_tp_list()
  -> ubcore_exchange_tp_info()
     -> create_session_for_create_connection()
     -> send_create_req()
        -> ubcore_net_send_to()
           -> ubcore_ubcm_send_to()
              -> ubcore_call_cm_send_ops()
                 -> ubmad_ubc_send()
                    -> ubmad_post_send()
                       -> select jetty_rsrc[0]  // well-known jetty ID 1
                       -> get/import remote well-known tjetty
                       -> ubmad_do_post_send()
                          -> ubmad_prepare_msg()
                          -> ubcore_post_jetty_send_wr()
```

Concrete call sites:
- `ubcore_exchange_tp_info()` builds a session and sends the create request in `ubcore_connect_adapter.c:334-410`.
- `send_create_req()` creates `UBCORE_NET_CREATE_REQ` and calls `ubcore_net_send_to()` in `ubcore_connect_adapter.c:184-201`.
- The default net transport is `UBCORE_CONNECT_WK_JETTY` in `ubcore_comm.c:55-62`.
- `ubcore_net_send_to()` dispatches to `ubcore_ubcm_send_to()` when `g_ubcore_connect_type == UBCORE_CONNECT_WK_JETTY` in `ubcore_comm.c:157-183`.
- `ubcore_ubcm_send_to()` maps `UBCORE_NET_CREATE_REQ` to `UBCORE_CM_CONN_REQ` and calls `ubcore_call_cm_send_ops()` in `ubcore_cm.c:168-224`.
- `ubcore_register_cm_send_ops(ubmad_ubc_send)` wires `g_send` to UBMAD in `ub_cm.c:350`; `ubcore_call_cm_send_ops()` calls `g_send` in `ubcore_cm.c:63-72`.
- `ubmad_ubc_send()` fills `src_eid`, then calls `ubmad_post_send()` in `ubmad_datapath.c:1153-1195`.
- `ubmad_post_send()` chooses `jetty_rsrc[0]` for `UBMAD_UBC_CONN_REQ`, `UBMAD_UBC_CONN_RESP`, and `UBMAD_UBC_SINGLE_REQ` in `ubmad_datapath.c:795-807`.

If the remote well-known target jetty is not already cached:

```text
ubmad_post_send()
  -> ubcore_get_main_primary_eid()
  -> ubmad_get_tjetty_lockless()
  -> queue_work(dev_priv->conn_wq, ubmad_jetty_work_handler)
     -> ubmad_import_jetty()
        -> build ubcore_tjetty_cfg:
           id.id = local well-known rsrc->jetty_id
           id.eid = peer primary EID
           trans_mode = UBCORE_TP_UM
           type = UBCORE_JETTY
        -> ubmad_import_jetty_compat()
           -> ubcore_get_tp_list()
           -> ubcore_import_jetty_ex()
     -> ubmad_do_post_send()
```

Important lines:
- Cache miss and workqueue setup are in `ubmad_datapath.c:815-873`.
- Worker imports the remote well-known tjetty and posts the send in `ubmad_datapath.c:733-765`.
- `ubmad_import_jetty()` builds the target config with `tjetty_cfg.id.id = rsrc->jetty_id` and calls `ubmad_import_jetty_compat()` in `ub_mad.c:575-664`.
- `ubmad_import_jetty_compat()` gets a TP and imports the remote well-known tjetty with `ubcore_import_jetty_ex()` in `ub_mad.c:530-568`.
- `ubmad_do_post_send()` builds an `UBCORE_OPC_SEND` WR and calls `ubcore_post_jetty_send_wr()` in `ubmad_datapath.c:654-719`.

The remote tjetty import is easy to miss: before UBMAD can send a control packet to the peer's well-known jetty ID 1, it imports that peer well-known jetty as a target.

### 4.4 Receive-side link setup chain

The peer's local well-known jetty already has posted receive WRs. When a create request arrives:

```text
well-known jetty recv completion
  -> ubmad_jfce_handler_r()
     -> queue work on agent_priv->jfce_wq_r
     -> ubmad_jfce_work_handler()
        -> ubmad_recv_work_handler()
           -> ubcore_poll_jfc()
           -> ubmad_process_msg()
              -> ubmad_process_conn_data()
                 -> ubmad_try_repost_all_response()
                 -> ubmad_cm_process_msg()
                    -> agent_priv->agent.recv_handler()
                       -> ubcm_recv_handler()
                          -> ubcore_cm_recv()
                             -> unwrap ubcore_net_msg from payload
                             -> ubcore_net_handle_msg()
                                -> handle_create_req()
```

Important lines:
- `ubmad_jfce_handler_r()` enters `ubmad_jfce_handler(... UBMAD_RECV_WORK)` in `ubmad_datapath.c:1429-1431`.
- The handler queues `ubmad_jfce_work_handler()` in `ubmad_datapath.c:1373-1410`.
- `ubmad_recv_work_handler()` polls the recv JFC, calls `ubmad_process_msg()`, releases the consumed recv SGE, and reposts another receive WQE in `ubmad_datapath.c:1265-1326`.
- `ubmad_process_msg()` dispatches `UBMAD_UBC_CONN_REQ` to `ubmad_process_conn_data()` in `ubmad_datapath.c:1110-1150`.
- `ubmad_process_conn_data()` calls `ubmad_cm_process_msg()` in `ubmad_datapath.c:991-1020`.
- `ubmad_cm_process_msg()` invokes the registered agent recv handler in `ubmad_datapath.c:968-989`.
- UBCM registered that handler as `ubcm_recv_handler()` in `ub_cm.c:188-189`.
- `ubcm_recv_handler()` calls `ubcore_cm_recv()` for `UBMAD_UBC_CONN_REQ` in `ub_cm.c:148-168`.
- `ubcore_cm_recv()` reconstructs `struct ubcore_net_msg` and calls `ubcore_net_handle_msg()` in `ubcore_cm.c:100-128`.
- `ubcore_exchange_init()` registered `handle_create_req()` for `UBCORE_NET_CREATE_REQ` in `ubcore_connect_adapter.c:1337-1344`.

The target then handles the link setup payload:

```text
handle_create_req()
  -> reverse local/peer EIDs
  -> ubcore_get_tp_list()
  -> ubcore_active_tp()
  -> send_create_resp()
     -> ubcore_net_send()
        -> ubcore_ubcm_send()
           -> ubcore_ubcm_send_to()
              -> ubmad_ubc_send()
                 -> ubmad_post_send()
                    -> jetty_rsrc[0] again
```

Important lines:
- `handle_create_req()` reverses the EIDs, calls `ubcore_get_tp_list()`, activates the TP, and sends a response in `ubcore_connect_adapter.c:707-775`.
- The response builder `send_create_resp()` uses `UBCORE_NET_CREATE_RESP` and `ubcore_net_send()` in `ubcore_connect_adapter.c:204-222`.
- `ubcore_ubcm_send_to()` maps `UBCORE_NET_CREATE_RESP` to `UBCORE_CM_CONN_RESP` in `ubcore_cm.c:198-201`, which UBMAD again sends over `jetty_rsrc[0]`.

### 4.5 Initiator response chain

The initiator receives the response on the same well-known jetty ID 1:

```text
ubmad_recv_work_handler()
  -> ubmad_process_msg()
     -> ubmad_process_conn_resp()
        -> ubmad_cm_process_msg()
           -> ubcm_recv_handler()
              -> ubcore_cm_recv()
                 -> ubcore_net_handle_msg()
                    -> handle_create_resp()
                       -> ubcore_session_find()
                       -> fill session_data_create_conn:
                          rx_psn = resp->tx_psn
                          peer_tp_handle = resp->tp_handle
                          ret = resp->result
                       -> ubcore_session_complete()
```

Then the blocked initiator in `ubcore_exchange_tp_info()` wakes up, copies `peer_tp_handle` and `rx_psn` out of the session data, and returns to the import/bind path. Code anchors:
- `ubmad_process_conn_resp()` in `ubmad_datapath.c:1023-1073`.
- `handle_create_resp()` in `ubcore_connect_adapter.c:778-799`.
- `ubcore_exchange_tp_info()` waits and reads `session_data` in `ubcore_connect_adapter.c:384-408`.

### 4.6 Where `urma_perftest` touches this

`urma_perftest` itself does **not** create UBMAD's well-known jettys. It creates normal test jettys and exchanges benchmark metadata over its own TCP socket path.

Default/non-TP-aware connect:

```text
connect_jetty_default()
  -> urma_import_jetty()
     -> UDMA userspace provider has no .import_jetty op
     -> liburma ctrlplane-compat path calls import_jetty_ex with empty active TP cfg
     -> kernel sees empty active_tp_cfg
     -> ubcore_import_jetty()
        -> ubcore_import_jetty_compat()
           -> ubcore_get_tp_list()
           -> ubcore_exchange_tp_info()
              -> UBCM over well-known jetty ID 1

  -> for RC:
     urma_bind_jetty()
       -> provider has no .bind_jetty op
       -> ubcore_bind_jetty_compat()
          -> ubcore_get_tp_list()
          -> ubcore_exchange_tp_info()
             -> UBCM over well-known jetty ID 1
```

Relevant lines:
- `connect_jetty_default()` calls `urma_import_jetty()` and, for RC, `urma_bind_jetty()` in `umdk/src/urma/tools/urma_perftest/perftest_resources.c:1540-1548`.
- UDMA userspace ops include `import_jetty_ex` and `bind_jetty_ex`, but not `import_jetty` / `bind_jetty`, in `umdk/src/urma/hw/udma/udma_u_ops.c:67-90`.
- `urma_check_ctrlplane_compat(op_ptr == NULL)` is in `umdk/src/urma/lib/urma/core/urma_cp_api.c:1186-1189`.
- `urma_import_jetty()` routes to `urma_import_jetty_compat()` when `.import_jetty` is absent in `urma_cp_api.c:1897-1926`.
- `urma_bind_jetty()` routes to `urma_bind_jetty_compat()` when `.bind_jetty` is absent in `urma_cp_api.c:1977-2008`.
- Kernel-side `ubcore_check_ctrlplane_compat(op_ptr == NULL)` is in `ubcore_connect_adapter.h:91-94`.
- `ubcore_import_jetty()` routes to `ubcore_import_jetty_compat()` when `.import_jetty` is absent in `ubcore_jetty.c:2476-2490`.
- `ubcore_bind_jetty()` routes to `ubcore_bind_jetty_compat()` when `.bind_jetty` is absent in `ubcore_jetty.c:2673-2683`.

TP-aware connect is different:

```text
create_tp_info()
  -> urma_get_tp_list()
  -> perftest exchanges TP handles/PSNs through its own TCP metadata path

connect_jetty_tp_aware()
  -> urma_import_jetty_ex(... active_cfg already filled ...)
  -> for RC: urma_bind_jetty_ex(... active_cfg already filled ...)
```

Because the TP handle and peer TP handle are already supplied, TP-aware perftest avoids the UBCM `UBCORE_NET_CREATE_REQ` / `UBCORE_NET_CREATE_RESP` exchange for that TP setup. It still enters kernel/provider import/bind and VTP activation paths, but the cross-node TP metadata exchange has already happened through the perftest side channel.

Relevant lines:
- `create_tp_info()` calls `urma_get_tp_list()` in `perftest_resources.c:1027-1064`.
- `connect_jetty_tp_aware()` calls `urma_import_jetty_ex()` and `urma_bind_jetty_ex()` in `perftest_resources.c:1574-1625`.

## 5. Other real consumers

### IPoURMA — the textbook case

`kernel/drivers/ub/urma/ulp/ipourma/ipourma_types.h:55`:
```c
IPOURMA_WELL_KNOWN_JETTY_ID = 32,
```

On startup, IPoURMA creates jettys at IDs `IPOURMA_WELL_KNOWN_JETTY_ID + eid_idx` for each local EID (`ipourma_res.c`). When sending IP traffic, IPoURMA derives the peer's jetty ID *without asking*:

`ipourma_ub.c`:
```c
u32 jetty_id = eid_index + IPOURMA_WELL_KNOWN_JETTY_ID;
```

Receiving side reverses the mapping:
```c
u32 eid_index = jetty_id - IPOURMA_WELL_KNOWN_JETTY_ID;
```

**Net effect: any pair of IPoURMA-enabled nodes can talk without a discovery handshake.** They just compute each other's jetty IDs from a public formula.

### bondp library

`umdk/src/urma/lib/urma/bond/bondp_types.h:35`:
```c
#define BONDP_MAX_WELL_KNOWN_JETTY_ID  (1024)
```

Bonding library reserves IDs up to 1024 for its management/control jettys. `bondp_api.c:1141` validates user-specified IDs against this ceiling:
```c
jetty_id > 0 && jetty_id < BONDP_MAX_WELL_KNOWN_JETTY_ID
```

### ubmgr / cluster control plane

ubmgr ping, topology probes, health checks — same pattern. Cluster-wide protocols where every node needs to know where to send without a per-pair handshake all live in the well-known range.

## 6. Constraint: page size

`udma_jetty.c:316, 341`:
```c
if ((CFGID_CHECK(cfg_id, udma_dev->caps.public_jetty) || ...) &&
    well_known_jetty_pgsz_check && PAGE_SIZE != UDMA_HW_PAGE_SIZE) {
    dev_err(...,
        "Does not support specifying Jetty ID on non-4KB page systems.\n");
    return -EINVAL;
}
```

Well-known jetty IDs are only allowed on **4KB-page systems** by default. The HW maps these jettys at fixed offsets that depend on page size, so 16K- or 64K-page kernels (common on ARM64) can't use them without disabling the check.

Module param to override (`udma_jetty.c:1864-1865`):
```c
module_param(well_known_jetty_pgsz_check, bool, 0444);
```

To use well-known jettys on a 64K-page ARM64 kernel:
```bash
modprobe udma well_known_jetty_pgsz_check=0
# or persistently
echo "options udma well_known_jetty_pgsz_check=0" \
    > /etc/modprobe.d/udma.conf
```

Ramifications: the HW page mappings may not behave correctly with a non-4KB host page size — it's an "off the warranty" path. Test thoroughly; consider sticking with normal (driver-allocated) jetty IDs on 64K-page systems for production.

## 7. Comparison with normal jetty

| | Normal jetty | Public / well-known jetty |
| --- | --- | --- |
| ID allocation | Driver-assigned at create time | Caller-specified, in reserved range |
| ID range | `[caps.jetty.start_idx, ...]` | `[caps.public_jetty.start_idx, ...]` |
| Discovery | Both sides need out-of-band ID exchange | Either side can compute the other's ID |
| Use case | Per-connection RPC, dynamic peers | Network-stack lower layers, cluster-wide control plane |
| Page-size constraint | none | 4KB only (by default) |
| ID conflict risk | none (driver picks unused IDs) | yes — two apps must agree on convention |
| IB analog | dynamic QPNs | QP0/QP1 well-known QPNs |
| TCP analog | ephemeral ports | well-known ports (0-1023) |

## 8. Practical guidance

- **If you're building a network-stack lower layer** (IP, RDMA-over-X transport) → use well-known jetty IDs. This is what they're for.
- **If you're building cluster-wide management/probe protocols** → use well-known jetty IDs.
- **If you're building per-connection RPC** → use normal driver-allocated IDs and exchange them via your bootstrap channel (UMQ, URPC's connect handshake, TCP, etc.).
- **If you're on a 64K-page kernel** and need well-known IDs: set `well_known_jetty_pgsz_check=0` at modprobe and validate end-to-end before relying on it in production.
- **Don't pick an arbitrary "well-known" ID** that conflicts with established conventions: IPoURMA owns 32+, bondp owns 0–1023. Check IPoURMA / bondp / ubmgr conventions before claiming an ID range for a new protocol.

## 9. References

- `kernel/include/ub/ubase/ubase_comm_dev.h:114` — `public_jetty_cnt` capability struct field.
- `kernel/drivers/ub/urma/hw/udma/udma_cmd.h:199-200` — `well_known_jetty_start`, `well_known_jetty_num` HW cmd fields.
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:172` — `reserved_jetty_id_max` exposed to userspace.
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:543, 561-562` — driver wires HW cap into `caps.public_jetty`.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:232-245` — normal jetty ID allocation can fall back into `caps.public_jetty`.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:298+` — `udma_verify_jetty_type_urma_normal`, `udma_verify_jetty_type_urma_ex`.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:316, 341` — page-size constraint enforcement.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:1864-1865` — `well_known_jetty_pgsz_check` module param.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_types.h:55` — `IPOURMA_WELL_KNOWN_JETTY_ID = 32`.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c` — IPoURMA's compute-don't-exchange jetty ID derivation.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_res.c` — IPoURMA's well-known-ID jetty creation.
- `umdk/src/urma/lib/urma/bond/bondp_types.h:35` — `BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024`.
- `umdk/src/urma/lib/urma/bond/bondp_api.c:1141, 1197` — bondp's well-known range validation.
- `kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:18-21` — UBMAD well-known jetty IDs 1 and 2.
- `kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c:947-963` — UBMAD well-known jetty resource array initialization.
- `kernel/drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c:768-873` — UBMAD send-side resource selection and remote tjetty import workqueue.
- `kernel/drivers/ub/urma/ubcore/net/ubcore_comm.c:55-183` — default net send path selects UBCM well-known jetty transport.
- `kernel/drivers/ub/urma/ubcore/net/ubcore_cm.c:168-224` — UBCM wrapping from `ubcore_net_msg` to `ubcore_cm_send_buf`.
- `kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:184-222` — create request/response message builders.
- `kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:334-410` — `ubcore_exchange_tp_info()` initiator-side TP exchange.
- `kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:707-799` — create request/response handlers.
