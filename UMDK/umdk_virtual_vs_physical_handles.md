# URMA virtual-vs-physical handles: vtp/tp and vjetty/pjetty

_Last updated: 2026-05-12._

Two pairs of URMA objects follow the same `v_*` / `p_*[]` naming pattern but live at different layers and solve different problems. This doc disambiguates them.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — primer for EID, jetty, TP, transport modes
- [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) — TP creation, modify, destroy
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) — first-RPC cost analysis

Source citations:
- Kernel UB core: `/Volumes/KernelDev/kernel/include/ub/urma/ubcore_types.h`
- URMA bonding library: `~/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/`

---

## 1. TL;DR

| Pair | Layer | Virtual side | Physical side |
| ---- | ----- | ------------ | ------------- |
| `vtp` / `tp` | kernel ubcore | one logical pair-connection (4-tuple keyed) | one wire-level transport |
| `vjetty` / `pjetty` | userspace bondp library | one bonded jetty handle | per-NIC backing jettys |

Both hide aggregation/multiplexing behind a stable virtual handle. The structural rhyme is intentional: `vtp:tp ≈ vjetty:pjetty`. They are otherwise unrelated — vtp/tp is *kernel* abstraction over transports (and live migration); vjetty/pjetty is *userspace* abstraction over bonded NICs.

---

## 2. vtp vs tp (kernel ubcore)

### 2.1 `tp` — the wire

`struct ubcore_tp` at `ubcore_types.h:957`. A single transport-layer connection between two nodes:

- TPN, peer TPN (driver-assigned)
- PSNs (tx_psn, rx_psn), MTU
- UDP src port range for multipath
- State machine: `RESET → RTR → RTS → SUSPENDED → ERR` (`enum ubcore_tp_state` at line 855)
- Retry config (retry_num, retry_factor, ack_timeout)
- Optional pointer to a `ubcore_tpg` (TP group) for RC mode

A TP is the actual wire-level pipe. For **RC mode** TPs are grouped into a TPG (`struct ubcore_tpg` at `ubcore_types.h:1026`), up to `UBCORE_MAX_TP_CNT_IN_GRP = 32` TPs per group. For **UM mode** the wire is a `utp` (unreliable transport); for **clan domain** it's a `ctp`. All three (`tp`, `utp`, `ctp`) are sibling "physical" transports.

### 2.2 `vtp` — the named pair-connection

`struct ubcore_vtp` at `ubcore_types.h:1175`. A virtual/logical transport keyed by the 4-tuple `(local_eid, local_jetty, peer_eid, peer_jetty)`:

```c
struct ubcore_vtp_cfg {
    union ubcore_eid local_eid;
    uint32_t local_jetty;
    union ubcore_eid peer_eid;
    uint32_t peer_jetty;
    /* ... */
    union {
        struct ubcore_tpg *tpg;
        struct ubcore_tp  *tp;
        struct ubcore_utp *utp;
        struct ubcore_ctp *ctp;
    };  /* ubcore_types.h:1167-1172 */
};
```

The vtp points at *one of* `{tp, tpg, utp, ctp}` via the trailing union. The mode is recorded in `cfg.trans_mode`.

This is the point: the **vtp is the stable user-facing handle**; the underlying transport object can be created, modified, or swapped (live migration, bonding, recovery) without the consumer knowing.

### 2.3 `vtpn` — the handle

`struct ubcore_vtpn` at `ubcore_types.h:1112`. The driver-assigned integer handle for a vtp. The same struct also caches the 4-tuple (`local_eid`, `peer_eid`, `local_jetty`, `peer_jetty`) for two hash-table lookup paths:

- `hnode` keyed by `eid + jetty` — used when a consumer creates/looks-up by 4-tuple
- `vtpn_hnode` keyed by vtpn — used when the driver references an existing vtp by id

`vtpn` carries the `state_lock` and `ubcore_vtp_state` (`RESET / READY / WAIT_DESTROY`) that gate concurrent operations. The `vtpn_wait_list` / `disconnect_list` linkages are how ubcore parks vtpns waiting for an asynchronous setup or teardown to complete.

