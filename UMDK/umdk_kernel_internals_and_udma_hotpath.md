# UB kernel foundations + UDMA hot path

_Last updated: 2026-04-25._

Deep dive into the kernel-side code below URMA — the foundation drivers (UBUS, UBASE, UBFI, OBMM, UMMU, UBMEMPFD, UBDEVSHM) and the UDMA hardware provider's data plane (probe, WQE format, doorbell, post-send, completion). Companion to [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), which gives the high-level picture; this doc adds the line-level detail.

Source: `~/Documents/Repo/kernel/` on `OLK-6.6` (kernel) + `~/Documents/Repo/ub-stack/umdk/src/urma/hw/udma/` (userspace fast path).

> **Caveat about line citations.** Some `file:line` cites below come from a survey agent and have been spot-verified at high-load anchors (e.g. `ubcore_register_device:1223`, `tpsa_ioctl.h:30-31`, `uburma_cmd.h` enum count). Lines for files I haven't personally opened are marked _(unverified line)_ where they look approximate. The fact and the file should be right; the column may drift by a few.

---

## 1. UBUS — the foundational UB bus

**Path:** `drivers/ub/ubus/`. Approx 82 files, with `enum.c` (~33 KB), `ubus_entity.c` (~24 KB), `sysfs.c` (~22 KB), `instance.c` (~21 KB) being the biggest.

**Role.** UBUS implements UB as a Linux bus type — parallel to `pci_bus_type` or `usb_bus_type`. All UB hardware (UBPUs, switches, controllers) hang off UBUS. UBUS does not export its own data-plane uAPI; it provides discovery + sysfs + the bus-level lifecycle for upper drivers (UBASE / UNIC / CDMA / UDMA).

**Init.** `ubus_driver_init()` (per agent survey, file: `ubus_driver.c:340` _(unverified line)_) registers the bus type and a vendor `ub_manage_subsystem_ops` vtable.

**Key public symbols** (per agent survey of `drivers/ub/ubus/ubus.h:60-76`):

```c
struct ub_bus_controller *ub_find_bus_controller(u32 ctl_no);
int ub_get_bus_controller(u32 *list, u32 max);   /* enumerate */
int register_ub_manage_subsystem_ops(const struct ub_manage_subsystem_ops *ops);
void ub_bus_type_iommu_ops_set(...);    /* IOMMU integration */
struct iommu_ops *ub_bus_type_iommu_ops_get(void);
```

**Key data structures.**

- `struct ub_entity` — represents any UB endpoint (controller, switch, device). Carries `priv_flags` such as `DETACHED`, `ROUTE_UPDATED`, `ACTIVE`. Defined in `drivers/ub/ubus/ubus.h:41-47` _(unverified)_.
- `enum ub_entity_type` — `BUS_CONTROLLER`, `IBUS_CONTROLLER`, `SWITCH`, `DEVICE`, `P_DEVICE`, `IDEVICE`, `P_IDEVICE`. Helpers `is_bus_controller()`, `is_device()`, `is_controller()`.
- `struct ub_manage_subsystem_ops` — vendor vtable: `controller_probe`, `controller_remove`, `ras_handler_probe`.

**Probe sequence.** UBFI parses firmware (UBRT table or DTS) → enumerates entities. UBUS binds to enumerated entities. Vendor `ub_manage_subsystem_ops` runs for controller-specific init. Then upper modules (UBASE → UNIC/CDMA/UDMA via aux bus) probe.

**Sub-Kconfigs:** `UB_UBUS_BUS` (modular part), `UB_UBUS_USI` (Message Signaled Interrupts on UB; selects `GENERIC_MSI_IRQ`). Vendor subtree at `drivers/ub/ubus/vendor/`.

---

## 2. UBASE — the auxiliary bus + command queue

**Path:** `drivers/ub/ubase/`. ~36 files; biggest are `ubase_dev.c` (51 KB), `ubase_ctrlq.c` (50 KB), `ubase_qos_hw.c` (36 KB), `ubase_eq.c` (33 KB), `ubase_hw.c` (29 KB), `ubase_cmd.c` (28 KB).

**Role.** UBASE creates an **auxiliary bus** for upper UB modules. UDMA, CDMA, and UNIC all bind through UBASE rather than directly to UBUS. Doing so lets each upper module probe as an `auxiliary_device` in standard Linux fashion. UBASE also owns the **command-queue** — the kernel↔HW control channel used to configure devices.

**Init.** `ubase_main.c:11-24` (per agent):

```c
int ubase_init(void) {
    int ret = ubase_dbg_register_debugfs();
    ret = ubase_ubus_register_driver();   /* bind to UBUS as a bus driver */
    return ret;
}
```

