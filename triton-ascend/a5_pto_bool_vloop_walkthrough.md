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

### `VDUPS.type Vd, Sn, Pmask, #pos`

Vector duplicate scalar — broadcast a scalar register's value to every
lane of `Vd` under `Pmask`. From `pto-isa/.../vector/ops/predicate-and-materialization/vdup.md`:
"Duplicate scalar or vector element to all lanes." The `#pos` is a
position selector (typically `#1` for "broadcast the scalar input as-is";
other positions select a lane of a vreg input).

```
Vd[i] ← Sn       for each lane i where Pmask[i] = 1
```

Equivalent semantically to `VLDI` with `#dist = brc_b32`, but the source is a
**scalar register** rather than a UB address. Useful when the broadcast
value is computed in scalar code (e.g., a program-id-derived constant)
rather than read from memory.

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
VLDI V2, [S6],  #0,  #0, #0         ; dist=normal, full-VL load (256 B = 64 i32 lanes)
                                    ; addr = S6 + 0·32 = S6
                                    ; p=0  → S6 unchanged (constant load each iter)
                                    ; ROLE: k_offset[None, :] data — row-invariant across iters
                                    ;       (Algorithmic row width is 32 elems; vreg holds 64
                                    ;        lanes. Whether the upper 32 lanes are padding,
                                    ;        a packed second row, or a replicated copy is not
                                    ;        determinable from this snippet — see §11.)

VLDI V3, [S69], #16, #0, #1         ; dist=normal, full-VL load
                                    ; addr = S69
                                    ; p=1  → S69 ← S69 + 16·32 = S69 + 512 B (post-incr)
                                    ; ROLE: q_offset[:, None] pre-vbrc tile, streaming per iter;
                                    ;       row r contains q_offset[r] replicated across the
                                    ;       row's 32 elements (upper-lane content: see §11)

VLDI V4, [S68], #1,  #3, #1         ; dist=brc_b32 (5h03): 1 i32 broadcast → all 64 lanes
                                    ; addr = S68
                                    ; p=1  → S68 ← S68 + 1·4 = S68 + 4 B (per-iter scalar stream)
                                    ; ROLE: q_attn[i] — one new scalar per iter, replicated to
                                    ;       all 64 lanes (brc_b32 makes upper-lane question moot)

VLDI V5, [S10], #0,  #0, #0         ; dist=normal, full-VL load
                                    ; addr = S10, p=0 (constant load)
                                    ; ROLE: k_attn[None, :] data — row-invariant
                                    ;       (Algorithmic row width 32; upper-lane content
                                    ;        unverified, see §11.)

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

### 3.1 What the per-iter `VADDS` is doing

```asm
VADDS.s32 V2, V2, S8, P1            ; V2 ← V2 + S8 (lane-wise add of broadcast scalar)
```

`VADDS.s32 Vd, Vs, Sn, Pmask` is **vector-add-scalar**: the scalar
`Sn` is broadcast to all lanes of `Vs`, lane-wise added, and the
result is written to `Vd` in the lanes selected by the predicate
mask `Pmask`. Equivalent expression:

```
V2[i] ← V2[i] + S8       for each lane i where P1[i] = 1
```

#### What this does *not* map to in `mask_fn`

`mask_fn` itself contains no addition:

```python
def mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE: tl.constexpr):
    if TYPE == 1:
        triu_causal = (q_offset[:, None] <= k_offset[None, :])
        …
```

It takes `q_offset` / `k_offset` as **already-computed arguments**
and only compares them. So no line of mask_fn produces this VADDS.

#### Where the addition actually comes from — the launcher

The compiled `mask_kernel` is `mask_fn` **inlined into a launcher**
that prepares the offset arrays. The standard Triton-Ascend pattern
for the launcher is:

```python
# launcher kernel that wraps mask_fn
pid_n   = tl.program_id(1)            # block index along the "k" axis
base    = tl.arange(0, BLOCK_N)       # constant pattern: [0, 1, …, 31]
k_offset = base + pid_n * BLOCK_N     # ◄══ this addition becomes the VADDS

mask = mask_fn(q_attn_arg, k_attn_arg, q_offset, k_offset, TYPE=1)
```

When bishengir-compile-a5 fuses the launcher with mask_fn into a
single `mask_kernel`, the offset-computation arithmetic ends up in
the same body as the comparisons.

#### The hardware mapping

```
V2  ← VLDI [S6]              ;  load the constant pattern, e.g. arange(0, 32)
                             ;  V2 = [0, 1, 2, …, 31]   (zero-based lane indices)

S8  ← (set pre-loop, not in snippet)
                             ;  S8 = pid_n × BLOCK_N    (block-dependent stride scalar,
                             ;        passed in as one of the kernel's i32 args 7..12)

VADDS.s32 V2, V2, S8, P1     ;  V2 ← arange(0, 32) + pid_n · BLOCK_N
                             ;     ◄══ "k_offset = pid_n * BLOCK_N + arange(0, BLOCK_N)"
```

After VADDS, V2 holds the actual `k_offset[None, :]` values (the
absolute positions in the global k axis), which is exactly what the
subsequent VCMPs (`VCMP.LE P5, V3, V2` and `VCMP.EQ P4, V3, V2`)
need.

#### Why VADDS rather than just loading a precomputed k_offset

Two reasons:

1. **Avoids materialising a 32-element k_offset buffer in GM/UB** —
   only `BLOCK_N` and `pid_n` are passed in as scalars; the offset
   array is reconstructed on-chip from `arange + scalar`.
2. **Reuses one constant pattern across all program blocks** —
   `arange(0, 32)` is identical for every block; only the scalar S8
   changes per block.

#### Confidence

| Claim | Tier | Reason |
|---|:---:|---|
| `VADDS` is vector-add-scalar with the operand order shown | A | Operand convention matches the `vadds` family in the PTO ISA repo |
| The addition originates in the launcher's `pid * BLOCK + arange` pattern | B | Strong Triton-Ascend convention; not directly verified for *this* kernel |
| `S8 = pid_n × BLOCK_N` and `V2 = arange(0, 32)` specifically | B | Plausible defaults; resolving requires either the launcher source or disassembly of the pre-loop scalar setup that initialises S8 and the buffer at `[S6]` |

This VADDS reading is the most natural one given the kernel's
structure, but a definitive mapping needs the upstream launcher
or the pre-loop assembly.

### 3.2 The full body is two passes — pass B (lines 23–38)

The original 22-line snippet I documented in §3 was only **half** of
the VLOOP body. The full body (per `#instr=35` in `VLOOPV2_V310 S3, #35, #1, #1`)
is 35 instructions, and lines 23–38 of `~/Documents/docs/assembler.as`
reveal a **second compute pass** that mirrors pass A's structure but
operates on different source/destination addresses.

```asm
;══════════════════════════════════════════════════════════════════════════════
; Pass B  (lines 23–38, structurally identical to pass A but different addrs)
;══════════════════════════════════════════════════════════════════════════════
VLDI V2, [S14], #0,  #0, #0         ; V2 ← UB[S14], normal full-VL, no incr
                                    ;       ◄══ k_offset for pass B's region (different from pass A's [S6])

VLDI V3, [S66], #16, #0, #1         ; V3 ← UB[S66], normal full-VL, +512 B post-incr
                                    ;       ◄══ q_offset stream for pass B (different stream from pass A's [S69])

VLDI V5, [S16], #0,  #0, #0         ; V5 ← UB[S16], normal full-VL, no incr
                                    ;       ◄══ k_attn for pass B's region

VLDAS ULD0, [S18]                   ; UnalignReg ULD0 ← S18  (pass B's precomputed-C buffer base)

VADDS.s32 V2, V2, S8, P1            ; V2 += S8        (same program-id stride as pass A; reuses S8)
                                    ;       Note: source typoed as "VADDS,s32" in the assembler file —
                                    ;       harmless transcription artifact

VCMP.LE.s32 P5, V3, V2, P1          ; P5 = (V3 ≤ V2)   — A_row for pass B's region
VCMP.EQ.s32 P4, V4, V5, P1          ; P4 = (V4 == V5)  — B_row for pass B's region
                                    ;       (V4 = q_attn[i] is REUSED unchanged from pass A!)

VLDUI V6, ULD0, [S70], #0           ; V6 ← unaligned load (pass B's C bytes)
                                    ;       (S70 is whatever pass A's tail set it to via SMOV S70, S18)

MOVVP.b32 P3, V6, #0                ; P3 = C  for pass B
PXOR P3, P3, P2, P1                 ; (no-op — same vnot-collapse as pass A)
POR  P3, P4, P3, P1                 ; D = B | C
PAND P3, P5, P3, P1                 ; E = A & D
VCMP.EQ.s32 P4, V3, V2, P1          ; P4 = F (q_off == k_off) for pass B
POR  P3, P3, P4, P1                 ; result = E | F
VSEL.b32 V2, V1, V0, P3             ; i1 → i32 widening (V1, V0 reused unchanged from pass A)
VSTI V2, [S65], #16, #2, P1, #1     ; store V2 to UB[S65 + …]
                                    ;       ◄══ DIFFERENT output address from pass A's [S67]
```

