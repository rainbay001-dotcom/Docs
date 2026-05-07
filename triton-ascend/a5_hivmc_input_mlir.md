# Last MLIR before HIVMC for A5 — `mask_kernel` (bool vs cast)

This doc lists the **last transparent MLIR** that flows into `hivmc-a5` (the
A5-target HIVM Compiler) for the two `mask_fn` source variants, with the
**complete annotated MLIR** for each — every phase mapped back to the
original Triton-Python expression. After this layer, hivmc-a5 takes over
and the IR is no longer textual MLIR.

Companion docs:
- `helloworld_cast_vs_nocast_comparison.md` — full A5 vs 910B1 cast-vs-bool
  comparison (machine-code level, A5 §4.7; 910B1 §4.6 incl. §4.6.5
  hivmc-input diff).
- `mask_fn_compilation_stack.md` — full 7-stage walkthrough Python → ELF.

## 1. Capture method

Both captures were produced on GCP VM `cann9-test` (CANN 9.0.0,
x86_64-linux), using the `bishengir-compile-a5` driver.

`bishengir-compile-a5` internally invokes the binary
`/home/ray/Ascend/cann-9.0.0/x86_64-linux/bin/hivmc-a5` (a symlink). We
swapped that symlink to a wrapper script that copies the `.mlir` argument
out before `exec`-ing the real binary:

```bash
#!/bin/bash
LOG=/tmp/hivmc_a5_wrapper.log
echo "=== invoked $(date) ===" >> $LOG
echo "ARGS=$@" >> $LOG
DEST=${HIVMC_CAPTURE_DEST:-/tmp/hivmc_a5_captured.mlir}
for arg in "$@"; do
  if [[ "$arg" == *.mlir ]]; then
    cp "$arg" "$DEST" 2>>$LOG
    break
  fi
done
exec /home/ray/Ascend/cann-9.0.0/tools/bishengir/bin/hivmc-a5 "$@"
```

Driver invocations:

```bash
HIVMC_CAPTURE_DEST=/tmp/hivmc_a5_bool.mlir bishengir-compile-a5 \
  --enable-hivm-compile --enable-hfusion-compile \
  --mlir-elide-elementsattrs-if-larger=8 \
  -o mask_kernel_a5.o /home/ray/mask_kernel.ttadapter

HIVMC_CAPTURE_DEST=/tmp/hivmc_a5_cast.mlir bishengir-compile-a5 \
  --enable-hivm-compile --enable-hfusion-compile \
  --mlir-elide-elementsattrs-if-larger=8 \
  -o mask_kernel_cast_a5.o /home/ray/mask_kernel_cast.ttadapter
```

The driver passed each MLIR to hivmc-a5 as
`/tmp/bishengir-compile-XXXXXX/module.hivm.opt.mlir` — confirming that the
last transparent layer is the **post-`hivm-opt`** MLIR.

Captured artifacts (committed alongside this doc):
- `captures_hivmc_input_a5_bool.mlir` — 15,804 B, 146 lines
- `captures_hivmc_input_a5_cast.mlir` — 18,095 B, 172 lines

### 1.1 Note on target attribute

Both captures carry:

```mlir
hacc.target = #hacc.target<"Ascend910B1">, ARCH = "dav-c220"
```

The `.ttadapter` inputs were generated on 218 (CANN 8.5.0, target 910B1)
and re-used here as input to the A5 pipeline, so the target spec
propagated forward. The post-hivmc divergence (predicate registers vs
packed-bool with shuffle, RVECEX/RVECLD/RVECST vs M/V/S queues) happens
**inside** hivmc-a5 — i.e. the MLIR target attribute is **not** what
selects the A5 codegen; the binary path (`hivmc-a5`) is.

## 2. Triton source

`mask_fn` (TYPE=1, triu causal) — verbatim from `helloworld.py` and
`helloworld_cast.py`:

```python
# bool variant (helloworld.py)
@triton.jit
def mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE: tl.constexpr):
    if TYPE == 1:
        triu_causal = (q_offset[:, None] <= k_offset[None, :])           # A
        return(
            (triu_causal &                                                # E = A & D
            ((q_attn_arg[:, None] == k_attn_arg[None, :]) |               # B
            (k_attn_arg[None, :] == 0))) |                                # C ⇒ D = B | C
            (q_offset[:, None] == k_offset[None, :]))                     # F ⇒ result = E | F

# cast variant (helloworld_cast.py)
@triton.jit
def mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE: tl.constexpr):
    if TYPE == 1:
        triu_causal = (q_offset[:, None] <= k_offset[None, :]).to(tl.int32)
        return(
            (triu_causal &
            ((q_attn_arg[:, None] == k_attn_arg[None, :]).to(tl.int32) |
            (k_attn_arg[None, :] == 0).to(tl.int32))) |
            (q_offset[:, None] == k_offset[None, :]).to(tl.int32))
```

