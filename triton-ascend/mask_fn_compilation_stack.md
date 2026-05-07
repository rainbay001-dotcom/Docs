# The full Triton-Ascend compilation stack — `mask_fn` from Python to machine code

_Last updated: 2026-05-07._

End-to-end walk through every IR layer between Triton Python source and the final ELF binary, with concrete excerpts at each stage and the semantic transformations between adjacent layers. Uses the `mask_fn` helper from `helloworld.py` as the running example, with side-by-side endings for both 910_9362 (the silicon on 218) and Ascend950DT_9572 (A5).

This consolidates prior docs:
- [`triton_ascend_lowering.md`](triton_ascend_lowering.md) — pipeline at high level + 270-pass dump recipe
- [`disassembly_via_camodel.md`](disassembly_via_camodel.md) — how to recover machine-code mnemonics
- [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) — bool vs cast on 910B1 vs A5

---

## Pipeline at a glance

```
Python @triton.jit              ← user writes (helloworld.py / helloworld_cast.py)
    │
    ▼  Triton frontend (`@triton.jit` decorator → upstream Triton compiler passes)
TTIR (tt dialect)               ← cached as mask_kernel.ttir
    │
    ▼  Triton-Ascend TTAdapter pass
TTAdapter MLIR (linalg/tensor/  ← cached as mask_kernel.ttadapter
                memref/hacc)        (target-AGNOSTIC; this is where retargeting branches off)
    │
    ▼  bishengir-compile --target=<TARGET> (or bishengir-opt --lower-hfusion-pipeline)
HFusion MLIR (hfusion dialect)  ← visible only via --mlir-print-ir-after-all
    │                              (hardware-aware fused ops)
    ▼  bishengir-opt --optimize-hivm-pipeline (~70 passes inside)
HIVM MLIR (hivm dialect +       ← captured as module.hivm.opt.mlir via wrapper trick
           hacc annotations)        (post-buffer-planning, pre-machine-code)
    │
    ▼  hivmc (closed: HIVM → LLVM dialect → LLVM IR → machine code)
ELF .o / .npubin                ← final binary, 910_9362=2496B / A5=616B .text
                                   (decoder gated; only camodel can show mnemonics)
```

**Two boundaries are publicly observable** (cache files + camodel trace); **the in-between IR is reachable** via `bishengir-opt` with `--mlir-print-ir-after-all`; **hivmc is opaque** and only the input snapshot + final `.text` are recoverable.

---

## Stage 1 — Python `@triton.jit` source

**Tool:** the user's keyboard.
**Format:** Python source.
**File:** `helloworld.py`, `helloworld_cast.py`.

```python
@triton.jit
def mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE: tl.constexpr):
    if TYPE == 1:
        triu_causal = (q_offset[:, None] <= k_offset[None, :])
        return ((triu_causal & ((q_attn_arg[:, None] == k_attn_arg[None, :]) |
                                (k_attn_arg[None, :] == 0))) |
                (q_offset[:, None] == k_offset[None, :]))
```

What's notable at this layer:
- Tile-level operations on Triton's `[:, None]`-style broadcasts — pure tensor algebra
- `TYPE: tl.constexpr` — known at compile time, controls which branch survives lowering
- Casts (`.to(tl.int32)` in cast version) — type-system annotations for downstream

Triton's frontend captures the function's AST when `@triton.jit` is applied, then JIT-compiles on first call.

---

## Stage 2 — TTIR (Triton IR, `tt` dialect)

**Tool:** upstream Triton compiler frontend (`triton.compiler` Python-side passes — the same chain Triton uses for NVIDIA backends; the Triton-Ascend backend plugs in below this).
**Format:** MLIR with the `tt` (Triton) dialect.
**File:** `<cache>/<hash>/mask_kernel.ttir`.

Sample from real `mask_kernel.ttir` (truncated):

