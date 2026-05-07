# CANN 9.0.0 simulator coverage — Ascend chip variant matrix

_Last updated: 2026-05-07. Verified empirically on a fresh GCP `e2-standard-16` VM with `Ascend-cann-toolkit_9.0.0_linux-x86_64.run` installed._

CANN 9.0.0 (the latest publicly downloadable release as of May 2026) ships **81 simulator directories** under `<install>/x86_64-linux/simulator/`. This is the most complete CANN simulator coverage publicly available — notably, **A5 / Ascend950PR / Atlas 350 chip family is now bundled**, which CANN 8.5.0 lacked.

## The full chip-variant simulator list (CANN 9.0.0)

```
~/Ascend/ascend-toolkit/latest/x86_64-linux/simulator/
├── 910 family
│   ├── Ascend910A, Ascend910B, Ascend910B1/B2/B2C/B3/B4
│   ├── Ascend910PremiumA, Ascend910ProA/B
│   ├── Ascend910_9362, _9372, _9381, _9382, _9391, _9392
│   └── Ascend920A
├── 310 family
│   └── Ascend310, Ascend310B*, Ascend310P*
├── BS9SX1AA, AS31XM1
└── 950 family — A5 / Atlas 350 / Da Vinci C310, NPU arch 351x
    ├── Ascend950PR_950x, _950y, _950z          (10 placeholder variants)
    ├── Ascend950PR_9571, _9572, _9573, _9574, _9575, _9576, _9577, _9578
    ├── Ascend950PR_957b, _957c, _957d
    ├── Ascend950PR_9581 through _958b
    ├── Ascend950PR_9591, _9592, _9595, _9596, _9599
    └── Ascend950PR_95A1, _95A2
```

**Total: 81 simulator targets, 30+ A5 variants** (the 9572 / 957x / 958x / 959x / 95A series).

## Per-variant lib contents

Each variant directory has the same file structure:

```
Ascend950PR_9572/lib/
├── config.json              (chip parameters: cores, clocks, cache sizes)
├── config_stars.json        (instruction cache + scheduler config)
├── libruntime_camodel.so    ← cycle-accurate simulator runtime drop-in
├── libruntime_cmodel.so     ← functional (faster, not cycle-accurate)
├── libnpu_drv_camodel.so    ← driver mock for camodel
├── libnpu_drv_pvmodel.so    ← driver mock for power/voltage model
├── libnpu_drv.so
├── libstars.so              ← STARS scheduler model
├── libstars_pv.so
├── libffts_model.so         ← FFTS task scheduler model
├── libpem_davinci.so        ← Power & Energy Model
├── libmcu_loop.so           ← MCU control plane sim
├── libmcu_wrapper.so
├── libmodel_top.so          ← top-level model glue
├── libmodel_top_pv.so
└── libesl_top_wrapper.so
```

(16 files total. `libstars.so` is what CANN 8.5.0 lacks for some variants; in 9.0.0 every variant has the full set.)

## Why this matters

