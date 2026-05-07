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

## What's still pending

Empirically confirmed (2026-05-07):
- ✅ CANN 9.0.0 toolkit installs cleanly on x86_64 Ubuntu 22.04
- ✅ 81 simulator directories present, 30+ are A5/Ascend950PR variants
- ✅ `Ascend950PR_9572/lib/` has the complete 16-file simulator stack

Not yet verified:
- ❓ Whether `AscendOpKernelRunner(simulator_mode="ca", soc_version="Ascend950PR_9572")` actually selects the 9572 simulator config (vs falling back to a default like 8.5.0 did with 910B1)
- ❓ What per-instruction trace looks like for the same kernel under 9572 vs 9362 simulators
- ❓ Whether CANN 9.0.0's bishengir-compile chain emits `pto.pand`/`pto.psel`/etc. for an A5-targeted compile
- ❓ Whether `msopgen sim` parses 9572 dumps correctly

These are the natural next steps for verifying [`helloworld_cast_vs_nocast_comparison.md`](helloworld_cast_vs_nocast_comparison.md) §4.7's hypothetical A5 lowering predictions against real compiled+simulated output.

## References

- [Huawei CANN Community Edition (account login)](https://www.hiascend.com/en/software/cann/community)
- [CANN community version history](https://www.hiascend.com/software/cann/community-history)
- Direct OBS download bucket: `https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/`
- [PTO ISA Manual](https://pto-isa.github.io/) — predicate ISA reference
- [github.com/cannmirror/pto-isa](https://github.com/cannmirror/pto-isa) — A5 added 2026-03-30