```mlir
module {
  tt.func public @mask_kernel(
      %arg0: !tt.ptr<i32> {tt.divisibility = 16 : i32},   // q_attn_ptr
      %arg1: !tt.ptr<i32> {tt.divisibility = 16 : i32},   // k_attn_ptr
      %arg2: !tt.ptr<i32> {tt.divisibility = 16 : i32},   // q_off_ptr
      %arg3: !tt.ptr<i32> {tt.divisibility = 16 : i32},   // k_off_ptr
      %arg4: !tt.ptr<i8>  {tt.divisibility = 16 : i32}) {  // out_ptr
    %cst   = arith.constant dense<0> : tensor<1x32xi32>
    %cst_0 = arith.constant dense<32> : tensor<32x1xi32>
    %cst_1 = arith.constant dense<0> : tensor<32x32xi32>
    %cst_2 = arith.constant dense<1> : tensor<32x32xi32>
    %0  = tt.make_range {end = 32, start = 0} : tensor<32xi32>
    %1  = tt.splat %arg2 : !tt.ptr<i32> -> tensor<32x!tt.ptr<i32>>
    %2  = tt.addptr %1, %0 : ...
    %3  = tt.load %2 : tensor<32x!tt.ptr<i32>>             // q_off
    ...
    %13 = tt.expand_dims %3 {axis = 1} : tensor<32xi32> -> tensor<32x1xi32>
    %14 = tt.expand_dims %6 {axis = 0} : tensor<32xi32> -> tensor<1x32xi32>
    %15 = tt.broadcast %13 : tensor<32x1xi32> -> tensor<32x32xi32>
    %16 = tt.broadcast %14 : tensor<1x32xi32> -> tensor<32x32xi32>
    %17 = arith.cmpi sle, %15, %16 : tensor<32x32xi32>     // A: q_off <= k_off
    ...
    %22 = arith.cmpi eq, %20, %21 : tensor<32x32xi32>      // B: q_attn == k_attn
    %23 = arith.cmpi eq, %19, %cst : tensor<1x32xi32>      // C: k_attn == 0
    %24 = tt.broadcast %23 : tensor<1x32xi1> -> tensor<32x32xi1>
    %25 = arith.ori %22, %24 : tensor<32x32xi1>            // B | C
    %26 = arith.andi %17, %25 : tensor<32x32xi1>           // A & (B | C)
    %27 = arith.cmpi eq, %15, %16 : tensor<32x32xi32>      // D: q_off == k_off
    %28 = arith.ori %26, %27 : tensor<32x32xi1>            // (A & (B|C)) | D
    %29 = arith.select %28, %cst_2, %cst_1 : tensor<32x32xi1>, tensor<32x32xi32>
    %30 = arith.trunci %29 : tensor<32x32xi32> to tensor<32x32xi8>  // → int8
    %31 = tt.expand_dims %0 {axis = 1} : tensor<32xi32> -> tensor<32x1xi32>
    %32 = arith.muli %31, %cst_0 : tensor<32x1xi32>
    ...
    tt.store %33, %30 : tensor<32x32x!tt.ptr<i8>>
  }
}
```

### Semantic mapping: Python → TTIR

| Python | TTIR |
|---|---|
| `tl.load(q_off_ptr + tl.arange(0, M))` | `tt.make_range` + `tt.splat` + `tt.addptr` + `tt.load` |
| `q_offset[:, None] <= k_offset[None, :]` | `tt.expand_dims` (axis=1, axis=0) + `tt.broadcast` + `arith.cmpi sle` |
| `q_attn == k_attn` | `arith.cmpi eq` |
| `k_attn == 0` | `arith.cmpi eq` against `arith.constant dense<0>` |
| `&`, `\|`, `\|` of bool tensors | `arith.andi`, `arith.ori` (on `i1` element types) |
| `tl.where(mask, 1, 0).to(tl.int8)` | `arith.select` (with `cst_2`/`cst_1` constants) + `arith.trunci` (`i32 → i8`) |
| `tl.store(out_ptr + ..., out)` | `tt.expand_dims` + `arith.muli` (offset compute) + `tt.addptr` + `tt.store` |

What's preserved from Python: tile shapes (32×32), the four logical comparisons, the bitwise combine structure, the int8 output type.

What's added at this layer: explicit pointer arithmetic (`tt.addptr`), explicit broadcasting (`tt.broadcast`), pointer types (`!tt.ptr<i32>`).

---

## Stage 3 — TTAdapter MLIR (linalg/tensor/memref/hacc)

**Tool:** Triton-Ascend backend's TTAdapter pass (Triton-Ascend specific).
**Format:** MLIR with `linalg`, `tensor`, `memref`, `hacc`, `arith`, `bufferization` dialects.
**File:** `<cache>/<hash>/mask_kernel.ttadapter`.