**Public API.**

- `int ubase_cmd_send_inout(struct auxiliary_device *adev, struct ubase_cmd_buf *in, struct ubase_cmd_buf *out)` — synchronous command send/recv via the device's command queue.
- Capability queries: `ubase_dev_urma_supported()`, `ubase_dev_cdma_supported()`, `ubase_dev_unic_supported()` (`ubase_dev.c`), used by upper drivers to gate functionality.

**Command queue model.** A pair of DMA-coherent rings — CSQ (command send) and CRQ (command response) — programmed into HW BARs (CSQ_BASEADDR_L/H, CRQ_BASEADDR_L/H, DEPTH, HEAD, TAIL). Allocations via `dma_alloc_coherent()`. PI/CI indices guarded by spinlocks. Default timeout `UBASE_CMDQ_TX_TIMEOUT`.

**Key structs.**

- `struct ubase_dev` (`ubase_dev.c`) — wraps HW context. Holds `hw.cmdq`, mailbox, event-queue arrays.
- `struct ubase_cmdq_ring` (`ubase_cmd.c`) — PI, CI, desc count, DMA address of descriptor array, lock.
- `struct ubase_mailbox_cmd` — semaphore-gated mailbox for command polling.

**Why this layer exists.** Upper-module probes (UDMA, UNIC, CDMA) are uniform — all bind via Linux `auxiliary_driver`, all use `ubase_cmd_send_inout()` to talk to the HW command engine. This decouples them from each other and from UBUS internals.

---

## 3. UBFI — firmware interface

**Path:** `drivers/ub/ubfi/`.

**Role.** Bridges firmware-described UB topology to kernel; bootstraps the entity tree that UBUS consumes.

**Init.** `ubfi/ub_fi.c:100-119` (per agent):

```c
int ub_fi_init(void) {
    ub_firmware_mode_init();     /* detect ACPI vs DTS */
    int ret = ubfi_get_ubrt();    /* fetch UBRT table or DTS node */
    ret = handle_ubrt();          /* parse and instantiate entities */
    return ret;
}
```

**Firmware tables.** Two flavors:

- **ACPI**: signature `UBRT`, retrieved via `acpi_get_table(ACPI_SIG_UBRT)` (`ub_fi.c:15-16`).
- **DTS**: `/chosen/linux,ubios-information-table` property points to the physical address of an in-memory table (`ub_fi.c:16` _(unverified)_).

Both call into `handle_acpi_ubrt()` or `handle_dts_ubrt()` to parse.

**What it parses.** Per UBRT entry: entity type, port count, link speeds, memory size limits (DMA window), IOMMU/UMMU routing hints. For each entry, `struct ub_entity` is allocated and registered with UBUS.

**Lifecycle.** `ubfi_get_ubrt()` / `ubfi_put_ubrt()` (refcount the parsed table).

---

## 4. OBMM — Ownership-Based Memory Management

**Path:** `drivers/ub/obmm/`. ~35 files; `obmm_shm_dev.c` (~30 KB), `ubmempool_allocator.c` (~18 KB), `obmm_core.c` (~17 KB), `obmm_import.c` (~17 KB), `obmm_ownership.c` (~11 KB).

**Role.** **Cross-supernode coherent shared memory.** Probably the most distinctive UB kernel module. Lets a process on node A *export* a region of physical memory and a process on node B *import* it, with cross-supernode cache-consistency maintained by HW (HiSilicon SoC cache hooks). Selected `NUMA_REMOTE`, `PFN_RANGE_ALLOC`, `RECLAIM_NOTIFY` per `Kconfig`.

**uAPI.**

- `/dev/obmm` — master char device, ioctls for region create/delete/query.
- `/dev/obmm_shmdev{region_id}` — per-region char device, mmap to access the region's pages.

**Region lifecycle** (per `obmm_core.c:79-98` — agent survey).

```c
struct obmm_region {
    refcount_t ref;
    bool       enabled;
    /* ... */
};

void activate_obmm_region(struct obmm_region *r) {
    refcount_set(&r->ref, 1);
    r->enabled = true;
}

bool try_get_obmm_region(struct obmm_region *r) {
    return refcount_inc_not_zero(&r->ref);
}

bool disable_obmm_region_get(struct obmm_region *r) {
    /* dec-if-one: only succeeds when no in-flight users */
    return refcount_dec_if_one(&r->ref);
}
```

The dec-if-one pattern guards against concurrent removal while users hold refs.

**Two region kinds.**

