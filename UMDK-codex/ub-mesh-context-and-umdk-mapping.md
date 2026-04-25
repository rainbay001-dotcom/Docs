# UB-Mesh Context and UMDK Mapping

Last updated: 2026-04-25

This document connects the UB-Mesh paper to the local UMDK, URMA, UDMA,
UVS, ubcore, ubagg, and UMMU source trees. It uses three evidence levels:

- Paper claim: stated by the UB-Mesh paper.
- Source evidence: visible in the local UMDK or kernel source.
- Inference: a likely architectural connection, but not directly proven by the
  source in this checkout.

## Primary Reference

- Title: `UB-Mesh: a Hierarchically Localized nD-FullMesh Datacenter Network Architecture`
- arXiv: `2503.20377`
- DOI: `10.48550/arXiv.2503.20377`
- Observed version: v3, revised 2025-05-17
- Abstract page: `https://arxiv.org/abs/2503.20377`
- PDF: `https://arxiv.org/pdf/2503.20377`

The paper positions UB-Mesh as an AI datacenter network architecture for LLM
training. Its main architectural move is replacing symmetric node-to-node
datacenter bandwidth with a hierarchically localized `nD-FullMesh` topology
that spends more direct bandwidth near the traffic source and less on long-range
fabric. The paper says its concrete UB-Mesh-Pod design is based on a
`4D-FullMesh` topology and uses NPUs, CPUs, low-radix switches, high-radix
switches, NICs, and Unified Bus links.

## Why This Matters for UMDK

UMDK should not be read as a generic RDMA clone. From the source and the paper
together, the better interpretation is:

```text
LLM traffic locality
  -> UB-Mesh topology and routing design
  -> Unified Bus as the common interconnect
  -> UMDK/URMA as the user API and provider framework
  -> UVS/ubagg/ubcore as topology and device control
  -> UDMA as the provider/hardware binding
  -> UMMU as the memory-domain and token/TID enforcement layer
```

That does not mean every paper mechanism is implemented in the public source.
The local source proves that topology, aggregation, path-set selection, UB
device registration, and memory-domain mechanics are software-visible. The
paper-level APR, LRS/HRS behavior, and some failure-recovery machinery may live
in firmware, hardware, management software, or private components not present
in this checkout.

## Paper Concepts

| Paper concept | Meaning in the paper | Local source relationship |
| --- | --- | --- |
| `nD-FullMesh` | Recursively localized full-mesh topology across dimensions. | Source exposes `1D-fullmesh` and Clos topology values, but not a complete nD topology builder. |
| `UB-Mesh-Pod` | Concrete physical design based on `4D-FullMesh`. | No complete pod constructor was found locally; likely management/hardware context. |
| Unified Bus | Common interconnect for CPU, NPU, NIC, and switch roles. | Kernel exposes a UB bus, UB entities, ubcore devices, and UDMA provider registration. |
| LRS/HRS | Low-radix and high-radix switch building blocks. | Names are not directly visible in the checked source; may map to hardware/topology entities or external management. |
| APR | All-Path-Routing for direct-link utilization and failure handling. | Local source has route/path-set APIs, but APR itself is not named in this checkout. |
| Resource pooling | Flexible use of CPU/NPU/DDR/IO resources over UB. | Source-visible pieces include topology maps, aggregate devices, UMMU TID/token mapping, and ubagg/bond paths. |
| 64+1 backup | Rack-level extra NPU for high availability. | No direct software object named `64+1` was found locally. Runtime topology output is needed. |
| Topology-aware collectives | Collective communication aligned with network locality. | CAM tiling code contains `level0:fullmesh` collective hints for AllToAll, BatchWrite, and MultiPut. |
| CCU | Collective Communication Unit in UB IO controller. | Not directly named in the checked UMDK/kernel source; CAM hints may be the closest visible user-space signal. |

## Source Mapping

