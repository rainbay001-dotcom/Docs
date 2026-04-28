# Getting peer EIDs from UBSE for UDMA TP-list warmup

_Last updated: 2026-04-28._

The UDMA TP-list cache warmup (see [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) and the `codex/udma-tp-cache` branch) needs peer EIDs as input. Today the in-kernel cache only consumes them via the `udma_tp_warmup_peer_eids` module parameter — i.e. an operator types them. There is no kernel-side peer-EID enumeration helper in `ubcore`. This doc traces where peer-EID information actually lives in the UBSE stack and lays out the practical options for feeding it into UDMA.

Source: `ubs-engine` repo at `git@atomgit.com:ray-yang0218/ubs-engine.git` (cloned to `/Volumes/KernelDev/ubs-engine`).

---

## 1. Where the data lives inside UBSE

```
UBM (topology source)
  ──xml/socket──▶ UbseNodeController                     ubseNodeInfo.bondingEid : std::string
                       │                                  ubse_node_controller.cpp:64,707
                       ▼
                ubse_urma_uvs.cpp::UbsePushTopoAndBondingToUvs
                       │   fills UbcoreTopoNode { primary_eid, port_eid[] }
                       │   marks local node is_current = 1
                       ▼
                uvs_set_topo_info(nodes, sizeof(UbcoreTopoNode), n)   /* dlsym from libuvs */
                       │
                       ▼
                uvs → ubcore_cmd_set_topo → g_ubcore_topo_map
```

So UBSE has every cluster node's `bondingEid` in memory (string), and pushes per-node `primary_eid` plus per-port `port_eid[]` into UVS, which forwards it into kernel `ubcore`. Once UBSE has run, `g_ubcore_topo_map` in ubcore knows every peer's EIDs.

The data exists. It is just not exposed *outward* through any clean library API.

## 2. What's exposed externally

| Surface | Has peer EIDs? | Reference |
| --- | --- | --- |
| `libubse-client.so` topo C API (`ubs_topo_node_list`, `ubs_topo_node_local_get`, `ubs_topo_link_list`) | ❌ slot/socket/NUMA/IP/hostname only; links return `{slot,port,peer_slot,peer_port}`, never EIDs | `docs/api/libubse_topo.md` |
| `libubse-client.so` URMA C API (`ubs_urma_dev_get/_alloc/_free`) | ❌ local device only — `bonding_eid` from `_alloc` is the local one | `docs/api/libubse_urma.md` |
| Go SDK (`src/sdk/go/topo`, `src/sdk/go/urma`) | ❌ wraps the C API, same coverage | |
| Python SDK (`src/sdk/python`) | ❌ same | |
| LCNE topo notification (`/var/run/ubse/ubse_ubm.socket`) | ❌ change-event endpoint only — does not expose peer EIDs | `docs/api/lcne_topo.md` |
| **`ubsectl display cluster`** | ✅ `bonding-eid` column for *every* cluster node | `docs/cli/ubsectl_topo.md` §2 |
| **`ubsectl display node [-n N]`** | ✅ same data, single node | `docs/cli/ubsectl_topo.md` §3 |
| **Internal RPC `ubse_invoke_call(UBSE_NODE, UBSE_CLUSTER_INFO, ...)`** | ✅ what the CLI calls | `src/cli/ubse_cli_node_cmd_reg.cpp:90` |

**Note on ubcore (kernel side).** Three exported symbols look like topology helpers but none enumerate peer EIDs:

- `ubcore_get_route_list(src, dst, &out)` — needs the peer EID as input. Used by codex's warmup for path expansion.
- `ubcore_get_path_set(src, dst, &out)` — same shape.
- `ubcore_get_topo_eid(...)` — defined at `kernel-ub/drivers/ub/urma/ubcore/ubcore_topo_info.c:1219`, but the body is a stub: `if (... != NULL) { ubcore_log_info(...); return 0; } return -1;` — does not actually fill the output args.

So the kernel doesn't currently expose peer enumeration either. The only authoritative producer is UBSE in user-space.

## 3. Output shape

`ubsectl display cluster` returns rows like:

```
node                  role          bonding-eid                               guid
computer01(1)         master        4245:4944:0000:0000:0000:0000:0100:0000   CC08-A000-...
computer02(2)         standby       4245:4944:0000:0000:0000:0000:0200:0000   CC08-A000-...
computer03(3)         agent         4245:4944:0000:0000:0000:0000:0300:0000   CC08-A000-...
```

Format conversion to the form `udma_tp_warmup_peer_eids` accepts: strip colons, prepend `0x`. `4245:4944:0000:0000:0000:0000:0100:0000` → `0x42454944000000000000000001000000`.

## 4. Concrete options for UDMA warmup integration

### Option A — scrape `ubsectl` from a deployment script (recommended for now)

Works today, requires no code changes anywhere. Sketch:

```bash
#!/bin/bash
# Drop in /etc/udma-warmup-peers.sh, run as a systemd oneshot ordered After=ubse.service.

# Find local slot to exclude
local_slot=$(ubsectl display node 2>/dev/null | awk '/^[a-zA-Z]/ && $1 ~ /\(/ { gsub(/[()]/," "); print $2; exit }')

# Pull all cluster bonding-eids except local
peer_eids=$(ubsectl display cluster | awk -v skip="$local_slot" '
    $1 ~ /^[a-zA-Z]/ && $1 ~ /\(/ {
        # extract slot from "host(N)"
        match($1, /\(([0-9]+)\)/, m)
        if (m[1] == skip) next
        if ($3 == "-") next
        eid = $3
        gsub(":", "", eid)
        printf "%s0x%s", (n++ ? "," : ""), eid
    }
    END { print "" }
')

[ -n "$peer_eids" ] && echo "$peer_eids" > /sys/module/udma/parameters/udma_tp_warmup_peer_eids
echo 1 > /sys/module/udma/parameters/udma_tp_warmup_enable
echo 1 > /sys/module/udma/parameters/udma_tp_cache_enable
```

Re-run on topology-change events. Two ways to trigger:

- Subscribe to LCNE notifications at `/var/run/ubse/ubse_ubm.socket` `POST /topolink/change/` and re-run on each notification (`docs/api/lcne_topo.md`).
- Or just rely on a periodic `systemd timer` (cheapest).

Strengths: zero code changes outside deployment. Per the warmup design, after the script writes new peer EIDs every subsequent ucontext-creation re-reads the param so future user processes warm against the latest topology. Module-load (device-probe) warmup misses this, but ucontext warmup catches it from the next process onward.

Weaknesses: brittle to CLI output format changes; race window between UBSE start and first kernel `udma_init_dev` warmup attempt (loses the device-probe warmup train).

### Option B — direct RPC over `ubse.sock`

Skip the CLI; call the same RPC the CLI calls:

```c
ubse_invoke_call(UBSE_NODE, UBSE_CLUSTER_INFO, &req, &res);
/* res is a serialized stream of [node, role, bondingEid, guid] rows;
   see UbseCliRegNodeModule::UbseCliProcessClusterDataTable in src/cli/ubse_cli_node_cmd_reg.cpp:55-90 */
```

`ubse_invoke_call` is in `libubse` — the same lib `ubsectl` itself links against. The opcode `(UBSE_NODE, UBSE_CLUSTER_INFO)` is not in the public `libubse-client.so` API doc, but the binary stability is at least as good as the CLI's contract. A small C/Go program calls it, parses the stream, and writes to sysfs.

Strengths: structured stream, no parsing of human-formatted CLI output, faster than spawning `ubsectl`.

Weaknesses: not a documented public API surface; `(UBSE_NODE, UBSE_CLUSTER_INFO)` could be renamed across UBSE versions.

### Option C — add a real public API to libubse-client (long-term answer)

Promote what the CLI already gets via RPC into a documented C API:

```c
/* New in <ubs_engine_topo.h> */
typedef struct {
    uint32_t slot_id;
    char     hostname[HOST_NAME_MAX];
    char     role[16];                              /* master|standby|agent */
    char     bonding_eid[UBS_MAX_URMA_PATH_LENGTH]; /* "4245:4944:..." */
    char     guid[UBS_MAX_GUID_LENGTH];
} ubs_cluster_node_t;

int32_t ubs_cluster_node_list(ubs_cluster_node_t **list, uint32_t *cnt);
```

Wires through the same RPC machinery. UBSE already has the data; this is just exposing it. Update `docs/api/libubse_topo.md` accordingly. Once shipped, the deployment helper above stops scraping and calls the library directly.

### Option D (nuclear) — kernel ubcore enumeration

Add an EXPORT_SYMBOL like `ubcore_for_each_peer_eid(ubcore_device *, ubcore_eid *, u32 *cnt)` that walks `g_ubcore_topo_map`. Then `udma_tp_cache_schedule_owner_warmup` calls it directly instead of (or in addition to) parsing the module param. Requires ubcore patches plus a UDMA hook on `ubcore_cmd_set_topo` so warmup re-runs whenever UVS pushes new topology.

Most invasive, cleanest end state. Reasonable as a follow-up after Option C is in place — by then the user-space side already has a stable enumeration; mirroring it in-kernel is mechanical.

## 5. Recommendation

| Phase | Action |
| --- | --- |
| **Now** (no code changes) | Option A — scrape `ubsectl display cluster`, push to sysfs from a systemd oneshot ordered after `ubse.service`. Optionally re-run on LCNE topology-change notifications. |
| **Short term** (small UBSE patch) | Option C — add `ubs_cluster_node_list` to `libubse-client`. Then the deployment helper calls the library, no CLI scraping. |
| **Long term** (cross-stack) | Option D — kernel ubcore peer enumeration + UDMA notifier. Eliminates the user-space middleman entirely. |

Until any of B/C/D lands, A is the minimum-viable deployment story. It converts the codex `udma_tp_warmup_peer_eids` param from "operator types it" into "deployment automatically maintains it" without touching kernel or UBSE source.

## 6. References

- Codex branch implementation: `kernel-dev:/Volumes/KernelDev/kernel/drivers/ub/urma/hw/udma/udma_tp_cache.c`
- UDMA prewarm doc: [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md)
- UBSE→UVS push site: `ubs-engine:/src/adapter_plugins/urma_uvs/ubse_urma_uvs.cpp:UbsePushTopoAndBondingToUvs`
- CLI cluster RPC: `ubs-engine:/src/cli/ubse_cli_node_cmd_reg.cpp:UbseCliQueryClusterInfoFunc`
- LCNE notification endpoint: `ubs-engine:/docs/api/lcne_topo.md`
