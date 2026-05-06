# NVLink, NVSHMEM, Coherence — Architectural Notes for UB/Ascend Comparison

Date: 2026-04-29

Comparative analysis of NVIDIA's NVLink coherence regimes, the NVSHMEM/IBGDA stack, Triton-distributed, and what each implies for UB / Ascend / XiangShan architecture decisions. Distilled from a single discussion thread; treat as a living reference rather than a definitive spec.

---

## 1. The framing question

> "Ascend NPU is scratchpad architecture, no load/store instructions, so is there value to use the NVIDIA OpenSHMEM-related architecture?"

The premise needs a small correction: Ascend's *bulk dataflow* path (GM ↔ L1 ↔ L0A/L0B/L0C/UB) is MTE-orchestrated, but the AI-CPU + UMMU + URMA atomic verbs do support fine-grained remote ops at the *fabric* level. The gap is that the **AICore datapath** can't reach into them — only the scalar/AI-CPU side can. NVSHMEM's bet is that compute lanes themselves can poke remote memory; Ascend's bet (today) is bulk-DMA + collectives.

### NVSHMEM-style value decomposes into three layers

| Layer | What NVSHMEM provides | Maps to Ascend? |
|---|---|---|
| **A. PGAS programming model** (symmetric heap, `shmem_put/get`, teams, signal+wait) | Library API + compiler integration | Yes — clean port over URMA. HCCL is collective-only; SHMEM-on-URMA gives one-sided + signaling. |
| **B. Device-initiated communication** (kernel issues comm, no CPU bounce) | NVLink/NVSwitch + GPUDirect | **Partially.** UDMA/CDMA can be programmed device-side via doorbells; URMA atomic verbs (CAS/swap/store/load/fetch_*, 1–32 B naturally aligned) are spec'd. But initiation today is from AI-CPU/host, not from AICore. |
| **C. Per-thread fine-grained remote LD/ST** (a warp lane does `*p = x` on remote mem) | Native — every SM thread can fault on remote addr | **No** on 910C. **Maybe** on A5/351x (SIMT + DCache + RegFile finally appear), but UB-fabric reach from a warp lane isn't documented. |

### Concrete recommendation

