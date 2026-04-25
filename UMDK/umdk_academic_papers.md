# Academic-paper findings — UB-Mesh + CloudMatrix384

_Last updated: 2026-04-25._

Deep readings of the two peer-reviewed Huawei papers that underpin the UB ecosystem in production. Both substantially extend what the spec preview and umdk source give us, with concrete numbers and an outside-the-spec architectural perspective.

> **Important meta-finding.** Neither paper uses the names **URMA / UDMA / UMDK**. They both call the protocol "UB" (UnifiedBus) generically and the API layer is described in terms of CANN / HCCL / ACL — Huawei's existing AI software stack. This means URMA / UDMA / UMDK are kernel- and userspace-level *implementation* labels (matching what we already concluded in [`umdk_spec_survey.md`](umdk_spec_survey.md)), and the higher-level workloads in production go through HCCL/ACL on top of CANN — which itself sits above the UB driver layer.

---

## 1. UB-Mesh — [arXiv:2503.20377](https://arxiv.org/abs/2503.20377)

**Authors:** all Huawei (March 2025 preprint).

### 1.1 Problem framing — why Clos fails AI

UB-Mesh names four requirements (§1):

| Req | Headline | Why prior arch fails |
|---|---|---|
| **R1 Scale** | 16K → 100K+ accelerators | Clos sym BW too expensive at this scale |
| **R2 BW** | >3.2 Tbps/node, ~10× CPU DC | Optical modules dominate cost |
| **R3 Cost** | 10–100× BW increase wrecks economics | — |
| **R4 Availability** | 100K-GPU cluster has ~1M optical modules → MTBF <30 min | Optics unreliable at scale |

The fundamental Clos critique: **TP + SP traffic = ~97% of training traffic and is local to 8–64 adjacent NPUs** (§2.2 Table 1). Clos pays for symmetric long-range bandwidth that this workload doesn't use. 3D Torus has too little per-node BW; DragonFly is still NPU-switch-heavy (§2.3).

### 1.2 nD-FullMesh topology

Recursive construction (§3.1):

- **1-D**: every NPU directly cabled to every peer in its tier (e.g. 8 NPUs per board).
- **2-D**: two 1-D meshes interconnected (e.g. 64 NPUs per rack as 8×8).
- **n-D**: extend by recursively connecting (n-1)-D meshes.

Cable mix breakdown (Table 2, §3.1):

| Cable | Distance | Share |
|---|---|---|
| Passive electrical | ~1 m intra-rack | **86.7%** |
| Active electrical | ~10 m inter-rack | ~7.2% |
| Optical | 100–1000 m | ~6% |

That cable economics is the single biggest cost win — passive electrical cables are ~10–100× cheaper than optical and dramatically more reliable.

### 1.3 UB-Mesh-Pod composition

- **Per rack:** 64 NPUs (8 boards × 8 NPUs) in 8×8 2-D full-mesh + **1 backup NPU**. Plus separate CPU boards (UB x32 IO each), 48 LRS (Low-Radix Switches @ UB x72 each), back-plane LRS units exporting four UB x256 outputs.
- **Per Pod:** 16 racks in a 4×4 2-D grid (4-D total: intra-rack 2-D + inter-rack 2-D). Each rack exports four UB x128 links.
- **Pod total:** **1,024 NPUs**.
- **SuperPod:** multiple Pods via Clos with HRS (High-Radix Switches @ UB x512). Scales to **8K NPUs**, then to **100K+** at the DC level (§3.3.4).

NPU IO is UB x72 (two controllers per NPU); CPUs are UB x32 (§3.2.1, Table 3).

### 1.4 All-Path-Routing (APR)

Three components:

1. **Source routing** (§4.1.1). 8-byte header with: 4-bit pointer + 12-bit bitmap (which hops use SR vs default) + up to 6 instruction fields encoding next-hop choices. Per-packet overhead minimal; routing decided at source.
2. **Structured addressing + linear table lookup** (§4.1.2). Address space partitions hierarchically by physical location; intra-segment routing is offset-from-base instead of full table lookup. Smaller tables, faster generation/distribution, faster failure recovery.
3. **TFC (Topology-aware Flow Control)** for deadlock freedom (§4.1.3). Channel Dependency Graphs decomposed into acyclic per-VL subgraphs via N-dimensional + same-dimensional loop-breaking. Result: **all-path routing using only 2 VLs** of HW resource — important because virtual lanes are expensive in switch silicon.

### 1.5 Failure handling

**64 + 1 backup NPU per rack** (§3.3.2). On NPU failure, the backup is activated; bad direct path "NPU-A → NPU-B" reroutes through an LRS as "NPU-A → LRS → backup". Adds one hop; alternative would be losing 1/64 of rack BW.

