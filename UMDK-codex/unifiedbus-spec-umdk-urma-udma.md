# UnifiedBus Spec Deep Dive for UMDK, URMA, and UDMA

Last updated: 2026-04-25

This note is a spec-side reading of how UnifiedBus defines the pieces that UMDK,
URMA, and UDMA implement. It focuses on the local full Chinese UB base
specification and the local English/Chinese OS reference design, then compares
the resulting model with Ethernet, InfiniBand RDMA, and RoCE.

## Source Set

Local specification documents:

| Source | Local path | Use in this note |
| --- | --- | --- |
| UB Base Specification 2.0, full Chinese PDF | `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-zh.pdf` | Authoritative protocol stack, transaction layer, functional layer, UBoE, Ethernet interop |
| UB Base Specification 2.0, English preview PDF | `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-preview-en.pdf` and `/Users/ray/UnifiedBus-docs-2.0/UB-Base-Specification-2.0-preview-en.pdf` | Public preview cross-check, not sufficient alone |
| UB Software Reference Design for OS 2.0, English PDF | `/Users/ray/UnifiedBus-docs-2.0/UB-Software-Reference-Design-for-OS-2.0-en.pdf` | UMDK and URMA software architecture |
| UB Software Reference Design for OS 2.0, Chinese PDF | `/Users/ray/Documents/docs/unifiedbus/UB-Software-Reference-Design-for-OS-2.0-zh.pdf` | Chinese cross-check of UMDK/URMA wording |
| UB Service Core SW Architecture RD 2.0, English PDF | `/Users/ray/UnifiedBus-docs-2.0/UB-Service-Core-SW-Arch-RD-2.0-en.pdf` | Higher-level service position for URMA, RoUB, sockets, and HCOM |

Public web references used for comparison:

| Source | Link | Use |
| --- | --- | --- |
| IANA Service Name and Port Number Registry | https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=4792 | Confirms `unified-bus` TCP/UDP port 4792 |
| IANA ARP Parameters | https://www.iana.org/assignments/arp-parameters/arp-parameters.xhtml | Confirms ARP hardware type 38 for Unified Bus |
| IEEE 802.3-2022 standard page | https://standards.ieee.org/ieee/802.3/10422/ | Ethernet scope and MAC/PHY baseline |
| IEEE 802.3bd/PFC page | https://1.ieee802.org/dcb/802-3bd/ | Data Center Bridging priority flow control context |
| NVIDIA RDMA-aware programming guide | https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/RDMA-Aware%2BProgramming%2BOverview | Verbs/QP/RDMA programming model comparison |
| NVIDIA InfiniBand overview | https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/InfiniBand | InfiniBand fabric and native RDMA comparison |
| NVIDIA RoCE documentation | https://docs.nvidia.com/networking/display/MLNXENv23100550/RDMA%2Bover%2BConverged%2BEthernet%2B%28RoCE%29 | RoCEv1/RoCEv2 encapsulation and UDP port 4791 comparison |

Extracted local text used during analysis:

```text
/tmp/unifiedbus-text/UB-Base-Specification-2.0-zh.txt
/tmp/unifiedbus-text/UB-Software-Reference-Design-for-OS-2.0-en.txt
/tmp/unifiedbus-text/UB-Software-Reference-Design-for-OS-2.0-zh.txt
/tmp/unifiedbus-text/UB-Service-Core-SW-Arch-RD-2.0-en.txt
```

## Executive Findings

UnifiedBus is specified as a memory/message/management fabric, not as a narrow
Ethernet replacement and not simply as "RDMA over Ethernet." The base spec
defines a complete stack from physical link through transaction semantics. URMA
is then defined in the function layer as the asynchronous programming model that
uses the transaction layer. UMDK is the OS/software implementation package that
exposes this model to applications. UDMA is the device/provider implementation
that lets liburma and the kernel execute URMA operations on concrete UB hardware.

The spec hierarchy is:

```text
UB physical/data-link/network/transport layers
  -> provide link reliability, routing, multipath, congestion control, and TP services
UB transaction layer
  -> defines memory, message, maintenance, and management transaction operations
UB function layer
  -> defines Load/Store synchronous access and URMA asynchronous access
UB OS reference design
  -> maps URMA into UMDK/liburma/uburma/ubcore/UDMA drivers
UMDK source
  -> implements northbound URMA APIs and southbound provider APIs
UDMA provider
  -> implements hardware-specific queues, doorbells, contexts, memory registration,
     transport-path control, and completion handling
```

The most important distinction from classic RDMA is that UB has a transaction
layer below URMA. URMA submits work using Jetty resources, but the protocol
semantics underneath are UB transactions: Write, Read, Atomic, Send,
maintenance, and management, with explicit transaction service modes. This gives
the spec room to place ordering and reliability responsibilities at the
Initiator, Target, lower transport layer, or nowhere, depending on the operation.

The most important distinction from Ethernet is that Ethernet primarily defines
MAC/PHY framing and operation, while UB defines a compute fabric with endpoint
identity, partitioning, memory addressing, access tokens, transaction semantics,
transport channels, and management. UB can interoperate with Ethernet through
UBoE and UB2E, but Ethernet is a possible carrier/interconnect domain, not the
semantic core.

