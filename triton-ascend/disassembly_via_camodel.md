# Disassembling Ascend NPU kernels via camodel trace

_Last updated: 2026-05-07._

CANN-8.5.0 doesn't ship a working public disassembler for Ascend AICore (`hiipu64`) machine code — the BiSheng `llvm-objdump` decoder is gated, and `msdebug` (LLDB fork) refuses to decode. **But** a camodel cycle-accurate run produces per-instruction execution traces that, after parsing with `msopgen sim`, give you mnemonic + operand + pipeline-classification annotations on every instruction the kernel actually executed.

Companions:
- [`ascend_cycle_profiling.md`](ascend_cycle_profiling.md) — the camodel-launch + msopgen-sim infrastructure (§3.6–3.8). This doc reuses that recipe; read it first.
- [`triton_ascend_lowering.md`](triton_ascend_lowering.md) — what's in the `.npubin` and what other disassembly tooling looks like.

---

## 1. The trick

Camodel emits per-instruction trace dumps for every instruction it simulates. The dumps are binary; `msopgen sim` parses them into a Chrome-trace JSON where every event is one issued instruction with its mnemonic, operands, and timing.

```bash
# 1. Run the kernel under camodel — see ascend_cycle_profiling.md §3.6
python3 triton_camodel.py        # ~2 min wall-clock for vector_add

# 2. Parse the per-core dumps — see ascend_cycle_profiling.md §3.7
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
mkdir -p trace_out
for c in core0 core1 core2 core3; do
  for sc in veccore0 veccore1; do
    msopgen sim -c $c -subc $sc -d $DUMP_DIR -out trace_out
  done
done
```

Output: `trace_out/dump2trace_core{0..3}.json` — Chrome-trace JSON.

**Don't pass `-reloc <kernel.npubin>`.** That triggers `llvm-objdump --save-aicore-bins` which is decoder-gated and the run errors out. Without `-reloc` the trace JSON still has full mnemonics + operands; you just lose source-line annotations on each instruction.

## 2. What each trace event gives you

```json
{
  "name": "MOV_XD_IMM",
  "cname": "startup",
  "ph": "X",
  "ts": 688,
  "dur": 2,
  "pid": "core0_veccore0",
  "tid": "SCALAR",
  "args": {
    "addr": "0x10d11000",
    "detail": "XD:X29=0x7f80, IMM:0x7f80,"
  }
}
```

Each event encodes:

| Field | What it tells you |
|---|---|
| `name` | Mnemonic — the instruction name (`MOV_XD_IMM`, `LDP_XI_XJ_XN`, `DIV`, `JUMPC`, `SET_FLAG`, `MOVEMASK`, …) |
| `args.addr` | PC — sortable to reconstruct the static binary order |
| `args.detail` | Operand string with **register names AND their values at issue time** (e.g. `XD:X29=0x7f80, IMM:0x7f80`) |
| `tid` | Pipeline that issued it: `SCALAR` / `VECTOR` / `MTE2` / `MTE3` / `FLOWCTRL` |
| `ts` | Cycle timestamp at issue |
| `dur` | Cycles to complete (`DIV` = 21, most scalar = 2, sync flags = 1) |
| `pid` | Which veccore: `core{N}_veccore{0,1}` (or `cubecore0` for AIC kernels) |
| `cname` | Trace-renderer color hint — useful for `chrome://tracing` view |

You get the full **dynamic execution trace with operand values** — strictly more information than a static `objdump -d` dump, for the inputs you ran.

## 3. Worked example — full executed assembler for `vector_add`

68 instructions executed on core0/veccore0 over a 1053-cycle span, sorted by PC and grouped by phase.

> **Phase labels are interpretive, not directly evidenced.** The trace gives PC + mnemonic + operand state + pipeline; **it does not give source-line annotations** (that path requires `msopgen sim -reloc <npubin>` which triggers the gated BiSheng llvm-objdump decoder). The phase boundaries below are inferred from explicit SPR names in operands (`SYS_VA_BASE`, `COREID`, `PARA_BASE`, `BLOCKID`, `CTRL`), `JUMPC` targets, and pattern-matching on Triton-Ascend's typical lowering shape. **See §3.8 for what's solid vs guessed.**

