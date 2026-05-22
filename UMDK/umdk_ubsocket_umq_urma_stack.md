# UBSocket → UMQ → URMA: the full user-space call chain

_Last updated: 2026-05-22. Traced against `atomgit:ray-yang0218/ubs-comm_9477` at `d6a6a4d` (master)._

UBSocket is the LD_PRELOAD-based POSIX-socket interception layer that lets unmodified TCP applications (Apache bRPC validated, +40% over native TCP) run over UB. This doc traces the complete user-space call chain from the application's `socket()` / `writev()` / `epoll_wait()` calls down through UMQ and into URMA, with file:line citations end-to-end. It complements the existing UMDK surveys by capturing the **userspace-side** trace; the URMA primitives all bottom out into the kernel paths covered by `umdk_urma_jetty_kernel_call_trace.md`.

Source repos:
- ubsocket + the vendored UMQ used here: `git@atomgit.com:ray-yang0218/ubs-comm_9477.git` (HCOM project, hosts `src/ubsocket/` and `src/hcom/umq/`)
- canonical UMQ upstream: `git@atomgit.com:ray-yang0218/umdk.git` (`src/urpc/umq/` — same layout, periodically synced into ubs-comm)
- liburma userspace: shipped via the `umdk-urma` rpm; dlopened at runtime

Companions:
- [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md) — paired IO+FC jetty design rationale
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — EID/jetty/JFR/JFC/JFCE primer
- [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) — RC vs RM at the URMA level
- [`umdk_urma_jetty_kernel_call_trace.md`](umdk_urma_jetty_kernel_call_trace.md) — kernel-side continuation

---

## 1. TL;DR

```
Application (POSIX sockets, epoll)
        │   intercepted via LD_PRELOAD: librpc_adapter_brpc.so
        ▼
ubsocket — socket_adapter, file_descriptor, polling_epoll, brpc/* shims
        │   only the UMQ public API is used; ubsocket never sees URMA types directly
        ▼
UMQ public API — umq_init / umq_create / umq_bind / umq_buf_* / umq_get_cq_event
        │   vtable dispatch on trans_mode (UB / IB / UCP / IPC / UBMM / UB_PLUS / UBMM_PLUS)
        ▼
UMQ UB transport backend (libumq_ub.so, dlopened by libumq.so at framework init)
        │   talks to URMA exclusively through a 47-entry function-pointer table
        ▼
liburma.so — dlopened by libumq_ub.so via dlopen("liburma.so", RTLD_LAZY|RTLD_GLOBAL)
        ▼
uburma char dev → ubcore.ko → UB driver → UB silicon
```

Two key facts that aren't visible from a casual read:

1. **ubsocket has zero direct URMA references.** A grep for `urma_*` across `src/ubsocket/` returns exactly one hit, in a comment at `brpc/brpc_context.h:42` documenting the recursion guard: `Brpc::Context() -> umq_init() -> urma_init() -> epoll_creat() -> Brpc::Context()`. The comment is, effectively, the architectural diagram.
2. **Both layer boundaries are `dlopen`'d, not linked.** libumq.so dlopens transport-mode backends by name (`libumq_ub.so`, `libumq_ib.so`, …); libumq_ub.so dlopens `liburma.so` and `libtpsa.so`. Neither URMA nor any transport `.so` is a link-time dependency. Swapping which `.so` is on disk changes which transport binds — no recompile.

---

## 2. Repo layout (ubs-comm_9477)

```
ubs-comm_9477/
├── src/
│   ├── hcom/                  ← HCOM core library (RDMA/IB/TCP/SHM/UB multi-transport)
│   │   ├── api/, transport/, common/, multicast/, service_v2/, under_api/
│   │   └── umq/               ← vendored UMQ (a sync of umdk/src/urpc/umq/)
│   └── ubsocket/              ← independent product, ships as librpc_adapter_brpc.so
│       ├── 3rdparty/umq       ← symlinks/uses src/hcom/umq via add_subdirectory
│       ├── brpc/              ← bRPC-specific shims (Context, share-JFR, iobuf adapter)
│       ├── cli/, example/, trace/, unit_test/
│       └── socket_adapter.h, file_descriptor.{h,cpp}, polling_epoll.{h,cpp},
│           ubsocket_io.{h,cpp}, ub_lock_ops.{h,cpp}, ...
├── test/, tools/, doc/, build/
└── CMakeLists.txt, BUILD.bazel, build.sh, hcom.spec, ...
```

The top-level `src/CMakeLists.txt` only adds `hcom` by default; `src/ubsocket/CMakeLists.txt` is its own project. **ubsocket is a UMQ consumer, not a HCOM consumer.** Per the ubsocket README, build is two-stage:

```sh
# stage 1 — build UMQ as a standalone tree under hcom/
cd src/hcom/umq && mkdir build && cd build && cmake .. && make -j32
# produces: libumq.so, qbuf/libumq_buf.so, umq_ub/libumq_ub.so

# stage 2 — build ubsocket pointing at the UMQ headers + libs
cd src/ubsocket && mkdir build && cd build && \
  cmake -DUMQ_INCLUDE=/…/src/hcom/umq/include/umq/ \
        -DUMQ_LIB=/…/src/hcom/umq/build/src/libumq.so .. && \
  make -j32
# produces: brpc/librpc_adapter_brpc.so
```

Runtime activation (from the README):
```sh
env LD_PRELOAD=/…/librpc_adapter_brpc.so \
    UBSOCKET_TRANS_MODE=ub \
    UBSOCKET_DEV_NAME="bonding_dev_0" \
    UBSOCKET_SRC_EID="xxxx:…:0100:0000" \
    UBSOCKET_TX_DEPTH=1024 UBSOCKET_RX_DEPTH=1024 \
    ./application
```

---

## 3. ubsocket layer

### 3.1 POSIX interception

`src/ubsocket/socket_adapter.h` declares a function-pointer table covering ~60 libc symbols (`open`, `socket`, `connect`, `accept`, `read`, `writev`, `epoll_create`, `epoll_wait`, `fcntl`, `select`, `poll`, `clone`, `fork`, `sigaction`, …). On startup, each is resolved via `dlsym(RTLD_NEXT, "<name>")` and stashed as `<name>_ptr`. `OsAPiMgr::GetOriginApi()` is the accessor for invoking the originals.

`src/ubsocket/brpc/brpc_socket_adapter.h` declares the LD_PRELOAD entry points using `EXPOSE_C_DEFINE`:

