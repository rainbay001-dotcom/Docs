# End-to-end walkthrough: cycle-accurate disassembly of a Triton mask kernel

_Last updated: 2026-05-07._

A worked example: take a Triton-Ascend mask kernel (`mask_fn` from `helloworld.py`), compile it, run it under camodel, and produce per-instruction cycle analysis.

This is the same recipe as the `vector_add` walkthrough — just substituting a more interesting kernel. Useful as a template for any precompiled `.npubin` you want to inspect.

Companions:
- [`disassembly_via_camodel.md`](disassembly_via_camodel.md) — what the trace gives you and what it doesn't
- [`ascend_cycle_profiling.md`](ascend_cycle_profiling.md) §3.6–3.8 — the launch + parse infrastructure

---

## 1. The kernel

`mask_fn` from `helloworld.py` is a Triton **helper** (`@triton.jit` but with no `tl.load` / `tl.store` / `tl.program_id`):

```python
@triton.jit
def mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE: tl.constexpr):
    if TYPE == 1:
        triu_causal = (q_offset[:, None] <= k_offset[None, :])
        return ((triu_causal & ((q_attn_arg[:, None] == k_attn_arg[None, :]) |
                                (k_attn_arg[None, :] == 0))) |
                (q_offset[:, None] == k_offset[None, :]))
    if TYPE == 2:
        ...
```

Camodel can't run it directly — there's no kernel surface to launch. Wrap it in a kernel that has loads, the helper call, and a store:

```python
@triton.jit
def mask_kernel(
    q_attn_ptr, k_attn_ptr, q_off_ptr, k_off_ptr, out_ptr,
    M: tl.constexpr, N: tl.constexpr, TYPE: tl.constexpr,
):
    q_off  = tl.load(q_off_ptr  + tl.arange(0, M))
    k_off  = tl.load(k_off_ptr  + tl.arange(0, N))
    q_attn = tl.load(q_attn_ptr + tl.arange(0, M))
    k_attn = tl.load(k_attn_ptr + tl.arange(0, N))
    mask   = mask_fn(q_attn, k_attn, q_off, k_off, TYPE=TYPE)
    out    = tl.where(mask, 1, 0).to(tl.int8)
    tl.store(out_ptr + tl.arange(0, M)[:, None] * N + tl.arange(0, N)[None, :], out)
```

Use small `M=N=32` (1024-element output) to keep camodel runtime under 10 minutes.

## 2. Compile to `.npubin` on real device

```bash
ssh -p 1234 root@192.168.25.218
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /home/Ray/venv/bin/activate

cd /home/Ray/triton_hello
TRITON_CACHE_DIR=$PWD/mask_cache ASCEND_RT_VISIBLE_DEVICES=10 \
  python3 helloworld_runner.py
# → first row sample: [1, 1, 1, 1, 1, 1, 1, 1]
# → last row sample:  [0, 0, 0, 0, 0, 0, 0, 0]    (TYPE=1: upper-triangular causal mask)

find mask_cache -name '*.npubin'
# mask_cache/<hash>/mask_kernel.npubin
```

Triton caches the binary along with `mask_kernel.json` (metadata: `mix_mode="aiv"`, target `Ascend910_9362`, etc.).

## 3. Run under camodel

The camodel launcher uses `op_test_frame.AscendOpKernelRunner` with `simulator_mode="ca"`:

```python
import os, json, glob, numpy as np
import te.platform as tp
tp.te_set_version("Ascend910B1", core_type="AiCore")
from op_test_frame.common.ascend_tbe_op import AscendOpKernel, AscendOpKernelRunner

CACHE = "/home/Ray/triton_hello/mask_cache"
BIN_PATH  = glob.glob(f"{CACHE}/*/mask_kernel.npubin")[0]
JSON_PATH = BIN_PATH.replace(".npubin", ".json")

DUMP_DIR = "/home/Ray/triton_hello/camodel_run/mask_dumps"
os.makedirs(DUMP_DIR, exist_ok=True)

# Triton's JSON has snake_case fields; AscendOpKernel needs camelCase. Synthesize one.
triton_meta = json.load(open(JSON_PATH))
tik_json = f"{DUMP_DIR}/mask_kernel_tik.json"
with open(tik_json, "w") as f:
    json.dump({
        "kernelName": triton_meta["kernel_name"],
        "blockDim":   1,                                # grid=(1,) at launch
        "magic":      "RT_DEV_BINARY_MAGIC_ELF_AIVEC",  # mix_mode=aiv
        "workspace":  {"size": []},
    }, f)

M, N = 32, 32
q_attn = np.zeros(M, dtype=np.int32)
k_attn = np.zeros(N, dtype=np.int32)
q_off  = np.arange(M, dtype=np.int32)
k_off  = np.arange(N, dtype=np.int32)

op = AscendOpKernel(BIN_PATH, tik_json)
op.set_input_info([
    {"shape": (M,), "dtype": "int32", "value": q_attn},
    {"shape": (N,), "dtype": "int32", "value": k_attn},
    {"shape": (M,), "dtype": "int32", "value": q_off},
    {"shape": (N,), "dtype": "int32", "value": k_off},
])
op.set_output_info([{"shape": (M, N), "dtype": "int8"}])

with AscendOpKernelRunner(
    simulator_mode="ca",
    soc_version="Ascend910B1",
    simulator_lib_path="/usr/local/Ascend/cann-8.5.0/tools/simulator",
    simulator_dump_path=DUMP_DIR,
) as runner:
    runner.run(op, inputs=[q_attn, k_attn, q_off, k_off], block_dim=1)
```

```bash
export LD_LIBRARY_PATH=/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910B1/lib:$LD_LIBRARY_PATH
python3 mask_camodel.py
# → wall-clock ~7 min on 218
# → camodel reports: "Total tick: 28573"
```

Outputs 4 non-zero per-core dumps (only `core0/veccore0` since `blockDim=1`):

```
core0.veccore0.dcache_log.dump        2,561,782 B
core0.veccore0.ifu.icache_log.dump    3,810,981 B
core0.veccore0.instr_log.dump         1,134,875 B
core0.veccore0.instr_popped_log.dump  1,132,889 B
```

vs. `vector_add`'s 12 KB per dump — this kernel does ~100× more work.

## 4. Parse to per-instruction trace JSON

```bash
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
mkdir -p mask_trace
msopgen sim -c core0 -subc veccore0 \
  -d mask_dumps -out mask_trace
# → "Generation completed."
# → mask_trace/dump2trace_core0.json  (~2 MB)
```

(`-reloc` is gated; skip it. Mnemonics + operands still come through.)

## 5. Per-instruction cycle analysis

### 5.1 Top-line numbers

```
Total instruction events:    9,459
Unique PCs (executed code):    624
Cycle span (start → end):  703 → 28,348 = 27,645 cycles
Camodel "Total tick":      28,573 cycles
```

Comparison with `vector_add` (n=1024, BLOCK=128, 8 grid blocks):

| Metric | vector_add | mask_kernel (M=N=32) |
|---|---|---|
| Events (one veccore) | 68 | 9,459 |
| Unique PCs executed | 68 | 624 |
| Cycle span | 1,053 | 27,645 |
| Camodel total tick | (per-block) | 28,573 |

Mask is ~25× longer per veccore, with ~9× more unique code surfaced — there's a real loop body running here, not just setup.

### 5.2 Per-pipeline breakdown

| Pipeline | Total cycles | Instructions | Avg cyc/instr |
|---|---|---|---|
| **SCALAR** | 70,590 | 8,035 | 8.8 |
| **VECTOR** | 8,647 | 348 | 24.8 |
| **MTE2** (DMA load) | 3,658 | 13 | 281.4 |
| **FLOWCTRL** (jumps/loops) | 1,065 | 1,060 | 1.0 |
| **MTE3** (DMA store) | 219 | 2 | 109.5 |
| **ALL** (full barrier) | 214 | 1 | 214.0 |

(Pipe sums exceed the 27,645-cycle span because pipes overlap — VLIW-style parallelism.)

Read-out: SCALAR pipe is doing most of the work (mostly address computation, scalar comparisons, loop control). VECTOR has only 348 ops but each is expensive (avg 25 cyc) — these are the `MOVEMASK`, `MOVEV`, `VNCHWCONV`, `BAR` operations that implement the actual mask logic. The 13 MTE2 (DMA) ops are 281 cycles on average — first-touch cache misses on parameter and tensor loads.

### 5.3 Top mnemonics by total cycles