#### What's the same and what changes between passes

| Quantity                             | Pass A address | Pass B address | Reused? |
|--------------------------------------|----------------|----------------|---------|
| k_offset source                      | `[S6]`         | `[S14]`        | no      |
| q_offset stream                      | `[S69]`        | `[S66]`        | no      |
| k_attn source                        | `[S10]`        | `[S16]`        | no      |
| Precomputed C buffer (VLDAS)         | `[S12]`        | `[S18]`        | no      |
| Output destination (VSTI)            | `[S67]`        | `[S65]`        | no      |
| q_attn broadcast scalar (V4)         | brc_b32 from `[S68]` | **same V4** | **YES** |
| Program-id stride (S8)               | constant       | constant       | YES     |
| Constant tiles V0 (zeros), V1 (ones) | preloaded      | preloaded      | YES     |
| Predicate seeds P1 (VL64), P2 (ALLF) | preloaded      | preloaded      | YES     |

#### What this implies — likely interpretation

The two passes share `q_attn[i]` (V4) and the program-id stride (S8),
but everything else — k_offset, k_attn, precomputed C, output buffer
— is different. The most consistent interpretation is that the
kernel is computing **mask outputs for two independent key blocks
per VLOOP iter**, against the same query block:

```
                      query block (one set of q_attn, q_offset)
                                        │
                          ┌─────────────┴─────────────┐
                          ▼                           ▼
                    key block #A                  key block #B
        (k_attn @ [S10], k_offset @ [S6])  (k_attn @ [S16], k_offset @ [S14])
        (C precomp @ [S12])                 (C precomp @ [S18])
        (output mask @ [S67])               (output mask @ [S65])
```

