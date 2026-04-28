# `get_tp_list` mitigation module plan

_Created: 2026-04-28._

This document plans a module to reduce the latency impact of repeated
`get_tp_list` calls in the URMA/UDMA stack. It is a design and implementation
plan only; it does not claim the module already exists.

Source context:

- Userspace API: `umdk/src/urma/lib/urma/core/urma_cp_api.c`,
  `urma_cmd.c`, `urma_cmd_tlv.c`
- Kernel uAPI handler: `kernel/drivers/ub/urma/uburma/uburma_cmd.c`
- Kernel common TP API: `kernel/drivers/ub/urma/ubcore/ubcore_tp.c`
- UDMA provider: `kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c`
- UBASE control queue: `kernel/drivers/ub/ubase/ubase_ctrlq.c`

---

## 1. Problem

`urma_get_tp_list()` looks like a small query from the application side, but
the UDMA implementation is a synchronous control-plane operation:

```text
urma_get_tp_list()
  -> urma_cmd_get_tp_list()
  -> ioctl(URMA_CMD_GET_TP_LIST)
  -> uburma_cmd_get_tp_list()
  -> ubcore_get_tp_list()
  -> udma_get_tp_list()
  -> udma_ctrlq_get_tpid_list()
  -> ubase_ctrlq_send_msg()
  -> wait for management/UE response
```

`udma_ctrlq_set_tp_msg()` sets `need_resp = 1`, so `ubase_ctrlq_send_msg()`
treats the request as synchronous. `ubase_ctrlq_wait_completed()` waits on a
completion with the control-queue timeout. The default timeout is initialized
as `CTRLQ_TX_TIMEOUT = 3000` ms in `ubase_ctrlq_queue_init()`.

The current `udma_get_tp_list()` path always sends `UDMA_CMD_CTRLQ_GET_TP_LIST`
to the control queue. It then validates the response and stores each TPID in
`udev->ctrlq_tpid_table`, but it does not use a local lookup to avoid a later
identical control-queue request.

This hurts most when applications call `get_tp_list` in a loop, for example
once per Jetty. `urma_perftest` already has a narrow mitigation:

```c
if (cfg->tp_reuse && cfg->trans_mode == URMA_TM_RM && i > 0) {
    ctx->tp_info[i] = ctx->tp_info[0];
    continue;
}
```

That helps one benchmark mode, but it does not protect general applications or
kernel-side users that repeatedly ask for the same TP list.

---

## 2. Goal

Add a small UDMA-side TP-list mitigation module that handles both latency
sources:

- first-use latency, by proactively creating/fetching TP lists before the
  application's first hot-path `get_tp_list`;
- repeated-call latency, by caching successful responses and collapsing
  concurrent identical misses.

The module should:

- Prewarm likely local/peer EID pairs after EID discovery or context creation.
- Cache successful `GET_TP_LIST` responses by a strict request key.
- Collapse concurrent identical misses so only one caller sends the control
  queue request.
- Invalidate cached entries when TP state changes.
- Expose debug counters for hit/miss/wait/invalidation behavior.
- Be easy to disable at runtime for bring-up and correctness triage.

Non-goals:

- Do not change the UE/MUE firmware protocol.
- Do not change the public URMA API.
- Do not remove the existing perftest `tp_reuse` optimization.
- Do not cache failed `GET_TP_LIST` responses unless a later benchmark proves
  negative caching is safe and useful.
- Do not assume module-init prewarming is valid for userspace callers until the
  request owner semantics of the `flag` field are proven.

---

## 3. First-Creation Mitigation: TP Warmup

Caching only helps after a TP list exists or after the first slow miss. To
mitigate the first creation, the module must move the slow control-queue round
trip earlier and off the application's critical path.

The correct model is **prewarm, not eliminate**: the first
`UDMA_CMD_CTRLQ_GET_TP_LIST` still has to happen somewhere, because the
management side owns TPID allocation and selection. The mitigation is to issue
that request asynchronously when enough topology information is known, so the
later application call usually becomes a local cache hit.

### 3.1 Warmup Trigger Points

Use two trigger points.

1. **Device/EID warmup** after `udma_init_eid_table()`.

   `udma_init_dev()` calls `udma_init_eid_table()`, which calls
   `udma_query_eid_from_ctrl_cpu()` and populates the local UDMA EID table. If
   the module also has a configured peer-host EID set at this point, it can
   schedule background warmup for `(local_eid, peer_eid)` pairs.