| Mnemonic | Total cyc | Count | Avg cyc | What it does |
|---|---|---|---|---|
| `ST_XD_XN_IMM` | 33,029 | 1,026 | 32.2 | Scalar store with immediate offset (1024 = M×N output writes) |
| `LD_XD_XN_IMM` | 26,451 | 2,082 | 12.7 | Scalar load with immediate offset (input loads + reloads) |
| `ADD` | 4,174 | 2,087 | 2.0 | 64-bit add (offset arithmetic, dominant in SCALAR pipe) |
| `SET_FLAG` | 2,504 | 75 | 33.4 | Pipe-pair sync: signal another pipe |
| `BAR` | 2,435 | 24 | 101.5 | Pipeline barrier (full-fence) |
| `ADD_IMM` | 2,116 | 1,058 | 2.0 | Scalar add-immediate (loop counter, address increment) |
| `CMPN` | 2,048 | 1,024 | 2.0 | Compare-not-equal (one per output element — the equality test in `mask_fn`) |
| `MOVEV` | 1,704 | 69 | 24.7 | Move vector |
| `MOVEMASK` | 1,544 | 84 | 18.4 | Build vector mask register |
| `MOV_SRC_TO_DST_ALIGN` | 1,496 | 5 | **299.2** | Aligned move; ~300 cyc each, slowest scalar op |
| `WAIT_FLAG` | 1,405 | 75 | 18.7 | Pipe-pair sync: wait for another pipe |
| `MOV_SPR_XN` | 1,071 | 111 | 9.6 | Move from special-purpose register |
| `ENDLOOP` | 1,024 | 1,024 | 1.0 | Loop-body terminator (one per inner-loop iteration) |
| `VNCHWCONV` | 828 | 8 | 103.5 | NCHW layout conversion (vector format change) |
| `MOVEVA` | 448 | 64 | 7.0 | Move vector arithmetic |

Read-out:

- **The 2-D mask compute IS vectorized.** Five `VCMPV` / `VCMPVS` instructions at distinct PCs on the VECTOR pipe each fire once — these are the actual element-wise comparisons (`q_off <= k_off`, `q_attn == k_attn`, `k_attn == 0`, `q_off == k_off`, plus a fifth combining op). Together with the 84 `MOVEMASK` and 69 `MOVEV`/`MOVEVA` instructions they compute a packed 32×32 bitmap on the vector ALU.
- **The 1024-iteration loop is the STORE phase, not the compare.** The loop body at PC 0x10d11344–0x10d11364 reads packed bytes from the mask bitmap and writes one int8 to the output tensor per iteration. `CMPN`'s 1024 instances are byte-generation `LE` compares between two scalar registers loaded from the packed mask data — they're producing the 0/1 byte to store, not doing the original mask comparison. (See §5.7 for the corrected reading and the loop-body assembler.)
- **Stores dominate cycle time**: 1,026 `ST_XD_XN_IMM` × avg 32 cyc = 33K cyc, bigger than the entire vector pipe (8.6K cyc on 348 instrs). **This kernel is store-bound, not compute-bound** — the int8 unpacked-byte writes serialize the late part of the kernel timeline.
- **Two heavy mnemonics**: `MOV_SRC_TO_DST_ALIGN` averages **299 cycles** — only 5 instances but they cost 1.5K cycles total. `BAR` averages 101 cycles (24 of them). These are per-stage pipeline drains.
- **First-touch param-load cost is real**: 13 MTE2 DMA ops at 281 cyc/each = 3.7K cyc — first time the kernel reaches into PARA_BASE / GM, all latency is exposed.

### 5.4 Sample assembler — first 30 instructions (prologue)

