# URPC + UMQ + control-plane tools

_Last updated: 2026-04-25._

Detailed walk through the UMDK userspace **URPC** framework, the **UMQ** (userspace message queue) backends URPC sits on, and the URMA control-plane CLIs (`urma_admin`, `urma_perftest`, `urma_ping`).

Source: `~/Documents/Repo/ub-stack/umdk/src/{urpc,urma/tools}/`. Cross-references the spec doc for what URPC is per the UB Base Spec.

> **Verification status.** Most of the structural detail (function names, header structs, file paths) was surveyed by an Explore agent and reads consistent with the ground-truth files. Specific line numbers should be sanity-checked before quoting. Treat percentages and "max sizes" as sourced from headers but not separately profiled.

---

## 1. URPC framework

URPC is a transport-agnostic, application-level RPC framework. Spec defines it as a **function-layer protocol on top of UB transactions** (UB-Base-Spec §1.6, §8.5, App. H). UMDK ships a userspace implementation that runs over a pluggable **UMQ** transport.

### 1.1 Public API surface

In `urpc_framework_api.h` (paths relative to `~/Documents/Repo/ub-stack/umdk/src/urpc/include/framework/`).

**Lifecycle.**

```c
int  urpc_init(urpc_config_t *cfg);
void urpc_uninit(void);
int  urpc_allocator_register(struct urpc_allocator *allocator);
```

**Channel API** (`urpc_framework_api.h:79–232` per agent):

```c
uint32_t urpc_channel_create(void);
int      urpc_channel_destroy(uint32_t urpc_chid);
int      urpc_channel_server_attach(uint32_t chid,
                                    urpc_host_info_t *server,
                                    urpc_channel_connect_option_t *opt);
int      urpc_channel_queue_add(uint32_t chid, uint64_t qh);
int      urpc_channel_queue_rm(uint32_t chid, uint64_t qh);
int      urpc_channel_queue_pair(uint32_t chid, uint64_t local_qh, peer_qh);
int      urpc_server_start(urpc_control_plane_config_t *cfg);
```

**Queue API** (`urpc_framework_api.h:244–366`):

```c
uint64_t urpc_queue_create(enum urpc_queue_trans_mode trans_mode,
                           urpc_qcfg_create_t *cfg);
int      urpc_queue_modify(uint64_t qh, urpc_queue_status_t status);
int      urpc_queue_destroy(uint64_t qh);
int      urpc_queue_rx_post(uint64_t qh, urpc_sge_t *args, uint32_t nsge);
int      urpc_queue_stats_get(uint64_t qh, uint64_t *stats, int len);
int      urpc_queue_interrupt_fd_get(uint64_t qh);   /* epoll-friendly fd */
```

**Function (method) registration & dispatch** (`urpc_framework_api.h:370–506`):

```c
int      urpc_func_register(urpc_handler_info_t *info, uint64_t *func_id);
uint64_t urpc_func_call(uint32_t chid, urpc_call_wr_t *wr,
                        urpc_call_option_t *opt);
int      urpc_func_exec(uint64_t func_id, urpc_sge_t *args, uint32_t nsge,
                        urpc_sge_t **rsps, uint32_t *nrsp);
int      urpc_func_return(uint64_t qh, void *req_ctx,
                          urpc_return_wr_t *wr, urpc_return_option_t *opt);
int      urpc_func_poll(uint32_t chid, urpc_poll_option_t *opt,
                        urpc_poll_msg_t msgs[], uint32_t max);
int      urpc_func_poll_wait(uint32_t chid, uint64_t req_h, ...);
int      urpc_async_event_get(urpc_async_event_t events[], int num);
```

**Memory + security** (`urpc_framework_api.h:542–594`):

```c
uint64_t urpc_mem_seg_register(uint64_t va, uint64_t len);
int      urpc_mem_seg_token_get(uint64_t mem_h, mem_seg_token_t *token);
int      urpc_ssl_config_set(urpc_ssl_config_t *cfg);   /* TLS-PSK */
```

### 1.2 Service registration & dispatch

**Server-side registration** (per agent — `framework/lib/func.c:145–180`). `urpc_func_register()` accepts a `urpc_handler_info_t` (name, function pointer, signature). The framework allocates a 48-bit **method ID** from `g_urpc_func_id_gen` (`func.c:77`), and stores the entry in two hash maps:

- `g_urpc_func_id_table` — keyed by ID
- `g_urpc_func_name_table` — keyed by name

Both are protected by `g_urpc_func_table_rwlock` (`func.c:76`).

**Function ID layout** (per agent — `func.c:18–40`). 64-bit composite:

```
[ device class : 12 ] [ sub class : 12 ] [ P : 1 ] [ method : 23 ]   (48-bit ID)
                                                  ↑
                               Private (P=1) = user; (P=0) = system reserved
```

