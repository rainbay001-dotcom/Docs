# URMA TP Type Comparison and Call Chains

This note compares `RTP`, `CTP`, and `UTP` in the local URMA/UDMA stack and
shows how their kernel call chains differ. The analysis is based on the local
OLK-6.6 kernel checkout under `/Volumes/KernelDev/kernel` and UMDK under
`/Volumes/KernelDev/umdk`.

## 1. Two Different Axes

URMA uses two related but separate fields:

```c
typedef enum urma_tp_type {
    URMA_RTP,
    URMA_CTP,
    URMA_UTP
} urma_tp_type_t;
```

Kernel mirror:

```c
enum ubcore_tp_type { UBCORE_RTP, UBCORE_CTP, UBCORE_UTP };
```

These are TP types. Separately, URMA has transport modes:

```c
URMA_TM_RM  /* Reliable message */
URMA_TM_RC  /* Reliable connection */
URMA_TM_UM  /* Unreliable message */
```

Kernel mirror:

```c
UBCORE_TP_RM  /* Reliable message */
UBCORE_TP_RC  /* Reliable connection */
UBCORE_TP_UM  /* Unreliable message */
```

So do not read `RTP`, `CTP`, and `UTP` as a replacement for `RM`, `RC`, and
`UM`. A connection/import request carries both:

```text
tp_type    = RTP / CTP / UTP
trans_mode = RM / RC / UM
```

The normal practical combinations in this tree are:

| Combination | Meaning |
| --- | --- |
| `RC + RTP` | Reliable, bound, connection-style Jetty pair |
| `RM + RTP` | Reliable message mode with per-peer TP state |
| `RM + CTP` | Compact/lower-state reliable or lower-layer-assisted message mode |
| `UM + UTP` | Unreliable message/datagram-like mode |

The UMDK parameter check explicitly rejects `UTP` unless the transport mode is
`UM`, and rejects `RTP` with `UM`. `CTP` is usually paired with `RM`; UDMA's
control-queue preparation treats the `ctp` flag as a special transport type that
overrides the regular `RM/RC/UM` mapping.

## 2. Semantic Comparison

| Item | RTP | CTP | UTP |
| --- | --- | --- | --- |
| Name | Reliable Transport Path | Compact Transport Path | Unreliable Transport Path |
| Reliability | Full reliable transport semantics | Compact/lower-state reliable semantics, often relying more on lower layers | Best effort |
| Typical mode | `RC` or `RM` | `RM` | `UM` |
| Peer state | Per peer or per TP pair | Shared/compact across peers | Minimal |
| Peer TP exchange | Yes in the compat RTP paths | No in the local compat import paths | No |
| Peer-side `handle_create_req()` | Yes, for RTP exchange | No | No |
| UDMA get-TP-list control type | Derived from `RM` or `RC` transport mode | Forced to `UDMA_CTRLQ_TRANS_TYPE_CTP` | Derived from `UM` transport mode |
| Best fit | Strong reliability, normal connection setup, smaller peer count | Many peers where per-peer RTP state is too expensive | Loss-tolerant or setup/control-style traffic |

The biggest code-level difference is this:

```text
RTP:
  get local TP
  exchange TP info with peer over UB MAD
  peer also gets and activates a TP
  local side receives peer TP handle and PSN
  local side activates its TP

CTP / UTP:
  get local TP
  skip ubcore_exchange_tp_info()
  connect/activate local VTP with the TP info returned by get_tp_list()
```

## 3. Common Configuration Path

The common kernel helper is `ubcore_fill_get_tp_cfg()` in
`ubcore_connect_adapter.c`.

It maps `tp_type` into a TP-list request flag:

```text
UBCORE_CTP -> get_tp_cfg.flag.bs.ctp = 1
UBCORE_RTP -> get_tp_cfg.flag.bs.rtp = 1
UBCORE_UTP -> get_tp_cfg.flag.bs.utp = 1
```

It also copies:

