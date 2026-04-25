# UMDK / URMA / UDMA — web research addenda

_Last updated: 2026-04-25._

Web sources collected to fill in context the local PDFs and source code don't cover: design philosophy from a UMDK author, concrete product specs and scale numbers from Huawei announcements, peer-reviewed benchmarks, and mainline-kernel status. Cite into the rest of the UMDK/ doc set.

> **Quote discipline.** Verbatim passages are kept under 15 words. Where I paraphrase a source, the paraphrase is meant to be substantively faithful but is not a substitute for reading the original.

---

## 1. Source inventory

### 1.1 Primary author / design philosophy

| URL | Author / venue | Date | One-line value |
|---|---|---|---|
| [`01.me/en/2025/09/a-story-of-unified-bus/`](https://01.me/en/2025/09/a-story-of-unified-bus/) | Bojie Li (李博杰) | 2025-09 | "The Thinking Behind Unified Bus" — design philosophy essay |
| [`01.me/en/2023/09/towards-compute-native-networking/`](https://01.me/en/2023/09/towards-compute-native-networking/) | Bojie Li (Kun Tan keynote) | 2023-09 | APNet'21 keynote summary — early UB framing |

### 1.2 Huawei official announcements (HUAWEI CONNECT 2025, 2025-09-18)

| URL | Topic |
|---|---|
| [`huawei.com/en/news/2025/9/hc-lingqu-ai-superpod`](https://www.huawei.com/en/news/2025/9/hc-lingqu-ai-superpod) | "Lingqu" / UnifiedBus 2.0 SuperPoDs and SuperClusters launch |
| [`huawei.com/en/news/2025/9/hc-superpod-innovation`](https://www.huawei.com/en/news/2025/9/hc-superpod-innovation) | Open-access SuperPoD architecture commitment |
| [`huawei.com/en/news/2025/9/hc-xu-keynote-speech`](https://www.huawei.com/en/news/2025/9/hc-xu-keynote-speech) | Eric Xu keynote on SuperPoD interconnect |

### 1.3 Academic / peer-reviewed

| URL | Paper | Notes |
|---|---|---|
| [`arxiv.org/abs/2503.20377`](https://arxiv.org/abs/2503.20377) | UB-Mesh — hierarchically-localized nD-FullMesh DC network architecture | March 2025 preprint; uses UB primitives |
| [`arxiv.org/abs/2506.12708`](https://arxiv.org/abs/2506.12708) | "Serving Large Language Models on Huawei CloudMatrix384" | June 2025; concrete LLM-serving numbers |

### 1.4 Kernel-mailing-list traces

| URL | What |
|---|---|
| [`lore.kernel.org/all/aac718c5-880e-4763-8b31-12b66f4bb3cb@stanley.mountain/T/`](https://lore.kernel.org/all/aac718c5-880e-4763-8b31-12b66f4bb3cb@stanley.mountain/T/) | smatch static-analysis warning on `ubcore_copy_to_user()` in OLK-5.10 — confirms URMA / ubcore is reviewed only inside openEuler's tree, not posted to LKML for upstream merge |
| [`mailweb.openeuler.org/hyperkitty/list/kernel@openeuler.org/`](https://mailweb.openeuler.org/hyperkitty/list/kernel@openeuler.org/latest) | openEuler internal kernel list — primary forum for URMA / ubcore review |

### 1.5 Community discussion / press

| URL | Source | Note |
|---|---|---|
| [`siliconflash.com/exploring-huaweis-unifiedbus-architecture-...`](https://siliconflash.com/exploring-huaweis-unifiedbus-architecture-revolutionizing-cloud-ai-infrastructure/) | Silicon Flash | Press summary of UB 2.0 |
| [`cloudcomputing-news.net/news/cloud-ai-infrastructure-huawei-unifiedbus-superpod/`](https://www.cloudcomputing-news.net/news/cloud-ai-infrastructure-huawei-unifiedbus-superpod/) | Cloud Computing News | UB AI infra coverage |
| [`crnasia.com/news/2025/artificial-intelligence/huawei-s-open-source-gambit-...`](https://www.crnasia.com/news/2025/artificial-intelligence/huawei-s-open-source-gambit-chinese-tech-giant-makes-superpo) | CRN Asia | Open-source angle on the announcement |
| [`forrester.com/blogs/huawei-connect-2025-building-ai-infrastructure-in-a-sanctioned-world/`](https://www.forrester.com/blogs/huawei-connect-2025-building-ai-infrastructure-in-a-sanctioned-world/) | Forrester | Industry analyst take |

LWN.net does not appear to have UB-specific coverage as of this writing (search did not surface dedicated articles); will revisit if a discussion post or article appears.

---

## 2. Bojie Li's "The Thinking Behind Unified Bus" — design philosophy

Bojie Li (李博杰) is one of the URMA / UMDK authors (see `umdk/RELEASE-NOTES.md` and source-file copyright headers, e.g. `umdk/src/urma/lib/urma/core/`). His September 2025 essay is the first authoritative public statement of the design intent. Headline arguments, paraphrased:

### 2.1 What UB is solving

1. **Bus-versus-network split.** Buses are tightly-coupled and low-latency but don't scale; networks scale but pay microsecond-to-millisecond latency. UB unifies intra-node and inter-node interconnects under a single memory abstraction.
2. **CPU bottleneck in heterogeneous systems.** Master-slave architectures funnel device-to-device traffic through the CPU. UB makes every device a peer (CPU, GPU, NPU, storage, memory) so they communicate directly.
3. **Connection-state explosion in RDMA.** RDMA's per-connection Queue Pair model scales as O(N²M²) (N peer threads × M remote servers, both squared). URMA's Jetty decouples transaction from transport, reducing to O(NM) — many transactions share a TP.
4. **Strict-ordering waste.** TCP and RDMA both enforce stricter ordering than most apps need. Single-packet loss head-of-line-blocks the entire stream. UB defaults to weak ordering with strong ordering as opt-in.
5. **Cluster-scale memory latency.** Prior systems force explicit data movement; UB exposes datacenter-scale shared memory with load/store semantics — OBMM is the kernel piece that delivers this.
6. **Slow congestion signalling.** Traditional AQM reacts only after queues fill. UB uses **Confined AQM (C-AQM)** — credit-based, end-to-end, pre-allocated bandwidth via switch-NIC negotiation.
7. **The KV-cache distribution problem.** LLM inference needs hundreds of GB of shared KV state across GPUs. Prefix-Caching across GPU clusters (built on UB's pooled memory) is the killer application that finally validated the UB thesis after years of "abstract peer memory pool" framing.

### 2.2 Named design tradeoffs

| Tradeoff | UB's choice | Cost |
|---|---|---|
| Synchronous Load/Store vs. async Read/Write | Both supported | More HW complexity; flexibility for caller |
| Strong vs. weak ordering | Default weak (RO/NO); SO opt-in | Apps must reason about consistency |
| Per-transaction vs. per-packet load balancing | Both, exposed via TPG | Per-packet maxes throughput but adds reordering complexity |
| Fast vs. timeout retransmit | Conditional: fast if single-path, timeout if ECMP | App must know its topology |
| Jetty resource sharing | Connectionless + optional isolation via multiple jetties | App chooses fairness vs. scale |
| Cache coherence model | Multi-reader, single-writer | Simpler than dynamic sharers; software handles edge cases |

### 2.3 Historical context Bojie Li shares

- UB was **conceived 4–5 years before 2025**, motivated by AI scaling laws.
- The early design targeted abstract "peer memory pools" but had no killer app.
- The KV-cache problem (Prefix Caching across GPU clusters) emerged later as the validation case.
- Bojie's prior **iPipe research (2018–2021)** on total-order protocols revealed fragility under load — that experience drove UB's weak-ordering bias.
- Inspirations cited: causal-structure thinking from quantum physics; fault-tolerant probabilistic AI algorithms.

### 2.4 What UB defends and what it critiques

**Defends:**

- Supporting both Load/Store and Read/Write models despite implementation cost — different workloads genuinely need different access patterns.
- The complex jetty "berth" model — back-pressure-aware flow control between software and hardware.
- Exposing ordering choice (RO/SO/NO) to apps — match performance to actual consistency needs.

**Critiques:**

- Master-slave RDMA / PCIe as a heterogeneous-systems bottleneck.
- Connection-oriented QP design as historical inertia blocking multicore fairness.
- TCP byte-stream semantics for over-enforcing ordering.
- Timeout-based deadlock recovery as a "blunt last resort" violating losslessness.

**Architectural systemic insight (paraphrased):** push complexity into hardware near line-rate, away from the OS / app layer — but expose the *choice* of how much isolation and fairness each app needs.

---

## 3. The earlier (APNet'21 / 2023) framing — additional details

From Bojie Li's 2023 post summarizing Kun Tan's APNet'21 talk on "compute native networking":

- UB defines three properties: **memory semantics** (load/store, not byte streams), **unified protocol** (one protocol for all device types), **scalability** (10⁴+ components).
- An older URMA address format: **3 fields = (Entity ID, UASID, offset)** — single address space across nodes. (Note: this differs from the current public spec's UBMD = (EID, TokenID, UBA). UASID may have been renamed / repurposed; **flag for spec verification**.)
- **UBMMU** is hardware-based virtual address translation **integrated into CPUs** — important: not a discrete IOMMU bolt-on, but co-designed.
- **Confined AQM (C-AQM):** credit-based, end-to-end congestion control, avoids queueing.
- An **Orchestrator** is a programmable engine that groups multiple memory operations into complex transactions.
- The UB protocol layer is described as **SDN-based**, not Ethernet/IP, supporting **800 Gbps+** speeds.

The 2023 talk does **not** explicitly contrast with InfiniBand / RoCE / NVLink / CXL — but the framing implicitly says UB achieves both performance and scale where prior interconnects had to choose.

---

## 4. Concrete product scale (HUAWEI CONNECT 2025)

Per Huawei's `hc-lingqu-ai-superpod` announcement:

| Product | NPU count | Notes |
|---|---|---|
| **Atlas 950 SuperPoD** | 8,192 Ascend NPUs | Flagship UB 2.0 SuperPoD |
| **Atlas 960 SuperPoD** | 15,488 Ascend NPUs | Next-gen variant |
| **Atlas 950 SuperCluster** | 500,000+ Ascend NPUs | Cross-domain via UBoE |
| **Atlas 960 SuperCluster** | 1,000,000+ Ascend NPUs | Targeted scale |
| **TaiShan 950 SuperPoD** | (general-purpose; CPU-centric) | Non-NPU variant |

**Earlier production:** Atlas 900 A3 SuperPoD shipped **starting March 2025** with UnifiedBus 1.0; over 300 deployed and "fully validated" UB 1.0 by the time of the September 2025 announcement.

**Open-access commitments** (per `hc-superpod-innovation`):

- **UB OS Component**: made open-source for integration into "upstream open-source OS communities such as openEuler."
- **CANN toolkit** (Compute Architecture for Neural Networks): "progressively open-sourcing".
- **Mind series components**: "fully open-source".
- **Hardware specs**: NPU modules, air- and liquid-cooled blade servers, AI cards, CPU boards, cascade cards — opened for partner products.
- **No specific dates** in the announcement for the open-source releases.

UnifiedBus 2.0 specification itself was released as an open standard at HC 2025 (the local PDF cover page lists release date 2025-12-31 — that's the canonical spec freeze date).

---

## 5. CloudMatrix384 — concrete benchmarks ([arXiv:2506.12708](https://arxiv.org/abs/2506.12708))

The first peer-reviewed benchmark study of UB in production:

**Hardware:** 384 Ascend 910C NPUs + 192 Kunpeng CPUs in one supernode, interconnected via **ultra-high-bandwidth UnifiedBus**.

**Software:** "CloudMatrix-Infer" — LLM serving stack tested on **DeepSeek-R1**, supporting **expert parallelism EP320**.

**Throughput (per NPU):**

- **Prefill: 6,688 tokens/sec/NPU**
- **Decode: 1,943 tokens/sec/NPU**, with TPOT (time-per-output-token) under 50 ms
- **Decode under tight latency (15 ms TPOT): 538 tokens/sec/NPU sustained**

**Why UB matters here (paraphrased from the paper's framing):** all-to-all expert-parallel traffic and KV-cache distribution would saturate any standard fabric. UB's pooled memory + low-latency RDMA-like transactions enable the EP320 pattern.

---

## 6. UB-Mesh — academic claim about topology ([arXiv:2503.20377](https://arxiv.org/abs/2503.20377))

A March 2025 preprint on "hierarchically localized nD-FullMesh" topology built on UB primitives:

- **UB-Mesh-Pod**: 4D-FullMesh topology with NPU + CPU + switch + NIC.
- **UB enables flexible IO bandwidth allocation and hardware resource pooling** — quoted claim from the abstract.
- **All-Path-Routing (APR)** for traffic management.
- **Headline numbers vs. Clos:**
  - 2.04× cost-efficiency
  - 7.2% higher network availability
  - 95%+ linearity in LLM training tasks

34 authors, no institutional affiliations on the abstract page — but the author list and topic strongly suggest Huawei + academic collaborators. **Useful as an independent third-party validation of UB's scaling claims.**

---

## 7. Mainline-kernel status

The picture from `lore.kernel.org` and `mailweb.openeuler.org` (the openEuler internal kernel list):

- **URMA / ubcore exists only in the openEuler kernel tree** (`drivers/ub/` on OLK-5.10 and OLK-6.6 branches). No RFC has been posted to LKML for upstream merge.
- The only LKML traces are **smatch static-analysis warnings** (e.g. `ubcore_copy_to_user()` return-value handling in `ubcore_cmd.h:134`) automatically reported against the openEuler tree — not direct submissions.
- Active code review happens on `kernel@openeuler.org` (the openEuler internal kernel list).
- Huawei's stated open-source commitment is that the **UB OS Component** is to be integrated into upstream OS communities such as openEuler — but no submission timeline to LKML is announced.

**Reasonable expectation:** URMA stays an openEuler-only kernel feature for the foreseeable future. Anyone wanting URMA on a non-openEuler distribution must port the `drivers/ub/` tree out-of-tree.

---

## 8. What this round changes / refines in the existing UMDK/ docs

### 8.1 Refinements to the spec doc (`umdk_spec_survey.md`)

- §1.3 (web sources) had a "TBD" placeholder. The Bojie Li essay, Huawei announcements, UB-Mesh paper, and CloudMatrix384 paper now anchor that section — see this doc.
- The 2023 talk's claim that **UBMMU is integrated into CPUs** (not a separate IOMMU) usefully clarifies why `drivers/iommu/hisilicon/{ummu-core,logic_ummu}` exists — the kernel piece exposes a CPU-side hardware feature.
- The earlier (2023) URMA address format "(Entity ID, UASID, offset)" differs from the current spec's UBMD = (EID, TokenID, UBA). UASID either renamed to TokenID, or the address layout was reworked. Worth verifying when reading the full Chinese spec.

### 8.2 Refinements to the comparison doc (`umdk_vs_ib_rdma_ethernet.md`)

- The §2.2 design-perspective table now has Bojie Li-cited justifications for several entries (jetty's many-to-many shape, weak ordering default, Confined AQM, the explicit Load/Store + async dual model).
- Concrete performance numbers: prefill 6,688 tok/s/NPU and decode 1,943 tok/s/NPU on CloudMatrix384 (vs. an empty cell in §2.6 of the comparison). Latency-bandwidth-class is in the same range as IB NDR but with markedly higher all-to-all bandwidth utilization on EP workloads.
- Ecosystem perspective: confirms the single-vendor (Huawei/HiSilicon) reality and the openEuler-only kernel status.

### 8.3 Updates to the architecture doc (`umdk_architecture_and_workflow.md`)

- The C-AQM congestion-control mechanism described in the 2023 talk is a control-plane behaviour that lives below URMA — note as an open-question follow-up to read in the Chinese spec §6.6 Congestion Control Mechanism.
- The "Orchestrator" (programmable engine grouping memory operations) from the 2023 talk has no obvious code-side analogue in the current `drivers/ub/` tree — possibly absent in the public release, possibly renamed. Flag as open question.

### 8.4 New facts worth promoting to memory

- UnifiedBus 2.0 spec was released as an open standard at **HUAWEI CONNECT 2025 (2025-09-18)** in Shanghai — Eric Xu keynote.
- UB OS Component is open-source for upstream import into openEuler; CANN and Mind series progressively / fully open-source.
- Atlas 900 A3 SuperPoD shipped with UB 1.0 since March 2025 — over 300 deployments before UB 2.0 launched.
- Atlas 950 / 960 SuperPoD scale: 8,192 / 15,488 NPUs.
- Atlas 950 / 960 SuperCluster scale: 500K+ / 1M+ NPUs.
- DeepSeek-R1 on CloudMatrix384: prefill 6,688 tok/s/NPU, decode 1,943 tok/s/NPU (≤50 ms TPOT), 538 tok/s @ 15 ms TPOT.
- UB-Mesh research vs Clos: 2.04× cost-efficiency, 95%+ training linearity.

---

## 9. Open follow-ups after this round

1. **UASID → TokenID rename verification.** The 2023 talk mentions UASID as part of the URMA address; the 2025 spec uses TokenID. Confirm in Chinese Base Spec §9 Memory Management whether UASID survived or was replaced.
2. **Orchestrator absence.** The 2023 talk mentions a programmable Orchestrator engine; not visible in current `drivers/ub/`. Was it renamed (UVS? UBFM?), dropped, or held back from the public release?
3. **C-AQM in code.** Confined AQM is a transport / data-link layer mechanism. Where is it parameterized and what knobs exist? Likely in `drivers/ub/ubus/` or `drivers/ub/urma/ubcore/ubcore_tp.c` flow-control code.
4. **UB OS Component repo.** Huawei announced the "UB OS Component" as open-source, but no specific repo. Is this a renaming of the `drivers/ub/` tree we already have, or a separate project?
5. **LKML upstreaming roadmap.** No public roadmap for URMA upstream submission. Worth tracking by subscribing to `kernel@openeuler.org` for activity signals.
6. **LWN coverage.** None as of this writing. Likely a future LWN article when (or if) URMA gets posted upstream.
7. **CANN open-source completeness.** "Progressively open-sourcing" is a present-tense; confirm what fraction of CANN — the Ascend toolkit URMA + CAM ride on — is actually source-available now.

---

_Companion: [`umdk_spec_survey.md`](umdk_spec_survey.md), [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), [`umdk_vs_ib_rdma_ethernet.md`](umdk_vs_ib_rdma_ethernet.md)._