### 3.1 Phase 1 — Setup (PC 0x10d11000–0x10d11030)

Register init, special-purpose register reads, mask register init.

```
0x10d11000  MOV_XD_IMM   X29 = 0x7f80                                    ; SCALAR  2 cyc
0x10d11004  MOVK         X29 = 0x107f80   (insert 0x10 at UIMM:1)        ; SCALAR  2 cyc
0x10d11008  MOV_XD_SPR   X15 = SYS_VA_BASE                               ; SCALAR  2 cyc
0x10d1100c  ADD          X29 = X29 + X15                  (S64)          ; SCALAR  2 cyc
0x10d11010  MOV_XD_SPR   X15 = COREID         (= 0x19)                   ; SCALAR  2 cyc
0x10d11014  MOV_XD_IMM   X16 = 0x7fff                                    ; SCALAR  2 cyc
0x10d11018  MOV_XD_IMM   X0  = 0x1                                       ; SCALAR  2 cyc
0x10d1101c  AND          X15 = X15 & X16                  (B64)          ; SCALAR  2 cyc
0x10d11020  MOV_XD_IMM   X17 = 0x8000                                    ; SCALAR  2 cyc
0x10d11024  NEG          X0  = -X0          (= 0xff..ff)  (S64)          ; SCALAR  2 cyc
0x10d11028  MADD         X29 = X15*X17 + X29 = 0x1cff80   (S64)          ; SCALAR  4 cyc  ← stack-frame base = COREID*0x8000 + ffts_base
0x10d1102c  MOVEMASK     pos:0  id:11    XN:X0=0xff..ff                  ; VECTOR  17 cyc ← initialize vector mask register
0x10d11030  MOVEMASK     pos:1  id:12    XN:X0=0xff..ff                  ; VECTOR  17 cyc
```

### 3.2 Phase 2 — Parameter loading (PC 0x10d11034–0x10d11058)

Read kernel args from PARA_BASE: x_ptr, y_ptr, n_elements, gridX/Y/Z.

```
0x10d11034  ADD_IMM      X30 = X29 + 0x770   (= 0x1d06f0)                ; SCALAR  2 cyc   ← workspace pointer
0x10d11038  MOV_XD_SPR   X1  = PARA_BASE     (= 0x1022fe00)              ; SCALAR  2 cyc
0x10d1103c  ADD_IMM      X6  = X1 + 0x38     (= 0x1022fe38)              ; SCALAR  2 cyc
0x10d11040  ADD_IMM      X0  = X1 + 0x20     (= 0x1022fe20)              ; SCALAR  2 cyc
0x10d11044  LD_XD_XN_IMM X5  = [X1 + 0x18]   (B64)                       ; SCALAR  361 cyc ← load FFTS-related metadata (cache miss)
0x10d11048  ADD_IMM      X2  = X1 + 0x30                                 ; SCALAR  2 cyc
0x10d1104c  LDP_XI_XJ_XN X1,X6 = [X6]        (B32 pair)                  ; SCALAR  361 cyc ← load gridX, gridY (cache miss)
0x10d11050  LDP_XI_XJ_XN X3,X0 = [X0]        (B64 pair)                  ; SCALAR  361 cyc ← load 2 ptrs (x_ptr, y_ptr)
0x10d11054  MUL          X1  = X6 * X1                    (S64)          ; SCALAR  3 cyc
0x10d11058  LDP_XI_XJ_XN X2,X4 = [X2]        (B32 pair)                  ; SCALAR  6 cyc   ← load (gridZ, n_elements)
```

### 3.3 Phase 3 — program_id computation + bounds (PC 0x10d1105c–0x10d110ac)

`DIV`/`REM` on BLOCKID to get program_id; clamp to valid offset range.

