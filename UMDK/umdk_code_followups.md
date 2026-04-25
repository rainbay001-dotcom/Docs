# UMDK code-side follow-ups — answers to open questions

_Last updated: 2026-04-25._

Targeted code reads to resolve specific questions left open by earlier docs in this directory. Each entry is question → concrete answer with `path:line` citations → residual unknown if any. Source: kernel `OLK-6.6` (`~/Documents/Repo/kernel/`) + userspace `umdk/master`.

---

## Q1. `udma_mue` — what is "UE"?

**Answer.** UE = **User Engine**. MUE = **Management User Engine**. The module is the kernel↔microcontroller control-plane for transport-path lifecycle.

**Evidence.**

- `drivers/ub/urma/hw/udma/udma_mue.c:29` defines `udma_send_ue_msg()` — sends "mue2ue" frames.
- `udma_mue.c:51-52` calls `ubase_ctrlq_send_mue2ue_resp()` over the UBASE control queue.
- `udma_mue.c:262-280` registers TP-control request/response handlers: `GET_TP_LIST`, `ACTIVE_TP`, `DEACTIVE_TP`, `SET_TP_ATTR`, `GET_TP_ATTR`.
- `udma_main.c:1092-1098` wires these handlers in during device init.

**Channel character.** Inter-firmware (kernel ↔ on-device User Engine microcontroller), **not** inter-VM. The User Engine is a co-processor managing transport-path aggregation and topology — analogous to an HCA's management processor in IB.

**Correction to earlier docs.** The arch doc speculated "UE = User Entity?" or "Message Unit?" — the correct expansion is **User Engine**. Update the arch doc's open question.

---

## Q2. `udma_dfx` — telemetry surface

**Answer.** DFX exposes **query-only context introspection**, not persistent telemetry. No sysfs / debugfs / proc files; on-demand reads from HW mailboxes.

**Evidence.**

- `drivers/ub/urma/hw/udma/udma_dfx.h:50-57` declares `udma_query_jfr()`, `udma_query_jfs()`, `udma_query_jetty()`, `udma_query_res()`.
- `udma_dfx.c:81-127` shows `udma_query_jfr()` issues `UDMA_CMD_QUERY_JFR_CONTEXT` via mailbox; returns RX threshold (`limit_wl`), state, depth, SGE size, transport mode.
- `udma_dfx.c:13` defines a global `bool dfx_switch` parameter that gates DFX ops.

**What it is and isn't.**

- **Is**: live device-state inspection — read jetty / queue contexts off the chip.
- **Isn't**: counters, logs, fault injection, or sysfs/debugfs surfaces.

The "DFX" expansion is debatable — agent suggested **Diagnosis and FiXture**; the more common semiconductor-industry usage is **"Design For X"** (where X ∈ {testability, manufacturability, debuggability, …}). Either reading fits the inspection-only character of this module.

---

## Q3. `ipver=609` — semantics

**Answer.** **Cannot be fully resolved from source.** No `module_param` for `ipver` is defined inside the local kernel/`umdk` trees for the modules that take it.

**What is known.** UMDK README documents `ipver=609` as a required `insmod` parameter for `ummu`, `ubus`, and `udma`. Naming suggests an "IP version" / silicon revision selector.

**Why it's unfindable here.** The parameter likely lives in a HAL / bootloader / vendor module not present in the public openEuler kernel tree (e.g. inside the closed `hisi_ubus` vendor blob or a firmware-flashed HAL). **Definitive answer requires Huawei vendor docs.**

---

## Q4. OBMM cross-supernode cache coherence

**Answer.** OBMM uses HiSilicon SoC-cache hardware primitives via `hisi_soc_cache_maintain()`, plus ASID-broadcast TLB invalidation.

**Evidence.**

- `drivers/ub/obmm/Kconfig:5` selects `HISI_SOC_CACHE`.
- `drivers/ub/obmm/obmm_cache.c:60-66` maps OBMM ops to HW cache ops:

| OBMM op | HiSilicon SoC cache op |
|---|---|
| invalidate | `HISI_CACHE_MAINT_MAKEINVALID` |
| write-back only | `HISI_CACHE_MAINT_CLEANSHARED` |
| write-back + invalidate | `HISI_CACHE_MAINT_CLEANINVALID` |

- `obmm_cache.c:57-119` `flush_cache_by_pa()` — batches up to **1 GB per call** (`MAX_FLUSH_SIZE`); calls `hisi_soc_cache_maintain()` with the physical-address range; retries on `-EBUSY` (HW contention).
- `obmm_cache.c:121-159` `obmm_region_flush_range()` — dispatches to `flush_import_region()` or `flush_export_region()` based on ownership.
- `obmm_cache.c:162-171` `obmm_flush_tlb()` — broadcast TLB invalidate via ASID: `__tlbi(aside1is, asid)`.

**Coherence flow.** When a remote page is unmapped: import/export path → `obmm_region_flush_range()` with the right cache op → `hisi_soc_cache_maintain()` issues fabric-wide cache flush → `obmm_flush_tlb()` invalidates ASID. A semaphore serializes calls into the HW primitive to avoid contention.

This is a HW-enforced coherence: the SoC cache fabric carries invalidations; software just drives the maintenance op.

---

## Q5. UBMEMPFD virtualization — what does it look like?

**Answer.** UBMEMPFD is a **misc char device** providing IOMMU mappings for guest VM address spaces — the "vUMMU" backend that QEMU plugs into.

**Evidence.**

- `drivers/ub/ubmempfd/ubmempfd_main.c:29` registers `/dev/ubmempfd` as a misc device.
- `ubmempfd_main.c:303-349` implements a **`write()`-based command interface** (not `ioctl`). `write()` accepts a structured payload.
- `ubmempfd_main.c:339-349` decodes opcode field:

| Opcode | Meaning |
|---|---|
| `UBMEMPFD_OPCODE_MAP` | `ubmempfd_do_map()` |
| `UBMEMPFD_OPCODE_UNMAP` | unmap path |

- `ubmempfd_main.c:106-152` `ubmempfd_do_iommu_map()` — for each coalesced HPA range, calls `iommu_map()` to bind guest HVA → UB Address (UBA).
- `ubmempfd_main.c:222-259` allocates / caches a UMMU **TDEV** (Tagged Device) per context via `ummu_core_alloc_tdev()`.

**Request shape (paraphrased from struct definitions):**

```c
struct ubm_request {
    tid_t      tid;       /* translation ID */
    u32        opcode;    /* MAP | UNMAP */
    u64        uba;       /* UB address */
    struct ubm_area areas[];
    u32        size;
};
```

**vUMMU role.** UBMEMPFD acts as the host-side translation backend for a guest UMMU. When the guest updates its page tables, QEMU writes the new mapping to `/dev/ubmempfd`; UBMEMPFD programs the real UMMU/IOMMU so HW DMA from UBPUs can target guest memory.

---

## Q6. ubagg implementation status

**Answer.** **Working module, not a stub.** ~3,479 lines across 16 files. Replica-side bonding paths are stubs (handlers nullptr) but the primary-server functionality is fully wired.

**Evidence.**

- `drivers/ub/urma/ubagg/ubagg_main.c:1-158` — full module: cdev registration, class, module lifecycle.
- `drivers/ub/urma/ubagg/ubagg_ioctl.c` — 1,886 LOC (largest file in the dir), implements ioctl handlers.
- `ubagg_main.c:148` calls `ubagg_delete_topo_map()` and `ubagg_clear_dev_list()` on exit — confirms topology + device-list management is real.
- Supporting files: `ubagg_seg.c` (183 LOC), `ubagg_topo_info.c` (196), `ubagg_jetty.c` (129), `ubagg_hash_table.c` (102), `ubagg_bitmap.c` (116).

