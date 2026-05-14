# UBMAD well-known jetty deep dive

_Last updated: 2026-05-14._

This is the expanded investigation of UBMAD's well-known jetty path: what a WK
jetty is, where the reserved public range comes from, when the local WK jettys
are created, how `ub_mad.c` is involved, and the detailed send/receive calling
chain used by link setup.

Primary source tree:

- Kernel: `/Volumes/KernelDev/kernel/drivers/ub/urma/`
- `urma_perftest`: `/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/`

Related docs:

- [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md)
- [`umdk_urma_perftest_function_graph.md`](umdk_urma_perftest_function_graph.md)
- [`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md)
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md)

## 1. Short Answer

UBMAD creates two local well-known jettys per `ubcore_device`: ID `1` and ID
`2`. ID `1` is the UBCM control-plane jetty used for link setup messages such
as `UBCORE_NET_CREATE_REQ` and `UBCORE_NET_CREATE_RESP`; ID `2` is selected for
`UBMAD_AUTHN_DATA`.

The important distinction:

- **Public jetty range**: UDMA provider capability. Hardware reports
  `well_known_jetty_start` and `well_known_jetty_num`; UDMA stores this as
  `udma_dev->caps.public_jetty`.
- **Concrete UBMAD WK jettys**: UBCM/UBMAD creates actual jetty objects with
  fixed IDs `1` and `2` inside that reserved/public range.

`ubcore_call_cm_send_ops()` does **not** create the WK jetty. It only dispatches
to the registered CM send op. The local WK jettys are created earlier through
UBMAD's ubcore client add path, or later through the CM EID-add path if the
device had no EID when UBMAD opened it.

`ub_mad.c` is the lifecycle/resource manager. It owns:

- fixed WK jetty ID list
- per-device UBMAD private object
- local WK JFC/JFR/jetty/segment creation
- EID-add/remove handling
- remote well-known tjetty import cache
- UBMAD agent registration for UBCM
- teardown and close notification

`ubmad_datapath.c` owns the actual send/receive datapath: selects
`jetty_rsrc[0]`, imports the remote WK tjetty if absent, posts the send WR,
polls completions, unwraps received MADs, and hands the payload back to UBCM.

## 2. File Map

| File | Role |
|---|---|
| `ubcore/ubcm/ub_mad_priv.h` | UBMAD private constants and structs: WK IDs, depths, resource structs, message layout |
| `ubcore/ubcm/ub_mad.h` | Public UBMAD API consumed by UBCM |
| `ubcore/ubcm/ub_mad.c` | UBMAD lifecycle, resource creation, EID ops, remote tjetty cache, agent registry |
| `ubcore/ubcm/ubmad_datapath.c` | UBMAD send/recv, retransmit, polling, message dispatch |
| `ubcore/ubcm/ub_cm.c` | UBCM module glue: initializes UBMAD, registers UBMAD agent, registers CM send op |
| `ubcore/net/ubcore_cm.c` | UBCM bridge: wraps net messages into CM send buffers and unwraps received CM payloads |
| `ubcore/net/ubcore_comm.c` | Default control transport selection; `UBCORE_CONNECT_WK_JETTY` is default |
| `ubcore/ubcore_connect_adapter.c` | Link setup create request/response logic |
| `hw/udma/udma_main.c`, `udma_cmd.h`, `udma_jetty.c` | UDMA public-jetty capability, validation, allocation, provider ops |

## 3. What "WK Jetty" Means Here

The code uses three related names:

- **well-known jetty / WK jetty**: fixed jetty IDs known by both peers before a
  handshake.
- **public jetty**: UDMA provider name for the reserved jetty-ID range.
- **reserved jetty ID**: ubcore/userspace-facing device attribute name for the
  same reserved range.

UBMAD defines two concrete WK IDs in
`/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:18-21`:

```c
#define UBMAD_WK_JETTY_NUM 2 /* well-known jetty 0 and 1 only used in ubcm */
#define UBMAD_WK_JETTY_ID_0 1U
#define UBMAD_WK_JETTY_ID_1 2U
```

`ub_mad.c` then initializes the actual ID array in
`ub_mad.c:22-28`:

```c
// udma jetty id starts from 1 currently
#define WK_JETTY_ID_INITIALIZER { UBMAD_WK_JETTY_ID_0, UBMAD_WK_JETTY_ID_1 }
static const uint32_t g_ubmad_wk_jetty_id[UBMAD_WK_JETTY_NUM] =
    WK_JETTY_ID_INITIALIZER;
```

The comment says "well-known jetty 0 and 1", but the actual jetty IDs are
`1` and `2`; `0` and `1` are the array/resource indexes:

- `dev_priv->jetty_rsrc[0]` -> real jetty ID `1`
- `dev_priv->jetty_rsrc[1]` -> real jetty ID `2`

UBMAD message types align with UBCM message types in
`ub_mad.h:20-30`:

```c
UBMAD_UBC_CONN_REQ   = UBCORE_CM_CONN_REQ,
UBMAD_UBC_CONN_RESP  = UBCORE_CM_CONN_RESP,
UBMAD_UBC_SINGLE_REQ = UBCORE_CM_SINGLE_REQ,
UBMAD_AUTHN_DATA     = 0x10,
UBMAD_CLOSE_REQ      = 0x20,
```

The UBMAD send-side selection rule is in
`ubmad_datapath.c:795-807`:

```text
UBMAD_UBC_CONN_REQ   -> dev_priv->jetty_rsrc[0]  -> WK ID 1
UBMAD_UBC_CONN_RESP  -> dev_priv->jetty_rsrc[0]  -> WK ID 1
UBMAD_UBC_SINGLE_REQ -> dev_priv->jetty_rsrc[0]  -> WK ID 1
UBMAD_AUTHN_DATA     -> dev_priv->jetty_rsrc[1]  -> WK ID 2
```

So the link setup path uses **WK jetty ID 1**.

## 4. Public Jetty Range From UDMA

The reserved public range starts at the provider/device capability layer, not
in UBMAD.

UDMA command resource fields in
`hw/udma/udma_cmd.h:198-200`:

```c
uint16_t well_known_jetty_start;
uint16_t well_known_jetty_num;
```

UDMA stores those into provider caps in
`hw/udma/udma_main.c:558-562`:

```c
udma_dev->caps.public_jetty.start_idx = cmd->well_known_jetty_start;
udma_dev->caps.public_jetty.max_cnt = cmd->well_known_jetty_num;
```

UDMA exposes the range upward as reserved jetty IDs. The current code exposes
the maximum as `public_jetty.max_cnt - 1` in `udma_main.c:164-172`, and config
validation requires the public range to be `0..max_cnt-1` in
`udma_main.c:253-258`.

On create, the UDMA validation accepts IDs in the public range. For normal URMA
jetty type, `udma_verify_jetty_type_urma_normal()` accepts `cfg_id` if it falls
inside `caps.public_jetty`, `caps.hdc_jetty`, or normal `caps.jetty`
(`udma_jetty.c:298-321`). The extended path accepts the public range too
(`udma_jetty.c:324-347`).

The provider create chain for a UBMAD WK jetty is:

```text
ubmad_create_jetty()                                      ub_mad.c:394
  -> ubcore_create_jetty()                                ubcore_jetty.c:2118
     -> ubcore_jetty_pre_check()
     -> dev->ops->create_jetty()
        -> udma_create_jetty()                            udma_jetty.c:655
           -> udma_active_jetty_detail()                  udma_jetty.c:637
              -> udma_alloc_jetty_sq()                    udma_jetty.c:502
                 -> alloc_jetty_id()                      udma_jetty.c:402
                    -> udma_verify_jetty_type()
                       -> accepts cfg_id in public_jetty range
                    -> if cfg_id > 0 and no jetty group:
                       -> udma_user_specify_jetty_id()
                       -> sq->id = cfg_id                 udma_jetty.c:410-415
              -> udma_add_xa_and_create_hw_ctx()
     -> fill ubcore jetty fields
     -> add to dev->ht[UBCORE_HT_JETTY]                   ubcore_jetty.c:2172
```

For UBMAD, `cfg_id` is fixed to `1` or `2`, so the driver follows the
specified-ID path rather than allocating a dynamic normal jetty ID.

## 5. `ub_mad.c` Resource Model

### 5.1 Global State

`ub_mad.c:30-35` owns three global registries:

```text
g_ubmad_device_list       all UBMAD per-device private objects
g_ubmad_device_list_lock

g_ubmad_agent_list        all registered UBMAD agents, normally one from UBCM
g_ubmad_agent_list_lock

g_ubc_eid_lock            serializes CM EID add/remove handling
```

### 5.2 `struct ubmad_device_priv`

Defined in `ub_mad_priv.h:135-155`.

This is UBMAD's per-`ubcore_device` object. It stores:

- `device`: owning ubcore device
- `kref`: lifetime
- `handler`: ubcore event handler, although its EID-change callback only logs
  "No need to handle eid event"
- `valid`: whether WK resources were successfully initialized
- `jetty_rsrc[UBMAD_WK_JETTY_NUM]`: two local WK jetty resources
- `rt_wq`: delayed retransmit workqueue for initiator-side reliable CM traffic
- `eid_info`: EID/EID index used by the local WK resources
- `has_create_jetty_rsrc`: whether EID ops have created resources
- `conn_wq`: workqueue used to import a remote WK tjetty on a send cache miss

### 5.3 `struct ubmad_jetty_resource`

Defined in `ub_mad_priv.h:73-96`.

One `ubmad_jetty_resource` is one local WK endpoint:

- fixed `jetty_id` (`1` or `2`)
- send JFC `jfc_s`
- recv JFC `jfc_r`
- shared JFR `jfr`
- local `struct ubcore_jetty *jetty`
- `tx_in_queue` throttle
- send segment and send bitmap
- recv segment and recv bitmap
- `tjetty_hlist[]`, a cache of imported remote WK target jettys keyed by
  destination primary EID

### 5.4 `struct ubmad_tjetty`

Defined in `ub_mad_priv.h:117-133`.

This wraps an imported remote target jetty:

- `tjetty`: `struct ubcore_tjetty *` returned by `ubcore_import_jetty_ex()`
- `kref`: cache/lifetime
- initiator reliable state:
  - `msn_mgr`: outstanding message sequence numbers
  - `ini_rt_hlist`: initiator retransmit buffers
- target reliable state:
  - `tgt_hash_hlist`: request MSN tracking
  - `tgt_rt_buffer`: cached response payloads for duplicate request replay
- back pointer to local `ubmad_jetty_resource`

### 5.5 `struct ubmad_msg`

Defined in `ub_mad_priv.h:167-182`.

Every UBMAD packet is stored directly inside one registered SGE slot:

```text
version
msg_type
payload_len
reserved
msn
payload[]
```

`msn` is the message sequence number used by the UBMAD reliability layer.

### 5.6 Agent Model

`struct ubmad_agent_priv` (`ub_mad_priv.h:157-165`) stores a public
`ubmad_agent` plus two workqueues:

- `jfce_wq_s`: send completion work
- `jfce_wq_r`: receive completion work

UBCM registers the agent in `ub_cm.c:171-200`:

```text
ubcm_add_device()
  -> ubmad_register_agent(device, ubcm_send_handler, ubcm_recv_handler, cm_dev)
```

That registration is what lets UBMAD call back into UBCM after send/receive
completion processing.

## 6. Module Init And Registration Chain

`ubcore_init()` calls `ubcore_exchange_init()` early, then later calls
`ubcm_init()` (`ubcore_main.c:35-75`).

Expanded chain:

```text
ubcore_init()                                               ubcore_main.c:35
  -> ubcore_exchange_init()                                 ubcore_main.c:39
     -> ubcore_net_register_msg_handler(CREATE_REQ,
                                        handle_create_req)  ubcore_connect_adapter.c:1337
     -> ubcore_net_register_msg_handler(CREATE_RESP,
                                        handle_create_resp)
     -> ubcore_net_register_msg_handler(DESTROY_REQ,
                                        handle_destroy_req)

  -> ubcm_init()                                            ubcore_main.c:71
     -> ubmad_init()                                        ub_cm.c:338
        -> INIT_LIST_HEAD(g_ubmad_device_list)
        -> INIT_LIST_HEAD(g_ubmad_agent_list)
        -> ubcore_register_client(&g_ubmad_client)          ub_mad.c:1279
           -> future/current devices call g_ubmad_client.add
        -> ubcore_register_cm_eid_ops(ubmad_ubc_eid_ops)    ub_mad.c:1286

     -> ubcm_base_init()                                    ub_cm.c:344
        -> INIT_LIST_HEAD(&cm_ctx->device_list)
        -> alloc_workqueue("ubcm")
        -> ubcore_register_client(&g_ubcm_client)           ub_cm.c:273
           -> future/current devices call g_ubcm_client.add

     -> ubcore_register_cm_send_ops(ubmad_ubc_send)         ub_cm.c:350
        -> g_send = ubmad_ubc_send                          ubcore_cm.c:94-98
```

The split matters:

- UBMAD client registration creates/manages WK resources.
- UBCM client registration creates the UBMAD agent that receives callbacks.
- CM send-op registration only sets a function pointer used later by
  `ubcore_call_cm_send_ops()`.

`ubcore_call_cm_send_ops()` is just:

```text
ubcore_call_cm_send_ops()                                   ubcore_cm.c:63
  -> if g_send missing: error
  -> return g_send(dev, send_buf)                           ubcore_cm.c:72
```

It does not allocate JFCs, JFRs, jettys, segments, or receive WQEs.

## 7. When The Local WK Jettys Are Created

There are two creation timings.

### 7.1 Case A: Device Already Has An EID

If the device has an EID when UBMAD opens it:

```text
ubcore_register_client(&g_ubmad_client)
  -> ubmad_add_device(device)                               ub_mad.c:1237
     -> ubmad_open_device(device)                           ub_mad.c:1113
        -> kzalloc ubmad_device_priv
        -> kref_init
        -> dev_priv->device = device
        -> dev_priv->handler.event_callback = ubmad_event_cb
        -> ubcore_register_event_handler(device, &handler)
        -> ubmad_create_device_priv_resources(dev_priv)     ub_mad.c:1128
           -> ubcore_get_eid_list(device, &cnt)             ub_mad.c:1027
           -> if no EID: return 0 without creating resources
           -> ubmad_init_jetty_rsrc_array(dev_priv->jetty_rsrc,
                                          dev_priv)          ub_mad.c:1035
              -> for i in [0, 2):
                 -> rsrc_array[i].jetty_id =
                    g_ubmad_wk_jetty_id[i]                  ub_mad.c:953-955
                 -> ubmad_init_jetty_rsrc(&rsrc_array[i],
                                          dev_priv)          ub_mad.c:955
           -> dev_priv->valid = true                        ub_mad.c:1042
        -> alloc rt_wq                                      ub_mad.c:1135
        -> alloc conn_wq                                    ub_mad.c:1147
        -> list_add_tail(&dev_priv->node,
                         &g_ubmad_device_list)              ub_mad.c:1162
```

Nuance: `ubmad_create_device_priv_resources()` only checks that an EID list
exists; it does not copy an entry from that list into `dev_priv->eid_info`.
During this open path, `dev_priv->eid_info.eid_index` is therefore whatever was
already present in the freshly allocated struct, normally zero. The EID-add path
below explicitly copies the EID info before creating resources.

### 7.2 Case B: Device Has No EID Yet

If no EID exists yet, `ubmad_create_device_priv_resources()` returns `0` and
logs that it will not create WK resources (`ub_mad.c:1027-1032`). This is not
treated as fatal. `ubmad_open_device()` continues to allocate workqueues and add
the private object to `g_ubmad_device_list`.

Later, a management EID-add event calls registered CM EID ops:

```text
ubcore_dispatch_mgmt_event()                                ubcore_device.c:2457
  -> ubcore_call_cm_eid_ops(dev, eid_info, event_type)       ubcore_cm.c:75
     -> g_eid_ops(dev, eid_info, event_type)
        == ubmad_ubc_eid_ops()                              ub_mad.c:257
```

The UVS command path can also call the same registered EID ops directly after
creating EID information (`ubcore_uvs_cmd.c:225-226`).

Expanded UBMAD EID-add chain:

```text
ubmad_ubc_eid_ops(dev, eid_info, UBCORE_MGMT_EVENT_EID_ADD)
  -> mutex_lock(g_ubc_eid_lock)
  -> ubmad_check_eid_in_dev(dev, eid_info)                  ub_mad.c:148
     -> scan dev->eid_table for matching eid + eid_index
  -> ubcore_get_main_primary_eid(&eid_info->eid,
                                 &main_primary_eid)         ub_mad.c:274
  -> if eid_info->eid != main_primary_eid:
       return 0; non-primary EIDs do not create WK resources
  -> ubmad_ubc_eid_ops_inner(dev, eid_info, event_type)      ub_mad.c:289
     -> ubmad_get_device_priv_lockless(dev)                 ub_mad.c:211-213
     -> if dev_priv->has_create_jetty_rsrc:
          -> ubmad_update_device_priv_resources()
             -> ubmad_destroy_device_priv_resources()
             -> copy new eid/eid_index
             -> ubmad_create_device_priv_resources()
             -> has_create_jetty_rsrc = true
        else:
          -> copy eid/eid_index into dev_priv->eid_info      ub_mad.c:229-231
          -> ubmad_create_device_priv_resources()            ub_mad.c:232
          -> has_create_jetty_rsrc = true                    ub_mad.c:237-238
  -> mutex_unlock(g_ubc_eid_lock)
```

This is the delayed creation path for devices whose EIDs arrive after UBMAD has
already registered its device object.

### 7.3 Local Resource Creation For Each WK ID

For each ID in `g_ubmad_wk_jetty_id[]`, UBMAD calls
`ubmad_init_jetty_rsrc()` (`ub_mad.c:792-880`):

```text
ubmad_init_jetty_rsrc(rsrc, dev_priv)
  -> ubmad_create_jfc_s(device)                             ub_mad.c:301
     -> jfc_cfg.depth = UBMAD_JFS_DEPTH                     ub_mad.c:307
     -> ubcore_create_jfc(... ubmad_jfce_handler_s ...)
     -> ubcore_rearm_jfc(jfc, false)
     -> rsrc->jfc_s = jfc

  -> ubmad_create_jfc_r(device)                             ub_mad.c:324
     -> jfc_cfg.depth = UBMAD_JFR_DEPTH                     ub_mad.c:330
     -> ubcore_create_jfc(... ubmad_jfce_handler_r ...)
     -> ubcore_rearm_jfc(jfc, false)
     -> rsrc->jfc_r = jfc

  -> ubmad_create_jfr(dev_priv, jfc_r)                      ub_mad.c:347
     -> jfr_cfg.id = 0
     -> jfr_cfg.depth = UBMAD_JFR_DEPTH
     -> jfr_cfg.flag.bs.token_policy = UBCORE_TOKEN_NONE
     -> jfr_cfg.trans_mode = UBCORE_TP_UM
     -> jfr_cfg.eid_index = dev_priv->eid_info.eid_index
     -> jfr_cfg.max_sge = UBMAD_JFR_MAX_SGE_NUM
     -> jfr_cfg.jfc = jfc_r
     -> ubcore_create_jfr()
     -> rsrc->jfr = jfr

  -> ubmad_create_jetty(dev_priv, jfc_s, jfc_r, jfr,
                        rsrc->jetty_id)                     ub_mad.c:830
     -> jetty_cfg.id = jetty_id                             ub_mad.c:402
     -> jetty_cfg.flag.bs.share_jfr = 1
     -> jetty_cfg.trans_mode = UBCORE_TP_UM
     -> jetty_cfg.eid_index = dev_priv->eid_info.eid_index
     -> jetty_cfg.jfs_depth = UBMAD_JFS_DEPTH
     -> ubmad_jetty_set_priority()
        -> query dev attr
        -> choose first priority whose tp_type.bs.rtp == 1
        -> if none, log and continue with priority 0
     -> set max_send_sge, max_send_rsge, jfr_depth,
        max_recv_sge, send_jfc, recv_jfc, jfr, err_timeout
     -> ubcore_create_jetty()
     -> rsrc->jetty = jetty

  -> atomic_set(&rsrc->tx_in_queue, 0)
  -> ubmad_create_seg(rsrc, device)
     -> register send segment and recv segment
     -> create send bitmap of UBMAD_SEND_SGE_NUM
     -> create recv bitmap of UBMAD_RECV_SGE_NUM

  -> for idx in [0, UBMAD_JFR_DEPTH):
       -> ubmad_post_recv(rsrc)                             ub_mad.c:852-855
          -> allocate recv SGE bitmap slot                  ubmad_datapath.c:943
          -> build ubcore_jfr_wr
          -> ubcore_post_jetty_recv_wr(rsrc->jetty, ...)    ubmad_datapath.c:957

  -> initialize rsrc->tjetty_hlist[]
  -> spin_lock_init(&rsrc->tjetty_hlist_lock)
```

After this, the local WK jetty is actually listening: it has receive WQEs
preposted on the shared JFR, and the recv JFC handler is armed.

## 8. UBCM Agent Registration

UBMAD owns the transport mechanics, but UBCM owns the higher-level CM protocol.
The bridge is the UBMAD agent registered in `ubcm_add_device()`.

```text
ubcore_register_client(&g_ubcm_client)
  -> ubcm_add_device(device)                                ub_cm.c:171
     -> kzalloc ubcm_device
     -> ubcm_get_ubc_dev(device)
     -> ubmad_register_agent(device,
                             ubcm_send_handler,
                             ubcm_recv_handler,
                             cm_dev)                        ub_cm.c:188-189
        -> kzalloc ubmad_agent_priv                         ub_mad.c:1362
        -> alloc jfce_wq_s                                  ub_mad.c:1367
        -> alloc jfce_wq_r                                  ub_mad.c:1373
        -> agent->device = device
        -> agent->send_handler = ubcm_send_handler
        -> agent->recv_handler = ubcm_recv_handler
        -> list_add_tail(&agent_priv->node,
                         &g_ubmad_agent_list)               ub_mad.c:1387-1391
     -> list_add_tail(&cm_dev->list_node, &cm_ctx->device_list)
     -> ubcore_set_client_ctx_data(device, &g_ubcm_client, cm_dev)
```

Send completion callback:

```text
ubmad_send_work_handler()
  -> if cr.status == UBCORE_CR_SUCCESS:
       -> agent_priv->agent.send_handler(&agent, &send_cr)
          == ubcm_send_handler()
             -> validate completion status only             ub_cm.c:131-146
```

Receive callback:

```text
ubmad_cm_process_msg()
  -> recv_cr.msg_type = UBMAD_UBC_CONN_REQ                  ubmad_datapath.c:977-978
  -> agent_priv->agent.recv_handler(&agent, &recv_cr)
     == ubcm_recv_handler()
        -> ubcore_cm_recv(agent->device, recv_cr)           ub_cm.c:148-162
```

Important nuance: `ubmad_cm_process_msg()` sets `recv_cr.msg_type` to
`UBMAD_UBC_CONN_REQ` for every CM message it forwards, including connection
responses and single messages. The original packet type remains inside the
payload's embedded `ubcore_net_msg` header; UBCM uses that after
`ubcore_cm_recv()` unwraps the payload. This is why `ubcm_recv_handler()` only
has a case for `UBMAD_UBC_CONN_REQ`.

## 9. Link Setup Send Path: Initiator Create Request

The link setup request starts in `ubcore_exchange_tp_info()`, not in UBMAD.
UBMAD is the transport used to send the CM message.

```text
ubcore_exchange_tp_info(dev, get_tp_cfg, active_tp_cfg,
                        tjetty_cfg, udata)                  ubcore_connect_adapter.c:334
  -> if loopback:
       -> fill peer_tp_handle/rx_psn locally
       -> return
  -> create_session_for_create_connection()
  -> req.get_tp_cfg = *get_tp_cfg
  -> req.tp_handle = active_tp_cfg->tp_handle
  -> req.tx_psn = active_tp_cfg->tp_attr.tx_psn
  -> req.share_tp = tjetty_cfg->flag.bs.share_tp
  -> send_create_req(dev, session_id, &req)                 ubcore_connect_adapter.c:376
     -> msg.type = UBCORE_NET_CREATE_REQ                    ubcore_connect_adapter.c:190
     -> msg.len = sizeof(msg_create_conn_req)
     -> msg.session_id = session_id
     -> msg.data = req
     -> ubcore_net_send_to(dev, &msg, req->get_tp_cfg.peer_eid)
```

`ubcore_net_send_to()` chooses the default control transport. The default is
`UBCORE_CONNECT_WK_JETTY` in `ubcore_comm.c:55-62`.

```text
ubcore_net_send_to(dev, msg, peer_eid)                      ubcore_comm.c:157
  -> if peer_eid is loopback:
       -> ubcore_net_handle_msg(dev, msg, NULL)
  -> ep = ubcore_comm_get_default_endpoint()
  -> if ep exists:
       -> ubcore_comm_send_to(ep, dev, peer_eid, msg)
  -> switch g_ubcore_connect_type:
       UBCORE_CONNECT_WK_JETTY:
         -> ubcore_ubcm_send_to(dev, peer_eid, msg)         ubcore_comm.c:175-177
```

`ubcore_ubcm_send_to()` wraps the net message into a CM send buffer:

```text
ubcore_ubcm_send_to(dev, addr, msg)                         ubcore_cm.c:168
  -> allocate ubcore_cm_send_buf
  -> send_buf->session_id = msg->session_id
  -> send_buf->dst_eid = addr
  -> map msg->type:
       UBCORE_NET_CREATE_REQ  -> UBCORE_CM_CONN_REQ         ubcore_cm.c:194-197
       UBCORE_NET_CREATE_RESP -> UBCORE_CM_CONN_RESP        ubcore_cm.c:198-201
       DESTROY/BONDING_USER   -> UBCORE_CM_SINGLE_REQ       ubcore_cm.c:202-205
  -> send_buf->payload_len = MSG_HDR_SIZE + msg->len
  -> copy ubcore_net_msg header to send_buf->payload
  -> copy msg->data after header
  -> ubcore_call_cm_send_ops(dev, send_buf)                 ubcore_cm.c:218
     -> g_send(dev, send_buf)
        == ubmad_ubc_send(dev, send_buf)
  -> free send_buf after g_send returns
```

UBMAD's registered send op fills `src_eid` and enters the datapath:

```text
ubmad_ubc_send(device, send_buf)                            ubmad_datapath.c:1155
  -> validate msg_type is CONN_REQ/CONN_RESP/SINGLE/CLOSE
  -> dev_priv = ubmad_get_device_priv(device)
  -> send_buf->src_eid = dev_priv->eid_info.eid             ubmad_datapath.c:1181
  -> ubmad_put_device_priv(dev_priv)
  -> ubmad_post_send(device, (struct ubmad_send_buf *)send_buf,
                     &bad_send_buf)                         ubmad_datapath.c:1188
```

`ubmad_post_send()` selects local WK resource ID 1 for link setup messages:

```text
ubmad_post_send(device, send_buf, bad_send_buf)             ubmad_datapath.c:768
  -> dev_priv = ubmad_get_device_priv(device)
  -> if !dev_priv->valid:
       -> error "dev_priv rsrc not inited"                  ubmad_datapath.c:788-792
  -> switch send_buf->msg_type:
       UBMAD_UBC_CONN_REQ   -> rsrc = &dev_priv->jetty_rsrc[0]
       UBMAD_UBC_CONN_RESP  -> rsrc = &dev_priv->jetty_rsrc[0]
       UBMAD_UBC_SINGLE_REQ -> rsrc = &dev_priv->jetty_rsrc[0]
       UBMAD_AUTHN_DATA     -> rsrc = &dev_priv->jetty_rsrc[1]
  -> ubcore_get_main_primary_eid(&send_buf->dst_eid,
                                 &dst_primary_eid)          ubmad_datapath.c:817
  -> hash dst_primary_eid
  -> lookup remote WK tjetty in rsrc->tjetty_hlist
```

### 9.1 Fast Path: Remote WK Tjetty Already Imported

```text
ubmad_post_send()
  -> found cached ubmad_tjetty                              ubmad_datapath.c:828
  -> ubmad_do_post_send(rsrc, tjetty, send_buf,
                        send_buf->session_id,
                        dev_priv->rt_wq)                    ubmad_datapath.c:832
     -> allocate send SGE slot from rsrc->send_seg_bitmap   ubmad_datapath.c:674
     -> ubmad_prepare_msg()
        -> write ubmad_msg header into SGE
        -> msg.version = UBMAD_MSG_VERSION_0
        -> msg.msn = send_buf->session_id
        -> msg.msg_type = send_buf->msg_type
        -> msg.payload_len = send_buf->payload_len
        -> copy CM payload                                  ubmad_datapath.c:487-492
     -> build ubcore_jfs_wr:
        -> opcode = UBCORE_OPC_SEND
        -> tjetty = cached remote WK tjetty
        -> one SGE pointing into send segment
        -> user_ctx = sge_addr
        -> complete_enable = 1
     -> dispatch by UBMAD msg type                          ubmad_datapath.c:701-719
        CONN_REQ   -> ubmad_do_post_send_conn_data()
        CONN_RESP  -> ubmad_do_post_send_conn_resp_data()
        SINGLE_REQ -> ubmad_do_post_send_conn_single()
```

For `CONN_REQ`, UBMAD makes the send reliable:

```text
ubmad_do_post_send_conn_data()                              ubmad_datapath.c:497
  -> create msn_node before posting                         ubmad_datapath.c:514-517
  -> increment rsrc->tx_in_queue, enforce threshold
  -> ubcore_post_jetty_send_wr(local_wk_jetty, wr, bad_wr)  ubmad_datapath.c:532
     -> provider post send, e.g. udma_post_jetty_send_wr()  udma_jetty.c:1440
  -> ubmad_create_rt_work(rt_wq, msn_mgr, msn, dst_eid,
                          rsrc)                             ubmad_datapath.c:541
     -> queue delayed retry work after 2 ms                 ubmad_datapath.c:455-457
  -> if payload fits, save retransmit copy in ini_rt_hlist
```

For `CONN_RESP`, UBMAD posts the send and caches the response payload in the
target response buffer so duplicate requests can be answered without invoking
the adapter again (`ubmad_datapath.c:567-618`).

### 9.2 Slow Path: Remote WK Tjetty Not Imported Yet

If the remote target is missing, `ubmad_post_send()` does not import it inline.
It copies the send buffer and queues connection work:

```text
ubmad_post_send()
  -> allocate ubmad_jetty_work                              ubmad_datapath.c:844
  -> allocate private copy of ubmad_send_buf                ubmad_datapath.c:849
  -> jetty_work->dev_priv = dev_priv
  -> jetty_work->rsrc = rsrc
  -> jetty_work->dst_primary_eid = dst_primary_eid
  -> jetty_work->send_buf = copied send buf
  -> queue_work(dev_priv->conn_wq, ubmad_jetty_work_handler)
```

The workqueue imports the remote WK target jetty, then posts:

```text
ubmad_jetty_work_handler(work)                              ubmad_datapath.c:734
  -> ubmad_import_jetty(device, rsrc, dst_primary_eid)       ubmad_datapath.c:745
     -> lookup tjetty cache again                           ub_mad.c:586-593
     -> kzalloc ubmad_tjetty
     -> tjetty_cfg.id.id = rsrc->jetty_id                   ub_mad.c:602
     -> tjetty_cfg.id.eid = dst_eid                         ub_mad.c:603
     -> tjetty_cfg.flag.bs.token_policy = UBCORE_TOKEN_NONE
     -> tjetty_cfg.trans_mode = UBCORE_TP_UM
     -> tjetty_cfg.type = UBCORE_JETTY
     -> tjetty_cfg.eid_index = local WK jetty eid_index
     -> ubmad_import_jetty_compat(device, &tjetty_cfg, NULL)
        -> ubmad_fill_get_tp_cfg()
           -> get_tp_cfg.flag.bs.utp = 1                    ub_mad.c:507-510
           -> get_tp_cfg.trans_mode = cfg->trans_mode
           -> local_eid = device eid_table[eid_index].eid
           -> peer_eid = cfg->id.eid
        -> ubcore_get_tp_list(dev, &get_tp_cfg, &tp_cnt,
                              &tp_list, NULL)               ub_mad.c:550
        -> active_tp_cfg.tp_handle = tp_list.tp_handle
        -> ubcore_import_jetty_ex(dev, cfg,
                                  &active_tp_cfg, NULL)     ub_mad.c:564
           -> dev->ops->import_jetty_ex()
           -> for UB + UM/RM/shared RC:
              -> ubcore_connect_vtp_ctrlplane()             ubcore_jetty.c:2569-2585
     -> initialize retransmit and target-response state
     -> double-check tjetty cache under lock
     -> add new ubmad_tjetty to rsrc->tjetty_hlist
  -> ubmad_do_post_send(rsrc, wk_tjetty, copied_send_buf,
                        session_id, dev_priv->rt_wq)
  -> ubmad_put_tjetty(wk_tjetty)
  -> ubmad_put_device_priv(dev_priv)
  -> free copied send buffer and work item
```

The remote target jetty ID is not exchanged. UBMAD constructs it from:

```text
remote EID = dst_primary_eid
remote jetty ID = rsrc->jetty_id  // 1 for link setup
```

That is the essence of the well-known jetty bootstrap.

## 10. `ubcore_get_tp_list()` Under The WK Import Path

The WK send path can itself need a TP to import the peer's WK target jetty.
That TP lookup is the call to `ubcore_get_tp_list()` inside
`ubmad_import_jetty_compat()`.

Expanded lower path:

```text
ubmad_import_jetty_compat()                                 ub_mad.c:530
  -> ubmad_fill_get_tp_cfg()
  -> ubcore_get_tp_list(dev, &get_tp_cfg, &tp_cnt,
                        &tp_list, NULL)                     ub_mad.c:550
     -> validate dev->ops->get_tp_list exists               ubcore_tp.c:33-35
     -> dev->ops->get_tp_list(dev, cfg, tp_cnt,
                              tp_list, udata)               ubcore_tp.c:43
        -> udma_get_tp_list()                               udma_ctrlq_tp.c:652
           -> udma_tp_cache_get_or_fetch()                  udma_ctrlq_tp.c:658
              -> udma_tp_cache_get_or_fetch_owner()         udma_tp_cache.c:528
                 -> if cache disabled or missing:
                    -> udma_tp_cache_fetch_uncached()
                       -> udma_tp_cache_build_key()
                       -> udma_tp_cache_fetch_rsp()
                          -> udma_ctrlq_fetch_tpid_list()   udma_tp_cache.c:254
                       -> udma_tp_cache_copy_rsp()
                       -> udma_ctrlq_store_tpid_list()
                 -> if cache enabled:
                    -> build cache key
                    -> wait if another fill is in progress
                    -> return hit if entry is fresh
                    -> evict stale entry
                    -> insert filling entry
                    -> fetch ctrlq response
                    -> complete waiting callers
                    -> copy response to ubcore_tp_info
```

This means a WK-jetty send is not "free of TP setup." The well-known jetty
removes the need to exchange the peer jetty ID, but the sender may still need a
TP-list lookup and a target-jetty import before its first control packet can be
posted.

## 11. Receive Path: Peer Handles `CREATE_REQ`

The peer already created local WK jetty ID `1` and preposted receive WQEs during
`ubmad_init_jetty_rsrc()`.

When the create request arrives:

```text
hardware/provider completes recv on local WK jetty ID 1
  -> recv JFC callback ubmad_jfce_handler_r(jfc)             ubmad_datapath.c:1429
     -> ubmad_jfce_handler(jfc, UBMAD_RECV_WORK)             ubmad_datapath.c:1375
        -> ubmad_get_agent_priv(jfc->ub_dev)
        -> kzalloc ubmad_jfce_work
        -> queue_work(agent_priv->jfce_wq_r,
                      ubmad_jfce_work_handler)              ubmad_datapath.c:1405

ubmad_jfce_work_handler(work)                               ubmad_datapath.c:1329
  -> dev_priv = ubmad_get_device_priv(dev)
  -> if !dev_priv->valid: error
  -> type == UBMAD_RECV_WORK:
       -> ubmad_recv_work_handler(dev_priv, jfce_work)      ubmad_datapath.c:1266
          -> ubmad_get_jetty_rsrc_by_jfc_r(dev_priv, jfc)   ub_mad.c:996
          -> loop:
             -> ubcore_poll_jfc(jfc, 1, &cr)                ubmad_datapath.c:1285
             -> if cr.status == UBCORE_CR_SUCCESS:
                  -> ubmad_process_msg(&cr, rsrc, dev_priv,
                                       agent_priv)           ubmad_datapath.c:1295
             -> free recv SGE bitmap slot
             -> ubmad_post_recv(rsrc) to refill JFR WQE     ubmad_datapath.c:1311-1313
          -> ubcore_rearm_jfc(jfc, false)
```

`ubmad_process_msg()` validates the message length and dispatches by UBMAD
message type (`ubmad_datapath.c:1110-1150`):

```text
UBMAD_UBC_CONN_REQ
  -> ubmad_process_conn_data()

UBMAD_UBC_CONN_RESP
  -> ubmad_process_conn_resp()

UBMAD_UBC_SINGLE_REQ
  -> ubmad_process_conn_single()

UBMAD_CLOSE_REQ
  -> ubmad_process_close_req()
```

For a create request:

```text
ubmad_process_conn_data(cr, rsrc, dev_priv, agent_priv)     ubmad_datapath.c:991
  -> msg = (struct ubmad_msg *)cr->user_ctx
  -> seid = cr->remote_id.eid
  -> ubmad_try_repost_all_response(dev_priv->device, rsrc,
                                   seid, msg->msn)           ubmad_datapath.c:1004
     -> if remote sender tjetty not cached:
          -> ubmad_import_jetty(dev, rsrc, seid)             ubmad_datapath.c:307-310
     -> find/create target hash node for msn
     -> if this is duplicate and response cached:
          -> repost cached response via ubcore_post_jetty_send_wr()
          -> return 0
     -> if this is first request or response overflow:
          -> return -2
  -> if repost returned 0:
       -> stop; duplicate already answered
  -> ubmad_cm_process_msg(cr, local_wk_eid, msg, agent_priv)
     -> build ubmad_recv_cr
     -> recv_cr.msg_type = UBMAD_UBC_CONN_REQ               ubmad_datapath.c:977-978
     -> recv_cr.payload points at embedded ubcore_net_msg
     -> agent recv_handler == ubcm_recv_handler()
        -> ubcore_cm_recv()                                 ub_cm.c:156
```

UBCM unwraps the payload and hands it to ubcore net dispatch:

```text
ubcore_cm_recv(dev, recv_cr)                                ubcore_cm.c:100
  -> addr = recv_cr->cr->remote_id.eid
  -> memcpy ubcore_net_msg header from recv_cr->payload      ubcore_cm.c:116
  -> msg.data = recv_cr->payload + MSG_HDR_SIZE             ubcore_cm.c:117
  -> ubcore_cm_lookup_ep(dev, &recv_cr->local_eid)
  -> if endpoint recv_cb exists:
       -> ep->recv_cb(ep, dev, &msg, &addr)
     else:
       -> ubcore_net_handle_msg(dev, &msg, &addr)           ubcore_cm.c:125

ubcore_net_handle_msg(dev, msg, conn)                       ubcore_comm.c:83
  -> desc = g_msg_descriptors[msg->type]
  -> validate msg length
  -> desc->handler(dev, msg, conn)                          ubcore_comm.c:106
     -> handle_create_req(dev, msg, conn)
```

`handle_create_req()` is the peer-side link setup handler:

```text
handle_create_req(dev, msg, conn)                           ubcore_connect_adapter.c:707
  -> req = msg->data
  -> get_tp_cfg = req->get_tp_cfg
  -> reverse EIDs:
       local_eid = req.peer_eid                             ubcore_connect_adapter.c:720
       peer_eid  = req.local_eid                            ubcore_connect_adapter.c:721
  -> tx_psn = get_random_u32()
  -> if RM/RTP/share_tp:
       -> ubcore_get_rm_stp_list()
     else:
       -> ubcore_get_tp_list(dev, &get_tp_cfg,
                             &tp_cnt, &tp_info, NULL)       ubcore_connect_adapter.c:732
  -> active_cfg.tp_handle = tp_info.tp_handle
  -> active_cfg.peer_tp_handle = req->tp_handle
  -> active_cfg.tp_attr.rx_psn = req->tx_psn
  -> active_cfg.tp_attr.tx_psn = tx_psn
  -> if RM/RTP/share_tp:
       -> ubcore_active_rm_share_tp()
     else:
       -> ubcore_active_tp(dev, &active_cfg)                ubcore_connect_adapter.c:760
  -> resp.tp_handle = local tp_handle
  -> resp.tx_psn = tx_psn
  -> resp.result = CREATE_CONN_SUCCESS or error
  -> send_create_resp(dev, conn, msg->session_id, &resp)    ubcore_connect_adapter.c:774
```

## 12. Response Path Back To Initiator

The peer response uses the same UBCM WK jetty path, but with
`UBCORE_NET_CREATE_RESP`.

```text
send_create_resp(dev, conn, session_id, resp)               ubcore_connect_adapter.c:204
  -> msg.type = UBCORE_NET_CREATE_RESP
  -> msg.len = sizeof(msg_create_conn_resp)
  -> msg.session_id = session_id
  -> msg.data = resp
  -> ubcore_net_send(dev, &msg, conn)                       ubcore_connect_adapter.c:216
```

`ubcore_net_send()` uses the same default transport:

```text
ubcore_net_send()
  -> if conn == NULL: loopback shortcut
  -> if default endpoint: ubcore_comm_send()
  -> UBCORE_CONNECT_WK_JETTY:
       -> ubcore_ubcm_send(dev, conn, msg)                  ubcore_comm.c:147-149
          -> ubcore_ubcm_send_to(dev, *(union ubcore_eid *)conn, msg)
             -> msg type CREATE_RESP maps to UBCORE_CM_CONN_RESP
             -> ubcore_call_cm_send_ops()
                -> ubmad_ubc_send()
                   -> ubmad_post_send()
                      -> select dev_priv->jetty_rsrc[0]
                      -> import/lookup remote WK tjetty
                      -> ubmad_do_post_send()
                         -> ubmad_do_post_send_conn_resp_data()
                            -> ubcore_post_jetty_send_wr()
                            -> cache response payload for duplicate request replay
```

On the original initiator:

```text
recv completion on WK ID 1
  -> ubmad_jfce_handler_r()
  -> ubmad_recv_work_handler()
  -> ubmad_process_msg()
     -> msg_type == UBMAD_UBC_CONN_RESP
     -> ubmad_process_conn_resp()                           ubmad_datapath.c:1023
        -> tjetty = ubmad_get_tjetty(seid, rsrc)
        -> find msn_node in tjetty->msn_mgr.msn_hlist
        -> if found:
             -> remove msn_node; this response is effective
             -> ubmad_cm_process_msg()
                -> ubcm_recv_handler()
                -> ubcore_cm_recv()
                -> ubcore_net_handle_msg()
                -> handle_create_resp()
        -> if not found:
             -> redundant ack; ignore

handle_create_resp(dev, msg, conn)                          ubcore_connect_adapter.c:778
  -> session = ubcore_session_find(msg->session_id)
  -> session_data->rx_psn = resp->tx_psn                    ubcore_connect_adapter.c:792
  -> session_data->peer_tp_handle = resp->tp_handle         ubcore_connect_adapter.c:793
  -> session_data->ret = resp->result                       ubcore_connect_adapter.c:794
  -> ubcore_session_complete(session)                       ubcore_connect_adapter.c:797
```

`ubcore_exchange_tp_info()` has been waiting in `ubcore_session_wait()`
(`ubcore_connect_adapter.c:384`). After the response completes the session, it
copies `peer_tp_handle` and `rx_psn` back into the caller's
`active_tp_cfg` (`ubcore_connect_adapter.c:396-397`).

## 13. Retransmission And Duplicate Suppression

UBMAD adds a small reliability layer on top of WK jetty sends.

Initiator state:

```text
CONN_REQ send
  -> ubmad_do_post_send_conn_data()
     -> create msn_node in tjetty->msn_mgr                  ubmad_datapath.c:517
     -> post send WR
     -> queue ubmad_rt_work after 2 ms                      ubmad_datapath.c:455-457
     -> copy payload to ini_rt_hlist if small enough
```

Delayed retry:

```text
ubmad_rt_work_handler()                                     ubmad_datapath.c:383
  -> look for msn_node in msn_hlist
  -> if found:
       -> response has not removed it yet
       -> rt_cnt++
       -> ubmad_repost_send_conn_data()
          -> get cached tjetty
          -> allocate send SGE
          -> copy saved payload from ini_rtbuffer
          -> ubcore_post_jetty_send_wr()
       -> if repost ok and retry count <= ubcore_max_retry_cnt:
          -> queue delayed work again with exponential delay
  -> if not found or retry limit reached:
       -> release ini_rtbuffer
       -> free rt_work
```

Target duplicate suppression:

```text
CONN_REQ receive
  -> ubmad_process_conn_data()
     -> ubmad_try_repost_all_response()
        -> get/import tjetty for sender EID
        -> find/create target hash node for msn
        -> if this MSN already has cached response:
             -> repost cached response directly
             -> do not call ubcore adapter again
        -> if first request:
             -> return -2; let ubcore handle request
```

Response receive:

```text
CONN_RESP receive
  -> ubmad_process_conn_resp()
     -> find msn_node in initiator tjetty->msn_mgr
     -> remove it
     -> pass CM payload to UBCM/ubcore
```

`ubcore_max_retry_cnt` is a module parameter described as "maximum retry count
for wk-jetty" in `ubcore_main.c:32-33`; default value is `11` in
`ubmad_datapath.c:19`.

Review note: `ubmad_repost_send_conn_data()` gets a `ubmad_tjetty` reference at
`ubmad_datapath.c:233` and releases it on several error paths, but the success
path returns immediately after `ubcore_post_jetty_send_wr()` without a local
put. That may be intentional if some later completion path owns the reference,
but I did not find that handoff in this pass. It is worth a focused review if
WK retransmission leaks are suspected.

## 14. Send And Receive Completion Handling

Send JFC callback:

```text
ubmad_jfce_handler_s(jfc)                                   ubmad_datapath.c:1424
  -> ubmad_jfce_handler(jfc, UBMAD_SEND_WORK)
     -> ubmad_get_agent_priv(jfc->ub_dev)
     -> allocate ubmad_jfce_work
     -> queue_work(agent_priv->jfce_wq_s,
                   ubmad_jfce_work_handler)

ubmad_jfce_work_handler()
  -> type == UBMAD_SEND_WORK
  -> ubmad_send_work_handler(dev_priv, jfce_work)           ubmad_datapath.c:1199
     -> ubmad_get_jetty_rsrc_by_jfc_s(dev_priv, jfc)
     -> poll JFC in a loop
     -> atomic_dec(&rsrc->tx_in_queue)
     -> if status success:
          -> agent send_handler == ubcm_send_handler()
     -> compute send SGE slot from cr.user_ctx
     -> ubmad_bitmap_put_id(rsrc->send_seg_bitmap, sge_idx)
     -> ubcore_rearm_jfc(jfc, false)
```

Receive JFC callback was covered in the receive path above. Its core cleanup is:

```text
ubmad_recv_work_handler()
  -> poll one receive completion
  -> ubmad_process_msg()
  -> compute recv SGE slot from cr.user_ctx
  -> ubmad_bitmap_put_id(rsrc->recv_seg_bitmap, sge_idx)
  -> ubmad_post_recv(rsrc)      // refill one WQE
  -> ubcore_rearm_jfc(jfc, false)
```

The receive side stays armed and replenished one consumed WQE at a time.

## 15. Teardown Path

On UBMAD device removal:

```text
ubmad_remove_device(device)                                 ub_mad.c:1253
  -> ubmad_notify_close(device)                             ub_mad.c:1257
     -> ubmad_get_device_priv_lockless(device)
     -> for each rsrc in jetty_rsrc[0..1]:
          -> ubmad_rsrc_notify_close(rsrc)                  ub_mad.c:1169
             -> iterate cached remote tjettys
             -> ubmad_post_send_close_req(rsrc, tjetty)
                -> build UBMAD_CLOSE_REQ packet             ubmad_datapath.c:880
                -> ubcore_post_jetty_send_wr()
  -> ubmad_close_device(device)                             ub_mad.c:1259
     -> remove dev_priv from g_ubmad_device_list
     -> ubmad_put_device_priv() twice
        -> ubmad_release_device_priv()
           -> drain/destroy rt_wq
           -> drain/destroy conn_wq
           -> ubmad_destroy_device_priv_resources()
              -> ubmad_uninit_jetty_rsrc_array()
                 -> ubmad_uninit_jetty_rsrc(each)
                    -> remove/unimport all cached tjettys
                    -> destroy send/recv segments
                    -> delete local WK jetty
                    -> delete JFR
                    -> delete recv JFC
                    -> delete send JFC
           -> ubcore_unregister_event_handler()
           -> kfree(dev_priv)
```

`UBMAD_CLOSE_REQ` is sent through the dedicated
`ubmad_post_send_close_req()` path. `ubmad_ubc_send()` accepts
`UBMAD_CLOSE_REQ` in its validation (`ubmad_datapath.c:1166-1169`), but
`ubmad_post_send()` does not select a resource for `UBMAD_CLOSE_REQ`; its switch
only handles connection request/response/single and authn data. In the observed
teardown code, close notification does not go through `ubmad_ubc_send()`.

## 16. Detailed `ub_mad.c` Function Catalog

### Common Bitmap Helpers

`ubmad_create_bitmap()` (`ub_mad.c:47`) allocates a bitmap wrapper and backing
bits. Used by send/recv segment slot allocators.

`ubmad_destroy_bitmap()` (`ub_mad.c:65`) frees bitmap bits and wrapper.

`ubmad_bitmap_get_id()` (`ub_mad.c:72`) finds the first zero bit, sets it, and
returns the ID. This is the hot allocation helper for SGE slots.

`ubmad_bitmap_put_id()` (`ub_mad.c:88`) clears a bit. Send completion and
receive completion use it to return SGE slots.

`ubmad_bitmap_test_id()` (`ub_mad.c:101`) returns whether a bit was previously
clear, but also sets it. The name is easy to misread: it is not a pure test.

`ubmad_bitmap_set_id()` (`ub_mad.c:118`) force-sets an ID.

### Event And EID Handling

`ubmad_event_cb()` (`ub_mad.c:134`) is registered as a generic ubcore event
handler, but for `UBCORE_EVENT_EID_CHANGE` it only logs "No need to handle eid
event." Real WK resource re-create logic is in the registered CM EID ops, not
this callback.

`ubmad_check_eid_in_dev()` (`ub_mad.c:148`) scans the device EID table for the
specific `(eid, eid_index)` pair.

`ubmad_update_device_priv_resources()` (`ub_mad.c:170`) destroys old WK
resources, copies new EID info, creates resources again, and sets
`has_create_jetty_rsrc`.

`ubmad_ubc_eid_ops_inner()` (`ub_mad.c:203`) handles add/remove after
`ubmad_ubc_eid_ops()` has validated the EID. On add, it either updates existing
resources or creates them for the first time. On remove, it destroys resources
and clears `has_create_jetty_rsrc`.

`ubmad_ubc_eid_ops()` (`ub_mad.c:257`) is the registered CM EID operation. It
serializes with `g_ubc_eid_lock`, validates that the EID exists in the device,
normalizes to main primary EID, ignores non-primary EIDs, and delegates to
`ubmad_ubc_eid_ops_inner()`.

### Local JFC/JFR/Jetty Creation

`ubmad_create_jfc_s()` (`ub_mad.c:301`) creates the send completion queue with
depth `UBMAD_JFS_DEPTH`, callback `ubmad_jfce_handler_s`, then rearms it.

`ubmad_create_jfc_r()` (`ub_mad.c:324`) creates the recv completion queue with
depth `UBMAD_JFR_DEPTH`, callback `ubmad_jfce_handler_r`, then rearms it.

`ubmad_create_jfr()` (`ub_mad.c:347`) creates a JFR with ID `0`, no token,
transport mode `UBCORE_TP_UM`, EID index from `dev_priv->eid_info`, one SGE,
and the recv JFC.

`ubmad_jetty_set_priority()` (`ub_mad.c:363`) queries device attributes and
chooses the first priority whose `tp_type.bs.rtp == 1`. The comment says no
priority supports UTP currently, so it uses RTP priority. If no such priority
is found, it returns `-EINVAL`; `ubmad_create_jetty()` logs and continues with
priority `0`.

`ubmad_create_jetty()` (`ub_mad.c:394`) creates the local WK jetty. It sets:

- `id = jetty_id`
- `share_jfr = 1`
- `trans_mode = UBCORE_TP_UM`
- `eid_index = dev_priv->eid_info.eid_index`
- JFS/JFR depths and SGE counts
- send JFC, recv JFC, shared JFR
- error timeout

Then it calls `ubcore_create_jetty()`.

### Remote Tjetty Cache And Import

`ubmad_get_tjetty_lockless()` (`ub_mad.c:423`) scans one hash bucket and
returns a cached `ubmad_tjetty` matching destination EID, with a kref get.

`ubmad_get_tjetty()` (`ub_mad.c:441`) wraps the lockless lookup with the
resource hash lock.

`ubmad_release_tjetty()` (`ub_mad.c:456`) frees retransmission buffers, target
hash nodes, MSN manager, calls `ubcore_unimport_jetty()`, and frees the wrapper.

`ubmad_put_tjetty()` (`ub_mad.c:496`) drops the tjetty kref.

`ubmad_fill_get_tp_cfg()` (`ub_mad.c:501`) builds the TP-list query for a WK
target import. It sets UTP flag, copies transport mode, reads local EID from
the device EID table, and sets peer EID from target jetty config.

`ubmad_import_jetty_compat()` (`ub_mad.c:530`) is the core import helper:

```text
validate TP ctrlplane support
ubmad_fill_get_tp_cfg()
ubcore_get_tp_list()
active_tp_cfg.tp_handle = tp_list.tp_handle
ubcore_import_jetty_ex()
```

`ubmad_import_jetty()` (`ub_mad.c:575`) is the cache-aware public helper used
by the datapath. It builds a target config with `id.id = rsrc->jetty_id` and
`id.eid = dst_eid`, imports the remote WK tjetty, initializes reliability
state, double-checks the cache to avoid duplicate imports, then inserts the new
wrapper into the resource hash table.

`ubmad_remove_tjetty()` (`ub_mad.c:671`) removes a cached remote tjetty for a
source EID, used when `UBMAD_CLOSE_REQ` is received.

### Segment Creation

`ubmad_register_seg()` (`ub_mad.c:695`) allocates backing memory and registers
it as a target segment with token policy `UBCORE_TOKEN_NONE`.

`ubmad_unregister_seg()` (`ub_mad.c:728`) unregisters the segment and frees
backing memory.

`ubmad_create_seg()` (`ub_mad.c:736`) creates:

- send segment with `UBMAD_SEND_SGE_NUM` slots
- send bitmap
- recv segment with `UBMAD_RECV_SGE_NUM` slots
- recv bitmap

`ubmad_destroy_seg()` (`ub_mad.c:778`) destroys those in reverse order.

### WK Resource Array

`ubmad_init_jetty_rsrc()` (`ub_mad.c:792`) creates one complete local WK
resource: send JFC, recv JFC, shared JFR, local WK jetty, segments, initial
recv WQEs, and remote tjetty hash table.

`ubmad_uninit_jetty_rsrc()` (`ub_mad.c:915`) unimports all remote tjettys and
destroys the local resource.

`ubmad_init_jetty_rsrc_array()` (`ub_mad.c:947`) creates both WK resources.
It assigns IDs from `g_ubmad_wk_jetty_id[]`, so index 0 gets ID 1 and index 1
gets ID 2.

`ubmad_uninit_jetty_rsrc_array()` (`ub_mad.c:972`) destroys both resources.

`ubmad_get_jetty_rsrc_by_jfc_s()` (`ub_mad.c:981`) maps a send JFC back to its
WK resource.

`ubmad_get_jetty_rsrc_by_jfc_r()` (`ub_mad.c:996`) maps a recv JFC back to its
WK resource.

### Device Lifecycle

`ubmad_create_device_priv_resources()` (`ub_mad.c:1013`) creates WK resources
if `dev_priv->valid` is false and the device has at least one EID. If no EID
exists, it returns success without creating resources.

`ubmad_destroy_device_priv_resources()` (`ub_mad.c:1046`) checks `valid`, marks
the object invalid, and destroys the WK resource array.

`ubmad_get_device_priv_lockless()` (`ub_mad.c:1060`) finds a device-private
object in `g_ubmad_device_list` and increments its kref.

`ubmad_get_device_priv()` (`ub_mad.c:1074`) wraps the lockless lookup with
`g_ubmad_device_list_lock`.

`ubmad_release_device_priv()` (`ub_mad.c:1086`) drains/destroys workqueues,
destroys resources, unregisters the ubcore event handler, and frees the object.

`ubmad_open_device()` (`ub_mad.c:1113`) allocates the per-device object,
registers the event handler, attempts resource creation, allocates retransmit
and connection workqueues, and inserts the object into the global device list.
Failure to create WK resources is not fatal here because EID add may occur
later.

`ubmad_rsrc_notify_close()` (`ub_mad.c:1169`) sends close notifications to all
cached remote tjettys in one local WK resource.

`ubmad_notify_close()` (`ub_mad.c:1192`) applies close notification to both WK
resources.

`ubmad_close_device()` (`ub_mad.c:1213`) removes the device-private object from
the global list and drops both the lookup kref and initial kref.

`ubmad_add_device()` (`ub_mad.c:1237`) is the ubcore client `.add` callback and
calls `ubmad_open_device()`.

`ubmad_remove_device()` (`ub_mad.c:1253`) is the ubcore client `.remove`
callback and calls notify-close then close.

`ubmad_init()` (`ub_mad.c:1272`) initializes UBMAD global lists, registers the
UBMAD ubcore client, and registers CM EID ops.

`ubmad_uninit()` (`ub_mad.c:1291`) unregisters the UBMAD client.

### Agent Lifecycle

`ubmad_get_agent_priv_lockless()` (`ub_mad.c:1297`) finds the UBMAD agent for a
device and increments its kref.

`ubmad_get_agent_priv()` (`ub_mad.c:1312`) wraps that lookup with
`g_ubmad_agent_list_lock`.

`ubmad_release_agent_priv()` (`ub_mad.c:1324`) drains/destroys send and recv
JFCE workqueues and frees the agent.

`ubmad_register_agent()` (`ub_mad.c:1342`) creates an agent for UBCM and stores
the send/recv callbacks.

`ubmad_unregister_agent()` (`ub_mad.c:1404`) removes the agent from the global
agent list and drops its initial kref.

## 17. Where `urma_perftest` Fits

`urma_perftest` does not create UBMAD's WK jetty IDs `1` and `2`. Those are
kernel UBMAD resources created per `ubcore_device`.

`urma_perftest` creates normal benchmark resources and exchanges peer metadata
over its own out-of-band socket. In the default non-TP-aware connect path:

```text
connect_jetty_default()                                     perftest_resources.c:1510
  -> rjetty.jetty_id = ctx->remote_jetty_id[i]
  -> rjetty.trans_mode = cfg->trans_mode
  -> rjetty.type = URMA_JETTY
  -> urma_import_jetty()                                    perftest_resources.c:1540
  -> if RC:
       -> urma_bind_jetty()                                 perftest_resources.c:1547
```

In the TP-aware path:

```text
query_tp_info() or equivalent setup
  -> urma_get_tp_list()                                     perftest_resources.c:1060

connect_jetty_tp_aware()
  -> build active_cfg from local/remote TP info
  -> urma_import_jetty_ex()                                 perftest_resources.c:1608
  -> if RC:
       -> urma_bind_jetty_ex()                              perftest_resources.c:1615
```

How it relates to WK jetty:

- The benchmark app itself does not call `ubmad_create_jetty()`.
- If a userspace import/bind path needs kernel control-plane TP exchange, that
  exchange can enter `ubcore_exchange_tp_info()`, which uses UBCM over WK jetty
  as described above.
- The steady-state benchmark loop posts work to its normal benchmark JFS/jetty
  and polls/mmap-completion paths. It does not send each benchmark message
  through UBMAD WK jetty.

## 18. Key Invariants And Pitfalls

- WK resource index and WK jetty ID are different. `jetty_rsrc[0]` is ID `1`;
  `jetty_rsrc[1]` is ID `2`.
- UBMAD ID `1` is the link setup path for `CONN_REQ`, `CONN_RESP`, and
  `SINGLE_REQ`.
- UBMAD ID `2` is selected for `UBMAD_AUTHN_DATA`.
- `ubcore_call_cm_send_ops()` only dispatches to `g_send`; it does not create
  WK resources.
- `ubmad_event_cb()` is not the real EID-create path. Real resource creation on
  EID add is through `ubmad_ubc_eid_ops()`.
- `ubmad_ubc_eid_ops()` ignores non-main-primary EIDs.
- `ubmad_post_send()` fails if `dev_priv->valid` is false. In that state, no
  local WK jetty resources exist yet.
- First send to a remote EID may queue work because UBMAD must import the
  remote WK target jetty first.
- Remote WK tjetty import sets `tjetty_cfg.id.id = rsrc->jetty_id`, so both
  sides agree on the target ID without exchanging it.
- WK tjetty import uses `ubcore_get_tp_list()` and `ubcore_import_jetty_ex()`;
  well-known jetty removes ID bootstrap, not every control-plane cost.
- `ubmad_cm_process_msg()` normalizes the outward UBMAD recv type to
  `UBMAD_UBC_CONN_REQ`; the actual net message type is inside the payload.
- `UBMAD_CLOSE_REQ` has a dedicated close-notification path and is not selected
  in the normal `ubmad_post_send()` switch.

## 19. Condensed End-To-End Call Graph

Creation:

```text
ubcore_init
  -> ubcm_init
     -> ubmad_init
        -> ubcore_register_client(g_ubmad_client)
           -> ubmad_add_device
              -> ubmad_open_device
                 -> ubmad_create_device_priv_resources
                    -> ubmad_init_jetty_rsrc_array
                       -> [ID 1] ubmad_init_jetty_rsrc
                          -> create send JFC
                          -> create recv JFC
                          -> create JFR
                          -> create WK jetty
                          -> create send/recv segments
                          -> prepost recv WQEs
                       -> [ID 2] same
     -> ubcm_base_init
        -> ubcore_register_client(g_ubcm_client)
           -> ubcm_add_device
              -> ubmad_register_agent(ubcm_send_handler,
                                      ubcm_recv_handler)
     -> ubcore_register_cm_send_ops(ubmad_ubc_send)
```

Create request send:

```text
ubcore_exchange_tp_info
  -> send_create_req
     -> ubcore_net_send_to
        -> ubcore_ubcm_send_to
           -> ubcore_call_cm_send_ops
              -> ubmad_ubc_send
                 -> ubmad_post_send
                    -> select jetty_rsrc[0] / ID 1
                    -> lookup/import remote WK tjetty
                    -> ubmad_do_post_send
                       -> ubmad_do_post_send_conn_data
                          -> ubcore_post_jetty_send_wr
```

Create request receive:

```text
recv completion on peer WK ID 1
  -> ubmad_jfce_handler_r
     -> ubmad_jfce_work_handler
        -> ubmad_recv_work_handler
           -> ubmad_process_msg
              -> ubmad_process_conn_data
                 -> duplicate-response repost check
                 -> ubmad_cm_process_msg
                    -> ubcm_recv_handler
                       -> ubcore_cm_recv
                          -> ubcore_net_handle_msg
                             -> handle_create_req
                                -> ubcore_get_tp_list
                                -> ubcore_active_tp
                                -> send_create_resp
```

Create response send:

```text
send_create_resp
  -> ubcore_net_send
     -> ubcore_ubcm_send
        -> ubcore_ubcm_send_to
           -> ubcore_call_cm_send_ops
              -> ubmad_ubc_send
                 -> ubmad_post_send
                    -> select jetty_rsrc[0] / ID 1
                    -> ubmad_do_post_send
                       -> ubmad_do_post_send_conn_resp_data
                          -> ubcore_post_jetty_send_wr
                          -> cache response for duplicate req replay
```

Create response receive:

```text
recv completion on initiator WK ID 1
  -> ubmad_jfce_handler_r
     -> ubmad_recv_work_handler
        -> ubmad_process_msg
           -> ubmad_process_conn_resp
              -> remove msn_node
              -> ubmad_cm_process_msg
                 -> ubcm_recv_handler
                    -> ubcore_cm_recv
                       -> ubcore_net_handle_msg
                          -> handle_create_resp
                             -> fill session_data
                             -> ubcore_session_complete
  -> ubcore_exchange_tp_info resumes
     -> copy peer_tp_handle and rx_psn to active_tp_cfg
```

