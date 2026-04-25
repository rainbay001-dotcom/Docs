# UB Root Bus, udev, and Device Enumeration

Last updated: 2026-04-25

This document focuses on the part that was previously under-covered: how UB
hardware becomes visible to Linux as a bus, how UB entities become driver-core
devices, how udev sees those devices, and how `/dev/ubcore` and
`/dev/uburma/<device>` are created for UMDK.

## Terminology Used Here

| Term | Meaning in this source tree |
| --- | --- |
| UBRT | ACPI "UB Root Table"; firmware-reported root table for UB system information. |
| UBIOS table | DTS/device-tree equivalent root table found through `/chosen/linux,ubios-information-table`. |
| UBC | UB Controller, represented by `struct ub_bus_controller`. |
| UMMU | UB memory-management/translation unit, represented in firmware by `struct ummu_node`. |
| UB bus | Linux `struct bus_type ub_bus_type` with name `ub`. |
| ub_entity | Linux device object for a UB management entity or user entity. |
| ubase | UB base driver that binds to UB entities and bridges toward auxiliary devices. |
| UDMA auxiliary device | Auxiliary-bus device that the UDMA driver probes. |
| ubcore_device | URMA/UDMA device registered to the ubcore resource layer. |
| uburma device | Per-URMA-device character endpoint exposed under `/dev/uburma/<device>`. |

## Source Anchors

| Concern | Source |
| --- | --- |
| Firmware entry point | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ub_fi.c` |
| UBRT/UBIOS root-table parsing | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ubrt.c` |
| UBC table and controller creation | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ubc.c` |
| UMMU table and platform-device updates | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubfi/ummu.c` |
| UB bus definition and DMA/IOMMU hook | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c` |
| UB bus callbacks, uevent, host probe | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c` |
| Topology enumeration | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/enum.c` |
| UB entity data model | `/Users/ray/Documents/Repo/kernel/include/ub/ubus/ubus.h` |
| Hisilicon management driver | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/vendor/hisilicon/hisi-ubus.c` |
| ubase UB driver | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_ubus.c` |
| UDMA auxiliary driver | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c` |
| ubcore class and `/dev/ubcore` | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ubcore/ubcore_device.c` |
| uburma class and `/dev/uburma/<device>` | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/uburma/uburma_main.c` |

## High-Level Device Model

```text
firmware UBRT/UBIOS
  -> UBC nodes
       -> struct ub_bus_controller
       -> Linux device named ub_bus_controllerN
       -> global ubc_list
  -> UMMU nodes
       -> platform devices renamed ummu.N and ummu_pmu.N
       -> firmware node records for UMMU lookup

ub_bus_type ("ub")
  -> ub_entity devices discovered from UB topology
  -> uevents with UB_ID/UB_CLASS/MODALIAS
  -> ubase_ubus_driver binds to matching entities

ubase
  -> initializes UB entity as base device
  -> creates/uses auxiliary devices

udma auxiliary_driver
  -> creates udma_dev
  -> registers ubcore_device

ubcore
  -> creates /sys/class/ubcore/<device>
  -> creates /dev/ubcore
  -> notifies uburma client

uburma
  -> creates /sys/class/uburma/<device>
  -> creates /dev/uburma/<device>
```

## Step 1: Firmware Root Table Discovery

`ubfi_init()` is the first UB-specific kernel entry point in this path.

Important source behavior:

- `ub_firmware_mode_init()` selects ACPI when ACPI is enabled, otherwise DTS.
- ACPI path reads table signature `UBRT`, described in the code as "UB Root
  Table".
- DTS path reads physical address `linux,ubios-information-table` from the
  `/chosen` node.
- `handle_ubrt()` dispatches into ACPI or DTS table parsing.

The table parser handles at least:

| Type | Meaning | Handler |
| --- | --- | --- |
| `UB_BUS_CONTROLLER_TABLE` | UBC/controller information | `handle_ubc_table()` |
| `UMMU_TABLE` | UMMU/PMU information | `handle_ummu_table()` |
| `UB_RESERVED_MEMORY_TABLE` | Reserved memory for virtualized UMMU/IOMMU cases | referenced from ubfi reserved-memory support |

The important design point is that UB does not start at UMDK or ubcore. It
starts from firmware topology and address/interrupt/memory-management metadata.
UMDK can only see a usable URMA device after this lower layer has created and
activated the UB bus devices.

## Step 2: UBC Creation

`handle_ubc_table()` loads the UBC table and calls `parse_ubc_table()`.

`parse_ubc_table()` reads global controller ranges:

- CNA range.
- EID range.
- feature bits.
- cluster mode.
- UBC count.

For each `struct ubc_node`, `create_ubc()` creates a `struct ub_bus_controller`.

Notable fields from `struct ubc_node`:

