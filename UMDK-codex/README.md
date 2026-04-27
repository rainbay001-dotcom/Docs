# UMDK Codex Notes

This directory tracks Codex findings about openEuler UMDK, with the current focus on the URMA and UDMA stack.

Last updated: 2026-04-27

## Local Repositories

The current analysis is based on local checkouts, not fresh network clones.

| Component | Local path | Branch | Commit | Purpose |
| --- | --- | --- | --- | --- |
| UMDK | `/Users/ray/Documents/Repo/ub-stack/umdk` | `master` | `d04677a` | Current UMDK source tree: URMA, URPC, CAM, ULOCK, USOCK |
| Paired UB kernel tree | `/Users/ray/Documents/Repo/ub-stack/kernel-ub` | `OLK-5.10` | `5ae3d7d` | Older paired UB/URMA kernel tree with `ubcore`, `uburma`, and HNS3 UDMA |
| openEuler kernel | `/Users/ray/Documents/Repo/kernel` | `OLK-6.6` | `8f8378999` | Newer openEuler kernel tree with `drivers/ub/urma/hw/udma` |

## Local UnifiedBus Documents

Two local document directories were found:

| Directory | Contents |
| --- | --- |
| `/Users/ray/Documents/docs/unifiedbus` | Chinese UnifiedBus 2.0 PDFs, including full base spec and Chinese software reference docs |
| `/Users/ray/UnifiedBus-docs-2.0` | English public/reference PDFs, including OS software reference, Service Core reference, Management/O&M reference, and base-spec preview |

## Contents

- [Documentation index and coverage matrix](./00-index-and-coverage.md)
- [UMDK executive summary](./01-summary.md)
- [UnifiedBus and UMDK research findings](./unifiedbus-umdk-research.md)
- [UnifiedBus spec deep dive for UMDK, URMA, and UDMA](./unifiedbus-spec-umdk-urma-udma.md)
- [UMDK/RDMA terminology mapping and comparison](./umdk-rdma-terminology-and-comparison.md)
- [UB-Mesh context and UMDK mapping](./ub-mesh-context-and-umdk-mapping.md)
- [UMDK component architecture](./umdk-component-architecture.md)
- [End-to-end platform workflow](./end-to-end-platform-workflow.md)
- [Architecture diagrams and workflows](./architecture-diagrams-and-workflows.md)
- [UMQ architecture and workflows](./umq-architecture-and-workflows.md)
- [UB root bus, udev, and device enumeration](./ub-root-bus-udev-device-enumeration.md)
- [UB and PCIe probe process comparison](./ub-vs-pcie-probe-process-comparison.md)
- [UMMU memory-management deep dive](./ummu-memory-management-deep-dive.md)
- [URMA/UDMA user-kernel boundary](./urma-udma-user-kernel-boundary.md)
- [Socket API above a UB/URMA-backed transport](./socket-api-over-ub-urma-transport.md)
- [UNIC, CDMA, URPC, UMS, and tool coverage](./unic-cdma-urpc-ums-tools-coverage.md)
- [Runtime validation guide](./runtime-validation-guide.md)
- [URMA/UDMA working flows](./urma-udma-working-flows.md)
- [URMA/UDMA architecture](./urma-udma-architecture.md) - older snapshot, kept for continuity
- [Source map](./source-map.md)
- [Source evidence map](./08-source-evidence-map.md)
- [Documentation refinement TODO](./refinement-todo.md)
- [Working log](./working-log.md)

## Current Understanding

UMDK is the user-space portion of the UnifiedBus memory-semantics software stack. In this checkout it provides:

- `src/urma`: URMA API, liburma, UDMA userspace provider, UVS/TPSA support, tools, and examples.
- `src/urpc`: URPC framework and UMQ messaging implementations.
- `src/cam`: communication acceleration code for AI/MoE workloads.
- `src/ulock`: distributed lock implementation.
- `src/usock`: socket compatibility support through UMS.

The side-component coverage now explicitly includes UNIC, CDMA, URPC/UMQ,
UMS/USOCK, and the discovered runtime tools. No local source named `ubtool`,
`ub_tool`, `ub tool`, or `ub-tool` was found in the checked UMDK and kernel
trees; the actual discovered tools are `urma_admin`, `urma_ping`,
`urma_perftest`, `urpc_admin`, URPC perftest tools, `ums_admin`, `ums_run`, and
the UMS preload library source.

The terminology guide maps UMDK/URMA objects to familiar RDMA and Ethernet
concepts. The short version is: `ubcore_device` is closest to `ib_device`,
`ubcore_ops` to `ib_device_ops`, `Jetty` to `QP`, `JFS/JFR/JFC` to
`SQ/RQ/CQ`, and `Segment` to `MR`, with important UB-specific differences.