The most important distinction from RoCEv2 is that RoCEv2 carries InfiniBand
transport over UDP/IP/Ethernet using UDP destination port 4791; UBoE carries UB
transaction/transport semantics over Ethernet/IP using the IANA registered
`unified-bus` TCP/UDP port 4792. The shape is similar at the encapsulation
level, but the payload semantics and software model are different.

## What UB Is

The UB base spec defines these primary objects:

| UB object | Meaning for UMDK/URMA/UDMA |
| --- | --- |
| UBPU | Processing unit that supports the UB stack. Can be CPU, NPU, GPU, DPU, switch-like component, or another UB-capable device class depending on implementation. |
| UB Controller | UBPU component that executes the UB protocol stack and exposes software/hardware interfaces. This is the protocol execution point that UDMA ultimately drives. |
| UMMU | Memory translation and permission-checking unit. This is essential for Segment registration/import and Token validation. |
| UB Switch | Optional packet-forwarding component inside a UBPU. Enables fabric routing. |
| UB Link | Point-to-point connection between UBPU ports. |
| UB Domain | Set of UBPU devices connected by UB Links. |
| UB Fabric | UB Switch and UB Link collection inside a UB Domain. |
| UBoE | UB over Ethernet/IP, used to carry UB transactions across Ethernet/IP networks and across UB Domains. |
| UBFM | UB Domain manager responsible for resource, interconnect, and communication management. |

From a UMDK viewpoint, the defining claims are:

- UB normalizes operations into memory access, message passing, procedure call,
  and resource management.
- UB treats different UBPUs as peer participants rather than assuming a
  CPU-centric host/device hierarchy.
- UB allows resources to be pooled at Entity granularity: compute, memory,
  storage, and interconnect resources can be shared and composed.
- UB makes multipath and ordering explicit across the network, transport, and
  transaction layers.
- UB includes reliability and RAS at several layers: physical lane/rate
  fallback, link retry, network multipath, end-to-end transport retry, and
  transaction-level exception handling.

These points explain why UMDK is not merely a communication library. It is the
software face of a larger resource-pooling and heterogeneous-compute fabric.

## UB Protocol Stack as It Relates to URMA

The base spec stack is layered as follows.

### Physical Layer

The physical layer supplies bit transport over SerDes lanes. It supports
customized rates, FEC modes, dynamic FEC mode selection, lane/rate reduction on
fault, lane/rate restoration after recovery, optical link protection, and
asymmetric transmit/receive lane widths.

For URMA/UDMA, the practical implication is that link behavior is more than a
generic Ethernet PHY assumption. A UDMA implementation can rely on UB-specific
link training, lane handling, FEC, and recovery behavior when running over native
UB links.

### Data-Link Layer

The data-link layer is a point-to-point reliable packet service between two UB
ports. The spec defines:

- Flits as the basic data-link unit.
- CRC-based and non-CRC modes.
- Retry Buffer based retransmission.
- GoBackN link retransmission.
- Credit-based flow control.
- Virtual Lanes.
- Init Block negotiation for features such as VL enablement, credit return
  granularity, retry buffer depth, and flow-control cell size.

For URMA/UDMA, this means reliability can be supplied below the UB transport
layer in low-fault or direct-connect scenarios. This is why the transport layer
has CTP and TP Bypass modes in addition to RTP.

This is a major difference from commodity Ethernet. Ethernet has frame check
sequence and optional PAUSE/PFC behavior, but it does not define a native
per-link packet retry protocol comparable to the UB link-layer retry mechanism.
Data Center Bridging can make Ethernet behave closer to lossless for RoCE-style
traffic classes, but that is not the same as UB's native layered reliability
model.

### Network Layer

The network layer provides routing within and across UB Domains. It supports:

- Full IP address formats.
- Short CNA address formats, 16-bit and 24-bit.
- Dynamic or static address management.
- Per-packet and per-flow multipath load balancing.
- Service Level to Virtual Lane mapping.
- Congestion marking.
- Network isolation through NPI.
- ICRC over immutable packet fields.
- Routing Type fields that let upper layers select all reachable paths vs
  shortest-path sets, and per-flow vs per-packet load balancing.

For URMA, this matters because transaction ordering and multipath are tied
together. If the upper layer can tolerate out-of-order transmission, UB can use
per-packet multipath. If the operation needs lower-layer ordering, it can select
per-flow routing or rely on RTP sequencing.

The spec's network header has several formats:

| Address format | Role |
| --- | --- |
| IP address format | Domain-internal or cross-domain operation using IPv4/IPv6 style addressing. |
| 16-bit CNA | Compact network address for Domain-internal packets. |
| 24-bit CNA | Larger compact network address for Domain-internal packets. |

For IP-carried UB stack traffic, the base spec sets the UDP destination port to
4792, matching IANA's `unified-bus` registration.

### Transport Layer

The UB transport layer sits between network and transaction layers. It defines
Transport Endpoints, TP Packets, TP Channels, and TP Channel Groups.

Transport modes:

