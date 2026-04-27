# UMQ Architecture

UMQ ("Unified Message Queue") is the message-passing substrate underneath URPC in
the openEuler UMDK userspace stack. It owns the data-plane queue abstraction
(create / bind / post / poll / enqueue / dequeue / buf_alloc) and dispatches each
operation to one of several pluggable transport backends. This doc maps the code,
not the marketing.

Source tree: `~/Documents/Repo/ub-stack/umdk/src/urpc/` (the entire `umq/` subdir).

---

## 1. Layered view

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                APPLICATION                                  │
│           umq_init/_create/_bind/_post|_enqueue/_poll|_dequeue/_buf_alloc   │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │ public API
┌───────────────────────────────────┴─────────────────────────────────────────┐
│                FRONT-END (umq_api.c, umq_pro_api.c, umq_dfx_api.c)          │
│  - singleton globals: g_umq_inited, g_umq_config, g_umq_fws[8]              │
│  - per-instance umq_t { mode, tp_ops, pro_tp_ops, dfx_tp_ops, umqh_tp }     │
│  - dispatches every call through the trans-mode's ops table                 │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │ umq_ops_t / umq_pro_ops_t / umq_dfx_ops_t
                                    │ resolved via dlopen("libumq_<mode>.so")
                                    │ + symbol "umq_<mode>_ops_get"
┌─────────────┬──────────────┬──────┴───────┬──────────────┬──────────────────┐
│   UB / UB+  │   IB / IB+   │  IPC         │ UBMM / UBMM+ │   UCP            │
│ libumq_ub.so│ libumq_ib.so │ libumq_ipc.so│libumq_ubmm.so│ libumq_ucp.so    │
│             │              │              │              │                  │
│ umq_ub/core/│ (stub)       │ umq_ipc/     │ umq_ubmm/    │ (stub)           │
│  umq_ub_*.c │              │  umq_ipc_    │  umq_ubmm_   │                  │
│  flow_ctrl/ │              │  impl.c +    │  impl.c +    │                  │
│  private/   │              │  msg_ring    │  obmem_      │                  │
│             │              │              │  common      │                  │
│ UDMA jetty  │ IB verbs     │ POSIX shm +  │ UB shared    │ UB offload (CPU- │
│ direct;     │              │ ring buffer  │ memory via   │ side ULP, max IO │
│ max IO 64K/ │              │ between local│ OBMM/UBMM    │ 64K)             │
│ 10M (plus)  │              │ procs;       │ ownership;   │                  │
│             │              │ max IO 10M   │ 8K base/10M+ │                  │
└─────────────┴──────────────┴──────┬───────┴──────────────┴──────────────────┘
                                    │ all backends share:
┌───────────────────────────────────┴─────────────────────────────────────────┐
│                   QBUF POOL (qbuf/)         common DFX (dfx/perf.c)         │
│  umq_qbuf_pool.c (1579 LOC) — global TLS pool, 8K/16K/32K/64K blocks,       │
│                                hierarchical expand+shrink, per-thread cache │
│  umq_huge_qbuf_pool.c (534)  — huge-page pool (256 KB / 8 MB tiers)         │
│  umq_shm_qbuf_pool.c  (744)  — per-queue shared-memory pool (IPC + UBMM)    │
│  msg_ring.c           (365)  — SPSC ring used by IPC                        │
│  buffer mode: SPLIT (metadata + payload non-contig, 4K-aligned payload)     │
│              COMBINE (contiguous, latency-optimized; metadata 128 B)        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Two API surfaces (one or the other per `umq_init`)

| Feature flag | Data-plane verbs | Who replenishes RX? | Who flushes on unbind? |
|---|---|---|---|
| `UMQ_FEATURE_API_BASE` | `umq_enqueue` / `umq_dequeue` | UMQ does | UMQ does |
| `UMQ_FEATURE_API_PRO` | `umq_post` / `umq_poll` | **caller** posts RX after bind | **caller** flushes |

Pro mode trades automation for tighter control (latency, batch shape, completion-event
detection). Both ride the same `umq_buf_t` chain and qbuf-pool machinery. Headers:

