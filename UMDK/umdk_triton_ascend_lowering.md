# Triton-Ascend lowering: Python → TTIR → TTAdapter → NPU binary

_Last updated: 2026-05-06._

How a 7-line `@triton.jit` kernel becomes machine code on Ascend AICore. Walks through every IR stage Triton-Ascend dumps, shows the actual file contents, and documents what disassembly tooling is and isn't publicly available.

Tested on:
- 192.168.25.218 container (port 1234)
- Triton-Ascend 3.2.0 in `/home/Ray/vllm_v13_venv`
- CANN 8.5.0 + driver 25.5.1
- Target: Ascend910_9362 (AI Vector core)

---

## 1. The pipeline at a glance

```
   vector_add.py        7 lines of Python with @triton.jit
        │
        │ Triton frontend (Python AST → MLIR)
        ▼
   add_kernel.ttir      Triton IR (high-level MLIR dialect)        ~25 ops
        │
        │ Triton-Ascend lowering passes
        ▼
   add_kernel.ttadapter TTAdapter (Ascend-specific MLIR)            ~40 ops
        │
        │ BiSheng / CCE compiler (proprietary, uses LLVM 15 internally)
        ▼
   add_kernel.npubin    ELF64 with HiIPU AICore machine code        3168 B
                          .text = 740 B (one 740-byte kernel function)
                          + .ascend.stack.size.record (8 B)
                          + __CCE_KernelArgSize (4 B)
                          + .comment, .symtab, .strtab, .shstrtab

   launcher_cxx11abi1.cxx + .so   host-side C++ stub that loads + invokes the .npubin
```