```
PC           Mnemonic             Pipe      dur  Operands
0x10d11000   MOV_XD_IMM           SCALAR      2  XD:X29=0x7f60, IMM:0x7f60
0x10d11004   MOVK                 SCALAR      2  XD:X29=0x107f60, IMM:0x10, UIMM:0x1
0x10d11008   MOV_XD_SPR           SCALAR      2  XD:X15=0, SPR:SYS_VA_BASE
0x10d1100c   ADD                  SCALAR      2  XD:X29=X29+X15  (S64)
0x10d11010   MOV_XD_SPR           SCALAR      2  XD:X15=0x18, SPR:COREID
0x10d11014   MOV_XD_IMM           SCALAR      2  XD:X16=0x7fff
0x10d11018   MOV_XD_IMM           SCALAR      2  XD:X0=0x1
0x10d1101c   AND                  SCALAR      2  XD:X15=X15&X16  (B64)
0x10d11020   MOV_XD_IMM           SCALAR      2  XD:X17=0x8000
0x10d11024   NEG                  SCALAR      2  XD:X0=-X0  (S64)
0x10d11028   MADD                 SCALAR      4  XD:X29=X15*X17+X29 (S64)   ; stack-frame base
0x10d1102c   MOVEMASK             VECTOR     17  XN:X0=0xff..ff, Pos:0
0x10d11030   MOVEMASK             VECTOR     17  XN:X0=0xff..ff, Pos:1
0x10d11034   ADD_IMM              SCALAR      2  XD:X30=X29+0x780             ; workspace ptr
0x10d11038   MOV_XD_SPR           SCALAR      2  XD:X0=0x1022fe00, SPR:PARA_BASE
0x10d1103c   MOV_XD_IMM           SCALAR      2  XD:X1=0
0x10d11040   LD_XD_XN_IMM         SCALAR    361  [X0+0x38]                    ; first FFTS load — cache miss
0x10d11044   MOV_XD_IMM           SCALAR      2  XD:X6=0x20
0x10d11048   MOVEMASK             VECTOR     17  Pos:1, Id:18
0x10d1104c   MOV_XD_IMM           SCALAR      2  XD:X7=0x400
0x10d11050   ST_XD_XN_IMM         SCALAR    289  [X30+0x878]                  ; first-touch store, cache miss
0x10d11054   ADD_IMM              SCALAR      2  XD:X2=X0+0x28
0x10d11058   LDP_XI_XJ_XN         SCALAR      6  X0,X5 = [X0+0x18]            ; load pair (warm cache now)
0x10d1105c   LDP_XI_XJ_XN         SCALAR      6  X3,X2 = [X2]
0x10d11060   MOV_XD_SPR           SCALAR      2  XD:X4=0, SPR:CTRL
0x10d11064   INSERT_XD            SCALAR      2  POSITION:0x38, EXT:0
0x10d11068   MOV_SPR_XN           SCALAR      1  SPR:CTRL, XN:X4=0
0x10d1106c   MOV_XD_SPR           SCALAR      2  XD:X4=0, SPR:CTRL
0x10d11070   INSERT_XD            SCALAR      2  XD:X4=0x100..., POSITION:0x38
0x10d11074   MOV_SPR_XN           SCALAR      1  SPR:CTRL, XN:X4=…
```

Same pattern as `vector_add`'s setup, but the kernel diverges into a much longer body afterwards.

### 5.5 Sample assembler — loop body (PC ~0x10d11200)

```
0x10d1120c   MOV_XD_IMM           SCALAR      2  XD:X0=0x8
0x10d11210   MOV_XD_IMM           SCALAR      2  XD:X8=0x5555
0x10d11214   NEG                  SCALAR      2  XD:X0=-X0  (= -8)
0x10d11218   MOVK                 SCALAR      2  XD:X8=0x55555555  (build 0x5555_5555)
0x10d1121c   MOVEMASK             VECTOR     33  Pos:1, Id:135
0x10d11220   AND                  SCALAR      2  XD:X0=X3&X0  (= 0x80000)
0x10d11224   MOVK                 SCALAR      2  XD:X8=0x555555555555      ; building causal-bit pattern 0x55555..
0x10d11228   ADD                  SCALAR      2  XD:X0=X0+X6
0x10d1122c   MOV_XD_IMM           SCALAR      2  XD:X6=0x4780
0x10d11230   MOVK                 SCALAR      2  XD:X8=0x5555555555555555  ; 64-bit alternating-bit mask
0x10d11234   MOV_XD_IMM           SCALAR      2  XD:X9=0x2000
0x10d11238   BAR                  VECTOR     30  PIPE:VEC                  ; barrier — drain VEC pipe
0x10d1123c   SET_FLAG             VECTOR     20  PIPE:VEC, TRIGGER:SCALAR
0x10d11240   WAIT_FLAG            SCALAR     21  PIPE:VEC, TRIGGER:SCALAR
0x10d11244   LD_XD_XN_IMM         SCALAR     13  [X0+0x8]
0x10d11248   SET_FLAG             SCALAR     13  PIPE:SCALAR, TRIGGER:VEC
0x10d1124c   WAIT_FLAG            VECTOR      1  PIPE:SCALAR, TRIGGER:VEC
0x10d11250   MOV_XD_SPR           SCALAR      2  XD:X13=0, SPR:CTRL
0x10d11254   INSERT_XD            SCALAR      2  POSITION:0x38
0x10d11258   ADD                  SCALAR      2  XD:X12=X10+X6
0x10d1125c   MOV_SPR_XN           SCALAR      1  SPR:CTRL, XN:X13=0
0x10d11260   SIGNEXT              SCALAR      2  XD:X13=(S32)X11
0x10d11264   SHR                  SCALAR      2  XD:X11>>=0x20
0x10d11268   MOVEMASK             VECTOR     17  XN:X7=0xaaaaaaaaaaaaaaaa  ; alternating 0xa = 0b1010 mask
0x10d1126c   ADD_IMM              SCALAR      2  XD:X10=X10+0x100         ; loop counter ++=0x100
0x10d11270   CMP                  SCALAR      2  XN:X10 vs X9=0x2000, NE  ; loop-end check
0x10d11274   MOVEV                VECTOR     23  XD:X12, XN:X11, XT:X4
```

