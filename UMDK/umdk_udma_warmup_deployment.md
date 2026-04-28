# Deploying UDMA TP-list warmup with UBSE-derived peer EIDs

_Last updated: 2026-04-28._

The codex `udma-tp-cache` warmup needs peer EIDs as input. Today the only source the kernel reads is the `udma_tp_warmup_peer_eids` module parameter. UBSE has the data internally but does not expose it through `libubse-client.so`; the most stable user-facing surface is `ubsectl display cluster` (see [`umdk_ubse_peer_eid_discovery.md`](umdk_ubse_peer_eid_discovery.md)).

This doc covers the deployment script that bridges the two: scrape `ubsectl`, write the kernel sysfs parameter, optionally enable the cache and warmup. Plus systemd integration and verification.

Script: [`scripts/udma_warmup_peers.sh`](scripts/udma_warmup_peers.sh).

---

## 1. What the script does

1. Verifies prerequisites (root, `ubsectl` in PATH, udma sysfs present, codex patch parameter exists).
2. Determines the local node's slot id via `ubsectl display node` and excludes it (default).
3. Calls `ubsectl display cluster`, extracts the `bonding-eid` column for every other node, skipping rows where the EID is `-` (UBSE info missing) or malformed.
4. Converts the IPv6-style colon notation (`4245:4944:...:0100:0000`) to the hex form the kernel expects (`0x4245494400000000000000000100000`), comma-joined.
5. Writes the result to `/sys/module/udma/parameters/udma_tp_warmup_peer_eids`.
6. Optionally flips `udma_tp_cache_enable` and `udma_tp_warmup_enable` to 1.

If the cluster has only the local node, or UBSE has not yet pushed peer info, the script leaves the existing parameter unchanged and exits 0 with a log line.

## 2. Prerequisites

- UBSE daemon running and the local node has joined a cluster (verify: `ubsectl display cluster` succeeds and shows ≥ 2 nodes).
- `udma` kernel module loaded with the `codex/udma-tp-cache` patch applied (verify: `/sys/module/udma/parameters/udma_tp_warmup_peer_eids` exists).
- Run as root for the actual write (sysfs requires it). `UDMA_WARMUP_DRY_RUN=1` skips the root requirement.

## 3. Quick usage

```bash
# Plain run (must be root)
sudo /opt/udma/udma_warmup_peers.sh

# Dry-run, no privileges needed — useful for inspection
UDMA_WARMUP_DRY_RUN=1 UDMA_WARMUP_VERBOSE=1 ./udma_warmup_peers.sh

# Verbose, also flip cache + warmup enables (defaults already do this)
sudo UDMA_WARMUP_VERBOSE=1 ./udma_warmup_peers.sh
```

Sample successful output (verbose):

```
[udma_warmup_peers] local slot id = 1
[udma_warmup_peers] udma_tp_warmup_peer_eids = 0x42454944000000000000000002000000,0x42454944000000000000000003000000
[udma_warmup_peers] udma_tp_cache_enable = 1
[udma_warmup_peers] udma_tp_warmup_enable = 1
[udma_warmup_peers] set 2 peer EID(s)
```

## 4. Configuration knobs (env vars)

| Variable | Default | Purpose |
| --- | --- | --- |
| `UDMA_WARMUP_DRY_RUN` | `0` | If `1`, prints intended writes without touching sysfs (no root needed) |
| `UDMA_WARMUP_VERBOSE` | `0` | Chatty: log local slot, each parameter set |
| `UDMA_WARMUP_ENABLE_CACHE` | `1` | If `1`, also write `udma_tp_cache_enable=1` |
| `UDMA_WARMUP_ENABLE_WARMUP` | `1` | If `1`, also write `udma_tp_warmup_enable=1` |
| `UDMA_WARMUP_INCLUDE_LOCAL` | `0` | If `1`, do not exclude the local node (debug only — never set in production) |
| `UDMA_SYSFS_BASE` | `/sys/module/udma/parameters` | Override sysfs path (testing) |
| `UBSECTL` | `ubsectl` | Override ubsectl binary path |

## 5. Systemd integration

### 5.1 Oneshot at boot, ordered after UBSE

`/etc/systemd/system/udma-warmup-peers.service`:

```ini
[Unit]
Description=Push UBSE peer EIDs into UDMA TP-list warmup
Wants=ubse.service
After=ubse.service systemd-modules-load.service
ConditionPathExists=/sys/module/udma/parameters/udma_tp_warmup_peer_eids

[Service]
Type=oneshot
ExecStart=/opt/udma/udma_warmup_peers.sh
# Retry transient UBSE-not-ready failures
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=120
StartLimitBurst=10
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

Enable: `systemctl enable --now udma-warmup-peers.service`

`RemainAfterExit=true` so the unit shows as `active (exited)` after success, making it visible in `systemctl status`.

`ConditionPathExists` lets the unit silently skip on hosts without the codex patch. Without that condition, every boot logs an error.

### 5.2 Refresh on topology change

UBSE exposes `POST /topolink/change/` on `/var/run/ubse/ubse_ubm.socket` ([`docs/api/lcne_topo.md`](https://atomgit.com/ray-yang0218/ubs-engine/blob/master/docs/api/lcne_topo.md) in the ubs-engine repo). Two approaches:

**A. Periodic timer (simplest, lossy by polling interval).**

`/etc/systemd/system/udma-warmup-peers.timer`:

```ini
[Unit]
Description=Refresh UDMA peer EIDs from UBSE periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

