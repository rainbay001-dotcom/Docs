# UMDK Executive Summary

Last updated: 2026-04-25

This is the short entry point for the UMDK/URMA/UDMA research notes. It
summarizes what the stack is, what local source proves, what is inferred from
the UnifiedBus specifications and UB-Mesh paper, and what still needs runtime
validation on UB hardware.

## One-Screen Model

UnifiedBus, or UB, is a memory-semantics interconnect architecture. In the
local source and spec set, it is not just an Ethernet-like packet network and
not just an InfiniBand/RDMA clone. It defines UB transport, transaction, memory,
management, and URMA programming concepts around EID addressing, Jetty-style
endpoints, Segments, tokens, TIDs, and UMMU protection.

UMDK is the user-space software kit in the checked UMDK repo. It contains
`liburma`, the UDMA user provider, UVS/TPSA, URPC/UMQ, CAM, ULOCK, USOCK/UMS
pieces, examples, and tools.

URMA is the user-facing programming model and API. Applications call URMA APIs
through `liburma`. URMA is the closest conceptual peer to RDMA verbs, but the
object model is UB-specific: `Jetty`, `JFS`, `JFR`, `JFC`, `Segment`,
`token_id`, `TID`, and `EID`.

UDMA is the concrete provider/driver implementation that realizes URMA over UB
hardware. It appears in two halves:

- user space: `u-udma` provider inside UMDK;
- kernel space: k-UDMA driver under the openEuler kernel UB stack.

The main software path is:

```text
application
  -> liburma public API
  -> UDMA user provider
  -> /dev/uburma/<device> ioctl and mmap setup
  -> uburma kernel bridge
  -> ubcore common kernel resource layer
  -> UDMA kernel provider
  -> UMMU / UBASE / UB hardware
```

After context, queue, Segment, and mmap setup, the normal user-space datapath
is intended to bypass per-work-request syscalls:

```text
application
  -> liburma dataplane wrapper
  -> UDMA user provider
  -> user-mapped WQE/CQE buffers
  -> user-mapped doorbell
  -> hardware
```

## Why UB-Mesh Matters

The UB-Mesh paper gives the datacenter-scale reason this stack exists. The
paper describes a localized nD-FullMesh topology for AI clusters, with
topology-aware routing, resource pooling, and collective-communication goals.

The local source does not prove every UB-Mesh paper claim. What it does show is
software support for several pieces that line up with the paper's direction:

- UVS exposes topology APIs and passes topology to ubagg and ubcore.
- ubcore stores topology/path-set data.
- the bond provider and ubagg model aggregate devices and paths.
- CAM code contains fullmesh collective hints.
- UMMU, TID, token, and Segment handling provide the protection model needed
  when memory access crosses devices and resource pools.

The inference is that URMA/UDMA is the application and transport-facing
software layer below topology-aware UB-Mesh operation. The code proves the
local software mechanisms; the paper supplies the broader architecture intent.

## What Local Source Proves

The current local source proves these implementation facts:

- UB device discovery starts below URMA, from firmware UBRT/UBIOS data, UB bus
  enumeration, `ub_entity` objects, and `ubase` binding.
- UBASE creates auxiliary children such as UDMA, UNIC, and CDMA.
- UDMA registers a `ubcore_device` and installs `ubcore_ops`.
- `ubcore` publishes common URMA device/resource state and sysfs attributes.
- `uburma` exposes `/dev/uburma/<device>` and handles user-kernel ioctl/mmap.
- `liburma` discovers `/sys/class/ubcore`, falls back to `/sys/class/uburma`,
  opens `/dev/uburma/<device>`, and dispatches to provider ops.
- The UDMA user provider creates contexts, maps doorbells, formats WQEs, polls
  completions, and sends provider-private data through `liburma` command
  wrappers.
- UMMU/TID/token/Segment paths are visible in the UDMA kernel driver.
- UNIC, CDMA, URPC/UMQ, UMS/USOCK, and discovered tools exist around the native
  URMA/UDMA path, but they are not the same as the normal URMA fast path.

The strongest source-backed docs are:

- [Source evidence map](./08-source-evidence-map.md)
- [Source map](./source-map.md)
- [UMDK component architecture](./umdk-component-architecture.md)
- [URMA/UDMA user-kernel boundary](./urma-udma-user-kernel-boundary.md)
- [End-to-end platform workflow](./end-to-end-platform-workflow.md)

## What Is Spec or Paper Interpretation

The following points are interpreted from the UnifiedBus specs, OS reference
design, and UB-Mesh paper, then mapped back to local source where possible:

- UB is positioned as a memory-semantics interconnect, not merely an Ethernet
  encapsulation.
- URMA is the programming model above UB transaction and transport semantics.
- UMDK is the OS/user-space software realization of that programming model.
- UDMA is a concrete provider implementation under URMA.
- UB-Mesh explains why topology, resource pooling, collective communication,
  UMMU isolation, and direct memory access are central to the design.
- Ethernet, InfiniBand, RoCE, and Linux RDMA verbs are useful comparisons, but
  none is an exact model for UB/URMA/UDMA.

The comparison and terminology details are in:

- [UnifiedBus spec deep dive](./unifiedbus-spec-umdk-urma-udma.md)
- [UMDK/RDMA terminology and comparison](./umdk-rdma-terminology-and-comparison.md)
- [UB-Mesh context and UMDK mapping](./ub-mesh-context-and-umdk-mapping.md)

## Side Components

The native path for application data movement is URMA/UDMA. The adjacent
components fit around it:

- UNIC: UB network-driver side path, exposed as netdev/channel/NAPI behavior.
- CDMA: Crystal DMA path with `/dev/cdma/dev`, CDMA ABI, queue, Segment, and
  UMMU/SVA/TID behavior.
- URPC/UMQ: RPC and queue framework; the UB backend can use URMA Jetty/JFC.
- UMS/USOCK: socket compatibility path using AF_SMC, TCP ULP, preload tools,
  and ubcore client integration.
- Tools: discovered local tools include `urma_admin`, `urma_ping`,
  `urma_perftest`, `urpc_admin`, URPC perftest tools, `ums_admin`, and
  `ums_run`. No local source named `ubtool`, `ub_tool`, `ub tool`, or
  `ub-tool` was found.

Details are in [UNIC, CDMA, URPC, UMS, and tool coverage](./unic-cdma-urpc-ums-tools-coverage.md).

## What Still Needs Validation

These notes are source-derived and spec/paper-derived. Runtime validation is
still needed on UB hardware or a faithful UB environment:

- real `/sys/bus/ub`, `/sys/class/ubcore`, `/sys/class/uburma`, and
  `/dev/uburma` output;
- `udevadm info` output for UB entities and character devices;
- dmesg traces for UB firmware discovery, UBASE, UDMA, ubcore, uburma, and
  UMMU setup;
- successful `urma_create_context()`, Segment registration, queue creation,
  mmap, post, and poll traces;
- topology output from `urma_admin show topo` and `urma_ping`;
- confirmation of exact deployed UMDK/kernel branch pairing and ABI match.

Use [Runtime validation guide](./runtime-validation-guide.md) when hardware is
available.

## Read Next

Recommended path after this summary:

1. [Documentation index and coverage matrix](./00-index-and-coverage.md)
2. [URMA/UDMA user-kernel boundary](./urma-udma-user-kernel-boundary.md)
3. [End-to-end platform workflow](./end-to-end-platform-workflow.md)
4. [UMDK/RDMA terminology and comparison](./umdk-rdma-terminology-and-comparison.md)
5. [Source evidence map](./08-source-evidence-map.md)