- **Export region.** Local physical memory. Allocator choice: `conti_mem_allocator.c` (contiguous) for HW with strict alignment, `ubmempool_allocator.c` (pooled) for general use.
- **Import region.** Local mapping shim onto remote memory. First access triggers RDMA-fetch over UB or UBoE.

**NUMA + reclaim.** Hooks `memory_hotplug.h`, owns mmu_notifier callbacks for invalidation when remote pages are removed.

**Coherence mechanism (verified 2026-04-25).** `obmm_cache.c` drives HiSilicon SoC-cache HW primitives:

| OBMM op | HW primitive (from `obmm_cache.c:60-66`) |
|---|---|
| invalidate | `HISI_CACHE_MAINT_MAKEINVALID` |
| write-back only | `HISI_CACHE_MAINT_CLEANSHARED` |
| write-back + invalidate | `HISI_CACHE_MAINT_CLEANINVALID` |

`flush_cache_by_pa()` (`obmm_cache.c:57-119`) batches up to **1 GB per call** (`MAX_FLUSH_SIZE`) and retries on `-EBUSY`. `obmm_region_flush_range()` (`obmm_cache.c:121-159`) dispatches by ownership (import vs export region). TLB invalidation is broadcast across the inner-shareable domain via `__tlbi(aside1is, asid)` (`obmm_cache.c:162-171`). A semaphore serializes calls into the HW maintenance primitive to avoid contention. Cache-coherence is HW-enforced at the SoC fabric layer; software just drives the maintenance op. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q4.

**Why this matters.** OBMM is a parallel mechanism to URMA's segment_register: URMA segments are accessed via verb-level operations (post_send WRITE/READ), while OBMM regions are accessed via plain CPU loads/stores backed by the HW coherence fabric. The two are different programming models — message-passing vs shared-memory — over the same underlying UB.

---

## 5. UBMEMPFD + UBDEVSHM — virtualization & shared-mem contexts

**UBMEMPFD** (`drivers/ub/ubmempfd/`). The **vUMMU backend that QEMU plugs into** for guest memory translation (verified 2026-04-25).

- Registers `/dev/ubmempfd` as a misc device (`ubmempfd_main.c:29`).
- **Unusual choice:** uses a **`write()`-based command interface**, not `ioctl` (`ubmempfd_main.c:303-349`). Each `write()` carries a structured payload `{tid, opcode, uba, areas[], size}`.
- Two opcodes: `UBMEMPFD_OPCODE_MAP` → `ubmempfd_do_map()`, and `UBMEMPFD_OPCODE_UNMAP`.
- `ubmempfd_do_iommu_map()` (`ubmempfd_main.c:106-152`) calls `iommu_map()` for each coalesced HPA range, mapping guest HVA → UB Address.
- Allocates / caches a UMMU TDEV (Tagged Device) per context via `ummu_core_alloc_tdev()` (`ubmempfd_main.c:222-259`).

When a guest updates its page tables, QEMU writes the new mapping to `/dev/ubmempfd`; UBMEMPFD programs the real UMMU/IOMMU so HW DMA from UBPUs targets guest memory correctly. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q5.

**UBDEVSHM** (`drivers/ub/ubdevshm/`). Shared-memory device contexts. Lets multiple "user engines" share segment tables and page tables for zero-copy. Exports `/dev/ubdevshm`. ~8 files; integrates with OBMM for cross-process memory sharing.

Both are kernel glue layers; the heavy lifting is in OBMM and UMMU.

---

## 6. UMMU — UB IOMMU

**Path:** `drivers/iommu/hisilicon/{ummu-core, logic_ummu}/`.

**Why two halves.** `ummu-core` is the abstraction — TID (Translation ID) manager, EID registry, ops dispatch. `logic_ummu` is the actual page-table walker, flush handler, interrupt path. Same split as `iommu/intel-iommu` core/dmar.

**Init.** `ummu-core/core.c:14-56` (per agent):

```c
int ummu_core_init(struct ummu_core_device *dev) {
    ummu_core_alloc_tid_manager(dev, &tid_ops, max, min);
    set_global_device(dev);                  /* registers ub_bus_type_iommu_ops */
    return 0;
}
```

**Public API.**

- `ummu_core_register_device()`
- `tid_alloc()`, `tid_free()` — translation-context allocation
- `eid_add()`, `eid_del()` — endpoint registration

**IOMMU framework integration.** Implements `iommu_ops` for the Linux IOMMU framework. UDMA and UNIC call standard `iommu_map()` / `iommu_unmap()`; UMMU services them under the hood.

**SVA path.** UMMU supports SVA (Shared Virtual Addressing) via `iommu_sva_bind_device()`. With SVA, user VA == device VA (same ASID); UMMU shares the kernel page-table walker.