Tile shape: 32×32 (1024 elements). All four operand tensors are i32.
Result is i8.

Throughout the annotated MLIR below, we use the shorthand:
- **A** = `triu_causal = (q_offset[:, None] <= k_offset[None, :])`
- **B** = `(q_attn_arg[:, None] == k_attn_arg[None, :])`
- **C** = `(k_attn_arg[None, :] == 0)`
- **D** = `B | C`
- **E** = `A & D`
- **F** = `(q_offset[:, None] == k_offset[None, :])`
- **result** = `E | F`

## 3. Annotated bool variant — full MLIR

```mlir
// =====================================================================
// captures_hivmc_input_a5_bool.mlir  (146 lines, 15,804 B)
// =====================================================================
module attributes {
  dlti.target_system_spec = #dlti.target_system_spec<"NPU" : #hacc.target_device_spec<
    AI_CORE_COUNT=24, CUBE_CORE_COUNT=24, VECTOR_CORE_COUNT=48,
    UB_SIZE=1572864, L1_SIZE=4194304, L0A_SIZE=524288, L0B_SIZE=524288,
    L0C_SIZE=1048576, UB_ALIGN_SIZE=256, L1_ALIGN_SIZE=256, L0C_ALIGN_SIZE=4096,
    ARCH="dav-c220">>,
  hacc.target = #hacc.target<"Ascend910B1">,
  hivm.module_core_type = #hivm.module_core_type<AIV>
} {
  func.func @mask_kernel(
      %arg0: ... gm,    // SyncBlockLock workspace (unused in body)
      %arg1: ... gm,    // Workspace
      %arg2: i32 gm,    // q_attn_arg     (Triton: q_attn_arg)
      %arg3: i32 gm,    // k_attn_arg     (Triton: k_attn_arg)
      %arg4: i32 gm,    // q_offset       (Triton: q_offset)
      %arg5: i32 gm,    // k_offset       (Triton: k_offset)
      %arg6: i8  gm,    // result         (Triton return value, 32×32 i8)
      %arg7..%arg12: i32) attributes {... mix_mode="aiv" ...} {

    // ───── Constants & UB byte offsets (allocator output) ─────
    %c1, %c0, %c1024 = arith.constant 1, 0, 1024 : index
    %c47392_i64..%c0_i64 = arith.constant ... : i64       // 17 UB byte addresses
    %cst       = arith.constant 0.000000e+00 : f16
    %c1_i32    = arith.constant 1 : i32
    %c0_i32    = arith.constant 0 : i32

    // ─────────────────────────────────────────────────────────
    // Phase 1 — broadcast operand row/col scalars to 32×32 i32 tiles in UB.
    // These tiles are the inputs to the full-tile vcmp's of Phase 5.
    // ─────────────────────────────────────────────────────────

    // Triton:  q_offset[:, None]   →   32×32 tile at UB c0
    %0 = hivm.hir.pointer_cast(%c19232_i64) : 32x1xi32 ub        // q_offset row scalars
    %collapse_shape = collapse %0 → 32xi32                       // flat alias (used for i64 widen + DMA-load dst)
    %1 = hivm.hir.pointer_cast(%c0_i64)     : 32x32xi32 ub
    %2 = hivm.hir.pointer_cast(%c4096_i64)  : 256xi32 ub          // temp_buffer
    hivm.hir.vbrc ins(%0) outs(%1) temp_buffer(%2) broadcast_dims=[1]
        // ◄═══ q_offset[:, None]

    // Triton:  k_offset[None, :]   →   32×32 tile at UB c5120
    %3 = hivm.hir.pointer_cast(%c19360_i64) : 1x32xi32 ub
    %collapse_shape_0 = collapse %3 → 32xi32
    %4 = hivm.hir.pointer_cast(%c5120_i64)  : 32x32xi32 ub
    hivm.hir.vbrc ins(%3) outs(%4) broadcast_dims=[0]
        // ◄═══ k_offset[None, :]

    // Triton:  q_attn_arg[:, None] →   32×32 tile at UB c9216
    %5 = hivm.hir.pointer_cast(%c18976_i64) : 32x1xi32 ub
    %collapse_shape_1 = collapse %5 → 32xi32
    %6 = hivm.hir.pointer_cast(%c9216_i64)  : 32x32xi32 ub
    %7 = hivm.hir.pointer_cast(%c13312_i64) : 256xi32 ub
    hivm.hir.vbrc ins(%5) outs(%6) temp_buffer(%7) broadcast_dims=[1]
        // ◄═══ q_attn_arg[:, None]

    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID0>]    // V→MTE2 fence

    // Triton:  k_attn_arg[None, :] →   32×32 tile at UB c14336
    %8 = hivm.hir.pointer_cast(%c19104_i64) : 1x32xi32 ub
    %collapse_shape_2 = collapse %8 → 32xi32
    %9 = hivm.hir.pointer_cast(%c14336_i64) : 32x32xi32 ub
    hivm.hir.vbrc ins(%8) outs(%9) broadcast_dims=[0]
        // ◄═══ k_attn_arg[None, :]

    // ─────────────────────────────────────────────────────────
    // Phase 2 — i32 → i64 widening of q_offset / k_offset for the scalar
    // causal compare (Phase 8). The Scalar pipe needs i64.
    // ─────────────────────────────────────────────────────────
    %10 = hivm.hir.pointer_cast(%c18432_i64) : 32xi64 ub
    hivm.hir.vcast ins(%collapse_shape) outs(%10)            // q_offset i32→i64
    %11 = hivm.hir.pointer_cast(%c18688_i64) : 32xi64 ub
    hivm.hir.vcast ins(%collapse_shape_0) outs(%11)          // k_offset i32→i64

    // ─────────────────────────────────────────────────────────
    // Phase 3 — Triton:  C = (k_attn_arg[None, :] == 0)   per-row 32×i1
    // ─────────────────────────────────────────────────────────
    %12 = hivm.hir.pointer_cast(%c18944_i64) : 32xi1 ub
    hivm.hir.vcmp ins(%collapse_shape_2, %c0_i32) outs(%12)
        // ◄═══ C  (held as a 32-wide i1 row, broadcasted later)

    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID1>]

    // ─────────────────────────────────────────────────────────
    // Phase 4 — DMA-load operand tiles from gm into UB scratch buffers
    // (the same UB locations whose row/col scalar versions Phase 1 broadcasted).
    // ─────────────────────────────────────────────────────────
    %reinterpret_cast = reinterpret_cast %arg2 → 32xi32 gm
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID0>]
    hivm.hir.load ins(%reinterpret_cast) outs(%collapse_shape_1)   // q_attn_arg gm→ub

    %reinterpret_cast_3 = reinterpret_cast %arg3 → 1x32xi32 gm
    %collapse_shape_4   = collapse %reinterpret_cast_3 → 32xi32 gm
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE2>, <EVENT_ID1>]
    hivm.hir.load ins(%collapse_shape_4) outs(%collapse_shape_2)   // k_attn_arg gm→ub

    %reinterpret_cast_5 = reinterpret_cast %arg4 → 32xi32 gm
    hivm.hir.load ins(%reinterpret_cast_5) outs(%collapse_shape)   // q_offset gm→ub

    %reinterpret_cast_6 = reinterpret_cast %arg5 → 1x32xi32 gm
    %collapse_shape_7   = collapse %reinterpret_cast_6 → 32xi32 gm
    hivm.hir.load ins(%collapse_shape_7) outs(%collapse_shape_0)   // k_offset gm→ub

    %reinterpret_cast_8 = reinterpret_cast %arg6 → 32x32xi8 gm     // result tile gm view

    // ─────────────────────────────────────────────────────────
    // Phase 5 — full-tile vcmp's   F  and  B
    // ─────────────────────────────────────────────────────────
    %collapse_shape_9  = collapse %1 → 1024xi32       // q_offset[:,None] tile flat
    %collapse_shape_10 = collapse %4 → 1024xi32       // k_offset[None,:] tile flat
    %13 = hivm.hir.pointer_cast(%c0_i64)    : 1024xi1 ub      // alias over %1's slot
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%collapse_shape_9, %collapse_shape_10) outs(%13)   // default cmp = eq
        // ◄═══ F = (q_offset[:, None] == k_offset[None, :])

    %collapse_shape_11 = collapse %6 → 1024xi32       // q_attn[:,None] tile flat
    %collapse_shape_12 = collapse %9 → 1024xi32       // k_attn[None,:] tile flat
    %14 = hivm.hir.pointer_cast(%c9216_i64) : 1024xi1 ub      // alias over %6's slot
    hivm.hir.vcmp ins(%collapse_shape_11, %collapse_shape_12) outs(%14)
        // ◄═══ B = (q_attn_arg[:, None] == k_attn_arg[None, :])

    // ─────────────────────────────────────────────────────────
    // Phase 6 — i64-tile broadcast of q_offset / k_offset for the scalar causal loop.
    // ─────────────────────────────────────────────────────────
    %expand_shape    = expand %10 → 32x1xi64
    %15 = hivm.hir.pointer_cast(%c19488_i64) : 32x32xi64 ub
    %16 = hivm.hir.pointer_cast(%c27680_i64) : 0xi64 ub               // 0-byte temp
    hivm.hir.vbrc ins(%expand_shape) outs(%15) temp_buffer(%16) broadcast_dims=[1]
    %expand_shape_13 = expand %11 → 1x32xi64
    %17 = hivm.hir.pointer_cast(%c27680_i64) : 32x32xi64 ub
    hivm.hir.vbrc ins(%expand_shape_13) outs(%17) broadcast_dims=[0]
    hivm.hir.set_flag[<PIPE_V>, <PIPE_S>, <EVENT_ID0>]                // V→S fence

    // ─────────────────────────────────────────────────────────
    // Phase 7 — i1 → f16 trunc of C row scalars (for Phase 10 broadcast).
    // ─────────────────────────────────────────────────────────
    %18 = hivm.hir.pointer_cast(%c35872_i64) : 32xf16 ub      // C-as-f16
    %19 = hivm.hir.pointer_cast(%c35936_i64) : 48xf16 ub      // temp
    hivm.hir.vcast ins(%12) outs(%18) temp_buffer(%19) round_mode=<trunc>
        // (C: i1 → f16   — { false→0.0, true→1.0 })

    // ─────────────────────────────────────────────────────────
    // Phase 8 — scalar causal loop:   A = (q_offset[:,None] <= k_offset[None,:])
    // Stored as 1024×i8 in UB (1=true, 0=false). Why scalar-pipe?
    // — i64 sle isn't a vector op; the i32→i64 widen above set this up.
    // ─────────────────────────────────────────────────────────
    %collapse_shape_14 = collapse %15 → 1024xi64
    %collapse_shape_15 = collapse %17 → 1024xi64
    %20 = hivm.hir.pointer_cast(%c19488_i64) : 1024xi8 ub             // A bytes (alias over the i64 tile)
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_S>, <EVENT_ID0>]
    scf.for %arg13 = %c0 to %c1024 step %c1 {
      %34 = memref.load %collapse_shape_14[%arg13]                    // q_off[i] : i64
      %35 = memref.load %collapse_shape_15[%arg13]                    // k_off[i] : i64
      %36 = arith.cmpi sle, %34, %35                                  // A[i] : i1
      %37 = arith.extui %36 : i1 to i8
      memref.store %37, %20[%arg13]
    }
        // ◄═══ A = triu_causal stored as 1024×i8 at UB c19488
    hivm.hir.set_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]                // S→V fence

    // ─────────────────────────────────────────────────────────
    // Phase 9 — recover A as i1 (lift through f16 lane).
    //   i8 → f16 → vcmp(ne, 0.0) → i1
    // ─────────────────────────────────────────────────────────
    %21 = hivm.hir.pointer_cast(%c36032_i64) : 1024xf16 ub            // A-as-f16
    hivm.hir.wait_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%20) outs(%21)                                 // A: i8 → f16
    %22 = hivm.hir.pointer_cast(%c38080_i64) : 1024xf16 ub
    hivm.hir.vbrc  ins(%cst) outs(%22)                                // f16 0.0 tile
    %23 = hivm.hir.pointer_cast(%c36032_i64) : 1024xi1 ub             // alias
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%21, %22) outs(%23) compare_mode=<ne>
        // ◄═══ A as 1024×i1   (= A_f16 != 0.0)

    // ─────────────────────────────────────────────────────────
    // Phase 10 — broadcast C from the 32-wide row to the full 32×32 tile,
    // recover as i1. The double-vcmp+vnot is the canonicalizer's chosen
    // pattern (cf. §4.6.5 in helloworld_cast_vs_nocast_comparison.md).
    // ─────────────────────────────────────────────────────────
    %expand_shape_16 = expand %18 → 1x32xf16
    %24 = hivm.hir.pointer_cast(%c40128_i64) : 32x32xf16 ub
    hivm.hir.vbrc ins(%expand_shape_16) outs(%24) broadcast_dims=[0]   // C: 1×32 f16 → 32×32 f16
    %collapse_shape_17 = collapse %24 → 1024xf16
    %25 = hivm.hir.pointer_cast(%c40128_i64) : 1024xi1 ub              // alias
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%collapse_shape_17, %cst) outs(%25)              // (C_f16 == 0.0) → !C
    %26 = hivm.hir.pointer_cast(%c40128_i64) : 1024xi1 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vnot ins(%25) outs(%26)
        // ◄═══ C as 1024×i1 (broadcasted to full tile)

    // ─────────────────────────────────────────────────────────
    // Phase 11 — boolean algebra in i1   (D = B | C ; E = A & D ; result = E | F)
    // ─────────────────────────────────────────────────────────
    %27 = hivm.hir.pointer_cast(%c9216_i64)  : 1024xi1 ub              // overwrites B's slot
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vor ins(%14, %26) outs(%27)
        // ◄═══ D = B | C

    %28 = hivm.hir.pointer_cast(%c36032_i64) : 1024xi1 ub              // overwrites A's slot
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vand ins(%23, %27) outs(%28)
        // ◄═══ E = A & D

    %29 = hivm.hir.pointer_cast(%c0_i64)     : 1024xi1 ub              // overwrites F's slot
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vor ins(%28, %13) outs(%29)
        // ◄═══ result = E | F   (still as 1024×i1)

    // ─────────────────────────────────────────────────────────
    // Phase 12 — i1 → i32 → i8 narrowing for the i8 result tensor.
    //   bool path uses vsel(i1, 1, 0) (1 op), then vcast i32→i8.
    // ─────────────────────────────────────────────────────────
    %30 = hivm.hir.pointer_cast(%c42176_i64) : 1024xi32 ub
    %31 = hivm.hir.pointer_cast(%c46272_i64) : 24xi32 ub               // temp
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vsel ins(%29, %c1_i32, %c0_i32) outs(%30) temp_buffer(%31)
    %32 = hivm.hir.pointer_cast(%c46368_i64) : 1024xi8 ub
    %33 = hivm.hir.pointer_cast(%c47392_i64) : 2048xi32 ub             // temp
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%30) outs(%32) temp_buffer(%33) round_mode=<truncwithoverflow>
    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]              // V→MTE3 fence

    // ─────────────────────────────────────────────────────────
    // Phase 13 — DMA-store result (1024×i8) to gm.
    // ─────────────────────────────────────────────────────────
    %collapse_shape_18 = collapse %reinterpret_cast_8 → 1024xi8 gm
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]
    hivm.hir.store ins(%32) outs(%collapse_shape_18)
        // ◄═══ *result_ptr = result
    return
  }
}
```

