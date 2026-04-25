# UMDK / URMA / UDMA — component architecture and end-to-end workflows

_Last updated: 2026-04-25._

Comprehensive reference covering (1) the component architecture of the UnifiedBus software stack across kernel and userspace, and (2) end-to-end dataflow / workflow for the common operations an application performs. Written from direct source reading on the following local clones (see [README](README.md) for full paths):

- Kernel `OLK-6.6` at `~/Documents/Repo/kernel/` (primary).
- Older kernel `OLK-5.10` at `~/Documents/Repo/ub-stack/kernel-ub/` (for contrast).
- Userspace UMDK at `~/Documents/Repo/ub-stack/umdk/`, `master`, post-restructure (latest commit 2026-04-24).

Citations are `path:line`; anything marked _(inferred)_ is an educated guess pending code confirmation. Anything marked _(TODO)_ is acknowledged as missing.

---

## 0. The big picture

URMA is only one of several "upper-layer" UnifiedBus kernel modules. The full UB layer cake in `drivers/ub/` on OLK-6.6 has ~10 distinct subsystems. The architecture roughly divides into three horizontal planes:

```
 Apps ── liburma / urpc / cam / dlock / ums ───────────┐
                                                       │ userspace
 uvs library ── urma_admin / urma_perftest ─── tools   │
───────────────────────────────────────────────────────┘
 /dev/ub_uburma*  (ioctl, mmap)     netlink genl
───────────────────────────────────────────────────────┐
 ubcore (framework, EID, jetty/JFS/JFR/JFC, TP/TPG, UVS cmd, genl)
  │                                                    │
  ├─ uburma (char dev)  ubagg  ulp/ipourma (netdev)    │ kernel
  └─ hw/udma (HiSilicon 2025)                          │
                                                       │
 ubase (auxiliary bus) ── ubus (UB bus) ── ubfi (firmware) ── ubmempfd ── ubdevshm
 obmm (cross-node memory)  sentry (event relay)  cdma (sibling DMA engine)
 UMMU @ drivers/iommu/hisilicon/{ummu-core, logic_ummu}
 UNIC @ drivers/net/ub/unic  (UB NIC, sibling to UDMA)
───────────────────────────────────────────────────────┘
 Hardware (HiSilicon UB-capable silicon: NIC, DMA engines, MMU)
```

URMA is a **userspace-accessible, verbs-like API** for remote memory access. UDMA is a **HiSilicon hardware provider** under URMA's provider framework. UMDK is the **userspace kit** wrapping liburma, providers, control libraries (UVS), and higher-level services (urpc, cam, dlock, ums).

---

## 1. The broader UB kernel ecosystem

`drivers/ub/` contains ten sibling subsystems. Most are not part of URMA per se, but URMA depends on several of them. Each entry below cites its `Kconfig`.

### 1.1 `ubus/` — UB bus driver

`drivers/ub/ubus/Kconfig` — `CONFIG_UB_UBUS` (bool, default `n`).

> "UB bus device management functionality, providing fundamental capabilities such as UB bus registration, device registration, and driver registration."

Contains sub-configs: `UB_UBUS_BUS` (modular part), `UB_UBUS_USI` (Message Signaled Interrupts on UB; selects `GENERIC_MSI_IRQ`), and a vendor subtree at `ubus/vendor/`. This is the foundation that all UB hardware hangs off.

### 1.2 `ubase/` — auxiliary bus for upper modules

`drivers/ub/ubase/Kconfig` — `CONFIG_UB_UBASE` (tristate, default `n`). Depends on `UB_UBUS_BUS && UB_UBUS_USI && UB_UMMU_CORE_DRIVER`.

> "Create auxiliary bus for upper Unifiedbus modules like unic, udma and cdma."

**This is the auxiliary-bus framework that UDMA binds through.** Responsibilities (per earlier survey): command-queue abstraction to hardware (`ubase_cmd.c`, `ubase_mailbox.c`), reset / hotplug, event queue, QoS.

### 1.3 `ubfi/` — UnifiedBus firmware interface

`drivers/ub/ubfi/Kconfig` — `CONFIG_UB_UBFI` (tristate, default `n`, depends on `UB_UBUS`). Firmware interface driver for UB-attached functions.

### 1.4 `ubmempfd/` — memfd address mapping for virtualization

`drivers/ub/ubmempfd/Kconfig` — depends on `UB_UBFI && UB_UMMU_CORE && UB_UMMU`.

> "Provides address mapping on the host side for QEMU, which is a virtualization software that supports UB. And the vUMMU Driver implements the virtualization function of UMMU devices."

This is the UB virtualization piece: host-side translation for a guest's vUMMU.

### 1.5 `ubdevshm/` — shared-memory contexts

`drivers/ub/ubdevshm/Kconfig`. Provides the ability for memory providers to register/deregister shared memory contexts and expose shared-memory info to users. Groundwork for zero-copy between UB-aware processes.

### 1.6 `obmm/` — Ownership-Based Memory Management