**Invalidation.** Mmu_notifier callbacks (e.g. on `/dev/obmm` import region removal, or process exit) fire UMMU TID invalidation. In-flight HW operations to invalidated pages complete with `LOCAL_ACCESS_ERR` or `REM_ACCESS_ERR` on the CQE.

---

## 7. UDMA hot path — the data plane

UDMA is HiSilicon's UnifiedBus DMA engine, registered as a UBASE auxiliary device and as a `ubcore` provider. The kernel side is `drivers/ub/urma/hw/udma/` (38 files, ~16k LOC). Userspace side is `umdk/src/urma/hw/udma/udma_u_*.{c,h}` (~28 files).

### 7.1 Probe + resource model

**Entry** (per agent — file `udma_main.c:1344-1354`):

```c
int udma_probe(struct auxiliary_device *adev,
               const struct auxiliary_device_id *id) {
    if (udma_init_dev(adev)) {
        ubase_adev_fault_log(adev, UDMA_FAULT_EVENT_ID_PROBE, NULL);
        return -EINVAL;
    }
    ubase_reset_register(adev, udma_reset_handler);
    return 0;
}
```

`udma_init_dev()` allocates the per-device state:

- `struct udma_dev` (`udma_dev.h:110-150` _(unverified)_) — top-level HW context.
- Jetty tables (Xarray-backed): `jetty_table`, `jfr_table`, `jfc_table`.
- Doorbell BAR mapping: `k_db_base` (kernel VA), `db_base` (resource_size_t).
- EQ (event queue) for async completions.
- KSVA — kernel SVA context for UMMU pinning.

**Capability negotiation.** `udma_set_dev_caps()` (per agent — `udma_main.c:122-150`) populates `attr->dev_cap`: max JFS/JFR/JFC depth and count, max jetties per group, SGE limits, inline-payload size, feature flags (e.g. JFC_INLINE), CQE coalescing mode.

**Module parameters** (`udma_main.c:36-46`):

| Param | Type | Effect |
|---|---|---|
| `cqe_mode` | bool | CQE count by CI-PI gap (1) vs explicit count (0) |
| `jfc_arm_mode` | int | 0 = always raise interrupt; non-zero = conditional / coalesced |
| `hugepage_enable` | bool | Use huge pages for queue buffers |
| `jfr_sleep_time` | int | µs between RQ polls in the kthread fallback |

The `jfc_arm_mode=2` flag in UMDK's install instructions implies coalesced interrupt mode is the recommended default.

### 7.2 WQE format

A jetty's send queue stores work requests as **SQEs** (Send Queue Entries), packed into 64-byte **WQEBBs** (Work Queue Entry Basic Blocks). One SQE may span up to 4 WQEBBs depending on opcode and SGE count.

User-visible SQE control header (per agent — `umdk/src/urma/hw/udma/udma_u_jfs.h:17-50`):

```c
struct udma_jfs_sqe_ctl {
    uint32_t sqe_bb_idx : 16;      /* WQE block index */
    uint32_t flag       :  7;
    uint32_t opcode     :  8;      /* WRITE | READ | SEND | ATOMIC */
    uint32_t sge_num    :  8;
    uint32_t tp_id      : 24;      /* Transport Path ID */
    uint32_t rmt_eid[URMA_EID_SIZE];   /* remote EID */
    uint32_t rmt_token_value;
    /* + variable: remote_addr, sgelist or inline payload */
};
```

Sizes (`udma_u_jfs.h:81-114` _(unverified)_):

- `MAX_SQE_BB_NUM = 4`
- `SQE_NORMAL_CTL_LEN = 48`, `SQE_WRITE_IMM_CTL_LEN = 64`
- `UDMAWQE_INLINE_EN = 0x40` flag: encode inline data
- Inline payload max: 192 B for `WRITE_IMM`, 176 B for `WRITE_NTF`

### 7.3 Doorbell mechanics

Each jetty has its own doorbell page (a 4 KB region of HW BAR). Multiple jetties may share one page at different offsets.

**Mapping** (per agent — `udma_db.c:12-65`):

- User: mmap'd page via uburma. VA recorded as `db_addr`.
- Kernel pin: `udma_pin_sw_db()` → `udma_umem_get()` walks page tables, holds page refs.
- Tracking struct `udma_sw_db`: user VA, kernel VA, page ref, `offset` for shared pages.

**Doorbell layout for JFC** (per agent — `udma_abi.h:138-146`):

