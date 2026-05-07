# Cycle profiling for Ascend NPU kernels (Triton-Ascend, AscendC, etc.)

_Last updated: 2026-05-06._

How to get cycle counts and per-pipeline utilization for a kernel running on Ascend AICore. Two paths: real-device profiling via `msprof` (works today, fast), and cycle-accurate simulation via the camodel runtime (works once you know the activation trick, slow).

Source of the worked example: the `vector_add` Triton kernel from [`triton_ascend_lowering.md`](triton_ascend_lowering.md). The same techniques work for any Ascend kernel — Triton-Ascend, AscendC, hand-written CCE — as long as you can launch it from a Python or C process.

Tested on:
- 192.168.25.218 container (port 1234)
- CANN 8.5.0 + driver 25.5.1
- Triton-Ascend 3.2.0 in `/home/Ray/vllm_v13_venv`
- Target: Ascend910 (chip phy-id 4 was free at run time)

Companions:
- [`triton_ascend_lowering.md`](triton_ascend_lowering.md) — the lowering pipeline this doc complements
- [`reference_npu_server.md`](../../../.claude/projects/-Users-ray/memory/reference_npu_server.md) — connection + driver-libs `LD_LIBRARY_PATH` setup (memory)

---

## 1. Two paths to cycles

| | `msprof` on real hardware | Camodel (cycle-accurate simulator) |
| --- | --- | --- |
| What it measures | Real cycles + real pipeline counters | Modeled cycles per the simulated chip variant |
| Latency to first result | ~2 minutes | ≥5 minutes per kernel (sim is slow) |
| Granularity | Per task, per pipeline (vec/scalar/MTE1-3/fixpipe) | Per-instruction execution trace (with post-parse) |
| Mnemonics | No on the binary (BiSheng llvm-objdump decoder is gated) | **Yes** via `msopgen sim` post-parse of camodel dumps (§3.7-3.8) |
| Hardware needed | Yes — actual NPU | No — works on any host with CANN installed |
| Best for | Everyday perf work, real workloads | What-if scenarios, modeling different chips |

For routine tuning, **`msprof`** is the practical answer. Camodel is for the tail of investigations where you need either per-instruction traces or chip-variant comparisons.

## 2. `msprof` — real-device cycle profiling

### 2.1 Prerequisites

`msprof` itself fails to start with `libc_sec.so: cannot open shared object file` unless the driver lib paths are on `LD_LIBRARY_PATH`. Add this once to your shell rc (per `reference_npu_server.md` memory):

```bash
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

### 2.2 Invocation

Wrap the python invocation in `msprof`:

```bash
mkdir -p /home/Ray/triton_hello/msprof_out
/usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/msprof \
    --output=/home/Ray/triton_hello/msprof_out \
    --application="python /home/Ray/triton_hello/vector_add.py" \
    --aic-metrics=PipeUtilization \
    --aicpu=on
```

End-to-end: ~2 minutes including post-processing.

### 2.3 Output layout

```
msprof_out/PROF_000001_<timestamp>_<random>/
├── host/                        host-side profile
│   ├── data/                    raw protobuf-style traces
│   └── start_info, end_info     run boundaries
├── device_0/                    NPU-0 profile
│   ├── data/                    raw traces
│   └── sqlite/                  parsed SQLite databases
│       ├── ai_core_op_summary.db    ← per-op AICore data
│       ├── ascend_task.db
│       ├── time.db
│       ├── op_counter.db
│       ├── biu_perf.db              ← BIU = Bus Interface Unit perf counters
│       ├── freq.db                  ← AICore frequency timeline
│       └── metric_summary.db
└── mindstudio_profiler_output/  human-readable summaries
    ├── op_summary_<ts>.csv      ← per-task cycles + per-pipeline (most useful)
    ├── op_statistic_<ts>.csv    ← per-op-type aggregates
    ├── api_statistic_<ts>.csv   ← host-side API timings
    ├── task_time_<ts>.csv       ← raw timeline per task
    └── msprof_<ts>.json         ← Mind Studio Insight format