Per [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §6.5: on CANN 8.5.0 the camodel internally locks to `Ascend910B1` regardless of what `soc_version` you pass. Whether CANN 9.0.0 honors `soc_version=Ascend950PR_9572` correctly hasn't been confirmed by an actual run yet, but **the existence of per-variant `config.json`/`config_stars.json` files in 9.0.0 strongly suggests** the variant-selection mechanism now respects user choice.

This is the missing piece for verifying the hypothetical A5 lowering predictions in [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.7.4 (the `pto.pand` / `pto.psel` / etc. lowering). Run `mask_kernel` with target `Ascend910_9572` under simulator `Ascend950PR_9572` and inspect the trace.

## How to install CANN 9.0.0

### Option 1: Fresh x86 VM (lowest risk)

```bash
# On any Linux x86_64 machine (GCP, AWS, local) with ~10 GB free disk and Python 3.8+
sudo apt update && sudo apt install -y python3 python3-pip python3-venv \
    libsqlite3-0 zlib1g-dev libssl-dev libffi-dev build-essential git wget curl bc

pip3 install --user numpy decorator sympy cffi attrs psutil pyyaml \
    pathlib2 cloudpickle protobuf scipy

mkdir -p ~/cann_install && cd ~/cann_install
wget --content-disposition \
  "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.0.0/Ascend-cann-toolkit_9.0.0_linux-x86_64.run"

chmod +x Ascend-cann-toolkit_9.0.0_linux-x86_64.run
./Ascend-cann-toolkit_9.0.0_linux-x86_64.run --install --quiet

source ~/Ascend/ascend-toolkit/latest/set_env.sh
```

Default install path: `~/Ascend/ascend-toolkit/latest/`. **No Huawei account login required** for the OBS download. **No Ascend hardware required** for camodel simulation work.

### Option 2: Side-by-side install on a host with existing CANN

```bash
# Same .run installer; pass --install-path to keep it separate from existing
./Ascend-cann-toolkit_9.0.0_linux-x86_64.run \
    --install --install-path=/opt/cann-9.0.0 --quiet

# DON'T overwrite /usr/local/Ascend/ascend-toolkit/latest if other users source from it
# Source 9.0.0 explicitly:
source /opt/cann-9.0.0/set_env.sh
```

See [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §6.5 for full side-by-side install details (the "how do I install CANN 9.0.0 alongside 8.5.0 on 218" question).

## Available `Ascend-*` packages at OBS for CANN 9.0.0

```
https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.0.0/
├── Ascend-cann-toolkit_9.0.0_linux-x86_64.run     1,188 MB
├── Ascend-cann-toolkit_9.0.0_linux-aarch64.run    1,166 MB
├── Ascend-cann-nnal_9.0.0_linux-x86_64.run          544 MB
└── Ascend-cann-nnal_9.0.0_linux-aarch64.run         546 MB
```

Probed via `curl -I` on 2026-05-07. `nnal` is needed for vllm-ascend / inference workloads but optional for pure compiler/simulator work. Per-chip kernel packages (`Ascend-cann-kernels-910b`, etc.) weren't found at this URL pattern — they may be bundled in the toolkit, or distributed via a different path.

## Cost and time to verify on a fresh VM

| Step | Time | Cost on `e2-standard-16` (us-central1, on-demand $0.54/hr) |
|---|---|---|
| Spin up VM | ~30 sec | ~$0.005 |
| `apt install` prereqs | ~30 sec | ~$0.005 |
| Download CANN 9.0.0 toolkit (1.16 GB) | ~3 min | ~$0.03 |
| Install CANN 9.0.0 (`--install --quiet`) | ~2 min | ~$0.02 |
| List simulator dirs | <1 sec | negligible |
| **Total to definitively answer "does CANN 9.0.0 have 9572 sim?"** | **~6 min** | **~$0.06** |

Using `--provisioning-model=SPOT` cuts this to ~$0.02. Stopping the VM after the check (vs deleting) preserves the install for future use at ~$10/mo storage cost.

## End-to-end verification (2026-05-07)

All originally-pending items are now empirically verified — see [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.7.3.5 for the trace data.

| Item | Status |
|---|---|
| CANN 9.0.0 toolkit installs cleanly on x86_64 Ubuntu 22.04 | ✅ |
| 81 simulator directories present, 30+ are A5/Ascend950PR variants | ✅ |
| `Ascend950PR_9572/lib/` has complete 16-file simulator stack | ✅ |
| `AscendOpKernelRunner(simulator_mode="ca", soc_version="Ascend950PR_9572")` actually launches A5 sim (not 910B1 fallback) | ✅ — trace shows new `RVECEX`/`RVECLD`/`RVECST` pipelines unique to A5 |
| `bishengir-compile --target=Ascend950DT_9572` produces A5-specific binary | ✅ — `.text` is 616 B (75% smaller than 910_9362's 2496 B) |
| Trace shows `RV_PAND` / `RV_POR` / `RV_PSET` predicate instructions | ✅ — `RV_PAND` 32×, `RV_POR` 64×, `RV_PXOR` 1×, `RV_PSET` 3×, `RV_VSEL` 32× |
| `MOVEMASK`/`MOVEVA`/`VNCHWCONV` eliminated on A5 | ✅ — zero instances |
| 1024-iteration scalar unpack-store loop eliminated on A5 | ✅ — replaced by 32× `RV_VSTI` and 1× `RV_VLOOP` |
| `msopgen sim` parses A5 dumps correctly | ✅ — produced 86 KB Chrome-trace JSON; only complaint is "files in input path are too many" if you don't subset |

## Known CANN 9.0.0 packaging issues (workarounds documented)

1. **Missing `release_config.json` for `Ascend950PR_*` and dav_3510 variants.** The simulator libs are installed but the `<simulator>/<variant>/conf/release_config.json` config that `msopst.runtime.rts_api._init_model_so_list()` looks for is absent. Workaround: copy the `dav_2201` (910/910C) version into `Ascend950PR_9572/conf/`:
   ```json
   {
     "ca": ["libpem_davinci.so", "libnpu_drv_camodel.so", "libstars.so", "libmodel_top.so", "libruntime_camodel.so"],
     "pv": ["libpem_davinci.so", "libnpu_drv_pvmodel.so", "libstars_pv.so", "libmodel_top_pv.so", "libruntime_cmodel.so"]
   }
   ```

2. **Circular import in `msopst.runtime.__init__.py`.** Ships as `from . import AscendRTSApi` (importing nonexistent submodule) instead of `from .rts_api import AscendRTSApi`. Patch:
   ```bash
   sed -i 's|from . import AscendRTSApi|from .rts_api import AscendRTSApi|' \
     ~/Ascend/cann-9.0.0/python/site-packages/msopst/runtime/__init__.py
   ```

3. **`ulimit -n` too low.** A5 simulator opens ~1100 dump files per run (vs ~16 for 910B1). Default Ubuntu `ulimit -n 1024` causes `Too many open files` mid-run. Fix: `ulimit -n 65536` before launching.

4. **Missing `<simulator_lib_path>/common/data/` directory.** Runner expects this even if empty. Workaround: `mkdir -p ~/Ascend/ascend-toolkit/latest/x86_64-linux/simulator/common/data`.

5. **`msopgen sim` rejects input paths writable by group/others.** Run `chmod -R go-w <dump-dir>` (and parent dirs) first.

6. **`msopgen sim` rejects dump dirs with too many files.** A5 sim writes ~1100 files per kernel; tool errors with "files exceed -1". Workaround: copy only the per-core subset you want to parse (`cp <dump-dir>/core0.veccore0.* <subset-dir>/`) before running `msopgen sim`.

7. **Compile-target naming mismatch with simulator dirs.** `bishengir-compile --target=Ascend950PR_9572` doesn't exist (`PR` is not a valid compile-target prefix). Use `Ascend950DT_9572` for compile, `Ascend950PR_9572` for simulator. (Or `Ascend910_*` family — also valid for some 9572-class targets.)

These are the natural next steps for verifying [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.7's hypothetical A5 lowering predictions against real compiled+simulated output.

## Full reproduction recipe — verify A5 simulation from scratch

### 1. Create x86 VM (~$0.20 if you stop after verification)

```bash
gcloud compute instances create cann9-test \
  --machine-type=e2-standard-16 \
  --boot-disk-size=200GB --boot-disk-type=pd-balanced \
  --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
  --zone=us-central1-a
gcloud compute ssh cann9-test --zone=us-central1-a
```

### 2. Install prereqs + download CANN 9.0.0

```bash
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    libsqlite3-0 zlib1g-dev libssl-dev libffi-dev \
    build-essential git wget curl bc

pip3 install --user --quiet numpy decorator sympy cffi attrs psutil \
    pyyaml pathlib2 cloudpickle protobuf scipy

mkdir -p ~/cann_install && cd ~/cann_install
wget --content-disposition \
  "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.0.0/Ascend-cann-toolkit_9.0.0_linux-x86_64.run"

chmod +x Ascend-cann-toolkit_9.0.0_linux-x86_64.run
./Ascend-cann-toolkit_9.0.0_linux-x86_64.run --install --quiet
```

### 3. Apply CANN 9.0.0 packaging workarounds

```bash
# (1) Fix circular import in msopst.runtime
sed -i 's|from . import AscendRTSApi|from .rts_api import AscendRTSApi|' \
  ~/Ascend/cann-9.0.0/python/site-packages/msopst/runtime/__init__.py

# (2) Write missing release_config.json for Ascend950PR_9572
cat > ~/Ascend/ascend-toolkit/latest/x86_64-linux/simulator/Ascend950PR_9572/conf/release_config.json <<'EOF'
{
  "ca": ["libpem_davinci.so", "libnpu_drv_camodel.so", "libstars.so", "libmodel_top.so", "libruntime_camodel.so"],
  "pv": ["libpem_davinci.so", "libnpu_drv_pvmodel.so", "libstars_pv.so", "libmodel_top_pv.so", "libruntime_cmodel.so"]
}
EOF

# (3) Create empty common/data dir (runner expects it)
mkdir -p ~/Ascend/ascend-toolkit/latest/x86_64-linux/simulator/common/data
```

### 4. Compile a Triton kernel for A5

Either copy a `.ttadapter` from elsewhere (e.g., 218 dev box) or compile from a fresh Triton-Ascend run. Once you have `mask_kernel.ttadapter`:

```bash
source ~/Ascend/ascend-toolkit/latest/set_env.sh

mkdir -p ~/a5_compile && cd ~/a5_compile
# (.ttadapter source must be available)
bishengir-compile mask_kernel.ttadapter \
  --enable-hfusion-compile=true --enable-triton-kernel-compile=true \
  --target=Ascend950DT_9572 \
  -o mask_kernel_a5.npubin
# Output is actually mask_kernel_a5.o (.npubin extension is Triton convention,
# bishengir-compile writes ELF .o)

ls -la mask_kernel_a5.o
# ~616 bytes for the bool variant — 75% smaller than Ascend910_9362's 2496 B
```

### 5. Launcher script (`sim_a5.py`)

```python
import os, json, numpy as np
import te.platform as tp
tp.te_set_version("Ascend950DT_9572", core_type="AiCore")
from msopst.common.ascend_tbe_op import AscendOpKernel, AscendOpKernelRunner

DUMP_DIR = "/home/ray/a5_compile/a5_dumps"
os.makedirs(DUMP_DIR, exist_ok=True)
tik_json = f"{DUMP_DIR}/mask_kernel_tik.json"
with open(tik_json, "w") as f:
    json.dump({"kernelName": "mask_kernel", "blockDim": 1,
               "magic": "RT_DEV_BINARY_MAGIC_ELF_AIVEC",
               "workspace": {"size": []}}, f)

M, N = 32, 32
q_attn = np.zeros(M, dtype=np.int32); k_attn = np.zeros(N, dtype=np.int32)
q_off = np.arange(M, dtype=np.int32); k_off = np.arange(N, dtype=np.int32)

op = AscendOpKernel("/home/ray/a5_compile/mask_kernel_a5.o", tik_json)
op.set_input_info([
    {"shape": (M,), "dtype": "int32", "value": q_attn},
    {"shape": (N,), "dtype": "int32", "value": k_attn},
    {"shape": (M,), "dtype": "int32", "value": q_off},
    {"shape": (N,), "dtype": "int32", "value": k_off},
])
op.set_output_info([{"shape": (M, N), "dtype": "int8"}])

with AscendOpKernelRunner(
    simulator_mode="ca",
    soc_version="Ascend950PR_9572",
    simulator_lib_path="/home/ray/Ascend/ascend-toolkit/latest/x86_64-linux/simulator",
    simulator_dump_path=DUMP_DIR,
) as runner:
    runner.run(op, inputs=[q_attn, k_attn, q_off, k_off], block_dim=1)
print("done", flush=True)
```

### 6. Run the simulator

```bash
cd ~/a5_compile
ulimit -n 65536    # A5 sim opens ~1100 dump files
export LD_LIBRARY_PATH=$HOME/Ascend/ascend-toolkit/latest/x86_64-linux/simulator/Ascend950PR_9572/lib:$LD_LIBRARY_PATH
python3 sim_a5.py
# Wait ~7 sec; expect "Total tick: 2240" or similar
```

### 7. Parse trace and extract mnemonics

```bash
# msopgen sim refuses dirs with too many files; subset to one core+veccore
mkdir -p ~/a5_compile/a5_dumps_c0v0
cp ~/a5_compile/a5_dumps/core0.veccore0.* ~/a5_compile/a5_dumps_c0v0/
chmod -R go-w ~/a5_compile ~/a5_compile/a5_dumps_c0v0

source ~/Ascend/ascend-toolkit/latest/set_env.sh
mkdir -p ~/a5_compile/a5_trace
msopgen sim -c core0 -subc veccore0 \
  -d ~/a5_compile/a5_dumps_c0v0 \
  -out ~/a5_compile/a5_trace
# Output: a5_trace/dump2trace_core0.json
```

Extract mnemonic statistics:

```python
import json, re
from collections import Counter
d = json.load(open("a5_trace/dump2trace_core0.json"))
events = d.get("traceEvents", d) if isinstance(d, dict) else d

# A5's msopgen sim puts mnemonic in args.detail field, not name
def mn(e):
    detail = e["args"].get("detail", "")
    m = re.match(r"\(ID:\s*\d+\)\s*([A-Z_][A-Z_0-9]*)", detail)
    return m.group(1) if m else detail

mns = Counter(mn(e) for e in events)
for n, c in mns.most_common():
    print(f"{n:25s}: {c}")
```

## Empirical mnemonic frequency comparison: 910B1 vs A5

Same `mask_kernel` (TYPE=1, M=N=32), camodel cycle-accurate trace.

| Mnemonic class | 910B1 (CANN 8.5.0) | A5/9572 (CANN 9.0.0) | Notes |
|---|---|---|---|
| **Vector compare** | `VCMPV` 4 + `VCMPVS` 1 = 5 | `RV_VCMP_EQ` 65 + `RV_VCMP_LE` 32 = 97 | A5 vectorizes the loop body — 1 compare per element, lane-by-lane |
| **Predicate logic** | (none — packed-bool with `Dtype:B16`) | `RV_PAND` 32, `RV_POR` 64, `RV_PXOR` 1, `RV_PSET` 3 | A5's hardware predicate ALU |
| **Predicate-driven select** | `VSEL` 4 (mixed F16/F32) | `RV_VSEL` 32 | A5 SEL fires per element, predicate-driven |
| **Predicate buffer push** | (no analog) | `PUSH_PB` 1 | New: dedicated predicate-buffer hardware |
| **Vector load/store** | `LD_XD_XN_IMM`/`ST_XD_XN_IMM` (scalar, byte-by-byte): 2082+1026 = 3108 | `RV_VLDI` 66, `RV_VSTI` 32 = 98 | A5 stores 32 bytes/op (vector); 910B1 stores 1 byte/op (scalar) |
| **Loop control** | `LOOP` 1 + `ENDLOOP` 1024 = 1025 | `RV_VLOOP` 1 (single vector-loop primitive) | A5's `RV_VLOOP` ≡ 1024 iterations of 910B1's scalar loop |
| **Format-conversion shuffles** | `MOVEMASK` 84 + `MOVEVA` 64 + `VNCHWCONV` 8 = 156 | 0 | Eliminated entirely on A5 — predicate registers don't need bit-layout repacking |
| **Type conversion** | `VCONV` 3 + `VNCHWCONV` 8 | `RV_VCVT_I2I` 32 | A5 uses one canonical convert mnemonic per element |
| **Vector duplicate (broadcast)** | `VBRCB` 2 | `RV_VDUPS` 2 | Equivalent role |
| **Scalar (setup, addresses)** | ~1100 calls (VOR, VAND, MOVEV, INSERT_XD, SHL, etc.) | `MOV_XD_IMM` 19, `MOVK` 10, `MOV_XD_SPR` 8, `MOV_SPR_XN` 7, `ADD_IMM` 5, etc. | A5 setup is ~70 ops vs 910B1's ~8000+ |
| **Total events** | **9,459** | **452** | **−95%** |
| **Cycle span** | **27,645** | **1,431** | **−95% (19× faster)** |

## Cost summary

Total to verify A5 cycle-accurate simulation works on CANN 9.0.0 (from a fresh GCP VM):

| Step | Wall-clock | Cost on `e2-standard-16` ($0.54/hr on-demand) |
|---|---|---|
| VM create | 30 sec | $0.005 |
| `apt install` | 30 sec | $0.005 |
| `pip install` | 30 sec | $0.005 |
| Download CANN 9.0.0 (1.16 GB) | 3 min | $0.03 |
| Install CANN 9.0.0 | 2 min | $0.02 |
| Apply packaging workarounds | 30 sec | $0.005 |
| Compile mask_kernel for A5 | 5 sec | $0.001 |
| Run sim | 7 sec | $0.001 |
| Parse trace | 2 sec | $0.001 |
| Inspect mnemonics | <1 sec | $0.001 |
| **Total** | **~6 min** | **~$0.07** |

Stop the VM after verification (disk persists at ~$10/mo for the 200 GB pd-balanced) or delete entirely.

## References

- [Huawei CANN Community Edition (account login)](https://www.hiascend.com/en/software/cann/community)
- [CANN community version history](https://www.hiascend.com/software/cann/community-history)
- Direct OBS download bucket: `https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/`
- [PTO ISA Manual](https://pto-isa.github.io/) — predicate ISA reference
- [github.com/cannmirror/pto-isa](https://github.com/cannmirror/pto-isa) — A5 added 2026-03-30
