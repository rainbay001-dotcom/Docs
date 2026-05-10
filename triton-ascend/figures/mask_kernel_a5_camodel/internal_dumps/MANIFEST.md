# Camodel internal dumps — `mask_kernel_a5.o`, core 0 / veccore 0

`a5_internal_dumps.tar.gz` (82 KB) — extract with `tar xzf` to get
the 13 dump files below. These are the camodel's per-cycle internal
state logs for the bool-variant `mask_kernel` run. Sourced from a
GCE camodel run (cann9-test VM, CANN 9.0.0, dav_3510 simulator)
on 2026-05-10.

The dumps expose microarchitecture detail that is not present in
the cycle-trace JSON (`../trace_v0/dump2trace_core0.json`):

| File                                                    | Lines | What it captures                                                  |
|---------------------------------------------------------|------:|-------------------------------------------------------------------|
| `core0.veccore0.rvec.OOO.dump`                          |   905 | Out-of-order rename buffer events; **`reg_free_buf_size:15`** for V/P rename pools (5 frees/cyc) |
| `core0.veccore0.rvec.IDU.dump`                          |  4766 | Instruction Decode Unit log                                       |
| `core0.veccore0.rvec.ISU.dump`                          |  3908 | Issue Stage Unit — RECV / ISSUE / BLOCK events with reasons; LDQ + SHQ split visible |
| `core0.veccore0.rvec.LSU.dump`                          |   509 | Load/Store Unit — `LDU0` / `LDU1` / `STU` sub-pipes; **UB read ports** `PORT_0` / `PORT_1` |
| `core0.veccore0.rvec.EXU.dump`                          |   267 | Execution Unit — `exu_id:0` / `exu_id:1` per RVECEX op            |
| `core0.veccore0.rvec.simd.isu.STALL.dump`               |     1 | Issue stalls (mask_kernel: empty — no overflow stalls observed)   |
| `core0.veccore0.rvec.simd.isu.scoreboards.scb_V.dump`   |     1 | V-register scoreboard (header only)                               |
| `core0.veccore0.rvec.simd.isu.scoreboards.scb_P.dump`   |     1 | P-register scoreboard (header only)                               |
| `core0.veccore0.ccu.vec_issque.dump`                    |     7 | Vector instruction queue at the SIMD-VF front-end                  |
| `core0.veccore0.ccu.mte2_issque.dump`                   |    32 | MTE2 instruction queue                                             |
| `core0.veccore0.ccu.mte3_issque.dump`                   |     6 | MTE3 instruction queue                                             |
| `core0.veccore0.ccu.scalar_issque.dump`                 |   181 | Scalar / SU instruction queue                                      |
| `core0.veccore0.instr_log.dump`                         |   453 | Per-instruction issue/retire log                                   |

## Key findings extracted (also see `a5_aiv_vector_parallelism.html` §7)

- **Three OoO structures (not one ROB)**: IDU dispatch buffer (capacity ≥ 6),
  OOO rename free-list (15 V + 15 P, 5 frees/cyc), per-pipe retirement
  (no single global structure).
- **Lane counts** (exact, from sub-pipe labels in `LSU.dump` / `EXU.dump`):
  - RVECEX = **2 lanes** (EXU0 + EXU1, balanced 393 / 396 events)
  - RVECLD = **2 lanes** (LDU0 + LDU1, balanced 34 / 33 events)
  - RVECST = **1 lane** (STU only — paired stores serialize through it)
- **UB read ports**: 2 (`PORT_0`, `PORT_1`) — confirms the dual-issue
  VLDI dataflow from the cycle trace.
- **IDU_BLOCK peak occupancies (authoritative — supersedes earlier
  RECV/ISSUE-delta-based numbers)**:
  - LDQ ≥ **22**, STQ stayed at 0, SHQ ≥ **55**
  - PREG ≥ 30 simultaneously allocated (rename pool exhausted 41 times),
    VREG ≥ 65 simultaneously allocated
  - Dispatch buffer fullness peak = **6**
- **IDU_BLOCK reason taxonomy** (161 events): 85 UOP-Split number reached,
  31 VEC dispatch number reached, 29 OOO no avail phy preg,
  12 UOP-Split + OOO no avail phy preg, 4 ASU-related, 1 SEND_BARRIER.
- **ISU stall reasons** (842 events, 9 distinct): 248 SRC_NOT_READY_PREG,
  193 SRC_NOT_READY_VREG, 143 DST_PORT_LIMIT, 103 EXQ_ISSUED_CNT_LIMIT,
  52 VALU_GRP_OUTPUT_ACTIVE_MD_AVL, 50 MOV_FU_INPUT_CFLT,
  35 SHQ_TO_EXQ0_ISSUE_LIMIT, 17 SHQ_TO_EXQ1_ISSUE_LIMIT,
  1 SEND_BARRIER. Proves SHQ → EXQ caps at 1 op/cyc per EXQ.
- **Per-pipe retirement** (RETIRE event count by source):
  ISU 367 (RVECEX, 100 % in-order), LSU 100 (loads/stores, **76 %
  in-order — 24 % retire OoO**), scalar_issque 60, mte2_issque 10,
  mte3_issque 1, vec_issque 1.
- **Surprise**: LSU retires ≈ 24 % out-of-order. Loads with longer
  `dur` (UB-bank-conflict victims) finish after their younger
  partners; physical-register renaming makes this safe to consumers.

## Reproducing on the cann9-test GCE VM

```bash
gcloud compute instances start cann9-test --zone=us-central1-a
gcloud compute ssh cann9-test --zone=us-central1-a
# inside VM:
ls ~/a5_compile/a5_dumps_c0v0/    # already-generated dumps
# To regenerate from scratch:
cd ~/a5_compile && python sim_a5.py    # camodel run
```

## Analysis script

```python
import re, collections
isu = open('core0.veccore0.rvec.ISU.dump').read().splitlines()

# LDQ / SHQ peak occupancy
ldq = shq = ldq_pk = shq_pk = 0
for line in isu:
    m = re.match(r'\[info\] \[0+(\d+)\] \[(LDQ|SHQ)\] \[ISU_(\w+)\]', line)
    if not m: continue
    cyc, q, op = int(m.group(1)), m.group(2), m.group(3)
    if op == 'RECV':
        if q == 'LDQ': ldq += 1; ldq_pk = max(ldq_pk, ldq)
        else: shq += 1; shq_pk = max(shq_pk, shq)
    elif op == 'ISSUE':
        if q == 'LDQ': ldq = max(0, ldq - 1)
        else: shq = max(0, shq - 1)
print(f'LDQ peak: {ldq_pk}, SHQ peak: {shq_pk}')

# Block-reason histogram
print(collections.Counter(re.search(r'REASON:(\w+)', l).group(1)
      for l in isu if 'REASON:' in l))
```