| Mode | Spec role | URMA implication |
| --- | --- | --- |
| RTP, Reliable Transport | End-to-end reliable transport with packet sequence numbers, acknowledgements, retransmission, TP Channel load balancing, and congestion control. | Strongest fit for reliable multi-hop paths and shared transport channels. |
| CTP, Compact Transport | Reliability is jointly provided with lower layers; no heavy end-to-end retransmission in the described implementation. | Good for high-quality direct-connect or low-fault environments where link reliability is enough. |
| UTP, Unreliable Transport | Connectionless, best effort, no retransmission. | Useful for loss-tolerant or setup/control cases, not for reliable memory operations. |
| TP Bypass | No transport-layer service; transaction layer calls network service directly. | Lower overhead, mainly paired with Load/Store synchronous access and local/near paths. |

RTP reliability is based on PSN, receiver-side packet classification, and
TPACK/TPNAK/TPSACK responses. It also allows transaction responses and
transaction error status to be piggybacked in transport acknowledgements. That
piggybacking is important: it lets the transport and transaction layers
cooperate instead of acting as opaque layers.

RTP multipath support is explicit. A pair of UBPUs can use multiple TP Channels,
grouped into a TPG, and traffic can be distributed by policy. The spec also
allows per-packet load balancing through fields such as UDP source port in IP/UDP
format or LBF in CNA format. Because per-packet multipath can reorder packets,
RTP supports out-of-order receive windows and retransmission policy tuning.

Congestion control is also defined at this layer. The base spec includes window
or rate control concepts and optional algorithms/mechanisms such as LDCP,
CNP/DCQCN-style feedback, and switch-side active queue management style marking.

### Transaction Layer

The transaction layer is the bridge between the UB transport and URMA's
programming model. It exposes four transaction classes:

| Transaction class | Examples | URMA/UMDK mapping |
| --- | --- | --- |
| Memory transactions | Write, Write_with_notify, Write_with_be, Writeback, Read, Atomic | One-sided URMA read/write/atomic work requests; Load/Store memory access |
| Message transactions | Send, Send_with_immediate | Two-sided URMA send/receive |
| Maintenance transactions | Prefetch_tgt and state/cache maintenance operations | Memory pooling/cache/maintenance semantics |
| Management transactions | Configuration, resource management, fault and device management | UBFM/ubcore/control paths |

The transaction layer defines four service modes:

| Mode | Expanded meaning | Ordering/reliability placement |
| --- | --- | --- |
| ROI | Reliable and Ordered by Initiator | Initiator waits for ordered predecessor transactions before issuing dependent work. Packets may still use multipath. |
| ROT | Reliable and Ordered by Target | Target maintains ordering state, avoiding a full initiator-side RTT wait at the cost of target resources. |
| ROL | Reliable and Ordered by Lower layer | Lower layers such as RTP TP Channel ordering deliver the order guarantee. |
| UNO | Unreliable and Non-Ordering | No reliability or ordering guarantee. |

This is one of the deepest spec differences from classic RDMA verbs. Verbs
developers often reason in terms of QP transport type, QP ordering, and CQ
completion. UB makes transaction service mode a first-class part of the protocol
composition, and the spec gives rules for pairing transaction modes with
transport and network behavior.

Examples:

- ROI/ROT with RTP can use TPG or multiple TP Channels and can choose per-flow
  or per-packet network load balancing.
- ROL with RTP can still use network paths that reorder packets, because the
  transport receiver can restore order for a TP Channel.
- ROL with CTP or TP Bypass requires per-flow/single-path behavior when ordered
  execution is required, because those modes do not have the same transport
  ordering machinery.
- UNO can use CTP, UTP, or TP Bypass and can use per-flow or per-packet routing.

### Function Layer

The function layer defines programming models above transactions:

- Load/Store synchronous access.
- URMA asynchronous access.
- Higher-level features such as URPC, multi-Entity cooperation, and Entity
  management.

For Load/Store, the UB Controller converts processor or accelerator memory
operations into transaction operations such as Read, Write, and Atomic. For URMA,
applications use Jetty interfaces to establish communication relationships,
submit operations, and query completion.

This is the spec layer that directly defines URMA as a programming model. UMDK
then implements this model in software.

## How URMA Is Defined by the Spec

URMA is defined as asynchronous access using Jetty as the basic communication
unit. The base spec and OS reference design line up on the same conceptual
model:

```text
Application
  -> creates or imports Jetty resources
  -> registers or imports memory Segments
  -> submits Work Requests to Jetty/SQ resources
  -> UB Controller turns those requests into transaction operations
  -> transaction/transport/network/link layers execute them
  -> completions are reported through JFC/CQ or JFCE/EQ
```

### Memory Segments

A Segment is a contiguous virtual address space mapped to physical memory. The
spec describes a Segment using EID, TokenID, UBA, and size. Multiple Segments
can share a TokenID, or one Segment can have multiple TokenIDs.

Before an Initiator accesses Target memory, it must obtain Segment information.
The Initiator can either map it into its VA space as an MVA for synchronous or
asynchronous access, or use it only through the asynchronous model. If the Target
requires protection, the Initiator carries TokenValue information so the Target
can validate access through UMMU/security mechanisms.

UMDK mapping:

