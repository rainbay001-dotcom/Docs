# UMDK / URMA / UDMA vs Ethernet / InfiniBand / RDMA — terminology + comparison

_Last updated: 2026-04-25._

A side-by-side reference for engineers coming from Ethernet, InfiniBand (IB), or RDMA-via-verbs and trying to find their footing in UnifiedBus / URMA / UDMA / UMDK. Two parts:

1. **Concrete terminology mapping** — what term in UB-land means what in IB/Ethernet/RDMA-land, with caveats about where the analogy breaks.
2. **Multi-axis comparison** — spec, design, implementation, interface, ecosystem, security, performance.

Anchored to the UB Base Specification 2.0 preview (English) and the openEuler `kernel` + `umdk` source trees on this machine. See [`umdk_spec_survey.md`](umdk_spec_survey.md) and [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) for the underlying material this distills.

> **Caveat up front.** The mappings below are useful pedagogical analogies — most are not strict equivalences. The "≈" symbol means "plays the same role," not "byte-for-byte equal." A handful of UB concepts (jetty groups, separable tokens, ROI/ROT/ROL/UNO ordering modes) have no clean IB/RDMA equivalent at all; some Ethernet concepts (broadcast domains, STP) have no UB equivalent.

---

## Part 1 — Terminology mapping

### 1.1 Spec-level vocabulary

| UnifiedBus / URMA | InfiniBand verbs | RoCE / generic RDMA | Ethernet / IP | Notes |
|---|---|---|---|---|
| **UnifiedBus (UB)** | InfiniBand fabric | RoCE-capable Ethernet | Ethernet | UB is *both* a protocol stack *and* a unified semantic for memory + messaging + RPC. IB Architecture is a closer parallel than RoCE alone. |
| **UB domain** | Subnet | Broadcast / L2 domain | Broadcast / L2 domain | A UB domain is the unit of single-protocol-instance scope; cross-domain reach uses UBoE. |
| **UB Fabric** | The fabric (switches + links inside a subnet) | The L2 network | The L2 network | All UB switches and links inside one UB domain. |
| **UB link** | IB link | Ethernet link | Ethernet link | Full-duplex, point-to-point, asymmetric (TX-lane count may differ from RX-lane count — unlike Ethernet). |
| **UBPU** (UB Processing Unit) | HCA | NIC + endpoint compute | NIC + host | Spec-level term for any device speaking UB: CPU, NPU, GPU, DPU, SSU (storage), Memory, Switch — all are UBPUs. |
| **UB Controller** | HCA's transport-capable engine | NIC's RDMA engine | NIC + driver | The component inside a UBPU that implements the UB protocol stack. |
| **UMMU** (UB Memory Management Unit) | HCA address translation + protection | RDMA-NIC address translation + IOMMU | IOMMU / SMMU | UMMU translates UB addresses to physical and validates tokens. |
| **UB Switch** | IB switch | Ethernet switch | Ethernet switch | Optional inside a UBPU — switching can be embedded in compute UBPUs. |
| **UBFM** (UB Fabric Manager) | Subnet Manager (SM) | _(no exact equivalent)_ | _(no exact equivalent)_ | Logically centralized resource scheduler for a UB domain. |
| **UBoE** (UB over Ethernet) | _(none — IB never tunneled itself)_ | _Inverse of_ RoCE (RoCE is RDMA over Ethernet; UBoE is UB over Ethernet) | _(n/a)_ | UBoE wraps the **transport layer + upper layers** of UB; lower layers are replaced by Ethernet/IP. |

### 1.2 URMA object model ↔ IB verbs

