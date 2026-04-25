# UMDK End-to-End Platform Workflow

Last updated: 2026-04-25

This document connects the individual UMDK notes into one boot-to-data-path
workflow. The older working-flow notes focus mainly on URMA/UDMA API behavior;
this file adds the missing platform lifecycle: firmware discovery, UB bus
enumeration, udev-visible devices, UMMU setup, user-space discovery, resource
creation, data movement, and teardown.

## One-Line Summary

The complete path is:

```text
firmware UBRT/UBIOS
  -> ubfi creates UBC/UMMU platform knowledge
  -> ub bus registers and enumerates ub_entity devices
  -> ubase binds UB entities and creates auxiliary devices
  -> udma auxiliary driver registers ubcore_device objects
  -> ubcore and uburma expose sysfs and /dev nodes
  -> liburma discovers devices and opens /dev/uburma/<device>
  -> application creates context, queues, Jetty, Segment, and WRs
  -> UDMA maps memory through UMMU and drives UB transactions
  -> completions/events flow back through JFC and uburma
```

## Layered View

| Layer | Main implementation | Main artifacts |
| --- | --- | --- |
| Firmware interface | `drivers/ub/ubfi` | UBRT/UBIOS root table, UBC table, UMMU table, reserved memory table. |
| UB bus core | `drivers/ub/ubus` | `ub_bus_type`, `ub_entity`, topology enumeration, UB services, uevents. |
| UB base device layer | `drivers/ub/ubase` | `ub_driver` binding, `ubase_dev`, auxiliary devices, reset and debugfs hooks. |
| URMA kernel core | `drivers/ub/urma/ubcore` | `ubcore_device`, resource APIs, sysfs, `/dev/ubcore`. |
| User/kernel bridge | `drivers/ub/urma/uburma` | `/dev/uburma/<device>`, ioctl command dispatcher, mmap, uobject lifecycle. |
| UDMA kernel provider | `drivers/ub/urma/hw/udma` | Auxiliary driver, `ubcore_ops`, queue/Jetty/Segment/TID/EID implementation. |
| UMDK user space | `ub-stack/umdk/src/urma` | liburma core, provider loading, UDMA userspace provider, examples/tools. |

## Workflow 1: Firmware to UB Bus

1. `ubfi` starts and decides whether firmware is ACPI or DTS based.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ub_fi.c`
   - `ubfi_init()` calls `ub_firmware_mode_init()`, obtains UBRT/UBIOS, and
     dispatches `handle_acpi_ubrt()` or `handle_dts_ubrt()`.

2. The root table is split into sub-tables.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ubrt.c`
   - ACPI uses `ACPI_SIG_UBRT`, "UBRT".
   - DTS uses the `/chosen` property `linux,ubios-information-table`.
   - The table types include:
     - `UB_BUS_CONTROLLER_TABLE`
     - `UMMU_TABLE`
     - `UB_RESERVED_MEMORY_TABLE`

3. UBC entries become kernel devices.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ubc.c`
   - `parse_ubc_table()` reads CNA/EID ranges, cluster mode, feature bits,
     and per-controller nodes.
   - `create_ubc()` allocates a `struct ub_bus_controller`.
   - `init_ubc()` calls `device_initialize()`, names the device
     `ub_bus_controller%u`, and calls `device_add()`.
   - The UBC is inserted into the global `ubc_list`.

4. UMMU entries update platform UMMU devices.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ummu.c`
   - `parse_ummu()` reads `struct ummu_node` records.
   - ACPI path finds `HISI0551` and `HISI0571` devices.
   - DTS path finds compatible nodes `ub,ummu` and `ub,ummu_pmu`.
   - Devices are renamed to `ummu.N` or `ummu_pmu.N`, resources are attached,
     proximity is set, and `ubrt_fwnode` records link firmware entries to
     Linux devices.

5. The generic UB bus is registered.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c`
   - `ub_bus_type` has `.name = "ub"`.
   - `postcore_initcall(ub_driver_init)` registers the bus early.
   - Its DMA configuration path configures DMA/IOMMU state for UB entities.

## Workflow 2: UB Manage Subsystem to Entity Enumeration

1. The vendor management driver registers itself.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/vendor/hisilicon/hisi-ubus.c`
   - `hisi_ubus_driver_register()` calls
     `register_ub_manage_subsystem_ops()`.
   - The same module registers a platform driver matching `HISI0581` or
     `hisi,ubus`.

