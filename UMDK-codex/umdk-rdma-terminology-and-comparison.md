# UMDK, URMA, UDMA, Ethernet, InfiniBand, and RDMA Terminology Mapping

Last updated: 2026-04-25

This note maps UnifiedBus/UMDK terms to the closest Ethernet, InfiniBand, RDMA
verbs, and Linux RDMA-core concepts. The mappings are intentionally written as
analogies, not equivalence claims. `Jetty ≈ QP` is useful for orientation, but
Jetty is not a Queue Pair clone; it lives in a UB transaction model with
different ordering, transport, grouping, and access-control semantics.

## Source Anchors

Local UnifiedBus/UMDK sources:

| Source | Local path | Relevance |
| --- | --- | --- |
| UB Base Specification 2.0 full Chinese PDF | `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-zh.pdf` | Defines UB protocol stack, transaction layer, function-layer URMA, UBoE, UPI/EID, Segment, Jetty, JFC/JFCE/JFAE |
| UB OS Software Reference Design 2.0 English PDF | `/Users/ray/UnifiedBus-docs-2.0/UB-Software-Reference-Design-for-OS-2.0-en.pdf` | Defines UMDK functional architecture and URMA module/usage model |
| UMDK source | `/Users/ray/Documents/Repo/ub-stack/umdk` | User-space liburma, provider ABI, UDMA user provider |
| Paired UB kernel tree | `/Users/ray/Documents/Repo/ub-stack/kernel-ub` | Older paired ubcore, uburma, HNS3 UDMA kernel implementation |
| Newer openEuler kernel | `/Users/ray/Documents/Repo/kernel` | Newer `drivers/ub/urma/hw/udma` and Linux RDMA core comparison headers |

Local code anchors:

| Concept family | Local anchor |
| --- | --- |
| User URMA types | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_types.h` |
| User URMA APIs | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_api.h` |
| Provider API | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_provider.h` |
| UDMA user provider ops | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/hw/udma/udma_u_ops.c` |
| Kernel UB core types | `/Users/ray/Documents/Repo/kernel/include/ub/urma/ubcore_types.h` |
| Newer kernel UDMA implementation | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma` |
| Linux RDMA core types | `/Users/ray/Documents/Repo/kernel/include/rdma/ib_verbs.h` |

External reference anchors:

| Source | Link | Relevance |
| --- | --- | --- |
| IEEE 802.3-2022 | https://standards.ieee.org/ieee/802.3/10422/ | Ethernet MAC/PHY scope |
| NVIDIA RDMA-aware programming guide | https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/RDMA-Aware%2BProgramming%2BOverview | RDMA verbs, QP, RDMA read/write/atomic baseline |
| NVIDIA InfiniBand overview | https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/InfiniBand | InfiniBand as native RDMA fabric |
| NVIDIA RoCE documentation | https://docs.nvidia.com/networking/display/MLNXENv23100550/RDMA%2Bover%2BConverged%2BEthernet%2B%28RoCE%29 | RoCEv1/RoCEv2 encapsulation, UDP 4791 |
| IANA service registry | https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=4792 | `unified-bus` TCP/UDP port 4792 |
| IANA ARP parameters | https://www.iana.org/assignments/arp-parameters/arp-parameters.xhtml | Unified Bus ARP hardware type 38 |

## Mapping Rules

The mapping strength column uses:

| Strength | Meaning |
| --- | --- |
| Strong | The concept fills almost the same role in the programming or implementation model. |
| Partial | Useful analogy, but important semantics differ. |
| Weak | Only helps at a high level; do not use for API or protocol reasoning. |
| None | No direct equivalent; the concept is UB-specific or RDMA/Ethernet-specific. |

The most common mistake is mapping names one-to-one too aggressively. The safer
mental model is:

```text
Linux RDMA / verbs:
  ib_device -> ib_ucontext / ibv_context -> PD -> MR, QP, CQ -> WR/WC

UMDK / URMA:
  ubcore_device / urma_device -> urma_context -> Segment, JFS/JFR/JFC/Jetty
      -> Work Request / Completion Record

UnifiedBus protocol:
  UB Entity/EID/UPI/NPI/UMMU -> transaction layer -> transport/network/link layers
