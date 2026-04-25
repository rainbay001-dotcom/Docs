# CAM + dlock + USOCK / UMS

_Last updated: 2026-04-25._

UMDK's three "non-URMA-API" components: **CAM** (collective operators for AI training), **dlock** (distributed locks), and **USOCK / UMS** (a kernel-side TCP socket emulator that takes over the `AF_SMC` family). Source: `~/Documents/Repo/ub-stack/umdk/src/{cam,ulock/dlock,usock/ums}`.

---

## 1. CAM — Communication Acceleration for Matrix on Ascend NPU

### 1.1 What CAM is

From `src/cam/README.md` (verbatim is short — paraphrased to stay under quote limits): **CAM** = "Communication Acceleration for Matrix on Ascend NPU" — a SuperPOD communication acceleration library providing EP (Expert Parallelism) collective kernels, KVCache transfer for prefill-decode disaggregation and KVC pooling, AFD communication, and RL weight transfer. It can run as a single-kernel library or be integrated into vllm or SGLang.

**HW prereq.** Only Ascend A2 / A3 SuperPoD chips. Requires CANN ≥ 8.3.RC1.

### 1.2 Python integration — PyTorch operator library

CAM is **not a separate collective comm library** in the NCCL sense. It is a **PyTorch operator library** registered via `TORCH_LIBRARY_IMPL`:

```cpp
TORCH_LIBRARY_IMPL(umdk_cam_op_lib, PrivateUse1, m) { ... }
TORCH_LIBRARY_IMPL(umdk_cam_op_lib, AutogradPrivateUse1, m) { ... }
```

`PrivateUse1` is PyTorch's reserved device-type slot for non-standard accelerators — Ascend NPU dispatches there. So CAM ops appear as PyTorch ops the framework can dispatch alongside standard CUDA/CPU ops.

Module name registered: `umdk_cam_op_lib` (verified across `pybind/moe_*.cpp` files).

### 1.3 Python API entry

`src/cam/comm_operator/pybind/pybind.cpp:13-26` (per agent) registers nine primary ops:

| Op | Purpose |
|---|---|
| `fused_deep_moe` | Unified MOE dispatch + GEMM + combine in one kernel |
| `moe_dispatch_prefill` | Ring-based MOE token dispatch (prefill phase) |
| `moe_combine_prefill` | Ring-based MOE token combine (prefill phase) |
| `get_dispatch_layout` | Compute token-to-expert routing metadata |
| `moe_dispatch_shmem` | Shared-memory optimized dispatch (A3) |
| `moe_combine_shmem` | Shared-memory optimized combine (A3) |
| `moe_dispatch_prefill_a2` | A2-specific dispatch |
| `moe_combine_prefill_a2` | A2-specific combine |
| `get_dispatch_layout_a2` | A2-specific routing layout |

Function signatures in `pybind/functions.h:19-139` (per agent). Pattern: input tensors (token data, expert IDs, weights), config (world size, rank ID, expert count), returns 5 tensors (dispatched tokens + indices + metadata). All hook into PyTorch autograd via `torch::autograd::custom_function`.

### 1.4 Algorithm folders (`comm_operator/ascend_kernels/`)

- `moe_dispatch_normal/`, `moe_dispatch_normal_a2/`, `moe_dispatch_shmem/` — token routing variants (ring vs SHMEM fastpath).
- `moe_combine_*` mirrors.
- `fused_deep_moe/` — fused dispatch → GEMM → combine.
- `notify_dispatch_a2/` — A2 inter-rank notification synchronization.
- `dispatch_layout/` — routing-metadata computation.
- `utils/op_kernel/{comm_args.h, sync_collectives.h}` — common collective primitives (barriers, ring reductions).

Each kernel has `op_kernel/*.h` (AscendC kernel code) and `op_host/*.cpp` (host-side launcher). Tiling in `*_tiling.h` files for L0/L1/SRAM placement on Ascend cores.

### 1.5 Build flow

`build/cam/build.sh` produces two artifacts:

- `.run` — compiled AscendC kernels for installation under `/usr/local/Ascend/ascend-toolkit/latest/opp/vendors/CAM/`.
- `.whl` — Python extension wrapping the `umdk_cam_op_lib` torch ops.

