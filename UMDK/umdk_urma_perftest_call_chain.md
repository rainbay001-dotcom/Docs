# urma_perftest send_lat — call chain and time breakdown

_Last updated: 2026-05-12._

Structured walkthrough of `urma_perftest send_lat`'s userland → kernel call chain, synthesized from the round-by-round investigation in [`rainbay001-dotcom/UMDK#2`](https://github.com/rainbay001-dotcom/UMDK/issues/2) (36 comments across 2026-05-11 / 2026-05-12) plus on-host source verification.

Companions:
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) §10.21 / §10.22 — same material from a different cut (trace-leaf → stage). This doc is the **forward** view (stage → kernel ops).
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer for jetty/jfs/jfr/seg objects.
- [`umdk_virtual_vs_physical_handles.md`](umdk_virtual_vs_physical_handles.md) — vtp/tp + vjetty/pjetty pairs.

Source citations:
- Userspace: `~/Documents/Repo/ub-stack/umdk/tools/perftest/` (`urma_perftest.c`, `perftest_parameters.c`, `perftest_resources.c`)
- Kernel ubcore: `/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/`
- All trace numbers below come from JinDou1210's ftrace captures on worker1 (issue #2).

---

## 1. TL;DR

`urma_perftest send_lat` is a 7-stage userland program. Setup (stages 4 + 7) crosses the user/kernel boundary ~9 times per side and takes **~25 ms wall-clock**. Steady-state ping-pong (stage 6) is **~3.47 μs per round-trip** and has **zero kernel transitions** — userspace polls a mapped CQ.

**The dominant setup cost is not network RTT.** It's a CPU-bound linear scan in `ubcore_get_main_primary_eid` (`drivers/ub/urma/ubcore/ubcore_topo_info.c:452`), fired ~8× per setup at ~4.9 ms each from inside `ubmad_post_send` (`ubcm/ubmad_datapath.c:817`) *before any packet leaves the wire*. ~117,000 `is_eid_match` calls per invocation, no hash, no cache. Total CPU-scan budget: **~39 ms** per first-time setup.

This conclusion overturns four earlier rounds of "97% network RTT" / "97% control-plane" / "4.8 ms in ubcore_net_send_to" framings. The wire portion (`ubmad_do_post_send`) is only 2–7 μs per send.

---

## 2. The 7 top-level stages