**Bool variant — physical op count:**
3× `vbrc` (i32 tiles) + 1× `vbrc` (i32 tile, no temp) + 2× `vcast i32→i64`
+ 1× `vcmp i32` + 4× `hivm.hir.load` + 2× `vcmp 1024xi32` (B, F) + 2×
`vbrc i64` + 1× `vcast i1→f16` (C) + 1× `scf.for 0..1024` (A as i8) + 1×
`vcast i8→f16` (A→f16) + 1× `vbrc f16` + 1× `vcmp f16,f16,ne` (A as i1) +
1× `vbrc f16` (C tile) + 1× `vcmp f16,f16` + 1× `vnot` (C as i1) + 1×
`vor i1` (D) + 1× `vand i1` (E) + 1× `vor i1` (result) + 1× `vsel i1,i32`
+ 1× `vcast i32→i8` + 1× `hivm.hir.store`. Boolean algebra is **fully in
i1**.

## 4. Annotated cast variant — full MLIR

```mlir
// =====================================================================
// captures_hivmc_input_a5_cast.mlir  (172 lines, 18,095 B)
// =====================================================================
module attributes {... same dlti / hacc.target / module_core_type ...} {
  func.func @mask_kernel_cast(
      %arg0..%arg6: ... ,    // same signature as bool variant; arg6 still 1024×i8 result
      %arg7..%arg12: i32) attributes {... mix_mode="aiv" ...} {

    // ───── Constants & UB byte offsets (22 of them — 5 more than bool) ─────
    %c1, %c0, %c1024 = ...index
    %c61024_i64 .. %c0_i64 = ... : i64
    %cst   = arith.constant 0.000000e+00 : f16
    %cst_0 = arith.constant 0.000000e+00 : f32     // ★ NEW vs bool
    %c0_i32 = arith.constant 0 : i32               // (no %c1_i32 — vsel is gone)

    // ─────────────────────────────────────────────────────────
    // Phase 1 — broadcast operand row/col scalars to 32×32 tiles.
    // IDENTICAL to bool variant.
    // ─────────────────────────────────────────────────────────
    // ... same 4× vbrc i32 producing %1, %4, %6, %9
    //     (q_offset[:,None] tile, k_offset[None,:] tile,
    //      q_attn_arg[:,None] tile, k_attn_arg[None,:] tile)

    // ─────────────────────────────────────────────────────────
    // Phase 2 — i32 → i64 widen of q/k offsets   — same as bool
    // ─────────────────────────────────────────────────────────
    // %10 = i64 q_offset row,  %11 = i64 k_offset row

    // ─────────────────────────────────────────────────────────
    // Phase 3 — C = (k_attn_arg[None, :] == 0)   as 32×i1   — same as bool
    // ─────────────────────────────────────────────────────────
    %12 = hivm.hir.pointer_cast(%c18944_i64) : 32xi1 ub
    hivm.hir.vcmp ins(%collapse_shape_3, %c0_i32) outs(%12)
        // ◄═══ C  (as 32×i1)

    // ─────────────────────────────────────────────────────────
    // Phase 4 — DMA-load 4× operands from gm   — same as bool
    // ─────────────────────────────────────────────────────────
    // ... 4× hivm.hir.load

    // ─────────────────────────────────────────────────────────
    // Phase 5 — full-tile vcmp's   F  then  B   — same as bool, same result types
    // ─────────────────────────────────────────────────────────
    %13 = hivm.hir.pointer_cast(%c0_i64)    : 1024xi1 ub
    hivm.hir.vcmp ins(...q_off, k_off) outs(%13)            // ◄═══ F
    %14 = hivm.hir.pointer_cast(%c9216_i64) : 1024xi1 ub
    hivm.hir.vcmp ins(...q_attn, k_attn) outs(%14)          // ◄═══ B

    // ─────────────────────────────────────────────────────────
    // Phase 6 — i64-tile broadcast for causal scalar loop   — same as bool
    // ─────────────────────────────────────────────────────────

    // ═════════════════════════════════════════════════════════
    //  ★ DIVERGENCE STARTS HERE — `.to(tl.int32)` forces i1 → f16 → i32
    //  for every comparison, then boolean algebra runs as i32 bitwise.
    // ═════════════════════════════════════════════════════════

    // ─── Phase 7a — vcast i1 → f16 of   C, F, B   (3 sites) ───
    //   Note: this is just step 1 of 2 for `(...)→.to(int32)`.
    //   The bool variant only does this for C (single 32-wide row).

    %18 = hivm.hir.pointer_cast(%c35872_i64) : 32xf16 ub
    %19 = hivm.hir.pointer_cast(%c35936_i64) : 48xf16 ub
    hivm.hir.vcast ins(%12) outs(%18) temp_buffer(%19)              // C  (32×i1 → 32×f16)
        // (no round_mode = trunc here; the bool variant did emit one)

    %20 = hivm.hir.pointer_cast(%c36032_i64) : 1024xf16 ub
    %21 = hivm.hir.pointer_cast(%c38080_i64) : 48xf16 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%13) outs(%20) temp_buffer(%21)              // ★ F (1024×i1 → 1024×f16) — extra vs bool
                                                                     //   (Triton: (q_off==k_off).to(int32) step 1)

    %22 = hivm.hir.pointer_cast(%c38176_i64) : 1024xf16 ub
    %23 = hivm.hir.pointer_cast(%c40224_i64) : 48xf16 ub
    hivm.hir.vcast ins(%14) outs(%22) temp_buffer(%23)              // ★ B (1024×i1 → 1024×f16) — extra vs bool
                                                                     //   (Triton: (q_attn==k_attn).to(int32) step 1)

    // ─── Phase 8 — scalar causal loop   A = (q_off ≤ k_off)   ───
    //   IDENTICAL to bool — stores 1024×i8 at UB c19488 (=%24).
    %collapse_shape_15 = collapse %15 → 1024xi64
    %collapse_shape_16 = collapse %17 → 1024xi64
    %24 = hivm.hir.pointer_cast(%c19488_i64) : 1024xi8 ub
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_S>, <EVENT_ID0>]
    scf.for ... { cmpi sle i64; extui i1→i8; store }
        // ◄═══ A = triu_causal as 1024×i8

    hivm.hir.set_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]

    // ─── Phase 9a — recover A as i1   (same shape as bool Phase 9, no compare_mode arg differs)
    %25 = hivm.hir.pointer_cast(%c40320_i64) : 1024xf16 ub
    hivm.hir.wait_flag[<PIPE_S>, <PIPE_V>, <EVENT_ID0>]
    hivm.hir.vcast ins(%24) outs(%25)                                // A: i8 → f16
    %26 = hivm.hir.pointer_cast(%c42368_i64) : 1024xf16 ub
    hivm.hir.vbrc  ins(%cst) outs(%26)                               // f16(0.0) tile
    %27 = hivm.hir.pointer_cast(%c40320_i64) : 1024xi1 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%25, %26) outs(%27) compare_mode=<ne>
        // ◄═══ A as 1024×i1

    // ─── Phase 7b — vcast f16 → i32   (3 sites)   — STEP 2 of `.to(int32)` ───
    %28 = hivm.hir.pointer_cast(%c44416_i64) : 32xi32 ub
    hivm.hir.vcast ins(%18) outs(%28)                                // ★ C: 32xf16 → 32xi32
        // ◄═══ (k_attn==0).to(int32)   (32 wide)

    %29 = hivm.hir.pointer_cast(%c44544_i64) : 1024xi32 ub
    hivm.hir.vcast ins(%20) outs(%29)                                // ★ F: 1024xf16 → 1024xi32
        // ◄═══ (q_offset==k_offset).to(int32)   (1024 wide)

    %30 = hivm.hir.pointer_cast(%c48640_i64) : 32x32xi32 ub
    %collapse_shape_17 = collapse %30 → 1024xi32
    hivm.hir.vcast ins(%22) outs(%collapse_shape_17)                 // ★ B: 1024xf16 → 1024xi32 (32x32 tile)
        // ◄═══ (q_attn==k_attn).to(int32)

    // ─── Phase 7c — also widen A to i32 (via i1 → f16 → i32) ───
    %31 = hivm.hir.pointer_cast(%c52736_i64) : 1024xf16 ub
    %32 = hivm.hir.pointer_cast(%c54784_i64) : 48xf16 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%27) outs(%31) temp_buffer(%32)               // A: i1 → f16
    %expand_shape_18 = expand %28 → 1x32xi32                          // C-as-i32 reshape for broadcast OR
    %33 = hivm.hir.pointer_cast(%c54880_i64) : 1024xi32 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%31) outs(%33)                                // A: f16 → i32
        // ◄═══ A.to(int32)

    // ═════════════════════════════════════════════════════════
    // Phase 10 — boolean algebra is now BITWISE i32   (replaces bool's i1 algebra)
    // ═════════════════════════════════════════════════════════

    %34 = hivm.hir.pointer_cast(%c48640_i64) : 32x32xi32 ub
    hivm.hir.vor ins(%30, %expand_shape_18) outs(%34) broadcast=[0]
        // ◄═══ D = B.to(int32) | C.to(int32)   (broadcast OR: 32x32 ∨ 1x32)

    %collapse_shape_19 = collapse %34 → 1024xi32
    %35 = hivm.hir.pointer_cast(%c54880_i64) : 1024xi32 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vand ins(%33, %collapse_shape_19) outs(%35)
        // ◄═══ E = A.to(int32) & D

    %36 = hivm.hir.pointer_cast(%c44544_i64) : 1024xi32 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vor ins(%35, %29) outs(%36)
        // ◄═══ result_i32 = E | F.to(int32)

    // ─────────────────────────────────────────────────────────
    // Phase 11 — recover an i1 mask from the i32 result, then i1 → i8.
    //   path:    i32 → f32 → vcmp(eq, 0.0) → vnot → i1 → f16 → i8
    //   This is the cast variant's overhead vs bool's single vsel(i1,1,0).
    // ─────────────────────────────────────────────────────────
    %37 = hivm.hir.pointer_cast(%c44544_i64) : 1024xf32 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%36) outs(%37)                                // ★ result: i32 → f32
    %38 = hivm.hir.pointer_cast(%c44544_i64) : 1024xi1 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcmp ins(%37, %cst_0) outs(%38)                         // ★ (result_f32 == 0.0)  → !result
    %39 = hivm.hir.pointer_cast(%c44544_i64) : 1024xi1 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vnot ins(%38) outs(%39)
        // ◄═══ result as i1   (= (result_i32) != 0)

    %40 = hivm.hir.pointer_cast(%c58976_i64) : 1024xf16 ub
    %41 = hivm.hir.pointer_cast(%c61024_i64) : 48xf16 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%39) outs(%40) temp_buffer(%41)               // ★ i1 → f16
    %42 = hivm.hir.pointer_cast(%c58976_i64) : 1024xi8 ub
    hivm.hir.pipe_barrier[<PIPE_V>]
    hivm.hir.vcast ins(%40) outs(%42)                                // ★ f16 → i8
    hivm.hir.set_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]

    // ─────────────────────────────────────────────────────────
    // Phase 12 — DMA-store result (1024×i8) to gm   — same as bool
    // ─────────────────────────────────────────────────────────
    %collapse_shape_20 = collapse %reinterpret_cast_9 → 1024xi8 gm
    hivm.hir.wait_flag[<PIPE_V>, <PIPE_MTE3>, <EVENT_ID0>]
    hivm.hir.store ins(%42) outs(%collapse_shape_20)
        // ◄═══ *result_ptr = result
    return
  }
}
```