2. **Context/PID warmup** when a user context is created.

   Current `udma_get_tp_list()` sends a 24-bit owner-like flag:

   ```c
   if (current->flags & PF_KTHREAD)
       tp_cfg_req.flag = UDMA_DEFAULT_PID;
   else
       tp_cfg_req.flag = (uint32_t)current->tgid & UDMA_PID_MASK;
   ```

   A module-init work item runs in kernel context and therefore uses
   `UDMA_DEFAULT_PID`. If the management side treats that field as process
   ownership, module-init warmup will not satisfy a later userspace process
   using its own `tgid`. To avoid this, add a context-aware warmup hook that
   runs when the process is known. It should enqueue warmup work for the same
   process key that later `get_tp_list()` will use.

### 3.2 `udma_init_eid_table()` Timing And Process

`udma_init_eid_table()` is reached through UDMA device bring-up, not directly
from `module_init()`.

Normal probe path:

```text
module_init(udma_init)
  -> auxiliary_driver_register(&udma_drv)
  -> Linux auxiliary-driver core matches an aux device
  -> udma_probe()
  -> udma_init_dev()
  -> udma_init_eid_table()
```

Reset re-init path:

```text
udma_reset_handler(..., UBASE_RESET_STAGE_INIT)
  -> udma_reset_init()
  -> udma_init_dev()
  -> udma_init_eid_table()
```

Inside `udma_init_dev()`, `udma_init_eid_table()` runs after these steps:

1. `udma_create_dev(adev)` creates the provider device object.
2. `udma_register_event(adev)` registers event handlers.
3. `udma_register_workqueue(udma_dev)` makes the UDMA workqueue available.
4. `udma_set_ubcore_dev(udma_dev)` registers/sets up the ubcore-facing device.
5. `udma_init_eid_table(udma_dev)` queries and installs local EIDs.
6. On success, `udma_dev->status = UDMA_NORMAL`.

This means the warmup module has two useful facts immediately after
`udma_init_eid_table()` returns success: local EIDs are known, and the UDMA
workqueue already exists. The warmup should be scheduled at that point, before
or just after `udma_dev->status = UDMA_NORMAL`, but it must not block probe.

`udma_init_eid_table()` itself is a wrapper around
`udma_query_eid_from_ctrl_cpu()`. That function:

1. Builds a control-queue message with:
   - opcode `UDMA_CTRLQ_GET_SEID_INFO`;
   - service version `UBASE_CTRLQ_SER_VER_01`;
   - service type `UBASE_CTRLQ_SER_TYPE_DEV_REGISTER`;
   - `need_resp = 1`;
   - payload command `UDMA_CMD_CTRLQ_QUERY_SEID` (`0xb5`).
2. Sends the message through `ubase_ctrlq_send_msg()`, so this is a synchronous
   control-queue query to the control CPU.
3. Validates that returned `seid_num` does not exceed `UDMA_CTRLQ_SEID_NUM`.
4. Takes `udma_dev->eid_mutex`.
5. Iterates over returned EIDs.
6. Validates each returned `eid_idx` against `SEID_TABLE_SIZE`.
7. Calls `udma_add_one_eid()` for each entry.

`udma_add_one_eid()`:

1. Allocates a `struct udma_ctrlq_eid_info`.
2. Copies the returned EID info.
3. Stores it in `udma_dev->eid_table` with the EID index as the xarray key.
4. For non-UE devices, registers the EID with UMMU through
   `ummu_core_add_eid()`.
5. Dispatches `UBCORE_MGMT_EVENT_EID_ADD` through ubcore.

On partial failure, `udma_query_eid_from_ctrl_cpu()` rolls back entries already
added in that call by invoking `udma_del_one_eid()` in reverse order, then
returns the error. On init failure, `udma_init_dev()` unwinds ubcore
registration, workqueue registration, event registration, and device creation.

For first-TP mitigation, this matters because the earliest safe device-level
warmup hook is:

```c
ret = udma_init_eid_table(udma_dev);
if (ret)
    goto err_init_eid;

udma_tp_cache_schedule_device_warmup(udma_dev);
udma_dev->status = UDMA_NORMAL;
```