`drivers/ub/obmm/Kconfig` — `CONFIG_OBMM` (tristate, default `n`). Depends on `UB_UMMU_CORE && UB_UBUS && HISI_SOC_CACHE`. Selects `NUMA_REMOTE`, `PFN_RANGE_ALLOC`, `RECLAIM_NOTIFY`.

> "A framework for managing shared memory regions across multiple systems. It supports both memory import (accessing remote memory) and export (making local memory visible across systems) operations with proper NUMA integration and provides capability of cross-supernode cache consistency maintenance."

**This is the cache-coherent distributed shared memory layer.** "Supernode" is the UB term for a coherency domain. OBMM lets processes on different supernodes share memory with proper invalidation — it's the memory-side analogue of URMA's jetty-based messaging.

**Coherence mechanism (verified 2026-04-25):** OBMM uses HiSilicon SoC-cache HW primitives via `hisi_soc_cache_maintain()` (op codes `MAKEINVALID`, `CLEANSHARED`, `CLEANINVALID`), with `flush_cache_by_pa()` batching up to 1 GB per call (`obmm_cache.c:57-119`); TLB invalidation is broadcast via ASID using `__tlbi(aside1is, asid)` (`obmm_cache.c:162-171`). A semaphore serializes calls into the HW primitive. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q4 for full citations.

### 1.7 `sentry/` — kernel→userspace event relay

`drivers/ub/sentry/Kconfig` — `CONFIG_UB_SENTRY` (tristate, default `m`, depends on `UB && ACPI_POWER_NOTIFIER_CHAIN`).

> "Listens to kernel event(eg. oom) and send sentry msg to userspace. Provides device for userspace to read kernel message and reply ack."

Plus `UB_SENTRY_REMOTE` (tristate, default `m`, depends on `UB_SENTRY && UB_URMA`) to relay panic/reboot events over URMA to remote nodes.

### 1.8 `cdma/` — CDMA (sibling DMA engine)

`drivers/ub/cdma/Kconfig` — `CONFIG_UB_CDMA` (tristate, default `n`). Depends on `UB_UBASE && UB_UMMU_CORE`.

> "Facilitates the creation and destruction of CDMA devices, as well as the creation of resources within CDMA devices to perform DMA read/write tasks and retrieve the completion status of executed tasks."

CDMA is a **sibling to UDMA**. Both register as aux-bus devices under UBASE. Roles likely distinct (CDMA may be chiplet-to-chiplet on-die; UDMA is fabric-scale) _(inferred — confirm)_.

### 1.9 `urma/` — URMA framework (the subject of this doc)

`CONFIG_UB_URMA` (tristate, default `m`) at `drivers/ub/Kconfig:26-33`. See §2.

### 1.10 Adjacent: UMMU and UNIC (outside `drivers/ub/`)

- **UMMU** at `drivers/iommu/hisilicon/{ummu-core, logic_ummu}/` — the UB IOMMU. Many of the `drivers/ub/` modules depend on `UB_UMMU_CORE` for IOVA translation.
- **UNIC** at `drivers/net/ub/unic/` — a UB-based NIC (Ethernet-like). Called out in `ubase/Kconfig` as one of the upper modules ("unic, udma and cdma").

**Implication:** UDMA's "hardware provider" role is narrower than it first appears. UDMA is one of at least three aux-bus UB device types (UNIC, UDMA, CDMA). UNIC and CDMA have their own uAPIs and do not ride on URMA.

---

## 2. Kernel URMA: `drivers/ub/urma/`

Five kernel subdirectories: `ubcore/`, `uburma/`, `ubagg/`, `ulp/ipourma/`, `hw/udma/`.

### 2.1 `ubcore/` — framework core

**Location:** `drivers/ub/urma/ubcore/` — ~66 files, ~18k LOC.

**Role.** Central control plane and object model for URMA. Owns the provider registry, per-process ucontexts, jetty/JFS/JFR/JFC object managers, segment registry, EID management, transport-path (TP/TPG/VTP) state machine, UVS command gateway, and the netlink generic family.

**Public API.**
- `ubcore_register_device()` at `drivers/ub/urma/ubcore/ubcore_device.c:1223` (verified). `EXPORT_SYMBOL` at line 1289.
- Provider vtable `struct ubcore_ops` at `include/ub/urma/ubcore_types.h:2101` (verified); referenced via `struct ubcore_device::ops` at types.h:3366.
- Public headers: `ubcore_api.h`, `ubcore_types.h`, `ubcore_opcode.h`, `ubcore_uapi.h` under `include/ub/urma/`.

**Internal managers (by file):**

| File | Responsibility |
|---|---|
| `ubcore_device.c` | Provider registration, device list, hot-remove |
| `ubcore_jetty.c` | Jetty lifecycle (create/modify/destroy/bind/import) |
| `ubcore_tp.c` / `ubcore_vtp.c` / `ubcore_tpg.c` | Transport Path state machine, virtual TP, TP groups |
| `ubcore_uvs_cmd.c` (~92 KB) | UVS-admin command plane |
| `ubcore_genl.c`, `ubcore_genl_admin.c`, `ubcore_genl_define.h` | Netlink `genl` family for stats/topology queries |
| `ubcore_segment.c` | Memory segment registration |
| `ubcore_umem.c` | Page pinning via `get_user_pages_fast`, IOVA mapping |
| `ubcore_hash_table.c` | Hash tables for jetty/segment/EID lookups |
| `ubcore_workqueue.c` | Jetty→TP workqueue dispatch |

