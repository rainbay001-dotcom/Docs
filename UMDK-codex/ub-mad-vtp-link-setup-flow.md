# UB MAD VTP Link Setup Flow

This note checks the proposed Node A / Node B link setup flow against the local
OLK-6.6 UB/URMA kernel tree and the local UMDK tree under `/Volumes/KernelDev`.
The flow is directionally correct for the UB MAD exchange and the UDMA data-path
send/receive mechanics, but several function nesting details differ from the
code in this branch.

## Short Verdict

The high-level shape is correct:

- Node A needs a local TP descriptor before it can create the control-plane VTP.
- Node A sends a create request to Node B as a UB MAD over the well-known MAD
  Jetty.
- The MAD itself is posted through the normal Jetty send data path, eventually
  becoming a UDMA send WQE.
- Node B receives the MAD through an RX JFC completion, handles the create
  request, obtains and activates its own TP, and sends a create response MAD.
- Node A receives the response, learns the peer TP handle and peer PSN, then
  activates its own TP through the UDMA control queue.

Important corrections for this local tree:

- `UBURMA_CMD_ADVISE_JETTY` is not the active implemented handler path for this
  link setup. The kernel command dispatcher registers `BIND_JETTY`,
  `BIND_JETTY_EX`, `IMPORT_JETTY_EX`, and `IMPORT_JFR_EX`, but not
  `ADVISE_JETTY`. UMDK also returns success immediately for
  `urma_advise_jetty()` on UB transport.
- `ubcore_connect_vtp_ctrlplane()` does not call `ubcore_get_tp_list()` and does
  not build or send the MAD. In the compat bind/import paths, `ubcore_get_tp_list()`
  and `ubcore_exchange_tp_info()` happen before `ubcore_bind_jetty_ex()` or
  `ubcore_import_jetty_ex()` reaches VTP connection.
- The observed registered send path is `ubcore_ubcm_send_to()` ->
  `ubmad_ubc_send()` -> `ubmad_post_send()`. `ubcm_work_handler()` exists, but
  it is not the main registered send operation in this branch.
- A received `UBMAD_UBC_CONN_RESP` is first dispatched by `ubmad_process_msg()`
  to `ubmad_process_conn_resp()`. By the time it reaches `ubcm_recv_handler()`,
  the receive is normalized as `UBMAD_UBC_CONN_REQ`, and the inner net payload
  type `UBCORE_NET_CREATE_RESP` dispatches to `handle_create_resp()`.

## Corrected Sequence

The sequence below keeps the same two host-kernel lanes as the original sketch,
but uses the call ordering seen in the local source.

```text
NODE A - HOST KERNEL / UMDK                     NODE B - HOST KERNEL
==========================                      ====================

userspace urma_bind_jetty()
  -> UDMA provider bind_jetty_ex
  -> ioctl(UBURMA_CMD_BIND_JETTY_EX)
  -> uburma_cmd_bind_jetty_ex
       |
       | if active_tp_cfg is empty, compat path is used:
       v
  ubcore_bind_jetty_compat
    -> ubcore_fill_get_tp_cfg
    -> ubcore_get_tp_list                         [instrumented]
         -> dev->ops->get_tp_list
         -> udma_get_tp_list / tp-cache path
    -> ubcore_exchange_tp_info
         -> send_create_req
         -> ubcore_net_send / ubcore_ubcm_send_to
         -> ubmad_ubc_send
         -> ubmad_post_send
         -> ubcore_post_jetty_send_wr
         -> udma_post_jetty_send_wr
         -> udma_post_sq_wr
         -> udma_post_one_wr
              -> SEND WQE on MAD Jetty SQ
                    |
                    | create request MAD over UB fabric
                    v
                                                   CQE on RX JFC
                                                   -> ubmad_jfce_handler_r
                                                   -> ubmad_recv_work_handler
                                                   -> ubcore_poll_jfc
                                                   -> udma_poll_jfc
                                                   -> ubmad_process_msg
                                                   -> ubmad_process_conn_data
                                                   -> ubcore_cm_recv
                                                   -> ubcore_net_handle_msg
                                                   -> handle_create_req
                                                        -> invert local/peer EIDs
                                                        -> ubcore_get_tp_list
                                                           [instrumented]
                                                        -> ubcore_active_tp
                                                           [instrumented]
                                                        -> send_create_resp
                                                        -> ubmad_post_send
                                                        -> udma_post_one_wr
                                                            SEND WQE
                    ^
                    | create response MAD over UB fabric
                    |
              CQE on RX JFC
         -> ubmad_jfce_handler_r
         -> ubmad_recv_work_handler
         -> ubmad_process_msg
         -> ubmad_process_conn_resp
         -> ubcore_cm_recv
         -> ubcore_net_handle_msg
         -> handle_create_resp
              -> fill peer_tp_handle and rx_psn
              -> ubcore_session_complete
    -> ubcore_exchange_tp_info returns
    -> ubcore_bind_jetty_ex
         -> ubcore_inner_bind_jetty_ctrlplane
         -> ubcore_connect_rc_vtp_ctrlplane
            or ubcore_connect_vtp_ctrlplane
              -> find/reuse VTPN cache entry
              -> allocate and insert VTPN on miss
              -> ubcore_active_tp                    [instrumented]
                   -> dev->ops->active_tp
                   -> udma_active_tp
                   -> udma_ctrlq_set_active_tp_ex
                   -> udma_k_ctrlq_create_active_tp_msg
                   -> ubase_ctrlq_send_msg
                   -> wait_for_completion_timeout
                        firmware/MUE programs Node A TP context
```

