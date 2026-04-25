# UMDK Codex Notes

This directory tracks Codex findings about openEuler UMDK, with the current focus on the URMA and UDMA stack.

Last updated: 2026-04-25

## Local Repositories

The current analysis is based on local checkouts, not fresh network clones.

| Component | Local path | Branch | Commit | Purpose |
| --- | --- | --- | --- | --- |
| openEuler kernel | `/Users/ray/Documents/Repo/kernel` | `OLK-6.6` | `8f8378999` | Kernel-side UB/URMA/UDMA drivers and UAPI headers |
| UMDK | `/Users/ray/Documents/Repo/ub-stack/umdk` | `master` | `d04677a` | User-space URMA library, HNS3 UDMA provider, tools, and transport service |

## Contents

- [URMA/UDMA architecture](./urma-udma-architecture.md)
- [Source map](./source-map.md)
- [Working log](./working-log.md)

## Current Understanding

UMDK is the user-space portion of the Unified Memory Development Kit. In this checkout it provides:

- `liburma`: the user-facing URMA control and data-plane API implementation.
- `hw/hns3`: a hardware provider for HNS3 UDMA devices.
- `tools`: admin and performance tools.
- `transport_service`: TPS/UVS daemon and control-plane services.

The kernel repo provides the matching kernel-side UB/URMA components:

- `drivers/ub/urma/ubcore`: shared URMA core and character-device/ioctl plumbing.
- `drivers/ub/urma/hw/udma`: HiSilicon UDMA hardware driver.
- `include/uapi/ub/urma/udma/udma_abi.h`: kernel UAPI ABI visible to user space.

The main call path is:

```text
application
  -> liburma public API
  -> provider ops, such as hns3_udma_v1
  -> urma_cmd_* ioctl wrappers
  -> ubcore character device
  -> kernel ubcore_ops implemented by udma
  -> UBASE/firmware/hardware
```

## Follow-up Questions

- Confirm the exact branch/tag pairing between `/Users/ray/Documents/Repo/kernel` and `/Users/ray/Documents/Repo/ub-stack/umdk`.
- Compare `kernel/include/uapi/ub/urma/udma/udma_abi.h` against `umdk/hw/hns3/hns3_udma_abi.h`; the local checkouts appear to carry different ABI families.
- Trace a complete operation end to end, preferably `create_context`, `create_jfs`, `post_jfs_wr`, or `poll_jfc`.
