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
