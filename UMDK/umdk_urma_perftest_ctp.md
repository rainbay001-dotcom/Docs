# urma_perftest with CTP — flag, constraints, invocations

_Last updated: 2026-05-20._

How to run `urma_perftest` against a CTP (Connectionless Transport Pair) backend instead of the default RTP, what the `--ctp` flag actually flips in the code, and which constraints will reject the run.

Companions:
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) §"TP variants: RTP / CTP / UTP" — what CTP is and how it differs from RTP/UTP at the object level.
- [`umdk_urma_tp_memory_cost.md`](umdk_urma_tp_memory_cost.md) — why CTP wins on HW SRAM at N-peer scale.
- [`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md) — the 7-stage send_lat program; this doc patches the flags column for CTP.

Source citations (all paths absolute):
- `/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_parameters.{c,h}`
- `/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/perftest_resources.c`

---

## 1. The flag

`--ctp` (no_argument, default off). Defined at `perftest_parameters.c:566`, parsed at `860-861` → sets `cfg->use_ctp = true`. Help text at `170`.

There is no `--rtp` opposite; RTP is the default when `--ctp` is absent.

---

## 2. Minimal invocations

### Single-path bonding device (most common smoke test)

```bash
# Server
urma_perftest send_lat --ctp -d bonding_dev_0 --single_path -n 1000 -s 64

# Client
urma_perftest send_lat --ctp -d bonding_dev_0 --single_path -n 1000 -s 64 -S <server_ip>
```

### Multipath bonding device (`--single_path` off)

```bash
# --ctp is REQUIRED here, see §3
urma_perftest send_lat --ctp -d bonding_dev_0 -n 1000 -s 64
urma_perftest send_lat --ctp -d bonding_dev_0 -n 1000 -s 64 -S <server_ip>
```

Server and client MUST mirror `--ctp`: it flows into the remote-import path (`perftest_resources.c:1382 / 1521 / 1603` set `rjfr.tp_type = URMA_CTP` / `rjetty.tp_type = URMA_CTP`), so a CTP client trying to import an RTP-published jetty fails the type check.

---

## 3. Constraints that will reject the run

| Source | Constraint | Severity |
|---|---|---|
| `perftest_parameters.c:1034-1042, 1055` | On a `bonding_dev*`, `--single_path` off REQUIRES `--ctp`. Without it: `Invalid config: --single_path: false requires --ctp: true.` | Fatal |
| `perftest_parameters.c:1389-1392` | `api_type == SEND && use_ctp && size > 4096`: `Invalid size: %u with ctp for send opcode, max size: 4096.` (`PERFTEST_CTP_MAX_SEND_SIZE`) | Fatal (`exit(1)`) |
| `perftest_parameters.c:1399-1403` | `api_type == SEND && use_ctp && order > 12`: `Invalid order: %u with for send opcode, max order: 12.` (`PERFTEST_CTP_MAX_ORDER`) | Fatal (`exit(1)`) |
| `perftest_resources.c:206-208` | `-p N` is set but `dev_attr.dev_cap.priority_info[N].tp_type` is not CTP: `You should set the priority of type CTP` → `goto uninit` | Fatal |
| `perftest_resources.c:1068-1069` | Device backend is uboe: `ctp is not supported by uboe!` | Fatal |
| `perftest_parameters.c:1380-1382` | `trans_mode == URMA_TM_UM && use_ctp`: `UM transport mode is not recommended for ctp.` | Warning only |

For RTP comparison: `PERFTEST_RTP_MAX_SEND_SIZE` / `PERFTEST_RTP_MAX_ORDER` are larger (defined alongside at `perftest_parameters.c:31-35`).

---

## 4. Priority handling — the easy-to-miss gotcha

CTP and RTP live in **different priority slots** of `ctx->dev_attr.dev_cap.priority_info[]`. The init path in `perftest_resources.c:188-216`:

- If `-p` is **omitted** (`cfg->priority == PERFTEST_INVALID_PRIORITY`):
  - Sets `tp_type.bs.ctp = 1`, scans `priority_info[]` via `get_jetty_priority_by_tp_type`, picks the matching slot, and stderrs:  
    `Warning: ctp should set priority to <X>.`
  - Then continues with that auto-selected priority.

- If `-p N` is **set**:
  - Checks `priority_info[N].tp_type.value` matches the CTP encoding. Mismatch ⇒ `You should set the priority of type CTP` and abort.

**Recommended pattern**: first run without `-p` to read the auto-selected value off stderr, then re-run with `-p X` explicit for reproducibility.

---

## 5. What `--ctp` flips in the kernel-facing config

| File:line | Effect |
|---|---|
| `perftest_parameters.c:861` | `cfg->use_ctp = true` |
| `perftest_resources.c:190-192, 204-205` | `tp_type.bs.ctp = 1` on the URMA tp_type union used for priority lookup |
| `perftest_resources.c:1039-1040` | `tp_cfg.flag.bs.ctp = 1` on the TP cfg passed into create-TP path (only in `tp_aware` branch) |
| `perftest_resources.c:1136` | `tp_aware` create-TP path is **skipped** when ctp is set (`!cfg->tp_aware || cfg->trans_mode == URMA_TM_UM || cfg->use_ctp`) — CTP routes through its own resource path |
| `perftest_resources.c:1382, 1521, 1603` | Remote imports: `rjfr.tp_type = URMA_CTP` / `rjetty.tp_type = URMA_CTP` |
| `perftest_resources.c:1430, 1583` | Branch on `trans_mode == URMA_TM_UM \|\| use_ctp` selects the no-tp-cache import path |

Kernel-side, `URMA_CTP` corresponds to `UBCORE_CTP` in `enum ubcore_tp_type` at `kernel/include/ub/urma/ubcore_types.h:1495`. The cache-key canonicalization (`udma_tp_cache.c:733`) coerces `trans_mode = URMA_TM_RM` whenever `flag.bs.ctp = 1`, which is why CTP runs are always RM regardless of the configured `--trans_mode`.

---

## 6. Suggested first sweep on the NPU fleet

Two free hosts as of 2026-05-18 sweep: `.212` (8 free chips, load 20) and `.218` (6 free chips, load 66 — busier).

```bash
# baseline: RTP send_lat for comparison
urma_perftest send_lat -d bonding_dev_0 --single_path -n 1000 -s 64
urma_perftest send_lat -d bonding_dev_0 --single_path -n 1000 -s 64 -S <server>

# then: CTP
urma_perftest send_lat --ctp -d bonding_dev_0 --single_path -n 1000 -s 64
urma_perftest send_lat --ctp -d bonding_dev_0 --single_path -n 1000 -s 64 -S <server>
```

Watch the `First-RPC-Latency` field — the RTP path pays the topo-scan + CM-RTT setup cost analyzed in [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) §10.19 (~905 ms cold on the original UMDK#1 case, ~25 ms warm). CTP imports go through a different resource path (`perftest_resources.c:1136` short-circuit), so the cold-setup cost profile should be qualitatively different — quantitative comparison TBD.

Steady-state ping-pong (`run_send_lat_duplex`) is kernel-bypass on both RTP and CTP, so per-iteration latency should differ only by HW path effects, not by software setup.