For the receive path on Node B, the same call chain is used in reverse when the
response MAD returns to Node A. The connection response is not processed as a
separate `case UBMAD_UBC_CONN_RESP` inside `ubcm_recv_handler()`. The
`UBMAD_UBC_CONN_RESP` branch is in `ubmad_process_msg()`, and the inner
`UBCORE_NET_CREATE_RESP` message is what completes the waiting session.

## Stage Details

### 1. Userspace Entry

For the current UDMA provider path, the practical entry is bind/import, not
advise.

`urma_bind_jetty()` in UMDK checks the provider ops. If the legacy
`bind_jetty` op is not available, it calls the compat helper, which invokes
`ops->bind_jetty_ex()` with an empty active TP config. The UDMA provider exports
`bind_jetty_ex`, so userspace reaches `urma_cmd_bind_jetty_ex()` and then the
kernel `UBURMA_CMD_BIND_JETTY_EX` handler.

`urma_advise_jetty()` is not a real setup path for UB transport in this local
UMDK tree. If the device type is `URMA_TRANSPORT_UB`, it returns success without
issuing the advise ioctl. On the kernel side, the command enum and TLV
description for `UBURMA_CMD_ADVISE_JETTY` exist, but the command handler array
does not register an advise handler. That makes the supplied
`ioctl(UBURMA_CMD_ADVISE_JETTY) -> ubcore_advise_jetty` prefix inaccurate for
this branch.

### 2. Node A Local TP Allocation

In the compat bind path, `ubcore_bind_jetty_compat()` builds a
`ubcore_get_tp_cfg`, then calls:

```text
ubcore_get_tp_list(dev, &get_tp_cfg, &tp_cnt, &tp_list, NULL)
```

This is the first expensive point in a cold setup. `ubcore_get_tp_list()` is a
thin wrapper around the provider operation `dev->ops->get_tp_list`. In UDMA that
ultimately reaches the driver TP-list allocation path. In the branch that has the
tp-cache patch, the provider path can consult `udma_tp_cache_get_or_fetch()`;
without that patch, it goes to the original control-queue fetch path.

The resulting TP handle becomes `active_tp_cfg.tp_handle`. Node A also generates
its local transmit PSN before starting the peer exchange.

### 3. Node A Create Request MAD

For RTP mode, the compat path calls `ubcore_exchange_tp_info()`. This allocates
a session, sends a create request, waits for the response, and fills the peer TP
handle and receive PSN into `active_tp_cfg`.

The request enters the UB connection manager through the net layer:

```text
send_create_req
  -> ubcore_net_send
  -> ubcore_ubcm_send_to
  -> ubcore_call_cm_send_ops
  -> ubmad_ubc_send
```

`ubcm_init()` registers `ubmad_ubc_send` as the CM send operation. The separate
`ubcm_work_handler()` can post a MAD too, but it is not the registered fast path
seen for this exchange in the local tree.

### 4. MAD Transmit Uses the Normal Jetty Data Path

`ubmad_ubc_send()` fills the source EID and calls `ubmad_post_send()`.
`ubmad_post_send()` selects the well-known MAD Jetty resource. For connection
request and connection response MADs, it uses `dev_priv->jetty_rsrc[0]`.

The actual post path is:

```text
ubmad_post_send
  -> ubmad_do_post_send
  -> ubmad_do_post_send_conn_data
     or ubmad_do_post_send_conn_resp_data
  -> ubcore_post_jetty_send_wr
  -> dev_ops->post_jetty_send_wr
  -> udma_post_jetty_send_wr
  -> udma_post_sq_wr
  -> udma_post_one_wr
```