The actual implementation can schedule the work before or after setting
`UDMA_NORMAL`, but the work function must tolerate reset/remove racing it and
must cancel/flush warmup in the reset and remove paths.

### 3.3 Warmup Input

The module needs a source of peer EIDs. If the host EIDs are known at module
initialization, provide them through one of these mechanisms:

- module parameter with a bounded peer-EID list for bring-up;
- configfs/sysfs/debugfs write path for dynamic peer-EID updates;
- UVS/topology callback when topology is set or changed;
- static platform/firmware-provided host EID list if the deployment has one.

Do not derive an all-to-all fabric matrix blindly unless the deployment is
small. Warmup should be bounded by policy:

- selected transport modes: RM/RC/UM as needed;
- selected TP type flags: RTP/CTP/UTP/UBOE as needed;
- local EID subset;
- peer EID subset;
- max concurrent control-queue requests;
- retry/backoff budget.

### 3.4 Peer EIDs From UVS / UBSE Topology

For topology-driven warmup, peer EIDs should come from the UVS/ubcore topology
map rather than from `udma_init_eid_table()`. `udma_init_eid_table()` only
installs local SEIDs. The peer side is known after an external topology source
has populated UVS/ubcore.

The apparent UBSE path is:

```text
UBSE / topology producer
  -> uvs_set_topo_info(topo_buf, node_size, node_num)
  -> uvs_ubagg_ioctl_set_topo()
  -> uvs_ubcore_ioctl_set_topo()
  -> ubcore_cmd_set_topo()
  -> g_ubcore_topo_map
```

The local repo does not contain a UBSE implementation. The evidence that UBSE
is the upstream topology producer is the size check in `uvs_set_topo_info()`:

```c
uint32_t size = sizeof(struct urma_topo_node);

if (size != node_size) {
    TPSA_LOG_ERR("node size not match, urma=%u, ubse=%u\n", size, node_size);
    return -EINVAL;
}
```

`uvs_set_topo_info_inner()` writes the same topology into both ubagg and ubcore:

```text
uvs_ubagg_ioctl_set_topo(topo, topo_num)
uvs_ubcore_ioctl_set_topo(topo, topo_num)
```

The topology node carries the EID material needed for warmup:

```c
struct urma_topo_ue {
    uint32_t chip_id;
    uint32_t die_id;
    uint32_t entity_id;
    char primary_eid[EID_LEN];
    char port_eid[PORT_NUM][EID_LEN];
};

struct urma_topo_agg_dev {
    char agg_eid[EID_LEN];
    struct urma_topo_ue ues[IODIE_NUM];
};

struct urma_topo_node {
    uint32_t type;
    uint32_t super_node_id;
    uint32_t node_id;
    uint32_t is_current;
    struct urma_topo_link links[IODIE_NUM][PORT_NUM];
    struct urma_topo_agg_dev agg_devs[DEV_NUM];
};
```

The warmup module should not pair raw EIDs by scanning this topology itself
unless it exactly duplicates ubcore route logic. Prefer the existing route
helpers, because they convert bonding/aggregate EIDs into correctly paired
primary and port EIDs.

Userspace model:

```c
uvs_route_t route = {
    .src = local_agg_eid,
    .dst = peer_agg_eid,
};
uvs_route_list_t routes = {0};

ret = uvs_get_route_list(&route, &routes);
if (ret == 0) {
    for (uint32_t i = 0; i < routes.len; i++) {
        local_eid = routes.buf[i].src;
        peer_eid = routes.buf[i].dst;
    }
}
```

Kernel-side model:

```c
struct ubcore_route route = {
    .src = local_agg_eid,
    .dst = peer_agg_eid,
};
struct ubcore_route_list routes = {0};

ret = ubcore_get_route_list(&route, &routes);
if (ret == 0) {
    for (uint32_t i = 0; i < routes.route_num; i++) {
        get_tp_cfg.local_eid = routes.buf[i].src;
        get_tp_cfg.peer_eid = routes.buf[i].dst;
        /* schedule warmup for this pair */
    }
}
```

`ubcore_get_route_list()` first appends primary-EID pairs, then appends port-EID
pairs using topology links. For a cross-node direct route, the port pair comes
from the source port link:

```text
src = src_agg_dev->ues[iodie_id].port_eid[port_id]
dst = dst_agg_dev->ues[iodie_id].port_eid[peer_port_id]
```