```c
EXPOSE_C_DEFINE int     ubsocket_socket(int domain, int type, int protocol);
EXPOSE_C_DEFINE int     ubsocket_connect(int sock, const struct sockaddr *addr, socklen_t len);
EXPOSE_C_DEFINE int     ubsocket_accept(int sock, struct sockaddr *addr, socklen_t *len);
EXPOSE_C_DEFINE ssize_t ubsocket_writev(int fildes, const struct iovec *iov, int iovcnt);
EXPOSE_C_DEFINE ssize_t ubsocket_readv(int fildes, struct iovec *iov, int iovcnt);
EXPOSE_C_DEFINE int     ubsocket_epoll_wait(int epfd, struct epoll_event *events,
                                            int maxevents, int timeout);
/* …also send/recv/sendto/recvfrom/sendmsg/recvmsg/sendfile/fcntl/ioctl/setsockopt/
       epoll_create/epoll_create1/epoll_ctl/epoll_pwait */
```

Each shim decides per-fd whether to hand off to the recorded original libc fn (TCP fallback) or route through UMQ.

### 3.2 Process-wide setup — `Brpc::Context`

On first call, the singleton `Brpc::Context` is constructed lazily. Code path: `socket()` → `ubsocket_socket` → `Brpc::Context::GetContext()` (`src/ubsocket/brpc/brpc_context.h:34`) → `Brpc::Context::Context()` (`brpc_context.h:148-308`).

The construction body (paraphrased):

```cpp
umq_init_cfg_t umq_config;
memset_s(&umq_config, sizeof(umq_config), 0, sizeof(umq_config));
umq_config.feature        = UMQ_FEATURE_API_PRO | UMQ_FEATURE_ENABLE_FLOW_CONTROL;
umq_config.buf_mode       = UMQ_BUF_SPLIT;
umq_config.io_lock_free   = true;
umq_config.trans_info_num = 1;
umq_config.flow_control.use_atomic_window     = true;
umq_config.flow_control.initial_credit        = DEFAULT_INITIAL_CREDIT;       /* 1024 */
umq_config.flow_control.max_credits_request   = DEFAULT_MAX_CREDITS_REQUEST;  /* 1024 */
umq_config.flow_control.min_reserved_credit   = GetMinReservedCredit();
umq_config.block_cfg.small_block_size         = GetIOBlockType();              /* env */
umq_config.trans_info[0].dev_info.assign_mode = UMQ_DEV_ASSIGN_MODE_DUMMY;
umq_config.trans_info[0].mem_cfg.total_size   = GetIOTotalSize();              /* env: UBSOCKET_POOL_INITIAL_SIZE */
umq_config.trans_info[0].trans_mode           = GetTransMode();                /* UMQ_TRANS_MODE_UB | _IB */
umq_config.buf_pool_cfg.umq_buf_pool_max_size = GetPoolMaxSize();
umq_config.buf_pool_cfg.tls_qbuf_pool_depth   = GetBufPoolDepth();

int ret = umq_init(&umq_config);                                /* brpc_context.h:239 */
/* …on failure: SOCKET_FD_TRANS_MODE_TCP fallback */

/* private async-event epoll fd + drainer thread */
m_asyncEventEpollFd = OsAPiMgr::GetOriginApi()->epoll_create(1);
m_asyncEventThread  = std::thread(&Context::AsyncEventProcess, this);

/* enumerate UB or IB devices */
ret = (transMode == UMQ_TRANS_MODE_IB) ? AddIbDev(...) : AddUbDev(...);

/* fall back to TCP on any failure; otherwise SOCKET_FD_TRANS_MODE_UMQ */
```

The recursion-guard comment at line 42 — `Brpc::Context() -> umq_init() -> urma_init() -> epoll_creat() -> Brpc::Context()` — documents the only way URMA leaks into ubsocket's *vocabulary*: as a recursion-trap because `umq_init` causes `urma_init` which calls `epoll_create` which is itself wrapped.

`src/ubsocket/ub_lock_ops.cpp:239,259` then registers ubsocket-owned mutex / rwlock implementations *down into* UMQ:

```c
umq_external_mutex_lock_ops_register(&umq_mutex_ops);
umq_external_rwlock_ops_register   (&umq_rwlock_ops);
```

so UMQ uses ubsocket-supplied primitives for its own internal state (matching the bRPC threading model).

### 3.3 Per-connection lifecycle

Each application-level socket gets a `BrpcFileDescriptor` (`src/ubsocket/brpc/brpc_file_descriptor.h`) that owns:
- `int m_fd` — the **real** TCP fd (still kept; used for OOB control plane during bind, and for TCP-fallback paths)
- `uint64_t m_local_umqh` — the UMQ instance handle (one per connection in non-shared mode; sub-UMQ in share-JFR mode)
- per-fd state: peer EID, peer IP, share-JFR membership, flow-control window, qbuf queues

The handshake (excerpted from `brpc_file_descriptor.h:670-734`):

```cpp
/* 1. TCP handshake completes normally on the original fd. */

/* 2. Each side has already done umq_create(); produce its bind blob. */
uint8_t  local_bind_blob[UMQ_BIND_INFO_SIZE_MAX];                 /* 512 B */
uint32_t local_blob_sz = umq_bind_info_get(m_local_umqh,
                                           local_bind_blob,
                                           sizeof(local_bind_blob));

/* 3. Exchange blobs over TCP. */
local_cp_msg.queue_bind_info_size = local_blob_sz;
memcpy(local_cp_msg.queue_bind_info, local_bind_blob, local_blob_sz);
SendSocketData(m_fd, &local_cp_msg.queue_bind_info_size,
               sizeof(local_cp_msg) - sizeof(uint64_t),
               CONTROL_PLANE_TIMEOUT_MS);
RecvSocketData(m_fd, &remote_cp_msg, sizeof(remote_cp_msg),
               CONTROL_PLANE_TIMEOUT_MS);

/* 4. Bring up the UMQ peering. */
int umq_ret = umq_bind(m_local_umqh,
                       remote_cp_msg.queue_bind_info,
                       remote_cp_msg.queue_bind_info_size);     /* brpc_file_descriptor.h:702 */
/* …error handling, retryable fallback to TCP… */

/* 5. Share-JFR: pre-fill the main UMQ's shared receive ring */
if (Context::GetContext()->EnableShareJfr()) {
    auto main_umq = EidUmqTable::GetFirst(m_conn_info.conn_eid, GetUbTransMode());
    return main_umq->EnsurePrefilled([this] { return PrefillRx(); });
}
```