```

### 2.4 The `op_summary_<ts>.csv` schema

This is the file you'll actually want. Per-task row with these columns (~46 fields):

```
Device_id, Model ID, Task ID, Stream ID,
Op Name, OP Type, OP State, Task Type,
Task Start Time(us), Task Duration(us), Task Wait Time(us),
Block Dim, Mix Block Dim, HF32 Eligible,
Input Shapes, Input Data Types, Input Formats,
Output Shapes, Output Data Types, Output Formats, Context ID,

aicore_time(us), aic_total_cycles,
aic_mac_time(us), aic_mac_ratio,
aic_scalar_time(us), aic_scalar_ratio,
aic_mte1_time(us), aic_mte1_ratio,
aic_mte2_time(us), aic_mte2_ratio,
aic_fixpipe_time(us), aic_fixpipe_ratio,
aic_icache_miss_rate,

aiv_time(us), aiv_total_cycles,
aiv_vec_time(us), aiv_vec_ratio,
aiv_scalar_time(us), aiv_scalar_ratio,
aiv_mte2_time(us), aiv_mte2_ratio,
aiv_mte3_time(us), aiv_mte3_ratio,
aiv_icache_miss_rate,

cube_utilization(%)
```

Pipeline glossary (Ascend AICore):
- **Cube** (AIC): matrix multiply unit. `aic_*` columns.
- **Vector** (AIV): SIMD vector unit. `aiv_*` columns.
- **Scalar**: per-AIC/AIV scalar pipeline.
- **MTE1**: Memory Transfer Engine 1 — local-buffer ↔ L0 cache (cube only).
- **MTE2**: Memory Transfer Engine 2 — DRAM/L1 → unit buffers (load).
- **MTE3**: Memory Transfer Engine 3 — unit buffers → DRAM/L1 (store).
- **Fixpipe**: post-cube quantize/dequant/scale path (cube only).

A *_ratio* of `0.235` means 23.5% of the unit's time was spent in that pipeline. Sum of ratios is typically <1 because dispatch/sync/idle time is subtracted.

### 2.5 Worked example: `add_kernel`

From running our hello-world `vector_add` kernel on chip 4 with `msprof --aic-metrics=PipeUtilization`:

| Metric | Value |
| --- | --- |
| Op Name / OP Type | `add_kernel` / `add_kernel` |
| OP State | static |
| Task Type | **AI_VECTOR_CORE** (matches `mix_mode = "aiv"` in the kernel JSON) |
| Block Dim | 8 (matches `triton.cdiv(1024, 128) = 8`) |
| Mix Block Dim | 0 (no AI Cube use) |
| HF32 Eligible | YES |
| Input Shapes | 1024;1024 (FLOAT;FLOAT) |
| Output Shape | 1024 (FLOAT) |
| **Task Duration** | **3.360 µs** |
| Task Wait Time | 12,223,361.58 µs (waiting in queue before issue) |
| **aicore_time** | 0.0 µs (cube unused) |
| aic_total_cycles | 0 |
| **aiv_time** | **1.978 µs** |
| **aiv_total_cycles** | **12,658** |
| aiv_vec_time / ratio | 0.049 µs / 0.025 (2.5% — actual vector ops) |
| aiv_scalar_time / ratio | 0.315 µs / 0.159 (15.9% scalar) |
| aiv_mte2_time / ratio | 0.173 µs / 0.088 (8.8% — DRAM load) |
| aiv_mte3_time / ratio | 0.183 µs / 0.092 (9.2% — DRAM store) |
| aiv_icache_miss_rate | 0.235 (23.5% — first-run cold I-cache) |
| cube_utilization(%) | 0.000 |

**Headline: 12,658 AIV cycles, 1.978 µs of AI Vector time, 3.36 µs total task duration.**

The pipeline-utilization ratios sum to ~36.4%. The remaining ~63% is dispatch/sync/idle. Expected for a tiny kernel: 1024 elements × 4 bytes = 4 KB of data, split across 8 blocks of 128 elements each, with cold I-cache on the first invocation. A larger N or a hot run would shift the ratios toward MTE2/MTE3.

### 2.6 Op-statistic context

Aggregates from the same run, sorted by total time:

```csv
OP Type,     Core Type,      Count, Total(us), Avg(us), Ratio(%)
Range,       AI_VECTOR_CORE, 1,     12.16,     12.16,   50.000   ← torch.arange(1024)
add_kernel,  AI_VECTOR_CORE, 1,      3.36,      3.36,   13.816   ← Triton kernel
ReduceMax,   MIX_AIV,        1,      2.74,      2.74,   11.266   ← .abs().max()
Add,         AI_VECTOR_CORE, 1,      1.80,      1.80,    7.401   ← (out - (x+y))
Abs,         AI_VECTOR_CORE, 1,      1.42,      1.42,    5.839   ← .abs()
Fill,        AI_VECTOR_CORE, 1,      1.42,      1.42,    5.839   ← torch.full(10.0)
Sub,         AI_VECTOR_CORE, 1,      1.42,      1.42,    5.839   ← (out - (x+y))
```

Useful baseline: **for tiny kernels, surrounding torch ops dwarf the kernel itself.** Our `add_kernel` is 13.8% of total kernel time; `torch.arange(1024)` at 50% is the bottleneck. When optimizing a tiny kernel for benchmarking, eliminate the torch-side noise (allocate inputs once outside the timed region, run the kernel many times in a loop, etc.) before reading the kernel-row numbers.

### 2.7 Other useful `msprof` flags

```bash
--aic-metrics=PipeUtilization         # default; per-pipeline ratios
--aic-metrics=ArithmeticUtilization   # FLOPS / FLOP utilization
--aic-metrics=Memory                  # HBM/L2 bandwidth focus
--aic-metrics=MemoryL0                # L0 cache focus
--aicpu=on                             # also profile AICPU host coproc
--ai-stack=on                          # full host-stack timeline (slower)
--task-time=on                         # default; per-task timeline
--runtime-api=on                       # per-CANN-API timing on host
--output-format=json                   # for Mind Studio Insight import
```

Combine multiple metrics in separate runs and join CSVs. A single run captures one metric set.

## 3. Camodel — cycle-accurate simulation

### 3.1 What's there

CANN ships full CA-model libraries for many chip variants under `/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/`. Available targets (as of CANN 8.5.0):

```
AS31XM1          Ascend310B1-B4   Ascend910A     Ascend910_9362
Ascend310        Ascend310P1-P7   Ascend910B-B4  Ascend910_9372
Ascend310B1-B4   Ascend610        Ascend910Premium  Ascend910_9381
Ascend310P1-P7   Ascend610Lite    Ascend910Pro      Ascend910_9382
Ascend910A       Ascend910A-B4    Ascend920A     Ascend910_9391/9392
BS9SX1AA, BS9SX2AA/AB, MC61AM21AA/AB, common
```

Each `<TARGET>/lib/` contains:

```
config.json              L2 cache + log config
config_hwts.json
config_stars.json        instruction-cache + scheduler config
libruntime_camodel.so    ← the runtime drop-in (the activation point)
libruntime_cmodel.so     ← functional (faster) model — different from CA
libnpu_drv_camodel.so    ← driver mock for camodel
libnpu_drv_pvmodel.so    ← driver mock for power/voltage model
libtsch_camodel.so       ← task scheduler
libffts_model.so         ← FFTS (Function-Function Task Switch) model
libmodel_top.so          ← top-level model glue
libmodel_top_pv.so       ← top-level for power/voltage model
libstars.so              ← STARS scheduler
libstars_pv.so           ← STARS for power/voltage
libpem_davinci.so        ← Power & Energy Model
libesl_top_wrapper.so
libmcu_loop.so           ← MCU control-plane simulation
libmcu_wrapper.so
```

### 3.2 Activation: `LD_PRELOAD` is the missing trick

`LD_LIBRARY_PATH` alone does NOT redirect the runtime — programs still bind to the real driver's `libruntime.so`. The activation env is:

```bash
SIM_LIB=/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910_9362/lib
export CAMODEL_CONFIG_PATH=$SIM_LIB
export LD_LIBRARY_PATH=$SIM_LIB:$LD_LIBRARY_PATH
export LD_PRELOAD=$SIM_LIB/libruntime_camodel.so       # ← the load-bearing line
```

Then run your kernel. Confirmation that camodel took over comes from its own startup banner:

```
[INFO] Config file [config_stars.json] from environment variable [CAMODEL_CONFIG_PATH].
       Path: /usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910B1/lib/config_stars.json
