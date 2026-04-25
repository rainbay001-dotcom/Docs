# URMA user↔kernel boundary — ioctl & data-structure catalogue

_Last updated: 2026-04-25._

The per-ioctl, per-struct catalogue of the URMA user↔kernel boundary. Companion to [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) §6 (which gives the high-level boundary picture).

> **Verification note.** Headline counts (85 enum entries, 4 ioctl magics, key offsets / sizes) were verified directly against `~/Documents/Repo/kernel/drivers/ub/urma/uburma/uburma_cmd.h` on 2026-04-25. The detailed per-command argument-struct tables in §3 came from an Explore-agent survey of the same file plus `uburma_cmd.c`, `ubcore_uapi.h`, `tpsa_ioctl.h`, `uvs_ubagg_ioctl.h`, and `urma_cmd.c`; spot-checked but not exhaustively cross-verified. Treat the tables as a working catalogue — if a specific field width matters for code you're writing, open the header.

---

## 1. The four ioctl magics

The URMA stack uses **four distinct ioctl magics** across the user↔kernel boundary. All confirmed from kernel source.

| Magic | cmd nr | Source | Header struct | Purpose |
|---|---|---|---|---|
| **`'U'`** (`UBURMA_CMD_MAGIC`) | `1` | `uburma_cmd.h:35-36` | `struct uburma_cmd_hdr` (16 B; `uburma_cmd.h:24-28`) | Main URMA control plane (84 sub-commands) |
| **`'E'`** (`UBURMA_EVENT_CMD_MAGIC`) | `0` | `uburma_cmd.h:1369-1380` | (per-call: `uburma_cmd_jfce_wait`, `uburma_cmd_async_event`, `uburma_cmd_wait_notify`) | Event polling — JFC completion / async-event / import-notify wait |
| **`'V'`** (`TPSA_CMD_MAGIC`) | `1` | `umdk/src/urma/lib/uvs/core/tpsa_ioctl.h:30-31` | `tpsa_cmd_hdr_t` (16 B; same shape as uburma_cmd_hdr) | UVS topology / route service |
| `UVS_UBAGG_CMD_MAGIC` | `1` | `umdk/src/urma/lib/uvs/core/uvs_ubagg_ioctl.h:36` | `uvs_ubagg_cmd_hdr` (16 B; same shape) | UVS device aggregation (bonding) |

**`'E'` magic is unusual** — all three event sub-commands use `nr = 0`; they're differentiated by the **`sizeof(type)`** that `_IOWR(magic, nr, type)` encodes into the final ioctl number. From `uburma_cmd.h:1369-1380`:

```c
#define UBURMA_EVENT_CMD_MAGIC 'E'
#define JFCE_CMD_WAIT_EVENT       0
#define JFAE_CMD_GET_ASYNC_EVENT  0
#define NOTIFY_CMD_WAIT_NOTIFY    0

#define UBURMA_CMD_WAIT_JFC \
    _IOWR(UBURMA_EVENT_CMD_MAGIC, JFCE_CMD_WAIT_EVENT, struct uburma_cmd_jfce_wait)
#define UBURMA_CMD_GET_ASYNC_EVENT \
    _IOWR(UBURMA_EVENT_CMD_MAGIC, JFAE_CMD_GET_ASYNC_EVENT, struct uburma_cmd_async_event)
#define UBURMA_CMD_WAIT_NOTIFY \
    _IOWR(UBURMA_EVENT_CMD_MAGIC, NOTIFY_CMD_WAIT_NOTIFY, struct uburma_cmd_wait_notify)
```

**Key constant** (`uburma_cmd.h:30`): `UBURMA_CMD_MAX_ARGS_SIZE = 25600` — kernel-side cap on the args buffer behind `args_addr`.

---

## 2. The wrapper struct — `uburma_cmd_hdr`

Every `'U'` / `'V'` / ubagg ioctl carries the same 16-byte wrapper:

```c
/* uburma_cmd.h:24-28 */
struct uburma_cmd_hdr {
    uint32_t command;     /* enum uburma_cmd value (1..MAX-1) */
    uint32_t args_len;    /* TLV payload length, ≤ UBURMA_CMD_MAX_ARGS_SIZE */
    uint64_t args_addr;   /* userspace pointer to TLV-encoded args buffer */
};
```