```c
struct udma_jfc_db {
    uint32_t ci      : 24;   /* completion index */
    uint32_t notify  :  1;   /* request event */
    uint32_t arm_sn  :  2;   /* arm sequence */
    uint32_t type    :  1;
    uint32_t jfcn    : 20;   /* JFC number */
};
```

Doorbell offsets per spec preview (`udma_abi.h:29`): `UDMA_DOORBELL_OFFSET = 0x80`, `UDMA_JFC_HW_DB_OFFSET = 0x40`.

**Format of a single write.** A single 64-bit MMIO store to the doorbell address: lower 32 bits hold CI/notify/arm_sn/type, upper 32 bits hold JFCN. Posted-write semantics on Kunpeng (HiSilicon ARMv8) — HW DMA engine fetches the pending WQE immediately.

### 7.4 Post-send walkthrough

User-app sequence (per agent — `udma_u_jfs.c:115+`):

```c
/* 1. Encode WQE in the user-mmapped JFS ring */
sq->wqebb_index = sq->pi >> 6;        /* 64-byte block index */
memcpy(sq_ring + (pi % ring_size), &wqe, wqe_len);

/* 2. Bump producer */
sq->pi += wqe_block_count;

/* 3. Doorbell write — 64-bit MMIO */
uint64_t db_value = ((uint64_t)jfs_id << 32) | sq->pi;
*(volatile uint64_t *)doorbell_va = db_value;

/* 4. Inner-shareable barrier after MMIO */
asm volatile("dmb ish" ::: "memory");
```

Note: the `wmb()` *before* the MMIO is actually required by the WQE-then-doorbell ordering rule — visible WQE first, then doorbell. The code above conceptually follows: WQE write completion → doorbell store; `dmb` after the doorbell flushes the write itself.

CPU instructions emitted on aarch64 (Kunpeng):

```
str   x0, [doorbell_va]      ; MMIO write
dmb   ish                    ; data memory barrier, inner shareable
```

### 7.5 Completion: poll + event

**Poll mode** (`udma_u_jfc.c`, `udma_jfc.c`):

- CQ ring is mmap'd to userspace.
- User polls JFC's CI (advanced by HW), reads CQE at `(ci % ring_size)`.
- CQE format: opcode, status, length, work-request ID, syndrome, `imm_data`.
- User increments CI, writes CI doorbell to update HW watermark.

**Event mode** (`udma_eq.c:23-83`):

- EQ collects async events from HW.
- Interrupt handler:
  - `udma_ae_jfs_check_err()` (`udma_eq.c:85-102`) — check jetty error.
  - Invokes `ubcore_jetty->jfae_handler()` callback.
  - Callback signals eventfd or per-fd event flag in uburma.
- CQE coalescing controlled by `jfc_arm_mode`.

**Status codes** (per agent — `udma_abi.h:166-187`):

```
UDMA_CQE_SUCCESS                            = 0x00
UDMA_CQE_UNSUPPORTED_OPCODE                 = 0x01
UDMA_CQE_LOCAL_OP_ERR                       = 0x02
UDMA_CQE_TRANSACTION_ACK_TIMEOUT_ERR        = 0x05
JETTY_WORK_REQUEST_FLUSH                    = 0x06
/* + sub-status fields for local/remote data errors */
```

### 7.6 Error paths

- **Timeout** → `UDMA_CQE_TRANSACTION_ACK_TIMEOUT_ERR`.
- **Link down / TP-level error** → async event `UBASE_EVENT_TYPE_TP_LEVEL_ERROR` (`udma_eq.c:41`) → `udma_ctrlq_remove_single_tp()` → flushed pending SQEs return with `JETTY_WORK_REQUEST_FLUSH`.
- **Reset** (`udma_main.c:1356-1403`): `ubcore_stop_requests()` → poll until idle (max 800 ms) → `ubcore_unregister_device()` → `udma_destroy_dev()`.

### 7.7 MMU / IOMMU integration

- User pages pinned via `udma_umem_get()` (looks up VMA, may call `get_user_pages_fast()`).
- IOMMU translation context allocated via UMMU (TID).
- Page table programmed: `iommu_map()` — or, in SVA mode, the kernel pagetable is shared (same ASID).
- TID stored in JFS/JFR/JFC contexts.
- Code path: `udma_jfs.c:75-108` → `udma_create_sgt_from_pages()` → `udma_ioummu_map(ctx, tid, flags, addr, sgt)` → kernel `iommu_map_sg()` (in SVA-off mode).

### 7.8 DCA / HEM evolution from OLK-5.10

