# A5 PTO assembly walkthrough — `mask_kernel` bool variant VLOOP body

This doc decodes the actual A5/PTO machine code emitted by `hivmc-a5` for
the bool variant of `mask_fn`, with each instruction mapped back to:
- the corresponding HIVM-MLIR op (`captures_hivmc_input_a5_bool.mlir`),
- the original Triton-Python expression (`helloworld.py`).

It also documents what each PTO mnemonic actually means, sourced from the
local PTO ISA repo at `~/Documents/Repo/pto-isa/docs/isa/` and verified
against the chip-spec descriptions provided directly by the architect.

Companion docs:
- `a5_hivmc_input_mlir.md` — last MLIR before hivmc-a5 (Triton → HIVM)
- `helloworld_cast_vs_nocast_comparison.md` — bool vs cast at the
  full-stack level (Python → ELF), §4.7 covers the A5 cast-vs-bool
  contrast
- `mask_fn_compilation_stack.md` — full 7-stage pipeline survey

## 1. Hardware facts (verified)

From `~/Documents/Repo/pto-isa/docs/isa/machine-model/execution-agents.md`
and `instruction-surfaces/vector-instructions.md`:

```
vreg (256 bytes = 2048 bits total):
┌─────────┬─────────┬─────────┬─────┬─────────┬─────────┐
│ VLane 0 │ VLane 1 │ VLane 2 │ ... │ VLane 6 │ VLane 7 │
│   32 B  │   32 B  │   32 B  │     │   32 B  │   32 B  │
└─────────┴─────────┴─────────┴─────┴─────────┴─────────┘
```

| Element type        | Lanes per VLane | Total lanes per vreg |
|---------------------|----------------:|---------------------:|
| `i8`/`u8`           | 32              | **256**              |
| `i16`/`u16`/`f16`/`bf16` | 16         | **128**              |
| `i32`/`u32`/`f32`   | 8               | **64**               |
| `i64`/`u64`         | 4               | **32**               |

So a HIVM-level `1024xi32` vector op (e.g. `hivm.hir.vor`) lowers to
**`⌈1024 / 64⌉ = 16` hardware vector instructions**.

A `_b32` predicate register is **32 bits wide**; for full 64-i32-lane
masking, pack two `_b32` predicates with `ppack` (not used in this
kernel — the per-iter row width is ≤ 32 lanes anyway).

## 2. Instruction format reference (verified by architect)

### `PSET.type Pd, #pat`

Sets a predicate to a static pattern selected by a 4-bit immediate
token. `.type` = element data type.

| `#pat` | Bits   | Pattern                                   |
|-------:|:------:|-------------------------------------------|
| `#0`   | `b0000`| **ALL** — all elements TRUE               |
| `#8`   | `b1000`| **VL64** — lowest 64 elements active      |
| `#15`  | `b1111`| **ALLF** — all elements FALSE             |

(Other immediate values map to additional VL/ALL/H/Q/M3/M4 patterns —
see `pto-isa/docs/isa/scalar/ops/predicate-generation-and-algebra/pset-b32.md`.)

### `VLOOPV2 Sn, #instr, #layer, #last`

Marks the start of a hardware vector loop.

| Field    | Width  | Meaning                                                                |
|----------|:------:|------------------------------------------------------------------------|
| `Sn`     | scalar reg | runtime iteration count                                            |
| `#instr` | imm    | body length (instructions in this loop body, **excluding** VLOOPV2)    |
| `#layer` | 4 bits | nesting indicator: `b0001` = innermost                                 |
| `#last`  | 1 bit  | `1` = terminal at this layer; `0` = more cascaded loops follow         |

The `_V310` suffix is an encoding-variant tag (chip-revision specific).

### `VLDI vd, [sn], #offset, #dist, #p`

Vector aligned load with immediate offset.

| Field      | Width  | Meaning                                                              |
|------------|:------:|----------------------------------------------------------------------|
| `vd`       | vreg   | destination                                                          |
| `[sn]`     | scalar | base address                                                         |
| `#offset`  | 8 bit signed | offset, in **alignment-size units**                            |
| `#dist`    | 5 bit  | data distribution mode (see below)                                   |
| `#p`       | 1 bit  | post-update enable                                                   |