**Direct fault notification** (§4.2). Instead of hop-by-hop link-state propagation, the failed-link endpoint directly notifies all dependent nodes (pre-computed from routing). Cuts control-plane convergence latency.

**MTTR**: 75 min baseline → ~13 min with in-house monitoring (10 min detect + 3 min migrate).

### 1.6 Headline numbers

**Cost-efficiency** (§6.4, Fig. 21; methodology: in-house cost estimates):

- 1.18× CapEx vs 2D-FM+x16 Clos
- 1.65× vs x64T Clos
- 2.46× CapEx vs x64T Clos full-system
- **2.04× overall cost-efficiency vs baseline Clos** (with OpEx)
- Network infrastructure share of cost: 67% (Clos) → **20% (UB-Mesh)** via 98% fewer HRS + 93% fewer optical modules
- OpEx ~35% lower

**Availability** (§6.6, Table 6):

- Clos baseline (8K-NPU, 75-min MTTR): MTBF = 13.8 hr → **91.6%** availability
- UB-Mesh: MTBF = 98.5 hr → **98.8%** availability
- With monitoring: 99.78%
- Reason: AFR for electrical cables = 5.82 vs optical 13.8–574 vs switches 18–27

**Performance vs ideal Clos:** 6.4% average degradation intra-rack (§6.2); narrowed to 0.46% on GPT4-2T inter-rack with APR Detour+Borrow routing (§6.3 Fig 19).

**Linearity** (§6.5 Fig. 22, Eq. 2): ≥95% to 64K NPUs on Dense-1T and GPT4-2T; >100% in 1×–32× range (scaling unlocks better parallelism strategies).

### 1.7 Workload methodology

5 models tested (Table 5, §6.1): LLAMA-70B, GPT3-175B, Dense-1T, GPT4-2T (16-expert MoE), MoE-10T (32-expert). All five parallelism axes (TP/SP/PP/DP/EP). Sequence lengths 8K–10M tokens. Forward/backward/optimizer. **Training only, no inference.**

### 1.8 Seq-length sweep finding

Inter-rack BW required (§6.3 Fig. 20):

| Seq length | Optimal inter-rack BW | Gain x16→x32 |
|---|---|---|
| 8K–32K | UB x16 | +0.44% |
| 64K–10M | UB x32 | +1.85% |

Implies inter-rack BW provisioning should be tuned per-workload sequence length.

### 1.9 Limitations called out

1. Pod cap at 1K NPUs (4D-FullMesh); higher dimensions deferred for engineering simplicity.
2. ~7% perf gap vs ideal Clos remains.
3. Simulation-only evaluation — no production deployment numbers.
4. No discussion of debug/profiling tools for nD-FullMesh.
5. Limited treatment of congestion detection / adaptive routing beyond APR multipath.
6. No power/thermal analysis of UB controller replication.

### 1.10 Future directions named

- 5D-FullMesh and beyond as needs scale.
- Collective Communication Unit (CCU) co-processor in UB IO controller — could offload all-to-all (relevant for MoE).
- Multi-path hierarchical all-to-all for thousand-expert MoE models.
- Inter-Pod via UB switches *or* CPU NICs; DCN remains Clos.

---

## 2. CloudMatrix384 — [arXiv:2506.12708](https://arxiv.org/abs/2506.12708)

**Authors:** Huawei + SiliconFlow co-authors (June 2025). Corresponding authors include Zhou Yu and Heng Liao (Huawei) plus several SiliconFlow contributors.

### 2.1 Hardware composition

- **384 Ascend 910C NPUs** in 48 nodes (8 NPUs/node).
- **192 Kunpeng CPUs** (4 CPUs/node).
- **NPU memory: 49.2 TB** (128 GB/NPU × 384).
- CPU-attached DRAM ~768 GB total.

Each Ascend 910C is a **dual-die package**:

- ~376 TFLOPS BF16/FP16 per die → 752 TFLOPS per package
- 64 GB per die (8 stacks × 8 GB)
- 1.6 TB/s aggregate memory BW per die

The compute-to-memory ratio is tuned for inference (memory-BW bound, not compute-bound).

### 2.2 The UB plane — concrete bandwidth and latency

| Link type | Per-NPU BW | Latency (512 B) |
|---|---|---|
| **NPU↔NPU read** | **196 GB/s** unidirectional | **1.2 µs** |
| **NPU↔CPU access** | **~151 GB/s** | **1.0 µs** |
| Inter-node degradation | <3% BW loss | <1.6 µs added |