```text
get_tp_cfg.trans_mode = cfg->trans_mode
get_tp_cfg.local_eid  = local EID from cfg->eid_index
get_tp_cfg.peer_eid   = cfg->id.eid
```

After that, all three TP types eventually call:

```text
ubcore_get_tp_list
  -> dev->ops->get_tp_list
  -> udma_get_tp_list
  -> udma_tp_cache_get_or_fetch
  -> udma_ctrlq_prepare_get_tp_list_req
  -> udma_ctrlq_fetch_tpid_list on cache miss
  -> ubase_ctrlq_send_msg(UDMA_CMD_CTRLQ_GET_TP_LIST)
```

The UDMA request preparation is where CTP becomes special:

```text
if ctp flag is set:
  trans_type = UDMA_CTRLQ_TRANS_TYPE_CTP
else:
  trans_type = map(link_mode, trans_mode)
```

So:

```text
RTP + RM -> UDMA_CTRLQ_TRANS_TYPE_TP_RM
RTP + RC -> UDMA_CTRLQ_TRANS_TYPE_TP_RC
UTP + UM -> UDMA_CTRLQ_TRANS_TYPE_TP_UM
CTP      -> UDMA_CTRLQ_TRANS_TYPE_CTP
```

For UBOE link mode, the non-CTP cases map to `UBOE_RM`, `UBOE_RC`, or
`UBOE_UM`.

## 4. RTP Call Chains

RTP is the only TP type in these compat paths that performs a two-sided TP
handle exchange with the peer. That exchange is the extra control-plane work
that makes the RTP chain visibly longer.

### 4.1 RM + RTP Import Chain

This is the message-mode path used when importing a remote JFR or remote Jetty.

```text
userspace import_jfr/import_jetty
  -> ioctl(UBURMA_CMD_IMPORT_JFR[_EX])
     or ioctl(UBURMA_CMD_IMPORT_JETTY_EX)
  -> uburma_cmd_import_jfr_ex / uburma_cmd_import_jetty_ex
  -> ubcore_import_jfr / ubcore_import_jetty
  -> ubcore_import_jfr_compat / ubcore_import_jetty_compat
  -> ubcore_fill_get_tp_cfg
       sets flag.bs.rtp = 1
       sets trans_mode = UBCORE_TP_RM
       fills local_eid and peer_eid
  -> ubcore_get_tp_list
       or ubcore_get_rm_stp_list if RM + RTP + share_tp
  -> active_tp_cfg.tp_handle = returned local TP handle
  -> active_tp_cfg.tp_attr.tx_psn = generated or shared tx_psn
  -> ubcore_exchange_tp_info
       -> send_create_req
       -> ubcore_net_send / ubcore_ubcm_send_to
       -> ubmad_ubc_send
       -> ubmad_post_send
       -> ubcore_post_jetty_send_wr
       -> udma_post_jetty_send_wr
       -> udma_post_sq_wr
       -> udma_post_one_wr
       -> create request MAD over UB fabric
```

Peer-side handling:

```text
peer RX JFC completion
  -> ubmad_jfce_handler_r
  -> ubmad_recv_work_handler
  -> ubcore_poll_jfc
  -> udma_poll_jfc
  -> ubmad_process_msg
  -> ubmad_process_conn_data
  -> ubcore_cm_recv
  -> ubcore_net_handle_msg
  -> handle_create_req
       swaps local_eid and peer_eid
       -> ubcore_get_tp_list
          or ubcore_get_rm_stp_list for shared RM RTP
       -> ubcore_active_tp
          or ubcore_active_rm_share_tp
       -> send_create_resp
       -> response MAD over UB fabric
```

Initiator response handling:

```text
response RX JFC completion
  -> ubmad_recv_work_handler
  -> ubmad_process_msg
  -> ubmad_process_conn_resp
  -> ubcore_cm_recv
  -> ubcore_net_handle_msg
  -> handle_create_resp
       fills peer_tp_handle
       fills rx_psn
       ubcore_session_complete
  -> ubcore_exchange_tp_info returns
```

Then the local import continues:

```text
ubcore_import_jfr_ex / ubcore_import_jetty_ex
  -> dev->ops->import_jfr_ex / dev->ops->import_jetty_ex
  -> ubcore_set_vtp_param
  -> if RM + RTP + share_tp:
       ubcore_connect_rm_svrtp_ctrlplane
     else:
       ubcore_connect_vtp_ctrlplane
  -> ubcore_active_tp
  -> dev->ops->active_tp
  -> udma_active_tp
  -> udma_ctrlq_set_active_tp_ex
  -> udma_k_ctrlq_create_active_tp_msg
  -> ubase_ctrlq_send_msg(UDMA_CMD_CTRLQ_ACTIVE_TP)
```

### 4.2 RC + RTP Bind Chain

RC bind is Jetty-to-target-Jetty connection setup. In practical UDMA usage this
is an RTP path.

```text
userspace bind_jetty / bind_jetty_ex
  -> ioctl(UBURMA_CMD_BIND_JETTY_EX)
  -> uburma_cmd_bind_jetty_ex
  -> if active_tp_cfg is empty:
       ubcore_bind_jetty
       -> ubcore_inner_bind_ub_jetty
       -> ubcore_bind_jetty_compat
     else:
       ubcore_bind_jetty_ex
```

The empty-config compat chain does the TP allocation and peer exchange:

```text
ubcore_bind_jetty_compat
  -> ubcore_fill_get_tp_cfg
       sets flag.bs.rtp = 1
       sets trans_mode = UBCORE_TP_RC
  -> ubcore_get_tp_list
  -> active_tp_cfg.tp_handle = returned local TP handle
  -> active_tp_cfg.tp_attr.tx_psn = generated tx_psn
  -> if tjetty->cfg.tp_type == UBCORE_RTP:
       ubcore_exchange_tp_info
         -> same create request / peer handle_create_req / response chain
  -> ubcore_bind_jetty_ex
  -> dev->ops->bind_jetty_ex
  -> ubcore_connect_rc_vtp_ctrlplane
  -> ubcore_active_tp
  -> udma_active_tp
  -> ubase_ctrlq_send_msg(UDMA_CMD_CTRLQ_ACTIVE_TP)
```

The important RTP-only cost is:

```text
local get_tp_list
  + create request MAD
  + peer get_tp_list
  + peer active_tp
  + create response MAD
  + local active_tp
```

That is why RTP setup is the most expensive of the three TP types on a cold
path.

## 5. CTP Call Chain

CTP uses the same import framework but skips the RTP peer TP exchange. It is
typically used as `RM + CTP`.

Example consumer:

```text
ipourma_build_tjetty_cfg
  -> if ctp_en:
       tp_type = UBCORE_CTP
       trans_mode = UBCORE_TP_RM
```

Import chain:

```text
userspace or kernel import_jetty/import_jfr
  -> uburma_cmd_import_jetty_ex / uburma_cmd_import_jfr_ex
  -> ubcore_import_jetty / ubcore_import_jfr
  -> ubcore_import_jetty_compat / ubcore_import_jfr_compat
  -> ubcore_fill_get_tp_cfg
       sets flag.bs.ctp = 1
       usually sets trans_mode = UBCORE_TP_RM
       fills local_eid and peer_eid
  -> ubcore_get_tp_list
  -> active_tp_cfg.tp_handle = returned local CTP handle
```

Then CTP diverges from RTP:

```text
if cfg is CTP:
  skip ubcore_exchange_tp_info
```

There is no create request MAD, no peer `handle_create_req()`, and no peer TP
handle/PSN returned through `handle_create_resp()` in this compat path.

The chain continues locally:

```text
ubcore_import_jetty_ex / ubcore_import_jfr_ex
  -> dev->ops->import_jetty_ex / dev->ops->import_jfr_ex
  -> ubcore_set_vtp_param
  -> ubcore_connect_vtp_ctrlplane
       -> find/reuse VTPN by TP handle
       -> allocate VTPN on miss
       -> ubcore_active_tp
  -> udma_active_tp
  -> udma_ctrlq_set_active_tp_ex
  -> ubase_ctrlq_send_msg(UDMA_CMD_CTRLQ_ACTIVE_TP)
```