**Key data structures** (all in `include/ub/urma/ubcore_types.h`):

| Struct | Line | Role |
|---|---|---|
| `ubcore_device` | 3366 | Registered provider device handle |
| `ubcore_ops` | 2101 | Provider vtable (~20 fn ptrs) |
| `ubcore_ucontext` | 1231 | Per-process kernel context |
| `ubcore_tp` | 957 | Transport path (PSN, state, peer EID) |
| `ubcore_tpg` | 1026 | TP group (up to 32 TPs, RM/UM mode) |
| `ubcore_jetty` | 1152 | IB-QP analogue |
| `ubcore_jfs` / `ubcore_jfr` / `ubcore_jfc` | 1367 / 1433 / 1506 | Send / recv / completion queues |

**Depends on:** Linux `device model`, `auxiliary_device` via UBASE, netlink `genl`, `mmu_notifier`, UMMU (`UB_UMMU_CORE`).

**Depended on by:** `uburma` (ioctl routing), `ipourma` ULP, userspace via uburma.

### 2.2 `uburma/` — character device bridge

**Location:** `drivers/ub/urma/uburma/` — ~15 files.

**Role.** User↔kernel boundary. Registers per-device char device (`/dev/ub_uburma*`), dispatches ioctls, and brokers mmap'd doorbell/WQ/CQ regions.

**ioctl surface.** `uburma_cmd.h:34-36` (verified):

```c
#define UBURMA_CMD_MAGIC 'U'
#define UBURMA_CMD _IOWR(UBURMA_CMD_MAGIC, 1, struct uburma_cmd_hdr)
```

Single ioctl entrypoint; the specific operation is discriminated by an enum in the header. A `grep -c 'UBURMA_CMD_[A-Z]'` counts **101 tokens** (verified) covering the full uAPI surface — context lifecycle (CREATE_CTX, DESTROY_CTX), memory (REGISTER/UNREGISTER/IMPORT_SEG, ALLOC/FREE_TOKEN_ID), work queues (CREATE_JFS/JFR/JFC, ARM_JFC), jetty (CREATE/MODIFY/DELETE/BIND/IMPORT_JETTY, CREATE_JETTY_GRP), EID (ADD/DELETE_EID, GET_EID_LIST), device (QUERY_DEV_ATTR, QUERY_STATS), and MMAP.

**mmap path.** `uburma_mmap.c` maps doorbell pages, WQ/CQ rings; tracks VMAs per-fd for teardown on close. `uburma_main.c:20` installs the mmap file op.

**Object tracking.** `uburma_uobj.c` tables handles per-fd so abrupt close reclaims in-flight objects. `uburma_event.c` delivers async events (CQ armed, errors, port state) via eventfd.

**Key structs:** `uburma_cmd_hdr` (command, args_len, args_addr) at `uburma_cmd.h:24`; `uburma_file` per-fd state.

### 2.3 `ubagg/` — aggregator (working)

**Location:** `drivers/ub/urma/ubagg/`. **Working module, not a stub** — ~3,479 LOC across 16 files (verified 2026-04-25). Largest is `ubagg_ioctl.c` (1,886 LOC). Exposes `/dev/ubagg` char device for management; `ubagg_main.c:148` calls `ubagg_delete_topo_map()` and `ubagg_clear_dev_list()` on exit, confirming topology + device-list management is real. Userspace UVS calls into UBAGG via ioctl. Replica-side bonding paths are the only stubbed parts; primary functionality is fully wired. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q6.

### 2.4 `ulp/ipourma/` — IP-over-URMA ULP

**Location:** `drivers/ub/urma/ulp/ipourma/` — ~25 files.

**Role.** Presents URMA as a Linux `net_device` so that legacy IP traffic can run over UB jetties without kernel changes in the network stack. A classic upper-layer protocol pattern (analogous to IPoIB).

**Files of interest:**
- `ipourma_netdev.c` — netdev registration, TX/RX handlers.
- `ipourma_addr_res.c` — IP→EID resolution (UB analogue of ARP/ND).
- `ipourma_netlink.c` — userspace configuration channel.
- `ipourma_sysfs.c` — per-device sysfs for debugging.

**Data plane.** TX intercepts IP packets, looks up destination EID, posts an URMA SEND on a jetty bound to (src_eid, dst_eid). RX drains completions from JFR, rebuilds `skb`s, and hands them back to the IP stack.

**Depends on:** ubcore (jetty/segment), Linux netdev, netlink.

### 2.5 `hw/udma/` — HiSilicon UDMA hardware provider

**Location:** `drivers/ub/urma/hw/udma/` — 38 files, ~15.8k LOC (verified file list).

**Role.** HiSilicon's 2025-gen UnifiedBus DMA hardware driver. Implements the `ubcore_ops` vtable and binds through UBASE's auxiliary-bus framework.

