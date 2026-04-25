# UMDK Documentation Refinement TODO

Last updated: 2026-04-25

This TODO tracks the next refinement pass for the UMDK/URMA/UDMA documentation
set. The current docs already cover the major architecture, terminology,
UnifiedBus specification interpretation, root-bus enumeration, udev exposure,
UMMU memory management, and end-to-end workflows. The next pass should turn the
research notes into a source-anchored technical reference.

## 1. Freeze and Push Current Baseline

Status: in progress

Commit the current `UMDK-codex` documentation state before deeper restructuring.
This preserves the root-bus, udev, UMMU, workflow, terminology, and comparison
research as a stable baseline.

Expected output:

- One committed and pushed baseline for the current documentation set.
- Worktree check showing unrelated files outside `UMDK-codex` were not staged.

## 2. Add Source-Anchored Diagrams

Status: pending

Add Mermaid diagrams that are tied to concrete source files and function names.
The diagrams should make the architecture readable without hiding the source
evidence.

Required diagrams:

- Firmware discovery: UBRT/UBIOS to UBC and UMMU nodes.
- UB root bus: `ub_bus_type`, `ub_entity`, topology enumeration, and uevents.
- ubase binding: UB entity match to `ubase` device and auxiliary device.
- UDMA registration: auxiliary driver probe to `ubcore_register_device`.
- User-space open path: liburma discovery to `/dev/uburma/<device>`.
- UMMU memory path: SVA/KSVA, TID, token, MATT/MAPT, and segment mapping.
- Data path: context, Jetty, JFS/JFR/JFC, work request, completion.
- Teardown path: resource destruction, segment unmap, token/TID release.

## 3. Create a Line-Referenced Evidence Table

Status: pending

Create a table that maps each major claim in the docs to source evidence. Each
row should include repository, file path, function or struct, role, and the
reason it matters.

Initial evidence targets:

- `ubfi_init` for firmware table discovery.
- `handle_ubc_table` and `handle_ummu_table` for UBC/UMMU node parsing.
- `ub_bus_type` for the UB root bus abstraction.
- `ub_uevent` for udev and `MODALIAS=ub:*` exposure.
- `ub_enum_probe` for topology enumeration.
- `ubase_ubus_probe` for UB entity to ubase binding.
- UDMA auxiliary driver probe and `ubcore_register_device`.
- `ubcore_devnode` and `uburma_devnode` for `/dev/ubcore` and
  `/dev/uburma/<device>`.
- `udma_alloc_dev_tid`, `udma_alloc_ucontext`, `udma_alloc_tid`, and
  `udma_register_seg` for UMMU/TID/token/segment behavior.

## 4. Add End-to-End Workflow Chapters

Status: pending

Expand the workflow documentation into full sequence chapters. Each chapter
should describe trigger, actors, source path, kernel/user boundary, expected
state changes, and teardown.

Required workflows:

- Boot to UB device visible in sysfs.
- UB entity enumeration to ubase binding.
- UDMA device registration into ubcore.
- Application device discovery and open through liburma.
- Context creation and user TID allocation.
- Segment registration, token allocation, and memory grant or map.
- Jetty, JFS, JFR, and JFC creation.
- Work request post, device execution, and completion polling.
- Segment, queue, context, and device teardown.

## 5. Strengthen Comparisons

Status: pending

Split the current comparison material into sharper spec, design,
implementation, and interface comparisons.

Required comparison tables:

- UB vs Ethernet.
- UB vs InfiniBand.
- UB vs RoCE.
- UB vs Linux RDMA verbs.
- UMDK/liburma vs libibverbs.
- UMMU vs IOMMU/SVA/ODP-style RDMA memory models.
- UB memory semantics vs RDMA memory registration and key semantics.
- UB transport/control-plane assumptions vs RDMA CM and subnet-management
  assumptions.

## 6. Add Canonical Terminology Mapping

Status: pending

Create one authoritative glossary for UB/URMA/UDMA terms and their nearest
RDMA/Ethernet concepts. The table should explicitly distinguish exact matches,
near equivalents, and misleading analogies.

Initial canonical mappings:

- `ubcore_device` approximately maps to `ib_device`.
- `ubcore_ops` approximately maps to `ib_device_ops`.
- `Jetty` approximately maps to `QP`.
- `JFS` approximately maps to `SQ`.
- `JFR` approximately maps to `RQ`.
- `JFC` approximately maps to `CQ`.
- `Segment` approximately maps to `MR`.
- `token_id` and `TID` are memory access and address-space binding concepts,
  but they are not simple `lkey` or `rkey` replacements.
- `ub_entity` is a UB bus device-model object, not an Ethernet NIC or RDMA
  port by itself.

