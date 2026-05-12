# UBASE Local Hardware and Control Queue

Last updated: 2026-05-12

## Short Answer

In the UMDK/URMA/UDMA stack, "local hardware" means the local UnifiedBus
device entity behind UBASE. It is not the peer host, and
`ubase_ctrlq_send_msg()` is not itself a fabric MAD sent to the remote node.

For the UDMA path, the local hardware is normally a local UB Entity exposed as
one of the UBASE-supported functions, such as `URMA_MUE`, `URMA_UE`,
`CDMA_MUE`, `CDMA_UE`, `PMU_MUE`, `PMU_UE`, `UBOE_MUE`, or `UBOE_UE`. UBASE
binds that UB Entity, maps its local resources, creates auxiliary child devices
such as `udma`, and provides command queues used by the child drivers.

The practical mental model is close to an RDMA HCA firmware command queue:

```text
kernel UDMA driver
  -> UBASE control queue
  -> local UB entity / management software / firmware side
  -> local command response queue
```

This is different from a wire-level control-plane packet. The wire-level UB MAD
or peer negotiation path lives above or beside this local device command path.

## Spec Terms

The UnifiedBus Base Specification defines UB as an interconnect technology and
protocol stack for SuperPoD-scale systems. A UB system is made of UBPUs, UB
Controllers, UMMUs, switches, links, and domains.

Relevant terms:

| Term | Meaning in this context |
| --- | --- |
| UBPU | UB processing unit. A processing unit that supports the UB protocol stack and implements device-specific functions. |
| UB Controller | A component inside a UBPU that implements the UB protocol stack and provides software and hardware interfaces. |
| UB Entity | The basic device resource and communication object visible to software in a UB domain. |
| EID | Entity Identifier. The identifier assigned to a UB Entity. |
| UE | UB Entity, or a managed UB Entity in the MUE/UE relationship. |
| MUE | Management UB Entity. The management entity that owns or coordinates shared UB resources for other entities in the same UBPU. |
| UBASE | Kernel base layer that binds UB Entities and creates auxiliary devices for upper modules such as UDMA, UNIC, CDMA, PMU, UVB, and fwctl. |

The important point is that a UB Entity is a local software-visible hardware
object. It has local resources, local configuration space, local EID/capability
state, interrupts, and queue/register interfaces.

## UBASE Device Binding

The local code shows UBASE binding specific UB Entity device IDs:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:20
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.h:16
```

The matched IDs include:

```text
UBASE_DEV_ID_K_0_URMA_MUE
UBASE_DEV_ID_K_0_URMA_UE
UBASE_DEV_ID_K_0_CDMA_MUE
UBASE_DEV_ID_K_0_CDMA_UE
UBASE_DEV_ID_A_0_URMA_MUE
UBASE_DEV_ID_A_0_URMA_UE
UBASE_DEV_ID_A_0_UBOE_MUE
UBASE_DEV_ID_A_0_UBOE_UE
```

During probe, UBASE initializes a `struct ub_entity`, records local capability
fields such as `tid`, `eid`, `upi`, and `ctl_no`, and maps local IO/MEM
resources:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:195
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:218
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:225
```

The mapping path is concrete local MMIO/resource setup:

```text
ub_entity_enable(ue, 1)
dma_set_mask_and_coherent(...)
ub_resource_start(...)
ub_iomap(...)
devm_ioremap_wc(...)
```

The resource mapping is in:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:40
```

This strongly identifies the target as local hardware/resource space, not a
remote host.

## Auxiliary Devices

UBASE then creates Linux auxiliary devices for upper functional modules:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_dev.c:105
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_dev.c:185
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_dev.c:247
```

The supported auxiliary suffixes include:

```text
unic
udma
cdma
fwctl
pmu
uvb
```

The UDMA driver attaches as an auxiliary child. This is why the UDMA TP code
has an `auxiliary_device` handle and calls UBASE APIs instead of binding
directly to a root UB bus device.

The local hierarchy is:

```text
UB bus
  -> ub_entity
      -> UBASE ub_driver probe
          -> ubase_dev
              -> auxiliary_device: udma
                  -> UDMA provider
```

## `ubase_ctrlq_send_msg()` Path

The code comment for `ubase_ctrlq_send_msg()` is explicit:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:904
```

It says the driver uses this function to send a ctrlq message to the management
software. The management software dispatches by:

```text
msg->service_ver
msg->service_type
msg->opcode
```

For synchronous requests, the function waits for the management software
response and stores it in `msg->out`.

The core path is:

```text
ubase_ctrlq_send_msg(aux_dev, msg)
  -> __ubase_get_udev_by_adev(aux_dev)
  -> __ubase_ctrlq_send(...)
  -> ubase_ctrlq_send_real(...)
  -> ubase_ctrlq_send_msg_to_sq(...)
  -> ubase_ctrlq_send_to_csq(...)
  -> memcpy_toio(...) into local CSQ ring
  -> write UBASE_CTRLQ_CSQ_TAIL_REG
  -> report ctrlq IRQ
  -> wait_for_completion_timeout(...)