`#dist` modes (partial — confirmed):
- `5h00` = **normal**: load full VL (256 B); alignment = 32 B
- `5h03` = **brc_b32**: load 1 b32 element, broadcast to all 64 i32 lanes; alignment = 4 B

`#p` semantics:
- `#p = 0` → effective addr = `sn + #offset · alignment_size`; `sn` unchanged
- `#p = 1` → effective addr = `sn`; `sn ← sn + #offset · alignment_size` (post-incr)

### `VCMP.cond.type Pd, V0, V1, Pseed`

`Pd[i] = cmp_cond(V0[i], V1[i])` for lanes where `Pseed[i]` is active.
Convention verified from `pto-isa/docs/isa/vector/ops/compare-select/vcmp.md`:

```mlir
%lt_mask = pto.vcmp %a, %b, %seed, "lt"
// lt_mask[i] = 1 if a[i] < b[i]
```

So in the asm form `VCMP.LE.s32 P5, V3, V2, P1`: `P5[i] = (V3[i] ≤ V2[i])`.

### `POR / PAND / PXOR Pd, P0, P1, Pseed`

Bitwise predicate algebra.
`Pd[i] = (P0[i] op P1[i])` for active lanes (per `pto-isa/docs/isa/scalar/ops/predicate-generation-and-algebra/por.md`).

### `VSEL.type Vd, V_true, V_false, Pmask`

Lane-wise predicated select: `Vd[i] = Pmask[i] ? V_true[i] : V_false[i]`.

## 3. The annotated assembly

Bool variant, VLOOP body of `mask_kernel`. The 20-line snippet shown is
the predicate-algebra heart; the real body is 35 instructions (per the
`#35` field of VLOOPV2) — additional loads/stores/sync ops surround the
core shown here.