```

## Quick Mapping Table

| UB/UMDK/URMA/UDMA term | Closest Ethernet/IB/RDMA term | Strength | Why the analogy helps | Where it breaks |
| --- | --- | --- | --- | --- |
| UB | InfiniBand fabric plus Ethernet/IP interop plus transaction fabric | Partial | UB is a fabric/protocol stack for low-latency peer communication and memory semantics. | UB also defines a transaction layer, Load/Store access, URMA, URPC, UMMU, and resource pooling beyond Ethernet or verbs. |
| UB Link | Ethernet link or IB link | Partial | Point-to-point physical/link connection between ports. | UB link has native credit flow control, retry, VL, lane/rate fallback, and UB-specific framing. |
| UB Domain | IB subnet or managed Ethernet fabric/domain | Partial | Scope of connected devices and routing/management. | UB Domain is built around UBPU, UB Link, UB Fabric, UBFM, UPI/NPI, and resource pooling. |
| UB Fabric | IB fabric or switched Ethernet fabric | Partial | Collection of switches/links for packet forwarding. | UB fabric is part of a compute/memory fabric with UB transactions. |
| UBPU | HCA/NIC/device endpoint plus processing element | Partial | It is a participant in the fabric. | UBPU is broader: CPU/GPU/NPU/DPU/switch-like units can be peers with compute, memory, storage, and function roles. |
| UB Controller | NIC/HCA device function | Partial | Executes protocol stack and exposes software/hardware interface. | UB Controller can translate Load/Store into UB transactions and participate in memory/resource pooling. |
| UMMU | IOMMU plus RDMA memory translation/protection | Partial | Performs address translation and access checks for remote memory. | UMMU is defined as a UBPU component and participates in UB memory descriptors, UBA, TokenID/TokenValue, and pooled memory. |
| UB Entity | RDMA endpoint/function, VF, or process-visible endpoint | Partial | It is the communication identity/resource allocation unit. | Entity semantics are UB-specific and tied to EID, UPI, resource pooling, and management. |
| EID | GID/LID/IP address/endpoint ID | Partial | Identifies a UB Entity for communication. | EID is not just a network address; it is an Entity identity used with UPI, UMMU, and transaction semantics. |
| UEID | User-visible EID | Partial | User/entity identity for software-visible communication. | No exact verbs equivalent. |
| UPI | IB P_Key, VLAN, tenant/partition ID | Partial | Provides partition/isolation semantics. | UPI is checked by UB hardware for Entity partition access and does not participate in switch forwarding in the same way as VLAN/IP routing. |
| NPI | VRF/VLAN/VNI-like network partition | Partial | Isolates network-level traffic. | NPI is UB network-layer isolation, distinct from Entity partition UPI. |
| CNA | Compact LID-like address | Partial | Short network address for Domain-local forwarding. | CNA is UB-specific and coexists with IP-format addressing. |
| UBoE | RoCEv2-like UDP/IP carriage | Partial | Carries fabric semantics over Ethernet/IP. | RoCEv2 carries IB/RDMA transport on UDP 4791; UBoE carries UB transaction/transport on TCP/UDP 4792. |
| UMDK | rdma-core/libibverbs plus provider libraries, with UB-native APIs | Partial | User-space package with communication APIs and providers. | UMDK exposes URMA, URPC, CAM, ULOCK, USOCK; it is not a libibverbs replacement alone. |
| URMA | RDMA verbs-like async memory/message API | Strong conceptually | Provides one-sided read/write, two-sided send/recv, atomic operations, completions. | URMA is defined over UB transactions and Jetty resources, not QP/PD/MR semantics. |
| UDMA | RDMA hardware provider/driver, like mlx5/qedr/rxe provider role | Strong implementation role | Implements provider ops, queues, doorbells, memory registration, CQ polling. | UDMA implements UB/URMA provider semantics, not IB verbs semantics. |
| liburma | libibverbs-like user library | Strong implementation role | Loads providers, exposes user APIs, calls provider ops/ioctls. | API names, object model, and transaction service modes differ. |
| uburma | uverbs-like kernel/user bridge | Strong implementation role | Character-device/ioctl bridge from user space into kernel UB core. | UB command set is for URMA/Jetty/Segment/TP, not verbs/uverbs commands. |
| ubcore | Linux RDMA core / ib_core-like kernel core | Strong implementation role | Owns shared kernel abstractions and dispatches to hardware provider ops. | UB objects and protocol semantics differ from RDMA core. |
| `ubcore_device` | `ib_device` | Strong implementation role | Kernel object representing a UB/URMA-capable device. | Device attributes include UB-specific transport, EID, UPI, Jetty, Segment, TP, and UMMU concepts. |
| `ubcore_ops` | `ib_device_ops` | Strong implementation role | Provider callback table registered by hardware driver. | Callback set is UB object oriented: JFS/JFR/JFC/Jetty/Segment/TP/user_ctl. |
| `urma_device_t` | `ibv_device` | Strong user role | User-visible device discovered before context creation. | Discovery path and attributes are UB-specific. |
| `urma_context_t` | `ibv_context` | Strong user role | User process context tied to an opened device/provider. | No mandatory PD object sits between context and objects in the same way as verbs. |
| Protection Domain | No exact direct URMA object | None/Weak | Some isolation is covered by context, token, UPI, and UMMU. | URMA does not expose a PD object as the central grouping object in the local API. |
| Segment | Memory Region (`MR`) | Strong conceptually | Registered memory exposed for local/remote access. | Segment uses UB memory descriptor, UBA, TokenID/TokenValue, UMMU semantics. |
| Target Segment | Remote MR handle / remote memory descriptor | Strong conceptually | Imported remote memory used for one-sided operations. | Import carries UB EID/UBA/token semantics, not just raddr/rkey. |
| UBA | Remote address / IOVA | Partial | Address used by UB transactions to access memory. | UBA belongs to UB memory descriptor semantics, not generic virtual address alone. |
| TokenID/TokenValue | R_Key/L_Key-like access credential | Partial | Protects remote memory or Jetty access. | UB token model is tied to Segment/Jetty and Target validation; not identical to verbs keys. |
| Jetty | Queue Pair (`QP`) | Partial/Strong orientation | Main communication object used to submit/receive work and establish relationships. | Jetty can be standard, one-sided, or grouped; can support M:N communication; transaction service modes are explicit. |
| Standard Jetty | QP with send and receive queues | Partial | Has send/receive roles and Jetty ID. | Target/Initiator mapping and import/bind model differs from QP state machine. |
| JFS | Send Queue (`SQ`) or send-side WQ | Strong | Jetty For Sending carries outgoing work requests. | It can exist as a one-sided Jetty object and may not require a remote receive object for memory operations. |
| JFR | Receive Queue (`RQ`) or receive-side WQ | Strong | Jetty For Receiving carries posted receive buffers. | It is a named URMA object, not merely a hidden queue inside a QP. |
| JFC | Completion Queue (`CQ`) | Strong | Completion records are polled from JFC. | Completion record format and association with Jetty/JFS/JFR are URMA-specific. |
| JFCE | Completion channel / CQ event channel | Strong | Event/interrupt path for completion notification. | Event semantics use URMA rearm/wait APIs. |
| JFAE | Async event channel | Partial | Receives async/error events. | UB Jetty/driver/hardware async events differ from verbs async events. |
| Jetty Group | SRQ/RSS/indirection group/thread dispatch group | Weak/Partial | Groups target-side receive resources and can distribute requests. | UB Jetty Group is a target-side Jetty/RQ Group mechanism with CPU-bypass dispatch and policies such as hint hash, round robin, or RQ-depth balance. |
| TP Channel | RDMA connection path / transport channel | Partial | End-to-end transport context for reliable transport. | Can be shared across Initiator/Target pairs and grouped in TPG. |
| TPG | Multipath transport group | Weak/Partial | Groups transport channels for load balancing. | No direct verbs object; it is UB transport-layer machinery. |
| ROI/ROT/ROL/UNO | QP transport/ordering policy | Weak/Partial | Describes reliability and ordering behavior. | UB transaction service modes place ordering at Initiator, Target, lower layer, or nowhere. Verbs transport types do not map one-to-one. |
| Work Request (`urma_jfs_wr_t`, `urma_jfr_wr_t`) | `ibv_send_wr`, `ibv_recv_wr` | Strong | Posted work descriptors. | Opcodes and target fields carry UB Segment/Jetty/transaction metadata. |
| Completion Record (`urma_cr_t`) | Work Completion (`ibv_wc`) | Strong | Reports operation completion/status. | Fields encode URMA completion and token/immediate data semantics. |
| `urma_poll_jfc` | `ibv_poll_cq` | Strong | Polls completion queue. | Poll target is JFC; completion record format differs. |
| `urma_rearm_jfc`/`urma_wait_jfc` | `ibv_req_notify_cq`/`ibv_get_cq_event` | Strong conceptually | Enables event-driven completion. | Exact wakeup/rearm semantics differ. |
| `urma_post_jetty_send_wr` | `ibv_post_send` | Strong conceptually | Posts send-side work. | Target may be Jetty or Segment, and transaction service mode matters. |
| `urma_post_jetty_recv_wr` | `ibv_post_recv` | Strong conceptually | Posts receive-side buffers. | Receive object is JFR/Jetty rather than QP RQ only. |

## Kernel Object Mapping

The Linux RDMA kernel stack centers on `struct ib_device`, `struct ib_device_ops`,
`struct ib_qp`, `struct ib_cq`, `struct ib_mr`, `struct ib_pd`, and
`struct ib_ucontext` in `include/rdma/ib_verbs.h`.

The UB kernel stack centers on `struct ubcore_device`, `struct ubcore_ops`,
`struct ubcore_jetty`, `struct ubcore_jfs`, `struct ubcore_jfr`,
`struct ubcore_jfc`, `struct ubcore_target_seg`, and `struct ubcore_ucontext`
in `include/ub/urma/ubcore_types.h`.

| Linux RDMA core | UB kernel core | Strength | Notes |
| --- | --- | --- | --- |
| `struct ib_device` | `struct ubcore_device` | Strong | Device abstraction registered by provider. |
| `struct ib_device_ops` | `struct ubcore_ops` | Strong | Provider callback table. |
| `struct ib_ucontext` | `struct ubcore_ucontext` | Strong | Per-user process/device context. |
| `struct ib_qp` | `struct ubcore_jetty`, plus `ubcore_jfs`/`ubcore_jfr` | Partial | Jetty is the closest endpoint object, but JFS/JFR can be separate objects. |
| `struct ib_cq` | `struct ubcore_jfc` | Strong | Completion queue abstraction. |
| `struct ib_mr` | `struct ubcore_target_seg` / Segment objects | Partial/Strong | Both represent registered/imported memory, but UB Segment has UBA/token/EID semantics. |
| `struct ib_pd` | No direct ubcore object seen in local API | None/Weak | UB uses context, token, Entity/UPI, and UMMU mechanisms instead of a verbs-style PD centerpiece. |
| `ib_post_send` provider op | `post_jfs_wr`, `post_jetty_send_wr` in provider ops | Strong conceptually | Submit outgoing work. |
| `ib_post_recv` provider op | `post_jfr_wr`, `post_jetty_recv_wr` in provider ops | Strong conceptually | Submit receive buffers. |
| `poll_cq` provider op | `poll_jfc` provider op | Strong | Poll completions. |
| `reg_user_mr` provider op | `register_seg` provider op | Strong conceptually | Register memory with device/translation layer. |
| `query_device`, `query_port` | `query_device_attr`, EID/TP/IP helpers | Partial | UB device attributes include different capability families. |

Implementation shape:

```text
Linux RDMA:
  hardware driver
    -> registers ib_device + ib_device_ops
    -> ib_core / uverbs
    -> libibverbs provider
    -> application