- `src/urpc/include/umq/umq_api.h` — base
- `src/urpc/include/umq/umq_pro_api.h` — pro
- `src/urpc/include/umq/umq_types.h` — shared types (~620 LOC)

---

## 3. Front-end dispatch (`umq_api.c`)

`g_umq_fws[UMQ_TRANS_MODE_MAX]` is a static table of 8 framework slots:
UB, IB, UCP, IPC, UBMM, UB+, IB+, UBMM+ (`umq_api.c:61–245`).

`umq_init` walks `cfg->trans_info[]`, marks needed slots `enable=true`, then for
each enabled slot:

1. `dlopen` the `libumq_<mode>.so`
2. Resolve `umq_<mode>_ops_get` / `umq_pro_<mode>_ops_get` / `umq_<mode>_dfx_ops_get`
3. Call the ops_get to get an `umq_ops_t*` (vtable of ~30 fn pointers — see
   `transport_layer/umq_tp_api.h:19`)
4. Invoke `umq_tp_init(cfg)` to materialize per-mode device context

`umq_create` allocates a thin `umq_t` wrapper (`umq_inner.h:34`) holding `mode`,
the three ops tables, and the backend's own handle `umqh_tp`. Every subsequent
API call indirects through `umq->tp_ops->umq_tp_xxx(umq->umqh_tp, ...)`.

`UMQ_STATIC_LIB` build mode skips dlopen and links the UB backend directly — only
UB/UB+ are supported in static builds (`umq_api.c:24, 663–668, 728–733`).

The per-mode framework struct, for reference:

```c
typedef struct umq_framework {
    umq_trans_mode_t mode;
    bool enable;
    char dlopen_so_name[MAX_SO_NAME_LEN];
    void *dlhandler;
    char ops_get_funcname[MAX_FUNCNAME_LEN];
    umq_ops_get_t ops_get_func;
    umq_ops_t *tp_ops;
    uint8_t *ctx;
    char pro_ops_get_funcname[MAX_FUNCNAME_LEN];
    umq_pro_ops_get_t pro_ops_get_func;
    umq_pro_ops_t *pro_tp_ops;
    char dfx_ops_get_funcname[MAX_FUNCNAME_LEN];
    umq_dfx_ops_get_t dfx_ops_get_func;
    umq_dfx_ops_t *dfx_tp_ops;
} umq_framework_t;
```

---

## 4. Transport backends

### UB / UB+ (production path)

| File | Role |
|---|---|
| `umq_ub/core/umq_ub_impl.c` (2255 LOC) | glues all sub-pieces into the `umq_ops_t` table |
| `umq_ub/core/private/umq_ub.c` | UDMA jetty management (QP-equivalent), bind/unbind, state machine |
| `umq_ub/core/private/umq_ub_dev.c` | device init per EID; supports multiple EIDs simultaneously |
| `umq_ub/core/private/umq_pro_ub.c` | pro-API post/poll path |
| `umq_ub/core/private/umq_symbol_private.c` | `dlsym` resolution of UDMA userspace symbols |
| `umq_ub/core/flow_control/umq_ub_flow_control.c` | credit-based flow control (UB only) |
| `umq_ub/umq_ub_api.c` / `umq_ub_plus_api.c` | base- vs pro-flavour ops_get exporters |

Limits: UB max IO 64K (base) / 10M (plus); supports `UMQ_TM_RC` / `_RM` / `_UM`
TP modes (`umq_types.h:111-116`).

### IPC (`umq_ipc/`, 778 LOC core)

Local same-host inter-process transport using POSIX shared memory + a SPSC ring
(`msg_ring.c`, 365 LOC). Max IO 10 MB. Files:

- `umq_ipc/umq_ipc_impl.c` — main impl
- `umq_ipc/umq_ipc.c` — base ops_get
- `umq_ipc/umq_pro_ipc.c` — pro ops_get
- `umq_ipc/umq_ipc_dfx_api.c` — DFX exporter

### UBMM / UBMM+ (`umq_ubmm/`, 869 LOC core)

