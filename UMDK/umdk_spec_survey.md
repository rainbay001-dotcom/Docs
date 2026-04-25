# UnifiedBus / UMDK / URMA / UDMA — spec and concept survey

_Last updated: 2026-04-25._

What the **UnifiedBus 2.0 Base Specification** and the **UMDK** project's own documentation say about the concepts named in the title, anchored to authoritative primary sources. Companion to [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), which covers the same stack from the source-code side.

> **Headline correction.** The UB Base Spec defines **URMA** (a high-performance asynchronous communication library) and **URPC** (a remote procedure call protocol) as software/library concepts, but it does **NOT** define "UDMA" or "UMDK". Those are implementation labels: **UDMA** is HiSilicon's specific UB DMA hardware engine (one of three aux-bus upper modules alongside UNIC and CDMA); **UMDK** is openEuler's "Lingqu UnifiedBus Memory Development Kit" — the userspace toolkit that ships URMA, URPC, ULOCK, USOCK, and CAM. (UB-Base-Spec-2.0-preview-en §1.6, §2.2; UMDK `README.md` §2.)

---

## 1. Source inventory

### 1.1 Local PDFs (`~/Documents/docs/unifiedbus/`)

| File | Size | Notes |
|---|---|---|
| `UB-Base-Specification-2.0-preview-en.pdf` | 325 KB | Public English preview — Ch. 1 (Intro), Ch. 2 (Arch), Ch. 1.6 Terminology table, plus full ToC of the rest. **Primary citable English source for this doc.** |
| `UB-Base-Specification-2.0-zh.pdf` | 28.8 MB | Full Chinese spec (~500–700 pp). Authoritative; used here only via the preview's mirrored ToC. |
| `UB-Software-Reference-Design-for-OS-2.0-zh.pdf` | 1.9 MB | OS-side software reference design. |
| `UB-Service-Core-SW-Arch-RD-2.0-zh.pdf` | 1.2 MB | Service-core software architecture. |
| `UB-Mgmt-OM-SW-Arch-and-IF-RD-2.0-zh.pdf` | 856 KB | Management / O&M software arch and interface. |
| `UB-SuperPoD-Architecture-White-Paper-zh.pdf` | 3.5 MB | SuperPoD whitepaper. |
| `1-超节点和关键应用场景.pdf` | 8.2 MB | "SuperNode and key application scenarios". |
| `2-灵衢总线技术和软件参考设计.pdf` | 3.1 MB | "Lingqu bus tech and software reference design". |
| `3-灵衢内存池化关键技术和应用.pdf` | 1.9 MB | "Memory pooling key tech and applications". |
| `5-灵衢设备虚拟化关键技术和应用.pdf` | 3.5 MB | "Device virtualization key tech". |
| `6-超节点可靠性关键技术.pdf` | 3.0 MB | "SuperNode reliability key tech". |
| `7-灵衢系统高阶服务关键技术和应用.pdf` | 6.6 MB | "System advanced services". |
| `8-超节点编程编译关键技术.pdf` | 1.9 MB | "SuperNode programming/compilation". |

### 1.2 Repo-side documentation

| Path | Notes |
|---|---|
| `~/Documents/Repo/ub-stack/umdk/README.md` | Lists UMDK components (URMA, CAM, URPC, ULOCK, USOCK) and exact kernel-module load order |
| `~/Documents/Repo/ub-stack/umdk/doc/en/urma/{URMA User Guide, URMA API Guide, URMA QuickStart Guide}.md` | English URMA docs — definition, install, API |
| `~/Documents/Repo/ub-stack/umdk/doc/en/urpc/Overview.md`, `URPC User Guide.md`, `UMQ {IO, Buffer, Flowcontrol, Initialize, Abnormal Event, Security}.md` | URPC + UMQ docs |
| `~/Documents/Repo/ub-stack/umdk/doc/ch/cam/CAM API Guide.ch.md` | CAM API (Chinese) |
| `~/Documents/Repo/ub-stack/umdk/doc/ch/urma/{User, API, QuickStart}.ch.md` | URMA Chinese docs |

### 1.3 Web sources (TBD)

The Bojie Li essay "The Thinking Behind Unified Bus", openEuler doc center, and Huawei Compute developer portal are noted in earlier memory but were not freshly fetched for this revision. **Add them in a follow-up pass.**

---

## 2. UnifiedBus at a glance

