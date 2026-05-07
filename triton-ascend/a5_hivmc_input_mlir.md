# Last MLIR before HIVMC for A5 — `mask_kernel` (bool vs cast)

This doc lists the **last transparent MLIR** that flows into `hivmc-a5` (the
A5-target HIVM Compiler) for the two `mask_fn` source variants, and maps each
HIVM op back to the original Triton-Python source. After this layer, hivmc-a5
takes over and the IR is no longer textual MLIR.

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
last transparent layer is the **post-`hivm-opt`** MLIR, just as it is for
the 910B1 path.

Captured artifacts (also committed alongside this doc):
- `captures_hivmc_input_a5_bool.mlir` — 15,804 B, 146 lines
- `captures_hivmc_input_a5_cast.mlir` — 18,095 B, 172 lines

### 1.1 Note on target attribute

Both captures carry:

```mlir
hacc.target = #hacc.target<"Ascend910B1">
... ARCH = "dav-c220" ...
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
        triu_causal = (q_offset[:, None] <= k_offset[None, :])
        return(
            (triu_causal &
            ((q_attn_arg[:, None] == k_attn_arg[None, :]) |
            (k_attn_arg[None, :] == 0))) |
            (q_offset[:, None] == k_offset[None, :]))

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
Result is i8 for bool, i8 (downcast from i32) for cast.

## 3. Mapping — bool variant (146 lines)

The bool path keeps every comparison result as native `i1` (1-bit
predicate) and combines them with `i1`-typed `vand`/`vor`/`vnot`. A
single `i1→i8` materialization at the very end produces the byte mask
to store. The op sequence below corresponds to the high-level Triton
expression in the order they appear in the captured MLIR.

| Capture line | HIVM op | Maps to Triton expression |
|---|---|---|
| 33–37 | `vbrc 32x1xi32 → 32x32xi32` (UB c19232 → c0) | `q_offset[:, None]` broadcast (LHS of `<=`) |
| 38–41 | `vbrc 1x32xi32 → 32x32xi32` (UB c19360 → c5120) | `k_offset[None, :]` broadcast (RHS of `<=`) |
| 42–46 | `vbrc 32x1xi32 → 32x32xi32` (UB c18976 → c9216) | `q_attn_arg[:, None]` broadcast (LHS of `==`) |
| 48–51 | `vbrc 1x32xi32 → 32x32xi32` (UB c19104 → c14336) | `k_attn_arg[None, :]` broadcast (RHS of inner `==`) |
| 52–53 | `vcast i32→i64` on `q_offset` row scalars | i32→i64 widening before per-element causal cmp loop (lines 96–102) |
| 54–55 | `vcast i32→i64` on `k_offset` row scalars | i32→i64 widening, same |
| 56–57 | `vcmp i32,0 → 32xi1` (`%12`) | `(k_attn_arg[None, :] == 0)` along the row (32-elem result) |
| 59–70 | `hivm.hir.load` ×4 (gm→ub) | DMA-in for `q_attn_arg`, `k_attn_arg`, `q_offset`, `k_offset` |
| 71 | `reinterpret_cast %arg6 → 32x32xi8 gm` | result tensor view |
| 72–76 | `vcmp 1024xi32,1024xi32 → 1024xi1` (`%13`) | `q_attn_arg[:, None] == k_attn_arg[None, :]` (full tile) |
| 77–80 | `vcmp 1024xi32,1024xi32 → 1024xi1` (`%14`) | `q_offset[:, None] == k_offset[None, :]` (full tile, equality) |
| 81–87 | `expand_shape` + `vbrc i64` for both q_off and k_off i64 broadcast | broadcast i64 versions for the causal loop |
| 89–91 | `vcast 32xi1→32xf16` + temp_buffer (`%18`, round_mode=trunc) | per-row materialization of `(k_attn[None,:] == 0)` for later broadcast — **f16 is just intermediate** |
| 92–102 | `scf.for 0..1024 step 1 { cmpi sle i64,i64; extui i1→i8; store }` (writes i8 at UB `c19488`, `%20`) | scalar fallback for `(q_offset[:, None] <= k_offset[None, :])` — **`triu_causal`** stored as i8 packed in UB |
| 104–107 | `vcast 1024xi8→1024xf16` (`%21`) | hoist `triu_causal` from i8 packing back into f16 lane for vector-pipe path |
| 108–109 | `vbrc f16 0.0 → 1024xf16` (`%22`) | broadcast f16 zero (constant for `triu_causal != 0`) |
| 111–112 | `vcmp 1024xf16,1024xf16 (ne) → 1024xi1` (`%23`) | rematerialize `triu_causal != 0` as i1 — i.e. recover `triu_causal` as boolean |
| 113–115 | `expand_shape 32xf16` + `vbrc 1x32xf16 → 32x32xf16` (`%24`) of `%18` | broadcast `(k_attn[None, :] == 0)` to full tile (still f16) |
| 116–119 | `vcmp 1024xf16,f16(0.0) → 1024xi1` (`%25`) | recover the broadcasted `(k_attn[None, :] == 0)` as i1 |
| 120–122 | `vnot i1 → i1` (`%26`) | **NB:** the canonicalizer recasts the original disjunction; this is the masking polarity bit-flip preceding the inner OR (see line 125) |
| 123–125 | `vor 1024xi1, 1024xi1 → 1024xi1` (`%27`) | `(q_attn==k_attn) | (k_attn==0)` — but with the polarity inverted relative to source (matches §4.6.5 finding for 910B1) |
| 126–128 | `vand 1024xi1, 1024xi1 → 1024xi1` (`%28`) | `triu_causal & (...)` |
| 129–131 | `vor 1024xi1, 1024xi1 → 1024xi1` (`%29`) | `(triu_causal & (...)) | (q_off==k_off)` — top-level OR |
| 132–135 | `vsel i1, 1, 0 → 1024xi32` (`%30`) | i1 → i32 widening (1 if true, 0 if false) |
| 136–139 | `vcast 1024xi32 → 1024xi8` truncwithoverflow (`%32`) | i32 → i8 narrowing for the i8 result |
| 141–143 | `hivm.hir.store 1024xi8 → gm` (collapse_shape of arg6) | DMA-out result tensor |

**Bool-variant summary:** comparisons stay in i1 land. The only
materialization through f16 is to round-trip the `(k_attn == 0)` row
and the `triu_causal` byte buffer through the f16 broadcast lane —
the AIV vector pipe wants typed memrefs, and i1 broadcasts go via f16
on dav-c220 (this is *not* the same as the cast variant's i32 round
trip). The inner Boolean algebra is `vand`/`vor`/`vnot` directly on
i1.

## 4. Mapping — cast variant (172 lines)

The `.to(tl.int32)` annotation on every comparison forces every i1
intermediate to be widened to i32 immediately. The Boolean algebra
(`&`/`|`) is then done as bitwise i32 ops, and the final result
narrows i32 → i8. The main consequences vs. the bool variant:

1. **Each compare grows two extra `vcast` ops**: `i1 → f16 → i32`.
   AIV doesn't have a direct i1→i32 path on dav-c220, so it goes
   through f16 lane.
2. **Bitwise on i32**: `vor i32` and `vand i32` instead of `vor i1`,
   `vand i1`. Larger throughput requirement (32 b vs 1 b lanes).
3. **One extra `vcast i32 → f32` + `vcmp f32, 0.0 → i1` + `vnot i1`
   trip**: required to go back from the i32 algebra into an i1 mask
   before the final i8 narrowing.
4. **Two extra constants** (`%cst_0 = 0.0 : f32` shows up; bool
   variant uses `%c1_i32`+`%c0_i32` pair instead).

| Capture line | HIVM op | Maps to Triton expression |
|---|---|---|
| 40–48 | `vbrc` ×2 (q_off, k_off scalar broadcasts) | same as bool |
| 49–53 | `vbrc` (q_attn broadcast) | same as bool |
| 55–58 | `vbrc` (k_attn broadcast) | same as bool |
| 59–62 | `vcast i32→i64` ×2 | same as bool |
| 63–64 | `vcmp i32,0 → 32xi1` (`%12`) | `(k_attn[None,:] == 0)` |
| 66–77 | `hivm.hir.load` ×4 | DMA-in operands, same as bool |
| 78–87 | `vcmp 1024xi32,1024xi32 → 1024xi1` ×2 (`%13`, `%14`) | `(q_attn==k_attn)` and `(q_off==k_off)` |
| 88–94 | `expand`+`vbrc i64` for causal broadcast | same as bool |
| 96–98 | `vcast 32xi1→32xf16` (`%18`) | `(k_attn==0).to(int32)` step 1 of 2 |
| 99–102 | `vcast 1024xi1→1024xf16` (`%20`) of `%13` (q_attn==k_attn) | `(q_attn==k_attn).to(int32)` step 1 of 2 |
| 103–105 | `vcast 1024xi1→1024xf16` (`%22`) of `%14` (q_off==k_off) | `(q_off==k_off).to(int32)` step 1 of 2 |
| 106–116 | scalar `scf.for` causal loop → packed i8 at `%24` (UB c19488) | `triu_causal = (q_off[:,None] <= k_off[None,:]).to(int32)` byte form |
| 117–120 | `vcast 1024xi8→1024xf16` (`%25`) | hoist `triu_causal` to vector lane |
| 121–122 | `vbrc f16 0.0 → 1024xf16` (`%26`) | constant for the `triu_causal != 0` recovery |
| 124–125 | `vcmp 1024xf16,1024xf16 (ne) → 1024xi1` (`%27`) | recover `triu_causal` as i1 (only inside the loop's polarity machinery; the cast path does *not* keep it as i32) |
| 126–127 | **`vcast 32xf16→32xi32`** (`%28`) | `.to(tl.int32)` on `(k_attn==0)` (final step from f16→i32) |
| 128–129 | **`vcast 1024xf16→1024xi32`** (`%29`) | `.to(tl.int32)` on `(q_attn==k_attn)` (final step) |
| 130–132 | `collapse_shape` + `vcast 1024xf16→1024xi32` (`%collapse_shape_17`) | `.to(tl.int32)` on `(q_off==k_off)` (final step) |
| 133–136 | `vcast 1024xi1→1024xf16` (`%31`) of `%27` | re-widening of the `triu_causal != 0` result for the next vcast (see line 140) |
| 137–138 | `expand_shape 32xi32 → 1x32xi32` of `%28` | reshape `(k_attn==0).to(int32)` for broadcast OR |
| 140 | `vcast 1024xf16→1024xi32` (`%33`) of `%31` | finish recovering `triu_causal` as i32 |
| 141–142 | **`vor 32x32xi32, 1x32xi32 → 32x32xi32` broadcast=[0]** (`%34`) | `(q_attn==k_attn).to(int32)) | (k_attn==0).to(int32))` — broadcast OR of cast (k_attn==0) row across the tile |
| 143–146 | **`vand 1024xi32, 1024xi32 → 1024xi32`** (`%35`) | `triu_causal & (...)` — bitwise AND on i32 |
| 147–149 | **`vor 1024xi32, 1024xi32 → 1024xi32`** (`%36`) | `(triu_causal & ...) | (q_off==k_off).to(int32)` — top-level OR on i32 |
| 150–152 | **`vcast 1024xi32 → 1024xf32`** (`%37`) | i32 → f32 (preparing the final i32 → i1 conversion via f32 != 0) |
| 153–155 | **`vcmp 1024xf32, f32(0.0) → 1024xi1`** (`%38`) | f32 → i1 mask: `result != 0` |
| 156–158 | `vnot i1 → i1` (`%39`) | polarity flip (matches the canonical pattern, same role as bool variant line 122) |
| 159–162 | `vcast 1024xi1→1024xf16` (`%40`) | i1 → f16 (step 1 of 2 for i1→i8) |
| 163–165 | `vcast 1024xf16→1024xi8` (`%42`) | f16 → i8 (step 2 of 2) |
| 167–169 | `hivm.hir.store 1024xi8 → gm` | DMA-out result tensor |

**Cast-variant summary:** the cast path inserts **6 extra vector ops**
that are pure type-juggling: 3 `i1→f16→i32` widenings (one per
`.to(int32)` site) and an `i32→f32→i1→f16` round-trip to recover an i1
mask for the final byte narrowing. None of these ops change the value;
they only change the storage type. This is exactly why the A5 cast
variant takes ≈the same cycles as the bool variant despite spending
more lines of MLIR — the extra ops are AIV vector ops which retire 1
per VECTOR cycle on A5 (see `helloworld_cast_vs_nocast_comparison.md`
§4.7).

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
| Final store type | 1024xi8 | 1024xi8 |

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
- Bool variant (146 L): boolean algebra in i1; one i1→i32→i8
  materialization at the end via `vsel`.
- Cast variant (172 L): boolean algebra in i32; six extra
  `i1↔f16↔i32` type-juggle vcasts; final i32→f32→i1→f16→i8 chain.
- A5 vs 910B1 hivmc-input is essentially identical at this layer
  (same module attributes propagate from the `.ttadapter`); the
  divergence in machine-code semantics happens **inside** hivmc-a5
  (predicate registers, RVEC* pipes), not before it.
