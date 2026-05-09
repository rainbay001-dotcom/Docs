# Operating MTE on Ascend NPU — MTE1 / MTE2 / MTE3

How to move data through the Ascend memory hierarchy using the MTE
(Memory Transfer Engine) pipes. Three programming layers, listed in
increasing detail / decreasing abstraction.

> Scope: AIC + AIV side together. Concrete examples target the
> Atlas 350 (A5 / 351x) but the API surface is shared across 910B /
> 910C / A5. ISA-level details that differ across generations are
> called out inline.

## 1. The pipes — what each MTE does

| Pipe        | Direction                              | Side | Latency (typical) | Issue width |
|-------------|----------------------------------------|------|-------------------|-------------|
| **MTE1**    | L1 ↔ L0A / L0B / BT                    | AIC  | tens of cyc       | single      |
| **MTE2**    | GM → {L1, L0A/L0B, UB}                 | AIC + AIV | ~80 cyc / 256 B (UB target) | dual on AIV (proven by trace) |
| **MTE3**    | UB → GM (and UB → L1)                  | AIV  | hundreds of cyc per burst | single |
| **Fixpipe** | L0C → GM / L1 (matrix accumulator drain) | AIC | tens of cyc      | single      |

MTE1 is matrix-operand staging on the Cube side (L1 → L0A/L0B for
GEMM). MTE2 is the only path to **read** from GM. MTE3 is the only
path to **write back** to GM. Fixpipe handles the L0C accumulator
drain on the AIC side and is sometimes documented as a separate pipe
rather than an MTE.

Each pipe has its own instruction queue on the AIV (`MTE2` and `MTE3`
queues — see `a5_aiv_vector_parallelism.html` §1.2) and its own
async issue port. They run concurrently with each other and with the
Vector / SIMT / Scalar queues, so a well-pipelined kernel has all of
them busy at once.

## 2. Layer 1 — Ascend C (recommended)

This is what you write in TBE / op-kernel C++ code. The runtime emits
the right MTE intrinsics + sync flags from `DataCopy` + `TQue` calls.

```cpp
#include "kernel_operator.h"
using namespace AscendC;

class VecAddKernel {
public:
  __aicore__ inline void Init(GM_ADDR x, GM_ADDR y, GM_ADDR z) {
    xGm.SetGlobalBuffer((__gm__ half*)x, TOTAL_LEN);
    yGm.SetGlobalBuffer((__gm__ half*)y, TOTAL_LEN);
    zGm.SetGlobalBuffer((__gm__ half*)z, TOTAL_LEN);

    pipe.InitBuffer(qX, BUFFER_NUM, TILE_LEN * sizeof(half));   // UB tile
    pipe.InitBuffer(qY, BUFFER_NUM, TILE_LEN * sizeof(half));
    pipe.InitBuffer(qZ, BUFFER_NUM, TILE_LEN * sizeof(half));
  }

  __aicore__ inline void Process() {
    for (int i = 0; i < tileCount; ++i) {
      // -------- Load (MTE2) --------
      LocalTensor<half> xL = qX.AllocTensor<half>();
      LocalTensor<half> yL = qY.AllocTensor<half>();
      DataCopy(xL, xGm[i * TILE_LEN], TILE_LEN);   // MTE2: GM -> UB
      DataCopy(yL, yGm[i * TILE_LEN], TILE_LEN);   // MTE2: GM -> UB
      qX.EnQue(xL);                                 // implicit set_flag MTE2->V
      qY.EnQue(yL);

      // -------- Compute (V) --------
      LocalTensor<half> xC = qX.DeQue<half>();      // implicit wait_flag V<-MTE2
      LocalTensor<half> yC = qY.DeQue<half>();
      LocalTensor<half> zL = qZ.AllocTensor<half>();
      Add(zL, xC, yC, TILE_LEN);
      qX.FreeTensor(xC);
      qY.FreeTensor(yC);
      qZ.EnQue(zL);                                 // set_flag V->MTE3

      // -------- Store (MTE3) --------
      LocalTensor<half> zC = qZ.DeQue<half>();      // wait_flag MTE3<-V
      DataCopy(zGm[i * TILE_LEN], zC, TILE_LEN);    // MTE3: UB -> GM
      qZ.FreeTensor(zC);
    }
  }

private:
  TPipe pipe;
  TQue<TPosition::VECIN,  BUFFER_NUM> qX, qY;
  TQue<TPosition::VECOUT, BUFFER_NUM> qZ;
  GlobalTensor<half> xGm, yGm, zGm;
};
```

Key points:

- **`DataCopy` picks MTE2 vs MTE3** from src/dst memory class (the
  direction of the move). You don't name the pipe by hand.
- **`TQue::EnQue` / `DeQue`** emit the `set_flag` / `wait_flag` pair
  that synchronizes the MTE pipe with the Vector compute pipe. No
  manual flag bookkeeping.