> "UB is a high-performance, low-latency interconnect protocol specifically designed for SuperPoD-scale AI and HPC deployments." (UB-Base-Spec-2.0-preview-en §2.1 p. 7)

UB is at once:

- **A protocol stack** — six layers from physical to function (§2.2 below).
- **A device model** — UBPUs (UB Processing Units) connected via UB links into a UB Fabric inside a UB domain.
- **A unified semantic** — one protocol covers memory access, messaging, RPC, and resource management.
- **A multi-domain encapsulation** — UBoE (UB over Ethernet) tunnels native UB transactions over IP networks for cross-domain reach.

UB Base Spec Revision 2.0, release date 2025-12-31 (cover page).

### 2.1 The six-layer protocol stack

From the spec's Figure 2-3 (p. 9), bottom up:

| Layer | What it does | Cite |
|---|---|---|
| **Physical** | SerDes, FEC, dynamic data-rate / lane-count adjustment, optical channel protection | §2.2 p. 9 |
| **Data link** | Per-link reliability via CRC, retransmission, credit-based flow control, virtual lanes | §2.2 p. 9 |
| **Network** | Routing inside and across UB domains; supports IP and **CNA** (Compact Network Address, 16/24-bit); per-packet/per-flow load balancing; multipath; upper-layer-customizable routing | §2.2 p. 9 |
| **Transport** | End-to-end. Three modes: **RTP** reliable, duplication-free; **CTP** compact (relies on lower-layer reliability — for low-loss environments); **UTP** unreliable. Multi-channel scheduling, congestion control, optional **TP bypass** for direct transaction-layer→network access | §2.2 p. 9 |
| **Transaction** | Four operation classes: **memory access**, **M2N messaging**, **maintenance**, **management**. Synchronous and asynchronous variants. Four service modes: **ROI** (reliable, ordered by initiator), **ROT** (by target), **ROL** (by lower layer), **UNO** (unreliable, non-ordered) | §2.2 p. 10 |
| **Function** | Two programming models: **load/store synchronous access** (UB Controller + NoC turn loads/stores into transaction ops) and **URMA asynchronous access** (the Jetty-based async API, §6 below). Higher-level abstractions like **URPC** sit at this layer | §2.2 p. 10 |

Two cross-cutting concerns sit alongside the stack diagram:

- **UMMU** — UB Memory Management Unit, performs UB→physical address translation and permission checks (§2.2 p. 10; §9 Memory Management).
- **UBFM** — UB Fabric Manager, oversees a UB domain; manages compute, communication, and interconnect resources. Multiple instances may collaborate in a large domain (§2.2 p. 10).

### 2.2 UB system fundamental elements

Per spec §2.1 p. 8:

| Element | Spec definition (paraphrased) |
|---|---|
| **UBPU** (UB Processing Unit) | A processing unit that supports the UB protocol stack and implements specific functions. CPU, NPU, GPU, DPU, SSU (storage), Memory, Switch, etc. all instantiate as UBPUs. |
| **UB Controller** | Inside a UBPU, implements the UB protocol stack and exposes SW + HW interfaces. |
| **UMMU** | Inside a UBPU, address mapping + permission checks. |
| **UB Switch** | Optional inside a UBPU; forwards packets between UB ports. |
| **UB link** | Full-duplex, point-to-point connection between two UBPU ports. Asymmetric (TX-lane count may ≠ RX-lane count). |
| **UB domain** | Collection of UBPUs interconnected via UB links. |
| **UB Fabric** | All UB Switches and UB links inside one domain. |
| **UBoE** | Encapsulation that lets native UB transactions ride over Ethernet/IP — the cross-domain bridge. |

Spec figure 2-1 (p. 7) shows a single domain with seven UBPU types — CPU, NPU, GPU, SSU, DPU, Memory, Switch (and "Others") — all peers on the UB Fabric, each with its own UB Controller + UMMU. Figure 2-2 (p. 8) shows two domains stitched together by UBoE over an Ethernet link.

### 2.3 Key features called out in the spec

> "Unified protocol", "Peer-to-peer coordination", "All-resource pooling", "Full-stack coordination", "Flexible topology", "High availability". (§2.1 pp. 8–9)

Notable specifics:

- **Peer-to-peer.** Every UBPU is an architectural peer; any UBPU can directly initiate transactions to any other without a host or proxy.
- **All-resource pooling.** Compute, memory, storage, and interconnect (TP channels) are all poolable. UBFMs centrally schedule pooled resources.
- **Multipath.** Multiple TP channels can be aggregated; per-packet or per-flow load balancing; end-to-end.
- **Per-workload tuning.** Each layer offers selectable modes; system can be tuned for the latency/power/reliability mix a workload needs.

---

## 3. Memory model (Chapter 9 of the spec)

The base unit of remote memory access is the **memory segment**:

> "A block of continuous virtual/logical addresses that serves as the basic object of memory transaction operations, identified by a globally unique UB memory descriptor (UBMD)." (§1.6 Terminology)

A **UBMD** is a 3-tuple `(EID, TokenID, UB address)`:

> "A UBMD includes the Entity identifier, TokenID, and UB address, used to index the home's physical address." (§1.6)

The model is **Home-User**:

- **Home** owns the memory segment.
- **User** is the UBPU that accesses it.
- The Home publishes the segment along with a **UBA** (UB Address) — the address the User uses to reach into the Home's segment.
- The User presents a **token** (TokenID + TokenValue) for authentication.

The **UMMU** translates the UBMD into a Home physical address and verifies the token's permissions. From spec ToC: `9.2 Home-User Access Model`, `9.3 UBMD`, `9.4 UMMU Functions and Working Process`, `9.5 UB Decoder Functions and Processes`.

**UB Decoder.** A UB Controller component that translates user *physical* addresses into UB addresses for outgoing transactions. (§1.6)

**Why the token is separate from the segment.** The TokenID is independent of the segment — that lets the Home rotate tokens (revoke and reissue) without re-registering the segment. This is the foundation of **rotating token revocation** referred to in §11 Security.

---

## 4. Transport modes & ordering modes

### 4.1 Three transport-layer modes (§2.2 p. 9; §6 Transport Layer)

| Mode | Definition | Use case |
|---|---|---|
| **RTP** (Reliable Transport) | Connection-oriented, reliable, duplication-free; lossless end-to-end. | Default for HPC/AI. |
| **CTP** (Compact Transport) | Reliability via lower layers (data link + retransmit); minimal transport-layer state. | Low-loss-rate environments where transport-layer state machine overhead is unwanted. |
| **UTP** (Unreliable Transport) | Connectionless, no reliability. | Tolerant of loss — e.g. in-band connection establishment, discovery. |

A **TP channel** is "an end-to-end connection established between two transport endpoints. It provides end-to-end reliable communication for the transaction layer." (§1.6) A **TPG** (TP channel group) groups several TP channels for load balancing across them.

ACKs / NAKs at the transport layer are explicit: **TPACK** (positive) and **TPNAK** (negative) packets between transport endpoints (§1.6).

### 4.2 Four transaction-layer service modes (§1.6, §7 Transaction Layer)

| Mode | Reliability | Ordering kept by | Out-of-order pkts allowed |
|---|---|---|---|
| **ROI** | Reliable | Initiator | Yes |
| **ROT** | Reliable | Target | Yes |
| **ROL** | Reliable | Lower layer | Yes (subject to lower-layer caps) |
| **UNO** | Unreliable | None | Yes |

These give the transaction layer flexibility about *who* enforces ordering — useful for workloads with very different ordering vs throughput tradeoffs.

---

## 5. URMA — Unified Remote Memory Access

### 5.1 The spec's definition

> "A high-performance asynchronous communication library supporting UB semantics, providing asynchronous memory access and two-sided message communication functions." (UB-Base-Spec-2.0-preview-en §1.6)

URMA lives at the **function layer** of the UB stack. It is one of two programming models the spec acknowledges (the other is load/store synchronous):

> "In URMA asynchronous access, applications can use APIs provided by Jetties to set up communication pairs, submit transaction operations, and query responses." (§2.2 p. 10)

### 5.2 The Jetty

The **Jetty** is the basic communication unit of URMA:

> "Provides the capability to issue and execute asynchronous transaction operations, supporting communication modes such as many-to-many and one-to-one." (§1.6)

A Jetty is the spec's analogue of a queue pair (QP) in InfiniBand verbs — but more flexible because it explicitly supports many-to-many. URMA's spec-level object model:

- **Jetty** — the endpoint.
- **Memory segment** + **UBMD** — the addressable target of memory transactions.
- **Token** — credential enforcing access.
- **EID** — Entity identifier.

### 5.3 What UMDK's URMA documentation adds