```
0x10d1105c  MOV_XD_SPR   X7 = CTRL                                       ; SCALAR  2 cyc
0x10d11060  MOV_XD_SPR   X6 = BLOCKID        (= 0x1)                     ; SCALAR  2 cyc   ← which grid block this is
0x10d11064  INSERT_XD    X7 bit-insert (POS:0x38)                        ; SCALAR  2 cyc
0x10d11068  SIGNEXT      X6 = (S32) X6                                   ; SCALAR  2 cyc
0x10d1106c  SIGNEXT      X1 = (S32) X1                                   ; SCALAR  2 cyc
0x10d11070  MOV_SPR_XN   CTRL = X7                                       ; SCALAR  1 cyc
0x10d11074  DIV          X1 = X6 / X1                     (S64)          ; SCALAR  21 cyc  ← BLOCKID / gridX_total → program_id
0x10d11078  SIGNEXT      X4 = (S32) X4                                   ; SCALAR  2 cyc
0x10d1107c  SIGNEXT      X2 = (S32) X2                                   ; SCALAR  2 cyc
0x10d11080  SIGNEXT      X1 = (S32) X1                                   ; SCALAR  2 cyc
0x10d11084  REM          X1 = X1 % X4                     (S64)          ; SCALAR  21 cyc  ← within-row index
0x10d11088  SHL          X1 = imm 0x7   (= 0xff..ff80, i.e. -128)        ; SCALAR  2 cyc
0x10d1108c  SIGNEXT      X6 = (S32) X1                                   ; SCALAR  2 cyc
0x10d11090  MAX          X1 = max(X2, X6)                 (S64)          ; SCALAR  2 cyc   ← lower bound
0x10d11094  ADD_IMM      X2 = X6 + 0x80                                  ; SCALAR  2 cyc   ← upper bound = base + BLOCK
0x10d11098  MIN          X7 = min(X2, X1)                 (S64)          ; SCALAR  2 cyc
0x10d1109c  SUB          X4 = X7 - X6                     (= 0x80)       ; SCALAR  2 cyc   ← effective tile size
0x10d110a0  MOV_XD_XN    X1 = X6                          (S64)          ; SCALAR  2 cyc
0x10d110a4  MOV_XD_XN    X2 = X4                          (S64)          ; SCALAR  2 cyc
0x10d110a8  SHL          X1 = X1 << 0x2  (×4 for f32 byte offset)        ; SCALAR  2 cyc
0x10d110ac  SHL          X2 = imm 0x12                                   ; SCALAR  2 cyc
```

### 3.4 Phase 4 — Mask check + branch (PC 0x10d110b0–0x10d110b4)

Triton's `mask = offsets < n_elements` lowering: full-tile fast path vs masked-tail slow path.

```
0x10d110b0  CMP_IMM      X4 vs 0x7f, GT?                                 ; SCALAR  2 cyc   ← is tile size > 127 (full BLOCK)?
0x10d110b4  JUMPC        if cond=1 → PC=0x10d111d8                       ; FLOWCTRL 1 cyc  ← TAKEN (skip masked-tail path)
```

### 3.5 Phase 5 — Full-tile fast path (PC 0x10d111d8–0x10d11234)

DMA descriptor build + VEC↔MTE2 sync handshake. The actual element-wise add lives at PCs we didn't reach in this run (in the masked-tail or in tile-loop iterations).