| Spec concept | UMDK/liburma concept |
| --- | --- |
| Segment creation/registration | `urma_register_seg` |
| Remote Segment use | `urma_import_seg` |
| Segment access credential | TokenValue/TokenID in Segment exchange/import |
| Target address | UBA and remote Segment address fields |
| UMMU translation/protection | kernel UMMU/ubcore/UDMA registration paths |

### Jetty

The base spec defines Jetty as the basic URMA communication unit above the
transaction layer. A developer uses Jetty to issue transaction operations. Jetty
creation and import establish the necessary local and remote resources.

Jetty types:

| Type | Meaning |
| --- | --- |
| Standard Jetty | Can send transaction requests and receive transaction responses; identified by a Jetty ID; binds SQ and RQ. |
| One-sided Jetty | Simplified Jetty for one-way use. JFS binds SQ, JFR binds RQ. Initiator JFS can access Target memory without the Target creating a JFR for that one-sided memory access case. |
| Jetty Group | Target-side group of Jetties or JFRs with one group ID and RQ Group dispatch. Supports CPU-bypass request distribution, NUMA-affine dispatch, round robin, hash by hint, or RQ-depth balancing. |

The spec allows both many-to-many and one-to-one Jetty communication models:

- Many-to-many: an Initiator Jetty can send to arbitrary Target Jetties, and a
  Target Jetty can receive from arbitrary Initiators. This reduces Jetty count
  and avoids wasting endpoint resources.
- One-to-one: Initiator and Target Jetties are bound, closer to a traditional
  connection-like endpoint pairing.

Jetty state machine:

| State | Meaning |
| --- | --- |
| Reset | Newly created or reset; resources allocated; packets may be dropped and work requests rejected. |
| Ready | Link/relationship negotiated; requests and packets execute normally. |
| Suspend | Recoverable fault handling state, depending on exception mode. |
| Error | Jetty stops SQ scheduling and packet receive until reset/recovery. |

UMDK mapping:

| Spec concept | UMDK/liburma concept |
| --- | --- |
| Standard Jetty | `urma_create_jetty`, `urma_import_jetty`, Jetty send/recv operations |
| JFS | `urma_create_jfs`, `urma_post_jfs_wr`, `urma_post_jetty_send_wr` paths |
| JFR | `urma_create_jfr`, `urma_post_jfr_wr`, `urma_post_jetty_recv_wr` paths |
| JFC | `urma_create_jfc`, `urma_poll_jfc` |
| JFCE | `urma_create_jfce`, `urma_rearm_jfc`, `urma_wait_jfc` |
| JFAE | async event APIs and provider event paths |

### Transaction Queues

The spec defines transaction queues as the software/hardware media used to carry
asynchronous work:

| Queue | Role | UMDK analog |
| --- | --- | --- |
| SQ | Send Queue. Holds user-submitted transaction requests, each as SQE. | JFS/Jetty send path and UDMA SQ/WQE. |
| RQ | Receive Queue. Holds receive-side contexts as RQE. | JFR/Jetty receive path and UDMA RQ. |
| CQ | Completion Queue. Holds completed transaction records as CQE. | JFC and `urma_poll_jfc`. |
| EQ | Event Queue. Holds event notifications. | JFCE/JFAE and event-driven completion/error handling. |

The spec's FIFO queue model is the basis for ordering: same queue can provide
order constraints, while different queues have no implied ordering relationship.

### Access Security

URMA access control is built around credentials:

- Target Jetty TCID and TokenValue.
- Segment TokenID and TokenValue.
- Optional translation through a UB Decoder result.

The Target validates credentials before allowing message or memory access. This
maps directly to the UMDK Segment and Jetty token exchange described in the OS
reference design. The management plane assigns TokenValue; applications exchange
it through a secure side channel; the Initiator configures it during import; the
hardware carries it in data-plane requests.

This is analogous in spirit to RDMA remote keys, but the UB model is tied to
Entity identity, Segment/Jetty objects, UPI/NPI partitioning, and UMMU checks.

### Communication Management

The base spec does not force one connection-manager protocol for all URMA use.
It allows:

- UBFM-mediated exchange.
- Well-known Jetty exchange.
- TCP/IP exchange.
- Other extended exchange methods.

Reserved well-known Jetty IDs include:

| Jetty ID | Purpose |
| --- | --- |
| 0 | Exchange transport-layer information. |
| 1 | Exchange transaction-layer information. |
| 2 | Socket over UB. |
| 3-31 | Reserved. |
| 32-1023 | User-defined. |

This flexibility explains the UMDK sample pattern: the sample can exchange
Segment/Jetty data over TCP even though the eventual data path is URMA/UDMA.

### URMA Operation Flow

The base spec's URMA flow:

1. Obtain EID and create a URMA context.
2. Create Jetty, JFC, JFCE, and related resources under that context.
3. Establish communication relationships by importing remote Jetty and Segment
   information.
4. Bind transaction queues and choose transaction service mode.
5. Submit transaction requests through Jetty to SQ.
6. UB Controller schedules SQ elements and converts them into one or more
   transaction operations.
7. Transaction layer executes memory/message/maintenance operations over the
   chosen lower-layer service.
8. Completion information is written to CQ; exceptions may generate EQ events.
9. Application polls JFC or waits on JFCE to observe completion.