From `umdk/doc/en/urma/URMA User Guide.md` line 4 (paraphrased):

> The URMA subsystem provides high-bandwidth, low-latency data services within UBUS. It carries message communication and data forwarding for data-center services, and is the substrate for higher-level semantic orchestration. It targets reduced end-to-end latency for big-data workloads and high bandwidth + low latency for HPC/AI.

From `umdk/README.md` §2 entry 1 (paraphrased):

> URMA unifies memory semantics, providing unilateral, bilateral, and atomic remote-memory operations. It exposes two interface families: a **northbound** API for applications and a **southbound** driver-programming API for driver developers.

The northbound/southbound split matches the kernel/userspace boundary explored in [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md): northbound = `urma_api.h`, southbound = the `ubcore_ops` provider vtable.

### 5.4 Operation set (informal, from spec + repo)

URMA exposes RDMA-like primitives at the API level: **WRITE** (one-sided), **READ** (one-sided), **SEND/RECV** (two-sided), **ATOMIC** (fetch-add, CAS). The transaction layer also offers **memory access**, **M2N messaging**, **maintenance**, and **management** as transaction types — so URMA is a concrete subset of what the transaction layer can express.

### 5.5 Differences from InfiniBand verbs (per spec terminology)

The spec keeps a verbs-like shape but with explicit deviations:

| URMA spec concept | InfiniBand verbs equivalent | Note |
|---|---|---|
| **EID** (Entity identifier) | GID | EID identifies the *Entity* (resource allocator), not the device port. |
| **Jetty** | QP (RC) | Many-to-many natively; not just point-to-point. |
| **Memory segment** + **UBMD** | MR + rkey | MR-equivalent and key are decoupled — see token rotation. |
| **TokenID/TokenValue** | rkey | Independently allocable — supports rotation without re-registering memory. |
| **TP channel group (TPG)** | LAG | First-class multipath aggregation. |
| **Reliable / Compact / Unreliable transport** | RC / RD / UD (not 1:1) | Different distinctions; CTP especially has no clean IB analogue. |
| **ROI/ROT/ROL/UNO ordering modes** | _(no analogue)_ | UB is more flexible about who enforces ordering. |

---

## 6. URPC — Unified Remote Procedure Call

> "A remote procedure call protocol, utilizing UB transaction layer capabilities and direct memory access, enabling direct peer-to-peer remote function calls between UBPUs." (UB-Base-Spec-2.0-preview-en §1.6)

URPC is **a layer above URMA**: it uses the transaction layer's memory-access semantics and DMA to implement RPC without socket-style framing. Spec coverage in §8.5 URPC and Appendix H URPC Message Format (H.1 Overview, H.2 URPC Function, H.3 URPC Messages).

In UMDK, URPC is one of the five top-level components (`umdk/README.md` §2 entry 3) and ships with its own documentation set under `umdk/doc/en/urpc/`. Notable companion artifact: **UMQ** (Userspace Message Queue), URPC's transport substrate, with its own docs (`UMQ IO.md`, `UMQ Buffer.md`, `UMQ Flowcontrol.md`, `UMQ Initialize.md`, `UMQ Abnormal Event.md`, `URPC Security.md`).

---

## 7. UMDK — what the project says about itself

UMDK is **not a spec concept**; it is the openEuler umbrella for the UnifiedBus userspace toolkit.

> "Lingqu UnifiedBus Memory Development Kit (UMDK) is a distributed communication software library centered around memory semantics. It provides high-performance communication interfaces for data center networks, within super nodes, and between cards inside servers." (`umdk/README.md` §1)

### 7.1 Components (per `umdk/README.md` §2)

| # | Component | One-line role |
|---|---|---|
| 1 | **URMA** | Memory-semantics communication library; northbound app API + southbound driver API |
| 2 | **CAM** | SuperPOD communication acceleration library — northbound to vllm / SGlang / VeRL, southbound to Ascend SuperPOD hardware |
| 3 | **URPC** | UB-native high-performance RPC between hosts and devices |
| 4 | **ULOCK** | Distributed lock support for state synchronization |
| 5 | **USOCK** | Standard socket API compatibility — TCP apps gain UB performance with no code changes |

### 7.2 Where it ships

