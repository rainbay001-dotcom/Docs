# UMDK — Unified Multi-Device Kit notes

Running notes and findings on openEuler's **UMDK** (userspace) and **URMA / UDMA** (kernel + userspace) stacks, the software layer of UnifiedBus (灵衢 / Ling Qu).

## Source trees (local clones)

| Role | Path | Remote | Branch |
|---|---|---|---|
| Kernel (OLK-6.6, primary) | `~/Documents/Repo/kernel/drivers/ub/urma/` | `gitcode.com/openeuler/kernel` | `OLK-6.6` |
| Kernel (OLK-5.10, historical) | `~/Documents/Repo/ub-stack/kernel-ub/drivers/ub/` | `github.com/openeuler-mirror/kernel` | `OLK-5.10` (sparse) |
| Userspace UMDK | `~/Documents/Repo/ub-stack/umdk/` | `github.com/openeuler-mirror/umdk` | `master` |

Canonical upstream lives on Huawei/openEuler forges; GitHub copies are auto-mirrors and usually fine to clone.

## Docs in this directory

**Concept / spec / comparison:**
- [`umdk_spec_survey.md`](umdk_spec_survey.md) — What the **UnifiedBus 2.0 Base Specification** and the UMDK project's own README/docs say about UMDK / URMA / UDMA / URPC. Glossary, six-layer protocol stack, transport/transaction modes, vocabulary discipline (UDMA is **not** a spec term), spec ↔ implementation mapping.
- [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md) — Terminology mapping (URMA ↔ IB verbs ↔ generic RDMA ↔ Ethernet) plus multi-axis comparison: spec / design / implementation / interface / ecosystem / performance / security perspectives. Where the analogies break and what URMA does that IB doesn't (and vice versa).

**Code architecture:**
- [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) — Code-side reference. The broader UB kernel ecosystem (UBUS / UBASE / UBFI / UMMU / OBMM / SENTRY / CDMA / UNIC alongside URMA), every URMA + UDMA subsystem with file:line cites, end-to-end workflows for device discovery, context open, memory registration, jetty lifecycle, post-send fast path, completion, teardown, control plane, multipath, ipourma, URPC, CAM.
- [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) — Deep dive into the kernel foundation drivers (UBUS, UBASE, UBFI, OBMM, UBMEMPFD, UBDEVSHM, UMMU) and the **UDMA hot path** (probe, WQE format, doorbell, post-send, poll vs event completion, error paths, MMU integration, OLK-5.10→6.6 evolution). Plus contrasts vs UNIC and CDMA.
- [`umdk_urpc_and_tools.md`](umdk_urpc_and_tools.md) — URPC framework (API, dispatch, wire format, marshalling, security), the three UMQ backends (`umq_ipc`, `umq_ub`, `umq_ubmm`) with their flow control + buffering, and the URMA control-plane CLIs (`urma_admin`, `urma_perftest`, `urma_ping`).
- [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md) — CAM (PyTorch operator library `umdk_cam_op_lib` for Ascend NPU collectives, MoE dispatch/combine), dlock (URMA-atomics-backed distributed locks with leases), and **USOCK / UMS** which takes over the upstream Linux `AF_SMC` socket family and substitutes URMA for SMC-R's RDMA backend.

**Reference snapshot:**
- [`umdk_repo_layout.md`](umdk_repo_layout.md) — Initial repo layout note. Largely superseded by the architecture doc; kept as a quick-reference jump-table.

Still pending (next research batches):

- Web research pass — Bojie Li "The Thinking Behind Unified Bus" essay, openEuler doc center, LWN / lore.kernel.org mentions, Huawei CloudMatrix whitepapers. Cite into the spec doc.
- Full Chinese spec read (UB-Base-Specification-2.0-zh.pdf) — fill in details deferred from the English preview (full §6 Transport, §7 Transaction, §10 Resource Management, §11 Security).
- UBFM ↔ UVS daemon mapping (where does the topology brain live?).
- DCA / HEM removal rationale from OLK-5.10 → 6.6.
- OBMM cross-supernode coherence implementation details.
- `udma_mue` and `udma_dfx` purpose.

## Style

- Short, citation-heavy (file:line) notes — these are reference material, not essays.
- English-first. Bilingual `_zh.md` copies can be added later when a doc stabilizes, following the pattern used in `../linux-memory-compression/`.
- Prefer `.md` while a finding is still evolving; promote to `.html` (`pandoc` or similar) once stable.