**OLK-5.10 hns3** had Dynamic Context Allocation (DCA — pooled HW context cache, file `hns3_udma_dca.c`, ~33 KB) and Hardware Entry Memory paging (HEM — `hns3_udma_hem.c`, ~53 KB).

**OLK-6.6 UDMA does not have DCA or HEM.** `grep` for "dca", "hem", "context_pool", "hardware_entry" in `drivers/ub/urma/hw/udma/` returns nothing. All contexts are pre-allocated upfront in `struct udma_dev`. Jetty allocation uses bitmap IDs (`alloc_jetty_id()`, `udma_jetty.c:269` _(unverified)_).

Most likely rationale: per-UE (user engine — ~47 per chip) instances have smaller scale than the top-of-chip resource pool, so pre-allocation suffices and the paging machinery is dropped for simplicity.

---

## 8. UNIC and CDMA — quick contrast

### UNIC

**Path:** `drivers/net/ub/unic/`. **55 files** (corrected from earlier "~35"). Five biggest: `unic_tx.c` (34 KB), `unic_rx.c` (34 KB), `unic_hw.c` (29 KB), `unic_dev.c` (27 KB), `unic_netdev.c` (23 KB).

**File organization:**

- Core: `unic_main.c`, `unic_dev.c`, `unic_netdev.c`
- Data path: `unic_tx.c`, `unic_rx.c`, `unic_txrx.c`
- HW control: `unic_hw.c`, `unic_channel.c`, `unic_cmd.c`
- Filtering / mgmt: `unic_mac.c`, `unic_vlan.c`, `unic_ip.c`, `unic_bond.c`, `unic_qos_hw.c`
- Misc: `unic_ethtool.c`, `unic_stats.c`, `unic_guid.c`, `unic_dcbnl.h`, `unic_reset.c`, `unic_lb.c`, `unic_crq.c`, `unic_event.c`, `unic_comm_addr.c`
- 8 files in `debugfs/` subdir
- Headers: `unic.h`, `unic_trace.h`

**Role.** UB-native NIC. Exposes a `struct net_device` to the Linux network stack. Multi-queue (RSS), checksum offload, TSO/LSO via UBL, VLAN offload, QoS per virtual lane (Traffic Class mapping), MAC filtering, multicast, GRO, bonding (`unic_bond.c`).

**Module init.** `unic_init()` at `unic_main.c:78` creates a workqueue, registers netdev + IP-addr notifiers, registers an auxiliary driver. Per-device probe `unic_probe()` at `unic_main.c:17` calls `unic_dev_init()`, then `unic_dbg_init()` for debugfs.

**Netdev ops** at `unic_netdev.c:696-709`:

| ndo | Function |
|---|---|
| `.ndo_open` | `unic_net_open` |
| `.ndo_stop` | `unic_net_stop` |
| `.ndo_start_xmit` | `unic_start_xmit` (`unic_tx.c:1222`) |
| `.ndo_select_queue` | `unic_select_queue` (RSS) |
| `.ndo_set_rx_mode` | `unic_set_rx_mode` (multicast filtering) |
| `.ndo_set_mac_address` | `unic_set_mac_address` |

**TX path.** `unic_start_xmit()` at `unic_tx.c:1222` selects an SQ from the channel via `skb->queue_mapping`; pads short packets to 60 bytes if UBL not supported; checks `unic_maybe_stop_tx()` for ring availability; constructs a 64-byte SQE WQE with up to 18 SGEs; stores skb in `sq->skbs[]`; rings doorbell. TX completion polled by `unic_poll_tx()` → `unic_reclaim_sq_space()` (`unic_tx.c:200-243`).

**RX path.** Per-channel NAPI; poll function `unic_poll_rx()` at `unic_rx.c:1129-1180`. Reads JFC CQE at `cq->cqe[cq->ci & cq_mask]` (`:1157`), checks owner bit. Constructs skb via `unic_rx_construct_skb()` at `unic_rx.c:1048-1080` — `napi_alloc_skb(napi, UNIC_RX_HEAD_SIZE=256)`; adds page-frag fragments; `napi_gro_receive()` at `:1126`. Packet-type table `unic_rx_ptype_tbl[]` at `unic_rx.c:32-200` maps HW packet-type ID to `skb->ip_summed`, hash type, L3 type — entry 19 (IPv4 TCP) gives `CHECKSUM_UNNECESSARY` + `PKT_HASH_TYPE_L4`.