Source: `urma_perftest.c` `main()` → `tools/perftest/` resources path. Numbering follows the thread (comment #1, refined #6 / #7 / #9).

```
urma_perftest send_lat (client)
│
├── 1. parse_args / check_local_cfg          [userland; no kernel calls]
│
├── 2. establish_connection                  [TCP socket setup]
│       — used only for metadata sync, not for data
│
├── 3. check_remote_cfg                      [TCP exchange of config]
│
├── 4. create_duplex_ctx                     ★ heavy stage
│       4a  init_device              — open URMA device
│       4b  create_duplex_jettys     — JFC × 4 + JFR × 2 + JETTY × 2
│       4c  register_mem             — register local buffer (seg × 2)
│       4d  import_seg_for_duplex    — import remote seg  (× 2)
│       4e  exchange_connection_info — TCP exchange jetty IDs
│       4f  connect_jetty            — ubcore_import_jetty × 2 (two code paths)
│
├── 5. prepare_test                          [rearm JFC + TCP barrier with server]
│
├── 6. run_send_lat_duplex                   ★ data plane — kernel bypass
│       — ping-pong loop × n=5
│       — post_send via mapped doorbell, poll JFC via mapped CQ
│       — NO syscalls, NO ftrace visibility, ~3.47 μs/iter
│
└── 7. destroy_ctx                           ★ heavy teardown
        7a  unimport remote jetty/seg
        7b  delete local jetty/jfr/jfc
        7c  close TCP connection
```

Stage 5 visible ftrace activity (`ubcore_rearm_jfc`) runs in **kworker context** as part of ubcore's internal CM protocol — it is not `urma_pe`'s call path. Same caveat applies to any `ubcore_post_jetty_*` / `ubcore_poll_jfc` seen during stage 6 (issue #2 comment #11).

---

## 3. Stage 4 deep dive — create_duplex_ctx

This is the only stage where setup latency actually accumulates. Sub-stages are observed empirically (ftrace `max_graph_depth=1`, `tracing_thresh=0`).

### 3.1 Sub-stage → kernel function mapping

| Sub-stage | Kernel function(s) | Count | Per-call duration | Path |
| --------- | ------------------ | ----- | ----------------- | ---- |
| 4a init_device | `ubcore_create_context` | 1 | not directly traceable | local |
| 4b create_jettys | `ubcore_create_jfc` | 4 | 0.5 / 1.3 / 46.7 / 108.9 μs | local |
| 4b create_jettys | `ubcore_create_jfr` | 2 | 2.7 / 64.4 μs | local |
| 4b create_jettys | `ubcore_create_jetty` | 2 | 2.1 / 47.3 μs | local |
| 4c register_mem | `ubcore_register_seg` | 2 | 1.6 / 4.0 μs | local |
| 4d import_seg | `ubcore_import_seg` | 1 | **~5.9 ms** | CM-send |
| 4f connect_jetty | `ubcore_import_jetty` | 2 | **~5.3 / 6.0 ms** | CM-send (×2) |

Local creates total ~280 μs. The wall-clock damage is the three CM-send paths.

The Count column reflects **bondp library fan-out** — see §3.2 for why one userspace call produces multiple kernel events.

### 3.2 Why the counts: bondp `dev_num` vs `active_count` fan-out

`urma_perftest -d bonding_dev_0` runs against a bonded device, so every URMA call goes through the bondp library (`~/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/`). Bondp applies one of **two fan-out rules** depending on the operation type. See [`umdk_virtual_vs_physical_handles.md`](umdk_virtual_vs_physical_handles.md) for the vjetty/pjetty primer.

| Operation type | Fan-out rule | Why |
| -------------- | ------------ | --- |
| Local resource create (jfc / jfr / jetty / seg-register) | × `dev_num` | Create the resource on **every** slave NIC so the bonding can switch active path without re-allocating. |
| Remote resource import (`import_jetty`) | **v-side (1) + p-side (× `active_count`)** | The v-side does peer-metadata exchange once for the virtual handle; the p-side programs hardware VTP per currently active slave. |
| Remote seg import (`import_seg`) | v-side only (1) | A remote seg is just an address handle, not a hardware resource — no per-slave state needed. |

`dev_num` and `active_count` are both fields of `bondp_comp` (`bondp_types.h:209`):

| Field | Set at | This config (`--single_path`) | Source |
| ----- | ------ | ----------------------------- | ------ |
| `dev_num` | bonding device setup | **2** (all members) | `bondp_create_jfc:276`, `bondp_create_jetty:1175` loops |
| `active_count` | path selection | **1** (one active path) | `bondp_import_pjetty:1442` loop |

### 3.3 The two `ubcore_import_jetty` calls — v-side phase + p-side phase

`bondp_import_jetty` (`bondp_api.c:1486`) is structured as two distinct phases. With `active_count=1`, each fires exactly one kernel `ubcore_import_jetty`, hence the trace shows two with **different child trees**:

```
urma_import_jetty(v_ctx, ...)                       [one userspace call]
  └─ bondp_import_jetty
     ├─ bondp_import_vjetty  ────────────────────  PHASE A (v-side)
     │   └─ urma_cmd_import_jetty(v_ctx, ...)
     │       └─ kernel: ubcore_import_jetty #1
     │
     └─ bondp_import_pjetty  ────────────────────  PHASE B (p-side, × active_count)
         for n in 0..active_count-1:
           └─ urma_import_jetty(p_ctxs[idx], ...)
               └─ kernel: ubcore_import_jetty #2
```

The two kernel events take fundamentally different code paths inside ubcore because they are doing different work — not because they are duplicates.

**Phase A (v-side)** — `ubcore_connect_exchange_udata_when_import_jetty`. Exchanges peer metadata (jetty ID, segment info) for the virtual tjetty. Does not touch hardware TP yet.
```
ubcore_import_jetty #1 (Phase A, v-side)        # 5333.59 μs
└─ ubcore_connect_exchange_udata_when_import_jetty   # 5309.06 μs
   ├─ ubcore_find_physical_device                     2.08 μs
   ├─ create_session_for_exchange_udata.constprop.0   2.54 μs
   ├─ send_jetty_info_req                       # 4846.51 μs  ★
   │  ├─ ubcore_get_primary_eid_by_agg_eid       13.70 μs
   │  └─ ubcore_net_send_to                     # 4832.18 μs
   │     └─ ubcore_ubcm_send_to → ubmad_ubc_send → ubmad_post_send
   │        ├─ ubcore_get_main_primary_eid       4.9 ms  ★★★ CPU scan
   │        └─ ubmad_do_post_send                7.16 μs  ← actual wire send
   └─ ubcore_session_wait                          452.90 μs  ← real wait for peer reply
└─ ubagg_import_jetty                                23.06 μs
```

**Phase B (p-side)** — `ubcore_import_jetty_compat`. TP-aware path: fetches the TP list, exchanges TP info with the peer, programs the hardware VTP. One invocation per active slave NIC.

```
ubcore_import_jetty #2 (Phase B, p-side)        # 6104.82 μs
└─ ubcore_import_jetty_compat
   ├─ ubcore_get_tp_list                          176.74 μs
   │  └─ udma_get_tp_list                         175.17 μs
   ├─ ubcore_exchange_tp_info                   # 5749.47 μs  ★
   │  ├─ create_session_for_create_connection     1.47 μs
   │  ├─ send_create_req                        # 4889.15 μs
   │  │  └─ ubmad_post_send                       (same ~4.9 ms shape)
   │  └─ ubcore_session_wait                      854.17 μs
   └─ ubcore_import_jetty_ex                      174.03 μs
      └─ ubcore_connect_vtp_ctrlplane             171.66 μs
```

Under a real multipath config (`active_count=2`), this trace would show **three** `ubcore_import_jetty` events: 1 v-side (Phase A) + 2 p-side (Phase B per slave). The v-side phase always fires first because Phase B needs the metadata it gathers.

`ubcore_import_seg` (stage 4d) is v-side only — count is 1, not 2 — because a remote seg is just an address handle. Its internal cost still follows the same pattern as Phase A: `send_seg_info_req` → `ubmad_post_send` → ~4.9 ms CPU scan + tiny wire send, then `ubcore_session_wait` ~870 μs for peer ack.

### 3.4 Concurrent kworker activity (not on critical path)

While stage 4 is blocked in `ubcore_session_wait`, kworker threads run ubcore's *internal* control plane:

| Function (kworker) | Per-call | Note |
| ------------------ | -------- | ---- |
| `udma_ctrlq_get_tpid_list` | 193.77 μs | TP id allocation |
| `ubcore_get_tp_list` (kworker) | 200.44 μs | server-side replied TP list |
| `udma_active_tp` | 191.18 μs | activate TP in hardware |
| `udma_ctrlq_set_active_tp_ex` | 190.22 μs | command-queue write |
| `ubcore_active_tp` (kworker) | 192.83 μs | wrapper |

These run *in parallel* with `urma_pe`'s session-wait sleep. Even if `udma_ctrlq_get_tpid_list` were 0, the wall-clock wouldn't shrink — `session_wait` is waiting for the peer's reply, not for the local kworker (issue #2 comment #5).

---

## 4. Where time actually goes — the round-by-round correction

The investigation took **5 rounds** to find the bottleneck. Each round drilled one more level into ftrace and found the prior round's "dominant function" was 90% subroutines.

| Round | Claim | Refuted by |
| ----- | ----- | ---------- |
| 1 | Only 2 trace lines because `tracing_thresh=1000` filtered everything | Setup advice; not a bottleneck claim |
| 2 | "**97.5% network RTT**" — `send_jetty_info_req` 4.83 ms + `session_wait` 6.01 ms | Round 3 |
| 3 | Inside `send_jetty_info_req`, `ubcore_net_send_to` independently is 4.83 ms (90.6%) — "low-level transport ACK" | Round 4 |
| 4 | Inside `ubcore_net_send_to`, `ubmad_post_send` is 4.91 ms; inside that **`ubcore_get_main_primary_eid` is 4.90 ms (99.8%)**; `ubmad_do_post_send` is 7 μs. "Synchronous CM-daemon query?" | Round 5 |
| 5 | **`ubcore_get_main_primary_eid` is pure CPU**: 117k `is_eid_match` calls, ~42 ns each, scanning the global UE topology table | — (correct) |

### 4.1 The bottom — what `ubcore_get_main_primary_eid` actually does

Per invocation (depth=6 trace, comment #20):

```
ubcore_get_main_primary_eid                       (1 call per top-level send)
└─ ubcore_get_primary_eid                          (1:1 wrapper)
   ├─ find_primary_eid_in_ues × ~5,605             (loop over agg_devs)
   │  └─ is_eid_match × 21                          (1 agg_eid + 2 UEs × 10 EIDs)
   ├─ ubcore_get_primary_eid_array                  0.24 μs (tail)
   └─ ubcore_get_min_eid                            0.22 μs (tail)
```

Aggregated across one perftest setup:

```
ubcore_get_main_primary_eid :         8 calls
ubcore_get_primary_eid      :         8 calls    (1:1)
find_primary_eid_in_ues     :    44,837 calls    (~5,605/outer)
is_eid_match                :   941,429 calls    (~117,678/outer, ~21/find)
```

Per-call cost (untraced, comment #21): **~4.9 ms**. Per-call cost when ftrace also instruments the inner loop: **~38 ms** (7.8× inflation from 117k tracer entries). 4900 μs ÷ 117,678 calls ≈ **42 ns/call** — matches "16-byte memcmp + linked-list pointer chase."

### 4.2 The 8 invocations per setup

`ubcore_get_main_primary_eid` is called by `ubmad_post_send` *before every MAD send*. The 8 MAD sends per setup are roughly:

| # | Origin | What it sends |
| - | ------ | ------------- |
| 1 | `ubcore_import_seg` → `send_seg_info_req` | tell peer about my seg |
| 2 | `ubcore_import_jetty #1` → `send_jetty_info_req` | tell peer about my jetty |
| 3 | `ubcore_import_jetty #2` → `send_create_req` | request TP create |
| 4–8 | teardown + ack paths | unimport_jetty's MAD send and friends |

Total CPU-scan budget per setup: **8 × 4.9 ms ≈ 39 ms**. Plus the rest of `ubmad_post_send` (~10 μs each) and the actual wire (~2–7 μs each via `ubmad_do_post_send`).

### 4.3 Why this looked like "network RTT" for so long

`ubcore_net_send_to` is the function name. Its body looks like:

```c
ubcore_net_send_to(...)
  → ubcore_ubcm_send_to
    → ubmad_ubc_send
      → ubmad_post_send
        → ubcore_get_main_primary_eid     // 4.9 ms CPU
        → ubmad_do_post_send               // 7 μs wire
```

At depth 3 only the outer name is visible, and the outer name *implies* a network operation. Bot's confidence ran ahead of evidence quality for four rounds (rounds 2–4 all claimed "network RTT" or "control-plane fabric"). Round 5's depth-6 trace exposed the inner scan loop and broke the spell.

---

## 5. Time breakdown — canonical numbers

### 5.1 Stage 4 (`create_duplex_ctx`) wall-clock

| Sub-stage | Wall-clock | Share | Cost type |
| --------- | ---------- | ----- | --------- |
| 4a–4c local creates | ~279 μs | 1.6% | local CPU |
| 4d `import_seg` (1 call) | 5.91 ms | 33% | **~99% CPU scan, ~1% wire + peer-wait** |
| 4f `import_jetty` #1 | 5.33 ms | 30% | **~91% CPU scan, ~9% peer-wait** |
| 4f `import_jetty` #2 | 6.10 ms | 34% | **~80% CPU scan + ~14% peer-wait + ~3% TP-list** |
| context-switch / scheduling | ~660 μs | 3.7% | — |
| **Stage 4 total** | **~18.0 ms** | 100% | |

(Numbers from comment #9; stage attributions revised per round-5 round-up.)

### 5.2 Stage 7 (`destroy_ctx`) wall-clock

| Sub-stage | Wall-clock | Cost type |
| --------- | ---------- | --------- |
| `ubcore_unimport_jetty` #1 | 5.13 ms | ~CPU scan again (same primary-eid path) |
| `ubcore_unimport_jetty` #2 | 0.45 μs | local |
| `ubcore_unimport_seg` | 0.54 μs | local |
| `ubcore_delete_jfr` #2 | 1.14 ms | HW resource recycle |
| `ubcore_delete_jetty` #2 | 287.6 μs | HW resource recycle |
| `ubcore_delete_jfc` × 4 | 0.67 + 95.5 + 0.37 + 93.1 μs | HW batch reclaim |
| `ubcore_delete_jfr` #1 | 1.35 μs | local |
| `ubcore_unregister_seg` × 2 | 1.17 + 2.56 μs | local |
| **Stage 7 total** | **~7.15 ms** | |

### 5.3 Stage 6 (`run_send_lat_duplex`) per-round-trip

Direct measurement from urma_perftest's own user-mode timer (`-n 5 -s 2`):

| Run | t_min | t_avg | t_median | t_max | t_99.999% |
| --- | ----- | ----- | -------- | ----- | --------- |
| issue body (server) | 3.45 | 3.52 | 3.52 | 3.61 | 3.61 |
| issue body (worker1) | 3.47 | 3.47 | 3.47 | 3.70 | 3.70 |
| comment #8 | 2.96 | 3.04 | 3.03 | 3.28 | 3.28 |
| comment #14 | 3.05 | 3.14 | 3.14 | 3.37 | 3.37 |

All units μs. Zero ftrace events on `urma_pe` during this window — data path uses mmap'd doorbell + mmap'd CQ, no syscall.

### 5.4 The 223 ms gap between stages 4 and 7

Wall-clock between end of stage 4 and start of stage 7 in JinDou's traces is ~223 ms, but this is **not** the test duration. It's:

- TCP barrier sync (`prepare_test()`)
- Waiting for server to finish its own ~10 ms import_jetty
- Bilateral ready signaling
- 5 round-trips × ~3.5 μs ≈ 18 μs (negligible)

ftrace cannot see most of this — it's userspace TCP poll loops.

### 5.5 Setup totals

| | Cold (first run after module load) | Warm (subsequent) |
| - | ---------------------------------- | ----------------- |
| `ubcore_import_jetty` × 2 | 43.2 + 87.5 ms (issue body) | 5.3 + 6.1 ms |
| Stage 4 total | ~135 ms | ~18 ms |
| Cause of gap | ubcm peer-session cache fill, EID resolution cache fill, fabric-route cache fill | — |

Note: the 8 × 4.9 ms = 39 ms CPU scan happens *every* invocation (cold or warm). The cold/warm gap is on top of that, in the parts of CM setup that **do** get cached across runs (ubcm session, EID→phys map, fabric route). The scan is what nothing caches.

---

## 6. Stage 6 — why the data path is invisible

UB transport's data plane is **kernel bypass**:

- `urma_post_send` writes a doorbell to mapped MMIO; hardware picks up the WQE.
- `urma_poll_jfc` reads the CQ from mapped memory; no syscall.
- Inline payloads ≤ inline-size (configured) avoid even a buffer fetch.

The kernel `ubcore_post_jetty_send_wr` / `ubcore_post_jetty_recv_wr` / `ubcore_poll_jfc` symbols **do exist in ftrace** during a perftest run — but they belong to **kworker threads** (`kworker-...`), running ubcore's *internal* CM protocol concurrently. The `urma_pe-...` PID never enters them (issue #2 comment #11).

This is why the 3.47 μs steady-state number has no ftrace breakdown — there's literally nothing to trace from the user thread's side.

---

## 7. ftrace methodology — observations from the thread

### 7.1 Filter settings that matter

- `tracing_thresh > 0` filters by duration. `1000` (= 1 ms) hides everything fast; **set to 0 for flow analysis** and let `funcgraph-duration` colorize prefixes (`*` >100 ms, `#` >1 ms, `!` >100 μs, `+` >10 μs).
- `max_graph_depth` controls recursion. Depth 1 sees only outer ubcore symbols; depth 3 reveals `ubcore_session_wait` / `ubcore_net_send_to`; depth 5 reaches `ubmad_post_send`; **depth 6 is required to see `find_primary_eid_in_ues` and `is_eid_match`** (and at that depth the act of tracing inflates the duration ~7.8×).
- `set_graph_function` filters traced root functions. Always include `ubcore_create_*`, `ubcore_register_seg`, `ubcore_import_*`, `ubcore_unimport_*`, `ubcore_delete_*` for stage-4/7 coverage.
- `funcgraph-proc=1` adds PID/comm to each line — essential for distinguishing `urma_pe-*` (critical path) from `kworker-*` (concurrent).

### 7.2 The 7.8× ftrace overhead trap

`ubcore_get_main_primary_eid` measured at **4.9 ms** untraced internally vs **38 ms** when ftrace also instruments the 117k inner `is_eid_match` calls. Each tracer-emitted entry is ~330 ns. Lesson: **never trust absolute timings of a function whose hot inner loop is itself being traced.** Use depth limits to keep the inner loop out of the trace, then time the outer function once with the inner loop opaque.

### 7.3 Round-of-prompts the bot got wrong

Each round's wrong answer followed from depth-truncated traces. The pattern is generic: when ftrace's depth window cuts mid-call-chain, the deepest-visible function gets blamed for everything below it. Round 2 blamed `send_jetty_info_req` (4.83 ms); Round 3 blamed `ubcore_net_send_to` (4.83 ms); Round 4 blamed `ubmad_post_send` (4.91 ms). Each was right that *that function* was slow, and wrong about *why*. Only depth 6 reaches the leaf.

---

## 8. Quick reference

### 8.1 File locations

| Concept | File | Notes |
| ------- | ---- | ----- |
| `urma_perftest` main / stages | `tools/perftest/urma_perftest.c` | userland |
| `create_duplex_ctx`, `connect_jetty_default` | `tools/perftest/perftest_resources.c:1512` | userland; setup loop |
| `-J N` gate (only allowed for `send_bw`) | `tools/perftest/perftest_parameters.c:677` | use `send_bw` for serial scale tests |
| `unimport_seg` (error silently swallowed) | `tools/perftest/perftest_resources.c:1231-1240` | leaks kernel handles on failure |
| `bondp_create_jetty` (× `dev_num` fan-out) | `lib/urma/bond/bondp_api.c:1175` | resource-creation rule |
| `bondp_create_jfc` (× `dev_num` fan-out) | `lib/urma/bond/bondp_api.c:268` | resource-creation rule |
| `bondp_import_jetty` (v-side + p-side phases) | `lib/urma/bond/bondp_api.c:1486` | structural source of the 2 `ubcore_import_jetty` events |
| `bondp_import_pjetty` (loop × `active_count`) | `lib/urma/bond/bondp_api.c:1442` | p-side fan-out site |
| `bondp_comp.dev_num` / `.active_count` | `lib/urma/bond/bondp_types.h:209` | the two fan-out parameters |
| `ubmad_post_send` (MAD send origin) | `drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c:817` | calls `ubcore_get_main_primary_eid` *before* wire send |
| `ubcore_get_main_primary_eid` (the scan) | `drivers/ub/urma/ubcore/ubcore_topo_info.c:452` | O(N) over `topo_map`, no hash |
| `find_primary_eid_in_ues` | (inside `ubcore_get_primary_eid`) | per-agg_dev loop body |
| `is_eid_match` | (leaf) | 16-byte EID compare, ~42 ns |
| `topo_map` constants `MAX_NODE_NUM=64`, `DEV_NUM=256`, `IODIE_NUM=2`, `PORT_NUM=9` | `topo_info.h:28/52/61` | drives the 5,605 / 21 counts |

### 8.2 Cost summary

| Phase | Cost | Why |
| ----- | ---- | --- |
| Setup (stages 4 + 7), warm | ~25 ms wall-clock | dominated by 8 × `ubcore_get_main_primary_eid` ≈ 39 ms CPU (parallelized across the 4 sends + cleanup) |
| Setup (stages 4 + 7), cold first run | ~135 + 7 ms | + ubcm session establish + EID/route cache fill |
| Steady state (stage 6) | ~3.47 μs per round-trip | mmap doorbell + mmap CQ, no syscall, no ftrace |
| Peer waits (`ubcore_session_wait`) | ~450 μs – 870 μs each | real network RTT, but a minor share of setup |
| Actual wire (`ubmad_do_post_send`) | 2–7 μs per MAD | negligible |

### 8.3 The "obvious" fix that wouldn't help

The `codex/udma-tp-cache` patch caches at the **udma** layer (`drivers/ub/urma/hw/udma/`). The bottleneck is at the **ubcore** layer (`drivers/ub/urma/ubcore/ubcore_topo_info.c`) — one level up. A udma cache cannot short-circuit an ubcore scan. The real fix would be either:

- A hash index on `topo_map`'s agg_dev table keyed by EID prefix, or
- A primary-EID cache keyed by destination EID populated on first lookup.

### 8.4 Open experiments (issue #2 thread end)

- Serial `-J N` scale test (`send_bw -J N -n 1 -s 2`) to see if per-link cost grows with N (would indicate O(N²) compounding from topo-table growth).
- Concurrent N-process test to see if the topo scan holds a lock that serializes under contention.
- Coarse-grained first round before drilling: depth=1 on full `ubcore_*` set, because per-stage bottleneck may shift away from `ubcore_get_main_primary_eid` under concurrency (could be JFC/JFR/JETTY-pool global locks).
- Cold-vs-warm `modprobe -r/-i` protocol to disambiguate "what's sticky" from "what the patch would add."
- Read `git diff master..codex/udma-tp-cache -- drivers/ub/urma/` to definitively confirm wrong-layer hypothesis.