UDMA-specific get-TP-list request:

```text
udma_ctrlq_prepare_get_tp_list_req
  -> sees flag.bs.ctp
  -> sets trans_type = UDMA_CTRLQ_TRANS_TYPE_CTP
  -> does not use the normal RM/RC/UM trans_mode map
```

The practical result:

- CTP still calls `get_tp_list()`.
- CTP still creates/connects a VTPN and activates a TP locally.
- CTP avoids the RTP peer exchange path.
- CTP is designed to reduce per-peer TP state pressure compared with RTP.

This is why CTP is attractive for many-peer patterns such as IPoURMA or cluster
health/control traffic.

## 6. UTP Call Chain

UTP is the unreliable message path. In practical usage it is paired with
`UM + UTP`.

Example consumer:

```text
ipourma_build_tjetty_cfg
  -> if ctp_en is false:
       tp_type = UBCORE_UTP
       trans_mode = UBCORE_TP_UM
```

Import chain:

```text
userspace or kernel import_jetty/import_jfr
  -> uburma_cmd_import_jetty_ex / uburma_cmd_import_jfr_ex
  -> ubcore_import_jetty / ubcore_import_jfr
  -> ubcore_import_jetty_compat / ubcore_import_jfr_compat
  -> ubcore_fill_get_tp_cfg
       sets flag.bs.utp = 1
       sets trans_mode = UBCORE_TP_UM
       fills local_eid and peer_eid
  -> ubcore_get_tp_list
  -> active_tp_cfg.tp_handle = returned local UTP/UM TP handle
```

Then UTP also skips RTP peer exchange:

```text
if cfg is UTP:
  skip ubcore_exchange_tp_info
```

The local connect/active chain is:

```text
ubcore_import_jetty_ex / ubcore_import_jfr_ex
  -> dev->ops->import_jetty_ex / dev->ops->import_jfr_ex
  -> ubcore_set_vtp_param
  -> ubcore_connect_vtp_ctrlplane
  -> ubcore_active_tp
  -> udma_active_tp
  -> ubase_ctrlq_send_msg(UDMA_CMD_CTRLQ_ACTIVE_TP)
```

UDMA-specific get-TP-list request:

```text
udma_ctrlq_prepare_get_tp_list_req
  -> flag.bs.ctp is false
  -> maps trans_mode UBCORE_TP_UM
  -> trans_type = UDMA_CTRLQ_TRANS_TYPE_TP_UM
     or UDMA_CTRLQ_TRANS_TYPE_UBOE_UM for UBOE
```

The practical result:

- UTP still calls `get_tp_list()`.
- UTP still has a local VTPN/active-TP flow.
- UTP avoids all RTP peer TP exchange work.
- UTP does not provide RTP-style reliable transport. Loss handling, if needed,
  must happen above this layer or be accepted by the workload.

## 7. Side-by-Side Function Chain

### Importing a Remote Target in RM/UM Mode

| Stage | RTP | CTP | UTP |
| --- | --- | --- | --- |
| Fill request | `flag.bs.rtp = 1` | `flag.bs.ctp = 1` | `flag.bs.utp = 1` |
| Transport mode | `RM` for message mode | Usually `RM` | `UM` |
| TP-list call | `ubcore_get_tp_list`, or `ubcore_get_rm_stp_list` if shared RM RTP | `ubcore_get_tp_list` | `ubcore_get_tp_list` |
| UDMA control type | `TP_RM` | `CTP` | `TP_UM` |
| Peer exchange | `ubcore_exchange_tp_info()` | skipped | skipped |
| Peer handler | `handle_create_req()` | not used in this path | not used in this path |
| Peer active TP during exchange | yes | no | no |
| Local VTP connect | `ubcore_connect_vtp_ctrlplane()` or `ubcore_connect_rm_svrtp_ctrlplane()` | `ubcore_connect_vtp_ctrlplane()` | `ubcore_connect_vtp_ctrlplane()` |
| Local active TP | yes | yes | yes |

