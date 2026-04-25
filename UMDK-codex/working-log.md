# Working Log

## 2026-04-25

Created this directory to track Codex findings about UMDK and the URMA/UDMA stack.

Findings captured:

- Local openEuler kernel checkout is `/Users/ray/Documents/Repo/kernel`, branch `OLK-6.6`, commit `8f8378999`.
- Local UMDK checkout is `/Users/ray/Documents/Repo/ub-stack/umdk`, branch `master`, commit `d04677a`.
- Kernel UDMA driver lives under `drivers/ub/urma/hw/udma`.
- UMDK HNS3 provider lives under `hw/hns3`.
- `lib/urma/core/urma_cmd.c` is the user-space ioctl wrapper layer.
- `hns3_udma_u_provider_ops.c` registers the HNS3 provider and creates provider contexts.
- `udma_main.c` registers the kernel `ubcore_ops` table and the ubcore device.
- Local kernel UAPI and local UMDK HNS3 ABI headers appear to differ; branch/release alignment should be verified before treating them as a matched pair.

Commit/push policy requested by user:

- Keep notes under `Docs-repo/UMDK-codex`.
- Push regularly after meaningful updates.

Additional research pass:

- Located local UnifiedBus documents under `/Users/ray/Documents/docs/unifiedbus` and `/Users/ray/UnifiedBus-docs-2.0`.
- Extracted text from key PDFs into `/tmp/unifiedbus-text` for local analysis.
- Confirmed the local UMDK checkout uses the newer `src/` layout with `src/urma`, `src/urpc`, `src/cam`, `src/ulock`, and `src/usock`.
- Found a paired local kernel tree at `/Users/ray/Documents/Repo/ub-stack/kernel-ub`, branch `OLK-5.10`, commit `5ae3d7d`.
- Compared that with the newer local openEuler kernel tree at `/Users/ray/Documents/Repo/kernel`, branch `OLK-6.6`, commit `8f8378999`.
- Added extensive research and architecture docs:
  - `unifiedbus-umdk-research.md`
  - `umdk-component-architecture.md`
  - `urma-udma-working-flows.md`
- Updated `README.md` and `source-map.md` to reflect the current local repo layout instead of the older pre-`src/` layout.

Specification deep-dive pass:

- Re-read the full local `UB-Base-Specification-2.0-zh.pdf` extraction with focus on UB architecture, data-link reliability, network addressing/routing, transport services, transaction services, function-layer URMA, UBoE, and Ethernet interop.
- Cross-checked the OS reference design sections for UMDK functional architecture and URMA module/usage model.
- Cross-checked public IANA, IEEE, and NVIDIA/InfiniBand/RoCE references for comparison with Ethernet, InfiniBand RDMA, and RoCEv2.
- Added `unifiedbus-spec-umdk-urma-udma.md` with a spec-first explanation of UB, URMA, UMDK, UDMA, UBoE, and comparison with Ethernet/RDMA/RoCE.
- Updated `README.md` and `source-map.md` with the new spec deep-dive entry and source map.

Terminology/comparison pass:

- Added `umdk-rdma-terminology-and-comparison.md`.
- Mapped UB/UMDK/URMA/UDMA terms to Ethernet, InfiniBand, RDMA verbs, and Linux RDMA-core terms.
- Compared UMDK/URMA/UDMA against Ethernet, InfiniBand, RoCE, and RDMA from spec, design, implementation, interface, wire, reliability, ordering, memory, endpoint, and migration perspectives.
- Added code anchors for local UB and RDMA kernel/user-space type definitions.

Refinement pass for root bus, udev, UMMU, and full end-to-end workflow:

- Added `00-index-and-coverage.md` as the reading order and coverage matrix.
- Added `end-to-end-platform-workflow.md` to connect firmware, UBRT/UBIOS, UB bus, ubase, UDMA, ubcore, uburma, liburma, Segment, data path, and teardown.
- Added `ub-root-bus-udev-device-enumeration.md` with detailed source-derived coverage of UB root table parsing, `struct ub_bus_controller`, `ub_bus_type`, `ub_entity` topology enumeration, uevents, udev-visible state, `/dev/ubcore`, and `/dev/uburma/<device>`.
- Added `ummu-memory-management-deep-dive.md` with detailed source-derived coverage of UMMU firmware nodes, UBC-to-UMMU mapping, UB bus DMA/IOMMU configuration, UDMA IOPF/SVA/KSVA setup, user-context TID allocation, token ID/TID handling, Segment registration, page pinning, UMMU grant/ungrant, MATT map/unmap, EID sync, queue buffer mapping, and teardown.
- Updated `README.md` and `source-map.md` to link and index the new docs and source anchors.