**File map** (verified full list):

| Files | Role |
|---|---|
| `udma_main.c` | Probe (`udma_probe()` → `ubcore_register_device()`), module init |
| `udma_ctx.{c,h}` | `alloc_ucontext` — per-process HW context |
| `udma_jetty.{c,h}`, `udma_jetty_group.{c,h}` | Jetty + jetty-group (multipath) |
| `udma_jfs.{c,h}` / `udma_jfr.{c,h}` / `udma_jfc.{c,h}` | Send / recv / completion queue HW impl |
| `udma_db.{c,h}` | Doorbell MMIO region management |
| `udma_eq.{c,h}` | Event queue (interrupt handling) |
| `udma_segment.{c,h}`, `udma_tid.{c,h}` | Segment registration, token ID (rkey) allocation |
| `udma_cmd.{c,h}`, `udma_ctl.c`, `udma_ctrlq_tp.{c,h}` | Command-ring interface to HW; control-queue TP programming |
| `udma_eid.{c,h}` | EID management at the provider level |
| `udma_mue.{c,h}` | MUE = Management User Engine; kernel↔microcontroller control plane for transport-path lifecycle (GET/ACTIVE/DEACTIVE/SET/GET_TP_ATTR), `udma_mue.c:29, 262-280` |
| `udma_def.h`, `udma_dev.h`, `udma_common.{c,h}` | Common defs, device struct, utilities |
| `udma_dfx.{c,h}` | Debug/introspection (DFx) |
| `Kconfig`, `Makefile` | `CONFIG_UB_UDMA`, depends on `UB_UBASE && UB_URMA && UB_UMMU_CORE` |

**uAPI header** at `include/uapi/ub/urma/udma/udma_abi.h` (jetty types, doorbell layout, CQE format).

**Fast-path contract.** Userspace produces WQEs directly in mmap'd WQ rings; post-send is an MMIO doorbell write after a `wmb()`. HW DMA-reads the WQE, moves data across UB, writes CQE to the JFC ring. No syscall per operation.

**Register/doorbell:** mmap-ed page set up by `udma_db.c` in kernel, consumed by `src/urma/hw/udma/udma_u_db.c` in userspace. Exact offsets in `udma_abi.h`.

### 2.6 For contrast: OLK-5.10 `drivers/ub/hw/hns3/`

**Older HiSilicon NS3 provider**, ~44 files on OLK-5.10 (see `~/Documents/Repo/ub-stack/kernel-ub/`). Key files to read if archaeology is needed:

| File | Role |
|---|---|
| `hns3_udma_hw.c` (62 KB) | Hot path |
| `hns3_udma_qp.c` (64 KB) | QP state machine |
| `hns3_udma_hem.c` (53 KB) | HEM (Hardware Entry Memory) paging |
| `hns3_udma_dca.c` (33 KB) | Dynamic Context Allocation |

DCA and HEM are absent from 2026-04 `hw/udma/` in OLK-6.6 — the new HW apparently has enough on-die resources or a different allocation model that removes the need for those optimizations.

Also on 5.10: `drivers/roh/` and `hns3_roh.{c,h}` — ROH (RoCE-over-HSlink) was an earlier RDMA-over-Huawei-fabric effort; superseded by URMA.

---

## 3. Userspace UMDK: `umdk/src/`

The umdk repo restructured between Nov 2024 and early 2026: old top-level (`common/`, `hw/`, `include/`, `lib/`, `tools/`, `transport_service/`) was replaced by `src/` with multiple sub-stacks.

### 3.1 `src/urma/lib/urma/` — liburma

**Role.** Userspace URMA library. Exposes `urma_api.h` primitives; underneath, dispatches to provider shared libraries loaded at runtime.

**Files of interest:**
- `core/urma_main.c:49` — `urma_register_provider_ops()` (provider self-registration at library load via constructor).
- `core/urma_main.c:64` (_(approx, confirm)_) — provider discovery: dlopen of `*.so` from `/usr/lib64/urma/`.
- `core/urma_device.c` — device enumeration (sysfs / netlink).
- `core/urma_cmd.c` — ioctl packing: issues `ioctl(dev_fd, URMA_CMD, &hdr)` to `/dev/ub_uburma*`.

**Public API** (`include/urma_api.h`, representative):

| Category | Functions |
|---|---|
| Context | `urma_create_context`, `urma_destroy_context` |
| Memory | `urma_register_seg`, `urma_unregister_seg`, `urma_import_seg` |
| Queues | `urma_alloc_jfc`, `urma_alloc_jfr`, `urma_alloc_jfs` |
| Jetty | `urma_create_jetty`, `urma_delete_jetty`, `urma_import_jetty`, `urma_bind_jetty` |
| Work | `urma_post_send`, `urma_poll_jfc` |

**Produces:** `liburma.so.1` via CMake.

### 3.2 `src/urma/lib/uvs/` — UVS (Unified Vector Service) library

**Role.** Control-plane library exposing topology / transport-path operations. Replaces the older TPSA daemon (whose source was deleted in the restructure).

