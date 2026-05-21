# URMA ioctl dispatcher & its consumers — perftest, UMS, UMQ

_Last updated: 2026-05-21._

Investigation thread on [`rainbay001-dotcom/UMDK#7`](https://github.com/rainbay001-dotcom/UMDK/issues/7) (流程测试). Starts from a syscall trace observation about ioctl `0xc0105501`, unfolds into a structural understanding of how URMA, UMS (ubsocket), and UMQ all sit on top of the same `ubcore_*` kernel API via different paths.

Companions in this directory:
- [`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md) — perftest **send_lat** wall-clock breakdown and stage-by-stage trace numbers. This doc complements it with the **dispatcher-level** view.
- [`umdk_urma_perftest_function_graph.md`](umdk_urma_perftest_function_graph.md) — function-graph-level call chain for the same binary.
- [`umdk_user_kernel_boundary.md`](umdk_user_kernel_boundary.md) — per-ioctl, per-struct catalogue across all four URMA ioctl magics (`'U'`, `'E'`, `'V'`, ubagg). Section 4 below is the **runtime** view of the `'U'` dispatcher; that doc is the **structural** view.
- [`umq_architecture.md`](umq_architecture.md) — UMQ deep-dive (backends, qbuf pools, flow control). Section 7 below is the slice of that doc relevant to the URMA-API contract.
- [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md) — UMS overview. Section 6 below adds the **connect-path** internals.

Source citations throughout: `/Volumes/KernelDev/umdk/` and `/Volumes/KernelDev/kernel/drivers/ub/`.

---

## 1. TL;DR

1. **`0xc0105501` is a multiplexer, not an op.** It decodes as `_IOWR('U', 1, urma_cmd_hdr_t)` — the single ioctl number under which **all 86 URMA commands** ride. The actual op selector lives in the first 4 bytes of the user-pointer struct (`urma_cmd_hdr_t.command`). From a raw `sys_ioctl` tracepoint you **cannot** identify which URMA operation was issued — you need a `kprobe` on `uburma_ioctl` reading the `command` field, a `uprobe` on `urma_tlv_ioctl`, or a function-graph trace into `uburma_cmd_parse`.

2. **The "same arg pointer across calls" pattern is benign.** The userspace shim allocates `urma_cmd_hdr_t hdr` as a **stack local** (`urma_cmd_tlv.c:47`), so sequential calls from the same thread reuse the same stack slot. Identical `arg=0x…` values across many ioctls are consistent with 22 *distinct* URMA ops — not 22 polls of the same one.

3. **Between `ubcore_register_seg` and `ubcore_import_seg`, the kernel does nothing for peer coordination.** All inter-node activity in that window is plain TCP `send`/`recv` from userspace `sock_sync_data` over the `establish_connection` control socket.

4. **The on-wire URMA handshake fires later**, in `connect_jfr` → `urma_import_jfr` / `urma_advise_jfr` / `urma_bind_jetty`. This is the most likely source of multi-second blocking during setup, not register/import_seg themselves.

5. **UMS and UMQ are parallel consumers of the same `ubcore_*` API.** UMS lives in the kernel and calls ubcore symbols directly (`EXPORT_SYMBOL`). UMQ lives in userspace and reaches ubcore through the URMA ioctl dispatcher. The lower half of the stack is identical for both.

---

## 2. The dispatcher anatomy

### 2.1 Decode of `0xc0105501`

From `umdk/src/urma/lib/urma/core/include/urma_cmd.h:51-52`:

```c
#define URMA_CMD_MAGIC 'U'
#define URMA_CMD       _IOWR(URMA_CMD_MAGIC, 1, urma_cmd_hdr_t)
```

| field | value | meaning |
|---|---|---|
| dir   | `0b11`  | `_IOC_READ \| _IOC_WRITE` |
| size  | `0x010` | `sizeof(urma_cmd_hdr_t) = 16` |
| magic | `0x55`  | `'U'` |
| nr    | `0x01`  | the singular URMA dispatch number |

### 2.2 The header that rides on top

`urma_cmd.h:19-23`:

```c
typedef struct urma_cmd_hdr {
    uint32_t command;     // <-- op selector
    uint32_t args_len;
    uint64_t args_addr;   // pointer to per-op struct (create_ctx_t, import_seg_t, …)
} urma_cmd_hdr_t;
```

### 2.3 The full URMA op enum

`urma_cmd.h:54-140` defines **86 commands** (`URMA_CMD_CREATE_CTX = 1` through `URMA_CMD_DEACTIVE_JETTY = 85`, plus `URMA_CMD_MAX`). All 86 are multiplexed onto `0xc0105501`.

Frequency-class summary (`grep "urma_tlv_ioctl(ioctl_fd, URMA_CMD_" umdk/src/urma/lib/urma/core/urma_cmd_tlv.c | sort -u`):

- Lifecycle:     `CREATE_CTX`, `CREATE_JETTY/JFC/JFR/JFS/JFCE/JETTY_GRP/NOTIFIER`, `DELETE_*`
- Memory:        `ALLOC_TOKEN_ID`, `REGISTER_SEG`, `IMPORT_SEG`, `UN(REGISTER|IMPORT)_SEG`, `FREE_TOKEN_ID`
- Connection:    `IMPORT_JFR(_EX)`, `IMPORT_JETTY(_EX|_ASYNC)`, `BIND_JETTY(_EX|_ASYNC)`, `UNBIND/UNIMPORT_*`, `ADVISE/UNADVISE_*`
- TP:            `GET_TP_LIST`, `GET/SET_TP_ATTR`, `EXCHANGE_TP_INFO`, `MODIFY_TP`
- Query/util:    `QUERY_*`, `MODIFY_*`, `GET_EID_LIST/NETADDR_LIST/EID_BY_IP/IP_BY_EID/SMAC/DMAC/DEV_ATTR`
- Bulk:          `*_BATCH` (delete)
- Userland ctl:  `USER_CTL`
- New API:       `ALLOC/FREE/SET_*_OPT/GET_*_OPT/ACTIVE/DEACTIVE_*` for JFR/JFS/JFC/JETTY

### 2.4 Userspace dispatch shim

`umdk/src/urma/lib/urma/core/urma_cmd_tlv.c:45-58`:

```c
static int urma_tlv_ioctl(int ioctl_fd, urma_cmd_t cmd, urma_cmd_attr_t *args, uint32_t args_len)
{
    urma_cmd_hdr_t hdr = {                  // stack local — same slot every call
        .command  = (uint32_t)cmd,          // ← op selector
        .args_len = args_len,
        .args_addr = (uint64_t)args,
    };
    return ioctl(ioctl_fd, URMA_CMD, &hdr); // URMA_CMD = 0xc0105501
}
```

The `hdr` local sits on the caller's stack frame. In a single-threaded process calling sequential URMA ops, the address of `hdr` is reused — explains why a raw `sys_ioctl` tracepoint shows identical `arg=0x…` across many distinct ops from one PID.

### 2.5 Kernel dispatch

`drivers/ub/urma/uburma/uburma_cmd.c:4991-5053`:

```c
long uburma_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    if (cmd == UBURMA_CMD) {
        copy_from_user(&hdr, user_hdr, sizeof(struct uburma_cmd_hdr));
        uburma_cmd_parse(ubc_dev, file, &hdr);   // dispatches by hdr.command
    }
}
```

`uburma_cmd.c:4971-4982`:

```c
static int uburma_cmd_parse(...) {
    if (hdr->command < UBURMA_CMD_CREATE_CTX || hdr->command >= UBURMA_CMD_MAX ||
        g_uburma_cmd_handlers[hdr->command] == NULL)
        return -EINVAL;
    return g_uburma_cmd_handlers[hdr->command](ubc_dev, file, hdr);
}
```

`uburma_cmd.c:4886-4969` is the static dispatch table mapping each enum value to its `uburma_cmd_<opname>` handler.

### 2.6 How to actually identify an op from a trace

A vanilla `sys_ioctl` tracepoint captures only `(fd, cmd, arg)`. To name the op, you need one of:

- `kprobe` on `uburma_ioctl`, capture `((urma_cmd_hdr_t*)arg)->command` after the `copy_from_user`.
- `uprobe` on `urma_tlv_ioctl`, capture the `cmd` argument (parameter 2).
- function-graph trace into `uburma_cmd_parse` — the next frame will literally be `uburma_cmd_<opname>`.

The bot-suggested mapping "`cmd=0xc0105501` = `IMPORT_SEG`" is **not supported** by a raw ioctl tracepoint: that mapping requires reading user memory at `arg`, which the tracepoint doesn't do.

---

## 3. Anatomy of an URMA setup — per-phase ioctl/TCP budget

For `urma_perftest` simplex mode with `N = cfg->jettys`, UB transport, default config (no credit / no jfce / `tp_aware=false` / `seg_pre_jetty=true`):

| Phase | URMA op (in `hdr->command`) | Count | Cum. | TCP RTTs |
|---|---|---:|---:|---:|
| `init_device` (`perftest_resources.c:150`) | `CREATE_CTX` | 1 | 1 | 0 |
| `create_simplex_jettys` (L637) → `create_jfc` | `CREATE_JFC` × 2 (send+recv) | 2N | 1+2N | 0 |
| → `create_jfs` (L408) | `CREATE_JFS` | N | 1+3N | 0 |
| → `create_jfr` (L467) | `CREATE_JFR` | N | 1+4N | 0 |
| `register_mem` (L743) | `ALLOC_TOKEN_ID` | N | 1+5N | 0 |
| same | `REGISTER_SEG` | N | 1+6N | 0 |
| **`exchange_connection_info`** (L1177) | *(none — TCP only)* | 0 | 1+6N | **2N min, up to 4N** |
| `import_seg_for_simplex` (L1255) | `IMPORT_SEG` | N | 1+7N | 0 |
| `connect_jfr` → `connect_jfr_default` (L1373) | `IMPORT_JFR` | N | 1+8N | 0 *(but on-wire URMA CM handshake)* |
| `create_run_ctx` (L1799) | *(none — calloc)* | 0 | 1+8N | 0 |

Optional features add: `+2N` for `use_jfce` (`CREATE_JFCE`), `+2N` for `enable_credit` (extra TOKEN_ID + REGISTER_SEG + IMPORT_SEG pairs), `+N` for `tp_aware` (`GET_TP_LIST`).

For the 22 URMA ioctls observed in JinDou's PID-379062 trace, `N≈2-3` with a credit/jfce/tp_aware option is consistent. Inter-ioctl gaps of 15–31 ms match the "issue N ioctls → block on a TCP RTT → issue N more" pattern caused by `exchange_connection_info` (and the post-import `sync_time` barrier).

### 3.1 What `exchange_connection_info` actually does (`perftest_resources.c:1177-1209`)

```c
static int exchange_connection_info(perftest_context_t *ctx, perftest_config_t *cfg)
{
    int ret;
    ret = exchange_seg_info(ctx, &cfg->comm, cfg);          // urma_seg_t per jetty
    if (ret) return -1;
    ret = exchange_jetty_id(ctx, &cfg->comm, cfg);          // urma_jetty_id_t per jetty
    if (ret) goto exchange_jetty_id_fail;
    ret = exchange_credit_info(ctx, &cfg->comm, cfg);       // skipped if !enable_credit
    if (ret) goto exchange_credit_fail;
    ret = create_tp_info(ctx, &cfg->comm, cfg);             // skipped if !tp_aware
    if (ret) goto create_tp_info_fail;
    ret = exchange_tp_info(ctx, &cfg->comm, cfg);           // skipped if !tp_aware || UM || use_ctp
    if (ret) goto exchange_tp_info_fail;
    return 0;
    /* unwind labels free remote-side allocations */
}
```

Each sub-phase issues `sock_sync_data` over `comm->sock_fd[i]` for `i ∈ [0, pair_num)` — see §3.2.

### 3.2 `sock_sync_data` — what each TCP exchange costs

`umdk/src/urma/tools/urma_perftest/perftest_communication.c:308-337`:

```c
int sock_sync_data(int sock_fd, int size, char *local_data, char *remote_data)
{
    int rc = write(sock_fd, local_data, (size_t)size);
    if (rc < size) fprintf(stderr, "...");                   // logs only — does NOT return

    int total = 0;
    while (total < size) {
        int n = read(sock_fd, remote_data + total, (size_t)size - total);
        if (n > 0) total += n; else break;
    }
    return (total == size) ? 0 : -1;
}
```

- **Pattern:** `write` → blocking `read` until exactly `size` bytes received.
- `TCP_NODELAY` is set by `ip_set_sockopts` (`perftest_communication.c:42`), so Nagle won't hold the small writes.
- **Trace appearance:** `sys_sendto` (write) + `sys_recvmsg`/`sys_recvfrom` (read) per call.
- **No timeout.** A missing or slow peer leaves both sides blocked in `read()` indefinitely.
- The `write < size` failure path only logs and continues; it does not return early. A half-written exchange on a broken socket can leave both sides hung.

`sync_time` (L339) is a thin wrapper used as a **barrier**: both sides send the same string, each waits to receive it back. Used at the end of `connect_jfr_tp_aware` (`perftest_resources.c:1451`).

### 3.3 Client/server symmetry

Selection is by **one flag**: `cfg->comm.server_ip`. Pass `-S <ip>` → client. Omit → server.

The *only* function that branches client/server in the setup phase is `establish_connection` (`perftest_communication.c:272-287`):

```c
int establish_connection(perftest_config_t *cfg)
{
    if (cfg->comm.server_ip != NULL)
        return client_connect(cfg);   // socket + [bind] + connect()
    else
        return server_connect(cfg);   // socket + bind + listen + accept()
}
```

After that, both peers run the same `create_ctx → create_simplex_ctx → init_device / create_simplex_jettys / register_mem / exchange_connection_info / import_seg_for_simplex / connect_jfr / create_run_ctx` chain. Symmetry is enforced by `sock_sync_data` (write-then-read) which rendezvouses both sides on every TCP exchange.

Only the data-path phase (`perftest_run_test.c`) checks `is_server = cfg->comm.server_ip == NULL` for directional choices (who posts sends vs receives). The setup chain itself is fully symmetric.

### 3.4 Implication for blocking diagnostics

If a multi-second pause appears around the import_seg moment in the trace, it is **not** the kernel `register_seg`/`import_seg`. The most natural causes:

1. **One peer blocked in `sock_sync_data` `read()`** waiting for the other to reach the same `exchange_*` step (most likely).
2. **`connect_jfr` → `urma_import_jfr` / `urma_advise_jfr` / `urma_bind_jetty`** triggering a kernel UB CM/MAD-style handshake. This is where the actual on-wire URMA traffic lives.

`register_seg` and `import_seg` themselves are local descriptor work (sub-millisecond) — see §5.

---

## 4. `urma_register_seg` end-to-end call chain

A worked example because it surfaces every layer (userspace API → provider → core → TLV → ioctl → kernel handler → ubcore → driver). Every other URMA op follows the same five-layer shape.

### 4.1 Userspace

```
urma_register_seg(ctx, seg_cfg)                            lib/urma/core/urma_cp_api.c:2763
│
├─ urma_check_seg_cfg(dev->type, seg_cfg)                  validation
├─ urma_alloc_token_id(ctx)                                only if token_id missing && UB
│
└─ ops->register_seg(ctx, &tmp_cfg)                        provider dispatch (function pointer)
    │
    └─ udma_u_register_seg(urma_ctx, seg_cfg)              hw/udma/udma_u_segment.c:132
        ├─ udma_u_check_seg_cfg(seg_cfg)
        ├─ calloc(struct udma_u_segment)
        ├─ udma_u_init_seg_cfg(...)
        │
        ├─ udma_u_grant_segment(seg)                       udma_u_segment.c:64
        │   ├─ udma_u_get_seg_perm(&attr)
        │   └─ ummu_grant(tid, va, len, perm, &attr)       USERSPACE IOMMU GRANT
        │
        └─ udma_exec_register_seg_cmd(ctx, cfg, tseg)      udma_u_segment.c:91
            │
            └─ urma_cmd_register_seg(ctx, tseg, cfg, &udata)   lib/urma/core/urma_cmd.c:240
                │   builds urma_cmd_register_seg_t arg
                │   {va, len, token_id, token_id_handle, token, flag}
                │
                └─ urma_ioctl_register_seg(fd, &arg)       lib/urma/core/urma_cmd_tlv.c:100
                    │   TLV-encodes args into attrs[]
                    │
                    └─ urma_tlv_ioctl(fd, URMA_CMD_REGISTER_SEG, attrs, len)   urma_cmd_tlv.c:45
                        │   hdr.command = URMA_CMD_REGISTER_SEG (= 4)
                        │
                        └─ ioctl(fd, 0xc0105501, &hdr)     ← USER/KERNEL BOUNDARY
```

### 4.2 Kernel

```
uburma_ioctl(filp, UBURMA_CMD, arg)                        drivers/ub/urma/uburma/uburma_cmd.c:4991
│
├─ copy_from_user(&hdr, user_hdr, 16)
│
└─ uburma_cmd_parse(ubc_dev, file, &hdr)                   uburma_cmd.c:4971
    │
    └─ g_uburma_cmd_handlers[4](ubc_dev, file, &hdr)
        │
        └─ uburma_cmd_register_seg(ubc_dev, file, hdr)     uburma_cmd.c:207
            │
            ├─ uburma_tlv_parse(hdr, &arg)                 unpack TLV → urma_cmd_register_seg
            ├─ uobj_get_read(UOBJ_CLASS_TOKEN, ...)        look up token_id object
            ├─ uburma_fill_attr(&cfg, &arg)                build ubcore_seg_cfg
            ├─ uobj_alloc(UOBJ_CLASS_SEG, file)
            │
            ├─ ubcore_register_seg(ubc_dev, &cfg, &udata)  drivers/ub/urma/ubcore/ubcore_segment.c:155
            │   ├─ ubcore_check_register_seg_para(dev, cfg, udata)
            │   ├─ ubcore_alloc_token_id(dev, flag, NULL)  only if UB && cfg->token_id NULL
            │   │
            │   ├─ dev->ops->register_seg(dev, &tmp_cfg, udata)   ← DRIVER HOOK
            │   │   ├─ get_user_pages_fast / pin_user_pages
            │   │   ├─ iommu_map / dma_map_sg
            │   │   ├─ program HW token-id table entry
            │   │   ├─ alloc struct ubcore_target_seg
            │   │   └─ return tseg
            │   │
            │   ├─ tseg->ub_dev          = dev
            │   ├─ tseg->seg.len         = cfg->len
            │   ├─ tseg->seg.ubva.va     = cfg->va
            │   ├─ tseg->seg.ubva.eid    = dev->eid_table.eid_entries[cfg->eid_index].eid
            │   ├─ tseg->seg.attr        = cfg->flag
            │   ├─ tseg->token_id        = cfg->token_id
            │   └─ return tseg
            │
            ├─ arg.out.token_id = seg->seg.token_id
            ├─ arg.out.handle   = uobj->id                 ← userspace's seg handle
            ├─ uburma_tlv_append(hdr, &arg)
            └─ uobj_alloc_commit(uobj)
```

### 4.3 Where the work actually lives

| Layer | What it really does |
|---|---|
| `ummu_grant` (userspace) | sets memory permissions in the U-MMU layer — happens before the ioctl |
| `dev->ops->register_seg` (kernel driver) | pins user pages with `get_user_pages_fast`, IOMMU-maps them, programs the device's token-id table |

Everything else is parameter validation, TLV encode/decode, and uobj bookkeeping. **`register_seg` itself is fully local — no peer coordination.**

---

## 5. What's actually inside `register_seg` on either side

### 5.1 The buffer (`perftest_resources.c:743-865`)

```c
local_buf[i] = use_huge_page ? ub_hugemalloc(buf_len, ...)
                             : memalign(page_size, buf_len);
```

Neither `calloc` nor `memset` is applied. The buffer is **uninitialized** at registration time. Contents are whatever the kernel zero-page fault filled in for fresh allocations (effectively zeros on first touch), but perftest never deliberately populates them. The run-test phase overwrites the buffer.

### 5.2 Layout

`PERFTEST_BUF_NUM = 2` in `perftest_resources.h:21`. Comment at L772 says "Buff is divided into two parts, one for recv and the other for send":

```
buf_size = align_to_cacheline(max(cfg->size, page_size))
buf_len  = buf_size * 2 * (seg_pre_jetty ? 1 : cfg->jettys)

  ┌─────────────────┬─────────────────┐
  │  recv landing   │  send / scratch │
  │  first half     │  second half    │
  └─────────────────┴─────────────────┘
```

The run-test code (`perftest_run_test.c`) consistently uses `local_buf[id] + 0` as the receive area and `local_buf[id] + buf_size` as the send/scratch area.

### 5.3 The `seg_cfg` shipped to the kernel (`perftest_resources.c:823-837`)

```c
urma_reg_seg_flag_t flag = {
    .bs.token_policy   = cfg->token_policy,
    .bs.cacheable      = URMA_NON_CACHEABLE,
    .bs.access         = URMA_ACCESS_READ | URMA_ACCESS_WRITE | URMA_ACCESS_ATOMIC,
    .bs.token_id_valid = URMA_TOKEN_ID_VALID,
};
urma_seg_cfg_t seg_cfg = {
    .va          = (uint64_t)local_buf[j],
    .len         = buf_len,
    .token_value = { .token = 0xABCDEF },   // hardcoded g_perftest_token at L31-33
    .token_id    = token_id[j],
    .flag        = flag,
};
```

Hardcoded token `0xABCDEF` on both sides — this is what authorizes the peer's `import_seg` to address this memory.

### 5.4 The kernel-side descriptor

```c
struct ubcore_seg {
    struct ubcore_ubva ubva;   // {eid = ctx->eid, va = local_buf[j]}
    uint64_t len;              // buf_len
    uint32_t token_id;
    union ubcore_reg_seg_flag attr;
};
```

This `urma_seg_t` is what `exchange_seg_info` ships per jetty over TCP (`perftest_resources.c:891`).

---

## 6. UMS (ubsocket) — the kernel-side consumer

UMS = **UB Memory-based Socket**. A kernel module that fork-ports Linux's `net/smc/` (SMC-R) to use UMDK-URMA/ubcore in place of RDMA verbs. Source: `umdk/src/usock/ums/`. Already overviewed in [`umdk_cam_dlock_usock.md`](umdk_cam_dlock_usock.md); this section adds the **`connect()` call chain**.

### 6.1 Layout

```
umdk/src/usock/ums/
├── kmod/ums/                      ← kernel module (~5,700 lines core)
│   ├── ums_mod.c                  ← module init/exit, AF_SMC registration
│   ├── sockops/                   ← proto_ops (one .c per syscall)
│   ├── cm/                        ← CLC + LLC + link/conn lifecycle (from SMC-R)
│   │   ├── ums_clc.c              ← CLC handshake (over TCP)
│   │   ├── ums_llc.c              ← Link Layer Control (over UB)
│   │   ├── ums_core.c             ← ums_conn_create, ums_buf_register, ums_rmb_import_seg
│   │   └── ums_process_link.c
│   ├── dev/                       ← URMA/UB adapter
│   │   ├── ums_ubcore.c           ← ubcore client + device tracking + jfr creation
│   │   └── ums_wr.c               ← work requests, rx/tx seg registration
│   ├── io/                        ← data path (ums_tx, ums_rx, ums_cdc)
│   ├── dim/  dfx/  utils/  config/
│   └── ums_mod.h
├── ums_agent/                     ← userspace daemon (systemd-managed)
└── tools/
    ├── ums_admin/                 ← admin CLI
    ├── ums_run/                   ← LD_PRELOAD wrapper script
    └── ums-preload.c              ← libsmc-preload.so source
```

### 6.2 How an app reaches UMS — three onboarding modes

1. Direct: `socket(AF_SMC, SOCK_STREAM, SMCPROTO_SMC)` (or `SMCPROTO_SMC6`).
2. LD_PRELOAD: `ums_run ./your_app` → `libsmc-preload.so` intercepts `socket()` and rewrites `AF_INET + SOCK_STREAM + IPPROTO_TCP` → `AF_SMC + SMCPROTO_SMC` (`tools/ums-preload.c:77-100`).
3. ULP: `setsockopt(SOL_TCP, TCP_ULP, "smc")` on an existing TCP socket — enabled by `tcp_register_ulp(&g_ums_ulp_ops)` in `ums_mod.c:1159`.

Module init at `ums_mod.c:1143-1184` also calls `sock_register(&UMS_SOCK_FAMILY_OPS)` (AF_SMC = 43) and `ums_ubcore_register_client()` (`dev/ums_ubcore.c:929`) to join ubcore's client list.

### 6.3 `connect()` call chain

When the app calls `connect()` on an AF_SMC socket, VFS dispatches to `sock->ops->connect = ums_connect`.

```
sys_connect(sockfd, &peer, alen)                 glibc → kernel
│
└─ __sys_connect → sock->ops->connect            net/socket.c
   │
   └─ ums_connect(sock, addr, alen, flags)       sockops/ums_connect.c:573
      │
      ├─ ums_connect_check_sock_state            L589
      ├─ ums_connect_check_sk_state              L596
      ├─ ums_connect_process_clcsock             L600   ← prep internal TCP sock
      │
      ├─ kernel_connect(ums->clcsock, addr, ...) L604
      │  └─ standard tcp_v4_connect, 3-way handshake on clcsock     ◄═ TCP control plane
      │
      └─ ums_connect_inner(ums)                  L620                  (= clcsock)
         │
         ├─ ums_connect_fallback_check                                  ║
         │  (early TCP fallback if peer doesn't advertise UMS)         ║
         │                                                              ║
         ├─ ums_connect_ini_init                                        ║
         │  └─ ums_vlan_by_tcpsk(clcsock, ini)                          ║
         │                                                              ║
         └─ ums_connect_process_clc              L357                   ║
            │                                                           ║
            ├─ ums_connect_clc                   L339                   ║
            │  ├─ ums_clc_send_proposal(ums, ini)         ─────────►   ║  CLC proposal
            │  └─ ums_clc_wait_msg(..., UMS_CLC_ACCEPT, CLC_WAIT_TIME)◄═║  CLC accept
            │                                                           ║
            ├─ ums_connect_check_aclc                                   ║
            │                                                           ║
            └─ if (aclc->hdr.typev1 == UMS_TYPE_R):                     ║
               │                                                        ║
               └─ ums_connect_ub(ums, aclc, ini)   L277                ║
                  │                                                     ║
                  ├─ ums_client_create_resources    L178                ║
                  │  ├─ ums_init_ini_info(ini, aclc)                    ║
                  │  ├─ ums_ubcore_find_ub_dev_by_eid(peer_eid, ini)    ║
                  │  │  └─ ubcore_get_device_by_eid(...)                ║   ◄── into
                  │  └─ ums_conn_create(ums, ini)         cm/ums_core.c:1322 ║      ubcore
                  │     └─ ums_link_create(...) (per link, in dev/ums_wr.c)   ║
                  │        ├─ ubcore_create_jfc(...)                    ║
                  │        ├─ ubcore_create_jfs(...)                    ║
                  │        ├─ ubcore_create_jfr(...)                    ║
                  │        ├─ ums_wr_alloc_rx_tx_bufs(...)               ║
                  │        │  ├─ lnk->rx_tseg = ubcore_register_seg(rx_cfg) ║  ums_wr.c:788
                  │        │  └─ lnk->tx_tseg = ubcore_register_seg(tx_cfg) ║  ums_wr.c:794
                  │        └─ ums_llc_send_add_link(...)                 ║   ◄── over UB
                  │                                                     ║         (URMA path)
                  ├─ ums_client_bind_server         L238                ║
                  │  ├─ ums_buf_create(ums)            kernel vzalloc   ║
                  │  ├─ ums_buf_register(ums)          cm/ums_core.c:1626 ║
                  │  │  └─ ums_link_reg_buf(link, buf_desc, is_rmb)      ║
                  │  │     └─ ubcore_register_seg(rmb / sndbuf, ...)     ║   ums_core.c:1426
                  │  ├─ ums_rmb_import_seg(conn, aclc)  cm/ums_core.c:1658 ║
                  │  │  └─ ubcore_import_seg(peer_rmb, ...)              ║   ums_core.c:1677
                  │  └─ if (first_contact_local):                       ║
                  │     │   ums_ubcore_ready_link(link)                  ║
                  │     │   └─ ubcore_advise_jfr / TP setup              ║   <─── on-wire UB CM
                  │     │     (this is where multi-ms peer handshake fires)
                  │     └─ else: ums_llc_announce_credits(link, UMS_LLC_RESP)
                  │                                                     ║
                  ├─ ums_clc_send_confirm(...)    L297     ───────────►║   CLC confirm
                  │                                                     ║
                  └─ if (first_contact_local):  ums_clnt_conf_first_link
```

### 6.4 Key features

- **Two channels run in parallel:** TCP `clcsock` for CLC negotiation (analogous to perftest's `sock_sync_data`), plus the UB data plane for the actual RDMA-style transfers.
- **Sequence:** TCP `connect` → CLC proposal → CLC accept → resource creation (jfs/jfr + rx/tx tsegs) → buf create + register + peer-RMB import → ready_link (TP setup) → CLC confirm.
- **Ubcore calls in the connect path:** `ubcore_get_device_by_eid`, `ubcore_create_jfc/jfs/jfr`, `ubcore_register_seg` (×2 for rx/tx, ×2 for sndbuf/rmb), `ubcore_import_seg` (peer rmb), `ubcore_advise_jfr` / TP modify.
- **No URMA userspace library involved.** UMS links against the kernel's exported ubcore symbols.

### 6.5 UMS vs perftest — what differs

| Concern | urmaperftest | UMS |
|---|---|---|
| Who issues `register_seg` | userspace via `URMA_CMD_REGISTER_SEG` ioctl | kernel direct (no ioctl) — runs in module context |
| Peer key exchange channel | TCP from `establish_connection` + `sock_sync_data` | per-socket `clcsock` (also TCP) + CLC frames |
| Buffer ownership | user `memalign` / `ub_hugemalloc` | kernel `vzalloc` / contiguous pages (`UMS_PHYS_CONT_BUFS`) |
| Token | hardcoded `0xABCDEF` | random per-buf via `get_random_bytes` (or 0 if `ub_token_disable=1`) |
| Access flags | READ\|WRITE\|ATOMIC for all segs | `RMB_ACCESS` vs `SENDBUF_ACCESS` (asymmetric — sendbuf is local-only) |
| TP setup | userspace `connect_jfr` → `urma_import_jfr` ioctl | kernel `ubcore_create_jfr` direct |
| Failure mode | abort | falls back to plain TCP via `clcsock` (graceful) |

---

## 7. UMQ — the userspace consumer

UMQ is a userspace messaging library (part of URPC). It does **not** sit underneath UMS — they're parallel paths to ubcore. The closest thing to "connect" in UMQ is `umq_create()`. Details in [`umq_architecture.md`](umq_architecture.md); the slice below is the URMA-API contract.

### 7.1 `umq_create()` call chain

```
umq_create(umq_create_option_t *option)            urpc/umq/umq_api.c:721
│
├─ option validation, transport selection (IPC | UB | UB_PLUS | UBMM)
│
└─ tp_create dispatcher selects per-transport impl:
   │
   ├─ option->transport == UMQ_TP_UB:
   │  └─ umq_tp_ub_create(umqh, ctx, option)        umq/umq_ub/umq_ub_api.c:59
   │     │
   │     └─ umq_ub_create_impl(umqh, ctx, option)   umq/umq_ub/core/umq_ub_impl.c:908
   │        │
   │        ├─ umq_ub_alloc_resources
   │        │  └─ urma_create_context / urma_get_device_by_name
   │        │     └─ ioctl(URMA_CMD_CREATE_CTX = 1)
   │        │
   │        ├─ umq_create_jetty(queue, dev_ctx, jetty_idx)   umq_ub.c:1103
   │        │  └─ urma_create_jetty(urma_ctx, &cfg)
   │        │     └─ ioctl(URMA_CMD_CREATE_JETTY = 22)
   │        │
   │        ├─ umq_create_jfc / umq_create_jfr                    umq_ub.c:1510-1542
   │        │  └─ urma_create_jfce → ioctl(URMA_CMD_CREATE_JFCE)
   │        │  └─ urma_create_jfc  → ioctl(URMA_CMD_CREATE_JFC)
   │        │  └─ urma_create_jfr  → ioctl(URMA_CMD_CREATE_JFR)
   │        │
   │        ├─ umq_ub_create_flow_control_resource              umq_ub.c:1642
   │        │  └─ urma_register_seg(ctx, &seg_cfg)
   │        │     └─ ioctl(URMA_CMD_REGISTER_SEG = 4)
   │        │
   │        ├─ umq_ub_exchange_remote_info                       (transport layer)
   │        │  └─ OOB channel (typically UDS/TCP, not UB)
   │        │
   │        └─ umq_ub_connect_jetty                              umq_ub.c:515
   │           └─ urma_bind_jetty(jetty[i], tjetty)
   │              └─ ioctl(URMA_CMD_BIND_JETTY = 33)
   │                 → kernel uburma_cmd_bind_jetty
   │                 → ubcore_bind_jetty
   │                 → driver TP/CM state machine (UB on-wire handshake)
   │
   ├─ option->transport == UMQ_TP_IPC:
   │  └─ umq_ipc_create_impl(...)        umq_ipc/umq_ipc_impl.c:257
   │     (shared-memory ring; no URMA, no ioctl, no network)
   │
   └─ option->transport == UMQ_TP_UBMM:
      └─ umq_tp_ubmm_create(...)          umq_ubmm/umq_ubmm.c:44
```

Every URMA call here lands as `ioctl(0xc0105501)` with the per-op `command` byte set, as documented in §2.

---

## 8. Convergence at `ubcore_*`

Both UMS and UMQ bottom out at the same set of **ubcore kernel functions** — `ubcore_register_seg`, `ubcore_import_seg`, `ubcore_create_jfs/jfr/jfc`, `ubcore_bind_jetty`, `ubcore_advise_jfr`. The only difference is *who* calls them:

- **UMS calls them directly** via `EXPORT_SYMBOL` (UMS is loaded into the kernel; ubcore is its dependency).
- **UMQ calls them indirectly** by issuing `URMA_CMD_*` ioctls through the URMA userspace library; the kernel's `uburma_cmd_*` handler translates each ioctl into the corresponding `ubcore_*` call.

```
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│ socket(AF_SMC, ...) + connect() │   │ umq_create(...)                 │
│   userspace app                 │   │   userspace app                 │
└───────────┬─────────────────────┘   └───────────┬─────────────────────┘
            │ syscall (sys_connect, sys_send…)    │ function call (linked .so)
            ▼                                      ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│ UMS kernel module                │   │ liburpc-umq.so / liburma.so     │
│   ──> ubcore_register_seg(...)   │   │   ──> ioctl(0xc0105501, ...)    │
└───────────┬─────────────────────┘   └───────────┬─────────────────────┘
            │                                      │
            │           ┌──────────────┐           │
            └──────────►│   ubcore     │◄──────────┘
                        │  kernel API  │
                        └──────┬───────┘
                               ▼
                       (driver, HW, IOMMU)
```

The lower half of the stack (everything below `ubcore_*`) is identical for both paths: driver `register_seg` op, page pinning, IOMMU map, token-id table programming, TP state-machine traffic. The difference is purely the **upper-half binding** — kernel-resident protocol vs userspace library + ioctl.

---

## 9. How to measure the suspected pause

For diagnosing where setup time goes (sub-phases of `exchange_connection_info`, or the TP handshake in `connect_jfr`):

### 9.1 Source-level (recommended if rebuild is possible)

Add `clock_gettime(CLOCK_MONOTONIC, ...)` calls around each sub-phase of `exchange_connection_info` (`perftest_resources.c:1177`) and emit a single `fprintf` at the end with `seg=Xus jid=Yus credit=Zus tp_create=Aus tp_xchg=Bus total=Tus`. Run on **both** peers simultaneously — the slower one reports true elapsed; the faster one reports how long it was blocked in `read()`.

### 9.2 Without rebuild — bpftrace uprobe

```bash
nm /path/to/urma_perftest | grep exchange_connection_info
```

If the static symbol survived `-O2`:

```bash
sudo bpftrace -e '
uprobe:/path/to/urma_perftest:exchange_connection_info { @t[tid] = nsecs; }
uretprobe:/path/to/urma_perftest:exchange_connection_info /@t[tid]/ {
    printf("pid %d xchg: %lld us\n", pid, (nsecs - @t[tid])/1000);
    delete(@t[tid]);
}'
```

If inlined away, use `sock_sync_data` (defined in a different .o, survives) and count entries per-tid; or use `perf probe --add 'exchange_connection_info' -x /path/to/urma_perftest` with DWARF.

### 9.3 Derive from existing trace

Walk the trace for the relevant PID:

- **start of `exchange_connection_info`** = first `sys_sendto` after the last `REGISTER_SEG`-class ioctl burst
- **end of `exchange_connection_info`** = last `sys_recvmsg` before the first `IMPORT_SEG`-class ioctl burst

The timestamp delta is the elapsed time as observed.

---

## 10. Open questions

- **Inlining behavior** for `exchange_connection_info` and `sock_sync_data` under `-O2` on aarch64 — needs `nm` / `objdump` confirmation on a built binary. The static-with-single-caller pattern is highly inlinable; if inlined, uprobe attachment requires DWARF + `perf probe`.
- **The 5.95s pause from PID 329289's function_graph trace** (different run than the trace this analysis is built from) — provisional verdict: most likely `connect_jfr` waiting for peer's UB CM handshake, not setup TCP. Needs paired-side instrumentation to confirm.
- **Bonding path divergence:** `ubcore_import_seg` has a bonding-specific branch (`ubcore_connect_exchange_udata_when_import_seg` at `ubcore_segment.c:265`) that *does* coordinate across the bonding pair. Not on the simple perftest path; left as future work if the trace is on a bonded device.

---

## Document log

- **2026-05-21** — Initial draft. Synthesized from GitHub issue #7 investigation: ioctl dispatcher analysis, perftest per-phase ioctl/TCP budget, client/server symmetry, `sock_sync_data` semantics, register_seg full call chain, UMS connect call chain, UMQ comparison.
