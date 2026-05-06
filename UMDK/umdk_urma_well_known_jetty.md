# Public-known / well-known jetty in URMA

_Last updated: 2026-05-06._

URMA reserves a range of jetty IDs that any two nodes can use **without exchanging IDs first**. The codebase calls this concept both "public_jetty" and "well_known_jetty" — same thing, two names. This is what lets IPoURMA, bondp, and the cluster control plane bootstrap connections to peers they've never spoken to.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer on jetty / EID
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — link setup; explains the chicken-and-egg this fixes

---

## 1. What it is

Normal URMA jettys are identified by `(eid, uasid, id)` where `id` is **driver-allocated** at create time. For peer-to-peer connect, both sides must know each other's full triple — meaning there's a chicken-and-egg problem at bootstrap: how do you exchange jetty IDs if you don't already have a side-channel?

A **well-known jetty** (== "public-known jetty") is one created with a **caller-specified jetty ID in a reserved range** that's known across the cluster ahead of time. Both sides compute the peer's jetty ID purely from public information (peer EID, an EID index, etc.) plus the well-known base — no handshake needed.

The two names in source:
- **`public_jetty`** — UDMA HW provider naming (`udma_dev->caps.public_jetty`)
- **`well_known_jetty`** — UDMA cmd struct + ubase comm_dev capability fields

`ubase_comm_dev.h:114`:
```c
struct ubase_comm_dev_cap {
    ...
    u32 public_jetty_cnt;     /* public jetty count */
    ...
};
```

`udma_cmd.h:199-200`:
```c
uint16_t well_known_jetty_start;
uint16_t well_known_jetty_num;
```

Same structural concept; just different naming traditions across layers.

## 2. Why it exists

Without a well-known jetty range, every URMA bootstrap requires:
1. Some non-URMA channel (TCP, shared file, KV store, …) to exchange `(eid, uasid, id)` triples.
2. Plus `urma_get_tp_list` to set up the TP.
3. Plus `urma_import_jetty_ex` etc. to wire up the local target_jetty.

Step 1 is the awkward one — applications that *are* the network stack (IPoURMA), or that need to talk to *every* node in the cluster (ubmgr health probes), can't depend on a higher-level transport for bootstrap. Well-known jettys make step 1 unnecessary.

This is the same pattern as:
- **IB well-known QPNs**: QP0 for SMP (Subnet Management Packets), QP1 for GMP/general management. Anyone connecting to an IB node can target QP1 without exchanging QP numbers.
- **TCP/UDP well-known ports**: 0–1023 reserved. Clients know where servers listen without asking — port 80 for HTTP, 22 for SSH, etc.

## 3. Implementation

```
HW reports its capability:           ubase_comm_dev.public_jetty_cnt = N
                                     cmd->well_known_jetty_start = base
                                     cmd->well_known_jetty_num = count
                                       │
                                       ▼
UDMA caches:                         udma_dev->caps.public_jetty = {
                                         .start_idx = base,
                                         .max_cnt = count,
                                     }
                                       │
                                       ▼
User app creates jetty with cfg_id:  if cfg_id ∈ [start_idx, start_idx + max_cnt - 1]
                                         driver accepts user-specified ID
                                     else
                                         driver allocates from normal pool
```

`udma_main.c:561-562` (driver wires HW cap into device caps):
```c
udma_dev->caps.public_jetty.start_idx = cmd->well_known_jetty_start;
udma_dev->caps.public_jetty.max_cnt   = cmd->well_known_jetty_num;
```

`udma_main.c:172` (capability exposed to userspace):
```c
attr->reserved_jetty_id_max = udma_dev->caps.public_jetty.max_cnt - 1;
```

`udma_jetty.c:298+` (validation at create time, function `udma_verify_jetty_type_urma_normal`):
```c
if (!(CFGID_CHECK(cfg_id, udma_dev->caps.public_jetty) ||
      CFGID_CHECK(cfg_id, udma_dev->caps.hdc_jetty) ||
      CFGID_CHECK(cfg_id, udma_dev->caps.jetty))) {
    dev_err(...,"user id %u error...");
    return -EINVAL;
}
```

User code that wants a well-known jetty just sets `cfg.id` in the reserved range; the driver routes the allocation to the public-jetty pool instead of the dynamic pool.

## 4. Real consumers

### IPoURMA — the textbook case

`kernel/drivers/ub/urma/ulp/ipourma/ipourma_types.h:55`:
```c
IPOURMA_WELL_KNOWN_JETTY_ID = 32,
```

On startup, IPoURMA creates jettys at IDs `IPOURMA_WELL_KNOWN_JETTY_ID + eid_idx` for each local EID (`ipourma_res.c`). When sending IP traffic, IPoURMA derives the peer's jetty ID *without asking*:

`ipourma_ub.c`:
```c
u32 jetty_id = eid_index + IPOURMA_WELL_KNOWN_JETTY_ID;
```

Receiving side reverses the mapping:
```c
u32 eid_index = jetty_id - IPOURMA_WELL_KNOWN_JETTY_ID;
```

