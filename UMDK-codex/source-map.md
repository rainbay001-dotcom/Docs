# Source Map

Last updated: 2026-04-25

## Kernel Repo

Local path:

```text
/Users/ray/Documents/Repo/kernel
```

Observed branch/commit:

```text
OLK-6.6 @ 8f8378999
```

Key files:

| File | Role |
| --- | --- |
| `drivers/ub/urma/hw/udma/Kconfig` | Defines `CONFIG_UB_UDMA` and dependencies |
| `drivers/ub/urma/hw/udma/Makefile` | Builds the `udma` module objects |
| `drivers/ub/urma/hw/udma/udma_main.c` | Module entry, auxiliary driver registration, ubcore device registration, ubcore ops table, capability query |
| `drivers/ub/urma/hw/udma/udma_dev.h` | Main `struct udma_dev`, resource tables, module-wide state |
| `drivers/ub/urma/hw/udma/udma_common.c` | Memory pinning, UMMU map/unmap, ID allocation, shared queue helpers |
| `drivers/ub/urma/hw/udma/udma_ctl.c` | Extended/user-control paths, kernel-created JFS/JFC helpers |
| `drivers/ub/urma/hw/udma/udma_ctx.c` | User context handling and mmap support |
| `drivers/ub/urma/hw/udma/udma_db.c` | Doorbell management |
| `drivers/ub/urma/hw/udma/udma_segment.c` | Segment registration/import and memory mapping |
| `drivers/ub/urma/hw/udma/udma_jfc.c` | Completion queue/JFC implementation |
| `drivers/ub/urma/hw/udma/udma_jfs.c` | Send queue/JFS implementation |
| `drivers/ub/urma/hw/udma/udma_jfr.c` | Receive queue/JFR implementation |
| `drivers/ub/urma/hw/udma/udma_jetty.c` | Full Jetty object implementation |
| `drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` | Control queue and transport-path operations |
| `drivers/ub/urma/hw/udma/udma_eid.c` | EID/IP and related address helpers |
| `include/uapi/ub/urma/udma/udma_abi.h` | Kernel UAPI ABI structures and constants |

Neighboring kernel paths:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/ubcore` | URMA core, char device, ubcore object handling |
| `drivers/ub/urma/ulp/ipourma` | IP-over-URMA upper-layer protocol |
| `drivers/ub/urma/ubagg` | Aggregation layer |
| `include/ub/urma` | Internal kernel URMA headers |

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
| `include` | Public and shared URMA/common headers |
| `common` | Shared C utility libraries |
| `lib/urma` | User-space URMA implementation |
| `hw/hns3` | HNS3 UDMA provider |
| `tools/urma_admin` | URMA admin tool |
| `tools/uvs_admin` | UVS admin tool |
| `tools/urma_perftest` | Performance test tool |
| `transport_service` | TPS/UVS daemon and control-plane services |

Key user library files:

| File | Role |
| --- | --- |
| `lib/urma/core/urma_cmd.c` | ioctl command wrapper implementation |
| `lib/urma/core/urma_device.c` | Device discovery through sysfs and cdev fallback |
| `lib/urma/core/urma_cp_api.c` | Control-plane API implementation |
| `lib/urma/core/urma_dp_api.c` | Data-plane API implementation |
| `lib/urma/include/urma_provider.h` | Provider-facing operations and command declarations |
| `include/urma_api.h` | Public URMA API |
| `include/urma_types.h` | Public URMA types |
| `include/common/urma_cmd.h` | Command definitions shared by liburma |

Key HNS3 provider files:

| File | Role |
| --- | --- |
| `hw/hns3/hns3_udma_u_main.c` | Provider constructor/destructor registration |
| `hw/hns3/hns3_udma_u_provider_ops.c` | Provider ops table, context create/delete, DCA setup |
| `hw/hns3/hns3_udma_abi.h` | HNS3 provider ABI structs/constants |
| `hw/hns3/hns3_udma_u_common.h` | MMIO/register helpers, barriers, queue/common structs |
| `hw/hns3/hns3_udma_u_jfc.c` | Completion object creation, polling, event handling |
| `hw/hns3/hns3_udma_u_jfs.c` | Send object creation, WQE allocation, posting |
| `hw/hns3/hns3_udma_u_jfr.c` | Receive object creation and posting |
| `hw/hns3/hns3_udma_u_jetty.c` | Combined send/receive Jetty object |
| `hw/hns3/hns3_udma_u_segment.c` | Segment registration/import provider handling |
| `hw/hns3/hns3_udma_u_tp.c` | Transport path operations |
| `hw/hns3/hns3_udma_u_db.c` | Software and hardware doorbell helpers |
| `hw/hns3/hns3_udma_u_user_ctl.c` | Provider user-control commands |

## Important Symbols

Kernel:

- `g_dev_ops`: UDMA implementation of `struct ubcore_ops`.
- `udma_probe()`: auxiliary-device probe path.
- `udma_set_ubcore_dev()`: configures and registers the ubcore device.
- `query_caps_from_firmware()`: queries hardware/firmware resources.
- `udma_query_device_attr()`: exposes device capabilities to ubcore/user space.

User space:

- `g_hns3_udma_u_provider_ops`: HNS3 provider registration object.
- `g_hns3_udma_u_ops`: URMA operation table implemented by HNS3 UDMA.
- `hns3_udma_u_create_context()`: provider context creation path.
- `urma_cmd_create_context()`: liburma ioctl wrapper for context creation.
- `hns3_udma_u_create_jfs()`: user-space JFS creation path.
- `hns3_udma_u_create_jfc()`: user-space JFC creation path.
- `hns3_udma_u_poll_jfc()`: completion polling path.
