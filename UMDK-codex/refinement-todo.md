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
- `09-open-questions.md`

Migration rules:

- Keep source-derived claims tied to file/function evidence.
- Keep spec interpretation separate from implementation facts.
- Keep version differences explicit when OLK-5.10 and OLK-6.6 differ.
- Preserve older snapshots only when they carry historical context not present
  in the new structure.
