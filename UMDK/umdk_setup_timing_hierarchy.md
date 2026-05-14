# URMA `urma_perftest` setup-phase timing breakdown — big-to-small hierarchy

**Purpose:** a single reference that explains where every millisecond of `urma_perftest send_lat` setup goes, decomposed from top-level (userspace ioctls) down to the leaf functions actually doing work.

**Scope:** single-process baseline only. For dilation behavior under N-concurrent load, see `umdk_link_setup_timing.md` §10.

**Source of numbers:** UMDK GitHub issues #1/#2/#3, JinDou's depth-3 ftrace traces from 2026-05-11. Cross-checked against kernel source at `/Volumes/KernelDev/kernel/drivers/ub/urma/`.

## 1. TL;DR — the three top-level operations

A single `urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0` setup phase issues **three back-to-back userspace ioctls** to the URMA kernel:

| Order | Userspace API | Kernel entry | Baseline cost |
| ---: | --- | --- | ---: |
| [1] | `urma_import_seg` | `ubcore_import_seg` | **5.7 ms** |
| [2] | `urma_import_jetty` (vjetty) | `ubcore_import_jetty` Phase A | **5.3 ms** |
| [3] | `urma_import_jetty` (pjetty) | `ubcore_import_jetty` Phase B | **6.0 ms** |
| | | **Total setup** | **~17 ms** |

These run **sequentially** — each ioctl blocks userspace until its return; the next one starts only after the previous completes. The cost numbers below are NOT additive across leaves; they are the time the **parent function** spent, which includes time inside each child.

## 2. Why three operations, why two `import_jetty`

- `import_seg` registers a remote memory segment. Needed once per peer for one-sided RDMA (READ/WRITE) but `urma_perftest` always does it (framework convenience, not a semantic requirement of SEND tests).
- `import_jetty` is called **twice** because the bondp library (in `--single_path` mode) registers:
  - First a **vjetty** (virtual jetty — metadata-only, no transport pair created) → kernel takes the `connect_exchange_udata_when_import_jetty` path
  - Then a **pjetty** (physical jetty — actual TP programmed in firmware) → kernel takes the `import_jetty_compat` path

The two kernel paths are structurally different even though they share the userspace API name. We refer to them as **Phase A** (metadata only) and **Phase B** (TP-aware) throughout this doc.

For the bondp v/p decomposition and its `active_count` math, see [`umdk_virtual_vs_physical_handles.md`](./umdk_virtual_vs_physical_handles.md).

## 3. Level 1 — the call tree, with timings

```
[1] ubcore_import_seg                                          5.7 ms
    │
    ├── ubcore_connect_exchange_udata_when_import_seg
    │   ├── send_seg_info_req                                  5.1 ms  ← CPU-bound
    │   │   └── ubmad_post_send
    │   │       ├── ubcore_get_main_primary_eid                4.9 ms  ← EID linear scan
    │   │       │   └── find_primary_eid_in_ues (×117k)
    │   │       └── ubmad_do_post_send                         ~2-7 µs (actual MAD enqueue)
    │   │
    │   └── ubcore_session_wait                                0.87 ms ← MAD reply wait
    │
    └── ubagg_import_seg                                       ~16 µs  (userspace pointer fixup)


[2] ubcore_import_jetty Phase A                                5.3 ms
    │
    └── ubcore_connect_exchange_udata_when_import_jetty
        ├── send_jetty_info_req                                4.8 ms  ← SAME CPU-bound path
        │   └── ubmad_post_send
        │       └── ubcore_get_main_primary_eid                4.9 ms  ← scan AGAIN
        │
        └── ubcore_session_wait                                0.45 ms ← shorter wait than [1]


[3] ubcore_import_jetty Phase B                                6.0 ms
    │
    └── ubcore_import_jetty_compat
        ├── ubcore_get_tp_list                                 177 µs
        │   └── udma_get_tp_list                               175 µs  ← firmware ctrlq cmd
        │
        ├── ubcore_exchange_tp_info                            ~5.7 ms ← ANOTHER MAD round-trip
        │   └── ubmad_post_send
        │       ├── ubcore_get_main_primary_eid                4.9 ms  ← scan AGAIN
        │       └── ubcore_session_wait                        ~0.5-0.9 ms
        │
        └── ubcore_import_jetty_ex                             234 µs
            └── udma_active_tp                                 ~170 µs ← firmware ctrlq cmd
```

