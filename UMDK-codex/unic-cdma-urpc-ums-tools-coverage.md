# UNIC, CDMA, URPC, UMS, and Tool Coverage

Last updated: 2026-04-25

This note closes the coverage gap around the UMDK-adjacent components that are
not fully explained by the main URMA/UDMA docs:

- UNIC, the UB-facing network driver.
- CDMA, the Crystal DMA driver and its UMMU-backed DMA object model.
- URPC and UMQ, the higher-level RPC and queue layer in UMDK.
- UMS/USOCK, the socket compatibility path.
- Admin, diagnostic, ping, perftest, and preload tools.
- The requested `ubtool` name, which was not found in the local source trees.

It should be read after:

- `umdk-component-architecture.md`
- `end-to-end-platform-workflow.md`
- `ummu-memory-management-deep-dive.md`
- `umdk-rdma-terminology-and-comparison.md`

## Direct Answer: Coverage by Requested Area

| Requested area | Coverage status after this pass | Primary docs |
| --- | --- | --- |
| `liburma` | Deeply covered | `unifiedbus-spec-umdk-urma-udma.md`, `umdk-component-architecture.md`, `urma-udma-working-flows.md`, `source-map.md` |
| `urma` / URMA | Deeply covered | `unifiedbus-spec-umdk-urma-udma.md`, `umdk-rdma-terminology-and-comparison.md`, `urma-udma-working-flows.md` |
| `UDMA` | Deeply covered for user provider, kernel provider, queues, segments, UMMU, and workflows | `umdk-component-architecture.md`, `urma-udma-working-flows.md`, `ummu-memory-management-deep-dive.md`, `08-source-evidence-map.md` |
| `UMMU` | Deeply covered for firmware discovery, UDMA context TID, token/TID, SVA/KSVA, segment grant/map, and teardown | `ummu-memory-management-deep-dive.md`, `end-to-end-platform-workflow.md` |
| `UVS` | Covered for topology, TPSA, ubagg, ubcore topology push, and UB-Mesh mapping | `ub-mesh-context-and-umdk-mapping.md`, `source-map.md`, `08-source-evidence-map.md` |
| `UNIC` | Newly covered here at architecture and workflow depth | This doc, plus `source-map.md` |
| `CDMA` | Newly covered here at architecture, ABI, UMMU, and workflow depth | This doc, plus `source-map.md` |
| `URPC` | Newly covered here beyond earlier architecture mentions | This doc, plus `source-map.md` |
| `UMS` / USOCK | Newly covered here beyond earlier architecture mentions | This doc, plus `source-map.md` |
| `ubtool` | Not found locally by this name | This doc records the search result and lists the actual discovered tools |

The practical result is:

```text
Core memory semantics path:
  liburma -> UDMA user provider -> uburma -> ubcore -> UDMA kernel -> UMMU

Adjacent UB software paths:
  UNIC -> Linux netdev facade for UB network/port behavior
  CDMA -> Crystal DMA char-device and kernel DMA-client API
  URPC/UMQ -> higher-level RPC/queue library over IPC/UB/UBMM transports
  UMS/USOCK -> socket compatibility through AF_SMC, TCP ULP, and LD_PRELOAD
  tools -> admin, topology, ping, perftest, and preload controls
```

## Source Scope

This pass used local source only.

| Component | Primary local source |
| --- | --- |
| UNIC | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic` |
| CDMA | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma` |
| CDMA kernel API | `/Users/ray/Documents/Repo/kernel/include/ub/cdma/cdma_api.h` |
| CDMA UAPI ABI | `/Users/ray/Documents/Repo/kernel/include/uapi/ub/cdma/cdma_abi.h` |
| URPC | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc` |
| UMQ | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq` |
| UMS/USOCK | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums` |
| URMA tools | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools` |
| URPC tools | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools` |
| UMS tools | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools` |

Search for `ubtool`, `ub_tool`, `ub tool`, `ub-tool`, and `UB tool` across:

- `/Users/ray/Documents/Repo/ub-stack/umdk`
- `/Users/ray/Documents/Repo/kernel`
- `/Users/ray/Documents/Repo/ub-stack/kernel-ub`

found no local matches. The local tools are named more specifically:
`urma_admin`, `urma_ping`, `urma_perftest`, `urpc_admin`, URPC perftest tools,
`ums_admin`, `ums_run`, and `libums-preload.so`.

## Component Positioning

