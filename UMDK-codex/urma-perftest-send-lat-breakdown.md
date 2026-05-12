# `urma_perftest send_lat` Breakdown and Test Findings

Last updated: 2026-05-12

## Scope

This note summarizes GitHub issue
[`rainbay001-dotcom/UMDK#2`](https://github.com/rainbay001-dotcom/UMDK/issues/2)
and checks the findings against the local source trees:

| Tree | Local path | Used for |
| --- | --- | --- |
| UMDK | `/Volumes/KernelDev/umdk` | `urma_perftest` user-space flow and URMA API calls |
| Kernel | `/Volumes/KernelDev/kernel` | `ubcore`, `uburma`, UDMA, UBASE, and UB MAD control-plane paths |

The target command was mainly:

```bash
urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0
urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0 -S <server_ip>
```

The user-visible perftest result for 2-byte `send_lat` was consistently around
3 us per ping-pong operation, for example:

| Run | t_min | t_median | t_avg | t_max |
| --- | ---: | ---: | ---: | ---: |
| Initial issue run | 3.45 us | 3.52 us | 3.52 us | 3.61 us |
| Later coarse trace run | 2.96 us | 3.03 us | 3.04 us | 3.28 us |

The ftrace work below measures setup and teardown around the test. It does not
directly measure the steady-state user-space datapath, because URMA send/poll
mostly uses mapped queues and doorbells after setup.

## Top-Level Perftest Flow

The executable entry point is:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/urma_perftest.c:158
```

The main function runs these high-level stages:

```text
1. perftest_parse_args()
2. check_local_cfg()
3. establish_connection()
4. check_remote_cfg()
5. create_ctx()
6. prepare_test()
7. run_test()
8. destroy_ctx()
9. close_connection()
```

For the issue's `send_lat` command, `run_test()` dispatches to
`run_send_lat()`:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/urma_perftest.c:25
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/urma_perftest.c:46
```

The default UB run uses duplex Jetty mode. `create_ctx()` therefore selects
`create_duplex_ctx()`:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:2198
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:2263
```

The important setup sequence is:

```text
create_duplex_ctx()
  -> init_device()
  -> create_duplex_jettys()
  -> register_mem()
  -> exchange_connection_info()
  -> import_seg_for_duplex()
  -> connect_jetty()
  -> create_run_ctx()
```

The measured datapath loop is in `run_send_lat_duplex()`:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_run_test.c:1501
```

It pre-posts receive WQEs, synchronizes with the peer, then repeats:

```text
poll receive JFC
post more receive WQEs when needed
record timestamp
post Jetty send WR
poll send JFC when completions are requested
```

Source anchors:

```text
urma_poll_jfc()            perftest_run_test.c:1560
urma_post_jetty_recv_wr()  perftest_run_test.c:1490
urma_post_jetty_send_wr()  perftest_run_test.c:1624
```

## Why The First Trace Only Showed Two `ubcore_import_jetty` Calls

The first ftrace configuration used:

```bash
echo 1000 > tracing_thresh
echo 1 > max_graph_depth
```

That records only calls above 1000 us and shows only top-level entries. Most
local setup calls are in the low microsecond to hundreds-of-microseconds range,
so they were filtered out.

The two visible entries were both `ubcore_import_jetty` because:

- `connect_jetty_default()` calls `urma_import_jetty()` once per Jetty. With
  `jetty_num=1`, that gives one import.
- The UB/bonding compat path performs another import-related step for TP/VTP
  setup, so a normal duplex setup can expose two `ubcore_import_jetty` top-level
  calls.
- These imports happen during resource creation only. They are not repeated for
  each `-n 5` datapath iteration.

Relevant UMDK source:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1510
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1540
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1773
```

## Coarse Baseline Breakdown

After removing the 1 ms threshold and tracing the coarse setup/teardown
functions, the useful baseline looked like this:

| Stage | Function group | Calls | Observed time |
| --- | --- | ---: | ---: |
| Resource create | `ubcore_create_jfc` | 4 | 108.86 / 1.25 / 46.73 / 0.48 us |
| Resource create | `ubcore_create_jfr` | 2 | 64.37 / 2.68 us |
| Resource create | `ubcore_create_jetty` | 2 | 47.31 / 2.06 us |
| Memory registration | `ubcore_register_seg` | 2 | 3.98 / 1.59 us |
| Peer segment import | `ubcore_import_seg` | 1 | 5681.07 us |
| Peer Jetty import | `ubcore_import_jetty` | 2 | 5267.03 / 6044.77 us |

Wall-clock resource creation was about 17.93 ms:

```text
local resource create/register:  ~0.28 ms
import_seg:                       ~5.68 ms
import_jetty x2:                 ~11.31 ms
scheduling/gaps:                  ~0.66 ms
```

Cleanup was about 7.15 ms, dominated by the first `ubcore_unimport_jetty`
call:

| Cleanup operation | Observed time |
| --- | ---: |
| `ubcore_unimport_jetty` #1 | 5128.81 us |
| `ubcore_unimport_jetty` #2 | 0.45 us |
| `ubcore_delete_jfr` #2 | 1135.85 us |
| `ubcore_delete_jetty` #2 | 287.63 us |
| `ubcore_delete_jfc` total | 189.7 us |

The initial interpretation was that most of the setup time was network RTT.
The later `ubcore_net_send_to()` and `ubcore_get_main_primary_eid()` traces
corrected that: a large part of the apparent "send" time is local CPU topology
lookup before the control message is posted.

## `ubcore_import_seg` Detail

User-space calls:

```text
import_seg_for_duplex()
  -> urma_import_seg()
```

Source:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1304
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1336
```

Kernel entry:

```text
ubcore_import_seg()
  -> ubcore_connect_exchange_udata_when_import_seg()
  -> dev->ops->import_seg()
```

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_segment.c:253
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_segment.c:265
```

Measured hot-state breakdown:

| Sub-step | Observed time | Meaning |
| --- | ---: | --- |
| `send_seg_info_req` | 4990.26 us | Sends segment metadata request |
| `ubcore_session_wait` | 872.50 us | Waits for peer response |
| `ubcore_find_physical_device` | 3.04 us | Local physical-device lookup |
| `create_session_for_exchange_udata` | 2.29 us | Local session allocation |
| Local segment import/record | 33.48 us | Local ubagg/driver bookkeeping |
| Total | ~5909 us | Mostly control-plane send path plus response wait |

The send helper is:

```text
send_seg_info_req()
  -> ubcore_get_primary_eid_by_agg_eid()
  -> ubcore_net_send_to()
```

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:330
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:348
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:422
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:460
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:466
```

## `ubcore_import_jetty` Detail

User-space calls:

```text
connect_jetty()
  -> connect_jetty_default()
  -> urma_import_jetty()
```

Source:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1510
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1540
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1773
```

Kernel entry:

```text
ubcore_import_jetty()
```

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c:2476
```

### First `ubcore_import_jetty`

The first hot-state import was about 5.33 ms:

```text
ubcore_import_jetty
  -> ubcore_connect_exchange_udata_when_import_jetty
       -> send_jetty_info_req
            -> ubcore_net_send_to
       -> ubcore_session_wait
```

Measured breakdown:

| Sub-step | Observed time |
| --- | ---: |
| `ubcore_connect_exchange_udata_when_import_jetty` | 5309.06 us |
| `send_jetty_info_req` | 4846.51 us |
| `ubcore_net_send_to` inside send | 4832.18 us |
| `ubcore_session_wait` | 452.90 us |
| Local ubagg bookkeeping | 23.06 us |

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c:2491
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:376
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:394
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:497
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:535
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_bonding.c:541
```

Cold runs can be much slower. One early run had the first import around
10.87 ms because peer/server-side state was not warm yet.

### Second `ubcore_import_jetty`

The second hot-state import was about 6.10 ms and used the compat TP path:

```text
ubcore_import_jetty
  -> ubcore_import_jetty_compat
       -> ubcore_get_tp_list
       -> ubcore_exchange_tp_info
            -> send_create_req
            -> ubcore_session_wait
       -> ubcore_import_jetty_ex
            -> ubcore_connect_vtp_ctrlplane
```

Measured breakdown:

| Sub-step | Observed time | Meaning |
| --- | ---: | --- |
| `ubcore_get_tp_list` | 176.74 us | Local UDMA ctrlq TP lookup |
| `udma_get_tp_list` | 175.17 us | UDMA driver work under `get_tp_list` |
| `ubcore_exchange_tp_info` | 5749.47 us | Peer TP create exchange |
| `send_create_req` | 4889.15 us | Control message send path |
| `ubcore_session_wait` | 854.17 us | Waits for peer create response |
| `ubcore_import_jetty_ex` | 174.03 us | Local import + VTP programming |
| `ubcore_connect_vtp_ctrlplane` | 171.66 us | Local control-plane VTP setup |

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:1162
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:1184
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:1202
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_connect_adapter.c:1214
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_jetty.c:2542
```

## What `ubcore_net_send_to()` Actually Spent Time On

The important correction from the deeper trace is that `ubcore_net_send_to()`
was not spending about 4.8 ms on the wire send itself.

The send stack is:

```text
ubcore_net_send_to()
  -> ubcore_ubcm_send_to()
  -> ubmad_ubc_send()
  -> ubmad_post_send()
       -> ubcore_get_main_primary_eid()
       -> ubmad_do_post_send()
```

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/net/ubcore_comm.c:157
```

The trace showed:

| Function | Observed time |
| --- | ---: |
| `ubmad_post_send` | 4905.23 us |
| `ubcore_get_main_primary_eid` | 4895.66 us |
| `ubmad_do_post_send` | 2-7 us |

So the real cost was local EID/topology resolution before posting the UB MAD,
not the send WQE itself.

## `ubcore_get_main_primary_eid()` Root Cause

The fifth trace expanded `ubcore_get_main_primary_eid()`:

```text
ubcore_get_main_primary_eid x 8
  -> ubcore_get_primary_eid x 8
       -> find_primary_eid_in_ues x 44,837
            -> is_eid_match x 941,429
```

Per top-level call, that is roughly:

```text
find_primary_eid_in_ues: ~5,605 calls
is_eid_match:           ~117,678 calls
```

The code is a linear scan over the global topology map:

```text
ubcore_get_main_primary_eid()
  -> ubcore_get_primary_eid()
       for each node
         for each dev
           find_primary_eid_in_ues()
             for each iodie
               compare primary_eid
               for each port
                 compare port_eid
  -> ubcore_get_primary_eid_array()
  -> ubcore_get_min_eid()
```

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:306
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:353
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:452
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_topo_info.c:467
```

Key conclusion:

```text
Each control-plane send redoes an O(topology-size) EID lookup.
In this environment, a single lookup costs about 4.9 ms hot-state.
```

Deep tracing inflated the function to about 38 ms because ftrace recorded nearly
one million inner calls. The less-intrusive trace is the better estimate for
real cost.

The environment output later showed:

```text
urma_admin show topo | grep -c "Dev"          -> 96
urma_admin show topo | grep -c "UE"           -> 192
urma_admin show topo | grep -c "Primary eid"  -> 192
```

That command output did not directly explain the approximately 5,605
`find_primary_eid_in_ues()` calls. The likely explanation is that the admin
output is a filtered/rendered view, while `ubcore_get_primary_eid()` walks the
full in-kernel topology dimensions across node/dev/iodie/port arrays.

## UDMA Ctrlq Slice Is Small

The local UDMA hardware-control part is visible but not the main cost in these
traces.

Examples:

| Function | Observed time |
| --- | ---: |
| `ubcore_get_tp_list` | ~176-194 us |
| `udma_get_tp_list` | ~175 us |
| `udma_ctrlq_get_tpid_list` | ~194 us in one early run |
| `ubcore_import_jetty_ex` | ~174 us |
| `ubcore_connect_vtp_ctrlplane` | ~172 us |
| `ubcore_active_tp` / UDMA active TP | ~191 us in one early run |

Source:

```text
/Volumes/KernelDev/kernel/drivers/ub/urma/ubcore/ubcore_tp.c:26
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:652
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:717
/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c:981
/Volumes/KernelDev/kernel/drivers/ub/ubase/ubase_ctrlq.c:926
```

Implication for TP-cache evaluation:

- A cache only inside `drivers/ub/urma/hw/udma/` naturally targets the local
  ctrlq slice, which is sub-millisecond in these traces.
- The larger repeated cost is in `ubcore_get_main_primary_eid()` and in
  peer-control/session wait. A local UDMA TP cache will not remove that unless
  the upper ubcore/UB MAD path also avoids repeated EID resolution or repeated
  peer exchange.

## Serial vs Concurrent Test Purpose

The later issue discussion separated two scaling questions:

| Scenario | Command shape | Question |
| --- | --- | --- |
| Serial `-J N` | One process creates N Jettys | Does the i-th connection get slower as N grows? |
| Concurrent N processes | N processes create one Jetty each | Do simultaneous setup calls serialize on locks or queues? |

`send_lat` cannot be used with `-J > 1`; UMDK rejects multiple Jettys on
non-bandwidth tests:

```text
Multiple jettys only available on band width tests.
```

Source:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_parameters.c:677
```

Therefore serial `-J N` tests must use `send_bw`. This is still valid for
setup analysis because `send_bw` and `send_lat` share the same `create_ctx()`
and `create_duplex_ctx()` setup path; they diverge later in the data test.

## Resource Exhaustion Finding From `send_bw -J 100`

One serial stress attempt used:

```bash
urma_perftest send_bw -J 100 -n 5 -s 2 -d bonding_dev_0 --single_path -p 0
```

Observed failure:

```text
server: Failed to import seg, loop:45!
client: Connection reset by peer
```

After that, even `send_bw -J 1` failed on both sides:

```text
Failed to import seg, loop:0!
```

Interpretation:

- The `-J 100` partial failure likely consumed kernel-side import/segment
  resources and did not fully release them on the failure path.
- The later `loop:0` failure means the resource pool was already exhausted
  before the first import in a new run.
- This is a separate resource-lifecycle problem from the `send_lat` timing
  bottleneck.

Source for user-space failure path:

```text
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1335
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1338
/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c:1346
```

Practical rule for future serial tests: reset or otherwise verify kernel
resource state before each large `-J N` run, and start with small N.

## Concurrent 100-Process Result

The final captured experiment launched 100 server instances and 100 clients,
each using `send_lat -J 1` with unique ports. The client side traced coarse
kernel setup functions with `trace_clock=global`.

The important comparison was:

| Function group | Single-process hot baseline | 100-process concurrent | Change |
| --- | ---: | ---: | ---: |
| `ubcore_create_jfc` x4 | 108 / 0.5 / 46 / 0.5 us | 202 / 1.8 / 153 / 1.4 us | ~2x, still small |
| `ubcore_create_jfr` x2 | 64 / 2.7 us | 121 / 3.5 us | ~2x, still small |
| `ubcore_create_jetty` x2 | 47 / 2.1 us | 147 / 2.7 us | ~3x, still small |
| `ubcore_register_seg` x2 | 4 / 1.6 us | 3.5 / 1.8 us | no material change |
| `ubcore_import_seg` | ~5.9 ms | 42.7 ms | 7.2x |
| `ubcore_import_jetty` #1 | ~5.3 ms | 108.7 ms | 20.5x |
| `ubcore_import_jetty` #2 | ~6.1 ms | 554 ms | 91x |
| `ubcore_unimport_jetty` #1 | ~5.1 ms | 5.9 ms | roughly unchanged |
| Local delete cleanup | ~1.8 ms | ~1.8 ms | unchanged |

Conclusions:

- Local resource creation is not the concurrent bottleneck. It grows slightly,
  but stays in the microsecond range.
- The concurrent bottleneck is concentrated in `import_seg` and especially the
  two `import_jetty` control-plane setup steps.
- The second `import_jetty` is much worse than the first in the 100-process
  run. The likely reason is synchronization of many clients into the same later
  setup stage, causing a burst of requests against the same serialized
  bottleneck.

The current evidence does not fully split the 100-process slowdown between:

| Effect | How it would show up |
| --- | --- |
| Client-side EID/topology lookup contention | `ubcore_get_main_primary_eid()` becomes much larger than 4.9 ms or waits on a lock |
| Server-side control-plane queue buildup | `ubcore_session_wait()` grows from sub-ms to tens/hundreds of ms |
| Both | Both functions grow materially |

That split is the next experiment.

## Recommended Next Trace

For the next 100-process run, keep the top-level process filter and expand only
enough to separate local CPU lookup from peer wait:

```bash
cd /sys/kernel/debug/tracing
echo nop > current_tracer
echo > trace
echo 0 > tracing_on
echo global > trace_clock

cat > set_graph_function << 'EOF'
ubcore_import_seg
ubcore_import_jetty
ubcore_connect_exchange_udata_when_import_seg
ubcore_connect_exchange_udata_when_import_jetty
send_seg_info_req
send_jetty_info_req
ubcore_import_jetty_compat
ubcore_exchange_tp_info
send_create_req
ubcore_net_send_to
ubcore_get_main_primary_eid
ubcore_session_wait
EOF

echo 0 > tracing_thresh
echo 3 > max_graph_depth
echo 1 > options/funcgraph-abstime
echo 1 > options/funcgraph-proc
echo 32768 > buffer_size_kb
echo function_graph > current_tracer
```

Then trace only the observed client process:

```bash
echo 1 > tracing_on
sh -c 'echo $$ > /sys/kernel/debug/tracing/set_ftrace_pid && exec urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0 -P 9090 -S <server_ip>'
echo 0 > tracing_on
```

Avoid tracing `is_eid_match` in the concurrent run unless absolutely needed.
The fifth baseline experiment showed that deep inner-loop tracing distorts the
target function by roughly 8x.

## Result Summary

1. `urma_perftest send_lat` steady-state data latency was about 3 us for this
   2-byte, 5-iteration test.
2. The setup path is much more expensive than the data path. A single hot
   setup spent about 5.9 ms in `import_seg` and about 5.3 ms + 6.1 ms in two
   `import_jetty` steps.
3. The biggest single local cost is not the actual UB MAD send. It is repeated
   `ubcore_get_main_primary_eid()` topology lookup, about 4.9 ms per
   control-plane send in the hot baseline.
4. Local UDMA ctrlq operations such as `get_tp_list`, `active_tp`, and VTP
   programming were sub-ms and much smaller than the repeated EID lookup.
5. In the 100-process concurrent run, local resource creation stayed small, but
   `import_seg` grew to 42.7 ms and the two `import_jetty` calls grew to
   108.7 ms and 554 ms.
6. The next unresolved question is whether the concurrent inflation is mainly
   client-side EID lookup contention, server-side control-plane queueing, or
   both.