The loop body shows what the mask kernel actually does at the instruction level:

- **`0x10d11224–0x10d11230`** builds the alternating-bit pattern `0x5555_5555_5555_5555` step by step via `MOVK` — that's the bit pattern that lays out one mask bit per element in the final packed output.
- **`0x10d11268`** moves `0xaaaa_aaaa_aaaa_aaaa` (the inverse) — the other half of the 1-bit-per-element packing.
- **`0x10d1123c–0x10d1124c`** is a `SET_FLAG` / `WAIT_FLAG` ping-pong between VEC and SCALAR pipes — this is what makes the VECTOR pipe wait for SCALAR's address computation and vice versa.
- **`0x10d11270`** is the loop end-check: compare loop counter against `0x2000` and branch back if not equal. This `CMP` fires 1024 times (matching the `ENDLOOP` count) — confirming the inner loop trip count.
- **`MOVEV`** at the end moves the computed mask vector to its destination.

### 5.7.0 Microarchitecture caveat

Cycle numbers in this walkthrough are from the camodel with `soc_version="Ascend910B1"`. Although the kernel was compiled for `Ascend910_9362` and `te_set_version("Ascend910_9362")` is supported by the launcher, **the camodel internally locks to 910B1's config** regardless. Verified: identical traces under both `soc_version` settings. See [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §6.5 for the diff. Treat camodel cycle numbers as 910B1-model values; for real-silicon Ascend910_9362 numbers, use msprof on the 218 dev box (yesterday's vector_add measurement: 12,658 AIV cycles).

### 5.7 Corrected reading: where the mask compute actually happens

**An earlier version of §5.3 above claimed "Triton lowered the 2-D mask compute as a flat scalar loop, not a vectorized comparison" based on the 1024 `CMPN` instructions matching M×N. That was wrong — see the evidence here.**

The 1024 `CMPN` at PC 0x10d1135c are inside a 1024-iteration loop, with operands that are **identical across all 1024 iterations** (`dtype:S64, XN:X6=0, XM:X7=0, cond_op:LE`). That tells you the CMPN isn't comparing source-data values — it's a scalar `LE` between two register-held bytes loaded from a packed mask bitmap.

**The actual element-wise compares fire on the VECTOR pipe as `VCMPV` / `VCMPVS`:**

```
PC=0x10d1142c  VCMPV   VECTOR  dur=36   Dtype:F16, XD:X5, XN:X5, XM:X6, XT:X7=0x800080800010101
PC=0x10d114f0  VCMPV   VECTOR  dur=53   Dtype:S32, XD:X6, XN:X6, XM:X11, XT:X7=0x1000080800010101
PC=0x10d11504  VCMPVS  VECTOR  dur=60   Dtype:S32, XD:X8=0, XN:X9=0x2200, XM:X8=0
PC=0x10d115e4  VCMPV   VECTOR  dur=28   Dtype:F16, XD:X9, XN:X9, XM:X0=0
PC=0x10d11684  VCMPV   VECTOR  dur=53   Dtype:S32, XD:X4, XN:X4, XM:X3, XT:X7=0x1000080800010101
```

Five vector compares. `mask_fn(TYPE=1)` has four logical comparisons:

```python
triu_causal             = q_offset <= k_offset      # VCMPV  PC=0x10d1142c
q_attn == k_attn                                     # VCMPV  PC=0x10d114f0
k_attn == 0                                          # VCMPVS PC=0x10d11504  (compare-vector-with-scalar)
q_offset == k_offset                                 # VCMPV  PC=0x10d115e4
```

