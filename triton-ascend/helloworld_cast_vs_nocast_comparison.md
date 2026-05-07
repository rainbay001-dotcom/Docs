# Triton-Ascend lowering: bool vs i32 mask kernel comparison

_Last updated: 2026-05-07._

What changes when you add `.to(tl.int32)` to every comparison in a Triton mask kernel? Side-by-side cycle-accurate camodel runs of [`helloworld.py`](https://github.com/...) (bool path) and [`helloworld_cast.py`](https://github.com/...) (i32-cast path) on the same 32×32 input.

Companions:
- [`helloworld_mask_camodel_walkthrough.md`](helloworld_mask_camodel_walkthrough.md) — the bool kernel's full per-instruction analysis
- [`disassembly_via_camodel.md`](disassembly_via_camodel.md) — the trace-reading methodology

---

## 1. The two kernels

Both compute the same 2-D causal-with-attention mask. They differ only in whether the intermediate boolean tensors are explicitly cast to `int32` before the bitwise `&` / `|` ops.

**`helloworld.py`** — bool path:
```python
triu_causal = (q_offset[:, None] <= k_offset[None, :])      # i1 (bool)
return ((triu_causal & ((q_attn == k_attn) | (k_attn == 0))) | (q_off == k_off))
```

**`helloworld_cast.py`** — i32-cast path:
```python
triu_causal = (q_offset[:, None] <= k_offset[None, :]).to(tl.int32)  # i32 (4 bytes)
return ((triu_causal & ((q_attn == k_attn).to(tl.int32) | (k_attn == 0).to(tl.int32))) | (q_off == k_off).to(tl.int32))
```

Wrapped in identical `mask_kernel` launchers (32×32 int8 output) and run under camodel with the same inputs.

## 2. Headline numbers

| Metric | bool (no-cast) | i32 (cast) | Δ |
|---|---|---|---|
| Camodel `Total tick` | 28,573 | 28,937 | **+364 (+1.3%)** |
| Trace event count | 9,459 | 9,364 | -95 (-1.0%) |
| **Unique PCs (static code surface)** | **624** | **529** | **-95 (-15.2%)** |
| Cycle span (start → end) | 27,645 | 27,995 | +350 (+1.3%) |
| Static `.text` size | 2,496 B | 2,116 B | -380 B (-15.2%) |

**Surprising headline**: the cast version is a **smaller binary (-15%)** but runs **slightly slower (+1.3%)**. The two effects are uncorrelated — fewer instructions in the binary doesn't translate to fewer cycles in execution.

## 3. Per-pipeline breakdown

| Pipe | bool cyc | i32 cyc | Δ | bool n | i32 n |
|---|---|---|---|---|---|
| SCALAR | 70,590 | 71,608 | **+1,018** | 8,035 | 7,983 |
| VECTOR | 8,647 | 8,383 | -264 | 348 | 305 |
| MTE2 (DMA load) | 3,658 | 3,656 | -2 | 13 | 13 |
| MTE3 (DMA store) | 219 | 172 | -47 | 2 | 2 |
| FLOWCTRL | 1,065 | 1,065 | 0 | 1,060 | 1,060 |
| ALL (full barrier) | 214 | 172 | -42 | 1 | 1 |

Read-out:

- **VECTOR pipe gets cheaper** with the cast (-264 cyc, -43 instructions). Fewer vector ops needed because i32 is the natural width for the Ascend AICore vector ALU.
- **SCALAR pipe gets more expensive** (+1,018 cyc) — the cost saved on VECTOR is eaten by added scalar-pipe work (more sync, more bit shuffling).
- **DMA pipes (MTE2/MTE3) are unchanged** — same memory traffic to/from GM regardless of intermediate type.
- **FLOWCTRL identical** — same loop structure (1024-iteration unpack-store loop is the dominant control flow in both).

## 4. Mnemonic-level diffs (sorted by |Δ cycles|)

| Mnemonic | bool n | bool cyc | i32 n | i32 cyc | Δ cyc | Why |
|---|---|---|---|---|---|---|
| `VNCHWCONV` | 8 | 828 | 0 | 0 | **-828** | Vector NCHW format conversion — needed only for bool packing. **Cast version eliminates entirely.** |
| `LDP_XI_XJ_XN` | 2 | 12 | 2 | 722 | +710 | Same instruction count; cache-miss timing differs (artifact, not work change) |
| `WAIT_FLAG` | 75 | 1,405 | 81 | 2,014 | +609 | i32 path needs more pipe-pair sync handshakes (wider data, more stage transitions) |
| `MOVEVA` | 64 | 448 | 0 | 0 | **-448** | Vector arithmetic move — used by bool path's bit-packing. **Cast version eliminates entirely.** |
| `MOVEMASK` | 84 | 1,544 | 96 | 1,847 | +303 | More mask-register manipulation in the i32 path |
| `BAR` | 24 | 2,435 | 27 | 2,728 | +293 | Slightly more pipe barriers (3 extra) |
| `ST_XD_XN_IMM` | 1,026 | 33,029 | 1,025 | 32,740 | -289 | Same 1024 byte-stores; tiny variance |
| `MOV_XD_IMM` | 186 | 372 | 92 | 184 | -188 | Bit-pattern building (e.g. `0x5555_5555…`) is gone in cast version — no per-bit packing needed |
| `SET_FLAG` | 75 | 2,504 | 81 | 2,628 | +124 | Pairs with the WAIT_FLAG increase |
| `VSEL` | 2 | 51 | 5 | 155 | +104 | More vector-select ops in the i32 path |
| `VOR` | 2 | 35 | 2 | 112 | +77 | Same count, cycle cost up — i32-width OR is more expensive |
| `VCONV` | 3 | 107 | 5 | 171 | +64 | Vector type conversions — i32 path has more |
| `STI_XN_IMM` | 0 | 0 | 4 | 52 | +52 | Store-immediate; only in cast version |
| `VCOPY` | 6 | 321 | 5 | 270 | -51 | Slight reduction |
| `VMOVMASK_XN` | 2 | 34 | 5 | 85 | +51 | More mask-vector moves |
| `VAND` | 1 | 18 | 1 | 48 | +30 | i32-width AND is heavier than bool-width |

## 4.5 VECTOR-pipe deep dive

The headline §3 / §4 numbers blur control ops, mask helpers, and actual compute together. Filtered to the VECTOR pipe only, the picture is sharper.

### 4.5.1 VECTOR-pipe summary

| Metric | bool (no-cast) | i32 (cast) | Δ |
|---|---|---|---|
| Total VECTOR instructions | 348 | 305 | **−43** |
| Unique VECTOR PCs | 162 | 119 | **−43** |
| Total VECTOR busy cycles | 8,647 | 8,383 | −264 |
| First vector op (ts) | 711 | 715 | +4 (kernel prologue, identical) |
| Last vector op (ts+dur) | 28,191 | 28,545 | +354 (cast finishes vector work later) |

The cast version uses **fewer vector instructions** (43 fewer ops, 43 fewer unique PCs in the binary) but the cycle savings are modest (−264 cyc out of ~8.6K).

> **Why does the cast version have 43 fewer vector instructions even though i32 is 32× wider than bool?** Because 910B1/910_9362 have no dedicated predicate registers — bool data is packed in regular vector registers and needs `MOVEMASK`/`MOVEVA`/`VNCHWCONV` shuffles to bridge layout mismatches between compare, logic-op, and store. The cast widens to native lane width and skips all that shuffle. See §4.7 for the architectural background and how A5's `PAND`/predicate-register model differs.

### 4.5.2 Per-mnemonic VECTOR-pipe diff

| Mnemonic | bool n × cyc (avg) | cast n × cyc (avg) | Δ cyc | What it does |
|---|---|---|---|---|
| **`VNCHWCONV`** | 8 × 828 (103.5) | **0 × 0** | **−828** | NCHW format conversion. Bool path packs results into a tight format; i32 already in target layout. **Eliminated entirely.** |
| **`MOVEVA`** | 64 × 448 (7.0) | **0 × 0** | **−448** | Vector arithmetic move; bool path uses 64 of these (= N rows) for per-row bit-shuffles. **Eliminated entirely.** |
| `BAR` | 23 × 2,221 | 26 × 2,556 | +335 | Vector pipe full barrier — cast adds 3 more |
| `MOVEMASK` | 84 × 1,544 | 96 × 1,847 | +303 | Mask-register builds; cast does 12 more |
| `VSEL` | 2 × 51 | 5 × 155 | +104 | Vector select; cast does 3 more |
| `MOVEV` | 69 × 1,704 (24.7) | 71 × 1,699 (23.9) | −5 | Vector move; basically unchanged |
| `SET_FLAG` (vec→scalar sync) | 36 × 698 | 39 × 784 | +86 | Pipe sync; cast adds 3 |
| `VOR` | 2 × 35 (17.5) | 2 × 112 **(56.0)** | +77 | Same count, **3.2× cycle cost per op** — i32-width OR is heavier |
| `VCONV` | 3 × 107 | 5 × 171 | +64 | Type-conversion; cast adds 2 |
| `VMOVMASK_XN` | 2 × 34 | 5 × 85 | +51 | Mask-vector move; cast adds 3 |
| `VAND` | 1 × 18 (18.0) | 1 × 48 **(48.0)** | +30 | Same count, **2.7× cycle cost** — i32-width AND is heavier |
| `VCMPV` | **4** × 202 | **4** × 223 | +21 | Element-wise compares (`<=`, `==`). **Identical count** — both versions vectorize the same 4 ops |
| `VCOPY` | 6 × 321 | 5 × 270 | −51 | Cast saves one VCOPY |
| `VCMPVS` | **1** × 28 | **1** × 36 | +8 | Compare-vector-with-scalar (the `k_attn == 0` test). **Identical count.** |
| `MOV_UB_TO_UB` | 1 × 17 | 0 | −17 | UB-to-UB move; bool only |
| `VBRCB` | 2 × 60 | 2 × 62 | +2 | Vector broadcast — basically unchanged |
| `VNOT` | 1 × 17 | 1 × 17 | 0 | Vector NOT — identical |

### 4.5.3 Categorized roll-up of VECTOR pipe

| Category | bool cyc / ops | cast cyc / ops | Δ |
|---|---|---|---|
| **Mask helpers** (MOVEMASK packing, MOVEVA) | 1,992 / 148 | 1,847 / 96 | −145 cyc / **−52 ops** |
| **Control** (BAR, SET_FLAG, WAIT_FLAG on VEC pipe) | 3,233 / 98 | 3,658 / 107 | **+425 cyc / +9 ops** |
| **Pure vector compute** (VCMP*, VAND/VOR/VSEL/VCONV/VBRCB/VNOT) | 441 / 13 | 745 / 18 | +304 cyc / +5 ops |
| **Vector data movement** (MOVEV, VCOPY, VNCHWCONV, MOV_UB_TO_UB) | 2,870 / 84 | 1,969 / 81 | −901 cyc / −3 ops |

### 4.5.4 The actual element-wise compares — VCMPV/VCMPVS detail

Both versions emit **5 vector compares** at distinct PCs, mapping to the 4 logical comparisons in `mask_fn` plus 1 combining op:

| | bool path | cast path |
|---|---|---|
| `q_offset <= k_offset` | `VCMPV` Dtype:**F16** ts=26,994 dur=36 | `VCMPV` Dtype:**F16** ts=26,962 dur=36 |
| `q_attn == k_attn` | `VCMPV` Dtype:S32 ts=27,142 dur=53 | `VCMPV` Dtype:S32 ts=27,472 dur=53 |
| (combining op #1) | `VCMPV` Dtype:S32 ts=27,143 dur=60 | `VCMPV` Dtype:S32 ts=27,582 dur=50 |
| `k_attn == 0` | `VCMPVS` Dtype:**F16** ts=27,330 dur=28 | `VCMPVS` Dtype:**F32** ts=28,263 dur=36 |
| `q_offset == k_offset` (final OR) | `VCMPV` Dtype:S32 ts=27,603 dur=53 | `VCMPV` Dtype:S32 ts=27,999 dur=84 |

**Surprise — `Dtype:F16` on the position compares.** Triton-Ascend's lowering casts integer position values to half-precision floats for `<=` and `==` between `q_offset` and `k_offset`. Adding `.to(tl.int32)` in the source doesn't override this choice — both versions still use F16 / F32 for the position-compare opcodes. That's a vendor lowering quirk: the AICore vector ALU's compare instructions favor floating-point dtype, so integer compares are emitted as float compares with the bit pattern preserved.

### 4.5.5 The big timing finding — vector window stretches 2×

| | bool | cast |
|---|---|---|
| First VCMP ts | 26,994 | 26,962 |
| Last VCMP ts+dur | 27,656 | 28,299 |
| **VCMP-cluster span** | **662 cyc** | **1,337 cyc (~2×)** |
| Inter-VCMP start gaps | 148, 1, 187, 273 | **510, 110, 417, 264** |

**Same 5 compares, same per-op cost (~50 cyc each), but cast spreads them over twice the wall-clock window.** Why? The added VEC-pipe `BAR` (+3 instances, +335 cyc) and `SET_FLAG`/`WAIT_FLAG` (+6 instances, +210 cyc) live in those inter-compare gaps. The wider i32 data-flow forces more pipe-pair sync between consecutive vector compares.

That's where the cast version's savings go: VNCHWCONV+MOVEVA elimination (−1,276 cyc) is consumed by pipe-sync overhead between VCMPVs (+545 cyc) + i32-width pure-compute growth (VCONV +64, VOR +77, VSEL +104, VAND +30 = +275 cyc) → net cancellation.

## 4.6 Source-to-assembler mapping

Mapping the Triton source lines onto the trace VECTOR-pipe events for both versions. All five `VCMPV` / `VCMPVS` ops correspond to source-level comparisons; the surrounding `VAND` / `VOR` / `VSEL` / `VNOT` / `VCONV` implement the bitwise combine and the bool↔int conversions.

> **These mappings are interpreted from operand register flow (which `XD` becomes a later op's `XN`/`XM`) and Dtype patterns; without `-reloc` source-line annotations, treat them as best-guess.** Confidence rating per line.

### 4.6.1 The source operations

```python
# mask_fn (TYPE=1) returns:
#   (A & (B | C)) | D
# where:
A = (q_offset[:, None] <= k_offset[None, :])    # i1 vs i32 cast
B = (q_attn_arg[:, None] == k_attn_arg[None, :]) # i1 vs i32 cast
C = (k_attn_arg[None, :] == 0)                   # i1 vs i32 cast
D = (q_offset[:, None] == k_offset[None, :])     # i1 vs i32 cast

# mask_kernel wrapper:
out = tl.where(mask, 1, 0).to(tl.int8)           # bool path
out = (mask != 0).to(tl.int8)                    # cast path
```

### 4.6.2 Bool path (helloworld.py) — VECTOR-pipe trace

```
ts     PC           Mnem      dur Dtype  Maps to                                                Conf
─────  ───────────  ────────  ─── ─────  ──────────────────────────────────────────────────────  ────
 1393  0x10d1114c   VBRCB      21  B32   prologue: broadcast q_off into a vector register         M
 1469  0x10d111fc   VCONV      58        prologue: S32→S64 lane-widen for q_off                   M
 3227  0x10d112c8   VCONV      21        prologue: S32→S64 lane-widen for k_off                   M

 — late compute cluster begins —
26958  0x10d113dc   VCONV      28        S8→F16 cast for position compare (lowering quirk)        S
26994  0x10d1142c   VCMPV      36  F16   ★ A: q_offset <= k_offset                                S
26996  0x10d11450   VBRCB      39  B32   broadcast for next compare                               M
27142  0x10d114f0   VCMPV      53  S32   ★ B: q_attn == k_attn                                    S
27143  0x10d11504   VCMPV      60  S32   ★ extract-bool helper (compare result vs 0 to widen)     W
27261  0x10d1158c   VSEL       18  F16   select to fold an output                                 W
27330  0x10d115e4   VCMPVS     28  F16   ★ C: k_attn == 0  (compare-vector-with-scalar)           S
27394  0x10d11614   VNOT       17  B16   negate (used by some De Morgan'd combine)                W
27412  0x10d11648   VOR        17  B16   ★ B | C  (combine attn-equality and k_attn-zero tests)   M
27429  0x10d1166c   VAND       18  B16   ★ A & (B | C)                                            M
27603  0x10d11684   VCMPV      53  S32   ★ D: q_offset == k_offset                                S
27656  0x10d1169c   VOR        18  B16   ★ (A & (B | C)) | D  — the final mask combine           M
27713  0x10d11704   VSEL       33  F32   tl.where(mask, 1, 0) — pick 1 or 0 per lane              S
27778  0x10d11840 } VNCHWCONV  75   B8 \
27779  0x10d11844 } VNCHWCONV 130   B8  | output: pack int8 result into NCHW layout for write-out
27780  0x10d11848 } VNCHWCONV 185   B8  |                                                         M
27781  0x10d1184c } VNCHWCONV 240   B8 /
28119  0x10d1197c } VNCHWCONV  30   B8 \
28120  0x10d11980 } VNCHWCONV  43   B8  | output: 4 more NCHW conversions
28121  0x10d11984 } VNCHWCONV  56   B8  |                                                         M
28122  0x10d11988 } VNCHWCONV  69   B8 /
```

`Conf`: **S** = strong (operand pattern + Dtype + position match clearly), **M** = moderate, **W** = weak (informed guess).

### 4.6.3 Cast path (helloworld_cast.py) — VECTOR-pipe trace

```
ts     PC           Mnem      dur Dtype  Maps to                                                Conf
─────  ───────────  ────────  ─── ─────  ──────────────────────────────────────────────────────  ────
 1366  0x10d11104   VBRCB      21  B32   prologue: broadcast q_off                                M
 1442  0x10d111b4   VCONV      58        prologue: S32→S64 lane-widen for q_off                   M
 3200  0x10d11280   VCONV      21        prologue: S32→S64 lane-widen for k_off                   M

 — late compute cluster begins —
26926  0x10d11370   VCONV      28        S8→F16 cast for first position compare                   S
26962  0x10d113c0   VCMPV      36  F16   ★ A: q_offset <= k_offset                                S
27321  0x10d11440   VSEL       38  F32   .to(tl.int32) on A — 1.0 if true, 0.0 if false           S
27323  0x10d11470   VBRCB      41  B32   broadcast for B                                          M
27472  0x10d114ec   VCMPV      53  S32   ★ B: q_attn == k_attn                                    S
27581  0x10d11550   VSEL       38  F32   .to(tl.int32) on B                                       S
27582  0x10d11570   VCMPV      50  S32   ★ D: q_offset == k_offset (early — note S32 here)        S
27689  0x10d115dc   VSEL       17  F32   .to(tl.int32) on D                                       S
27933  0x10d11618   VOR        64  B16   ★ first | of i32 results                                 M
27998  0x10d11644   VAND       48  B16   ★ &  (between triu_causal-i32 and the OR result)         M
27999  0x10d11658   VCMPV      84  S32   ★ extract-bool helper (compare i32 result with 0)        W
28140  0x10d116c4   VSEL       37  F32   .to(tl.int32) for combine                                W
28178  0x10d116e8   VOR        48  B16   ★ final OR with D                                        M
28227  0x10d1171c   VCONV      36        S32→F32 conversion for the final compare-with-zero       S
28263  0x10d11740   VCMPVS     36  F32   ★ C: k_attn == 0 (note F32 here vs F16 in bool)          S
28301  0x10d11764   VNOT       17  B16   negate for an inverted-form combine                       W
28374  0x10d117d8   VSEL       25  F16   (mask != 0).to(tl.int8) — select 1 or 0 per lane          S
28517  0x10d11808   VCONV      28        F16→S8 cast for output                                    S
```

(no `VNCHWCONV` ops at all in cast path — that's the −828 cyc savings shown in §4.5.2)

### 4.6.4 Side-by-side mapping of the four source compares

| Source line | bool-path PC + ts + Dtype | cast-path PC + ts + Dtype | Notes |
|---|---|---|---|
| `q_off <= k_off` | `0x10d1142c VCMPV F16 ts=26994 dur=36` | `0x10d113c0 VCMPV F16 ts=26962 dur=36` | Identical Dtype (F16) and dur. The position compare lowers to half-float regardless of source dtype. |
| `q_attn == k_attn` | `0x10d114f0 VCMPV S32 ts=27142 dur=53` | `0x10d114ec VCMPV S32 ts=27472 dur=53` | Identical instruction; cast version 330 cyc later in wall-clock |
| `k_attn == 0` | `0x10d115e4 VCMPVS F16 ts=27330 dur=28` | `0x10d11740 VCMPVS F32 ts=28263 dur=36` | **Dtype diverges**: bool=F16, cast=**F32** — the i32 cast forced a wider compare on the scalar-with-zero path |
| `q_off == k_off` | `0x10d11684 VCMPV S32 ts=27603 dur=53` | `0x10d11570 VCMPV S32 ts=27582 dur=50` | Identical Dtype/cost; **cast version emits this earlier in the schedule** |

### 4.6.5 What the mapping reveals

1. **The `<=` and `==` for position values lower differently.** Both versions emit `<=` as `VCMPV F16` but `==` as `VCMPV S32`. The lowering decides per-operator, not per-data-type.

2. **`.to(tl.int32)` doesn't override the F16 position compare.** Adding `.to(tl.int32)` in source still lowers `q_off <= k_off` to `VCMPV F16` — the operator-driven choice wins over the source type annotation.

3. **The `k_attn == 0` compare DOES widen with the cast.** F16 (bool path) → F32 (cast path). When the compare-vector-with-scalar path encounters i32-typed inputs, it uses the wider float type instead of the compact F16.

4. **Cast version explicitly materializes int values per compare.** Each of B, D in cast path is followed by a `VSEL F32` (ts 27581, 27689) — that's the `.to(tl.int32)` materializing the int value (1 or 0) for every lane, before feeding into the bitwise AND/OR. Bool path skips this — it keeps results as i1/B16 throughout.

5. **The combine-op order differs slightly.** Bool path runs the combines tightly together (VOR ts=27412, VAND ts=27429, then D-compare, then final VOR ts=27656). Cast path interleaves more `VSEL` between VCMPVs and the combiner (more pipe bookkeeping for the wider data path).

6. **Output formatting differs sharply.** Bool path uses 8 `VNCHWCONV` (4×4 = 8 calls totaling 828 cyc) for output layout conversion. Cast path uses 1 `VCONV` F16→S8R (28 cyc). That's the main vector-pipe saving from the cast: ~800 fewer cycles in output formatting alone.

### 4.6.6 Honest caveats on the mapping

What I can verify directly from the trace:
- ✓ All Dtypes (literal `Dtype:F16`, `Dtype:S32` in operand string)
- ✓ All PCs and ts/dur values
- ✓ The 4 source compares correspond to exactly 4 `VCMPV`/`VCMPVS` per version (5th VCMPV in each is an extract-bool helper)
- ✓ Operand register flow (which `XD` becomes a later op's `XM`)

What I'm guessing:
- ✗ Which specific VCMPV is "A" vs "D" (both are position compares; I disambiguated by Dtype: A=`<=` always F16, D=`==` always S32, plus operand-flow analysis)
- ✗ Which `VOR`/`VAND` corresponds to which combine in `(A & (B|C)) | D`
- ✗ The role of the 5th VCMPV in each version

The way to get strict confirmation: re-run with `msopgen sim -reloc <kernel.npubin>`. That triggers `llvm-objdump --save-aicore-bins` which is decoder-gated, so we can't actually do this on shipped CANN-8.5.0. The mapping above is the closest you get without an internal Huawei build.

## 4.7 Architectural context — why bool needs MOVEMASK/MOVEVA/VNCHWCONV on 910B1, but uses PAND on A5

The expensive shuffle work (`VNCHWCONV` × 8, `MOVEVA` × 64, `MOV_UB_TO_UB` × 1) the bool path emits — and which the cast path eliminates — exists because of a fundamental architectural difference between AICore generations.

### 4.7.1 Two architectural styles for bool/predicate

**A5 (newer Ascend gen)** has **dedicated predicate registers** (`P0`, `P1`, …) and predicate-specific instructions: `PAND`, `POR`, `PNOT`, masked vector ops, `VSEL` driven by a predicate input. A vector compare can directly write a predicate (`VCMP X1, X2 → P0`), and predicate ALU is hardware-native — same model as ARM SVE / x86 AVX-512 mask registers.

**910B1 / 910_9362 (current AICore, what camodel runs on)** has **no dedicated predicate registers**. Bool/mask data lives in regular wide vector registers, packed as bits. All bool logic uses **generic vector ALU instructions** with `Dtype:B16` semantics ("treat-this-register-as-packed-bools"). Format conversions are needed when the layout mismatches between consecutive ops.

### 4.7.2 What we see in our 910B1 camodel trace

Direct evidence from the bool-path trace's VECTOR pipe:

```
0x10d1142c  VCMPV  F16  Dtype:F16   ← compare result lands in regular vector register (X5)
                                       as bit-packed bools, not in a predicate register
0x10d11648  VOR    B16  Dtype:B16   ← bitwise OR on packed-bool data
0x10d1166c  VAND   B16  Dtype:B16   ← bitwise AND on packed-bool data
0x10d11614  VNOT   B16  Dtype:B16   ← bitwise NOT on packed-bool data
```

These **aren't predicate ops**. They're regular vector ALU ops with `Dtype:B16` telling the unit "interpret operand bits as packed bools." The hardware applies the logic op bitwise across the packed lane.

### 4.7.3 Why MOVEMASK / MOVEVA / VNCHWCONV exist (and disappear under cast)

Without dedicated predicate hardware, the AICore needs to fix up bit layouts between operations:

| Instruction | Calls in bool path | Role |
|---|---|---|
| `MOVEMASK` | 84 | Convert between "VCMPV-result layout" (one bit per element packed within a lane) and "operand layout" (where AND/OR expect specific bit positions) |
| `MOVEVA` | 64 (= N rows) | Per-row bit-arithmetic shuffle. With 32×32 packed bools, the compiler aligns bits within each row to match the next op's expected layout |
| `VNCHWCONV B8` | 8 | Final output format conversion: packed-bool → byte-per-element int8 store layout |

Combined: 73 shuffle/conversion instructions, ~1.3K cycles, **all of which exist to bridge the lack of predicate hardware**.

The cast version sidesteps these by widening every bool to a full i32 lane. Once each "bool" lives in its own 32-bit lane, the AND/OR/SEL ops are regular vector arithmetic — no packing, no shuffling. **The cast is essentially "fake A5"** — it emulates the predicate-register-style flat layout by paying memory width instead of using HW support.

### 4.7.4 What A5's PAND would replace (hypothetical lowering)

If the same `mask_fn` were lowered for A5 with predicate registers, the structure would be:

```
VCMPV  X1, X2 → P0                  ; compare directly writes predicate
VCMPV  X3, X4 → P1
PAND   P0, P0, P1                   ; predicate-AND, hardware-native
VCMPVS X5, 0  → P2
POR    P0, P0, P2                   ; predicate-OR
VSEL   XD = P0 ? Xtrue : Xfalse     ; predicate-driven select
                                    ; output stored directly under predicate mask
```

Compared to the 910B1 lowering, this eliminates:
- All 84 `MOVEMASK` instructions (predicates have a fixed HW layout)
- All 64 `MOVEVA` instructions (no per-row repack needed)
- All 8 `VNCHWCONV` instructions (predicates can drive output stores directly)
- The `Dtype:B16` annotations on logic ops (predicate ALU is its own class)

### 4.7.5 Why the cast path is roughly cycle-neutral on 910B1

This is the architectural reason for the §3 / §4 finding that **bool and i32 cast variants take ~equal cycles**:

| Path | Bool data carried as | Cost on 910B1 |
|---|---|---|
| **Bool** (`helloworld.py`) | Packed bits in vector registers | Saves ALU cost on heavy ops (VOR=17.5 cyc, VAND=18 cyc) but spends ~1.3K cyc on `MOVEMASK`+`MOVEVA`+`VNCHWCONV` shuffles |
| **i32 cast** (`helloworld_cast.py`) | One i32 per lane, no packing | Eliminates shuffles entirely (~1.3K cyc saved) but each per-op ALU cost is heavier (`VOR`=56 cyc, `VAND`=48 cyc — ~3× the per-call cost) + extra inter-op pipe sync |

Both paths arrive at roughly the same total cost because the savings from avoiding shuffles match the cost of wider per-op work. Triton-Ascend's bool packing is well-tuned for 910B1 — the shuffle overhead pays for itself.

### 4.7.6 What this means for forward-looking work

If you're targeting **910B1 / 910_9362** today: **don't add `.to(tl.int32)` casts to bool intermediates expecting a speedup.** The two paths are roughly equivalent (and the cast version is actually +1.3% slower). The cast helps binary size (15% smaller) but not cycles.

If you're targeting **A5 (when it's available)**: bool intermediates should be the natural-fit choice. The compiler's `PAND`/`POR`/predicate-driven `VSEL` lowering will be strictly better than the i32-cast path. Don't manually widen what the architecture has hardware for.

The actual perf improvements on this kernel come from **changing the output type**, not the intermediate type — the 1024-iteration int8 byte-store loop dominates either way (33K of 71K SCALAR cycles). Pack output as `int32` per row or as a bitmap, and the kernel speeds up regardless of which architecture you target.

## 5. What this tells you

### 5.1 The bool path packs efficiently

The bool path uses 8 `VNCHWCONV` (NCHW format conversion) + 64 `MOVEVA` + extensive `MOV_XD_IMM` to build alternating-bit patterns (`0x5555_5555_5555_5555`). Together these are ~1,650 cycles of "bool-specific" work — bit-packing the boolean result into a compact format before the per-byte unpack-store loop.

### 5.2 The i32 path eliminates packing but pays more sync

When you cast every compare to int32, Triton-Ascend's lowering takes the natural-width path. The 1,650 cycles of bool-packing (`VNCHWCONV`+`MOVEVA`+bit-pattern setup) disappear entirely. **But the saving is fully eaten** by:

- +609 cyc in `WAIT_FLAG` + 124 cyc in `SET_FLAG` (more pipe sync)
- +293 cyc in `BAR` (more barriers)
- +303 cyc in `MOVEMASK` + various smaller VEC-pipe op increases

Net: ~+364 cycles — within noise, but in the wrong direction for a "should be more natural" code shape.

### 5.3 The store loop is the actual bottleneck — and it's unchanged

In both versions, **the 1024-iteration scalar unpack-store loop is the dominant cost** (~33K of the ~71K SCALAR-pipe cycles, ~46% of all SCALAR work). The cast version doesn't change this loop at all (1024 stores in both, same body shape). Whatever you do to the upstream compute, the int8 byte-by-byte store is the limiter.

To actually speed up the kernel: change the **output type** (e.g. write as a packed bitmap, `int32` per row, etc.) — not the intermediate type. The cast on intermediates is rearrangement of upstream work that doesn't touch the bottleneck.

### 5.4 Smaller binary ≠ faster execution

The cast `.text` is 15% smaller (529 unique PCs vs 624; 2116 B vs 2496 B). This is mostly because the bit-packing helper code (`MOV_XD_IMM` literal builders, `VNCHWCONV` setup, etc.) doesn't appear. But execution time is set by the dominant loop, not by code-cache footprint. **Static size is a poor proxy for cycles** on this architecture.

## 6. Methodology — how the comparison was done

Same recipe as `helloworld_mask_camodel_walkthrough.md`:

1. Wrap each `mask_fn` variant in a launchable `mask_kernel` that does loads + helper call + store
2. Compile both via Triton-Ascend on real device (separate `TRITON_CACHE_DIR` to keep `.npubin`s distinct)
3. Run each through `AscendOpKernelRunner(simulator_mode="ca")` on the same 32×32 inputs
4. Parse with `msopgen sim` → Chrome-trace JSON
5. Diff the two JSONs at three levels: top-line, per-pipe, per-mnemonic

The comparison Python script:

```python
import json
from collections import Counter, defaultdict

def load(path):
    d = json.load(open(path))
    return d.get('traceEvents', d) if isinstance(d, dict) else d

def stats(events):
    end = max((e.get('ts',0)+e.get('dur',0)) for e in events)
    start = min(e.get('ts',0) for e in events)
    pipe_dur = defaultdict(int); pipe_cnt = Counter()
    for e in events:
        pipe_dur[e['tid']] += e.get('dur', 0)
        pipe_cnt[e['tid']] += 1
    return {'events': len(events),
            'unique_pcs': len({e['args']['addr'] for e in events}),
            'span': end - start, 'pipes': dict(pipe_dur), 'pipe_cnt': dict(pipe_cnt)}

def mn_stats(events):
    dur = defaultdict(int); cnt = Counter()
    for e in events:
        dur[e['name']] += e.get('dur', 0)
        cnt[e['name']] += 1
    return dur, cnt
```

## 6.5 Microarchitecture caveat — what model the camodel actually ran

The kernel was **compiled for `Ascend910_9362`** (the silicon variant on dev box 218; per `mask_kernel.json`'s `target.arch` field). The camodel was launched with `soc_version="Ascend910B1"` for the runs in §3–§4.6 above. To check whether this mattered, I re-ran both kernels with `soc_version="Ascend910_9362"` and compared.

**Result: instruction traces are bit-identical between the two settings.**

| Run | events | unique PCs | span | SCALAR | VECTOR | MTE2 | camodel `Total tick` |
|---|---|---|---|---|---|---|---|
| bool, soc=910B1 | 9,459 | 624 | 27,645 | 70,590 | 8,647 | 3,658 | 28,573 |
| bool, soc=9362 | 9,459 | 624 | 27,645 | 70,590 | 8,647 | 3,658 | 28,709 |
| cast, soc=910B1 | 9,364 | 529 | 27,995 | 71,608 | 8,383 | 3,656 | 28,937 |
| cast, soc=9362 | 9,364 | 529 | 27,995 | 71,608 | 8,383 | 3,656 | 28,857 |

The msopgen-parsed instruction stream is identical. Camodel's own `Total tick` counter varies by ±200 cycles between runs but doesn't track the soc_version — these are run-to-run variations in init/teardown bookkeeping, not microarchitecture differences.

Why: the simulator loads `Ascend910B1/lib/config_stars.json` regardless of `te_set_version` / `soc_version`. The doc note in [`ascend_cycle_profiling.md`](ascend_cycle_profiling.md) §3.3 ("CAMODEL_CONFIG_PATH may not be honored as expected — the camodel has its own platform-detection that picks a closest available config") explains this. **In CANN-8.5.0, the camodel infrastructure is hardcoded to 910B1 internally**; passing `Ascend910_9362` doesn't activate a different microarchitecture model.

Implications:
- The cycle numbers in §3, §4, §4.5, §4.6 are **910B1-model values**, regardless of how the run was launched.
- The bool-vs-cast comparison is internally consistent (same model ran both, same compilation settings) — so the 4.5%/15% deltas, the VECTOR-pipe diffs, and the source-mapping all hold.
- They don't directly map to real-silicon Ascend910_9362 cycles. The closest comparison for that is **msprof on real device**, e.g. the 12,658 AIV cycles measured for `vector_add` in [`helloworld_mask_camodel_walkthrough.md`](helloworld_mask_camodel_walkthrough.md) §2.
- To get a "true" Ascend910_9362 simulator, you'd need either an internal Huawei build with the 9362-specific config wired up or a direct silicon measurement via msprof.

What this means in practice: **treat camodel cycle numbers as model-relative, not silicon-absolute.** Diffs between two camodel runs are valid signal; absolute cycles aren't directly comparable to vendor 910_9362 datasheets.

## 7. Where everything lives

Server (192.168.25.218):
- `/home/Ray/triton_hello/helloworld_runner.py` — bool kernel
- `/home/Ray/triton_hello/helloworld_cast_runner.py` — cast kernel
- `/home/Ray/triton_hello/mask_cache/<hash>/mask_kernel.npubin` — bool compiled
- `/home/Ray/triton_hello/mask_cast_cache/<hash>/mask_kernel_cast.npubin` — cast compiled
- `/home/Ray/triton_hello/camodel_run/mask{,_cast}_dumps{,_9362}/` — per-core dumps for all 4 runs
- `/home/Ray/triton_hello/camodel_run/mask{,_cast}_dumps_9362_trace/` — parsed traces (9362)
- `/home/Ray/triton_hello/camodel_run/mask{,_cast}_trace/` — parsed traces (910B1)

Local:
- `/tmp/mask_trace.json` — bool trace 910B1 (1.95 MB)
- `/tmp/mask_cast_trace.json` — cast trace 910B1 (1.93 MB)
- `/tmp/mask_9362_trace.json` — bool trace 9362 (identical to 910B1)
- `/tmp/mask_cast_9362_trace.json` — cast trace 9362 (identical to 910B1)

## 8. TL;DR

| Finding | Implication |
|---|---|
| `+1.3%` cycle span (cast slightly slower) | The cast doesn't help; intermediate-type rearrangement is roughly cycle-neutral |
| `-15%` binary size (cast smaller) | Triton emits less per-bool-bit-packing helper code, but execution time isn't proportional |
| `VNCHWCONV` + `MOVEVA` (~1.3K cyc) eliminated by cast | Bool-packing path has measurable structural overhead |
| `WAIT_FLAG`/`SET_FLAG`/`BAR` (+1K cyc) added by cast | i32-width path needs more inter-pipe sync |
| **Loop body and 1024 stores unchanged** | The kernel's bottleneck is the scalar unpack-store loop, not the upstream type. Cast doesn't touch it. |
| **To actually speed up**: change the output type | Pack output as bitmap or wider int → cut store cost ~8×. Casting intermediates can't fix what the output type forces. |
| **Camodel μarch caveat** | `te_set_version("Ascend910_9362")` doesn't change the simulator behavior — camodel locks to 910B1 internally. All cycle numbers are 910B1-model. Real-silicon 910_9362 numbers need msprof. See §6.5. |
| **910B1 has no predicate registers** | Bool data is packed in regular vector registers; logic ops use `Dtype:B16` semantics; `MOVEMASK`/`MOVEVA`/`VNCHWCONV` bridge layout mismatches. The cast eliminates these by widening to native lane width — "fake A5". See §4.7. |
| **A5 implications** | A5 has hardware predicate registers + `PAND`/`POR`. Bool path will be strictly faster than cast there. Don't manually widen on A5. |