UnifiedBus/URMA:
  UDMA/HNS3 kernel driver
    -> registers ubcore_device + ubcore_ops
    -> ubcore / uburma
    -> liburma provider, such as liburma-udma
    -> application
```

## User-Space API Mapping

| RDMA verbs operation | URMA operation | Strength | Notes |
| --- | --- | --- | --- |
| `ibv_get_device_list` | URMA device discovery/list APIs and `urma_get_device_by_name` | Partial | URMA also reads UB sysfs/cdev data such as `/sys/class/ubcore` and `/dev/uburma`. |
| `ibv_open_device` | `urma_create_context` | Strong | Creates user context for a device. |
| `ibv_query_device` | `urma_query_device` | Strong | Query capabilities. |
| `ibv_alloc_pd` | No direct PD equivalent | None/Weak | URMA examples create context then JFC/JFS/JFR/Jetty/Segment directly. |
| `ibv_reg_mr` | `urma_register_seg` | Strong conceptually | Register local memory for device/remote use. |
| Exchange `raddr`/`rkey` | Exchange Segment info: EID, UASID, VA/UBA, length, flags, token | Strong conceptually | Payload differs; UB needs Entity and token metadata. |
| `ibv_create_cq` | `urma_create_jfc` | Strong | Completion queue. |
| `ibv_create_comp_channel` | `urma_create_jfce` | Strong conceptually | Event-driven completion support. |
| `ibv_create_qp` | `urma_create_jetty`, or separate `urma_create_jfs`/`urma_create_jfr` | Partial | URMA can model standard Jetty, one-sided JFS/JFR, and Jetty Group. |
| RDMA CM route/connection setup | UBFM, well-known Jetty, TCP side channel, UVS/TPSA, import/bind APIs | Partial | UB allows multiple exchange methods and app-level connectionless URMA over shared UB transport services. |
| `ibv_modify_qp` | `urma_modify_jetty`, `urma_bind_jetty`, provider TP operations | Partial | State and binding model differ. |
| `ibv_post_send` with RDMA write/read/send/atomic | `urma_post_jfs_wr` or `urma_post_jetty_send_wr` | Strong conceptually | URMA work requests map to UB transaction operations. |
| `ibv_post_recv` | `urma_post_jfr_wr` or `urma_post_jetty_recv_wr` | Strong conceptually | Receive-side buffers for two-sided messages. |
| `ibv_poll_cq` | `urma_poll_jfc` | Strong | Polls completion records. |
| `ibv_req_notify_cq` / `ibv_get_cq_event` | `urma_rearm_jfc` / `urma_wait_jfc` | Strong conceptually | Event path differs in API shape. |
| `ibv_dereg_mr` | `urma_unregister_seg` / `urma_unimport_seg` | Strong conceptually | Local vs remote Segment cleanup. |
| `ibv_destroy_qp` | `urma_delete_jetty`, `urma_delete_jfs`, `urma_delete_jfr` | Partial | Object split differs. |

## Interface Model Comparison

| Axis | Ethernet sockets/netdev | InfiniBand/RDMA verbs | RoCE | UMDK/URMA/UDMA |
| --- | --- | --- | --- | --- |
| Common application API | BSD sockets, send/recv, TCP/UDP | libibverbs, RDMA CM, higher protocols like MPI/NVMe-oF | Same verbs/RDMA CM model, Ethernet/IP carriage | liburma URMA APIs; compatibility via USOCK/UMS, RoUB, HCOM |
| Kernel surface | netdev, socket stack, qdisc, NAPI, ethtool | `ib_core`, `uverbs`, RDMA CM, provider drivers | RDMA core plus Ethernet netdev/GID integration | `ubcore`, `uburma`, UDMA/HNS3 provider, UMMU/UBASE dependencies |
| User-space provider model | Usually not provider-based for sockets | libibverbs provider libraries | libibverbs provider libraries | liburma provider libraries, e.g. `liburma-udma` |
| Endpoint object | socket | QP | QP | Jetty, JFS/JFR, Jetty Group |
| Memory registration | Not part of socket API | MR with keys | MR with keys | Segment with UBA/TokenID/TokenValue/EID metadata |
| Completion model | syscall/blocking/epoll/io_uring | CQ/WC polling or event | CQ/WC polling or event | JFC/CR polling or JFCE event |
| Remote CPU involvement | TCP/UDP receive path usually involves kernel/remote stack | One-sided operations bypass remote CPU after setup | Same RDMA semantics over Ethernet | One-sided URMA operations bypass remote app; UB Controller/UDMA execute transactions |
| Compatibility path | Native | Native for RDMA apps | Native for RDMA apps over Ethernet | RoUB for verbs apps, UMS/USOCK for sockets, native URMA for UB apps |

## Spec Perspective

### Ethernet

IEEE 802.3 defines Ethernet LAN/access/metropolitan operation for selected
speeds using a common MAC and PHY model. It defines frame transmission,
half/full duplex operation, physical media interfaces, and management
information. It does not define remote memory registration, one-sided reads,
one-sided writes, atomics, completion queues, or queue pairs.

For RDMA-like behavior on Ethernet, the ecosystem adds layers:

- RoCEv1 or RoCEv2 to carry RDMA semantics.
- Data Center Bridging/PFC/ECN/DCQCN-style mechanisms to reduce or react to
  loss/congestion for sensitive traffic classes.
- NIC offloads and RDMA-core providers.

Ethernet by itself is a carrier. RDMA over Ethernet is an added semantic layer.

### InfiniBand and RDMA

InfiniBand is a native RDMA fabric. The verbs model exposes device, context,
protection domain, memory region, queue pair, completion queue, work request,
and work completion objects. The programming guide summarizes QP as the mechanism
used to set up RDMA communication with the remote host, after which verbs can
issue RDMA read/write/atomic and send/receive operations.

Spec-level RDMA terms are centered around:

- Registered memory and access keys.
- QP transport type and QP state.
- Work queues and completion queues.
- Fabric addressing/path management.
- Reliable vs unreliable transports.

### RoCE

RoCE keeps the RDMA/InfiniBand transport semantics but changes the wire carriage:

- RoCEv1 uses a dedicated Ethernet Ethertype.
- RoCEv2 uses UDP/IP and dedicated UDP port 4791.
- UDP source port can be used as an opaque flow identifier for ECMP.
- Applications continue to use RDMA services transparently because packets are
  generated and consumed below the application.

RoCE is therefore best understood as:

```text
RDMA verbs semantics + IB transport packet semantics + Ethernet/IP carriage
```

### UnifiedBus, URMA, and UMDK

UB defines a full fabric stack:

```text
Physical layer
  -> Data-link layer: Flits, CRC/FEC, retry, credit flow control, VL
  -> Network layer: IP/CNA addressing, routing, multipath, SL/VL, NPI, ICRC
  -> Transport layer: RTP, CTP, UTP, TP Bypass, TP Channel, TPG, PSN, congestion
  -> Transaction layer: memory/message/maintenance/management transactions
  -> Function layer: Load/Store synchronous access, URMA async access, URPC