[INFO] Config file is found, path is .../Ascend910B1/lib/config_stars.json.
[FuncCache]: size:0x20000, line_size:128, way_num:16, line_num:1024, idx_num:64
             idx_lsb:7, idx_mask:0x3f, tag_lsb:13, tag_mask:0xffffffffffffffff, ofst_mask:0x7f
[TmSim]: Run in serial mode.
[INFO] AicWrapper attach AIC 0, num_vec_core=2, num_subcore=3
... (attaches AIC 0 through AIC 21 — 22 simulated AI Cores)
```

### 3.2.1 The simulator is locked to 910B1 internally (verified 2026-05-07)

`te_set_version("Ascend910_9362")` and `soc_version="Ascend910_9362"` in `AscendOpKernelRunner` do NOT activate a 9362-specific simulator. Verified by running the same kernel twice with both `soc_version` settings and diffing the parsed traces:

| `soc_version=` | events | unique PCs | span (cyc) | SCALAR cyc | VECTOR cyc | MTE2 cyc |
|---|---|---|---|---|---|---|
| `Ascend910B1` | 9,459 | 624 | 27,645 | 70,590 | 8,647 | 3,658 |
| `Ascend910_9362` | **same** | **same** | **same** | **same** | **same** | **same** |

The `msopgen sim`-parsed instruction streams are bit-identical. Camodel's own `Total tick` counter varies by ±200 cyc between runs (28,573 vs 28,709 for the bool variant) but it's run-to-run init/teardown variance, not a microarchitecture signal.

The simulator banner gives the explanation: regardless of `soc_version`, it loads `/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910B1/lib/config_stars.json`. CAMODEL's platform-detection is hardcoded to 910B1 in CANN-8.5.0.

**Implication on CANN 8.5.0: treat camodel cycle numbers as 910B1-model values, not silicon-specific.** Diffs between two camodel runs (different kernels, different inputs) are valid signal; absolute cycles aren't comparable to vendor 910_9362 / 910C / 910A datasheets. For real-silicon cycle data on 910_9362, use msprof on the 218 dev box.

**This is fixed in CANN 9.0.0.** Verified 2026-05-07: a fresh `Ascend-cann-toolkit_9.0.0_linux-x86_64.run` install lays down 81 simulator directories including 30+ Ascend950PR variants (`Ascend950PR_9572`, etc.) and the existing 910 variants. Each variant has its own `config.json`/`config_stars.json` — the platform-detection that locks to 910B1 in 8.5.0 likely respects `soc_version=` properly in 9.0.0, but this needs an actual run to verify. Direct download URL (no Huawei login): `https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.0.0/Ascend-cann-toolkit_9.0.0_linux-x86_64.run` (~1.16 GB).

### 3.3 Surprises observed

Two things worth knowing:

1. **CAMODEL_CONFIG_PATH may not be honored as expected.** Even with our env pointing at `Ascend910_9362/lib`, the runtime banner shows it loaded `Ascend910B1/lib/config_stars.json`. The camodel has its own platform-detection that picks a closest available config. To force a specific variant, you may need to symlink/copy 9362 configs over the 910B1 directory, or unset `CAMODEL_CONFIG_PATH` and set a more specific selector.

2. **Simulated topology ≠ physical topology.** The 22 attached AI Cores correspond to the 910B1 model's spec, not the physical chip's 16 cores. The camodel is faithful to the model variant, not the silicon you happen to be running on.

### 3.4 Bonus: I-cache structure from the camodel banner

The `[FuncCache]` line in the startup log reveals the modeled I-cache:

```
size       = 0x20000  = 128 KB
line_size  = 128 B
way_num    = 16
line_num   = 1024
idx_num    = 64       (sets per way)
```

So 64 sets × 16 ways × 128 B = 128 KB total. This is the I-cache configuration the codegen targets — useful for tuning code-size budgets. Our msprof-measured 23.5% I-cache miss rate on the first add_kernel run was against this 128 KB capacity.

L2 cache parameters from `config.json` (for 910_9362):

```json
"L2CACHE": {
    "cache_set_size": 24,
    "cache_way_size": 16384,
    "cache_line_size": 512,
    "cache_read_latency": 241,
    "cache_write_latency": 96
}
```

24 × 16384 × 512 = 192 MiB modeled L2, with 241 cycle read / 96 cycle write latency.

### 3.5 Timing caveat

Camodel is genuinely cycle-accurate, which means **slow**. For successful end-to-end camodel runs:

1. Set the env (CAMODEL_CONFIG_PATH + LD_PRELOAD) as above.
2. **Allow ≥5 minutes wall-clock per simple kernel.**
3. Look for dump output in the working directory.

### 3.6 The working path — `AscendOpKernelRunner` from `op_test_frame`

**This is the answer for any precompiled `.npubin` kernel** (Triton-Ascend, AscendC, hand-rolled CCE — anything with a `.npubin`):

```python
import os, json, numpy as np
import te.platform as tp
tp.te_set_version("Ascend910B1", core_type="AiCore")
from op_test_frame.common.ascend_tbe_op import AscendOpKernel, AscendOpKernelRunner