```
0x10d111d8  SHL          X4 = imm 0x2     (= 0x200)                      ; SCALAR  2 cyc
0x10d111dc  ADD_IMM      X6 = X4 + 0x1f   (= 0x21f)                      ; SCALAR  2 cyc
0x10d111e0  MOV_XD_IMM   X7 = 0xe0                                       ; SCALAR  2 cyc
0x10d111e4  AND          X6 = X6 & X7     (= 0)         (B64)            ; SCALAR  2 cyc
0x10d111e8  SUB          X4 = X6 - X4     (= 0xff..fe00)                 ; SCALAR  2 cyc
0x10d111ec  MOV_XD_IMM   X6 = 0                                          ; SCALAR  2 cyc
0x10d111f0  SHL          X4 = imm 0x34    (= 0xe000_0000_0000_0000)      ; SCALAR  2 cyc
0x10d111f4  MOVK         X6 = 0xfc0_0000_0000_0000  (insert at UIMM:3)   ; SCALAR  2 cyc
0x10d111f8  AND          X4 = X4 & X6     (= 0)                          ; SCALAR  2 cyc
0x10d111fc  MOV_XD_IMM   X6 = 0                                          ; SCALAR  2 cyc
0x10d11200  MOVK         X6 = 0xfffc_0000  (insert at UIMM:1)            ; SCALAR  2 cyc
0x10d11204  STI_XN_IMM   [X30 + 0x880] = ZERO  (B32, store-immediate)    ; SCALAR  259 cyc ← clear MTE descriptor slot (cache miss)
0x10d11208  MOVK         X6 = 0x1f_fffc_0000  (insert at UIMM:2)         ; SCALAR  2 cyc
0x10d1120c  LD_XD_XN_IMM X7 = [X30 + 0x880] (B64)                        ; SCALAR  257 cyc ← reload after store (cache miss)
0x10d11210  AND          X6 = X2 & X6     (= 0x2000000)  (B64)           ; SCALAR  2 cyc
0x10d11214  SET_FLAG     PIPE:VEC, TRIGGER:MTE2, FLAG_ID:0               ; VECTOR  1 cyc   ← signal MTE2: load is ready
0x10d11218  OR           X4 = X6 | X4     (= 0x2000000)                  ; SCALAR  2 cyc
0x10d1121c  WAIT_FLAG    PIPE:VEC, TRIGGER:MTE2, FLAG_ID:0               ; MTE2    1 cyc   ← MTE2 receives the signal
0x10d11220  ADD          X5 = X5 + X1                                    ; SCALAR  2 cyc
0x10d11224  INSERT_XD    X4 = bit-insert at POS:0x4                      ; SCALAR  2 cyc
0x10d11228  MOV_XD_IMM   X6 = 0                                          ; SCALAR  2 cyc
0x10d11234  SET_FLAG     (final fence — kernel done)                     ; VECTOR  1 cyc
```

### 3.6 What this listing tells you about Triton's lowering

- **No actual `VEC.ADD` / element-wise vector instruction appears.** The `vector_add` semantics (`x + y`) is in the masked-tail path the `JUMPC` skipped, or in tile-loop iterations that didn't fire on this BLOCKID. The 68 instructions we see are setup + parameter loading + program-id math + bounds clamping + sync — i.e. the part of the kernel that runs once per dispatch regardless of which path the data takes.
- **53 of 68 instructions are pure setup before the branch.** Spending three quarters of a kernel on setup is plausible for a 1024-element add; with a larger `n` and more tile iterations the ratio amortizes.
- **Heavy memory-stall costs:** three loads at 361 cycles each (`LD_XD_XN_IMM`/`LDP_XI_XJ_XN` on first access to the kernel param block — first-touch cache miss), plus a 259/257-cycle store/reload pair at 0x10d11204. These dominate the SCALAR-pipe busy count (1757 of 1053 span cycles — pipes overlap).
- **Pipe-pair sync** (`SET_FLAG` VEC→MTE2 + `WAIT_FLAG` MTE2 receives) appears once. Triton's lowering uses one VEC↔MTE2 handshake per tile load.
- **Branch taken**: `JUMPC` at 0x10d110b4 → 0x10d111d8 skips ~290 bytes of masked-tail code that's invisible in this trace. Surfacing it would need a non-128-aligned `n` (e.g. 1023 or 1100).

### 3.7 What's NOT in the executed slice

