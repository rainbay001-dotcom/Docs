# UB and PCIe Probe Process Comparison

Last updated: 2026-04-25

This document compares the Linux PCIe probe process with the openEuler UB probe
and device bring-up process. It focuses on:

- UB root discovery and UB bus bring-up.
- Regular UB driver and UB entity matching.
- UBASE as the first functional UB driver.
- UDMA, UNIC, and CDMA auxiliary-device bring-up.
- Where the flow is similar to PCIe and where the analogy breaks.

The key conclusion:

```text
PCIe usually probes endpoint functions directly.

UB first creates UB entities from firmware/topology,
then binds those entities to a regular UB driver such as ubase,
then ubase creates auxiliary devices such as udma, unic, and cdma,
then those auxiliary drivers register the user-visible subsystem devices.
```

## Short Comparison

| Stage | PCIe | UB |
| --- | --- | --- |
| Firmware/root discovery | ACPI/DT/platform host bridge creates `struct pci_host_bridge`. | UBRT/UBIOS firmware tables create UBC and UMMU platform knowledge. |
| Global Linux bus | `pci_bus_type` named `pci`. | `ub_bus_type` named `ub`. |
| Topology scan | `pci_scan_root_bus_bridge()` and `pci_scan_child_bus()` enumerate buses, bridges, slots, functions. | `ub_host_probe()` calls `ub_enum_probe()` to scan UB topology, calculate routes, and activate entities. |
| Device object | `struct pci_dev`. | `struct ub_entity`. |
| Driver object | `struct pci_driver`. | `struct ub_driver`. |
| Match data | PCI vendor/device/class IDs and dynamic IDs. | UB vendor/device/module/type/class/version/entity fields and dynamic IDs. |
| Probe callback | `pci_driver->probe(struct pci_dev *, const struct pci_device_id *)`. | `ub_driver->probe(struct ub_entity *, const struct ub_device_id *)`. |
| First function driver in this stack | A PCI endpoint driver often owns the real device directly. | `ubase` is the first regular UB driver; it creates auxiliary child devices. |
| Leaf functional drivers | Often the same PCI driver registers netdev, RDMA, NVMe, GPU, etc. | UDMA, UNIC, and CDMA are auxiliary drivers below UBASE. |
| User-visible device | Driver-specific: netdev, `/dev/nvme*`, `/dev/infiniband/*`, etc. | `ubcore_device`, `/dev/uburma/<device>`, netdev via UNIC, `/dev/cdma/dev`, etc. |
| Memory/IOMMU | PCI bus configures DMA/IOMMU for `pci_dev`; drivers map BARs and DMA. | UB bus configures DMA using UBC firmware attributes; UDMA/CDMA also allocate UMMU TID/token/SVA resources. |

## Object Mapping

These are useful analogies, not exact equivalences.

| PCIe object | UB object | Analogy strength | Notes |
| --- | --- | --- | --- |
| `pci_bus_type` | `ub_bus_type` | Strong | Both are Linux `struct bus_type` registrations. |
| `pci_host_bridge` | UBC plus firmware UB root data | Partial | PCI has a host-bridge object and bus hierarchy; UB has UBC firmware/controller state and a UB topology model. |
| `pci_bus` | UB controller/topology context | Weak/partial | UB does not expose a direct `pci_bus` clone; topology is represented through UBC, routes, and `ub_entity` devices. |
| `pci_dev` | `ub_entity` | Strong for Linux device model | Both embed `struct device` and are matched to bus drivers. |
| `pci_driver` | `ub_driver` | Strong | Both wrap `struct device_driver`, id tables, probe/remove, dynamic IDs, and driver-core registration. |
| PCI endpoint driver | `ubase` plus auxiliary drivers | Partial | PCI endpoint driver often owns the hardware function directly; UB splits ownership across `ubase` and child auxiliary drivers. |
| BAR/MMIO resources | UBASE resource spaces and provider mappings | Partial | PCI drivers commonly ioremap BARs; UB child drivers get resource/capability access through UBASE helper APIs. |
| PCI MSI/MSI-X | UB event/completion/control queues | Weak/partial | Both surface interrupts/events, but UB event paths are UBASE/provider-specific and tied to UB services. |
| RDMA `ib_device` from a PCI driver | `ubcore_device` from UDMA auxiliary driver | Strong implementation role | The registration point is one layer later in UB because UDMA is an auxiliary child of UBASE. |

## PCIe Probe Path

This is the generic Linux PCIe path in the local kernel tree. Individual PCIe
host-controller drivers differ, but most converge on `pci_host_probe()` or
`pci_scan_root_bus_bridge()`.