Topology (§3, Fig. 5):

- **L1 (on-board):** 7 UB switch chips per node, each mapping to an independent L2 sub-plane.
- **L2 (rack):** 4 communication racks, each with 7 sub-planes; each sub-plane has 16 L2 switches.
- **Non-blocking:** 448 GB/s uplink per node matches internal node BW — no oversubscription.

This is the all-to-all peer-to-peer fabric that makes EP320 feasible.

### 2.3 Three network planes per node

| Plane | Per-NPU / per-node | Purpose |
|---|---|---|
| **UB** | 196 GB/s NPU-NPU | Intra-supernode all-to-all |
| **RDMA (RoCE)** | 200 Gbps per NPU die / 3.2 Tbps per node aggregate | Inter-supernode scale-out |
| **VPC (Ethernet)** | 400 Gbps via Qingtian DPU | Mgmt, storage, external services |

So even within Huawei's stack, **UB is not the only fabric** — they retain RoCE for scale-out and Ethernet for management. UBoE could in principle bridge UB to RoCE; that's named as future work (§6.1.2).

### 2.4 Software stack — and where URMA isn't

The paper describes the stack from top to bottom (§Fig. 6 and §3.4):

```
ModelArts (AI Platform Services)
    Lite / Standard / Studio
─────────────────────────────────
MatrixContainer (k8s + topology-aware)
─────────────────────────────────
MatrixCompute (lifecycle orchestration)
─────────────────────────────────
MatrixLink (networking, QoS, routing)
MatrixResource (node provisioning, on Qingtian DPU)
─────────────────────────────────
CANN runtime
    ACL API + HCCL + Driver layer (UB fabric)
─────────────────────────────────
Ascend 910C HW + UB fabric
```

Crucially: applications go through **HCCL (Huawei Collective Communication Library)** for collective ops and **ACL (Ascend Computing Language) API** for compute. Both sit above CANN's "UB driver layer." The paper does **not name URMA, UDMA, ubcore, or uburma** at any layer — those are kernel-side implementation labels Huawei doesn't surface in this serving-stack description.

What this implies for our docs:

- Production AI workloads on Ascend SuperPoDs use HCCL on top of UB driver + CANN.
- URMA-direct programs (apps using `liburma` / `urpc` / `cam` from UMDK) are a *separate* application path — for OS-level / framework-developer use, not the typical PyTorch user.
- CAM (in UMDK) is a PyTorch operator library targeting these workloads from a different angle (`umdk_cam_op_lib` ops dispatched by the framework). The CloudMatrix paper's "FusedDispatch / FusedCombine" custom operators are the same conceptual species but via CANN's operator-package channel.

### 2.5 PDC disaggregation — Prefill / Decode / Caching

Architectural departure from KV-cache-centric serving (Dynamo, Mooncake):

| Pool | NPU alloc | Parallelism | Purpose |
|---|---|---|---|
| **Prefill** | 16 NPUs (32 dies) | EP32 | Process input prompts; first-token + initial KV |
| **Decode** | 160 NPUs (320 dies) | **EP320** | Autoregressive generation |
| **Caching** | CPU + DRAM pool via UB | Disaggregated | Context cache (prefix reuse) + model cache |

Why this works on UB: **uniform 151 GB/s remote-DRAM BW** means decode nodes don't need their KV cache local. The unified pool eliminates affinity constraints. Conventional clusters can't do this because remote access is 100×–10000× slower than local.

### 2.6 EP320 and the FusedDispatch / FusedCombine operators

DeepSeek-R1 has 256 router experts per layer; CloudMatrix-Infer deploys each on one die. EP320 = 256 distinct + 32 shared × 32 replicas.

Standard MoE flow needs 3 all-to-all rounds (routing metadata, token dispatch, expert output collection) with sync barriers and dynamic shapes. Replaced by **FusedDispatch + FusedCombine** which:

- Quantize tokens **BF16 → INT8 before** UB transmission (cuts message size).
- Use direct UB writes (no intermediate buffering).
- Pre-allocate memory (kills dynamic-shape overhead).
- Decouple dispatch / FFN compute / combine so they can pipeline.

**Bandwidth math:** ~1.8 MB per decode iteration per die (top-8 routing × ~7,200 dim × INT8 + metadata). At 196 GB/s → single iteration ~10 µs. Pipelined microbatches hide further latency.

### 2.7 MLA — Multi-Head Latent Attention

DeepSeek-R1 reduces KV cache size **93.3%** via MLA. CloudMatrix-Infer ships custom Ascend kernels using cube cores for matmuls + vector cores for element-wise + on-package fabric for cross-die sync.