```

UMDK and URMA sit above this stack:

- URMA is the UB-native async programming model.
- UMDK is the software package that exposes URMA and related libraries.
- UDMA is the provider/hardware implementation that realizes URMA over UB DMA
  hardware.

Spec-level UB differs from RDMA because it exposes a transaction layer with
service modes:

| UB transaction mode | Meaning |
| --- | --- |
| ROI | Reliable and ordered by Initiator. |
| ROT | Reliable and ordered by Target. |
| ROL | Reliable and ordered by lower layer. |
| UNO | Unreliable and non-ordering. |

This is deeper than a QP transport-type choice. It lets the UB stack decide where
ordering responsibility sits and how that composes with multipath routing and
transport behavior.

## Design Perspective

| Design axis | Ethernet | InfiniBand/RDMA | RoCE | UB/UMDK/URMA/UDMA |
| --- | --- | --- | --- | --- |
| Primary goal | Universal packet/frame network. | Low-latency native RDMA fabric. | RDMA semantics on Ethernet/IP infrastructure. | Peer heterogeneous compute/memory/message fabric with resource pooling. |
| Semantic center | Frames and higher-layer protocols. | QP/MR/CQ and RDMA operations. | Same RDMA operations, Ethernet/IP wire. | UB transactions and function-layer models: Load/Store, URMA, URPC. |
| Host/device model | Host networking stack plus NIC. | Host plus HCA/NIC offload. | Host plus RDMA NIC on Ethernet. | Peer UBPUs: CPU, GPU, NPU, DPU, memory/storage/compute providers. |
| Remote memory | Not native. | Native through registered MR and keys. | Native through RDMA over Ethernet. | Native through Segment, UBA, UMMU, tokens, transaction layer. |
| Messages | TCP/UDP/app protocols. | Send/receive verbs. | Send/receive verbs over Ethernet. | Message transactions through Jetty/JFR/JFS. |
| Atomics | Not native at Ethernet layer. | RDMA atomic verbs. | RDMA atomic verbs if supported. | UB Atomic memory transactions through URMA. |
| Procedure calls | Application protocol. | Upper-layer protocol. | Upper-layer protocol. | URPC is a UB-defined higher-level function model. |
| Multipath | LAG/ECMP independent of app semantics. | Fabric/path features, often abstracted. | ECMP via IP/UDP fields. | RT/LBF/source-port routing plus TP Channel/TPG plus transaction ordering modes. |
| Ordering | TCP stream order or app-defined. | QP transport ordering semantics. | Same as RDMA transport semantics. | Explicit ROI/ROT/ROL/UNO transaction service modes. |
| Reliability | TCP or app layer; Ethernet detects corruption. | Reliable transports plus fabric mechanisms. | RDMA reliable transports depend on Ethernet fabric behavior and congestion/loss handling. | Layered: link retry, transport retry, transaction retry/status, completions/events. |
| Isolation | VLAN/VRF/IP policy. | P_Key, PD, QP/MR access keys. | VLAN/DSCP/GID/RDMA keys/PDs. | UPI, NPI, EID, TokenID/TokenValue, UMMU, UBFM. |
| Compatibility | Native for sockets. | Native for verbs apps. | Native for verbs apps on Ethernet. | Native URMA plus RoUB for verbs, UMS/USOCK for sockets, HCOM for abstraction. |

Design conclusion:

```text
Ethernet optimizes universal packet carriage.
InfiniBand optimizes native RDMA fabric semantics.
RoCE optimizes RDMA compatibility over Ethernet/IP.
UnifiedBus optimizes peer heterogeneous compute, memory pooling, and transaction
semantics, with URMA as the async memory/message API.
```

## Implementation Perspective

### Ethernet Implementation

Typical Linux Ethernet data path:

```text
application
  -> socket API
  -> kernel TCP/UDP/IP stack
  -> qdisc/NAPI/netdev driver
  -> NIC
  -> Ethernet frames