The full `.text` is **740 bytes / 185 instructions**. We executed 68 here. The other ~117 are:
- Masked-tail path (PC range ~0x10d110b8–0x10d111d4) — taken when `tile_size <= 127`
- The actual `VEC_ADD` (or equivalent element-wise op) and its surrounding load/store
- Possibly an outer tile loop for larger `n`
- Error/abort handlers
Run the kernel with different inputs (e.g., `n=1023`) to surface them.

### 3.8 Solid evidence vs. inference — how reliable are the phase labels?

The phase labels in §3.1–3.5 are not directly evidenced in the trace. Here's what's strong, what's pattern-matched, and what's a guess.

**Directly observable in the trace** (these are facts):

| Signal | Where it appears | What it tells you |
|---|---|---|
| SPR names in operand details | `SPR:SYS_VA_BASE`, `SPR:COREID`, `SPR:PARA_BASE`, `SPR:BLOCKID`, `SPR:CTRL` | Architectural register being read — explicit in the trace |
| `JUMPC` target PC | `Target PC:0x10d111d8, cond_flag:1` | Defines branch boundary — explicit |
| `SET_FLAG` / `WAIT_FLAG` operands | `PIPE:VEC, TRIGGER PIPE:MTE2, FLAG ID:0` | Pipe-pair sync semantics — explicit |
| `cname` field | "startup" on PC 0x10d11000–0x10d111fc, "rail_response" on `JUMPC`, "cq_build_failed" on VEC ops, "thread_state_iowait" on `WAIT_FLAG` | Camodel render-color hint, **not a kernel-phase label** — but suggestive |
| Per-instruction `dur` | `LD_XD_XN_IMM`=361, `DIV`=21, `STI_XN_IMM`=259, etc. | Direct cycle cost — explicit |

**Inferred phase labels** (these are interpretation):

| Phase | Inference basis | Strength |
|---|---|---|
| §3.1 Setup | First reads of `SYS_VA_BASE` + `COREID` SPRs; `cname="startup"` on these PCs; mask-register init via `MOVEMASK` | **Strong** — SPRs by convention read in kernel prologue; `MOVEMASK` initializes vector mask |
| §3.2 Parameter loading | `MOV_XD_SPR PARA_BASE` then `LD/LDP` from `PARA_BASE+offset` | **Strong — SPR is literally named "parameter base"** |
| §3.3 program_id computation | `MOV_XD_SPR BLOCKID` then `DIV` and `REM` | Moderate — DIV/REM after BLOCKID is the textbook block-id → program_id pattern, but the trace doesn't say so. Could plausibly be tile-coordinate math. |
| §3.4 Mask check + branch | `CMP_IMM ... 0x7f, GT` immediately followed by `JUMPC` | **Weak — the most interpretive label.** It's a compare-and-branch; calling it "mask check" assumes Triton's `mask = offsets < n_elements` lowering. The `0x7f = 127` immediate is consistent with "is tile size > 127" matching our `BLOCK=128`, which is circumstantial correlation but not proof. |
| §3.5 Full-tile fast path | The PC region after the taken `JUMPC` | Moderate — labeling it "fast path" assumes the not-taken branch is slow (masked-tail), which is just my framing. The trace doesn't tag it. |

**What would make the labels rigorous:**
- `msopgen sim -reloc <npubin>` would map PCs to source lines — but the underlying `llvm-objdump --save-aicore-bins` decoder is gated.
- Re-running with `n=1023` (non-128-aligned) would force `JUMPC` the other way; whichever PC range becomes the executed-branch this time IS the masked-tail path. Whichever stays unexecuted IS the fast path. That confirms §3.4 and §3.5 directly.
- Reading the Triton-Ascend pattern that emits the mask-check IR-to-asm lowering would close §3.3 and §3.4.

**Don't take the phase labels as ground truth.** They're a reading of the assembler that's consistent with the kernel's source, the SPR names visible in the trace, and the typical Triton-Ascend lowering shape. The instruction-level data (mnemonics, operands, cycle counts, pipes) is direct.
- **0x10d11214–0x10d11234**: `SET_FLAG` / `WAIT_FLAG` synchronization between VEC and MTE2 pipes — the load/compute/store handshake

