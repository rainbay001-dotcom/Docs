# UMDK Documentation Index and Coverage Matrix

Last updated: 2026-04-25

This file is the reading order and coverage map for the UMDK/URMA/UDMA
research notes in this directory. It is meant to answer two questions quickly:

- Which document should I read for a specific layer?
- Which parts are covered deeply, partially, or still need source tracing?

## Recommended Reading Order

1. `README.md`
   - Scope, local repositories, and the shortest end-to-end call path.
2. `unifiedbus-umdk-research.md`
   - Initial research findings from local UnifiedBus documents and source.
3. `unifiedbus-spec-umdk-urma-udma.md`
   - Spec-side interpretation of UB, URMA, UDMA, UMMU, token, and memory semantics.
4. `umdk-rdma-terminology-and-comparison.md`
   - Mapping to Ethernet, InfiniBand, RoCE, RDMA verbs, and Linux RDMA core.
5. `ub-mesh-context-and-umdk-mapping.md`
   - UB-Mesh paper context, source mapping, topology, resource pooling, and
     UMMU implications.
6. `umdk-component-architecture.md`
   - User-space and kernel component architecture.
7. `end-to-end-platform-workflow.md`
   - Full boot-to-application workflow, including the newly added root-bus,
     udev, UMMU, and URMA/UDMA paths.
8. `architecture-diagrams-and-workflows.md`
   - Mermaid diagrams and workflow chapters for boot, udev, UMMU, topology,
     CAM, data path, and teardown.
9. `ub-root-bus-udev-device-enumeration.md`
   - Kernel device model, UB root bus, UBRT/UBIOS parsing, ub bus,
     ub_entity enumeration, uevents, and device-node exposure.
10. `ummu-memory-management-deep-dive.md`
   - UMMU, TID/token, SVA/KSVA, MATT/MAPT, segment registration, page pinning,
     and teardown.
11. `unic-cdma-urpc-ums-tools-coverage.md`
   - Side-component coverage for UNIC, CDMA, URPC/UMQ, UMS/USOCK, tools, and
     the absence of a local `ubtool` by that name.
12. `urma-udma-working-flows.md`
   - Detailed URMA/UDMA API and operation-level flows.
13. `runtime-validation-guide.md`
   - Commands and expected observations for hardware/runtime validation.
14. `source-map.md`
   - Source anchors by component and operation.
15. `08-source-evidence-map.md`
   - Claim-to-source evidence table with concrete paths and line numbers.
16. `refinement-todo.md`
   - Next refinement tasks for diagrams, evidence tables, workflow chapters,
     comparisons, terminology, runtime validation, and doc restructuring.
17. `working-log.md`
   - Chronological notes and unresolved follow-ups.

`urma-udma-architecture.md` is an older architecture snapshot kept for
continuity. Prefer `umdk-component-architecture.md` and
`end-to-end-platform-workflow.md` for current reading.

## Coverage Matrix

| Area | Status | Primary docs | Notes |
| --- | --- | --- | --- |
| UB concept and spec model | Covered | `unifiedbus-spec-umdk-urma-udma.md` | Explains UB protocol, memory semantics, URMA model, and relation to RDMA. |
| UMDK component architecture | Covered | `umdk-component-architecture.md` | Covers liburma, UDMA provider, UVS/TPSA, uburma, ubcore, and UDMA driver. |
| RDMA/IB/RoCE/Ethernet comparison | Covered | `umdk-rdma-terminology-and-comparison.md` | Includes terminology mapping and design comparison. |
| URMA API workflows | Covered | `urma-udma-working-flows.md` | Context, JFC/JFS/JFR/Jetty, Segment, remote import/bind, WR post, poll, teardown. |
| UDMA provider and kernel path | Covered | `umdk-component-architecture.md`, `urma-udma-working-flows.md`, `source-map.md` | User/kernel ABI and provider responsibilities are mapped. |
| End-to-end platform workflow | Newly covered | `end-to-end-platform-workflow.md` | Adds boot, firmware table, UB bus, udev, UMMU, URMA, data path, and teardown. |
| UB root bus and enumeration | Newly covered | `ub-root-bus-udev-device-enumeration.md` | Adds `ub_bus_type`, `ub_entity`, UBRT/UBIOS, `ub_enum_probe`, and uevents. |
| udev and device-node exposure | Newly covered | `ub-root-bus-udev-device-enumeration.md` | Documents kernel devnode callbacks and uevent variables; no custom udev rules were found in source. |
| UMMU memory management | Newly covered | `ummu-memory-management-deep-dive.md` | Covers firmware UMMU nodes, UMMU mapping, SVA/KSVA, TID, token, segment grant/map/unmap. |
| UNIC network driver | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers auxiliary-device binding, netdev queue/channel/NAPI/link behavior, and open TX/RX trace gaps. |
| CDMA Crystal DMA | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers `/dev/cdma/dev`, `CDMA_SYNC`, context, queue, JFS/JFC/JFCE, CTP, Segment, and UMMU/SVA/TID paths. |
| URPC and UMQ | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers URPC channel/server/queue APIs, UMQ APIs, UB backend use of URMA Jetty/JFC, and admin tool behavior. |
| UMS/USOCK socket compatibility | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md`, `source-map.md` | Covers AF_SMC registration, TCP ULP, ubcore client registration, preload socket remapping, `ums_run`, and `ums_admin`. |
| Tooling and `ubtool` status | Newly covered | `unic-cdma-urpc-ums-tools-coverage.md` | Records discovered tools and that no local `ubtool` source was found by that name. |
| UB-Mesh paper context | Newly covered | `ub-mesh-context-and-umdk-mapping.md` | Maps the UB-Mesh paper to UVS, ubcore topology, ubagg, bond provider, CAM fullmesh hints, and UMMU. |
| Source evidence map | Newly covered | `08-source-evidence-map.md` | Claim-to-source table with file and line anchors. |
| Diagrams and workflow chapters | Newly covered | `architecture-diagrams-and-workflows.md` | Adds Mermaid diagrams for boot, udev, UMMU, topology, CAM, data path, and teardown. |
| Failure, teardown, hot-remove | Partially covered | `end-to-end-platform-workflow.md`, `ummu-memory-management-deep-dive.md` | Major paths are covered; line-level failure matrices can still be expanded. |
| Debug and observability | Partially covered | `runtime-validation-guide.md`, `ub-root-bus-udev-device-enumeration.md`, `ummu-memory-management-deep-dive.md`, `source-map.md` | Commands and source probes are listed; runtime examples need real hardware output. |
| Test/smoke validation | Partial | `urma-udma-working-flows.md` | Existing commands are source-derived. Hardware-dependent output is not validated here. |

## What Was Missing Before This Refinement

The earlier document set was already broad, but it had three important gaps:

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