### PCIe Bring-Up Sequence

```text
platform/ACPI/DT host-controller driver
  -> allocate/register pci_host_bridge
  -> pci_host_probe()
  -> pci_scan_root_bus_bridge()
  -> pci_register_host_bridge()
  -> pci_scan_child_bus()
  -> pci_scan_slot()
  -> pci_scan_single_device()
  -> pci_setup_device()
  -> pci_device_add()
  -> pci_bus_add_devices()
  -> device_attach()
  -> pci_bus_type.probe = pci_device_probe()
  -> pci_match_device()
  -> pci_driver->probe()
  -> endpoint driver enables device, maps BARs, sets DMA/MSI, registers subsystem object
```

### PCIe Source Anchors

| Step | Local source |
| --- | --- |
| `pci_bus_type` is named `pci` and owns match/uevent/probe/remove callbacks. | `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c:1690` |
| `pci_register_driver()` sets `drv->driver.bus = &pci_bus_type` and calls `driver_register()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c:1451` |
| `pci_host_probe()` scans the root bus, assigns/claims resources, and calls `pci_bus_add_devices()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:3150` |
| `pci_scan_root_bus_bridge()` registers the host bridge and scans the child bus. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:3244` |
| `pci_register_host_bridge()` allocates/initializes the root `pci_bus`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:924` |
| `pci_scan_child_bus()` walks subordinate devices and bridges. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:3095` |
| `pci_scan_child_bus_extend()` scans devfn slots and bridges. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:2971` |
| `pci_scan_slot()` scans functions in a slot. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:2755` |
| `pci_setup_device()` fills class, memory, IO, IRQ, and bus information and sets `dev->dev.bus = &pci_bus_type`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:1903` |
| `pci_device_add()` initializes the Linux device, DMA masks, MSI domain, list membership, and `device_add()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c:2612` |
| `pci_bus_add_device()` creates sysfs/proc state and calls `device_attach()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/bus.c:334` |
| `pci_device_probe()` assigns IRQs and calls `__pci_device_probe()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c:444` |
| `__pci_device_probe()` matches the device and calls `pci_call_probe()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c:407` |
| `local_pci_probe()` finally calls `pci_driver->probe()`. | `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c:305` |

### PCIe Responsibilities

PCIe enumeration answers these questions:

- Which root complexes and buses exist?
- Which devices/functions exist at bus/device/function addresses?
- What are the vendor/device/class IDs?
- What BAR/resource windows exist?
- Which interrupts/MSI domains apply?
- Which IOMMU/DMA configuration applies?
- Which `pci_driver` owns each endpoint?

After `pci_driver->probe()` starts, the endpoint driver typically does the
subsystem-specific work:

```text
PCI NIC driver:
  pci_enable_device()
  pci_request_regions()
  pci_iomap()
  dma_set_mask()
  pci_alloc_irq_vectors()
  register_netdev()

PCI RDMA driver:
  PCI probe
  -> hardware init
  -> ib_register_device()
  -> uverbs/rdma-core user visibility
```

The exact calls vary by driver, but the key point is that the PCI driver often
owns the endpoint function directly.

## UB Probe Path

UB has a Linux bus like PCI, but the bring-up is not just "scan PCI config
space and bind an endpoint driver." UB starts from UB firmware tables and UB
topology, then creates `ub_entity` devices, then binds a regular `ub_driver`.
In this stack, the regular driver is usually UBASE, and UBASE creates auxiliary
devices for functional drivers.

### UB Bring-Up Sequence

```text
firmware UBRT/UBIOS
  -> ubfi parses UBC and UMMU tables
  -> UBC/UMMU platform knowledge exists
  -> UB management subsystem registers vendor ops
  -> ub_host_probe()
  -> ub_bus_type_init()
  -> ub_bus_controllers_probe()
  -> ub_enum_probe()
  -> ub_enum_topo_scan()
  -> ub_enum_bfs_route_cal()
  -> ub_enum_entities_active()
  -> ub_entity_add()
  -> ub_start_ent()
  -> Linux driver core match on ub_bus_type
  -> ub_entity_probe()
  -> ub_driver->probe()
  -> ubase_ubus_probe()
  -> ubase initializes resources/caps/control/event state
  -> ubase creates auxiliary devices: ubase.udma, ubase.unic, ubase.cdma
  -> auxiliary drivers probe: udma_probe(), unic_probe(), cdma_probe()
  -> leaf subsystem devices appear: ubcore/uburma, netdev, cdma cdev
```

### UB Source Anchors

