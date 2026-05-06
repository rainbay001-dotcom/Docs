# URMA per-connection memory cost: RC+RTP, RM+RTP, RM+CTP

_Last updated: 2026-05-06._

How much memory does a single URMA "connection" actually consume, broken down by component, with concrete numbers from the umdk + kernel-ub source. Why HW SRAM is usually the binding constraint before host memory. Why CTP gets you ~250–400× memory savings at IP-stack scale.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer
- [`umdk_urma_rm_vs_rc_summary.md`](umdk_urma_rm_vs_rc_summary.md) — RM vs RC cheat-sheet
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — link setup + CTP design

---

## 1. The components

A URMA "connection" — really a TP and the jetty/queue state behind it — isn't one allocation. It's a stack across user-space, kernel, and HW.

### 1.1 Queue buffers (the dominant cost)

User-space holds the SQ/RQ buffers HW reads via doorbell.

`umdk/src/urma/hw/udma/udma_u_jfs.h:57`:
```c
struct udma_jfs_wqebb {
    uint32_t value[16];   /* 64 bytes per Work-Queue-Element Basic Block */
};
#define MAX_SQE_BB_NUM 4   /* up to 4 BBs per WQE */
```

So:
- Minimum WQE: **64 B** (1 BB) — small SEND.
- Maximum WQE: **256 B** (4 BBs) — RDMA-Write/Read with many SGEs + inline.
- Typical: 64–128 B per WQE for RPC traffic.

For `jfs_depth = D`:
- SQ buffer: D × 64 to 256 B.
- RQ buffer (one if jetty has a receive queue): roughly D × 64 B.
- SGE buffers (outboard scatter-gather): D × max_sge × 16 B.

**Concrete sample at common settings** (`D = 256`, `max_sge = 8`):
- SQ buffer: 256 × 128 ≈ **32 KB**.
- RQ buffer: 256 × 64 ≈ **16 KB**.
- SGE buffers: 256 × 8 × 16 ≈ **32 KB**.
- **Subtotal: ~80 KB.**

**Range across realistic deployments:**
- Lightweight (D=64): ~16–32 KB.
- Default (D=256): ~80 KB.
- High-throughput (D=4096, max_sge=16): ~1.5 MB.

### 1.2 User-space control structs