The `umq_create` call lives in `brpc_file_descriptor.h:3418/3437/3452`, distinguishing main vs sub UMQ:

```cpp
if (is_main) return umq_create(&cfg_main);            /* one per (device, trans_mode) */
if (is_sub_share_jfr) {                               /* per-connection in share-JFR mode */
    cfg->share_rq_umqh = main_umq->GetUmqHandle();
    return umq_create(cfg);
}
return umq_create(cfg);                               /* per-connection, no sharing */
```

### 3.4 RX dispatch via epoll

ubsocket implements its own polling multiplexer in `src/ubsocket/polling_epoll.cpp`. When the app calls `epoll_wait` (intercepted), ubsocket dispatches both real-fd events *and* UMQ-eventfd events using the `EpollEvent` hierarchy:
- `BrpcFileDescriptorEpollEvent` for individual UB sockets
- `ShareJfrRxEpollEvent` for the shared-JFR receive ring (one per (device, trans_mode))
- `ShareJfrEventFdEpollEvent` for the eventfd that wakes the share-JFR loop

The fd backing each UMQ-side event source is obtained by:
- `umq_async_event_fd_get(&info)` — async device events (link state, etc.) — used by `Brpc::Context::AsyncEventProcess` (`brpc_context.cpp:263`)
- `umq_interrupt_fd_get(umqh, &option)` — JFCE eventfd for CQ-event delivery (per direction and per FC/IO)

The hot loop is in `src/ubsocket/brpc/brpc_share_jfr.cpp`:

```cpp
/* drain notification */
umq_ack_interrupt(m_main_umq, event_num, option);                /* line 238 */

/* find out how many CQ events arrived */
int events = umq_get_cq_event(m_main_umq, &option);              /* line 246 */
/* …on failure log + bail… */

/* refill the shared RX ring */
umq_buf_t *rx_buf_list = umq_buf_alloc(BrpcIOBufSize(),
                                       ioPollNum,
                                       UMQ_INVALID_HANDLE,
                                       &option);                  /* line 299 */
/* …post via the public umq_post / umq_enqueue path… */
umq_buf_free(bad_qbuf);                                           /* line 313 */
```