| Component | Layer | Main purpose | Closest familiar analogy | Important difference |
| --- | --- | --- | --- | --- |
| UNIC | Kernel network driver under UB/UBASE | Expose a UB-attached network port as a Linux netdev-style device | Ethernet NIC driver | It is bound through UBASE auxiliary devices and carries UB-specific VL/channel/link state. |
| CDMA | Kernel DMA engine and char-device ABI | Provide Crystal DMA queues, JFS/JFC/JFCE, CTP, Segment, and UMMU-backed DMA context | DMA engine plus RDMA-like queue resources | It is not the same as UDMA/liburma; it has its own `/dev/cdma/dev` ABI and kernel DMA-client API. |
| URPC | UMDK user-space RPC framework | Build channels, attach servers, pair queues, expose remote function and memory-segment access | RPC framework over high-speed transport | It uses UMDK/UMQ/URMA-style resources rather than TCP as the primary data-plane abstraction. |
| UMQ | UMDK queue substrate for URPC | Create/bind queues, allocate buffers, enqueue/dequeue, poll, and interrupt | Message queue or transport queue | The UB backend directly uses URMA Jetty/JFC operations. |
| UMS/USOCK | Socket compatibility | Let socket-style apps use UB memory socket transport | SMC-like socket family and preload shim | It maps selected TCP sockets into `AF_SMC` and registers a UMS TCP ULP plus ubcore client. |
| UVS | User-space topology and TPSA control | Program topology/path/control information into ubagg and ubcore | RDMA CM plus fabric/topology manager, partially | It is UB-specific and interacts with topology and aggregate-device models. |
| UDMA | URMA provider/hardware binding | Implement liburma provider ops and kernel ubcore ops | RDMA provider driver | It implements URMA/UB semantics, not verbs semantics. |

The important boundary is that UNIC, CDMA, URPC, and UMS are not replacements
for liburma/UDMA. They surround it:

```text
Network compatibility:
  app sockets -> ums_run/libums-preload -> AF_SMC/UMS -> ubcore/UB transport

Native URMA:
  app -> liburma -> UDMA provider -> uburma/ubcore -> UDMA hardware/UMMU

RPC/queue:
  app -> URPC -> UMQ -> IPC or UB transport -> URMA Jetty/JFC where UB backend is used

Kernel DMA:
  kernel/user CDMA clients -> /dev/cdma/dev or cdma_api -> CDMA queues/segments -> UMMU

Netdev facade:
  Linux networking -> UNIC netdev -> UBASE auxiliary device -> UB port/link/channel behavior
```

## UNIC

### Role

UNIC is a Hisilicon UB network driver in the newer openEuler kernel tree. It is
not the liburma provider. It is a kernel netdev-facing component that binds to a
UBASE-created auxiliary device and exposes Linux network-device behavior:
queues, traffic classes, NAPI, link status, notifiers, debugfs, and MAC/link
control.

Source anchors:

| Claim | Source |
| --- | --- |
| UNIC is an auxiliary driver named `unic`. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_main.c:71` |
| It matches auxiliary devices named `UBASE_ADEV_NAME ".unic"`. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_main.c:62` |
| Probe calls `unic_dev_init()` and `unic_dbg_init()`. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_main.c:17` |
| Module init registers IP address notifier, netdevice notifier, and the auxiliary driver. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_main.c:78` |
| Module description says `UNIC: Hisilicon Network Driver`. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_main.c:122` |

### Architecture

UNIC is structured like a normal Linux NIC driver, but its parent device is UB
specific:

```text
UB entity discovered by ubus
  -> ubase binds entity
  -> ubase creates auxiliary device named <ubase>.unic
  -> unic auxiliary driver probes
  -> unic_dev_init creates/initializes netdev state
  -> channels, NAPI, MAC, link, VLAN, QoS, DCB, debugfs paths become active