The kernel repo provides the matching kernel-side UB/URMA components:

- `kernel-ub/drivers/ub/urma/ubcore`: shared URMA core and resource model.
- `kernel-ub/drivers/ub/urma/uburma`: character-device/ioctl bridge from user space.
- `kernel-ub/drivers/ub/hw/hns3`: HNS3 UDMA kernel driver.
- `kernel/drivers/ub/urma/hw/udma`: newer UDMA driver in the OLK-6.6 tree.

The main call path is:

```text
application
  -> liburma public API
  -> provider ops, such as udma
  -> urma_cmd_* ioctl wrappers
  -> /dev/uburma/<device>
  -> uburma command dispatcher
  -> ubcore resource APIs
  -> kernel UDMA ubcore_ops implementation
  -> UBASE/UMMU/UDMA hardware
```

The user-kernel boundary is now consolidated in
`urma-udma-user-kernel-boundary.md`. The key split is that setup/control
operations cross `/dev/uburma/<device>` through `ioctl()` and `mmap()`, while
the normal user-space post/poll datapath runs through the UDMA user provider
using mapped queue and doorbell pages after setup.

The full platform path starts earlier than the user API:

```text
firmware UBRT/UBIOS
  -> ubfi parses UBC and UMMU tables
  -> ub_bus_type enumerates ub_entity devices
  -> ubase binds UB entities and creates auxiliary devices
  -> UDMA registers ubcore_device objects
  -> ubcore/uburma publish sysfs and /dev nodes
  -> liburma discovers and opens /dev/uburma/<device>
```

Compared with PCIe, the important difference is that UB has a two-level bind
path:

```text
PCIe:
  pci_dev -> pci_driver.probe() -> endpoint subsystem device

UB:
  ub_entity -> ub_driver.probe(ubase) -> UBASE auxiliary devices
            -> udma/unic/cdma auxiliary probes -> subsystem devices
```

The spec-side interpretation is:

```text
UB Base Specification
  -> defines UB protocol stack, transaction layer, and URMA programming model
UB OS Software Reference Design
  -> maps that model into UMDK, liburma, uburma, ubcore, and UDMA drivers
UMDK source tree
  -> implements the user-space API and provider ABI
UDMA user/kernel drivers
  -> implement provider-specific queues, doorbells, contexts, segments, and TP support
```

The UB-Mesh interpretation adds the datacenter topology layer:

```text
LLM workload locality
  -> UB-Mesh nD-FullMesh / UB-Mesh-Pod architecture
  -> topology-aware UVS, ubagg, and ubcore path selection
  -> URMA/UDMA data path
  -> UMMU-protected UB memory access
```

Adjacent UB software paths fill in compatibility and service surfaces around
the native URMA/UDMA path:

```text
Linux netdev path:
  UNIC -> netdev/channels/NAPI/link state over UBASE auxiliary devices

Crystal DMA path:
  CDMA -> /dev/cdma/dev -> CDMA_SYNC -> JFS/JFC/CTP/Segment -> UMMU

RPC/queue path:
  URPC -> UMQ -> IPC or UB backend -> URMA Jetty/JFC where UB transport is used

Socket compatibility path:
  ums_run/libums-preload -> AF_SMC/UMS -> TCP ULP + ubcore client
```

Socket API over UB/URMA-backed transport now has a dedicated note in
`socket-api-over-ub-urma-transport.md`. The short version is that two local
paths preserve a socket interface while using UB/URMA/UDMA below it:
UMS/USOCK rewrites selected TCP stream sockets to `AF_SMC`/UMS and then uses
ubcore resources internally, while IPoURMA exposes a Linux netdev over URMA so
normal TCP/IP sockets can route through a UB-backed device. No socket-backed
native `liburma` provider was found locally.

## Follow-up Questions

- Confirm the exact branch/tag pairing between `/Users/ray/Documents/Repo/ub-stack/umdk` and `/Users/ray/Documents/Repo/ub-stack/kernel-ub`.
- Compare current `src/urma/hw/udma/udma_u_abi.h` with the kernel-side ABI in both kernel trees.
- Capture real UB hardware output for `/sys/bus/ub`, `/sys/class/ubcore`, `/sys/class/uburma`, `/dev/ubcore`, `/dev/uburma`, and `udevadm info`.
- Continue line-by-line tracing for the highest-value user API paths:
  `create_context`, `create_jetty`, `register/import segment`, `post_jfs_wr`, and `poll_jfc`.
- Deepen the new side-component coverage with line-level paths for UNIC TX/RX,
  CDMA ABI/client use, URPC channel attach/queue pairing, and UMS connection
  manager/token/buffer behavior.