The OS reference design recasts the same flow for UMDK:

1. Create Jetty resources.
2. Create/register/import Segments.
3. Issue two-sided, one-sided, or atomic operations.
4. Read completion records.

## How UMDK Is Defined by the OS Reference Design

The base spec defines URMA as a programming model but does not define UMDK as a
source tree. The OS reference design supplies that software mapping.

UMDK is described as a distributed communication software library that provides
high-performance inter-card communication interfaces in data center networks,
SuperPoD environments, and servers. It is explicitly intended to expose UB
hardware capability to applications.

The UMDK functional architecture includes:

| Component | Spec/reference role | Local source mapping |
| --- | --- | --- |
| `liburma` | User-space communication library for Jetty, Segment, and data-plane APIs. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma` |
| `uburma` | User/kernel message bridge. | `/Users/ray/Documents/Repo/ub-stack/kernel-ub/drivers/ub/urma/uburma` |
| `ubcore` | Kernel URMA core for connection setup, Jetty/Segment allocation, state management. | `/Users/ray/Documents/Repo/ub-stack/kernel-ub/drivers/ub/urma/ubcore` |
| UDMA driver | Kernel-space device driver from hardware vendor. | `/Users/ray/Documents/Repo/ub-stack/kernel-ub/drivers/ub/hw/hns3`; newer `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma` |
| User UDMA driver | User-space provider that plugs into UMDK. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/hw/udma` |
| `urma_admin` | Device/resource query and configuration tool. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin` |
| `liburpc`/`kurpc` | RPC semantic communication interfaces. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urpc` and kernel-side support |
| UMS | Socket compatibility. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock` |

The OS reference makes an important API split:

- Northbound APIs: application-facing communication APIs.
- Southbound APIs: provider-facing APIs that let hardware/device drivers attach
  to UMDK.

This is why the local UMDK tree has both `urma_api.h` and `urma_provider.h`.
`liburma` exposes user APIs, while UDMA implements the provider callbacks.

## How UDMA Is Defined

UDMA is not defined in the base spec as a standalone protocol layer. The base
spec defines the UB layers and URMA programming model. The OS reference and
source tree define UDMA as the hardware/provider implementation of URMA over UB
hardware.

The local UMDK UDMA README describes UDMA as UnifiedBus Direct Memory Access.
Its role is to implement URMA programming APIs on top of UnifiedBus hardware.
The provider has two halves:

| UDMA half | Local source | Role |
| --- | --- | --- |
| User UDMA driver, `liburma-udma` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/hw/udma` | User-space provider loaded by liburma; implements provider ops, queues, doorbells, WQE posting, CQ polling, Segment import/register, TP control. |
| Kernel UDMA driver, `udma.ko` or HNS3 UDMA | `/Users/ray/Documents/Repo/ub-stack/kernel-ub/drivers/ub/hw/hns3` and `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma` | Hardware resource allocation, mmap, UMMU integration, queue/context creation, ubcore ops, device registration. |

The user-space provider implements a `provider_ops` table named `udma` and an
operation table for URMA objects. Those callbacks are the implementation of the
OS reference's southbound API. The provider does not redefine URMA semantics; it
maps them to UDMA hardware queue formats and control operations.

UDMA's spec position can be summarized as:

```text
URMA is the programming model.
UMDK/liburma is the user-space API implementation.
UDMA is a provider implementation for UB DMA hardware.
UB transaction/transport/network/link layers are the protocol substrate.
UMMU is the address-translation and access-check substrate.
```

Therefore, when asking "what does the spec define for UDMA?", the answer is
split:

- The base spec defines what UDMA must ultimately realize: URMA Jetty/Segment
  operations converted into UB transactions, with correct reliability, ordering,
  routing, access control, and completion behavior.
- The OS reference design defines where UDMA attaches: user and kernel drivers
  integrate with UMDK, liburma, uburma, and ubcore.
- The source code defines the concrete ABI and device behavior: context mmap,
  doorbells, JFC/JFS/JFR/Jetty allocation, WQE posting, CQ polling, Segment
  registration, import, TP control, and provider-private user control.

## UB Compared with Ethernet

Ethernet, as specified by IEEE 802.3, defines Ethernet LAN/access/metropolitan
operation across selected speeds, using a common MAC and PHY model. It is a
frame transport technology. Modern switched full-duplex Ethernet is the dominant
data center link/network substrate, but by itself it does not define memory
registration, remote memory access, transaction modes, or queue-pair semantics.

UB is broader and more semantically rich:

| Area | Ethernet | UnifiedBus |
| --- | --- | --- |
| Main scope | MAC/PHY frame transmission and management. | Compute fabric stack from physical link through transactions and function models. |
| Reliability | FCS detects corruption. Loss recovery normally belongs above Ethernet; DCB/PFC can reduce congestion loss for selected classes. | Link-layer CRC/FEC-triggered retry, credit flow control, transport retry, transaction error handling. |
| Flow control | Ethernet PAUSE/PFC are optional network features; PFC is priority-based and deployed in DCB domains. | Credit-based data-link flow control and VLs are part of native UB link behavior. |
| Addressing | MAC addresses plus higher-layer IP. | IP or compact CNA network addressing; Entity identity through EID; UPI/NPI partitioning. |
| Semantics | Frame delivery. | Memory, message, maintenance, and management transactions. |
| Multipath | ECMP/LAG at Ethernet/IP layers; application transport often unaware. | Per-flow/per-packet routing selected with RT/LBF/source port and coordinated with transaction ordering modes. |
| Memory access | None by itself. | Built-in memory transaction model and UMMU translation/protection. |
| UMDK relevance | Can carry UBoE packets, or interoperate through UB2E. | Native semantic substrate for URMA/UDMA. |