```asm
;══════════════════════════════════════════════════════════════════════════════
; Pre-loop predicate setup
;══════════════════════════════════════════════════════════════════════════════
PSET.b32 P1, #8                     ; P1 ← VL64 (b1000): all 64 i32 lanes ACTIVE
                                    ;       — body's "main" seed mask
PSET.b32 P2, #15                    ; P2 ← ALLF (b1111): all lanes FALSE
                                    ;       — used as PXOR pattern below; XOR-with-0 = no-op
                                    ;         (compiler kept the slot for predicate dependency
                                    ;         tracking; see §6 "vnot collapsed")

;══════════════════════════════════════════════════════════════════════════════
; Loop header
;══════════════════════════════════════════════════════════════════════════════
VLOOPV2_V310 S3, #35, #1, #1        ; iter count = S3 (runtime, set above)
                                    ; body length = 35 insns (excludes VLOOPV2)
                                    ; layer       = b0001 (innermost)
                                    ; last        = 1     (terminal at this layer)
                                    ; _V310       = encoding variant

;══════════════════════════════════════════════════════════════════════════════
; Loads (per-iter unless flagged constant)
;══════════════════════════════════════════════════════════════════════════════
VLDI V2, [S6],  #0,  #0, #0         ; dist=normal, full-VL load (256 B = 64 i32)
                                    ; addr = S6 + 0·32 = S6
                                    ; p=0  → S6 unchanged (constant load each iter)
                                    ; ROLE: k_offset[None, :]  (32 elems padded to 64-lane vreg)
                                    ;       — row-invariant across iterations

VLDI V3, [S69], #16, #0, #1         ; dist=normal, full-VL load
                                    ; addr = S69
                                    ; p=1  → S69 ← S69 + 16·32 = S69 + 512 B (post-incr)
                                    ; ROLE: q_offset[:, None] pre-vbrc tile, streaming row(s)
                                    ;       per iter; row = q_offset[i] replicated across 32 lanes

VLDI V4, [S68], #1,  #3, #1         ; dist=brc_b32 (5h03): 1 i32 broadcast → all 64 lanes
                                    ; addr = S68
                                    ; p=1  → S68 ← S68 + 1·4 = S68 + 4 B (per-iter scalar stream)
                                    ; ROLE: q_attn[i] — one new scalar per iter, replicated full-VL

VLDI V5, [S10], #0,  #0, #0         ; dist=normal, full-VL load
                                    ; addr = S10, p=0 (constant load)
                                    ; ROLE: k_attn[None, :] (32 elems padded to 64-lane vreg)
                                    ;       — row-invariant

VLDAS ULD0, [S12]                   ; UnalignReg ULD0 ← addr S12 (sets up unaligned-load context)
SMOV.b32 S70, S12                   ; S70 ← S12 (offset register snapshot)

;══════════════════════════════════════════════════════════════════════════════
; Compute — predicate boolean algebra (the "i1 land" of the bool MLIR)
;══════════════════════════════════════════════════════════════════════════════
VADDS.s32 V2, V2, S8, P1            ; V2 ← V2 + S8  (lane-wise add of broadcast scalar S8)
                                    ; ROLE: program-id stride applied to k_offset

VCMP.LE.s32 P5, V3, V2, P1          ; P5[j] ← (V3[j] ≤ V2[j])     under seed P1
                                    ; ◄══ A_row = (q_offset[i] ≤ k_offset[j])  =  triu_causal

VCMP.EQ.s32 P4, V4, V5, P1          ; P4[j] ← (V4[j] == V5[j])    under seed P1
                                    ; ◄══ B_row = (q_attn[i] == k_attn[j])

VLDUI V6, ULD0, [S70], #0           ; V6 ← unaligned load via ULD0 + S70 offset
                                    ; ROLE: precomputed C as bytes (= (k_attn==0), row-invariant)
SMOV.b32 S70, S18                   ; advance S70 ← S18

MOVVP.b32 P3, V6, #0                ; P3 ← V6 lane-bits as predicate (vector→pred convert)
                                    ; ◄══ C = (k_attn == 0)        (recovered from byte form)

PXOR P3, P3, P2, P1                 ; P3 ← P3 XOR P2 (=ALLF=0)  under seed P1
                                    ; ★ EFFECTIVE NO-OP — see §6 "vnot collapsed"

POR  P3, P4, P3, P1                 ; P3 ← P4 | P3        ◄══ D_row = B_row | C
PAND P3, P5, P3, P1                 ; P3 ← P5 & P3        ◄══ E_row = A_row & D_row

VCMP.EQ.s32 P4, V3, V2, P1          ; P4[j] ← (V3[j] == V2[j])   (overwriting old P4=B_row)
                                    ; ◄══ F_row = (q_offset[i] == k_offset[j])

POR  P3, P3, P4, P1                 ; P3 ← P3 | P4        ◄══ result_row = E_row | F_row    ★ FINAL i1

;══════════════════════════════════════════════════════════════════════════════
; Materialize i1 → i32 → store
;══════════════════════════════════════════════════════════════════════════════
VSEL.b32 V2, V1, V0, P3             ; V2[j] ← P3[j] ? V1[j] : V0[j]
                                    ; (V1 = preloaded all-1 i32 tile, V0 = preloaded all-0 tile)
                                    ; ◄══ exact 1:1 with MLIR `vsel(i1, c1_i32, c0_i32)` (Phase 12)

VSTI V2, [S67], #16, #2, P1, #1     ; store V2 to UB at [S67 + …]
                                    ; (full mode-field semantics deferred — VSTI spec not yet given)
```

## 4. Translation back to Triton source