For path-aware warmup, `uvs_get_path_set()` / `ubcore_get_path_set()` return a
path set whose entries already contain `src_eid` and `dst_eid`:

```c
struct ubcore_path {
    union ubcore_port_id src_port;
    union ubcore_port_id dst_port;
    union ubcore_eid src_eid;
    union ubcore_eid dst_eid;
};
```

Use route-list output for basic `(local_eid, peer_eid)` warmup. Use path-set
output only when the warmup policy needs per-path port selection, multipath
behavior, or topology-specific filtering.

Practical warmup source sequence:

1. Wait until `ubcore_cmd_set_topo()` has created or updated
   `g_ubcore_topo_map`.
2. Identify the current/local aggregate EID from topology or device policy.
3. Enumerate peer aggregate EIDs from topology nodes where `is_current == 0`,
   or from a UBSE/admin-provided peer subset.
4. For each `(local_agg_eid, peer_agg_eid)`, call `ubcore_get_route_list()`.
5. Schedule warmup for each returned physical/primary/port EID pair.
6. Re-run or invalidate warmup when topology is updated.

If the warmup code lives inside UDMA, it should consume a peer aggregate-EID
list delivered by an admin/topology integration path, then call the kernel
ubcore route helpers. It should not call the userspace UVS APIs directly.

### 3.5 Warmup API

Extend the proposed module with explicit warmup calls:

```c
int udma_tp_cache_warmup_pair(struct udma_dev *udev,
                              const union ubcore_eid *local_eid,
                              const union ubcore_eid *peer_eid,
                              const struct udma_tp_warmup_policy *policy,
                              u32 owner_key);

int udma_tp_cache_schedule_warmup(struct udma_dev *udev,
                                  const struct udma_tp_warmup_plan *plan);

void udma_tp_cache_cancel_warmup(struct udma_dev *udev);
```

`owner_key` must be explicit. For device/EID warmup it can be
`UDMA_DEFAULT_PID`. For context warmup it must be the same
`current->tgid & UDMA_PID_MASK` value that normal userspace calls will send.

### 3.6 Warmup Execution

Warmup should run on a dedicated or existing UDMA workqueue, never inline in
probe or context creation. Probe and context creation should enqueue work and
return.

Warmup flow for each key:

1. Build the same cache key that a later `get_tp_list` call would build.
2. Insert a `filling` cache entry before sending the control-queue request.
3. Call the existing slow path once.
4. Store the successful response in the cache and in `ctrlq_tpid_table`.
5. Complete waiters.
6. On failure, complete waiters with the same error and remove the failed
   entry.

This means if the application races with warmup, the application waits on the
in-flight warmup entry instead of sending a duplicate control-queue request.

### 3.7 Owner-Semantics Decision

Before relying on module-init warmup for userspace latency, verify what the
MUE/management side does with `tp_cfg_req.flag`.

Possible outcomes:

- **Flag is only a hint or default namespace.** Device/EID warmup with
  `UDMA_DEFAULT_PID` can populate real TP resources, and later process-specific
  calls can reuse them after cache-key policy is relaxed with proof.
- **Flag is process ownership.** Device/EID warmup helps only kernel/default
  owner users. Userspace first-call mitigation must happen at context creation
  or requires a firmware/API extension to precreate for a specified owner.
- **Flag selects isolation and resource accounting.** Keep PID in the cache key
  and never reuse module-init entries for userspace. Use context warmup as the
  production path.

Until proven otherwise, assume process ownership and keep the cache key strict.

### 3.8 Firmware/API Extension Option

If the requirement is strict "create all first TP lists during module
initialization for future userspace processes," the current API may be
insufficient because the owner is implicit in `current`. The clean extension is
one of:

- add a kernel-internal precreate command that carries an explicit owner key;
- add a shared/global TP-list owner namespace supported by the management side;
- add a userspace/admin prewarm API that runs under the target process or under
  an explicitly selected owner namespace.

Without one of these, module-init prewarming can only safely precreate default
owner TP lists.

---

## 4. Module Boundary

Implement this as a source module inside the kernel UDMA provider, not as a
separate loadable Linux module.

Proposed files:

```text
kernel/drivers/ub/urma/hw/udma/udma_tp_cache.c
kernel/drivers/ub/urma/hw/udma/udma_tp_cache.h
```