| UB-Mesh concern | Source anchor | What it proves |
| --- | --- | --- |
| Topology type model | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/include/uvs_api.h:77` | UVS defines `UVS_TOPO_TYPE_FULLMESH_1D` and `UVS_TOPO_TYPE_CLOS`. |
| User topology node | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/include/uvs_api.h:118` | `struct urma_topo_node` carries type, super-node ID, node ID, current-node marker, links, and aggregate devices. |
| Kernel topology node | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.h:59` | ubcore mirrors the topology node model and documents `0:1D-fullmesh, 1: Clos topology with parallel planes`. |
| Path-set model | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.h:98` | ubcore stores topology type, source/destination nodes, chip/die counts, path count, and paths. |
| Topology set API | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/tpsa_api.c:134` | `uvs_set_topo_info` validates topology node size and calls the internal setter. |
| Topology propagation | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/tpsa_api.c:96` | UVS sends topology into both ubagg and ubcore. |
| ubagg topology ioctl | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/uvs_ubagg_ioctl.c:125` | User space opens the ubagg device and sends `UVS_UBAGG_CMD_SET_TOPO_INFO`. |
| ubcore topology ioctl | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/uvs_ubagg_ioctl.c:181` | User space opens the ubcore device and sends topology through the UVS ubcore TLV path. |
| Kernel ubcore map update | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_uvs_cmd.c:256` | ubcore validates topology input, creates or updates the global topology map, shows it, and creates Jetty resources. |
| Kernel ubagg map update | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubagg/ubagg_ioctl.c:1469` | ubagg validates topology input and creates or updates its topology map. |
| Path-set selection | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:1157` | ubcore resolves source and destination aggregate EIDs into path sets with special handling for fullmesh and Clos-like cases. |
| Bond provider topology load | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/bondp_provider_ops.c:179` | The liburma bond provider fetches topology through user control and builds a local topology map. |
| Admin visibility | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_admin/admin_cmd_show.c:1246` | `urma_admin show topo` retrieves and prints topology. |
| Ping helper visibility | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/tools/urma_ping/ping_run.c:58` | `urma_ping` uses `uvs_get_topo_info` for EID/topology behavior. |
| CAM fullmesh collective hint | `/Users/ray/Documents/Repo/ub-stack/umdk/src/cam/comm_operator/ascend_kernels/moe_dispatch_normal/op_host/moe_dispatch_normal_tiling.cpp:514` | MoE dispatch uses `AlltoAll=level0:fullmesh;level1:pairwise`. |
| CAM BatchWrite fullmesh hint | `/Users/ray/Documents/Repo/ub-stack/umdk/src/cam/comm_operator/ascend_kernels/notify_dispatch_a2/op_host/notify_dispatch_tiling_a2.cpp:189` | Notify dispatch configures `BatchWrite=level0:fullmesh`. |
| CAM MultiPut fullmesh hint | `/Users/ray/Documents/Repo/ub-stack/umdk/src/cam/comm_operator/ascend_kernels/moe_combine_normal_a2/op_host/moe_distribute_combine_a2_tiling.cpp:292` | MoE combine uses `MultiPut=level0:fullmesh`. |

## Topology Control Flow

```text
management plane or MXE topology data
  -> uvs_set_topo_info()
  -> uvs_ubagg_ioctl_set_topo()
  -> kernel ubagg topology map
  -> uvs_ubcore_ioctl_set_topo()
  -> kernel ubcore topology map
  -> ubcore_create_jetty_rsrc()
  -> ubcore_get_path_set()
  -> liburma bond provider topology map
  -> provider path or aggregate-device selection
  -> JFS/Jetty operation
```

Important source-derived details:

- The UVS API comment says topology comes from the `MXE module`.
- The topology is sent to both ubagg and ubcore; this implies split
  responsibility between aggregate-device handling and ubcore path/resource
  management.
- The ubcore topology command creates Jetty resources after setting topology,
  which links topology configuration to transport-resource availability.
- The bond provider falls back to a general mode when topology retrieval fails,
  which means topology improves behavior but is not the only possible path.

## UMMU Connection

The UB-Mesh paper emphasizes hardware resource pooling and UB peer-to-peer
communication. The source-visible mechanism that makes this safe on the
software side is UMMU integration:

```text
URMA Segment intent
  -> ubcore segment validation
  -> UDMA provider segment registration
  -> token_id/TID selection
  -> UMMU SVA/KSVA grant or MATT/MAPT mapping
  -> bounded remote UB memory access
```

This is not equivalent to saying that UMMU is "the UB-Mesh router." It is the
memory-domain enforcement layer that lets UB-style direct access be controlled
when topology and resource pooling expose more resources across the fabric.

Relevant source anchors:

- `udma_alloc_dev_tid`: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c:905`
- `udma_alloc_ucontext`: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_ctx.c:92`
- `udma_alloc_tid`: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_tid.c:82`
- `udma_register_seg`: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_segment.c:212`

## Comparison Implications

| Axis | Ethernet Clos | InfiniBand/RoCE | UB-Mesh plus UMDK |
| --- | --- | --- | --- |
| Topology assumption | Symmetric fabric, usually oversubscription/non-oversubscription choices. | RDMA fabric, often subnet or Ethernet-control-plane dependent. | Hierarchically localized fullmesh plus selective switch usage. |
| Traffic target | General datacenter traffic. | HPC/storage/AI RDMA data paths. | LLM training traffic with locality-heavy collectives. |
| Software object model | NIC, netdev, sockets, DPDK, offloads. | HCA, verbs device, QP, CQ, MR, lkey/rkey. | UB entity, ubcore device, Jetty, JFS/JFR/JFC, Segment, token/TID. |
| Memory model | Packet payload ownership; no native remote memory semantic. | Memory registration and keys. | UB memory semantics with UMMU token/TID mapping. |
| Topology visibility | Usually routing/control plane external to application API. | Fabric and route details may be visible through RDMA stack/tools. | UVS, ubcore, ubagg, bond provider, `urma_admin show topo`. |
| Collective fit | Implemented by libraries over the network. | Implemented by collective libraries over RDMA. | CAM/CC-style hints show explicit `fullmesh` awareness in local code. |

## What Is Still Not Proven by Local Source

The following items are paper-supported but not directly proven in this checkout:

- How `nD-FullMesh` and `4D-FullMesh` are generated from deployment data.
- Whether APR tables are programmed by local kernel code, firmware, management
  plane, or hardware microcode.
- Whether LRS and HRS appear as UB entities at runtime.
- Whether CCU is configured by CAM, compiler/runtime components outside UMDK,
  or hardware firmware.
- How the paper's 64+1 backup policy is represented in runtime topology.

These should be resolved with runtime captures and, if available, management
plane or firmware documentation.