KERNEL_DIR = "/path/to/triton_cache/<hash>"
BIN_PATH   = f"{KERNEL_DIR}/add_kernel.npubin"

# Triton's metadata JSON has snake_case fields; AscendOpKernel needs camelCase.
# Synthesize a TIK-style JSON pointing to the same npubin.
DUMP_DIR = "/tmp/triton_dumps"
os.makedirs(DUMP_DIR, exist_ok=True)
tik_json_path = f"{DUMP_DIR}/add_kernel_tik.json"
with open(tik_json_path, "w") as f:
    json.dump({
        "kernelName": "add_kernel",
        "blockDim":   8,                              # n / BLOCK
        "magic":      "RT_DEV_BINARY_MAGIC_ELF_AIVEC", # ELF + AIV-only mix_mode
        "workspace":  {"size": []},
    }, f)

n = 1024
x = np.arange(n, dtype=np.float32)
y = np.full((n,), 10.0, dtype=np.float32)
op = AscendOpKernel(BIN_PATH, tik_json_path)
op.set_input_info([
    {"shape": (n,), "dtype": "float32", "value": x},
    {"shape": (n,), "dtype": "float32", "value": y},
])
op.set_output_info([{"shape": (n,), "dtype": "float32"}])

with AscendOpKernelRunner(
    simulator_mode="ca",
    soc_version="Ascend910B1",
    simulator_lib_path="/usr/local/Ascend/cann-8.5.0/tools/simulator",
    simulator_dump_path=DUMP_DIR,
) as runner:
    runner.run(op, inputs=[x, y], block_dim=8)
