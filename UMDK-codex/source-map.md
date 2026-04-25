# Source Map

Last updated: 2026-04-25

## UMDK Repo

Local path:

```text
/Users/ray/Documents/Repo/ub-stack/umdk
```

Observed branch/commit:

```text
master @ d04677a
```

Top-level layout:

| Path | Role |
| --- | --- |
| `README.md` | Current high-level UMDK introduction |
| `umdk.spec` | RPM/package build logic and feature switches |
| `doc/en/urma` | URMA quickstart, user guide, API guide |
| `doc/en/urpc` | URPC and UMQ guides |
| `doc/en/cam` | CAM API guide |
| `src/urma` | URMA stack, UDMA user provider, UVS support, tools, examples |
| `src/urpc` | URPC framework and UMQ implementation |
| `src/cam` | CAM communication acceleration |
| `src/ulock` | distributed lock |
| `src/usock` | UMS/socket compatibility |

Key URMA user-space files:

| Path | Role |
| --- | --- |
| `src/urma/lib/urma/core/urma_main.c` | Initialization, provider loading, device list, context API |
| `src/urma/lib/urma/core/urma_device.c` | sysfs and cdev discovery |
| `src/urma/lib/urma/core/urma_cmd.c` | ioctl command wrappers |
| `src/urma/lib/urma/core/urma_cmd_tlv.c` | TLV command wrappers |
| `src/urma/lib/urma/core/urma_cp_api.c` | control-plane APIs |
| `src/urma/lib/urma/core/urma_dp_api.c` | data-plane APIs |
| `src/urma/lib/urma/core/include/urma_api.h` | public URMA API |
| `src/urma/lib/urma/core/include/urma_provider.h` | provider-facing ABI |
| `src/urma/lib/urma/bond` | bonding/multipath provider |
| `src/urma/lib/uvs` | UVS/TPSA APIs and ioctls |

Key UDMA user provider files:

| Path | Role |
| --- | --- |
| `src/urma/hw/udma/README.md` | UDMA user driver overview |
| `src/urma/hw/udma/udma_u_ops.c` | provider ops table and context lifecycle |
| `src/urma/hw/udma/udma_u_main.c` | provider registration |
| `src/urma/hw/udma/udma_u_abi.h` | provider-private ABI |
| `src/urma/hw/udma/udma_u_jfc.c` | JFC and completion polling |
| `src/urma/hw/udma/udma_u_jfs.c` | JFS and send WQE posting |
| `src/urma/hw/udma/udma_u_jfr.c` | JFR and receive posting |
| `src/urma/hw/udma/udma_u_jetty.c` | Jetty management and Jetty send/receive posting |
| `src/urma/hw/udma/udma_u_segment.c` | segment register/import/unimport |
| `src/urma/hw/udma/udma_u_db.c` | doorbell allocation/mapping |
| `src/urma/hw/udma/udma_u_ctrlq_tp.c` | control-queue TP operations |
| `src/urma/hw/udma/udma_u_ctl.c` | provider user-control operations |

## Paired UB Kernel Repo

Local path:

```text
/Users/ray/Documents/Repo/ub-stack/kernel-ub
```

Observed branch/commit:

```text
OLK-5.10 @ 5ae3d7d
```

Key paths:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/ubcore` | shared URMA kernel core |
| `drivers/ub/urma/uburma` | user-kernel command bridge and cdev path |
| `drivers/ub/hw/hns3` | HNS3 UDMA kernel driver |
| `drivers/net/ethernet/hisilicon/hns3` | related HNS3 network/UNIC support |

Key kernel files:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/uburma/uburma_cmd.c` | command dispatcher from user ioctl to ubcore |
| `drivers/ub/urma/uburma/uburma_uobj.c` | user object management |
| `drivers/ub/urma/ubcore/ubcore_device.c` | device registration, sysfs, context allocation |
| `drivers/ub/urma/ubcore/ubcore_jetty.c` | JFC/JFS/JFR/Jetty/Jetty group core lifecycle |
| `drivers/ub/urma/ubcore/ubcore_segment.c` | segment registration/import core lifecycle |
| `drivers/ub/urma/ubcore/ubcore_tp.c` | transport path management |
| `drivers/ub/hw/hns3/hns3_udma_main.c` | HNS3 UDMA ops table, context, mmap, registration |
| `drivers/ub/hw/hns3/hns3_udma_abi.h` | HNS3 user/kernel private ABI |
| `drivers/ub/hw/hns3/hns3_udma_jfc.c` | kernel JFC implementation |
| `drivers/ub/hw/hns3/hns3_udma_jfs.c` | kernel JFS implementation |
| `drivers/ub/hw/hns3/hns3_udma_jfr.c` | kernel JFR implementation |
| `drivers/ub/hw/hns3/hns3_udma_jetty.c` | kernel Jetty implementation |
| `drivers/ub/hw/hns3/hns3_udma_segment.c` | kernel segment implementation |
| `drivers/ub/hw/hns3/hns3_udma_tp.c` | kernel TP implementation |
| `drivers/ub/hw/hns3/hns3_udma_user_ctl.c` | provider extension command handlers |