Integration points:

- Add cache state to `struct udma_dev`.
- Initialize it during UDMA device initialization.
- Destroy it during UDMA device teardown/reset cleanup.
- Replace the direct call inside `udma_get_tp_list()` with
  `udma_tp_cache_get_or_fetch()`.
- Schedule optional device/EID warmup after `udma_init_eid_table()` succeeds.
- Schedule optional context/PID warmup when a userspace context is created.
- Add invalidation hooks where TPID state is removed, deactivated, or replaced.

Keep the current slow path intact. The cache module should call the existing
`udma_ctrlq_get_tpid_list()` miss path rather than duplicating message packing
or control-queue logic.

---

## 5. Cache Key

The key must be conservative. It should include every field that can change the
returned TP list:

- process identity used by the request:
  - `UDMA_DEFAULT_PID` for kernel threads
  - `current->tgid & UDMA_PID_MASK` for user callers
- canonical transport selector:
  - `trans_type` after `udma_ctrlq_get_trans_type()`, or CTP override
  - link mode: UB vs UBOE
- original `ubcore_get_tp_cfg` selectors:
  - `cfg->flag.value`
  - `cfg->trans_mode`
  - `cfg->local_eid`
  - `cfg->peer_eid`

Suggested key struct:

```c
struct udma_tp_cache_key {
    u32 pid_key;
    u32 flag_value;
    u32 trans_mode;
    u32 trans_type;
    u32 link_mode;
    u8 local_eid[UDMA_EID_SIZE];
    u8 peer_eid[UDMA_EID_SIZE];
};
```

Use the same endian-normalized EID form used in the control-queue request, so
cache comparison matches what the management side actually receives.

---

## 6. Cache Value

Store the complete successful response, not just one TP handle:

```c
struct udma_tp_cache_entry {
    struct hlist_node node;
    struct udma_tp_cache_key key;
    struct completion fill_done;
    refcount_t refs;
    bool filling;
    int fill_result;
    unsigned long created_jiffies;
    struct udma_ctrlq_tpid_list_rsp rsp;
};
```

The response is small: `UDMA_MAX_TPID_NUM` is currently 5, and each TPID entry
contains `tpid`, `tpn_start`, `tpn_cnt`, and migration bits. Keeping the whole
response makes the cache independent of the current caller's requested
`tp_cnt`; the final copy into `struct ubcore_tp_info` still enforces the
caller's capacity.

---

## 7. Lookup And Single-Flight

Use a hash table protected by a mutex. A mutex is acceptable because the miss
path may allocate and because `get_tp_list` already may sleep in the control
queue wait.

Lookup behavior:

1. Build the cache key from `udev`, `tpid_cfg`, and current task identity.
2. If caching is disabled, call the existing slow path.
3. Take the cache mutex and search for the key.
4. If a complete non-expired entry exists, copy the response to the caller.
5. If an entry exists but is still filling, take a reference, drop the mutex,
   and wait on `fill_done`.
6. If no entry exists, insert a `filling` entry, drop the mutex, and execute
   the existing `udma_ctrlq_get_tpid_list()` slow path.
7. Store the result in the entry, complete `fill_done`, then copy the response
   for the original caller.

This prevents N threads requesting the same `(pid, flags, trans mode, local
EID, peer EID)` tuple from sending N control-queue messages.

---

## 8. Freshness And Invalidation

Correctness is more important than hit rate. Use both explicit invalidation and
a short TTL.

Configuration:

```text
udma_tp_cache_enable=0|1
udma_tp_cache_ttl_ms=<milliseconds>
udma_tp_cache_max_entries=<count>
udma_tp_warmup_enable=0|1
udma_tp_warmup_mode=device,context,both
udma_tp_warmup_max_inflight=<count>
```

Recommended rollout defaults:

- First patch: disabled by default, TTL 1000 ms when enabled.
- Warmup disabled by default until owner semantics are validated.
- After validation: enable by default only if TP lifecycle tests pass under
  create/import/bind/deactivate/reset stress.

Explicit invalidation hooks:

- Invalidate entries containing a TPID when `udma_ctrlq_erase_one_tpid()` runs.
- Invalidate entries containing a TPID when a remove/deactivate TP operation
  succeeds.