The kernel `copy_from_user`s the wrapper, then `copy_from_user`s `args_len` bytes from `args_addr` into a per-call kernel buffer. Per-command argument structs (§3 below) are TLV-encoded inside that buffer.

### 2.1 The provider-passthrough blob — `uburma_cmd_udrv_priv`

Most lifecycle commands embed an opaque "udata" blob the kernel does not interpret:

```c
/* uburma_cmd.h:126-131 */
struct uburma_cmd_udrv_priv {
    uint64_t in_addr;     /* userspace driver input buffer VA */
    uint32_t in_len;
    uint64_t out_addr;    /* userspace driver output buffer VA */
    uint32_t out_len;
};
```

uburma + ubcore copy this in/out and forward it to the provider's `ubcore_ops` slot. The provider — e.g. `hw/udma` — interprets the contents (per-HW versioning of the user-driver protocol). This is how userspace UDMA's `udma_u_*.c` and kernel UDMA's `udma_*.c` keep their version-coupled fields out of the URMA core.

---

## 3. Main `'U'` magic — sub-command catalogue

**Verified count**: 85 enum entries from `UBURMA_CMD_CREATE_CTX = 1` through `UBURMA_CMD_MAX` sentinel — i.e. **84 actual sub-commands** (`uburma_cmd.h:35-123`).

Below are the sub-commands grouped by purpose. **Tables sourced from automated agent survey of `uburma_cmd.h` + `uburma_cmd.c`; spot-checked but treat field widths as informative-not-authoritative.**

### 3.1 Context lifecycle

| Cmd | Direction | Input fields (selected) | Output fields | Provider op | mmap follow-up |
|---|---|---|---|---|---|
| `UBURMA_CMD_CREATE_CTX` | in/out | `eid[20]`, `eid_index`, **udata** | `async_fd` | `alloc_ucontext` | **YES** — doorbell page, JFC, WQ |
| `UBURMA_CMD_ALLOC_TOKEN_ID` | out | flag, **udata** | `token_id`, handle | `alloc_token_id` | no |
| `UBURMA_CMD_FREE_TOKEN_ID` | in | handle, token_id | — | `free_token_id` | no |

`CREATE_CTX` is the entry point — it's what `urma_create_context()` issues. The returned `async_fd` is the eventfd used for async error/event delivery.

### 3.2 Memory-segment lifecycle

| Cmd | Direction | Input | Output | Provider op | mmap |
|---|---|---|---|---|---|
| `UBURMA_CMD_REGISTER_SEG` | in/out | `va, len, token_id, token, flag`, **udata** | `token_id, handle` | `register_seg` | YES (HW DMA target) |
| `UBURMA_CMD_UNREGISTER_SEG` | in | handle | — | `unregister_seg` | no |
| `UBURMA_CMD_IMPORT_SEG` | in/out | peer `eid, va, len, flag, token, mva`, **udata** | handle | `import_seg` | YES |
| `UBURMA_CMD_UNIMPORT_SEG` | in | handle | — | `unimport_seg` | no |

