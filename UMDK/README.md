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

- [`umdk_repo_layout.md`](umdk_repo_layout.md) — Repo layout survey: kernel `drivers/ub/urma/` vs userspace `src/`, URMA↔IB terminology map, UDMA provider, umdk sub-stacks (urpc / usock / ulock / cam).

More docs will be added as surveys of each sub-component complete. Pending topics:

- UDMA hot path (work queues, doorbells, CQ coalesce) — kernel `drivers/ub/urma/hw/udma/` + userspace `src/urma/hw/udma/udma_u_*`.
- UBASE auxiliary-bus framework (how UDMA binds).
- `src/urpc/` — RPC framework + `umq` (userspace message queue).
- `src/usock/ums/` — UB message socket.
- `src/ulock/dlock/` — distributed lock library.
- `src/cam/` — collective comm/math operators (Ascend kernels + pybind).
- uvs_admin / urma_admin / urma_perftest control-plane tools.

## Style

- Short, citation-heavy (file:line) notes — these are reference material, not essays.
- English-first. Bilingual `_zh.md` copies can be added later when a doc stabilizes, following the pattern used in `../linux-memory-compression/`.
- Prefer `.md` while a finding is still evolving; promote to `.html` (`pandoc` or similar) once stable.