Every `GET_PER_ACK=32` events the loop acks; `POLL_BATCH_MAX=32` bounds per-iteration drain (matching bRPC's batching).

### 3.5 UMQ-side API surface actually used

A `grep -rho 'umq_[a-zA-Z0-9_]*' src/ubsocket/ | sort -u` yields ~60 distinct symbols. Grouped:

| Area | Calls used |
| --- | --- |
| Lifecycle | `umq_init`, `umq_create`, `umq_bind`, `umq_bind_info_get`, `umq_destroy` |
| Buffers | `umq_buf_alloc`, `umq_buf_free`, `umq_buf_list_*`, `umq_buf_cache_head/tail`, `umq_buf_pool_max_size`, `umq_alloc_option_t` |
| Completion/events | `umq_get_cq_event`, `umq_get_async_event`, `umq_async_event_fd_get`, `umq_interrupt_fd_get`, `umq_ack_interrupt`, `umq_ack_async_event` |
| Devices / topology | `umq_dev_info_get`, `umq_dev_info_list_get/free`, `umq_get_route_list` |
| Config / DFx | `umq_cfg_get`, `umq_init_cfg_t`, `umq_create_option_t`, `umq_flow_control_stats_t`, `umq_dfx_api` |
| Pluggable locks | `umq_external_mutex_lock_ops_register`, `umq_external_rwlock_ops_register` |

URMA's JFS / JFR / JFC, RC vs UM jetty selection, EID resolution, segment registration are **entirely hidden behind UMQ**. Even the endpoint-ID type that leaks into share-JFR vocabulary is `umq_eid_t`, not the underlying `urma_eid_t` (the two are layout-compatible but distinct).

---

## 4. UMQ layer

### 4.1 Public API dispatch

`src/hcom/umq/src/umq_api.c` and `src/hcom/umq/src/umq_pro_api.c` host the public API. State lives in:

```c
static umq_framework_t g_umq_fws[UMQ_TRANS_MODE_MAX] = {        /* umq_api.c:61 */
    [UMQ_TRANS_MODE_UB]      = { .dlopen_so_name = "libumq_ub.so",
                                 .ops_get_funcname     = "umq_ub_ops_get",
                                 .pro_ops_get_funcname = "umq_pro_ub_ops_get",
                                 .dfx_ops_get_funcname = "umq_ub_dfx_ops_get",   ... },
    [UMQ_TRANS_MODE_IB]      = { .dlopen_so_name = "libumq_ib.so",    ... },
    [UMQ_TRANS_MODE_UCP]     = { .dlopen_so_name = "libumq_ucp.so",   ... },
    [UMQ_TRANS_MODE_IPC]     = { .dlopen_so_name = "libumq_ipc.so",   ... },
    [UMQ_TRANS_MODE_UBMM]    = { .dlopen_so_name = "libumq_ubmm.so",  ... },
    [UMQ_TRANS_MODE_UB_PLUS] = { .dlopen_so_name = "libumq_ub.so",    ... },  /* same .so, plus vtable */
    /* … */
};
```

`umq_init` (`umq_api.c:626`) walks `cfg->trans_info[]`, marks `g_umq_fws[mode].enable = true` for each requested mode, then calls `umq_framework_init` (`umq_api.c:486`) per enabled framework. That fn `dlopen`s the backend `.so`, resolves three vtables via `dlsym`:

```c
umq_fw->ops_get_func     = dlsym(umq_fw->dlhandler, umq_fw->ops_get_funcname);      /* base tp_ops */
umq_fw->pro_ops_get_func = dlsym(umq_fw->dlhandler, umq_fw->pro_ops_get_funcname);  /* pro tp_ops */
umq_fw->dfx_ops_get_func = dlsym(umq_fw->dlhandler, umq_fw->dfx_ops_get_funcname);  /* DFx tp_ops */
umq_fw->tp_ops     = umq_fw->ops_get_func();
umq_fw->pro_tp_ops = umq_fw->pro_ops_get_func();
```

Calls then dispatch:

```c
int  umq_create(...)        { return umq->tp_ops->umq_tp_create(...); }
int  umq_bind(umqh, blob, sz){ return umq->tp_ops->umq_tp_bind(umq->umqh_tp, blob, sz); }
int  umq_enqueue(...)       { return umq->tp_ops->umq_tp_enqueue(umq->umqh_tp, qbuf, bad_qbuf); }   /* umq_api.c:1050 */
umq_buf_t *umq_dequeue(...) { return umq->tp_ops->umq_tp_dequeue(umq->umqh_tp); }                    /* umq_api.c:1075 */
int  umq_get_cq_event(...)  { return umq->pro_tp_ops->umq_tp_get_cq_event(umq->umqh_tp, option); }   /* umq_pro_api.c:75 */
```

### 4.2 UB-backend vtables

The UB backend lives in `src/hcom/umq/src/umq_ub/`:

```
umq_ub_api.c           ← base tp_ops vtable
umq_pro_ub_api.c       ← pro tp_ops vtable
umq_ub_dfx_api.c       ← DFx tp_ops vtable
umq_ub_plus_api.c      ← variant (UB_PLUS)
umq_pro_ub_plus_api.c  ← variant (pro UB_PLUS)
core/
  umq_ub_imm_data.h
  umq_ub_impl.c        ← top-level impls; ctx init, create, bind dispatch, enqueue/dequeue, JFC mgmt
  umq_ub_impl.h
  private/
    umq_ub.c           ← jetty + JFR + JFC create, import/bind jetty, fill_wr, poll_jfc
    umq_ub_dev.c       ← urma_get_device_list, urma_query_device
    umq_pro_ub.c       ← pro-API impls (post / poll / interrupt_fd_get / get_cq_event)
    umq_symbol_private.c/h ← dlopen liburma.so + libtpsa.so, dlsym all URMA fns
  flow_control/
```

The base vtable (`umq_ub_api.c:204-241`):

```c
static umq_ops_t g_umq_ub_ops = {
    .mode = UMQ_TRANS_MODE_UB,

    /* control plane */
    .umq_tp_load_symbol     = umq_tp_ub_symbol_load,    /* dlopen liburma/libtpsa, dlsym all */
    .umq_tp_init            = umq_tp_ub_init,
    .umq_tp_uninit          = umq_tp_ub_uninit,
    .umq_tp_create          = umq_tp_ub_create,
    .umq_tp_destroy         = umq_tp_ub_destroy,
    .umq_tp_bind_info_get   = umq_tp_ub_bind_info_get,
    .umq_tp_bind            = umq_tp_ub_bind,
    .umq_tp_unbind          = umq_tp_ub_unbind,
    .umq_tp_state_set       = umq_tp_ub_state_set,
    .umq_tp_state_get       = umq_tp_ub_state_get,
    .umq_tp_dev_add         = umq_tp_ub_dev_add_impl,
    .umq_tp_get_topo        = umq_tp_ub_get_route_list_impl,
    .umq_tp_dev_info_get    = umq_tp_ub_dev_info_get,
    .umq_tp_dev_info_list_get  = umq_tp_ub_dev_info_list_get,
    .umq_tp_dev_info_list_free = umq_tp_ub_dev_info_list_free,
    /* …mempool/buf-headroom/log/cfg… */

    /* datapath */
    .umq_tp_buf_alloc       = umq_tp_ub_buf_alloc,
    .umq_tp_buf_free        = umq_tp_ub_buf_free,
    .umq_tp_enqueue         = umq_tp_ub_enqueue,
    .umq_tp_dequeue         = umq_tp_ub_dequeue,
    .umq_tp_notify          = umq_tp_ub_notify,
    .umq_tp_rearm_interrupt = umq_tp_ub_rearm_interrupt,
    .umq_tp_wait_interrupt  = umq_tp_ub_wait_interrupt,
    .umq_tp_ack_interrupt   = umq_tp_ub_ack_interrupt,
    .umq_tp_async_event_fd_get = umq_tp_ub_async_event_fd_get,
    .umq_tp_async_event_get    = umq_tp_ub_async_event_get,
    .umq_tp_aync_event_ack     = umq_tp_ub_async_event_ack,
};
umq_ops_t *umq_ub_ops_get(void) { return &g_umq_ub_ops; }
```

The pro vtable (`umq_pro_ub_api.c:32-38`) adds:

```c
static umq_pro_ops_t g_umq_pro_ub_ops = {
    .mode                    = UMQ_TRANS_MODE_UB,
    .umq_tp_post             = umq_tp_ub_post,            /* umq_ub_post_impl */
    .umq_tp_poll             = umq_tp_ub_poll,            /* umq_ub_poll_impl */
    .umq_tp_interrupt_fd_get = umq_tp_ub_interrupt_fd_get,
    .umq_tp_get_cq_event     = umq_tp_ub_get_cq_event,    /* umq_ub_get_cq_event_impl */
};
```

Every `umq_tp_*` fn is a one-liner wrapper around the corresponding `umq_ub_*_impl` in `core/`.

### 4.3 The URMA-bridge struct

`src/hcom/umq/src/umq_ub/core/private/umq_symbol_private.h` declares the URMA bridge — a 47-entry function-pointer struct holding every URMA symbol UMQ uses:

```c
typedef struct umq_symbol_urma {
    /* Device/Init */
    urma_init_t              urma_init;
    urma_uninit_t            urma_uninit;
    urma_get_device_list_t   urma_get_device_list;
    urma_free_device_list_t  urma_free_device_list;
    urma_get_eid_list_t      urma_get_eid_list;
    urma_free_eid_list_t     urma_free_eid_list;
    urma_query_device_t      urma_query_device;
    urma_create_context_t    urma_create_context;
    urma_delete_context_t    urma_delete_context;

    /* JFC (completion queue) */
    urma_create_jfc_t  urma_create_jfc;
    urma_delete_jfc_t  urma_delete_jfc;
    urma_rearm_jfc_t   urma_rearm_jfc;
    urma_poll_jfc_t    urma_poll_jfc;
    urma_wait_jfc_t    urma_wait_jfc;
    urma_ack_jfc_t     urma_ack_jfc;

    /* JFCE (completion-event channel) */
    urma_create_jfce_t urma_create_jfce;
    urma_delete_jfce_t urma_delete_jfce;

    /* JFR (receive queue) */
    urma_create_jfr_t  urma_create_jfr;
    urma_delete_jfr_t  urma_delete_jfr;
    urma_modify_jfr_t  urma_modify_jfr;

    /* Jetty (SQ+RQ combo) */
    urma_create_jetty_t        urma_create_jetty;
    urma_delete_jetty_t        urma_delete_jetty;
    urma_modify_jetty_t        urma_modify_jetty;
    urma_bind_jetty_t          urma_bind_jetty;
    urma_unbind_jetty_t        urma_unbind_jetty;
    urma_import_jetty_t        urma_import_jetty;
    urma_unimport_jetty_t      urma_unimport_jetty;
    urma_flush_jetty_t         urma_flush_jetty;
    urma_post_jetty_send_wr_t  urma_post_jetty_send_wr;
    urma_post_jetty_recv_wr_t  urma_post_jetty_recv_wr;
    urma_post_jfr_wr_t         urma_post_jfr_wr;

    /* Segment (memory region) */
    urma_register_seg_t   urma_register_seg;
    urma_unregister_seg_t urma_unregister_seg;
    urma_import_seg_t     urma_import_seg;
    urma_unimport_seg_t   urma_unimport_seg;

    /* Async event */
    urma_get_async_event_t  urma_get_async_event;
    urma_ack_async_event_t  urma_ack_async_event;

    /* Log, UserCtl, Utility, UVS path-set, DFx perf… */
    urma_log_set_level_t        urma_log_set_level;
    urma_register_log_func_t    urma_register_log_func;
    urma_unregister_log_func_t  urma_unregister_log_func;
    urma_user_ctl_t             urma_user_ctl;
    urma_str_to_eid_t           urma_str_to_eid;
    uvs_get_path_set_t          uvs_get_path_set;           /* from libtpsa.so */
    urma_start_perf_t           urma_start_perf;
    urma_stop_perf_t            urma_stop_perf;
    urma_get_perf_info_t        urma_get_perf_info;
} umq_symbol_urma_t;
```

The loader (`umq_symbol_private.c:32-128`):

```c
static umq_symbol_urma_t g_umq_symbol_urma = {0};
static void *g_umq_urma_dlhandler = NULL;
static void *g_umq_tpsa_dlhandler = NULL;

#define LOAD_SYMBOL(sym, handle, type, name) \
    do { sym->name = (type)dlsym(handle, #name); \
         if (sym->name == NULL) { /* warn */ return -1; } } while (0)

int umq_symbol_urma_load(umq_symbol_urma_t *sym) {
    if (g_umq_urma_dlhandler == NULL) {
        g_umq_urma_dlhandler = dlopen("liburma.so", RTLD_LAZY | RTLD_GLOBAL);
        if (g_umq_urma_dlhandler == NULL) return -1;
    }
    if (g_umq_tpsa_dlhandler == NULL) {
        g_umq_tpsa_dlhandler = dlopen("libtpsa.so", RTLD_LAZY | RTLD_GLOBAL);
        if (g_umq_tpsa_dlhandler == NULL) return -1;
    }
    LOAD_SYMBOL(sym, g_umq_urma_dlhandler, urma_init_t,             urma_init);
    LOAD_SYMBOL(sym, g_umq_urma_dlhandler, urma_uninit_t,           urma_uninit);
    LOAD_SYMBOL(sym, g_umq_urma_dlhandler, urma_get_device_list_t,  urma_get_device_list);
    /* …all 47 entries… */
    LOAD_SYMBOL(sym, g_umq_tpsa_dlhandler, uvs_get_path_set_t,      uvs_get_path_set);
    return 0;
}
```

Every URMA call site in the UB backend goes through `umq_symbol_urma()->urma_<x>(…)`. There is no `urma_<x>(…)` call anywhere in libumq_ub.so — it's `dlsym` or nothing.

---

## 5. End-to-end call chain (per lifecycle event)

### 5.1 Process startup

```
LD_PRELOAD intercepts first socket() →
  Brpc::Context::GetContext()                              brpc_context.h:34
    └─ Brpc::Context::Context()                            brpc_context.h:148-308
       ├─ build umq_init_cfg_t (env-driven)
       └─ umq_init(&cfg)                                    umq_api.c:626
          ├─ umq_buf_size_pow_small_set(...)
          ├─ for each trans_info[i].trans_mode: g_umq_fws[mode].enable = true
          ├─ umq_thread_init(cfg)
          └─ for each enabled framework: umq_framework_init  umq_api.c:486
             ├─ dlopen("libumq_ub.so")
             ├─ dlsym("umq_ub_ops_get"),     "umq_pro_ub_ops_get",    "umq_ub_dfx_ops_get"
             ├─ tp_ops = umq_ub_ops_get()                  umq_ub_api.c:243
             ├─ tp_ops->umq_tp_load_symbol = umq_tp_ub_symbol_load    umq_ub_api.c:19
             │     └─ umq_symbol_urma_load()               umq_symbol_private.c:32
             │        ├─ dlopen("liburma.so", RTLD_LAZY|RTLD_GLOBAL)
             │        ├─ dlopen("libtpsa.so", …)
             │        └─ LOAD_SYMBOL × 47   (all URMA + UVS fns)
             └─ tp_ops->umq_tp_init(cfg) = umq_tp_ub_init   umq_ub_api.c:30
                ├─ umq_ub_ctx_init_impl(cfg)               umq_ub_impl.c:582
                │  ├─ umq_symbol_urma()->urma_init(&init_attr)        umq_ub_impl.c:602   ◀── first URMA call
                │  ├─ umq_ub_dev_info_init()
                │  │  └─ umq_symbol_urma()->urma_get_device_list()    umq_ub_dev.c:97
                │  └─ for each trans_info[i] (per device):
                │     umq_find_ub_device → urma_query_device
                │     └─ umq_symbol_urma()->urma_create_context(urma_dev, eid_index)  umq_ub.c:946
                └─ umq_ub_register_memory_impl(umq_io_buf_addr(), umq_io_buf_size())   umq_ub_impl.c:195
                   └─ umq_symbol_urma()->urma_register_seg(urma_ctx, &seg_cfg)         umq_ub.c:1654
       /* …then start AsyncEventProcess thread, AddUbDev(), set SOCKET_FD_TRANS_MODE_UMQ… */
```

The IO pool (`UBSOCKET_POOL_INITIAL_SIZE` MB, default 1024 MB; growable to `UBSOCKET_POOL_MAX_SIZE`) is registered **once, whole**. Every per-message qbuf is a slot inside that single segment, so no further `urma_register_seg` is needed on the hot path (slot → `sges[].tseg = tseg_list[mempool_id]` at WR-fill time).

### 5.2 Per-connection setup

```
ubsocket_connect(fd, addr, len)                            brpc/brpc_socket_adapter.h
  → real TCP connect on m_fd
  → m_local_umqh = umq_create(cfg_sub)                     brpc_file_descriptor.h:3437
     └─ umq->tp_ops->umq_tp_create                          umq_api.c
        └─ umq_tp_ub_create                                  umq_ub_api.c:59
           └─ umq_ub_create_impl                              umq_ub_impl.c:914
              ├─ umq_ub_jfr_ctx_get
              │   if (option->create_flag & UMQ_CREATE_FLAG_SHARE_RQ)
              │       ↳ reuse share_rq_umqh's JFR context (no new urma_create_jfr)
              │   else:
              │       ├─ if MODE_INTERRUPT: urma_create_jfce(urma_ctx)         umq_ub.c:1513
              │       ├─ urma_create_jfc (RX CQ)                                umq_ub.c:1528
              │       └─ urma_create_jfr                                        umq_ub.c:1544
              ├─ if MODE_INTERRUPT and not sharing: urma_create_jfce            umq_ub_impl.c:961
              ├─ urma_create_jfc (TX CQ, depth = tx_depth+1)                    umq_ub_impl.c:972
              ├─ umq_create_jetty(...) → urma_create_jetty(urma_ctx, cfg)       umq_ub.c:1122
              └─ if flow_control.enabled:
                 urma_create_jfc (FC CQ)                                        umq_ub_impl.c:845
                 urma_create_jetty (FC jetty) — see umdk_umq_jetty_pair_design.md

  → umq_bind_info_get(local_umqh, blob, max)
     └─ umq_tp_ub_bind_info_get → umq_ub_bind_info_serialize    umq_ub_impl.c:162
        packs { eid, jetty_id, tp_mode (RC/RM), tp_type, token,
                fc_info, notify_buf, order_type, … }

  → SendSocketData / RecvSocketData over m_fd (TCP)               brpc_file_descriptor.h:680-698
                       — control-plane exchange of bind blobs

  → umq_bind(m_local_umqh, remote.queue_bind_info, sz)            brpc_file_descriptor.h:702
     └─ umq_tp_ub_bind                                              umq_ub_api.c:74
        └─ umq_ub_bind_impl                                          umq_ub_impl.c:174
           ├─ umq_ub_bind_info_deserialize  (blob → umq_ub_bind_info_t)
           ├─ umq_ub_window_init  (flow-control credits)
           └─ umq_ub_bind_inner_impl(queue, info)                    umq_ub.c:540
              └─ umq_ub_connect_jetty(queue, info, UB_QUEUE_JETTY_IO)   umq_ub.c:480
                 ├─ build bondp_rjetty from info->{eid, jetty_id, tp_mode, tp_type, token, …}
                 ├─ tjetty = umq_symbol_urma()->urma_import_jetty(
                 │              urma_ctx, &bondp_rjetty.base, &token)     umq_ub.c:503
                 └─ if queue->tp_mode == URMA_TM_RC:
                       umq_symbol_urma()->urma_bind_jetty(
                           queue->jetty[IO], tjetty)                      umq_ub.c:515    ◀── RC pairing
              /* and the FC jetty too, if flow_control enabled */

  → PrefillRx()  (post initial RX buffers; RC-mode can't do this before bind)
     └─ umq_buf_alloc + umq_post(RX) →
        in umq_pro_ub.c:571-573, depending on shared vs per-jetty JFR:
           shared:  umq_symbol_urma()->urma_post_jfr_wr(jfr_ctx->jfr, wr, &bad_wr)
           per:     umq_symbol_urma()->urma_post_jetty_recv_wr(queue->jetty[IO], wr, &bad_wr)
```

The `umq_ub_bind_info_t` blob (≤ 512 B per `UMQ_BIND_INFO_SIZE_MAX`) is exactly the URMA-level peering info, opaquely serialized. TCP is just the OOB carrier — same pattern IB/RoCE has used for two decades with QPN/PSN exchange.

### 5.3 Send path (writev)

```
ubsocket_writev(fd, iov, iovcnt)                           brpc/brpc_socket_adapter.h
  → BrpcSocketAdapter::Writev → UbsocketWritev              ubsocket_io.h:34-44
       frames as: UbsocketMsgHeader { msgId, payloadLen, checksum, msgType=REQUEST/RESPONSE }
  → umq_buf_alloc(size, qbuf_num=1, umqh, &opt)              umq_api.c → umq_tp_ub_buf_alloc
       └─ umq_ub_buf_alloc_impl                                umq_ub_impl.c:231
          └─ umq_qbuf_alloc — pull from the pre-registered IO pool
  → memcpy iov bytes into qbuf->buf_data (registered memory)
  → umq_enqueue(umqh, qbuf, &bad_qbuf)                       umq_api.c:1050
     └─ tp_ops->umq_tp_enqueue → umq_tp_ub_enqueue → umq_ub_enqueue_impl   umq_ub_impl.c:1408
        ├─ umq_ub_enqueue_with_poll_tx (opportunistic completion drain to free slots)
        ├─ umq_ub_fill_wr_impl(qbuf, queue, urma_wr, sges, remain_tx)       umq_ub.c:3147
        │     one urma_jfs_wr_t per qbuf:
        │       - opcode = URMA_OPC_SEND        (line 3236, small two-sided)
        │              | URMA_OPC_SEND_IMM      (line 3068, send + immediate data)
        │              | URMA_OPC_WRITE_IMM     (line 3119, one-sided RDMA write w/ imm)
        │              | URMA_OPC_READ          (line 2094, RNDV pull for large messages)
        │       - sges[].tseg = tseg_list[mempool_id]   ← zero-copy via pre-registered seg
        │       - wr->user_ctx = qbuf                    ← so completion finds the qbuf
        │       - wr->tjetty  = bind_ctx->tjetty[IO]     ← imported target jetty from bind
        └─ umq_symbol_urma()->urma_post_jetty_send_wr(
              queue->jetty[IO], urma_wr, &bad_wr)                            umq_ub_impl.c:1442
           — single batched submission to UBCore via uburma char dev → UB silicon
```

### 5.4 Receive path (epoll → poll → deliver)

```
Application: epoll_wait(epfd, …) ← wrapped by ubsocket_epoll_wait
  ↳ ubsocket dispatches the JFCE eventfd for the shared RX (or per-jetty RX):
     ShareJfrRxEpollEvent::ProcessEpollEvent                  brpc/brpc_share_jfr.cpp
        └─ umq_get_cq_event(main_umq, &option)                umq_pro_api.c:75
           └─ pro_tp_ops->umq_tp_get_cq_event                  umq_pro_ub_api.c:37
              └─ umq_ub_get_cq_event_impl                       umq_ub_impl.c:1167
                 └─ umq_ub_wait_interrupt_impl(-1)              umq_ub_impl.c:1172  (timeout=-1: fd already readable)
                    ├─ urma_wait_jfc(jfce, jfc_cnt, time_out, temp_jfc)   umq_ub.c:3316/3347
                    │     — drains the JFCE eventfd, reports which JFCs have new CQEs
                    └─ urma_ack_jfc(temp_jfc, nevents, p_num)              umq_ub.c:3333/3363

  ↳ Poll-and-deliver loop:
     umq_dequeue(umqh)                                         umq_api.c:1075
       └─ tp_ops->umq_tp_dequeue → umq_tp_ub_dequeue → umq_ub_dequeue_impl     umq_ub_impl.c:1526
          ├─ umq_ub_dequeue_with_poll_rx
          │    └─ urma_poll_jfc(jfr_jfc, batch=UMQ_POST_POLL_BATCH, cr[])      umq_ub.c:2801
          │       for each cr: qbuf = cr->user_ctx; payload at qbuf->buf_data
          └─ umq_ub_fill_rx_buffer(queue, rx_cnt)                              umq_ub.c:2755
             └─ umq_buf_alloc + urma_post_jfr_wr (shared) | urma_post_jetty_recv_wr (per)
                                                                                umq_pro_ub.c:571/573

  ↳ ubsocket pushes qbuf payloads into a per-fd qbuf_queue (brpc/qbuf_queue.h)
     and signals the bRPC iobuf adapter (brpc/brpc_iobuf_adapter.cpp).
  ↳ Every GET_PER_ACK=32 events: umq_ack_interrupt(main_umq, n, &option)
        → urma_ack_jfc

  ↳ Application's epoll_wait returns POLLIN on the bRPC fd
  ↳ App calls readv() → ubsocket_readv pulls already-delivered bytes from the qbuf_queue
        (no URMA call on this fast path; the data has already been DMAed by the NIC)
```

The two completion-drain modes (busy poll vs interrupt) share the same URMA primitives:

- **Busy poll** (`UBSOCKET_POLLING_*`): repeated `urma_poll_jfc` with no JFCE involvement.
- **Interrupt**: `urma_rearm_jfc` → epoll_wait on JFCE fd → `urma_wait_jfc` + `urma_ack_jfc` → `urma_poll_jfc` (drain CRs) → repeat.

ubsocket's `umq_get_cq_event` is the post-eventfd-fires leaf; it consumes the notification and reports how many JFCs have new events, while the subsequent `umq_dequeue` does the actual CR-read.

### 5.5 Teardown

```
ubsocket close(fd) →
  umq_destroy(umqh)                                             umq_api.c
    └─ tp_ops->umq_tp_destroy → umq_tp_ub_destroy → umq_ub_destroy_impl
       ├─ umq_ub_disconnect_jetty                                umq_ub.c:531
       │   ├─ if tp_mode == URMA_TM_RC: urma_unbind_jetty(jetty[i])
       │   └─ urma_unimport_jetty(ctx->tjetty[i])
       ├─ urma_delete_jetty                                      (umq_ub.c destroy paths)
       ├─ urma_delete_jfc                                        (TX CQ and FC CQ)
       └─ if owns JFR: urma_delete_jfr, urma_delete_jfce

Process shutdown:
  umq_uninit → umq_framework_uninit (per mode) →
    tp_ops->umq_tp_uninit = umq_tp_ub_uninit                     umq_ub_api.c:49
      ├─ umq_ub_unregister_memory_impl                            umq_ub_impl.c:224
      │   └─ urma_unregister_seg (per ctx, per mempool_id)
      └─ umq_ub_ctx_uninit_impl
         ├─ urma_delete_context (per device)
         └─ urma_uninit
```

The IO pool segment registration is process-wide; it stays alive until `umq_uninit` runs.

---

## 6. URMA primitive cheat-sheet

| URMA fn | UMQ caller (file:line) | Purpose in this stack |
| --- | --- | --- |
| `urma_init` | `umq_ub_impl.c:602` | One-shot lib init |
| `urma_get_device_list` | `umq_ub_dev.c:97` | Enumerate UB devices; pick by `UBSOCKET_DEV_NAME` |
| `urma_query_device` | umq_ub_dev.c (in `umq_find_ub_device`) | Read dev_cap (max_jetty etc.) |
| `urma_create_context` | `umq_ub.c:946` | Per-device URMA ctx (`dev_ctx->urma_ctx`) |
| `urma_register_seg` | `umq_ub.c:1654` | Register entire IO pool once — backs every qbuf zero-copy |
| `urma_create_jfc` (RX) | `umq_ub.c:1528` | Per-(main/per-jetty) RX completion queue |
| `urma_create_jfc` (TX) | `umq_ub_impl.c:972` | IO send CQ |
| `urma_create_jfc` (FC) | `umq_ub_impl.c:845` | Flow-control send CQ |
| `urma_create_jfce` | `umq_ub_impl.c:961` / `umq_ub.c:1513` | Event channel → eventfd plumbed into ubsocket epoll |
| `urma_create_jfr` | `umq_ub.c:1544` | Receive queue; one per "main UMQ" in shared-JFR mode |
| `urma_create_jetty` | `umq_ub.c:1122` | Local jetty (SQ+RQ combo) per UMQ instance |
| `urma_import_jetty` | `umq_ub.c:503` | Build target_jetty from remote bind-info blob |
| `urma_bind_jetty` | `umq_ub.c:515` | RC-mode only — pair local SQ to remote RQ |
| `urma_post_jetty_send_wr` | `umq_ub_impl.c:1442/1503`, `umq_ub.c:2100/3071/3133` | TX: SEND / SEND_IMM / WRITE_IMM / READ |
| `urma_post_jfr_wr` | `umq_pro_ub.c:571,995` | RX-post when JFR is **shared** |
| `urma_post_jetty_recv_wr` | `umq_pro_ub.c:573,998` | RX-post when JFR is **per-jetty** |
| `urma_poll_jfc` | `umq_ub.c:2357/2801/2853/2936/2983` | Drain CRs (TX and RX paths) |
| `urma_wait_jfc` | `umq_ub.c:3316,3347` | Blocking JFCE wait (umq_get_cq_event leaf) |
| `urma_ack_jfc` | `umq_ub.c:3333,3363` | Per-batch ack on JFCE (matches GET_PER_ACK=32) |
| `urma_rearm_jfc` | `umq_ub_impl.c:1257/1260/1272/1275` | Re-arm CQ before sleeping on JFCE |
| `urma_get_async_event` | `umq_ub_impl.c:1694` | Async events → AsyncEventProcess thread in Brpc::Context |
| `urma_unbind_jetty / unimport_jetty / delete_*` | `umq_ub.c:531-538`, destroy paths | Tear-down |

---

## 7. Design observations

1. **Two `dlopen` layers, not one.** libumq.so dlopens transport backends (`libumq_ub.so` / `libumq_ib.so` / `libumq_ucp.so` / `libumq_ipc.so` / `libumq_ubmm.so`), and libumq_ub.so dlopens `liburma.so` + `libtpsa.so`. Neither URMA nor any transport backend is a link-time dependency of librpc_adapter_brpc.so. Install footprint = swap which `.so` exists on disk; no recompile.
2. **One big segment registration, not per-buffer.** `umq_register_memory_impl` registers the entire IO pool as a single URMA segment; every qbuf is a slot inside it (`sges[].tseg = tseg_list[mempool_id]`). Pool grows to `UBSOCKET_POOL_MAX_SIZE` by re-registering 64 MB chunks. This is why `urma_register_seg` is rare on the hot path.
3. **TCP carries the URMA bind blob.** ubsocket exchanges the serialized `umq_ub_bind_info_t` on the original TCP socket. The TCP socket survives only long enough to complete `urma_import_jetty` / `urma_bind_jetty`; data goes via UB afterwards. Mirrors the IB/RoCE QP-exchange pattern.
4. **`umq_get_cq_event` is `urma_wait_jfc` plus `urma_ack_jfc`.** It does **not** drain CRs — that's still `urma_poll_jfc` via `umq_dequeue`. The split mirrors the libibverbs `ibv_get_cq_event` + `ibv_poll_cq` pattern.
5. **Share-JFR is the only URMA-level choice ubsocket explicitly toggles.** `UBSOCKET_ENABLE_SHARE_JFR=true` (default) causes `umq_create` with `UMQ_CREATE_FLAG_SHARE_RQ` + `share_rq_umqh=main`, which skips per-connection `urma_create_jfr` and uses the main UMQ's JFR. RX-post becomes `urma_post_jfr_wr` instead of `urma_post_jetty_recv_wr`. Everything else is identical.
6. **No URMA opcode leaks past UMQ.** Whether a writev becomes `URMA_OPC_SEND`, `_SEND_IMM`, `_WRITE_IMM`, or a rendezvous `_READ` is chosen entirely inside `umq_ub_fill_wr_impl` based on size, headroom, and flags. ubsocket has no idea, and neither does the application.
7. **Pluggable locks across the layer boundary.** ubsocket *registers down* its mutex/rwlock implementations into UMQ via `umq_external_mutex_lock_ops_register` / `umq_external_rwlock_ops_register` (`ub_lock_ops.cpp:239,259`). This is unusual: UMQ doesn't choose its own primitives — its host does. Lets ubsocket maintain a single threading model end-to-end (matters for bRPC's bthread).
8. **`urma_*` does not appear in ubsocket source.** The single comment hit at `brpc_context.h:42` is the only place. This separation is enforced by header discipline (`#include "umq_*.h"` only in `src/ubsocket/`) and is what makes ubsocket trans_mode-agnostic at the source level.