## 7. Add Runtime Validation Section

Status: pending

Add a runtime validation guide for systems with UB hardware or emulation. The
current docs are source-derived; runtime captures are still needed to confirm
actual device names, permissions, uevents, sysfs topology, and dmesg behavior.

Capture commands:

```bash
ls /sys/bus/ub/devices
udevadm info -q property -p /sys/bus/ub/devices/<entity>
ls /sys/class/ubcore
ls /sys/class/uburma
ls -l /dev/ubcore /dev/uburma
dmesg | grep -iE 'ub|urma|udma|ummu'
```

Expected output:

- A hardware-observed appendix with sanitized command output.
- A comparison between runtime output and source-derived expectations.
- A short list of mismatches or version-specific differences.

## 8. Refactor into a Cleaner Book Structure

Status: pending

After the evidence tables and diagrams are added, reorganize the docs into a
stable book-like structure. Preserve the research history, but make the primary
reading path concise and predictable.

Proposed structure:

- `00-index-and-coverage.md`
- `01-architecture-overview.md`
- `02-boot-enumeration-root-bus-udev.md`
- `03-ubcore-uburma-userspace.md`
- `04-udma-provider-implementation.md`
- `05-ummu-memory-model.md`
- `06-workflows-end-to-end.md`
- `07-terminology-and-comparison.md`
- `08-source-evidence-map.md`
- `09-ub-mesh-context-and-topology.md`
- `10-open-questions.md`

Migration rules:

- Keep source-derived claims tied to file/function evidence.
- Keep spec interpretation separate from implementation facts.
- Keep version differences explicit when OLK-5.10 and OLK-6.6 differ.
- Preserve older snapshots only when they carry historical context not present
  in the new structure.

## 9. Integrate the UB-Mesh Paper

Status: pending

Add a dedicated UB-Mesh context document that explains why the UMDK/URMA/UDMA
stack exists in the larger AI datacenter architecture. Use the paper
`UB-Mesh: a Hierarchically Localized nD-FullMesh Datacenter Network
Architecture`, arXiv `2503.20377`, as the primary reference.

Reference metadata:

- Title: `UB-Mesh: a Hierarchically Localized nD-FullMesh Datacenter Network
  Architecture`
- arXiv: `2503.20377`
- DOI: `10.48550/arXiv.2503.20377`
- Current observed version during research: v3, revised 2025-05-17
- URL: `https://arxiv.org/abs/2503.20377`
- PDF: `https://arxiv.org/pdf/2503.20377`

Topics to extract:

- nD-FullMesh topology and hierarchical locality.
- UB-Mesh-Pod and 4D-FullMesh physical realization.
- NPU, CPU, NIC, LRS, and HRS building blocks.
- Unified Bus as a single interconnect spanning CPU, NPU, switch, and NIC
  roles.
- Flexible IO bandwidth allocation and hardware resource pooling.
- All-Path-Routing, source routing, structured addressing, table lookup, and
  deadlock-free flow control.
- 64+1 backup design and topology-aware fast-fault recovery.
- Topology-aware collective communication and parallelization.
- CCU, if relevant to CAM and collective-offload discussion.

Expected output:

- `ub-mesh-context-and-umdk-mapping.md`
- A clear boundary between paper claims, local source evidence, and inferred
  mapping.

## 10. Map UB-Mesh Concepts to Local Source

Status: pending

Create a paper-to-source mapping table. This should connect UB-Mesh concepts to
UMDK/UVS/ubcore/ubagg/UMMU implementation artifacts without overstating what
the code proves.

Initial mappings:

- UB-Mesh topology model -> `ubcore_topo_info.h` and `uvs_api.h`.
- `1D-fullmesh` and Clos topology with parallel planes -> `struct
  ubcore_topo_node`, `enum ubcore_topo_type_t`, and `struct urma_topo_node`.
- Topology push from user space -> `uvs_set_topo_info`.
- Topology propagation -> `uvs_ubagg_ioctl_set_topo` and
  `uvs_ubcore_ioctl_set_topo`.
- Kernel topology map -> ubcore topology-map creation/update APIs.
- Aggregation or bonding device model -> `ubagg` and UMDK `bond` provider
  paths.
- User inspection path -> `urma_admin show topo`.
- Test or diagnostic path -> `urma_ping` topology helpers.
- Fullmesh collective hints -> CAM `AlltoAll`, `BatchWrite`, and `MultiPut`
  `level0:fullmesh` algorithm strings.

Questions to resolve:

- Whether current source models only 1D-fullmesh plus Clos, or whether nD and
  4D UB-Mesh concepts are represented elsewhere by configuration tooling.