**Net effect: any pair of IPoURMA-enabled nodes can talk without a discovery handshake.** They just compute each other's jetty IDs from a public formula.

### bondp library

`umdk/src/urma/lib/urma/bond/bondp_types.h:35`:
```c
#define BONDP_MAX_WELL_KNOWN_JETTY_ID  (1024)
```

Bonding library reserves IDs up to 1024 for its management/control jettys. `bondp_api.c:1141` validates user-specified IDs against this ceiling:
```c
jetty_id > 0 && jetty_id < BONDP_MAX_WELL_KNOWN_JETTY_ID
```

### ubmgr / cluster control plane

ubmgr ping, topology probes, health checks — same pattern. Cluster-wide protocols where every node needs to know where to send without a per-pair handshake all live in the well-known range.

## 5. Constraint: page size

`udma_jetty.c:316, 341`:
```c
if ((CFGID_CHECK(cfg_id, udma_dev->caps.public_jetty) || ...) &&
    well_known_jetty_pgsz_check && PAGE_SIZE != UDMA_HW_PAGE_SIZE) {
    dev_err(...,
        "Does not support specifying Jetty ID on non-4KB page systems.\n");
    return -EINVAL;
}
```

Well-known jetty IDs are only allowed on **4KB-page systems** by default. The HW maps these jettys at fixed offsets that depend on page size, so 16K- or 64K-page kernels (common on ARM64) can't use them without disabling the check.

Module param to override (`udma_jetty.c:1864-1865`):
```c
module_param(well_known_jetty_pgsz_check, bool, 0444);
```

To use well-known jettys on a 64K-page ARM64 kernel:
```bash
modprobe udma well_known_jetty_pgsz_check=0
# or persistently
echo "options udma well_known_jetty_pgsz_check=0" \
    > /etc/modprobe.d/udma.conf
```

Ramifications: the HW page mappings may not behave correctly with a non-4KB host page size — it's an "off the warranty" path. Test thoroughly; consider sticking with normal (driver-allocated) jetty IDs on 64K-page systems for production.

## 6. Comparison with normal jetty

| | Normal jetty | Public / well-known jetty |
| --- | --- | --- |
| ID allocation | Driver-assigned at create time | Caller-specified, in reserved range |
| ID range | `[caps.jetty.start_idx, ...]` | `[caps.public_jetty.start_idx, ...]` |
| Discovery | Both sides need out-of-band ID exchange | Either side can compute the other's ID |
| Use case | Per-connection RPC, dynamic peers | Network-stack lower layers, cluster-wide control plane |
| Page-size constraint | none | 4KB only (by default) |
| ID conflict risk | none (driver picks unused IDs) | yes — two apps must agree on convention |
| IB analog | dynamic QPNs | QP0/QP1 well-known QPNs |
| TCP analog | ephemeral ports | well-known ports (0-1023) |

## 7. Practical guidance

- **If you're building a network-stack lower layer** (IP, RDMA-over-X transport) → use well-known jetty IDs. This is what they're for.
- **If you're building cluster-wide management/probe protocols** → use well-known jetty IDs.
- **If you're building per-connection RPC** → use normal driver-allocated IDs and exchange them via your bootstrap channel (UMQ, URPC's connect handshake, TCP, etc.).
- **If you're on a 64K-page kernel** and need well-known IDs: set `well_known_jetty_pgsz_check=0` at modprobe and validate end-to-end before relying on it in production.
- **Don't pick an arbitrary "well-known" ID** that conflicts with established conventions: IPoURMA owns 32+, bondp owns 0–1023. Check IPoURMA / bondp / ubmgr conventions before claiming an ID range for a new protocol.

## 8. References

- `kernel/include/ub/ubase/ubase_comm_dev.h:114` — `public_jetty_cnt` capability struct field.
- `kernel/drivers/ub/urma/hw/udma/udma_cmd.h:199-200` — `well_known_jetty_start`, `well_known_jetty_num` HW cmd fields.
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:172` — `reserved_jetty_id_max` exposed to userspace.
- `kernel/drivers/ub/urma/hw/udma/udma_main.c:543, 561-562` — driver wires HW cap into `caps.public_jetty`.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:298+` — `udma_verify_jetty_type_urma_normal`, `udma_verify_jetty_type_urma_ex`.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:316, 341` — page-size constraint enforcement.
- `kernel/drivers/ub/urma/hw/udma/udma_jetty.c:1864-1865` — `well_known_jetty_pgsz_check` module param.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_types.h:55` — `IPOURMA_WELL_KNOWN_JETTY_ID = 32`.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c` — IPoURMA's compute-don't-exchange jetty ID derivation.
- `kernel/drivers/ub/urma/ulp/ipourma/ipourma_res.c` — IPoURMA's well-known-ID jetty creation.
- `umdk/src/urma/lib/urma/bond/bondp_types.h:35` — `BONDP_MAX_WELL_KNOWN_JETTY_ID = 1024`.
- `umdk/src/urma/lib/urma/bond/bondp_api.c:1141, 1197` — bondp's well-known range validation.