| Field | Purpose |
| --- | --- |
| `hpa_base`, `hpa_size` | Host physical address window for controller resources. |
| `mem_size_limit` | Maximum addressable memory bit width used later by UB DMA setup. |
| `dma_cca` | DMA cache-coherency attribute translated by UB bus DMA setup. |
| `ummu_mapping` | Association from this UBC to a UMMU index. |
| `proximity_domain` | NUMA/PXM placement. |
| `msg_queue_base`, `msg_queue_size`, `msg_queue_depth` | Controller message queue resources. |
| `msg_int`, `msg_int_attr` | Controller message interrupt. |
| `ubc_guid_low`, `ubc_guid_high` | Controller GUID. |

`init_ubc()` creates a normal Linux `struct device`:

- `device_initialize(dev)`
- `set_dev_node(dev, pxm_to_node(...))`
- `dev_set_name(dev, "ub_bus_controller%u", ctl_no)`
- `device_add(dev)`

The controller is then appended to `ubc_list`.

This is the closest implementation object to a "UB root bus controller". The
Linux bus itself is `ub_bus_type`, but the firmware-derived UBC devices are the
roots from which active UB topology enumeration starts.

## Step 3: UMMU Platform Device Binding

UMMU discovery is parallel to UBC discovery. `handle_ummu_table()` loads UMMU
subtable data and calls `parse_ummu()`.

Each `struct ummu_node` contains:

- UMMU register base and size.
- UMMU interrupt ID.
- proximity/PXM.
- ITS index.
- PMU address/size/interrupt.
- minimum and maximum Token ID.
- vendor ID and vendor info.

ACPI path:

- Finds ACPI HID `HISI0551` for UMMU.
- Finds ACPI HID `HISI0571` for UMMU PMU.
- Uses `_UID` to match table index to platform device.
- Uses `bus_find_device_by_acpi_dev(&platform_bus_type, adev)`.

DTS path:

- Matches `ub,ummu`.
- Matches `ub,ummu_pmu`.
- Uses device-tree `index` to match firmware entries.

Common update:

- Renames devices to `ummu.N` or `ummu_pmu.N`.
- Sets proximity.
- Adds memory resources.
- Attaches vendor data for UMMU devices.
- Stores the Linux fwnode in the UBRT fwnode list.

This is not a URMA object yet. It is the kernel platform-device layer that the
later UMMU core and UB DMA/IOMMU integration depend on.

## Step 4: UB Bus Registration

The generic Linux UB bus is defined in `ub-driver.c`:

```text
struct bus_type ub_bus_type = {
    .name = "ub",
    .dma_configure = ub_dma_configure,
    .dma_cleanup = ub_dma_cleanup,
};
```

`postcore_initcall(ub_driver_init)` registers the bus early with
`bus_register(&ub_bus_type)`.

The bus also owns DMA/IOMMU integration:

- `ubct_dma_setup()` derives DMA masks from UBC memory address limits.
- `ub_hybrid_iommu_configure()` initializes an IOMMU fwspec using UMMU ops.
- `ub_dma_configure()` is called by the driver core when a UB entity binds.

This means the UB bus is not just a matching namespace. It is also the point
where UB entities are attached to the memory-translation model.

## Step 5: Installing UB Bus Callbacks

`ub_bus_type` is registered early, but the callback pointers are installed by
`ub_bus_type_init()` in `ubus_driver.c`:

```text
match    -> ub_bus_match
uevent   -> ub_uevent
probe    -> ub_entity_probe
remove   -> ub_entity_remove
shutdown -> ub_entity_shutdown
```

This split matters:

- `ub-driver.c` defines the bus and generic driver registration APIs.
- `ubus_driver.c` installs UB-specific behavior once management-subsystem
  probing starts.

## Step 6: Vendor Management Subsystem Trigger

Hisilicon management support is in `hisi-ubus.c`.

`hisi_ub_manage_subsystem_ops` provides:

- `controller_probe`
- `controller_remove`
- `ras_handler_probe`
- `ras_handler_remove`

`hisi_ubus_driver_register()` first calls
`register_ub_manage_subsystem_ops(&hisi_ub_manage_subsystem_ops)`, then
registers the platform driver.

`register_ub_manage_subsystem_ops()` checks the vendor bits in known UBC GUIDs.
If the vendor matches, it stores the ops and calls `ub_host_probe()`.

This is the handoff from static firmware-created UBC records to a live UB host
management environment.

## Step 7: Host Probe

`ub_host_probe()` performs the broad UB bus bring-up:

```text
ub_bus_type_init()
  -> ub_cfg_ops_init()
  -> ub_bus_controllers_probe()
  -> ub_enum_probe()
  -> ub_bus_attr_dynamic_init()
  -> bus_register(&ub_service_bus_type)
  -> ub_services_init()
  -> ub_cdev_init()
  -> ras_handler_probe()
  -> message_rx_init()
```