### 2.4 Why two structs (`vtpn` and `vtp`)

- `vtpn` is the **handle / state-bearing** record. Allocated by the driver via the `alloc_vtpn` op (`ubcore_types.h:2949`). One per consumer-visible connection.
- `vtp` is the **created transport binding** record. Allocated by `create_vtp` (`ubcore_types.h:2965`). It carries `vtp_cfg` (which includes the union picking `tp`/`tpg`/`utp`/`ctp`) plus role (`initiator / target / duplex`) and live-migration scaffolding (`vice_tpg_info`).

Lifecycle order: `alloc_vtpn` → `create_vtp` → connection ready → `destroy_vtp` → `free_vtpn`. `modify_vtp` (`ubcore_types.h:3144`) swaps the underlying transport pointer in `vtp_attr.tp` — that's how live migration rewires a live vtp to a different tpg/tp without recreating the consumer-visible handle.

### 2.5 One-line summary

**tp = the wire. vtp = the named pair-connection that owns a wire (or a tpg, or a utp, etc.).**

---

## 3. vjetty vs pjetty (userspace bondp library)

These do **not** exist in the kernel. They are concepts inside the URMA **bonding library** at `~/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/bond/`. They surface in code as `v_jetty` / `p_jetty[]` (and the parallel `v_jfs`/`p_jfs`, `v_jfr`/`p_jfr`, `v_dev`/`p_devs`).

### 3.1 `vjetty` — the bonded handle

The single virtual jetty handle returned to the URMA user when they create a jetty on a *bonded* device. Exactly one per logical jetty. Field `v_jetty` of `urma_jetty_t` type, member of `bondp_comp` (`bondp_types.h:209`):

```c
typedef struct bondp_comp {
    union {
        void *base;
        urma_jfs_t   v_jfs;
        urma_jfr_t   v_jfr;
        urma_jetty_t v_jetty;
    };
    union {
        void *members[URMA_UBAGG_DEV_MAX_NUM];
        urma_jfs_t   *p_jfs[URMA_UBAGG_DEV_MAX_NUM];
        urma_jfr_t   *p_jfr[URMA_UBAGG_DEV_MAX_NUM];
        urma_jetty_t *p_jetty[URMA_UBAGG_DEV_MAX_NUM];
    };
    int dev_num;
    /* ... */
    bondp_comp_type_t comp_type;  /* JFS / JFR / JETTY */
};
```

The tagged-union design is the bondp library's polymorphic component pattern — one `bondp_comp` instance can wrap a jetty, a jfs, or a jfr, with `comp_type` selecting which interpretation is live. Extra memory cost is acknowledged in the header (`bondp_types.h:206-208`).

### 3.2 `pjetty` — the per-NIC backings

The array of underlying physical jettys, one slot per slave/aggregated device, up to `URMA_UBAGG_DEV_MAX_NUM`. When the user creates a vjetty over a bonded device the bondp library transparently creates a pjetty on each member NIC and routes work over them.

Tracking fields colocated in `bondp_comp`:
- `dev_num` — total devices to traverse
- `enabled_indices[]` / `enabled_count` — which slots are populated
- `active_indices[]` / `active_count` — which are currently up
- `valid[URMA_UBAGG_DEV_MAX_NUM]` — per-device validity bit
- `pjettys_error_done[URMA_UBAGG_DEV_MAX_NUM]` — per-pjetty suspend/flush state (`PJETTY_SUSPEND_DONE`, `PJETTY_FLUSH_ERROR_DONE` from `bondp_types.h:201-204`)

### 3.3 The pjetty→vjetty mapping table

`bondp_context_t` (`bondp_types.h:142`) maintains `p_vjetty_id_table` — a hash from `pjetty.jetty_id.id` to `vjetty.jetty_id.id`:

```c
/* Record the mapping from the locally created jetty's pjetty.jetty_id.id to the vjetty.jetty_id.id, */
/* used to restore the local_id in CR. */
bondp_hash_table_t p_vjetty_id_table;
```

Purpose: incoming completion records (CRs) identify the local jetty by its *physical* id (because that's what the wire actually saw), but the consumer above only knows about the *virtual* id it created. The mapping table lets the library rewrite `local_id` in each CR back to the vjetty id before handing the CR upward. Same idea applies to fallback / switchback netlink ctrl messages (`bondp_netlink.c:72`, `bondp_health_check.c:900-904`).

### 3.4 Health-check / failover semantics

Health-check logic operates on **pjettys** (the per-NIC backings), but identity is preserved at the **vjetty** level. Concretely (from `bondp_health_check.c:793-884`):

1. Detect pjetty failure on slot `local_idx`.
2. `bondp_delete_primary_pjetty(local_idx)` — tear down the broken pjetty.
3. `bondp_create_primary_pjetty(local_idx)` on a healthy slave.
4. Refresh `p_vjetty_id_table` mapping (delete stale entry, add new entry).
5. Vjetty id is unchanged — consumer never sees the failover.

### 3.5 One-line summary

**vjetty = the bonded handle the app sees. pjetty = the per-NIC backing handles the bonding layer manages.**

---

## 4. Why the v/p pattern recurs

Both pairs solve the same kind of problem: one consumer-visible identity needs to remain stable while the underlying resource may be (a) plural, (b) replaceable, or (c) both.

| | vtp/tp | vjetty/pjetty |
| - | ------ | ------------- |
| Layer | kernel ubcore | userspace bondp |
| Plural backing? | yes — TPG holds up to 32 TPs per RC connection | yes — up to `URMA_UBAGG_DEV_MAX_NUM` pjettys per vjetty |
| Replaceable backing? | yes — `modify_vtp` swaps transport pointer (live migration) | yes — health-check tears down and recreates pjetty on failover |
| Stable identity to consumer | vtpn (and 4-tuple) | vjetty.jetty_id |
| State / lock lives on | vtpn (`state_lock`, `ubcore_vtp_state`) | bondp_comp (per-pjetty `valid[]`, `pjettys_error_done[]`) |

The two layers compose: a single vtp lives entirely inside the kernel — bonding does not split a vtp across NICs. Instead, a bonded application sees one vjetty above; below the userspace boundary the bondp library opens a separate URMA context per pjetty, and each pjetty independently creates its own vtps in its NIC's kernel ubcore instance. Bondp then fans CRs back upward and rewrites the local_id field via `p_vjetty_id_table`.

---

## 5. Quick reference — where to look

| Concept | Definition | Key ops |
| ------- | ---------- | ------- |
| `struct ubcore_tp` | `ubcore_types.h:957` | `create_tp` :2878, `modify_tp` :2888, `destroy_tp` :2908 |
| `struct ubcore_tpg` | `ubcore_types.h:1026` | (managed via TP ops; see `create_multi_tp` :2920) |
| `struct ubcore_vtp` | `ubcore_types.h:1175` | `create_vtp` :2965, `modify_vtp` :3144, `destroy_vtp` :2973 |
| `struct ubcore_vtpn` | `ubcore_types.h:1112` | `alloc_vtpn` :2949, `free_vtpn` :2956 |
| `enum ubcore_tp_state` | `ubcore_types.h:855` | RESET / RTR / RTS / SUSPENDED / ERR |
| `enum ubcore_vtp_state` | `ubcore_types.h:1097` | RESET / READY / WAIT_DESTROY |
| `bondp_comp` (vjetty + pjetty[]) | `bondp/bondp_types.h:209` | construction in `bondp_api.c:1044-1215` |
| `bondp_context_t.p_vjetty_id_table` | `bondp/bondp_types.h:155` | populated/refreshed in `bondp_health_check.c` |
| pjetty failover | `bondp/bondp_health_check.c:793-884` | delete → recreate → refresh mapping |