The device + subclass prefix is set once at library init. Private methods are user-registered; reserved IDs handle internal events (e.g. keepalive at function ID `0x002001000005`, see §1.3).

**Dispatch on receive** (`framework/lib/datapath/dp.c`). On message arrival:

1. Extract 48-bit function ID from `urpc_req_head_t`.
2. Lookup in ID hash table via `urpc_server_func_entry_get_by_id()` (`func.c:120–130`).
3. Pull SGEs from the received message; pass to `urpc_func_exec()`.
4. Handler runs; returned SGEs are collected for the response.

### 1.3 Wire format

**Cross-validated against UB Base Spec Appendix H** (see [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §6 for the spec-side bit layouts). The userspace `protocol.h` description below matches the spec-defined frame format; field semantics are authoritative via the spec.

**Function ID is 48-bit** (per spec §H.2): `[ UBPU Class : 12 | UBPU Subclass : 12 | P : 1 | Method : 23 ]`. Reserved P+Method patterns query/install/remove customized methods. Storage domain example: UBPU Class `0x002`, Subclass `0x001`, P=0.

**Request header** (per agent — `framework/protocol/protocol.h:69–105`). 32-byte base + variable DMA-descriptor table:

```
word 0   [ version :4  | type :4 | ack :1 | rsv :2 | arg_dma_count :5 | function_id :48 ]
word 1   [ req_total_size : 32 ]
word 2   [ req_id : 32 ]              /* sequence per request */
word 3   [ client_channel : 24 | function_defined : 8 ]
arg_dma[arg_dma_count] each = { size:32, address:64, token:32 }
```

**Acknowledge header** (16 bytes, `protocol.h:116–129`):

```
[ version :4 | type :4 | rsv :8 | req_id_range :16 ]
[ req_id : 32 ]
[ client_channel : 24 | rsv : 8 ]
```

`req_id_range` carries credit-window size for flow-control.

**Response header** (20 bytes + offsets, `protocol.h:131–157`):

```
[ version :4 | type :4 | status :8 | req_id_range :16 ]
[ req_id : 32 ]
[ client_channel : 24 | function_defined : 8 ]
[ response_total_size : 32 ]
[ return_data_offset[] : variable ]
```

`status` is a `urpc_msg_status_t`: `SUCCESS`, `SERVER_DECLINE`, `FUNCTION_ERR`, `REMOTE_LEN_ERR`, …

**Message types** (`protocol.h:28–34`):

```
URPC_MSG_REQ
URPC_MSG_ACK
URPC_MSG_RSP
URPC_MSG_ACK_AND_RSP   /* combined ack+response in one frame */
URPC_MSG_READ
```

**Keep-alive** is a special RPC with reserved ID `0x002001000005` (`protocol.h:25`).

### 1.4 Marshalling — caller-managed

URPC does **not** use protobuf, msgpack, or any IDL. The framework is transport-agnostic and does no serialization itself. Callers prepare their own argument buffers, describe them via `urpc_sge_t` (size + address + token), and let URPC embed those SGEs into the request DMA-descriptor table.

This trades convenience for control: no codegen step, no schema evolution support, but zero-copy is possible end-to-end.

### 1.5 Transport selection — static per queue

`urpc_queue_create(trans_mode, ...)` selects the UMQ backend at queue-creation time. **Per-queue, not per-call.** To use multiple transports, create multiple queues.

The framework keeps two ops lists (`framework/core/queue/queue.c:26–34`):

- `g_urpc_provider_ops_list` — per-transport provider hooks
- `g_urpc_queue_ops_list` — per-transport queue ops

At creation time, the framework binds the queue to the chosen ops set.

### 1.6 Concurrency model — explicit polling

URPC does **not** ship a built-in thread pool or async/await. Apps run their own event loops:

- `urpc_func_poll()` — non-blocking drain.
- `urpc_func_poll_wait(req_h, timeout)` — block until a specific request completes.
- `urpc_queue_interrupt_fd_get(qh)` — get a file descriptor for `epoll`/`select` integration.

Locking: `pthread_rwlock_t` for global state (function table); per-queue mutexes for channel/queue ops. Multiple threads may poll the same channel.

### 1.7 Security — control-plane TLS-PSK

`urpc_ssl_config_set(cfg)` enables TLS 1.2/1.3 PSK on the channel attach/detach path:

```c
urpc_ssl_config_t cfg = {
    .ssl_flag        = URPC_SSL_FLAG_ENABLE,
    .ssl_mode        = SSL_MODE_PSK,
    .min_tls_version = TLS_VERSION_1_2,
    .max_tls_version = TLS_VERSION_1_3,
    .psk = { .cipher_list = "...",
             .cipher_suites = "...",
             .client_cb_func = my_client_psk_cb,
             .server_cb_func = my_server_psk_cb },
};
urpc_ssl_config_set(&cfg);   /* after urpc_init() */
```

Data-plane encryption: a `dp_encrypt` flag exists in protocol headers (`protocol.h:189` per agent), but no public API surfaces it. Likely future work or internal-only.

UB-spec security primitives (EE_bits, CIP, TEE) are **not** exposed at the URPC layer; they live at lower layers (URMA segment registration, transaction headers).

---

## 2. UMQ — Userspace Message Queue backends

UMQ abstracts a queue with pluggable transports. Three backends ship: **IPC**, **UB** (URMA), **UBMM** (URMA + memory-mapped zero-copy). Each implements the same `umq_ops_t` vtable (`include/umq/umq_tp_api.h`).

### 2.1 Common API (`umq_api.h`)

```c
int       umq_init(umq_init_cfg_t *cfg);
void      umq_uninit(void);
uint64_t  umq_create(umq_create_option_t *opt);
int       umq_destroy(uint64_t qh);
int       umq_bind(uint64_t qh, uint8_t *bind_info, uint32_t info_size);
int       umq_unbind(uint64_t qh);
umq_buf_t *umq_buf_alloc(uint32_t req_size, uint32_t req_qbuf_num,
                          uint64_t qh, umq_alloc_option_t *opt);
void      umq_buf_free(umq_buf_t *qbuf);
int       umq_state_set(uint64_t qh, umq_state_t st);
umq_state_t umq_state_get(uint64_t qh);
umq_buf_t *umq_enqueue(uint64_t qh, umq_buf_t *qbuf);   /* returns first failure */
umq_buf_t *umq_dequeue(uint64_t qh);
int       umq_wait_interrupt(uint64_t qh, int timeout_ms,
                             umq_interrupt_option_t *opt);
int       umq_fd_get(uint64_t qh, umq_fd_type_t fd_type);
```

### 2.2 `umq_ipc` — local IPC

**Path:** `src/urpc/umq/umq_ipc/`.

**Mechanism.** Unix-domain sockets for control + optional shared-memory buffer pool for payloads. Per-queue slab allocator. `umq_ipc_enqueue_impl()` (`umq_ipc.c`) writes to socket; `umq_ipc_dequeue_impl()` reads.

**Limits** (`include/umq/umq_types.h:103`): max I/O 10 MB.

**Flow control:** none at UMQ level — sockets handle it.

**Use case.** Local-host RPC where peer is in a sibling process; useful for testing, dev, mixed-process workflows where some endpoints are on UB, others not.

### 2.3 `umq_ub` — URMA-transported

**Path:** `src/urpc/umq/umq_ub/`.

**Mechanism.** One URMA jetty per queue pair. `send` uses `urma_post_send` with SGEs. `imm_data` (≤32 B) is used to carry credit metadata inline.

**Flow control** (per agent — `umq_ub/core/flow_control/umq_ub_flow_control.h:20–77`):

- Credit per remote RX window, sliding-window with 10% threshold (`UMQ_UB_CREDIT_PERCENT`).
- On send: `umq_ub_window_dec()`. If below threshold, send `umq_ub_shared_credit_req_send()` to peer.
- On peer response: `umq_ub_shared_credit_resp_handle()` calls `umq_ub_window_inc()`.
- Permission check: `umq_ub_permission_acquire()` before posting.

**Buffer mgmt.**

- Hierarchical global pools (8 KB / 256 KB / 8 MB tiers) for typical use.
- Per-queue pool for the UBMM-PLUS variant.
- Max I/O: 64 KB (`UMQ_TRANS_MODE_UB`); 10 MB (`UMQ_TRANS_MODE_UB_PLUS`).

**Lifecycle.** One jetty per queue pair, created in `umq_create()` and destroyed in `umq_destroy()`. No jetty pooling — 1:1 queue-to-jetty mapping (which has implications for HW jetty exhaustion at scale).

### 2.4 `umq_ubmm` — URMA + memory-mapped ring (zero-copy)

**Path:** `src/urpc/umq/umq_ubmm/`.

**Mechanism.** Pre-mapped shared ring buffers exchanged at bind time. Producer writes directly into the shared ring; consumer reads without copying. Optional URMA SEND for control / flow notification.

**Bind sequence.**

1. Each side allocates a ring descriptor and includes its address + URMA token in `bind_info`.
2. Peer verifies the token and maps the remote ring.
3. Producers write to the ring; consumers poll the ring's tail pointer.

**Flow control.** Implicit via ring fill-level (full ring → backpressure).

**Limits.** Max I/O: 8 KB (`UMQ_TRANS_MODE_UBMM`); 10 MB (`UMQ_TRANS_MODE_UBMM_PLUS`).

**Use case.** Lowest-latency path for fixed-size messages between trusted peers.

---

## 3. Control-plane CLI tools

### 3.1 `urma_admin`

**Path:** `src/urma/tools/urma_admin/`.

**Top-level usage** (per agent — `admin_cmd.c:46–119`):

```
urma_admin <subcommand> [options]
  show <resource_type> [--dev <name>] [--key <id>] ...
  dev <subcommand>
  eid <subcommand>
```

**Legacy / deprecated** (`admin_cmd.c:63–117`):

- `add_eid --dev <name> --idx <n>` — manual EID add (UVS-only path).
- `show_stats --dev <name> --resource_type <type> --key <id>` — query device stats.
- `show_res / list_res` — enumerate URMA resources (jetties, JFS, JFR, segments, RC queues).

**Argument parsing.** `admin_cmd.c:121–220` uses `getopt_long()` for `-d/--dev`, `-R/--resource_type`, `-k/--key`. Args land in `admin_config_t`, dispatched to handlers in `admin_cmd_show.c` / `admin_cmd_res.c`.

**Kernel interface.** Generic netlink (libnl). `admin_netlink.c` builds genl messages; responses are async.

**Examples.**

```
urma_admin show --dev ubcore0 --resource_type 6   # list jetties
urma_admin eid add --dev ubcore0 --eid 10.0.0.1
```

### 3.2 `urma_perftest`

**Path:** `src/urma/tools/urma_perftest/`.

**Patterns** (per agent — `urma_perftest.c:38–65`):

- `PERFTEST_SEND_LAT` — round-trip latency (SEND).
- `PERFTEST_WRITE_LAT` — one-way latency (RDMA WRITE).
- `PERFTEST_READ_LAT` — RDMA READ latency.
- `PERFTEST_ATOMIC_LAT` — CAS latency.
- `PERFTEST_*_BW` — bandwidth variants with pipelining.

**Metrics** (`urma_perftest.c:25–85`, `perftest_run_test.c`):

- Latency: min / max / avg / p50 / p95 / p99.
- Bandwidth: Gbps or MB/s.
- Message rate: msg/sec.

**CLI shape mirrors `ib_send_lat`:**

```
urma_perftest -d <device> -e <remote_eid> --operation send_lat -s 64 -n 1000
```

**Setup** (`perftest_resources.c`): open device → allocate jetty pair → exchange peer info via TCP side-channel → connect jetty (RC mode).

**Multi-jetty.** `cfg->jettys` for parallelism (multiple independent jetty pairs).

### 3.3 `urma_ping`

**Path:** `src/urma/tools/urma_ping/`.

**CLI:**

```
urma_ping [-c count] [-i interval_s] [-s size_bytes] [-t timeout_s] <eid>
```

EID parsing accepts IPv4 (`x.x.x.x`), full IPv6, or 32-bit hex/decimal (`ping_parameters.c:57–84`). Stats: packets sent/received/lost, RTT min/max/avg, timeouts (`ping_stat.c`).

### 3.4 `urpc_admin` and URPC perftest

`src/urpc/tools/urpc_admin/` and `src/urpc/tools/perftest/` exist but were not surveyed in detail. Likely mirror the URMA tools at the URPC level (channel/method admin; URPC call-latency benchmarking).

---

## 4. Cross-cutting observations

1. **Caller-managed marshalling** is a deliberate choice. URPC ≠ gRPC. If your team wants schema-evolution semantics, you build them on top.
2. **Transport static at queue creation.** Multi-transport apps need multiple queues — there's no "RPC over the best available link" runtime selector.
3. **Flow control asymmetry across UMQ backends** (none / credit / ring fill). Tune thresholds per transport.
4. **One jetty per UMQ-UB queue.** No jetty pooling. At scale, this can hit per-device jetty caps. Not a bug — a known design choice that may need revisit for many-connection workloads.
5. **TLS-PSK is control-plane only.** Data-plane confidentiality (CIP / EE_bits) lives at URMA / transaction layer, not URPC.

---

## 5. Open questions

1. **`dp_encrypt` flag.** Real or vestigial? Where is it consumed if anywhere?
2. **URPC `urpc_admin` and `tools/perftest`.** Survey command set + benchmarks they support.
3. **Memory token rotation in URPC.** URMA tokens are rotatable; does URPC re-fetch tokens periodically, or does it cache them for a session lifetime?
4. **UMQ-UB jetty pooling.** Any plans? At what scale does the 1:1 mapping start hurting?
5. **Co-existence with NCCL/RCCL.** If CAM uses URMA directly (not URPC), but URPC also sits on URMA, what does fairness/QoS look like when both are active on one device?

---

_Companion: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md)._
