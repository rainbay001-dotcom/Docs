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

## 12. Useful Triton-Ascend env vars

```bash
TRITON_DUMP_DIR=/path           # dumps .ttir.mlir + .ttadapter.mlir
TRITON_CACHE_DIR=/path          # dumps .ttir + .ttadapter + .npubin + .json + launcher
TRITON_ALWAYS_COMPILE=1         # bypass cache hits, force fresh compile
TRITON_DEBUG=1                  # verbose driver output
MLIR_ENABLE_DUMP=1              # MLIR pass-by-pass dumps (large)
TRITON_PRINT_AUTOTUNING=1       # autotuner picks
```

For the `LD_LIBRARY_PATH` needed to actually run anything against an Ascend device, the `~/.bashrc` block is in `reference_npu_server.md` (memory).