- **Build target**: a single `umdk-25.12.0` RPM, built via `rpmbuild -ba umdk.spec`. CMake fall-back also supported (`cmake .. -D BUILD_ALL=disable -D BUILD_URMA=enable`).
- **Build options**: `--with {asan, test, urma, urpc, dlock, ums}`, `--define 'kernel_version 6.6.92'` (default kernel target).
- **Latest tag**: `URMA_24.12.0_LTS` (Dec 2024). Active development on `master` (latest commit 2026-04-24 at the time of writing).

### 7.3 Required kernel modules and load order

From the README's "Install Instructions" — mandatory load order for a working URMA stack:

```
ubfi.ko.xz  cluster=1
ummu-core.ko.xz
ummu.ko.xz                ipver=609
ubus.ko.xz                ipver=609 cc_en=0 um_entry_size=1
hisi_ubus.ko.xz           msg_wait=2000 fe_msg=1 um_entry_size1=0 cfg_entry_offset=512
ubase.ko.xz
unic.ko.xz                tx_timeout_reset_bypass=1
cdma.ko.xz
ubcore                    (modprobe)
uburma                    (modprobe)
udma.ko.xz                dfx_switch=1 ipver=609 fast_destroy_tp=0 jfc_arm_mode=2
```

This load order is the most concrete confirmation that **udma is one of three aux-bus upper modules (`unic`, `cdma`, `udma`) loaded after the foundation (ubfi, ummu, ubus, ubase)** and before/alongside ubcore + uburma. URMA does not "contain" udma; URMA (= ubcore + uburma) sits *next to* udma in the load order, and udma registers itself as a *provider* into ubcore.

### 7.4 Build dependencies (per README)

`rpm-build`, `make`, `cmake`, `gcc`, `gcc-c++`, `glibc-devel`, `openssl-devel`, `glib2-devel`, `libnl3-devel`, **`kernel-devel`** (URMA depends on `ubcore`, which is part of the openEuler kernel proper).

---

## 8. UDMA — clarifying what the spec does and does not say

UDMA is **not** a UB Base Specification term. Searching the English preview's terminology section (§1.6, pp. 4–7) finds no "UDMA" entry. UDMA appears only in implementation contexts:

- A **HiSilicon hardware DMA engine** for UnifiedBus, shipped as `drivers/ub/urma/hw/udma/` in the openEuler OLK-6.6 kernel (copyright 2025).
- A **kernel module** (`udma.ko.xz`) loaded after ubcore/uburma per UMDK's install instructions.
- Has its own userspace provider half at `umdk/src/urma/hw/udma/` (the `udma_u_*.{c,h}` files).

**What UDMA does, in spec terms:** UDMA is a UB Controller implementation (per spec §2.1 element list). It implements the UB transaction layer's memory-access and messaging operations and exposes the URMA programming API to userspace via ubcore + uburma + the UDMA-specific char dev mappings.

**Sibling implementations:** `unic` (UB-native NIC) and `cdma` (CDMA — a different DMA engine; on-die or chiplet-level, per inferred but-not-yet-confirmed reading). UNIC and CDMA do **not** plug into URMA — they have their own kernel-side uAPIs.

**Take-away for vocabulary discipline:**

- "UB" / "UnifiedBus" = the protocol stack and architecture.
- "URMA" = the spec-defined async communication library / programming model on the function layer.
- "UMDK" = the userspace kit shipping URMA, URPC, ULOCK, USOCK, CAM.
- "UDMA" = a HiSilicon DMA engine that implements URMA on UB hardware.
- "ubcore" / "uburma" = the kernel implementation of the URMA framework + char device.

---

## 9. Supporting concepts

### 9.1 EID (Entity identifier)

> "An identifier assigned to an Entity that uniquely identifies the communication object identity of that Entity within a UB domain." (§1.6)

> Entity: "The basic unit by which a device allocates its own resources. Each Entity is a communication object within a UB domain." (§1.6)

EID is to Entity as MAC is to NIC port — but Entity is an *abstraction over device-internal resources*, not a hardware port. A UBPU may host multiple Entities, each with its own EID, allowing fine-grained resource accounting and isolation within a single UBPU.

GUID is a separate, manufacturing-stage globally-unique identifier (§1.6).

### 9.2 UBFM and UVS

The spec describes **UBFM** (UB Fabric Manager) as the central resource manager for a UB domain (§2.2 p. 10). In code, the equivalent control-plane-from-userspace surface is **UVS** (Unified Vector Service) — see [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) §3.2 for the ioctl magic `'V'` and command set. _The mapping between UBFM (spec concept) and UVS (code) is plausible but not explicitly drawn in the preview — confirm in §10 Resource Management of the full spec._