## 4. Level 2 — three categories of work

Every function in the tree falls into one of three categories:

| Category | What it does | Per-call cost |
| --- | --- | --- |
| **CPU-bound EID scan** (`ubcore_get_main_primary_eid`) | Linear scan over the UE table to find primary EID for a peer | 4.9 ms / call |
| **MAD round-trip wait** (`ubcore_session_wait`) | Block waiting for peer to respond to a control-plane MAD | 0.45 - 0.87 ms / wait |
| **Firmware ctrlq cmd** (`udma_get_tp_list`, `udma_active_tp`) | Submit a command to the local NIC firmware and wait for ACK | 170 - 175 µs / cmd |

Per-operation budget (the 17 ms total wall-clock = 5.7 + 5.3 + 6.0):

| Operation | Wall-clock | CPU scan inside | MAD wait inside | Firmware ctrlq inside |
| --- | ---: | ---: | ---: | ---: |
| `[1] import_seg` | 5.7 ms | 4.9 ms (×1) | 0.87 ms (×1) | — |
| `[2] import_jetty A` | 5.3 ms | 4.9 ms (×1) | 0.45 ms (×1) | — |
| `[3] import_jetty B` | 6.0 ms | 4.9 ms (×1, inside `exchange_tp_info`) | ~0.7 ms (×1) | 0.35 ms (×2) |

**The 4.9 ms EID scan dominates each operation's wall-clock.** Each operation ≈ one EID scan + one MAD wait + small overheads, because every `ubmad_post_send` (the control-plane MAD send primitive) calls `ubcore_get_main_primary_eid` once before queueing the MAD.

Total client-side wall-clock = 3 operations × (~1 EID scan + ~1 MAD wait) = ~3 × 5-6 ms = ~17 ms. Additional EID scans happen on the SERVER side as part of the symmetric handshake (server runs its own `import_jetty` to register the client) — those don't count toward this client's wall-clock but do affect the bot at #4436759654's measured 39 ms "8 × scan" total CPU budget across both sides.

## 5. Level 3 — the EID scan in detail

`ubcore_get_main_primary_eid` is the load-bearing CPU cost. Each invocation:

1. Walks the `ubcore_topo_map` UE table (no hash, no cache)
2. For each UE entry (~256 of them per topo node × ~22 nodes ≈ 5,600), iterates and calls `find_primary_eid_in_ues`
3. `find_primary_eid_in_ues` itself walks all UE entries (~117,000 `is_eid_match` calls per `ubcore_get_main_primary_eid` invocation)
4. Returns the matching primary EID for the destination peer

