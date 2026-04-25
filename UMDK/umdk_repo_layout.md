# UMDK / URMA / UDMA — repo layout and architecture (survey)

_Last updated: 2026-04-25._

Survey of where UnifiedBus software lives on local clones, the kernel↔userspace boundary, and the URMA provider model. Citations point to specific file:line locations in the clones listed in the [README](README.md).

## 1. Big picture

- **URMA** ("Unified Remote Memory Access") is the UnifiedBus analogue of InfiniBand verbs. The API is a near-direct rebrand of IB verbs; semantics map cleanly. See §4 for the terminology table.
- **UDMA** is a **hardware provider under URMA**, not a parallel stack. Confirmed by `drivers/ub/urma/hw/udma/` binding as a `ubcore` provider and by `Documentation/ub/urma/udma/udma.rst:24-29`: UDMA "integrates with the UnifiedBus protocol by implementing the URMA programming API".
- **UMDK** is the userspace multi-device kit — `liburma`, hardware providers, tools, plus a growing set of sibling libraries (`urpc`, `usock`, `ulock`, `cam`) that ride on top of URMA.
- **UBASE** is an auxiliary-bus framework used by HW providers to register themselves with `ubcore`. Still to be surveyed.
- **ipourma** is a ULP (IP-over-URMA) that consumes jetties as transport; discovered via generic netlink, no driver registration.

## 2. Kernel side — `drivers/ub/urma/` on OLK-6.6

Full tree on `~/Documents/Repo/kernel/` (branch `OLK-6.6`):

```
drivers/ub/urma/
├── ubcore/         # core framework (device mgmt, jetty/JFS/JFR/JFC, segment, EID)
├── uburma/         # char device /dev/ub_uburma* + ioctl bridge to userspace
├── ubagg/          # aggregator role (stub in OLK-5.10, expanded here)
├── ulp/ipourma/    # IP-over-URMA upper-layer protocol (uses jetties as transport)
└── hw/udma/        # HiSilicon UDMA hardware provider (copyright 2025)
```

Public headers:

```
include/ub/urma/         ubcore_api.h, ubcore_types.h, ubcore_opcode.h, ubcore_uapi.h
include/uapi/ub/urma/udma/udma_abi.h      # UDMA userspace ABI (jetty types, doorbell)
Documentation/ub/urma/udma/udma.rst       # UDMA role description
```

### 2.1 Provider registration

- Entry: `ubcore_register_device()` at `drivers/ub/urma/ubcore/ubcore_device.c:1223`.
- Ops table: `struct ubcore_ops` at `include/ub/urma/ubcore_types.h:2101` (~20 function pointers: `query_device_attr`, `query_device_status`, `config_device`, `add_ueid`, `delete_ueid`, `query_res`, `query_stats`, and ~13 more covering device lifecycle and config).
- Pattern mirrors `drivers/infiniband/core/`'s `ib_register_device()` + `ib_device_ops` — a `ubcore` provider is effectively an `ib_device` rebadged.

### 2.2 Userspace channel (uAPI)

- Character device: `/dev/ub_uburma*` (per-device node).
- ioctl magic and command: `drivers/ub/urma/uburma/uburma_cmd.h:34-36`

  ```c
  #define UBURMA_CMD_MAGIC 'U'
  #define UBURMA_CMD _IOWR(UBURMA_CMD_MAGIC, 1, struct uburma_cmd_hdr)
  ```
- Command enum: `uburma_cmd.h:38-100` (~100 commands: CREATE_CTX, ALLOC_TOKEN_ID, REGISTER_SEG, CREATE_JFS/JFR/JFC/JETTY, IMPORT_JETTY, BIND_JETTY, GET_EID_LIST, etc.).
- Control plane (topology / management) uses generic netlink (`ubcore_genl`); not on the data path.

### 2.3 Kconfig

- `UB_URMA` (tristate, default `m`) at `drivers/ub/Kconfig:26-33` — core URMA framework.
- `UB_UDMA` (tristate, default `n`) at `drivers/ub/urma/hw/udma/Kconfig` — HiSilicon UDMA HW driver, depends on `UB_UBASE && UB_URMA && UB_UMMU_CORE`. Registers via the UBASE auxiliary-bus framework.

### 2.4 OLK-5.10 (historical)

`~/Documents/Repo/ub-stack/kernel-ub/` branch `OLK-5.10` has an older subset:

```
drivers/ub/
├── Kconfig
├── urma/{ubcore,uburma}     # same roles, ~2 years older
└── hw/hns3/                 # earlier HiSilicon provider (hns3_udma_*), 44 files
```

No `hw/udma/`, no `ulp/ipourma/`, no `ubagg/` beyond stubs. Last touched May 2023; use as historical reference only.

Also on 5.10: `drivers/roh/` + `drivers/net/ethernet/hisilicon/hns3/hns3_roh.{c,h}` — the ROH (RDMA over HSlink?) predecessor/sibling driver.

## 3. Userspace — `umdk/src/` (github.com/openeuler-mirror/umdk)

Restructured some time between Nov 2024 and early 2026; old top-level (`common/`, `hw/`, `include/`, `lib/`, `tools/`, `transport_service/`) is gone. Current layout:

```
src/
├── urma/                                 # original URMA stack
│   ├── lib/{urma,uvs}                    # liburma core + UVS (verbs service, replaces old TPSA)
│   ├── hw/udma/                          # userspace UDMA provider (20 udma_u_*.c files)
│   ├── common/                           # shared utilities
│   ├── tools/{urma_admin,urma_perftest,urma_ping}
│   └── examples/
├── urpc/                                 # RPC framework on UB (includes umq = userspace msg queue)
├── usock/ums/                            # UB message socket layer
├── ulock/dlock/                          # distributed lock library
└── cam/                                  # collective comm/math ops (Ascend kernels + pybind)
```

### 3.1 Userspace UDMA provider (new finding)

`src/urma/hw/udma/udma_u_*.{c,h}` — roughly 20 files. The `_u_` infix denotes userspace. Files mirror kernel structure one-to-one:

| Userspace | Kernel counterpart |
|---|---|
| `udma_u_main.c` | `hw/udma/udma_main.c` |
| `udma_u_jetty.{c,h}` | `hw/udma/udma_jetty.c` |
| `udma_u_jfs.{c,h}` / `udma_u_jfr.c` / `udma_u_jfc.{c,h}` | work-queue / recv-queue / CQ handlers |
| `udma_u_segment.{c,h}` | memory segment (MR) |
| `udma_u_ctl.c` | control channel |
| `udma_u_db.h` | doorbell layout |
| `udma_u_abi.h` | userspace copy of the kernel ABI header |

Talks to the kernel through `/dev/ub_uburma*` ioctls using the commands enumerated in `uburma_cmd.h:38-100`.

### 3.2 liburma command channel

- Issuer: `src/urma/lib/urma/core/urma_cmd.c` (equivalent of the old `lib/urma/core/urma_cmd.c` in the pre-restructure layout).
- Issues `ioctl(cfg->dev_fd, URMA_CMD, &hdr)` with `uburma_cmd_hdr`. One ioctl entrypoint; sub-command discriminated inside the header.

### 3.3 Version tags worth knowing

From `git tag` in `umdk/`:

- `URMA_24.12.0_LTS` — the current LTS of URMA userspace.
- `UB_20240523_miss`, `UB_20231117_alpha` — earlier UB drops; useful archaeological anchors.

Latest commit (as of this writing): 2026-04-24 — the repo is very actively maintained.

## 4. URMA ↔ IB verbs terminology map

| URMA | IB verbs | Notes |
|---|---|---|
| `urma_context_t` / `ubcore_device` | `ibv_context` / `ib_device` | Device handle |
| `urma_jetty_t` | `ibv_qp` (RC) | Bidirectional endpoint |
| `urma_jfs_t` / `urma_jfr_t` | send-QP / SRQ | Send / receive queues |
| `urma_jfc_t` | `ibv_cq` | Completion queue |
| `urma_target_seg_t` | `ibv_mr` | Memory region |
| `urma_token_id_t` | `rkey` | Remote key — allocable independently, which enables **rotating token revocation** (per UB Base Spec §11.4.4) |
| `urma_jetty_grp_t` | _(new)_ | Multipath / LAG group — no direct IB analogue |
| `urma_write / read / send / recv` | corresponding RDMA verbs | Core ops |
| `EID` | `GID` | Endpoint identifier |

## 5. Building blocks still to survey

- `src/urpc/` — RPC framework and `umq` (userspace message queue) — framework, protocol, core, tools. Expect gRPC-style APIs atop UB transport.
- `src/usock/ums/` — message socket, with `kmod/` suggesting a kernel companion module.
- `src/ulock/dlock/` — distributed locking. Probably built on top of URMA atomics.
- `src/cam/` — Collective Algorithm/Math — has `comm_operator/ascend_kernels/` and a `pybind/` binding. Likely the public part of CANN's collective ops exposed on UB.
- UBASE framework — how HW providers hang off the kernel auxiliary-bus.
- `uvs_admin` / `urma_admin` — control-plane tools.

## 6. Open questions / gotchas

- **UVS vs old TPSA daemon.** The pre-restructure `transport_service/daemon/tpsa_*` files were deleted; `src/urma/lib/uvs/` is the suspected replacement. Verify whether UVS is a daemon or a library, and whether it still terminates kernel genl control plane the way TPSA did.
- **Kernel/userspace version skew.** UDMA kernel code is dated 2025; userspace UDMA exists in the current umdk master. But the last stable umdk tag is `URMA_24.12.0_LTS` (Dec 2024) — UDMA userspace is probably post-LTS. Confirm before pairing a kernel + userspace build.
- **No third-party providers in tree.** Everything is Huawei/HiSilicon-authored. Mellanox/ConnectX-style providers are not present.
- **Shallow clones lie.** The first local umdk clone was depth=1 — `git log` showed one commit from Nov 2024, making the repo look stale. Always `git rev-parse --is-shallow-repository` before judging activity.

## 7. Handy commands

```sh
# Keep umdk current
( cd ~/Documents/Repo/ub-stack/umdk && git pull --ff-only )

# Find URMA commands used by a tool
grep -rn 'UBURMA_CMD_' ~/Documents/Repo/ub-stack/umdk/src/urma/

# Grep kernel ops-table for a function slot
grep -n 'query_device_attr\|add_ueid' ~/Documents/Repo/kernel/include/ub/urma/ubcore_types.h
```