- **`BUFFER_NUM = 2`** turns on double-buffering: while pass N's
  compute runs on one UB slot, pass N+1's MTE2 prefetches into the
  other slot. The MTE2 pipe is independent of the SIMD-VF queue, so
  this overlap is free. (This is the "Opt 21 cross-launch prefetch"
  pattern from `a5_pto_bool_vloop_walkthrough.md` §6.18.)
- **For matrix kernels** use `TPosition::A1` / `A2` / `B1` / `B2` /
  `CO1` / `CO2` for L1, L0A, L0B, L0C respectively.
  `DataCopy` then emits **MTE1** for the L1→L0A/L0B moves and
  **Fixpipe** for the L0C→GM drain.

### `DataCopy` parameter forms

```cpp
DataCopy(dst, src, count);                       // 1-D, contiguous
DataCopy(dst, src, DataCopyParams{nBurst,        // 2-D, with strides
                                  burstLen,
                                  srcStride,
                                  dstStride});
DataCopy(dst, src, DataCopyExtParams{...},       // for non-aligned
                   DataCopyPadParams{...});      // and padded loads
```

`burstLen` is in 32 B blocks (one UB row). `srcStride`/`dstStride`
are gaps between bursts — useful for stride-friendly L2 patterns
that hit the same lines on consecutive launches.

## 3. Layer 2 — Intrinsics (when AscendC is too high-level)

The compiler exposes the underlying ops directly. Use these when you
want to control the exact MTE issue or when AscendC's TQue model
doesn't fit (e.g. one-shot prologue / epilogue moves, or unusual
sync topologies).

| Intrinsic                                                     | Pipe        | Direction       |
|---------------------------------------------------------------|-------------|-----------------|
| `copy_gm_to_cbuf(dst, src, sid, nburst, lenburst, srcS, dstS, pad)` | **MTE2**  | GM → L1        |
| `copy_gm_to_ubuf(dst, src, sid, nburst, lenburst, srcS, dstS)`     | **MTE2**  | GM → UB        |
| `copy_cbuf_to_ca(dst, src, sid, nburst, lenburst, srcS, dstS)`     | **MTE1**  | L1 → L0A       |
| `copy_cbuf_to_cb(dst, src, sid, nburst, lenburst, srcS, dstS)`     | **MTE1**  | L1 → L0B       |
| `copy_cbuf_to_ubuf(dst, src, sid, nburst, lenburst, srcS, dstS)`   | **MTE2**  | L1 → UB        |
| `copy_ubuf_to_gm(dst, src, sid, nburst, lenburst, srcS, dstS)`     | **MTE3**  | UB → GM        |
| `copy_ubuf_to_cbuf(dst, src, sid, nburst, lenburst, srcS, dstS)`   | **MTE3**  | UB → L1        |
| `copy_matrix_cc_to_gm(dst, src, sid, nSize, mSize, dstStride, srcStride, ...)` | Fixpipe | L0C → GM (AIC) |

Argument cheat sheet:

- `sid` — stream / sync ID (logical channel, mostly `0`).
- `nburst` — number of bursts in the 2-D move.
- `lenburst` — bytes per burst, in 32 B units (one UB row).
- `srcS`, `dstS` — gap (in 32 B units) between bursts.
- `pad` (cbuf only) — padding mode for non-aligned loads.

### Manual sync

When you bypass TQue you also handle the pipe-to-pipe flags:

```cpp
// after DMA-load completes, signal the vector pipe
set_flag(PIPE_MTE2, PIPE_V, EVENT_ID0);
wait_flag(PIPE_V,  PIPE_MTE2, EVENT_ID0);  // V waits for MTE2

// ... vector compute that reads/writes the same UB region ...

set_flag(PIPE_V, PIPE_MTE3, EVENT_ID0);
wait_flag(PIPE_MTE3, PIPE_V, EVENT_ID0);   // MTE3 waits for V
```

Pipe enums: `PIPE_MTE1 / MTE2 / MTE3 / V / M / S / FIX`.
`EVENT_ID0..3` lets up to 4 logical channels coexist on the same
pipe pair — useful for double-buffering by alternating events
across iterations.

For end-of-kernel cleanup, drain a pipe with
`PipeBarrier<PIPE_MTE3>()` before exit.

## 4. Layer 3 — PTO ISA (compiler-emitted, you rarely write this)

At the assembly level the AIV's MTE2/MTE3 queues consume their own
opcodes (separate from `VLDI`/`VSTI`, which are **UB↔vreg**, not
**GM↔UB**). In our `mask_kernel` camodel trace they appear on
`tid=MTE2` and `tid=MTE3` with `RV_*` mnemonics — but the compiler
emits these from the intrinsics / `DataCopy` calls above; almost
no kernel writer touches this layer directly.

The pipe-to-pipe sync flags compile down to scalar ops on the SU
pipe (`set_flag` / `wait_flag` instructions); double-buffering
compiles to `EVENT_ID` rotation across iterations.