```
Triton expression                                                     PTO instruction
──────────────────────────────────────────────────────────────────    ──────────────────────────────
triu_causal = (q_offset[:, None] <= k_offset[None, :])             ─► VCMP.LE  P5, V3, V2  (= A_row)
(q_attn_arg[:, None] == k_attn_arg[None, :])                       ─► VCMP.EQ  P4, V4, V5  (= B_row)
(k_attn_arg[None, :] == 0)                                         ─► VLDUI + MOVVP        (= C; precomp)
B | C                                                              ─► POR     P3, P4, P3  (= D_row)
triu_causal & (B | C)                                              ─► PAND    P3, P5, P3  (= E_row)
(q_offset[:, None] == k_offset[None, :])                           ─► VCMP.EQ  P4, V3, V2  (= F_row)
((triu_causal & (B|C)) | (q_offset == k_offset))                   ─► POR     P3, P3, P4  (= result_row)
[i1 → i32 widening, MLIR Phase 12]                                 ─► VSEL.b32 V2, V1, V0
[i32 → i8 narrowing happens later, outside this snippet]           ─► (subsequent ops)
store result_row                                                   ─► VSTI    V2, [S67]
```

Each line of the high-level Triton expression maps to **one** hardware
op. No `f16` or `f32` round-trips appear — confirming this is the
**bool path**, where A5's predicate-register architecture lets the
boolean algebra stay in P-regs end-to-end.

## 5. Mapping back to the HIVM MLIR

| HIVM-MLIR op (bool variant)                          | PTO instruction                | Notes |
|------------------------------------------------------|--------------------------------|-------|
| `hivm.hir.vbrc q_offset 32x1 → 32x32 i32` (Phase 1)  | (pre-loop, not shown)          | Done before VLOOP; result lives at UB c0 |
| `hivm.hir.vbrc k_offset 1x32 → 32x32 i32` (Phase 1)  | (pre-loop, not shown)          | UB c5120 |
| `hivm.hir.vcmp 1024xi32,1024xi32` (Phase 5, F)        | `VCMP.EQ P4, V3, V2`           | Per-row; full tile across 32 iters |
| `hivm.hir.vcmp 1024xi32,1024xi32` (Phase 5, B)        | `VCMP.EQ P4, V4, V5`           | V4=q_attn[i] brc, V5=k_attn row |
| `hivm.hir.vcmp i32,0 (Phase 3, C)`                    | (pre-loop) → `VLDUI` + `MOVVP` | C precomputed once, reloaded per iter |
| Phase 9: `vcast i8→f16 → vcmp(ne 0)` (recover A as i1)| (collapsed by hivmc-a5)        | A enters loop already as predicate via `MOVVP` |
| Phase 10: `vbrc f16 + vcmp(==0) + vnot` (broadcast C) | **collapsed to PXOR ALLF (no-op)** | A5's predicate-reg arch eliminates the f16 dance |
| `hivm.hir.vor (B,C) → D` (Phase 11)                   | `POR P3, P4, P3`               | i1 ⇒ predicate-reg directly |
| `hivm.hir.vand (A,D) → E`                             | `PAND P3, P5, P3`              | |
| `hivm.hir.vor (E,F) → result`                         | `POR P3, P3, P4`               | |
| `hivm.hir.vsel(i1, c1_i32, c0_i32) → 1024xi32`        | `VSEL.b32 V2, V1, V0, P3`      | 1:1 |
| `hivm.hir.vcast 1024xi32 → 1024xi8`                   | (later in body, not shown)     | i32 → i8 narrowing |
| `hivm.hir.store 1024xi8 → gm`                         | (later DMA op)                 | UB → GM via MTE3 |

## 6. A5 codegen wins — MLIR ops that disappear into hardware modes

`hivmc-a5` exploits two A5 hardware features to eliminate entire MLIR
phases:

1. **Predicate registers** (P-regs, MaskRegs) — let boolean values
   stay as 32-bit predicates without round-tripping through `f16`
   memrefs.
2. **Distribution modes on loads** (`brc_b32`, etc.) — let broadcast
   semantics be folded into the load instruction, skipping explicit
   `vbrc` ops and the destination tiles they would write to.

Two worked examples follow.

### 6.1 The "vnot collapsed" insight

The bool MLIR (`captures_hivmc_input_a5_bool.mlir` Phase 10) has this
canonical sequence to broadcast `C = (k_attn == 0)` from a 32-element
row to the full 32×32 tile and recover it as i1:

```mlir
// Phase 10 — broadcast C (32-wide row) to full tile, recover as i1
hivm.hir.vbrc ins(%C_f16_row) outs(%C_f16_tile)            // f16 broadcast
hivm.hir.vcmp ins(%C_f16_tile, %f16_zero) outs(%notC_i1)   // (==0.0) → ¬C
hivm.hir.vnot ins(%notC_i1) outs(%C_i1)                    // vnot to recover C
```

A 3-op `f16-vbrc → f16-vcmp → vnot` ladder, present **only because the
MLIR types the boolean tile as a memref of f16** — there's no native
"broadcast a predicate to a full tile" memref type at the MLIR level.

On A5, hivmc-a5 collapses the entire ladder to **zero ops** by:

1. **Computing C directly as a predicate.** `VCMP.EQ.s32 P4, V4, V5`
   writes a P-register, not an f16 tile.
2. **Folding the broadcast into the load.** `VLDI V4, [S68], #1, #3, #1`
   uses dist mode `5h03` (`brc_b32`) to replicate one i32 to all 64
   lanes during the load itself.
3. **Skipping the polarity flip.** Since C arrives with the right sign
   from VCMP, no inversion is needed. The compiler still emits a
   `PXOR P3, P3, P2` slot (likely as a fixed-shape predicate-dependency
   template) but populates the second operand with `ALLF` (all-zero
   pattern), making the XOR a no-op.

This is a real A5 efficiency win that doesn't show up at the MLIR
level: **the bool variant's 3-op f16 detour for C-broadcast vanishes
entirely on A5 hardware.**

### 6.2 The "vbrc collapsed into VLDI brc_b32" worked example

A concrete trace of how Triton's `q_attn_arg[:, None]` semantic flows
through all three layers, showing where it disappears.

#### Layer 1 — Triton source

```python
B = (q_attn_arg[:, None] == k_attn_arg[None, :])
```

`[:, None]` adds a length-1 column axis; combined with `[None, :]` it
specifies a 32×32 broadcast. Concretely, computing one row `i` of B
reduces to:

```
B[i, j] = (q_attn[i] == k_attn[j])    for j ∈ [0, 32)
```

The scalar `q_attn[i]` is paired against the 32-element `k_attn` row.

#### Layer 2 — HIVM-MLIR (`captures_hivmc_input_a5_bool.mlir`)

The MLIR materializes the broadcast **eagerly**, allocating a
4096-byte tile in UB and running an explicit `vbrc`:

```mlir
// Phase 1 — broadcast q_attn col scalars to a 32×32 i32 tile in UB
%5 = hivm.hir.pointer_cast(%c18976_i64) : 32x1xi32 ub    // src: 32 scalars (128 B)
%6 = hivm.hir.pointer_cast(%c9216_i64)  : 32x32xi32 ub   // dst: q_attn[:, None] tile (4096 B)
hivm.hir.vbrc ins(%5) outs(%6) broadcast_dims=[1]        // ◄── q_attn[:, None]

// Phase 5 — full-tile vcmp produces B as 1024×i1
%14 = hivm.hir.pointer_cast(%c9216_i64) : 1024xi1 ub
hivm.hir.vcmp ins(%collapse_shape_11, %collapse_shape_12) outs(%14)
```

That looks tidy in the IR but it costs **4096 B of UB plus one
upfront broadcast op** (which lowers to ≈16 hardware vector insns to
fill the tile).

#### Layer 3 — A5 PTO assembly

`hivmc-a5` rewrites the algorithm. Instead of "broadcast eagerly to a
32×32 tile, then compute B as one big vcmp," it does **"stream
q_attn one scalar per iter using `brc_b32`, and compute B one row per
VLOOP iter."**

```asm
VLDI V4, [S68], #1, #3, #1   ; brc_b32: load q_attn[i] (4 B) → broadcast to all 64 lanes
                              ; S68 ← S68 + 4   (advance to q_attn[i+1] for next iter)
…
VCMP.EQ.s32 P4, V4, V5, P1   ; lane j: V4[j] == V5[j] = q_attn[i] == k_attn[j] = B[i, j]
```