UB shared-memory mode that piggybacks on the **Ownership-Based Memory Management**
spec primitive (Invalid → Write → Read transitions backed by HW
`hisi_soc_cache_maintain()`). User imports memory via `cna` + `ubmm_eid` in the
init cfg (`umq_types.h:255-256`). Files include `umq_ubmm_impl.c`,
`obmem_common.{c,h}`, plus the same pro / base / dfx api split as IPC.

Limits: UBMM 8K base / 10M plus.

### IB / IB+ / UCP

Slots exist in `g_umq_fws` and `umq_trans_mode_t` but the open-source repo ships
them as **stubs** (no `.c` impl in `src/urpc/umq/`). Reserved for IB-verbs and
UB-offload (CPU-side ULP) paths.

### Backend ops vtable

`src/urpc/include/umq/transport_layer/umq_tp_api.h:19` — `umq_ops_t` carries
~30 function pointers covering: `umq_tp_init / _uninit / _load_symbol / _create /
_destroy / _bind_info_get / _bind / _unbind / _state_set / _state_get / _buf_alloc /
_buf_free / _log_config_set / _log_config_reset / _buf_headroom_reset / _enqueue /
_dequeue / _notify / _rearm_interrupt / _wait_interrupt / _ack_interrupt /
_async_event_fd_get / _async_event_get / _aync_event_ack / _dev_add / _get_topo /
_user_ctl / _mempool_state_get / _mempool_state_refresh / _dev_info_get /
_dev_info_list_get / _dev_info_list_free / _cfg_get`.

Sister tables: `umq_pro_ops_t` (pro-API verbs) and `umq_dfx_ops_t` (perf / stats).

---

## 5. Buffer subsystem (`qbuf/`)

### Canonical metadata `umq_buf_t`

Defined at `umq_types.h:333`; 128 B = 2 cache lines.

```c
struct umq_buf {
    // cache line 0 : 64B
    umq_buf_t *qbuf_next;            // chain pointer for multi-fragment / batch
    uint64_t   umqh;                 // owning umq handle (if any)
    uint32_t   total_data_size;      // valid only on first fragment of a batch
    uint32_t   buf_size;             // total this fragment (metadata + payload)
    uint32_t   data_size;            // valid user payload bytes
    uint16_t   headroom_size;        // user header bytes
    uint16_t   first_fragment : 1;   // first fragment of a batch
    uint16_t   alloc_state    : 1;   // 0 free / 1 allocated
    uint16_t   rsvd1          : 14;
    uint32_t   token_id       : 20;  // for reference operation
    uint32_t   mempool_without_data : 1;
    uint32_t   mempool_id     : 11;  // which pool this came from
    uint32_t   token_value;
    uint64_t   status         : 32;  // umq_buf_status_t
    uint64_t   io_direction   : 2;   // 0 none / 1 TX / 2 RX
    uint64_t   rsvd3          : 30;
    uint64_t   rsvd4;
    char      *buf_data;             // points to data[0]
    // cache line 1 : 64B
    uint64_t   qbuf_ext[8];          // carries umq_buf_pro_t for pro-API extensions
    char       data[0];              // size of data should be data_size
};
```

Multi-fragment requests are a single linked chain via `qbuf_next`; only the
first fragment carries `total_data_size` and `qbuf_ext`.

### Three pools, picked by mode

- **Global TLS pool** (`umq_qbuf_pool.c`, 1579 LOC) — UB / IB / UB+ / IB+. Per-thread
  cache (capacity `tls_qbuf_pool_depth`), spills back to a global pool. Hierarchical
  block sizes (8 / 16 / 32 / 64 KB), expansion in 8 KB chunks, max 2 GB unless
  capped (`umq_buf_pool_cfg`). Default 1 GB total per `umq_memory_cfg`.
- **Huge-buffer pool** (`umq_huge_qbuf_pool.c`, 534 LOC) — overflow tier for
  >block-size requests, 256 KB / 8 MB block sizes.
- **Shared-memory pool** (`umq_shm_qbuf_pool.c`, 744 LOC) — IPC / UBMM. Per-queue
  (must pass `umqh` to `umq_buf_alloc` so the pool knows which queue's shm region
  to draw from).

### Two layout modes