The base spec explicitly includes Ethernet interop:

- UBPU can directly access Ethernet/IP networks through UBoE.
- UB2E Switch can translate UB link layer to Ethernet link layer while
  preserving IP and above.
- UB2E can map NPI to VLAN ID.
- UB2E can translate UB FECN and Ethernet ECN congestion marks.
- UBoE packets carry UB transaction and transport layers over Ethernet.
- Jumbo frames should be enabled on Ethernet devices to avoid packet drops due
  to maximum frame size.

This means Ethernet is a compatible interconnect environment for UB, but UB's
semantic model remains UB.

## UB Compared with InfiniBand RDMA

InfiniBand is a native RDMA fabric specified by IBTA. NVIDIA's programming guide
summarizes it as a high-speed, low-latency, low-CPU-overhead interconnect with
native RDMA and I/O channel semantics. The verbs programming model is built
around resources such as device context, protection domain, memory region,
completion queue, and queue pair.

Conceptual similarities:

| InfiniBand/RDMA concept | UB/URMA concept | Similarity |
| --- | --- | --- |
| Queue Pair | Jetty, JFS/JFR, transaction queues | Work is posted to queues and completions are polled or evented. |
| Completion Queue | JFC/CQ | Completed operations are reported separately from submission. |
| Memory Region | Segment | Local memory is registered and remote access credentials are exchanged. |
| Remote key/R_Key | TokenID/TokenValue plus UMMU checks | Remote access requires a credential. |
| RDMA read/write | URMA one-sided read/write | Local side can move data without remote application involvement. |
| Send/receive | URMA two-sided Send/Recv | Both sides participate in message semantics. |
| Atomic verbs | URMA atomic operations | Remote atomic update/read behavior. |
| Subnet/partition concepts | UB Domain, UPI, NPI | Fabric partitioning and isolation exist in both, though mechanisms differ. |

Key differences:

| Area | InfiniBand/RDMA | UB/URMA |
| --- | --- | --- |
| Fabric semantic base | RDMA verbs and IB transport semantics. | UB transaction layer with memory/message/maintenance/management transaction classes. |
| Endpoint model | QP is central; RC QPs are connection-oriented and paired. | Jetty supports one-to-one and many-to-many communication; URMA is described as app-level connectionless because it reuses UB transport-layer reliable service. |
| Ordering placement | Often reasoned through QP transport type and QP ordering. | Explicit transaction service modes: ROI, ROT, ROL, UNO. |
| Multipath | Fabric/path features exist, but verbs API normally abstracts them differently. | Network RT/LBF, transport TP Channel/TPG, and transaction ordering modes are designed to compose. |
| Heterogeneous peer model | Strong server/storage/HCA history. | Spec is explicitly peer UBPU-oriented across CPU/GPU/NPU/DPU-like units. |
| Synchronous Load/Store | Not the normal verbs programming model. | UB function layer defines both Load/Store synchronous access and URMA asynchronous access over the same transaction substrate. |
| Procedure-call layer | Not a base RDMA primitive. | URPC is specified as a higher-level function model over Load/Store or URMA. |

The most useful mental mapping is:

```text
RDMA verbs QP/CQ/MR model
  roughly maps to
URMA Jetty/JFC/Segment model

InfiniBand transport/RoCE transport
  roughly maps to
UB RTP/CTP/UTP/TP Bypass plus transaction service modes
```

But this mapping is approximate. UB's transaction layer is first-class and is
not just a different naming scheme for IB transport.

## UB/UBoE Compared with RoCE

RoCE is RDMA over Converged Ethernet. RoCEv1 uses a dedicated Ethernet
Ethertype. RoCEv2 carries RDMA transport over UDP/IP and uses UDP destination
port 4791. It keeps the InfiniBand/RDMA programming model while changing the
wire carriage to Ethernet/IP.

UBoE is UB over Ethernet. The UB base spec says UBoE carries UB transactions
through Ethernet/IP networks and can route across UB Domains. The spec uses UDP
destination port 4792 for UB stack traffic, and IANA registers `unified-bus`
TCP/UDP port 4792 as IP Routable Unified Bus.

Comparison:

| Area | RoCEv2 | UBoE |
| --- | --- | --- |
| IANA UDP port | 4791, `roce`, IP Routable RoCE. | 4792, `unified-bus`, IP Routable Unified Bus. |
| Payload semantics | InfiniBand/RDMA transport packet over UDP/IP. | UB transport/transaction packet over Ethernet/IP. |
| Application API | RDMA verbs / RDMA CM ecosystem. | UMDK/liburma URMA APIs, plus service-layer compatibility such as RoUB and sockets. |
| Network dependency | Ethernet/IP with DCB/PFC/ECN often used for loss-sensitive operation. | Ethernet/IP as UBoE carrier, with UB-defined network headers/extensions, NPI, congestion mark conversion, and UB transaction semantics. |
| ECMP/load balancing | UDP source port can act as flow identifier. | UB spec also uses UDP source port in IP/UDP format or LBF in CNA format as load-balance factors. |
| Interop goal | Make RDMA work on Ethernet/IP networks. | Let UB Domains and UB transaction semantics cross Ethernet/IP and interoperate with Ethernet infrastructure. |

The key similarity is encapsulation shape: both use UDP/IP to make a low-latency
memory-fabric protocol routable in IP networks. The key difference is semantic
identity: RoCEv2 remains RDMA/IB transport; UBoE remains UB transport and
transaction semantics.

## UB Service Core and RoUB Position

The UB Service Core reference helps place compatibility layers around UMDK:

- UBS Comm includes HCOM, Socket-over-UB, HCAL, and RoUB.
- HCOM can abstract RDMA, TCP, URMA, and shared memory under one communication
  framework.
- Socket-over-UB provides socket compatibility without sending the data plane
  through the normal TCP/IP stack.
- RoUB exposes RDMA Verbs semantics over UB, allowing traditional RDMA
  applications to migrate to UB networks.

This is important for comparison work. RoUB is not the same as URMA. RoUB is a
compatibility layer for RDMA verbs semantics. URMA is the UB-native asynchronous
memory/message programming model that UMDK implements directly.

## Spec-to-Implementation Mapping

| Spec definition | UMDK component | User-space implementation | Kernel/provider implementation |
| --- | --- | --- | --- |
| URMA context | liburma context | `urma_create_context` in `src/urma/lib/urma/core/urma_main.c` | uburma create context command; ubcore alloc context; UDMA context/mmap path |
| Device/EID discovery | liburma device list | `urma_get_device_by_name`, sysfs scan in `urma_device.c` | ubcore sysfs and EID/device attributes |
| Jetty | Jetty API | `urma_create_jetty`, `urma_import_jetty` | `ubcore_create_jetty`, UDMA/HNS3 create jetty callbacks |
| JFS/JFR | Send/receive resources | `urma_create_jfs`, `urma_create_jfr`, post APIs | UDMA queue allocation and WQE/RQE handling |
| JFC/JFCE | Completion/event resources | `urma_create_jfc`, `urma_poll_jfc`, `urma_rearm_jfc`, `urma_wait_jfc` | UDMA completion queue and event queue handling |
| Segment | Memory registration/import | `urma_register_seg`, `urma_import_seg` | ubcore segment, UMMU map/check, UDMA segment callbacks |
| Transaction operation | Work Request opcode | `urma_post_jetty_send_wr`, `urma_post_jetty_recv_wr`, `urma_post_jfs_wr` | Provider WQE format and doorbell posting |
| TP Channel/TPG | Transport path support | UVS/TPSA and UDMA TP control queue paths | ubcore TP and UDMA/HNS3 TP callbacks |
| Access token | Segment/Jetty token fields | token passed during import/register setup | UMMU/device validation on incoming transaction |
| Async exception | JFAE/event APIs | liburma async/event APIs | provider/hardware async event reporting |

The local UMDK code follows this mapping closely. `liburma` does provider
loading and command dispatch; `src/urma/hw/udma` supplies provider callbacks;
`uburma` dispatches user commands to `ubcore`; and the kernel UDMA/HNS3 driver
implements `ubcore_ops`.

## Packet and Addressing Details That Matter for UMDK

The following spec details are especially relevant when debugging UMDK/URMA/UDMA
behavior:

- UB memory descriptors include EID, TokenID, and UBA. A remote memory bug may
  therefore be an identity issue, an access-token issue, or an address
  translation issue, not merely a pointer issue.
- UPI is an Entity partition identifier. Different UPI partitions cannot
  communicate unless configured accordingly.
- NPI is a network partition identifier for IP-format network isolation.
- EIDH can carry Source EID and Destination EID in long or compact forms.
- UPIH can carry UPI in 32-bit or 16-bit forms.
- IP-format UB packets use UDP destination port 4792 for UB stack traffic.
- CNA-format packets are more compact for Domain-internal communication.
- LPH.CFG values distinguish TCP/IP packets, IP-based UB packets, network
  control packets, CNA-based UB packets, Non-Coherent memory/resource access,
  Coherent memory access, and other categories.
- RTP can carry transaction responses or errors in transport acknowledgements,
  which can affect where an error appears in UMDK.
- Transaction response status includes cases like receiver-not-ready and page
  fault; these are not generic network failures.

## Ordering Model: Why UB Looks Different From RDMA

Classic RDMA users often expect "reliable connected QP means ordered" as the
dominant mental model. UB's spec is more compositional.

Ordering can be achieved by:

1. Initiator-side waiting, ROI.
2. Target-side sequence context, ROT.
3. Lower-layer ordered delivery, ROL.
4. No ordering, UNO.

The choice then constrains network and transport:

- If the transaction can tolerate packet reordering, UB can use per-packet
  multipath and broader path sets.