| Step | Local source |
| --- | --- |
| `ub_bus_type` is named `ub` and owns DMA configure/cleanup hooks. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c:176` |
| UB bus registration uses `postcore_initcall(ub_driver_init)`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c:229` |
| `__ub_register_driver()` sets `drv->driver.bus = &ub_bus_type` and calls `driver_register()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ub-driver.c:200` |
| `struct ub_entity` embeds `struct device` and stores the matched `ub_driver`. | `/Users/ray/Documents/Repo/kernel/include/ub/ubus/ubus.h:171` |
| `struct ub_driver` defines probe/remove/virt/activate/deactivate/error callbacks. | `/Users/ray/Documents/Repo/kernel/include/ub/ubus/ubus.h:312` |
| `ub_bus_type_init()` installs UB match, uevent, probe, remove, shutdown, and sysfs groups. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:568` |
| `ub_host_probe()` initializes UB bus callbacks, controller probing, enumeration, service bus, cdevs, RAS, and message RX. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:621` |
| `ub_enum_probe()` scans topology, calculates BFS routes, and activates devices. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/enum.c:1447` |
| Entity activation calls `ub_entity_add()` and `ub_start_ent()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/enum.c:1428` |
| UB match uses static/dynamic IDs and `driver_override`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:238` |
| UB probe dispatch calls `drv->probe(dev, id)`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:294` |
| `ub_entity_probe()` does entity reference/virt-notify work and dispatches UB probe. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:332` |
| UB uevents include UB-specific ID, module, type, class, version, sequence, and entity name. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubus/ubus_driver.c:379` |
| UBASE registers a regular `struct ub_driver`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_ubus.c:465` |
| `ubase_ubus_probe()` initializes a matched `ub_entity` and copies TID/EID/UPI/controller fields. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_ubus.c:194` |
| UBASE creates child auxiliary devices with `auxiliary_device_init()` and `auxiliary_device_add()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/ubase/ubase_dev.c:185` |
| UDMA matches `UBASE_ADEV_NAME ".udma"`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c:48` |
| `udma_probe()` calls `udma_init_dev()` and registers reset handling. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c:1344` |
| UDMA auxiliary driver registers with `auxiliary_driver_register()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma/udma_main.c:1412` |

### Regular UB Driver Path

The "regular UB driver" path is this:

```text
struct ub_driver
  -> ub_register_driver()
  -> __ub_register_driver()
  -> driver_register(&drv->driver)
  -> driver core matches against ub_entity devices on ub_bus_type
  -> ub_bus_match()
  -> ub_entity_probe()
  -> ub_call_probe()
  -> drv->probe(struct ub_entity *, const struct ub_device_id *)
```

For this stack, `ubase` is the important regular UB driver:

```text
ubase_ubus_driver
  .name = ubase_ubus_driver_name
  .id_table = ubase_ubus_tbl
  .probe = ubase_ubus_probe
  .remove = ubase_ubus_remove
  .activate = ubase_ubus_activate
  .deactivate = ubase_ubus_deactivate
```

This is comparable to a PCI endpoint driver only up to the Linux driver-core
binding point. After that, the structure diverges. `ubase` does not itself
become "the UDMA device" or "the UNIC device." It prepares the common UB base
state and creates auxiliary devices for the specific child functions.

### UB Auxiliary Fan-Out

UBASE creates child devices under the Linux auxiliary bus:

```text
ubase bound to ub_entity
  -> ubase_init_aux_devices()
  -> ubase_add_one_adev()
  -> auxiliary_device_init()
  -> auxiliary_device_add()
  -> child device names based on UBASE_ADEV_NAME suffixes