```

Important source files:

| File | Role |
| --- | --- |
| `unic_main.c` | Module init, auxiliary driver, probe/remove. |
| `unic_dev.c` | Device init/uninit and likely netdev allocation glue. |
| `unic_netdev.c` | Netdev open/up/down, channel enable, link status, traffic-class setup. |
| `unic_tx.c`, `unic_rx.c`, `unic_txrx.c` | Transmit, receive, and channel data path. |
| `unic_hw.c`, `unic_mac.c` | Hardware and MAC operations. |
| `unic_qos_hw.c`, `unic_dcbnl.c` | QoS/DCB behavior. |
| `unic_bond.c` | Bond-related behavior. |
| `debugfs/*` | Debug and observability. |

### Netdev and Link Flow

`unic_netdev.c` shows the Linux netdev-facing behavior:

| Flow | Source anchor | Meaning |
| --- | --- | --- |
| Set traffic classes from UB/UBASE capabilities. | `unic_netdev_set_tcs()` at `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_netdev.c:37` | Uses `ubase_get_dev_caps()` and maps VL/priority to Linux traffic classes. |
| Set real TX/RX queue counts. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_netdev.c:79` | Bridges UB channel count into netdev queue counts. |
| Enable channels and NAPI. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_netdev.c:109` | Calls `napi_enable()` per channel and registers completion callback through UBASE. |
| Bring network side up. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_netdev.c:151` | Clears queues, enables channels, enables MAC mode, and starts with software link down. |
| Handle link up/down. | `/Users/ray/Documents/Repo/kernel/drivers/net/ub/unic/unic_netdev.c:200` | Wakes/stops queues and toggles carrier based on UB link status. |

### Spec and Design Interpretation

From a spec perspective, UNIC belongs to the compatibility and networking side
of UB. It makes UB-attached hardware usable through Linux network-device
semantics. That matters for:

- IP and Ethernet-compatible traffic over UB-related hardware.
- Notifier integration with the Linux networking stack.
- Traffic-class and virtual-lane mapping.
- Link state and network interface observability.
- Coexistence with URMA/UDMA paths on the same UB platform.

Compared with UDMA:

| Axis | UNIC | UDMA |
| --- | --- | --- |
| User API | Sockets/netdev tools through Linux networking | liburma URMA APIs |
| Kernel framework | Linux netdev and auxiliary bus | ubcore, uburma, auxiliary bus |
| Main objects | netdev, channels, NAPI, TX/RX queues, link | context, JFS/JFR/JFC, Jetty, Segment, TID/token |
| Memory semantics | Packet/network stack oriented | Remote memory and queue semantics |
| UMMU role | Not proven in this pass for UNIC data path | Central to context, TID, token, and Segment paths |

Open questions:

- Trace exactly how UBASE decides to create `.unic` auxiliary devices.
- Trace UNIC TX/RX packet formats and whether paths are UBoE, Ethernet-like, or
  vendor-specific UB link behavior in this branch.
- Map UNIC QoS/VL behavior back to the UB base-spec data-link and service-level
  model.

## CDMA

### Role

CDMA is the `Hisilicon UBus Crystal DMA Driver`. It is a separate kernel DMA
component under `/drivers/ub/cdma`, not the same thing as the URMA UDMA
provider. It has:

- An auxiliary driver named `cdma`.
- A char-device ABI under `cdma/dev`.
- A command dispatcher through `CDMA_SYNC`.
- Queue, JFS, JFC, JFCE, CTP, Segment, and context objects.
- UMMU/SVA/KSVA/TID integration.
- A kernel-facing `include/ub/cdma/cdma_api.h` API for DMA clients.

### Probe and Device Model

| Claim | Source |
| --- | --- |
| CDMA module params include JFC arm mode and CQE mode. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:22` |
| CDMA creates a class named `cdma`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:296` |
| CDMA matches `UBASE_ADEV_NAME ".cdma"`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:277` |
| Probe creates a CDMA device and char device. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:220` |
| Probe registers reset handling with UBASE. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:239` |
| Module description is `Hisilicon UBus Crystal DMA Driver`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_main.c:327` |

The bring-up path is:

```text
ubase auxiliary device .cdma
  -> cdma_probe()
  -> cdma_create_dev()
  -> cdma_create_chardev()
  -> cdma_client_callback(..., CDMA_CLIENT_ADD)
  -> ubase_reset_register()
```

The reset/remove path is unusually important. CDMA walks open files, unmaps VMA
pages, marks contexts invalid, stops/removes DMA clients, destroys the char
device, cleans user objects, flushes commands, and destroys the device. This is
visible in `cdma_reset_down()`, `cdma_reset_uninit()`, `cdma_reset_init()`, and
`cdma_remove()` in `cdma_main.c`.

### Char Device and ABI

| ABI surface | Source | Meaning |
| --- | --- | --- |
| Device name | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_chardev.c:19` | Uses `cdma/dev`. |
| Main ioctl | `/Users/ray/Documents/Repo/kernel/include/uapi/ub/cdma/cdma_abi.h:11` | `CDMA_SYNC` carries a `struct cdma_ioctl_hdr`. |
| Ioctl handler | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_chardev.c:63` | Copies the header from user space and calls `cdma_cmd_parse()`. |
| Mmap handler | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_chardev.c:174` | Maps JFC and Jetty doorbell/DSQE pages. |
| Mmap command types | `/Users/ray/Documents/Repo/kernel/include/uapi/ub/cdma/cdma_abi.h:63` | `CDMA_MMAP_JFC_PAGE`, `CDMA_MMAP_JETTY_DSQE`. |

The CDMA user ABI is command based:

```text
user
  -> open /dev/cdma/dev
  -> ioctl(CDMA_SYNC, cdma_ioctl_hdr)
  -> cdma_ioctl()
  -> cdma_cmd_parse()
  -> command-specific handler
  -> copy result back to user
```

The command table includes:

| Command | Handler source |
| --- | --- |
| Query device | `cdma_query_dev()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:38` |
| Create/delete context | `cdma_create_ucontext()` and `cdma_delete_ucontext()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:66` |
| Create/delete CTP | `cdma_cmd_create_ctp()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:151` |
| Create/delete JFS | `cdma_cmd_create_jfs()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:286` |
| Create/delete queue | `cdma_cmd_create_queue()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:418` |
| Register/unregister Segment | `cdma_cmd_register_seg()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:515` |
| Create/delete JFC | `cdma_cmd_create_jfc()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:612` |
| Create JFCE | `cdma_cmd_create_jfce()` at `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:748` |
| Command dispatch table | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_ioctl.c:783` |

### CDMA and UMMU

CDMA is UMMU-backed. That is a new finding for this pass and should be kept
separate from the earlier UDMA UMMU discussion.

Device-level TID setup:

```text
cdma_alloc_dev_tid()
  -> enable IOMMU KSVA, IOPF, and SVA features
  -> iommu_ksva_bind_device()
  -> ummu_get_tid()
  -> iommu_sva_grant(... CDMA_MAX_GRANT_SIZE ...)
```

Source anchors:

| Claim | Source |
| --- | --- |
| CDMA enables KSVA, IOPF, and SVA features. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_tid.c:12` |
| CDMA binds KSVA and obtains a TID. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_tid.c:53` |
| CDMA grants a device range through `iommu_sva_grant()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_tid.c:82` |
| CDMA ungrants and unbinds during teardown. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_tid.c:101` |

Context-level TID setup:

```text
cdma_alloc_context()
  -> cdma_ctx_alloc_tid()
  -> kernel context: iommu_ksva_bind_device + ummu_get_tid
  -> user context:
       shared SVA mode: iommu_sva_bind_device_isolated + ummu_get_tid
       separate SVA mode: ummu_alloc_tdev_separated
```

Source anchors:

| Claim | Source |
| --- | --- |
| Kernel contexts bind KSVA and call `ummu_get_tid()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_context.c:53` |
| User contexts support shared SVA and separated SVA modes. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_context.c:73` |
| Context allocation obtains a TID before exposing queue/seg lists. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_context.c:154` |
| Context free unbinds SVA/KSVA or frees separated TDEV. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_context.c:197` |

Segment registration and grant:

```text
cdma_register_seg()
  -> cdma_umem_get()
  -> allocate segment handle
  -> remember SVA, length, token value

cdma_seg_grant()
  -> inherit TID from context
  -> prepare ummu_token_info
  -> iommu_sva_grant(SVA, len, MAPT_PERM_RW, token)
```

Source anchors:

| Claim | Source |
| --- | --- |
| CDMA pins/registers Segment memory with `cdma_umem_get()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_segment.c:38` |
| CDMA Segment records token value, SVA, length, and validity. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_segment.c:59` |
| CDMA Segment grant uses context TID and `iommu_sva_grant()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_segment.c:83` |
| CDMA Segment ungrant calls `iommu_sva_ungrant()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/cdma/cdma_segment.c:106` |

### CDMA Compared With UDMA

| Axis | CDMA | UDMA |
| --- | --- | --- |
| Main API surface | `/dev/cdma/dev`, `CDMA_SYNC`, `cdma_api.h` | liburma provider ABI, `/dev/uburma/<device>`, ubcore ops |
| Kernel framework | CDMA auxiliary driver, cdev, DMA-client callbacks | UDMA auxiliary driver, ubcore device registration |
| Object names | context, queue, CTP, JFS, JFC, JFCE, Segment | context, Jetty, JFS, JFR, JFC, JFAE/JFCE, Segment, TP |
| Memory substrate | UMMU, KSVA/SVA, TID, token grant | UMMU, KSVA/SVA, TID, token, MATT/MAPT |
| User-space library | No liburma-like user library found in this pass | liburma and `liburma-udma` provider |
| Fit in UB stack | DMA service exposed to user/kernel clients | URMA service provider and primary memory semantics path |

The key design point: CDMA reuses several URMA-like object names and UMMU
concepts, but it is a separate driver and ABI. Treat it as a sibling UB DMA
facility, not as the UDMA implementation itself.

Open questions:

- Identify all in-tree CDMA clients using `include/ub/cdma/cdma_api.h`.
- Map CDMA CTP to UB transport terminology and compare it against UDMA TP.
- Trace CDMA user-space package/tooling, if any exists outside the current
  local UMDK tree.
- Add an ABI-by-ABI table for `cdma_abi.h` the way the existing docs already do
  for UDMA.

## URPC and UMQ

### Role

URPC is the UMDK remote procedure call framework. UMQ is the queue/messaging
substrate used under it. Earlier docs only noted that `src/urpc` exists; this
pass maps its visible API and its relationship to URMA/UB transports.

Key source trees:

| Path | Role |
| --- | --- |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/framework` | URPC control plane, datapath, channel management, DFX, examples. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq` | UMQ queue implementation. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ipc` | IPC transport mode. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub` | UB transport mode. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ubmm` | UB memory-management related mode. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/urpc_admin` | URPC admin IPC tool. |
| `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/perftest` | URPC/UMQ performance tests. |

### URPC Framework API

The public URPC API exposes a channel/server/queue model:

| API group | Source | Meaning |
| --- | --- | --- |
| Init/uninit | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:19` | Start or stop URPC with device/config settings. |
| Allocator registration | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:36` | Let caller provide memory allocation hooks. |
| Remote memory segment access | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:54` | Enable or disable remote access to a memory segment for a channel. |
| Channel create/destroy | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:73` | Create/destroy a URPC channel. |
| Server attach/refresh/detach | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:108` | Discover server capabilities and establish/refresh/break connectivity. |
| Server start | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:151` | Start the server control plane listener. |
| Queue add/remove/pair/unpair | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/urpc_framework_api.h:172` | Bind local queues into channels and pair them with remote queues. |

High-level URPC flow:

```text
process
  -> urpc_init()
  -> urpc_channel_create()
  -> server: urpc_server_start()
  -> client: urpc_channel_server_attach()
  -> create UMQ queue(s)
  -> urpc_channel_queue_add()
  -> urpc_channel_queue_pair()
  -> call/poll data path
  -> urpc_channel_server_detach()
  -> urpc_channel_destroy()
  -> urpc_uninit()
```

### UMQ API and UB Backend

UMQ provides a transport-neutral queue API:

| API group | Source | Meaning |
| --- | --- | --- |
| Init/uninit | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:20` | Configure global UMQ state. |
| Create/destroy | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:34` | Create or destroy a UMQ handle. |
| Bind/unbind | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:50` | Exchange or apply bind information. |
| Buffer allocation/free | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:99` | Allocate/free UMQ buffers from global or queue-local pools. |
| Enqueue/dequeue | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:154` | Queue data for send or receive. |
| Interrupt support | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:179` | Rearm, wait, and acknowledge queue interrupts. |
| Async event support | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/include/umq/umq_api.h:219` | Get/ack asynchronous transport events. |

The UB backend is where the connection to URMA becomes concrete. In
`umq_pro_ub.c`, the code polls URMA JFCs and posts Jetty receive work requests:

| UB backend behavior | Source |
| --- | --- |
| Flow-control RX polls a JFR JFC through `urma_poll_jfc()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub/core/private/umq_pro_ub.c:842` |
| Flow-control RX reposts receive work through `urma_post_jetty_recv_wr()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub/core/private/umq_pro_ub.c:889` |
| Data RX polls the IO JFR JFC through `urma_poll_jfc()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub/core/private/umq_pro_ub.c:906` |
| TX completion path polls JFS JFC through `urma_poll_jfc()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub/core/private/umq_pro_ub.c:1157` |
| Error flush path calls `urma_flush_jetty()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/umq/umq_ub/core/private/umq_pro_ub.c:1033` |

That means the UB transport version of UMQ is not just an abstract message
queue. It consumes the URMA object model:

```text
UMQ handle
  -> UB queue context
  -> Jetty for IO and flow-control
  -> JFS/JFR/JFC underneath
  -> liburma symbols loaded/called by UMQ backend
  -> UDMA provider/kernel path when provider is UDMA
```

### URPC Admin Tool

`urpc_admin` is not a general UB hardware tool. It connects to a URPC process
over a Unix-domain control socket:

| Claim | Source |
| --- | --- |
| `urpc_admin` creates an `AF_UNIX` socket. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/urpc_admin/urpc_admin.c:33` |
| The socket path is `urpc.sock.<pid>` under the configured path. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/urpc_admin/urpc_admin.c:49` |
| It sends an IPC control request and receives a reply. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/urpc_admin/urpc_admin.c:118` |

Open questions:

- Add a function-level call graph from `urpc_channel_server_attach()` through
  control-plane serialization and queue pairing.
- Map every UMQ transport mode (`ipc`, `ub`, `ubmm`) to its actual memory and
  control-plane behavior.
- Trace provider-loading and symbol-resolution code for `umq_symbol_urma()`.

## UMS and USOCK

### Role

UMS is the UB Memory based Socket implementation in UMDK's `src/usock/ums`
tree. It provides a socket compatibility path, not a native liburma API. It is
built around:

- A kernel module that registers `AF_SMC` protocol operations.
- A TCP ULP named `ums`.
- A ubcore client registration.
- A preload library that maps selected TCP sockets to `AF_SMC`.
- Runtime tools `ums_run` and `ums_admin`.

### Kernel Socket Path

Source anchors:

| Claim | Source |
| --- | --- |
| UMS declares protocol objects named `UMS` and `UMS6`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:136` |
| UMS allocates `AF_SMC` sockets. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:189` |
| UMS `proto_ops` uses `AF_SMC`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:763` |
| UMS creates an internal TCP socket for handshake/fallback. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:791` |
| UMS registers an `AF_SMC` net protocol family. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:837` |
| UMS registers proto objects and socket family during init. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1040` |
| UMS registers as a ubcore client. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1143` |
| UMS registers TCP ULP operations. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1159` |
| Module aliases include `AF_SMC` and TCP ULP `ums`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1213` |

High-level kernel flow:

```text
module load
  -> ums_init_sys_config()
  -> ums_init_base()
  -> proto_register(UMS/UMS6)
  -> sock_register(AF_SMC)
  -> ums_ubcore_register_client()
  -> tcp_register_ulp("ums")
  -> ums_dfx_init()
```

Application socket flow:

```text
socket(AF_SMC, SOCK_STREAM, UMSPROTO_UMS/UMS6)
  -> ums_create()
  -> ums_sock_alloc()
  -> internal TCP socket for CLC handshake/fallback
  -> UMS connection/core/LLC/CDC paths
  -> ubcore-backed transport when UB capability is available
```

### LD_PRELOAD Compatibility Path

`ums-preload.c` intercepts `socket()`:

| Claim | Source |
| --- | --- |
| The preload library defines an overriding `socket()` symbol. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:77` |
| It maps IPv4/IPv6 stream TCP sockets to `AF_SMC`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:85` |
| It resolves the original libc socket through `dlopen()` and `dlsym()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:113` |

`ums_run` wraps an application with that preload library:

| Claim | Source |
| --- | --- |
| The preload library path is `/usr/lib/libums-preload.so`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:14` |
| It appends the library to `LD_PRELOAD`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:45` |
| It executes the requested command. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:48` |

Therefore socket compatibility has two modes:

```text
Native UMS-aware app:
  socket(AF_SMC, SOCK_STREAM, UMSPROTO_UMS)

Existing TCP app:
  ums_run <app>
    -> LD_PRELOAD=...libums-preload.so
    -> socket(AF_INET/AF_INET6, SOCK_STREAM, TCP)
    -> rewritten to AF_SMC
```

### UMS Admin Tool

`ums_admin` is a DFX/diagnostic tool:

| Claim | Source |
| --- | --- |
| It supports a `show` command enum. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_admin/ums_admin.c:38` |
| It talks to generic netlink family `UMS_GENL_DFX`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_admin/ums_admin.c:111` |
| It prints link group, link, connection, send buffer, RMB buffer, and token fields. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_admin/ums_admin.c:114` |
| It reports `UMS module not loaded` if the generic netlink family is absent. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_admin/ums_admin.c:199` |

### Design Interpretation

UMS sits at the opposite end from liburma:

| Axis | UMS/USOCK | liburma/URMA |
| --- | --- | --- |
| Primary compatibility goal | Run socket/TCP-style applications over UB memory socket transport | Expose UB-native remote-memory and queue semantics |
| App changes | Potentially none with `ums_run` preload | App uses URMA APIs |
| Kernel API | Socket family, TCP ULP, proto ops | uburma cdev, ubcore, UDMA ops |
| Failure/fallback | Internal TCP socket is created for CLC handshake and fallback | Failures are URMA/provider/context/resource errors |
| Tooling | `ums_run`, `ums_admin` | `urma_admin`, `urma_ping`, `urma_perftest` |

Open questions:

- Trace UMS connection manager (`cm`), LLC, CDC, and RMB/token data paths in
  detail.
- Compare UMS to the UB Service Core "Socket-over-UB" description and RoUB/HCOM
  layers.
- Add a runtime validation appendix showing `ums_admin show` output when the
  module is loaded.

## Tools and Observability

### Discovered Tool Matrix

| Tool | Source path | Purpose |
| --- | --- | --- |
| `urma_admin` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin` | URMA device, resource, EID, topology, and admin operations. |
| `urma_admin show topo` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin_cmd_show.c` | Prints topology from topology map. |
| `urma_ping` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_ping` | URMA connectivity/ping diagnostics. |
| `urma_perftest` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_perftest` | URMA performance testing. |
| `urpc_admin` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/urpc_admin` | URPC process control/DFX through Unix-domain IPC. |
| URPC perftest | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc/tools/perftest` | URPC/UMQ performance tests. |
| `ums_admin` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_admin` | UMS generic-netlink DFX status. |
| `ums_run` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run` | Run a command with `libums-preload.so` injected. |
| `libums-preload.so` source | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c` | Intercept `socket()` and map TCP stream sockets to `AF_SMC`. |

### `urma_admin`

Source anchors:

| Claim | Source |
| --- | --- |
| `urma_admin` entry point builds `admin_config_t` and calls `admin_cmd_main()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin.c:51` |
| Show usage includes device and topology commands. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin_cmd_show.c:28` |
| `show topo` fetches topology and prints the requested/current node. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin_cmd_show.c:1246` |
| `show` dispatch table includes default and `topo`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin_cmd_show.c:1274` |

This is the main local user-facing admin tool for URMA/UDMA/topology, and it is
the closest match to what someone might casually call a "UB tool" in this
checkout. However, no binary/source literally named `ubtool` was found.

### `urpc_admin`

`urpc_admin` is process-local and IPC-oriented. It should not be confused with
`urma_admin`:

```text
urpc_admin args
  -> parse target pid/path/module/cmd
  -> connect to <path>/urpc.sock.<pid>
  -> send unix IPC control request
  -> receive and format response
```

### `ums_admin` and `ums_run`

`ums_admin` is runtime DFX for the kernel UMS module. `ums_run` is application
wrapping through `LD_PRELOAD`.

These tools answer different questions:

| Question | Tool |
| --- | --- |
| Which URMA devices, EIDs, resources, or topology are visible? | `urma_admin` |
| Is a URPC process exposing channel/debug information? | `urpc_admin` |
| Is the UMS kernel module loaded, and what link/connection/buffer status exists? | `ums_admin` |
| Can an existing TCP app be routed through UMS without code changes? | `ums_run <app>` |

## End-to-End Workflows

### Workflow A: UNIC Bring-Up to Netdev Behavior

```text
1. UB platform discovery creates UB entities.
2. ubase binds a UB entity and creates a `.unic` auxiliary device.
3. `unic_init()` registers notifiers and the auxiliary driver.
4. `unic_probe()` initializes device and debugfs state.
5. Netdev setup maps UB capability and VL information into traffic classes.
6. Netdev open/up enables channels, NAPI, and UBASE completion callbacks.
7. Link status changes wake/stop queues and toggle carrier state.
8. Remove/reset disables channels, unregisters debugfs, and uninitializes device state.
```

Failure/debug focus:

- Auxiliary device did not appear: check UBASE probe and `.unic` creation.
- Netdev exists but no carrier: check UNIC link-status path and UB link state.
- Queue setup failure: check capability/VL parsing and real TX/RX queue count.
- Packet path issues: trace `unic_tx.c`, `unic_rx.c`, and completion callback.

### Workflow B: CDMA User Command

```text
1. ubase creates a `.cdma` auxiliary device.
2. `cdma_probe()` creates CDMA device state and `/dev/cdma/dev`.
3. User opens the char device.
4. User sends `CDMA_SYNC` with `cdma_ioctl_hdr`.
5. `cdma_ioctl()` validates device state and copies the command header.
6. `cdma_cmd_parse()` selects a handler from `g_cdma_cmd_handler`.
7. Handler creates/query/deletes context, CTP, queue, JFS, JFC, JFCE, or Segment.
8. Handler copies output back to user.
9. Mmap maps JFC page or Jetty DSQE page when requested.
```

Failure/debug focus:

- `/dev/cdma/dev` missing: check `.cdma` auxiliary device and `cdma_create_chardev()`.
- Context failure: check SVA mode, KSVA/SVA feature enablement, and `ummu_get_tid()`.
- Segment failure: check `cdma_umem_get()`, grant path, token, and SVA range.
- JFS/JFC failure: check queue binding and event object lifetime.

### Workflow C: URPC/UMQ Over UB

```text
1. App initializes URPC and/or UMQ.
2. URPC creates a channel.
3. Server starts control-plane listener.
4. Client attaches to server and exchanges capabilities.
5. App creates UMQ queues.
6. URPC adds queues to the channel and pairs local/remote queues.
7. UMQ UB backend uses URMA Jetty/JFC operations for data and flow control.
8. App enqueues/dequeues buffers or issues RPC calls.
9. Completion path polls JFCs and maps CRs back to UMQ buffers.
10. Teardown unpairs queues, detaches server, destroys channel, destroys queues.
```

Failure/debug focus:

- Attach failure: control-plane socket/connectivity/version/capability mismatch.
- Queue pairing failure: local/remote queue handles or channel state mismatch.
- Data-path failure: URMA JFC polling status, Jetty receive reposting, or flow control.
- Performance issue: UMQ polling mode, interrupt mode, batch size, flow-control credit.

### Workflow D: UMS Socket Compatibility

```text
1. Kernel loads UMS module.
2. UMS registers AF_SMC protocol family and TCP ULP `ums`.
3. Existing app is launched through `ums_run`.
4. `libums-preload.so` intercepts `socket()`.
5. TCP stream sockets for AF_INET/AF_INET6 are rewritten to AF_SMC.
6. Kernel UMS creates a socket and an internal TCP socket for CLC/fallback.
7. UMS connection manager negotiates UB capability.
8. Data moves through UMS/ubcore paths when UB is available, or fallback behavior applies.
9. `ums_admin show` can inspect link group, link, connection, and buffer state.
```

Failure/debug focus:

- App still opens TCP sockets: check `LD_PRELOAD` and `UMS_DEBUG`/preload behavior.
- `AF_SMC` unsupported: check UMS module load and protocol registration.
- `ums_admin` says module not loaded: generic netlink DFX family was not registered.
- Connection falls back: trace CLC handshake, UB capability, peer support, and token/buffer setup.

## What Still Needs Deeper Refinement

This pass gives source-grounded architecture coverage. The next refinement round
should be more line-by-line:

1. UNIC TX/RX path:
   - Trace `ndo_open`, `ndo_start_xmit`, RX completion, NAPI poll, and link event
     flow.
   - Map VLAN/QoS/VL behavior to the UB base spec.
2. CDMA ABI and clients:
   - Build an ABI table for every `cdma_abi.h` structure.
   - Search and document every in-tree `cdma_api.h` client.
   - Compare CDMA CTP/JFS/JFC to UDMA TP/JFS/JFC object semantics.
3. URPC control plane:
   - Trace `urpc_channel_server_attach()` through serialization, Unix control
     socket handling, capability exchange, queue add, and queue pair.
   - Document provider and symbol resolution for URMA usage.
4. UMQ transports:
   - Compare `umq_ipc`, `umq_ub`, and `umq_ubmm` implementation paths.
   - Map buffer ownership, shared memory, and remote memory-segment access.
5. UMS data path:
   - Trace `cm`, `llc`, `cdc`, RMB/send buffer registration, token handling, and
     fallback decisions.
   - Compare code to UB Service Core Socket-over-UB, HCOM, and RoUB concepts.
6. Tools:
   - Add command examples and expected output templates for `urma_admin`,
     `urpc_admin`, `ums_admin`, `ums_run`, `urma_ping`, and perftests.
   - Confirm whether the user means a vendor tool named `ubtool` outside these
     local repos.

## Bottom Line

After this pass, the docs cover all requested names, but at different depths:

- Deep: `liburma`, URMA, UDMA, UMMU, UVS/topology.
- Solid architecture and workflow coverage: UNIC, CDMA, URPC/UMQ, UMS/USOCK,
  discovered tools.
- Explicitly not found: `ubtool` by that name in the local UMDK/openEuler
  source trees.

The largest remaining technical risk is not missing component names anymore. It
is source depth: CDMA, UNIC, URPC, and UMS each deserve their own line-level
deep dive if they become debugging or implementation targets.