**Cast variant — extra ops vs bool** (each marked ★ above):
- 2× `vcast i1 → f16` for B and F (Phase 7a) — bool only widens C
- 3× `vcast f16 → i32` for B, C, F (Phase 7b) — bool has none
- 1× `vcast f16 → i32` for A (Phase 7c, after the existing i1→f16) — bool keeps A in i1
- `vcast i32 → f32` + `vcmp f32,0.0` + `vnot` (Phase 11) — bool uses `vsel(i1,1,0)` instead
- `vcast i1 → f16` + `vcast f16 → i8` (Phase 11 tail) — bool uses single `vcast i32 → i8`

Net: **+8 vector ops** vs the bool variant, all pure type-juggling.

## 5. Bool vs cast — structural diff

| Property | bool | cast |
|---|---|---|
| Lines of MLIR | 146 | 172 |
| Bytes | 15,804 | 18,095 |
| UB pointer-cast constants | 17 | 22 |
| Top-level boolean ops in i1 | 3 (vor, vand, vor) | 0 |
| Top-level boolean ops in i32 | 0 | 3 (vor-bcast, vand, vor) |
| Final-mask materialization | `vsel(i1, 1, 0) → vcast(i32→i8)` (2 ops) | `vcast(i32→f32) → vcmp(f32,0,ne) → vnot → vcast(i1→f16) → vcast(f16→i8)` (5 ops) |
| Per-compare widening to i32 | none | 2 vcasts each (`i1→f16`, `f16→i32`) × 3 sites = +6 |
| Constant pool | i32 1, i32 0 | f32 0.0 (no i32 1) |
| `vnot` count | 1 | 1 |
| Final store type | 1024×i8 | 1024×i8 |