V4 holds `(q_attn[i], q_attn[i], …, q_attn[i])` — exactly what
`q_attn_arg[:, None]` yields for row `i`. The Triton `[:, None]`
semantic is now implemented purely as the load's distribution-mode
flag.

#### Why hivmc-a5 prefers this

|                                  | MLIR / eager broadcast | A5 / brc_b32 streaming |
|----------------------------------|------------------------|-------------------------|
| UB footprint for q_attn          | 128 B source + **4096 B broadcast tile** | 128 B source only — broadcast tile **never materialized** |
| Setup ops (pre-loop)             | 1× `vbrc` (≈16 hw vector insns) | 0 — broadcast happens at load time |
| Per-iter q_attn read             | 128 B (one tile row)   | **4 B** (one scalar)    |

`hivmc-a5` collapses an entire MLIR phase (the eager `vbrc q_attn`)
into a *load-mode flag* on the per-iter VLDI. The same pattern
applies to V5 (k_attn row, full-VL load with `#p=0` so the same
32-element row stays cached across iters) — together V4 + V5
implement the `[:, None] == [None, :]` pair entirely in load
semantics, with **zero explicit broadcast ops in the body**.

#### Cross-layer mapping summary

```
Triton:   B[i, :] = (q_attn[i] == k_attn[:])
                       │             │
                       │             └── V5 = k_attn row    (full-VL, constant load #p=0)
                       └── V4 = q_attn[i] broadcast         (brc_b32, +4 B/iter)

MLIR:     hivm.hir.vbrc q_attn 32x1 → 32x32  (eager, allocates 4096 B UB tile)
          hivm.hir.vcmp 1024-elem tile        (one big op over the tile)

A5 PTO:   VLDI V4, [S68], #1, #3, #1          ◄── broadcast folded into load
          VCMP.EQ.s32 P4, V4, V5, P1          ◄── one row of B per iter, ×32 iters
```

### 6.3 Combined effect on the bool kernel

The collapses together remove substantial cost from the bool path,
but not all MLIR `vbrc` ops disappear — some get **kept-but-streamed**
through their tile rather than eliminated. The decision depends on
how many compute consumers reuse the broadcast (see §6.4 for the
full cost analysis).

| MLIR op                            | A5 codegen choice    | Hardware replacement |
|------------------------------------|----------------------|----------------------|
| `vbrc q_attn 32x1 → 32x32 i32`     | **eliminated**       | `VLDI` brc_b32 mode (4 B/iter scalar stream); tile never materialized |
| `vbrc k_attn 1x32 → 32x32 i32`     | **eliminated**       | constant full-VL load (V5 unchanged across iters) |
| `vbrc q_offset 32x1 → 32x32 i32`   | **kept, streamed**   | tile built pre-loop; V3 reads one tile row per iter via full-VL load |
| `vbrc k_offset 1x32 → 32x32 i32`   | **kept, constant**   | tile reduced to single row in V2 (held constant via `#p=0`) |
| `vbrc C-f16 1x32 → 32x32 f16`      | **eliminated**       | C precomputed once, reloaded by `VLDUI` + `MOVVP` |
| `vcmp f16,0 → ¬C` (Phase 10)       | **eliminated**       | `VCMP` writes P-reg directly — no f16 detour |
| `vnot i1 → C` (Phase 10)           | **eliminated**       | `PXOR P3, P3, P2(=ALLF)` — no-op slot |
| `vcmp 1024xi1 → …` (full-tile)     | **rewritten**        | 32× per-row `VCMP` inside VLOOP |

### 6.4 Why q_offset uses full-VL while q_attn uses brc_b32

The asymmetry between V3 (q_offset, full-VL stream) and V4 (q_attn,
brc_b32 stream) is deliberate and tracks a single distinguishing
fact: **q_offset has two compute consumers per iteration; q_attn has
one.**

#### Same Triton/MLIR shape, different number of consumers

```python
# q_attn:  one consumer
B = (q_attn_arg[:, None] == k_attn_arg[None, :])

# q_offset: TWO consumers using the same broadcast
A = (q_offset[:, None] <=  k_offset[None,  :])
F = (q_offset[:, None] == k_offset[None,  :])
```