```

There are offloads and kernel-bypass alternatives, but the standard API remains
sockets/netdev. Ethernet does not require application memory registration for
remote access.

### Linux RDMA / InfiniBand / RoCE Implementation

Typical Linux RDMA data path:

```text
application
  -> libibverbs / rdma-core provider
  -> uverbs
  -> ib_core
  -> provider driver, such as mlx5/qedr/rxe
  -> HCA/NIC queues, doorbells, CQ, MR, QP
```

RoCE adds Ethernet/IP integration:

- Ethernet netdev association.
- GID table entries derived from IP addresses.
- RoCEv1/RoCEv2 GID types.
- UDP/IP encapsulation for RoCEv2.
- DCB/PFC/ECN/DCQCN configuration in practical deployments.

### UMDK / URMA / UDMA Implementation

Typical local UMDK data path:

```text
application
  -> liburma public API
  -> liburma provider dispatch
  -> liburma-udma provider
  -> /dev/uburma ioctl and mmap paths
  -> uburma user-command bridge
  -> ubcore object/resource layer
  -> UDMA/HNS3 kernel provider callbacks
  -> UMMU/UBASE/UDMA hardware
```

Control-plane object creation:

```text
urma_create_context
  -> provider create_context
  -> uburma create context ioctl
  -> ubcore alloc context
  -> UDMA context allocation, mmap, doorbell setup