## 4. What this does NOT give you

| Limitation | Why |
|---|---|
| **Untaken branches don't appear** | Camodel is a cycle-accurate simulator, not a static decoder. Code in branches the kernel didn't take on this input is invisible. For `vector_add`: the `.text` is 185 instructions; we executed 68. The other ~117 are in mask-skip paths, error handlers, alternate program-id tiles, etc. |
| **No source-line annotations** | `msopgen sim -reloc <npubin>` would map PC → source line, but the underlying `llvm-objdump --save-aicore-bins` decoder is gated. Without it, you have addresses + mnemonics but no mapping back to `.cce` / `.cpp` / `.py`. |
| **Static binary layout is reconstructed from execution, not parsed** | Sort events by `addr` to recover the static order in the executed region. Gaps in PC space are either dead code or branches you didn't enter. Can't tell which without re-running with different inputs. |
| **Instructions inside the same VLIW slot are flat-listed** | Camodel issues each into its pipeline at the recorded `ts`, but you don't see the bundle structure. Reconstruct it by grouping events with the same or near-equal `ts` but different `tid`. |

## 5. Strategies to get fuller coverage

Since traces only show executed instructions, varying the inputs surfaces more of the binary:

- **Vary input shapes** — `n=1024 vs 4096 vs 100` will hit different mask paths and different tile-loop trip counts.
- **Vary `BLOCK`** — different unroll factors → different unrolled instruction sequences materialize.
- **Vary grid dimensions** — kernels often have separate code paths for `program_id == 0` (header) vs middle vs last block.
- **Force error paths** — e.g. unaligned addresses, NaN inputs — to surface error-handling code.

After multiple runs, union the executed PCs to see what fraction of `.text` you've covered:

```python
import json, glob
seen = set()
for f in glob.glob("trace_*/dump2trace_core*.json"):
    d = json.load(open(f))
    events = d.get("traceEvents", d) if isinstance(d, dict) else d
    for e in events:
        addr = e.get("args", {}).get("addr")
        if addr: seen.add(int(addr, 16))
print(f"Unique PCs executed: {len(seen)}  ({min(seen):#x} – {max(seen):#x})")
```

## 6. When this matters

- **Reverse-engineering a Triton-generated kernel** to understand what the compiler chose for tiling, masking, and pipelining at the instruction level.
- **Verifying a kernel uses the expected pipes** — e.g., confirming a matmul actually fires `CUBE` ops instead of falling back to scalar simulation.
- **Cycle-attribution for hot instructions** — the per-instruction `dur` field tells you exactly which ops are expensive (`DIV`, `REM`, `LDP_XI_XJ_XN` with cache-miss durations of 360+ cycles).
- **Checking that pipe-pair sync (`SET_FLAG` / `WAIT_FLAG`) is non-redundant** — too many barriers serialize VEC and MTE2 unnecessarily.

## 7. TL;DR

Camodel + `msopgen sim` is **execution-trace disassembly with operand values and per-instruction timing**. Strictly stronger than static `objdump` for the inputs you ran. Strictly weaker for whole-binary coverage. The only public path to mnemonic disassembly on shipped CANN-8.5.0 — the BiSheng `llvm-objdump` static decoder is gated, so this is what you have.

## 8. References

- `/usr/local/Ascend/cann-8.5.0/python/site-packages/op_gen/simulator/simulator.py` — the parser (called by `msopgen sim`)
- `/home/Ray/triton_hello/camodel_run/triton_camodel.py` — the launcher
- `/home/Ray/triton_hello/camodel_run/trace_all/dump2trace_core{0..3}.json` — the parsed traces from the `vector_add` run
- [`ascend_cycle_profiling.md`](ascend_cycle_profiling.md) §3.6–3.8 — full launch + parse recipe
- [`triton_ascend_lowering.md`](triton_ascend_lowering.md) — kernel pipeline context