```

Then leaf drivers bind:

| Auxiliary child | Matching driver | Result |
| --- | --- | --- |
| `ubase.udma` | UDMA auxiliary driver | Creates UDMA device state and registers `ubcore_device`; later exposed to liburma through ubcore/uburma. |
| `ubase.unic` | UNIC auxiliary driver | Creates a Linux netdev-facing UB network driver path. |
| `ubase.cdma` | CDMA auxiliary driver | Creates `/dev/cdma/dev` and CDMA queue/segment objects. |

This fan-out is one of the biggest differences from a simple PCIe mental
model. In PCIe, a single endpoint function might directly be the NIC or RDMA
device. In UB, the first UB bus match is a base entity driver, and the actual
functional surfaces are children.

## Side-by-Side Probe Sequence

### PCIe

```text
1. Host-controller/platform driver creates pci_host_bridge.
2. pci_host_probe() starts PCI discovery.
3. pci_scan_root_bus_bridge() registers root bridge and root bus.
4. pci_scan_child_bus() scans slots and bridge hierarchy.
5. pci_setup_device() fills pci_dev identity/resource fields.
6. pci_device_add() calls device_add().
7. pci_bus_add_devices() calls device_attach().
8. pci_bus_type.match finds pci_driver by PCI IDs.
9. pci_bus_type.probe calls pci_device_probe().
10. pci_device_probe() calls pci_driver->probe().
11. Endpoint driver registers its subsystem device.
```

### UB

```text
1. UBRT/UBIOS firmware provides UB root/controller and UMMU information.
2. ubfi creates UBC/UMMU platform knowledge.
3. Vendor UB management subsystem registers ops.
4. ub_host_probe() starts UB discovery.
5. ub_bus_type_init() installs UB callbacks.
6. ub_bus_controllers_probe() prepares UB controller state.
7. ub_enum_probe() scans topology, calculates routes, and activates entities.
8. ub_entity_add()/ub_start_ent() expose ub_entity devices.
9. ub_bus_type.match finds ub_driver by UB IDs.
10. ub_bus_type.probe calls ub_entity_probe().
11. ub_entity_probe() calls ub_driver->probe().
12. ubase_ubus_probe() binds common UB base state.
13. ubase creates auxiliary devices.
14. UDMA/UNIC/CDMA auxiliary drivers probe.
15. Leaf drivers register ubcore/netdev/cdma surfaces.
```

## Probe Entry Point Comparison

| Question | PCIe answer | UB answer |
| --- | --- | --- |
| What starts bus discovery? | Host-controller driver calling `pci_host_probe()` or equivalent. | UB management subsystem ops registration leading to `ub_host_probe()`, after firmware UBC/UMMU data exists. |
| What does the scan read? | PCI config space through `pci_ops`. | UB topology/controller information through UB management/controller paths. |
| What object is added to Linux device model? | `struct pci_dev`. | `struct ub_entity`. |
| What is the match callback? | `pci_bus_match`. | `ub_bus_match`. |
| What is the probe callback installed in bus type? | `pci_device_probe`. | `ub_entity_probe`. |
| What does the bus probe call? | `pci_driver->probe()`. | `ub_driver->probe()`. |
| What does the first matched driver usually represent? | The actual endpoint function driver. | Often UBASE, a common UB base driver. |
| How do UDMA/UNIC/CDMA appear? | Not applicable as PCI child functions in this flow. | Auxiliary children created by UBASE. |

## Resource and Identity Comparison

| Topic | PCIe | UB |
| --- | --- | --- |
| Address identity | Domain:bus:device.function. | UB entity identity, EID, UPI, module/vendor/type/class/version, sequence/name. |
| Discovery unit | PCI function. | UB entity from topology scan. |
| Topology model | Bus/bridge hierarchy. | UB controller plus scanned UB topology and route calculation. |
| Route setup | Bridge bus numbers/windows and platform routing. | `ub_enum_bfs_route_cal()` and UB topology activation. |
| Resource windows | BARs, IO/memory windows, bus resources. | UBASE resource spaces, controller/caps, UB link/port/capability data. |
| DMA/IOMMU | Bus DMA configure plus driver DMA setup. | UB bus DMA configure from UBC firmware attr; UDMA/CDMA additionally allocate UMMU TID/token/SVA state. |
| Event model | IRQ/MSI/MSI-X per endpoint. | UBASE events/completions/control queues and provider-specific async events. |
| User-space exposure | Subsystem-specific device nodes and sysfs. | `/sys/bus/ub`, `/sys/class/ubcore`, `/sys/class/uburma`, `/dev/uburma/<device>`, netdev, `/dev/cdma/dev`. |

## Why UB Is Not Just PCIe With Different IDs

There are several structural differences:

1. UB has a firmware/topology layer that is part of software bring-up.
   PCIe discovers a bus/bridge/function hierarchy through config space. UB
   additionally builds controller, UMMU, entity, route, service, RAS, and
   message-receive state.

2. `ub_entity` is lower than `ubcore_device`.
   In RDMA terms, a `pci_dev` might directly become an `ib_device` after an
   RDMA PCI driver's probe. In UB, `ub_entity` first binds to `ubase`; UDMA
   later registers the `ubcore_device`.

3. UBASE is a split point.
   UBASE centralizes base capability/resource/event/reset behavior, then creates
   auxiliary children. This is why UDMA, UNIC, and CDMA are not regular
   `ub_driver` instances in this implementation.

4. UMMU is part of UB platform semantics.
   PCIe uses IOMMU/DMA APIs too, but UB memory semantics are tied to UMMU,
   TID/token, Segment registration, and direct UB transaction access.

5. UB has service and management components in bus bring-up.
   `ub_host_probe()` initializes service bus, cdevs, RAS, and message RX after
   entity enumeration. A simple PCIe endpoint-probe comparison misses these.

## Practical Debugging Comparison

### PCIe Device Missing

Typical checks:

```bash
lspci -nn
ls /sys/bus/pci/devices
dmesg | grep -iE 'pci|pcie'
lsmod | grep <driver>
```

Likely layers:

- Host bridge did not probe.
- PCIe link did not train.
- Root bus scan did not find the device.
- Resource allocation failed.
- No matching `pci_driver`.
- Driver probe failed.

### UB Device Missing

Typical checks:

```bash
ls /sys/bus/ub/devices
udevadm info -q property -p /sys/bus/ub/devices/<entity>
ls /sys/class/ubcore
ls /sys/class/uburma
ls -l /dev/ubcore /dev/uburma
dmesg | grep -iE 'ub|ubcore|ubase|udma|unic|cdma|ummu'
```

Likely layers:

- UBRT/UBIOS did not expose usable UBC/UMMU information.
- UB management subsystem ops did not register or did not match the UBC vendor.
- `ub_host_probe()` failed before or during controller probing.
- `ub_enum_probe()` failed topology scan or route calculation.
- `ub_entity` exists but no `ub_driver` matched.
- `ubase_ubus_probe()` failed.
- UBASE did not create an auxiliary child.
- UDMA/UNIC/CDMA auxiliary probe failed.
- Leaf subsystem registration failed: ubcore/uburma, netdev, or cdma cdev.

## Failure Stage Map

| Symptom | PCIe likely stage | UB likely stage |
| --- | --- | --- |
| No root object | Host bridge/platform driver | UBRT/UBIOS/ubfi/UBC table |
| Bus exists, no device | Link/config-space scan | `ub_enum_probe()` topology scan |
| Device exists, no driver | ID table/module/autoload | UB ID table, `ub_driver`, `MODALIAS=ub:*` |
| Driver probe starts but no user device | Endpoint driver init | UBASE auxiliary creation or child auxiliary probe |
| RDMA device missing | PCI RDMA driver failed before `ib_register_device()` | UDMA auxiliary probe failed before `ubcore_register_device()` |
| Network device missing | PCI NIC driver failed before `register_netdev()` | UNIC auxiliary probe/netdev init failed |
| DMA cdev missing | Driver-specific cdev failure | CDMA auxiliary probe or `cdma_create_chardev()` failed |
| Memory registration fails | DMA/IOMMU/MR/provider path | UMMU/TID/token/SVA/Segment path |

## Design Takeaways

For documentation and debugging, use this hierarchy:

```text
UB firmware/root:
  UBRT/UBIOS, UBC, UMMU