Important: the **token (TokenValue)** field rides in this struct. The independent rotation per UB Base Spec §11.4.4 is implemented by reissuing `ALLOC_TOKEN_ID` and updating segment bindings — see [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §4.3.

### 3.3 JFR (Jetty-For-Receive) lifecycle

| Cmd | Direction | Notable in fields | Out fields | Provider op | mmap |
|---|---|---|---|---|---|
| `UBURMA_CMD_CREATE_JFR` | in/out | `depth, flag, trans_mode, max_sge, min_rnr_timer, jfc_id/handle, token, id`, **udata** | `id, depth, max_sge, handle` | `create_jfr` | YES (RQ ring) |
| `UBURMA_CMD_MODIFY_JFR` | in | handle, mask, rx_threshold, state, **udata** | — | `modify_jfr` | no |
| `UBURMA_CMD_QUERY_JFR` | in/out | handle | full attr dump (depth, flag, trans_mode, sge, threshold, state) | (none — read-only) | no |
| `UBURMA_CMD_DELETE_JFR` | in/out | handle | `async_events_reported` | `delete_jfr` | no |
| `UBURMA_CMD_DELETE_JFR_BATCH` | in/out | `jfr_num, jfr_ptr` | `async_events_reported, bad_jfr_index` | batch | no |
| `UBURMA_CMD_IMPORT_JFR` | in/out | peer eid, id, flag, token, trans_mode, tp_type, **udata** | tpn, handle | `import_jfr` | YES |
| `UBURMA_CMD_IMPORT_JFR_EX` | in/out | + `tp_handle, peer_tp_handle, tag, tx/rx_psn, stag, dtag` | tpn, handle | `import_jfr` (with TP state) | YES |

Plus newer alloc-based variants: `ALLOC_JFR`, `FREE_JFR`, `SET_JFR_OPT`, `GET_JFR_OPT`, `ACTIVE_JFR`, `DEACTIVE_JFR` — separating "allocate resource" from "make active" for hot-rebind / migration use cases.

### 3.4 JFS (Jetty-For-Send) lifecycle

| Cmd | Direction | Notable fields | Out | Provider op | mmap |
|---|---|---|---|---|---|
| `UBURMA_CMD_CREATE_JFS` | in/out | `depth, flag, trans_mode, priority, max_sge, max_rsge, max_inline_data, retry_cnt, rnr_retry, err_timeout, jfc_id/handle`, **udata** | `id, depth, max_sge, max_rsge, max_inline_data, handle` | `create_jfs` | YES (SQ ring + inline-data buf) |
| `UBURMA_CMD_MODIFY_JFS` | in | handle, mask, state, **udata** | — | `modify_jfs` | no |
| `UBURMA_CMD_QUERY_JFS` | in/out | handle | full attr dump | (none) | no |
| `UBURMA_CMD_DELETE_JFS` | in/out | handle | `async_events_reported` | `delete_jfs` | no |
| `UBURMA_CMD_DELETE_JFS_BATCH` | in/out | `jfs_num, jfs_ptr` | counts + bad_index | batch | no |

Plus alloc-based: `ALLOC_JFS / FREE_JFS / SET_JFS_OPT / GET_JFS_OPT / ACTIVE_JFS / DEACTIVE_JFS`.

### 3.5 JFC + JFCE (completion + completion-event)

| Cmd | Direction | Notable fields | Out | Provider op | mmap |
|---|---|---|---|---|---|
| `UBURMA_CMD_CREATE_JFC` | in/out | `depth, flag, jfce_fd, ceqn`, **udata** | `id, depth, handle` | `create_jfc` | YES (CQ ring + arm-doorbell) |
| `UBURMA_CMD_MODIFY_JFC` | in | handle, mask, **moderate_count, moderate_period**, **udata** | — | `modify_jfc` | no |
| `UBURMA_CMD_DELETE_JFC` | in/out | handle | `comp_events_reported, async_events_reported` | `delete_jfc` | no |
| `UBURMA_CMD_DELETE_JFC_BATCH` | in/out | `jfc_num, jfc_ptr` | counts + bad_index | batch | no |
| `UBURMA_CMD_CREATE_JFCE` | out | — | eventfd `fd` | (none) | no — but `fd` is used for events |

`MODIFY_JFC` is where **CQ-coalescing tunables** ride — `moderate_count` (events before signal) and `moderate_period` (microsecond timer). Provider-specific.

Plus alloc-based: `ALLOC_JFC / FREE_JFC / SET_JFC_OPT / GET_JFC_OPT / ACTIVE_JFC / DEACTIVE_JFC`.

### 3.6 Jetty (the URMA endpoint)

The largest single struct in the catalogue. From the agent survey:

| Cmd | Direction | Selected in fields | Out | Provider op | mmap |
|---|---|---|---|---|---|
| `UBURMA_CMD_CREATE_JETTY` | in/out | `id, jetty_flag, jfs_depth/flag, trans_mode, priority, max_send_sge/rsge, max_inline_data, rnr_retry, err_timeout, send_jfc_id/handle, jfr_depth/flag, max_recv_sge, min_rnr_timer, recv_jfc_id/handle, token, jfr_id/handle, jetty_grp_handle, is_jetty_grp`, **udata** | `id, handle, jfs_depth, jfr_depth, max_send_sge/rsge, max_recv_sge, max_inline_data` | `create_jetty` | YES (SQ + RQ WQE tables, doorbell) |
| `UBURMA_CMD_MODIFY_JETTY` | in | handle, mask, rx_threshold, state, **udata** | — | `modify_jetty` | no |
| `UBURMA_CMD_QUERY_JETTY` | in/out | handle | full attr dump | (none) | no |
| `UBURMA_CMD_DELETE_JETTY` | in/out | handle | `async_events_reported` | `delete_jetty` | no |
| `UBURMA_CMD_DELETE_JETTY_BATCH` | in/out | `jetty_num, jetty_ptr` | counts + bad_index | batch | no |
| `UBURMA_CMD_IMPORT_JETTY` | in/out | peer `eid, id, flag, token, trans_mode, policy, type, tp_type`, **udata** | tpn, handle | `import_jetty` | YES (remote jetty mapping) |
| `UBURMA_CMD_IMPORT_JETTY_EX` | in/out | + `tp_handle, peer_tp_handle, tag, tx/rx_psn, stag, dtag` | tpn, handle | `import_jetty` (with TP state) | YES |
| `UBURMA_CMD_UNIMPORT_JETTY` | in | handle | — | `unimport_jetty` | no |
| `UBURMA_CMD_ADVISE_JETTY` | in | jetty_handle, tjetty_handle, **udata** | — | `advise_jetty` | no |
| `UBURMA_CMD_UNADVISE_JETTY` | in | jetty_handle, tjetty_handle | — | `unadvise_jetty` | no |
| `UBURMA_CMD_BIND_JETTY` | in/out | jetty_handle, tjetty_handle, **udata** | tpn | `bind_jetty` | no |
| `UBURMA_CMD_BIND_JETTY_EX` | in/out | + TP active state | tpn | `bind_jetty` (with TP state) | no |
| `UBURMA_CMD_UNBIND_JETTY` | in | jetty_handle | — | `unbind_jetty` | no |

Async variants — `IMPORT_JETTY_ASYNC`, `UNIMPORT_JETTY_ASYNC`, `BIND_JETTY_ASYNC`, `UNBIND_JETTY_ASYNC` — return immediately; completion is delivered via the `'E'` magic `WAIT_NOTIFY` ioctl.

Plus alloc-based: `ALLOC_JETTY / FREE_JETTY / SET_JETTY_OPT / GET_JETTY_OPT / ACTIVE_JETTY / DEACTIVE_JETTY`.

### 3.7 Jetty group (multipath / LAG)

| Cmd | Direction | In | Out | Provider op |
|---|---|---|---|---|
| `UBURMA_CMD_CREATE_JETTY_GRP` | in/out | `name[64], token, id, policy, flag`, **udata** | `id, handle` | `create_jetty_grp` |
| `UBURMA_CMD_DESTROY_JETTY_GRP` | in/out | handle | `async_events_reported` | `destroy_jetty_grp` |

### 3.8 EID, network address, MAC

| Cmd | Direction | In | Out | mmap |
|---|---|---|---|---|
| `UBURMA_CMD_GET_EID_LIST` | in/out | `max_eid_cnt` | `eid_cnt`, `eid_list[]` (`struct ubcore_eid_info`) | no |
| `UBURMA_CMD_GET_NETADDR_LIST` | in/out | `max_netaddr_cnt` | `netaddr_cnt, addr, len` | no |
| `UBURMA_CMD_GET_EID_BY_IP` | in/out | `net_addr` | `eid` | no |
| `UBURMA_CMD_GET_IP_BY_EID` | in/out | `eid` | `net_addr` | no |
| `UBURMA_CMD_GET_SMAC` | out | — | `mac[6]` (local source MAC) | no |
| `UBURMA_CMD_GET_DMAC` | in/out | `net_addr` | `mac[6]` (peer MAC) | no |

### 3.9 Transport-Path config

| Cmd | Direction | In | Out | Provider op |
|---|---|---|---|---|
| `UBURMA_CMD_MODIFY_TP` | in | `tpn, tp_cfg, tp_attr, tp_attr_mask` | — | `modify_tp` |
| `UBURMA_CMD_GET_TP_LIST` | in/out | `flag, trans_mode, local_eid, peer_eid, tp_cnt`, **udata** | `tp_cnt, tp_handle[≤128]` | provider |
| `UBURMA_CMD_SET_TP_ATTR` | in | `tp_handle, tp_attr_cnt, tp_attr_bitmap, tp_attr[128]`, **udata** | — | provider |
| `UBURMA_CMD_GET_TP_ATTR` | in/out | `tp_handle`, **udata** | `tp_attr_cnt, tp_attr_bitmap, tp_attr[128]` | provider |
| `UBURMA_CMD_EXCHANGE_TP_INFO` | in/out | `tp_cfg, tp_handle, tx_psn` | `peer_tp_handle, rx_psn` | (none — control-plane handshake) |

`MODIFY_TP`'s `tp_attr_mask` is an **18-bit bitmap** indicating which TP fields the call is updating (peer_tpn, PSN, MTU, UDP port range, hop limit, flow label, etc.).

### 3.10 Device queries

| Cmd | Direction | In | Out | Notes |
|---|---|---|---|---|
| `UBURMA_CMD_QUERY_DEV_ATTR` | in/out | `dev_name[64]` | `attr` (struct `uburma_cmd_device_attr`, ~1.9 KB) | Largest single response. Carries device caps, port attrs, GUID, reserved jetty-ID range. |
| `UBURMA_CMD_CREATE_NOTIFIER` | out | — | eventfd `fd` | Generic async-notification eventfd. |

`uburma_cmd_device_attr` (`uburma_cmd.h:1151-1211`) is composed of:

- `uburma_cmd_device_cap` — max counts (JFC/JFS/JFR/jetty/jetty_grp), depths, MTU, atomic caps, TP-type caps, port count.
- `uburma_cmd_port_attr[8]` — per-port MTU, state, link width, speed (max 8 ports = `UBURMA_CMD_MAX_PORT_CNT`).
- GUID + reserved jetty-ID range.

### 3.11 User-control passthrough

| Cmd | Direction | In | Out | Provider op |
|---|---|---|---|---|
| `UBURMA_CMD_USER_CTL` | in/out | `addr, len, opcode`, **udrv** | `addr, len, rsv` | `user_ctl` |

A generic escape hatch — apps send arbitrary opcode + payload through the kernel to provider's `user_ctl` op. Used for HW-specific tunables that don't have first-class commands.

---

## 4. `'E'` magic — event polling

```c
/* uburma_cmd.h:1369-1380 */
#define UBURMA_EVENT_CMD_MAGIC 'E'
#define JFCE_CMD_WAIT_EVENT       0
#define JFAE_CMD_GET_ASYNC_EVENT  0
#define NOTIFY_CMD_WAIT_NOTIFY    0
```

All three event ioctls share `nr=0`, differentiated by struct sizeof:

| Ioctl | Struct (size — agent-surveyed) | Purpose |
|---|---|---|
| `UBURMA_CMD_WAIT_JFC` | `struct uburma_cmd_jfce_wait` (in: `max_event_cnt, timeout_ms`; out: `event_cnt, event_data[16]`) | Block until JFC has CQEs (or timeout) |
| `UBURMA_CMD_GET_ASYNC_EVENT` | `struct uburma_cmd_async_event` (`event_type, event_data, pad`) | Drain async-error queue (jetty state changes, errors) |
| `UBURMA_CMD_WAIT_NOTIFY` | `struct uburma_cmd_wait_notify` (in: `cnt, timeout`; out: `cnt, notify[16]` of `struct uburma_notify`) | Block on async import / bind completion notifications |

`struct uburma_notify` (`uburma_cmd.h:1404-1410`): `{type, status, user_ctx, urma_jetty, vtpn}` — the per-event payload that `IMPORT_JETTY_ASYNC` / `BIND_JETTY_ASYNC` produce.

---

## 5. `'V'` magic — UVS topology / TPSA

`umdk/src/urma/lib/uvs/core/tpsa_ioctl.h:30-31`:

```c
#define TPSA_CMD_MAGIC 'V'
#define TPSA_CMD       _IOWR(TPSA_CMD_MAGIC, 1, tpsa_cmd_hdr_t)
```

Sub-command enum `uvs_global_cmd` (`tpsa_ioctl.h:44-50`):

| Cmd # | Name | Direction | In | Out | Purpose |
|---|---|---|---|---|---|
| 1 | `UVS_CMD_SET_TOPO` | in | `topo_info, topo_num` | — | Load topology (daemon → kernel) |
| 2 | `UVS_CMD_GET_TOPO_EID` | in/out | (per `uvs_cmd_get_route_list_t`) | route info | EID-by-topo lookup |
| 3 | `UVS_CMD_GET_TOPO` | out | — | `topo_map` | Fetch current topology |
| 4 | `UVS_CMD_GET_TOPO_PATH_EID` | in/out | (per `uvs_cmd_get_path_set_t`) | path set with multipath flags | Multi-path query |

Auxiliary structs:

- `uvs_cmd_get_route_list_t` (`tpsa_ioctl.h:65-68`) — query route list by `(src_eid, dst_eid)`.
- `uvs_cmd_get_path_set_t` (`tpsa_ioctl.h:70-78`) — multipath set including bonding EIDs, TP type, multipath flag.

---

## 6. UVS ubagg magic

`umdk/src/urma/lib/uvs/core/uvs_ubagg_ioctl.h:36`:

```c
#define UVS_UBAGG_CMD       _IOWR(UVS_UBAGG_CMD_MAGIC, 1, struct uvs_ubagg_cmd_hdr)
```

(The numeric value of `UVS_UBAGG_CMD_MAGIC` is defined elsewhere in the header; not yet line-verified here.)

Sub-command enum (`uvs_ubagg_ioctl.h:20-27`):

| Cmd # | Name | Purpose |
|---|---|---|
| 1 | `UVS_UBAGG_CMD_ADD_DEV` | Add device to aggregation pool |
| 2 | `UVS_UBAGG_CMD_RMV_DEV` | Remove device from pool |
| 3 | `UVS_UBAGG_CMD_SET_TOPO_INFO` | Set topology for aggregated devices |
| 4 | `UVS_UBAGG_CMD_CREATE_DEV` | Create virtual aggregated device (carries `agg_eid`, `dev_name[64]`) |
| 5 | `UVS_UBAGG_CMD_DELETE_DEV` | Delete virtual aggregated device |
| 6 | `UVS_UBAGG_CMD_GET_DEV_NAME` | Lookup device name by EID |

---

## 7. Patterns, observations, gotchas

### 7.1 Two parallel lifecycle conventions

The kernel maintains **both** the original `CREATE_*` / `DELETE_*` API and a newer **`ALLOC_* / ACTIVE_* / DEACTIVE_* / FREE_*`** convention for `JFR`, `JFS`, `JFC`, and `JETTY`:

- `CREATE` = old; resource is created and made usable in one call.
- `ALLOC` + `ACTIVE` = newer; resource alloc and "go live" are split. Useful for hot-rebind, migration, and pre-warmed pools.

The two paths both pass `udata` through to provider ops; no functional difference at the provider level. The split is about lifecycle granularity for advanced use.

### 7.2 Always-with-udata vs never-with-udata commands

**With udata** (provider-passthrough): all `CREATE_*`, `ALLOC_*`, `MODIFY_*`, `IMPORT_*`, `ADVISE_*`, `BIND_*`, `USER_CTL`, `GET_TP_LIST`, `SET/GET_TP_ATTR`. These all eventually flow through the `ubcore_ops` vtable.

**Never with udata** (kernel-only): `QUERY_*`, `DELETE_*`, `UNREGISTER_SEG`, `UNIMPORT_*`, `GET_EID_LIST`, `GET_NETADDR_LIST`, `GET_EID_BY_IP`, `GET_IP_BY_EID`, `GET_SMAC/DMAC`, `EXCHANGE_TP_INFO`, the three event ioctls. These are read-only or pure-kernel teardown.

### 7.3 mmap follow-ups

These commands need an `mmap()` after success to wire up HW resources:

- `CREATE_CTX` → doorbell page, JFC ring, WQ ring, CEQ.
- `CREATE_JFR / CREATE_JFS / CREATE_JFC` → the corresponding ring + (for JFC) arm-doorbell.
- `CREATE_JETTY` → SQ + RQ WQE tables, doorbell.
- `REGISTER_SEG` → mmap the VA so HW can access pinned pages via UMMU.
- `IMPORT_SEG / IMPORT_JFR / IMPORT_JETTY` → remote endpoint mapping.

These follow-ups use offsets returned in the command's output struct, plus per-command mmap flavors visible in `udma_abi.h` (e.g. `UDMA_DOORBELL_OFFSET = 0x80`, `UDMA_MMAP_RESERVED_SQ`).

### 7.4 Batch commands return `bad_*_index`

`DELETE_JFR_BATCH`, `DELETE_JFS_BATCH`, `DELETE_JFC_BATCH`, `DELETE_JETTY_BATCH` accept arrays and return the index of the first failure. A non-zero `bad_*_index` means everything before that index succeeded; the rest is unprocessed.

### 7.5 Device-reset resilience

`urma_cmd.c:53-61` (userspace) implements `uburma_is_destroy_err()` that **treats kernel `EIO` as success on free ops** — kernel may return `EIO` mid-deletion if the device was reset/hot-removed. Userspace squelches that to avoid double-cleanup attempts.

### 7.6 Async completion via eventfd

Three completion-notification mechanisms cross the boundary:

1. **`async_fd`** returned by `CREATE_CTX` — generic per-context async events.
2. **JFCE eventfd** returned by `CREATE_JFCE` — per-CQ completion-event signal.
3. **Notification eventfd** returned by `CREATE_NOTIFIER` — generic notification channel.

Userspace can `epoll`/`select` on any of them and then drain via the `'E'` magic ioctls (`WAIT_JFC`, `GET_ASYNC_EVENT`, `WAIT_NOTIFY`).

### 7.7 The `MODIFY_JFC` moderation tunables

`MODIFY_JFC` carries `moderate_count` (events before signal) and `moderate_period` (microsecond timer). These are the kernel-exposed knobs that map to UDMA's `jfc_arm_mode` module parameter (see [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) §7.5). Tune for latency vs CPU-load tradeoffs.

---

## 8. Boundary-crossing struct sizes (approximate)

| Struct | Approx. size | Where defined |
|---|---|---|
| `uburma_cmd_hdr` | 16 B | `uburma_cmd.h:24-28` |
| `uburma_cmd_udrv_priv` | 24 B | `uburma_cmd.h:126-131` |
| `uburma_cmd_create_ctx` | ~48 B (in + out + udata) | `uburma_cmd.h` |
| `uburma_cmd_create_jetty` | **~224 B** | `uburma_cmd.h` |
| `uburma_cmd_query_device_attr` | **~1.9 KB output** | `uburma_cmd.h:1151-1211` |
| `uburma_cmd_get_tp_list` output | up to **1024 B** (128 TP handles × 8 B) | `uburma_cmd.h:1280, 1294` |
| Per-call kernel cap | **25,600 B** | `uburma_cmd.h:30` `UBURMA_CMD_MAX_ARGS_SIZE` |

The `create_jetty` payload is the largest single ioctl input; the `query_device_attr` response is the largest single output. The 25 KB hard cap on the args buffer is the kernel-side input-validation limit.

---

## 9. Open / unverified items

1. **`UVS_UBAGG_CMD_MAGIC` numeric value** — defined in `uvs_ubagg_ioctl.h` but I haven't pinned the line. Quick `grep` would confirm.
2. **HCCL / CANN path** — does the production AI stack use these same `'U'` / `'E'` ioctls, or a separate kernel uAPI? The CloudMatrix384 paper ([`umdk_academic_papers.md`](umdk_academic_papers.md) §2.4) describes a "UB driver layer (within CANN)" without naming the kernel surface. Likely same `/dev/ub_uburma_<n>`, but not source-confirmed.
3. **UVS daemon vs library** — UVS is library-only (per [`umdk_code_followups.md`](umdk_code_followups.md) §Q8). The `'V'` magic ioctl works, but the topology state lives in the kernel; a fabric manager separate from per-host UVS lib calls would still be needed for cross-host coordination at scale.
4. **`uburma_cmd_event` exact layout** — agent reported `event_data[16]` for `WAIT_JFC` but didn't pin the line; verify in `uburma_cmd.h:1373-1380` if you depend on it.
5. **Vestigial commands** — the new `ALLOC/ACTIVE/DEACTIVE/FREE` lifecycle is recent; some old `CREATE/DELETE` may end up deprecated. No deprecation markers in source as of OLK-6.6 read.

---

## 10. Cross-references

- **High-level boundary picture** with diagram + summary tables: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md) §6.
- **Spec-side semantic context** (what each Jetty / segment / token actually means): [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §5.
- **UDMA fast-path code** (where mmap'd doorbell + WQ ring writes happen): [`umdk_kernel_internals_and_udma_hotpath.md`](umdk_kernel_internals_and_udma_hotpath.md) §7.
- **URPC wire format** (Appendix H): [`umdk_spec_deep_dive.md`](umdk_spec_deep_dive.md) §6 + [`umdk_urpc_and_tools.md`](umdk_urpc_and_tools.md) §1.3.
- **Two-usage-paths discussion** (URMA-direct vs CANN/HCCL): [`umdk_academic_papers.md`](umdk_academic_papers.md) §3.
