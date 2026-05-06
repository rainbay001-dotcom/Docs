# NCCL GIN — what it is, and how it compares to NVSHMEM

Date: 2026-05-06

NCCL 2.28.7 (late 2025) introduced a Device API including **GIN — GPU-Initiated Networking**, the NCCL-side counterpart to NVSHMEM/IBGDA. This note captures what GIN is, how it works, where it differs from NVSHMEM, and what the implications are for the Ascend / UB programming-model work that the rest of `accelerator-fabrics/` discusses.

Companion doc: `nvlink_nvshmem_coherence_notes.md` — covers NVLink coherence regimes, NVSHMEM internals, and the broader programming-model landscape this update fits into.

---

## 1. What GIN is

**GIN = GPU-Initiated Networking.** Introduced in NCCL 2.28.7. Reference: arXiv 2511.15076 ("GPU-Initiated Networking for NCCL") + NVIDIA Developer Blog "Fusing Communication and Compute with New Device API and Copy Engine Collectives in NVIDIA NCCL 2.28".

GIN is the inter-node piece of NCCL's new **Device API**, which has three pillars:

| API | Transport | Use case |
|---|---|---|
| **LSA** (Load/Store Accessible) | NVLink / PCIe peer mappings | Intranode device-initiated LD/ST |
| **Multimem** | NVLink SHARP | One-shot multi-destination collectives within an NVLink domain |
| **GIN** | RDMA over IB/RoCE | **Inter-node device-initiated** put/get/signal — the IBGDA equivalent |

Coverage matches NVSHMEM: peer-LD/ST inside the node, hardware-multicast over NVLink, and SM-posts-the-NIC across nodes. The novelty is that all three are now reachable from the existing NCCL communicator — no separate library to bootstrap.

## 2. How GIN works — three-layer stack

1. **Host-side setup**: register a device communicator + collective memory windows on top of an existing NCCL communicator. This is the analog of NVSHMEM's symmetric heap, but rooted in the NCCL comm so it inherits the topology / NIC / rail discovery NCCL already does.
2. **Device-side API**: callable from CUDA kernels.
   - Data movement: `put`, `putValue`, `signal`
   - Local completion: `flush`, `readCounter`, `waitCounter`, `resetCounter`
   - Remote completion: `readSignal`, `waitSignal`, `resetSignal`
   - Synchronization: `barrier`
3. **Network plugin** with two backend semantics:
   - **GDAKI** (GPU Direct Async Kernel-Initiated, via DOCA GPUNetIO): SM writes WQE into NIC-mapped memory and rings the doorbell directly. Mechanically identical to IBGDA — same PCIe-mapped doorbell trick, just owned by NCCL's plugin layer.
   - **Proxy backend**: SM writes commands to a lock-free FIFO; the existing `ncclProxy` thread on the host drains the FIFO and posts WQEs to the NIC. Slower than GDAKI but **runs on any RDMA NIC** — no ConnectX-7+ requirement.

The dual-backend design is the key contract. NVSHMEM also has IBGDA + proxy paths, but the proxy path was always a fallback rather than a first-class peer. NCCL GIN's proxy is co-equal — apps write the same code and the runtime picks the backend.

## 3. Side-by-side with NVSHMEM

### Origin and lineage

| | NVSHMEM | NCCL GIN |
|---|---|---|
| First release | ~2018 (OpenSHMEM-derived) | NCCL 2.28.7 (late 2025) |
| Standard basis | OpenSHMEM PGAS spec | None — NVIDIA-defined Device API |
| Status today (2026) | Mature, widely deployed | Recent, adoption ramping |

### Programming model

| | NVSHMEM | NCCL GIN |
|---|---|---|
| Memory abstraction | **Symmetric heap** — `nvshmem_malloc` returns matching offsets across PEs | **Collective memory windows** registered against an existing NCCL communicator |
| Identity | PE (Processing Element) | NCCL rank in a communicator |
| Allocation flow | Init NVSHMEM → `nvshmem_malloc` | Reuse existing NCCL comm → register window |
| Bootstrap cost | Separate library init (PMI/MPI-style or NCCL-bootstrapped) | Reuses comm setup the framework already did |

The biggest practical difference: **NVSHMEM is a standalone library that wants to own its world; NCCL GIN piggybacks on the NCCL comm every framework already has.** Much smaller integration footprint.

### API surface