Sample (truncated):

```mlir
module {
  func.func @mask_kernel(
      %arg0: memref<?xi8>,                                            // sync_block_lock
      %arg1: memref<?xi8>,                                            // workspace
      %arg2: memref<?xi32> {tt.tensor_kind = 0},                      // q_attn (input)
      %arg3: memref<?xi32> {tt.tensor_kind = 0},                      // k_attn (input)
      %arg4: memref<?xi32> {tt.tensor_kind = 0},                      // q_off (input)
      %arg5: memref<?xi32> {tt.tensor_kind = 0},                      // k_off (input)
      %arg6: memref<?xi8>  {tt.tensor_kind = 1},                      // out (output)
      %arg7..%arg12: i32                                              // grid metadata
  ) attributes {
      SyncBlockLockArgIdx = 0,
      WorkspaceArgIdx = 1,
      global_kernel = "local",
      mix_mode = "aiv",                                                // ← AIV (not AIC)
      parallel_mode = "simd"
  } {
    %c1_i32 = arith.constant 1 : i32
    %c0_i32 = arith.constant 0 : i32

    // q_off, k_off, q_attn, k_attn loaded into UB via DMA copy
    %reinterpret_cast = memref.reinterpret_cast %arg4 ... : memref<?xi32> to memref<32xi32, strided<[1]>>
    %alloc = memref.alloc() : memref<32xi32>
    memref.copy %reinterpret_cast, %alloc : ...
    %5 = bufferization.to_tensor %alloc restrict writable : memref<32xi32>
    // [...same for k_off, q_attn, k_attn...]

    // Broadcast positions to 32×32 then compare
    %broadcasted   = linalg.broadcast ins(%5 : tensor<32xi32>) outs(...) dimensions = [1]
    %broadcasted_6 = linalg.broadcast ins(%6 : tensor<32xi32>) outs(...) dimensions = [0]
    %9 = arith.cmpi sle, %broadcasted, %broadcasted_6 : tensor<32x32xi32>   // A
    // [...similar for B, C, D...]
    %final = arith.ori %.., %.. : tensor<32x32xi1>
    %sel   = arith.select %final, %fill_one, %fill_zero
    %trunc = arith.trunci %sel : tensor<32x32xi32> to tensor<32x32xi8>
    // store via memref.copy back to %arg6
  }
}
```

### Semantic mapping: TTIR → TTAdapter

| TTIR | TTAdapter |
|---|---|
| `!tt.ptr<i32>` function args | `memref<?xi32>` with `hacc`-style attribute annotations |
| `tt.load %ptr` | `memref.reinterpret_cast` + `memref.alloc` + `memref.copy` (explicit DMA from GM to local) + `bufferization.to_tensor` |
| `tt.broadcast` | `linalg.broadcast` |
| `arith.cmpi`, `arith.andi`, `arith.ori`, `arith.select`, `arith.trunci` | unchanged (already MLIR standard ops) |
| `tt.store` | `memref.copy` back into the output `memref<?xi8>` |
| (implicit kernel surface) | `mix_mode = "aiv"`, `parallel_mode = "simd"`, `WorkspaceArgIdx`, `SyncBlockLockArgIdx` annotations on the function |

**Key transformations:**
- Pointer/tensor → memref + bufferization-to-tensor (explicit memory layer)
- DMA via `memref.copy` becomes visible (was implicit in `tt.load`)
- New args added: `sync_block_lock`, `workspace` (for HW-managed sync state)
- `mix_mode = "aiv"` decided at this stage — selects AIV-only path (vs AIC or mixed)

**Key target-agnosticism**: the TTAdapter file does NOT reference any specific Ascend chip. The `mix_mode` annotation is generic. This is why we could **retarget the SAME `mask_kernel.ttadapter` from 218 (compiled for 910_9362) to A5/Ascend950DT_9572** without re-running the Triton frontend.

---

## Stage 4 — HFusion MLIR (mid-pipeline, intermediate)

**Tool:** `bishengir-compile` internal (the `--lower-hfusion-pipeline` composite).
**Format:** MLIR with the `hfusion` dialect (HW-aware fused operations).
**Visibility:** intermediate; visible via `bishengir-opt --lower-hfusion-pipeline --mlir-print-ir-after-all` (~101 IR dumps).

