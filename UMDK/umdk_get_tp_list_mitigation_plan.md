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

Add a small UDMA-side TP-list cache module that avoids repeated synchronous
control-queue requests for the same TP-list query while preserving correctness.

The module should:

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

---

## 3. Module Boundary

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
- Add invalidation hooks where TPID state is removed, deactivated, or replaced.

Keep the current slow path intact. The cache module should call the existing
`udma_ctrlq_get_tpid_list()` miss path rather than duplicating message packing
or control-queue logic.

---

## 4. Cache Key

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

## 5. Cache Value

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

## 6. Lookup And Single-Flight

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

## 7. Freshness And Invalidation

Correctness is more important than hit rate. Use both explicit invalidation and
a short TTL.

Configuration:

```text
udma_tp_cache_enable=0|1
udma_tp_cache_ttl_ms=<milliseconds>
udma_tp_cache_max_entries=<count>
```

Recommended rollout defaults:

- First patch: disabled by default, TTL 1000 ms when enabled.
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

## 8. Public Internal API

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
```

`udma_tp_cache_get_or_fetch()` should return the same error codes as the
current `udma_get_tp_list()` implementation.

---

## 9. Integration Detail In `udma_get_tp_list`

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

## 10. Observability

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

## 11. Test Plan

Unit/KUnit tests for cache logic:

- key equality and hashing;
- TTL expiry;
- capacity eviction;
- invalidation by TPID;
- single-flight success;
- single-flight failure propagation;
- caller capacity smaller than cached `tp_list_cnt`.

Functional tests:

- Existing `urma_perftest` without `tp_reuse`: verify repeated identical
  calls hit cache after the first call.
- Existing `urma_perftest` with `tp_reuse`: verify behavior is unchanged.
- Multi-threaded identical local/peer EID query: verify only one control-queue
  fetch is sent.
- Different peer EIDs: verify distinct misses and no cross-contamination.
- Different PID/processes: verify entries do not leak across process identity
  unless explicitly intended.
- Deactivate/remove TP then re-query: verify stale TPIDs are not returned.
- Device reset or UDMA teardown: verify cache is empty afterward.

Performance tests:

- Measure per-call latency around userspace `urma_get_tp_list()`.
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

## 12. Rollout

Phase 1: instrumentation only

- Add timing and counters around existing `udma_get_tp_list()`.
- Confirm where latency is spent on the target system.

Phase 2: cache module behind disabled-by-default parameter

- Add `udma_tp_cache`.
- Keep cache disabled by default.
- Validate correctness and benchmark locally.

Phase 3: enable for selected tests

- Enable cache for perftest and known repeated-query workloads.
- Collect hit rate and latency data.

Phase 4: broader default

- Consider enabling by default only after reset, deactivate, migration, and
  process-isolation tests pass.

---

## 13. Risks

Stale TP handles are the primary risk. A stale TPID can cause later TP attr or
activation operations to target a TP that has been removed or repurposed. The
plan therefore requires explicit invalidation plus a TTL.

Process scoping is another risk. The current request embeds a PID-like flag, so
the cache key must include the same value. Sharing cached TP lists across
processes is not safe without proof that the management side treats them as
process-independent.

RM shared-TP logic has a separate busy-wait path in
`ubcore_connect_adapter.c`. This module reduces repeated provider-level
control-queue calls, but it does not fix that spin wait. If profiles still show
CPU burn there, replace the spin loop with a completion/wait queue in a later
patch.

---

## 14. Acceptance Criteria

The module is acceptable when:

- A repeated identical `get_tp_list` workload sends one control-queue request
  per fresh key per TTL window, not one request per API call.
- Public URMA behavior and return codes remain compatible.
- TP deactivate/remove/reset tests do not observe stale TP handles.
- Multi-process tests prove PID scoping is respected.
- Debug counters clearly show lookup, hit, miss, invalidation, and slow-path
  fetch behavior.
- The feature can be disabled at runtime to restore the current behavior.