**Key header.** `src/urma/lib/uvs/core/tpsa_ioctl.h:30-31` (verified):

```c
#define TPSA_CMD_MAGIC 'V'
#define TPSA_CMD       _IOWR(TPSA_CMD_MAGIC, 1, tpsa_cmd_hdr_t)
```

**UVS has its own ioctl magic `'V'` (vs URMA's `'U'`).** Separate command plane from the user data-plane ioctl.

**Commands seen:** `UVS_CMD_SET_TOPO`, `UVS_CMD_GET_TOPO`, `UVS_CMD_GET_TOPO_PATH_EID`, with topology types (fullmesh, Clos, etc.) and path types RTP (reliable), CTP (control), UTP (user) per `tpsa_ioctl.h:34`.

**Related.** `uvs_ubagg_ioctl.h:36` defines a parallel `UVS_UBAGG_CMD` for aggregator/bonding control.

**Key data structures:**

- `uvs_eid_t` at `uvs_types.h:22` — 16-byte EID (network order), carrying IPv4/v6 interface ID + subnet prefix.
- `tpsa_ioctl_ctx_t` at `tpsa_ioctl.h:33` — ioctl context (fd + session).
- `uvs_route_t`, `uvs_route_list_t` — route descriptors.

**Resolved (2026-04-25):** UVS is **library-only** — no daemon process. Confirmed by direct code inspection (no `int main()` in `lib/uvs/`, no systemd unit, no init script). Topology / path-selection state is held by the kernel (in ubcore + ubagg); UVS is just the userspace caller-driven ioctl wrapper. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q8.

### 3.3 `src/urma/hw/udma/` — userspace UDMA provider

**Role.** Userspace fast path for UDMA hardware. Files named `udma_u_*` (~28 files) mirror the kernel `hw/udma/` layout.

| Userspace | Kernel peer |
|---|---|
| `udma_u_main.c` (constructor registers via `urma_register_provider_ops(&g_udma_provider_ops)` at line 16) | `udma_main.c` |
| `udma_u_ctx.c` | `udma_ctx.c` |
| `udma_u_db.{c,h}` — doorbell mmap | `udma_db.{c,h}` |
| `udma_u_jfs.{c,h}` / `udma_u_jfr.{c,h}` / `udma_u_jfc.{c,h}` | same roots without `u_` |
| `udma_u_segment.{c,h}` | `udma_segment.{c,h}` |
| `udma_u_abi.h` | userspace copy of kernel ABI header |
| `udma_u_ctl.c`, `udma_u_ctrlq_tp.h`, `udma_u_buf.c`, `udma_u_log.{c,h}`, `udma_u_tid.h` | control channel, buffer mgmt, log, tid |

**Output.** `libudma_udma.so` (or similar name) staged to `/usr/lib64/urma/` for liburma's dlopen.

### 3.4 `src/urma/tools/` — CLI tools

| Tool | Role |
|---|---|
| `urma_admin` | Device enumeration + topology configuration (issues `UVS_CMD_*` via TPSA ioctl) |
| `urma_perftest` | Benchmark harness — send/recv latency + bandwidth, atomics, multipath |
| `urma_ping` | Minimal connectivity test: open → jetty → send → recv |

### 3.5 `src/urpc/` — RPC framework + umq

**Sub-structure.** `framework/` (serialization, method dispatch), `umq/` (three backends: `umq_ipc` for AF_UNIX/SHM, `umq_ub` for URMA-transported messaging, `umq_ubmm` for URMA + memory-mapped zero-copy), `util/`, `include/`, `config/`, `examples/`, plus Bazel and CMake build files.

**Purpose.** Exposes an application-level RPC API whose transport can be local IPC or remote URMA, transparently to the caller. `umq_ub` posts RPC requests on URMA jetties and completes on peer JFR.

**Third-party vendored.** `src/urpc/third_party/{openssl,urma,zlib}` — in-tree copies _(source-of-truth TBD)_.

### 3.6 `src/usock/ums/` — UB message socket

**Role.** POSIX-sockets-like API backed by URMA jetties. Likely registers an `AF_UB` socket family (confirm in the `kmod/` subdir) or intercepts libc socket calls via LD_PRELOAD.

**Sub-structure.** `cmake/`, `kmod/`, `tools/`, + core sources. _(TODO: read `kmod/` to determine whether UMS requires an in-tree kernel module beyond uburma.)_

### 3.7 `src/ulock/dlock/` — distributed lock library

**Role.** Lock primitives (mutexes, semaphores, leases) over shared memory accessed with URMA atomics. Sub-structure `cmake/`, `examples/`, `include/`, `lib/`, `tools/`.

### 3.8 `src/cam/` — collective communication / math

**Sub-structure.** `comm_operator/` with `ascend_kernels/` and `pybind/`; `examples/`.

**Role.** Collective communication primitives (allreduce, allgather, broadcast) targeting AI workloads. `ascend_kernels/` contains low-level code for the HiSilicon Ascend NPU. `pybind/` provides a Python entry point — plausibly used by a PyTorch/MindSpore collective backend.

**Integration.** Collective algorithms decompose into point-to-point URMA sends/receives; NPU-resident kernels can fuse computation (e.g. reduce operator) with communication.

---

## 4. End-to-end workflows

Each subsection traces a concrete operation from user code through the stack. All citations are `file:line`; every step names either a concrete function or a concrete ioctl/ops slot.

### 4.1 Device discovery and binding

1. **Physical discovery.** UBUS enumerates UB hardware during boot; `ubase/` registers as the aux-bus parent for upper modules (see `ubase/Kconfig`: "create auxiliary bus for upper Unifiedbus modules like unic, udma and cdma").
2. **UDMA probe.** Auxiliary bus calls `udma_probe()` in `udma_main.c`. Device capabilities are negotiated; HW resources (queues, doorbells, EQs) are allocated.
3. **URMA registration.** `udma_probe()` → `ubcore_register_device(&dev->ub_dev)` at `ubcore_device.c:1223`. ubcore validates, calls its internal `init_ubcore_device()`, adds to global `g_device_list`, and creates the per-device character node via uburma.
4. **udev notification.** Kernel signals the char-dev creation; udev rules (if installed) stabilize `/dev/ub_uburma_<devname>` paths.
5. **Userspace enumeration.** liburma's `urma_get_device_list()` scans sysfs or netlink-queries ubcore's genl family; apps then open `/dev/ub_uburma_*` and issue `UBURMA_CMD_QUERY_DEV_ATTR`.

### 4.2 Context creation

```
urma_create_context()                                        [liburma]
  → ioctl(fd, UBURMA_CMD) { cmd=UBURMA_CMD_CREATE_CTX, ... } [uburma_cmd.c]
    → ubcore_create_ucontext()                               [ubcore]
      → dev->ops->alloc_ucontext(dev, eid_index, udata)      [udma_ctx.c]
    ← returns ubcore_ucontext*
  ← returns uctx handle
  → mmap() the doorbell / WQ base pages                      [uburma_mmap.c]
    → provider->ops->mmap(uctx, vma)                         [udma_db.c]
```

### 4.3 Memory registration

```
urma_register_seg(ctx, va, len, ...)                                [liburma]
  → ioctl(UBURMA_CMD_REGISTER_SEG)                                  [uburma]
    → ubcore_register_seg()                                         [ubcore_segment.c]
      → ubcore_umem_pin_pages(va, len)                              [ubcore_umem.c]
        → get_user_pages_fast()  (pins pages, elevates refs)
      → dev->ops->register_seg(dev, cfg, udata)                     [udma_segment.c]
        → iommu_map()  (IOVA set up via UMMU)
        → alloc_token_id() (rkey-equivalent)
        → records in ubcore_target_seg
  ← returns token_id to userspace
```

Key detail: the token_id is allocated separately from the segment (unlike IB rkey which is a property of an MR). This is what enables **rotating token revocation** at the spec level — a segment remains registered while tokens protecting it are churned.

### 4.4 Jetty lifecycle

Four phases: CREATE → MODIFY (state) → IMPORT (peer) → BIND (to TP).

```
CREATE:
  urma_create_jetty(ctx, { jfs_depth, jfr_depth, jfc_depth, ... })
    → ioctl(UBURMA_CMD_CREATE_JETTY)
      → ubcore_create_jetty()                                  [ubcore_jetty.c]
        → dev->ops->create_jfs(..)                             [udma_jfs.c]
        → dev->ops->create_jfr(..)                             [udma_jfr.c]
        → dev->ops->create_jfc(..)                             [udma_jfc.c]
        → allocate ubcore_jetty, link queues
    → mmap JFS/JFR/JFC rings into userspace
  ← urma_jetty* returned

MODIFY (INIT → RTR → RTS-equivalent):
  urma_modify_jetty(jetty, { new_state, ... })
    → ioctl(UBURMA_CMD_MODIFY_JETTY)
      → dev->ops->modify_jetty(jetty, attr, udata)             [udma_jetty.c]

IMPORT (produce a handle to a remote peer jetty):
  urma_import_jetty(ctx, peer_info)
    → ioctl(UBURMA_CMD_IMPORT_JETTY)
      → ubcore_import_jetty() : allocates an import handle bound to peer_id

BIND (pin to a transport path):
  urma_bind_jetty(jetty, { src_eid, dst_eid, ... })
    → ioctl(UBURMA_CMD_BIND_JETTY)
      → ubcore_bind_jetty()                                    [ubcore_jetty.c]
        → ubcore_get_or_create_tp(..)                          [ubcore_tp.c]
          → if miss: dev->ops->create_tp(dev, tp_cfg, udata)   [udma_ctrlq_tp.c]
        → link jetty → TP
```

### 4.5 Post-send (fast path)

No syscall on the happy path; everything after `urma_create_context()` runs in userspace until the doorbell MMIO.

```
urma_post_send(jetty, wr_list)                             [liburma+provider]
  for each wr:
    1. Allocate WQE slot in JFS ring (bump producer index in userspace).
    2. Fill WQE: opcode (SEND | WRITE | READ | ATOMIC), sgelist, remote_addr, rkey.
    3. wmb() / std::atomic release  (makes WQE globally visible before doorbell).
    4. MMIO store to doorbell[jetty_id]  — single CPU→HW write.

[HW]
  - Sees new WQE, DMA-reads it.
  - If WRITE/READ: DMAs data to/from local memory via the local UMMU.
  - Transports over UB fabric.
  - At remote end: for WRITE, DMAs into peer segment; for SEND, lands in peer JFR.
  - Generates CQEs on both sides (as requested).

urma_poll_jfc(jfc)                                         [liburma]
  Read JFC producer index (written by HW into ring metadata).
  For each new CQE:
    extract {status, opcode, jetty_id, imm_data, ...}
    fire user callback / return to caller.
  Bump consumer index.
```

**Why this is fast.** No ioctl per operation; only MMIO + memory barriers. The mmap'd WQ and CQ pages are the entire data plane.

### 4.6 Completion handling (poll vs event)

- **Poll mode.** App calls `urma_poll_jfc()` directly — the happy path in latency-sensitive code.
- **Event mode.** App registers an `eventfd` (via `UBURMA_CMD_ARM_JFC` or similar) and blocks in `epoll`. On HW completion, the provider's EQ interrupt handler (`udma_eq.c`) routes an event through ubcore → uburma → `eventfd_signal()`. App wakes, drains completions.

### 4.7 Teardown

Orderly close walks the object graph bottom-up: JFS/JFR/JFC → jetty → TP (ref-counted; destroyed only if last user) → segment (`iommu_unmap`, `put_user_pages`, release token) → ucontext (`free_ucontext`) → file `close()`. Abrupt close triggers `uburma_file_ops` release, which walks the uobj table for the fd and destroys survivors in the same order.

### 4.8 Control plane: UVS topology

```
admin tool (urma_admin) or UVS-using app
  → uvs_ioctl_in_global(ctx, UVS_CMD_SET_TOPO, topo)             [tpsa_ioctl.c]
    → ioctl(ubcore_fd, TPSA_CMD) with magic 'V'                  [tpsa_ioctl.h:30-31]
      → ubcore_uvs_cmd_parse()                                   [ubcore_uvs_cmd.c]
        → installs topology; may push down to provider via ops

Later, jetty bind path calls:
  uvs_ioctl_in_global(ctx, UVS_CMD_GET_TOPO_PATH_EID, {src_eid, dst_eid})
    → ioctl(TPSA_CMD)
      → ubcore_uvs_cmd_query_path() returns RTP/CTP/UTP list with mp flags
```

In parallel, `genl` family (`ubcore_genl.c:46` with ops array) answers stats/res queries out-of-band.

### 4.9 Multipath (jetty_grp / LAG)

A `urma_jetty_grp` aggregates multiple TPs between the same (src_eid, dst_eid) pair. Post-send to the group hashes or round-robins across member jetties; TP failure drops the failed member and steers subsequent posts to survivors. Load-balance policy is in the userspace bond provider (`bondp_*` in liburma). _(TODO: confirm the exact hash policy; earlier surveys did not find a concrete implementation file.)_

### 4.10 ipourma netdev I/O

- **TX:** IP stack → `ipourma_netdev_start_xmit()` → resolve dst_ip to EID via `ipourma_addr_res.c` → select jetty → `urma_post_send` with packet buffer → completion frees skb.
- **RX:** provider completion → `ipourma` RX handler pulls buffer → wraps in `skb` → `netif_receive_skb()` → up the IP stack.

### 4.11 URPC request/response (umq_ub backend)

```
Client
  urpc_call(service, method, args)
    → marshal args                               [framework/core]
    → umq_send(umq_ub_tx, rpc_msg)
      → urma_post_send(jetty, &msg_sge)
    → await JFR completion for response

Server
  urma_poll_jfr(jfr)
    → urpc_dispatch(rpc_msg)
      → lookup method_id, demarshal, invoke handler, marshal result
    → urma_post_send(reverse_jetty, response)
```

### 4.12 CAM collective (e.g. ring allreduce)

```
python: cam.collective.allreduce(tensor, op=SUM)   [pybind entry]
  → algorithm selector (ring / tree / halving-doubling)
  → for each phase k of N-1 phases:
       urma_post_send(neighbor_jetty, chunk_k)
       urma_poll_jfr(prev_jetty) → recv chunk
       reduce_op(local[k], recv_chunk)  — possibly fused on NPU via ascend_kernels
```

On Ascend NPUs, the reduction can be implemented directly in HBM-resident kernel code, minimizing host-device transfers. _(Confirm API boundary with a closer read of `src/cam/comm_operator/pybind/`.)_

---

## 5. Cross-component view

### 5.1 Control vs data plane separation

```
        ┌─── Control plane (ioctl magic 'V', genl, urma_admin) ──┐
UVS lib ├──► ubcore ─► provider ops ─► HW config                 │
        └────────────────────────────────────────────────────────┘

        ┌─── Data plane (mmap doorbell + WQ/CQ rings) ───────────┐
liburma │  userspace producer ─► MMIO doorbell ─► HW DMA ─► CQE  │
        └────────────────────────────────────────────────────────┘
```

The two planes are deliberately separate: the data plane has no kernel entry after context setup; the control plane uses two distinct ioctl magics (`'U'` for URMA user ops, `'V'` for UVS/TPSA) plus a genl family for queries.

### 5.2 Object ownership

```
ubcore_device
└─ ubcore_ucontext  (per process)
   ├─ ubcore_jetty  (per logical endpoint)
   │  ├─ ubcore_jfs / ubcore_jfr / ubcore_jfc
   │  └─ ubcore_tp  (ref-counted, shared across jetties to the same peer)
   │     └─ ubcore_tpg  (if in a multipath group)
   └─ ubcore_target_seg  (each registered memory region)
      ├─ ubcore_token_id  (rkey, can rotate independently)
      └─ ubcore_umem  (pinned pages + IOVA)
```

### 5.3 Data-plane send timeline (consolidated)

```
app → liburma → WQE into ring → wmb → doorbell MMIO
     │                                │
     └── userspace only ──────────────┘
                                      │
                                      ▼
                                 HW DMA read
                                      │
                                      ▼
                              UB fabric → remote HW
                                      │
                       ┌──────────────┴──────────────┐
                       ▼                             ▼
                 SEND → remote JFR           WRITE → remote segment
                       │                             │
                       └──────── remote CQE ─────────┘
                                      │
                                      ▼
                               local CQE (if requested)
                                      │
                                      ▼
                          urma_poll_jfc → app callback
```

---

## 6. Open questions / code-reading TODOs

_Several previously-listed questions have been resolved — see [`umdk_code_followups.md`](umdk_code_followups.md) for the answers._

**Resolved in follow-up rounds:**

- ~~UVS daemon~~ → confirmed **library-only**; topology state is in the kernel. (See §3.2 above.)
- ~~ubagg/ stub status~~ → confirmed **working module** (~3,479 LOC), only replica-side paths stubbed. (See §2.3 above.)
- ~~MUE event channel~~ → confirmed **UE = User Engine** (microcontroller); MUE is a kernel↔User-Engine control plane for transport-path lifecycle.
- ~~CAM Ascend kernels~~ → confirmed **real AscendC kernels** (not stubs), built via `add_kernels_compile()` CMake macro with `__global__ __aicore__` signatures.
- ~~OBMM vs URMA segments~~ → OBMM is a parallel mechanism (cross-supernode shared memory) using `hisi_soc_cache_maintain()` for coherence; URMA segments are independent (verb-level RDMA targets).
- ~~UMS kernel module~~ → it's an out-of-tree module that **takes over the upstream `AF_SMC` family** (replaces SMC-R). Not `AF_UB`.

**Still open:**

1. **DCA / HEM in UDMA.** Both present in OLK-5.10 hns3 provider but absent from OLK-6.6 `hw/udma`. Assume simpler HW or offloaded? Find Huawei's release notes.
2. **UNIC + CDMA depth dive.** Two sibling aux-bus upper modules. Worth focused surveys.
3. **Bond provider in liburma.** The `bondp_*` files drive multipath, but specific policy (hash function, failure detection timing) needs a code read.
4. **ipourma per-jetty vs per-CPU scaling.** Does ipourma use one jetty per netdev or one per CPU? Impacts throughput.
5. **Atomicity of hot-remove.** URMA supports hot-remove; the interplay between in-flight WQEs, mmu_notifier, and uobj tracking is complex. Full guarantees need a targeted read.
6. **`ipver=609`.** Lives outside the public openEuler tree (HAL / firmware blob). Needs Huawei vendor docs.
7. **Live-migration story.** `ubcore_vtp` (virtual TP) hints at it; not yet traced.

---

## 7. Further reading within the repos

**If you have one hour, read (in order):**

1. `include/ub/urma/ubcore_types.h` around line 2101 — the `ubcore_ops` vtable. Shape of the provider interface.
2. `drivers/ub/urma/uburma/uburma_cmd.h` — the whole ioctl uAPI surface.
3. `drivers/ub/urma/ubcore/ubcore_device.c:1223` — `ubcore_register_device` — how providers hook in.
4. `drivers/ub/urma/hw/udma/udma_main.c` (probe path) — how a concrete provider binds.
5. `~/Documents/Repo/ub-stack/umdk/src/urma/hw/udma/udma_u_main.c` — userspace provider symmetry.
6. `~/Documents/Repo/ub-stack/umdk/src/urma/lib/uvs/core/tpsa_ioctl.h` — control-plane ioctl.

**If you have a weekend:** work through the full post-send path, from `udma_u_jfs.c` (userspace WQE encode) → `udma_u_db.c` (doorbell) → `udma_jfs.c` / `udma_db.c` (kernel definitions that set up the rings) → ABI at `include/uapi/ub/urma/udma/udma_abi.h`.

---

_This document is a living reference. Updates should add new sub-sections or revise open questions rather than rewriting verified history; append a new `_Last updated:_` date when revising substantively._