- Whether APR is visible in this checkout or hidden in firmware, hardware,
  management software, or unreleased components.
- Whether LRS/HRS concepts appear as UB entities, topology links, route tables,
  or external management-plane abstractions.

## 11. Add Topology-Aware Workflows

Status: pending

Add workflows that start from topology input rather than device bring-up. The
current workflow docs explain boot, device registration, memory management, and
URMA operations; the next pass should explain how topology affects routing,
aggregation, bonding, and provider path selection.

Required workflows:

- MXE or management plane provides topology information.
- UVS accepts topology through `uvs_set_topo_info`.
- UVS sends topology to ubagg and ubcore.
- Kernel creates or updates the global topology map.
- ubagg resolves aggregate EIDs to physical devices.
- liburma bond provider loads topology and chooses aggregate or physical
  datapath behavior.
- ubcore returns path sets for source and destination bonding EIDs.
- JFS/Jetty operations use selected path or provider routing data.
- `urma_admin show topo` and `urma_ping` validate topology visibility.

## 12. Extend Comparison Docs With UB-Mesh

Status: pending

Add UB-Mesh as a separate comparison axis in the existing Ethernet, InfiniBand,
RoCE, RDMA, and UnifiedBus comparison docs.

Required comparisons:

- UB-Mesh vs Ethernet Clos: topology-localized AI fabric vs general-purpose
  symmetric datacenter fabric.
- UB-Mesh vs InfiniBand: topology/locality/resource-pooling model vs
  subnet-managed RDMA fabric.
- UB-Mesh vs RoCE: UB-native memory semantics and topology model vs Ethernet
  lossless/RDMA overlay.
- UB-Mesh vs NVLink/NVSwitch: datacenter-scale UB topology vs local GPU/NPU
  high-bandwidth domain.
- UB-Mesh vs Tofu or torus/mesh HPC networks: nD-fullmesh locality,
  all-to-all suitability, and routing implications.
- UB-Mesh and UMMU vs RDMA MR/lkey/rkey/ODP memory model.

The comparison should separate:

- topology design;
- protocol semantics;
- software interface;
- memory-protection model;
- routing and path selection;
- failure recovery;
- collective communication support;
- operational observability.

## 13. Tie UMMU and Resource Pooling Back to UB-Mesh

Status: pending

Add a cross-reference from the UMMU deep dive to UB-Mesh. The argument to make
is that UB-Mesh's resource-pooling and direct UB memory semantics need explicit
address-space isolation, TID/token management, and controlled memory grant/map
behavior.

Specific points:

- Explain why topology-level resource pooling needs memory-domain boundaries.
- Connect `token_id`, `TID`, SVA, KSVA, MAPT, and MATT to safe remote access.
- Compare this to RDMA memory registration and ODP without claiming exact
  equivalence.
- Show where UDMA provider code turns URMA segment intent into UMMU mappings.
- Note which parts are visible in source and which parts likely sit in
  firmware/hardware.

## 14. Add UB-Mesh Diagrams

Status: pending

Add diagrams that connect the paper's architecture to the local software stack.

Required diagrams:

- UB-Mesh paper layers:
  `LLM workload -> topology-aware collectives -> UB-Mesh topology -> UB
  interconnect -> UMDK/URMA/UDMA software -> UMMU`.
- nD-FullMesh vs Clos:
  local short-range paths, long-range paths, LRS/HRS role, and switch reduction
  rationale.
- Topology configuration path:
  `management/MXE -> UVS -> ubagg -> ubcore -> path set -> provider`.
- UMMU in resource pooling:
  `application buffer -> Segment -> token/TID -> UMMU grant/map -> remote UB
  access`.
- CAM collective path:
  `MoE/AllToAll -> CAM algorithm config -> fullmesh topology hint -> UB data
  movement`.

## 15. Add UB-Mesh Runtime and Source Validation

Status: pending

Add validation steps for machines or environments where UB topology is exposed.
The goal is to confirm whether the runtime topology matches the paper-to-source
mapping.

Commands and checks:

```bash
urma_admin show topo
urma_admin show topo <node_id>
urma_ping <options>
ls /sys/class/ubcore
ls /sys/class/uburma
dmesg | grep -iE 'ub|ubcore|ubagg|uvs|urma|udma|ummu|topo|mesh'
```

Evidence to capture:

- topology type: fullmesh, Clos, or another configured value;
- node ID, super-node ID, current-node marker;
- aggregate EID to physical-device mapping;
- path count and path endpoints if exposed;
- whether LRS/HRS or switch-like elements appear in software-visible topology;
- whether runtime output confirms or contradicts the UB-Mesh paper mapping.
