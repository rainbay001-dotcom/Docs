# `assembler.as` provenance — what MLIR captures do and do NOT tell us

**Status:** methodological correction, 2026-05-12. Forced by a sharp question
during the assembler PPT review: "the MLIR does not correspond to the
assembler code, so let's not refer to MLIR to infer the used number of
lanes."

This doc separates evidence by artifact provenance so that future analysis
doesn't conflate compilation paths.

## 1. The three artifacts and which compilation produced them

| Artifact | File path (or container) | Compilation provenance | What it directly attests to |
|---|---|---|---|
| **`assembler.as`** | `~/Documents/docs/assembler.as` | **unknown vintage** — disassembly only; no provenance metadata for the binary | the actual PTO instruction stream the silicon (or camodel) would execute |
| **MLIR captures** | `captures_hivmc_input_a5_bool.mlir`, `captures_hivmc_input_a5_cast.mlir` | hivmc-a5 Phase-10 dump from the **CANN 9.0.0** build of `mask_kernel_a5.o` | the IR the CANN 9.0.0 compiler hands to its A5 lowering pass |
| **camodel trace** | `dump2trace_core0.json` + `core0.veccore0.rvec.{IDU,ISU,EXU,LSU,OOO}.dump` | the **CANN 9.0.0** build of `mask_kernel_a5.o` run under the cycle-accurate camodel | per-instruction cycle / pipe / lane behavior of *that specific binary* |

The MLIR + camodel artifacts share a binary (CANN 9.0.0). `assembler.as`
does not. **Treating them as describing the same kernel is the
methodological error this doc exists to flag.**

Direct evidence: the camodel-traced kernel is single-pass (one VLOOP
body), per the timing in `a5_aiv_vector_parallelism.html` §5. The
`assembler.as` kernel is two-pass (pass A + pass B, line 22 VSTI to
`[S67]` and line 38 VSTI to `[S65]`). Different number of stores per
VLOOP iter means different code structure means different binary.

## 2. What MLIR types directly attest to

`captures_hivmc_input_a5_bool.mlir` Phase 1 contains:

```mlir
%0 = hivm.hir.pointer_cast(%c19232_i64) : memref<32x1xi32, ub>     // q_offset source
%3 = hivm.hir.pointer_cast(%c19360_i64) : memref<1x32xi32, ub>     // k_offset source
%5 = hivm.hir.pointer_cast(%c18976_i64) : memref<32x1xi32, ub>     // q_attn source
%8 = hivm.hir.pointer_cast(%c19104_i64) : memref<1x32xi32, ub>     // k_attn source
%12 = hivm.hir.pointer_cast(%c18944_i64) : memref<32xi1, ub>       // C predicate buffer
```

**What this attests to:** for the CANN 9.0.0 build, the lowering committed
to 32-element-per-K-block source operands placed at specific UB byte
offsets.

**What this does NOT attest to:** any property of `assembler.as`'s runtime
behavior. The MLIR doesn't say:
- That `assembler.as`'s `VLDI V5,[S10]` reads the same 32-element source
- That `assembler.as`'s K-block tile size is 32
- That `assembler.as`'s `[S10] .. [S10]+255` UB region has the same
  layout as the MLIR's `[c19104] .. [c19104]+128` region
- Anything about `assembler.as`'s BLOCK_N

## 3. What `assembler.as` alone directly attests to

Reading only the 39-line disassembly:

### Lane-count intent (verifiable from the asm)

| Mechanism | Evidence | What it attests to |
|---|---|---|
| `PSET.b32 P1,#8` (line 1) | `#8` is the VL64 mask token | P1 = "first 64 i32 lanes valid" |
| All VCMP/POR/PAND/VSEL/VSTI carry `P1` | direct read of lines 11–22, 28–38 | 64-lane intent end-to-end |
| `VLDI V4,[S68],#1,#3,#1` (line 6) | `#dist=3` = brc_b32 mode | V4[0..63] = `q_attn[i]` *by hardware contract* |
| `VLDI V5,[S10],#0,#0,#0` (line 7) | `#dist=0` = full-VL 256 B read | V5[0..63] = byte-for-byte copy of UB[S10..S10+255] |
| `VSTI V2,[S67],#16,#2,P1,#1` (line 22) | dtype × `P1` × `#offset=16 × align-unit` | 256 B written; `#p=1` advances S67 by `16 × align-unit` per iter |