UB Linux bus:
  ub_bus_type, ub_entity, ub_driver

UB base driver:
  ubase_ubus_probe, UBASE resources/caps/events/reset

Auxiliary children:
  ubase.udma, ubase.unic, ubase.cdma

Functional subsystems:
  UDMA -> ubcore/uburma/liburma
  UNIC -> netdev
  CDMA -> /dev/cdma/dev and cdma_api clients
```

Do not collapse these into one "PCIe probe" step. The UB stack has a two-level
driver architecture:

```text
regular UB bus driver:
  ub_driver over ub_entity

leaf function driver:
  auxiliary_driver over UBASE-created child device
```

That two-level shape explains many otherwise confusing observations:

- `ub_entity` can exist while no UDMA device is visible.
- `ubase` can bind successfully while UDMA, UNIC, or CDMA fails later.
- UDMA can fail because of UMMU/TID/SVA setup even after UB bus enumeration
  succeeded.
- Runtime validation has to check `/sys/bus/ub`, UBASE/auxiliary probe logs,
  and leaf subsystem outputs, not just one device node.

## What Should Be Added Next

To make this comparison executable as a debugging guide:

1. Add real runtime output from a UB machine for `/sys/bus/ub`,
   `/sys/class/ubcore`, `/sys/class/uburma`, `/dev/uburma`, UNIC netdev, and
   `/dev/cdma/dev`.
2. Add a table mapping UB uevents to PCI uevents and module autoload behavior.
3. Trace `ubfi` firmware parsing beside a concrete PCI host-controller driver
   on the target platform.
4. Add a diagram showing the two-level UB bind path:
   `ub_entity -> ubase -> auxiliary children`.
5. Add a debugging checklist with exact `dmesg` strings for each failed stage.