The fifth `VCMPV` (at 0x10d11684) is likely the OR/combining op or a re-compare that closes the expression. Each of these compares operates on a vector register holding many elements at once.

**The 1024-iteration loop body at PC 0x10d11344–0x10d11364** is the unpack-and-store phase:

```
0x10d11344  LOOP         FLOWCTRL  Total Iter Num: 1024              ← loop header (fires once)
0x10d11348  ADD          SCALAR  2  X6 = X1(base1) + X0(offset)      ; address of packed mask byte 1
0x10d1134c  ADD          SCALAR  2  X7 = X4(base2) + X0(offset)      ; address of packed mask byte 2
0x10d11350  LD_XD_XN_IMM SCALAR 13  X6 = [X6]  (B64)                 ; load packed mask data 1
0x10d11354  LD_XD_XN_IMM SCALAR 13  X7 = [X7]  (B64)                 ; load packed mask data 2
0x10d11358  ADD_IMM      SCALAR  2  X0 = X0 + 8                      ; offset += 8 byte stride
0x10d1135c  CMPN         SCALAR  2  X6 = (X6 <= X7) ? 1 : 0  (S64, LE) ← byte generation
0x10d11360  ST_XD_XN_IMM SCALAR 20  [X5+...] = X6  (B8)              ← store ONE int8 byte
0x10d11364  ENDLOOP      FLOWCTRL  Iter: 1024                        ← loop close
```

Each iteration: 2 ADDs (address) + 2 LDs (~13 cyc each, hot cache after first iter) + 1 ADD_IMM (counter) + 1 CMPN (byte gen) + 1 ST (~20 cyc) + 1 LOOP/ENDLOOP overhead.

**The cost breakdown:**
- 1024 stores × 20 cyc avg = **20,480 cycles** dedicated just to writing the 1024-byte int8 output
- The vector compute pipe finished by ts ~27,330 (last `VCMPV` at PC 0x10d11684 dur=53)
- The scalar unpack-store loop runs concurrently and dominates the late part of the timeline

**Performance implication:** this kernel is **store-bound**, not compute-bound. If the int8 output were instead packed (e.g. one bit per element, written 8 elements at a time as an int8 byte), the store cost would drop ~8×. As-is, Triton emitted byte-by-byte stores and they're the limiter.

### 5.6 What's NOT visible

- The other 117 instructions of the binary (`mask_kernel.npubin` is 740 B = 185 instr; we executed 624 unique PCs across multiple iterations of the same code, with a few unique to the loop body) — but the `TYPE==2` branch is invisible (we passed `TYPE=1`).
- Any instructions only reached when `M ≠ N`, or when the input shapes aren't 32-aligned.
- Any per-iteration variance — `msopgen sim` flattens the 1024-iteration loop into one event stream; you can see each iteration's `ts`/`dur` separately but reasoning about loop-iteration variance requires grouping events by PC and looking at the time-series of `dur` values.

To surface more code: run again with `TYPE=2`, `M=33` (mask-tail), `M=64`/`N=64` (different tile size). Union the executed PCs across runs.

## 6. Where to find everything

Server (192.168.25.218):
- `/home/Ray/triton_hello/helloworld_runner.py` — kernel + main wrapper
- `/home/Ray/triton_hello/mask_cache/<hash>/mask_kernel.{npubin,json,ttir,ttadapter}` — compiled artifacts
- `/home/Ray/triton_hello/camodel_run/mask_camodel.py` — camodel launcher
- `/home/Ray/triton_hello/camodel_run/run_mask.sh` — runner shell wrapper
- `/home/Ray/triton_hello/camodel_run/mask_dumps/` — per-core trace dumps (~8 MB total)
- `/home/Ray/triton_hello/camodel_run/mask_trace/dump2trace_core0.json` — Chrome-trace JSON (1.95 MB, 9459 events)

Local:
- `/tmp/mask_trace.json` — copy of the trace JSON

## 7. Wall-clock timing

| Stage | Time |
|---|---|
| Compile mask_kernel via Triton-Ascend on real device | ~5 sec |
| Camodel cycle-accurate sim of M=N=32 kernel | ~7 minutes |
| `msopgen sim` parse | <2 sec |
| Per-instruction Python analysis | <1 sec |

Camodel is the bottleneck. For larger M/N (e.g. 128×128 = 16K elements) expect 30+ minutes. For first-pass validation, **always start with the smallest input that exercises the code path you care about**.
