# UMDK Component Architecture

Last updated: 2026-04-25

## Repository Baseline

Local UMDK checkout:

```text
/Users/ray/Documents/Repo/ub-stack/umdk
branch: master
commit: d04677a
```

Local UB kernel checkout:

```text
/Users/ray/Documents/Repo/ub-stack/kernel-ub
branch: OLK-5.10
commit: 5ae3d7d
```

Newer local openEuler kernel checkout:

```text
/Users/ray/Documents/Repo/kernel
branch: OLK-6.6
commit: 8f8378999
```

## Top-Level UMDK Layout

The current UMDK repo uses a `src/` layout:

```text
umdk/
  README.md
  umdk.spec
  doc/
    en/
      urma/
      urpc/
      cam/
    ch/
      urma/
      urpc/
      cam/
    images/
  src/
    CMakeLists.txt
    urma/
    urpc/
    cam/
    ulock/
    usock/
  test/
    urma/
    urpc/
    cam/
    ulock/
    usock/
```

Component summary:

| Component | Path | Purpose |
| --- | --- | --- |
| URMA | `src/urma` | Unified Remote Memory Access API, liburma, UDMA provider, UVS/TPSA support, admin/perf/ping tools, examples |
| URPC | `src/urpc` | Unified RPC framework and UMQ messaging implementation |
| CAM | `src/cam` | Communication acceleration for AI/MoE workloads |
| ULOCK | `src/ulock` | Distributed lock and state synchronization |
| USOCK/UMS | `src/usock` | Socket compatibility through kernel module and preload/run tools |

## Packaging Architecture

`umdk.spec` builds from `./src` and exposes feature switches:

- `BUILD_ALL`
- `BUILD_URMA`
- `BUILD_URPC`
- `BUILD_UMS`
- `BUILD_DLOCK`
- `BUILD_UDMA`
- `UDMA_ST64B`
- test/sanitizer/coverage/release switches

RPM package families:

| Package family | Contents |
| --- | --- |
| `umdk-urma-lib` | `liburma.so.*`, `liburma_common.so.*`, `liburma_ubagg.so.*`, optional `liburma-udma.so` |
| `umdk-urma-devel` | URMA headers under `/usr/include/ub/umdk/urma`, optional UDMA extension header |
| `umdk-urma-tools` | `urma_admin`, `urma_ping`, `urma_perftest` |
| `umdk-urma-bin` | TPSA/UVS runtime libraries/config |
| `umdk-urma-example` | `urma_sample` and example docs |
| `umdk-urpc-*` | URPC framework, UMQ libs, headers, tools, examples |
| `umdk-dlock-*` | distributed-lock libraries, headers, examples |
| `umdk-ums` | `ums.ko` kernel module |
| `umdk-ums-tools` | `libums-preload.so`, `ums_run` |

The build instructions in the README and QuickStart use:

```text
cmake ./src/ -DCMAKE_INSTALL_PREFIX=/usr ...
```

For URMA-only source install:

```text
cd src
mkdir build
cd build
cmake .. -D BUILD_ALL=disable -D BUILD_URMA=enable
make install -j
```

## URMA Component Layout

URMA lives under:

```text
src/urma/
  common/
  examples/
  hw/udma/
  lib/
    urma/
    uvs/
  tools/
    urma_admin/
    urma_perftest/
    urma_ping/
```

### `src/urma/common`

Shared C utility code:

- Lists
- Hash maps
- Bitmaps
- Dynamic strings
- Perf cycle helpers
- Barrier/util helpers

These are local support libraries used by liburma, provider code, tools, and sometimes upper components.

### `src/urma/lib/urma`

The public URMA library:

```text
src/urma/lib/urma/
  core/
    urma_main.c
    urma_device.c
    urma_cmd.c
    urma_cmd_tlv.c
    urma_cp_api.c
    urma_dp_api.c
    urma_format_convert.c
    urma_perf.c
    include/
      urma_api.h
      urma_cmd.h
      urma_opcode.h
      urma_provider.h
      urma_types.h
  bond/
    bondp_*.c
```

Key responsibilities:

- Provider loading and registration.
- Device discovery through sysfs.
- Character-device path construction.
- Context creation/destruction.
- Control-plane API validation and dispatch.
- Data-plane API dispatch.
- Command encoding and ioctl dispatch.
- Bonding/multipath provider support.