The 117,000 number was measured directly by JinDou via depth-5 ftrace (issue #2, 2026-05-11 08:49):

```
941,429 is_eid_match calls / 8 ubcore_get_main_primary_eid calls per setup = 117,679 per call
```

Each `is_eid_match` is a static-memory comparison (no synchronization, no atomic), so the cost is pure scalar CPU work. At ~42 ns per `is_eid_match`, the 117k iterations come out to ~4.9 ms.

**This function is NOT load-sensitive** — under 100-concurrent runs it remains ~4.9 ms (issue #2, 2026-05-13). It scales with the **topology size** (UE count), not with the number of concurrent client processes.

For the topo-table source-verification (lock-free, no synchronization), see `umdk_link_setup_timing.md` §10.25.

## 6. Level 3 — the MAD round-trip wait in detail

`ubcore_session_wait` is the userspace-blocking wait for a MAD reply. The flow:

1. Local kernel calls `ubmad_post_send` to enqueue an outgoing control-plane MAD (request)
2. MAD travels over the wire to the peer's `ubmad_recv_work_handler`
3. Peer's kworker dispatches and processes the request (server-side work)
4. Peer sends a reply MAD back
5. Local kernel's `ubmad_recv_work_handler` matches the reply to the original session
6. Local userspace `ubcore_session_wait` unblocks

The 0.45 - 0.87 ms baseline cost is dominated by **network RTT + server-side processing**. Under single-process load, the server-side processing is microseconds (kworker dispatch + a few firmware ctrlq cmds), so most of the wait is wire latency.

**Under N-concurrent load, this is where the dilation lives** — the server-side firmware ctrlq becomes a serialization point, and the wait grows from ~0.5 ms to ~600 ms - 3.36 s at N=100. See `umdk_link_setup_timing.md` §10.27-§10.30.

## 7. Level 3 — the firmware ctrlq cmd in detail

`udma_get_tp_list` and `udma_active_tp` are calls into the UDMA driver that submit commands to the NIC firmware via the **control-plane queue (ctrlq)**. Each:

1. Kworker builds a ctrlq command descriptor
2. Submits it to the firmware via memory-mapped doorbell
3. Firmware processes the command (typically microseconds in the uncontended case)
4. Firmware writes a completion to the ctrlq response area
5. Kworker polls/IRQs the completion and returns

Baseline cost ~175 µs per cmd. The firmware ctrlq ring is actually **depth 2048** per `drivers/ub/ubase/ubase_ctrlq.c:257` (`UBASE_CTRLQ_QUEUE_DEFAULT`), but each calling kworker is synchronous (`ubase_ctrlq_send_msg()` blocks until firmware ACK), so per-kworker concurrency is 1. Under single-process load this is irrelevant — the one cmd in flight completes immediately. Earlier sections of this doc and `umdk_link_setup_timing.md` §10.30 used a "depth-1 firmware ctrlq" framing; that framing is wrong and is corrected in §10.31 — the effective serialization is at the kworker-pool layer, not the firmware queue.

**Under N-concurrent load, this is the SECONDARY bottleneck** — when 100 processes' MADs all reach the server simultaneously, the server's firmware ctrlq queues them serially. One observed `udma_get_tp_list` call on the server side took **33.5 ms** under N=100 burst (issue #2, 2026-05-14). See `umdk_link_setup_timing.md` §10.30.

## 8. Cross-cutting view — the 8 EID scans

`ubcore_get_main_primary_eid` is called **8 times per setup**, one inside each `ubmad_post_send` in:

| Operation | EID scans inside |
| --- | ---: |
| `[1] import_seg` | 1 (in `send_seg_info_req`) |
| `[2] import_jetty Phase A` | 1 (in `send_jetty_info_req`) |
| `[3] import_jetty Phase B` `exchange_tp_info` | 1 (in `send_jetty_info_req`-equivalent) |
| Auth handshake + CM state-machine MADs (server-side and client-side) | 5 additional |
| | **Total: 8** |

8 × 4.9 ms = **39 ms of pure CPU per setup** — but recall this is spread across the 17 ms wall-clock because (a) some scans run on the server side and don't count toward the client's wall-clock, and (b) some scans overlap with the corresponding `ubcore_session_wait` MAD-reply latency. The 39 ms is the **total CPU work**, not the wall-clock contribution.

For the fix-path implication ("cache the EID lookup per `<peer_eid, trans_mode>` tuple"), see `umdk_link_setup_timing.md` §10.29-§10.30 and the codex `udma-tp-cache` patch analysis.

## 9. Where time lives at each granularity — summary table

| Granularity | Component | Baseline | Load-sensitive? |
| --- | --- | ---: | :---: |
| **Operation** | `ubcore_import_seg` | 5.7 ms | ✓ (→42 ms at N=100) |
| | `ubcore_import_jetty` Phase A | 5.3 ms | ✓ (→108 ms at N=100) |
| | `ubcore_import_jetty` Phase B | 6.0 ms | ✓ (→554 ms at N=100) |
| **Sub-operation** | `connect_exchange_udata_when_*` | ~5 ms each | ✓ |
| | `import_jetty_compat` | ~6 ms | ✓ |
| | `exchange_tp_info` | ~5.7 ms | ✓ (largest dilation) |
| **Sub-call** | `send_seg_info_req` / `send_jetty_info_req` | ~5 ms each | ✗ (CPU-bound) |
| | `ubcore_get_tp_list` | 177 µs | ✗ (single process) |
| | `ubcore_import_jetty_ex` | 234 µs | ✗ |
| **Leaf** | `ubcore_get_main_primary_eid` (EID scan) | 4.9 ms | ✗ (topo-dependent) |
| | `ubcore_session_wait` (MAD reply) | 0.45 - 0.87 ms | ✓ (huge dilation) |
| | `udma_get_tp_list` (firmware ctrlq) | 175 µs | △ (tail outliers ~33 ms) |
| | `udma_active_tp` (firmware ctrlq) | ~170 µs | △ |
| | `find_primary_eid_in_ues` (inner loop) | 0.6 ms | ✗ |
| | `is_eid_match` (per-EID compare) | ~42 ns | ✗ |

**Pattern**: load-sensitive items are exactly the ones involving network/firmware (MAD waits, ctrlq cmds). CPU-bound items (EID scan, scalar compares) are not load-sensitive.

## 10. What the timing tree means for fix paths

Three orthogonal directions to reduce setup wall-clock:

| Optimization target | What it removes | Estimated wall-clock saving |
| --- | --- | --- |
| **Cache EID lookup** (replace `find_primary_eid_in_ues` with hash) | 4.9 ms × 8 = 39 ms CPU per setup | ~85% reduction at single-process baseline (17 ms → ~3 ms) |
| **Cache `udma_get_tp_list` result** (codex `udma-tp-cache` patch) | Firmware ctrlq cmd, mostly meaningful under load | ~3% at baseline, but **huge under load** (eliminates 33 ms tail × N) |
| **Client-side startup stagger** (break thundering-herd alignment) | Reduces queue depth at server firmware ctrlq | Only helps under load; no effect on baseline |

For full mechanism analysis and recommended priorities, see `umdk_link_setup_timing.md` §10.29-§10.30.

## 11. Under N-concurrent load — same tree, where the time goes instead

The single-process call tree above remains structurally correct under load — `urma_perftest` still issues the same three sequential ioctls, each containing the same nested calls. What changes is **where the time accumulates**.

The numbers below come from JinDou's depth-3 trace on **one specific observed process** in a 100-concurrent run (UMDK issue #2, 2026-05-13 02:59). This is a **tail observation** — the median process at N=100 saw 108-554 ms for `import_jetty`, while this observed process saw ~3.4 s. The distribution across all 100 procs hasn't been characterized yet (see umdk_link_setup_timing.md §10.27 G1 gap).

### 11.1 Call tree under N=100 (one observed process, tail case)

```
[1] ubcore_import_seg                                          615 ms     (108× baseline)
    │
    ├── ubcore_connect_exchange_udata_when_import_seg
    │   ├── send_seg_info_req                                  5.13 ms    ← UNCHANGED
    │   │   └── ubmad_post_send
    │   │       └── ubcore_get_main_primary_eid                4.9 ms     ← UNCHANGED
    │   │
    │   └── ubcore_session_wait                                610 ms     ← DILATED 700×
    │
    └── ubagg_import_seg                                       ~16 µs     ← UNCHANGED

[2] ubcore_import_jetty Phase A                                3,369 ms   (635× baseline)
    │
    └── ubcore_connect_exchange_udata_when_import_jetty
        ├── send_jetty_info_req                                4.80 ms    ← UNCHANGED
        │   └── ubmad_post_send
        │       └── ubcore_get_main_primary_eid                4.9 ms     ← UNCHANGED
        │
        └── ubcore_session_wait                                3,364 ms   ← DILATED 7500×

[3] ubcore_import_jetty Phase B                                3,363 ms   (561× baseline)
    │
    └── ubcore_import_jetty_compat
        ├── ubcore_get_tp_list                                 133 µs     ← UNCHANGED (this obs)
        │   └── udma_get_tp_list                               ~130 µs    ← UNCHANGED (this obs)
        │
        ├── ubcore_exchange_tp_info                            3,363 ms   ← DILATED 585×
        │   └── ubmad_post_send
        │       ├── ubcore_get_main_primary_eid                4.9 ms     ← UNCHANGED
        │       └── ubcore_session_wait                        ~3,363 ms  ← DILATED enormously
        │
        └── ubcore_import_jetty_ex                             284 µs     ← UNCHANGED
            └── udma_active_tp                                 ~170 µs    ← UNCHANGED
```

### 11.2 What dilates and why

The pattern is uniform across all three operations:

| Component | Behavior under load | Why |
| --- | --- | --- |
| **CPU-bound EID scan** | UNCHANGED at 4.9 ms / call | Pure local CPU, lock-free static table. N concurrent processes on N+ CPUs run in parallel. See §10.25 source verification. |
| **Firmware ctrlq cmd** (this obs) | UNCHANGED at ~175 µs | This particular process hit the firmware ctrlq when it was free. **Other processes saw 10-33 ms outliers** — JinDou's server-side trace captured one at 33.5 ms. See §10.30. |
| **MAD round-trip wait** | DILATED 700-7500× | Server-side firmware ctrlq serializes 100 simultaneous client requests. This process waited for ~100 other firmware cmds to drain. |

### 11.3 Where the 7500× dilation comes from

Math:

- Server's NIC firmware ctrlq has depth 2048 hardware capacity, but effective per-kworker concurrency is 1 (synchronous wait in `ubase_ctrlq_send_msg`). With ~1 dominant kworker on server (per §10.27.A), the effective queue depth becomes 1.
- 100 client processes all sending MADs to server at the same moment → 100 firmware cmds queued
- Per-cmd firmware processing time: ~33.5 ms (worst-observed individual cmd from server-side trace)
- 100 cmds × 33.5 ms = 3.35 seconds (arithmetic check)
- The 100th client at the back of the queue waits the full 3.35 s in this model

The 3.36 s `ubcore_session_wait` in the observed process matches this arithmetic. **Caveat (§10.31 correction)**: the match is a coincidence, not mechanism proof. The 33.5 ms outlier is rare (2-7 % of cmds), so 100 cmds at the *outlier* value isn't realistic — most cmds finish in ~200 µs. The real mechanism that produces the 3.36 s wait involves **multi-stage server-side processing across ~13.5 MAD round-trips per setup** queued through ~1 effective kworker. See §10.31.D for the corrected math.

Different processes see different waits depending on their queue position:
- Process at front: ~33 ms wait
- Median process: ~50 × 33 ms ≈ 1.7 s wait (but observed median import_jetty is 108-554 ms, suggesting non-uniform distribution)
- Process at back (this observation): ~3.36 s wait

The "median import_jetty = 554 ms but tail = 3.36 s" pattern indicates **thundering-herd alignment + firmware ctrlq serialization** — most clients arrive in tight clumps and clear quickly; a few stragglers see the full queue depth. See §10.27.C.

### 11.4 Why `import_jetty A` dilates more than `import_seg` for this observed process

| | `import_seg` | `import_jetty A` |
| --- | ---: | ---: |
| MAD wait baseline | 0.87 ms | 0.45 ms |
| MAD wait under N=100 (this obs) | 610 ms | 3,364 ms |
| Dilation factor | **700×** | **7500×** |

Both involve **one** server-side firmware ctrlq cmd (so per-cmd cost is identical). The 5.5× difference in MAD wait between the two operations comes from **queue position at the time of arrival**, not from the operation itself.

Mechanism: by the time this observed process completed `import_seg` and started `import_jetty A`, the **other 99 procs had also finished their `import_seg`** and were arriving at the server's firmware ctrlq for `import_jetty A`'s MAD almost simultaneously. The thundering-herd alignment tightens at each phase boundary because the prior phase synchronized them. This observed process had bad luck and ended up near the back of the second wave. See §10.27.C "thundering-herd alignment" framing.

### 11.5 Per-phase time distribution under load (this obs)

| Phase | CPU bound (EID scan) | MAD wait | Firmware ctrlq |
| --- | ---: | ---: | ---: |
| `[1] import_seg` | 5.1 ms (1×) | 610 ms (700×) | — |
| `[2] import_jetty A` | 4.8 ms (1×) | 3,364 ms (7500×) | — |
| `[3] import_jetty B` | ~5.0 ms (1×) inside `exchange_tp_info` | ~3,363 ms (enormous) | ~350 µs (1×, this obs) |

The dilation is **entirely** in the MAD wait. CPU-bound work is exactly the same as baseline.

### 11.6 Fix-path implications

Knowing the dilation is in MAD wait (which itself is driven by server-side firmware ctrlq serialization) maps fix paths cleanly:

| Fix | Removes | Effect |
| --- | --- | --- |
| **Cache `udma_get_tp_list` result** (codex `udma-tp-cache` patch) | Eliminates firmware ctrlq cmds for warm `<peer_eid, trans_mode>` tuples | Under 100-proc with shared target peer: 1 firmware-miss + 99 cache-hits → wall-clock drops from ~3.36 s to ~50 ms (>99 % improvement). See §10.30.D. |
| **Client-side startup stagger** | Eliminates thundering-herd alignment; spreads firmware ctrlq cmds over time | Server processes one-at-a-time always, but no proc waits behind 99 others. Predicted slowdown from 91× to <10×. See §10.27.G Test B. |
| **EID scan cache** (`find_primary_eid_in_ues` → hash) | Eliminates 4.9 ms × 8 CPU work per setup | Only meaningful at baseline; under load the EID scan is overlapped with MAD wait so wall-clock savings are <5 ms regardless of N. |

The first two (codex patch + stagger) are orthogonal and could be combined for compound benefit. The EID-scan optimization is **lowest-priority under load** because the CPU work isn't on the load-sensitive critical path.

## 12. References

| Source | What it has |
| --- | --- |
| `umdk_link_setup_timing.md` §1-§9 | Pre-2026-05-11 framework, MAD/CM/firmware integrated call chain |
| `umdk_link_setup_timing.md` §10.18-§10.30 | The investigation timeline that produced these numbers, plus load-behavior analysis |
| `umdk_urma_perftest_call_chain.md` | Inverse view — given a kernel function name in a trace, where does it sit in the call chain |
| `umdk_urma_jetty_kernel_call_trace.md` | Kernel internals for `ubcore_create_jetty` / `ubcore_import_jetty` / `ubcore_connect_vtp` |
| `umdk_virtual_vs_physical_handles.md` | The bondp v/p decomposition that produces the two `import_jetty` calls |
| UMDK issue #2 trace, 2026-05-11 07:13-08:49 | Direct measurements at depth 3-5 |
| UMDK issue #2, 2026-05-12 10:21 | Single-observed-process under N=100 contention (depth 1) |
| UMDK issue #2, 2026-05-13 02:59 | Single-observed-process under N=100 contention (depth 3) — tail outlier showing 3.36 s `session_wait` |