- **SPLIT** (`UMQ_BUF_SPLIT`) — metadata and payload in separate regions, payload
  aligned to 4K huge-page boundary. Best for huge-page-sized requests; access via
  `buf_data` only.
- **COMBINE** (`UMQ_BUF_COMBINE`) — metadata + payload contiguous, total aligned
  to 4K. Latency-optimized; access via `data` or `buf_data`. Slightly smaller
  payload (metadata overhead).

---

## 6. Lifecycle (pro API, post/poll)

```
client                                         server
  │  umq_init(cfg)                                │  umq_init(cfg)
  │  umqh = umq_create(opt)                       │  umqh = umq_create(opt)
  │  umq_bind_info_get(umqh, &bi_local)           │  umq_bind_info_get(umqh, &bi_local)
  │ ─── exchange bindinfo over secure channel ──→ │
  │  umq_bind(umqh, bi_peer)                      │  umq_bind(umqh, bi_peer)
  │ ───────────── connection up ─────────────→    │
  │                                               │
  │  q  = umq_buf_alloc(sz, n, umqh, opt)         │
  │  umq_post(umqh, q, UMQ_IO_TX)                 │  umq_poll(umqh, UMQ_IO_RX)  ←─ data
  │  umq_poll(umqh, UMQ_IO_TX)  ─ tx complete     │  process
  │                                               │  umq_buf_free(q); umq_buf_alloc(...);
  │                                               │  umq_post(umqh, q', UMQ_IO_RX)  ← refill
  │
  │  umq_unbind(umqh); umq_destroy(umqh); umq_uninit()
```

**Why bindinfo must travel over a secure channel** when token policy is enabled:
the bindinfo carries UB token information used for receive-side authorization
(`UMQ Initialize.en.md` §"Description"). UB token rotation is per Base Spec §11.4.4.

---

## 7. Cross-cutting subsystems

- **Flow control** (UB only, opt-in via `UMQ_FEATURE_ENABLE_FLOW_CONTROL`):
  per-pair credit pool sized off the peer's RX depth; main UMQ creates the pool,
  sub-UMQs share it via `UMQ_CREATE_FLAG_SHARE_RQ` + `UMQ_CREATE_FLAG_MAIN_UMQ` /
  `UMQ_CREATE_FLAG_SUB_UMQ`. Configurable: `initial_credit`, `max_credits_request`,
  `credit_multiple`, `return_ratio`, `min_reserved_credit`, `timeout_ms`,
  `use_atomic_window`. Stats via `umq_stats_flow_control_get()`. See
  `doc/en/urpc/UMQ Flowcontrol.md`.

- **Interrupt mode** (`UMQ_MODE_INTERRUPT`): users epoll on
  `umq_async_event_fd_get(trans_info)`, then arm / wait / ack via
  `umq_rearm_interrupt` / `umq_wait_interrupt` / `umq_ack_interrupt`. Polling
  mode is the default. Per-direction selection via `UMQ_FD_IO` vs `UMQ_FD_EVENT`
  (`umq_types.h:88-91`).

- **Async events** (`umq_get_async_event` / `umq_ack_async_event`): 13 types in
  `umq_async_event_type_t` (`umq_types.h:487-501`) — `QH_ERR`, `QH_LIMIT`,
  `QH_RQ_ERR`, `QH_RQ_LIMIT`, `QH_RQ_CQ_ERR`, `QH_SQ_CQ_ERR`, `PORT_ACTIVE`,
  `PORT_DOWN`, `DEV_FATAL`, `EID_CHANGE`, `ELR_ERR`, `ELR_DONE`, `OTHER`.
  Object can't be destroyed until `umq_ack_async_event` is called. See
  `doc/en/urpc/UMQ Abnormal Event.md`.

- **DFX** (`UMQ_FEATURE_ENABLE_PERF` / `_STATS`): one perf module (latency
  quantiles up to 8 thresholds) + per-mode stats counters. Driven via
  `umq_dfx_cmd_t` (start / stop / clear / get_result); per-mode dfx ops lazily
  attached. Source: `dfx/perf.c` (~14.8 KB) + per-backend `umq_*_dfx_api.c`.