```

Run with the simulator's lib dir on `LD_LIBRARY_PATH` (no `LD_PRELOAD` needed — the runner sets that up internally):

```bash
export LD_LIBRARY_PATH=/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910B1/lib:$LD_LIBRARY_PATH
python3 triton_camodel.py
```

Wall-clock: ~2 minutes for `vector_add` on Ascend910B1. CPU stays at ~280%; the 24-AIC simulation is multithreaded.

**Output:** 32 non-zero per-core dumps (4 cores × 2 veccores × 4 dump types: `instr_log`, `instr_popped_log`, `dcache_log`, `ifu.icache_log`). Cubecores stay 0 because vector_add is AIV-only.

The kernel runs across all 8 grid blocks distributed as 4 cores × 2 veccores. Each AIV gets one BLOCK=128 chunk.

### 3.7 Parsing the dumps — `msopgen sim`

The CANN-shipped wrapper for `op_gen.simulator.simulator`:

```bash
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
mkdir -p trace_out
for c in core0 core1 core2 core3; do
  for sc in veccore0 veccore1; do
    msopgen sim -c $c -subc $sc -d $DUMP_DIR -out trace_out
  done
done
```

(Don't pass `-reloc <kernel.npubin>` — that calls `llvm-objdump --save-aicore-bins` on the npubin, and the BiSheng llvm-objdump's hiipu64 decoder is gated. Skipping `-reloc` still gives you the trace, just without source-line annotations on each instruction.)

Output: `trace_out/dump2trace_core{0..3}.json` — each one is a Chrome-trace JSON with **full per-instruction execution records** including mnemonic, register operand state, and pipeline (SCALAR / VECTOR / MTE2 / MTE3 / FLOWCTRL).

### 3.8 Per-instruction view — what camodel actually shows

Per veccore for the tiny `vector_add` kernel:

| Core | Events | Span (cycles) | SCALAR | VECTOR | MTE2 | MTE3 |
|---|---|---|---|---|---|---|
| 0 | 68 | 1053 | 1757 | 36 | 1 | 0 |
| 1 | 68 | 1049 | 1752 | 36 | 1 | 0 |
| 2 | 68 | 1052 | 1763 | 36 | 1 | 0 |
| 3 | 68 | 1048 | 1757 | 36 | 1 | 0 |

(`Span` = max(ts+dur) − min(ts); per-pipe columns are total busy cycles. Pipes overlap, which is why pipe sums exceed span — VLIW-style parallelism.)

Cross-check vs §2.1's msprof real-device numbers:
- msprof: 12,658 AIV cycles for whole task → 12,658/8 grid blocks = **~1582 cycles/block**
- camodel: **~1050 cycles/block span per veccore**

Camodel is ~30% lower per block — the gap is the FFTS dispatch and AIV-AIC sync overhead that real hardware measures but the simulator skips. **Pipe-utilization ratios match closely**: VECTOR 36/1050 = 3.4% (camodel) vs vec 2.5% (msprof on real device).

Sample disassembled instructions from `trace_out/dump2trace_core0.json`:

```
0x10d11000  MOV_XD_IMM   X29=0x7f80, IMM:0x7f80                   SCALAR  ts=688  dur=2
0x10d11004  MOVK         X29=0x107f80, IMM:0x10, UIMM:0x1         SCALAR  ts=689  dur=2
0x10d11008  MOV_XD_SPR   X15=0,  SPR:SYS_VA_BASE                  SCALAR  ts=689  dur=2
0x10d1100c  ADD          X29=0x107f80, X29, X15  (S64)            SCALAR  ts=691  dur=2
0x10d11010  MOV_XD_SPR   X15=0x19, SPR:COREID                     SCALAR  ts=695  dur=2
…
0x10d11074  DIV          X1=…, X6=…, X1     (S64)                 SCALAR  ts=1069 dur=21  ← prog_id divide
0x10d11084  REM          X1=…, X1, X4       (S64)                 SCALAR  ts=1090 dur=21  ← prog_id mod
0x10d110b0  CMP_IMM      X4=0x80, IMM:0x7f, GT                    SCALAR  ts=1116 dur=2   ← mask check
0x10d110b4  JUMPC        Target=0x10d111d8, cond_flag=1           FLOWCTR ts=1117 dur=1
…
0x10d11214  SET_FLAG     PIPE:VEC, TRIGGER:MTE2, ID:0             VECTOR  ts=1484 dur=1   ← VEC→MTE2 sync
0x10d1121c  WAIT_FLAG    PIPE:VEC, TRIGGER:MTE2, ID:0             MTE2    ts=1485 dur=1
0x10d11234  SET_FLAG     (last)                                   VECTOR  ts=1741 dur=1
```

Yields (for the first time, publicly available without an internal Huawei build):

- **Mnemonic-level disassembly of hiipu64 machine code** — yesterday's doc claimed this was gated. It isn't, via this path.
- **Per-instruction cycle timestamps** with operand register state at each issue.
- **Pipeline classification** (SCALAR / VECTOR / MTE2 / MTE3 / FLOWCTRL) per instruction.
- **VLIW-style overlap visibility** — multiple instructions on different pipes at the same `ts`.

The Chrome-trace JSON loads in `chrome://tracing` (or `ui.perfetto.dev`) for a visual timeline.