| URMA / spec term | URMA / kernel struct | IB verbs analogue | Notes |
|---|---|---|---|
| **Entity** | (logical; no single struct) | _(no clean analogue)_ | The basic *resource-allocation unit* inside a UBPU. A device may host many Entities. Closer to "process inside an HCA" than to a port. |
| **EID** (Entity Identifier) | `ubcore_eid` (16 bytes) | GID | EID identifies an Entity; GID identifies a port. EID format carries network info similarly. |
| **Jetty** | `struct ubcore_jetty` (`include/ub/urma/ubcore_types.h:1152`) | `struct ib_qp` (RC-mode) | Bidirectional endpoint. **First-class many-to-many** support; verbs RC is point-to-point. |
| **JFS** (Jetty Free Send queue) | `struct ubcore_jfs` (types.h:1367) | Send Queue (SQ) inside a QP | Send work queue. |
| **JFR** (Jetty Free Receive queue) | `struct ubcore_jfr` (types.h:1433) | Recv Queue (RQ) or **SRQ** | The "shareable" flavor maps to SRQ. |
| **JFC** (Jetty Flush Completion queue) | `struct ubcore_jfc` (types.h:1506) | `ib_cq` | Completion queue. |
| **Memory segment** + **UBMD** | `struct ubcore_target_seg` | `ib_mr` + rkey | Spec term is "segment"; identifier is the **UBMD** = (EID, TokenID, UBA). Segment **and** key are decoupled. |
| **Token** (TokenID + TokenValue) | `struct ubcore_token_id` | rkey | **Independently allocable from the segment** — enables rotating revocation without re-registering memory. **Two-granularity per UB-Base-Spec §11.4.4**: group-wide (Home invalidates TokenID/TokenValue → all Users lose access) or per-User (Home generates B-TokenValue, sends only to surviving Users; transition window keeps both A+B; then promote B and generate C as new backup → un-updated User is revoked). See [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §4.3 for the full protocol. |
| **UBA** (UB Address) | (logical) | virtual addr in MR | The address the User uses to reach into the Home's segment. |
| **UB memory descriptor (UBMD)** | (logical) | rkey + virtual addr | The 3-tuple `(EID, TokenID, UBA)` identifying a memory access. |
| **UContext** (per-process kernel context) | `struct ubcore_ucontext` (types.h:1231) | `ib_ucontext` | Per-process kernel state. |
| **UB device handle** | `struct ubcore_device` (types.h:3366) | `struct ib_device` | Per-provider device record in core framework. |
| **Provider vtable** | `struct ubcore_ops` (types.h:2101) | `struct ib_device_ops` | ~20 function pointers; conceptually identical pattern. |
| **TP** (Transport Path / Channel) | `struct ubcore_tp` (types.h:957) | QP transport context (per-QP) | Reified, ref-counted, **shared across jetties between same EID pair** — IB's transport state is per-QP. |
| **TPG** (TP Group) | `struct ubcore_tpg` (types.h:1026) | LAG (link-aggregation group) | First-class multipath at the transport layer; up to 32 TPs per group. |
| **VTP** (Virtual TP) | `struct ubcore_vtp` | _(no equivalent)_ | An indirection layer used for live-migration and fault recovery. |
| **Jetty group** (jetty_grp) | `struct ubcore_jetty_grp` | LAG of QPs | Aggregates jetties for failover; userspace bond provider implements policy. |

### 1.3 Verbs / operations

| URMA verb | IB verbs | Notes |
|---|---|---|
| `urma_post_send` (opcode WRITE) | `ibv_post_send` with IBV_WR_RDMA_WRITE | One-sided write to remote segment. |
| `urma_post_send` (opcode READ) | `ibv_post_send` with IBV_WR_RDMA_READ | One-sided read from remote segment. |
| `urma_post_send` (opcode SEND) | `ibv_post_send` with IBV_WR_SEND | Two-sided message; lands in remote JFR/RQ. |
| `urma_post_send` (opcode ATOMIC) | IBV_WR_ATOMIC_FETCH_AND_ADD / CMP_AND_SWP | Same primitives. |
| `urma_poll_jfc` | `ibv_poll_cq` | Poll completions. |
| `urma_register_seg` | `ibv_reg_mr` | Pin pages, get key. |
| `urma_alloc_token_id` (separate from registration) | _(none — rkey is bundled with MR)_ | Token rotation. |
| `urma_create_jetty` + `urma_modify_jetty` | `ibv_create_qp` + `ibv_modify_qp` (INIT→RTR→RTS) | Same lifecycle. |
| `urma_import_jetty` | `ibv_open_qp`-ish on remote-known QP | Gets a remote-peer handle. |
| `urma_bind_jetty` | _(implicit in QP modify with destination addr)_ | Pins jetty to a TP. |
| `urma_create_jetty_grp` | _(no direct analogue; LAG is link-level)_ | First-class jetty multipath. |

### 1.4 Kernel implementation labels (not in spec)

| openEuler kernel | InfiniBand kernel | RDMA core | Ethernet kernel |
|---|---|---|---|
| `drivers/ub/urma/ubcore/` | `drivers/infiniband/core/` | rdma-core | _(n/a)_ |
| `drivers/ub/urma/uburma/` (char dev `/dev/ub_uburma*`, ioctl) | `drivers/infiniband/core/uverbs_*` (`/dev/infiniband/uverbs*`) | uverbs | `/dev/net/tun`, AF_PACKET |
| `drivers/ub/urma/hw/udma/` (HiSilicon UDMA HW) | `drivers/infiniband/hw/{mlx5,hns,bnxt_re,...}` | provider drivers | `drivers/net/ethernet/*` |
| `drivers/ub/ubase/` (auxiliary bus for UDMA/UNIC/CDMA) | `drivers/infiniband/hw/.../auxiliary` (per-HCA) | _(n/a)_ | _(n/a)_ |
| `drivers/iommu/hisilicon/{ummu-core, logic_ummu}/` | `drivers/iommu/{intel,amd,arm-smmu*}` | IOMMU core | IOMMU core |
| `drivers/ub/urma/ulp/ipourma/` (IP over URMA) | `drivers/infiniband/ulp/ipoib` (IPoIB) | IPoIB | _(n/a — Ethernet *is* the IP carrier)_ |
| `drivers/ub/urma/uburma/` ioctl `'U'` cmd `1` | uverbs ioctl over `/dev/infiniband/uverbs*` | uverbs ABI | _(n/a)_ |
| `umdk/src/urma/lib/uvs/` ioctl `'V'` cmd `1` | _(out-of-band: opensm)_ | _(n/a)_ | _(n/a — control plane is L2/L3 protocols)_ |
| **AF_SMC** taken over by `umdk/src/usock/ums/kmod/` | _(none — IB has no socket emulation in upstream)_ | _(SMC-R itself is RDMA-based)_ | TCP / UDP / sockets |

### 1.5 Userspace / library labels

| openEuler / UMDK userspace | rdma-core / IB userspace | Generic RDMA | Ethernet / sockets |
|---|---|---|---|
| `liburma` (`umdk/src/urma/lib/urma/`) | `libibverbs` | rdma-core libibverbs | libc sockets |
| `liburma` provider plugin (`udma_u_*.so`) | `libibverbs` provider plugin (`libmlx5.so`, etc.) | rdma-core providers | NIC firmware (no userspace plugin) |
| `liburma` device list via `urma_get_device_list` | `ibv_get_device_list` | rdma-core | `/proc/net/dev` |
| `libuvs` (`umdk/src/urma/lib/uvs/`) | _(n/a — opensm runs separately)_ | librdmacm (different role) | _(n/a)_ |
| `urma_admin` | `ibstat`, `ibstatus`, `ibportstate`, `mlxconfig` (vendor) | `rdma` (iproute2) | `ip`, `ethtool` |
| `urma_perftest` | `ib_send_lat`, `ib_send_bw`, etc. (perftest) | perftest | `iperf`, `netperf` |
| `urma_ping` | `ibping` (deprecated) | _(n/a)_ | `ping` |
| `urpc` (UB-native RPC over jetties) | _(n/a)_ | gRPC, Apache Thrift (transport-agnostic) | gRPC, HTTP |
| `umq` backends (`umq_ub`, `umq_ipc`, `umq_ubmm`) | _(n/a)_ | _(n/a)_ | unix sockets, ZeroMQ |
| `dlock` (distributed locks via URMA atomics) | _(n/a)_ | DLM (kernel), etcd, Redlock | flock / fcntl over NFS |
| `cam` (collectives over URMA) | _(n/a)_ | NCCL, RCCL, oneCCL, Gloo | _(higher-level)_ |
| `usock`/UMS (socket-emulation kernel module) | _(n/a — SMC-R itself maps loosely)_ | SMC-R, sockmap, AF_XDP | TCP, UDP |

---

## Part 2 — Multi-axis comparison

### 2.1 Specification perspective

| Axis | UnifiedBus 2.0 | InfiniBand Architecture | RoCE (RoCEv2) | Ethernet / IP |
|---|---|---|---|---|
| **Standards body** | Huawei-led; openEuler community | InfiniBand Trade Association (IBTA) | IBTA + IETF | IEEE 802.3 + IETF |
| **Release date** | 2025-12-31 (Rev 2.0) | Originally 1999, ongoing | 2014 (v2) | 1980 (Ethernet); 1981 (IP) |
| **Public availability** | Spec PDF (Chinese, partial English preview) | IBTA spec (member-only or paid) | IBTA spec + RFC 8166 ish | IEEE 802.3 paid; IETF RFCs free |
| **Layering** | 6 layers (PHY, data link, network, transport, transaction, function) | 5 layers (PHY, link, network, transport, transactional/upper) | Ethernet PHY/MAC + IB transport from L4 up | 7-layer OSI; in practice PHY/MAC/IP/TCP-UDP |
| **Scope** | Memory access + messaging + RPC + resource management — *unified protocol* | Memory access + messaging — verbs centric | RDMA verbs over Ethernet | Generic packet network |
| **Service modes** | RTP / CTP / UTP transport; ROI / ROT / ROL / UNO transaction service | RC / RD / UC / UD | Inherits IB's transport modes | Connection-oriented (TCP) / connectionless (UDP) |
| **Address types** | EID (16 B) + IP + CNA (16/24-bit compact) | LID (16-bit local) + GID (128-bit global) | MAC + IP + GID | MAC + IP |
| **Multipath** | First-class (TPG, jetty_grp, per-packet/per-flow LB) | LAG, ECMP via SM | ECMP at IP layer; LAG | LAG (802.1AX), ECMP |
| **Lossless guarantee** | Yes — credit-based flow control at data link; reliable transport | Yes — credit-based at link layer (CC-CB) | Requires PFC/ECN to emulate | None (best-effort) |
| **Memory access semantics** | First-class transaction layer | First-class via verbs | Inherited from IB transport | None (host stack synthesizes via TCP) |
| **Hot-plug** | First-class (Appendix G of spec) | Possible via SM | Standard PCIe hot-plug for NIC | Per NIC |
| **Security** | TEE extension, EE_bits, token rotation, partitions, CIP | Per-spec key + partition keys (P_Keys) | Inherits | TLS / IPsec at higher layers |

**Take-away:** UB tries to be one spec where IB historically had to coexist with Ethernet+TCP; instead of choosing, it unifies memory + messaging + RPC at the transaction layer. The closest single spec analogy is IB Architecture, but UB has a more aggressively unified function layer.

### 2.2 Design perspective

| Concept | UB / URMA design choice | IB / RDMA equivalent | What changed |
|---|---|---|---|
| **Identity** | Entity (resource-allocation unit) is decoupled from device port | GID identifies a port | UB lets one device host many independently-managed Entities — multi-tenant by construction. |
| **Endpoint** | Jetty (many-to-many) | RC QP (1:1) or UD (1:N, no reliability) | Many-to-many with reliability is native, not bolted on. |
| **Authorization** | Token (TokenID + TokenValue), separable from segment, rotatable | rkey, bundled with MR | Token rotation without re-registering memory enables stronger revocation. |
| **Transport state** | Per-EID-pair TP, shared across jetties | Per-QP transport state | Reusing TP across jetties saves HW state and enables jetty migration. |
| **Multipath** | First-class TPG; spec-level concept | LAG / ECMP at lower layers | Multipath is an architecture feature, not a workaround. |
| **Cross-fabric reach** | UBoE encapsulation | Routing requires gateway / IPoIB | UBoE explicitly designed to ride IP networks. |
| **RPC** | URPC defined in spec, on transactions | Out-of-band (gRPC, etc.) | First-class: spec defines RPC message format. |
| **Memory mgmt** | UMMU + UBMD; supports cross-supernode coherent shared memory (OBMM) | IOMMU + rkeys; shared-memory across nodes is bolted on (e.g. NVSHMEM is GPU-only) | Distributed shared memory with cache coherence is in scope. |
| **TEE integration** | EE_bits per transaction; spec chapter 11.6 | None (vendor-specific) | Trusted-environment context is wire-visible. |
| **Resource pooling** | Spec-level: compute, memory, storage, interconnect — managed by UBFM | Per-device, per-vendor | Pooling is a first-class spec feature. |
| **Programming models** | Two: load/store synchronous and URMA asynchronous | Verbs only (one) | Spec acknowledges that some workloads want synchronous semantics. |

**Design philosophy comparison:**

- **Ethernet:** "Best-effort packets; let upper layers sort it out." Generality, late binding.
- **IB:** "Reliable transport with HW offload of verbs primitives; assume in-data-center fabric." Performance, narrow scope.
- **RoCE:** "IB's verbs over Ethernet's wire." Compromise; performance depends on PFC tuning.
- **UB:** "One protocol for memory + messaging + RPC + management, designed for SuperPoD-scale AI/HPC, with hardware-software co-design." Vertical integration; assumes Huawei silicon + Linux.

### 2.3 Implementation perspective

| Layer | UMDK / openEuler | rdma-core / mainline Linux | Ethernet / Linux |
|---|---|---|---|
| **In-tree status** | Out of tree as of OLK-6.6 (lives in `drivers/ub/`); not submitted to lkml | In tree (`drivers/infiniband/`) | In tree (`drivers/net/`) |
| **Kernel framework** | `ubcore` (~18k LOC) | `ib_core` + `rdma-core` (~50k LOC) | core net (`net/ipv4`, `net/core`) |
| **Provider drivers** | UDMA (HiSilicon, ~16k LOC); CDMA, UNIC siblings | mlx5 (Mellanox/NVIDIA, ~250k LOC), hns, bnxt_re, qedr, others | i40e, ixgbe, mlx5 ethdev, etc. |
| **Auxiliary bus** | UBASE (UB-specific aux bus) | `auxiliary_bus` upstream | None — direct PCI |
| **IOMMU** | UMMU @ `drivers/iommu/hisilicon` | Standard IOMMU framework | Standard IOMMU framework |
| **Char dev** | `/dev/ub_uburma*` (per-device) | `/dev/infiniband/uverbs*` (per-device) | `/dev/net/tun`, sockets |
| **uAPI ioctl** | Single ioctl `UBURMA_CMD` magic `'U'` cmd `1`; ~101 sub-commands | uverbs ABI: many ioctls + nl variants | socket(2), ioctl(SIOCGIFCONF), netlink |
| **Control plane** | UVS lib with ioctl `'V'` cmd `1`; netlink genl | opensm subnet manager (separate process); user verbs | netlink rtnetlink, ethtool ioctl |
| **Hot path** | mmap'd doorbell + WQ/CQ rings; no syscall | Same pattern; mmap'd doorbell + rings | NAPI poll + DMA descriptors |
| **Userspace lib** | `liburma` + provider `.so` plugin | `libibverbs` + provider `.so` plugin | libc + sockets API |
| **Build distribution** | RPM (`umdk-25.12.0`), CMake fallback | Per-distro packaging (rdma-core) | Bundled with kernel + iproute2/ethtool |
| **License** | GPLv2 (kernel) + Apache 2.0 / dual (userspace TBD) | GPLv2 + dual licensed | GPLv2 + dual licensed |

**Notable implementation parallels:**

- The kernel **provider vtable pattern** (`ubcore_ops` ↔ `ib_device_ops`) is essentially the same — fill ~20 fn ptrs in a struct, call `*_register_device`, get char dev + ioctl plumbing for free.
- Both stacks ride **mmap'd rings + MMIO doorbell** for the data plane. URMA's WQE/CQE shapes are HW-specific (per provider) just like IB.
- The split between **a kernel framework + thin char-dev bridge + provider** is identical: ubcore : uburma : udma ↔ ib_core : uverbs : mlx5.

**Notable implementation differences:**

- URMA is **out-of-tree** in the openEuler kernel and has not been submitted to LKML; IB has been mainline since 2.6.
- URMA introduces a **whole UB sub-bus stack** (`drivers/ub/{ubus,ubase,ubfi,obmm,...}`) — IB sits directly on PCI auxiliary bus.
- URMA's userspace toolkit (UMDK) bundles RPC (URPC), distributed locks (dlock), collectives (CAM), and a socket emulator (UMS) **in the same repo as the verbs library** — IB's userspace ecosystem is a cluster of separate projects (rdma-core, libfabric, NCCL, MPI implementations).
- UMS literally takes over the **AF_SMC** socket family from upstream Linux: `umdk/src/usock/ums/kmod/ums/ums_mod.c:1196` calls `sock_unregister(AF_SMC)` and re-registers its own handlers. This is a pretty aggressive form of integration.
- CAM ships as a **PyTorch operator library** registered via `TORCH_LIBRARY_IMPL(umdk_cam_op_lib, PrivateUse1, ...)` — direct integration with the framework's dispatch system, not a separate collective comm library.

### 2.4 Interface perspective

#### 2.4.1 Userspace API surface

URMA's API in `urma_api.h` — illustrative:

```c
urma_context_t *urma_create_context(urma_device_t *dev, urma_context_cfg_t *cfg);
int urma_register_seg(urma_context_t *ctx, urma_seg_cfg_t *cfg, urma_target_seg_t **out);
int urma_alloc_token_id(urma_context_t *ctx, urma_token_id_t **out);   /* SEPARATE from segment */
int urma_create_jetty(urma_context_t *ctx, urma_jetty_cfg_t *cfg, urma_jetty_t **out);
int urma_post_send(urma_jetty_t *jetty, urma_send_wr_t *wr, urma_send_wr_t **bad_wr);
int urma_poll_jfc(urma_jfc_t *jfc, int max, urma_cr_t *cr_arr);
```

IB verbs in `infiniband/verbs.h`:

```c
struct ibv_context *ibv_open_device(struct ibv_device *device);
struct ibv_mr *ibv_reg_mr(struct ibv_pd *pd, void *addr, size_t length, int access);
/* rkey is part of struct ibv_mr — not separately allocated */
struct ibv_qp *ibv_create_qp(struct ibv_pd *pd, struct ibv_qp_init_attr *attr);
int ibv_post_send(struct ibv_qp *qp, struct ibv_send_wr *wr, struct ibv_send_wr **bad_wr);
int ibv_poll_cq(struct ibv_cq *cq, int num_entries, struct ibv_wc *wc);
```

**Surface diff:**

- URMA has an explicit `urma_alloc_token_id()` call **independent of segment registration** — IB has no such thing.
- URMA's create-jetty bundles JFS/JFR/JFC creation; IB's `ibv_create_qp` accepts pre-existing CQs.
- URMA has `urma_create_jetty_grp` for explicit multipath at the verbs layer; IB does not.
- URMA's TP binding (`urma_bind_jetty`) is its own call; IB folds destination into `ibv_modify_qp` to RTR.

#### 2.4.2 Kernel API surface

```c
/* URMA */
int ubcore_register_device(struct ubcore_device *dev);          /* drivers/ub/urma/ubcore/ubcore_device.c:1223 */
struct ubcore_ops {                                             /* include/ub/urma/ubcore_types.h:2101 */
    int (*query_device_attr)(struct ubcore_device *, struct ubcore_device_attr *);
    int (*alloc_ucontext)(struct ubcore_device *, uint32_t eid_index, struct ubcore_udrv_priv *);
    int (*register_seg)(struct ubcore_device *, struct ubcore_seg_cfg *, ...);
    /* ~20 ops total */
};

/* IB verbs */
int ib_register_device(struct ib_device *device, const char *name);   /* drivers/infiniband/core/device.c */
struct ib_device_ops {                                                /* include/rdma/ib_verbs.h */
    int (*query_device)(struct ib_device *, struct ib_device_attr *, struct ib_udata *);
    struct ib_ucontext *(*alloc_ucontext)(struct ib_device *, struct ib_udata *);
    /* ~80 ops total */
};
```

**Surface diff:**

- IB has more ops (~80 vs ~20) reflecting accumulated 25 years of feature additions (XRC, ODP, atomic types, counters, etc.).
- Both follow the same registration + vtable pattern.
- URMA explicitly accepts an `eid_index` in `alloc_ucontext`, anchoring the context to a specific Entity. IB's `alloc_ucontext` is per-device.

#### 2.4.3 Control-plane interface

| Feature | UB / URMA | IB | Ethernet |
|---|---|---|---|
| Topology mgmt | UVS library + ioctl `'V'`, plus genl | opensm (separate daemon, MAD packets on the wire) | Spanning Tree, dynamic routing protocols |
| Stats / monitoring | `urma_admin show ...` + genl | `perfquery`, ibtool suite, sysfs counters | `ip`, `ethtool`, `tc -s` |
| Reset / hot-plug | UBASE manages reset; ubcore hot-remove machinery | PCI hot-plug + IB device events | Standard NIC hot-plug |

#### 2.4.4 Data-plane interface

All three (URMA, IB verbs, modern AF_XDP) use the same fundamental shape: **mmap'd ring + MMIO doorbell**. The differences are in:

- **WQE format** (per-vendor for both URMA and IB).
- **CQE coalescing** semantics — URMA exposes `jfc_arm_mode` parameter; IB has `IBV_SEND_SIGNALED` per WR.
- **Inline-data handling** — URMA's UDMA supports inline up to 192 B (WRITE_IMM); IB inline limits are per-vendor.
- **Doorbell barrier** — both rely on `wmb()` / `dmb` on aarch64 before MMIO write.

### 2.5 Ecosystem & governance perspective

| Axis | UB / URMA / UMDK | InfiniBand / RDMA |
|---|---|---|
| **Standards body** | Huawei + openEuler community; not yet vendor-neutral | IBTA (multi-vendor, member-driven) |
| **Reference HW** | HiSilicon Kunpeng / Ascend silicon; CloudMatrix | NVIDIA/Mellanox ConnectX, Intel / Cornelis Omni-Path (legacy), HiSilicon HNS |
| **Reference SW** | openEuler kernel + UMDK | Linux upstream + rdma-core |
| **In-tree mainline?** | No (as of 2026-04) — kernel-side lives only in openEuler OLK-6.6 / OLK-5.10 forks | Yes since 2.6 |
| **Workload focus** | AI training/inference at SuperPoD scale; HPC; large-memory pooling | RDMA-aware HPC, AI, financial services, distributed storage |
| **Major workloads built on it** | vllm / SGLang / VeRL via CAM; Huawei CloudMatrix internal apps | NCCL/RCCL, MPI (Open MPI, MPICH), SPDK, NVMe-oF, Lustre |
| **License** | GPLv2 kernel; user lib license TBD per file | GPLv2 + BSD/Apache dual licensing |
| **Hardware ecosystem** | Single vendor (Huawei/HiSilicon) at present | Multi-vendor (NVIDIA, Intel, AMD, Huawei, Marvell, others) |
| **Supported topologies** | nD-FullMesh, Clos, torus, hybrid (per spec §2.1) | Fat-tree, Clos, torus | 

### 2.6 Performance & semantics perspective

Approximate, anecdotal — for orientation only:

| Metric | URMA + UDMA | IB EDR/HDR/NDR (verbs) | RoCEv2 over 100/200 GbE | TCP/IP over 100 GbE |
|---|---|---|---|---|
| Best-case one-way latency | **1.2 µs NPU↔NPU @ 512 B** on CloudMatrix384 (peer-reviewed; [arXiv:2506.12708](https://arxiv.org/abs/2506.12708) §3); 1.0 µs NPU↔CPU. ~1–5 µs aggregated for liburma post-send (UMDK perftest, HW-dependent) | ~0.7–1 µs (NDR ConnectX-7 best case) | ~2–4 µs (with PFC tuning) | ~10–50 µs |
| Per-NPU peer BW (one direction) | **196 GB/s** measured on CloudMatrix384 ([arXiv:2506.12708](https://arxiv.org/abs/2506.12708) §3) | ~50 GB/s (NDR ConnectX-7) | ~25 GB/s (200 GbE) | ~12 GB/s (100 GbE) |
| Aggregated cluster scale (per supernode) | **8,192 NPUs** (Atlas 950) / 384 (CloudMatrix384) | ~1K nodes typical, IB scale-out via routers | Same as IB | DC fabric scale |
| Cost-efficiency vs same-BW Clos | **2.04× cheaper** measured (UB-Mesh paper, [arXiv:2503.20377](https://arxiv.org/abs/2503.20377) §6.4) | Reference baseline | — | — |
| Availability (8K-NPU cluster) | **98.8%** measured (UB-Mesh §6.6); 99.78% with monitoring | 91.6% (Clos baseline, same-paper methodology) | — | — |
| Bandwidth | Up to fabric line rate (200/400 Gb/s class HW) | Up to fabric line rate | Up to NIC line rate | NIC line rate minus TCP overhead |
| Lossless? | Yes (credit-based, link-layer) | Yes (credit-based, link-layer) | Conditional (PFC) | No |
| Memory access | First-class (transaction layer) | First-class (verbs) | First-class | Synthesized via TCP+app |
| Multipath | First-class TPG (load balance per-packet or per-flow) | LAG, ECMP via SM | ECMP | LAG, ECMP |
| Atomics | Native (URMA atomic verb) | Native (atomic verbs) | Native | None |
| Ordering | ROI/ROT/ROL/UNO modes | RC ordered, others looser | Inherited | TCP byte-stream ordered |
| Cache-coherent shared memory | Yes via OBMM (cross-supernode) | Local NUMA only | Local NUMA only | Local NUMA only |

### 2.7 Security model

| Feature | UB / URMA | IB / RDMA | Ethernet / IP |
|---|---|---|---|
| Endpoint authentication | Spec §11.2 Device Authentication | P_Keys + per-vendor | TLS (above L4) |
| Memory access control | TokenID (rotatable) + UBMD | rkey (per MR) | None at L2/L3 |
| Resource isolation | UB partitions + network partitions | P_Keys partitions | VLAN / VXLAN |
| Confidentiality / integrity | CIP (Confidentiality and Integrity Protection) per spec §11.5 | None at link layer (vendor extensions for line-rate crypto exist) | IPsec, MACsec |
| TEE awareness | EE_bits in transactions (§11.6) | None | None |
| Multi-tenancy | Entity-level (each Entity is independent) | per-PD + P_Key | per-VLAN, per-VRF |

---

## Part 3 — Where the analogies break

### 3.1 UB concepts with no clean IB / RDMA / Ethernet analogue

- **Jetty groups (`urma_jetty_grp`).** First-class multipath at the verbs layer, with policy in userspace. IB has LAG at the link layer; nothing equivalent at the verbs layer.
- **Token rotation (separable TokenID).** IB's rkey is a property of the MR; you can't rotate it without re-registering.
- **OBMM (cross-supernode shared memory).** A whole distributed-shared-memory subsystem with NUMA integration and reclaim hooks. IB doesn't try to do this.
- **CAM as a PyTorch operator library.** Verbs ecosystems integrate with frameworks via NCCL/RCCL/oneCCL (separate libs). CAM ships as a PyTorch op set directly.
- **UVS as a library + ioctl.** opensm is a separate daemon that talks MADs on the wire; UVS is a library mediating local ioctls — the spec analogue (UBFM) is logically centralized but UVS is per-host.
- **EE_bits per transaction.** Per-transaction TEE security context. No IB / RDMA / Ethernet equivalent.
- **ROI/ROT/ROL/UNO.** Four named ordering modes. IB/RDMA mostly leaves this implicit; TCP is byte-stream-ordered; UDP is unordered.

### 3.2 Ethernet / IB / RDMA concepts with no UB analogue (or different)

- **MAC address.** UB uses EID + CNA (Compact Network Address); no MAC at the UB link layer per se.
- **VLAN.** UB uses partitions (network + UB), not VLAN tags.
- **STP / loop avoidance.** UB topology is defined and managed; no spanning-tree dynamic loop avoidance.
- **Broadcast domain.** UB doesn't have broadcast at the transaction layer (multicast support is TBD per spec preview).
- **Subnet Manager (SM) MAD packets.** UVS uses ioctls + genl, not on-wire management packets to a manager.
- **Verb-level extensions like XRC, ODP, MR-on-demand-paging.** Not surfaced in URMA's API yet; OBMM handles cross-node memory differently.
- **AF_XDP, sockmap, kernel bypass at socket layer for Ethernet.** UB has no socket layer to bypass — applications use URMA verbs directly. (UMS is socket *emulation*, going the other direction.)

### 3.3 Things people often get wrong

1. **"UDMA is UB's verbs."** No. URMA is UB's verbs. UDMA is HiSilicon's hardware DMA engine that implements URMA on UB hardware.
2. **"UMDK is the spec."** No. UMDK is openEuler's userspace toolkit — URMA is in the spec; UMDK is not.
3. **"UVS = UBFM."** Not exactly. UBFM is a spec-level logical fabric manager; UVS is a userspace library wrapping ioctls on a single host.
4. **"UB is RoCEv3."** No. UB is its own protocol stack; UBoE is the UB-over-Ethernet encapsulation, but UB itself is not Ethernet-derived.
5. **"URMA is just IB verbs renamed."** Mostly true at the API level, but several semantic differences are deliberate (token rotation, jetty groups, ordering modes, UMMU permission model).
6. **"UVS is a daemon like opensm."** **No** — UVS is a userspace **library** (`libuvs`); applications link it and call ioctls themselves. Topology state lives in the kernel (in `ubcore` and `ubagg`). Verified 2026-04-25 — see [`umdk_code_followups.md`](umdk_code_followups.md) §Q8.
7. **"UMS is its own AF_UB socket family."** No — UMS **takes over `AF_SMC`** from the upstream Linux SMC-R subsystem; it `sock_unregister(AF_SMC)` and re-registers its own handlers. CONFIG_SMC must be present for the fallback path. See [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md) §3.
8. **"CloudMatrix384 numbers above are theoretical."** No — they're peer-reviewed measurements on DeepSeek-R1 with EP320; see [`umdk_web_research_addenda.md`](umdk_web_research_addenda.md) §5 and [arXiv:2506.12708](https://arxiv.org/abs/2506.12708).

---

## Part 4 — Cross-reference

For deeper material on any axis here:

- **Spec-side definitions** → [`umdk_spec_survey.md`](umdk_spec_survey.md).
- **Code-side architecture and workflows** → [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md).
- **Repo layout snapshot** → [`umdk_repo_layout.md`](umdk_repo_layout.md).
- **UnifiedBus 2.0 preview spec** → `~/Documents/docs/unifiedbus/UB-Base-Specification-2.0-preview-en.pdf`.
- **InfiniBand Architecture Specification** (paid) → IBTA.
- **IEEE 802.3** (paid) → IEEE.
- **rdma-core source** → `https://github.com/linux-rdma/rdma-core`.