A `shmem-on-URMA` prototype is the high-leverage target:
- Symmetric heap = `urma_target_seg_t` with matching offsets per PE.
- `shmem_put/get` = `urma_write/read`.
- `shmem_atomic_*` = URMA atomic verb (the 9 subtypes already cover SHMEM's atomic set).
- `shmem_signal_op` + `shmem_wait_until` = atomic store + spin-poll on a UB-mapped flag word.
- `shmem_quiet/fence` = URMA CQ drain + ownership transition.

This gives NVSHMEM portability, exercises URMA's atomic + ownership features (which currently have no application driving them), and slots cleanly into dual-socket XiangShan / NPU-FPGA-prototype work as a fabric-API target. Per-warp-lane remote ops are a separate question for A5+.

---

## 2. NVLink coherence — three distinct regimes

| Scope | Generation | What's coherent | App reality |
|---|---|---|---|
| **Pre-Hopper NVLink P2P** | V100/A100 | Peer LD/ST works; no HW coherence | Software-managed (memcpyPeer / NVSHMEM). Just a fast DMA fabric. |
| **NVLink-C2C** | Grace–Hopper (GH200), Grace–Blackwell (GB200/300) | CPU↔GPU at 900 GB/s; one address space, HW cache-line coherence between Grace and the GPU SMs | **Production users today.** Memory-capacity extension. |
| **NVL72 fabric** | Blackwell + NVSwitch Gen5 | 72 GPUs in *one coherence domain*; SM on GPU#0 can issue an LD that hits a line in GPU#71's HBM through NVSwitch | **Mostly an enabler, not a target.** Apps run NCCL/NVSHMEM; coherence is incidental. |

### Why coherence is bought

1. **Pointer-is-a-pointer programming.** No `cudaMemcpyAsync` choreography, no symmetric-heap registration. Productivity, not performance.
2. **Fine-grained, unpredictable access.** Bulk DMA / NVSHMEM put-get assumes you know what to move. Coherent LD/ST is the only viable model for pointer-chasing through embedding tables (RecSys, GNN), MoE expert lookup with data-dependent active set, attention reads spread across multiple GPUs in long-context inference, graph traversal, sparse algos.
3. **Heterogeneous memory tiering as HBM extension.** Grace's 480 GB LPDDR becomes coherent spillover. KV-cache offload, parameter offload, embedding tables — no explicit staging.
4. **Cheap fine-grained synchronization.** Lock acquire/release, producer-consumer flags, work-stealing queues. Coherence miss + snoop is ~500 ns–1 µs; PCIe DMA setup is many µs. C2C closes this gap further.
5. **Disaggregated prefill/decode + speculative decoding.** Both want fine-grained, low-latency cross-device state sharing — natural fit for coherence, awkward fit for bulk transfer queues.

### Costs of coherence

- **Directory + snoop filter silicon.** NVL72 needs ~72-way directory state — non-trivial die area and a hard scaling ceiling. This is why NVL72 stops at 72, not 720.
- **Latency floor on every access.** Even hits pay coherence-protocol overhead.
- **Snoop bandwidth.** Cross-fabric coherence traffic competes with payload; NVSwitch Gen5 budgets include the overhead.
- **Power.** Coherence engines + directory access on every line miss.
- **Software determinism is harder.** Implicit migrations and snoop stalls hurt latency-SLO inference.

---

## 3. NVSHMEM apps in 2025–2026

The list shifted dramatically in early 2025 — DeepSeek's DeepEP made NVSHMEM mainstream LLM infra essentially overnight.

### The mainstream driver: DeepEP (Feb 2025)

- **Workload**: MoE all-to-all dispatch/combine — every token routes to top-k experts that may live on any GPU. Highly irregular, latency-critical.
- **Why NVSHMEM**: GPU-initiated puts with per-token granularity, single-kernel comm (no host bounce), IBGDA inter-node so the NIC is poked from the SM. Bulk collectives (NCCL all-to-all) added too much latency.
- **Distribution**: ships a *patched* NVSHMEM with hot-path optimizations + permissive comm pattern unsupported upstream.

Pre-DeepEP NVSHMEM was DOE labs and a few NVIDIA demos; post-DeepEP, every serious MoE inference stack has an NVSHMEM path.

### LLM inference / serving

| Project | Use of NVSHMEM |
|---|---|
| **SGLang** | DeepEP backend integrated for MoE; experimental KV-cache transfer for disaggregated P/D. |
| **vLLM** | DeepEP integration landed in 2025; fast TP allreduce on Hopper+; KV-transfer for P/D split. |
| **TensorRT-LLM** | Custom-allreduce + MoE EP communication via NVSHMEM/IBGDA. |
| **Mooncake / Splitwise-style P/D disaggregation** | KV-cache transfer between prefill and decode pools. |
| **FlashInfer** | Multi-GPU paged-attention paths use NVSHMEM for remote KV-block fetch. |

### LLM training

| Project | Use |
|---|---|
| **Megatron-Core / NeMo** | NVSHMEM-backed compute-comm overlap (TP allreduce hidden behind GEMM); fine-grained pipeline send/recv. |
| **TransformerEngine** | NVSHMEM paths for context-parallel attention and certain fused-comm patterns. |
| **Megablocks / Tutel / FastMoE successors** | MoE training comm — increasingly all routing through DeepEP-derived patterns. |
| **NVIDIA Triton-distributed** (research) | NVSHMEM in Triton kernels for distributed GEMM / attention. |

### RecSys / graph (the original constituency for ML)

- **HugeCTR / Merlin** — embedding tables sharded across GPUs; NVSHMEM put/get for embedding lookup + gradient scatter. Long-running production user, predates the LLM wave.
- **cuGraph** — multi-GPU graph algorithms.
- **DGL / PyG multi-GPU** — some paths.

### Classic HPC

QUDA (lattice QCD, JLab/BNL) — heaviest non-NVIDIA NVSHMEM consumer historically; LAMMPS GPU-package multi-node; GROMACS specific paths; NWChem-Ex / NWChemEx; HPGMG, Comb, BabelStream benchmarks.

### Why the LLM crowd flipped to NVSHMEM in 2025

The pattern that DeepEP exposed and others copied:

1. **MoE = irregular fine-grained all-to-all** — bulk NCCL primitive is the wrong shape; want per-token puts.
2. **Disaggregated serving = fine-grained KV transfer** — same shape: small, latency-sensitive, source-initiated.
3. **Compute-comm overlap inside a single kernel** — only achievable with device-initiated comm; CPU-driven NCCL stalls the SM.
4. **IBGDA matured** — the SM-pokes-the-NIC path got production-stable on H100/H200, removing the last reason to go through host.

Every modern NVSHMEM use is either MoE-EP, P/D-disagg KV transfer, embedding-table lookup, or in-kernel comm-overlap. **All four are workloads UB-Mesh / CloudMatrix explicitly target**, and all four are exactly the access patterns that bulk-DMA / HCCL collectives serve poorly.

---

## 4. IBGDA — InfiniBand GPU Direct Async

The mechanism that lets a CUDA kernel post work to the NIC and ring its doorbell *from SM code*, with no CPU thread on the control path.

### Progression

| Stage | Year | Data path | Control path | Latency floor |
|---|---|---|---|---|
| **GPUDirect RDMA** | 2013 | NIC ↔ GPU memory direct | CPU posts WQE, CPU rings doorbell | ~10 µs (CPU proxy) |
| **GPUDirect Async (KI / SA)** | ~2017 | NIC ↔ GPU direct | CPU pre-stages WQE; GPU rings doorbell | ~5 µs |
| **IBGDA** | 2021/2022 (NVSHMEM 2.6+) | NIC ↔ GPU direct | **GPU writes the WQE *and* rings doorbell** | ~1–3 µs |

### How it works

1. **NIC mapped into GPU address space.** Send queue (WQ), completion queue (CQ), and doorbell register mapped via BAR1. PCIe peer-to-peer + ATS make this work without bounce buffers.
2. **SM constructs the WQE.** A CUDA thread writes a 64-byte work-queue entry — addresses, rkey, length, opcode — directly into the WQ slot.
3. **SM rings the doorbell.** A single store to the doorbell address. NIC's DMA engine picks it up and issues the RDMA transfer.
4. **SM polls the CQ.** Completion entry lands in the GPU-mapped CQ; kernel polls it and proceeds. No interrupt, no CPU wakeup.

### Hardware requirements

- **NIC**: ConnectX-6 Dx minimum; ConnectX-7/8 and BlueField-3 are production targets.
- **GPU**: GPUDirect RDMA support (A100 onward; H100/Blackwell with PCIe Gen5 + ATS sings).
- **Stack**: recent MLNX_OFED or DOCA, GDRCopy, NVSHMEM ≥2.6.

### Why IBGDA mattered for LLM infra

Pre-IBGDA NVSHMEM ran with a **CPU proxy thread** — every put/get woke a host thread. Two problems:

1. **Latency floor ~10 µs**, dominated by proxy thread wakeup + queue handoff. MoE expert dispatch can't pay 10 µs per hop.
2. **Persistent / single-kernel comm patterns are impossible** — if you need a CPU thread per outstanding op, you can't keep a megakernel alive issuing arbitrary remote puts from inside.

IBGDA collapses both. The MoE-EP pattern that DeepEP popularized — "kernel does dispatch + GEMM + combine without ever yielding to host" — is only viable because IBGDA exists.

### Practical gotchas

- **WQE BB size + queue depth** matter; if the kernel produces WQEs faster than the NIC drains, SM stalls.
- **Atomic op support** is stricter than puts — older ConnectX silicon doesn't accelerate all NVSHMEM atomics in IBGDA mode and falls back to proxy.
- **CQ polling burns SM cycles** — for low concurrency, a few warps spin on CQ, trading occupancy.
- **Multi-NIC steering** (NIC-per-rail in NVL72-class systems) requires explicit binding; NVSHMEM picks rail by PE topology.
- **DPDK/host-net interop** is awkward — IBGDA assumes the NIC's QPs are GPU-managed.

### Mapping to UB

UMDK already notes UDMA exposes a doorbell at offset 0x80 with 22-bit CI mask. That's the substrate for an IBGDA-equivalent on UB:

- AICore (or AI-CPU on A3) constructs a 64 B `cdma_jfs_wqebb` directly in a UB-mapped queue.
- Stores to the doorbell at `+0x80`.
- UDMA hardware picks it up, generates the URMA write/read/atomic on the fabric.

Pieces are present in spec and silicon. Missing: a NVSHMEM-on-IBGDA equivalent in UMDK.

---

## 5. What's actually under NVSHMEM

NVSHMEM is a PGAS *API* — what's on the wire splits into three mechanisms.

| Operation | Mechanism | Hardware actually moving the data |
|---|---|---|
| **Intranode small put/get/atomic** (≤ a few KB) | Peer-mapped LD/ST | **SM's LSU** issues the load/store; bytes traverse NVLink to peer GPU's HBM. No DMA engine. |
| **Intranode bulk put/get** (above threshold) | Copy Engine | **CE (Copy Engine)** — GPU's dedicated DMA processor. Frees SMs for compute. Threshold via `NVSHMEM_BULK_TRANSFER_SIZE`. |
| **Inter-node any size** | RDMA via NIC | **NIC's DMA engine** does the transfer; only question is who posted the WQE. Pre-IBGDA: CPU proxy. With IBGDA: SM. |

### Peer LD/ST onto NVLink

For intranode small messages:

1. Setup: each PE calls `cudaDeviceEnablePeerAccess`. Remote GPU's HBM pages mapped into local GPU's virtual address space via IOMMU/SMMU. Symmetric heap base on PE *j* reachable by PE *i* as a regular pointer.
2. Runtime: `nvshmem_int_p(addr, val, pe=j)` lowers to `ST.E.SYS` (store with system scope) to peer-mapped VA.
3. SM's LSU resolves PTE → page is in PE *j*'s HBM → store goes out NVLink port → arrives at peer's memory controller → lands in remote HBM.
4. `nvshmem_quiet` issues `membar.sys` and waits for outstanding stores to drain.

**Coherence is incidental.** On A100/PCIe-NVLink, peer access is not cache-coherent — peer LD/ST goes to remote HBM, but neither L2 is snooped. NVSHMEM compensates with `fence`/`quiet` model, which is *weaker* than coherence and just demands ordering + completion. On NVL72 the same NVSHMEM stores ride on a coherent fabric but the API and ordering model don't change. **NVSHMEM doesn't require coherence — it requires ordered remote writes plus a completion fence.**

### Atomics

| Path | Where the atomic executes |
|---|---|
| Intranode peer | **NVLink fabric atomic** — remote MC (or NVSwitch on Hopper+) does CAS/fetch-add. Not in SM. |
| Inter-node IB | **NIC-side atomic** — IB atomic verb at remote NIC. Limited set (CAS + fetch-add at 8 B). |

### Inter-node bulk put chain

`nvshmem_putmem(remote, local, n, pe)` to remote-node PE:

1. SM (with IBGDA) constructs WQE in NIC-mapped queue, writes doorbell.
2. Local NIC DMA reads `n` bytes from local GPU HBM via PCIe + GPUDirect RDMA.
3. Bytes on the wire (IB or RoCE).
4. Remote NIC DMAs into remote GPU HBM via GPUDirect RDMA on receive side.
5. CQE lands; SM polls completion.

### Implication for UB

- **Intranode peer-LD/ST path is hardest to replicate on Ascend** — AICore can't issue fine-grained remote LD/ST, no PTE-mapped peer access from compute datapath. Needs A5/SIMT to land cleanly.
- **CE bulk path maps perfectly to UDMA / CDMA.** UDMA descriptors + doorbell at +0x80 = direct equivalent of CE-driven NVSHMEM bulk put. Implementable today.
- **IBGDA path maps to AI-CPU (or eventually AICore) writing UDMA WQEs directly.** UMDK already exposes `cdma_jfs_wqebb` and the doorbell — substrate is there; missing piece is the NVSHMEM-shaped library.
- **No coherence requirement.** NVSHMEM only needs ordered writes + fence. UB's ownership model (Inv/Write/Read with explicit transitions) is sufficient — no need to introduce cache-line coherence to host SHMEM-style API.

~80% of NVSHMEM's actual mechanism (CE bulk + NIC DMA) is achievable on UB today through UDMA + URMA verbs. ~20% that's hard (peer-mapped fine-grained LD/ST from compute lanes) is exactly the SIMT capability gap A5/351x is designed to close.

---

## 6. Apps actually using NVLink coherent semantics

Far fewer than marketing implies, and almost none use it the way the marketing pitches it ("write multi-GPU code as if it's one GPU"). Real value captured in two narrow patterns.

### Two coherence regimes, two app sets

| Regime | What's coherent | App reality |
|---|---|---|
| **NVLink-C2C (Grace–Hopper, Grace–Blackwell)** | CPU LPDDR ↔ GPU HBM | Production users today. Memory-capacity extension, not multi-CPU/GPU programming model. |
| **NVL72 multi-GPU coherence** | GPU HBM ↔ GPU HBM across 72 sockets | Mostly enabler, not target. Apps still use NCCL/NVSHMEM; coherence is incidental. Native coherence-targeting code is rare. |

### NVLink-C2C apps that lean on coherence

Pattern: **Grace LPDDR as HBM tier**, no explicit copies because fabric handles it.

- **LLM inference with CPU-offload of KV-cache or weights**
  - vLLM / SGLang / TensorRT-LLM CPU-offload paths
  - DeepSpeed ZeRO-Inference
  - HuggingFace `accelerate` device_map
  - Stock x86+H100 → PCIe heavily; GH200 → coherent C2C makes offload nearly free at 900 GB/s. Single biggest production use today.
- **RecSys / embedding-table workloads**: NVIDIA Merlin / HugeCTR; TorchRec on GH200.
- **Graph analytics**: cuGraph; NetworkX-cuGraph backend.
- **Vector search / RAG**: FAISS on GH200, RAPIDS cuVS, Milvus; NeMo Retriever pipelines.
- **DataFrame-scale analytics**: RAPIDS cuDF, Spark RAPIDS; HEAVY.AI / kinetica-style GPU databases.
- **Genomics / scientific**: NVIDIA Parabricks; NVIDIA Modulus.
- **Historical precedent**: ORNL Summit (Power9 + Volta, NVLink 2.0 coherent) — NWChemEx, LSMS, COMET, GTC. First HPC apps written *for* CPU-GPU coherence.

Common thread: working set bigger than HBM, irregular access pattern. **Capacity-bound + irregular = coherence wins.**

### NVL72 multi-GPU coherence — the more interesting story

Despite marketing, very few apps written specifically for NVL72 coherence. Reasons:

- **Inertia.** All large-scale code already targets NCCL or NVSHMEM. Those run faster on NVL72 (lower latency, no proxy threads) but don't require coherent semantics.
- **Portability.** NVL72-coherent code doesn't run on H100-NVL8, A100-DGX, or anything else.
- **Compiler maturity.** Single-address-space multi-GPU programming needs a compiler. NVIDIA's pitch (cuTile / Triton-distributed) is research-grade.

Concrete uses:
- **NVIDIA's "single GPU" inference pitch** for Llama-3.1-405B, GPT-4-class, DeepSeek-V3 — TRT-LLM has NVL72-aware paths using coherent loads to fetch shards from peer HBM rather than NCCL allgather. Not all teams adopted yet.
- **Megatron-Core / NeMo** — very-wide TP (>8-way) starts to use NVL72 coherence for allreduce shortcut when MNNVL detected. Mostly opportunistic.
- **vLLM / SGLang multi-GPU paged-attention** — recent work uses peer-HBM coherent reads for cross-GPU KV-block fetch instead of NVSHMEM put. Emerging in 2025.
- **Disaggregated prefill/decode** — Mooncake and Splitwise-style separations *could* use NVL72 coherence within a pool; in practice most use NVSHMEM for portability.
- **Research / compilers** — Triton-distributed, cuTile-distributed, Modular MAX, JAX/Pallas distributed primitives. Code actually written *for* NVL72 coherence.

### Notably absent from NVL72-coherent app list

- DeepEP / MoE EP — explicitly chose NVSHMEM/IBGDA, not coherence. Coherent-LD-from-SM at MoE granularity has too much directory pressure.
- NCCL — collective patterns are bulk; coherence overhead doesn't pay.
- Most training frameworks — bulk-DMA dominates training comm.

### The pattern

| | Source of value | Maturity |
|---|---|---|
| **Proven** (C2C) | Capacity extension — CPU memory becomes coherent HBM tier | Production. Every GH200 deployment uses this. |
| **Promised** (NVL72) | Single-address-space multi-GPU programming | Mostly aspirational. Apps run NCCL/NVSHMEM faster on it without targeting coherence directly. |

---

## 7. Triton-distributed — what it actually is

ByteDance Seed project (open-sourced 2025) extending OpenAI's Triton compiler with a *distributed language* layer — `triton.distributed.language` (`dl`). Single Python source defines compute *and* communication; compiler lowers both into one GPU kernel.

### DSL surface

```python
import triton.language as tl
import triton.distributed.language as dl

# 1. Symmetric heap — PGAS allocation, identical offsets across PEs
buf = dl.symm_alloc(shape, dtype)

# 2. Remote tile access — peer puts/gets at tile granularity
dl.consumer_tile(remote_buf, peer_rank, ...)
dl.producer_tile(local_buf, peer_rank, ...)

# 3. Signal/wait — fine-grained sync between producer and consumer
dl.notify(flag, tag, peer_rank)
dl.wait(flag, tag)
```

### What's under the DSL

This is the precision-correction. Triton-distributed lowers to:

| DSL construct | Compiled to |
|---|---|
| `symm_alloc` | NVSHMEM symmetric heap allocation |
| `consumer_tile` / `producer_tile` | `nvshmemx_*_put_block` / `nvshmem_*_get_block` device calls |
| `notify` / `wait` | `nvshmem_signal_op` / `nvshmem_signal_wait_until` |
| Atomics | `nvshmem_atomic_*` |

These are **NVSHMEM device functions**, riding on **IBGDA for inter-node and peer-mapped LD/ST or CE for intranode** — exactly the path described in §5. There is no coherent-load-from-peer-HBM lowering. NVL72 coherence is incidental; the compiler doesn't target it.

So Triton-distributed is **"DeepEP-class capability in a DSL"**, not a single-image coherent-fabric language. It belongs in the NVSHMEM column.

### Why it matters

1. **First open-source DSL fusing compute + one-sided comm.** DeepEP is hand-written CUDA/C++; Triton-distributed reaches comparable performance in ~100 lines of Python.
2. **Generalizes beyond MoE.** AllReduce-fused-GEMM, AllGather-fused-GEMM, ReduceScatter-fused-GEMM, attention-with-KV-fetch, P/D KV-transfer kernels.
3. **Performance claims are real.** ByteDance reports matching/beating DeepEP on MoE dispatch/combine and beating NCCL on AllReduce/AllGather/ReduceScatter on H800.
4. **Backend pluggable in principle.** IR is comm-primitive-agnostic; alternate backend emitting RCCL-like or URMA device calls is plausible without rewriting frontend.

### Limitations

- Triton compiler maturity ceiling: complex tile shapes / irregular indexing hit codegen issues.
- Officially NVIDIA-only (NVSHMEM dependence). AMD ROCm + RCCL backend in-flight late 2025.
- No coherent-fabric path — NVL72-targeting wouldn't be the vehicle without backend work.
- Depends on IBGDA stack (NIC, driver, NVSHMEM ≥2.6).

### Implication for Ascend

Right stack ordering for "DeepEP on Ascend":

1. **SHMEM-on-URMA** — NVSHMEM analogue over URMA verbs (UMDK gap today). Substrate exists; library doesn't.
2. **Device-initiated URMA via UDMA doorbell** — IBGDA analogue. Spec'd, untapped from compute side.
3. **Triton-Ascend backend emitting SHMEM-on-URMA calls** — port the `triton.distributed` lowering passes once Triton-Ascend exists. Cleanest path to MoE-EP-class capability without writing a DeepEP-equivalent in hand-coded AscendC.

Open-source community already built the abstraction layer (Triton-distributed) that decouples "what comm pattern" from "what fabric primitives execute it." Mapping onto UB needs the bottom two layers — neither requires coherent NVLink semantics.

---

## 8. Heterogeneous GPU + LPU systems — coherence requirements

(Note: "LPU" isn't an NVIDIA term as of Jan 2026 — Groq's branding, increasingly generic for inference-specialized accelerators. GTC 2026 not yet held at time of writing.)

### Five plausible role splits, five coherence answers

| Role split | Hot shared state | Comm pattern | Coherence needed? |
|---|---|---|---|
| **GPU does prefill, LPU does decode** (disaggregated serving) | KV-cache, transferred once per request | Bulk per-layer transfer | **No.** Bulk DMA + signaling. What Mooncake/Splitwise do today. |
| **GPU runs general compute, LPU runs attention only** | KV-cache hot during decode | Per-step block reads | **Marginal.** Pre-staged blocks with sync work; coherence helps if block table changes mid-step. |
| **GPU + LPU share long-context KV across both** | KV blocks accessed by data-dependent block table | Fine-grained, unpredictable | **Yes — capacity-extension flavor.** GH200-style coherent shared memory pool pays off. |
| **LPU is dataflow/scratchpad (Groq-style)** | None — LPU's whole point is no shared memory | Streaming I/O at boundaries | **No.** Coherence inside LPU meaningless; coherent staging *into* LPU's input buffers is bulk DMA. |
| **GPU + LPU share weights for very large model** | Weight tiles, read-only after load | Read-mostly, predictable | **No.** Read-only sharing doesn't benefit from coherence. |

### Bottleneck patterns realistic GPU + inference-accelerator systems hit

1. **KV-cache movement between domains** — bulk, predictable, large. DMA wins.
2. **Token-level handoff** — sync-heavy, latency-sensitive. **Signaling primitives** matter; coherence does not.
3. **Routing decisions for MoE / speculative decoding across heterogeneous engines** — fine-grained, data-dependent. Only pattern where cache-line coherence between domains has clear value, niche.
4. **Spillover working set** — capacity extension. **Coherent CPU↔accelerator link** (C2C-style) is the right answer; multi-accelerator coherence isn't.

**C2C-flavored coherence (CPU-memory-as-tier) is high-leverage for hybrid systems; multi-accelerator cache-line coherence is low-leverage relative to cost.**

### Why I'd bet against fully coherent GPU+LPU fabric

1. **Specialized inference accelerators usually win on dataflow / scratchpad architecture** (Groq TSP, Tenstorrent, Cerebras, SambaNova RDU, Ascend AICore). Cache-line coherence with such an accelerator is semantically awkward — no caches in conventional sense.
2. **Coherence directory cost grows quickly with PE count and PE heterogeneity.** Two PE classes with different cache-line sizes / consistency models is harder than monolithic NVL72.
3. **Actual workloads driving GPU+LPU systems are inference-shaped** — none *require* coherence; they require fast bulk transport + cheap signaling.

---

## 9. Why coherent CPU memory pool specifically

Four independent reasons, each sufficient alone.

### 1. CPU memory hosts the *irregular metadata*, not just bulk data

Modern inference engines are CPU-orchestrated. Hot data structures the accelerator needs to consult at fine granularity all live in CPU memory:

| Structure | Owner | Access from accelerator |
|---|---|---|
| **Block table** (paged attention KV mapping) | vLLM/SGLang scheduler on CPU | Per attention step, per sequence — irregular small-table reads |
| **Expert routing table** (MoE) | CPU control plane | Per token in dispatch |
| **Sequence state** (active seqs, gen positions, finish flags) | CPU scheduler | Per decode step |
| **Page tables / address translation** | OS on CPU | On every miss when SVM/UVM in use |
| **Speculative decoding draft state** | Draft side | Per verification round |
| **Graph adjacency / RecSys embedding indices** | CPU-managed | Pointer-chasing |

Small, scattered, latency-sensitive, **change continuously while accelerator runs**. Bulk DMA can't serve them — by the time you've staged the table, it's been updated. UVM page migration is too coarse. Only fit: "accelerator does coherent load against live CPU data structure at ~hundreds-of-ns latency." Exactly what NVLink-C2C provides.

### 2. CPU memory is the only realistic *capacity tier*

| Tier | Cost / GB (rough, late-2025) | Capacity per socket |
|---|---|---|
| HBM3e | ~$15–25 | 80–192 GB |
| LPDDR5X (Grace-attached) | ~$3–5 | 480 GB |
| DDR5 (host) | ~$3 | 1–2 TB |
| NVMe | ~$0.10 | 100s of TB |

If model + KV cache + activations exceed HBM, the next tier is CPU memory. Peer accelerator HBM doesn't help — same expensive tier. NVMe is different latency class (10s of µs). "Spill out of HBM" structurally means "spill into CPU memory."

Choice is whether spill is **explicit (DMA + sync, requires predicting access pattern)** or **implicit (coherent LD on demand)**. For irregular workloads (long context, MoE with cold experts, RecSys, graph), only implicit delivers usable performance.

### 3. Latency math flips at ~hundreds of bytes

| Mechanism | Setup + transfer cost for 64 B |
|---|---|
| CPU↔GPU PCIe Gen5 DMA | ~3–5 µs (descriptor + completion) |
| CPU↔GPU NVLink-C2C coherent load | ~200–400 ns |
| CPU↔CPU coherent load (cross-socket NUMA) | ~150–250 ns |
| Local L2 hit | ~30 ns |

For multi-MB transfers, DMA wins by amortization. For 64 B – 4 KB accesses, **coherent load beats DMA by 10×–20×**. CPU-produced metadata (block tables, routing tables, sequence state) all sit in this size range. Below ~1 KB, no DMA mechanism competes with coherent LD.

### 4. CPU is already coherent — extending it is incremental

Every CPU socket has a multi-core cache-coherent fabric (MESI/MOESI). Adding the accelerator as another participant in *that* fabric requires:
- Snoop traffic to/from the accelerator's port
- A coherence agent on the accelerator side that satisfies snoops on its own caches/buffers
- Address translation alignment (ATS/SMMU)

Directory state is bounded by CPU's existing coherence domain (typically already sized for ~100s of cores). Not building an N×N coherence fabric from scratch — attaching one accelerator to CPU's existing one.

Compare to multi-accelerator coherence (NVL72): build fresh 72-way directory with snoop filter sized to cross-product. Order-of-magnitude harder.

### Why the asymmetry: peer-accelerator data has none of these properties

| Property | CPU-side data | Peer-accelerator data |
|---|---|---|
| Producer | CPU control plane, irregular timing | Accelerator kernel, scheduled |
| Shape | Pointer-chasing structures | Tiles / tensors with known shapes |
| Size distribution | Bytes to KB hot path | KB to MB |
| Predictability | Data-dependent (which sequence, which expert) | Statically scheduled by framework |
| Update frequency | Continuous, asynchronous | Per-step, synchronized |
| Capacity rationale | Cheap LPDDR/DDR is the only big tier | Peer HBM is same expensive tier as local HBM |

Every row in right column is one where coherence doesn't pay. Bulk size + known shape + scheduled access = pattern bulk DMA + signaling handles optimally.

### One-line summary

**Coherent CPU memory pool turns LPDDR/DDR into a real HBM-extension tier for irregular fine-grained accesses.** Without it, CPU memory is reachable only by predictable bulk DMA, which fails on the workloads (long-context attention with offloaded KV, MoE with cold-expert spill, RecSys, graph) that need a capacity tier in the first place. Multi-accelerator coherence has no equivalent structural reason — peer HBM isn't the capacity tier and accelerator-produced data isn't the irregular-metadata workload.

GH200 / Grace-Blackwell is the most strategically important coherence direction even if it gets less marketing than NVL72: it solves a real bottleneck. NVL72 mostly speeds up things NCCL/NVSHMEM already handle.

---

## 10. NVLink-C2C bidirectional coherence detail

Yes — full bidirectional cache-line coherence. CPU writing a line invalidates GPU's cached copy, and vice versa. Two precise points to lock in:

1. **Bidirectional, but GPU-side direction is what matters.** NVLink-C2C makes CPU memory coherently loadable/storable from GPU SMs, *and* GPU HBM coherently accessible from CPU cores. In practice GPU-reads-CPU-memory is doing all the work; CPU rarely needs fine-grained reads of HBM.

2. **HW cache-line coherence, not just shared addressing.** Two distinct things often conflated:
   - **Unified addressing** (pointer is a pointer): had this since CUDA UVM in 2014, software-managed via page migration, works over PCIe.
   - **HW coherence** (snoop fabric extends across the C2C link): when CPU writes a cache line, any cached copy on the GPU side is invalidated by hardware; vice versa. New with C2C, makes coherent LD actually fast.

| | UVM over PCIe (x86 + H100) | NVLink-C2C (GH200 / GB200) |
|---|---|---|
| Same virtual address | Yes | Yes |
| Bandwidth | ~64 GB/s | 900 GB/s |
| Mechanism on miss | Page migration (~µs to ms) | Coherent cache-line fill (~hundreds of ns) |
| HW snoop between CPU and GPU caches | No | Yes |
| Useful for fine-grained metadata reads | No (migration cost dominates) | Yes |

### Mechanism

| Scenario | What happens |
|---|---|
| GPU L2 has line X cached, CPU writes X | C2C snoop reaches GPU L2 → line X invalidated; next GPU read fetches new value |
| CPU L3 has line X cached, GPU writes X | C2C snoop reaches Grace cache hierarchy → line X invalidated; next CPU read fetches new value |
| Both sides cache X read-only, then one writes | First write triggers invalidation on other side; standard MESI-style transition |

Coherent fabric doesn't care whether line's *home* is in HBM or LPDDR — it tracks **wherever the line is currently cached** and snoops accordingly. Line homed in GPU HBM but currently cached in Grace's L3 is fully coherent: when GPU writes, Grace's cache gets invalidated.

### Where the asymmetry actually lives

Capability is symmetric. Usage isn't:

- **GPU caching CPU memory** is the common case. SMs frequently fetch from LPDDR-home lines and cache in L2 — point of the link (block tables, scheduler state, KV-cache spillover).
- **CPU caching GPU HBM** is rare. Grace cores can cache HBM-home lines, but typical workloads don't have CPU reading HBM at fine granularity. HBM exists *for* GPU.

"CPU writes invalidate GPU's cached HBM line" path exists and works, but exercised mostly for control-plane: CPU thread writing doorbell or status word GPU is polling, where the word happens to live in HBM. More commonly producer-consumer flag lives in CPU memory and GPU is the polling side.

### Two important caveats

1. **Cache-line size mismatch.** ARM Neoverse V2 (Grace) is 64 B; Hopper L2 tracks 128 B. C2C fabric handles this, but false-sharing patterns that "work" on coherent x86 multi-socket can behave differently when CPU and GPU touch adjacent data in the same 128 B GPU line. Same correctness, different performance.

2. **GPU memory ordering must opt into system scope.** Plain CUDA load (`LD.E`) is weakly ordered, doesn't necessarily participate in full system-coherent ordering. To get cross-domain coherent behavior reliably:
   - PTX: `ld.relaxed.sys`, `ld.acquire.sys`, `red.sys`, `atom.sys`
   - C++: `cuda::atomic_ref<T, cuda::thread_scope_system>` or `cuda::memory_order_*` with `cuda::thread_scope_system`
   
   Without `.sys` scope, you can have correctly-coherent fabric and still see stale reads because GPU's memory model didn't ask for global view.

---

## 11. GPU memory ordering hierarchy

GPU memory model is **weakly ordered everywhere** — C++ memory model with explicit scopes, not x86 TSO. Ordering comes from atomics-with-scope and explicit fences; everything else can be reordered.

### The scope ladder

| Scope | PTX qualifier | C++ name | HW coherence boundary | Cost of fence |
|---|---|---|---|---|
| Thread | (none) | `thread_scope_thread` | Single lane | Free |
| CTA / block | `.cta` | `thread_scope_block` | One SM | ~10s of cycles |
| Cluster (Hopper+) | `.cluster` | `thread_scope_cluster` | One GPC (≤16 SMs) | ~100s of cycles |
| Device / GPU | `.gpu` | `thread_scope_device` | One GPU's L2 | ~100s–1000s of cycles |
| System | `.sys` | `thread_scope_system` | All CPUs + all coherent GPUs | µs-class on PCIe; ~hundreds of ns on C2C/NVL72 |

Invariant: **atomic / fence with scope X provides ordering only among threads within scope X.** Wider scope = wider snoop = more cost. Picking right scope is performance-critical.

### Inside an SM (within CTA / between warps)

- L1 + shared memory are SM-private; no coherence with other SMs.
- Within warp (32 lanes): post-Volta Independent Thread Scheduling — lanes *not* implicitly synchronized. Need `__syncwarp()` for cross-lane ordering.
- Within CTA (across warps): communicate via shared memory. `__syncthreads()` is canonical CTA-wide release-acquire fence. CTA-scope atomics (`atom.cta.*`) coherent across warps in same CTA, very low latency (shared-mem HW atomic units).
- Shared memory: software-managed scratchpad, not cached.

### Between SMs (within one GPU)

Most often misunderstood level.

- **L1 is incoherent across SMs.** SM 0 reads line X, caches in L1. SM 1 writes line X. SM 0's L1 may keep returning stale value.
- **L2 is GPU-wide coherence point.** All SMs see consistent state in L2. Inter-SM communication must traverse L2.
- **Two ways to get inter-SM ordering**:
  1. **Bypass L1 on loads**: PTX `.cg` cache hint (`ld.global.cg`) goes straight to L2. Stores to global mem are write-back; pairing with `.cg` loads gives coherent producer-consumer channel through L2.
  2. **GPU-scope atomic / fence**: `atom.gpu.*` or `membar.gl` (`__threadfence()` in CUDA C++) flushes L1 dirty data and orders against L2.
- **Hopper+ cluster-scope coherence (DSMEM).** Up to 16 CTAs in a cluster (one GPC) can directly access each other's shared memory via SM-to-SM network, bypassing L2. `.cluster` scope atomics + `cluster.sync()` are primitives. Faster than going through L2 but limited to one cluster.

So inside a GPU:
- Within block → shared memory + `__syncthreads()` (L1/SMEM scope)
- Within cluster (Hopper+) → DSMEM + `cluster.sync()` (SM-to-SM, sub-L2)
- Between blocks across GPU → global memory through L2 with `.cg` or `__threadfence()` (L2 scope)

### Between GPUs in a node

Fabric type completely changes the model.

#### Pre-Hopper / non-coherent NVLink P2P (V100, A100, H100 legacy)

- Peer-mapped LD/ST works but **not cache-coherent**. Peer LD reads remote HBM but **bypasses** remote L2; peer ST goes to remote HBM but doesn't snoop remote SMs' L1/L2.
- Local GPU's L1/L2 may cache peer-mapped lines, **but those caches never invalidated by remote writes**. `.ca` reads from peer pointers dangerous unless using `.cv` (volatile) or `.cg` modes.
- **System fence** (`membar.sys` / `__threadfence_system()`) drains outstanding peer writes but doesn't provide coherence — only ordering between issued ops.
- Why NVSHMEM uses `fence`/`quiet` semantics: fabric can't deliver stronger guarantees.

#### Coherent NVLink (NVL72, Blackwell + NVSwitch Gen5)

- **Multi-GPU snoop fabric**. SM-issued LD/ST against peer-HBM-home lines participates in cache-line coherence: peer writes invalidate local L2 copies; vice versa.
- `.sys` scope atomics work natively across 72-GPU domain.
- Memory model extends `thread_scope_system` across fabric. Same C++ atomics code that works CPU↔GPU on GH200 works GPU↔GPU on NVL72.
- Mechanism: snoop messages traverse NVSwitch with own QoS class; bandwidth budget split between data and snoop traffic.

#### Across nodes (IB / RoCE)

- **No HW coherence**, ever. Communication is software-managed RDMA.
- "Memory model" at this scope is SHMEM model: explicit `put`/`get` + `fence`/`quiet`. Not part of C++ memory model — compiler doesn't know about it.

### Between GPU and CPU

| Link | Coherence? | Memory model |
|---|---|---|
| PCIe (no UVM) | No | Bulk DMA only; software-managed |
| PCIe + UVM | Page-level migration | Pseudo-coherent at page granularity, ~µs–ms migration cost |
| **NVLink-C2C (GH200/GB200)** | **HW cache-line coherent** | C++ `thread_scope_system` works at full speed; `.sys` PTX atomics are real |

C2C is only regime where CPU↔GPU follows **same formal memory model** as inter-thread on a single CPU.

### Master picture

```
weakly ordered everywhere
   │
   ├─ within thread:    program order (compiler-respected with volatile/atomic)
   ├─ within warp:      __syncwarp() — explicit, post-Volta ITS
   ├─ within CTA:       __syncthreads() + shared mem + .cta atomics
   ├─ within cluster:   cluster.sync() + DSMEM + .cluster atomics      [Hopper+]
   ├─ within GPU:       L2 + .cg loads or .gpu atomics or __threadfence()
   ├─ across GPUs:
   │     ├─ legacy NVLink P2P:  fence/quiet model, no coherence
   │     └─ NVL72 coherent:    .sys atomics, HW snoop
   ├─ CPU↔GPU:
   │     ├─ PCIe:              UVM page migration or explicit memcpy
   │     └─ NVLink-C2C:        full HW coherence, .sys atomics native
   └─ across nodes:     SHMEM fence/quiet, RDMA-level
```

### Three things that bite people in practice

1. **Default loads cache in L1 → silently incoherent across SMs.** Code that "works" because L1 misses may break under contention. Use `.cg` or `volatile` for inter-SM communication.
2. **Picking wrong scope = silent stale reads.** `.cta` atomic between two CTAs gives no guarantees; `.gpu` atomic between CPU and GPU gives no guarantees. Compiler doesn't catch.
3. **Fence cost scales with scope** — by orders of magnitude. `__threadfence_system()` over PCIe is microseconds; on GH200 is hundreds of ns; `__threadfence_block()` is essentially free.

---

## 12. Coherence domains — GPU vs CPU explicit-domain models

GPU **does not** have explicit coherence domains the way CPUs do. Deliberate architectural choice.

### How CPU encodes a coherence domain

ARM and x86 both make coherence domain a **property of the memory mapping**:

- **ARM**: each PTE carries **shareability attributes** — Non-shareable / Inner Shareable / Outer Shareable. HW fabric (CMN/CCI) routes snoops based on this. Page marked Inner Shareable snooped only inside cluster; Outer Shareable extends across sockets.
- **x86**: shareability implicit in MTRR/PAT memory types but domain itself HW-defined per-socket via snoop directory; page table picks cacheable/UC/WC, not domain.
- **ARM CHI / x86 UPI** maintain explicit per-line directory state tracking which domain has line cached.

Two characteristics:
1. **Coherence is property of memory.** Page is in a domain or not; every access follows that domain's protocol.
2. **HW maintains directory state per line per domain.** Coherence cost scales with domain size.

### How GPU does it instead

GPU pushes choice from **memory** to **operation itself**:

- **No shareability attribute on GPU page tables.** GPU PTE encodes cacheability and target (local HBM / peer / system) but no analog of ARM's shareability bits.
- **Coherence boundary is implicit in HW structure**:

| HW boundary | What's coherent inside | What makes it work |
|---|---|---|
| One SM | Shared memory + L1 | Single physical bank, no distribution |
| One GPC / cluster (Hopper+) | DSMEM + L1 within cluster | Direct SM-to-SM crossbar, no caching |
| One GPU | L2 | **L2 is a single physical structure** — only one copy |
| NVL72 fabric | All 72 GPUs | NVSwitch + per-GPU CCM extends coherence agent into fabric |
| NVLink-C2C | GPU + CPU | GPU plugs into Grace's CMN-700 domain |

- **Software picks which boundary applies per-operation** via PTX scope tag (`.cta`, `.cluster`, `.gpu`, `.sys`). Same memory location can be accessed at different scopes by different ops; nothing about the memory commits it to one boundary.

Answer: **boundaries exist as HW facts, but no software-visible domain identity, no per-mapping attribute, no explicit directory state at most levels.**

### Why GPU got away with this

Clever part: GPU memory system avoids needing distributed cache coherence inside the device.

1. **L1 caches per-SM and explicitly *not* coherent.** No inter-L1 snoop fabric. No "L1 coherence domain" to track — HW guarantees nothing across L1s.
2. **L2 is single shared structure.** Coherence at L2 level automatic because only one copy of line in cache; no directory to track who has it. "GPU-scope coherence" is cheap structurally — not really a coherence protocol, just shared L2 access.
3. **Cluster DSMEM is direct point-to-point**, not cached. No coherence protocol needed because no caches to be inconsistent.

Combination — incoherent L1 + monolithic L2 + uncached DSMEM — means GPU **does not run MOESI/MESI internally**. No need for explicit domains because no distributed directory to organize.

CPU can't do this because CPU L2/L3 are physically distributed (per-core or per-cluster), so multiple cached copies of every line exist, requiring explicit protocol + directory + domain attributes.

### Where GPU does grow domain-like state

Two places NVIDIA *does* introduce explicit coherence-domain state:

1. **NVL72 fabric.** Each GPU has **CCM (Coherent Cache Manager)** participating in system-wide directory living in NVSwitch. Real distributed coherence protocol — multi-GPU lines have explicit directory entries tracking which GPU's L2 has the line. Still HW-only state; **no software-visible domain identity**, no PTE attribute, no API to query "which domain is this page in." Fabric topology defines the domain.
2. **NVLink-C2C.** GPU plugs into Grace's existing CMN-700 mesh as coherent participant. From Grace's perspective, GPU is one more agent in inner-shareability domain; from GPU's perspective, CPU is "system scope." Asymmetric: ARM-side software sees domain via PTE shareability bits; GPU-side software sees only `.sys` scope.

Outer levels: explicit domain emerges in HW, but never exposed to software the way CPUs expose it. GPU programming model deliberately keeps `.cta` / `.cluster` / `.gpu` / `.sys` scope tag as the only abstraction.

### Side-by-side

| | CPU | GPU |
|---|---|---|
| Domain identity exposed to software | Yes (PTE shareability, NUMA domain ID, sometimes cache partition ID) | **No** at any level |
| Domain bound to memory mapping | Yes (per-page) | No |
| Domain bound to operation | No (mapping decides) | **Yes (scope tag decides)** |
| Distributed directory inside device | Yes (per-line state across L2/L3) | **No, until NVL72** |
| Software queryable "what domain is this in" | Yes | No |
| HW pays directory cost regardless of access pattern | Yes | **No — pays only at scopes you use** |

---

## 13. Synthesis — implications for UB / Ascend / XiangShan

### Three architectural points on the coherence spectrum

| Architecture | Coherence model | Granularity | Software exposure |
|---|---|---|---|
| **CPU (ARM CHI / x86 UPI)** | Per-line directory at every level | Cache line | Per-mapping (PTE) |
| **GPU** | Scope-tagged ops, monolithic L2 inside device, NVSwitch directory at NVL72 boundary | Cache line at boundary, none inside | Per-operation (scope tag) |
| **UB ownership model** | Per-segment ownership (Inv/Write/Read), atomic verbs | Segment (thousands of bytes), token-rotation | Per-segment (TokenID) |

UB sits at a **third design point** that's neither CPU nor GPU: explicit domain at segment granularity, no fine-grained coherence inside a segment from the fabric's perspective. Deliberate choice — explicit enough to support RDMA atomics and shared memory, coarse enough to scale to SuperPoD without per-line directory cost.

### Recommendation prioritization

If picking where to invest coherence on the Ascend side:

1. **C2C-style coherent CPU↔NPU link (GH200 / NVLink-C2C analogue)** — high-leverage. Today CANN apps explicitly stage between AI-CPU memory and HBM through MTE/DMA. Coherent CPU↔HBM link (Kunpeng↔Ascend) directly enables KV-offload / RecSys / large-graph patterns driving GH200 adoption. UB Base Spec ch.9 (UMMU/UB Decoder) describes addressing substrate. Probably highest-ROI coherence direction.

2. **SHMEM-on-URMA library** — high-leverage. Substrate exists in URMA verbs + UDMA doorbell; UMDK has the gap. Enables MoE-EP-class workloads (DeepEP analogue) without committing to coherence.

3. **Device-initiated URMA via UDMA doorbell (IBGDA analogue)** — prerequisite for #2. Spec'd, untapped from compute side.

4. **Triton-Ascend backend emitting SHMEM-on-URMA calls** — once Triton-Ascend exists. Cleanest path to compiler-driven MoE-EP without hand-coding AscendC.

5. **NVL72-style multi-NPU coherent fabric** — low-leverage at this scale. UB's ownership model already covers what production apps actually use. Multi-NPU coherence would mostly serve workloads that today just use NVSHMEM/HCCL, and even on NVIDIA's side those workloads aren't actually written *for* coherence — they're written for fabric primitives that exist regardless.

### XiangShan two-socket via XSBridge

Live design tension. Today bridge is bulk-CHI forwarding with no remote-present bit in OpenLLC's directory. Roadmap step "remote-present bit + snoop forwarding" is exactly the moment of commitment to NVLink-style cross-socket coherence vs UB-style ownership. For two sockets it's tractable (directory state is one bit per line); cost story changes radically generalized further.

XSBridge two-socket scaffold is implicitly choosing CPU-style for 2 sockets (right answer at that scale) but won't extend cleanly past ~8 sockets without picking up either GPU's structural tricks or UB's segment-level coarsening.

### NPU-FPGA-prototype

If targeting SIMT semantics on a future variant, must commit to GPU-style L1-incoherent / L2-coherent model — pick what `.cg`-equivalent and `__threadfence()`-equivalent look like in the ISA. Cluster/DSMEM tier is optional but where Hopper got most of its inter-SM perf gains.

---

## Appendix: glossary

- **C2C**: Chip-to-Chip (NVLink-C2C, the coherent CPU-GPU link in Grace-Hopper / Grace-Blackwell)
- **CCM**: Coherent Cache Manager (NVIDIA's coherence agent on GPU, participates in NVSwitch directory at NVL72)
- **CE**: Copy Engine (GPU's dedicated DMA processor, distinct from SMs)
- **CTA**: Cooperative Thread Array (CUDA block; runs on one SM)
- **DSMEM**: Distributed Shared Memory (Hopper+ feature; cluster-scope direct SM-to-SM access to peer SM's shared memory)
- **GPC**: Graphics Processing Cluster (group of SMs sharing a cluster network, ~16 SMs on Hopper)
- **IBGDA**: InfiniBand GPU Direct Async (kernel-initiated NIC programming, NVSHMEM ≥2.6)
- **PGAS**: Partitioned Global Address Space (programming model: SHMEM, NVSHMEM, UPC, Coarray Fortran)
- **TMA**: Tensor Memory Accelerator (Hopper+ HW for async tile copies between global and shared memory)
- **URMA**: Unified Remote Memory Access (UB's RDMA-class verbs API; IB-verbs rebranded with new primitives)
- **UDMA**: HiSilicon DMA engine providing URMA hardware backing (kernel module under ubcore)
- **UMDK**: Unified Memory Development Kit (openEuler userspace toolkit: URMA, CAM, URPC, ULOCK, USOCK)