```

Source anchors:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:820
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:884
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:926
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:619
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:562
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:645
```

The send side copies command data into a local command send queue:

```text
memcpy_toio(addr, head, sizeof(*head))
memcpy_toio(addr, msg->in + offset, size)
ubase_write_dev(&udev->hw, UBASE_CTRLQ_CSQ_TAIL_REG, csq->pi)
ubase_ctrlq_csq_report_irq(udev)
```

That is a local device queue/register interaction.

The response path is also local:

```text
local CRQ interrupt / service task
  -> ubase_ctrlq_read_msg_data(...)
  -> ubase_ctrlq_handle_crq_msg(...)
  -> ubase_ctrlq_notify_completed(...)
  -> complete(&ctx->done)
```

Source anchors:

```text
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:959
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1057
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1131
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1164
```

## What `get_tp_list` Sends

The UDMA TP code builds a UBASE ctrlq message for TP ACL service:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:19
```

It sets:

```text
msg->service_ver  = UBASE_CTRLQ_SER_VER_01
msg->service_type = UBASE_CTRLQ_SER_TYPE_TP_ACL
msg->need_resp    = 1
msg->is_resp      = 0
msg->in           = request buffer
msg->out          = response buffer
```

For `get_tp_list`, it sets:

```text
msg.opcode = UDMA_CMD_CTRLQ_GET_TP_LIST
```

and calls:

```text
ubase_ctrlq_send_msg(udev->comdev.adev, &msg)
```

Source anchor:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:606
```

So `udma_get_tp_list()` asks the local management side for TP list or TPID
information. The call can be slow because the local management side may have to
allocate, validate, or coordinate TP state, but the immediate kernel operation
is still a local UBASE ctrlq transaction.

## What `active_tp` Sends

`active_tp` follows the same local ctrlq mechanism after the UB control-plane
negotiation has produced the peer TP information.

The UDMA code builds an active-TP request containing both local and remote TP
state:

```text
local_tp_id
local_tpn_cnt
local_tpn_start
local_psn
remote_tp_id
remote_tpn_cnt
remote_tpn_start
remote_psn
```

It then sets:

```text
msg.opcode = UDMA_CMD_CTRLQ_ACTIVE_TP
```

and calls `ubase_ctrlq_send_msg()`.

Source anchor:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:677
```

This programs or activates the TP state in local hardware/management software.
It is not the same thing as the earlier cross-host UB MAD exchange.

## MUE/UE Messaging

The code also has explicit UE/MUE message helpers:

```text
UBASE_OPC_MUE_TO_UE
UBASE_OPC_UE_TO_MUE
UBASE_OPC_UE2UE_UBASE
```

Source anchors:

```text
/Volumes/KernelDev/kernel/include/ub/ubase/ubase_comm_cmd.h:117
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:467
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:950
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1663
```

This is why the words "management software", "MUE", and "UE" appear together.
The driver can send:

```text
UE -> MUE
MUE -> UE
MUE -> UE response
```

But these are still handled through UBASE command/control mechanisms and
entity-management paths. They do not mean every `ubase_ctrlq_send_msg()` call is
a direct peer-host fabric packet.

For `GET_TP_LIST`, UDMA registers handlers for UE request/response messages:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_mue.c:117
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_mue.c:218
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_mue.c:272
```

That confirms this area is an MUE/UE TP-management path, but the open kernel
source does not expose all firmware-side implementation details.

## Relationship to UB MAD Link Setup

For link setup, separate the two layers:

```text
Cross-host control plane:
  ubcore / ubcm / ubmad
    -> CONN_REQ / CONN_RESP MADs over UB fabric
    -> peer host participates

Local hardware programming:
  ubcore_active_tp
    -> udma_active_tp
    -> ubase_ctrlq_send_msg
    -> local management software / local UB hardware
```

The local UBASE ctrlq path is the firmware/hardware command queue. The UB MAD
path is the peer-to-peer fabric control plane. They are connected in the
overall link setup flow, but they are not the same transport.

## RDMA Analogy

The closest RDMA analogy is:

| UB/UDMA path | RDMA analogy |
| --- | --- |
| `ub_entity` | PCIe function or local device function exposed by firmware/bus enumeration |
| UBASE | Base device framework plus common command/event/reset resource layer |
| `udma` auxiliary device | RDMA provider driver child over the base device |
| `ubase_ctrlq_send_msg()` | Local HCA firmware command queue |
| CSQ/CRQ | Command send queue / command response queue |
| MUE management side | Local firmware/control processor role |
| `ubmad_post_send` | Fabric control-plane packet path, closer to wire-level management messages |

