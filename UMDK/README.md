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

**Spec deep-dive + academic papers + web research + open-question follow-ups:**
- [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) — Targeted reads of the **Chinese UB Base Spec 2.0** chapters that the English preview only had ToCs for: §6 Transport (24-bit PSN + 8M-1 send window, four retransmit algorithms, exp-backoff RTO defaults), §7 Transaction (slicing, ROI/ROT/ROL/UNO modes with SC dynamic alloc, Atomic with 9 sub-types incl. CAS/swap/store/load/fetch_*), §10 Resource Mgmt (UBFM Sub-Domain split, **MUE = Management UB Entity** definitive, 128-bit EID = 108-bit Prefix + 20-bit Sub ID, UPI partition with 15/24-bit lengths, USI Type 1 vs Type 2 interrupts, full slice taxonomy), §11 Security (3-flow device auth, **token rotation per §11.4.4 with worked timeline**, CIP with AES-GCM/SM4-GCM, TEE extension UTEI/HTEI/UTM/HTM model + 2-bit EE_bits → 4 address spaces).
- [`umdk_academic_papers.md`](umdk_academic_papers.md) — Deep readings of the two peer-reviewed Huawei papers: **UB-Mesh** (nD-FullMesh topology, 2.04× cost-efficiency, 64+1 backup, All-Path-Routing, 86.7% passive-electrical cables, 95%+ training linearity to 64K NPUs) and **CloudMatrix384** (384 NPU + 192 CPU supernode, 196 GB/s & 1.2 µs measured, three-plane network, CANN/HCCL software stack, EP320 + FusedDispatch/Combine, prefill 6,688 tok/s/NPU on DeepSeek-R1). Includes the meta-finding that production AI workloads use HCCL/ACL (not URMA by name) — clarifies the two distinct usage paths into UB hardware.
- [`umdk_web_research_addenda.md`](umdk_web_research_addenda.md) — Lighter-weight web sources: Bojie Li's "The Thinking Behind Unified Bus" essay (design philosophy + tradeoffs), Huawei Connect 2025 announcements (Atlas 950/960 SuperPoD scale: 8K/15K NPUs, SuperCluster 500K/1M+), mainline-status check (URMA only in openEuler tree).
- [`umdk_code_followups.md`](umdk_code_followups.md) — Code-side answers to 10 open questions: `udma_mue` is **kernel ↔ User Engine** microcontroller control plane (not "User Entity"); UVS is **library-only, no daemon**; OBMM uses HW `hisi_soc_cache_maintain()` for cross-supernode coherence; UBMEMPFD is the **vUMMU backend QEMU plugs into**; ubagg is a working module; dlock replica is **declared but stubbed** (handlers nullptr); userspace UDMA registers via `__attribute__((constructor))` confirmed; `udma_dfx` is query-only inspection; `ipver=609` lives outside the public tree.

**Reference snapshot:**
- [`umdk_repo_layout.md`](umdk_repo_layout.md) — Initial repo layout note. Largely superseded by the architecture doc; kept as a quick-reference jump-table.

**Working backlog:**
- [`umdk_refinement_todos.md`](umdk_refinement_todos.md) — Consolidated TODO list of every open question, deferred read, gap, and verification step across all the other docs. Prioritized (P1/P2/P3), sized (S/M/L), and grouped into: quick wins, remaining Chinese-spec chapters to read, code-reading queue, cross-doc consistency sweeps, web-research follow-ups, new-doc proposals, and permanently out-of-scope items. **Pick from here when planning a refinement session.**

Still pending (next research batches):

- Remaining Chinese spec chapters — §5 Network Layer (NPI), §6.5/6.6 (multipath + congestion control / C-AQM), §8 Function Layer (URMA + URPC + Multi-Entity coord), §9 Memory Management (UMMU detail, UB Decoder), §10.5/10.6 (Virtualization, RAS), Appendix B (packet formats), Appendix D (config registers), Appendix G (hot-plug), Appendix H (URPC message format).
- DCA / HEM removal rationale from OLK-5.10 → 6.6.
- `ipver=609` definition (lives in HAL / firmware blob outside public tree — needs Huawei vendor docs).
- UVS canonical expansion (neither "User-space Virtual Switch" nor "Unified Vector Service" asserted in headers).
- OBMM multi-supernode topology programming (cache coherence is solved; cross-supernode routing path not yet traced).
- Live-migration story (`ubcore_vtp` hints at it; not traced).
- LWN / lore upstream activity on URMA (currently absent — track for first RFC submission).

## Style

- Short, citation-heavy (file:line) notes — these are reference material, not essays.
- English-first. Bilingual `_zh.md` copies can be added later when a doc stabilizes, following the pattern used in `../linux-memory-compression/`.
- Prefer `.md` while a finding is still evolving; promote to `.html` (`pandoc` or similar) once stable.