The `hfusion` dialect represents the kernel as **fused regions** that map to HW execution units. The 4 logical compares + 3 bitwise combines from the source become a single fused `hfusion.fused_region` containing pattern-matched HW-recognizable ops.

### Semantic mapping: TTAdapter → HFusion

The 45 unique passes inside `--lower-hfusion-pipeline` (per `triton_ascend_lowering.md` §14.2):

| Pass class | What it does |
|---|---|
| `convert-linalg-to-hfusion` | `linalg.broadcast`/`linalg.fill`/etc. → `hfusion.broadcast`, `hfusion.fill` |
| `convert-tensor-to-hfusion` | `tensor.empty`/`extract_slice` → `hfusion.empty`, `hfusion.slice` |
| `convert-arith-to-hfusion` | `arith.cmpi`/`arith.andi`/`arith.ori` → `hfusion.compare`, `hfusion.bitwise` |
| `hfusion-fuse-ops` | merge producer-consumer ops into one fused region |
| `hfusion-decompose` | break high-level ops into HW-mapped tiles |
| `auto-schedule` | tiling, vectorization decisions from HW caps |
| `hfusion-cache-io` | mark inputs/outputs for DMA-hoisting |
| `bool-related: legalize-bool` (910B1 only) | map `i1` to `i8` for compatibility with HW-byte-addressable lanes |

Output: a fused region with annotations like `mix_mode = "aiv"`, `parallel_mode = "simd"`, tile sizes, fusion topology — but still target-agnostic in terms of specific instruction selection.

---

## Stage 5 — HIVM MLIR (post-`--optimize-hivm-pipeline`)

**Tool:** `bishengir-compile` internal (the `--optimize-hivm-pipeline` composite).
**Format:** MLIR with the `hivm` dialect (Huawei IR Vector/Matrix — closest to LLVM).
**File:** captured as `module.hivm.opt.mlir` via the hivmc-wrapper trick (see [`triton_ascend_lowering.md`](triton_ascend_lowering.md) §15.3).

This is the **boundary between compiler-visible MLIR and the closed hivmc stage**. Sample header (from our captured file):

```mlir
module attributes {
    dlti.target_system_spec = #dlti.target_system_spec<"NPU" :
        #hacc.target_device_spec<
            #dlti.dl_entry<"AI_CORE_COUNT", 20 : i32>,        // ← NOW target-specific
            #dlti.dl_entry<"CUBE_CORE_COUNT", 20 : i32>,
            #dlti.dl_entry<"VECTOR_CORE_COUNT", 40 : i32>,
            #dlti.dl_entry<"UB_SIZE", 1572864 : i32>,           // 1.5 MB
            #dlti.dl_entry<"L1_SIZE", 4194304 : i32>,           // 4 MB
            ...>>,
    hivm.module_core_type = #hivm.module_core_type<AIV>,
    memref.memref_as_ptr
} {
  func.func @mask_kernel_infer_task_type_function() -> i8 attributes {...}
  func.func @mask_kernel(... hivm-typed args ...) attributes {hacc.entry, ...} {
    // hivm.* ops here, with explicit memory scopes (#hivm.address_space<gm/ub/l1/...>)
    // hivm.copy, hivm.compute, hivm.subblock_lock, scf.forall mapped to NPU blocks
  }
}
```

### Semantic mapping: HFusion → HIVM

The ~70 unique passes inside `--optimize-hivm-pipeline`:

| Pass class | What it does |
|---|---|
| `convert-hfusion-to-hivm` | `hfusion.*` → `hivm.*` ops (mostly 1:1, with explicit memory scopes) |
| `infer-hivm-data-layout` | decide ND vs NZ layout per tensor |
| `infer-hivm-mem-scope` | assign each buffer to UB / L1 / L2 / GM |
| `mark-real-core-type` | annotate AIV vs AIC per op |
| `align-alloc-size` / `auto-infer-buffer-size` / `set-buffer-size` | buffer-size finalization |
| `enable-multi-buffer` / `mark-multi-buffer` | materialize ping-pong DMA |
| `inject-sync` / `inject-block-sync` | insert pipe-pair sync barriers between AIV/AIC and DMA |
| `tile-and-bind-sub-block` | tile to sub-blocks, bind to HW execution units |
| `map-forall-to-blocks` | map `scf.forall` to NPU block IDs |
| `plan-memory` | final lifetime-disjoint memory assignment |
| `one-shot-bufferize` | convert tensor-semantic to memref-semantic |
| `hivm-lower-to-loops` | expand `hivm.compute` to `scf.for` loops |