---

## 8. Quick reference — file map

| File | Contents |
| --- | --- |
| `src/ubsocket/socket_adapter.h` | `dlsym`-loaded libc-original fn-ptr table |
| `src/ubsocket/brpc/brpc_socket_adapter.h` | `EXPOSE_C_DEFINE ubsocket_*` LD_PRELOAD entry points |
| `src/ubsocket/brpc/brpc_context.{h,cpp}` | Process-wide `Brpc::Context`, `umq_init` site |
| `src/ubsocket/brpc/brpc_file_descriptor.{h,cpp}` | Per-fd state, OOB TCP handshake, `umq_create`/`umq_bind` |
| `src/ubsocket/brpc/brpc_share_jfr.{h,cpp}` | Share-JFR completion-drain loop |
| `src/ubsocket/brpc/share_jfr_common.h` | `MainUmqState` wrapper around `uint64_t umqh` |
| `src/ubsocket/brpc/brpc_iobuf_adapter.{h,cpp}` | bRPC IOBuf-allocator hook for zero-copy |
| `src/ubsocket/brpc/qbuf_queue.h`, `qbuf_list.h` | Per-fd received-payload queues |
| `src/ubsocket/ubsocket_io.{h,cpp}` | `UbsocketWritev`/`UbsocketReadv` message-framing |
| `src/ubsocket/polling_epoll.{h,cpp}` | epoll multiplexer (real fds + UMQ eventfds) |
| `src/ubsocket/ub_lock_ops.{h,cpp}` | Lock-ops registered into UMQ |
| `src/hcom/umq/src/umq_api.c`, `umq_pro_api.c` | UMQ public dispatch + `g_umq_fws[]` table |
| `src/hcom/umq/src/umq_ub/umq_ub_api.c`, `umq_pro_ub_api.c` | UB-backend vtables |
| `src/hcom/umq/src/umq_ub/core/umq_ub_impl.c` | Top-level impls: ctx init, create, bind dispatch, enqueue/dequeue |
| `src/hcom/umq/src/umq_ub/core/private/umq_ub.c` | jetty/JFR/JFC create, import/bind jetty, fill_wr, poll_jfc |
| `src/hcom/umq/src/umq_ub/core/private/umq_ub_dev.c` | URMA device enumeration |
| `src/hcom/umq/src/umq_ub/core/private/umq_pro_ub.c` | pro-API impls; RX-post split (shared vs per-jetty) |
| `src/hcom/umq/src/umq_ub/core/private/umq_symbol_private.{c,h}` | `dlopen("liburma.so")` + `dlopen("libtpsa.so")` + `dlsym` of 47 fns |