This confirms the important observation in the supplied flow: UB MADs are
control-plane messages, but they are carried by the normal UDMA Jetty send data
path. The driver fills a send WQE on the MAD Jetty SQ and rings the queue
doorbell.

### 5. Node B MAD Receive

On Node B, hardware writes a completion on the receive JFC for the MAD Jetty.
The registered receive JFCE handler is:

```text
ubmad_jfce_handler_r
  -> ubmad_jfce_handler(..., UBMAD_RECV_WORK)
  -> queue_work(agent_priv->jfce_wq_r, ...)
  -> ubmad_jfce_work_handler
  -> ubmad_recv_work_handler
```

`ubmad_recv_work_handler()` polls the JFC:

```text
ubcore_poll_jfc
  -> dev_ops->poll_jfc
  -> udma_poll_jfc
```

For a successful completion, it calls `ubmad_process_msg()`. That function
checks the outer `struct ubmad_msg` type:

```text
UBMAD_UBC_CONN_REQ  -> ubmad_process_conn_data
UBMAD_UBC_CONN_RESP -> ubmad_process_conn_resp
UBMAD_UBC_SINGLE_REQ -> ubmad_process_conn_single
```

After the outer MAD handling, the message is delivered to the UB connection
manager and then to the ubcore net message dispatcher. For a create request, the
inner ubcore net message type is `UBCORE_NET_CREATE_REQ`, so
`handle_create_req()` runs.

### 6. Node B Creates and Activates Its TP

`handle_create_req()` is the peer-side core of the flow. It takes the request's
TP config and swaps the EIDs:

```text
get_tp_cfg.local_eid = req->get_tp_cfg.peer_eid
get_tp_cfg.peer_eid  = req->get_tp_cfg.local_eid
```

Then it either gets a shared RM STP list or calls:

```text
ubcore_get_tp_list(dev, &get_tp_cfg, &tp_cnt, &tp_info, NULL)
```

This is the second major cold-path TP-list allocation point. It happens on the
peer node while handling Node A's create request.

After a TP is obtained, Node B builds `active_cfg`:

- `tp_handle` is Node B's local TP handle.
- `peer_tp_handle` is the TP handle sent by Node A.
- `rx_psn` is Node A's transmit PSN.
- `tx_psn` is Node B's newly generated transmit PSN.

Then Node B calls `ubcore_active_tp()`. In the connect-adapter path this wrapper
calls `dev->ops->active_tp`, which is UDMA's `udma_active_tp()`.

After successful activation, Node B sends a create response containing:

- Node B's TP handle.
- Node B's transmit PSN.
- The create result code.

### 7. Node A Receives the Create Response

The response returns through the same UDMA receive mechanics:

```text
RX JFC CQE
  -> ubmad_jfce_handler_r
  -> ubmad_recv_work_handler
  -> ubcore_poll_jfc
  -> udma_poll_jfc
  -> ubmad_process_msg
```

At the outer MAD layer, the response is `UBMAD_UBC_CONN_RESP`, so
`ubmad_process_msg()` calls `ubmad_process_conn_resp()`. After normalization and
delivery into ubcore net, the inner net message type is
`UBCORE_NET_CREATE_RESP`, so `handle_create_resp()` runs.

`handle_create_resp()` finds the waiting session, writes the peer-side values
into the session data, and calls `ubcore_session_complete()`. That wakes the
initiator side of `ubcore_exchange_tp_info()`. The function then copies
`peer_tp_handle` and `rx_psn` into Node A's `active_tp_cfg`.

This is the point represented by the original sketch's "complete unblocks wait"
line. The exact completion here is the ubcore exchange session completion. It is
separate from the later UBASE control-queue completion used when firmware
finishes active-TP programming.

### 8. Node A VTP Creation and Active TP

After exchange succeeds, the compat bind path calls `ubcore_bind_jetty_ex()`.
For the control-plane VTP path, ubcore eventually calls
`ubcore_connect_vtp_ctrlplane()` or the RC-specific wrapper.

`ubcore_connect_vtp_ctrlplane()` does this:

```text
find existing control-plane VTPN by TP handle
if found:
  reuse it
else:
  allocate a VTPN
  insert it into UBCORE_HT_CP_VTPN
  call ubcore_active_tp()
  mark VTPN ready
```

This explains why placing `ubcore_get_tp_list()` under
`ubcore_connect_vtp_ctrlplane()` is misleading. By this point the TP handle,
peer TP handle, transmit PSN, and receive PSN are already known. The VTP layer is
using those values to activate and cache the control-plane VTPN.

### 9. UDMA Active TP and Control Queue Wait

On the UDMA provider, active TP goes through:

```text
ubcore_active_tp
  -> dev->ops->active_tp
  -> udma_active_tp
  -> udma_ctrlq_set_active_tp_ex
  -> udma_k_ctrlq_create_active_tp_msg
  -> ubase_ctrlq_send_msg
  -> wait_for_completion_timeout
```

`udma_k_ctrlq_create_active_tp_msg()` builds a
`UDMA_CMD_CTRLQ_ACTIVE_TP` command. The command includes the local TP id/count,
local PSN, remote TP id/count, and remote PSN. `ubase_ctrlq_send_msg()` submits
that command to the device/MUE control queue and waits for completion.

Node B performs the equivalent active-TP programming while handling the create
request. Node A performs it after the create response is received.

## Where Timing Should Be Added

The supplied flow marks two useful instrumentation points. They are valid, but
they measure different parts of the setup.

### `ubcore_get_tp_list()`

`ubcore_get_tp_list()` is called on both nodes:

- Node A calls it before sending the create request.
- Node B calls it while handling the create request.

Timing this function measures local TP-list allocation/fetch cost. This is the
path targeted by the TP-cache mitigation. In the unpatched original code, this
cost can include a synchronous device or firmware control-queue round trip.

### `ubcore_active_tp()`

`ubcore_active_tp()` is also called on both nodes:

- Node B calls it before sending the create response.
- Node A calls it after the create response gives it Node B's TP handle and PSN.

Timing this function measures provider active-TP programming cost. For UDMA, the
slow part is usually the control-queue command that programs the TP context and
waits for completion.

### MAD Send and Receive Path

If the total link setup time is still long after TP-list mitigation, useful
additional timestamps are:

- Around `ubcore_exchange_tp_info()` on Node A, to measure request/response
  round-trip time.
- Around `ubmad_post_send()` or `ubmad_ubc_send()`, to measure local MAD submit
  overhead.
- Around `ubmad_recv_work_handler()`, to measure receive workqueue and poll
  latency.
- Around `ubase_ctrlq_send_msg()` or `ubase_ctrlq_wait_completed()`, to measure
  firmware/device control-queue latency separately from ubcore wrapper time.

## Why First Link Setup Can Be Long

The first connection between a client node and a master node can pay several
cold costs in series:

1. Node A fetches or allocates its TP list.
2. Node A sends a create request MAD over the MAD Jetty data path.
3. Node B receives the MAD through a JFC event and receive workqueue.
4. Node B fetches or allocates its TP list.
5. Node B programs its local TP context with active TP.
6. Node B sends a create response MAD.
7. Node A receives the response and wakes the waiting exchange session.
8. Node A creates or reuses a control-plane VTPN.
9. Node A programs its local TP context with active TP.

The TP-cache mitigation primarily reduces steps 1 and 4 after a matching entry
has been warmed or cached. It does not remove the MAD RTT, receive workqueue
latency, or active-TP firmware programming time.

## Source Map

Local sources checked:

| Area | Source |
| --- | --- |
| UMDK bind compat | `/Volumes/KernelDev/umdk/src/urma/lib/urma/core/urma_cp_api.c` |
| UDMA userspace ops | `/Volumes/KernelDev/umdk/src/urma/hw/udma/udma_u_ops.c` |
| uburma command handlers | `/Volumes/KernelDev/kernel/drivers/ub/urma/uburma/uburma_cmd.c` |
| TP list wrapper | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_tp.c` |
| Bind/import compat and TP exchange | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c` |
| VTPN creation and active TP wrapper | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_vtp.c` |
| Jetty bind path | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c` |
| UB CM agent | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/ub_cm.c` |
| UB CM net send | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/net/ubcore_cm.c` |
| UB MAD data path | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c` |
| UDMA Jetty send | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_jetty.c` |
| UDMA SQ WQE post | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_jfs.c` |
| UDMA active TP ctrlq | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` |
| UBASE ctrlq wait | `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c` |

## Practical Takeaways

- Treat the original graph as a good conceptual picture of the two-node MAD
  exchange, not as exact stack nesting.
- For this branch, start tracing from `bind_jetty_ex` or the import-EX compat
  paths, not from `advise_jetty`.
- Measure `ubcore_get_tp_list()` on both nodes to confirm whether TP-list fetch
  is still the dominant first-link delay.
- Also measure `ubcore_exchange_tp_info()` and UDMA active TP if link setup is
  slow even when TP-list fetch is cached.
- If the tp-cache mitigation is applied, it can reduce repeated or warmed
  `get_tp_list` latency, but the first uncached MAD exchange and both active-TP
  control-queue waits remain part of the critical path.
