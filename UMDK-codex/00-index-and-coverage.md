# UMDK Documentation Index and Coverage Matrix

Last updated: 2026-04-25

This file is the reading order and coverage map for the UMDK/URMA/UDMA
research notes in this directory. It is meant to answer two questions quickly:

- Which document should I read for a specific layer?
- Which parts are covered deeply, partially, or still need source tracing?

## Recommended Reading Order

1. `README.md`
   - Scope, local repositories, and the shortest end-to-end call path.
2. `01-summary.md`
   - Short human-readable entry point for UB, UMDK, URMA, UDMA, UB-Mesh,
     proven source facts, inferred architecture, side components, and runtime
     validation gaps.
3. `unifiedbus-umdk-research.md`
   - Initial research findings from local UnifiedBus documents and source.
4. `unifiedbus-spec-umdk-urma-udma.md`
   - Spec-side interpretation of UB, URMA, UDMA, UMMU, token, and memory semantics.
5. `umdk-rdma-terminology-and-comparison.md`
   - Mapping to Ethernet, InfiniBand, RoCE, RDMA verbs, and Linux RDMA core.
6. `ub-mesh-context-and-umdk-mapping.md`
   - UB-Mesh paper context, source mapping, topology, resource pooling, and
     UMMU implications.
7. `umdk-component-architecture.md`
   - User-space and kernel component architecture.
8. `urma-udma-user-kernel-boundary.md`
   - Consolidated user-space vs kernel-space boundary for liburma, u-UDMA,
     `uburma`, `ubcore`, k-UDMA, mmap, ioctl, fast path, and debug workflow.
9. `end-to-end-platform-workflow.md`
   - Full boot-to-application workflow, including the newly added root-bus,
     udev, UMMU, and URMA/UDMA paths.
10. `architecture-diagrams-and-workflows.md`
   - Mermaid diagrams and workflow chapters for boot, udev, UMMU, topology,
     CAM, data path, and teardown.
11. `ub-root-bus-udev-device-enumeration.md`
   - Kernel device model, UB root bus, UBRT/UBIOS parsing, ub bus,
     ub_entity enumeration, uevents, and device-node exposure.
12. `ub-vs-pcie-probe-process-comparison.md`
   - Dedicated comparison between Linux PCIe host/device/driver probing and
     UB root, `ub_entity`, `ub_driver`, UBASE, and auxiliary-device bring-up.
13. `ummu-memory-management-deep-dive.md`
   - UMMU, TID/token, SVA/KSVA, MATT/MAPT, segment registration, page pinning,
     and teardown.
14. `socket-api-over-ub-urma-transport.md`
   - Dedicated answer for socket API over UB/URMA/UDMA-backed transport,
     separating UMS/USOCK, IPoURMA, native URMA, and the absence of a
     socket-backed `liburma` simulator/provider in the local tree.
15. `unic-cdma-urpc-ums-tools-coverage.md`
   - Side-component coverage for UNIC, CDMA, URPC/UMQ, UMS/USOCK, tools, and
     the absence of a local `ubtool` by that name.
16. `urma-udma-working-flows.md`
   - Detailed URMA/UDMA API and operation-level flows.
17. `runtime-validation-guide.md`
   - Commands and expected observations for hardware/runtime validation.
18. `source-map.md`
   - Source anchors by component and operation.
19. `08-source-evidence-map.md`
   - Claim-to-source evidence table with concrete paths and line numbers.
20. `refinement-todo.md`
   - Next refinement tasks for diagrams, evidence tables, workflow chapters,
     comparisons, terminology, runtime validation, and doc restructuring.
21. `working-log.md`
   - Chronological notes and unresolved follow-ups.

`urma-udma-architecture.md` is an older architecture snapshot kept for
continuity. Prefer `umdk-component-architecture.md` and
`end-to-end-platform-workflow.md` for current reading.

## Coverage Matrix