2. Management ops trigger host probing.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c`
   - `register_ub_manage_subsystem_ops()` checks vendor match against UBC
     GUID vendor bits and calls `ub_host_probe()`.

3. `ub_host_probe()` constructs the operational UB bus environment.
   - Initializes config ops.
   - Probes UBC controllers.
   - Calls `ub_enum_probe()`.
   - Initializes dynamic bus attributes.
   - Registers `ub_service_bus_type`.
   - Initializes UB services and UB cdev.
   - Registers RAS handlers and message receive path.

4. Enumeration scans topology and creates `ub_entity` devices.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/enum.c`
   - `ub_enum_bus_controllers()` creates the root/controller entities.
   - `ub_enum_do_topo_scan()` performs breadth-first topology discovery
     through ports and GUIDs.
   - `ub_enum_entities_active()` calls `ub_setup_ent()`,
     `ub_entity_add()`, and `ub_start_ent()` for active entities.

5. Linux driver core matches `ub_driver` instances.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c`
   - `ub_bus_type_init()` installs match/probe/remove/shutdown/uevent
     callbacks.
   - `ub_bus_match()` uses UB vendor/device/module/class identifiers.
   - `ub_entity_probe()` dispatches to the matched `struct ub_driver`.

## Workflow 3: ubase to UDMA to ubcore

1. `ubase` registers as a UB bus driver.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_main.c`
   - `ubase_init()` registers debugfs and calls `ubase_ubus_register_driver()`.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_ubus.c`
   - `ubase_ubus_driver` is a `struct ub_driver` with an id table declared
     through `MODULE_DEVICE_TABLE(ub, ubase_ubus_tbl)`.

2. `ubase_ubus_probe()` initializes a matched `ub_entity`.
   - It calls `ub_set_user_info()`.
   - It allocates `struct ubase_dev`.
   - It copies entity TID/EID/UPI/controller information.
   - It initializes UB resources through `ubase_ubus_init()`.
   - It initializes the base device with `ubase_dev_init()`.
   - It registers share-port operations.

3. UDMA binds through the auxiliary bus.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c`
   - `udma_drv` is an `auxiliary_driver` named `udma`.
   - `udma_id_table` matches `UBASE_ADEV_NAME ".udma"`.
   - `udma_init()` calls `auxiliary_driver_register(&udma_drv)`.

4. UDMA creates and registers an `ubcore_device`.
   - `udma_probe()` calls `udma_init_dev()`.
   - `udma_set_ubcore_dev()` fills:
     - `transport_type = UBCORE_TRANSPORT_UB`
     - `ops = &g_dev_ops`
     - parent and DMA device
     - device name such as `udma%hu`
     - driver name `udma`
   - It calls `ubcore_register_device()`.

5. `ubcore_register_device()` makes the device visible to upper layers.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_device.c`
   - It initializes the ubcore device.
   - It creates the main/logical device under the `ubcore` class.
   - It configures device attributes.
   - It registers cgroup state.
   - It notifies registered ubcore clients, including uburma.

6. `uburma` creates the per-device user ABI endpoint.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/uburma/uburma_main.c`
   - `uburma_init()` registers the `uburma` class and ubcore client.
   - `uburma_add_device()` creates a cdev and class device.
   - The devnode callback returns `uburma/<device>`, so userspace sees
     `/dev/uburma/<device>`.

## Workflow 4: udev and User-Space Discovery

There are two separate visibility paths:

1. UB bus devices under `/sys/bus/ub/devices`
   - The UB bus emits uevents with:
     - `UB_ID`
     - `UB_MODULE`
     - `UB_TYPE`
     - `UB_CLASS`
     - `UB_VERSION`
     - `UB_SEQ_NUM`
     - `UB_ENTITY_NAME`
     - `MODALIAS=ub:v...`
   - This enables module autoload and udev inspection for UB entities.

2. Character-device classes under `/sys/class/ubcore` and `/sys/class/uburma`
   - `ubcore` creates `/dev/ubcore` and class entries.
   - `uburma` creates `/dev/uburma/<device>` for each registered URMA device.
   - The source sets default node permissions to `0666` for uburma.

The local source search did not find custom udev rule files for UMDK. Device
node naming and default mode are driven by kernel class `devnode` callbacks,
not by repository-shipped udev rules.

## Workflow 5: Application to URMA Context

1. Application calls liburma APIs.
   - Source root: `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma`
   - liburma loads providers and scans sysfs class paths.
   - The UDMA userspace provider creates provider-specific command payloads.

2. Device discovery reads sysfs and builds `urma_device_t`.
   - Source: `src/urma/lib/urma/core/urma_device.c`
   - Discovery checks UB class paths, parses device attributes, matches
     providers, and builds the device path under `/dev/uburma`.

3. Context creation opens `/dev/uburma/<device>`.
   - User-space provider wraps ioctls.
   - `uburma_open()` creates a file context.
   - `create_context` allocates a kernel UDMA user context.