**Multi-queue (RSS).** Queue count from `unic_dev->channels.num` and `rss_size`; set via `netif_set_real_num_tx_queues()` / `_rx_queues()` (`unic_netdev.c:92-99`). Default `UNIC_DEFAULT_CHANNEL_NUM` (`unic_dev.c:49`). Max channels = `min(jfs.max_cnt, jfr.max_cnt, jfc.max_cnt >> 1)` (`unic_dev.c:65`). Per-VL queue arrays (`unic_dev.c:84-91`) for QoS. Traffic Class mapping via `unic_netdev_set_tcs()` at `unic_netdev.c:37-77` — VL → TC mapping with `netdev_set_prio_tc_map()`.

**Offload features.** `unic_ethtool_ops` at `unic_ethtool.c:662-690`:

- `.get_ringparam / .set_ringparam` → `unic_get/set_channels_param()` (`:679-680`)
- `.get_link_ksettings` (`unic_ethtool.c:68-80`)
- `.self_test`, `.set_phys_id` referenced in ops table

Hardware does IPv4/TCP/UDP RX checksum verification (per packet-type table). TX checksum enable in SQE control. **TSO/LSO**: UBL (UB Layer) optimization via `CONFIG_UB_UNIC_UBL` (`unic_tx.c:1254`). VLAN: `.ndo_vlan_rx_add_vid / _kill_vid` plus SQE-level VLAN tag insertion. **GRO** via `napi_gro_receive`.

**MAC table mgmt.** `unic_add_del_mac_tbl()` at `unic_mac.c:20-62` uses HW commands `UBASE_OPC_ADD_MAC_TBL` / `UBASE_OPC_DEL_MAC_TBL` (`unic_mac.c:41, 79`). Overflow → macvlan mode (`unic_mac.c:25-26`).

**Difference vs UDMA.** UNIC is a kernel-internal NIC — TX/RX rings are not exposed to userspace. Standard QDisc → netdev TX → UB-native frames. UNIC does **not** ride on URMA; it has its own kernel uAPI.

**Difference vs ipourma.** UNIC is an L2 offload engine — packets bypass kernel TCP processing; HW carries raw frames over UB. ipourma is an L3+ ULP gateway — packets traverse the full kernel stack first, then ipourma tunnels IP flows over URMA jetties. UNIC is the "fast path NIC"; ipourma is the "transparent gateway for legacy IP code". Both can coexist on the same UB hardware.

### CDMA

**Path:** `drivers/ub/cdma/`. **46 files** (corrected from earlier "~48"). Five biggest: `cdma_jfs.c` (26 KB), `cdma_api.c` (25 KB), `cdma_debugfs.c` (21 KB), `cdma_ioctl.c` (20 KB), `cdma_jfc.c` (17 KB).

**Role.** Simpler DMA engine. Bulk CPU↔memory or device↔memory transfers; the `token_id` field is present in SQE control but largely unused at present (`cdma_jfs.h:65`). Simpler trust model — appropriate for VM DMA. CDMA defines "DMA QP" = JFS (send queue) + JFC (completion queue) + CTP (transport path).

**Char device.** `/dev/cdma` (`cdma_chardev.c:19` `CDMA_DEVICE_NAME`); class `cdma_cdev_class` at `cdma_main.c:32`. Ioctl entry `cdma_ioctl()` at `cdma_chardev.c:63`. **Single ioctl command** `CDMA_SYNC` defined at `uapi/ub/cdma/cdma_abi.h:11` as `_IOWR(CDMA_IOC_MAGIC='C', 0, struct cdma_ioctl_hdr)`. Header carries `(command, args_len, args_addr)`; dispatcher `cdma_cmd_parse()` at `cdma_chardev.c:84`.

**Mmap.** `cdma_remap_vma_pages()` (`cdma_chardev.c`) maps the JFS doorbell page; `vm_pgoff` encodes mmap-type. Two mmap types per `uapi/cdma_abi.h:63-66`: `CDMA_MMAP_JFC_PAGE`, `CDMA_MMAP_JETTY_DSQE`.

**Command enum** (per `uapi/ub/cdma/cdma_abi.h:68-84`):

```
CDMA_CMD_QUERY_DEV_INFO       — device capabilities
CDMA_CMD_CREATE_CTX           — user context init
CDMA_CMD_DELETE_CTX
CDMA_CMD_CREATE_CTP           — create transport path
CDMA_CMD_DELETE_CTP
CDMA_CMD_CREATE_JFS / DELETE_JFS
CDMA_CMD_REGISTER_SEG / UNREGISTER_SEG
CDMA_CMD_CREATE_QUEUE / DELETE_QUEUE   — wraps JFS + JFC + CTP
CDMA_CMD_CREATE_JFC / DELETE_JFC
CDMA_CMD_CREATE_JFCE                   — async event queue
CDMA_CMD_MAX
```