### 9.3 Network partitions and access control

> Network partition: "A collection of UB processing units (UBPUs) with assigned IP addresses, where network communication between different network partitions is isolated." (§1.6)

UB partition: "A UB partition is a collection of Entities. UB transactional communication is isolated between UB partitions." (§1.6) — separate from network partition; sits at the transaction layer.

Spec Chapter 11 Security covers Device Authentication, Resource Partitioning, Access Control, Data Transmission Security (CIP), and TEE Extension.

### 9.4 Trusted Execution Environment (TEE)

> "A computing environment built upon hardware-level isolation and a secure boot mechanism… [Source: GB/T 41388-2022, 3.3, modified]" (§1.6)

UB has cross-device TEE extension (§11.6), and **EE_bits** (Execution Environment bits) tag transactions originating from a TEE — a per-transaction security context.

### 9.5 Hot-plug

Appendix G covers hot-plug as a first-class concern: General Requirements (G.1), Components Enabling Device Hot-Plug (G.2), Hot-Removal Process (G.3), Hot-Add (G.4), Hot-Plug Events (G.5). Implication for software: providers must handle device-disappear and device-arrive transitions cleanly — which is why ubcore has so much hot-remove machinery (see arch doc §2.1).

### 9.6 UBoE

> UBoE: "An encapsulation of UB transport layer and upper layers for transporting UB transactions over Ethernet/IP networks, where UB packets are routable over the IP network." (§1.6)

UBoE is the cross-domain bridge — Figure 2-2 (p. 8). Appendix E covers Ethernet Interworking in detail.

### 9.7 RAS / Reliability

Spec Chapter 10.6 RAS, plus pervasive references to multi-layer redundancy: physical-layer rate/lane fallback, data-link CRC + retransmit, network-layer multipath, transport-layer end-to-end retransmit + TPACK/TPNAK. Goal: graceful degradation over hard failure.

---

## 10. Terminology (consolidated)

Glossary expanded from spec §1.6, plus implementation labels.

### 10.1 Spec-defined terms

| Acronym | Expansion | Source |
|---|---|---|
| **CNA** | Compact Network Address (16/24-bit) | §1.6 |
| **CTP** | Compact Transport (mode) | §1.6 |
| **DLLDB** | Data Link Layer Data Block (1–32 flits) | §1.6 |
| **EE_bits** | Execution Environment bits (TEE security tag) | §1.6 |
| **EID** | Entity identifier | §1.6 |
| **flit** | 20-byte data link layer transfer unit | §1.6 |
| **GUID** | Globally Unique Identifier (per Entity, mfg-stage) | §1.6 |
| **LMSM** | Link Management State Machine (physical layer) | §1.6 |
| **MTU** | Maximum Transmission Unit | §1.6 |
| **ROI / ROL / ROT / UNO** | Reliable, Ordered by Initiator / Lower-layer / Target / Unreliable Non-Ordered | §1.6 |
| **RTP** | Reliable Transport (mode) | §1.6 |
| **TCO / TEO** | Transaction Completion Order / Execution Order | §1.6 |
| **TEE** | Trusted Execution Environment | §1.6 |
| **TP channel** | Transport channel — end-to-end transport-layer connection | §1.6 |
| **TPACK / TPNAK** | Transport (positive / negative) ACK | §1.6 |
| **TPEP** | Transport endpoint | §1.6 |
| **TPG** | Transport channel Group (multipath) | §1.6 |
| **UBA** | UB Address (Home-published address for User access) | §1.6 |
| **UBFM** | UB Fabric Manager | §2.2 |
| **UBMD** | UB Memory Descriptor (= EID + TokenID + UBA) | §1.6 |
| **UBoE** | UB over Ethernet | §1.6 |
| **UBPU** | UB Processing Unit | §1.6 |
| **UMMU** | UB Memory Management Unit | §1.6 |
| **UNO** | Unreliable Non-Ordered (transaction service mode) | §1.6 |
| **URMA** | Unified Remote Memory Access | §1.6 |
| **URPC** | Unified Remote Procedure Call | §1.6 |
| **UTP** | Unreliable Transport | §1.6 |

### 10.2 Implementation labels (not in the spec)

