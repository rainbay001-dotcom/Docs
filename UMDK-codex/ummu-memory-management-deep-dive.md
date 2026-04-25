# UMMU Memory Management Deep Dive for UMDK, URMA, and UDMA

Last updated: 2026-04-25

This document traces the UMMU-related lifecycle from firmware discovery through
UDMA probe, URMA context creation, token/TID allocation, Segment registration,
MATT/MAPT mapping, and teardown.

The main conclusion: in UMDK/URMA/UDMA, memory registration is not just an
RDMA-style "pin pages and hand an rkey to hardware" flow. It is a UB-specific
translation and authorization pipeline built around UMMU, TID, token, EID, and
Segment semantics.

## Source Anchors

| Concern | Source |
| --- | --- |
| UMMU firmware node definition | `/Users/ray/Documents/Repo/kernel/include/ub/ubfi/ubfi.h` |
| UMMU table parsing | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ummu.c` |
| UBC to UMMU mapping | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ubc.h` |
| UB bus DMA/IOMMU setup | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c` |
| UDMA probe-time UMMU setup | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c` |
| UDMA user context and user TID | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_ctx.c` |
| UDMA token/TID allocation | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_tid.c` |
| UDMA Segment registration | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_segment.c` |
| UDMA page pinning and MATT mapping | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_common.c` |
| UDMA EID to UMMU sync | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_eid.c` |
| uburma Segment ioctl bridge | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/uburma/uburma_cmd.c` |
| ubcore Segment API | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_segment.c` |
| UMDK URMA APIs | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma` |

## Mental Model

UMMU provides the translation and permission substrate for UB memory semantics.
UDMA is the URMA hardware provider that uses that substrate.

The practical model is:

```text
EID identifies the UB endpoint
TID identifies a translation/authorization context
Token ID selects a registered Segment/TID namespace
Token Value authorizes remote access when token policy requires it
Segment describes the address range, permissions, EID, and token state
UMMU grants or maps ranges so UB transactions can access them
```

The most important implementation distinction is the split between:

- `MAPT`/range-grant style: grant an address range to an SVA/KSVA context.
- `MATT`/map-table style: map pinned pages through a MATT domain for a local
  and remote TID pair.

The exact hardware table layout is not implemented in UMDK itself, but the
kernel UDMA driver calls UMMU core APIs that expose those concepts.

## Firmware-Level UMMU Model

The firmware UMMU node is defined in:

```text
/Users/ray/Documents/Repo/kernel/include/ub/ubfi/ubfi.h
```

`struct ummu_node` contains:

| Field | Meaning |
| --- | --- |
| `base_addr`, `addr_size` | UMMU register-space base and size. |
| `intr_id` | UMMU interrupt ID. |
| `pxm` | Proximity domain / NUMA placement. |
| `its_index` | Interrupt Translation Service association. |
| `pmu_addr`, `pmu_size`, `pmu_intr_id` | UMMU PMU resources. |
| `min_tid`, `max_tid` | Token ID / TID allocation range exposed by firmware. |
| `vendor_id`, `vendor_info` | Vendor-specific UMMU information. |

Firmware association from UBC to UMMU is reported in `struct ubc_node`:

```text
ummu_mapping: Indicates the association between this UBC and UMMU,
using the UMMU Index, which is represented by the UMMU serial number
in the UMMU information table.
```

This is why UMMU belongs in the platform lifecycle, not only in the Segment
registration lifecycle.

## UMMU Device Creation

`ubfi` parses UMMU data through:

```text
handle_ummu_table()
  -> parse_ummu()
  -> acpi_update_ummu_config() or dts_update_ummu_config()
```

ACPI path:

- ACPI HID `HISI0551`: UMMU device.
- ACPI HID `HISI0571`: UMMU PMU device.
- `_UID` selects the UMMU table index.
- `bus_find_device_by_acpi_dev(&platform_bus_type, adev)` locates the Linux
  platform device.

DTS path:

- Compatible `ub,ummu`.
- Compatible `ub,ummu_pmu`.
- `index` selects the UMMU table index.