urma_create_jfc/jfs/jfr/jetty
  -> provider object callback
  -> uburma command
  -> ubcore_create_*
  -> UDMA/HNS3 queue/context resources

urma_register_seg/import_seg
  -> provider segment callback
  -> ubcore segment path
  -> UMMU map/check and provider memory resources
```

Data-plane work:

```text
urma_post_jetty_send_wr / urma_post_jfs_wr
  -> provider WQE fill
  -> SQ doorbell
  -> hardware converts work into UB transaction operations
  -> completions written to JFC/CQ
  -> urma_poll_jfc reads completion records
```

Implementation conclusion:

| Layer | RDMA/RoCE implementation | UMDK/URMA/UDMA implementation |
| --- | --- | --- |
| User library | libibverbs, provider .so | liburma, provider .so |
| User/kernel ABI | uverbs | uburma |
| Kernel core | ib_core/rdma_core | ubcore |
| Device object | `ib_device` | `ubcore_device` |
| Provider ops | `ib_device_ops` | `ubcore_ops` |
| Endpoint | QP | Jetty/JFS/JFR |
| Completion | CQ | JFC |
| Memory | MR | Segment |
| Hardware provider | mlx5/qedr/rxe/etc. | UDMA/HNS3 UDMA |

## Wire and Encapsulation Perspective

| Wire mode | Ethernet | InfiniBand | RoCEv2 | UnifiedBus native | UBoE |
| --- | --- | --- | --- | --- | --- |
| Carrier | Ethernet PHY/MAC | IB physical/link/fabric | Ethernet/IP/UDP | UB physical/link/network | Ethernet/IP/UDP or TCP registry context |
| Main payload semantics | Higher-layer protocols | IB/RDMA transport | IB/RDMA transport | UB transport + transaction | UB transport + transaction |
| Standard port | Depends on upper protocol | Not UDP/IP | UDP 4791 | Native UB link | `unified-bus` TCP/UDP 4792 |
| Addressing | MAC/IP | LID/GID/path | IP/GID/Ethernet | IP or CNA, EID, UPI/NPI | IP plus UB extension/header semantics |
| ECMP/load balancing | IP/UDP five-tuple, LAG/ECMP | Fabric routing | UDP source port flow-id | RT/LBF, TP Channel/TPG | UDP source port or UB fields |
| Loss/corruption model | FCS detection; recovery above Ethernet or with DCB mechanisms | Fabric/RDMA mechanisms | RDMA transport over Ethernet; practical lossless config often needed | UB link retry + transport/transaction reliability | UB semantics over Ethernet interop |

Important port distinction:

```text
RoCEv2:
  UDP destination port 4791
  carries RDMA/IB transport semantics

UBoE:
  IANA unified-bus TCP/UDP port 4792
  carries UB transaction/transport semantics
