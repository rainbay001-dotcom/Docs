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

- [`umdk_spec_survey.md`](umdk_spec_survey.md) — What the **UnifiedBus 2.0 Base Specification** and the UMDK project's own README/docs say about UMDK / URMA / UDMA / URPC. Glossary, six-layer protocol stack, transport/transaction modes, vocabulary discipline (UDMA is **not** a spec term), spec ↔ implementation mapping. Anchored to the English preview spec at `~/Documents/docs/unifiedbus/UB-Base-Specification-2.0-preview-en.pdf`.
- [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) — Code-side reference. The broader UB kernel ecosystem (UBUS / UBASE / UBFI / UMMU / OBMM / SENTRY / CDMA / UNIC alongside URMA), every URMA + UDMA subsystem with file:line cites, end-to-end workflows for device discovery, context open, memory registration, jetty lifecycle, post-send fast path, completion, teardown, control plane, multipath, ipourma, URPC, CAM. Cross-component diagrams + open questions.
- [`umdk_repo_layout.md`](umdk_repo_layout.md) — Initial repo layout note (kernel `drivers/ub/urma/` vs userspace `src/`). Largely superseded by the architecture doc; kept as a quick-reference jump-table.

More docs will be added as deeper surveys of each sub-component complete. Pending topics:

- UDMA hot path (work queues, doorbells, CQ coalesce) — kernel `drivers/ub/urma/hw/udma/` + userspace `src/urma/hw/udma/udma_u_*`.
- UBASE / UBFI / UBUS internals — the foundational kernel layers UDMA binds through.
- `src/urpc/` — RPC framework + `umq` (userspace message queue) detailed walk.
- `src/usock/ums/` — UB message socket; in particular whether UMS adds a kernel module beyond uburma.
- `src/ulock/dlock/` — distributed lock library design.
- `src/cam/` — collective comm/math operators (Ascend kernels + pybind).
- uvs_admin / urma_admin / urma_perftest control-plane tools.
- Web research follow-up: Bojie Li essay, openEuler doc center, LWN/lore mentions; cite into the spec doc.

## Style

- Short, citation-heavy (file:line) notes — these are reference material, not essays.
- English-first. Bilingual `_zh.md` copies can be added later when a doc stabilizes, following the pattern used in `../linux-memory-compression/`.
- Prefer `.md` while a finding is still evolving; promote to `.html` (`pandoc` or similar) once stable.