In the assembly, the reuse is direct — `V3` and `V2` feed both compares:

```asm
VCMP.LE.s32 P5, V3, V2, P1   ; A_row uses V3 (q_offset row) and V2 (k_offset row)
…
VCMP.EQ.s32 P4, V3, V2, P1   ; F_row REUSES the same V3 and V2     ◄── two consumers
```

#### Cost trade-off

For a **1-consumer** broadcast (q_attn):

| Strategy        | Per-iter load | Per-iter compute | Pre-loop UB cost |
|-----------------|--------------:|-----------------:|-----------------:|
| `brc_b32`       | 4 B           | 1 `VCMP`         | 0                |
| full-VL streaming through tile | 256 B | 1 `VCMP`     | 4096 B           |

`brc_b32` wins outright — same compute, much smaller UB footprint.

For a **2-consumer** broadcast (q_offset):

| Strategy        | Per-iter load | Per-iter compute | Pre-loop UB cost |
|-----------------|--------------:|-----------------:|-----------------:|
| `brc_b32`       | 4 B           | 2 `VCMP`s        | 0                |
| full-VL streaming through tile | 256 B | 2 `VCMP`s    | 4096 B           |

Per-iter compute is identical. The full-VL path's only "loss" is the
4096 B UB tile, but **that tile is going to exist anyway** — the MLIR
allocates it in Phase 1 to feed the i32→i64 widening that powers the
scalar causal compare (Phase 6/8). Once the tile is going to be
built, streaming through it is essentially free, and avoids needing
to keep V4-style scalar live across two compares.

#### The general rule

> **brc_b32 elimination beats tile-materialization when the broadcast
> has one consumer; from two consumers up, streaming through a
> pre-built tile breaks even or wins** — especially if the tile is
> already needed for a different lowering path (here: i32→i64 widen).

This is the same rematerialize-vs-spill trade-off any vector
compiler makes, extended one layer deeper into
"broadcast-at-load-time vs broadcast-into-buffer."

#### Mirror case for V2 (k_offset)

