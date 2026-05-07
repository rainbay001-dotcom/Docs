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

## 3. Worked example — `vector_add`

68 instructions executed on core0/veccore0 over a 1053-cycle span. Sample slice:

```
PC          Mnemonic     Operands                                Pipe    Cycle  Dur
0x10d11000  MOV_XD_IMM   X29=0x7f80, IMM:0x7f80                  SCALAR  ts=688  dur=2
0x10d11004  MOVK         X29=0x107f80, IMM:0x10, UIMM:0x1        SCALAR  ts=689  dur=2
0x10d11008  MOV_XD_SPR   X15=0,  SPR:SYS_VA_BASE                 SCALAR  ts=689  dur=2
0x10d1100c  ADD          X29=0x107f80, X29, X15  (S64)           SCALAR  ts=691  dur=2
0x10d11010  MOV_XD_SPR   X15=0x19, SPR:COREID                    SCALAR  ts=695  dur=2
0x10d11014  MOV_XD_IMM   X16=0x7fff, IMM:0x7fff                  SCALAR  ts=695  dur=2
0x10d1101c  AND          X15=0x19, X15, X16                      SCALAR  ts=696  dur=2
0x10d1102c  MOVEMASK     XN:X0=0xff..ff, Pos:0, Id:11            VECTOR  ts=699  dur=17
0x10d11074  DIV          X1=…, X6=0x19, X1=0    (S64)            SCALAR  ts=1069 dur=21  ← prog_id divide
0x10d11084  REM          X1=…, X1, X4           (S64)            SCALAR  ts=1090 dur=21  ← prog_id mod
0x10d110b0  CMP_IMM      X4=0x80, IMM:0x7f, GT                   SCALAR  ts=1116 dur=2
0x10d110b4  JUMPC        Target=0x10d111d8, cond=1               FLOWCTL ts=1117 dur=1   ← jump (taken)
0x10d11214  SET_FLAG     PIPE:VEC, TRIGGER:MTE2, FLAG:0          VECTOR  ts=1484 dur=1   ← VEC→MTE2 sync
0x10d1121c  WAIT_FLAG    PIPE:VEC, TRIGGER:MTE2, FLAG:0          MTE2    ts=1485 dur=1
0x10d11234  SET_FLAG     (last)                                  VECTOR  ts=1741 dur=1
```

You can see the kernel's structure unfold:

- **0x10d11000–0x10d1101c**: register init — read special-purpose registers (`SYS_VA_BASE`, `COREID`), build base addresses
- **0x10d11074–0x10d11088**: `DIV`/`REM`/`SHL` — compute `program_id` from `COREID` and tile decomposition (each `DIV` is 21 cycles, ~10× a typical scalar op)
- **0x10d110b0–0x10d110b4**: mask check (`CMP_IMM` + `JUMPC`) — Triton's `mask = offsets < n_elements` skip path
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