**Most important transition**: target-system spec injected. `dlti.target_system_spec` carries chip-specific values (AI_CORE_COUNT, UB_SIZE, etc.). For 910_9362: 20 AICs / 1.5 MB UB. For A5/9572: different values (we haven't dumped this for A5 yet).

---

## Stage 6 — Inside hivmc (HIVM → LLVM → machine code)

**Tool:** `hivmc` — closed binary, no external introspection.
**Format internally:** HIVM MLIR → LLVM dialect MLIR → LLVM IR → ELF machine code.
**File output:** `mask_kernel.npubin` (Triton convention) or `mask_kernel.o` (raw bishengir-compile output).

We can't see what hivmc does inside. What we know:
- Input: `module.hivm.opt.mlir` (we captured this)
- Output: ELF64 with `e_machine = 0x1029` ("hiipu")
- Internal pipeline references include `convert-hivm-to-llvm`, `convert-hir-to-lir`, machine-code generation (LLVM backend)
- Target-specific lowering happens HERE — instruction selection, register allocation, scheduling

The `--target=Ascend910_9362` vs `--target=Ascend950DT_9572` flag passed to `bishengir-compile` propagates through `bishengir-opt`'s pipelines into hivmc, where it controls the LLVM backend's instruction selection table — which is why we get different machine code for the same `.ttadapter` input.

---

## Stage 7 — Machine code (ELF .text)

**Tool:** hivmc emits, BiSheng `llvm-objdump` would disassemble (gated).
**Format:** ELF64, `machine = 0x1029`, hiipu64 instructions.
**File:** `mask_kernel.npubin` / `mask_kernel_a5.o`.
**Sizes:**
- 910_9362: `.text` = 2,496 bytes (~624 instructions)
- A5/9572: `.text` = 616 bytes (~154 instructions)
**Visibility:** `readelf` shows section structure; mnemonic disassembly only via camodel + `msopgen sim`.

### Semantic mapping: HIVM → machine code (target-specific, divergent here)

#### 910_9362 emits:

For the same `mask_fn` body:
- 4 logical compares → `VCMPV` (3× S32) + `VCMPVS` (1× F16) + `VCMPV F16` (positions are cast to F16 by the lowering)
- 3 bitwise combines → `VOR`/`VAND` with `Dtype:B16` (treat-as-packed-bools)
- Output store → `VSEL F32` + `VNCHWCONV B8` × 8 (format conversion) + `ST_XD_XN_IMM` × 1024 (one byte at a time)
- Plus `MOVEMASK` × 84, `MOVEVA` × 64, `VNCHWCONV` × 8 (~156 layout-shuffle ops, no analog on A5)

See [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.6 for the full PC-by-PC mapping.

#### A5/9572 emits:

For the same `mask_fn` body:
- 4 logical compares → `RV_VCMP_LE` + `RV_VCMP_EQ` × 3 (predicate-result vector compares)
- 3 bitwise combines → `RV_PAND`, `RV_POR` × 2 (predicate-class bitwise)
- Output store → `RV_VSEL` + `RV_VCVT_I2I` + **`RV_VSTI` × 32** (32-byte vector stores, total covers same 1024 bytes)
- 1024-iteration scalar loop disappears entirely — replaced by 1× `RV_VLOOP` + per-iteration vector ops

See [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.7.3.8 for the A5 PC-by-PC mapping.

---

## Stage-by-stage observability summary

| Stage | Format | Cache file? | `bishengir-opt` dumpable? | Notes |
|---|---|---|---|---|
| 1 Python source | `.py` | n/a | n/a | What you write |
| 2 TTIR | `.ttir` (MLIR) | ✅ `<cache>/<hash>/mask_kernel.ttir` | n/a | Triton frontend output |
| 3 TTAdapter | `.ttadapter` (MLIR) | ✅ `<cache>/<hash>/mask_kernel.ttadapter` | n/a | Target-AGNOSTIC; the retargeting input |
| 4 HFusion (intermediate) | MLIR (in-memory) | ❌ | ✅ via `--lower-hfusion-pipeline --mlir-print-ir-after-all` | ~45 unique passes, ~101 dumps |
| 5 HIVM (post-optimize) | MLIR (in-memory) | ❌ | ✅ via `--optimize-hivm-pipeline --mlir-print-ir-after-all` | ~70 unique passes, ~116 dumps |
| 5b HIVM-opt snapshot | `module.hivm.opt.mlir` | ✅ via hivmc-wrapper trick | n/a | Bookend before hivmc |
| 6 LLVM dialect → LLVM IR (hivmc internal) | MLIR/LLVM IR | ❌ | ❌ | Closed; only inputs/outputs visible |
| 7 ELF .text | ELF64 | ✅ `<cache>/<hash>/mask_kernel.npubin` | n/a | Decoder gated; camodel + `msopgen sim` recovers mnemonics |

---

## Key insight — where target-specificity enters

The compilation stack has a **clear separation** between target-agnostic and target-specific stages:

| Stages | Target-aware? |
|---|---|
| 1 Python | ❌ (kernel source is generic) |
| 2 TTIR | ❌ (Triton-level abstraction) |
| 3 TTAdapter | ❌ (annotated with mix_mode + sync args, but no chip-specific values) |
| 4 HFusion | partially (auto-schedule consults HW caps) |
| 5 HIVM | ✅ (target spec injected: AI_CORE_COUNT, UB_SIZE, etc.) |
| 6 hivmc internal | ✅ (instruction selection per target) |
| 7 Machine code | ✅ (different ISA per chip) |

**Practical implication**: a single `mask_kernel.ttadapter` cached on 218 (originally compiled for 910_9362) can be retargeted to A5 by re-running just stages 4–7 via `bishengir-compile --target=Ascend950DT_9572 mask_kernel.ttadapter`. We did exactly this, and the result was a 75%-smaller A5 binary running ~19× faster.

---

## What this stack lets you reason about

| Question | Answer |
|---|---|
| "Where does the bool-vs-cast decision matter?" | Stage 1 (source) and Stage 3 (TTAdapter has different `arith.trunci` shapes). Below stage 4, on A5 the difference disappears (§4.7.3.6); on 910B1 it persists into stage 7's mnemonic mix (§4.5.2) |
| "Where does target architecture matter?" | Stages 5–7. Stages 1–3 are 100% portable across Ascend chip generations |
| "Where is the perf bottleneck?" | Stage 7's instruction selection. On 910_9362, the choice to emit 1024 scalar `ST_XD_XN_IMM` (vs A5's 32 `RV_VSTI`) is the entire ~19× cycle gap |
| "Why doesn't `.to(tl.int32)` help on A5?" | Stages 5–7 on A5 see through the cast — both source forms funnel through identical predicate-based hivm patterns. The cast survives at stage 3 (different `arith.trunci`) but stages 4+ converge |
| "What's the minimum repro for trying a new target?" | Run stages 1–3 on any Ascend host, copy the `.ttadapter` to a host with the new target's CANN, run stages 4–7 there |

---

## References

- [`triton_ascend_lowering.md`](triton_ascend_lowering.md) — full pipeline doc with §14.2 listing all 104 unique passes
- [`disassembly_via_camodel.md`](disassembly_via_camodel.md) — how to recover machine-code mnemonics
- [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) — bool vs cast on 910B1 vs A5 with PC-by-PC source-to-asm mapping (§4.6 for 910B1, §4.7.3.8 for A5)
- [`cann_900_simulator_coverage.md`](cann_900_simulator_coverage.md) — CANN 9.0.0 install + A5 simulator
- [`ascend_cycle_profiling.md`](ascend_cycle_profiling.md) — msprof and camodel infrastructure

Source artifacts:
- 218: `/home/Ray/triton_hello/mask_cache/<hash>/mask_kernel.{ttir,ttadapter,npubin,json}`
- 218: `/home/Ray/triton_hello/bishengir_dump/llvm_dump/captured_input.mlir` (HIVM-opt snapshot)
- GCP cann9-test VM: `/home/ray/a5_compile/mask_kernel_a5.o` (A5 compiled binary)
- GCP cann9-test VM: `/home/ray/a5_compile/a5_dumps/`, `a5_trace/dump2trace_core0.json` (A5 camodel trace)