This is a multi-block "fan-out" pattern — one query, two key blocks,
two output masks per iter. Confirming the algorithmic structure
needs the launcher source (which we don't have); this interpretation
is **Tier B**.

#### What this resolves about §11 (the upper-32-lane question)

The full body length is now confirmed at 35 instructions: pass A
(19 insns: lines 4–22) + pass B (16 insns: lines 23–38) = 35 ✓.

This **does not** by itself decide between Layouts A / B / C in §11
— that question is about what's in the upper 32 lanes of one vreg
during a single VCMP, not about how many compute passes a single
iter performs. But it does mean **§11's "Layout B" is not the
operative pattern here** — Layout B postulated "two output rows of
the same tile packed into one vreg," whereas what we see is "two
output rows of two *different* tiles, each computed in a separate
pass with its own VCMPs and VSTI." The work is unrolled across
*tiles*, not within a single vreg's 64 lanes.

So §11's question (padded vs packed-within-vreg vs replicated)
remains open for what's in the upper 32 lanes during one VCMP, and
the resolution paths in §11 still apply.

### 3.2.1 Why two passes — launcher unroll-by-2 over key blocks

The most consistent explanation for the two-pass body is that
`bishengir-compile-a5` **unrolled the launcher's loop over key
blocks by a factor of 2** during inlining. Each VLOOP iteration
processes one query row against **two** key blocks, sharing the
expensive query-side state across the two unrolled bodies.

#### Visual: the unrolled VLOOP body

![VLOOPV2 body — two passes per iter, V4 shared](figures/a5_two_pass_unroll.png)

The shared-resources box at top (yellow) holds V4 = q_attn[i], S8,
V0/V1, P1/P2 — all loaded or set up once per iter. Two side-by-side
pass boxes (blue = pass A, green = pass B) each load their own
key-side data (k_attn, k_offset, precomputed C) and write to their
own output buffer. The orange V4 arrows from the shared box into
both passes show the q_attn[i] reuse — V4 is loaded **once** but
fed into the VCMP.EQ in **both** passes.

#### Visual: the launcher transformation that produced this

![Launcher unroll-by-2 — before vs. after](figures/a5_unroll_before_after.png)

Left: the straight launcher form has an outer loop over key blocks
and an inner VLOOP over query rows; q_attn[i] is reloaded once per
inner iter, so total q_attn loads = `N · 32 = 32N`. Right: after
unroll-by-2 over the outer (key-block) loop, the inner VLOOP body
contains both passes; q_attn[i] is loaded once per VLOOP iter and
reused across both passes, so total q_attn loads = `(N/2) · 32 = 16N`
— exactly half. VLOOP-boundary overhead is also amortized over twice
as many key blocks per VLOOP-set up.

The cost is that the per-iter body grows from 19 instructions
(single-pass) to 35 instructions (matching the `#instr=35` we
observed).

#### The launcher pattern, before and after unrolling

A typical Triton-Ascend attention-mask launcher iterates over key
blocks for one query block:

```
BEFORE UNROLLING (conceptual launcher form)
──────────────────────────────────────────────────────────────────

for k_block in [0, 1, 2, …, N−1]:                ◄── outer loop over key blocks
    load k_attn[k_block], k_offset[k_block], precompute C[k_block]
    for i in [0..31]:                            ◄── inner loop over query rows
        load q_attn[i]                            ← ONE load per (k_block, i)
        compute mask[k_block][i, :]
        store output[k_block][i]


Cost: N × 32 = 32N q_attn loads total
```

After unrolling the *outer* loop by 2 and fusing the inner-loop
bodies, the compiler produces the structure we see in the assembly:

```
AFTER UNROLLING (matches the captured assembly)
──────────────────────────────────────────────────────────────────

for k_pair in [0, 2, 4, …, N−2]:                 ◄── outer loop over PAIRS of key blocks
    load k_block_A data: k_attn[A], k_offset[A], C[A]
    load k_block_B data: k_attn[B], k_offset[B], C[B]
    for i in [0..31]:                            ◄── this is the VLOOPV2 we see
        load q_attn[i]                            ← ★ ONE load shared by both passes
        ┌─ pass A ─────────────────────────┐
        │ compute mask[k_block_A][i, :]    │
        │ store output[k_block_A][i]       │
        └──────────────────────────────────┘
        ┌─ pass B ─────────────────────────┐
        │ compute mask[k_block_B][i, :]    │  ◄── reuses q_attn[i] in V4 from pass A
        │ store output[k_block_B][i]       │
        └──────────────────────────────────┘


Cost: (N/2) × 32 × 1 = 16N q_attn loads total      (HALF the unrolled-version cost)
```

The `for i in [0..31]` is the actual VLOOP we see; the outer pair
loop lives in code we haven't disassembled.

#### Data-flow per VLOOP iter — what's shared vs duplicated

```
                            ╔══════════════════════════════════════════╗
                            ║       per-iter shared resources           ║
                            ║   (loaded/computed ONCE per iter)         ║
                            ║                                           ║
                            ║   V4  =  q_attn[i]   (brc_b32, +4 B)      ║
                            ║   S8  =  pid · BLOCK   (pre-loop scalar)  ║
                            ║   V0, V1 (preloaded constants)            ║
                            ║   P1, P2 (preloaded predicates)           ║
                            ╚══════════════════════════════════════════╝
                                  │                       │
                                  │ V4 used by both       │
                                  ▼                       ▼
       ┌──────── PASS A ───────────────┐    ┌──────── PASS B ───────────────┐
       │  KEY BLOCK A                  │    │  KEY BLOCK B                  │
       │                               │    │                               │
       │  V2  ← VLDI [S6]    k_offset_A│    │  V2  ← VLDI [S14]   k_offset_B│
       │  V3  ← VLDI [S69]   q_off str │    │  V3  ← VLDI [S66]   q_off str │
       │  V5  ← VLDI [S10]   k_attn_A  │    │  V5  ← VLDI [S16]   k_attn_B  │
       │  ULD0 ← VLDAS [S12] C_A bytes │    │  ULD0 ← VLDAS [S18] C_B bytes │
       │                               │    │                               │
       │  VADDS V2 += S8               │    │  VADDS V2 += S8               │
       │  VCMP.LE  P5 ← (V3, V2)       │    │  VCMP.LE  P5 ← (V3, V2)       │
       │  VCMP.EQ  P4 ← (V4, V5) ◄─────┤────┤────► VCMP.EQ  P4 ← (V4, V5)   │
       │            ▲ V4 from above    │    │     ▲ V4 REUSED, no reload    │
       │  VLDUI V6, MOVVP P3 ← C_A     │    │  VLDUI V6, MOVVP P3 ← C_B     │
       │  POR/PAND/POR boolean algebra │    │  POR/PAND/POR boolean algebra │
       │  VSEL.b32 V2 ← P3 ? V1 : V0   │    │  VSEL.b32 V2 ← P3 ? V1 : V0   │
       │  VSTI V2, [S67]   output_A[i] │    │  VSTI V2, [S65]   output_B[i] │
       └───────────────────────────────┘    └───────────────────────────────┘
```

Side-by-side, the structural symmetry is exact. Every key-side
resource (k_attn, k_offset, precomputed C, output buffer) gets its
own copy per pass; every query-side resource (V4, S8, predicate
seeds, constant tiles) is loaded once at the top of the iter and
referenced by both passes.

#### Why V4 specifically — the structural test

V4 is the **only** operand that satisfies both:
1. *Varies per iter* — so it cannot be hoisted out of the loop entirely.
2. *Is identical in both passes within one iter* — so it CAN be shared between them.

| Operand            | Varies per iter? | Identical across passes? | Sharable? |
|--------------------|:---:|:---:|:---:|
| **q_attn (V4)**    | yes | **yes** (same q_attn[i] feeds both key blocks) | ✓ shared in asm |
| q_offset (V3)      | yes | no — pass A from `[S69]`, pass B from `[S66]` | ✗ |
| k_attn   (V5)      | no  | no — different key block each pass            | ✗ |
| k_offset (V2)      | no  | no — different key block each pass            | ✗ |
| precomputed C (P3) | no  | no — different per key block                  | ✗ |

V4 is the unique row with "yes" in both columns. The fact that the
assembly does NOT reload V4 between passes is the strongest
single-instruction evidence that the unroll axis is "key block,"
not anything else.

#### What this rules out

| Hypothesis | Why ruled out |
|---|---|
| Two halves of one wider tile (32×64 instead of 32×32) | Same C should serve both halves; assembly has different VLDAS sources `[S12]` vs `[S18]`. |
| Two adjacent rows packed in one vreg's 64 lanes (Layout B from §11) | Same C should serve both rows; same V4 should *not* (q_attn[i] ≠ q_attn[i+1]). Both checks fail. |
| Pure ILP-driven unroll on identical data | Pure ILP unroll wouldn't reach into different output buffers (`[S65]` vs `[S67]`). |

#### What's still Tier-B

The launcher source isn't in our hand, so we can't verify directly
that the outer loop iterates over key blocks (vs. some other axis
like attention head, or token-batch position). But the structural
fingerprint — shared query-side, distinct key-side, distinct output
buffers, distinct precomputed-C — matches the unroll-over-key-blocks
explanation and rules out the alternatives I can think of.

#### Why this is a *deliberate* optimization, not a missed one

This is the inverse of the "missed optimizations" in §6.6/§6.7/§6.8.
Here `hivmc-a5` (or its driver) actively did the right thing:

- **Saved 16N q_attn loads** by sharing V4 across passes.
- **Hid load latency** by interleaving pass A's VCMPs with pass B's
  VLDIs (instruction-level parallelism on the load and compute pipes).
- **Amortized VLOOP-boundary overhead** over twice as many key blocks.

It's the same idea as classical "unroll-and-jam" applied at the
launcher-loop level. The presence of this optimization tells us
hivmc-a5 *can* do non-trivial loop transformations — it just isn't
applying them to all the cases we identified as missed.

### 3.3 The post-loop `VDUPS.b32` (line 39)

```asm
VDUPS.b32 V0, S20, P1, #1           ; V0 ← S20 broadcast to all 64 lanes (b32, mask P1, position #1)
```

**`VDUPS`** = "vector duplicate scalar." Per the PTO ISA repo
(`pto-isa/.../vector/ops/predicate-and-materialization/vdup.md`):
"Duplicate scalar or vector element to all lanes." Semantically
equivalent to `VLDI` with `#dist = brc_b32`, but the source is a
**scalar register** (`S20` here), not a UB address.

Position of this instruction (after VLOOPV2's #35-insn body) places
it **post-loop**. Its role is most likely **resetting V0 for a
subsequent code section** — e.g., V0 was used as the all-zero tile
in the loop's `VSEL.b32 V2, V1, V0, P3`, and the same physical V0 is
about to be repurposed for some downstream step that wants `S20`
broadcast across all lanes. The Tier on what S20 holds is C; without
the surrounding code the role is inferred from position only.

### 3.4 Updated full instruction listing

For reference, the complete content of `~/Documents/docs/assembler.as`:

```asm
;══════════ Pre-loop predicate setup ══════════
PSET.b32 P1, #8                     ; P1 ← VL64 (all 64 i32 lanes active)
PSET.b32 P2, #15                    ; P2 ← ALLF (all lanes false; PXOR no-op pattern)

;══════════ VLOOP header ══════════
VLOOPV2_V310 S3, #35, #1, #1        ; iter count = S3, body length = 35,
                                    ; layer = innermost, last loop in this layer

;══════════ Body — Pass A  (lines 4–22, 19 insns) ══════════
VLDI V2, [S6],  #0,  #0, #0         ; k_offset row (pass A)
VLDI V3, [S69], #16, #0, #1         ; q_offset stream (pass A)
VLDI V4, [S68], #1,  #3, #1         ; q_attn[i] brc_b32 — SHARED across both passes
VLDI V5, [S10], #0,  #0, #0         ; k_attn row (pass A)
VLDAS ULD0, [S12]                   ; pass A's precomputed-C buffer base
SMOV.b32 S70, S12                   ; S70 ← S12
VADDS.s32 V2, V2, S8, P1            ; V2 += pid·BLOCK
VCMP.LE.s32 P5, V3, V2, P1          ; A_row = triu_causal
VCMP.EQ.s32 P4, V4, V5, P1          ; B_row = (q_attn == k_attn)
VLDUI V6, ULD0, [S70], #0           ; load C bytes
SMOV.b32 S70, S18                   ; ★ advance S70 to S18 — sets up pass B's C source
MOVVP.b32 P3, V6, #0                ; P3 = C (pass A)
PXOR P3, P3, P2, P1                 ; (no-op vnot slot)
POR  P3, P4, P3, P1                 ; D = B | C
PAND P3, P5, P3, P1                 ; E = A & D
VCMP.EQ.s32 P4, V3, V2, P1          ; F_row = (q_off == k_off)
POR  P3, P3, P4, P1                 ; result = E | F
VSEL.b32 V2, V1, V0, P3             ; i1 → i32
VSTI V2, [S67], #16, #2, P1, #1     ; store result to UB[S67]

;══════════ Body — Pass B  (lines 23–38, 16 insns) ══════════
VLDI V2, [S14], #0,  #0, #0         ; k_offset row (pass B's region)
VLDI V3, [S66], #16, #0, #1         ; q_offset stream (pass B's region)
VLDI V5, [S16], #0,  #0, #0         ; k_attn row (pass B's region)
VLDAS ULD0, [S18]                   ; pass B's precomputed-C buffer base
                                    ; (note: no SMOV here — S70 was set by pass A's tail SMOV S70, S18)
VADDS.s32 V2, V2, S8, P1            ; V2 += pid·BLOCK (same S8 — both passes share program-id stride)
VCMP.LE.s32 P5, V3, V2, P1          ; A_row for pass B
VCMP.EQ.s32 P4, V4, V5, P1          ; B_row — V4 reused unchanged from pass A
VLDUI V6, ULD0, [S70], #0           ; load C bytes for pass B
MOVVP.b32 P3, V6, #0                ; P3 = C (pass B)
PXOR P3, P3, P2, P1                 ; (no-op vnot slot)
POR  P3, P4, P3, P1                 ; D
PAND P3, P5, P3, P1                 ; E
VCMP.EQ.s32 P4, V3, V2, P1          ; F_row for pass B
POR  P3, P3, P4, P1                 ; result for pass B
VSEL.b32 V2, V1, V0, P3             ; i1 → i32
VSTI V2, [S65], #16, #2, P1, #1     ; store result to UB[S65]   ◄── different from pass A's [S67]

;══════════ Post-loop ══════════
VDUPS.b32 V0, S20, P1, #1           ; reset V0 ← S20 broadcast (likely staging V0 for downstream code)
```

#### Notes on the new structure

- **Body length matches `#instr=35`** (19 + 16 = 35). No body insns are missing.
- **V4 lifetime**: q_attn[i] (V4) is loaded once per iter via `brc_b32`
  and **reused across both passes**. Pass B does not reload V4. This
  is the dominant compute reuse between passes — both compares
  `(q_attn[i] == k_attn[j_passA])` and `(q_attn[i] == k_attn[j_passB])`
  share V4.
- **S8 reuse**: same program-id stride applied in both passes' VADDS.
- **V0, V1 reuse**: the constant 0/1 tiles are loaded once (somewhere
  pre-loop, not shown) and used in both VSEL ops without reload —
  Optimization 6 hoisting these is correct *and consistent with how
  the kernel already treats them in pass B*.
- **`SMOV S70, S18` in pass A acts as the *prologue* to pass B's
  unaligned-load**: by the time pass B reaches `VLDUI V6, ULD0, [S70], #0`,
  S70 is already pointing at S18.

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

#### Same Triton/MLIR shape, different number of consumers per iter

```python
# q_attn:  one consumer per iter
B = (q_attn_arg[:, None] == k_attn_arg[None, :])

# q_offset: two consumers per iter
A = (q_offset[:, None] <=  k_offset[None,  :])
F = (q_offset[:, None] == k_offset[None,  :])
```

In the assembly, the reuse is direct — `V3` and `V2` feed both compares:

```asm
VCMP.LE.s32 P5, V3, V2, P1   ; A_row uses V3 (q_offset row) and V2 (k_offset row)
…
VCMP.EQ.s32 P4, V3, V2, P1   ; F_row REUSES the same V3 and V2
```

The "consumer count" is interesting context, but as the cost model
below shows, **it doesn't actually drive the decision** — brc_b32
wins on raw cost regardless of N. The real driver is opaque without
deeper disassembly; see hypotheses below.

#### Cost calculation

Three resources matter:

1. Hardware instruction count
2. UB footprint (bytes occupied)
3. UB bandwidth (bytes loaded over the loop)

Let `T` = number of VLOOP iters (= 32), `N` = consumers per iter, and
`K` ≈ 16 = the ops needed to fill a 4096 B tile via `vbrc` (one vector
op writes 256 B = 64 i32 lanes; 1024 / 64 = 16 ops).

**Strategy A — brc_b32 (per-iter scalar broadcast):**

| Cost           | Formula     | T=32, N=1 | T=32, N=2 |
|----------------|-------------|----------:|----------:|
| Pre-loop insns | 0           | 0         | 0         |
| Per-iter insns | `1 + N`     | 2         | 3         |
| **Total insns**| `T·(1 + N)` | **64**    | **96**    |
| UB tile bytes  | 0           | 0         | 0         |
| Bytes loaded   | `T · 4`     | 128       | 128       |

**Strategy B — full-VL streaming through pre-built tile:**

| Cost           | Formula           | T=32, N=1 | T=32, N=2 |
|----------------|-------------------|----------:|----------:|
| Pre-loop insns | `K` (vbrc fill)   | 16        | 16        |
| Per-iter insns | `1 + N`           | 2         | 3         |
| **Total insns**| `K + T·(1 + N)`   | **80**    | **112**   |
| UB tile bytes  | 4096              | 4096      | 4096      |
| Bytes loaded   | `T · 256`         | 8192      | 8192      |

**Difference (A vs B):**

| Resource       | At any N             |
|----------------|---------------------:|
| Insn count     | A wins by `K` ≈ 16   |
| UB footprint   | A wins by 4096 B     |
| Bandwidth      | A wins by 8064 B     |

**Strategy A always wins on every metric**, regardless of `N`. The
per-iter compute (`N` `VCMP`s) is identical between A and B —
`VCMP` has no implementation difference based on which load
mode produced the operand register. So the consumer count cancels
out of the comparison.

#### Then why does hivmc-a5 keep the q_offset tile?

Three plausible reasons, in rough order of likelihood:

1. **The MLIR forces the tile to exist anyway**, and hivmc-a5 didn't
   prove it dead.
   The MLIR explicitly allocates the q_offset 32×32 i32 tile in
   Phase 1 and uses it in a full-tile `vcmp` in Phase 5. To
   *eliminate* the tile, hivmc-a5 must rewrite the Phase 5 consumer
   to brc_b32 streaming AND prove no other path needs the tile.
   For q_offset, the MLIR also wires the same source into the
   i32→i64 widen path (Phases 2, 6, 8) — that secondary path
   apparently complicates the dataflow analysis enough that the
   tile-elimination rewrite doesn't fire. For q_attn there's no
   secondary path, so elimination succeeds.

2. **Hidden hardware costs not in the simple cost model.**
   - `brc_b32` loads might pipeline differently than normal loads
     (replication on the load path could add cycles or bus contention).
   - There might be a per-cycle `brc_b32` issue rate ceiling, so
     using brc_b32 for *every* column-broadcast operand could
     serialize the load engine.
   - Register liveness: V3 is live across two compares separated by
     several other instructions; full-VL might schedule better than
     brc_b32 in that window. (Speculative — not verified.)

3. **Compiler heuristic, not optimum.**
   hivmc-a5 may have a coded heuristic — e.g., "default to keeping
   the tile when ≥2 consumers exist," or "default to streaming when
   the source has any other downstream user" — that doesn't derive
   from cost. Heuristics like this exist in real compilers because
   global cost analysis is expensive.

The honest answer is that **without disassembling more of the kernel
(particularly the pre-loop tile-construction insns and the dataflow
around the i64 path) we can't tell which hypothesis dominates.** The
2-consumer count is a coincidence of the situation, not a derived
break-even.

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

Net: 3 of 4 i32 broadcast tiles are eliminated (q_attn, k_attn,
k_offset — the latter two trivially, since their tiles are just one
row replicated 32× and any single row can be read directly from the
source). The q_offset tile is kept-and-streamed. UB footprint drop
is ≈ 3 × 4096 B = 12 KB just from the eliminated i32 broadcast
tiles, plus the f16 broadcast tile and i64 broadcast tile that the
MLIR's Phase 6/8 build but hivmc-a5 collapses (further savings).

### 6.5 Visual comparison — q_attn (brc_b32) vs q_offset (full-VL)

#### UB layout before the loop runs

```
q_attn path  (brc_b32 streaming — tile ELIMINATED):

  S68 ────────┐
              ▼
  ┌──────────────────────────────────┐
  │ q_attn source: 32 × i32 = 128 B  │   ◄── only this exists in UB
  │ [q[0]][q[1]][q[2]] … [q[31]]     │
  └──────────────────────────────────┘
                                                                    
  (no 4096-byte 32×32 broadcast tile is built)



q_offset path  (full-VL streaming — tile KEPT):

  ┌──────────────────────────────────┐
  │ q_offset source: 32 × i32 = 128 B│   (small, not directly read by V3)
  └──────────────────────────────────┘
                  │
                  │  pre-loop `vbrc` populates ↓
                  ▼
  S69 ────────┐
              ▼
  ┌──────────────────────────────────┐
  │ q_offset 32×32 i32 tile = 4096 B │   ◄── V3 streams through this
  │ row 0 : [q[0]][q[0]] … [q[0]]   │
  │ row 1 : [q[1]][q[1]] … [q[1]]   │
  │ row 2 : [q[2]][q[2]] … [q[2]]   │
  │   …                              │
  │ row 31: [q[31]][q[31]]…[q[31]]  │
  └──────────────────────────────────┘
```

#### Per-iter data flow

```
q_attn  (V4 via brc_b32, +4 B/iter):

  iter i:
    ┌──┐ read 4 B at [S68]
    │q[i]│ ──────► broadcast ──────►  V4 = [q[i],q[i],q[i],…,q[i]]
    └──┘                              (64 lanes, all equal)
         S68 ← S68 + 4   (advance to next scalar)



q_offset  (V3 via full-VL, +512 B/iter):

  iter i:
    ┌──────────────────────────────┐
    │ row i of tile:               │ read 256 B at [S69]
    │ [q[i],q[i],…,q[i], pad,pad…] │ ──────►  V3 = [q[i],…,q[i], pad,…]
    └──────────────────────────────┘          (64 lanes, first 32 equal)
         S69 ← S69 + 512   (advance past row + alignment gap)
```

#### Compute graph — observed reuse (not the cost driver)

```
q_attn   (one VCMP per iter):              q_offset  (two VCMPs per iter):

       V4 (q[i] brc)                              V3 (q[i] from tile row)
            │                                       ╲          ╲
            ▼                                        ╲          ╲
        VCMP.EQ ─► P4 (B_row)                     VCMP.LE     VCMP.EQ
            ▲                                       /            /
            │                                      /            /
       V5 (k_attn row)                          V2 (k_offset row + S8)
                                                   /            /
                                                  ▼            ▼
                                               P5 (A_row)   P4 (F_row)
```

This is what the kernel does, but per the cost analysis in §6.4 it
is **not** what causes hivmc-a5 to choose differently — both
strategies' per-iter cost is `1 load + N compares` regardless.

#### Decision flow — the actual question

```
              Does the MLIR commit to building this broadcast tile
              for some reason hivmc-a5 cannot rewrite away?
                                  │
                       ┌──────────┴──────────┐
                       no                    yes
                       │                      │
                  ┌────▼─────┐           ┌────▼──────┐
                  │ brc_b32  │           │ keep tile,│
                  │ wins on  │           │ stream    │
                  │ all      │           │ full-VL   │
                  │ metrics  │           │ through it│
                  └──────────┘           └───────────┘
                  (q_attn,                (q_offset)
                   k_attn,
                   k_offset)
```

The numbers in §6.4 say brc_b32 always wins on op count, UB
footprint, and bandwidth. So hivmc-a5's actual choice between A and
B depends on **whether it can prove the tile is dead** — not on a
clean cost-derived break-even. In practice that proof succeeds for
q_attn / k_attn / k_offset and fails for q_offset, almost certainly
because q_offset has the secondary i32→i64 widen path that
complicates the dataflow.

#### Why the q_offset tile survives — the secondary path

The MLIR commits q_offset to two consumers at the source level:

```
MLIR Phase 1:           vbrc q_offset 32×1 i32  → 32×32 i32 tile  (4096 B at UB c0)
                                                 ↓
                                        Phase 5: full-tile vcmp (F)

MLIR Phase 2:           vcast    32-elem        → 32-elem i64
MLIR Phase 6:           vbrc i64-row-vector     → 32×32 i64 tile  (8192 B at UB c19488)
MLIR Phase 8:           scalar scf.for          → 1024×i8 result tile

      [hivmc-a5 rewrites Phase 8 to a vector compare. The i64 tile
       becomes dead. But the i32 32×32 tile from Phase 1 has the
       Phase 5 full-tile vcmp as a downstream consumer the MLIR
       explicitly wired, plus the i64 widen reads from the same
       source row — making the source's liveness span longer than
       q_attn's. That probably tips hivmc-a5 toward keeping the
       tile rather than rewriting both consumers to brc_b32.]
```

q_attn has no analogous secondary path — its source is read only by
the Phase 1 `vbrc`, so once hivmc-a5 fuses the vbrc + Phase 5 vcmp
into a brc_b32-driven per-row VCMP, the source can be referenced
directly and the tile drops out. q_offset's extra outgoing edge
(into the i64 widen) keeps the source alive and apparently keeps
the tile-elimination rewrite from firing.

### 6.6 Why C lives in UB instead of a P-reg — and two missed optimizations

The third instance of the same pattern. C = `(k_attn_arg[None, :] == 0)`
is the only one of the four predicates {A, B, C, F} that is
**row-invariant** — it depends only on column index `j`, never on
row index `i`. So computing it once before the loop and reusing it
across all 32 iters is the right structure. The question is *how*
to keep it alive across iters.

#### What "row-invariant" means here, concretely

The VLOOP iterates over **rows of the output tile**. Each iter `i`
produces one full row `mask[i, :]` (all 32 columns), with the
column index `j` varying *across the lanes of one vreg* — not across
iterations.

```
                    j (column, varies across vreg lanes within ONE iter)
                    ──────────────────────────────────────►
                    j=0   j=1   j=2   …   j=31
                  ┌───────────────────────────────┐
i=0  (iter 0):   │  mask[0,0]  mask[0,1]   …      │   ◄── computed by iter 0
i=1  (iter 1):   │  mask[1,0]  mask[1,1]   …      │   ◄── computed by iter 1
…                 │              …                 │
i=31 (iter 31):  │  mask[31,0]            …       │   ◄── computed by iter 31
                  └───────────────────────────────┘
                    ▲
                    │
                  i (row index, what the VLOOP advances over)
```

For one row `i`, the per-element formula is:

```
mask[i, j] = (triu_causal[i,j] & (B[i,j] | C[j])) | F[i,j]
```

| Quantity                              | Depends on `i`? | Depends on `j`? |
|---------------------------------------|:---:|:---:|
| `triu_causal[i,j] = q_offset[i] ≤ k_offset[j]` | yes | yes |
| `B[i,j]           = q_attn[i]  == k_attn[j]`   | yes | yes |
| **`C[j]           = k_attn[j]  == 0`**         | **no**  | yes |
| `F[i,j]           = q_offset[i] == k_offset[j]`| yes | yes |

`C[j]` carries no `i` index. Iter 0 needs `(k_attn[0]==0, k_attn[1]==0,
…, k_attn[31]==0)`; iter 1 needs the same 32 values; so does iter 31.

#### Why iter `i+1` doesn't fetch a "next round" of `k_attn`

Because each iter consumes **the entire `k_attn` row** (all 32
elements at once, one per vreg lane). There is no "next batch" to
advance to:

```
operand          shape    iter 0          iter 1         iter 31     advances per iter?
─────────        ─────    ───────         ───────        ───────     ─────────────────
q_attn[:,None]   32       q_attn[0]       q_attn[1]      q_attn[31]  ✓ (one scalar per iter; brc_b32, +4 B)
k_attn[None,:]   32       k_attn[0..31]   k_attn[0..31]  k_attn[..]  ✗ (FULL row reused; full-VL, #p=0)
q_offset[:,None] 32       q_offset[0]     q_offset[1]    q_offset[..] ✓ (per-row, via tile or brc_b32)
k_offset[None,:] 32       k_offset[0..31] k_offset[..]   k_offset[..] ✗ (FULL row reused; full-VL, #p=0)
```

This is the asymmetry from the broadcast directions: `[:, None]`
operands (q_attn, q_offset) are *column-broadcast*, so per-row data
is one scalar that advances; `[None, :]` operands (k_attn, k_offset)
are *row-broadcast*, so the same 32-element row feeds every row of
the output. The assembly reflects this directly — V5 (k_attn) and V2
(k_offset) both load with `#p=0` (no advance) and stay in their
vregs for all 32 iters.

So C, being computed only from `k_attn`, inherits that
row-invariance. There is exactly **one** k_attn per kernel
invocation; `[None, :]` is just a broadcast declaration, not an
"iterate over k_attn" instruction. Every row of the output sees the
same C.

(Across different program blocks of a larger launch, the kernel will
be invoked again with potentially different k_attn data — and a
fresh pre-loop computation will produce a fresh C. The "reuse
across 32 iters" only applies within one invocation.)

#### What hivmc-a5 actually does

In the captured assembly:

```asm
;  pre-loop  (not shown in the snippet, but implied):
;    VCMP.EQ.s32  P_C, V_kattn, V_zero, P_seed
;    (vstore P_C bytes to UB[c18944])

;  per iter (inside VLOOP):
VLDUI V6, ULD0, [S70], #0           ; load 32 bytes from UB[c18944]
MOVVP.b32 P3, V6, #0                ; convert lane-bits in V6 to predicate P3
```

So pre-loop: 1 VCMP + 1 byte-store.
Per iter: 1 VLDUI + 1 MOVVP = 2 ops × 32 iters = **64 ops** dedicated
just to recovering C as a predicate.

Total: **2 + 64 = 66 ops** to keep C alive.

#### Why this happens

The MLIR commits C to a UB-resident memref:

```mlir
%12 = hivm.hir.pointer_cast(%c18944_i64) : memref<32xi1, #hivm.address_space<ub>>
hivm.hir.vcmp ins(%collapse_shape_2, %c0_i32) outs(%12)
```

`%12` is **typed as a memref backed by UB at byte offset c18944**. The
MLIR has explicitly chosen "C lives at c18944 in UB." hivmc-a5
honours that storage commitment: the vcmp's i1 output gets stored as
bytes; subsequent reads load from that address. There is no pass in
hivmc-a5 (that we can observe) that would say "this memref<i1, ub>
value is loop-invariant and small enough to live in a P-reg
instead." So the lowering goes through UB by default.

This is the same pattern as q_offset's tile (§6.4): hivmc-a5
faithfully implements the MLIR's storage typing, even when a
register-resident form would be cheaper.

#### Two missed optimizations (alternatives to the current 66-op cost)

##### Optimization 1 — Recompute C inline each iter

Eliminate the pre-loop precompute and the byte buffer entirely.
Instead, do the comparison fresh in each iter alongside the other
VCMPs.

```asm
;  no pre-loop work
;  per iter:
VCMP.EQ.s32 P_C, V_kattn, V_zero, P_seed   ; C = (k_attn == 0), 32 lanes
;  P_C used directly in the boolean algebra
```

This requires `V_zero` to be live in a vreg (cheap — it's a constant,
preloaded once outside the loop), and `V_kattn = V5` is already
loaded each iter for the B compare.

| Cost              | Current (γ)                | Optimization 1 (α) |
|-------------------|---------------------------:|-------------------:|
| Pre-loop ops      | 2 (VCMP + vstore)          | 0                  |
| Per-iter ops      | 2 (VLDUI + MOVVP)          | 1 (VCMP)           |
| Per-iter mem bw   | 32 B (the byte buffer)     | 0                  |
| Total ops (T=32)  | 2 + 64 = **66**            | 32 × 1 = **32**    |

**Savings vs current: 34 ops, 32 B × 32 iters = 1 KB UB bandwidth.**
Trade-off: 31 redundant `VCMP`s producing the same result (since C
doesn't change). Pure compute waste.

##### Optimization 2 — Hold C in a P-reg across iters (the optimum)

Compute C once before the loop, **leave it in a P-register**, and
have the loop body reference that P-reg directly. No UB buffer, no
reload, no MOVVP.

```asm
;  pre-loop:
VCMP.EQ.s32 P_C, V_kattn, V_zero, P_seed   ; once

;  per iter:
;  (just use P_C directly in POR / PAND etc.)
```

| Cost              | Current (γ)                | Optimization 2 (β) |
|-------------------|---------------------------:|-------------------:|
| Pre-loop ops      | 2 (VCMP + vstore)          | 1 (VCMP)           |
| Per-iter ops      | 2 (VLDUI + MOVVP)          | 0                  |
| UB bytes consumed | 32 (predicate buffer)      | 0                  |
| P-regs reserved   | 0 (during loop body)       | 1 (held across loop) |
| Total ops (T=32)  | 2 + 64 = **66**            | **1**              |

**Savings vs current: 65 ops** — by far the biggest win, dwarfing
optimization 1.

The cost is one extra P-register held live throughout the loop. The
assembly already uses P1, P2, P3, P4, P5; if A5 has at least 8
predicate registers (typical), keeping a sixth live for C is
trivially affordable.

##### Why this isn't done — the same pattern as q_offset

To do optimization 2, hivmc-a5 would need a pass that:
1. Recognises `memref<32xi1, ub>` values that are loop-invariant
2. Promotes them to a P-register that lives across the loop body
3. Deletes the byte-store and rewrites every memref load to a use of the P-reg

That's a "memref<i1, ub> → P-reg promotion" pass, structurally
analogous to the "vbrc'd tile → brc_b32 streaming" pass that *did*
fire for q_attn but didn't for q_offset. In both cases the limiting
factor seems to be the same: hivmc-a5 lowers MLIR storage
faithfully, and only rewrites it when a specific fusion pattern
matches. Predicate-bytes-in-memref → P-reg apparently isn't one of
the patterns it recognises.

#### Summary table for all three "missed" optimizations

| Value     | MLIR storage             | Optimal hardware        | hivmc-a5 picked              | Cost ratio |
|-----------|--------------------------|-------------------------|------------------------------|-----------:|
| q_attn    | 4096 B vbrc'd tile       | brc_b32 streaming, no tile | brc_b32 streaming ✓        | optimal    |
| q_offset  | 4096 B vbrc'd tile       | brc_b32 streaming, no tile | full-VL streaming through tile | ≈ 80/64 = 1.25× |
| C         | 32 B i1 memref           | P-reg held across loop  | UB byte buffer + reload      | **66 / 1 = 66×** |

All three "leakages" share the same root: hivmc-a5 follows the
MLIR's storage typing rather than aggressively promoting to
register-resident forms. The C case is the most extreme — a 66×
overhead for a 32-bit value — but also the most easily fixable,
since the optimization (hold a single predicate in a P-reg across a
loop) is structurally simple.

### 6.7 Missed optimization for q_offset — apply the q_attn treatment

Just as §6.6 spelled out the fixes for C, the q_offset asymmetry
described in §6.4 has a clear optimization analogue: **lower
q_offset the same way q_attn already gets lowered.** The pattern
fired for q_attn (brc_b32 streaming, no tile materialized); applying
it to q_offset would close the 1.25× gap.

#### What hivmc-a5 currently does for q_offset

```asm
;  pre-loop:
;    vbrc 32×1 i32 → 32×32 i32 tile in UB at c0      (≈16 hw insns to fill 4096 B)
;
;  per iter (inside VLOOP):
VLDI V3, [S69], #16, #0, #1         ; 256 B normal load from the tile
                                    ; S69 ← S69 + 512 B (post-incr to next row)
…
VCMP.LE.s32 P5, V3, V2, P1          ; consumer #1: A_row
VCMP.EQ.s32 P4, V3, V2, P1          ; consumer #2: F_row
```

Total q_offset machinery: ≈16 pre-loop ops + 1 normal VLDI per iter
+ 4096 B UB tile.

#### Optimization 3 — brc_b32 stream q_offset (mirror q_attn)

```asm
;  no pre-loop tile build
;
;  per iter (inside VLOOP):
VLDI V3, [S_qoff], #1, #3, #1       ; brc_b32: 1 i32 broadcast → all 64 lanes
                                    ; S_qoff ← S_qoff + 4 B (advance one scalar)
…
VCMP.LE.s32 P5, V3, V2, P1          ; consumer #1: A_row (V3 = q_offset[i] broadcast)
VCMP.EQ.s32 P4, V3, V2, P1          ; consumer #2: F_row (same V3 reused)
```

V3 stays in a vreg across both compares — vregs are not reset
between consecutive insns within an iter, so the second `VCMP.EQ`
just reads V3 again at zero extra cost.

| Cost              | Current (full-VL)                | Optimization 3 (brc_b32, mirror q_attn) |
|-------------------|---------------------------------:|----------------------------------------:|
| Pre-loop ops      | ≈16 (vbrc fills tile)            | 0                                       |
| Per-iter ops      | 1 VLDI normal + 2 VCMPs = 3      | 1 VLDI brc_b32 + 2 VCMPs = 3           |
| Per-iter UB read  | 256 B                            | 4 B                                     |
| UB tile bytes     | 4096                             | 0                                       |
| Total ops (T=32)  | 16 + 96 = **112**                | **96**                                  |

**Savings vs current: 16 ops + 4096 B UB + 32 × (256 − 4) = 8064 B
of bandwidth.**

The two consumers don't change anything — the per-iter cost is
identical between current and optimized (3 ops either way). The
saving comes entirely from skipping the pre-loop tile fill and the
tile's UB residency.

#### Why hivmc-a5 didn't pick this

Same root cause as before: hivmc-a5 honoured the MLIR's storage
typing. The MLIR commits q_offset to a 4096 B tile in UB (Phase 1),
so hivmc-a5 builds it. The q_attn case happened to fit a fusion
pattern that elides the tile; q_offset's didn't (probably because
q_offset's source is also live into the i64-widen path, see §6.4
hypotheses).

The fix would be a more general "vbrc'd tile is dead at this
hardware level — replace consumers with brc_b32 streams" pass that
recognises *all* such cases, not just the one that happens to
match q_attn's particular shape.

#### Updated summary table

| Value     | MLIR storage             | Optimal hardware              | hivmc-a5 picked              | Cost ratio | Optimization |
|-----------|--------------------------|-------------------------------|------------------------------|-----------:|--------------|
| q_attn    | 4096 B vbrc'd tile       | brc_b32 streaming, no tile    | brc_b32 streaming ✓          | optimal    | already optimal |
| **q_offset** | 4096 B vbrc'd tile    | **brc_b32 streaming, no tile** | full-VL streaming through tile | 1.17×    | **§6.7 Optimization 3** |
| C         | 32 B i1 memref           | P-reg held across loop        | UB byte buffer + reload      | 66×        | §6.6 Optimization 2 |

(q_offset cost ratio refined: 112/96 ≈ 1.17× rather than the earlier
1.25×, since the per-iter compute portion `2N` is identical between
strategies and only the constant `K=16` differs.)

#### Total potential savings if all three fire

- §6.6 Optimization 2 (C in P-reg): **−65 ops + −32 B UB**
- §6.7 Optimization 3 (q_offset brc_b32): **−16 ops + −4096 B UB + −8 KB UB read bandwidth**
- (q_attn / k_attn / k_offset: already optimal)

Net per kernel invocation from these three alone: roughly **−80 ops,
−4 KB of UB tile storage, −8 KB of UB read bandwidth.** All three
are missed by the same hivmc-a5 limitation: the lowering follows
MLIR storage typing rather than promoting loop-invariant or
fully-broadcastable values to register-resident forms.

§6.8 below lists more.

### 6.8 More missed optimizations — loop-invariant code motion and ISA-feature fusions

Re-examining the body, several additional instructions execute every
iter but produce identical results — classic loop-invariants that
hivmc-a5 isn't hoisting. The same mechanism that holds P1 = `VL64`
and P2 = `ALLF` across all 32 iters (registers preserve their
contents across VLOOP boundaries — see "why we can hold C in a
P-reg" earlier) is available for vector registers too.

#### What is being needlessly re-executed each iter

```asm
VLOOPV2_V310 S3, #35, #1, #1       ; ── loop start ──
VLDI V2, [S6],  #0,  #0, #0        ; ★ #p=0, S6 fixed; reloads SAME 256 B every iter
VLDI V3, [S69], #16, #0, #1        ;   (per-iter, real)
VLDI V4, [S68], #1,  #3, #1        ;   (per-iter, real)
VLDI V5, [S10], #0,  #0, #0        ; ★ #p=0, S10 fixed; reloads SAME 256 B every iter
VLDAS ULD0, [S12]                  ; ★ ULD0 ← S12 every iter (fixed)
SMOV.b32 S70, S12                  ; ★ S70 ← S12 every iter (fixed)
VADDS.s32 V2, V2, S8, P1           ; ★ V2 += S8 every iter; produces SAME V2 every time
…
```

Five instruction-classes (★) are loop-invariant. None of them needs
to live in the body.

#### Optimization 4 — Hoist V2 setup (VLDI + VADDS) out of the loop

```asm
;  pre-loop:
VLDI V2, [S6], #0, #0, #0
VADDS.s32 V2, V2, S8, P1   ; computed once

;  body:
;  V2 just sits there, used by VCMP.LE and VCMP.EQ
```

| Cost           | Current             | Optimized |
|---------------:|--------------------:|----------:|
| Pre-loop ops   | 0                   | 2         |
| Per-iter ops   | 2 (VLDI + VADDS)    | 0         |
| Total (T=32)   | **64**              | **2**     |

**Saving: 62 ops** + 32 × 256 B = **8 KB of UB read bandwidth**.

##### Common confusion — "if each iter is one row, shouldn't V2 advance?"

A natural question at this point: *each VLOOP iter computes a
different output row, so why isn't V2 bumped to "the next row's
data" each iter?* The answer is that `k_offset` is a **1D 32-element
array** — there is no "next row of k_offset data" to advance to,
because k_offset has no rows of its own.

Two very different "rows" are in play, and conflating them is what
produces the confusion:

```
output rows (32 of them)              source data layout
───────────────                       ──────────────────
The 32 rows of the 32×32 mask         q_offset, k_offset, q_attn, k_attn
result we are computing.              are each a 32-element 1D array.
The VLOOP iterates over THESE.        ← no rows of their own.
```

The Triton broadcast `[None, :]` makes a 1D row vector behave as if
replicated to every output row:

```python
k_offset[None, :]    # shape (1, 32) → broadcasts to (32, 32)
                     # every output row sees the SAME 32 values
```

So computing output row `i` uses k_offset values `[0..31]`; computing
output row `i+1` also uses k_offset values `[0..31]` — *literally
the same 32 numbers*. There's nothing to "bump" — the same data is
needed every iter.

```
                       j (column, lanes within one vreg)
                       0     1     …     31
                     ┌────────────────────────┐
output row  0 needs: │ k[0]  k[1]  …  k[31]   │
output row  1 needs: │ k[0]  k[1]  …  k[31]   │     ◄── identical
output row  2 needs: │ k[0]  k[1]  …  k[31]   │       every row
       …             │       …                │
output row 31 needs: │ k[0]  k[1]  …  k[31]   │
                     └────────────────────────┘
```

V2 with `#p=0` correctly captures this. The `VADDS V2 += S8` inside
the body is also constant (S8 doesn't change between iters), so V2's
contents are bit-identical every iter. Hoisting both ops outside the
loop is safe because they would re-produce the same V2 value every
time anyway.

This is the same row-vs-column-broadcast asymmetry from §6.6:

| Triton form | Per-row need | Hardware behavior |
|---|---|---|
| `[:, None]` (q_offset, q_attn) — column-broadcast | a *different* scalar each iter (`q_offset[i]`, `q_attn[i]`) | V3, V4 **advance** per iter |
| `[None, :]` (k_offset, k_attn) — row-broadcast | the *same* 32-element row every iter | V2, V5 **stay constant** (`#p=0`) |

The intuition "load next row each iter" applies to the
`[:, None]` operands. For `[None, :]` operands there is no "next
row of data" — broadcasting along the row axis means the entire
1D source array is the data for every output row.

#### Optimization 5 — Hoist V5 (k_attn row) out of the loop

V5 is loaded with `#p=0` and never written inside the body. Same
hoisting applies.

| Cost           | Current  | Optimized |
|---------------:|---------:|----------:|
| Pre-loop ops   | 0        | 1 (VLDI)  |
| Per-iter ops   | 1 (VLDI) | 0         |
| Total (T=32)   | **32**   | **1**     |

**Saving: 31 ops** + **8 KB UB read bandwidth**.

#### Optimization 6 — Hoist `VLDAS` / `SMOV` / `V0` / `V1` out of the loop

The `VLDAS ULD0, [S12]` and `SMOV.b32 S70, S12` both execute every
iter from a fixed source — pure loop-invariant. The two SMOVs in
the body (`S70 ← S12`, `S70 ← S18`) are also loop-invariant, since
S12 / S18 don't change between iters.

If §6.6 Optimization 2 fires (C in P-reg), the entire VLDAS + SMOV
+ VLDUI + MOVVP chain disappears anyway. Independently:

- VLDAS hoisted: −1 op/iter = **−32 ops**
- The two SMOVs hoisted (or eliminated): **−64 ops**

V0 (all-0 i32 tile) and V1 (all-1 i32 tile) feed `VSEL.b32 V2, V1, V0, P3`.
They are pure constants and almost certainly currently loaded
inside the body (same pattern as V2 / V5). Hoisting them out:

- V0 + V1 loads hoisted: 2 VLDIs/iter × T = **−64 ops**

(The V0/V1 part is Tier-B because we don't see their loads in the
20-line snippet, but the structural assumption is strong.)

#### Optimization 7 — Fuse `VCMP.LE` and `VCMP.EQ` on `(V3, V2)` (Tier-C, ISA-dependent)

The body computes both A = (V3 ≤ V2) and F = (V3 == V2) on the same
operand pair, with the same seed mask P1. If PTO has any "compare
and emit two predicates" form (e.g. emitting LE and EQ together,
or "VCMP_RANGE"), this saves 1 op/iter = **32 total**. This depends
on whether the PTO ISA includes such a fused-compare instruction.

A quick check of `~/Documents/Repo/pto-isa/docs/isa/vector/ops/compare-select/`
would settle whether the fusion exists.

#### Optimization 8 — Direct i1 → i8 narrowing instead of i1 → i32 → i8 (Tier-C)

Current path: `VSEL.b32 V2, V1, V0, P3` produces 1024 i32 (1 or 0),
then a later `VCAST.s8` (not in the snippet) narrows to i8 for the
result tile. If a `VSEL.b8` variant exists — emitting i8 directly
from a predicate plus two i8 sources — the i32 step is skipped.

- Saving: 1 op/iter = **32 ops**, plus a vreg slot freed from
  holding the i32 intermediate, plus possibly the temp_buffer
  the MLIR's narrowing vcast required.

Depends on whether `VSEL.b8` (or equivalent) is in the ISA.

#### Optimization 9 — Pack two rows per iter (structural, Tier-C)

The "Layout B" hypothesis from §11. If the kernel reshapes the
iteration so each iter produces **two output rows** (16 iters × 64
vreg lanes, instead of 32 iters × 32 useful lanes), then:

- VLOOP overhead amortizes over twice as many useful results
- All loop-invariant work (the hoistable items above) pays its
  fixed cost over half as many iters
- Bandwidth utilization on the V3/V4 streams improves

Approximate halving of per-output-row loop overhead. Requires the
input layout to actually pack two rows per vreg-load worth of data,
and the VSTI to write 64 lanes covering two output rows. Whether
this is structurally possible depends on the launch grid and the
upstream tile layout — which the architect or hivmc-a5 design intent
would determine.

#### Aggregate of all eight missed optimizations

| #   | Optimization                                  | Savings (ops) | Savings (UB) | Tier |
|----:|-----------------------------------------------|--------------:|-------------:|:---:|
| 1   | §6.6 inline-recompute C                       | −34           | −32 B + 1 KB BW | A |
| **2** | **§6.6 hold C in P-reg**                    | **−65**       | **−32 B**    | **A** |
| 3   | §6.7 brc_b32 stream q_offset                  | −16           | −4096 B + 8 KB BW | A |
| 4   | §6.8 hoist V2 (VLDI + VADDS)                  | −62           | −8 KB BW     | A |
| 5   | §6.8 hoist V5 (VLDI)                          | −31           | −8 KB BW     | A |
| 6   | §6.8 hoist VLDAS/SMOV/V0/V1                   | ~−160         | —            | B |
| 7   | §6.8 fuse `VCMP.LE` + `VCMP.EQ`               | −32           | —            | C |
| 8   | §6.8 direct i1 → i8 via `VSEL.b8`             | −32           | —            | C |
| 9   | §6.8 pack two output rows per iter            | ~50% loop overhead | —       | C |

**Tier-A-only total** (Opts 2, 3, 4, 5): −174 ops, ~−4 KB UB tile, ~−16 KB UB bandwidth.

Adding Tier-B (Opt 6): roughly −330 ops total.

Adding all Tier-C optimizations on top, if the ISA supports them:
another ~−100 ops plus halving of remaining loop overhead.

The pattern across all of these: hivmc-a5 emits a faithful
instruction-by-instruction lowering of the MLIR but doesn't apply
classical compiler-level loop-invariant code motion or aggressive
register-resident promotion. A pass library that knew about A5
register lifetimes across VLOOPs (the same way it would for any
other loop in any other architecture) could reclaim the bulk of
these missed cycles without needing any new ISA features.

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
| `VDUPS.b32`         | **A** | `pto-isa/docs/isa/vector/ops/predicate-and-materialization/vdup.md` ("Duplicate scalar … to all lanes") |
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
7. **Algorithmic role of pass A vs pass B** — same query × two different key blocks?
   Two halves of one tile with different precomputed masks? Resolution requires
   the launcher source.
8. **`VDUPS.b32 V0, S20, P1, #1` post-loop** — what S20 holds and what
   downstream code expects V0 to be after this reset. Resolution requires
   disassembling beyond line 39.

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

## 11. Layout open question — what's in the upper 32 lanes?

The annotated assembly assumes V2 / V3 / V5 use only the lower 32
lanes of their 64-lane vreg, with the upper 32 either padded, packed
with a second row, or replicated. None of these is verified.

### Status update from §3.2 — body-length resolved, lane question still open

§3.2 confirmed the full 35-instruction body via the updated assembler
listing, and revealed a **two-pass structure**: pass A (lines 4–22)
and pass B (lines 23–38) operate on different source/destination
addresses but share V4, V0, V1, S8, P1, P2.

The two-pass observation makes one of the original layout
hypotheses **less likely** but does not pick between them
definitively:

- **Layout B (packed two rows in one vreg)** is now *less* likely
  for the kernel as a whole — what we see is unrolling across
  separate compute regions (each pass has its own VCMPs, VLDIs,
  VSTI), not packing of two rows inside one vreg's 64 lanes.
  Layout B would have produced one vreg-load with two rows-worth
  of data and one VCMP that consumed both halves.
- **Layouts A (padded) and C (replicated)** remain possible for
  what's in the upper 32 lanes during a single pass's compute.

### What's pinned down

| Fact | Value | Source |
|---|---|---|
| vreg width | 256 B = 64 i32 lanes | PTO ISA `execution-agents.md` |
| `VLDI #dist=#0` load width | 256 B = 64 i32 (always full VL) | architect spec |
| MLIR tile shape | 32 × 32 i32 | `captures_hivmc_input_a5_bool.mlir` |
| Operand source rows (q/k_offset, q/k_attn) | 32 i32 each | MLIR `memref<32xi32, …>` |
| Per-iter mask `P1` | `VL64` = all 64 lanes active | `PSET.b32 P1, #8` |

Algorithmic row width = 32. Hardware vreg width = 64. There's a
gap of 32 lanes that the snippet alone can't account for.

### The three plausible layouts

```
A. PADDED — 32 valid + 32 unused
   V?: [d0][d1]…[d31] [pad][pad]…[pad]
   ↳ S3 = 32 iters (one row per iter). Compute happens on all 64 lanes
     but only the lower 32 contribute to a stored result.

B. PACKED — two adjacent rows
   V?: [d0][d1]…[d31] [d0'][d1']…[d31']     ← row r in low half, row r+1 in high half
   ↳ S3 = 16 iters (two rows per iter). All 64 lanes meaningful.
     V3's +512 B post-incr (= 2 × 256 B vreg loads) is at least
     consistent with this (each iter advances "two rows worth").

C. REPLICATED — 32 elems repeated
   V?: [d0][d1]…[d31] [d0][d1]…[d31]
   ↳ S3 = 32 iters. Upper 32 lanes redundantly re-compute the same
     compare result as the lower 32. Wasteful but harmless.
```

The annotated `ROLE:` lines in §3 used to commit to layout A
("32 elems padded to 64-lane vreg"). They have been softened to
"32 elems wide algorithmically; upper-lane content unverified."

### Resolution paths — any one would settle it

1. **Pre-loop disasm.** The instructions that build `[S6]` and
   `[S69]` and `[S10]` reveal the source layout. If the source is
   128 B of valid data followed by zero/garbage → layout A. If it's
   a 32 × 32 tile loaded contiguously → layout B (the +512 B stride
   matches a 256 B "row pair" layout). If 32 elems are explicitly
   replicated → layout C.

2. **Runtime value of S3.** The scalar `MOV` (or `LI`) before
   `VLOOPV2_V310` writes S3. S3 = 32 → layout A or C. S3 = 16 →
   layout B.

3. **Full 35-instruction body.** The unshown 15 instructions —
   particularly any second VLDI / VSTI not in our snippet — likely
   include the activity that handles "the other half" of the vreg,
   confirming the layout.

4. **VSTI byte stride field.** `VSTI V2, [S67], #16, #2, P1, #1` has
   a `#2` field whose meaning is still Tier-C (see §9). If `#2`
   encodes "store 2 vregs worth per iter," that's evidence for
   layout B; if "store 256 B per iter, masked to lower half," that's
   evidence for layout A.

Want one of these checks run? Item 2 is cheapest — start the VM,
re-disassemble the same `.o`, and grep for the scalar move targeting
S3 immediately before the VLOOPV2.