| Area | Status | Primary docs | Notes |
| --- | --- | --- | --- |
| Executive summary | Newly covered | `01-summary.md` | Short entry point covering UB, UMDK, URMA, UDMA, UB-Mesh, proven facts, inferences, side components, and validation gaps. |
| UB concept and spec model | Covered | `unifiedbus-spec-umdk-urma-udma.md` | Explains UB protocol, memory semantics, URMA model, and relation to RDMA. |
| UMDK component architecture | Covered | `umdk-component-architecture.md` | Covers liburma, UDMA provider, UVS/TPSA, uburma, ubcore, and UDMA driver. |
| URMA/UDMA user-kernel boundary | Newly covered | `urma-udma-user-kernel-boundary.md` | Consolidates liburma/u-UDMA, `/dev/uburma`, ioctl, mmap, uburma, ubcore, k-UDMA, fast path, kernel-client path, teardown, and debug boundaries. |
| RDMA/IB/RoCE/Ethernet comparison | Covered | `umdk-rdma-terminology-and-comparison.md` | Includes terminology mapping and design comparison. |
| URMA API workflows | Covered | `urma-udma-working-flows.md` | Context, JFC/JFS/JFR/Jetty, Segment, remote import/bind, WR post, poll, teardown. |
| UDMA provider and kernel path | Covered | `umdk-component-architecture.md`, `urma-udma-working-flows.md`, `source-map.md` | User/kernel ABI and provider responsibilities are mapped. |
| End-to-end platform workflow | Newly covered | `end-to-end-platform-workflow.md` | Adds boot, firmware table, UB bus, udev, UMMU, URMA, data path, and teardown. |
| UB root bus and enumeration | Newly covered | `ub-root-bus-udev-device-enumeration.md` | Adds `ub_bus_type`, `ub_entity`, UBRT/UBIOS, `ub_enum_probe`, and uevents. |
| UB vs PCIe probe process | Newly covered | `ub-vs-pcie-probe-process-comparison.md` | Compares PCIe host bridge, `pci_dev`, and `pci_driver` probing with UB root, `ub_entity`, `ub_driver`, UBASE, and auxiliary child probes. |
| udev and device-node exposure | Newly covered | `ub-root-bus-udev-device-enumeration.md` | Documents kernel devnode callbacks and uevent variables; no custom udev rules were found in source. |
| UMMU memory management | Newly covered | `ummu-memory-management-deep-dive.md` | Covers firmware UMMU nodes, UMMU mapping, SVA/KSVA, TID, token, segment grant/map/unmap. |
| UNIC network driver | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers auxiliary-device binding, netdev queue/channel/NAPI/link behavior, and open TX/RX trace gaps. |
| CDMA Crystal DMA | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers `/dev/cdma/dev`, `CDMA_SYNC`, context, queue, JFS/JFC/JFCE, CTP, Segment, and UMMU/SVA/TID paths. |
| URPC and UMQ | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers URPC channel/server/queue APIs, UMQ APIs, UB backend use of URMA Jetty/JFC, and admin tool behavior. |
| UMS/USOCK socket compatibility | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers AF_SMC registration, TCP ULP, ubcore client registration, preload socket remapping, `ums_run`, and `ums_admin`. |
| Socket API over UB/URMA transport | Newly covered | `socket-api-over-ub-urma-transport.md` | Separates UMS/USOCK, IPoURMA, native URMA/UDMA, and the absence of a socket-backed `liburma` provider; includes source anchors and validation checklist. |
| Tooling and `ubtool` status | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md` | Records discovered tools and that no local `ubtool` source was found by that name. |
| UB-Mesh paper context | Newly covered | `ub-mesh-context-and-umdk-mapping.md` | Maps the UB-Mesh paper to UVS, ubcore topology, ubagg, bond provider, CAM fullmesh hints, and UMMU. |
| Source evidence map | Newly covered | `08-source-evidence-map.md` | Claim-to-source table with file and line anchors. |
| Diagrams and workflow chapters | Newly covered | `architecture-diagrams-and-workflows.md` | Adds Mermaid diagrams for boot, udev, UMMU, topology, CAM, data path, and teardown. |
| Failure, teardown, hot-remove | Partially covered | `end-to-end-platform-workflow.md`, `ummu-memory-management-deep-dive.md` | Major paths are covered; line-level failure matrices can still be expanded. |
| Debug and observability | Partially covered | `runtime-validation-guide.md`, `ub-root-bus-udev-device-enumeration.md`, `ummu-memory-management-deep-dive.md`, `source-map.md` | Commands and source probes are listed; runtime examples need real hardware output. |
| Test/smoke validation | Partial | `urma-udma-working-flows.md` | Existing commands are source-derived. Hardware-dependent output is not validated here. |

## What Was Missing Before This Refinement

The earlier document set was already broad, but it had several important gaps:

1. The "first mile" from firmware-reported UB hardware to Linux devices was
   not described. The new root-bus doc covers UBRT/UBIOS parsing, UBC and UMMU
   platform devices, `ub_bus_type`, and topology enumeration.
2. udev was not directly covered. The new root-bus doc explains both UB bus
   uevents and character-device devnode creation for `/dev/ubcore` and
   `/dev/uburma/<device>`.
3. UMMU was mentioned conceptually but not traced as a lifecycle. The new UMMU
   doc follows firmware discovery, UDMA probe-time SVA enablement, context TID
   allocation, token/TID allocation, segment registration, MATT mapping, and
   teardown.
4. Side components were named but not traced. The new UNIC/CDMA/URPC/UMS/tools
   doc maps those components, records concrete source anchors, separates them
   from UDMA/liburma, and documents that `ubtool` was not found locally.
5. The URMA/UDMA user-kernel boundary was covered across several documents but
   not in one place. The new boundary doc consolidates the split between
   `liburma`, u-UDMA, `uburma`, `ubcore`, k-UDMA, ioctl setup, mmap setup, and
   user-space fast path behavior.

## Scope Boundaries

These notes are based on local source and local UnifiedBus documents. The main
source trees are:

| Tree | Path | Role |
| --- | --- | --- |
| UMDK | `/Users/ray/Documents/Repo/ub-stack/umdk` | User-space URMA, UDMA provider, URPC, CAM, ULOCK, USOCK. |
| Paired UB kernel tree | `/Users/ray/Documents/Repo/ub-stack/kernel-ub` | Older OLK-5.10 kernel-side UB/URMA reference. |
| openEuler kernel | `/Users/ray/Documents/Repo/kernel` | Newer OLK-6.6 UB stack with `ubfi`, `ubus`, `ubase`, `ubcore`, `uburma`, and `udma`. |

When the two kernel trees differ, the newer `/Users/ray/Documents/Repo/kernel`
tree is treated as the current implementation reference, and
`/Users/ray/Documents/Repo/ub-stack/kernel-ub` is treated as historical or
paired reference context.

## Still Useful Follow-Ups

- Confirm exact branch or tag pairing between the UMDK tree and the OLK-6.6
  kernel tree.
- Capture real hardware output for:
  - `ls /sys/bus/ub/devices`
  - `udevadm info -q property -p /sys/bus/ub/devices/<entity>`
  - `ls /sys/class/ubcore`
  - `ls /sys/class/uburma`
  - `ls -l /dev/ubcore /dev/uburma`
- Add line-by-line call graph tables for the highest-value API flows:
  `urma_create_context`, `urma_alloc_token_id`, `urma_register_seg`,
  `urma_import_seg`, `urma_create_jetty`, `urma_post_jfs_wr`, and
  `urma_poll_jfc`.
- Compare `src/urma/hw/udma/udma_u_abi.h` with the kernel UDMA ABI in both
  kernel trees.
- Deepen side-component source tracing for UNIC TX/RX, CDMA client/ABI use,
  URPC control plane and UMQ transport modes, and UMS connection/token/buffer
  paths.