> See `a5_pto_bool_vloop_walkthrough.md` §5.4–§5.5 for the empirical
> per-pipe behavior on a real trace, and `a5_aiv_vector_parallelism.html`
> §5 for the dual-issue evidence on MTE2.

## 5. Practical templates

### 5.1 One-shot vector kernel (no loop)

```cpp
DataCopy(ubIn, xGm, len);                                   // MTE2
SetFlag<HardEvent::MTE2_V>(EVENT_ID0);
WaitFlag<HardEvent::MTE2_V>(EVENT_ID0);                     // V waits for MTE2
// vector compute on ubIn → ubOut
SetFlag<HardEvent::V_MTE3>(EVENT_ID0);
WaitFlag<HardEvent::V_MTE3>(EVENT_ID0);                     // MTE3 waits for V
DataCopy(zGm, ubOut, len);                                  // MTE3
PipeBarrier<PIPE_MTE3>();                                   // drain before exit
```

### 5.2 Double-buffered loop (the recommended form)

Use the `TQue` pattern in §2 with `BUFFER_NUM = 2`. The runtime
rotates events 0/1 across iterations; pass N's compute overlaps with
pass N+1's MTE2 load and pass N-1's MTE3 store.

### 5.3 Matrix kernel skeleton (AIC side, MTE1 + MTE2 + Fixpipe)

```cpp
TQue<TPosition::A1, BUFFER_NUM> qL1A;
TQue<TPosition::A2, BUFFER_NUM> qL0A;
TQue<TPosition::B1, BUFFER_NUM> qL1B;
TQue<TPosition::B2, BUFFER_NUM> qL0B;
TQue<TPosition::CO1, BUFFER_NUM> qL0C;

// stage GM → L1
DataCopy(l1A, aGm[…], DataCopyParams{…});                   // MTE2

// stage L1 → L0A / L0B (matrix operand format)
LoadData(l0A, l1A, LoadData2DParams{…});                    // MTE1
LoadData(l0B, l1B, LoadData2DParams{…});                    // MTE1

// matrix multiply on L0A * L0B → L0C
Mmad(l0C, l0A, l0B, MmadParams{…});                         // M (Cube)

// drain L0C → GM
DataCopyEnhancedParams params; params.cbufWorkspaceAddr = ws;
DataCopy(cGm[…], l0C, params);                              // Fixpipe
```

## 6. Sync rules at a glance

```
producer pipe  →  consumer pipe   meaning
─────────────  ─    ─────────────   ────────────────────────────
MTE2          →    V                 vector waits for GM→UB load
MTE2          →    M                 cube waits for GM→L1/L0 load
MTE1          →    M                 cube waits for L1→L0A/L0B
M             →    FIX               drain L0C only after Mmad done
V             →    MTE3              store waits for compute output
FIX           →    MTE2 (next iter)  next-iter prefetch can run only
                                     after Fixpipe drained workspace
```

Forget any of these and you get a data hazard; the camodel will
usually catch it as a wrong-result mismatch, but on real silicon it
can race silently.

## 7. Verification recipes

- **See which MTE the compiler chose.** Dump the MLIR after
  `--lower-hfusion-pipeline --optimize-hivm-pipeline` (see
  `~/Documents/diary/2026-05-07.md` morning entry); MTE intrinsics
  appear as `hivm.dma.*` ops with explicit src/dst memory class.
- **See MTE on the trace.** In any camodel-generated
  `dump2trace_core*.json`, filter `tid==MTE2` or `tid==MTE3`. Each
  event has start cycle (`ts`), duration (`dur`), source/dest
  address (`args.addr`), and the issuing instruction
  (`args.detail`). Same trace also has `RVECEX` / `RVECLD` /
  `RVECST` events — overlapping `ts` ranges across pipes is your
  proof that MTE concurrency works.
- **Check sync flags fired correctly.** `bishengir-opt
  --optimize-hivm-pipeline` emits the lowered `set_flag` /
  `wait_flag` ops; misordered pairs show up as wait-on-wrong-event
  in the IR.

## Cross-references

- `a5_aiv_vector_parallelism.html` §1.2 — MTE pipes on the AIV
  diagram, instruction queues
- `a5_aiv_vector_parallelism.html` §5 — empirical MTE2 dual-issue
  evidence from the camodel trace
- `a5_pto_bool_vloop_walkthrough.md` §5.3 — vendor-published
  hardware facts incl. MTE pipe inventory
- `a5_pto_bool_vloop_walkthrough.md` §6.18 (Opt 21) — cross-launch
  MTE2 prefetch as the highest-leverage missed optimization on
  `mask_kernel`
- `~/Documents/docs/ascend_910c_microarchitecture.md` — full
  hardware-architecture reference for the MTE pipes across 910x /
  910B / 910C / A5

---

Generated 2026-05-10. Examples assume CANN ≥ 8.5.0 (AscendC API
stabilized at this version). Intrinsic argument lists are taken
from the public CANN headers; ISA-level mnemonics from the A5
camodel trace produced for `mask_kernel_a5.o`.