### Per-iter structure (verifiable)

- One VLOOP iter contains two passes (lines 4–22 = pass A; lines 23–38 = pass B + post-loop reset at 39).
- Pass B does *not* reload V4 — there is no `VLDI V4,...` at lines 23–25.
  Therefore V4 (`q_attn[i]`) is identical across both passes.
- Pass B *does* reload V5 (line 25, base S16) and V2 (line 23, base S14)
  from different addresses than pass A (lines 7 / 4, bases S10 / S6).
  Different base ⇒ different K-side data ⇒ different K block per pass.
- Therefore: **one VLOOP iter = one query row index `i` × two K-block-mask
  outputs.** This is K-block unroll, not row unroll. (See PPT slide 2/3
  callouts after the 2026-05-12 update.)

### What `assembler.as` does NOT directly attest to

- **BLOCK_N** (the column tile size). The asm has no constant pinning it.
- **`S3`**, the VLOOP iter count. Set by pre-loop code we don't see.
- **The launcher's UB-fill pattern.** Specifically, what's at
  `UB[S10+128] .. UB[S10+255]` (the upper half of V5's load source) is
  whatever the launcher wrote there before the VLOOP started — not
  visible in the disassembly.
- **Whether the upper 32 lanes of V5 / V2 / V3 carry meaningful data.**
  See §4 below.

## 4. The §11 "upper 32 lanes" question, restated without MLIR

A full-VL VLDI is a *passive 256 B read*: hardware byte-copies UB content
into vreg lanes. A brc_b32 VLDI is a *hardware-replication primitive*:
hardware reads 1 i32 and fans it out to all 64 lanes by construction.

**For V4 (brc_b32):** lanes 32..63 = `q_attn[i]` *by hardware contract*,
not by any launcher decision. The §11 question is vacuous — there's no
degree of freedom to fill differently.

**For V5 / V2 (full-VL):** lanes 32..63 hold whatever the launcher wrote
into `UB[S10+128..S10+255]` (and `UB[S6+128..S6+255]`) before the kernel
ran. Three families of launcher behavior are consistent with the asm:

| Hypothesis | Upper-half UB content | Net effect on the asm's 64-lane VCMP |
|---|---|---|
| **Layout A — replicated** | duplicate of lower-half UB | 64 results, 32 useful + 32 redundant |
| **Layout B — packed K blocks** | a *second* K block's data | 64 results, all useful (Opt 9/10/15 effectively already realized) |
| **Layout C — zero-padded** | zeros | 64 results, 32 useful + 32 garbage; downstream must mask off |

We cannot distinguish these from the assembler alone. Distinguishing
requires one of:

1. A UB-content dump from a runtime capture of **this specific binary**
   (not the camodel-traced `mask_kernel_a5.o` — that's a different
   compilation).
2. An annotated trace of the pre-loop MTE2 burst that filled
   `[S10] .. [S10]+255`.
3. Linkable source / provenance for `assembler.as` (we don't have it).

## 5. Implications for the assembler.as PPT and the §6 walkthrough

The PPT's per-Opt slides (notably **Opt 3** — brc_b32 stream q_offset;
**Opt 9** — pack 2 rows per iter; **Opt 10** — cross-tile pack K[0]+K[1];
**Opt 15** — single-VCMP via packed V5) and the walkthrough's `§6.6`,
`§6.7`, `§6.10`, `§6.11` cite MLIR pointer_cast shapes when reasoning
about lane usage and tile widths. Those citations are **valid for the
CANN 9.0.0 build** but should not be presented as evidence about
`assembler.as` specifically.

Practical labeling rule:

| Phrasing | When valid |
|---|---|
| "the MLIR commits q_offset to a 4096 B tile in UB" | when describing the CANN 9.0.0 lowering path |
| "the asm reads 256 B per VLDI #dist=0 from UB" | when describing assembler.as |
| "the source data is 32 elements per K block" | **only** when stated about the CANN 9.0.0 build, not assembler.as |
| "the upper 32 lanes are wasted" | **only** when stated as Opt 9's *worst-case assumption*, not as observed fact about either build |

For Opt 3 (brc_b32 stream q_offset): the *opportunity* is real for any
kernel where V3 is loaded full-VL with a per-iter scalar advance. That
the savings calculation uses CANN-9.0.0-derived constants (4096 B tile,
≈16 vbrc ops) is a separate question — that part is provenance-bound to
CANN 9.0.0.

For Opt 9 / 10 / 15 (lane-packing): the *opportunity* depends on which
Layout is currently live. From the assembler alone, the savings size is
not determinable. The PPT's Tier-C label on these correctly captures the
uncertainty.

## 6. Slides where this affects existing claims

- **Slide 2 callout** + **slide 3 body bullet** — already fixed (2026-05-12)
  to use K-block unroll, with V4-doesn't-reload-in-pass-B as the
  evidence. No MLIR citation in the new wording.
- **Slide 11 (Vector unit expanded)** — uses only camodel + asm evidence
  (no MLIR), so unaffected.
- **Slide 13 (Opt 1)** through **slide 35 (Opt 23)** — many cite §6.X of
  the walkthrough. The §6.X citations use MLIR shapes; the per-Opt
  slides inherit those. Open question: should the per-Opt slides be
  re-tagged with "CANN-9.0.0-derived constants; applicability to
  assembler.as varies"? Probably yes for Opts 3 / 9 / 10 / 15. Not yet
  done.
- **Slide 38 (Cumulative impact)** — has a per-artifact table separating
  `assembler.as` (unknown ver.) from CANN 9.0.0. That separation is
  already methodologically clean. No change needed.

## 7. Why this matters going forward

Two failure modes that this doc is designed to prevent:

1. **Asserting `assembler.as` behavior from MLIR types.** Example I made
   in chat 2026-05-12: "the source data is 32 elements per K block"
   citing MLIR `memref<1x32xi32>` as evidence — that's only valid for
   the CANN 9.0.0 build, not for the disassembled binary. Future
   reasoning about `assembler.as`'s lane usage should restrict to the
   evidence in §3 above.

2. **Asserting camodel pipe-utilization numbers about `assembler.as`.**
   The 64% RVECEX utilization, 18% RVECLD, 9% RVECST come from camodel
   on `mask_kernel_a5.o` (CANN 9.0.0). They are *not* measurements of
   `assembler.as`'s execution. The PPT correctly notes this on
   slide 38, but individual per-Opt slides sometimes blur the
   attribution. When citing util numbers in the context of an Opt that
   targets the assembler kernel, qualify with "by analogy from the
   CANN 9.0.0 trace, since assembler.as has no direct cycle data."

## 8. Cross-references

- `~/Documents/docs/assembler.as` — the disassembly itself
- `a5_pto_bool_vloop_walkthrough.md` §6 — the optimization analysis
  (currently MLIR-shape-dependent in places)
- `a5_pto_bool_vloop_walkthrough.md` §11 — the upper-32-lanes hypothesis
  framing (Layouts A/B/C)
- `a5_aiv_vector_parallelism.html` §5, §6, §7 — camodel-verified AIV
  μarch, valid for the CANN 9.0.0 build
- `assembler_as_optimizations_ppt.html` slides 2/3 (K-block unroll
  evidence chain), slide 10 (AI Core overview), slide 11 (Vector unit
  expanded), slides 13-35 (per-Opt)
- `captures_hivmc_input_a5_bool.mlir` — the MLIR capture that
  underpinned much of §6's reasoning (CANN 9.0.0 only)
- `dump2trace_core0.json` + `*.dump` files in the
  `figures/mask_kernel_a5_camodel/internal_dumps/` directory —
  the camodel trace data (CANN 9.0.0 only)