| Struct | Approx size |
| --- | --- |
| `struct urma_jetty_t` | ~200 B |
| `struct udma_u_jetty` (provider extension) | ~500 B |
| `struct urma_target_jetty_t` | ~120 B |
| `struct udma_u_target_jetty` | ~120 B |
| Doorbell page (mmap'd) | 4 KB |

**Subtotal: ~5 KB per connection.**

### 1.3 Kernel state

`struct ubcore_tp` (`kernel/include/ub/urma/ubcore_types.h`) carries ~50 fields — PSN counters, retry params, mutex, completion, hash node, ref_cnt — and clocks in at **~300 B** with alignment.

Plus per-connection:
- `struct ubcore_jetty` — **~250 B** + embedded `ubcore_jetty_cfg` (~120 B).
- `struct ubcore_tjetty` — **~80 B**.
- `struct ubcore_tp_ext` (~24 B + driver-private len). UDMA's tp_ext typically holds ~64–128 B of HW context pointers.
- Hash-table entries (`tp_node` hash, jetty hash): ~32 B per entry.
- Embedded `struct mutex` and `struct completion`: ~80 B total.

**Subtotal: ~1–2 KB per connection in kernel.**

### 1.4 HW state (opaque, not in host memory)

Inside the NPU/MUE SRAM (not host RAM):
- TPID context: per-pair sequence numbers, retransmit timers, credit state, congestion-control state.
- Estimated **~256 B – 1 KB per TPID** in HW SRAM.

This is **opaque to host profiling** — you can't see it in `slabinfo` or `pmap`. But it's the real scarce resource on UDMA: the device has a fixed TPID table size, and exhausting it produces "no more TPs available" errors regardless of host memory headroom. Capabilities like `udma_dev->caps.seid.max_cnt` set the ceiling.

### 1.5 Doorbell records

- Doorbell page: 4 KB mmap'd.
- DB record (one cache line): 64 B.

Often shared across jettys per context, so amortized — but counted once per connection if accounting strictly.

## 2. Per-connection totals by mode

Reference settings: `jfs_depth=256, jfr_depth=256, max_sge=8`.

### 2.1 RC + RTP

| Component | Size |
| --- | --- |
| User-space queue buffers (SQ + RQ + SGE) | ~80 KB |
| User-space control structs | ~5 KB |
| Kernel state (ubcore_tp + jetty + tjetty + tp_ext) | ~1–2 KB |
| HW TPID context (SRAM, opaque) | ~0.5–1 KB |
| **Total per connection (host memory)** | **~85–90 KB** |

Scales O(N) with peer count. Each new RC peer = a new dedicated TP + a new jetty + new queue buffers.

### 2.2 RM + RTP

Per-peer cost is similar to RC+RTP — dedicated TP per `(local_eid, peer_eid)`. The savings vs RC come from the option to have **one local jetty serve multiple peers**, sharing queue buffers.

If `tp_reuse=1` (perftest pattern, `perftest_resources.c:1050`) reuses one TP across many local jettys to the same peer, you save the per-jetty TP allocation. But peer-count scaling is still O(N) on TPs.

| Component | Size |
| --- | --- |
| User-space queue buffers (per local jetty, one or few) | ~80 KB × small constant |
| User-space target_jetty per peer | ~240 B per peer |
| Kernel ubcore_tp per peer | ~300 B per peer |
| HW TPID context per peer | ~0.5–1 KB per peer |
| **Per-peer marginal cost** | **~1.5–2 KB host + ~1 KB HW SRAM** |

For N peers with RM+RTP, the queue-buffer cost is a one-time ~80 KB; the TP/target_jetty cost is **~2 KB × N**. Better than RC+RTP at scale because queue buffers don't multiply.

### 2.3 RM + CTP

One TP serves *all* destinations. Per-peer state collapses to just the target_jetty handle.

| Component | Size |
| --- | --- |
| User-space queue buffers (per local jetty) | ~80 KB × constant |
| User-space target_jetty per peer | ~240 B per peer |
| Kernel ubcore_tp (one CTP, total) | ~300 B (not per-peer) |
| HW TPID context (one CTP, total) | ~0.5–1 KB (not per-peer) |
| **Per-peer marginal cost** | **~240 B host, ~0 HW SRAM** |

This is why CTP is qualitatively different — peer count doesn't multiply HW state.

## 3. Scaling at peer count

| Peers (N) | RC+RTP host | RM+RTP host | RM+CTP host | RC+RTP HW SRAM | RM+CTP HW SRAM |
| --- | --- | --- | --- | --- | --- |
| 10 | ~900 KB | ~100 KB | ~82 KB | ~10 KB | ~1 KB |
| 100 | ~9 MB | ~280 KB | ~85 KB | ~100 KB | ~1 KB |
| 1,000 | ~90 MB | ~2 MB | ~325 KB | ~1 MB | ~1 KB |
| 10,000 | impractical | ~20 MB host + likely HW exhaust | ~2.5 MB | exhaust | ~1 KB |

The exhaustion point on RC+RTP is **HW SRAM**, not host memory — typically you run out of TPID table entries first. The exact ceiling depends on `udma_dev->caps.seid.max_cnt` (read via `urma_query_device`).

CTP scales O(1) in HW SRAM, so the wall is much further out — often whatever fits in the local jetty's queue + the target_jetty hash table.

## 4. Why HW SRAM matters more than host memory

For most production UDMA deployments:

- Host memory is plentiful — even 100 MB for connection state is acceptable.
- HW TPID table is fixed-size, often a few thousand entries on a single device.
- Per-peer state (RTP) consumes one TPID per peer.

So a host with 64 GB RAM but only ~4K TPIDs in HW will hit the **TPID wall around ~4K peers** with RTP, and only host-memory-bound at ~700K peers — orders of magnitude later. The HW SRAM is the constraint.

This is exactly why IPoURMA prefers CTP, and falls back to UM+UTP rather than RM+RTP when CTP isn't available (`ipourma_ub.c:115`):
```c
tjetty_cfg->tp_type    = ctp_en ? UBCORE_CTP    : UBCORE_UTP;
tjetty_cfg->trans_mode = ctp_en ? UBCORE_TP_RM  : UBCORE_TP_UM;
```
RTP is not in the picture — its TPID-per-peer cost is unaffordable at IP-network scale (potentially ~10K-100K peers).

## 5. Practical implications

- **Queue depth tuning matters at scale.** Halving `jfs_depth` from 256 to 128 saves ~40 KB per connection — meaningful at hundreds of connections. But it caps in-flight WRs proportionally.
- **`max_sge` × `D` is the SGE buffer cost.** If you're not using scatter-gather, set `max_sge=1`; recovers ~28 KB at default depth.
- **`max_inline_data`** pushes WQE size from 64 B to 256 B per WQE if used heavily. ~3-4× SQ memory.
- **`share_tp` (RM only)** — multiple jettys to the same peer reuse one TP, reducing RM+RTP marginal cost by ~80 KB per additional jetty. Used by perftest's `tp_reuse=1`.
- **`udma_query_device` returns the HW caps** (`max_jetty`, `max_tp_cnt`, `max_jfs_depth`) — query these to size your application correctly. Don't assume.

## 6. CTP scaling: the headline result

For 1000 peers, same workload settings:

| Mode | Total host memory | Total HW SRAM |
| --- | --- | --- |
| RC + RTP | ~85 MB (or HW SRAM exhaust) | ~1 MB |
| RM + RTP | ~2 MB | ~1 MB (often exhausts) |
| **RM + CTP** | **~325 KB** | **~1 KB** |

That's the **~250–400× memory difference at scale**, plus the qualitative HW SRAM scaling collapse from O(N) to O(1).

## 7. Caveats on these numbers

- All host-memory numbers are derived from struct definitions in source — not measured. Actual sizes vary with kernel config (e.g., LOCKDEP, SLUB allocator overhead) and may include slab fragmentation overhead of 1.5–2× on small allocations.
- HW SRAM numbers (per-TPID context) are *estimates* based on what reliability state typically requires. Exact size is HW-dependent and usually undocumented; treat ±2× as the uncertainty band.
- Queue depths shown are common defaults but not enforced — applications can tune `jfs_depth` and `jfr_depth` within the device caps.
- Bonded devices (two FEs aggregated) carry per-FE state for some fields; numbers above assume a single non-bonded path.
- Multipath / `jetty_grp` adds per-path state — typically ~1 KB per additional path per connection.

## 8. References

- `umdk/src/urma/hw/udma/udma_u_jfs.h:57` — `struct udma_jfs_wqebb` (64 B/BB), `MAX_SQE_BB_NUM = 4`.
- `umdk/src/urma/hw/udma/udma_u_ctl.c` — depth + max_sge validation against device caps.
- `kernel/include/ub/urma/ubcore_types.h` — `struct ubcore_tp` (~50 fields, ~300 B), `struct ubcore_jetty`, `struct ubcore_tjetty`, `struct ubcore_jetty_cfg`, `struct ubcore_tp_ext`.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c:109-115` — IPoURMA's CTP-or-UTP fallback (no RTP option).
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:794` — `ctp_en` device-cap derivation.

For the full design rationale on why CTP exists and what it solves, see [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md).