## Newer openEuler Kernel Repo

Local path:

```text
/Users/ray/Documents/Repo/kernel
```

Observed branch/commit:

```text
OLK-6.6 @ 8f8378999
```

Key files:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/hw/udma/Kconfig` | Defines `CONFIG_UB_UDMA` and dependencies |
| `drivers/ub/urma/hw/udma/Makefile` | Builds the `udma` module objects |
| `drivers/ub/urma/hw/udma/udma_main.c` | module entry, auxiliary driver, ubcore ops, caps |
| `drivers/ub/urma/hw/udma/udma_dev.h` | main `struct udma_dev` |
| `drivers/ub/urma/hw/udma/udma_common.c` | memory pinning, UMMU map/unmap, ID allocation |
| `drivers/ub/urma/hw/udma/udma_ctl.c` | extended/user-control paths |
| `drivers/ub/urma/hw/udma/udma_ctx.c` | user context and mmap support |
| `drivers/ub/urma/hw/udma/udma_db.c` | doorbell management |
| `drivers/ub/urma/hw/udma/udma_segment.c` | segment register/import |
| `drivers/ub/urma/hw/udma/udma_jfc.c` | completion queue |
| `drivers/ub/urma/hw/udma/udma_jfs.c` | send queue |
| `drivers/ub/urma/hw/udma/udma_jfr.c` | receive queue |
| `drivers/ub/urma/hw/udma/udma_jetty.c` | Jetty object |
| `drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` | control queue and TP |
| `drivers/ub/urma/hw/udma/udma_eid.c` | EID/IP helpers |
| `include/uapi/ub/urma/udma/udma_abi.h` | kernel UAPI ABI |

## Important Symbols

UMDK/liburma:

- `urma_init`
- `urma_register_provider_ops`
- `urma_scan_sysfs_devices`
- `urma_get_device_by_name`
- `urma_create_context`
- `urma_create_jfc`
- `urma_create_jfs`
- `urma_create_jfr`
- `urma_create_jetty`
- `urma_register_seg`
- `urma_import_seg`
- `urma_post_jetty_send_wr`
- `urma_post_jetty_recv_wr`
- `urma_poll_jfc`

UMDK/u-UDMA:

- `g_udma_ops`
- `g_udma_provider_ops`
- `udma_u_create_context`
- `udma_u_create_jfc`
- `udma_u_create_jfs`
- `udma_u_create_jfr`
- `udma_u_create_jetty`
- `udma_u_register_seg`
- `udma_u_import_seg`
- `udma_u_post_jfs_wr`
- `udma_u_post_jetty_send_wr`
- `udma_u_poll_jfc`

kernel-ub:

- `uburma_cmd_create_ctx`
- `uburma_cmd_create_jfs`
- `uburma_cmd_create_jfr`
- `uburma_cmd_create_jfc`
- `uburma_cmd_create_jetty`
- `uburma_cmd_import_seg`
- `uburma_cmd_import_jetty`
- `ubcore_register_device`
- `ubcore_alloc_ucontext`
- `ubcore_create_jfc`
- `ubcore_create_jfs`
- `ubcore_create_jetty`
- `ubcore_register_seg`
- `ubcore_import_seg`
- `g_hns3_udma_dev_ops`

OLK-6.6 kernel:

- `g_dev_ops`: UDMA implementation of `struct ubcore_ops`.
- `udma_probe()`: auxiliary-device probe path.
- `udma_set_ubcore_dev()`: configures and registers the ubcore device.
- `query_caps_from_firmware()`: queries hardware/firmware resources.
- `udma_query_device_attr()`: exposes device capabilities to ubcore/user space.
