# URMA/UDMA Architecture Notes

Last updated: 2026-04-25

## High-Level Split

URMA is the remote-memory-access abstraction exposed to applications by UMDK. UDMA is the HiSilicon hardware implementation behind that abstraction.

There are two important local trees:

- Kernel driver side: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma`
- User provider side: `/Users/ray/Documents/Repo/ub-stack/umdk/hw/hns3`

The kernel driver owns hardware resources and ubcore integration. The user provider owns user-space queue buffers, doorbells, CQE parsing, and provider-specific private command payloads.

## Kernel Driver

The kernel UDMA module is built from:

```text
drivers/ub/urma/hw/udma/
  udma_main.c
  udma_cmd.c
  udma_common.c
  udma_ctx.c
  udma_db.c
  udma_tid.c
  udma_eq.c
  udma_jfc.c
  udma_jfs.c
  udma_jfr.c
  udma_jetty.c
  udma_jetty_group.c
  udma_segment.c
  udma_ctrlq_tp.c
  udma_eid.c
  udma_mue.c
  udma_dfx.c
```

`Kconfig` defines `CONFIG_UB_UDMA` as the UDMA module option. It depends on:

- `UB_UBASE`
- `UB_URMA`
- `UB_UMMU_CORE`

`udma_main.c` registers a `struct ubcore_ops` table. This is the kernel driver's main contract with ubcore. The table includes:

- Device operations: query/configure device, stats, EID/IP helpers.
- Context operations: allocate/free user context, mmap.
- Memory operations: allocate/free token id, register/import/unregister/unimport segment.
- Completion/send/receive objects: JFC, JFS, JFR.
- Jetty objects: create, modify, query, flush, destroy, import/unimport, bind/unbind.
- Transport path: get/set/activate/deactivate TP.
- Data path hooks: post JFS/JFR/Jetty work requests and poll JFC.
- Provider escape hatch: `user_ctl`.

The driver registers the ubcore device in `udma_set_ubcore_dev()` via `ubcore_register_device()`.

## Capability Discovery

The kernel driver queries firmware resources through `query_caps_from_firmware()` in `udma_main.c`.

Notable capabilities copied into `udma_dev->caps` include:

- JFS/JFR SGE limits and inline size.
- Jetty group count.
- Transport mode.
- SEID table size and count.
- Port count.
- Read/write/atomic size limits.
- Atomic feature flags.
- UE count and UE id.
- Jetty id ranges for public, CCU, HDC, cache-lock, user-control-normal, and normal URMA Jetty ranges.

`udma_query_device_attr()` maps those hardware capabilities into ubcore-visible device attributes.

## User-Space Provider

The HNS3 UDMA provider is under:

```text
/Users/ray/Documents/Repo/ub-stack/umdk/hw/hns3
```

Provider registration happens through constructor/destructor hooks in `hns3_udma_u_main.c`, which call:

- `urma_register_provider_ops(&g_hns3_udma_u_provider_ops)`
- `urma_unregister_provider_ops(&g_hns3_udma_u_provider_ops)`

The provider advertises:

- Provider name: `hns3_udma_v1`
- Transport type: `URMA_TRANSPORT_HNS_UB`
- URMA operation table name: `HNS3_UDMA_CP_OPS`

The provider match table includes Huawei PCI IDs for HNS3 UDMA over UBL, non-UBL, VF, and temporary VF variants.

## User/Kernel Command Flow

`lib/urma/core/urma_cmd.c` is the central user-space ioctl wrapper layer. For example:

```text
urma_cmd_create_context()
  -> fill URMA_CMD_CREATE_CTX command header
  -> attach provider private udata
  -> ioctl(dev_fd, URMA_CMD, &hdr)
```

The provider passes hardware-specific private command structures through `urma_cmd_udrv_priv_t`. This is how `hw/hns3` sends buffer addresses, doorbell addresses, and provider-specific options into the kernel path.

## Context Creation

`hns3_udma_u_create_context()` allocates the provider context and then:

1. Loads optional DCA settings from environment variables.
2. Builds `hns3_udma_create_ctx_ucmd`.
3. Calls `urma_cmd_create_context()`.
4. Initializes context fields from `hns3_udma_create_ctx_resp`.
5. mmaps the UAR page.
6. mmaps the reset-state page.
7. Optionally initializes DCA status mapping.
8. Initializes user-space Jetty/JFS/JFR lookup tables.

Relevant DCA environment variables:

- `HNS3_UDMA_DCA_UNIT_SIZE`
- `HNS3_UDMA_DCA_MAX_SIZE`
- `HNS3_UDMA_DCA_MIN_SIZE`
- `HNS3_UDMA_DCA_PRIME_TP_NUM`

## Queue and Completion Objects

JFS creation in `hns3_udma_u_jfs.c`:

1. Validates the JFS config.
2. Allocates a QP object.
3. Allocates software DB memory.
4. Allocates or prepares WQE buffers.
5. Sends `urma_cmd_create_jfs()` with provider private data.
6. Stores returned QPN, flags, path MTU, priority, and UM source-port data.
7. Optionally mmaps direct WQE if `HNS3_UDMA_QP_CAP_DIRECT_WQE` is set.
8. Adds the QP to user-space lookup tables.

JFC creation in `hns3_udma_u_jfc.c`:

1. Validates depth against `max_jfc_cqe`.
2. Allocates CQE buffer.
3. Allocates software DB.
4. Sends `urma_cmd_create_jfc()`.
5. Initializes CI, arm sequence number, CQN, and capability flags.

JFC polling parses CQEs, maps hardware completion status into URMA completion status, resolves local JFR/Jetty objects, and handles inline receive data when present.

## ABI Notes

There are two ABI headers worth comparing:

- Kernel UAPI: `/Users/ray/Documents/Repo/kernel/include/uapi/ub/urma/udma/udma_abi.h`
- User provider ABI: `/Users/ray/Documents/Repo/ub-stack/umdk/hw/hns3/hns3_udma_abi.h`

The local kernel UAPI uses `udma_*` structs, while the local user provider uses `hns3_udma_*` structs. These may belong to different generations or branch pairings. Do not assume the two local checkouts are ABI-matched without verifying openEuler release alignment.