### 2.8 Throughput

| Phase | Setting | Throughput | Compute eff. |
|---|---|---|---|
| Prefill | 4K prompt | **6,688 tokens/s/NPU** | 4.45 tok/s/TFLOPS (INT8) |
| Decode | 4K KV, <50 ms TPOT | **1,943 tokens/s/NPU** | 1.29 tok/s/TFLOPS |
| Decode strict (sub-15 ms TPOT) | smaller batches | 538 tokens/s/NPU | — |

Claimed superiority over SGLang on H100 (4.45 vs ?) and DeepSeek on H800 (1.29 vs ?), though direct H100/H800 numbers aren't reproduced in the visible excerpt.

INT8 quantization preserves accuracy "comparable to official DeepSeek-R1 API across 16 benchmarks" (no specific scores cited).

### 2.9 Reliability — notably absent

The paper does not have a dedicated reliability section. MatrixCompute is mentioned as the fault-recovery owner but no MTBF / fault injection / link-failure recovery details are given. **Gap worth flagging for follow-up** — CloudMatrix384 with 384 dual-die NPUs is a significant single-supernode failure domain.

### 2.10 Limitations called out

- VPC + RDMA as separate planes complicates inter-supernode scaling; UBoE bridging is future work.
- 384-NPU supernode boundary; multi-supernode federation deferred.
- CPU pooling not yet fully realized.
- Component-level disaggregation (model / KV / attention compute as separate pools) is future direction.
- Hybrid / adaptive deployment with live-workload rebalancing is named.

### 2.11 Coverage gaps

Single model (DeepSeek-R1, 671B MoE). Dense models (Llama-3, GPT-4 scale) and other MoE (Mixtral, Qwen-3) "assumed transferable but not validated". Multi-modal / reasoning models (o1) not discussed.

---

## 3. What these papers tell us about URMA / UDMA / UMDK

### 3.1 The naming gap

**Neither paper names URMA, UDMA, UMDK, ubcore, uburma.** They both refer to the protocol as "UB" and the runtime as CANN / HCCL / ACL. This is consistent with our [`umdk_spec_survey.md`](umdk_spec_survey.md) §8 finding — "UDMA" and "UMDK" are openEuler/HiSilicon implementation labels, not spec or research vocabulary.

### 3.2 Two distinct usage paths

Putting this together with what's in `umdk/`:

```
                   ┌─ Production AI workload (PyTorch + DeepSeek etc.)
                   │      ↓
                   │   ModelArts → CANN → HCCL / ACL → UB driver
                   │
HW (Ascend / UB) ──┤
                   │
                   └─ OS-level / framework-developer workload
                          ↓
                       liburma / urpc / cam / dlock
                          ↓
                       /dev/ub_uburma* (uburma) → ubcore → udma
```

The two paths share the same underlying UB hardware and (likely) the same kernel `drivers/ub/`, but call into it through different userspace stacks. CAM in UMDK is the bridge — it's a PyTorch op library that gives URMA/UB-aware kernels alongside CANN's own collective ops.

### 3.3 What the kernel-side ubcore + udma serve

- The OS-level UMDK stack via uburma (clearly).
- Probably also CANN's UB driver layer underneath HCCL — likely calls into ubcore for jetty / segment / atomic primitives. (Not directly verified, but the common kernel char dev `/dev/ub_uburma_*` would be the logical channel.)

### 3.4 Implication for our docs

The comparison doc and architecture doc should make explicit: **production AI workloads at Huawei don't use URMA's verbs API directly — they go through CANN/HCCL.** URMA is the API exposed for direct application use; UMDK is what people would use *outside* the CANN-HCCL ecosystem.

---

## 4. Concrete numbers consolidated

For quick-reference. Cross-cite into other docs as needed.

### 4.1 Bandwidth + latency

| Metric | Value | Source |
|---|---|---|
| NPU↔NPU read BW | 196 GB/s unidirectional | CloudMatrix384 §3 |
| NPU↔CPU access BW | 151 GB/s | CloudMatrix384 §3 |
| 512 B latency NPU↔NPU | 1.2 µs | CloudMatrix384 §3 Tab |
| 512 B latency NPU↔CPU | 1.0 µs | CloudMatrix384 §3 Tab |
| Inter-node penalty | <3% BW, <1.6 µs added | CloudMatrix384 §3 |
| RoCE per-die | 200 Gbps | CloudMatrix384 §3 |
| RoCE per-node aggregate | 3.2 Tbps | CloudMatrix384 §3 |
| Per-NPU UB IO width | UB x72 (two controllers) | UB-Mesh §3.2 Table 3 |
| Per-CPU UB IO width | UB x32 | UB-Mesh §3.2 Table 3 |