**Function.** UBAGG aggregates topology and device information across the fabric and exposes a `/dev/ubagg` char device for management queries. The `liburma`/UVS userspace side calls into UBAGG via ioctl.

**Correction to earlier docs.** The arch doc described `ubagg/` as "stub" based on first-pass file count; that was wrong. Replica/secondary-server paths are stubbed but primary functionality is implemented.

---

## Q7. Userspace UDMA provider registration — line-level confirmation

**Answer.** Confirmed: `__attribute__((constructor))` runs at `.so` load and calls `urma_register_provider_ops()`.

**Evidence.**

- `umdk/src/urma/hw/udma/udma_u_main.c:12-20` — constructor:

```c
__attribute__((constructor))
static void udma_init(void) {
    urma_register_provider_ops(&g_udma_provider_ops);
    /* ... */
}
```

- `umdk/src/urma/hw/udma/udma_u_ops.c:300-312` — top-level provider ops `g_udma_provider_ops`:
  - Transport type: `URMA_TRANSPORT_UB`
  - Lifecycle methods: `init`, `uninit`, `query_device`, `create_context`, `delete_context`
- `umdk/src/urma/hw/udma/udma_u_ops.c:32-113` — nested `g_udma_ops` vtable: 50+ operations (JFC/JFS/JFR/Jetty CRUD, TP control, event mgmt, work requests, …).

---

## Q8. UVS daemon — does one exist?

**Answer.** **No.** UVS is a library; there is no long-running daemon process anywhere in the umdk tree.

**Evidence.**

- `umdk/src/urma/lib/uvs/` is a CMake library directory; no `main()`.
- `umdk/src/urma/lib/uvs/core/tpsa_api.c:26-49` — `uvs_create_agg_dev()` / `uvs_delete_agg_dev()` are caller-driven API functions, not a daemon loop.
- No `int main()` in `lib/uvs/core/` or anywhere under `lib/uvs/`.
- No systemd unit files, no `/etc/init.d/` scripts, no `tpsad`-like binaries in the build output.

**Implication.** Topology / UBFM-equivalent functions happen via library calls from the application: the app links `libuvs`, calls UVS APIs, which translate to ioctl(`/dev/ubagg`) / ioctl(`/dev/ubcore`). There's no centralized fabric-manager daemon — that's a deliberate architectural choice.

**Naming note.** Agent expanded UVS as "User-space Virtual Switch", different from the earlier guess "Unified Vector Service". Neither is asserted in spec or repo headers; the abbreviation may be intentionally ambiguous. **Worth checking the spec / RELEASE-NOTES for the canonical expansion.**

**Correction to earlier docs.** The architecture doc had this listed as "Open question — is there a separate UVS daemon?"  — the answer is **no**, it's library-only.

---

## Q9. CAM Ascend kernel build pipeline

**Answer.** Custom CMake macro `add_kernels_compile()` orchestrates AscendC-toolchain compilation of real kernels.

**Evidence.**

- `umdk/src/cam/comm_operator/ascend_kernels/cmake_files/op_kernel/CMakeLists.txt:1-14` — invokes `add_kernels_compile()` (macro definition lives in a parent / global CMake file not present in the immediate dir).
- `umdk/src/cam/comm_operator/ascend_kernels/moe_dispatch_normal_a2/op_kernel/dispatch_normal_a2.cpp:10` — includes `kernel_operator.h` (AscendC).
- `dispatch_normal_a2.cpp:29` — `extern "C" __global__ __aicore__ ...` kernel signature: real Ascend NPU kernel code, not stubs.
- `dispatch_normal_a2.cpp:35-36` — `REGISTER_TILING_DEFAULT(...)` and `GET_TILING_DATA_WITH_STRUCT(...)` for parameterization.
- Header files (e.g. `cam_moe_distribute_dispatch_a2_layered.h`) carry kernel implementation, not stubs.

