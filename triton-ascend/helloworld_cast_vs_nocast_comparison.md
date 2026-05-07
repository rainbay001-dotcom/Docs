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

## 7. Where everything lives

Server (192.168.25.218):
- `/home/Ray/triton_hello/helloworld_runner.py` — bool kernel
- `/home/Ray/triton_hello/helloworld_cast_runner.py` — cast kernel
- `/home/Ray/triton_hello/mask_cache/<hash>/mask_kernel.npubin` — bool compiled
- `/home/Ray/triton_hello/mask_cast_cache/<hash>/mask_kernel_cast.npubin` — cast compiled
- `/home/Ray/triton_hello/camodel_run/mask_dumps/` + `mask_cast_dumps/` — per-core dumps
- `/home/Ray/triton_hello/camodel_run/mask_trace/` + `mask_cast_trace/` — parsed traces

Local:
- `/tmp/mask_trace.json` — bool trace (1.95 MB)
- `/tmp/mask_cast_trace.json` — i32 trace (1.93 MB)

## 8. TL;DR

| Finding | Implication |
|---|---|
| `+1.3%` cycle span (cast slightly slower) | The cast doesn't help; intermediate-type rearrangement is roughly cycle-neutral |
| `-15%` binary size (cast smaller) | Triton emits less per-bool-bit-packing helper code, but execution time isn't proportional |
| `VNCHWCONV` + `MOVEVA` (~1.3K cyc) eliminated by cast | Bool-packing path has measurable structural overhead |
| `WAIT_FLAG`/`SET_FLAG`/`BAR` (+1K cyc) added by cast | i32-width path needs more inter-pipe sync |
| **Loop body and 1024 stores unchanged** | The kernel's bottleneck is the scalar unpack-store loop, not the upstream type. Cast doesn't touch it. |
| **To actually speed up**: change the output type | Pack output as bitmap or wider int → cut store cost ~8×. Casting intermediates can't fix what the output type forces. |