### 4.2 Scale

| Scale | NPUs | Source |
|---|---|---|
| UB-Mesh-Pod | 1,024 | UB-Mesh §3.3.3 |
| CloudMatrix384 supernode | 384 | CloudMatrix384 §3.1 |
| SuperPod (UB-Mesh) | 8,192 | UB-Mesh §3.3.4 |
| Atlas 950 SuperPoD (announced) | 8,192 | HC2025 announcement |
| Atlas 960 SuperPoD | 15,488 | HC2025 |
| Atlas 950 SuperCluster | 500K+ | HC2025 |
| Atlas 960 SuperCluster | 1M+ | HC2025 |

### 4.3 Cost / availability

| Metric | UB-Mesh | Clos baseline | Source |
|---|---|---|---|
| Cost-efficiency factor | **2.04×** Clos | 1.0× | UB-Mesh §6.4 |
| Network infrastructure share | 20% | 67% | UB-Mesh §6.4 |
| HRS reduction | 98% fewer | — | UB-Mesh §6.4 |
| Optical-module reduction | 93% fewer | — | UB-Mesh §6.4 |
| OpEx reduction | ~35% | — | UB-Mesh §6.4 |
| MTBF (8K-NPU) | 98.5 hr | 13.8 hr | UB-Mesh §6.6 |
| Availability | 98.8% (99.78% w/ monitoring) | 91.6% | UB-Mesh §6.6 |
| AFR (electrical cable) | 5.82 | — | UB-Mesh §6.6 |
| AFR (optical module) | 13.8–574 | — | UB-Mesh §6.6 |

### 4.4 LLM serving (DeepSeek-R1 on CloudMatrix384)

| Metric | Value |
|---|---|
| Prefill throughput | 6,688 tok/s/NPU |
| Decode throughput (<50 ms TPOT) | 1,943 tok/s/NPU |
| Decode strict (<15 ms TPOT) | 538 tok/s/NPU |
| Prefill compute eff (INT8) | 4.45 tok/s/TFLOPS |
| Decode compute eff (INT8) | 1.29 tok/s/TFLOPS |
| EP scale | EP320 (256 router + 32×32 replicas) |
| KV cache reduction (MLA) | 93.3% |
| FusedDispatch payload | ~1.8 MB / decode iteration / die |
| FusedDispatch latency | <10 µs single iteration @ 196 GB/s |

---

## 5. Cross-updates needed in other docs

- **Comparison doc (`umdk_vs_ib_rdma_ethernet.md`) §2.6 perf row:** add 196 GB/s NPU↔NPU + 1.2 µs latency + EP320 scale numbers. (Currently only has the 538 tok/s @ 15ms TPOT figure.)
- **Spec doc (`umdk_spec_survey.md`) §1.3 Web sources:** add UB-Mesh + CloudMatrix384 paper citations explicitly (cross-link this doc).
- **Architecture doc:** add the "two distinct usage paths" callout — production AI workloads use HCCL/CANN, OS-level workloads use liburma/UMDK.
- **CAM doc (`umdk_cam_dlock_usock.md`) §1.5:** mention the FusedDispatch/FusedCombine analogue in CloudMatrix-Infer (different channel, same architectural pattern).

---

## 6. Open follow-ups specifically prompted by these papers

1. **CCU (Collective Communication Unit) co-processor** in UB IO controller — UB-Mesh §Discussion mentions it as enhancement. Is this in current Ascend silicon? Visible from kernel side?
2. **CANN UB driver** — paper calls this layer out but doesn't open-source it from what we see. Where in the openEuler kernel does it live? Or is it CANN-side userspace?
3. **HCCL ↔ ubcore wiring** — does HCCL go through the same `/dev/ub_uburma_*` char dev as liburma? Or its own?
4. **MatrixLink networking layer** — proprietary or open? What's its relationship to UVS / ubagg?
5. **CloudMatrix384 reliability story** — paper omits this. Real-world failure rates and recovery patterns at 384 dies / 768 chips would be very informative.
6. **TFC algorithm reuse** — UB-Mesh's Topology-aware Flow Control (§4.1.3) is a generalizable graph-theory result. Is the same algorithm present in switch firmware / kernel?
7. **APR source-routing header on the wire** — UB-Mesh §4.1.1 specifies an 8-byte format. Where is this defined in the spec / kernel?

---

_Companion: [`umdk_web_research_addenda.md`](umdk_web_research_addenda.md) (lighter-weight sources), [`umdk_spec_survey.md`](umdk_spec_survey.md), [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md), [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md)._