The qualitative pattern matches the 910B1 hivmc-input diff documented in
`helloworld_cast_vs_nocast_comparison.md` §4.6.5: hivmc has not yet
discriminated between architectures at this layer. A5 vs 910B1 codegen
divergence (predicate registers vs packed-bool + shuffle, RVEC* pipes
vs M/V/S queues) happens entirely inside hivmc/hivmc-a5.

## 6. Why this layer is the right place to diff

`module.hivm.opt.mlir` is the post-`hivm-opt` form. By this point:
- All Triton-level abstractions (tensor element-type, broadcast
  semantics, masked load) have been lowered to memref + HIVM ops.
- UB allocation is fixed (the i64 constants are UB byte offsets — same
  layout will be passed straight to the codegen).
- Sync-flag insertion (`set_flag`/`wait_flag`) is already done.

After this layer, hivmc-a5 lowers each `hivm.hir.*` op into M/V/S queue
microcode (or RVEC* on A5) using internal pattern tables that are not
exposed as dump-able MLIR. Hence "the last transparent layer".

## 7. Reproducibility

Inputs and the wrapper are still in place on `cann9-test`. To
re-capture:

```bash
gcloud compute ssh cann9-test --zone=us-central1-a
source /home/ray/Ascend/cann-9.0.0/set_env.sh
HIVMC_CAPTURE_DEST=/tmp/hivmc_a5_bool.mlir bishengir-compile-a5 \
  --enable-hivm-compile --enable-hfusion-compile \
  --mlir-elide-elementsattrs-if-larger=8 \
  -o /tmp/mask.o /home/ray/mask_kernel.ttadapter
```

The wrapper logs each invocation to `/tmp/hivmc_a5_wrapper.log`.

To restore the original symlink (revert capture mode):

```bash
sudo ln -sf ../../tools/bishengir/bin/hivmc-a5 \
  /home/ray/Ascend/cann-9.0.0/x86_64-linux/bin/hivmc-a5
```

## 8. TL;DR

- Last transparent MLIR before A5 hivmc = `module.hivm.opt.mlir`,
  generated by `bishengir-compile-a5` and passed as the sole CLI
  argument to `hivmc-a5`.
- Captured for both variants by symlink-hijacking
  `/home/ray/Ascend/cann-9.0.0/x86_64-linux/bin/hivmc-a5`.
- Bool variant (146 L): boolean algebra in i1; one `i1→i32→i8`
  materialization at the end via `vsel`.
- Cast variant (172 L): boolean algebra in i32; six extra
  `i1↔f16↔i32` type-juggle vcasts; final `i32→f32→i1→f16→i8` chain.
- A5 vs 910B1 hivmc-input is essentially identical at this layer
  (same module attributes propagate from the `.ttadapter`); the
  divergence in machine-code semantics happens **inside** hivmc-a5
  (predicate registers, RVEC* pipes), not before it.