- **TP modes** (`umq_tp_mode_t`, `umq_types.h:111-116`): RC (Reliable Connection),
  RM (Reliable Message), UM (Unreliable Message) — passed through to UDMA on UB.

- **Token policy** (`UMQ_FEATURE_ENABLE_TOKEN_POLICY`): turns on UB's per-User
  TokenID/TokenValue (the rotating revocation per Base Spec §11.4.4). Bind info
  now carries token state — must be exchanged over TLS.

- **External lock injection**: `umq_external_mutex_lock_ops_register` /
  `umq_external_rwlock_ops_register` let the host program supply its own mutex /
  rwlock implementation (e.g. for integration with a coroutine runtime). Must
  be called before any other API.

---

## 8. Quick file map

| Concern | File |
|---|---|
| Public API headers | `src/urpc/include/umq/umq_api.h` (base), `umq_pro_api.h`, `umq_dfx_api.h`, `umq_types.h` |
| Backend ops vtable | `src/urpc/include/umq/transport_layer/umq_tp_api.h` (`umq_ops_t`), `umq_pro_tp_api.h`, `umq_tp_dfx_api.h` |
| Front-end dispatch | `src/urpc/umq/umq_api.c`, `umq_pro_api.c`, `umq_dfx_api.c` |
| Per-instance struct | `src/urpc/umq/umq_inner.h:34` (`umq_t`) |
| UB backend | `src/urpc/umq/umq_ub/core/umq_ub_impl.c` + `core/private/` + `core/flow_control/`; ops_get exporters at `src/urpc/umq/umq_ub_api.c`, `umq_ub_plus_api.c`, `umq_pro_ub_api.c`, `umq_pro_ub_plus_api.c`, `umq_ub_dfx_api.c`, `umq_ub_plus_dfx_api.c` |
| IPC backend | `src/urpc/umq/umq_ipc/umq_ipc_impl.c` + `umq_ipc.c` + `umq_pro_ipc.c` + `umq_ipc_dfx_api.c` + `msg_ring.c` |
| UBMM backend | `src/urpc/umq/umq_ubmm/umq_ubmm_impl.c` + `umq_ubmm.c` + `umq_ubmm_plus.c` + `umq_pro_ubmm.c` + `umq_pro_ubmm_plus.c` + `umq_ubmm_dfx_api.c` + `umq_ubmm_plus_dfx_api.c` + `obmem_common.{c,h}` |
| Buffer pools | `src/urpc/umq/qbuf/umq_qbuf_pool.c` (1579), `umq_huge_qbuf_pool.c` (534), `umq_shm_qbuf_pool.c` (744), `qbuf_list.h` |
| DFX | `src/urpc/umq/dfx/perf.{c,h}` (~14.8 KB) |
| Examples | `src/urpc/examples/umq/{umq_example.c, umq_example_base.{c,h}, umq_example_pro.{c,h}, umq_example_common.{c,h}, connection_setup_tool/}` |
| Tests | `test/urpc/umq/{test_umq_api, test_umq_perf, test_umq_ub, test_umq_ipc, test_umq_dfx}.cpp` + `test/intergration_test/test_suites/UMQ/` |
| Docs | `doc/{en,ch}/urpc/UMQ {Initialize, IO, Buffer, Flowcontrol, Abnormal Event}.md` |
| Config | `src/urpc/config/umq.conf` and `src/urpc/config/umq/` |

---

## 9. Decisive shape

A thin singleton dispatcher behind `umq_*` calls, fanning out to four real
backends (UB / UB+ / IPC / UBMM(+)), all sharing the same `umq_buf_t` chain and
qbuf-pool machinery — so the data-plane code stays backend-agnostic while
transports plug in via dlopen. The split between **base** (`enqueue/dequeue`,
UMQ-managed RX) and **pro** (`post/poll`, caller-managed RX) lets the same
machinery serve both convenience users and latency-sensitive ones without two
parallel queue stacks.

UMQ is to URPC what RDMA verbs are to NCCL: the substrate everything else stands
on. URPC's three param-passing modes (inline ≤40 KB, out-of-line value-pass,
reference-pass — Base Spec §8.5.3) all bottom out in UMQ post/poll.