Common update:

- Rename platform device to `ummu.N` or `ummu_pmu.N`.
- Set NUMA/proximity node.
- Add memory resources.
- Add vendor data to UMMU devices.
- Store fwnode mapping through `ubrt_fwnode_add()` and `ubrt_fwnode_set()`.

At this stage no URMA Segment exists. The kernel is preparing platform UMMU
devices so later bus and UDMA drivers can use UMMU core services.

## UB Bus DMA and IOMMU Configuration

The UB bus is defined in:

```text
/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c
```

The bus type has DMA hooks:

```text
struct bus_type ub_bus_type = {
    .name = "ub",
    .dma_configure = ub_dma_configure,
    .dma_cleanup = ub_dma_cleanup,
};
```

`ub_dma_configure()`:

- Finds the owning UBC for the UB entity.
- Uses `ub_dma_attr_trans(ubc->attr.dma_cca)` for coherence attributes.
- Calls `ub_hybrid_dma_configure()`.
- Uses the default IOMMU domain unless the driver manages DMA itself.

`ub_hybrid_iommu_configure()`:

- Checks existing fwspec ops.
- Builds an IOMMU fwspec through UMMU ops.
- Calls `iommu_probe_device(dev)` when needed.

The practical point: when a UB entity binds to a UB driver, the UB bus configures
the DMA/IOMMU context using firmware-provided UBC/UMMU data. This is below
URMA, but URMA memory registration depends on it.

## UDMA Probe-Time UMMU Setup

UDMA probe is in:

```text
/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c
```

The driver is an auxiliary driver. After probe starts, UDMA initializes a device
and registers it to ubcore. The UMMU-specific probe setup appears in the device
TID setup path:

```text
udma_alloc_dev_tid()
  -> udma_enable_usva()
       -> ummu_get_sva_mode()
       -> iommu_dev_enable_feature(IOPF)
       -> iommu_dev_enable_feature(SVA)
  -> iommu_dev_enable_feature(KSVA)
  -> ummu_ksva_bind_device(..., MAPT_MODE_TABLE)
  -> ummu_get_tid()
  -> ummu_sva_grant_range(ksva, 0, UDMA_MAX_GRANT_SIZE, READ | WRITE)
```

Important concepts:

| Concept | Meaning |
| --- | --- |
| IOPF | I/O page fault support. Required so device-side address faults can be handled. |
| SVA | Shared Virtual Addressing for user address-space binding. |
| KSVA | Kernel SVA binding for kernel/device-level mappings. |
| `MAPT_MODE_TABLE` | UMMU mode used when binding KSVA for UDMA. |
| Device TID | TID assigned to the UDMA device's own KSVA context. |

On teardown, `udma_free_dev_tid()`:

- Ungrants the full device KSVA range.
- Iterates and unbinds stored KSVA entries in `ksva_table`.
- Unbinds the device KSVA.
- Disables KSVA.
- Disables USVA/SVA/IOPF features through `udma_disable_usva()`.

## User Context TID

User context allocation is in:

```text
/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_ctx.c
```

`udma_alloc_ucontext()` allocates `struct udma_context` and calls
`udma_get_usva_tid()`.

There are two modes:

| Mode | Flow |
| --- | --- |
| Normal SVA mode | `ummu_sva_bind_device(dev->dev, current->mm, NULL)` then `ummu_get_tid()`. |
| Separated SVA mode | `ummu_alloc_tdev_separated(&ctx->tid)`. |

The context stores:

- `ctx->tid`
- `ctx->mm`
- UMMU/SVA handle
- page/hugepage tracking lists
- UDMA capability response data returned to userspace

On context free:

```text
udma_free_ucontext()
  -> ummu_core_invalidate_cfg(tid, mm)
  -> destroy page tracking
  -> unbind SVA or free separated TDEV
```

The `ummu_core_invalidate_cfg()` call is important. It tells UMMU that the
context's translation configuration should no longer be used.

## Token ID and TID Allocation

URMA exposes token-related operations through ubcore, and UDMA implements them
as TID-backed token IDs.

