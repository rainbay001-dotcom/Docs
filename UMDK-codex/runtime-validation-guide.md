# Runtime Validation Guide

Last updated: 2026-04-25

This guide lists the runtime checks needed to validate the source-derived UMDK,
URMA, UDMA, UB root bus, UMMU, and UB-Mesh findings on a machine with UB
hardware or an equivalent emulation environment.

The current documentation is source-derived. This guide is complete as a test
plan, but the output is still pending until it is run on a real UB system.

## Baseline Kernel and Device Checks

```bash
uname -a
lsmod | grep -iE 'ub|urma|udma|ummu'
dmesg | grep -iE 'ubfi|ubrt|ubios|ubc|ub bus|ubcore|uburma|ubagg|udma|ummu'
```

Expected observations:

- UB firmware tables are detected or a clear "no UB information" message is
  logged.
- UB bus, ubcore, uburma, ubagg, UDMA, and UMMU messages line up with the
  source-derived boot path.
- If no UB hardware is present, absence should be explicit rather than a silent
  partial state.

## UB Root Bus and udev

```bash
find /sys/bus/ub -maxdepth 3 -print
ls -la /sys/bus/ub/devices
ls -la /sys/bus/ub/drivers
```

For each UB entity:

```bash
udevadm info -q property -p /sys/bus/ub/devices/<entity>
cat /sys/bus/ub/devices/<entity>/modalias 2>/dev/null || true
```

Expected observations:

- UB entities are visible under `/sys/bus/ub/devices`.
- udev properties include source-derived variables such as `UB_ID`,
  `UB_MODULE`, `UB_TYPE`, `UB_CLASS`, `UB_VERSION`, `UB_SEQ_NUM`,
  `UB_ENTITY_NAME`, and `MODALIAS=ub:*`.
- ubase-related drivers bind to the relevant UB entities.

## ubcore and uburma Nodes

```bash
ls -la /sys/class/ubcore
ls -la /sys/class/uburma
ls -la /dev/ubcore /dev/ubcore/* 2>/dev/null
ls -la /dev/uburma /dev/uburma/* 2>/dev/null
```

Expected observations:

- `/dev/ubcore/<device>` exists for ubcore devices.
- `/dev/uburma/<device>` exists for user-space URMA access.
- Device names line up with UDMA names such as `udma<N>` when UDMA is present.

## URMA Tooling

```bash
urma_admin show
urma_admin show topo
urma_admin show topo <node_id>
```

Expected observations:

- `show topo` reports node count, current node, aggregate devices, EIDs, and
  links if topology is configured.
- Topology type should be recorded: `1D-fullmesh`, Clos, or another runtime
  value if tooling prints one.
- If topology is unavailable, record the exact error because the bond provider
  has a source-visible fallback path.

## UVS and Topology

If UVS logs are available:

```bash
journalctl -k | grep -iE 'uvs|tpsa|topo|ubagg|ubcore'
```

Expected observations:

- Topology set path should show ubagg and ubcore acceptance or rejection.
- Failure cases should identify invalid node count, invalid node size, or
  missing topology map.

## UB-Mesh Specific Runtime Questions

Run:

```bash
urma_admin show topo
dmesg | grep -iE 'fullmesh|clos|topo|route|path|ubagg|uvs|ubcore'
```

Capture:

- topology type;
- node ID and super-node ID;
- current-node marker;
- aggregate EID list;
- physical device mapping for aggregate EIDs;
- path count and source/destination ports if available;
- whether switch-like entities appear in the exposed topology;
- whether LRS/HRS, APR, CCU, or backup concepts are named anywhere.

Interpretation:

- If only `1D-fullmesh` and Clos appear, the public source/runtime probably
  exposes a lower-level topology abstraction while nD/4D UB-Mesh composition
  is handled by management tooling.
- If LRS/HRS/APR names appear, add them to the paper-to-source mapping.
- If backup devices are visible, compare them with the paper's 64+1 model.

## UMMU and Segment Validation

Application-level smoke tests should include:

```bash
urma_ping --help
urma_perftest --help
```

Then run the site-specific ping/perftest commands for the available devices and
capture:

- context creation success or failure;
- Segment registration success or failure;
- token/TID-related errors;
- UMMU map/grant/unmap errors;
- completion polling behavior.

Kernel logs to collect:

```bash
dmesg | grep -iE 'tid|token|segment|sva|ksva|matt|mapt|ummu|ioummu|page'
```

Expected observations:

- Device TID allocation should happen during UDMA device bring-up.
- User TID/SVA state should be created during context creation.
- Segment registration should either pin/map/grant memory or fail with a
  source-correlatable validation error.

## CAM and Fullmesh Collectives

For CAM/MoE workloads, collect:

```bash
grep -R "level0:fullmesh" <runtime/log/path> 2>/dev/null
```

Expected observations:

- MoE AllToAll, BatchWrite, or MultiPut paths may show fullmesh algorithm
  choices.
- If topology is unavailable, note whether CAM falls back to pairwise/ring or
  another algorithm.

## Evidence Template

Use this format when adding runtime output to the docs:

```text
System:
Kernel:
UMDK commit:
Kernel UB commit:
Hardware:
Command:
Output:
Interpretation:
Source expectation:
Mismatch or follow-up:
```

## Known Limits

- This guide cannot prove paper-level APR, LRS/HRS, CCU, or 64+1 backup without
  runtime output or additional management/hardware documentation.
- The source tree proves topology APIs and maps, but not the complete UB-Mesh
  deployment generator.
- udev behavior may vary by distribution rules even though kernel uevent fields
  are source-visible.