4. UDMA allocates a user SVA/TID context.
   - Source: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_ctx.c`
   - `udma_alloc_ucontext()` obtains a UMMU-backed TID:
     - normal SVA mode: `ummu_sva_bind_device()` and `ummu_get_tid()`
     - separated mode: `ummu_alloc_tdev_separated()`
   - The response returns UDMA capabilities to the userspace provider.

## Workflow 6: Resource Setup

Typical application setup:

```text
open device
  -> create context
  -> create JFC
  -> create JFS/JFR
  -> create Jetty
  -> allocate/register Segment
  -> exchange EID/Jetty/Segment information out of band
  -> import remote Jetty or Segment
  -> bind Jetty/TP as needed
```

Main kernel path:

```text
liburma/provider ioctl wrapper
  -> /dev/uburma/<device>
  -> uburma command parser
  -> ubcore resource API
  -> udma ubcore_ops implementation
  -> UMMU/UBASE/UDMA hardware path
```

The important memory path is:

```text
urma_register_seg()
  -> uburma_cmd_register_seg()
  -> ubcore_register_seg()
  -> udma_register_seg()
  -> udma_umem_get()
  -> pin_user_pages_fast() or kernel page lookup
  -> UMMU grant or MATT map
  -> token_id/token_value returned to user
```

## Workflow 7: Data Path

For a one-sided write/read:

```text
application prepares SGE with local Segment and remote target Segment
  -> provider formats WQE
  -> user posts WR to JFS/SQ
  -> doorbell notifies UDMA hardware
  -> UDMA validates local and remote addressing through TID/token/UMMU state
  -> UB transaction crosses the fabric
  -> target side enforces permission/token/translation
  -> completion is generated into JFC/CQ
  -> application polls JFC
```

For two-sided send/recv:

```text
receiver posts JFR/RQ buffers
  -> sender posts JFS/SQ send WR
  -> Jetty/TP selects transport path
  -> completion appears on sender and receiver JFCs
```

The key difference from conventional verbs is that UB/URMA exposes Jetty and
Segment objects but the memory enforcement model is UMMU/TID/token based,
rather than only HCA lkey/rkey plus IOMMU/DMA mapping.

## Workflow 8: Teardown and Hot Remove

Normal application teardown:

```text
destroy/imported remote objects
  -> unregister/unimport Segments
  -> destroy Jetty/JFS/JFR/JFC
  -> free context
  -> close /dev/uburma/<device>
```

Kernel teardown:

```text
udma_remove()
  -> ubcore_stop_requests()
  -> close UE RX path
  -> ubcore_unregister_device()
  -> ubcore_clients_remove()
  -> uburma_remove_device()
  -> destroy /dev/uburma/<device>
  -> cleanup ucontexts/uobjects/mmaps
  -> destroy UDMA workqueues and events
```

UMMU teardown:

```text
unregister Segment
  -> ungrant UMMU range or unmap MATT
  -> unpin pages
  -> free token/TID when refcount allows
free context
  -> ummu_core_invalidate_cfg()
  -> unbind SVA or free separated TDEV
device remove
  -> ungrant device KSVA range
  -> unbind stored KSVA entries
  -> disable KSVA/SVA/IOPF features
```

## Workflow 9: Debug Triage by Layer

| Symptom | First layer to inspect | Commands or source anchors |
| --- | --- | --- |
| No UB devices | Firmware/UBRT/UBIOS | `dmesg` for `ubfi`, `ubrt`, `ubc`, `ummu`; inspect `drivers/ub/ubfi`. |
| UBC exists but no UB entities | UB topology enumeration | `dmesg` for `ub_enum_probe`, `topo_scan`, `ub_entity_add`. |
| Entity exists but ubase not bound | UB bus match/probe | `udevadm info`, `MODALIAS=ub:*`, `drivers/ub/ubase/ubase_ubus.c`. |
| UDMA probe failed | Auxiliary bus/UBASE/UDMA | `dmesg` for `udma init dev`, `auxiliary_driver`, `ubase` reset callbacks. |
| No `/dev/uburma/<device>` | ubcore/uburma client path | Check `/sys/class/ubcore`, `/sys/class/uburma`, `ubcore_register_device`, `uburma_add_device`. |
| `register_seg` fails | UMMU/segment path | Check `udma_register_seg`, `udma_umem_get`, `ummu_sva_grant_range`, `udma_ioummu_map`. |
| Completion errors | UDMA queue/TP/data path | Check JFS/JFR/JFC queues, TP setup, EID table, UMMU token/permission. |

## What This Adds Over the Existing Working-Flow Doc

`urma-udma-working-flows.md` already covers the URMA/UDMA operation flows. This
document fills in the lower layers that were previously implicit:

- Firmware root table handling.
- UB controller and UMMU creation.
- `ub_bus_type` registration and ub_entity enumeration.
- UB bus uevents and udev visibility.
- ubcore and uburma device-node creation.
- UMMU lifecycle from probe to segment registration and teardown.