So when debugging latency, do not treat `ubase_ctrlq_send_msg()` as "sending to
the remote hardware". Treat it as "asking the local UB management/control
engine to perform work". That work may depend on state that came from peer
negotiation, or may trigger entity-management behavior, but the immediate queue
is local.

## Why This Matters for `get_tp_list`

The slow `get_tp_list` first-call path should be analyzed as:

```text
ubcore_get_tp_list
  -> udma_get_tp_list
  -> udma_ctrlq_fetch_tpid_list
  -> ubase_ctrlq_send_msg
  -> local UBASE CSQ/CRQ
  -> local management software / MUE / local UB hardware state
```

If the delay is inside `ubase_ctrlq_send_msg()`, then the kernel is waiting for
the local management side to respond. If the delay is before or after it, the
expensive part may be ubcore route/session/MAD negotiation instead.

That is why useful timing points are:

```text
ubcore_get_tp_list entry/exit
udma_ctrlq_fetch_tpid_list entry/exit
ubase_ctrlq_send_msg entry/exit
ubase_ctrlq_wait_completed entry/exit
ubcore_active_tp entry/exit
udma_active_tp entry/exit
```

The interpretation is:

| Observation | Meaning |
| --- | --- |
| Time is mostly in `ubase_ctrlq_wait_completed()` | Local management software/hardware response is slow. |
| Time is mostly before `ubase_ctrlq_send_msg()` | ubcore/session/MAD/control-plane negotiation is slow. |
| Time is mostly in `ubcore_active_tp()` but not in `get_tp_list` | TP activation/local hardware programming is slow. |
| Time is mostly in UB MAD receive/wait path | Peer host or fabric control-plane response is slow. |

## Exact Conclusion

The local hardware behind `ubase_ctrlq_send_msg()` is the local UnifiedBus
endpoint/entity and its management/control engine. In concrete code terms, it is
the `ub_entity` bound by UBASE, exposed through UBASE-supported device IDs such
as `A_0_URMA_UE` or `A_0_URMA_MUE`, accessed via local resource mappings,
local CSQ/CRQ rings, and local MMIO registers.

For UDMA TP calls:

```text
get_tp_list / active_tp
  -> UDMA builds TP ACL ctrlq message
  -> UBASE sends it to local management software
  -> local hardware/firmware/MUE side responds
```

It is best described as local UB firmware/control hardware, not the remote peer.

## Source References

Local source:

- `/Volumes/KernelDev/kernel/include/ub/ubus/ubus.h:171` - `struct ub_entity`,
  EID, MUE/UE fields, topology relation to MUE.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.h:16` - UBASE vendor
  and device IDs for URMA/CDMA/PMU/UBOE MUE/UE devices.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:20` - UBASE UB
  device ID table.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:40` - local
  resource mapping for IO/MEM/resource0.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ubus.c:195` - UBASE probe
  of a `struct ub_entity`.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_dev.c:105` - UBASE
  auxiliary child device list.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_dev.c:185` - auxiliary
  device creation.
- `/Volumes/KernelDev/kernel/include/ub/ubase/ubase_comm_ctrlq.h:15` - CSQ/CRQ
  local register definitions.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:562` - copy command
  blocks to local CSQ ring and update tail register.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:904` -
  `ubase_ctrlq_send_msg()` comment describing management software dispatch.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1057` - complete
  synchronous ctrlq response.
- `/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:1131` - CRQ message
  handling.
- `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:19` -
  UDMA TP ctrlq message setup.
- `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:606` -
  `UDMA_CMD_CTRLQ_GET_TP_LIST`.
- `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:677` -
  `UDMA_CMD_CTRLQ_ACTIVE_TP`.
- `/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_mue.c:117` - UDMA
  MUE/UE handler registration for TP-list requests.

Local specification documents:

- `/Users/ray/UnifiedBus-docs-2.0/UB-Base-Specification-2.0-preview-en.pdf`
- `/Users/ray/UnifiedBus-docs-2.0/UB-Software-Reference-Design-for-OS-2.0-en.pdf`
- `/Users/ray/UnifiedBus-docs-2.0/UB-Service-Core-SW-Arch-RD-2.0-en.pdf`
- `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-zh.pdf`

Public references:

- Huawei, "Huawei Launches World's First General Computing SuperPoD":
  https://www.huawei.com/en/news/2025/9/hc-superpod-innovation
- Huawei keynote mentioning UnifiedBus and SuperPoD architecture:
  https://www.huawei.com/en/news/2025/9/hc-xu-keynote-speech
- openEuler UB OS Component project:
  https://www.openeuler.org/en/projects/ub-os-component/
- UB Service Core Software Architecture Reference Design:
  https://www.openeuler.org/projects/ub-service-core/white-paper/UB-Service-Core-SW-Arch-RD-2.0-en.pdf