**Toolchain.** AscendC — Huawei's proprietary compiler for Ascend AI accelerators. Output is Ascend bytecode loaded into the OPP vendor directory at install time (per CAM README).

---

## Q10. dlock HA / replication

**Answer.** **Replica path declared but not implemented.** Single-server (primary-only) is the working mode.

**Evidence.**

- `umdk/src/ulock/dlock/lib/include/dlock_types.h:165-169` — `enum server_type { SERVER_PRIMARY, SERVER_REPLICA, SERVER_MAX }`.
- `umdk/src/ulock/dlock/lib/server/dlock_server.cpp:51-92` — control-message handler array contains entries for `REPLICA_INIT_REQUEST`, `REPLICA_INIT_RESPONSE`, `REPLICA_CTRL_CATCHUP_REQUEST` — all `nullptr`.
- `dlock_server.cpp:721-722` — runtime warning: "invalid peer type, replica server is not supported".
- `dlock_server.h:63` — `int init_as_primary()` exists; **no** `init_as_replica()`.

**Inferred design (not realized).** The catch-up protocol shape (`REPLICA_CTRL_CATCHUP_REQUEST/RESPONSE`, `REPLICA_ADD_*`) suggests a **primary-backup model with state sync** was planned. None of the methods are wired. Production deployments must treat the dlock server as a SPOF.

---

## Residual unknowns after this round

1. **`ipver=609`.** Defined externally — likely in a HAL or firmware blob outside the public openEuler tree.
2. **CAM CMake macro definition.** `add_kernels_compile()` body lives in a parent build file not in the immediate dir.
3. **OBMM multi-supernode topology programming.** Cache coherence (Q4) is for one supernode; how cross-supernode routing is set up isn't in the cache module — search elsewhere in `drivers/ub/obmm/` next time.
4. **UVS canonical expansion.** "User-space Virtual Switch" vs "Unified Vector Service" — neither asserted. Check `RELEASE-NOTES.md` and Chinese docs.
5. **UDMA UE message firmware path.** How the User Engine microcontroller signals back into the UDMA driver async — auxiliary-device event model is invoked but firmware plumbing is opaque from kernel source alone.
6. **Live-migration story.** `udma_mue.c` doesn't directly mention migration but `ubcore_vtp` (virtual TP) hints at it. Need a separate trace.

---

## Updates to apply to earlier docs

These are corrections / refinements that should land in companion docs:

### Architecture doc (`umdk_architecture_and_workflow.md`)

- §2.5 (UDMA file map): **`udma_mue` = MUE / User Engine messaging** — change "UE = User Entity?" to confirmed "User Engine".
- §3.2 (UVS): change "Open question: is there a separate UVS daemon?" to **"Confirmed: UVS is library-only; no daemon process exists in umdk/."**
- §6.5 (open questions): cross-strike #5 (UVS daemon — resolved); add this doc as the source.

### Spec doc (`umdk_spec_survey.md`)

- §11 (open questions): mark #5 (UBASE deep dive — partially answered; UVS library-only) and add new follow-ups (UVS naming).

### Comparison doc (`umdk_vs_ib_rdma_ethernet.md`)

- §1.4 (kernel labels): the "UVS = userspace lib" entry is correct — confirmed not a daemon. Note in §3.3 alongside other corrections.

### Cam/dlock/usock doc (`umdk_cam_dlock_usock.md`)

- §1.5 (CAM URMA integration): no change — agent's tracing was indirect.
- §2.5 (dlock failure handling): change "single point of truth" → **"single-server only — replica protocol declared but stubbed; not a working HA system"**. Cite `dlock_server.cpp:51-92, 721-722`.

---

_Companion: [`umdk_web_research_addenda.md`](umdk_web_research_addenda.md), [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md), [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md)._