```

## Reliability and Congestion Perspective

| Topic | Ethernet | InfiniBand/RDMA | RoCE | UB/URMA |
| --- | --- | --- | --- | --- |
| Link corruption | Ethernet FCS detects frame errors. | IB link/fabric mechanisms. | Ethernet FCS plus RDMA transport assumptions. | UB physical FEC and data-link CRC/FEC-triggered retry. |
| Congestion loss | Ethernet may drop unless configured otherwise. PFC can reduce loss for priority classes. | Fabric designed for loss-sensitive high-performance transport. | DCB/PFC/ECN/DCQCN commonly required in practice. | UB data-link credit flow control, network congestion marks, transport congestion control. |
| End-to-end retry | TCP/app/RDMA layer. | RDMA reliable transport. | RDMA reliable transport over Ethernet/IP. | RTP PSN/ACK/retransmit; transaction retry/status; CTP can rely on lower layers. |
| Completion status | Socket errors or app protocol. | WC status in CQ. | WC status in CQ. | CR status in JFC; async events via JFAE/JFCE; transaction response status can be carried through layers. |
| Resource-not-ready | TCP backpressure or app protocol. | RNR in RDMA transport. | RNR in RDMA transport. | Transaction response can indicate receiver-not-ready or other resource status; Initiator retry policy applies. |

UB's layered reliability is not identical to RDMA reliable connected transport.
RTP provides end-to-end packet reliability, CTP composes with lower-layer
reliability, UTP is unreliable, and TP Bypass skips transport service. Above
that, the transaction layer still has ROI/ROT/ROL/UNO choices.

## Ordering Perspective

| Model | Ethernet/TCP | RDMA verbs | UB/URMA |
| --- | --- | --- | --- |
| Basic ordering object | TCP byte stream or app protocol. | QP/work queue ordering and transport type. | Transaction queue plus transaction service mode. |
| Main ordered endpoint | Socket stream. | QP. | Jetty/JFS/JFR plus SQ/RQ/CQ resources. |
| Multipath and ordering | ECMP can reorder unless transport handles it. TCP hides byte-stream reordering. | Provider/fabric handles based on transport semantics. | UB explicitly coordinates network RT, TP Channel/TPG, and ROI/ROT/ROL/UNO. |
| Out-of-order execution | App/protocol dependent. | Generally constrained by QP/transport semantics. | Explicitly supported where transaction mode allows it; used to avoid head-of-line blocking. |
| Target-side ordering | Not a network-layer concept. | Not exposed as ROT-like service mode. | ROT puts ordering at Target sequence context. |
| Lower-layer ordering | TCP handles order. | Reliable transport handles QP order. | ROL delegates ordering to RTP TP Channel or single-path lower layers. |

This is the biggest conceptual difference between Jetty and QP. A QP analogy
helps the reader understand queues and completions, but UB exposes a richer
ordering-placement model.

## Memory and Access-Control Perspective

| Topic | RDMA verbs | URMA/UB |
| --- | --- | --- |
| Local memory registration | `ibv_reg_mr`, produces lkey/rkey. | `urma_register_seg`, creates Segment and access metadata. |
| Remote memory use | Exchange address and rkey through side channel. | Exchange EID/UASID/Segment address or UBA/length/flags/TokenID/TokenValue through side channel. |
| Protection grouping | PD controls which QPs/MRs interact. | Context, Entity identity, UPI/NPI, TokenID/TokenValue, and UMMU checks provide protection; no obvious PD twin in local API. |
| Remote access credential | R_Key. | TokenID/TokenValue plus Segment/Jetty credentials. |
| Address translation | HCA memory translation. | UMMU and provider/kernel segment paths. |
| Remote memory address | Remote virtual address or IOVA-like address. | UBA and Segment metadata. |
| Deregistration hazard | Outstanding operations using MR must be handled safely. | Spec explicitly warns that Segment deletion must avoid residual UB packets causing inconsistency. |

Practical implication: in URMA debugging, "bad remote key" thinking is too
narrow. The failure can be EID, UASID, UPI, TokenID, TokenValue, Segment
permissions, UMMU mapping, or target Jetty credential related.

## Endpoint and Connection-Management Perspective

| Topic | RDMA verbs / CM | URMA / UB |
| --- | --- |
| Endpoint creation | QP creation under context/PD/CQ. | Jetty, JFS, JFR, JFC, JFCE creation under URMA context. |
| Connection model | RC QP is paired with a remote QP; CM can exchange info. | URMA is described as connectionless at application level because it reuses UB transport-layer reliable services; Jetty can be M:N or 1:1. |
| Side-channel exchange | RDMA CM or app-defined exchange. | UBFM, well-known Jetty, TCP/IP side channel, or extended methods. |
| Remote endpoint import | QP attributes/path/CM state. | `urma_import_jetty`, `urma_bind_jetty`, target Jetty metadata, token. |
| Grouping | SRQ/XRC/RSS-like constructs depending on provider. | Jetty Group is defined in UB for target-side dispatch across Jetty/RQ resources. |
| Transport path | QP path, GID/LID, provider route. | TP Channel/TPG, UVS/TPSA, EID/IP helpers, UB routing modes. |

The local UMDK sample uses TCP to exchange Segment and Jetty info, then uses
URMA/UDMA for the data path. That is conceptually similar to applications that
exchange RDMA QP/MR info over TCP, but the imported metadata is UB-specific.

## Operation Mapping

| Operation family | RDMA verbs | URMA/UMDK | UB transaction layer |
| --- | --- | --- | --- |
| Two-sided send | `IBV_WR_SEND`, `ibv_post_send`; receiver posts `ibv_post_recv` | `URMA_OPC_SEND`, `urma_post_jetty_send_wr`; receiver posts `urma_post_jetty_recv_wr` | Send / Send_with_immediate message transactions |
| One-sided write | `IBV_WR_RDMA_WRITE` | `URMA_OPC_WRITE` | Write / Write_with_notify / Write_with_be memory transactions |
| One-sided read | `IBV_WR_RDMA_READ` | `URMA_OPC_READ` | Read memory transaction |
| Atomic CAS | `IBV_WR_ATOMIC_CMP_AND_SWP` | CAS-style URMA atomic | Atomic_compare_swap |
| Atomic FAA | `IBV_WR_ATOMIC_FETCH_AND_ADD` | FAA-style URMA atomic | Atomic_fetch_add and related atomic transactions |
| Completion polling | `ibv_poll_cq` | `urma_poll_jfc` | CQE/CR generated after transaction completion |
| Event notification | `ibv_req_notify_cq`, completion channel | `urma_rearm_jfc`, `urma_wait_jfc`, JFCE | Event queue mechanism |
| Async error | async event channel | JFAE/async event APIs | Jetty/provider/hardware error events |

## Design Mismatches to Remember

### Jetty is not exactly QP

The mapping `Jetty ≈ QP` is good for onboarding because both are the main
communication object around which posting and completion are organized.

But it breaks in these ways:

- Jetty can be standard, one-sided, or grouped.
- JFS and JFR are first-class URMA objects and can be created independently.
- A JFS can perform one-sided memory access without a remote JFR.
- Many-to-many Jetty communication is explicitly supported to reduce endpoint
  resource count.
- Jetty Group supports target-side hardware/request dispatch policies.
- Transaction service mode is a separate semantic choice.

### Segment is not exactly MR

The mapping `Segment ≈ MR` is strong for memory registration and remote access,
but Segment belongs to UB memory descriptor semantics:

- EID identifies the Entity.
- UBA identifies UB-addressed memory.
- TokenID/TokenValue controls access.
- UMMU performs translation and permission checks.
- UPI/NPI and Entity partitioning may matter.

### UPI is not exactly P_Key or VLAN

UPI is closest to a partition identifier, but it is checked for Entity resource
access and is managed by UBFM. VLAN is a Layer 2 Ethernet tagging mechanism; IB
P_Key is a partition key in the IB fabric. UPI is UB-specific.

### UBoE is not RoCEv2

Both can use UDP/IP over Ethernet and both sit in the low-latency memory fabric
space, but:

- RoCEv2 carries RDMA/IB transport packets on UDP 4791.
- UBoE carries UB transaction/transport semantics on port 4792.
- RoCE preserves verbs semantics.
- UBoE preserves UB semantics.

### UMDK is not only libibverbs with different names

UMDK includes:

- URMA native memory/message operations.
- URPC function-call semantics.
- USOCK/UMS socket compatibility.
- CAM communication acceleration.
- ULOCK distributed lock.
- Provider-facing APIs for UDMA.

libibverbs analogies cover only the URMA/liburma/provider subset.

## Migration and Porting Notes

For a verbs/RDMA developer reading UMDK:

| Familiar habit | UMDK translation | Watch out |
| --- | --- | --- |
| Start from device/context/PD. | Start from URMA device/context. | No direct PD object in the local URMA API. |
| Create CQ and QP. | Create JFC/JFCE plus JFS/JFR/Jetty. | Standard Jetty vs one-sided JFS/JFR matters. |
| Register MR and exchange raddr/rkey. | Register Segment and exchange Segment/Jetty info with token/EID metadata. | TokenID/TokenValue and UBA/EID are not optional details. |
| Use RDMA CM or custom TCP exchange. | Use UBFM, well-known Jetty, TCP, or app exchange. | Local samples use TCP exchange for metadata. |
| Post send/read/write/atomic WRs. | Post Jetty/JFS WRs. | Opcode maps to UB transaction semantics. |
| Poll CQ. | Poll JFC. | Completion record fields differ. |
| Tune QP transport/path. | Tune transaction service mode, TP/TPG, network RT/LBF, device caps. | Ordering/performance tradeoff crosses more layers. |
| Debug CQ errors. | Debug CR status plus async events plus transaction/transport status. | Error may originate at token, UMMU, RNR, page fault, transport, or link layer. |

For an Ethernet/socket developer reading UMDK:

| Familiar habit | UMDK translation | Watch out |
| --- | --- | --- |
| Open socket and send bytes. | Create context/resources and post work requests. | Memory must be registered/imported for one-sided operations. |
| Kernel TCP handles order/retry. | UB service mode and transport mode define order/retry. | Correctness can depend on ROI/ROT/ROL/UNO and RTP/CTP choices. |
| Peer identity is IP/port. | Peer identity includes EID, UPI/NPI, Jetty/Segment info, token. | IP may be only the exchange path or UBoE carrier. |
| Completion is syscall return/readiness. | Completion is JFC/JFCE. | Operation submit success does not mean operation complete. |

## Layered Comparison Summary

| Layer | Ethernet stack | RDMA/IB/RoCE stack | UB/UMDK/URMA/UDMA stack |
| --- | --- | --- | --- |
| Application | socket apps | verbs/RDMA apps, MPI, NVMe-oF, storage | URMA apps, URPC apps, socket-compatible apps through UMS, verbs apps through RoUB |
| User library | libc/socket wrappers | libibverbs, rdma-core providers | liburma, UDMA provider, UMDK components |
| User/kernel bridge | syscalls, netlink, ioctls | uverbs, RDMA CM | uburma, UVS/TPSA ioctls/control |
| Kernel core | net core, TCP/IP, qdisc, NAPI | ib_core, rdma_cm, provider framework | ubcore, UB CM, UMMU/UB support |
| Provider driver | Ethernet NIC driver | mlx5/qedr/rxe/etc. | UDMA/HNS3 UDMA |
| Endpoint | socket/netdev queue | QP | Jetty/JFS/JFR |
| Memory object | normal process buffers | MR/MW | Segment/Target Segment |
| Completion | syscall/epoll/io_uring | CQ/WC | JFC/CR/JFCE |
| Wire | Ethernet frames/IP/TCP/UDP | IB link or RoCE UDP/IP/Ethernet | Native UB or UBoE |
| Protocol semantics | byte streams/datagrams | RDMA read/write/send/atomic | UB transactions, URMA operations, Load/Store, URPC |

## Strongest One-Line Mappings

```text
ubcore_device        ≈ ib_device
ubcore_ops           ≈ ib_device_ops
uburma               ≈ uverbs
ubcore               ≈ ib_core / RDMA core
liburma              ≈ libibverbs
UDMA provider        ≈ RDMA hardware provider
urma_device_t        ≈ ibv_device
urma_context_t       ≈ ibv_context
Jetty                ≈ QP, but broader
JFS                  ≈ SQ / send work queue
JFR                  ≈ RQ / receive work queue
JFC                  ≈ CQ
JFCE                 ≈ completion channel
JFAE                 ≈ async event channel
Segment              ≈ MR
TokenID/TokenValue   ≈ rkey/lkey-like access credential, but UB-specific
EID                  ≈ GID/LID/IP-like endpoint identity, but Entity-scoped
UPI                  ≈ P_Key/VLAN-like partition, but UB-specific
UBoE                 ≈ RoCEv2-like carriage, but UB semantics on 4792
```

## Practical Reading Guide for the Local Code

When reading the local source, use this order:

1. Start with user types in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_types.h`.
2. Read user API declarations in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_api.h`.
3. Read provider dispatch in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_provider.h`.
4. Trace liburma control-plane functions in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/urma_cp_api.c`.
5. Trace data-plane functions in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/urma_dp_api.c`.
6. Read UDMA provider callbacks in
   `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/hw/udma/udma_u_ops.c`.
7. Map those to kernel `ubcore_ops` definitions in
   `/Users/ray/Documents/Repo/kernel/include/ub/urma/ubcore_types.h`.
8. Compare with RDMA core in
   `/Users/ray/Documents/Repo/kernel/include/rdma/ib_verbs.h` only after the UB
   object model is clear.

## Bottom Line

The terminology mapping is useful, but the safest conceptual split is:

```text
Ethernet:
  packet/frame carriage

InfiniBand/RDMA/RoCE:
  registered-memory + QP/CQ + RDMA operation model

UnifiedBus/UMDK/URMA/UDMA:
  UB transaction fabric + Jetty/Segment/JFC programming model + UDMA provider
```

Use RDMA terms to navigate the object model, but use UB spec terms to reason
about correctness, ordering, routing, access control, and performance.