What's NOT in the dump pipeline (gated/internal):
- LLVM IR (the BiSheng compiler uses LLVM 15 internally, but doesn't surface `.ll` as a Triton dump artifact).
- AICore mnemonic disassembly — see §6 for what's publicly available.

## 2. Reproduction

```bash
ssh -p 1234 root@192.168.25.218
source /home/Ray/vllm_v13_venv/bin/activate
source /usr/local/Ascend/ascend-toolkit/set_env.sh

mkdir -p /home/Ray/triton_hello
cat > /home/Ray/triton_hello/vector_add.py << 'PYEOF'
import torch
import torch_npu
import triton
import triton.language as tl

@triton.jit
def add_kernel(x_ptr, y_ptr, out_ptr, n_elements, BLOCK: tl.constexpr):
    pid = tl.program_id(0)
    offsets = pid * BLOCK + tl.arange(0, BLOCK)
    mask = offsets < n_elements
    x = tl.load(x_ptr + offsets, mask=mask)
    y = tl.load(y_ptr + offsets, mask=mask)
    tl.store(out_ptr + offsets, x + y, mask=mask)

n = 1024
x = torch.arange(n, dtype=torch.float32, device="npu")
y = torch.full((n,), 10.0, dtype=torch.float32, device="npu")
out = torch.empty_like(x)
BLOCK = 128
grid = (triton.cdiv(n, BLOCK),)
add_kernel[grid](x, y, out, n, BLOCK=BLOCK)
print("max err:", (out - (x + y)).abs().max().item())
PYEOF

# Pin to a free chip; check chips with `npu-smi info`.
export ASCEND_RT_VISIBLE_DEVICES=4
# Direct dumps to a known place; force fresh compile.
export TRITON_CACHE_DIR=/home/Ray/triton_hello/cache
export TRITON_DUMP_DIR=/home/Ray/triton_hello/dump
export TRITON_ALWAYS_COMPILE=1
export TRITON_DEBUG=1
export MLIR_ENABLE_DUMP=1

cd /home/Ray/triton_hello
python vector_add.py
```

The `cache/<hash>/` directory after the run contains:

```
add_kernel.ttir            Stage 1 — Triton IR (text MLIR)
add_kernel.ttadapter       Stage 2 — TTAdapter MLIR (Ascend-lowered)
add_kernel.npubin          Stage 3 — final ELF binary
add_kernel.json            compile metadata (target, mix_mode, etc.)
__grp__add_kernel.json     pointer index for the above
```

The `dump/<hash>/` directory mirrors the `.ttir.mlir` and `.ttadapter.mlir` (same content as cache, with `.mlir` extension).

The `cache/<launcher-hash>/` directory contains the host-side C++ launcher:
```
launcher_cxx11abi1.cxx                            generated C++ source
launcher_cxx11abi1.cpython-310-aarch64-linux-gnu.so  compiled Python extension
precompiled.h, precompiled.h.gch                  PCH for fast rebuild
```

## 3. Stage 1 — TTIR (Triton's high-level MLIR dialect)

Reads almost like the Python source. Operates on `tensor<128xf32>` and `!tt.ptr<f32>` — abstract Triton types. No notion of memory hierarchy, scratchpads, or hardware blocks.

```mlir
module {
  tt.func public @add_kernel(
      %arg0: !tt.ptr<f32> {tt.divisibility = 16 : i32},
      %arg1: !tt.ptr<f32> {tt.divisibility = 16 : i32},
      %arg2: !tt.ptr<f32> {tt.divisibility = 16 : i32},
      %arg3: i32 {tt.divisibility = 16 : i32}
  ) attributes {noinline = false} {
    %cst = arith.constant dense<0.000000e+00> : tensor<128xf32>
    %c128_i32 = arith.constant 128 : i32
    %0 = tt.get_program_id x : i32                              // pid
    %1 = arith.muli %0, %c128_i32 : i32                         // pid * BLOCK
    %2 = tt.make_range {end = 128, start = 0} : tensor<128xi32> // tl.arange(0, BLOCK)
    %3 = tt.splat %1 : i32 -> tensor<128xi32>
    %4 = arith.addi %3, %2 : tensor<128xi32>                    // offsets
    %5 = tt.splat %arg3 : i32 -> tensor<128xi32>
    %6 = arith.cmpi slt, %4, %5 : tensor<128xi32>               // mask
    %7 = tt.splat %arg0 : !tt.ptr<f32> -> tensor<128x!tt.ptr<f32>>
    %8 = tt.addptr %7, %4                                       // x_ptr + offsets
    %9 = tt.load %8, %6, %cst                                   // tl.load(..., mask)
    %10 = tt.splat %arg1 : !tt.ptr<f32> -> tensor<128x!tt.ptr<f32>>
    %11 = tt.addptr %10, %4
    %12 = tt.load %11, %6, %cst                                 // (same for y_ptr)
    %13 = tt.splat %arg2 : !tt.ptr<f32> -> tensor<128x!tt.ptr<f32>>
    %14 = tt.addptr %13, %4
    %15 = arith.addf %9, %12 : tensor<128xf32>                  // x + y
    tt.store %14, %15, %6                                       // tl.store(..., mask)
    tt.return
  }
}
```

Key dialect ops: `tt.get_program_id`, `tt.make_range`, `tt.splat`, `tt.addptr`, `tt.load`, `tt.store`, plus generic `arith.*`. The `#loc` annotations preserve Python source locations through the entire pipeline.

## 4. Stage 2 — TTAdapter (Ascend-lowered MLIR)

The abstract pointer/tensor IR is replaced with concrete memory operations from upstream MLIR dialects (`memref`, `linalg`, `bufferization`, `tensor`). The kernel signature gains two prepended runtime slots (sync block lock, workspace).

```mlir
module {
  func.func @add_kernel(
      %arg0: memref<?xi8>,                                                // sync block lock (runtime)
      %arg1: memref<?xi8>,                                                // workspace (runtime)
      %arg2: memref<?xf32> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32},   // input x
      %arg3: memref<?xf32> {tt.divisibility = 16 : i32, tt.tensor_kind = 0 : i32},   // input y
      %arg4: memref<?xf32> {tt.divisibility = 16 : i32, tt.tensor_kind = 1 : i32},   // output
      %arg5: i32 {tt.divisibility = 16 : i32},                            // n_elements
      %arg6: i32, %arg7: i32, %arg8: i32, %arg9: i32, %arg10: i32, %arg11: i32  // grid/program IDs
  ) attributes {
      SyncBlockLockArgIdx = 0 : i64,
      WorkspaceArgIdx = 1 : i64,
      global_kernel = "local",
      mix_mode = "aiv",                                                   // ← AI Vector core
      parallel_mode = "simd"
  } {
    %cst = arith.constant 0.000000e+00 : f32
    %c128 = arith.constant 128 : index
    %c128_i32 = arith.constant 128 : i32
    %0 = arith.muli %arg9, %c128_i32 : i32                                // %arg9 = program_id_x
    %1 = arith.index_cast %0 : i32 to index

    // --- Load x_ptr block ---
    %reinterpret_cast = memref.reinterpret_cast %arg2 to offset:[%1], sizes:[128], strides:[1]
                        : memref<?xf32> to memref<128xf32, strided<[1], offset: ?>>
    %alloc = memref.alloc() : memref<128xf32>                              // 128-elem scratch
    %2 = arith.addi %1, %c128 : index
    %3 = arith.index_cast %arg5 : i32 to index
    %4 = arith.maxsi %1, %3 : index
    %5 = arith.minsi %2, %4 : index
    %6 = arith.subi %5, %1 : index                                         // live count in block
    %7 = arith.cmpi slt, %6, %c128 : index                                 // partial block?
    scf.if %7 {
      linalg.fill ins(%cst : f32) outs(%alloc : memref<128xf32>)           // zero-fill scratch
    } {hivm.unlikely_condition}                                            // ← branch hint
    %subview   = memref.subview %reinterpret_cast[0] [%6] [1] : ...        // live slice in DRAM
    %subview_0 = memref.subview %alloc[0] [%6] [1] : ...                   // matching slice in scratch
    memref.copy %subview, %subview_0                                       // copy live elements
    %8 = bufferization.to_tensor %alloc restrict writable : memref<128xf32>

    // --- (same dance for y_ptr) ---
    %reinterpret_cast_1 = memref.reinterpret_cast %arg3 ...
    %alloc_2 = memref.alloc() : memref<128xf32>
    scf.if %7 { linalg.fill ins(%cst : f32) outs(%alloc_2 : memref<128xf32>) } {hivm.unlikely_condition}
    %subview_3 = memref.subview %reinterpret_cast_1[0] [%6] [1] : ...
    %subview_4 = memref.subview %alloc_2[0] [%6] [1] : ...
    memref.copy %subview_3, %subview_4
    %9 = bufferization.to_tensor %alloc_2 restrict writable : memref<128xf32>

    // --- Compute + store ---
    %reinterpret_cast_5 = memref.reinterpret_cast %arg4 ...                // out_ptr block
    %10 = arith.addf %8, %9 : tensor<128xf32>                              // x + y
    %extracted_slice = tensor.extract_slice %10[0] [%6] [1] : tensor<128xf32> to tensor<?xf32>
    %subview_6 = memref.subview %reinterpret_cast_5[0] [%6] [1] : ...
    bufferization.materialize_in_destination %extracted_slice in writable %subview_6

    return
  }
}
```

### Key transformations

| TTIR concept | TTAdapter representation |
| --- | --- |
| `!tt.ptr<f32>` | `memref<?xf32>` with explicit offset/sizes/strides |
| `tt.load` with mask | `memref.alloc` + (conditional `linalg.fill` 0) + `memref.copy` of live slice |
| `tt.store` with mask | `tensor.extract_slice` + `bufferization.materialize_in_destination` |
| `tt.get_program_id x` | `%arg9` (one of six runtime program-ID args) |
| `tt.divisibility = 16` | preserved as attribute |
| (none) | `mix_mode = "aiv"` — selects AI Vector unit |
| (none) | `parallel_mode = "simd"`, `global_kernel = "local"` |
| (none) | `SyncBlockLockArgIdx`, `WorkspaceArgIdx` — runtime injects |
| (none) | `hivm.unlikely_condition` — branch hint for the partial-block path |

**Mask handling = fill-then-copy.** `mask = offsets < n_elements` becomes "alloc a 128-element scratch buffer, fill with zeros if the block is partial, then `memref.copy` only the live slice." Predicated loads aren't a primitive on AICore; masking is implemented as buffer fill + slice copy.

The same pattern repeats for both input loads, then `arith.addf` on the full `tensor<128xf32>`, then `tensor.extract_slice` to write only the live elements back to DRAM.

## 5. Stage 3 — Final NPU binary

`add_kernel.npubin` — ELF64, machine type `0x1029` (HiIPU AICore), 3168 bytes total.

### Section layout

```
There are 8 section headers, starting at offset 0xa60:

  [Nr] Name              Type            Address          Off    Size   Flg
  [ 0]                   NULL            0000000000000000 000000 000000
  [ 1] .text             PROGBITS        0000000000000000 0000b0 0002e4 AX     ← machine code (740 B)
  [ 2] .ascend.stack.size.record PROGBITS 0000000000000000 000394 000008      ← declared stack usage
  [ 3] __CCE_KernelArgSize PROGBITS      0000000000000000 00039c 000004      ← kernel arg footprint
  [ 4] .comment          PROGBITS        0000000000000000 0003a0 000069 MS    ← compiler banner
  [ 5] .symtab           SYMTAB          0000000000000000 000410 0004c8
  [ 6] .shstrtab         STRTAB          0000000000000000 0008d8 000058
  [ 7] .strtab           STRTAB          0000000000000000 000930 00012e
```

### Compiler banner (`.comment`)

```
Linker: LLD 15.0.5
BiSheng Compiler 202505 clang version 15.0.5 (clang-5c68a1cb1231 flang-5c68a1cb1231)
```

So the compiler chain inside CCE is **BiSheng (Huawei's LLVM 15 fork) + LLD 15.0.5**. BiSheng is publicly available (the binaries ship with CANN at `/usr/local/Ascend/cann-8.5.0/tools/bisheng_compiler/bin/`), but the AICore code-generator and disassembler modules are gated.

### Symbol table

Notable symbols:
```
  Num:    Value          Size Type    Bind   Vis      Ndx Name
   1: 0000000000000000     0 FILE    LOCAL  DEFAULT  ABS LLVMDialectModule
   2: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT    1 add_kernel$local
   ...
  44: 0000000000000014     0 NOTYPE  LOCAL  DEFAULT    4 $d.41
  45: 0000000000000000     0 SECTION LOCAL  DEFAULT    1 .text
  ...
  49: 0000000000000000   740 FUNC    GLOBAL DEFAULT    1 add_kernel        ← entry point, 740 B
  50: 0000000000000000     4 OBJECT  WEAK   DEFAULT    3 add_kernel__      ← arg-size constant
```

`LLVMDialectModule` is the file-scope symbol that betrays LLVM IR was used internally before the AICore backend emitted machine code. The 41 `$d.N` symbols (indices 4-44) are data labels embedded in the `.comment` section.

`add_kernel` (size 740 B = 0x2e4) matches the `.text` size exactly — one function, no padding.

### Raw `.text` (740 bytes)

```
0x00000000 80 7f 3a 07 10 00 7b 07 80 38 9e 02 81 d7 3b 00
0x00000010 80 08 1f 02 ff 7f 20 07 01 00 00 07 0a f8 de 00
0x00000020 00 80 22 07 80 00 00 02 84 f8 3a 00 00 00 40 80
0x00000030 80 00 40 80 70 d7 3d 08 80 48 02 02 38 10 0c 08
0x00000040 20 10 00 08 18 10 ca 03 30 10 04 08 00 63 82 09
0x00000050 00 00 c6 09 83 60 02 00 00 22 84 09 80 38 0e 02
...
0x000002d0 00 18 e0 40 00 00 1e 07 00 00 40 41 00 f0 2e 40
0x000002e0 00 00 60 41
```

The full hex dump is ~37 lines of 16 bytes each. The encoding is presumably HiIPU AICore's instruction format, which is **not publicly documented**. Section alignment is 4 bytes, suggesting either fixed 4-byte instructions or aligned VLIW bundles.

## 6. Disassembly attempts

Ascend does not ship a public AICore disassembler. Here's what's in the toolkit and what each does:

| Tool | What it does | Result on `add_kernel.npubin` |
| --- | --- | --- |
| BiSheng `llvm-objdump --version` (`/usr/local/Ascend/cann-8.5.0/tools/bisheng_compiler/bin/llvm-objdump`) | LLVM 15.0.5; only `aarch64*` targets registered | Recognizes file format `elf64-hiipu` |
| BiSheng `llvm-objdump -d` | Default disassembly | All instructions show `<not available>` — decoder gated |
| BiSheng `llvm-objdump --disassemble-aicore` | Documented option | Same — option exists in `--help`, decoder still gated |
| BiSheng `llvm-objdump --save-aicore-bins` | Used internally by `op_gen.simulator.parse_objdump` | Same |
| `msobjdump` (`/usr/local/Ascend/cann-8.5.0/tools/msobjdump/msobjdump`) | Mind Studio's fatbin tool | "Kernel meta information cannot be found" — expects fatbin, not raw kernel ELF |
| Stock binutils `objdump -d` | — | "can't disassemble for architecture UNKNOWN!" |
| Stock binutils `readelf -SW` / `-s` / `-x .text` | Section/symbol/hex dump | ✅ Works fine |

The HiIPU decoder lives only inside Ascend's internal Mind Studio plugins (not the publicly-shipped CANN binaries). To get mnemonic disassembly you'd need:
1. Mind Studio installed (with the simulator/profiler plugin).
2. Or reverse-engineer the encoding (substantial effort; AICore is a proprietary VLIW-style ISA).

For our purposes, the externally-visible picture stops at: `.text` is 740 bytes of machine code emitted by BiSheng + LLD, structured as one global function `add_kernel`.

### Side path: emitting AICore assembly directly via `ccec`

`ccec --cce-aiv -S source.cce` would emit `.s` from a CCE-C source file. This is a different path than disassembling Triton's output (it goes from CCE-C, not from Triton's IR), but it would let you *see* AICore assembly text. We didn't pursue this — Triton-Ascend's CCE invocation isn't reachable as a CCE-C source file (the compiler ingests MLIR/LLVM IR, not CCE C).

## 7. Compile metadata (`add_kernel.json`)

```json
{
  "hash": "16e89e4cfbf9c9a2ba526ebdadc4bf0bb2a9e60ec86646611b628e6ced4eac92",
  "target": { "backend": "npu", "arch": "Ascend910_9362", "warp_size": 0 },
  "kernel_name": "add_kernel",
  "name": "add_kernel aiv",
  "cluster_dims": [1, 1, 1],
  "num_warps": 4,
  "num_ctas": 1,
  "num_stages": 1,
  "warp_size": 32,
  "parallel_mode": "simd",
  "compile_mode": "simd",
  "mix_mode": "aiv",
  "tensor_kinds": [0, 0, 1],          // input, input, output
  "bs_task_type": 10,
  "llvm_version": 15,
  "shared": 1,
  "enable_fp_fusion": true,
  "multibuffer": true
}
```

- `target.arch = "Ascend910_9362"` — the specific 910 SKU (out of `9362`, `9372`, `9381`, `9382`, `9391`, `9392` seen in cost-model files).
- `mix_mode = "aiv"` — runs on **AI Vector**, not AI Cube. The compiler picks this based on op patterns — vector_add has no matrix multiply, so the cube unit is unnecessary.
- `parallel_mode = "simd"` — SIMD execution model (vs. SIMT-style).
- `bs_task_type = 10` — BiSheng task type enum (private values).
- `llvm_version = 15` — confirms LLVM 15 in the toolchain.
- `tensor_kinds = [0, 0, 1]` — these become `tt.tensor_kind` attributes on TTAdapter args (0 = input, 1 = output).

## 8. Key observations

1. **Three IR levels are publicly visible**: TTIR → TTAdapter → ELF. There's a fourth (LLVM IR after TTAdapter, as confirmed by `LLVMDialectModule` symbol and the BiSheng banner) but Triton-Ascend doesn't surface it as a dump artifact.
2. **CCE = BiSheng (LLVM 15 fork) + LLD 15** for the late stages, plus proprietary AICore code generator and disassembler.
3. **`mix_mode` is auto-picked**: vector_add → `aiv`. A matmul-style kernel would pick `aic` (AI Cube) or `mixed`.
4. **Masking is fill-then-copy**, not predication. Important to know if optimizing — every masked load incurs a scratch alloc + zero-fill (under `hivm.unlikely_condition`) + memref.copy.
5. **The binary is small**: 740 B of `.text` for this 4-line kernel. The HiIPU ISA is dense.
6. **The ELF target name is `elf64-hiipu`** (Huawei Intelligent Processing Unit). Machine type `0x1029` is undocumented in upstream binutils.
7. **Disassembly requires Mind Studio** or substantial reverse-engineering. CANN's public tools recognize the format but won't decode instructions.

## 9. Pipeline drift to watch for

- **Different kernel shapes pick different `mix_mode`.** Reductions and pure vector ops → `aiv`. Matmul-heavy → `aic`. Mixed workloads → `mixed`. The TTAdapter dialect changes accordingly.
- **`num_warps` changes don't change the IR shape much** for AI Vector kernels. They mostly affect runtime grid scheduling.
- **`enable_fp_fusion`** becomes important for kernels that do `c = a*b + d` — toggle to see fused-multiply-add appear in the IR.
- **Multi-buffer (`multibuffer = true`)** double-buffers the scratch allocs. You'll see two `memref.alloc` per input slot for pipelined patterns.
- **Stages (`num_stages > 1`)** add software pipelining at the TTAdapter level — visible as additional `scf.for` loops with offset reads/writes.

## 10. References

- Triton-Ascend repo: https://gitcode.com/Ascend/triton-ascend/
- BiSheng compiler: `/usr/local/Ascend/cann-8.5.0/tools/bisheng_compiler/bin/`
- msobjdump: `/usr/local/Ascend/cann-8.5.0/tools/msobjdump/msobjdump` (works on fatbins, not raw kernel ELFs)
- Internal parse_objdump.py (uses `--save-aicore-bins`): `/usr/local/Ascend/cann-8.5.0/python/site-packages/op_gen/simulator/parse_objdump.py`
- `ccec --help` — full CCE driver options including `--cce-aiv`, `--cce-hwloops`, `--cce-mask-opt`, `--cce-aicpu-arch`
- Hello-world sources used here: `/home/Ray/triton_hello/` on 192.168.25.218
- Companion: [`umdk_get_tp_list_prewarm.md`](umdk_get_tp_list_prewarm.md) (different topic — UDMA cache — but same Ascend hardware family)

## 11. msdebug + camodel: how far you can actually push disassembly

Beyond the BiSheng `llvm-objdump` path, two more tools are worth knowing about. Neither restores public mnemonic decoding, but together they expose a lot of structure.

### msdebug — Ascend's LLDB fork

`/usr/local/Ascend/cann-8.5.0/tools/msdebug/bin/msdebug` is a complete LLDB 15.0.4 build (revision `0517a29`, vendor branch `mindstudio/msdebug`). Branding:

> "msdebug (MindStudio Debugger) is part of MindStudio Operator-dev Tools.
> The tool provides developers with a mechanism for debugging Ascend kernels running on actual hardware.
> This enables developers to debug Ascend kernels without being affected by potential changes brought by simulation and emulation environments."

The architecture name in msdebug's view of the binary: **`hiipu64`** (recognized by LLDB's loader). When you run:

```
msdebug -b -o "target create $BIN" -o "disassemble --bytes --name add_kernel" -o "quit"
```

…you get per-PC instruction words like:

```
add_kernel.npubin`add_kernel__:
add_kernel.npubin[0x0] <+0>:   0x073a7f80          ← __CCE_KernelArgSize data (4 B)
add_kernel.npubin`add_kernel$local:
add_kernel.npubin[0x4] <+4>:   0x077b0010          ← real instructions start here
add_kernel.npubin[0x8] <+8>:   0x029e3880
add_kernel.npubin[0xc] <+12>:  0x003bd781
add_kernel.npubin[0x10] <+16>: 0x021f0880
...
```

The mnemonic column stays empty (decoder gated identically to `llvm-objdump`). But this *does* establish the encoding cleanly.

### Encoding observations from the 185-instruction listing

- **Fixed 32-bit instruction width.** Every PC in the disassembly is +4. No variable-length, no wide VLIW bundles in the public symbol view.
- **Little-endian in memory.** The on-disk hex `80 7f 3a 07` decodes to LLDB's `0x073a7f80`.
- **Total**: 740 B `.text` / 4 = exactly **185 instructions**. None of the 740 bytes are slack.
- **High-nibble (opcode group) frequency** across all 185 instructions:

  | High nibble | Count | % |
  | --- | ---: | ---: |
  | `0x0` | 96 | 52% |
  | `0x8` | 44 | 24% |
  | `0x1` | 16 | 8.6% |
  | `0x2` | 6 | 3.2% |
  | `0x3` | 6 | 3.2% |
  | `0xf` | 5 | 2.7% |
  | `0xe` | 3 | 1.6% |
  | `0xc` | 3 | 1.6% |
  | `0x7` | 3 | 1.6% |
  | `0xa` | 2 | 1.1% |
  | `0x4` | 1 | 0.5% |

  Strongly bimodal — the `0x0` and `0x8` groups together account for 76% of all instructions. Likely opcode-in-high-bits encoding with the dominant ALU/memory groups in 0x0 and 0x8.