Enable: `systemctl enable --now udma-warmup-peers.timer`. Pair it with the `.service` above (without changing `RemainAfterExit`). Gives at-most-5-minute drift after topology changes.

**B. Subscribe to `topolink/change/` (event-driven, lower latency).**

A small daemon listens on the LCNE socket, runs `udma_warmup_peers.sh` on each notification. Out of scope for this script; left as a follow-up if 5-minute polling is too coarse.

## 6. Verification

After a successful run, check the sysfs parameters:

```bash
for p in udma_tp_cache_enable udma_tp_warmup_enable udma_tp_warmup_peer_eids; do
    printf "%-28s = %s\n" "$p" "$(cat /sys/module/udma/parameters/$p)"
done
```

Then watch dmesg for the codex-added log lines:

```bash
sudo dmesg -wH | grep -E "tp warmup|tp cache"
# Expect:
#   tp warmup: keep disabled for production until tp_cfg_req.flag owner semantics are validated
#   tp warmup: owner 0 queued N work items   (only if a context is allocated/reset triggers)
```

The most informative surface is the new debugfs stats (codex commit `97bb32b4`):

```bash
# locate it
find /sys/kernel/debug -path '*tp_cache/stats' 2>/dev/null

# read counters
cat /sys/kernel/debug/.../tp_cache/stats
# Important fields:
#   warmup_queued_cnt       > 0  → script populated peer_eids and a warmup ran
#   warmup_started_cnt      > 0  → at least one work item began ctrlq fetch
#   warmup_success_cnt      > 0  → at least one warmup populated a cache entry
#   warmup_error_cnt        spike → ctrlq-side errors (peer unreachable, etc.)
#   ctrlq_fetch_cnt vs hit_cnt → cache hit rate; high hit_cnt = warmup paying off
```

To force a warmup pass without rebooting:
- Re-run the script (re-writes peer_eids; the next ucontext alloc on this host triggers context-warmup).
- Or trigger a ucontext alloc by running `urma_perftest --tp_reuse=0 -j 1 ...` once.

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `ubsectl not found in PATH` | UBSE not installed | install `ubs-engine` package |
| `udma_tp_warmup_peer_eids parameter not found` | codex patch not applied | rebuild kernel module from `codex/udma-tp-cache` branch |
| `must run as root` | invocation as non-root | `sudo` it, or use `UDMA_WARMUP_DRY_RUN=1` |
| `UBSE returned cluster error` | UBSE not running, or local node not joined | check `systemctl status ubse`, wait for cluster join |
| `no peer EIDs derived from cluster` | only local node visible to UBSE | not necessarily an error — single-node cluster has no peers; warmup will be a no-op |
| `set 0 peer EID(s)` *(see above)* | bonding-eid column is `-` for all peers | UBM hasn't reported topology to UBSE yet — wait or investigate UBM connectivity |
| `warmup_queued_cnt` stays 0 after script run | warmup didn't fire | warmup triggers are device probe (one-shot, missed) and ucontext alloc — open a ucontext (run perftest) to force it |
| `warmup_error_cnt` climbs | ctrlq round-trip is failing for these peers | check that peers are actually reachable on the UB fabric, not just in topology |

## 8. Limitations

- **CLI scrape is fragile.** If `ubsectl display cluster` output format changes between UBSE versions, the awk parser may break. The right long-term fix is a proper `libubse-client` API (`ubs_cluster_node_list`); see [`umdk_ubse_peer_eid_discovery.md`](umdk_ubse_peer_eid_discovery.md) §4 option C.
- **Misses device-probe warmup.** The script writes the parameter at user-space time, but the per-device warmup hook fires at module-init / aux-bus-bind, which is typically before UBSE has finished pushing topology. So device warmup runs with an empty peer list and queues nothing. Context warmup at the next ucontext alloc still benefits from the populated parameter.
- **Production gate.** Codex's patch logs `tp warmup: keep disabled for production until tp_cfg_req.flag owner semantics are validated` once per device. Until that is validated, treat warmup as bring-up-only. The cache itself (`udma_tp_cache_enable=1` without warmup) is independently safe.
- **5-minute polling drift.** Approach §5.2.A is at-most-5-minutes-stale on topology change. Move to event-driven (option B) if your workload cares about sub-minute drift.

## 9. Related

- Script source: [`scripts/udma_warmup_peers.sh`](scripts/udma_warmup_peers.sh)
- Cache + warmup design: [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md)
- Why we have to scrape: [`umdk_ubse_peer_eid_discovery.md`](umdk_ubse_peer_eid_discovery.md)
- User-space side of the cache contract: [`umdk_userspace_tp_cache_interface.md`](umdk_userspace_tp_cache_interface.md)
- Codex implementation: branch `codex/udma-tp-cache` in `ray-yang0218/kernel`, file `drivers/ub/urma/hw/udma/udma_tp_cache.c`