Important implications:

- Topology enumeration happens before user-space URMA devices exist.
- UB services are separate from the main `ub` bus and use `ub_service_bus_type`.
- UB has its own cdev path independent of ubcore/uburma.
- RAS and message receive paths are part of bring-up, not optional user-level
  decoration.

## Step 8: Topology Enumeration

`ub_enum_probe()` is the main topology entry point.

Its core flow:

```text
ub_enum_topo_scan()
  -> ub_enum_bus_controllers()
       -> ub_enum_create_bus_controller()
       -> ub_enum_and_configure_ent()
  -> ub_enum_do_topo_scan()
       -> BFS through UB ports and remote GUIDs
       -> create child ub_entity objects
       -> connect ports
  -> ub_enum_bfs_route_cal()
  -> ub_enum_entities_active()
       -> ub_setup_ent()
       -> ub_entity_add()
       -> ub_start_ent()
```

The important object is `struct ub_entity`, defined in
`include/ub/ubus/ubus.h`. It contains:

- base `struct device dev`
- matched `struct ub_driver *driver`
- vendor/device/class/module identifiers
- EID and CNA
- entity index
- topology parent and UBC pointer
- ports and remote links
- DMA mask and DMA parameters
- token ID/value fields
- sysfs resource attributes
- reset, route, slot, message, and bus-instance state

In RDMA terms, `ub_entity` is lower than `ib_device`. It is a bus-level
fabric/entity device. `ubcore_device` is the closer peer of `ib_device`.

## Step 9: UB uevents and udev

The UB bus exports uevents through `ub_uevent()`.

For each UB entity, the kernel adds:

```text
UB_ID=<vendor>:<device>
UB_MODULE=<module-vendor>:<module>
UB_TYPE=<type>
UB_CLASS=<class>
UB_VERSION=<version>
UB_SEQ_NUM=<sequence>
UB_ENTITY_NAME=<name>
MODALIAS=ub:v<VENDOR>d<DEVICE>mv<MOD_VENDOR>m<MODULE>c<CLASS>
```

These values support:

- udev inspection.
- module autoload through `MODALIAS`.
- debug correlation from sysfs devices to UB identity.

Useful runtime checks on a machine with UB hardware:

```sh
ls /sys/bus/ub/devices
udevadm info -q property -p /sys/bus/ub/devices/<entity>
udevadm monitor --kernel --property --subsystem-match=ub
modinfo ubase
```

The local source tree does not show custom UMDK udev rules. The important
udev-facing data is generated by the UB bus uevent callback and by class device
creation for ubcore/uburma.

## Step 10: ubase Binding

`ubase` registers a `struct ub_driver`:

```text
name      = ubase_ubus_driver_name
id_table  = ubase_ubus_tbl
probe     = ubase_ubus_probe
remove    = ubase_ubus_remove
shutdown  = ubase_ubus_shutdown
```

The id table is exported through:

```text
MODULE_DEVICE_TABLE(ub, ubase_ubus_tbl)
```

This is the module-autoload hook for the UB bus.

When `ubase_ubus_probe()` runs, it:

- Calls `ub_set_user_info(ue)`.
- Allocates `struct ubase_dev`.
- Copies entity TID/EID/UPI/controller number into ubase caps.
- Calls `ubase_ubus_init()`, which enables the UB entity and sets DMA masks.
- Calls `ubase_dev_init()`.
- Registers share-port behavior if applicable.

After this point, UDMA can appear through the auxiliary device path used by
ubase.

## Step 11: UDMA Auxiliary Driver

UDMA is not a direct `ub_driver`. It is an auxiliary driver:

```text
static struct auxiliary_driver udma_drv = {
    .name = "udma",
    .probe = udma_probe,
    .remove = udma_remove,
    .id_table = udma_id_table,
};
```

The id table matches:

```text
UBASE_ADEV_NAME ".udma"
```

`udma_probe()` calls `udma_init_dev()`, which creates the UDMA device, registers
events and workqueues, initializes EID tables, and calls `udma_set_ubcore_dev()`.

`udma_set_ubcore_dev()` fills the ubcore-facing device:

```text
transport_type = UBCORE_TRANSPORT_UB
ops            = &g_dev_ops
dev.parent     = udma_dev->dev
dma_dev        = parent
dev_name       = udma<N>
driver_name    = udma
```

Then it calls `ubcore_register_device()`.

## Step 12: ubcore Visibility

`ubcore` creates a Linux class named `ubcore`.

The class has a devnode callback:

```text
return kasprintf(GFP_KERNEL, "ubcore/%s", dev_name(dev));
```

For the global ubcore cdev:

- `ubcore_cdev_register()` allocates a chrdev region.
- It initializes and adds `g_ubcore_ctx.ubcore_cdev`.
- It creates `/dev/ubcore`.

For registered devices:

- `ubcore_register_device()` creates main/logical devices.
- `ubcore_create_logic_device()` creates `/sys/class/ubcore/<dev_name>`.
- It fills sysfs attributes for device and port capabilities.
- It notifies ubcore clients.

Runtime checks:

```sh
ls /sys/class/ubcore
ls -l /dev/ubcore
udevadm info -q property -n /dev/ubcore
```

## Step 13: uburma Visibility

`uburma` creates a class named `uburma`.

Its devnode callback returns:

```text
uburma/<device-name>
```

The source sets:

```text
UBURMA_DEVNODE_MODE = 0666
```

When `ubcore_register_device()` notifies clients, `uburma_add_device()` runs:

- Allocates `struct uburma_device`.
- Initializes uobject and file tracking.
- Allocates a dynamic minor.
- Initializes a cdev using `g_uburma_fops`.
- Calls `device_create(&g_uburma_class, ...)`.
- Creates `/sys/class/uburma/<ubcore-device-name>`.
- Causes devtmpfs/udev to expose `/dev/uburma/<ubcore-device-name>`.

Runtime checks:

```sh
ls /sys/class/uburma
ls -l /dev/uburma
udevadm info -q property -n /dev/uburma/<device>
```

This `/dev/uburma/<device>` endpoint is the main UMDK user/kernel ABI for
URMA operations.

## Step 14: liburma Discovery

UMDK user-space discovery is implemented in:

```text
/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/urma_device.c
```

The relevant behavior:

- Discover sysfs class path.
- Read each device directory.
- Parse attributes such as UB device name, driver name, transport type,
  vendor/device IDs, and capability files.
- Match a userspace provider driver.
- Build a device path under the URMA dev path, corresponding to
  `/dev/uburma/<device>`.

Thus the user-space discovery dependency is:

```text
UB bus enumeration
  -> ubase
  -> udma auxiliary probe
  -> ubcore_register_device()
  -> uburma_add_device()
  -> /sys/class/uburma + /dev/uburma/<device>
  -> liburma scan/open
```

## Relationship to Ethernet, PCI, and RDMA Device Models

| Model | Discovery root | Device object | User ABI |
| --- | --- | --- | --- |
| Ethernet PCI NIC | PCI bus | `struct net_device` | sockets, netlink, ethtool, sysfs |
| InfiniBand/RDMA | PCI or platform bus plus RDMA core | `struct ib_device` | `/dev/infiniband/uverbsX`, rdma-core |
| UB/URMA/UDMA | UBRT/UBIOS -> UBC -> `ub_bus_type` -> `ub_entity` | `struct ubcore_device` | `/dev/uburma/<device>`, liburma |

UB has a stronger fabric-management layer before the URMA device appears. A
UDMA URMA device is not just a PCI function with queues. It depends on:

- firmware-reported UBC/UMMU topology,
- UB entity enumeration,
- UB driver matching,
- ubase auxiliary-device construction,
- UDMA registration into ubcore,
- uburma character-device publication.

## Current Gaps and Cautions

- The docs do not yet include runtime output from actual hardware. The flows
  above are source-derived.
- No repository-shipped custom udev rule was found. If deployments require
  group ownership or non-`0666` policy, that may live in packaging outside the
  scanned source tree.
- The exact `ubase_dev_init()` to auxiliary-device creation flow can be expanded
  further if we need a line-by-line trace of every auxiliary device type.
- The paired `/Users/ray/Documents/Repo/ub-stack/kernel-ub` tree has older
  ubcore/uburma/HNS3 paths. This doc treats `/Users/ray/Documents/Repo/kernel`
  as the current OLK-6.6 reference.

## Checklist for Future Hardware Validation

Run these on a UB-capable system:

```sh
dmesg | rg "ubfi|ubrt|ubc|ummu|ubus|ub_enum|ubase|udma|ubcore|uburma"
ls /sys/bus/ub/devices
ls /sys/bus/ub/drivers
udevadm info -q property -p /sys/bus/ub/devices/<entity>
ls /sys/class/ubcore
ls /sys/class/uburma
ls -l /dev/ubcore
ls -l /dev/uburma
udevadm monitor --kernel --udev --property --subsystem-match=ub
```

Expected shape:

- `ubfi` should report UBRT/UBIOS parsing.
- UBC count should be nonzero unless no hardware is present.
- UMMU nodes should be discovered and platform devices renamed.
- `/sys/bus/ub/devices` should contain UB entities.
- `ubase` should bind matching entities.
- UDMA should report auxiliary driver probe success.
- `ubcore` should list the UDMA device.
- `uburma` should create `/dev/uburma/<device>`.