### Binding a Jetty in RC Mode

| Stage | RTP | CTP | UTP |
| --- | --- | --- | --- |
| Practical use | yes | not the normal RC path | not valid with RC |
| Entry | `ubcore_bind_jetty_compat()` | code can carry type, but semantics are not the normal CTP use | rejected earlier if UTP is not UM |
| TP-list call | `ubcore_get_tp_list()` | not a normal supported target | not valid |
| Peer exchange | yes, because `tp_type == UBCORE_RTP` | skipped by condition, but this combination should be treated as suspect | no |
| VTP connect | `ubcore_connect_rc_vtp_ctrlplane()` | not a normal supported target | no |

For RC, the engineering expectation is `RC + RTP`.

## 8. Why The Calling Chains Differ

RTP represents a transport that needs both endpoints to agree on peer TP handle
and PSN values before activation. That is why RTP performs:

```text
ubcore_exchange_tp_info
  -> create request MAD
  -> peer get_tp_list
  -> peer active_tp
  -> create response MAD
  -> local session completion
```

CTP is compact and connectionless-like from the initiator's state point of view.
The local UDMA/MUE side gets a CTP resource with `UDMA_CTRLQ_TRANS_TYPE_CTP`.
The compat import path does not need to run the RTP peer TP exchange.

UTP is unreliable message mode. It uses the `UM` transport mapping and avoids
the RTP peer exchange because it does not provide RTP's reliable paired state.

## 9. Impact On First-Link Latency

Cold setup cost by type:

| Cost source | RTP | CTP | UTP |
| --- | --- | --- | --- |
| Local `get_tp_list()` | yes | yes | yes |
| Peer `get_tp_list()` through MAD exchange | yes | no | no |
| Local active TP | yes | yes | yes |
| Peer active TP during setup | yes | no | no |
| MAD request/response RTT | yes | no | no |
| Per-peer state pressure | highest | lower | lowest |

This is why the earlier `get_tp_list()` mitigation helps all three when the
cache key matches, but the visible end-to-end setup win is usually largest for
RTP: RTP pays `get_tp_list()` on both nodes and has a peer MAD exchange around
it. CTP and UTP mainly need local TP-list fetch and local activation.

## 10. Source Map

| Topic | Source |
| --- | --- |
| User TP type enum | `/Volumes/KernelDev/umdk/src/urma/lib/urma/core/include/urma_types.h` |
| Kernel TP type enum | `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h` |
| User transport mode enum | `/Volumes/KernelDev/umdk/src/urma/lib/urma/core/include/urma_types.h` |
| Kernel transport mode enum | `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h` |
| UMDK TP type validity check | `/Volumes/KernelDev/umdk/src/urma/lib/urma/core/urma_cp_api.c` |
| Import/bind compat TP setup | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c` |
| Import Jetty/JFR VTP connection | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c` |
| VTPN connect and active TP wrappers | `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_vtp.c` |
| UDMA get-TP-list request preparation | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` |
| UDMA get-TP-list implementation | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` |
| UDMA TP cache | `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_tp_cache.c` |
| IPoURMA CTP/UTP selection | `/Volumes/KernelDev/kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c` |

## 11. Practical Selection Rule

Use this simple rule unless a workload or product requirement says otherwise:

```text
Need RC-style bound connection:
  use RC + RTP

Need reliable message mode for a small or moderate peer set:
  use RM + RTP

Need many-peer message mode and hardware supports CTP:
  use RM + CTP

Need many-peer best-effort or CTP is unavailable and loss is acceptable:
  use UM + UTP
```

For the UDMA TP-cache work, keep `tp_type` in the cache key. The same
`local_eid`, `peer_eid`, and `trans_mode` can lead to different MUE resource
pools depending on whether the request asks for RTP, CTP, or UTP.
