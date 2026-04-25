# UMDK Codex Notes

This directory tracks Codex findings about openEuler UMDK, with the current focus on the URMA and UDMA stack.

Last updated: 2026-04-25

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

- [UnifiedBus and UMDK research findings](./unifiedbus-umdk-research.md)
- [UMDK component architecture](./umdk-component-architecture.md)
- [URMA/UDMA working flows](./urma-udma-working-flows.md)
- [URMA/UDMA architecture](./urma-udma-architecture.md) - older snapshot, kept for continuity
- [Source map](./source-map.md)
- [Working log](./working-log.md)

## Current Understanding

UMDK is the user-space portion of the UnifiedBus memory-semantics software stack. In this checkout it provides:

- `src/urma`: URMA API, liburma, UDMA userspace provider, UVS/TPSA support, tools, and examples.
- `src/urpc`: URPC framework and UMQ messaging implementations.
- `src/cam`: communication acceleration code for AI/MoE workloads.
- `src/ulock`: distributed lock implementation.
- `src/usock`: socket compatibility support through UMS.

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

## Follow-up Questions

- Confirm the exact branch/tag pairing between `/Users/ray/Documents/Repo/ub-stack/umdk` and `/Users/ray/Documents/Repo/ub-stack/kernel-ub`.
- Compare current `src/urma/hw/udma/udma_u_abi.h` with the kernel-side ABI in both kernel trees.
- Continue tracing complete operations end to end, especially `create_context`, `create_jetty`, `register/import segment`, `post_jfs_wr`, and `poll_jfc`.