Important files:

- `urma_main.c`: provider loading, `urma_init`, device list management, `urma_create_context`.
- `urma_device.c`: sysfs discovery under `/sys/class/ubcore` with fallback `/sys/class/uburma`; device attributes and cdev path `/dev/uburma/<dev>`.
- `urma_cmd.c`: traditional ioctl command wrappers.
- `urma_cmd_tlv.c`: TLV-style command wrappers for modern commands.
- `urma_cp_api.c`: control-plane APIs for context, JFC, JFS, JFR, Jetty, segment, token, TP, async events.
- `urma_dp_api.c`: data-plane APIs: post send/receive work requests, poll completions.
- `urma_provider.h`: provider ABI for user-space drivers like UDMA.

### `src/urma/hw/udma`

The user-space UDMA provider:

```text
src/urma/hw/udma/
  udma_u_ops.c
  udma_u_main.c
  udma_u_abi.h
  udma_u_common.h
  udma_u_db.c
  udma_u_buf.c
  udma_u_jfc.c
  udma_u_jfs.c
  udma_u_jfr.c
  udma_u_jetty.c
  udma_u_segment.c
  udma_u_tid.c
  udma_u_ctrlq_tp.c
  udma_u_ctl.c
```

Provider role:

- Register provider ops named `udma`.
- Install `UDMA_OPS` as the implementation of URMA operations for UB transport.
- Create provider-specific context.
- Allocate/mmap doorbell and reserved SQ resources.
- Allocate and manage JFC/JFS/JFR/Jetty objects.
- Register/import/unimport segments.
- Post work requests in user space.
- Poll and parse completion queue entries.
- Handle async events and completion events.
- Expose user-control extensions.

The provider README describes it as `u-udma`, paired with kernel `k-udma`. The data path is intended to bypass the kernel after setup; the control path uses ioctls when kernel/hardware state must be created or changed.

### `src/urma/lib/uvs`

UVS/TPSA support:

```text
src/urma/lib/uvs/
  core/
    tpsa_api.c
    tpsa_ioctl.c
    uvs_private_api.c
    uvs_ubagg_ioctl.c
```

From the names and package output, this provides TPSA/UVS runtime integration, ioctl wrappers, UB aggregation ioctl support, and private APIs used around transport/path setup. The Service Core docs refer to UVS in the virtualization stack as handling negotiation and establishment of transport-layer resources.

### URMA Tools

| Tool | Path | Purpose |
| --- | --- | --- |
| `urma_admin` | `src/urma/tools/urma_admin` | Device/resource query and configuration via sysfs/netlink |
| `urma_perftest` | `src/urma/tools/urma_perftest` | Latency/bandwidth tests over send/recv, read/write, atomics |
| `urma_ping` | `src/urma/tools/urma_ping` | Connectivity and diagnostic tool |

## URPC Component Layout

URPC lives under `src/urpc`:

```text
src/urpc/
  framework/
    lib/
    protocol/
  umq/
    qbuf/
    umq_ipc/
    umq_ub/
    umq_ubmm/
  include/
    framework/
    umq/
  examples/
  tools/
  util/
```

URPC high-level roles:

- Framework layer: function registration/call protocol and RPC abstractions.
- UMQ layer: message queue transport with IPC, UB, and UBMM variants.
- QBUF layer: buffer pool implementations, including huge and shared-memory pools.
- Tools: admin and performance tests.

The OS reference design says URPC builds on URMA/UDMA concepts to provide unified RPC semantics. A URPC channel carries request/ack/response messages and queues map to underlying Jetties or memory resources depending on mode.

## CAM Component Layout

CAM lives under `src/cam`:

```text
src/cam/
  README.md
  comm_operator/
    ascend_kernels/
    pybind/
  examples/
```

The public UMDK README describes CAM as a SuperPoD communication acceleration library for AI training and inference/promotion communication, with northbound integration into communities such as vLLM, SGLang, and VeRL and southbound integration with Ascend SuperPoD hardware/networking.

The local file names show current emphasis on MoE-style operations:

- `fused_deep_moe`
- `moe_dispatch_prefill`
- `moe_combine_prefill`
- `moe_dispatch_shmem`
- `moe_combine_shmem`

CAM appears to be an upper-layer acceleration library over the lower UB/URMA/URPC substrate.

## ULOCK Component Layout