V2 is also full-VL with `#p=0` (constant across iters). The reasoning
is different though: k_offset varies *across lanes* within one vreg
(it's the row direction, not the column being broadcast), so
`brc_b32` does not apply structurally — there is no scalar to
broadcast. Full-VL is the only viable option, and `#p=0` keeps the
same 32-element row live throughout the loop (k_offset is
row-invariant by construction).

#### Summary table

| Operand   | Triton form              | Lane variation | Per-iter consumers | A5 strategy             |
|-----------|--------------------------|----------------|-------------------:|-------------------------|
| q_attn    | `q_attn_arg[:, None]`    | constant       | 1                  | `brc_b32`, tile elim.   |
| k_attn    | `k_attn_arg[None, :]`    | varies         | 1                  | full-VL, `#p=0`         |
| q_offset  | `q_offset[:, None]`      | constant       | **2**              | full-VL stream, tile kept |
| k_offset  | `k_offset[None, :]`      | varies         | **2**              | full-VL, `#p=0`         |

Net: the bool MLIR's 4 broadcast ops + f16 detour ladder shrink to
load-mode flags + a single no-op PXOR. UB footprint drops by roughly
4 × 4096 B ≈ 16 KB just for the eliminated broadcast tiles.

## 7. Per-iter hardware-op tally

Compute portion of the body (excluding loads/stores/sync):

| Class                          | Count | Insns                                  |
|--------------------------------|------:|----------------------------------------|
| Vector-scalar arith (broadcast add) | 1   | `VADDS`                                |
| Vector compare → predicate     | 3     | `VCMP.LE`, `VCMP.EQ` ×2                |
| Vector → predicate convert     | 1     | `MOVVP`                                |
| Predicate algebra              | 4     | `PXOR` (no-op), `POR` ×2, `PAND` ×1    |
| Predicate → vector materialize | 1     | `VSEL.b32`                             |
| **Compute total per iter**     | **10**|                                        |

Plus per-iter memory/scalar overhead: 4× `VLDI` + 1× `VLDAS` + 1× `VLDUI`
+ 2× `SMOV` + 1× `VSTI` = 9 ops. So roughly **19 of 35 body insns** are
shown in the snippet; the remaining 16 are likely additional setup,
sync, or post-compute massaging that the architect elided.

If S3 = 32 iterations (one per output row of the 32×32 tile), the
loop's hardware-op cost for the bool path is ≈ **35 × 32 = 1,120
instructions** for the entire mask result. Cast variant cost will be
higher due to extra vcasts at i1↔f16↔i32 boundaries — to be
quantified once the cast-variant asm is decoded.

## 8. Confidence levels per opcode

Tier-A claims are verified against the local PTO ISA repo
(`~/Documents/Repo/pto-isa/docs/isa/`) **and** the chip-spec
descriptions provided directly by the architect.

| Mnemonic            | Tier | Source of truth                                                              |
|---------------------|:----:|------------------------------------------------------------------------------|
| `PSET.b32`          | **A**| Architect spec (`#0`=ALL, `#8`=VL64, `#15`=ALLF, 4-bit pattern token)        |
| `VLOOPV2`           | **A**| Architect spec (`Sn,#instr,#layer,#last`)                                    |
| `VLDI`              | **A**| Architect spec (`#offset` in alignment units, `#dist` modes 5h00/5h03, `#p`) |
| `VCMP.cond.type`    | **A**| `pto-isa/docs/isa/vector/ops/compare-select/vcmp.md` operand-order example   |
| `POR`/`PAND`/`PXOR` | **A**| `pto-isa/docs/isa/scalar/ops/predicate-generation-and-algebra/{por,pand,pxor}.md` |
| `VSEL.b32`          | **A**| `pto-isa/docs/isa/vector/ops/compare-select/vsel.md` (Vd[i] = mask ? Vt[i] : Vf[i]) |
| `vreg = 256 B`      | **A**| `pto-isa/docs/isa/machine-model/execution-agents.md`                         |
| `VADDS.s32`         | B    | "vector add scalar" — strong naming inference; arch spec not yet provided    |
| `MOVVP.b32`         | B    | "move vreg → predicate"; mode bit `#0` semantics inferred (LSB-extract vs ≠0 test) |
| `VLDAS`             | C    | "vector load address (set up unaligned ctx)"; pattern-matched from usage     |
| `VLDUI`             | C    | "vector load unaligned, immediate"; field meanings unclear without spec      |
| `VSTI`              | C    | "vector store immediate"; the `#16,#2,...,#1` field interpretation unclear   |
| `_V310` suffix      | C    | Chip-revision encoding variant — meaning of digit pattern unknown            |

## 9. Open questions / TODO

To finalize the table to 100% Tier-A:

1. `VSTI vd, [sn], #offset, #?, Pmask, #?` — meanings of the two unlabeled fields
2. `MOVVP.b32 Pd, Vs, #mode` — what the `#mode` immediate encodes
3. `VLDAS ULDn, [sn]` — exactly what state `ULDn` holds
4. `VLDUI vd, ULDn, [sn], #imm` — relationship between ULDn and the offset register
5. `VADDS.type Vd, Vs, Sn, Pmask` — broadcast-add semantics formally stated
6. `_V310` suffix — what the encoding variant identifies (chip revision? layer config?)

## 10. Reproducibility

The bool-variant `.o` file from which this assembly was disassembled
lives at:
- `/home/ray/a5_capture_bool/mask_kernel_a5.o` on GCP VM `cann9-test`
  (now stopped — start it to re-disassemble)
- `mask_kernel_a5.o` produced by:
  ```bash
  source /home/ray/Ascend/cann-9.0.0/set_env.sh
  bishengir-compile-a5 --enable-hivm-compile --enable-hfusion-compile \
    -o mask_kernel_a5.o /home/ray/mask_kernel.ttadapter
  ```

Disassembly tooling: TBD (the disassembler used to produce the listing
above was provided externally by the architect; the local tooling chain
needs documenting).