### 3.9 The PyTorch / torch_npu trap — what NOT to do

The natural path is `LD_PRELOAD=…/libruntime_camodel.so python vector_add.py`. **It crashes** at `torch_npu._C._npu_init()` with:

```
RuntimeError: SetPrecisionMode: NPU function error: at_npu::native::AclSetCompileopt(
    aclCompileOpt::ACL_PRECISION_MODE, precision_mode), error code is 500001
[ERROR] FEOpsKernelInfoStore: Initialize custom and builtin sub-information library failed
[ERROR] OpsManager initialize failed.
```

Reason: camodel mocks the **runtime** layer (`libruntime_camodel.so`) but PyTorch-NPU also calls into the **GE / FE / OpCompiler** layers (`libge_runner.so`, `libfe.so`, etc.) which have no camodel mock. They try to talk to a real driver, fail at `AclSetCompileopt(ACL_PRECISION_MODE)`, and PTA crashes during `_npu_init`.

So Python + `torch_npu` is a dead end under camodel. Use `AscendOpKernelRunner` (§3.6) — it sidesteps all of PyTorch's GE/FE init and goes straight to `rtKernelLaunch`.

### 3.10 What about a hand-rolled ctypes launcher (LD_PRELOAD style)?

A direct ctypes launcher that LD_PRELOADs `libruntime_camodel.so` and calls `aclInit → aclrtSetDevice → aclrtCreateContext → aclrtSetCurrentContext → rtDevBinaryRegister → rtFunctionRegister → rtKernelLaunch` *appears* to set up everything correctly (every call returns 0, camodel banner appears) — but then **`rtKernelLaunch` returns 107002 = `ACL_ERROR_RT_CONTEXT_NULL`** despite the context being explicitly bound, and the per-core dump files all stay 0 bytes.