### Cycle-Accurate Model (camodel) for Ascend910_9362

CANN ships a full CA-model simulator library set for our exact target:

```
/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910_9362/
├── config.json           L2 cache / log config (latencies, line size)
├── config_hwts.json
├── config_stars.json
├── conf/
└── lib/
    ├── libruntime_camodel.so      ← cycle-accurate runtime drop-in
    ├── libruntime_cmodel.so       ← functional (faster) model
    ├── libnpu_drv_camodel.so
    ├── libnpu_drv_pvmodel.so
    ├── libtsch_camodel.so
    ├── libffts_model.so
    ├── libmodel_top.so / libmodel_top_pv.so
    ├── libstars.so / libstars_pv.so
    └── libpem_davinci.so          ← PEM = Power & Energy Model
```

`config.json` reveals the modeled L2:

```json
"L2CACHE": {
    "cache_set_size": 24,
    "cache_way_size": 16384,
    "cache_line_size": 512,
    "cache_read_latency": 241,
    "cache_write_latency": 96
}
```

**Activation experiment.** Prepending `simulator/Ascend910_9362/lib` to `LD_LIBRARY_PATH` and re-running the kernel completes successfully, but the runtime logs (`ASCEND_GLOBAL_LOG_LEVEL=1 ASCEND_SLOG_PRINT_TO_STDOUT=1`) show `DeviceClose: Close device success, device_id=0` — i.e., the real driver was used, not camodel. The simulator libraries are present but `LD_LIBRARY_PATH` alone doesn't redirect runtime selection. To actually invoke the camodel runtime needs:

1. A specific launch path (likely Mind Studio's Operator-dev Tools wrapper, or a CMake `-DASCEND_PLATFORM=SIMULATOR` build flag); or
2. An undocumented runtime-selector env var (the visible `ASCEND_*` env vars in `npu_executor_main` strings don't include a camodel switch); or
3. Modify the loader's resolution order via `/etc/ld.so.conf.d/` to win over the regular driver.

We did not crack the activation env this session. The Python `op_gen.simulator.simulator` module is a *post-hoc parser* that ingests dumps the camodel runtime would emit; without the runtime running, there's no dump to parse.

The internal `op_gen.simulator.RelocParser._executable2obj` does:

```python
cmd = ["llvm-objdump", "--save-aicore-bins", self.relocatable_file]
```

Which produces the same `<not available>` listing we see — meaning Mind Studio's pipeline relies on the camodel runtime emitting *separate* dump files (which our Triton-Ascend run did not produce because we ran on real hardware), not on the LLVM disassembler.

### What this means for the doc's earlier claim

§6 (above) said disassembly is "gated everywhere we look." That's still accurate for **mnemonics**. But this section adds the structural picture:

- Architecture identifier: **`hiipu64`** (per msdebug's LLDB target loader).
- Encoding: **fixed 32-bit, little-endian, 4-byte aligned**.
- Total instruction count: **185** for our vector_add.
- Opcode-group frequency: dominated by `0x0_` (52%) and `0x8_` (24%) high-nibble groups.
- Per-PC instruction words: extractable via `msdebug -b -o "disassemble --bytes ..."`.
- L2 cache parameters of the modeled hardware: 24 sets × 16384 ways × 512 B lines, ~241 cycles read latency, ~96 cycles write latency.

For people doing performance work, those L2 parameters alone are useful — they're the simulated values the codegen targets.

## 12. Cycle profiling

Two ways to get cycles for a Triton-Ascend kernel: real-device profiling via `msprof` (works today, what we used), and CA-model simulation via `LD_PRELOAD`-activated camodel runtime (also works once you know the trick).

### 12.1 Real-device profiling with `msprof`

Concrete command (no Triton changes needed; just wrap the python invocation):

```bash
mkdir -p /home/Ray/triton_hello/msprof_out
/usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/msprof \
    --output=/home/Ray/triton_hello/msprof_out \
    --application="python /home/Ray/triton_hello/vector_add.py" \
    --aic-metrics=PipeUtilization \
    --aicpu=on
```

Caveat encountered: `msprof` itself fails to start with `libc_sec.so: cannot open shared object file` unless the driver lib paths are on `LD_LIBRARY_PATH`. Use the same `~/.bashrc` block from the NPU server memory:

```bash
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

End-to-end run takes ~2 minutes. The output goes to `msprof_out/PROF_000001_<timestamp>_<random>/` with three subtrees: `host/`, `device_0/`, and `mindstudio_profiler_output/`. The most useful files:

```
mindstudio_profiler_output/
├── op_summary_<ts>.csv      ← per-task cycles + per-pipeline breakdown
├── op_statistic_<ts>.csv    ← per-op-type aggregate
├── api_statistic_<ts>.csv   ← host-side API timings
├── task_time_<ts>.csv       ← raw timeline
└── msprof_<ts>.json         ← Mind Studio Insight format

device_0/sqlite/
├── ai_core_op_summary.db    ← same data, queryable as SQL
├── ascend_task.db
├── time.db
├── op_counter.db
├── biu_perf.db              ← BIU = Bus Interface Unit perf counters
├── freq.db                  ← AICore frequency over time
└── metric_summary.db
```

### 12.2 What `add_kernel` actually cost

From `op_summary_<ts>.csv`, here's the row for our Triton-compiled `add_kernel`:

| Field | Value |
| --- | --- |
| Op Name / OP Type | `add_kernel` / `add_kernel` |
| OP State | static |
| Task Type | **AI_VECTOR_CORE** (matches `mix_mode = "aiv"` in the metadata) |
| Block Dim | 8 (our `triton.cdiv(1024, 128) = 8`) |
| Mix Block Dim | 0 (no AI Cube use) |
| HF32 Eligible | YES |
| Input Shapes | 1024;1024 (FLOAT;FLOAT) |
| Output Shape | 1024 (FLOAT) |
| **Task Duration** | **3.360 µs** |
| Task Wait Time | 12,223,361.58 µs (waiting for issue) |
| **aicore_time** | 0.0 µs (didn't use AI Cube) |
| aic_total_cycles | 0 |
| **aiv_time** | **1.978 µs** (AI Vector core) |
| **aiv_total_cycles** | **12,658** |
| aiv_vec_time / ratio | 0.049 µs / 0.025 (2.5% — actual vector ops) |
| aiv_scalar_time / ratio | 0.315 µs / 0.159 (15.9% scalar) |
| aiv_mte2_time / ratio | 0.173 µs / 0.088 (8.8% — DRAM load) |
| aiv_mte3_time / ratio | 0.183 µs / 0.092 (9.2% — DRAM store) |
| aiv_icache_miss_rate | 0.235 (23.5% — first-run cold I-cache) |
| cube_utilization(%) | 0.000 |

**Headline: 12,658 AIV cycles, 1.978 µs of AI Vector time, 3.36 µs total task duration.**

The pipeline-utilization ratios add up to ~36.4% — the remaining ~63% is dispatch/sync/idle. Expected for such a small kernel: 1024 elements × 4 bytes = 4 KB of data, split across 8 blocks of 128 elements each, with cold I-cache on the first invocation. A bigger N or a hot run would shift the ratios toward MTE2/MTE3.

Cube utilization is 0 (we never touched the cube unit). MTE1 and fixpipe are also zero.

### 12.3 Op-statistic comparison across the test run

```csv
OP Type,Core Type,Count,Total(us),Avg(us),Ratio(%)
Range,        AI_VECTOR_CORE,1,12.16, 12.16, 50.000   ← torch.arange(n=1024)
add_kernel,   AI_VECTOR_CORE,1, 3.36,  3.36, 13.816   ← our Triton kernel
ReduceMax,    MIX_AIV,       1, 2.74,  2.74, 11.266   ← .abs().max()
Add,          AI_VECTOR_CORE,1, 1.80,  1.80,  7.401   ← (out - (x+y))
Abs,          AI_VECTOR_CORE,1, 1.42,  1.42,  5.839   ← .abs()
Fill,         AI_VECTOR_CORE,1, 1.42,  1.42,  5.839   ← torch.full(10.0)
Sub,          AI_VECTOR_CORE,1, 1.42,  1.42,  5.839   ← (out - (x+y))
```

`add_kernel` is 13.8% of total kernel time on this run; `Range` (the `torch.arange(1024, device="npu")` call) dominates at 50%. That's a useful baseline — for tiny kernels, surrounding torch ops can dwarf the kernel itself.

### 12.4 Cycle-Accurate Model (camodel) activation — found

The activation env we missed in §11: **`LD_PRELOAD=$SIM_LIB/libruntime_camodel.so`**, *not* just `LD_LIBRARY_PATH`.

```bash
SIM_LIB=/usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910_9362/lib
export CAMODEL_CONFIG_PATH=$SIM_LIB
export LD_LIBRARY_PATH=$SIM_LIB:$LD_LIBRARY_PATH
export LD_PRELOAD=$SIM_LIB/libruntime_camodel.so       # ← this is what flips the runtime
```

Confirmed via the camodel's own startup logs — once `LD_PRELOAD` is set, the camodel's loader prints:

```
[INFO] Config file [config_stars.json] from environment variable [CAMODEL_CONFIG_PATH].
       Path: /usr/local/Ascend/cann-8.5.0/aarch64-linux/simulator/Ascend910B1/lib/config_stars.json
[INFO] Config file is found, path is .../Ascend910B1/lib/config_stars.json.
[FuncCache]: size:0x20000, line_size:128, way_num:16, line_num:1024, idx_num:64
[TmSim]: Run in serial mode.
[INFO] AicWrapper attach AIC 0, num_vec_core=2, num_subcore=3
[INFO] AicWrapper attach AIC 1, num_vec_core=2, num_subcore=3
... (attaches AIC 0 through AIC 21 — 22 simulated AI Cores)
```

Two surprises:
- **Even with `CAMODEL_CONFIG_PATH` pointing at `Ascend910_9362/lib`, the runtime preferred `Ascend910B1/lib/config_stars.json`.** Likely the camodel runtime has its own platform-detection logic that picked 910B1 as the closest available config. To force 910_9362, you may need a more specific runtime selector or to symlink/copy 9362 configs over 910B1.
- **22 AI Cores attached** — that's the simulated topology for 910B1, not your physical 16. Indicates the camodel is faithful to the model variant's spec, not the physical chip.

`[FuncCache]` line: instruction cache is 0x20000 = **128 KB total**, 16-way, 128 B lines, 1024 lines, 64 sets per way. That's the I-cache configuration our 23.5% miss rate was measured against.

### 12.5 Camodel timing caveat

Camodel is a cycle-accurate simulator — even `vector_add` of n=1024 takes substantially longer than real-hardware execution. With a 60s timeout the test didn't complete (cut off mid-init while attaching cores). For real cycle-accurate runs, budget several minutes per kernel. That's why msprof on real hardware is the practical path for everyday cycle data; camodel is for when you need cycle counts on hardware you don't have, or want to model a different chip variant.

If you need a successful camodel end-to-end run with dump output, expect to:
1. Set the env (CAMODEL_CONFIG_PATH + LD_PRELOAD) as above.
2. Allow ≥5 minutes wall-clock per simple kernel.
3. Look for dump output in the working directory (the camodel writes per-AIC dumps that `op_gen.simulator.simulator -d <dump-dir> -reloc <kernel.npubin>` then parses into per-instruction execution traces).

## 13. Useful Triton-Ascend env vars

```bash
TRITON_DUMP_DIR=/path           # dumps .ttir.mlir + .ttadapter.mlir
TRITON_CACHE_DIR=/path          # dumps .ttir + .ttadapter + .npubin + .json + launcher
TRITON_ALWAYS_COMPILE=1         # bypass cache hits, force fresh compile
TRITON_DEBUG=1                  # verbose driver output
MLIR_ENABLE_DUMP=1              # MLIR pass-by-pass dumps (large)
TRITON_PRINT_AUTOTUNING=1       # autotuner picks
```

For the `LD_LIBRARY_PATH` needed to actually run anything against an Ascend device, the `~/.bashrc` block is in `reference_npu_server.md` (memory).

## 14. Capturing every MLIR pass dump (~270 dumps)

The `vector_add` kernel runs through ~104 unique MLIR passes from `.ttadapter` to `.npubin`, but they're hidden from `--mlir-print-ir-after-all` on `bishengir-compile` because the entire backend is wrapped in a single composite pass `adapt-triton-kernel` that builds its inner pipeline imperatively (not via a nested PassManager).

The same inner pipeline IS reachable from `bishengir-opt` via composite *pipeline* names — `--lower-hfusion-pipeline` and `--optimize-hivm-pipeline` — that DO decompose normally:

```bash
# Triton frontend dumps (Python side) — 9 passes
MLIR_PRINT_IR_AFTER_ALL=1 TRITON_KERNEL_DUMP=1 MLIR_DISABLE_THREADING=1 \
  python vector_add.py 2> frontend.log

# Backend dumps via bishengir-opt — 270 dumps (104 unique passes)
bishengir-opt cache_dir/<hash>/add_kernel.ttadapter \
  --lower-hfusion-pipeline \
  --optimize-hivm-pipeline \
  --mlir-print-ir-after-all \
  --mlir-disable-threading \
  2> backend.log >/dev/null
```

The backend run segfaults at the very end (after the last pass writes its dump) — harmless, all 270 dumps are captured before the crash. On the tiny `vector_add` this produces ~770 KB / ~8950 lines of MLIR IR.

### 14.1 Why `--mlir-print-ir-after-all` doesn't work on `bishengir-compile`

Three traps worth knowing:

1. **`bishengir-compile --mlir-print-ir-after-all` is rejected at the CLI parser.** The string is in the binary (`strings | grep mlir-print-ir-after-all` matches) but it's not surfaced to the option parser. `strings | grep flag` is a false-positive trap — always verify with `--help` or by trying the flag.
2. **`bishengir-compile --print-after-all` is accepted BUT goes to hivmc** (the LLVM clang stage), not the MLIR PassManager. Names look identical to MLIR's flag; behavior diverges.
3. **`bishengir-compile --bishengir-print-ir-after=<pass-name>` accepts ~hundreds of registered names but only `hivm-inject-sync` is actually wired to a dump hook.** All other names accept silently and produce nothing. cl::opt is single-value; multiple `--bishengir-print-ir-after=` flags only honor the last one.

So the path forward — for any future Triton-Ascend kernel where you want pass-by-pass IR — is the `bishengir-opt` chain in §14.

### 14.2 What each pass does

The 9 frontend + 104 unique backend passes, by stage. Many fire multiple times (CSE, ExtendedCanonicalizer, ConvertArithToAffine each repeat between distinct transforms — that's why total dumps is 270, not 113).

#### Triton frontend (9 passes — Python side, TT-IR level)

| Pass | What it does |
|---|---|
| Inliner | Inline all callees into the kernel; remove function-call boundaries on the device side |
| Canonicalizer | Standard MLIR rewrite framework: normalize patterns (`+0`, `*1`, constant folding, idempotent op merging) |
| TritonCombineOps | Merge adjacent fusable Triton ops (e.g., `broadcast(broadcast(x))` → `broadcast(x)`) |
| TritonReorderBroadcast | Push `tt.broadcast` later in the data flow so upstream ops work on smaller tensors |
| CSE | Common subexpression elimination — dedupe identical pure ops |
| LoopInvariantCodeMotion | Hoist loop-invariant ops out of loops |
| SymbolDCE | Remove unused symbols (functions, globals) |
| TritonLoopUnroll | Unroll loops marked with Triton's `@unroll` annotation or autotuner unroll factor |

#### `lower-hfusion-pipeline` — linalg/tensor/arith/math → hfusion

**Conversion to hfusion dialect**

| Pass | What it does |
|---|---|
| ConvertGenericToNamedOp | Pattern-match `linalg.generic` bodies against named ops (matmul, fill, reduce) to enable named-op-aware lowering |
| ConvertLinalgToHFusion | Lower `linalg.matmul`/`linalg.add`/etc. → `hfusion.*` (HW-aware ops with NPU scheduling annotations) |
| ConvertTensorToHFusion | Lower `tensor.extract_slice`/`insert_slice`/`empty` → hfusion equivalents |
| ConvertArithToHFusion | Lower tensor-semantic arith ops (mul/div/add) → hfusion |
| ConvertMathToHFusion | Lower `math.exp`/`sqrt`/etc. → hfusion's NPU-mapped intrinsics |
| ConvertArithToAffine | Lower index-typed arith to `affine` dialect for analyzability |

**Hfusion-level optimization**

| Pass | What it does |
|---|---|
| HFusionOpFusion | Vertical fusion: merge producer→consumer hfusion ops into one fused region |
| HFusionInlineBrc | Inline broadcast — replace `broadcast` with cloned producers when cheaper |
| InferFuncFusionKind | Annotate functions with vec / cube / mix kind |
| AutoSchedule | Tiling, fusion, vectorization decisions made automatically from shapes + HW caps |
| ConstantizeTilingData | Fold known tiling block dims into constants |
| PackTilingData | Pack tiling params into a struct passed to the kernel |
| OutlineSingleOp | Promote a single hfusion op into its own function for the auto-scheduler |

**Decomposition**

| Pass | What it does |
|---|---|
| Decompose | Break high-level hfusion ops into building blocks (e.g., `softmax → max + sub + exp + sum + div`) |
| DecomposeMulti | Multi-step variant for ops that decompose conditionally |
| FlattenOps | Flatten nested fused regions |
| LinalgFoldUnitExtentDimsPass | Drop tensor dims of size 1 (`<1×128>` → `<128>`) |
| ComposeMultiReduce | Combine adjacent reductions (e.g., sum-then-mean) |

**Layout / shape normalization**

| Pass | What it does |
|---|---|
| CanonicalizeTensorReshape | Simplify reshape chains |
| PropagateReshape | Push reshape ops earlier/later to expose fusion |
| NormalizeSliceOps | Rewrite slice ops into canonical form |
| NormalizeLastDimUnalignedTensorOp | Insert padding/pack when the last dim is unaligned |
| NormalizeTensorOps | Standardize `tensor.reshape`/`collapse`/`expand` to lowering's expected form |
| Normalize | Catch-all generic normalization |
| BubblePadUp | Move `tensor.pad` upward toward producers (often eliminable there) |
| BubbleUpExtractSlice | Move `extract_slice` upward — exposes constants, enables fusion |
| TrickleConcatDown | Move `concat` downward — reduces register pressure on producers |
| ReorderOpsByBFS | Reorder fused ops in BFS order (dep-respecting linear schedule) |

**Symbol & memory cleanup at this stage**

| Pass | What it does |
|---|---|
| HoistTensorEmpty | Hoist `tensor.empty` allocations out of inner loops |
| FoldTensorEmpty | Fold `tensor.empty` into adjacent ops |
| FoldSymbolicDim | Fold known dynamic dims to constants |
| UnfoldSymbolicDim | Inverse — re-introduce symbolic dims when needed downstream |
| EraseSymbol / DropSymbols | Remove unused symbol definitions |
| EliminateDuplicateFuncs | Dedupe identical functions after inlining/cloning |
| CacheIOForReturnArg | Mark return-args for cache (input args read once → DMA-hoist; output args written once) |
| AddFFTSAddr | Add FFTS (Fast Function Task Scheduler) base-address arg to kernel signature |
| WrapHostFunc | Split kernel from host-launch wrapper |

**Special handling**

| Pass | What it does |
|---|---|
| DowngradeFP | Downcast unsupported precision (FP64 → FP32 since 910 has no FP64 vector unit) |
| LegalizeBF | Bring bf16 ops into HW-supported form |
| LegalizeBoolPass | Map i1 to i8 (NPU vector lane is byte-addressable) |
| ExtendedCanonicalizer | Bisheng's extended canonicalizer over MLIR's builtin (adds NPU-aware patterns) |

#### `optimize-hivm-pipeline` — hfusion → hivm → loops → llvm-ready

**Conversion + decisions about layout/scope/core**

| Pass | What it does |
|---|---|
| ConvertToHIVMOp | Convert hfusion ops → HIVM (Huawei IR Vector/Matrix) — lowest abstraction before LLVM |
| InferHIVMDataLayout | Decide ND vs NZ layout per tensor (L1/L2 fragments use NZ) |
| InferHIVMMemScope | Decide which scratch each op uses (UB / L1 / L2 / GM) |
| InferFuncCoreType | Decide AIV vs AIC vs Mix for each function |
| MarkRealCoreType | Annotate each op with its real execution core |
| MarkStrideAlign | Annotate buffers needing stride alignment for vectorization |
| MarkMultiBuffer | Mark buffers eligible for double-buffering (DMA + compute overlap) |
| MarkDisableLoad | Mark ops where loads should be skipped (already resident in scratch) |

**Buffer / memory planning**

| Pass | What it does |
|---|---|
| AlignAllocSize | Pad allocations to HW alignment (32B / 256B / 512B for AIV/AIC) |
| AllocExtraBuffer | Insert temp buffers for stages that need them |
| AutoInferBufferSize | Compute size of each buffer from analyses |
| ConstantizeBufferSize | Fold known shapes → constant buffer sizes |
| SetBufferSize | Apply final buffer size annotations |
| EnableMultiBuffer | Materialize multi-buffer (ping-pong DMA) as code |
| EnableStrideAlign | Apply stride-align decisions as code |
| PlanMemory | Final memory-plan analysis — assign each buffer to a physical scratch region with non-overlapping lifetime |
| OneShotBufferize | Tensor-semantic → memref-semantic (canonical MLIR bufferization) |
| MemrefDeadStoreEliminationOp | Remove dead stores post-bufferization |
| DropEquivalentBufferResults | Drop function results equivalent to output args |
| LowerMemRefExt | Lower `memref_ext` dialect to standard memref + arith |
| FoldAllocReshapeOp | Fold `alloc + reshape` into one alloc |
| ConvertNonContiguousReshapeToCopy | Insert explicit copy for non-contiguous reshape |
| CloneTensorEmpty | Clone `tensor.empty` for each user (avoid aliasing) |

**Scheduling & sub-block mapping**

| Pass | What it does |
|---|---|
| TileAndBindSubBlock | Tile loops and bind tiles to sub-blocks (HW execution units) |
| TileBatchMMIntoLoop | Tile batch matmul into a serial loop |
| MapForToForall | Convert `scf.for` → `scf.forall` for parallel execution |
| HIVMMapForallToBlocks | Map `scf.forall` to NPU blocks (HW thread-group equivalent) |
| CVPipelining | Compute–vector pipelining: overlap compute and vector ops |
| NormalizeMatmul | Standardize matmul to codegen-expected form |

**Synchronization**

| Pass | What it does |
|---|---|
| InjectSync | Insert sync barriers where needed (between AIC/AIV and DMA stages) |
| InjectBlockSync | Insert block-level barriers |
| SyncBlockHoisting | Hoist common sync points to reduce barrier count |
| AddFFTSToSyncBlockSetOp | Add FFTS task-base address to sync ops |
| LowerCreateSyncBlockLock | Lower sync-block-lock creation to runtime calls |

**Lowering-time inlining**

| Pass | What it does |
|---|---|
| InlineFixpipe | Inline matmul postprocess (bias-add / scale / relu fixpipe ops) |
| InlineLoadCopy | Inline DMA load + copy ops |
| InlineOTFBroadcast | Inline on-the-fly broadcast |
| HIVMInlineOTFLoadStore | Inline on-the-fly load/store |

**Decomposition at hivm level**

| Pass | What it does |
|---|---|
| HIVMDecomposeOp | Decompose hivm ops into lower-level ops |
| HIVMAggregatedDecomposeOp | Decompose aggregated hivm ops |
| HIVMRecognizeDeinterleaveOp | Pattern-match deinterleave (complex → real/imag, etc.) |
| HIVMFlattenOps | Flatten nested hivm operations |
| HIVMOptSinglePointOp | Optimize single-point ops (scalar broadcast to vector) |
| InsertNZ | Insert NZ-format conversion ops |

**Loop opt at hivm level**

| Pass | What it does |
|---|---|
| HIVMLowerToLoops | **Final lowering:** hivm ops → `scf.for` loops (preparing for LLVM emission) |
| SCFForLoopCanonicalization | Canonicalize `scf.for` (combine bounds, simplify steps) |
| CanonicalizeIterArg | Normalize loop iter-args |
| RemoveRedundantLoopInit | Remove redundant init values |
| LoopInvariantSubsetHoisting | Hoist subset extractions (`extract_slice`) out of loops |
| LiftLowestStride | Move stride-1 (innermost) dims to lowest — ensures contiguous access |
| LiftZeroRank | Promote 0-d ops out of loops |
| ReduceRankSubview | Reduce rank of subview ops where possible |

**Function signature & kernel-launch metadata**

| Pass | What it does |
|---|---|
| InitEntryKernel | Set up the kernel entry point (initialize FFTS, etc.) |
| BindWorkSpaceArg | Add workspace (scratchpad) arg to function signature |
| BindSyncBlockLockArg | Add sync-block-lock arg |
| InsertInferTaskTypeFunc | Add runtime callback to infer task type |
| InsertInferSyncBlockLockNumAndInitFunc | Same for sync-block-lock-num and init |
| InsertWorkSpaceForMixCV | Workspace handling for mix CV (cube+vector) kernels |
| InsertLoadStoreForMixCV | Insert load/store for mix CV |
| SplitMixKernel | Split mix (AIC+AIV) kernel into separate AIC and AIV functions |

After these 104 unique passes, control passes to **hivmc** for the final lowering to npubin. See §15 for the result of investigating hivmc's dump support — the short answer is that hivmc's internal pipeline is **opaque from CLI introspection** on the shipped binary.

## 15. The hivmc stage — opaque from outside

`hivmc` (`/usr/local/Ascend/cann-8.5.0/tools/bishengir/bin/hivmc`, version `0.1.0 (e4e2ba9841d1 2026-01-16)`, 102 MB) is the third compiler stage invoked as a subprocess of `bishengir-compile`. **Despite its name suggesting an LLVM-only role, hivmc takes MLIR as input** — specifically `module.hivm.opt.mlir`, the post-`optimize-hivm-pipeline` HIVM-dialect snapshot. It then finishes the MLIR lowering (HIVM → LLVM dialect → LLVM IR) and emits hiipu64 machine code.

The actual command bishengir-compile runs:

```
hivmc /tmp/<tmpdir>/module.hivm.opt.mlir \
  --enable-debug-info=false --enable-static-bare-ptr=true \
  --enable-bin-relocation=true --enable-hivm-inject-barrier-all-sync=false \
  --enable-sanitizer=false -o <out>.npubin
```

### 15.1 Every dump flag is dead

Tested against `captured_input.mlir` (the intercepted hivmc input):

| Flag | Result |
|---|---|
| `--print-after-all` (LLVM new-PM) | Accepted silently, 0 dumps |
| `--print-before-all` | Accepted silently, 0 dumps |
| `--print-changed=quiet \| diff` | Accepted silently, 0 dumps |
| `--print-isel-input`, `--print-after-isel`, `--print-machine-bfi` | 0 dumps |
| `--print-pipeline-passes` | 0 dumps |
| `--debug-pass=Structure \| Executions` (LLVM legacy PM) | 0 dumps |
| `--debug-pass-manager` | Rejected as unknown |
| `--mlir-print-ir-after-all` | Rejected — flag not registered |
| `--bishengir-print-ir-after=<post-optimize-hivm pass name>` | Accepted silently, 0 dumps for every name tried (`hivm-lower-to-loops`, `convert-hivm-to-llvm`, `convert-hivm-to-std`, `hivm-inject-sync`, `hivm-decompose-op`). Unlike bishengir-compile where `hivm-inject-sync` was hand-instrumented, none of hivmc's late-stage passes are wired to dump hooks. |
| `--default-pipeline`, `--lower-hfusion-pipeline`, `--optimize-hivm-pipeline`, `--buffer-deallocation-pipeline` (composite pipeline-name flags) | All rejected at parse |

`strings` against the binary shows the same composite pipeline names that work on `bishengir-opt` (`lower-hfusion-pipeline`, `optimize-hivm-pipeline`, `default-pipeline`, `convert-to-hivm-pipeline`, `buffer-deallocation-pipeline`, plus `torch-*` and `gpu-*` pipelines) but none are exposed via `--help` and none are callable from hivmc's CLI. **`strings | grep` is again a false-positive trap** — the tokens are present (probably from MLIR pipeline-registration code) but not connected to the parser.

No env var unlocks dumps either — `strings | grep '^[A-Z_]+$'` shows only `BISHENG_INSTALL_PATH`, `MLIR_DISABLE_THREADING`, `mlir_reproducer`, `mlir_snapshot`.

### 15.2 Bonus trap: `--hivmc-args=` is broken on bishengir-compile

bishengir-compile exposes `--hivmc-args=<string>` to forward flags to the hivmc subprocess. It mangles the leading dashes:

```
--hivmc-args=--print-after-all   →  hivmc invocation gets ----print-after-all
--hivmc-args=print-after-all     →  silently dropped (not prefixed with --)
```

So even if hivmc honored `--print-after-all`, you can't forward it through. Reported as found, not chased.

### 15.3 The one workaround that does work — input capture

You can capture hivmc's MLIR input by wrapping the binary with a copy-then-exec shim:

```bash
cat > /tmp/hivmc_wrapper.sh <<'EOF'
#!/bin/bash
for arg in "$@"; do
  [[ "$arg" == *.mlir ]] && cp "$arg" /path/to/captured_input.mlir && break
done
exec /usr/local/Ascend/cann-8.5.0/tools/bishengir/bin/hivmc "$@"
EOF
chmod +x /tmp/hivmc_wrapper.sh
mv /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc{,.bak}
ln -s /tmp/hivmc_wrapper.sh /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc
# … run bishengir-compile, then restore the symlink.
```

The captured `module.hivm.opt.mlir` is the **bookend to §14's 270-dump backend pipeline** — the IR snapshot at the boundary where MLIR introspection ends and hivmc takes over. For `vector_add`: 65 lines / 6.5 KB. The header carries the target system spec:

```mlir
#dlti.target_system_spec<"NPU" :
  AI_CORE_COUNT=20, CUBE_CORE_COUNT=20, VECTOR_CORE_COUNT=40,
  UB_SIZE=1572864, L1_SIZE=4194304, L0A_SIZE=524288, L0B_SIZE=524288, L0C_SIZE=1048576,
  UB_ALIGN_SIZE=256, L1_ALIGN_SIZE=256, L0C_ALIGN_SIZE=4096>
```

— useful as a sanity check that the right device target was selected.

### 15.4 Why running the post-optimize-hivm passes via bishengir-opt fails

You might expect that since `bishengir-opt` exposes `--convert-hivm-to-llvm` and other late-stage passes, you could chain them on the captured input to surface the hivmc pipeline. It doesn't work — the first pass (`--convert-hivm-to-llvm`) errors with:

```
captured_input.mlir:34:16: error: failed to legalize operation 'memref.subview'
that was explicitly marked illegal
// -----// IR Dump After ConvertHIVMToLLVM Failed (convert-hivm-to-llvm) //----- //
```

The post-optimize-hivm pipeline that hivmc runs has specific constraints / preceding lowering steps that aren't reproducible by chaining individual `--convert-*` passes from outside. So **the pipeline isn't reachable from `bishengir-opt` either**.

### 15.5 Conclusion

The hivmc internal pipeline (HIVM-MLIR → LLVM dialect → LLVM IR → hiipu64 machine code) is opaque from CLI introspection on the shipped CANN-8.5.0 binary. To see those passes you'd need:

- Build hivmc from source with debug-printing enabled (BiSheng OSS doesn't ship the late-stage passes, so this means an internal Huawei build).
- Use a debugger or `strace` to catch intermediate buffers in process memory.
- Wait for CANN to expose a dump flag in a future release.

For the practical pipeline view of a Triton-Ascend kernel today, the ceiling sits at:
- **9 frontend dumps** via `MLIR_PRINT_IR_AFTER_ALL=1` on the Python invocation
- **270 backend dumps** via `bishengir-opt --lower-hfusion-pipeline --optimize-hivm-pipeline --mlir-print-ir-after-all` on the cached `.ttadapter`
- **1 hivmc-input snapshot** (`module.hivm.opt.mlir`) via the wrapper-script trick

After that snapshot, the kernel disappears into hivmc's internals and reappears as 740 B of `.text` machine code.

## 16. Quick reference: getting the pass dumps

Three commands, three boundaries. Run on the NPU server (CANN-8.5.0).

### 16.1 Frontend (~9 dumps) — Python side

```bash
cd /home/Ray/triton_hello
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash
source /home/Ray/venv/bin/activate

MLIR_PRINT_IR_AFTER_ALL=1 \
TRITON_KERNEL_DUMP=1 \
MLIR_DISABLE_THREADING=1 \
TRITON_CACHE_DIR=$PWD/cache_kdump \
  python vector_add.py 2> frontend.log

grep -c 'IR Dump' frontend.log         # → 9
```

Captures the TT-IR / TTGPU-IR passes: Inliner, Canonicalizer, TritonCombineOps, TritonReorderBroadcast, CSE, LoopInvariantCodeMotion, SymbolDCE, TritonLoopUnroll. Stops at TTAdapter — `bishengir-compile` is a subprocess and ignores the env var.

### 16.2 Backend (270 dumps, 104 unique passes) — `bishengir-opt`

Input is the `.ttadapter` from any prior Triton-Ascend compile of the same kernel; it's deposited in the Triton cache:

```bash
find $TRITON_CACHE_DIR -name '*.ttadapter' | head
# e.g. /home/Ray/triton_hello/cache_kdump/<hash>/add_kernel.ttadapter
```

Then:

```bash
source /usr/local/Ascend/ascend-toolkit/latest/bin/setenv.bash

bishengir-opt add_kernel.ttadapter \
  --lower-hfusion-pipeline \
  --optimize-hivm-pipeline \
  --mlir-print-ir-after-all \
  --mlir-disable-threading \
  2> backend.log >/dev/null

grep -c 'IR Dump' backend.log                                       # → 270
grep -oE 'IR Dump After [A-Za-z]+' backend.log | sort -u | wc -l    # → 104
```

The chain segfaults at the very end after the last pass writes its dump — **harmless, all 270 dumps are captured before the crash.** Output is ~770 KB / ~8950 lines of MLIR IR for the tiny `vector_add` kernel.

### 16.3 hivmc-input snapshot — wrapper-script trick

`hivmc` is a symlink, so swap it for a shim:

```bash
cat > /tmp/hivmc_wrapper.sh <<'EOF'
#!/bin/bash
for arg in "$@"; do
  [[ "$arg" == *.mlir ]] && cp "$arg" /home/Ray/triton_hello/captured.mlir && break
done
exec /usr/local/Ascend/cann-8.5.0/tools/bishengir/bin/hivmc "$@"
EOF
chmod +x /tmp/hivmc_wrapper.sh

# swap the symlink
mv /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc{,.bak}
ln -s /tmp/hivmc_wrapper.sh /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc

# run bishengir-compile normally — it'll invoke our wrapper transparently
export PATH=/usr/local/Ascend/cann-8.5.0/aarch64-linux/bin:$PATH
bishengir-compile add_kernel.ttadapter \
  --enable-hfusion-compile=true --enable-triton-kernel-compile=true \
  --target=Ascend910_9362 -o add_kernel.npubin

# restore — important, don't leave the shim in place
rm /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc
mv /usr/local/Ascend/cann-8.5.0/aarch64-linux/bin/hivmc{.bak,}
```

`/home/Ray/triton_hello/captured.mlir` (~65 lines / 6.5 KB) is the bookend — what comes out of the 270-dump pipeline and goes into hivmc. Everything after this snapshot is opaque (see §15).

### 16.4 Existing artifacts on 218

If you don't want to re-run, the canonical outputs from the 2026-05-07 session are:

| File | Content | Size |
|---|---|---|
| `/home/Ray/triton_hello/kernel_dump_err.log` | 9 frontend dumps | ~25 KB / 390 lines |
| `/home/Ray/triton_hello/bishengir_dump/clean_pipeline.log` | 270 backend dumps | ~770 KB / 8948 lines |
| `/home/Ray/triton_hello/bishengir_dump/llvm_dump/captured_input.mlir` | hivmc-input snapshot | 6.5 KB / 65 lines |
| `/home/Ray/triton_hello/cache_kdump/<hash>/add_kernel.npubin` | final npubin (ELF64 hiipu64) | 740 B `.text` |