- Flush all entries on UDMA reset, device teardown, or UE/MUE re-registration.
- Flush entries for a process identity when a process-scoped context is
  destroyed, if a reliable context-destroy hook is available.

TTL rule:

- An entry older than `udma_tp_cache_ttl_ms` is treated as stale and refetched.
- A TTL of `0` should mean "no TTL reuse"; keep the single-flight behavior but
  avoid serving completed cached entries.

---

## 9. Public Internal API

Header sketch:

```c
int udma_tp_cache_init(struct udma_dev *udev);
void udma_tp_cache_destroy(struct udma_dev *udev);

int udma_tp_cache_get_or_fetch(struct udma_dev *udev,
                               struct ubcore_get_tp_cfg *cfg,
                               uint32_t *tp_cnt,
                               struct ubcore_tp_info *tp_list);

void udma_tp_cache_invalidate_tpid(struct udma_dev *udev, u32 tpid);
void udma_tp_cache_flush(struct udma_dev *udev);
void udma_tp_cache_flush_pid(struct udma_dev *udev, u32 pid_key);

int udma_tp_cache_schedule_device_warmup(struct udma_dev *udev);
int udma_tp_cache_schedule_context_warmup(struct udma_dev *udev, u32 pid_key);
void udma_tp_cache_cancel_warmup(struct udma_dev *udev);
```

`udma_tp_cache_get_or_fetch()` should return the same error codes as the
current `udma_get_tp_list()` implementation.

---

## 10. Integration Detail In `udma_get_tp_list`

Current shape:

```c
ret = udma_ctrlq_get_tpid_list(udev, &tp_cfg_req, tpid_cfg, &tpid_list_resp);
...
for (i = 0; i < tpid_list_resp.tp_list_cnt; i++) {
    tp_list[i].tp_handle.bs.tpid = tpid_list_resp.tpid_list[i].tpid;
    ...
}
*tp_cnt = tpid_list_resp.tp_list_cnt;
ret = udma_ctrlq_store_tpid_list(...);
```

Target shape:

```c
ret = udma_tp_cache_get_or_fetch(udev, tpid_cfg, tp_cnt, tp_list);
```

The cache module should internally:

- build `tp_cfg_req.flag` the same way the current code does;
- call the existing control-queue miss function;
- preserve the current validation rules:
  - reject `tp_list_cnt == 0`;
  - reject `tp_list_cnt > *tp_cnt`;
  - reject migration if existing response validation requires it;
- call `udma_ctrlq_store_tpid_list()` for newly fetched responses.

If a cached response contains TPIDs already present in `ctrlq_tpid_table`,
`udma_ctrlq_store_one_tpid()` already treats that as success.

---

## 11. Observability

Add counters to `struct udma_tp_cache`:

- `lookup_cnt`
- `hit_cnt`
- `miss_cnt`
- `stale_cnt`
- `singleflight_wait_cnt`
- `singleflight_error_cnt`
- `insert_cnt`
- `evict_cnt`
- `invalidate_tpid_cnt`
- `flush_cnt`
- `ctrlq_fetch_cnt`
- `ctrlq_fetch_error_cnt`
- `warmup_queued_cnt`
- `warmup_started_cnt`
- `warmup_success_cnt`
- `warmup_error_cnt`
- `warmup_cancel_cnt`
- `warmup_race_wait_cnt`

Expose counters through the existing UDMA debug surface if available. If there
is no suitable debugfs/sysfs surface, start with rate-limited debug logs gated
by the existing `debug_switch`, then add a real readout in a follow-up patch.

Also add tracepoints or temporary timing logs around:

- cache lookup start/end;
- control-queue fetch start/end;
- wait-on-inflight start/end.

The first performance proof should compare `ctrlq_fetch_cnt` against the
number of application-level `urma_get_tp_list()` calls.

---

## 12. Test Plan

Unit/KUnit tests for cache logic:

- key equality and hashing;
- TTL expiry;
- capacity eviction;
- invalidation by TPID;
- single-flight success;
- single-flight failure propagation;
- caller capacity smaller than cached `tp_list_cnt`.

Functional tests:

- Device/EID warmup with known local/peer EIDs: verify the first later
  `get_tp_list` for `UDMA_DEFAULT_PID` is a cache hit.
- Context/PID warmup: create context, wait for warmup completion, then verify
  the first userspace `get_tp_list` is a cache hit for that process key.