The upper path:

```text
ubcore_alloc_token_id()
  -> dev->ops->alloc_token_id()
  -> udma_alloc_tid()
```

UDMA implementation:

```text
udma_alloc_tid()
  if called from user udata:
      copy TID from user input
      token_id = tid
      tid = token_id >> UDMA_TID_SHIFT
  else:
      ummu_ksva_bind_device(..., MAPT_MODE_TABLE)
      ummu_get_tid()
      store ksva in udma_dev->ksva_table
      token_id = tid << UDMA_TID_SHIFT
```

So, in this driver:

- user-mode token IDs can be provided by user/provider command payload,
- kernel-mode token IDs are allocated by binding KSVA and asking UMMU for a TID,
- `ksva_table` maps TID to KSVA handle for later grant/ungrant and unbind.

On `udma_free_tid()`:

- user-mode TID: invalidate UMMU config for the context/mm.
- kernel-mode TID: lookup KSVA by TID, unbind it, erase it from `ksva_table`.

## Segment Registration Path

The full path from liburma to UMMU is:

```text
application
  -> urma_register_seg()
  -> UDMA userspace provider ioctl wrapper
  -> /dev/uburma/<device>
  -> uburma_cmd_register_seg()
  -> ubcore_register_seg()
  -> udma_register_seg()
  -> udma_umem_get()
  -> UMMU grant or MATT map
```

### uburma Layer

`uburma_cmd_register_seg()`:

- Parses command TLV.
- Looks up optional token-ID uobject.
- Fills `struct ubcore_seg_cfg`.
- Creates a Segment uobject.
- Calls `ubcore_register_seg()`.
- Returns:
  - Segment handle.
  - `token_id`.

### ubcore Layer

`ubcore_register_seg()`:

- Validates device ops.
- Validates access flags.
- Checks token-id validity for UB transport.
- Allocates a token ID when needed.
- Calls provider `dev->ops->register_seg()`.
- Fills common Segment metadata:
  - length,
  - virtual address,
  - EID,
  - Segment attributes,
  - token ID,
  - ucontext.
- Increments token-ID use count.

Access validation includes:

- `LOCAL_ONLY` cannot be combined with read/write/atomic.
- write requires read.
- atomic requires read and write.

### UDMA Layer

`udma_register_seg()`:

- Validates token ID, access, and token policy.
- Initializes UDMA Segment state.
- Converts `ubcore_token_id` to UDMA TID.
- Pins memory unless non-pin behavior is requested.
- Chooses one of two UMMU paths:
  - separated SVA user mode: pin pages and `udma_ioummu_map()`
  - kernel mode: `ummu_sva_grant_range()`

## Page Pinning

Page pinning is implemented in:

```text
/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_common.c
```

For user pages:

```text
udma_umem_get()
  -> udma_get_target_umem()
  -> udma_pin_all_pages()
  -> pin_user_pages_fast(..., FOLL_LONGTERM | FOLL_HONOR_NUMA_FAULT)
  -> sg_alloc_append_table_from_pages()
```

For kernel pages:

```text
udma_k_pin_pages()
  -> vmalloc_to_page() or kmap_to_page()
  -> get_page()
  -> sg_set_page()
```

Unpinning:

```text
udma_umem_release()
  -> udma_unpin_pages()
  -> unpin_user_page_range_dirty_lock() for user pages
  -> put_page() for kernel pages
```

Compared with classic RDMA MR registration, the pinning step is familiar, but
the authorization and translation step is UMMU-specific.

## UMMU Grant Path

The grant path appears in `udma_segment.c`:

```text
udma_sva_grant()
  -> build ummu_seg_attr
  -> derive UMMU permissions from Segment access flags
  -> optional token info
  -> ummu_sva_grant_range(ksva, va, len, perm, seg_attr)
```

Permission mapping:

| URMA/ubcore access | UMMU permission |
| --- | --- |
| read | `UMMU_DEV_READ` |
| read + write | `UMMU_DEV_READ | UMMU_DEV_WRITE` |
| read + write + atomic | `UMMU_DEV_READ | UMMU_DEV_WRITE | UMMU_DEV_ATOMIC` |
| local-only | local-only handling with invalid remote TID in mapping paths |

Token policy:

- If token policy is none, grant uses no token info.
- If token policy is enabled, `ummu_token_info.tokenVal` carries
  `cfg->token_value.token`.
- The token value is cleared after grant/ungrant calls.

This is the path that makes the registered address range accessible according
to UB/URMA permissions and token policy.

## MATT Mapping Path

The MATT path appears through:

```text
udma_ioummu_map()
  -> struct ummu_matt_domain
       l_tid = ctx->tid
       r_tid = remote or invalid TID
       mm = current->mm
  -> ummu_sva_matt_map(domain, addr, sg_table, prot)
```

and teardown:

```text
udma_ioummu_unmap()
  -> ummu_sva_matt_unmap(domain, addr, size)
```

This path is used for:

- separated SVA Segment registration,
- some queue/buffer mappings,
- hugepage/normal page mappings in UDMA context code,
- JFS/JFR/JFC buffer mapping paths.

`r_tid` is set to `UMMU_INVALID_TID` for local-only or internal mappings. For
remote-relevant mappings, UDMA passes the target/remote TID derived from token
or Segment state.

## Segment Import Path

Remote Segment import is lighter in the UDMA kernel implementation:

```text
udma_import_seg()
  -> validate token policy
  -> allocate udma_segment
  -> store token value if present
  -> derive tid from remote token_id
  -> return target segment
```

The imported Segment carries enough metadata for later work requests to address
remote memory:

- remote token ID,
- remote token value when policy requires it,
- derived TID,
- Segment attributes from the exported target Segment.

Actual access enforcement occurs when the WQE/data path reaches UDMA/UMMU and
the target side validates translation, permission, token, and EID state.

## EID Synchronization with UMMU

UDMA also syncs EID information into UMMU core:

```text
ummu_core_add_eid(...)
ummu_core_del_eid(...)
```

Source:

```text
/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_eid.c
/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_common.c
```

Why it matters:

- UB addressing is endpoint based.
- UMMU needs to understand which EID/GUID belongs to which translation context.
- Segment permissions alone are not enough; endpoint identity must also line up.

## JFS/JFR/JFC Buffer Mapping

UMMU is not only for user-declared data Segments. Queue buffers and doorbells
also cross this path.

Examples:

- `udma_jfs.c` maps JFS/SQ buffers with `udma_ioummu_map()`.
- `udma_jfr.c` maps receive queue buffers and sleep buffers.
- `udma_jfc.c` maps completion queue buffers and handles TID lists.
- `udma_ctx.c` allocates and maps normal pages and hugepages.
- `udma_db.c` pins software doorbell pages.

This means UMMU is part of both:

- application memory registration,
- control/data queue memory backing.

## Teardown Matrix

| Object | Teardown path | UMMU action |
| --- | --- | --- |
| Segment | `uburma_cmd_unregister_seg()` -> `ubcore_unregister_seg()` -> `udma_unregister_seg()` | Ungrant range or unmap MATT, unpin pages, clear token value. |
| Token/TID | `ubcore_free_token_id()` -> `udma_free_tid()` | Invalidate user config or unbind kernel KSVA. |
| User context | `ubcore_free_ucontext()` -> `udma_free_ucontext()` | `ummu_core_invalidate_cfg()`, free TID/SVA state. |
| UDMA device | `udma_remove()` -> `udma_free_dev_tid()` | Ungrant device KSVA range, unbind KSVA table, disable KSVA/SVA/IOPF. |
| UB entity | `ub_entity_remove()` / `ub_enum_remove()` | Driver remove path eventually tears down ubase/UDMA state. |

## Comparison with RDMA Memory Registration