| Operation class | NVSHMEM | NCCL GIN |
|---|---|---|
| Put/get | `nvshmem_put*`, `nvshmem_get*` | `put`, `putValue` (no `get` in initial release) |
| Signaling | `nvshmem_signal_op`, `signal_wait_until` | `signal`, `readSignal`, `waitSignal`, `resetSignal` |
| Counters | (via signals) | First-class `readCounter` / `waitCounter` / `resetCounter` |
| Atomics | **Rich** — CAS, swap, fetch_add/sub/and/or/xor, set, inc, store/load | **Limited** — counter primitives only |
| Barrier | `nvshmem_barrier`, `nvshmem_team_sync` | `barrier` |
| Collectives in API | broadcast / reduce / alltoall / fcollect / teams | Not in GIN — host-side NCCL collectives still separate |
| Quiet/fence | `nvshmem_quiet`, `nvshmem_fence` | `flush` |
| Memory ordering | SHMEM fence/quiet semantics | Counter/signal-based, NCCL-flavored |

NVSHMEM has the richer surface, especially for atomics. NCCL GIN is leaner — focused on the primitives needed to build collectives inside kernels rather than a full PGAS replacement.

### Backend / transport (mechanically very similar)

| Layer | NVSHMEM | NCCL GIN |
|---|---|---|
| Intranode peer | Peer-mapped LD/ST (P2P transport) | **LSA** — same mechanism, different name |
| Intranode multicast | (via collective ops) | **Multimem** (NVLink SHARP one-shot) |
| Intranode bulk | Copy Engine | LSA bulk path / CE |
| Inter-node device-initiated | **IBGDA** | **GDAKI** (DOCA GPUNetIO) |
| Inter-node proxy fallback | NVSHMEM-managed proxy thread | **Reuses existing `ncclProxy` thread** |

The mechanisms are essentially the same on the wire. GDAKI and IBGDA both have the SM construct a WQE in NIC-mapped memory and ring the doorbell. **The difference is who runs the proxy thread when GDAKI isn't available** — NVSHMEM ships its own; GIN reuses NCCL's.

### Hardware requirements

Effectively identical at the high-end:
- ConnectX-6 Dx minimum, CX-7/8 / BlueField-3 ideal.
- DOCA GPUNetIO for GIN's GDAKI; MLNX_OFED (NVSHMEM ≥ 2.6) for IBGDA.
- A100+ for IBGDA reliability; H100/Blackwell ideal.

Both fall back to proxy thread on older NICs. GIN's fallback is more cleanly engineered into the API contract.

### Integration footprint

| | NVSHMEM | NCCL GIN |
|---|---|---|
| Need to add to your build? | Yes — separate library + init | No — already linked via NCCL |
| Coexist with existing NCCL? | Yes, but two separate comm contexts to manage | Single communicator |
| Bootstrapping | NVSHMEM-specific or NVSHMEM-bootstrapped-from-NCCL | Inherits NCCL bootstrap |
| Topology awareness | Own discovery | **Reuses NCCL's** (NVLink graph, rail-aware NIC selection) |
| Used in framework today | DeepEP, FlashInfer, Megatron-Core, vLLM, SGLang | NCCL 2.28+ examples, early adopters |

Integration is the strongest argument for GIN. Every framework that uses NCCL gets GIN with a version bump. NVSHMEM has always been "yes but please add this other thing too."

### Maturity and ecosystem

| | NVSHMEM | NCCL GIN |
|---|---|---|
| Years in production | ~7 | <1 |
| Killer app | DeepEP (MoE EP) | None at scale yet |
| Triton bindings | Yes — `triton.distributed` lowers to NVSHMEM | Not yet |
| HPC adoption | QUDA, LAMMPS, NWChemEx, etc. | None — HPC stays on NVSHMEM/SHMEM |
| ML adoption | Strong (post-DeepEP) | Building |

This is the practical reason teams haven't migrated. **DeepEP is on NVSHMEM, vLLM/SGLang's MoE-EP paths are on NVSHMEM, Triton-distributed lowers to NVSHMEM.** GIN will earn its way in over time, but as of mid-2026 NVSHMEM is what's deployed.

## 4. Strategic positioning