**Hot path.** Userspace writes a 64-byte WQE (`cdma_jfs_wqebb` at `cdma_jfs.h:33-35`, four 16-dword arrays) directly to the JFS ring. WQE control `cdma_sqe_ctl` at `cdma_jfs.h:43-70`: DW0 = SQE index + fence + inline + owner; DW1 = opcode (send/write/atomic) + inline length; DW2 = TPN (transport path number) + SGE count; DW4-7 = remote EID (optional); DW8 = remote token. Doorbell offset `CDMA_DOORBELL_OFFSET = 0x80` (`cdma_abi.h:24`); CI mask `GENMASK(21, 0)` lower 22 bits (`cdma_abi.h:26`).

**Status codes** at `cdma_abi.h:43-61` (`enum dma_cr_status`): SUCCESS, unsupported opcode, access error, timeout, etc.

**Userspace `dma_*` API at `cdma_api.c`:** exports `dma_get_device_list()` at line 33 returning `dma_device` array; opaque `private_data`. **No dedicated libcdma found in umdk** — CDMA is wrapped via direct ioctl + mmap from a higher-level lib, likely integrated into URMA userspace (`urma/lib/urma/`).

**Niche.** CDMA complements UDMA. UDMA does RDMA-like remote ops with full QP state machine, atomics, bonding, transport-path migration. CDMA is the minimal local DMA engine for CPU↔mem transfers (e.g. PCIe-attached accelerators, GPU memory, intra-node DMA where overhead must be minimal). Concurrent operation possible.

---

## 9. Cross-section: load order and dependencies

Recapped from UMDK README (the only authoritative source for ordering on real hardware):

```
ubfi               # firmware tables
ummu-core          # IOMMU core
ummu               # vendor-specific UMMU (HiSilicon)
ubus               # UB bus
hisi_ubus          # HiSilicon-specific bus driver
ubase              # auxiliary bus for upper modules
unic               # UB NIC
cdma               # CDMA engine
ubcore             # URMA framework (modprobe)
uburma             # URMA char dev (modprobe)
udma               # URMA hardware provider
```

Module parameter cheat-sheet (also from the README):

| Module | Important params |
|---|---|
| `ubfi` | `cluster=1` (omit for VF NIC) |
| `ummu` | `ipver=609` |
| `ubus` | `ipver=609 cc_en=0 um_entry_size=1` |
| `hisi_ubus` | `msg_wait=2000 fe_msg=1 um_entry_size1=0 cfg_entry_offset=512` |
| `unic` | `tx_timeout_reset_bypass=1` |
| `udma` | `dfx_switch=1 ipver=609 fast_destroy_tp=0 jfc_arm_mode=2` |

The `ipver=609` recurring parameter is a UB silicon revision tag (suspected — needs confirmation).

---

## 10. Open questions / follow-ups

1. **`ipver=609` semantics.** Almost certainly a silicon revision selector. Confirm in `drivers/ub/ubus/vendor/hisi/`.
2. **UDMA MUE — RESOLVED.** UE = **User Engine** (an on-device microcontroller). MUE = Management User Engine. The module is a kernel↔User-Engine control plane for transport-path lifecycle (`GET_TP_LIST`, `ACTIVE/DEACTIVE_TP`, `SET/GET_TP_ATTR`). Carrier is the UBASE control queue. Cited in [`umdk_code_followups.md`](umdk_code_followups.md) §Q1.
3. **`udma_dfx` — RESOLVED.** Query-only context inspection (jfr/jfs/jetty/res via mailbox `UDMA_CMD_QUERY_*_CONTEXT`). No sysfs / debugfs / proc surface; no counters or fault injection. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q2.
4. **OBMM cross-supernode coherence — RESOLVED.** `hisi_soc_cache_maintain()` HW primitives + ASID-broadcast TLB invalidation; see §4 above and [`umdk_code_followups.md`](umdk_code_followups.md) §Q4.
5. **UBMEMPFD virtualization — RESOLVED.** Misc device `/dev/ubmempfd` with `write()`-based command interface; QEMU writes guest HVA → UBA mappings on guest page-table updates. See §5 above and [`umdk_code_followups.md`](umdk_code_followups.md) §Q5.
6. **Why two UMMU drivers?** `ummu-core` vs `logic_ummu` split. Are there other `logic_*` siblings planned?
7. **DCA/HEM removal rationale.** Confirm via Huawei release notes or commit logs.
8. **UNIC offload quirks.** Any UB-specific offloads (e.g. compression, tag-list) not exposed via standard `ethtool -k`?

---

_Companion: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), [`umdk_spec_survey.md`](umdk_spec_survey.md), [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md)._