Root cause: a TLS-slot mismatch. `aclrtSetCurrentContext()` writes ACL's TLS slot; the camodel-mocked `rt*` calls read a *different* slot that the ACL layer never populates. Going pure-rt (`rtCtxCreate` directly) returns `507033` (`ACL_ERROR_INVALID_DEVICE`) because the camodel's bookkeeping requires the ACL-layer init.

`AscendOpKernelRunner` (§3.6) sidesteps this because it loads the simulator libs in the right order via `op_test_frame/runtime/rts_api.py`'s `_dll_simulator_so()` — that helper knows which TLS slot the camodel actually reads. Don't reinvent it via raw ctypes; use the runner.

The dump format is a per-AIC binary stream that `op_gen.simulator.simulator` can post-parse:

```bash
python3 -m op_gen.simulator.simulator \
    -c <core_id> \
    -d <dump-dir-from-camodel> \
    -reloc /path/to/add_kernel.npubin \
    -out trace.json
```

Add `-mix` for 910B mixed-mode and `-subc <id>` for subcore selection. The output `trace.json` is in the Mind Studio chrome-trace format and contains per-instruction execution records — the closest thing to mnemonic disassembly available publicly. Note: this requires the camodel to have actually emitted dumps; `LD_LIBRARY_PATH`-only invocation produces nothing to parse.

