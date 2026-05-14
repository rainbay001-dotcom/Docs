# urma_perftest Function Call Graph

_Source anchor: `/Volumes/KernelDev/umdk`, branch `master`, commit `2d99e487`._

This note is a source-level call graph for `src/urma/tools/urma_perftest/`.
It is intentionally broader than
[`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md), which
is a timing-focused forward view for `send_lat`. This note maps the executable's
userspace control flow, resource setup/teardown, latency tests, bandwidth tests,
and the main URMA API boundaries.

## Source Files

| File | Role |
| --- | --- |
| `urma_perftest.c` | Top-level `main()`, command dispatch, global test barriers |
| `perftest_parameters.c` | CLI parsing, local config validation, remote config compatibility check |
| `perftest_communication.c` | TCP control channel and simple synchronization protocol |
| `perftest_resources.c` | URMA device/context/resource creation, remote descriptor exchange, import/connect, teardown |
| `perftest_run_test.c` | Work-request construction, latency loops, bandwidth loops, reporting |

## 1. Top-Level Control Flow

Source: `urma_perftest.c:158`.

```text
main(argc, argv)
|- perftest_parse_args(argc, argv, &cfg)                     parameters.c:481
|  |- init_cfg                                               parameters.c:259
|  `- getopt/command-specific option parsing
|
|- check_local_cfg(&cfg)                                     parameters.c:1044
|  |- validates device name, priority, time mode, depths
|  |- normalizes JFC/JFS/JFR depths and CQ moderation
|  |- enforces command/mode constraints
|  `- applies UB/send/CTP/credit/user-TP restrictions
|
|- establish_connection(&cfg)                                communication.c:272
|  |- client_connect(cfg) if cfg->comm.server_ip != NULL     communication.c:85
|  `- server_connect(cfg) otherwise                          communication.c:185
|
|- check_remote_cfg(&cfg)                                    parameters.c:1541
|  |- sock_sync_data(sock_fd, OFF_SET, cfg, remote_cfg)      communication.c:308
|  `- check_both_side_cfg(local, remote)                     parameters.c:1415
|
|- create_ctx(&ctx, &cfg)                                    resources.c:2263
|  |- create_simplex_ctx(ctx, cfg) if SIMPLEX                resources.c:1968
|  `- create_duplex_ctx(ctx, cfg) otherwise                  resources.c:2198
|
|- prepare_test(&ctx, &cfg, &args)                           urma_perftest.c:139
|  |- print_cfg(cfg)
|  |- rearm_jfc(ctx, cfg) if cfg->use_jfce                   urma_perftest.c:87
|  `- pthread_create(write_dirty_thread) for BW dirty-write  urma_perftest.c:113
|
|- run_test(&ctx, &cfg)                                      urma_perftest.c:25
|  |- sync_time(sock_fd, "Start test") per pair              communication.c:339
|  |- dispatch by cfg->cmd
|  `- sync_time(sock_fd, "End test") per pair
|
|- destroy_ctx(&ctx, &cfg)                                   resources.c:2317
|- close_connection(&cfg)                                    communication.c:289
`- destroy_cfg(&cfg)                                         parameters.c:956
```

Important split: the TCP connection is control-plane metadata only. Data-plane
latency/BW loops use URMA queues after `create_ctx()`; they do not use the TCP
socket except for phase barriers and result exchange.

## 2. TCP Control Channel

Source: `perftest_communication.c`.

```text
establish_connection(cfg)                                    :272
|- client_connect(cfg)                                       :85
|  |- allocate cfg->comm.sock_fd[pair_num]
|  |- resolve server address
|  |- socket/connect for each pair
|  `- ip_set_sockopts
|
`- server_connect(cfg)                                       :185
   |- allocate cfg->comm.sock_fd[pair_num]
   |- socket/bind/listen
   |- accept pair_num connections
   `- ip_set_sockopts

sock_sync_data(sock_fd, size, local_data, remote_data)        :308
|- write local_data
`- read exactly size bytes from peer

sync_time(sock_fd, marker)                                   :339
`- sock_sync_data(marker, marker) + memcmp
```

`check_remote_cfg()` uses `sock_sync_data()` to exchange the first 360 bytes of
`perftest_config_t`, then `check_both_side_cfg()` rejects mismatched command,
size, transport mode, jetty mode, time mode, credit mode, SGE count, and related
options.

## 3. Resource Setup: Common Shape

`create_ctx()` dispatches by `cfg->jetty_mode`:

```text
create_ctx(ctx, cfg)                                         resources.c:2263
|- create_simplex_ctx(ctx, cfg)                              resources.c:1968
`- create_duplex_ctx(ctx, cfg)                               resources.c:2198
```

### 3.1 SIMPLEX Setup

```text
create_simplex_ctx(ctx, cfg)                                 resources.c:1968
|- init_device(ctx, cfg)                                     :150
|- create_simplex_jettys(ctx, cfg)                           :637
|  |- create_jfc(ctx, cfg)                                   :338
|  |- create_jfs(ctx, cfg)                                   :408
|  `- create_jfr(ctx, cfg)                                   :467
|- register_mem(ctx, cfg)                                    :743
|- create_credit_ctx(ctx, cfg) if enable_credit              :1879
|- exchange_connection_info(ctx, cfg)                        :1177
|- import_seg_for_simplex(ctx, cfg)                          :1255
|- connect_jfr(ctx, cfg)                                     :1468
`- create_run_ctx(ctx, cfg)                                  :1799
```

SIMPLEX creates JFS and JFR as separate objects. Its remote receive target is
imported through `connect_jfr()`, which eventually calls either
`urma_import_jfr()` or `urma_import_jfr_ex()`.

### 3.2 DUPLEX Setup

```text
create_duplex_ctx(ctx, cfg)                                  resources.c:2198
|- init_device(ctx, cfg)                                     :150
|- create_duplex_jettys(ctx, cfg)                            :658
|  |- create_jfc(ctx, cfg)                                   :338
|  `- create_jetty(ctx, cfg)                                 :564
|- register_mem(ctx, cfg)                                    :743
|- create_credit_ctx(ctx, cfg) if enable_credit              :1879
|- exchange_connection_info(ctx, cfg)                        :1177
|- import_seg_for_duplex(ctx, cfg)                           :1304
|- connect_jetty(ctx, cfg)                                   :1773
|- modify_user_tp(ctx, cfg) if enable_user_tp                :2157
`- create_run_ctx(ctx, cfg)                                  :1799
```

DUPLEX creates a single bidirectional Jetty object per logical stream. Its
remote target is imported through `connect_jetty()`, which eventually calls
`urma_import_jetty()`, `urma_import_jetty_ex()`, or the async import path.

## 4. Device And Local Resource Creation

### 4.1 `init_device`

```text
init_device(ctx, cfg)                                        resources.c:150
|- urma_init(&init_attr)
|- urma_register_log_func(print_log) if enable_stdout
|- urma_get_device_by_name(cfg->dev_name)
|- urma_query_device(urma_dev, &ctx->dev_attr)
|- get_jetty_priority_by_tp_type(...) if priority omitted     :136
|- urma_create_context(urma_dev, cfg->eid_idx)
|- urma_user_ctl(BONDP_USER_CTL_SET_BONDING_MODE) if bonding
`- check_dev_cap(ctx, cfg)                                   :68
```

The bonding-mode write is important for `bonding_dev_0 --single_path`: it sets
the bonding level to port-level single-path mode before resources are created.

### 4.2 JFC/JFS/JFR/Jetty Creation

```text
create_jfc(ctx, cfg)                                         resources.c:338
|- alloc_jfc(ctx, cfg)                                       :278
|- optionally urma_create_jfce() for send/recv event channels
|- urma_create_jfc(ctx->urma_ctx, &jfc_cfg) for send JFC
`- urma_create_jfc(ctx->urma_ctx, &jfc_cfg) for recv JFC

create_jfs(ctx, cfg)                                         resources.c:408
`- loop jettys:
   `- urma_create_jfs(ctx->urma_ctx, &jfs_cfg)

create_jfr(ctx, cfg)                                         resources.c:467
`- loop jettys:
   `- urma_create_jfr(ctx->urma_ctx, &jfr_cfg)

create_jetty(ctx, cfg)                                       resources.c:564
|- fill_jfs_cfg(ctx, cfg, inline, &jfs_cfg)                   :502
|- fill_jfr_cfg(ctx, cfg, &jfr_cfg)                           :534
|- if share_jfr:
|  `- create shared JFRs with urma_create_jfr()
`- loop jettys:
   `- urma_create_jetty(ctx->urma_ctx, &jetty_cfg)
```

JFC sharing rule: `create_jfc()` reuses JFC 0 for later jettys when
`pair_flag == false` or the test is BW. That is why the number of local JFC
objects can be lower than `2 * cfg->jettys`.

## 5. Memory Registration And Remote Metadata Exchange

### 5.1 Local Memory Registration

```text
register_mem(ctx, cfg)                                       resources.c:743
|- allocate local_buf[jettys]
|  |- ub_hugemalloc(...) if cfg->use_huge_page
|  `- memalign(page_size, buf_len) otherwise
|- if URMA_TRANSPORT_UB:
|  `- urma_alloc_token_id(ctx->urma_ctx) per segment
`- loop seg_num:
   `- urma_register_seg(ctx->urma_ctx, &seg_cfg)
```

`seg_num` is either `1` or `cfg->jettys`, depending on `seg_pre_jetty`. If
`seg_pre_jetty == false`, all jettys share one local target segment.

### 5.2 TCP Metadata Exchange

```text
exchange_connection_info(ctx, cfg)                           resources.c:1177
|- exchange_seg_info(ctx, &cfg->comm, cfg)                    :882
|  `- sock_sync_data(local urma_seg_t[], remote urma_seg_t[])
|- exchange_jetty_id(ctx, &cfg->comm, cfg)                    :926
|  `- sock_sync_data(local jfr_id/jetty_id[], remote ids[])
|- exchange_credit_info(ctx, &cfg->comm, cfg) if credit       :976
|- create_tp_info(ctx, &cfg->comm, cfg) if tp_aware           :1027
|  `- loop jettys:
|     `- urma_get_tp_list(ctx->urma_ctx, &tp_cfg, ...)
`- exchange_tp_info(ctx, &cfg->comm, cfg) if tp_aware         :1134
   `- sock_sync_data(local tp_handle/psn[], remote[])
```

This is still userspace TCP metadata exchange. The important exception is
`create_tp_info()`: if `tp_aware` is enabled, it calls the URMA API
`urma_get_tp_list()`, which crosses into the URMA provider/kernel path.

### 5.3 Remote Segment Import

```text
import_seg_for_simplex(ctx, cfg)                             resources.c:1255
|- optionally import remote credit segments
|  `- urma_import_seg(ctx->urma_ctx, &remote_credit_seg[i], ...)
`- loop jettys:
   `- urma_import_seg(ctx->urma_ctx, &ctx->remote_seg[i], ...)

import_seg_for_duplex(ctx, cfg)                              resources.c:1304
|- optionally import remote credit segments
`- loop jettys:
   `- urma_import_seg(ctx->urma_ctx, &ctx->remote_seg[i], ...)
```

For SEND tests, `import_seg` is framework overhead rather than a semantic
requirement of SEND. It is still part of the common perftest setup because the
same resource framework serves READ/WRITE/ATOMIC/SEND.

## 6. Remote Jetty/JFR Connect Paths

### 6.1 SIMPLEX: `connect_jfr`

```text
connect_jfr(ctx, cfg)                                        resources.c:1468
|- allocate ctx->import_tjfr[]
|- if cfg->tp_aware:
|  `- connect_jfr_tp_aware(ctx, cfg)                          :1421
|     |- build urma_import_jfr_ex_cfg_t from tp_info
|     |- loop jettys:
|     |  `- urma_import_jfr_ex(ctx->urma_ctx, &rjfr, token, &active_cfg)
|     `- sync_time(sock_fd[0], "tp aware connect finished")
`- else:
   `- connect_jfr_default(ctx, cfg)                           :1373
      |- loop jettys:
      |  |- build urma_rjfr_t / optional bondp_rjfr_t
      |  |- urma_import_jfr(ctx->urma_ctx, &rjfr, token)
      |  `- urma_advise_jfr(...) for non-UB RM devices
      `- rollback with disconnect_jfr_default on failure       :1360
```

### 6.2 DUPLEX: `connect_jetty`

```text
connect_jetty(ctx, cfg)                                      resources.c:1773
|- allocate ctx->import_tjetty[]
|- if cfg->enable_async_import:
|  `- connect_jetty_async(ctx, cfg)                           :1687
|     |- urma_create_notifier(ctx->urma_ctx)
|     |- loop jettys:
|     |  `- urma_import_jetty_async(notifier, &rjetty, token, user_ctx, -1)
|     |- wait_jetty_async(ctx, notifier, expected)             :1632
|     |- loop jettys:
|     |  `- urma_bind_jetty_async(...) for RC, or advise for non-UB RM
|     `- wait_jetty_async(...) for RC bind completion
|
|- else if cfg->tp_aware:
|  `- connect_jetty_tp_aware(ctx, cfg)                         :1574
|     |- build urma_import_jfr_ex_cfg_t active_cfg from tp_info
|     |- loop jettys:
|     |  `- urma_import_jetty_ex(ctx->urma_ctx, &rjetty, token, &active_cfg)
|     |- urma_bind_jetty_ex(...) for RC
|     `- sync_time(sock_fd[0], "tp aware connect finished")
|
`- else:
   `- connect_jetty_default(ctx, cfg)                          :1510
      |- loop jettys:
      |  |- build urma_rjetty_t / optional bondp_rjetty_t
      |  |- urma_import_jetty(ctx->urma_ctx, &rjetty, token)
      |  |- urma_bind_jetty(...) for RC
      |  `- urma_advise_jetty(...) for non-UB RM devices
      `- rollback with disconnect_jetty_default on failure      :1493
```

For the common UMDK#2 command
`urma_perftest send_lat -d bonding_dev_0 --single_path`, the interesting branch
is DUPLEX + non-`tp_aware` + non-async:

```text
create_duplex_ctx
`- connect_jetty
   `- connect_jetty_default
      `- urma_import_jetty(bondp_rjetty)
```

The bondp library then expands that one userspace import into a virtual-side
import and a physical-side import, which is why kernel ftrace can show two
`ubcore_import_jetty` events for one logical perftest Jetty. See
`umdk_urma_perftest_call_chain.md` section 3.2/section 3.3 for that userspace-bondp to kernel
breakdown.

## 7. Run Context And Test Preparation

```text
create_run_ctx(ctx, cfg)                                     resources.c:1799
|- allocate run_ctx.tposted[cycles_num]
|- allocate run_ctx.tcompleted[cycles_num]
|- allocate run_ctx.scnt[jettys]
`- allocate run_ctx.ccnt[jettys]

prepare_test(ctx, cfg, args)                                 urma_perftest.c:139
|- print_cfg(cfg)
|- rearm_jfc(ctx, cfg) if use_jfce                           urma_perftest.c:87
`- start write_dirty_thread for BW dirty-write mode           urma_perftest.c:113
```

`create_run_ctx()` prepares measurement arrays. The per-command run path later
allocates concrete WR templates (`jfs_wr`, `jfr_wr`, SGE arrays) because those
depend on command type and message size.

## 8. Command Dispatch

Source: `run_test()` in `urma_perftest.c:25`.

```text
run_test(ctx, cfg)
|- sync_time(sock_fd[i], "Start test") for i in pair_num
|- switch (cfg->cmd)
|  |- PERFTEST_READ_LAT   -> run_read_lat(ctx, cfg)            run_test.c:1326
|  |- PERFTEST_WRITE_LAT  -> run_write_lat(ctx, cfg)           run_test.c:1455
|  |- PERFTEST_SEND_LAT   -> run_send_lat(ctx, cfg)            run_test.c:1672
|  |- PERFTEST_ATOMIC_LAT -> run_atomic_lat(ctx, cfg)          run_test.c:1694
|  |- PERFTEST_READ_BW    -> run_read_bw(ctx, cfg)             run_test.c:3061
|  |- PERFTEST_WRITE_BW   -> run_write_bw(ctx, cfg)            run_test.c:3083
|  |- PERFTEST_SEND_BW    -> run_send_bw(ctx, cfg)             run_test.c:3236
|  `- PERFTEST_ATOMIC_BW  -> run_atomic_bw(ctx, cfg)           run_test.c:3255
|- join write_dirty_thread if active
`- sync_time(sock_fd[i], "End test") for i in pair_num
```

`WRITE_IMM` is treated as send-style in the dispatch layer: `run_write_lat()`
and `run_write_bw()` call the SEND path when `cfg->enable_imm == true`.
`run_atomic_lat()` reuses `run_read_lat()`.

## 9. Latency Test Graph

### 9.1 Shared Latency Harness

```text
run_*_lat(ctx, cfg)
|- print latency header
|- if cfg->all:
|  `- for size = 2^1 .. 2^order:
|     `- run_*_lat_once(ctx, cfg)
`- else:
   `- run_*_lat_once(ctx, cfg)

run_*_lat_once(ctx, cfg)
|- prepare_jfs_wr(ctx, cfg)                                  run_test.c:1036
|  |- allocate run_ctx.jfs_wr[]
|  |- allocate run_ctx.jfs_sge[]
|  |- init_jfs_wr_base(...)                                  run_test.c:718
|  `- init_jfs_wr_sg(...) dispatch by cfg->cmd               run_test.c:928
|- prepare_jfr_wr(ctx, cfg) for SEND                         run_test.c:1139
|  |- allocate jfr_wr/jfr_sge/rx_buf_addr
|  |- init_jfr_wr(...)                                       run_test.c:1074
|  `- pre-post receive WRs only for BW, not LAT
|- run_lat_test(ctx, cfg, worker_fn)                         run_test.c:1215
|  |- allocate perftest_thread_arg_t[jettys]
|  |- pthread_create one worker per jetty
|  |- pthread_join pair_num workers
|  `- print_lat_report or print_lat_duration_report
`- destroy WR templates
```

`run_lat_test()` creates one thread per `cfg->jettys` but only joins
`cfg->pair_num` threads. In the common one-pair case this is one worker thread.

### 9.2 READ_LAT

```text
run_read_lat(ctx, cfg)                                       run_test.c:1326
`- run_read_lat_once(ctx, cfg)                               :1306
   |- prepare_jfs_wr
   `- run_lat_test(..., worker)
      |- SIMPLEX -> run_read_lat_simplex                      :208
      |  |- loop until scnt == iters
      |  |- timestamp tposted
      |  |- urma_read(...) if flat API, else urma_post_jfs_wr(ctx->jfs[id], wr)
      |  `- poll_jfc_until_expected_cqe(ctx, cfg, id, cr)    :173
      `- DUPLEX -> run_read_lat_duplex                        :1248
         |- loop until scnt == iters
         |- timestamp tposted
         |- urma_post_jetty_send_wr(ctx->jetty[id], wr)
         `- poll_jfc_until_expected_cqe(ctx, cfg, id, cr)
```

The DUPLEX read path posts through the Jetty send queue; the WR opcode prepared
by `prepare_jfs_wr()` makes it a READ operation.

### 9.3 WRITE_LAT

```text
run_write_lat(ctx, cfg)                                      run_test.c:1455
|- if cfg->enable_imm: run_send_lat(ctx, cfg)
`- run_write_lat_once(ctx, cfg)                              :1434
   |- prepare_jfs_wr
   `- run_lat_test(..., worker)
      |- SIMPLEX -> run_write_lat_simplex                     :279
      |  |- ping-pong via memory byte polling
      |  |- urma_post_jfs_wr(ctx->jfs[id], wr)
      |  `- poll_jfc_until_expected_cqe
      `- DUPLEX -> run_write_lat_duplex                       :1353
         |- ping-pong via memory byte polling
         |- urma_post_jetty_send_wr(ctx->jetty[id], wr)
         `- poll_jfc_until_expected_cqe
```

WRITE latency uses a memory-side ping-pong marker (`post_buf` / `poll_buf`) in
addition to send-completion polling. The server/client first-send condition is
opposite between simplex and duplex workers.

### 9.4 SEND_LAT

```text
run_send_lat(ctx, cfg)                                       run_test.c:1672
`- run_send_lat_once(ctx, cfg)                               :1647
   |- prepare_jfs_wr(ctx, cfg)
   |- prepare_jfr_wr(ctx, cfg)
   `- run_lat_test(..., worker)
      |- SIMPLEX -> run_send_lat_simplex                      :404
      |  |- send_lat_post_recv(ctx, cfg, id, prefill_cnt)    :371
      |  |  `- urma_post_jfr_wr(ctx->jfr[id], jfr_wr)
      |  |- sync_time(sock_fd[id], "send_lat_post_recv")
      |  |- loop:
      |  |  |- receive side: urma_poll_jfc(ctx->jfc_r[id], ...)
      |  |  |- repost receives with send_lat_post_recv(...)
      |  |  |- send side: urma_post_jfs_wr(ctx->jfs[id], wr)
      |  |  `- poll_jfc_until_expected_cqe(ctx->jfc_s[id])
      |  `- print latency report
      |
      `- DUPLEX -> run_send_lat_duplex                        :1501
         |- get_rqe_prefill_multiple_duplex(...)             :119
         |- send_lat_post_jetty_recv(ctx, cfg, id, cnt)      :1481
         |  `- urma_post_jetty_recv_wr(ctx->jetty[id], jfr_wr)
         |- sync_time(sock_fd[id], "send_lat_post_recv")
         |- loop:
         |  |- receive side:
         |  |  |- wait_jfc_event(...) if event mode          :147
         |  |  |- urma_poll_jfc(ctx->jfc_r[id], ...)
         |  |  |- set_on_first_rx(ctx, cfg)                  :394
         |  |  `- repost receives via send_lat_post_jetty_recv
         |  |- send side:
         |  |  |- timestamp tposted
         |  |  |- set WR user_ctx / completion flag
         |  |  |- urma_post_jetty_send_wr(ctx->jetty[id], wr)
         |  |  `- poll_jfc_until_expected_cqe(ctx->jfc_s[id])
         |  `- duration-state accounting if enabled
         `- destroy_jfr_wr / destroy_jfs_wr
```

For UMDK#2's `send_lat -n 5 -s 2 -d bonding_dev_0 --single_path`, this is the
steady-state loop. After setup, the repeated operations are post-send, poll
receive JFC, repost receive, and poll send JFC. In the mapped fast path these
are userspace queue operations; the expensive setup work has already happened.

## 10. Bandwidth Test Graph

The BW path is centralized around `run_bw_once()` and the SEND-specific receive
side.

```text
run_read_bw(ctx, cfg)                                        run_test.c:3061
`- run_bw_once(ctx, cfg) per size                            :3004

run_write_bw(ctx, cfg)                                       run_test.c:3083
|- if cfg->enable_imm: run_send_bw(ctx, cfg)
`- run_bw_once(ctx, cfg) per size

run_atomic_bw(ctx, cfg)                                      run_test.c:3255
`- run_bw_once(ctx, cfg)

run_bw_once(ctx, cfg)                                        :3004
|- server half of unidirectional READ/WRITE/ATOMIC:
|  `- sync/report only; no data posting
|- if infinite:
|  `- prepare_run_bw_infinite(ctx, cfg)                      :2927
|     |- prepare_jfs_wr
|     `- run_once_bw_infinite(ctx, cfg)                      :2587
`- else:
   `- prepare_run_bw_once(ctx, cfg, reports)                 :2943
      |- prepare_jfs_wr
      |- perform_warm_up(ctx, cfg) if warm_up                resources.c:2344
      |- sync_time before/after for bidirectional
      |- run_once_bw(ctx, cfg)                               run_test.c:1699
      |- print_bw_report(...)
      `- exchange/print bidirectional report if needed

run_once_bw(ctx, cfg)                                        :1699
|- loop over jettys and queue depth
|  |- optional rate limiter / credit checks
|  |- urma_post_jfs_wr(...) for SIMPLEX
|  `- urma_post_jetty_send_wr(...) for DUPLEX
|- poll send completion:
|  `- urma_poll_jfc(ctx->jfc_s[0], PERFTEST_POLL_BATCH, cr)
`- record tposted/tcompleted for BW report
```

SEND_BW has an explicit sender/receiver split:

```text
run_send_bw(ctx, cfg)                                        run_test.c:3236
`- run_send_bw_one_size(ctx, cfg)                            :3189
   |- prepare_jfs_wr if client or bidirectional              :1036
   |- prepare_jfr_wr if server or bidirectional              :1139
   |- prepare_credit_wr if credit                            :989
   |- if infinite:
   |  `- run_send_bw_infinite(ctx, cfg)                      :3159
   |     |- sync_time("run_send_bw_infinite")
   |     |- client: run_once_bw_infinite(ctx, cfg)            :2587
   |     `- server: run_once_bw_recv_infinite(ctx, cfg)       :2737
   `- else:
      `- run_send_bw_once(ctx, cfg)                          :3105
         |- sync_time("send_bw_post_recv")
         |- bidirectional: run_once_bi_bw(ctx, cfg)           :2115
         |- client: run_once_bw(ctx, cfg)                     :1699
         `- server: run_once_bw_recv(ctx, cfg)                :1903

run_once_bw_recv(ctx, cfg)                                   :1903
|- poll receive completions:
|  `- urma_poll_jfc(ctx->jfc_r[0], PERFTEST_POLL_BATCH, cr)
|- set_on_first_rx(ctx, cfg) on first packet
|- repost receive WRs:
|  |- SIMPLEX: urma_post_jfr_wr(ctx->jfr[cr_id], jfr_wr)
|  `- DUPLEX:  urma_post_jetty_recv_wr(ctx->jetty[cr_id], jfr_wr)
`- optional credit notification via write WR
```

## 11. Teardown Graph

```text
destroy_ctx(ctx, cfg)                                        resources.c:2317
|- SIMPLEX -> destroy_simplex_ctx(ctx, cfg)                    :2271
|  |- destroy_run_ctx(ctx)                                   :1839
|  |- disconnect_jfr(ctx, cfg)                               :1461
|  |  `- disconnect_jfr_default(ctx, cfg)                    :1360
|  |     |- urma_unadvise_jfr(...) for non-UB RM
|  |     `- urma_unimport_jfr(...)
|  |- unimport_seg(ctx, jetty_num)                           :1231
|  |- sync_time("unimport_jfr")
|  |- unimport_credit(...) if credit                         :1242
|  |- destroy_connection_info(ctx)                           :1222
|  |- destroy_credit_ctx(...) if credit                      :1850
|  |- unregister_mem(ctx, cfg)                               :867
|  |- destroy_simplex_jettys(ctx, cfg)                       :674
|  `- uninit_device(ctx)                                     :261
|
`- DUPLEX -> destroy_duplex_ctx(ctx, cfg)                      :2292
   |- destroy_run_ctx(ctx)
   |- free user_tp buffers if enabled
   |- disconnect_jetty(ctx, cfg)                             :1762
   |  |- disconnect_jetty_async(...) if async                :1667
   |  `- disconnect_jetty_default(...) otherwise             :1493
   |     |- urma_unbind_jetty(...) for RC
   |     |- urma_unadvise_jetty(...) for non-UB RM
   |     `- urma_unimport_jetty(...)
   |- sync_time("unimport_jetty")
   |- unimport_credit(...) if credit
   |- unimport_seg(ctx, jetty_num)
   |- destroy_connection_info(ctx)
   |- destroy_credit_ctx(...) if credit
   |- unregister_mem(ctx, cfg)
   |- destroy_duplex_jettys(ctx, cfg)                        :682
   `- uninit_device(ctx)
```

## 12. Main URMA API Boundary Map

These are the calls in `urma_perftest` that cross from the test program into
the URMA library/provider stack. Some become `uburma` ioctls; some are mmaped
queue operations in the steady-state fast path.

| Perftest phase | URMA API calls | Source |
| --- | --- | --- |
| Device init | `urma_init`, `urma_get_device_by_name`, `urma_query_device`, `urma_create_context`, `urma_user_ctl` | `resources.c:150` |
| Local queues | `urma_create_jfce`, `urma_create_jfc`, `urma_create_jfs`, `urma_create_jfr`, `urma_create_jetty` | `resources.c:338`, `:408`, `:467`, `:564` |
| Memory | `urma_alloc_token_id`, `urma_register_seg`, `urma_import_seg`, `urma_unimport_seg`, `urma_unregister_seg`, `urma_free_token_id` | `resources.c:743`, `:1255`, `:1304` |
| TP-aware metadata | `urma_get_tp_list`, `urma_set_tp_attr`, `urma_import_jfr_ex`, `urma_import_jetty_ex`, `urma_modify_tp` | `resources.c:1027`, `:1421`, `:1574`, `:2157` |
| Remote JFR/Jetty | `urma_import_jfr`, `urma_import_jetty`, async import/bind variants, bind/advise/unimport calls | `resources.c:1373`, `:1510`, `:1687` |
| Lat/BW fast path | `urma_post_jfs_wr`, `urma_post_jfr_wr`, `urma_post_jetty_recv_wr`, `urma_post_jetty_send_wr`, `urma_poll_jfc`, `urma_wait_jfc`, `urma_ack_jfc`, flat `urma_read` | `run_test.c:173`, `:208`, `:404`, `:1248`, `:1501`, `:1699`, `:1903` |

For the `send_lat` steady-state path, the important boundary is:

```text
run_send_lat_duplex
|- urma_post_jetty_recv_wr     # prepost / repost receive WQEs
|- urma_poll_jfc(jfc_r)        # receive completion polling
|- urma_post_jetty_send_wr     # send WQE
`- urma_poll_jfc(jfc_s)        # send completion polling
```

The expensive first-RPC/import work is not in this steady-state loop. It happens
earlier in `create_duplex_ctx()` through `import_seg_for_duplex()` and
`connect_jetty()`.

## 13. Common `send_lat --single_path` Path

For the current UMDK#2 investigation command:

```bash
urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0 [-S server_ip]
```

the userspace path is:

```text
main
|- perftest_parse_args
|- check_local_cfg
|- establish_connection
|- check_remote_cfg
|- create_ctx
|  `- create_duplex_ctx
|     |- init_device
|     |  `- urma_user_ctl(BONDP_USER_CTL_SET_BONDING_MODE, PORT level)
|     |- create_duplex_jettys
|     |  |- create_jfc
|     |  `- create_jetty
|     |- register_mem
|     |- exchange_connection_info
|     |  |- exchange_seg_info
|     |  |- exchange_jetty_id
|     |  `- create/exchange tp_info only if tp_aware
|     |- import_seg_for_duplex
|     |  `- urma_import_seg
|     |- connect_jetty
|     |  `- connect_jetty_default
|     |     `- urma_import_jetty(bondp_rjetty)
|     `- create_run_ctx
|- prepare_test
|- run_test
|  |- sync_time("Start test")
|  `- run_send_lat
|     `- run_send_lat_once
|        |- prepare_jfs_wr
|        |- prepare_jfr_wr
|        `- run_lat_test(..., run_send_lat_duplex)
|           `- worker thread:
|              |- prepost recv WRs with urma_post_jetty_recv_wr
|              |- sync_time("send_lat_post_recv")
|              |- poll recv completions with urma_poll_jfc(jfc_r)
|              |- repost receives
|              |- post send WR with urma_post_jetty_send_wr
|              `- poll send completion with urma_poll_jfc(jfc_s)
`- destroy_ctx / close_connection / destroy_cfg
```

That is the function graph to keep in mind when mapping traces:

- `ubcore_import_seg` or `ubcore_import_jetty` ftrace entries belong to
  `create_ctx()`, not the measured steady-state loop.
- `ubcore_rearm_jfc` belongs to `prepare_test()` if event mode is enabled.
- steady-state `send_lat` mostly shows up as mapped queue access and polling,
  not as large setup ioctls.

## 14. Expanded Setup Paths

The setup path has two layers:

1. Process/test setup: parse options, validate config, build the TCP control
   channel, exchange config, and create URMA resources.
2. Per-command WR setup: allocate and initialize WQE templates immediately
   before a test run. This happens after the `run_test()` "Start test" barrier,
   but before the perftest latency timestamps in the worker loops.

### 14.1 Common Process Setup

```text
main                                                     urma_perftest.c:158
|- perftest_parse_args                                  parameters.c:481
|  |- init_cfg                                          parameters.c:259
|  |- command parser selects api_type/cmd/type
|  |- option parser fills dev, size, iters, depths, mode
|  `- derived defaults such as jetty_mode, trans_mode, pair_num
|
|- check_local_cfg                                      parameters.c:1044
|  |- check device/options are coherent locally
|  |- normalize queue depths and CQ moderation
|  |- reject unsupported combinations
|  `- set command-specific constraints
|
|- establish_connection                                 communication.c:272
|  |- client_connect if server_ip exists                communication.c:85
|  `- server_connect otherwise                          communication.c:185
|
|- check_remote_cfg                                     parameters.c:1541
|  |- sock_sync_data(local cfg prefix, remote cfg)       communication.c:308
|  `- check_both_side_cfg                               parameters.c:1415
|
|- create_ctx                                           resources.c:2263
|  |- create_simplex_ctx or create_duplex_ctx
|  `- details below
|
|- prepare_test                                         urma_perftest.c:139
|  |- print_cfg
|  |- rearm_jfc if event mode                           urma_perftest.c:87
|  `- start dirty-write thread for selected BW tests
|
`- run_test                                             urma_perftest.c:25
   |- sync_time("Start test") for each TCP pair
   |- run command-specific setup and hot loop
   `- sync_time("End test") for each TCP pair
```

`establish_connection()`, `check_remote_cfg()`, `exchange_connection_info()`,
and the later `sync_time()` calls all use TCP. They coordinate both sides and
move descriptors; they are not the URMA data path.

### 14.2 SIMPLEX Resource Setup

```text
create_simplex_ctx                                      resources.c:1968
|- memset(ctx)
|- init_device                                          resources.c:150
|  |- urma_init
|  |- optional urma_register_log_func
|  |- urma_get_device_by_name
|  |- urma_query_device
|  |- choose priority from TP type if omitted
|  |- reject enable_user_tp on this path
|  |- urma_create_context
|  |- bonding device only:
|  |  `- urma_user_ctl(BONDP_USER_CTL_SET_BONDING_MODE)
|  `- check_dev_cap
|
|- create_simplex_jettys                                resources.c:637
|  |- create_jfc                                        resources.c:338
|  |  |- allocate jfc_s/jfc_r arrays
|  |  |- optional urma_create_jfce for send/recv events
|  |  |- create or share send JFCs with urma_create_jfc
|  |  `- create or share recv JFCs with urma_create_jfc
|  |- create_jfs                                        resources.c:408
|  |  |- fill jfs_cfg: depth, lock_free, trans_mode, priority
|  |  |- single_path -> jfs_cfg.flag.bs.multi_path = 0
|  |  `- loop jettys: urma_create_jfs
|  `- create_jfr                                        resources.c:467
|     |- fill jfr_cfg: depth, trans_mode, token, max_sge
|     `- loop jettys: urma_create_jfr
|
|- register_mem                                         resources.c:743
|  |- allocate local_buf
|  |- optional huge pages
|  |- optional urma_alloc_token_id for UB transport
|  `- loop local segments: urma_register_seg
|
|- create_credit_ctx if enable_credit                   resources.c:1879
|  |- allocate per-jetty ctrl_buf
|  |- optional urma_alloc_token_id
|  `- loop credit segments: urma_register_seg
|
|- exchange_connection_info                             resources.c:1177
|  |- exchange_seg_info over TCP                         resources.c:882
|  |- exchange_jetty_id over TCP                         resources.c:926
|  |- exchange_credit_info over TCP if credit            resources.c:976
|  |- create_tp_info if tp_aware                         resources.c:1027
|  `- exchange_tp_info over TCP if tp_aware              resources.c:1134
|
|- import_seg_for_simplex                               resources.c:1255
|  |- optional remote credit import: urma_import_seg
|  `- loop remote data segments: urma_import_seg
|
|- connect_jfr                                          resources.c:1468
|  |- default: connect_jfr_default                       resources.c:1373
|  |  |- build urma_rjfr_t or bondp_rjfr_t
|  |  |- urma_import_jfr
|  |  `- optional urma_advise_jfr for non-UB RM
|  `- tp_aware: connect_jfr_tp_aware                     resources.c:1421
|     |- build active_cfg from local/remote TP info
|     |- urma_import_jfr_ex
|     `- sync_time("tp aware connect finished")
|
`- create_run_ctx                                       resources.c:1799
   |- allocate tposted/tcompleted arrays
   `- allocate per-jetty scnt/ccnt counters
```

SIMPLEX uses separate local send and receive objects (`JFS` and `JFR`). Its
remote target import is `connect_jfr()`.

### 14.3 DUPLEX Resource Setup

```text
create_duplex_ctx                                       resources.c:2198
|- memset(ctx)
|- init_device                                          resources.c:150
|- create_duplex_jettys                                 resources.c:658
|  |- create_jfc                                        resources.c:338
|  `- create_jetty                                      resources.c:564
|     |- fill_jfs_cfg                                   resources.c:502
|     |- fill_jfr_cfg                                   resources.c:534
|     |- optional shared JFRs: urma_create_jfr
|     `- loop jettys: urma_create_jetty
|
|- register_mem                                         resources.c:743
|- create_credit_ctx if enable_credit                   resources.c:1879
|- exchange_connection_info                             resources.c:1177
|- import_seg_for_duplex                                resources.c:1304
|  |- optional remote credit import: urma_import_seg
|  `- loop remote data segments: urma_import_seg
|
|- connect_jetty                                        resources.c:1773
|  |- async: connect_jetty_async                        resources.c:1687
|  |  |- urma_create_notifier
|  |  |- loop: urma_import_jetty_async
|  |  |- wait_jetty_async
|  |  |- loop: urma_bind_jetty_async for RC
|  |  `- wait_jetty_async
|  |
|  |- tp_aware: connect_jetty_tp_aware                  resources.c:1574
|  |  |- build active_cfg from TP handles/PSNs
|  |  |- loop: urma_import_jetty_ex
|  |  |- RC only: urma_bind_jetty_ex
|  |  `- sync_time("tp aware connect finished")
|  |
|  `- default: connect_jetty_default                    resources.c:1510
|     |- build urma_rjetty_t
|     |- bonding + RM: wrap as bondp_rjetty_t
|     |- urma_import_jetty
|     |- RC only: urma_bind_jetty
|     `- non-UB RM only: urma_advise_jetty
|
|- modify_user_tp if enable_user_tp                     resources.c:2157
|  |- fill_user_tp_info                                 resources.c:2042
|  |  |- urma_get_net_addr_list
|  |  |- urma_get_tpn for each local jetty
|  |  `- sock_sync_data user TP and net address metadata
|  `- loop jettys: urma_modify_tp
|
`- create_run_ctx                                       resources.c:1799
```

DUPLEX uses one bidirectional Jetty per logical stream. For the common
`send_lat -d bonding_dev_0 --single_path` case, the active branch is the
default `connect_jetty_default()` branch, but the `urma_import_jetty()` argument
is actually a `bondp_rjetty_t` extension. The bond provider then performs extra
virtual/physical import work under that one perftest call.

### 14.4 TP-Aware Setup Expansion

`tp_aware` adds a pre-connect TP lookup and TP-info exchange. The userspace
perftest call is:

```text
exchange_connection_info                                  resources.c:1177
`- create_tp_info                                         resources.c:1027
   |- choose TP kind:
   |  |- cfg->use_ctp -> ctp
   |  |- trans_mode == UM -> utp
   |  `- otherwise -> rtp
   |- set cfg local_eid from JFS or Jetty
   |- set peer_eid from remote_jetty_id
   `- urma_get_tp_list(ctx->urma_ctx, &tp_cfg, &tp_cnt, &ctx->tp_info[i])
```

The `urma_get_tp_list()` provider/kernel path is:

```text
urma_get_tp_list                                          urma_cp_api.c:3053
`- ops->get_tp_list
   `- udma_u_ctrlq_get_tp_list                            udma_u_ctrlq_tp.c:14
      `- urma_cmd_get_tp_list                             urma_cmd.c:2931
         `- urma_ioctl_get_tp_list                        urma_cmd_tlv.c:1421
            `- ioctl URMA_CMD_GET_TP_LIST
               `- uburma_cmd_get_tp_list                  uburma_cmd.c:4508
                  `- ubcore_get_tp_list                   ubcore_tp.c:26
                     `- dev->ops->get_tp_list
                        `- udma_get_tp_list               udma_ctrlq_tp.c:652
                           `- udma_tp_cache_get_or_fetch  udma_tp_cache.c:516
                              |- cache hit: copy cached TP info
                              `- cache miss:
                                 |- udma_ctrlq_fetch_tpid_list
                                 |  `- ubase_ctrlq_send_msg(GET_TP_LIST)
                                 `- udma_ctrlq_store_tpid_list
```

That path is setup-only. It is used to feed `connect_jfr_tp_aware()` or
`connect_jetty_tp_aware()`, not to post data WQEs in the measured loop.

### 14.5 Major Setup URMA API Boundaries

```text
urma_import_seg                                           perftest resources.c:1255/:1304
`- provider import_seg
   `- urma_cmd_import_seg                                 urma_cmd.c:304
      `- urma_ioctl_import_seg                            urma_cmd_tlv.c:129
         `- uburma_cmd_import_seg                         uburma_cmd.c:1044
            `- ubcore_import_seg                          ubcore_segment.c:253
               `- dev->ops->import_seg

urma_import_jetty                                         perftest resources.c:1540
`- provider import_jetty
   |- bond provider path when `has_drv_ext` is set
   |  |- bondp_import_jetty                               bondp_api.c:1513
   |  |- virtual-side urma_cmd_import_jetty
   |  `- physical-side urma_import_jetty                  bondp_api.c:1533
   `- UDMA/core path
      `- urma_cmd_import_jetty                            urma_cmd.c:2172
         `- urma_ioctl_import_jetty                       urma_cmd_tlv.c:888
            `- uburma_cmd_import_jetty                    uburma_cmd.c:3322
               `- ubcore_import_jetty                     ubcore_jetty.c:2476
                  `- dev->ops->import_jetty

urma_import_jetty_ex                                      perftest resources.c:1608
`- urma_cmd_import_jetty_ex                               urma_cmd.c:2214
   `- urma_ioctl_import_jetty_ex                          urma_cmd_tlv.c:909
      `- uburma_cmd_import_jetty_ex                       uburma_cmd.c:4768
         `- ubcore_import_jetty or ubcore_import_jetty_ex
```

These paths explain why setup traces show `ubcore_import_seg`,
`ubcore_import_jetty`, and sometimes multiple imports for one logical perftest
object. They are not expected inside the normal `send_lat` or BW steady-state
posting loop.

## 15. Expanded Steady-State Loop Paths

The steady-state loop means the repeated work after resources and WR templates
exist. The perftest latency timestamps are written inside these loops, not in
`create_ctx()`.

### 15.1 Data-Path API Boundary

For UDMA, the hot calls normally stay in the userspace provider and touch
mapped queues/CQs:

```text
urma_post_jetty_send_wr                                  urma_dp_api.c:360
`- dp_ops->post_jetty_send_wr
   `- udma_u_post_jetty_send_wr                          udma_u_jetty.c:462
      `- udma_u_post_sq_wr

urma_post_jetty_recv_wr                                  urma_dp_api.c:379
`- dp_ops->post_jetty_recv_wr
   `- udma_u_post_jetty_recv_wr                          udma_u_jetty.c:478
      `- udma_u_post_jfr_wr

urma_poll_jfc                                            urma_dp_api.c:250
`- dp_ops->poll_jfc
   `- udma_u_poll_jfc                                    udma_u_jfc.c:743
      |- poll CQ entries with udma_u_poll_one
      `- update CQ consumer doorbell sw_db
```

With the bond provider, the virtual call first selects a physical component:

```text
bondp_post_jetty_send_wr / bondp_post_jfs_wr
`- comp_post_send                                        bondp_datapath.c:42
   |- BONDP_COMP_JETTY -> urma_post_jetty_send_wr(p_jetty[send_idx])
   `- BONDP_COMP_JFS   -> urma_post_jfs_wr(p_jfs[send_idx])
```

Event mode is the exception inside the hot loop: `wait_jfc_event()` calls
`urma_wait_jfc()`, `urma_ack_jfc()`, and `urma_rearm_jfc()` before polling.

### 15.2 Shared Per-Command WR Template Setup

```text
prepare_jfs_wr                                           run_test.c:1036
|- allocate run_ctx.jfs_wr[jettys * jfs_post_list]
|- allocate run_ctx.jfs_sge[...]
|- reset run_ctx.scnt[] and run_ctx.ccnt[]
`- for each jetty/post-list entry:
   |- init_jfs_wr_base                                   run_test.c:718
   |  |- set opcode from cmd
   |  |- set completion flag from cq_mod
   |  |- set inline flag for WRITE/SEND
   |  |- set target: import_tjfr for SIMPLEX, import_tjetty for DUPLEX
   |  `- chain wr->next for post-list batching
   `- init_jfs_wr_sg                                     run_test.c:928
      |- READ: local dst SGE + remote src SGE
      |- WRITE: local src SGE + remote dst SGE
      |- SEND: local src SGE only
      `- ATOMIC: local/remote SGEs plus CAS/FADD fields

prepare_jfr_wr                                           run_test.c:1139
|- compute rposted from jfr_depth / jfr_post_list
|- bonding/aggr: get_rqe_prefill_multiple_* may call user_ctl query port
|- allocate jfr_wr, jfr_sge, rx_buf_addr
|- init_jfr_wr for each receive WR
`- for SEND_BW only, pre-post receives before entering the BW loop

prepare_credit_wr if credit                              run_test.c:989
|- allocate credit_wr and credit SGEs
`- build WRITE WRs that update remote ctrl_buf credit counters
```

These allocations and template fills are command setup. The same WR objects are
then reused in the hot loop, with only small fields such as `user_ctx`,
completion-enable, and SGE addresses updated.

### 15.3 READ_LAT Hot Loop

```text
run_read_lat                                             run_test.c:1326
`- client side only; server returns immediately

run_read_lat_once                                        run_test.c:1306
|- prepare_jfs_wr
`- run_lat_test(worker)
   |- SIMPLEX worker: run_read_lat_simplex               run_test.c:208
   |  `- repeat until iters/duration ends:
   |     |- tposted[id * iters + scnt] = get_cycles()
   |     |- flat API: urma_read(...)
   |     |  or WR API: urma_post_jfs_wr(ctx->jfs[id], wr)
   |     |- scnt += jfs_post_list
   |     `- poll_jfc_until_expected_cqe
   |        |- optional wait_jfc_event on jfce_s[id]
   |        `- loop urma_poll_jfc(ctx->jfc_s[id])
   |
   `- DUPLEX worker: run_read_lat_duplex                 run_test.c:1248
      `- repeat until iters/duration ends:
         |- tposted[...] = get_cycles()
         |- update wr[i].user_ctx
         |- urma_post_jetty_send_wr(ctx->jetty[id], wr)
         |- scnt += jfs_post_list
         `- poll_jfc_until_expected_cqe on jfc_s[id]
```

READ latency is one-sided: only the client posts read operations. The measured
completion is the send/completion CQE for that read WR.

### 15.4 WRITE_LAT Hot Loop

```text
run_write_lat                                            run_test.c:1455
|- if enable_imm: run_send_lat
`- run_write_lat_once
   |- prepare_jfs_wr
   `- run_lat_test(worker)
      |- SIMPLEX: run_write_lat_simplex                  run_test.c:279
      `- DUPLEX:  run_write_lat_duplex                   run_test.c:1353
```

Both SIMPLEX and DUPLEX WRITE_LAT use the same ping-pong shape:

```text
repeat until send/complete/receive counters are done:
|- receive-side turn:
|  |- skip first wait on the side that sends first
|  `- spin on local poll_buf until peer's RDMA WRITE changes marker byte
|
|- send-side turn:
|  |- timestamp tposted
|  |- update local post_buf marker byte
|  |- update wr[i].user_ctx
|  |- SIMPLEX: urma_post_jfs_wr(ctx->jfs[id], wr)
|  `- DUPLEX:  urma_post_jetty_send_wr(ctx->jetty[id], wr)
|
`- completion side:
   `- poll_jfc_until_expected_cqe on jfc_s[id]
```

The receive indication is memory polling, not a receive CQE. The send side
still polls its send JFC for completion.

### 15.5 SEND_LAT Hot Loop

SEND_LAT has an explicit receive queue on both sides. Before the loop, both
sides pre-post receives and synchronize:

```text
run_send_lat_once                                        run_test.c:1647
|- prepare_jfs_wr
|- prepare_jfr_wr
`- run_lat_test(worker)

worker pre-loop:
|- get_rqe_prefill_multiple_simplex/duplex
|  `- bonding/aggr may call urma_user_ctl(BONDP_USER_CTL_QUERY_PORT)
|- SIMPLEX: send_lat_post_recv                           run_test.c:371
|  `- urma_post_jfr_wr(ctx->jfr[id], jfr_wr)
|- DUPLEX: send_lat_post_jetty_recv                      run_test.c:1481
|  `- urma_post_jetty_recv_wr(ctx->jetty[id], jfr_wr)
`- sync_time("send_lat_post_recv")
```

SIMPLEX steady state:

```text
run_send_lat_simplex                                     run_test.c:404
`- repeat until send/receive counters are done:
   |- receive side, except client skips before first send:
   |  |- optional wait_jfc_event(jfce_r[id])
   |  |- loop until expected recv CQEs:
   |  |  |- urma_poll_jfc(ctx->jfc_r[id], ...)
   |  |  |- validate CR status
   |  |  |- first packet: set_on_first_rx
   |  |  |- rcnt += cqe_cnt
   |  |  `- accumulate used_recv_wr
   |  `- when enough recv WRs are consumed:
   |     `- send_lat_post_recv -> urma_post_jfr_wr
   |
   `- send side:
      |- timestamp tposted
      |- update wr[i].user_ctx
      |- adjust completion flag when jfs_post_list == 1
      |- urma_post_jfs_wr(ctx->jfs[id], wr)
      `- when completion expected:
         `- poll_jfc_until_expected_cqe(ctx->jfc_s[id])
```

DUPLEX steady state:

```text
run_send_lat_duplex                                      run_test.c:1501
`- repeat until send/receive counters are done:
   |- receive side, except client skips before first send:
   |  |- optional wait_jfc_event(jfce_r[id])
   |  |- loop until expected recv CQEs:
   |  |  |- urma_poll_jfc(ctx->jfc_r[id], ...)
   |  |  |- validate CR status
   |  |  |- first packet: set_on_first_rx
   |  |  |- rcnt += cqe_cnt
   |  |  `- accumulate used_recv_wr
   |  `- when enough recv WRs are consumed:
   |     `- send_lat_post_jetty_recv -> urma_post_jetty_recv_wr
   |
   `- send side:
      |- timestamp tposted
      |- update wr[i].user_ctx
      |- adjust completion flag when jfs_post_list == 1
      |- urma_post_jetty_send_wr(ctx->jetty[id], wr)
      `- when completion expected:
         `- poll_jfc_until_expected_cqe(ctx->jfc_s[id])
```

For `send_lat -n 5 -s 2 -d bonding_dev_0 --single_path`, this DUPLEX loop is
the central steady-state path. The earlier setup imports and TP queries should
not repeat per message.

### 15.6 READ/WRITE/ATOMIC_BW Hot Loop

READ_BW, non-immediate WRITE_BW, and ATOMIC_BW all use `run_bw_once()` unless
in infinite mode:

```text
run_read_bw / run_write_bw / run_atomic_bw
`- run_bw_once                                           run_test.c:3004
   |- if server side and not bidirectional:
   |  `- only sync/report; no data posting
   |- if infinite: prepare_run_bw_infinite
   `- else: prepare_run_bw_once
      |- prepare_jfs_wr
      |- optional perform_warm_up
      |- optional bidirectional before sync
      |- run_once_bw                                    run_test.c:1699
      |- optional bidirectional after sync
      |- print_bw_report
      `- optional exchange/print bidirectional report
```

`run_once_bw()` steady state:

```text
repeat while total sends or completions are outstanding:
|- posting phase across all jettys:
|  `- for each jetty:
|     `- while per-jetty outstanding + jfs_post_list <= jfs_depth:
|        |- optional rate limiter gap/burst check
|        |- optional credit window check
|        |- possibly disable completion for CQ moderation
|        |- record tposted unless no_peak
|        |- SIMPLEX: urma_post_jfs_wr(ctx->jfs[index], wr)
|        |  DUPLEX:  urma_post_jetty_send_wr(ctx->jetty[index], wr)
|        |- for small non-list WRs, advance local/remote SGE addresses
|        |- scnt[index] += jfs_post_list
|        `- possibly re-enable completion before CQ-mod boundary
|
`- completion phase:
   |- optional wait_jfc_event(jfce_s[0])
   |- urma_poll_jfc(ctx->jfc_s[0], PERFTEST_POLL_BATCH, cr)
   |- for each CQE:
   |  |- validate status
   |  |- cr_id = cr[i].user_ctx
   |  |- ccnt[cr_id] += cq_mod
   |  |- tot_ccnt += cq_mod
   |  `- record tcompleted unless no_peak
   `- duration mode may increase cfg->iters dynamically
```

The receive side of READ/WRITE/ATOMIC BW is passive in unidirectional mode.
For READ, the remote side exposes memory; for WRITE and ATOMIC, the remote side
is modified by the initiator's one-sided operations.

### 15.7 SEND_BW Client, Server, And Bidirectional Hot Loops

SEND_BW has explicit sender and receiver loops:

```text
run_send_bw                                              run_test.c:3236
`- run_send_bw_one_size                                  run_test.c:3189
   |- client or bidirectional: prepare_jfs_wr
   |- server or bidirectional: prepare_jfr_wr
   |- if credit: prepare_credit_wr
   |- if infinite: run_send_bw_infinite
   `- else: run_send_bw_once                             run_test.c:3105
      |- sync_time("send_bw_post_recv")
      |- bidirectional: run_once_bi_bw
      |- client: run_once_bw
      `- server: run_once_bw_recv
```

Unidirectional SEND_BW client steady state is the same sender loop as
`run_once_bw()` in section 15.6, except the opcode prepared in `prepare_jfs_wr()`
is SEND/SEND_IMM and the remote target is a receive queue.

Unidirectional SEND_BW server steady state:

```text
run_once_bw_recv                                         run_test.c:1903
`- repeat until received all messages:
   |- optional wait_jfc_event(jfce_r[0])
   |- do:
   |  |- urma_poll_jfc(ctx->jfc_r[0], PERFTEST_POLL_BATCH, cr)
   |  |- first packet: set_on_first_rx
   |  |- for each recv CQE:
   |  |  |- cr_id = cr[i].user_ctx
   |  |  |- validate status
   |  |  |- rcnt_pre_jetty[cr_id]++, rcnt++, unused_recv++
   |  |  |- if enough receive WRs consumed:
   |  |  |  |- SIMPLEX: urma_post_jfr_wr(ctx->jfr[cr_id], jfr_wr)
   |  |  |  `- DUPLEX:  urma_post_jetty_recv_wr(ctx->jetty[cr_id], jfr_wr)
   |  |  |- optionally advance receive SGE address
   |  |  `- if credit threshold reached:
   |  |     |- poll send JFC to clean old credit WR completions
   |  |     `- post credit WRITE WR with urma_post_jfs_wr or
   |  |        urma_post_jetty_send_wr
   |  `- repeat while poll returns CQEs
   `- on completion: record tcompleted[0]
```

Bidirectional SEND_BW steady state:

```text
run_once_bi_bw                                           run_test.c:2115
`- repeat until send completions and recv completions are done:
   |- posting phase:
   |  `- for each jetty, while send queue has room:
   |     |- optional credit window check
   |     |- optional CQ moderation flag changes
   |     |- record tposted unless no_peak
   |     |- SIMPLEX: urma_post_jfs_wr
   |     |  DUPLEX:  urma_post_jetty_send_wr
   |     `- update scnt/tot_scnt
   |
   |- recv completion phase:
   |  |- optional wait_jfc_event(jfce_r[0])
   |  |- urma_poll_jfc(ctx->jfc_r[0], jfr_depth, cr_recv)
   |  |- first server receive starts duration timer if needed
   |  |- validate CQEs
   |  |- update recv counters
   |  |- repost receive WRs with urma_post_jfr_wr or
   |  |  urma_post_jetty_recv_wr
   |  `- optionally post credit WRITE WRs
   |
   `- send completion phase:
      |- urma_poll_jfc(ctx->jfc_s[0], PERFTEST_POLL_BATCH, cr_send)
      |- distinguish credit completions by user_ctx flag
      |- update send completion counters
      `- record tcompleted unless no_peak
```

The bidirectional loop interleaves send posting, receive polling/repost, and
send-completion polling in one function. That is why traces can show send and
receive datapath calls alternating tightly.

### 15.8 Infinite BW Variants

```text
run_once_bw_infinite                                     run_test.c:2587
|- start infinite_print_thread
|- optional duration alarm
|- repeat forever until duration END_STATE:
|  |- post sends across jettys while SQ depth permits
|  |- optional credit/rate-limit checks
|  |- poll send JFC and update completions
|  `- increment cfg->iters as completions arrive
`- stop/join print thread

run_once_bw_recv_infinite                                run_test.c:2737
|- start infinite_print_thread
|- repeat forever until duration END_STATE:
|  |- poll receive JFC
|  |- first packet sets timing state
|  |- repost receive WRs
|  |- optional credit WRITE path
|  `- increment cfg->iters as receives arrive
`- stop/join print thread
```

Infinite mode replaces fixed `iters` termination with a print thread plus
duration/alarm state. The hot datapath calls are still the same post and poll
calls as the fixed-iteration BW loops.

## 16. Practical Trace Interpretation

Use this split when reading ftrace, perf, or log timestamps:

| Trace event/API | Usually belongs to | Why |
| --- | --- | --- |
| `uburma_cmd_get_tp_list`, `ubcore_get_tp_list`, `udma_ctrlq_fetch_tpid_list` | setup, `tp_aware` only | TP handles are gathered before import/bind |
| `ubcore_import_seg` | setup | remote memory metadata import before tests |
| `ubcore_import_jetty`, `ubcore_import_jfr` | setup | remote queue object import before tests |
| two `ubcore_import_jetty` events for one perftest Jetty on bonding | setup through bond provider | one logical bond import may expand to virtual + physical imports |
| `ubcore_rearm_jfc` / `urma_rearm_jfc` | prepare/event mode or event hot loop | event mode rearms completion events |
| `urma_post_jetty_send_wr`, `urma_post_jfs_wr` | steady-state hot loop | WQE posting |
| `urma_post_jetty_recv_wr`, `urma_post_jfr_wr` | SEND setup prepost and SEND receive hot loop | receive WQE prepost/repost |
| `urma_poll_jfc` | steady-state hot loop | CQ polling |
| TCP `sync_time` / `sock_sync_data` | barriers/report exchange | not data movement |