**Build pipeline (verified 2026-04-25).** Custom CMake macro `add_kernels_compile()` orchestrates AscendC compilation. Invoked at `cmake_files/op_kernel/CMakeLists.txt:1-14`; macro definition lives in a parent / global CMake file outside the immediate dir. Kernels are real — `extern "C" __global__ __aicore__` signatures and `REGISTER_TILING_DEFAULT()` / `GET_TILING_DATA_WITH_STRUCT()` macros for parameterization (e.g. `comm_operator/ascend_kernels/moe_dispatch_normal_a2/op_kernel/dispatch_normal_a2.cpp:10, 29, 35-36`). Header files carry kernel implementation, not stubs. Toolchain is Huawei's proprietary AscendC compiler. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q9.

**Important caveat.** Per `src/cam/README.md`, `Ascend-SHMEM` is an **optional** dependency for SHMEM kernel paths. Without it, fall back to ring-based variants.

### 1.6 URMA integration — indirect

CAM does **not** call URMA APIs directly from Python or pybind. Instead:

- The PyTorch ops decompose collectives into AscendC kernels.
- AscendC kernels use CANN's collective primitives.
- CANN drivers, in turn, can use URMA underneath for data movement.

So the path is `Python → PyTorch op → CAM kernel (AscendC) → CANN collective → URMA / UDMA`. CAM's value-add is the fused-kernel design (single launch covering dispatch + GEMM + combine for MoE), not low-level communication.

This is the architectural difference vs NCCL: NCCL puts collective algorithms (ring, tree, halving-doubling) above the verbs/CUDA layer; CAM puts them inside fused HBM-resident kernels and lets CANN handle the verb-level moves.

### 1.7 Topology awareness

No auto-discovery via UBFM/UVS within CAM itself. The caller passes `ep_world_size`, `ep_rank_id`, `moe_expert_num`, etc. The framework (vllm / SGLang) is responsible for setting up the rank topology. `get_dispatch_layout()` (`pybind/functions.h:41-44`) computes per-rank send-lists and counts based on supplied expert→rank mappings.

### 1.8 Northbound integration (vllm / SGLang / VeRL)

CAM is a kernel set, not an integration shim. Frameworks `import umdk_cam_op_lib` and call ops within their `ProcessGroup`. Example: `src/cam/examples/moe_dispatch_combine_prefill_sample.py:17` shows direct import + invocation under DDP.

### 1.9 Example walkthrough

`src/cam/examples/moe_dispatch_combine_prefill_sample.py:27-80`:

1. Inputs: tokens `(batch, hidden)`, expert assignments `(batch, top_k)`, weights.
2. `moe_dispatch_prefill()` — sends tokens to assigned experts across EP ranks. Returns scattered token buffers + routing metadata.
3. Local expert GEMMs.
4. `moe_combine_prefill()` — gathers expert outputs back to original positions.
5. Per-rank SHMEM buffers hold inter-rank token exchange; rank topology passed explicitly.

---

## 2. dlock — distributed locks via URMA

### 2.1 Surface

`src/ulock/dlock/lib/include/dlock_client_api.h`. Lock variants per agent:

- `DLOCK_ATOMIC` — atomic-instruction-backed lock (line 79).
- `DLOCK_FAIR` — FIFO-ordered. `DLOCK_EAGAIN` returns when ticket queues (line 183).
- Exclusive vs shared (read-write) lock kinds.
- **Reentrant** semantics for same-client repeat `lock()` calls (refcount-based, lines 237-240).

### 2.2 Core API

```c
int       client_init(...);                     /* dlock_client_api.h:46 */
int       get_lock(...);                        /* :110 — allocate lock obj */
int       trylock(...);                         /* :193 — non-blocking */
int       lock(..., timeout);                   /* :220 — blocking */
int       unlock(...);                          /* :246 */
int       lock_extend(...);                     /* :267 — renew lease */
```

### 2.3 Atomic-object API (lines 410-512)

Distributed 64-bit atomics:

```c
int      umo_atomic64_create(...);
int      umo_atomic64_get(...);
int      umo_atomic64_release(...);
uint64_t umo_atomic64_faa(handle, value);     /* fetch-and-add  :476 */
uint64_t umo_atomic64_cas(handle, exp, new);  /* compare-and-swap :494 */
uint64_t umo_atomic64_get_snapshot(handle);   /* :512 */
```

Plus batch APIs (process up to 31 locks per RPC, lines 282-340) and async APIs (`lock_request_async`, `lock_result_check`, lines 366-389).

### 2.4 Implementation — URMA atomics + jetty messaging