| Label | Meaning |
|---|---|
| **UMDK** | openEuler "Lingqu UnifiedBus Memory Development Kit" — userspace toolkit (`umdk` repo) |
| **UDMA** | HiSilicon hardware DMA engine implementing URMA on UB hardware |
| **UNIC** | HiSilicon UB-native NIC driver (`drivers/net/ub/unic/`) |
| **CDMA** | HiSilicon CDMA (sibling to UDMA, `drivers/ub/cdma/`) |
| **UBASE** | Auxiliary-bus framework in the kernel for UB upper modules (`drivers/ub/ubase/`) |
| **UBUS** | UB bus driver in the kernel (`drivers/ub/ubus/`) |
| **UBFI** | UB Firmware Interface driver (`drivers/ub/ubfi/`) |
| **OBMM** | Ownership-Based Memory Management — cross-supernode shared memory framework (`drivers/ub/obmm/`) |
| **UVS** | Unified Vector Service — userspace control library (`umdk/src/urma/lib/uvs/`); spec-side analogue is UBFM |
| **UMQ** | Userspace Message Queue — URPC's transport substrate (`umdk/src/urpc/umq/`) |
| **CAM** | SuperPOD Communication Acceleration library (`umdk/src/cam/`) |
| **ULOCK / dlock** | Distributed lock library (`umdk/src/ulock/dlock/`) |
| **USOCK / UMS** | UB Message Socket — POSIX-compatible socket facade (`umdk/src/usock/ums/`) |

---

## 11. Open questions

1. **UBFM ↔ UVS mapping.** The spec describes UBFM as a logical fabric manager. In code, UVS appears to be the userspace half of that. Confirm the intended scope of UBFM via spec §10 Resource Management before treating them as equivalent.
2. **UBoE encapsulation specifics.** Appendix E covers Ethernet interworking; full layout (UDP/TCP? port allocation? packet headers?) needs to be read out of the Chinese spec or located in another doc.
3. **TP bypass.** Mentioned in §2.2 as letting the transaction layer reach the network layer directly. Conditions and consequences not in the preview — read §6.8 Interaction Between the Transport Layer and Transaction Layer.
4. **Token rotation.** Spec preview implies it but does not detail. Read the full §11.4 Access Control.
5. **CDMA's actual role.** Sibling of UDMA per `ubase/Kconfig`, but the spec preview doesn't enumerate UB DMA engines. Likely a Huawei whitepaper or PDF #2 ("Lingqu bus tech and software reference design") covers this.
6. **ROI / ROT / ROL distinctions.** Preview gives one-liners. The full spec §7 Transaction Layer presumably details when each is mandatory or recommended.
7. **GUID vs EID lifecycle.** GUID is fixed at manufacturing; EID is assigned in a domain. How does device discovery resolve GUID → EID? UBFM presumably owns this — but where in the spec is the protocol described?
8. **CAM's relationship to URMA at the API level.** UMDK README pitches CAM as an upstream-facing accelerator for vllm/SGlang/VeRL. The spec doesn't mention CAM (it's a UMDK-specific library). Read `umdk/doc/ch/cam/CAM API Guide.ch.md` to map CAM ops to URMA primitives.
9. **USOCK kernel surface.** UMS likely registers an `AF_UB` socket family — `umdk/src/usock/ums/kmod/` should reveal whether it is in-tree or out-of-tree.
10. **The `ipver=609` parameter.** Several module-load lines pass `ipver=609`. Looks like an IP-version / protocol-version tag specific to a UB silicon revision. Find the definition.

---

## 12. Citations

Inline `(UB-Base-Spec-2.0-preview-en §X.Y p. N)` refers to `~/Documents/docs/unifiedbus/UB-Base-Specification-2.0-preview-en.pdf`. UMDK README and per-component docs are at the paths listed in §1.2.

Web sources to add in a follow-up revision:

- Bojie Li (李博杰), "The Thinking Behind Unified Bus" (essay on bojieli.com).
- openEuler doc center pages on UMDK / URMA.
- gitee.com/openeuler/umdk repo (canonical, vs the GitHub mirror).
- Huawei Compute developer portal (for CloudMatrix / SuperPoD whitepapers in English).
- LWN articles (search "URMA", "ubcore"); kernel mailing list mentions (lore.kernel.org).

A second pass should fetch each of these and add `(URL)` citations alongside the spec references where they corroborate or extend the claims here.

---

_Companion document: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md)._