ULOCK currently exposes `dlock`:

```text
src/ulock/
  dlock/
    include/
    lib/
    examples/
    tools/
```

The public README describes ULOCK as unified state synchronization with distributed lock support. It is packaged as:

- `libdlockm.so`
- `libdlocks.so`
- `libdlockc.so`
- dlock headers
- dlock examples

It depends on `umdk-urma-lib`, suggesting URMA is the underlying communication/memory-semantic substrate.

## USOCK/UMS Component Layout

USOCK currently maps to UMS:

```text
src/usock/
  ums/
    kmod/ums/
      ums_mod.c
    tools/
      ums-preload.c
      ums_run
      ums_admin/
```

The public README describes USOCK as compatible with the standard socket API and enabling TCP applications to improve communication performance without modifications. The local packaging includes:

- `ums.ko`
- `libums-preload.so`
- `ums_run`

This suggests an interception/preload path plus kernel module support.

## Kernel-Side Architecture in `kernel-ub`

Relevant kernel paths:

```text
kernel-ub/drivers/ub/
  urma/
    ubcore/
    uburma/
  hw/
    hns3/
```

### `uburma`

`uburma` is the user-kernel command bridge. It implements the command dispatcher for `/dev/uburma/<dev>`.

Important file:

```text
drivers/ub/urma/uburma/uburma_cmd.c
```

Important responsibilities:

- Copy command structures from user space.
- Own per-file user object tables.
- Create and bind user contexts.
- Allocate/free token IDs.
- Register/import/unregister/unimport segments.
- Create/delete JFC, JFS, JFR, Jetty, JFCE, Jetty groups.
- Import/unimport/bind/unbind remote Jetty/JFR resources.
- Dispatch user-control and transport commands.
- Return object handles and provider-private response data to user space.

The command table maps `UBURMA_CMD_*` IDs to functions such as `uburma_cmd_create_ctx`, `uburma_cmd_create_jfs`, `uburma_cmd_create_jfr`, `uburma_cmd_create_jfc`, `uburma_cmd_create_jetty`, `uburma_cmd_import_seg`, and `uburma_cmd_import_jetty`.

### `ubcore`

`ubcore` is the shared kernel resource model and device registry.

Important paths:

```text
drivers/ub/urma/ubcore/ubcore_device.c
drivers/ub/urma/ubcore/ubcore_jetty.c
drivers/ub/urma/ubcore/ubcore_segment.c
drivers/ub/urma/ubcore/ubcore_tp.c
drivers/ub/urma/ubcore/ubcore_netlink.c
drivers/ub/urma/ubcore/ubcore_msg.c
```

Responsibilities:

- Register/unregister UB devices.
- Create sysfs attributes consumed by liburma.
- Provide common APIs for context allocation, Jetty resources, segment resources, TP resources, and message exchange.
- Call into provider-specific `ubcore_ops`.
- Manage netlink and UVS interaction.
- Handle EID/SIP/device/port state and topology-adjacent information.

### HNS3 UDMA Kernel Driver

Important path:

```text
drivers/ub/hw/hns3
```

Important files:

| File | Role |
| --- | --- |
| `hns3_udma_main.c` | Device probe, context/mmap, ubcore ops table, device registration |
| `hns3_udma_abi.h` | User/kernel private ABI for the HNS3 UDMA provider |
| `hns3_udma_jfc.c` | Completion queue/context creation and destruction |
| `hns3_udma_jfs.c` | Send queue / QP creation and destruction |
| `hns3_udma_jfr.c` | Receive queue / SRQ-style resource handling |
| `hns3_udma_jetty.c` | Jetty creation and imported target handling |
| `hns3_udma_segment.c` | Memory registration/import |
| `hns3_udma_tp.c` | TP modify/create/transport state |
| `hns3_udma_dca.c` | Dynamic Context Attach support |
| `hns3_udma_db.c` | Doorbell and record-DB handling |
| `hns3_udma_user_ctl.c` | Provider extension commands, including flush CQE, POE, DCA operations |

The driver registers a `struct ubcore_ops` table named `g_hns3_udma_dev_ops`, with callbacks for context allocation, mmap, segment management, JFC/JFS/JFR/Jetty resources, TP operations, send/resp path, user control, and stats.

## Newer OLK-6.6 Kernel UDMA Tree

The newer kernel tree at `/Users/ray/Documents/Repo/kernel` has:

```text
drivers/ub/urma/hw/udma
```

This tree uses generic `udma_*` names rather than `hns3_udma_*`. It also has a large `ubcore_ops` table and similar resource modules:

- `udma_main.c`
- `udma_cmd.c`
- `udma_common.c`
- `udma_ctx.c`
- `udma_db.c`
- `udma_tid.c`
- `udma_eq.c`
- `udma_jfc.c`
- `udma_jfs.c`
- `udma_jfr.c`
- `udma_jetty.c`
- `udma_jetty_group.c`
- `udma_segment.c`
- `udma_ctrlq_tp.c`
- `udma_eid.c`
- `udma_mue.c`
- `udma_dfx.c`

This appears closer to the current UMDK user provider naming, but it should still be verified against branch/tag metadata before using it as the exact pair for `d04677a`.

## Layered Architecture

The practical stack for URMA/UDMA looks like:

```text
Application
  Uses URMA, URPC, CAM, ULOCK, or socket-compatible APIs

UMDK upper components
  CAM / URPC / ULOCK / USOCK
  Often depend on URMA or UB memory semantics

liburma public API
  Context, device, Jetty, Segment, TP, post/poll APIs

liburma provider layer
  Provider discovery, device matching, ops dispatch

u-udma provider
  User-space queue buffers, doorbells, CQ parsing, provider-private commands

/dev/uburma/<dev> ioctl path
  Command/control plane into kernel

uburma
  Per-file context, user objects, command dispatcher

ubcore
  Common URMA resource model and device registry

k-udma / hns3_udma
  Hardware-specific context, memory, queue, TP, event, and stats implementation

UBASE / UMMU / UB hardware
  Memory translation, DMA, transport, completion, and access control
```

## Component Boundaries

### Application Boundary

Applications should usually call URMA APIs, not UDMA-specific APIs. The UDMA README explicitly says application developers should write against URMA; UDMA is selected internally by provider matching.

### Provider Boundary

`urma_provider.h` defines the contract between liburma and provider modules. The UDMA provider implements this contract through `g_udma_ops` and `g_udma_provider_ops`.

The provider owns:

- Provider-private command input/output structs.
- User-space buffers and doorbell mappings.
- Fast data-plane implementations.
- Completion parsing.
- Hardware-specific user-control paths.

### Kernel Command Boundary

`urma_cmd.c` and `urma_cmd_tlv.c` encode commands. `uburma_cmd.c` decodes them. This boundary carries:

- Generic URMA command metadata.
- Generic URMA object handles.
- Provider-private `udrv_data` input/output payloads.

### ubcore Boundary

`ubcore` owns common semantics and object lifecycle rules, but delegates hardware-specific implementation to `ubcore_ops`.

### Hardware Boundary

The HNS3/UDMA driver owns:

- PCI/auxiliary-device interaction.
- Capability discovery.
- Context and UAR allocation.
- Queue context programming.
- Memory-table programming.
- Doorbell mappings.
- Error/event reporting.
- Statistics.

## Dependencies and Runtime Load Order

The UMDK README and QuickStart list the typical runtime prerequisites:

1. `ubfi`
2. `ummu-core`
3. hardware-specific UMMU
4. `ubus`
5. vendor `hisi_ubus`
6. `ubase`
7. `unic`
8. `cdma`
9. `ubcore`
10. `uburma`
11. `udma`
12. optional `ubagg`
13. optional `ums`

This order explains the dependency chain:

- UDMA depends on UB/UBASE/UMMU foundations.
- URMA user space depends on `/sys/class/ubcore` and `/dev/uburma`.
- Multipath/bonding depends on `ubagg`.
- Socket compatibility depends on UMS.

## Architecture Risks and Things To Verify

- The current UMDK source uses `src/urma/hw/udma`, while `kernel-ub` uses `drivers/ub/hw/hns3`; naming and ABI may reflect different generations.
- The current UMDK README targets kernel 6.6, while local `kernel-ub` is OLK-5.10.
- The newer `/Users/ray/Documents/Repo/kernel` tree likely better matches the generic `udma` naming, but release pairing is not yet proven.
- Some local UnifiedBus forum PDFs are scanned slides; extracted text is not reliable enough for detailed citation.
- CAM, ULOCK, and USOCK were mapped architecturally but not yet traced line-by-line.