`src/ulock/dlock/lib/common/urma_ctx.h:51-100`:

- Holds underlying `urma_device_t` (line 97-99).
- `register_new_seg()` (line 63) — register memory with URMA for remote access.
- `gen_token_value()` (line 64) — token for access control.

Lock state lives in URMA-registered shared memory. Lock requests travel via URMA messaging (jetty SEND) to a server; server updates state via URMA CAS / FAA atomically. `urma_buf` (lines 34-40) chains buffers with `jfs_ref_count`.

### 2.5 Failure handling — leases, no consensus

Locks are **lease-based**. `lock_desc` carries `lease_time` (`client_test.cpp:80`).

On client death:

1. Server detects heartbeat timeout (`client_heartbeat()` line 84; max 300 s).
2. Lock auto-expires server-side.
3. Other waiters unblocked.

Client may extend proactively via `lock_extend()` (line 267).

**No working replication.** A primary-backup protocol is **declared** in the codebase (`SERVER_REPLICA` enum, `REPLICA_INIT_REQUEST` / `REPLICA_CTRL_CATCHUP_REQUEST` message types) but **handlers are nullptr** — at runtime the server logs "invalid peer type, replica server is not supported" (`dlock_server.cpp:721-722`). Only `init_as_primary()` is implemented; no `init_as_replica()` exists. Production deployments must treat the dlock server as a SPOF until the replica path is wired. See [`umdk_code_followups.md`](umdk_code_followups.md) §Q10.

### 2.6 Examples + tools

- `examples/client/client_test.cpp` — 32 clients × N threads × 10 k acquire/release loops (line 31-32).
- `examples/client/client_test_object.cpp` — atomic FAA/CAS tests.
- `examples/server/primary_test.cpp` — server-side lock manager.
- `tools/` — admin/debug CLIs (not surveyed in detail).

---

## 3. USOCK / UMS — TCP socket emulation, takes over AF_SMC

### 3.1 The unusual design choice

UMS does **not** introduce a new socket family (no `AF_UB`). Instead, it **literally takes over the `AF_SMC` family** from upstream Linux:

- `MODULE_DESCRIPTION("ums implementation for AF_SMC address family")` — `kmod/ums/ums_mod.c:1214` (verified).
- `MODULE_ALIAS_NETPROTO(AF_SMC)` — line 1216 (verified).
- `sock_unregister(AF_SMC)` then re-registers UMS handlers — lines 1123, 1196 (verified).
- Falls back to upstream SMC-R if `CONFIG_SMC=y` and UMS is unavailable: lines 339, 342, 1165, 1192 (verified).

**Why this is interesting.** Linux already ships **SMC-R** (Shared Memory Communications over RDMA) — IBM's transparent socket-level RDMA fast path. SMC-R is an in-tree feature that bridges TCP `SOCK_STREAM` semantics to RDMA primitives. UMS treats SMC-R as a substrate: same socket family, same fallback semantics, swap RDMA for URMA underneath. From the application's perspective, opening a `socket(AF_INET, SOCK_STREAM, 0)` and connecting to a UMS-capable peer transparently uses URMA — no app code changes, no LD_PRELOAD.

### 3.2 Kernel module structure

**Path:** `src/usock/ums/kmod/ums/`. Out-of-tree module loaded via `modprobe ums`.

Key files (per agent):

- `ums_mod.c` / `ums_mod.h` — module init/exit, family registration.
- `ums_clc.h` — CLC (Connection Level Control) negotiation phase.
- `ums_cdc.h` — CDC (Connection Data Control), cursor/credit messages.
- `sockops/ums_connect.h`, `ums_accept.h`, `ums_listen.h` — socket-op dispatch.

Init (per agent — `ums_mod.c:99 ff`):

```c
proto_register(&g_ums_proto, 1);
proto_register(&g_ums_proto6, 1);
register_pernet_subsys(&g_ums4_net_ops);
register_pernet_subsys(&g_ums6_net_ops);
sock_register(&ums_family_ops);   /* with .family = AF_SMC, line 764, 838 */
```

Exit reverses, including `sock_unregister(AF_SMC)`.

### 3.3 Connection setup — three phases

UMS preserves SMC-R's two-phase handshake atop a TCP CLC channel:

1. **CLC (Connection Level Control).** Peers do a TCP 3-way handshake. They exchange CLC messages negotiating UMS support. If either side doesn't support UMS, the connection stays plain TCP (transparent fallback).
2. **LLC (Link Layer Control) / URMA setup.** Both sides exchange URMA endpoint info — EIDs, jetty IDs, RMBE (Receive Memory Buffer Element) addresses — via the CLC TCP connection. URMA jetties get bound.
3. **Data phase.** Subsequent `send`/`recv` go over URMA (writes to peer's RMBE), not TCP.

### 3.4 Byte-stream emulation over URMA

URMA is message-oriented; TCP is byte-stream. UMS bridges the gap in the kernel:

- **Send.** Fragment skb queue into URMA-message-sized chunks; post URMA writes to peer's RMBE ring buffer.
- **Receive.** Accept URMA writes into RMBE, expose as a contiguous byte stream via skb assembly back into the socket layer.
- **Cursor tracking** (`ums_cdc.h:34-45`): `ums_cdc_cursor` carries producer (sent) and consumer (acked) pointers in network byte order, updated atomically via URMA fetch-and-add — TCP-like ack semantics.
- **Credits** (`ums_cdc.h:57`): 8-bit credit field (max 256) in CDC messages piggybacked on URMA writes; sender throttles when credits are low.

`struct ums_cdc_msg` at `ums_cdc.h:48-59` carries seqno, token, and cursor updates.

### 3.5 What the application sees

Standard POSIX socket code. **Zero modifications.**

```c
int s = socket(AF_INET, SOCK_STREAM, 0);
connect(s, &addr, sizeof addr);
send(s, buf, len, 0);
```

The kernel transparently picks UMS for eligible connections (peer supports it, fabric is UB-capable). For UMS-specific tuning, the module borrows the SMC-R sock-level constant `SOL_SMC = 286`.

### 3.6 Test harness

`umdk/test/usock/ums/README.md`:

- Server: `ut_cov.sh -S -l SERVER_IP -r CLIENT_IP`
- Client: `ut_cov.sh -C -l CLIENT_IP -r SERVER_IP`
- Verifies CLC negotiation, basic socket ops, error paths.
- Optional kernel GCOV; depends on URMA + googletest.
- Tests inherit structure from upstream SMC-R tests — confirming the architectural lineage.

---

## 4. Cross-component view

### 4.1 Shared substrate

All three components ride URMA at different abstraction levels:

| Component | Abstraction over URMA |
|---|---|
| CAM | High-level fused collective kernels (URMA underneath via CANN) |
| dlock | RPC + atomic primitives |
| UMS | TCP byte-stream emulation (replaces SMC-R) |

### 4.2 Build / deploy

| Component | Form factor | Loader |
|---|---|---|
| CAM | `.whl` (Python) + `.run` (AscendC kernels in CANN OPP) | `pip install` + CANN OPP install |
| dlock | C++ library `libdlock.so` | linked into apps/server |
| UMS | Out-of-tree kernel module `ums.ko` | `modprobe ums` |

### 4.3 Why each is separate (architectural taste)

- **CAM** lives in framework-extension space — it's a PyTorch dispatch target, not a comm library replaceable at runtime. Tight HW affinity (Ascend-only).
- **dlock** is application-level synchronization. URMA is the right substrate (message + atomics) but locks are a service, not a transport.
- **UMS** is a kernel feature that relies on the `AF_SMC` slot already cut by SMC-R. Userspace exposure would require code changes; kernel-level lets unmodified TCP apps benefit.

---

## 5. Open questions

1. **CAM ↔ URMA wire-level path.** Verify that CANN's collective ops do go over URMA (vs HCCL or another backend) on UB-capable Ascend chips.
2. **dlock server replication.** Any planned HA story?
3. **UMS coexistence with upstream SMC-R.** What happens if both modules try to claim `AF_SMC`? UMS wins because it loads later, but is there an explicit incompatibility guard?
4. **UMS performance vs raw TCP.** What latency / bandwidth uplift in practice? Does it match SMC-R's published numbers?
5. **CAM SHMEM dependency.** When `Ascend-SHMEM` is missing, does the fallback (ring) reach the same throughput? Or is SHMEM required for line rate?
6. **dlock max scale.** How many simultaneous locks / clients does the single-server design tolerate before saturating?

---

_Companion: [`umdk_architecture_and_workflow.md`](umdk_architecture_and_workflow.md), [`umdk_urpc_and_tools.md`](umdk_urpc_and_tools.md)._