| Axis | NVSHMEM | NCCL GIN |
|---|---|---|
| Designed for | HPC + adventurous ML teams | Mainstream ML frameworks |
| Standard compliance | OpenSHMEM-derived (somewhat) | None (NVIDIA-proprietary API shape) |
| Programming model | PGAS, full-fat | NCCL device primitives, focused |
| Migration cost from existing NCCL code | High (parallel stack) | Low (version bump + add device-API calls) |
| Migration cost from existing NVSHMEM code | Free (already there) | Rewrite |

GIN consolidates: NVIDIA gets to bring device-initiated primitives into the library every framework already uses, without forcing them to take a second dependency.

## 5. When to pick which

**Pick NVSHMEM if:**
- You're targeting MoE EP today and need DeepEP-class behavior — that's where the existing battle-tested kernels are.
- You need rich atomics (CAS, fetch_add, multi-element) on remote memory.
- You're writing Triton kernels — `triton.distributed` lowers there.
- You're an HPC code that already runs OpenSHMEM elsewhere.

**Pick NCCL GIN if:**
- You're starting fresh and want the smallest integration footprint into an existing NCCL-using framework.
- You need the Proxy fallback to work on commodity NICs — GIN's dual-backend contract is cleaner than NVSHMEM's.
- You're writing primitives that fuse compute + comm and want host-side comm (allreduce, allgather) and device-side ones in the same library.
- You expect to live for years and don't want to bet against NVIDIA's own consolidation.

**Pick both if** you're bridging — legacy NVSHMEM kernels (DeepEP) plus new GIN-based device-API code in the same training run. They can coexist; you just pay registration cost twice.

## 6. Implications for the Ascend / UB direction

Updates the "shmem-on-URMA" recommendation captured in `nvlink_nvshmem_coherence_notes.md` §13. Key shifts:

1. **The right architectural shape to port is NCCL Device API, not NVSHMEM.** The Device API trio (LSA + Multimem + GIN) is leaner, more focused on primitives needed for compute-comm fusion, and is where mainstream framework integration is converging post-2025.
2. **HCCL needs an analog.** Call it "HCCL Device API" — exposes:
   - Symmetric / collective memory windows registered on an HCCL communicator
   - Device-side `put` / `signal` / `counter` / `barrier`
   - Dual backend: GDAKI-style (AICore-direct, gated on A5/SIMT availability) + Proxy-style (AI-CPU-mediated, achievable today on UDMA)
3. **The Proxy backend is the achievable-today path.** UDMA's doorbell at `+0x80` plus a small AI-CPU FIFO drainer gives the equivalent of NCCL GIN's Proxy backend without any compute-side ISA changes. This is what should get prototyped first.
4. **Triton-Ascend binding** for this would slot in cleanly under `triton.distributed`'s lowering interface — and a future GIN-equivalent target on the upstream Triton side would naturally extend to it.
5. **Strategic conclusion unchanged**: bulk + atomic + signal verbs over UDMA is the substrate, no fabric coherence needed. What's changed is the *user-facing library shape* — from "shmem-on-URMA" to "device-API-on-HCCL/URMA."

## 7. Quick gotchas

- **NCCL 2.28.x is recent enough** that many production stacks haven't migrated. vLLM / TRT-LLM / DeepEP at the time of the GIN paper still pinned older NCCL. Adoption is the late-2025 / early-2026 story.
- **GIN ≠ free.** GDAKI requires DOCA GPUNetIO + ConnectX-7 / BlueField-3, just like IBGDA. Without that, you fall back to Proxy and lose ~half the latency benefit.
- **The Device API is C++ from kernels**, not Python. Triton bindings would need separate work, paralleling how NVSHMEM-on-Triton was bolted on.
- **No `get` in GIN's initial release.** Only `put`/`putValue`/`signal`. If your access pattern needs remote-pull semantics (rare in modern MoE patterns, but real in some RecSys flows), you're back on NVSHMEM until GIN catches up.

## Appendix: references

- arXiv 2511.15076 — "GPU-Initiated Networking for NCCL" (the architecture paper)
- NCCL 2.29.7 documentation — Device API + Device-Initiated Communication
- NVIDIA Developer Blog: "Fusing Communication and Compute with New Device API and Copy Engine Collectives in NVIDIA NCCL 2.28"
- NCCL examples: `examples/06_device_api/02_alltoall_gin` (the canonical "MoE-style alltoall in pure GIN" reference)
- DeepWiki: "GIN and RMA: Device-Initiated Networking" (NVIDIA/nccl documentation extract)