- Race test: start userspace `get_tp_list` while warmup for the same key is in
  flight; verify only one control-queue fetch is sent.
- Existing `urma_perftest` without `tp_reuse`: verify repeated identical
  calls hit cache after the first call.
- Existing `urma_perftest` with `tp_reuse`: verify behavior is unchanged.
- Multi-threaded identical local/peer EID query: verify only one control-queue
  fetch is sent.
- Different peer EIDs: verify distinct misses and no cross-contamination.
- Different PID/processes: verify entries do not leak across process identity
  unless explicitly intended.
- Module-init warmup versus userspace PID: verify whether `UDMA_DEFAULT_PID`
  warmed entries can actually satisfy process-keyed calls. Keep strict
  isolation if not.
- Deactivate/remove TP then re-query: verify stale TPIDs are not returned.
- Device reset or UDMA teardown: verify cache is empty afterward.

Performance tests:

- Measure per-call latency around userspace `urma_get_tp_list()`.
- Measure first-call latency with no mitigation, with cache only, with
  device/EID warmup, and with context/PID warmup.
- Measure kernel time spent in `ubase_ctrlq_send_msg()`.
- Record hit/miss counters.
- Compare `jetty_num = 1, 8, 64, 128` with and without cache.
- Run under control-queue pressure by mixing `GET_TP_ATTR`, `SET_TP_ATTR`, and
  `GET_TP_LIST`.

Failure tests:

- Force `ubase_ctrlq_send_msg()` timeout and confirm no failed response is
  cached.
- Force zero `tp_list_cnt` response and confirm the error path is unchanged.
- Force `tp_list_cnt > caller capacity` and confirm `-EINVAL` is returned.

---

## 13. Rollout

Phase 1: instrumentation only

- Add timing and counters around existing `udma_get_tp_list()`.
- Confirm where latency is spent on the target system.

Phase 2: cache module behind disabled-by-default parameter

- Add `udma_tp_cache`.
- Keep cache disabled by default.
- Validate correctness and benchmark locally.

Phase 3: warmup behind disabled-by-default parameter

- Add device/EID warmup after EID table initialization.
- Add context/PID warmup when userspace owner identity is known.
- Validate owner semantics of `tp_cfg_req.flag`.

Phase 4: enable for selected tests

- Enable cache for perftest and known repeated-query workloads.
- Enable warmup for deployments with known peer EIDs.
- Collect hit rate and latency data.

Phase 5: broader default

- Consider enabling by default only after reset, deactivate, migration, and
  process-isolation tests pass.

---

## 14. Risks

Stale TP handles are the primary risk. A stale TPID can cause later TP attr or
activation operations to target a TP that has been removed or repurposed. The
plan therefore requires explicit invalidation plus a TTL.

Process scoping is another risk. The current request embeds a PID-like flag, so
the cache key must include the same value. Sharing cached TP lists across
processes is not safe without proof that the management side treats them as
process-independent.

Module-init warmup can create the wrong owner namespace if the management side
uses `tp_cfg_req.flag` for process ownership. In that case, it will make
kernel/default-owner calls faster but will not remove first-call latency for
normal userspace. Context/PID warmup or an explicit-owner firmware command is
required for that case.

Warmup can create unnecessary TP resources. Bound it by peer-EID policy,
transport mode, max in-flight requests, and TTL. Add a cancel path on EID
removal and device reset.

RM shared-TP logic has a separate busy-wait path in
`ubcore_connect_adapter.c`. This module reduces repeated provider-level
control-queue calls, but it does not fix that spin wait. If profiles still show
CPU burn there, replace the spin loop with a completion/wait queue in a later
patch.

---

## 15. Acceptance Criteria

The module is acceptable when:

- With known peer EIDs and enabled warmup, the first application-visible
  `get_tp_list` for a warmed key avoids sending a new control-queue request.
- A repeated identical `get_tp_list` workload sends one control-queue request
  per fresh key per TTL window, not one request per API call.
- Public URMA behavior and return codes remain compatible.
- TP deactivate/remove/reset tests do not observe stale TP handles.
- Multi-process tests prove PID scoping is respected.
- Debug counters clearly show lookup, hit, miss, invalidation, and slow-path
  fetch behavior.
- The feature can be disabled at runtime to restore the current behavior.