## 4. Choosing between paths

| Use case | Tool |
| --- | --- |
| Everyday "is my kernel faster than yesterday?" | `msprof` |
| Per-pipeline bottleneck identification | `msprof --aic-metrics=PipeUtilization` |
| FLOP utilization / arithmetic-bound ratio | `msprof --aic-metrics=ArithmeticUtilization` |
| Memory bandwidth diagnosis | `msprof --aic-metrics=Memory` |
| Compare with a different chip variant (no hardware) | camodel with `CAMODEL_CONFIG_PATH=<variant>` |
| Per-instruction execution trace / pseudo-disassembly | camodel + `op_gen.simulator.simulator` |
| Cycle-accurate model verification | camodel |
| Fast first cycle estimate during development | functional model `libruntime_cmodel.so` |

The `cmodel` (functional, not cycle-accurate) at `libruntime_cmodel.so` is faster than `camodel` but gives only correctness verification, not cycle counts. Same activation pattern (LD_PRELOAD).

## 5. Quick reference: end-to-end profile run

For copy-paste reuse:

```bash
# On 192.168.25.218 (or any CANN-installed host with a real NPU)
ssh -p 1234 root@192.168.25.218
source /home/Ray/vllm_v13_venv/bin/activate
source /usr/local/Ascend/ascend-toolkit/set_env.sh

# (One-time: ensure ~/.bashrc has the driver lib paths exported)

# Pick a free chip
export ASCEND_RT_VISIBLE_DEVICES=4
mkdir -p /home/Ray/myapp/msprof_out
/usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/msprof \
    --output=/home/Ray/myapp/msprof_out \
    --application="python /home/Ray/myapp/run.py" \
    --aic-metrics=PipeUtilization \
    --aicpu=on

# Inspect
cd /home/Ray/myapp/msprof_out/PROF_*/mindstudio_profiler_output
column -t -s, op_summary_*.csv | less -S          # tabulated view
sqlite3 ../device_0/sqlite/ai_core_op_summary.db   # SQL access
```

For camodel:

```bash
SIM_LIB=/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910_9362/lib
export CAMODEL_CONFIG_PATH=$SIM_LIB
export LD_LIBRARY_PATH=$SIM_LIB:$LD_LIBRARY_PATH
export LD_PRELOAD=$SIM_LIB/libruntime_camodel.so
mkdir -p /tmp/camodel_dump
cd /tmp/camodel_dump

# Allow ≥5 minutes for non-trivial kernels
timeout 600 python /home/Ray/myapp/run.py 2>&1 | tee camodel.log

# Post-parse if dumps appeared
ls -la /tmp/camodel_dump/
python3 -m op_gen.simulator.simulator \
    -c 0 -d /tmp/camodel_dump \
    -reloc /path/to/your_kernel.npubin \
    -out trace.json
```

## 6. References

- `/usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/msprof` — main profiler binary.
- `/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/<target>/lib/` — camodel libraries per chip variant.
- `/usr/local/Ascend/cann-8.5.0/python/site-packages/op_gen/simulator/` — Python post-parse for camodel dumps.
- `/usr/local/Ascend/cann-8.5.0/python/site-packages/op_gen/simulator/simulator.py` — entry point.
- Driver lib path setup: see [`reference_npu_server.md`](memory) and [`reference_npu_servers_all.md`](memory).
- The Triton-Ascend kernel used as worked example: `/home/Ray/triton_hello/vector_add.py` on 218.
- Lowering pipeline context (TTIR → TTAdapter → npubin): [`triton_ascend_lowering.md`](triton_ascend_lowering.md).
