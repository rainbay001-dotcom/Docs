# UB device bringup vs PCIe probe — side-by-side comparison

_Last updated: 2026-04-25._

A focused comparison of how a UB device gets discovered, configured, and bound to a driver in Linux, set against the familiar PCIe probe path. The two stacks share more than they differ — UB borrows most of the kernel-bus-type pattern from PCIe — but the differences (firmware-driven enumeration, central UBFM, peer-to-peer fabric, first-class multi-tenancy) are architecturally important.

> **Scope note.** This doc focuses on the kernel-side bringup of a UB controller / Entity and the contrast with PCIe device probe. It does **not** cover the application-layer URMA/URPC API surface — see [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §5 for that. It also does not cover bus electrical / link-up — that's the spec's §3 Physical Layer + §4 Data Link Layer, neither of which we've read.

---

## 1. At a glance

```
                 PCIe                                            UnifiedBus
                                                                 
   ┌─────────────────────────┐                       ┌──────────────────────────────┐
   │ Host (CPU + MMU + IOMMU)│                       │ Host (CPU + MMU + UMMU)       │
   │  pci_root_bus_type      │                       │  ub_bus_type +                │
   │                         │                       │  ub_service_bus_type          │
   └────────────┬────────────┘                       └─────────────┬─────────────────┘
                │                                                  │
                │ ECAM/Config space                                │ Slices: CFG0/CFG1/PORT0..N + ROUTE_TABLE
                │ MMIO BARs                                        │ Resource Space (up to 3 segments per Entity)
                │ MSI/MSI-X                                        │ USI Type 1 / Type 2
                │ Hot-plug                                         │ Hot-plug (Spec App G) + Sentry events
                ▼                                                  ▼
   ┌─────────────────────────┐                       ┌──────────────────────────────┐
   │ Root Complex            │                       │ UB Root + UBFM                │
   │ ├── Bridge ─── Bridge   │                       │ ├── Switch ─── Switch         │
   │ │                       │                       │ │                             │
   │ │   ┌───────┐           │                       │ │   ┌───────┐                 │
   │ │   │ Dev A │           │                       │ │   │ UBPU A│ (Controller +    │
   │ │   └───────┘           │                       │ │   └───────┘  multiple        │
   │ │                       │                       │ │              Entities)       │
   │ │   ┌───────┐           │                       │ │   ┌───────┐                 │
   │ │   │ Dev B │           │                       │ │   │ UBPU B│                 │
   │ │   └───────┘           │                       │ │   └───────┘                 │
   └─────────────────────────┘                       └──────────────────────────────┘
```

**Single-line summary**: PCIe is "host bridge → enumerate tree → assign BARs → bind drivers"; UB is "firmware UBRT → register two bus types → vendor controller_probe → UBASE aux bus → upper-module probes → UBFM authenticates + assigns EIDs at runtime".

---

## 2. PCIe probe sequence — refresher

For comparison context (mainline Linux):

1. **Boot / reset.** Root Complex powers on; firmware (UEFI/BIOS) optionally pre-enumerates and assigns BARs.
2. **`pci_arch_init` / `pcibios_init`.** Architecture registers PCI host bridges; sysfs `/sys/bus/pci/` appears.
3. **`pci_register_driver(struct pci_driver *)`.** Each driver module's `module_init` registers a driver against `pci_bus_type` with a Vendor/Device/Class match table.
4. **Bus enumeration.** Kernel walks `bus 0`, reads each device's Vendor/Device ID at config-space offset `0x00`. For bridges, programs `Primary/Secondary/Subordinate Bus Number` and recurses.
5. **BAR allocation.** For each `Type 0` device, reads BARs at offsets `0x10`–`0x24`, sizes them, allocates MMIO/IO ranges from a host resource pool, programs the BAR registers.
6. **Capability walk.** Reads capability list (offset `0x34` → cap chain), discovers MSI/MSI-X, AER, ATS, etc.
7. **Driver match.** `pci_bus_type.match()` runs; on hit, calls `driver->probe(pci_dev)`.
8. **Driver-side init.** `pci_enable_device()` (powers on, enables BARs); `pci_set_master()` (bus master); `pci_alloc_irq_vectors()` (MSI/MSI-X); `dma_set_mask_and_coherent()`; `ioremap()` + `pci_iomap_range()` for each used BAR; device-specific register init.
9. **Sysfs.** `/sys/bus/pci/devices/0000:XX:YY.Z/` exposes `vendor`, `device`, `class`, `subsystem_*`, `config`, `resource{0..5}`, `driver_override`, etc.
10. **Hot-plug.** Native PCIe Hot-Plug Controller events trigger re-enumeration and device add/remove notifications.

---

## 3. UB bringup sequence — what actually runs at boot

The UB stack has more independent moving parts than PCIe. The order of `module_init` matters.

### 3.1 Firmware-stage enumeration (UBFI)

`drivers/ub/ubfi/ub_fi.c` — `module_init(ubfi_init)`. Sequence:

1. `ub_firmware_mode_init()` — detect ACPI vs DTS source.
2. `ubfi_get_ubrt()` — fetch the **UBRT** (UnifiedBus Resource Table). For ACPI: `acpi_get_table(ACPI_SIG_UBRT)`. For DTS: read `/chosen/linux,ubios-information-table` property's physical address.
3. `handle_ubrt()` dispatches to `handle_acpi_ubrt()` or `handle_dts_ubrt()`. UBRT enumerates UB entities (controllers, switches, devices) with their port counts, link speeds, GUIDs, memory window hints.

Output: a kernel-internal entity tree, ready for UBUS to consume. **PCIe analogue:** ACPI MCFG / `_OSC` for ECAM regions + early `pcibios_init`. UBRT is more declarative than MCFG — it describes the topology, not just the config-space windows.

### 3.2 Two parallel bus types in UBUS

UBUS registers **two** Linux bus types at boot (vs PCIe's single `pci_bus_type`):

| Bus type | Defined at | Registered at | Init level |
|---|---|---|---|
| `ub_bus_type` | `drivers/ub/ubus/ub-driver.c:176` | `bus_register(&ub_bus_type)` at `ub-driver.c:231` inside `ub_driver_init()` | **`postcore_initcall`** (`ub-driver.c:233`) — runs early, before normal `module_init`s |
| `ub_service_bus_type` | `drivers/ub/ubus/ubus_driver.c:610` | `bus_register(&ub_service_bus_type)` at `ubus_driver.c:646` inside `ubus_driver_init()` | `module_init(ubus_driver_init)` (`ubus_driver.c:776`) |

**Why two?** `ub_bus_type` is the foundational bus that hosts every UB Entity (UBPU controllers, switches, sub-Entities); it's analogous to `pci_bus_type` but registered earlier so that Entity probe can run during `subsys_initcall`/`fs_initcall` if needed. `ub_service_bus_type` (declared in `ubus_driver.h:10`) is a higher-level "service" bus for management/vendor drivers — there's no PCIe equivalent.

**PCIe analogue:** `pci_bus_type` (`drivers/pci/pci-driver.c`), registered by `postcore_initcall(pci_driver_init)`. UB mirrors the early-init pattern.

### 3.3 Vendor-controller hook

```c
/* drivers/ub/ubus/ubus_driver.c:711 (EXPORT_SYMBOL_GPL line 745) */
int register_ub_manage_subsystem_ops(const struct ub_manage_subsystem_ops *ops);
void unregister_ub_manage_subsystem_ops(const struct ub_manage_subsystem_ops *ops);
```

`struct ub_manage_subsystem_ops` (`ubus.h:62-73`) carries vendor callbacks: `controller_probe`, `controller_remove`, `ras_handler_probe`. The HiSilicon vendor module (`hisi_ubus.ko`) calls `register_ub_manage_subsystem_ops()` at its module-init; UBUS routes per-controller probe events to those callbacks.

**PCIe analogue:** `pci_register_driver(struct pci_driver *)` — but the UB vendor hook is *coarser*. It's per-controller, not per-driver-per-device. Per-device drivers in UB live on the UBASE auxiliary bus (next section).

### 3.4 UBASE — auxiliary bus for upper modules

UBASE (`drivers/ub/ubase/ubase_main.c:11-24`) registers as a UBUS driver via `ubase_ubus_register_driver()`. On controller probe (`ubase_ubus.c:39 ubase_ubus_init`), it creates Linux **`auxiliary_device`** instances for each upper module the silicon advertises (UDMA, UNIC, CDMA, …).

Upper modules then use **standard `auxiliary_driver_register`** to bind:

```c
/* drivers/ub/urma/hw/udma/udma_main.c:1344 */
int udma_probe(struct auxiliary_device *adev,
               const struct auxiliary_device_id *id);
```

**PCIe analogue:** there isn't one. PCIe has no equivalent "upper module on aux bus" pattern at the device level (you don't need it — a single PCIe function exposes BARs for all its capabilities). UB needs UBASE because one UBPU can host many distinct functions (URMA + NIC + DMA all on one UB Controller); auxiliary bus splits them into separate driver-facing devices.

**Closest PCIe analogue:** `mfd_*` (Multi-Function Device subsystem) for non-PCIe SoCs that pack many functions into one platform device. Linux `auxiliary_bus` (mainlined in 5.11) was added precisely for cases like this.

### 3.5 Per-Entity init + sysfs

UBUS exposes a per-Entity sysfs that closely mirrors PCIe's (`drivers/ub/ubus/sysfs.c`):

| UB sysfs attr | PCIe analogue |
|---|---|
| `ubc` | (no PCIe equivalent — UB Controller index) |
| `class_code` | `class` |
| `guid` | `subsystem_*` (ish — UB GUID is mfg-stage globally unique) |
| `entity_idx` | `function` part of B:D.F |
| `eid` | (no PCIe equivalent — runtime fabric identifier) |
| `tid` | (no PCIe equivalent — UMMU translation context) |
| `kref` | (kernel-internal refcount; no PCI equivalent in sysfs) |
| `resource` | `resource{0..5}` |
| `driver_override` | **`driver_override`** (verbatim same — same name, same semantics) |
| `match_driver` | (UB-specific manual match) |
| `direct_link` | (UB-specific link health) |

**Config-space access via sysfs** (`sysfs.c:101 ub_read_config`, `sysfs.c:154 ub_write_config`) — binary attribute on each Entity directory. **Direct PCIe analogue:** `/sys/bus/pci/devices/0000:XX:YY.Z/config`.

**Resource mmap via sysfs** (`sysfs.c:775 ub_mmap_resource`, `:790 ub_mmap_resource_wc`, `:797 ub_mmap_resource_uc`) — binary attribute per Entity. **Direct PCIe analogue:** `/sys/bus/pci/devices/0000:XX:YY.Z/resource{N}` with `mmap()` support. Both stacks let userspace mmap MMIO regions directly through sysfs.

### 3.6 Interrupt setup — USI vs MSI

UBUS interrupt allocation:

```c
/* drivers/ub/ubus/interrupt.c:262 */
int ub_alloc_irq_vectors_affinity(struct ub_entity *uent, unsigned int min_vecs,
                                   unsigned int max_vecs, ...);
```

**PCIe analogue:** `pci_alloc_irq_vectors_affinity(struct pci_dev *, ...)` (`drivers/pci/msi/api.c`). Same shape.

UB has **two** interrupt-register types per Entity (vs PCIe's MSI + MSI-X):

- **Type 1** (Spec §10.3.4.2): 8 register fields — Enable, Number, Enable Number, Data, Address, ID, Mask, Pending. ≤32 vectors per Entity. Comparable to PCIe MSI's "fixed table" model.
- **Type 2** (Spec §10.3.4.3): 4 capability registers + 3 indirection tables (Vector / Address / Pending). Address-table entries carry **DEID + TokenID**, so different vectors can share the same target Entity. Many more vectors. Closer to PCIe MSI-X's table-driven model — but with UB-specific fabric routing.

USI messages use **Write-class transaction semantics** on the UB fabric — i.e. the same primitive used for normal data writes. PCIe MSI/MSI-X are also memory writes (to the LAPIC), so the conceptual analogy holds, but UB's USI travels over the fabric and can target any UMMU-translatable address rather than a fixed APIC.

### 3.7 Runtime fabric management — UBFM (no PCIe analogue)

After the kernel-side bringup completes, **UBFM** (UB Fabric Manager, Spec §10.1) takes over:

- Authenticates each UBPU (Spec §11.2 — three flows: cert-based, measured-boot+SPDM, admin-asserted).
- Assigns **EIDs** at runtime (the 128-bit total = 108-bit Prefix + 20-bit Sub ID). PCIe has no runtime address assignment beyond BAR programming.
- Builds routing tables.
- Configures **UPI partitions** for Entity isolation (Spec §10.3.2).
- Handles ongoing topology changes (hot-plug, link-state changes).

In a single server, UBFM duties may be borne by host system software (Spec §10.2.1). In a SuperPoD, multiple UBFM instances cooperate, each managing a Sub Domain.

**PCIe gap:** there is nothing like UBFM in PCIe. A PCIe fabric is fully described by static config space + hot-plug events; identity and routing are byproducts of the topology tree, not actively managed.

### 3.8 Putting it all together — boot-time call sequence

```
postcore_initcall stage:
  ub_driver_init()            — registers ub_bus_type        (ub-driver.c:229)

(Firmware tables already populated by UBRT; ubfi_init reads them.)

module_init stage (order non-deterministic but dependencies resolved):
  ubfi_init()                 — parses UBRT                  (ub_fi.c:100)
  ubus_driver_init()          — registers ub_service_bus_type (ubus_driver.c:766)
                              — sysfs hooks live now
  hisi_ubus_init()  (vendor)  — register_ub_manage_subsystem_ops(...)  (in vendor mod)
                              ↓
  per-controller probe:
    vendor controller_probe() — capability negotiation
    ubase_ubus_init()         — creates auxiliary_device per upper module
                              ↓
  per-upper-module probe (UDMA / UNIC / CDMA):
    udma_probe(adev)          — udma_main.c:1344
      ↓
      ubcore_register_device(ub_dev)   — drivers/ub/urma/ubcore/ubcore_device.c:1223
        ↓
        creates /dev/ub_uburma_<devname> via uburma
        publishes via genl
        userspace can now liburma → urma_get_device_list()

UBFM runs continuously after boot:
  device authentication, EID assignment, UPI configuration, hot-plug handling
```

**PCIe analogue boot sequence:**

```
postcore_initcall:
  pci_driver_init()           — registers pci_bus_type

acpi_init / pci_subsys_initcall:
  pci_acpi_init()             — host bridges discovered via ACPI MCFG
  pci_arch_init()             — bus enum kicks off, BARs allocated

module_init stage:
  per-driver pci_register_driver(...)
                              ↓
  bus match:
    driver->probe(pci_dev)
      ↓
      pci_enable_device, pci_set_master, pci_alloc_irq_vectors_affinity,
      pci_iomap_range, dma_set_mask_and_coherent, device-specific reg init
      register subsystem (e.g. block_dev, net_dev, ib_dev, etc.)
```

---

## 4. Direct kernel-API translation table

If you're porting a PCIe driver to UB (or just want a quick lookup):

| PCIe API | UB equivalent | File |
|---|---|---|
| `pci_register_driver(&drv)` | (vendor side) `register_ub_manage_subsystem_ops(&ops)` | `drivers/ub/ubus/ubus_driver.c:711` |
| `pci_register_driver(&drv)` | (upper-module side) `auxiliary_driver_register(&drv)` (Linux core) | `include/linux/auxiliary_bus.h` |
| `pci_enable_device(pdev)` | `udma_init_dev(adev)` / `unic_dev_init(adev)` (per-driver init) — UBFM authentication is implicit | `udma_main.c`, `unic_main.c` |
| `pci_set_master(pdev)` | (no equivalent — UB peer-to-peer is allowed by default within UPI; UMMU + Token gate access) | n/a |
| `pci_alloc_irq_vectors_affinity(pdev, ...)` | `ub_alloc_irq_vectors_affinity(uent, ...)` | `drivers/ub/ubus/interrupt.c:262` |
| `pci_iomap_range(pdev, bar, off, len)` | mmap of Resource Space via `ub_mmap_resource_*` (kernel-internal: ioremap from `struct ub_entity` resource) | `drivers/ub/ubus/sysfs.c:775` |
| `pci_read_config_dword(pdev, where, &val)` | (kernel) `ub_check_cfg_msg_code` + cfg-msg send-recv via UB Controller; (sysfs) `ub_read_config` | `ubus_config.h:11`, `sysfs.c:101` |
| `pci_write_config_dword(pdev, where, val)` | (kernel) cfg-msg pair via UB Controller (Spec §10.4.1.2 access mechanism); (sysfs) `ub_write_config` | `sysfs.c:154` |
| `dma_map_single(dev, va, size, dir)` | (URMA path) `urma_register_seg(ctx, ...)` → kernel pins + UMMU map; (CDMA path) `dma_register_seg` ioctl on `/dev/cdma` | `ubcore_segment.c`, `cdma_ioctl.c` |
| `pci_request_regions` | (no equivalent — Resource Space allocation is per-Entity at UBFM-controlled stage; driver doesn't request) | n/a |
| `pci_disable_device(pdev)` | (no direct equivalent — destroy on auxiliary_device unbind) | per-driver |
| Hot-plug: `pci_hp_register` (PCI Hotplug Core) | UBASE reset/hotplug path + Sentry events; Spec App G | `drivers/ub/ubase/`, `drivers/ub/sentry/` |

---

## 5. Data-structure parallels

| PCIe | UB | Notes |
|---|---|---|
| `struct pci_dev` | `struct ub_entity` (`drivers/ub/ubus/ubus.h:41`) | Per-device handle. Fields like `priv_flags` carry DETACHED / ROUTE_UPDATED / ACTIVE state — somewhat like PCIe device state. |
| `struct pci_driver` | `struct ub_manage_subsystem_ops` (vendor) **or** `struct auxiliary_driver` (upper module) | UB splits the driver concept across two registration points. |
| `struct pci_bus` | UB Domain (a logical grouping; not a single struct) | UB Domain is the spec-level equivalent. In code, individual UBPUs carry a `ubc_no` (controller index). |
| `struct resource` (BAR) | `struct ub_entity` resource fields + Resource Space attribute | UB has up to 3 Resource Space segments per Entity (vs 6 BARs per PCIe function). |
| Capability list | CFG0_CAP / CFG1_CAP / PORT_CAP slices (Spec §10.4.1.3 Table 10-6) | UB has a structured slice taxonomy: `CFG1_CAP1_DECODER`, `CFG1_CAP2_JETTY`, `CFG1_CAP3_INT_TYPE1`, `CFG1_CAP4_INT_TYPE2`, etc. Capability discovery is by slice-bitmap rather than linked-list walk. |
| `pci_dev->vendor / device / class` | `ub_entity->guid + class_code` | GUID is wider (manufacturer-stage globally unique). Class Code defined per Spec App C. |
| Bus Number (B in B:D.F) | UBC index (see `controller.c`) | UB has `ub_bus_controller` representing each controller. |
| Device:Function (D.F) | Entity Index inside a Controller | Entity 0 is mandatory, holds the controller-level CFG0_PORT_BASIC + CFG0_PORT_CAP + CFG0_ROUTE_TABLE. |

---

## 6. What's the same, what's different — semantic comparison

### 6.1 Things UB does ~exactly~ like PCIe

- **Bus type registration pattern** with `bus_register()` + `bus_type.match` + `bus_type.probe`.
- **postcore_initcall** for the foundational bus, `module_init` for the rest.
- **Sysfs layout** per device, with `class`, `resource`, `config` binary attrs, and the **`driver_override`** attribute (verbatim same name + semantics).
- **`auxiliary_bus`** for splitting multi-function devices (mainline since 5.11; UB uses it for UDMA/UNIC/CDMA).
- **MSI-style interrupt allocation API shape**: `pci_alloc_irq_vectors_affinity` ↔ `ub_alloc_irq_vectors_affinity`.
- **Hot-plug as a first-class concern** — though the UB mechanism is different.

### 6.2 Things UB does that PCIe doesn't

| UB feature | What PCIe doesn't have |
|---|---|
| **Two bus types** (`ub_bus_type` + `ub_service_bus_type`) | PCIe has only `pci_bus_type`. The UB "service" bus is for management semantics that PCIe handles via separate ACPI/firmware paths. |
| **UBFM as a runtime fabric manager** | PCIe has no online resource manager — config-space + hot-plug-controller-events are the whole story. UBFM does device authentication, runtime EID assignment, partition management. |
| **Two-stage discovery** (UBFI firmware + UBFM runtime) | PCIe has firmware enumeration only; no runtime equivalent of UBFM. |
| **First-class multi-tenancy** (Entity + UPI partition) | PCIe has SR-IOV (limited) and ATS (translation, not isolation). UB partitions are spec-level + UBFM-managed. |
| **Network-layer routing** | PCIe switches just forward inside the tree; no multipath, no load balancing, no destination-based routing. UB has Spec §5 Network Layer with NPI partitioning + routing. |
| **Token rotation per memory region** | PCIe has no per-region access tokens; protection is via IOMMU page tables only. |
| **Device authentication + measured boot** | PCIe assumes board trust. UB requires UBFM to authenticate each UBPU (Spec §11.2). |
| **Cross-device TEE extension** | PCIe has no equivalent. UB has UTEI/HTEI/UTM/HTM model with EE_bits per transaction (Spec §11.6). |
| **Native multipath / LAG at the verbs layer** | PCIe has no multipath; it's a tree. |
| **CIP encryption on the wire** | PCIe has no equivalent at the transaction layer (PCIe IDE was added in 6.0 and is essentially equivalent — same idea, different protocol). |

### 6.3 Things PCIe has that UB doesn't (or treats differently)

| PCIe feature | UB equivalent / lack thereof |
|---|---|
| Bus mastering enable bit (`pci_set_master`) | No equivalent — UB peer-to-peer is implicit within UPI; UMMU + Token gate access. |
| Power management (D0–D3) | Spec doesn't define UB power states yet; SoC-specific. |
| ASPM (link power saving) | No ASPM equivalent in current UB spec. Physical-layer rate/lane fallback exists but isn't a low-power mode. |
| Root complex peer-to-peer being problematic | UB is peer-to-peer by design; no "this transaction can't traverse the root" worry. |
| Address Translation Services (ATS) | UMMU integrates the translation; no ATS-style separate cache-on-NIC required. SVA can share kernel page-tables (analogous to PCIe PASID + PRI). |
| Bus B:D.F as canonical address | UB uses (UBC index, Entity index) as canonical kernel-side addressing; EID is the fabric-level address. |
| Latency/bandwidth tuning bits in config space | UB has them in port-level CAP slices (`CFG0_PORT_CAP1_LINK`, `LINK_PERF`, `EYE_MONITOR`, `LTSM_ST`, `PORT_ERR_RECORD`, …). |

---

## 7. If you're porting a PCIe driver to UB

A practical decision tree:

1. **Is your driver vendor-controller logic** (per-silicon init, RAS handler, controller-wide config)?
   → Register via `register_ub_manage_subsystem_ops()`. Match by GUID / Class Code.
2. **Is your driver per-function** (UDMA-style RDMA, UNIC-style NIC, CDMA-style DMA engine)?
   → Register an `auxiliary_driver` and bind on the UBASE-created auxiliary_device. Match by `auxiliary_device_id::name`.
3. **Mapping BARs?**
   → Use the Resource Space sysfs attribute or kernel-internal `ub_entity->resource` fields. mmap from userspace via `ub_mmap_resource_*`.
4. **Allocating interrupts?**
   → `ub_alloc_irq_vectors_affinity()`. Choose USI Type 1 (≤32 vectors, fixed) or Type 2 (table-driven, many vectors with shared addresses).
5. **DMA?**
   → Don't use `dma_map_single()` directly. For URMA-aware ops, register a segment via `ubcore_register_seg` (kernel) or `urma_register_seg` (userspace). For non-URMA bulk, the CDMA `/dev/cdma` ioctl path applies.
6. **Config-space access?**
   → For management commands, send config-msg pairs via the UB Controller (Spec §10.4.1.2). For sysfs surface, `ub_read_config` / `ub_write_config` mimic PCIe's `config` binary attr.
7. **Hot-plug?**
   → Hook the UBASE reset notifier (`ubase_reset_register(adev, handler)` per `udma_main.c:1351`) and Sentry events for OS-level event reporting.
8. **Multi-tenant or live-migrate?**
   → Get familiar with **UPI** (Entity partition) and **MUE** (Management UB Entity, Spec §10.2.3) — the latter is what makes virtualization manageable by hosting shared resources outside the VM-attached Entity.

---

## 8. What's not in this comparison

- **Physical / data-link layer comparison** (Spec §3 / §4 vs PCIe physical/link layer). UB has its own SerDes-rate negotiation, FEC, dynamic data-rate, lane-fallback. Not yet read into the doc set.
- **PCIe IDE (Integrity and Data Encryption)** vs UB CIP detail comparison. CIP is documented (see [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §4.5); IDE could be a separate row in §6.2 above.
- **Error reporting (AER) vs UB error message queues**. UB has Class A/B/C errors via Completion / Event / Error Message queues (Spec §10.3.5); PCIe has AER capability + correctable/non-fatal/fatal hierarchy. Comparable but not yet aligned in our docs.
- **PCIe TPH / Steering Tags vs UB ordering modes**. PCIe TPH gives processing hints for cache placement; UB's NO/RO/SO ordering markers + ROI/ROT/ROL service modes are the spec analogue.

---

## 9. Open questions

1. **How does UB enumerate cross-supernode UBPUs at boot?** UBFI parses local UBRT; cross-supernode discovery presumably happens via UBFM after boot. Not yet traced in spec or code.
2. **Is `ub_bus_type.match` a Vendor/Class match or topology match?** Need to read `ub_bus_type` field defs at `ub-driver.c:176` carefully.
3. **Are there per-Entity capability quirks** (analogue of PCIe's `pcibios_dev_init` quirks)? Likely yes given vendor module layering, but not yet enumerated.
4. **How does UB handle a hot-removed UBPU mid-transaction?** UBASE reset path exists; UBFM also reacts; the interaction with in-flight URMA WQEs needs to be traced.
5. **Does UBUS expose a `driver_override` write that persists across boot?** PCIe's `driver_override` is per-device, runtime-only. UB's same-named attribute likely behaves the same — confirm.

---

## 10. Cross-references

- Spec-side Resource Management (UBFM, Entity model, Configuration Space, USI interrupts): [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §3.
- Code-side foundation drivers (UBUS, UBASE, UBFI, UMMU, OBMM): [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) §1–§6.
- UDMA probe + WQE format + doorbell mechanics: [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) §7.
- UB system architectural overview: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) §0 + §1.
- Multi-axis comparison vs IB / RDMA / Ethernet (different angle, complementary): [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md).