- If ordering must be preserved by lower layers without RTP sequence recovery,
  network routing should stay per-flow/single-path.
- If RTP is used, lower-layer reordering can be hidden by RTP receiver ordering
  before transaction delivery.
- If CTP or TP Bypass is used, the design relies much more on link reliability
  and routing choices.

For UMDK, this means performance tuning and correctness are coupled. A seemingly
simple choice such as JFS/Jetty service mode can determine whether per-packet
multipath is safe.

## Reliability Model: Layered, Not Single-Point

UB reliability is layered:

| Layer | Reliability contribution |
| --- | --- |
| Physical | FEC, link training, lane/rate fallback and recovery. |
| Data link | CRC/FEC failure detection, retry buffer, GoBackN retransmission, credit flow control. |
| Network | Multipath, congestion marking, ICRC for immutable fields, isolation. |
| Transport | RTP PSN, acknowledgements, retransmission, congestion window/rate control, TPG load balancing. |
| Transaction | Retry on processable exceptions, response status, ordering modes, exception reporting. |
| Function/URMA | JFC/JFCE/JFAE completion and async event handling; Jetty state transitions. |

This layering is why UDMA debugging should avoid assuming that all failures are
equivalent to Ethernet packet loss or RDMA CQ errors. The failure may have been
handled or transformed at a lower layer before liburma sees it.

## Deadlock and Memory Pooling Details

The base spec spends notable space on deadlock avoidance for memory and message
operations. The core issue is that UB can pool memory and let UBPUs play both
memory-user and memory-provider roles. This can create circular dependencies
when writeback, page table access, page fault handling, or message receive
resources depend on the same fabric resources being consumed by the original
operation.

Spec mechanisms include:

- Request retry.
- Virtual-channel isolation.
- Distinguishing transaction types.
- Reserving resources.
- Dedicated message-processing resources.
- Returning resource status in transaction responses and letting the Initiator
  retry.
- Timeout and failure handling to release resources.

For UMDK/UDMA, this is relevant to:

- RNR handling on receive queues.
- Page fault and memory migration handling.
- Segment deregistration safety.
- Writeback and maintenance transaction ordering.
- Jetty exception mode and state transitions.

## What the Spec Does Not Fully Define

The public/local spec material does not fully define every UDMA implementation
detail. Important gaps:

- Exact user/kernel private ABI for the current UDMA provider is source-defined,
  not base-spec-defined.
- Doorbell page layout, queue element binary layouts, and provider-private
  hardware control commands are UDMA implementation details.
- TP Channel establishment procedure is intentionally not fully specified in
  the base spec; UVS/TPSA and ubcore/provider code fill in practical behavior.
- Exact branch pairing between the local UMDK source and kernel UDMA/HNS3 source
  still matters before treating an ABI as stable.
- The English public base spec is a preview; the full local Chinese spec should
  remain the authority unless an updated full English release is obtained.

## Practical Debugging Implications

When a URMA/UDMA operation fails, classify it by layer:

| Symptom | Likely layer to inspect |
| --- | --- |
| Device not visible to liburma | sysfs/cdev discovery, ubcore registration, UDMA probe. |
| `create_context` failure | uburma command path, provider context allocation, mmap, UMMU/device caps. |
| Segment registration failure | UMMU map/check, token setup, memory pinning, access flags. |
| Remote access denied | TokenValue/TokenID, UPI/NPI/EID mismatch, Target permission check. |
| Send/recv stuck | JFS/JFR queue state, RQ depth, RNR, JFC polling, Jetty state. |
| One-sided write/read no completion | TP state, transaction response status, JFC/CQ handling, provider doorbell. |
| Performance below expectation | service mode, TP Channel/TPG setup, RT/LBF routing, congestion control, VL/credit behavior. |
| Only Ethernet/IP carriage fails | UBoE port 4792, MTU/jumbo frame, NPI/VLAN mapping, ECN/FECN conversion, UDP source port/load balancing. |

## Current Mental Model

The most accurate compact model is:

```text
Ethernet/RoCE mental model:
  app -> verbs -> QP/MR/CQ -> IB transport -> RoCE UDP/IP/Ethernet

UnifiedBus/URMA mental model:
  app -> UMDK/liburma -> Jetty/Segment/JFC -> UB transaction layer
      -> UB transport mode (RTP/CTP/UTP/Bypass)
      -> UB network mode (IP or CNA, routing, multipath, partitions)
      -> UB link/physical reliability
      -> native UB or UBoE Ethernet/IP carriage
```

UDMA is the concrete provider below liburma that turns the second model into
hardware operations.

## Open Research Threads

- Compare `src/urma/hw/udma/udma_u_abi.h` with the matching kernel UDMA ABI in
  the exact intended branch pairing.
- Trace how UVS/TPSA establishes TP Channels and maps them to the base spec's TP
  Channel and TPG model.
- Map each local UDMA WQE opcode to UB transaction opcodes where the ABI exposes
  enough information.
- Check whether current UMDK exposes all four transaction service modes directly
  or hides some policy behind provider/device attributes.
- Validate UBoE packet behavior with real device counters or packet capture if
  hardware access is available.
- Find the full English base spec if it becomes publicly available; current full
  analysis depends on the local Chinese full spec.