| Topic | RDMA verbs / IB / RoCE | UB/URMA/UDMA with UMMU |
| --- | --- | --- |
| Memory object | MR | Segment |
| Local access key | lkey | local Segment/token/TID state |
| Remote access key | rkey | token ID plus optional token value and Segment metadata |
| Endpoint identity | GID/LID/QP context | EID/GUID plus TID/token context |
| Translation | HCA page tables, IOMMU, MTT/MPT depending on device | UMMU SVA/KSVA, MAPT/MATT, TID-indexed domains |
| Permission | MR access flags | Segment access flags translated to UMMU permissions |
| Registration path | ib_uverbs -> ib_core -> provider -> pin/map | uburma -> ubcore -> UDMA -> pin/map/grant through UMMU |
| Remote authorization | rkey capability | token policy and token value, plus UMMU permission checks |
| Queue buffer mapping | provider-specific | UDMA maps queue buffers through UMMU helpers too |

The user-facing shape is similar enough that `Segment` maps conceptually to
MR, but the design center is different. RDMA primarily exposes protection
domains, MRs, QPs, and CQs. UB/URMA exposes EID, Jetty, Segment, token, and
UMMU-backed translation, making memory permission a UB fabric concept rather
than only a NIC-local registration concept.

## Failure Modes

| Failure | Likely layer | Source clues |
| --- | --- | --- |
| No UMMU device | firmware/platform | `ubfi/ummu.c`, missing `HISI0551`, `ub,ummu`, or UBRT UMMU table. |
| UDMA probe fails at SVA | UMMU/IOMMU feature enable | `udma_enable_usva()`, `iommu_dev_enable_feature(IOPF/SVA)`. |
| UDMA probe fails at KSVA | kernel SVA binding | `ummu_ksva_bind_device()`, `ummu_get_tid()`. |
| Context create fails | user SVA/TID | `udma_get_usva_tid()`, `ummu_sva_bind_device()`, separated TDEV allocation. |
| Token allocation fails | UMMU TID allocation | `udma_alloc_tid()`, `ummu_get_tid()`, `ksva_table` store. |
| Segment register fails before UMMU | validation/page pin | access flags, token policy, `pin_user_pages_fast()`, sg-table allocation. |
| Segment register fails in UMMU | grant/map | `ummu_sva_grant_range()`, `ummu_sva_matt_map()`. |
| Teardown returns busy | token refcount or active object | `token_id->use_cnt`, uburma uobject cleanup. |
| Completion has access error | data path/UMMU | remote token, permission, EID, TID, or mapping mismatch. |

## Runtime Debug Checklist

On hardware:

```sh
dmesg | rg "ummu|UMMU|SVA|KSVA|IOPF|MATT|MAPT|tid|token|grant|ungrant|matt map"
ls /sys/bus/platform/devices | rg "ummu|ub"
ls /sys/bus/ub/devices
ls /sys/class/ubcore
ls /sys/class/uburma
```

For a failed Segment registration, trace logs around:

```text
uburma_cmd_register_seg
ubcore_register_seg
udma_register_seg
udma_umem_get
pin_user_pages_fast
ummu_sva_grant_range
udma_ioummu_map
ummu_sva_matt_map
```

For teardown leaks, trace:

```text
uburma_cmd_unregister_seg
ubcore_unregister_seg
udma_unregister_seg
ummu_sva_ungrant_range
udma_ioummu_unmap
udma_umem_release
udma_free_tid
udma_free_ucontext
udma_free_dev_tid
```

## Design Takeaways

- UMMU is a platform dependency, not only a data-path feature.
- UB firmware tables associate UBCs and UMMUs before Linux enumerates UB
  entities.
- The UB bus configures DMA/IOMMU state for UB entities.
- UDMA enables IOPF, SVA, and KSVA during device bring-up.
- URMA user contexts obtain UMMU-backed TIDs.
- Token IDs in UDMA are TID-derived.
- Segment registration combines access validation, page pinning, token policy,
  UMMU range grants, and MATT mappings.
- Queue memory also uses UMMU mapping helpers, so UMMU failures can affect
  context, queue creation, Segment registration, and data transfer.
- Compared with RDMA MR/rkey, UB Segment/token/TID is more deeply tied to
  fabric identity and platform memory management.

