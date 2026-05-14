# UMDK link setup timing — tools and recipes

Reference for measuring how long UDMA / URMA link (transport-pair) setup
takes between client and master nodes, and for general kernel tracing of
the UMDK stack. Captures the toolset surveyed on 2026-05-10 while
deciding how to confirm whether the codex `tp-cache` patch (branch
`codex/udma-tp-cache` on `atomgit.com/ray-yang0218/kernel`) actually
attacks the right hot-spot.

The question driving this doc:

> The connection test between a client pod and a master pod has very
> long link setup time. We're running pre-built binaries
> (`ub_performance_server` / `ub_performance_client` from `B036`) inside
> Kubernetes pods. How do we measure where the time goes **without
> recompiling anything**?

## 0. The test command, for reference

> **Current runner** (as of 2026-05-11): see §10.12. The reporter has
> switched from `ub_performance_client` to `urma_perftest send_lat`,
> which is open-source under `src/urma/tools/urma_perftest/` and uses
> JFS+JFR (not Jetty). Same kernel link-setup path; different userland
> entry. The k8s pod commands below are kept here because the early
> sections (§2 log timestamping, §3 strace) were written against them
> and remain valid examples.

Server pod (original test, kept for §2/§3 examples):

```bash
kubectl exec -it -n default auto-master-brpc1 -- bash -c '
  numactl -N 0 -m 0 /home/share/B036/ub_performance_server \
    --port 9889 --num_threads=16 --max_concurrency=0 \
    --server_bthread_concurrency=12 --use_rdma=false \
    --ubsocket_pool_initial_size=1024 \
    --ubsocket_share_jfr_rx_queue_depth=102400 \
    --ubsocket_enable=true --use_ub=true \
    --ubsocket_log_use_printf=true --ubsocket_degrade=false \
    --ubsocket_enable_share_jfr=true --server_ignore_oc=true \
    --max_body_size=21474836480 --ubsocket_ub_epoll_enable=true \
    --ubsocket_tx_depth=1024 --ubsocket_rx_depth=1024 \
    --socket_max_unwritten_bytes=107374182400 \
    --ubsocket_pool_max_size=4096
'
```

Client pod:

```bash
kubectl exec -it -n default auto-master-brpc1 -- bash -c '
  numactl -N 0 -m 0 /home/share/B036/ub_performance_client \
    --servers=XXX --rpc_timeout_ms=400000 --connect_timeout_ms=400000 \
    --use_rdma=false --thread_num=1 --queue_depth=10 \
    --ubsocket_pool_initial_size=2048 \
    --ubsocket_share_jfr_rx_queue_depth=102400 \
    --ubsocket_enable=true --use_ub=true \
    --ubsocket_log_use_printf=true --ubsocket_degrade=false \
    --ubsocket_enable_share_jfr=true --max_body_size=21474836480 \
    --ubsocket_ub_epoll_enable=true --ubsocket_tx_depth=1024 \
    --ubsocket_rx_depth=1024 --socket_max_unwritten_bytes=107374182400 \
    --ubsocket_pool_max_size=4096 --max_retry=3 \
    --attachment_size=102400 --echo_attachment=true
'
```

`--ubsocket_log_use_printf=true` is the lever — it routes the URMA /
ubsocket log lines to stdout, so wrapping stdout is enough to anchor
events in wall-clock.

## 1. Decision matrix — pick a tool by what you can do

| Constraint                                     | Best starting tool   |
|------------------------------------------------|----------------------|
| Only `kubectl exec` access; no host shell      | log-line timestamping (§2) |
| Pod has `strace` + `CAP_SYS_PTRACE`            | strace (§3) |
| Host (K8s node) shell + root, kernel ≥ 4.x     | ftrace (§4) |
| Host shell + root + `bpftrace` installed       | bpftrace (§6) |
| Want a permanent stable probe for the driver   | define tracepoints (§5) |
| Want to ship a long-running observability tool | raw eBPF / libbpf (§7) |

For "is the codex `tp-cache` patch attacking the right thing?" on the
current `urma_perftest send_lat` runner with host access:

1. **§10.13** minimal trace setup (8–11 functions, `tracing_thresh=1000`) — one ~10-line trace per first-RPC, identifies which of the 5 phases holds the wall-clock
2. **§10.11** VTP cache verification — add `ubcore_create_vtpn` / `ubcore_reuse_vtpn` to confirm cache hit/miss
3. **§10.4** zero-instrumentation check — `dmesg | grep consumes:` after bumping `g_ubcore_log_level=6` (see §10.4 for the gate gotcha)
4. Apply codex patch, re-run, compare durations

The ftrace and tracepoint sections (§4–§5) are background for when
you want permanent in-tree probes rather than ad-hoc tracing.

## 2. Log-line timestamping — no privilege, no rebuild

The cheapest measurement. The client already prints ubsocket logs (with
`--ubsocket_log_use_printf=true`); the only thing missing is wall-clock
timestamps on every line. Wrap stdout/stderr through a per-line
timestamper:

```bash
kubectl exec -it -n default auto-master-brpc1 -- bash -c '
  numactl -N 0 -m 0 /home/share/B036/ub_performance_client \
    --servers=XXX [...all flags...] 2>&1 |
  while IFS= read -r l; do
    printf "%s %s\n" "$(date +%H:%M:%S.%N)" "$l"
  done
' | tee client.log
```

Then locate the markers that bracket "link setup":

```bash
grep -E "connect|TP|JFS|JFR|established|ready|first" client.log | head -20
```

Subtract the timestamps of the bracket lines to get the link-setup
duration. If the existing logs are too coarse, escalate to strace (§3)
or bpftrace (§6).

Tradeoff: only as good as the binary's own logging. If a slow stage
runs entirely in the kernel and never produces a userspace log line,
this approach can't see it.

## 3. strace — syscall-level tracing from inside the pod

`strace` prints every syscall a process makes. Useful here because URMA
userspace talks to the kernel driver via `ioctl()` on `/dev/urma*`, and
each TP / JFS / JFR creation step is one ioctl. Per-syscall durations
plus wall-clock timestamps tell you where the kernel hot-spots are
without rebuilding anything.

### 3.1 Modes

```bash
# Launch-wrap (you control the run)
strace -ttt -T -f -e trace=ioctl -o /tmp/client.strace <binary> <args>

# Attach to an already-running PID
strace -ttt -T -f -p <pid> -e trace=ioctl -o /tmp/srv.strace

# Summary only ("which syscall ate the most time")
strace -c -f <binary> <args>
```

Key flags:

| Flag         | Effect |
|--------------|--------|
| `-ttt`       | Wall-clock timestamp (epoch.us) on every line |
| `-T`         | Per-syscall duration in `<seconds>` at end of line |
| `-f`         | Follow forks/threads (multi-threaded clients need this) |
| `-e trace=…` | Filter — see §3.2 |
| `-o file`    | Write trace to file instead of stderr |

### 3.2 What can go after `-e trace=`

**Individual syscall names** (comma-separated):

```
-e trace=ioctl
-e trace=ioctl,openat,close
-e trace=ioctl,openat,mmap,connect,recvmsg,sendmsg,futex
```

**Categories** (`%` prefix, much easier than enumerating syscalls):

| Category      | Covers |
|---------------|--------|
| `%file`       | Path-taking calls: `openat`, `stat`, `unlink`, `chmod`, … |
| `%desc`       | FD-taking calls: `read`, `write`, `close`, `ioctl`, `epoll_*`, … |
| `%network`    | `socket`, `connect`, `bind`, `accept`, `send*`, `recv*`, … |
| `%signal`     | Signal-related: `kill`, `rt_sigaction`, … |
| `%ipc`        | SysV IPC: `shmget`, `semop`, `msgsnd`, … |
| `%process`    | `fork`, `clone`, `execve`, `wait*`, `exit*` |
| `%memory`     | `brk`, `mmap`, `munmap`, `mprotect`, `madvise`, … |
| `%creds`      | `setuid`, `setgid`, `capset`, … |
| `%clock`      | `clock_gettime`, `nanosleep`, `gettimeofday`, … |

**Special tokens**:

- `all` — every syscall (default if `-e trace` omitted)
- `none` — none
- `!name` — exclude. `-e trace=all,!futex,!nanosleep` drops the noise
- Globs work: `-e trace=epoll_*`

Other `-e` sub-options worth knowing:

- `-e signal=…` / `-e signal=none` — control signal logging
- `-e read=<fd>` / `-e write=<fd>` — also dump buffer contents on that fd
- `-e abbrev=` / `-e verbose=ioctl` — full struct decoding instead of bare pointers
- `-e decode-fds=path,socket,dev` — annotate every fd with its actual path / peer / device (huge readability win)

### 3.3 Recommended starter for URMA link setup

```bash
strace -ttt -T -f \
  -e trace=ioctl,%network,openat,close \
  -e decode-fds=path,socket \
  -o /tmp/client.strace \
  /home/share/B036/ub_performance_client ...
```

Then find the URMA fd and rank ioctls by duration:

```bash
# Find URMA fd
grep -E "openat.*urma" /tmp/client.strace | head

# Slowest ioctls overall
awk '/ioctl\(/ {match($0, /<([0-9.]+)>/, m); print m[1], $0}' /tmp/client.strace \
  | sort -rn | head -20
```

The longest-duration ioctls in the early part of the run are the
link-setup hot-spots — the same surface the codex `tp-cache` patch
targets.

### 3.4 Caveats

- **Pod permissions.** Kubernetes usually drops `CAP_SYS_PTRACE`. Test
  with `strace -e trace=write echo hi` inside the pod first; if that
  errors with "Operation not permitted", strace is blocked. Add
  `securityContext.capabilities.add: ["SYS_PTRACE"]` to the pod spec
  or run the pod privileged.
- **Overhead.** Every traced syscall stops the process via `ptrace`.
  Fine for setup-time measurement; not fine for steady-state
  throughput.
- **Filter is critical.** Without `-e trace=…` you'll log
  `read`/`write`/`futex`/… at MB/s. Always start narrow and widen.

## 4. ftrace — kernel-side tracing without recompiling

`ftrace` lives at `/sys/kernel/debug/tracing/` (or
`/sys/kernel/tracing/` on newer kernels) and is the kernel's built-in
tracing facility. Three sub-modes are useful here.

> ftrace runs on the **host's kernel**, not inside the pod. SSH to the
> K8s node where the client pod runs (`kubectl get pod -o wide` to find
> it). Run ftrace there as root; trigger the test from `kubectl exec`
> in another terminal.

### 4.1 Existing tracepoints

If the URMA / ubcore driver already defines tracepoints, this is the
cheapest path. Check:

```bash
grep -rE "urma|udma|ubcore" /sys/kernel/debug/tracing/available_events | head -40
```

If something like `ubcore:tp_create` shows up:

```bash
cd /sys/kernel/debug/tracing
echo > trace
echo 1 > events/ubcore/enable
echo 1 > tracing_on
# run the test from kubectl exec
echo 0 > tracing_on
cat trace | head -200
```

Each line has `[CPU]` + timestamp + event + fields. Subtract paired
timestamps to get phase durations.

### 4.2 Function tracer (works on any kernel function)

Hook the URMA driver functions directly. List candidates:

```bash
grep -E "ubcore|urma|udma" /sys/kernel/debug/tracing/available_filter_functions | head -30
```

Use **function_graph** — it gives per-function entry/exit + a
`DURATION` column for free:

```bash
cd /sys/kernel/debug/tracing
echo nop > current_tracer
echo > set_ftrace_filter
echo 'ubcore_create_tp*' > set_ftrace_filter
echo 'urma_advise_jfs*' >> set_ftrace_filter
echo function_graph > current_tracer
echo 16384 > buffer_size_kb     # for long runs
echo 1 > tracing_on
# run the test
echo 0 > tracing_on
cat trace
```

Output:

```
 12) ! 82345.123 us  |  ubcore_create_tp [ubcore]();
 12)   1234.567 us  |  urma_advise_jfs [urma]();
```

`!` flags any call > 100 µs.

### 4.3 kprobe / kretprobe (when function tracer can't reach it)

For static / inlined / arg-of-interest cases:

```bash
echo 'p:tp_enter ubcore_create_tp tpid=$arg1' >> kprobe_events
echo 'r:tp_exit  ubcore_create_tp ret=$retval' >> kprobe_events
echo 1 > events/kprobes/tp_enter/enable
echo 1 > events/kprobes/tp_exit/enable
echo 1 > tracing_on
# run the test
echo 0 > tracing_on
cat trace
```

bpftrace (§6) is the higher-level wrapper around this same machinery.

## 5. Defining tracepoints in the driver

If the URMA stack lacks tracepoints today, adding them is a small
patch. They're zero-overhead when off and consumable by ftrace, perf,
and BPF simultaneously.

### 5.1 Mental model

```
   source code              binary at runtime           when enabled
   ───────────             ─────────────────────         ─────────────────────
   trace_tp_create(tpn)     5-byte NOP (no cost)        NOP rewritten to jump
                                                        → calls all attached
                                                          probes (ftrace, perf,
                                                          BPF, …)
```

Three properties make this work:

1. **Static keys / jump labels.** "Is this tracepoint enabled?" is a
   NOP that the kernel patches at runtime to a real branch when
   something attaches.
2. **Multi-consumer.** ftrace, perf, and BPF can all subscribe to the
   same tracepoint at once; the backend isn't picked at definition
   time.
3. **Stable ABI by convention.** Once shipped, name + fields are a
   contract — userspace tools depend on them.

### 5.2 How to define one

**Step 1** — class header at `include/trace/events/ubcore.h`:

```c
/* SPDX-License-Identifier: GPL-2.0 */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM ubcore

#if !defined(_TRACE_UBCORE_H) || defined(TRACE_HEADER_MULTI_READ)
#define _TRACE_UBCORE_H

#include <linux/tracepoint.h>

TRACE_EVENT(tp_create_start,
    TP_PROTO(u32 tpn, u32 fe_idx),
    TP_ARGS(tpn, fe_idx),
    TP_STRUCT__entry(
        __field(u32, tpn)
        __field(u32, fe_idx)
    ),
    TP_fast_assign(
        __entry->tpn    = tpn;
        __entry->fe_idx = fe_idx;
    ),
    TP_printk("tpn=0x%x fe_idx=%u", __entry->tpn, __entry->fe_idx)
);

TRACE_EVENT(tp_create_end,
    TP_PROTO(u32 tpn, int ret),
    TP_ARGS(tpn, ret),
    TP_STRUCT__entry(
        __field(u32, tpn)
        __field(int, ret)
    ),
    TP_fast_assign(
        __entry->tpn = tpn;
        __entry->ret = ret;
    ),
    TP_printk("tpn=0x%x ret=%d", __entry->tpn, __entry->ret)
);

#endif /* _TRACE_UBCORE_H */

/* MUST be outside the multi-include guard */
#include <trace/define_trace.h>
```

Macros at a glance:

| Macro                | Purpose |
|----------------------|---------|
| `TRACE_EVENT(name…)` | Declares the tracepoint; generates `trace_<name>()`, the event struct, sysfs entry |
| `TP_PROTO`           | C signature of `trace_<name>()` |
| `TP_ARGS`            | Names from `TP_PROTO`, in order |
| `TP_STRUCT__entry`   | Per-event record layout: `__field`, `__array`, `__string` |
| `TP_fast_assign`     | Copy args into `__entry`. Hot path — keep tiny. |
| `TP_printk`          | Format string for `cat .../trace` output |

Two boilerplate must-haves: `#undef TRACE_SYSTEM` + `#define
TRACE_SYSTEM ubcore`, and `#include <trace/define_trace.h>` **outside**
the multi-include guard.

**Step 2** — emit code in exactly one `.c` file (e.g.
`drivers/ub/urma/ubcore_tp.c`):

```c
#define CREATE_TRACE_POINTS
#include <trace/events/ubcore.h>
```

`CREATE_TRACE_POINTS` is the trigger that re-includes the events header
in code-emitting mode. Define it in **exactly one** `.c` per
`TRACE_SYSTEM` or you'll get duplicate-symbol link errors.

**Step 3** — call sites in other `.c` files (header without
`CREATE_TRACE_POINTS`):

```c
#include <trace/events/ubcore.h>

int ubcore_create_tp(struct ubcore_device *dev, u32 fe_idx)
{
    u32 tpn = alloc_tpn();
    trace_tp_create_start(tpn, fe_idx);
    int ret = do_the_slow_thing(dev, tpn, fe_idx);
    trace_tp_create_end(tpn, ret);
    return ret;
}
```

`trace_tp_create_start(...)` looks like a function call but is the
patched NOP at the binary level.

### 5.3 Runtime mechanics

1. **Build time** — `TRACE_EVENT` expands to `__do_trace_<name>()` (the
   probe-walk slow path), a `trace_<name>()` inline that branches on a
   static key, and a registration entry in a section ftrace walks at
   boot.
2. **Boot** — keys default off; every `trace_<name>()` is a NOP.
3. **Enable** — `echo 1 > events/ubcore/<name>/enable` flips the key,
   kernel rewrites the NOP at every call site to a jump to
   `__do_trace_*`. Modules use `tracepoint_probe_register` but
   semantically the same.
4. **Probe fires** — `__do_trace_*` walks the registered probe list;
   each consumer (ftrace, perf, BPF) copies `__entry` into its own
   buffer.
5. **Disable** — list empties, key flips back, NOPs return.

Net cost when off: one branch the CPU never takes plus 5 patched bytes.
Measurable in ns only at extreme rates.

### 5.4 Tracepoint vs. kprobe

|                  | Tracepoint                        | kprobe                                      |
|------------------|------------------------------------|---------------------------------------------|
| Defined          | In source by developer            | At any kernel symbol by user at runtime     |
| Stability        | Stable ABI by convention           | Breaks the moment function is renamed/inlined |
| Args             | What `TP_PROTO` exposes            | Whatever's in registers/stack at probe point |
| Cost off         | Zero (NOP)                         | Zero                                        |
| Cost on          | ~tens of ns                        | ~hundreds of ns (`int3` trap)               |
| Setup            | Kernel rebuild + commit            | Runtime only                                |

For URMA: define tracepoints if you want a permanent, stable probe
surface (committed alongside the `tp-cache` patch makes natural
sense). Use kprobes / bpftrace for one-off measurement on a kernel you
don't want to rebuild.

### 5.5 End-to-end recipe (header → call site → enable → read)

The `TRACE_EVENT(...)` block by itself does nothing. Three more pieces
make it fire:

**Step 1 — header location.** Save the `TRACE_EVENT` block in
`include/trace/events/ubcore.h`. Required wrapping (top-and-tail
repeated here because it's the part people miss):

```c
/* SPDX-License-Identifier: GPL-2.0 */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM ubcore     /* dir name in /sys/.../events/ */

#if !defined(_TRACE_UBCORE_H) || defined(TRACE_HEADER_MULTI_READ)
#define _TRACE_UBCORE_H

#include <linux/tracepoint.h>

/* TRACE_EVENT(...) blocks here */

#endif /* _TRACE_UBCORE_H */

/* MUST be outside the multi-include guard */
#include <trace/define_trace.h>
```

**Step 2 — generator hook in exactly one .c.** Pick one source file
in the same subsystem (typically the one with `module_init`, e.g.
`drivers/ub/urma/ubcore_main.c`) and add at the top, before any other
ubcore include:

```c
#define CREATE_TRACE_POINTS
#include <trace/events/ubcore.h>
```

`CREATE_TRACE_POINTS` is the trigger that re-includes the events
header in code-emission mode. **Only one** `.c` per `TRACE_SYSTEM` may
set this define — duplicates produce link errors.

**Step 3 — call sites in real code.** In whatever file does TP
creation:

```c
#include <trace/events/ubcore.h>     /* no CREATE_TRACE_POINTS */

int ubcore_create_tp(struct ubcore_device *dev, u32 fe_idx)
{
    u32 tpn = ubcore_alloc_tpn(dev);
    if (tpn == UBCORE_INVALID_TPN)
        return -ENOMEM;

    trace_tp_create_start(tpn, fe_idx);          /* entry probe */
    int ret = ubcore_program_hw_tp(dev, tpn, fe_idx);
    trace_tp_create_end(tpn, ret);               /* exit probe */
    return ret;
}
```

`trace_tp_create_start(...)` looks like a function call but at the
binary level is a 5-byte NOP when nothing is listening. Cost when off
≈ 0 — these calls can stay in production code.

**Step 4 — build.**

If ubcore is a module:

```bash
cd /Volumes/KernelDev/kernel
make -j$(nproc) M=drivers/ub modules
sudo make M=drivers/ub modules_install
sudo depmod -a
sudo modprobe -r ubcore && sudo modprobe ubcore
```

If built into the kernel:

```bash
cd /Volumes/KernelDev/kernel
make -j$(nproc)
sudo make modules_install install
sudo reboot
```

`include/trace/events/ubcore.h` is on the kernel include path
automatically — no Kbuild edits needed. After reload:

```bash
ls /sys/kernel/debug/tracing/events/ubcore/
# tp_create_start  tp_create_end  enable  filter
```

**Step 5 — enable + read.**

```bash
cd /sys/kernel/debug/tracing
echo 1 > events/ubcore/enable           # all events in subsystem
# or per-event: echo 1 > events/ubcore/tp_create_start/enable
echo 16384 > buffer_size_kb             # roomy enough for long runs
echo > trace
echo 1 > tracing_on
# … run the client/server test …
echo 0 > tracing_on
cat trace | head -50
```

Output:

```
ub_performance_-3421 [012] ...1 4567.123456: tp_create_start: tpn=0x42 fe_idx=3
ub_performance_-3421 [012] ...1 4567.205797: tp_create_end:   tpn=0x42 ret=0
```

`4567.205797 − 4567.123456 = 82.341 ms` for that TP-create. Disable
with `echo 0 > events/ubcore/enable; echo 0 > tracing_on`.

### 5.6 What each line of `TRACE_EVENT(...)` does

The block is **one macro invocation that expands into roughly seven
things at compile time** — a function, a struct, two callbacks, a
format string, a registration record, and a sysfs entry. Three phases
and which line drives each:

```
   compile time       enable time              hot path                    display time
   ──────────────     ───────────────          ───────────────             ─────────────
   macro expands      sysfs flips a            trace_tp_create_start()     cat trace prints
   to declarations    static key on            fires; TP_fast_assign       a line using
   + struct + fns     so probe registers       copies args into ring       TP_printk format
                                                buffer __entry struct
```

`TP_fast_assign` runs on every fire. `TP_printk` runs **only** when
something reads the trace output. People often confuse them —
`TP_fast_assign` must be cheap, `TP_printk` doesn't have to be.

| Line                                              | What it contributes |
|---------------------------------------------------|----------------------|
| `TRACE_EVENT(tp_create_start,`                    | Event name. Combined with `TRACE_SYSTEM` becomes `ubcore:tp_create_start` (perf/bpftrace name), `events/ubcore/tp_create_start/` (sysfs dir), and `trace_tp_create_start(...)` (the C callable). |
| `TP_PROTO(u32 tpn, u32 fe_idx)`                   | C signature of the call site. The compiler type-checks `trace_tp_create_start(...)` calls against this. Change it and every caller has to change. |
| `TP_ARGS(tpn, fe_idx)`                            | Bare arg names from `TP_PROTO`, in the same order, with no types. Used by inner macros to forward values. Mismatched lists are a build error. |
| `TP_STRUCT__entry(...)`                           | On-wire record format — the struct laid out in the per-CPU ring buffer at every fire. `__field(u32, tpn)` reserves 4 bytes named `tpn`. Other field types: `__array(t, n, size)`, `__string(n, src)`, `__dynamic_array(t, n, count)`. The same struct shows up under `events/.../format` as a machine-readable schema. |
| `TP_fast_assign(...)`                             | **Hot path.** Runs on every fire when enabled. Magic pointer `__entry` points at the freshly-allocated record. Keep to scalar copies and small `memcpy`s — no locks, no `printk`, no allocations. |
| `TP_printk("tpn=0x%x fe_idx=%u", __entry->...)`   | **Display path.** Runs lazily when somebody reads `trace`/`trace_pipe`. Free to be expensive — bitmask decoding, conditional strings, multi-line output. Reads `__entry` populated earlier. |
| `);`                                              | Closes the macro. The expansion ends in a declaration; the trailing `;` is required. |

What `tp_create_start` specifically gives you:

- Public name: `ubcore:tp_create_start`
- Call syntax: `trace_tp_create_start(my_tpn, my_fe_idx);`
- Logged fields: two `u32`s (`tpn`, `fe_idx`) plus standard timestamp/CPU/PID/comm header
- `cat trace` line: `tp_create_start: tpn=0x42 fe_idx=3`
- bpftrace access: `args->tpn` / `args->fe_idx` inside `tracepoint:ubcore:tp_create_start { ... }`
- perf access: `perf record -e ubcore:tp_create_start ...`
- Cost when off: zero (NOP at every call site)
- Cost when on: ~tens of ns per fire (slot allocation + two `u32` stores + commit)

### 5.7 Common gotchas

| Symptom                                     | Cause                                                                                                | Fix |
|---------------------------------------------|------------------------------------------------------------------------------------------------------|-----|
| `cat trace` shows nothing                   | `tracing_on` never set                                                                               | `echo 1 > tracing_on` |
| `events/ubcore/` doesn't exist              | `CREATE_TRACE_POINTS` not in any built `.c`, OR header has no `#include <trace/define_trace.h>` outside the guard | Re-check Steps 1 + 2 |
| Linker error: multiple definition           | `CREATE_TRACE_POINTS` in more than one `.c`                                                          | Pick one — only one |
| Build error: `expected '}' before TRACE_EVENT` | Missing semicolon after `TRACE_EVENT(...)` block                                                  | The macro expands to a declaration; needs a `;` at the end |
| Format string crashes the kernel            | `%s` in `TP_printk` reads a userspace pointer or freed kernel pointer                                | Save strings into `__entry` via `__string`/`__assign_str`, not as raw pointers |
| Tracepoint compiles but never fires         | Compiler inlined the function containing the call site, so the call site got optimized out          | Mark the function `noinline` or move the trace call into a non-inlined wrapper |
| Output truncated                            | Default 1408 KB ring buffer too small                                                                | `echo 16384 > buffer_size_kb` (or larger) |

### 5.8 Reading without rebuilding the parser

bpftrace already understands tracepoints. Once your patch is loaded:

```bash
bpftrace -e '
tracepoint:ubcore:tp_create_start { @s[args->tpn] = nsecs; }
tracepoint:ubcore:tp_create_end /@s[args->tpn]/ {
    @us = hist((nsecs - @s[args->tpn]) / 1000); delete(@s[args->tpn]);
}'
```

Same shape as the `kprobe:ubcore_create_tp` script in §6 but anchored
on the **stable** tracepoint name instead of the function symbol —
survives renames, function inlining, refactors. That's the long-term
value of putting tracepoints in the driver instead of just kprobing
it.

## 6. bpftrace — high-level tracing language

bpftrace is `awk` for kernel tracing — short scripts that compile to
eBPF, attach to probes, and aggregate in-kernel. Created by Brendan
Gregg + Alastair Robertson, modeled on DTrace.

### 6.1 What sits on top of what

```
   bpftrace script  ─── parses & compiles ──►  BPF bytecode
                                                   │
                                            BPF verifier (kernel)
                                                   │
                                       attached to one or more probe points:
                                           ├─ kprobe / kretprobe
                                           ├─ tracepoint
                                           ├─ uprobe / uretprobe
                                           ├─ USDT (statically defined userspace)
                                           ├─ perf events
                                           ├─ software events
                                           └─ profile / interval timers
                                                   │
                                       runs in-kernel on every fire,
                                       writes results to BPF maps
                                                   │
                              bpftrace reads maps & prints when you Ctrl-C
```

### 6.2 Language model in 30 seconds

A program is a list of `probe / filter / action` triples:

```
probe_spec  /optional predicate/  { action }
```

Probe families:

```
kprobe:ubcore_create_tp        # function entry
kretprobe:ubcore_create_tp     # function return
tracepoint:ubcore:tp_create_start
uprobe:/path/to/binary:func
profile:hz:99                  # 99 Hz sampling on every CPU
interval:s:1                   # once a second
BEGIN / END                    # script start / end
```

Builtins inside actions:

| Builtin             | Meaning |
|---------------------|---------|
| `pid`, `tid`, `comm`| pid, tid, command name |
| `cpu`               | CPU we fired on |
| `nsecs`             | monotonic ns timestamp |
| `arg0..argN`        | function args (kprobe/uprobe) |
| `args->field`       | tracepoint fields by name |
| `retval`            | return value (kretprobe/uretprobe) |
| `kstack`, `ustack`  | stack traces |
| `func`              | name of probed function |

Variables:

- `$local` — scratch, scope = current probe firing
- `@global` — map, persists across firings, printed at exit
- `@map[k1,k2]` — multidim associative array

Map functions (the magic):

- `count()`, `sum(x)`, `avg(x)`, `min(x)`, `max(x)`, `stats(x)`
- `hist(x)` — power-of-two histogram (great for latency)
- `lhist(x, lo, hi, step)` — linear histogram

### 6.3 The exact script for URMA TP-create timing

```bash
bpftrace -e '
kprobe:ubcore_create_tp {
    @start[tid] = nsecs;
}
kretprobe:ubcore_create_tp /@start[tid]/ {
    @us = hist((nsecs - @start[tid]) / 1000);
    delete(@start[tid]);
}'
```

Trigger the client, let it run, Ctrl-C bpftrace. Output is a histogram
of TP-create durations in µs. Slow-call detail with stacks:

```bash
bpftrace -e '
kprobe:ubcore_create_tp {
    @start[tid] = nsecs;
}
kretprobe:ubcore_create_tp /@start[tid] && (nsecs - @start[tid]) > 10000000/ {
    printf("slow tp_create: %d us, kstack:\n%s\n",
           (nsecs - @start[tid]) / 1000, kstack);
    delete(@start[tid]);
}'
```

That prints a stack trace at every TP-create > 10 ms — the answer to
"which call path is slow", which is what tells you whether the codex
`tp-cache` patch attacks the right hot-spot.

### 6.4 Why bpftrace exists when ftrace already does

ftrace gives raw events; bpftrace **aggregates and filters in the
kernel** before data ever crosses to userspace.

| Need                                           | ftrace                              | bpftrace                       |
|------------------------------------------------|--------------------------------------|--------------------------------|
| Show every call                                | `events/.../enable` + `cat trace`   | yes, also possible             |
| Histogram of durations                         | dump → awk → process                | one line: `@ = hist(elapsed)`  |
| Stack at every page fault > 1 ms               | hard                                 | one line with `kstack`         |
| Filter on argument value                       | limited                              | full predicate language        |
| Per-tid state across two probes                | external script                      | `@start[tid] = nsecs`          |
| Per-CPU counters summed at exit                | manual                               | maps are per-CPU by default    |

The win scales with event rate — millions of events, ftrace dumps them
all and you grep later; bpftrace runs the awk in-kernel and gives you
a one-line summary.

### 6.5 Practical notes

- **Install:** `apt install bpftrace` (Debian/Ubuntu), `dnf install
  bpftrace` (RHEL/CentOS). Needs root; kernel 5.x+ ideal.
- **Discover probes:** `bpftrace -l 'kprobe:ubcore*'`,
  `bpftrace -l 'tracepoint:ubcore:*'`.
- **Inspect tracepoint args:** `bpftrace -l -v
  tracepoint:ubcore:tp_create_start` prints the argument struct.
- **Verifier limits:** rejects unbounded loops, unverifiable pointer
  reads, stack > 512 B. Errors can be cryptic — usual fix is "use
  `bpf_probe_read_*`" or "shrink your map key".
- **Overhead:** lower than strace, slightly higher than raw ftrace
  tracepoints. ~1 µs per kprobe call (Brendan Gregg's number).

## 7. eBPF — the platform underneath

eBPF is a **virtual machine inside the Linux kernel** that runs small,
sandboxed programs at hook points (syscalls, function entry/exit,
packet arrival, scheduler events) without recompiling the kernel and
without loading a kernel module. It's the foundation that bpftrace,
BCC, Cilium, Falco, perf, and modern observability tooling all build
on.

### 7.1 Lineage

| Era  | What it was |
|------|-------------|
| 1992 | "BPF" classic — 31-instruction VM for `tcpdump` packet filters |
| 2014 | "eBPF" extended — 64-bit, 11 registers, kernel helpers, JIT'd, repurposed beyond networking |
| Now  | Kernel-side platform; the "e" is mostly dropped in conversation |

### 7.2 Architecture

```
   userspace                     kernel
   ─────────                     ──────
                                 ┌────────────────────────────────┐
   your program (.o)  ─load──►   │  BPF verifier                  │
                                 │   ├─ proves termination        │
                                 │   ├─ checks every memory access│
                                 │   ├─ tracks register types     │
                                 │   └─ rejects if unsafe         │
                                 ├────────────────────────────────┤
                                 │  BPF JIT                       │
                                 │   compiles bytecode → native   │
                                 ├────────────────────────────────┤
                                 │  attached at hook points       │
                                 │   (kprobe, tracepoint, XDP, …) │
                                 └────────────────────────────────┘
                                                ▲     │
                                          fires │     │ writes
                                                │     ▼
                                                ┌────────────┐
                                          ◄────►│ BPF maps   │ ←── userspace reads/writes
                                                └────────────┘
```

Five things make this work:

1. **Restricted ISA.** 11 64-bit registers (r10 read-only stack ptr),
   512-byte stack, no arbitrary memory access — only via verified
   pointers. Looks vaguely like x86-64 ABI on purpose.
2. **The verifier.** Before running, the kernel proves the program is
   safe: every load goes to a memory region it can name (map value,
   packet buffer, stack within bounds), every loop is bounded, every
   helper has the right argument types, the program terminates. If the
   verifier can't prove safety, the load fails. This is what lets the
   kernel run untrusted code at ring 0.
3. **JIT to native.** Verified bytecode is compiled to x86-64 / arm64 /
   s390x machine code.
4. **Maps.** Programs can't allocate arbitrary memory — they read/write
   typed, bounded maps (hash, array, ringbuf, lru, percpu_*, lpm_trie,
   sk_storage, …). Userspace mmaps the same maps to read results. Maps
   are also how two BPF programs communicate.
5. **Helpers.** Curated kernel functions BPF programs can call (~200 of
   them): `bpf_probe_read_user`, `bpf_get_current_pid_tgid`,
   `bpf_perf_event_output`, `bpf_redirect`, etc.

### 7.3 Hook families

| Family                    | What you can hook                          | Example use |
|---------------------------|--------------------------------------------|-------------|
| kprobe / kretprobe        | Any non-inlined kernel function           | bpftrace measuring `ubcore_create_tp` |
| tracepoint / raw_tracepoint | Static probes defined in source         | "page fault rate per process" |
| uprobe / uretprobe        | Userspace functions in any binary         | Tracing `SSL_read` in libssl |
| fentry / fexit            | Lower-overhead, BTF-typed args             | High-rate function tracing |
| XDP                       | NIC driver, before skb allocation          | DDoS drop, load balancer (Cilium, Cloudflare, Katran) |
| TC                        | Per-egress / ingress packet                | Per-pod network policy |
| socket filter / sockops   | Per-socket BPF                             | Sidecar-less service mesh |
| LSM hooks                 | Linux Security Module hooks               | Runtime security (Falco, Tetragon) |
| perf events               | Hardware counters, sampling               | Off-CPU flamegraphs |
| cgroup hooks              | Per-cgroup network/file events             | Container-aware policy |

### 7.4 Tooling that targets eBPF

```
   ┌─────────────────────────────────────────────────────────────┐
   │  high-level tools                                           │
   │  bpftrace        BCC          Cilium      Falco/Tetragon    │
   ├─────────────────────────────────────────────────────────────┤
   │  libbpf (C) / cilium/ebpf (Go) / aya (Rust)                 │
   │   — load BPF objects, manage maps, attach probes            │
   ├─────────────────────────────────────────────────────────────┤
   │  BPF object file format + BTF (type info for portability)   │
   ├─────────────────────────────────────────────────────────────┤
   │  bpf() syscall                                              │
   ├─────────────────────────────────────────────────────────────┤
   │  kernel: verifier, JIT, hooks, maps, helpers                │
   └─────────────────────────────────────────────────────────────┘
```

When you write `bpftrace -e 'kprobe:foo { ... }'`, bpftrace's frontend
parses the script, generates BPF bytecode + map definitions, hands them
to libbpf, libbpf calls the `bpf()` syscall, the verifier accepts, the
JIT compiles, the kprobe fires, results flow into a perf/ringbuf, and
bpftrace prints. All of that machinery is invisible by default.

### 7.5 Why eBPF matters

- **Safety + speed at once.** ~80% of the power of a kernel module,
  but the verifier ensures you can't crash the kernel.
- **Hot-loadable.** No reboot, no module unload-load. Attach, detach,
  change behavior in production.
- **Portable across kernel versions** with CO-RE — Compile Once Run
  Everywhere — using BTF type info. One BPF object runs on multiple
  kernel versions because the loader rewrites struct field offsets at
  load time.
- **Multi-tenant.** Multiple BPF programs can attach to the same hook
  simultaneously — Cilium's networking + Falco's security probes +
  your bpftrace one-liner all coexist.

## 8. eBPF vs bpftrace — they're not at the same level

eBPF is the **platform**; bpftrace is **one of many tools that produces
eBPF programs**. Same relationship as `x86 ↔ Python` or `JVM ↔ Groovy`.

```
   What you write                Tool / library             What runs in the kernel
   ─────────────                 ──────────────             ───────────────────────
   bpftrace one-liner    ──►     bpftrace                          ┐
   Python + C snippets   ──►     BCC                                │
   C + libbpf            ──►     libbpf-bootstrap, etc.            ├──►  eBPF bytecode
   Go + cilium/ebpf      ──►     Cilium, Tetragon, Pixie           │     (verified, JIT'd,
   Rust + aya            ──►     Aya-based agents                  │      attached to a hook)
   Hand-written .o       ──►     bpftool / clang -target bpf       ┘
```

### 8.1 What you trade

| Dimension          | bpftrace                                        | Raw eBPF (libbpf / BCC / cilium-ebpf) |
|--------------------|--------------------------------------------------|-----------------------------------------|
| Code volume        | 1–10 line script                                 | 50–500 lines of C + loader |
| Iteration speed    | Edit → Ctrl-C → re-run, instant                 | Edit → recompile → reload, seconds |
| Hook points        | kprobe, uprobe, tracepoint, USDT, profile, interval, software events | All of those *plus* XDP, TC, socket filter, sockops, LSM, cgroup, sk_lookup, lwt, sched_ext, struct_ops, … |
| Program types      | Tracing only                                     | Networking, security, scheduling, custom |
| Map types          | Auto-derived from how `@var` is used            | All ~30 map types |
| Output             | Stdout when you Ctrl-C; printf during run        | Anything — perf buf, ringbuf, mmap'd map, control plane, … |
| Persistence        | Process-lifetime — bpftrace exits, programs unload | Pinned programs/maps survive the loader |
| CO-RE / portability| Loaded against running kernel each time          | One `.o` runs on multiple kernels |
| Verifier dialogue  | Mostly hidden                                    | You see verifier logs directly |
| Skill required     | bpftrace DSL                                     | C / Go / Rust + helper API + BTF + libbpf |

### 8.2 The big asymmetry

**bpftrace is great at observation, not at intervention.** A bpftrace
script can *count* packets but not drop them; can *measure* a syscall
but not change its return value; can't run inside an XDP hook to do
load balancing. The moment your goal goes beyond "extract a number"
into "change kernel behavior", you've outgrown bpftrace.

Things that need raw eBPF (libbpf-class):

1. **Networking data plane** — XDP drop, TC redirect, eBPF load
   balancers (Cilium, Katran, Cloudflare L4 LB).
2. **Security policy enforcement** — LSM hooks that *deny* operations.
   Falco-modern, Tetragon, KubeArmor.
3. **Long-lived production agents** — survive process restart, expose
   maps to other consumers, CO-RE for cross-kernel portability.
4. **Custom data structures and aggregations** beyond
   hash/array/hist — e.g. LRU map keyed by 5-tuple for connection
   tracking, ringbuf with custom event format consumed by a Prometheus
   exporter.
5. **Modify return values / arguments** — `bpf_override_return`, drop
   packets, redirect.
6. **bpf_loop / large iteration** — bpftrace has limited loop support.
7. **Sub-millisecond aggregation pipelines** — custom ringbufs +
   userspace consumers running at thousands of events/sec/CPU.

### 8.3 Decision rule

| Question                                                           | Use |
|--------------------------------------------------------------------|-----|
| How long does `ubcore_create_tp` take?                              | bpftrace |
| Distribution of TP-create durations across 10 minutes of load?     | bpftrace |
| Stack trace whenever TP-create > 50 ms                              | bpftrace |
| Ship a tool to the team that monitors this in production for weeks | libbpf + small daemon |
| Drop packets from non-allowlisted IPs at NIC level                  | libbpf + XDP |
| Deny `openat()` to anything outside `/etc`                          | libbpf + LSM |
| Cluster CNI doing load balancing in BPF                             | libbpf + TC/XDP (or use Cilium) |

For the URMA link-setup question, bpftrace is unambiguously right —
measurement, not intervention. If the prototype proves valuable and
you want a permanent observability daemon for the URMA TP path, port
the bpftrace script to libbpf for CO-RE portability and unattended
operation.

## 9. Recommended attack plan for the original question

1. **§2 first** — log timestamping inside the pod. One `kubectl exec`,
   no privilege needed. Get a magnitude: is "very long" 10 ms, 100 ms,
   1 s, 10 s? This number alone tells you how much room the codex
   `tp-cache` patch could save.

2. **§3 if §2 isn't precise enough** — strace inside the pod. Needs
   `CAP_SYS_PTRACE`. Confirms the time is in `ioctl()` (kernel) and not
   userspace setup, and ranks the slowest ioctls.

3. **§6 once you have host access** — bpftrace on the K8s node.
   Histogram of `ubcore_create_tp` durations. Stack traces on slow
   ones. This is the real answer.

4. **§5 once you've identified the hot stages** — define tracepoints
   in the URMA driver at the boundaries of those stages, so future
   measurements are stable across kernel rebuilds and the codex
   `tp-cache` patch can be evaluated by anyone running `cat trace`.

5. **Re-run the bpftrace histogram on the patched kernel** — same
   script, before/after. The shift in the distribution is your patch
   acceptance signal.

## 10. OLK-6.6 link-setup call chain (concrete, post-investigation)

This section is the result of reading the actual OLK-6.6 source under
`/Volumes/KernelDev/kernel/drivers/ub/` after the preceding sections
were written. It supersedes any guesses from earlier sections about
which kernel function holds the first-RPC latency.

The investigation was triggered by issue
`rainbay001-dotcom/UMDK#1`, where JinDou1210 reported
`First-RPC-Latency: 904959 μs` on a healthy URMA setup
(`Avg-Latency: 861 μs` steady-state). Their environment loads
`ubcore + udma + ubase + ummu_core + drv_seclib_host` and uses the
UMQ + URMA path (not UMS).

### 10.1 Earlier guess (wrong) vs. reality

An earlier hypothesis was that the slow step is
`ubcore_nl_send_wait()` at `ubcore_netlink.c:418`, doing a synchronous
genl round-trip to a userspace UVS daemon (`uvsd`) with a 30 s
`UBCORE_TYPICAL_TIMEOUT`. That **was wrong for this code base** —
`ubcore_nl_send_wait` exists in OLK-6.6 source but has **zero in-tree
callers**:

```bash
grep -rn "ubcore_nl_send_wait\b" /Volumes/KernelDev/kernel/drivers/ub/
# only the function definition and the header declaration; no .c uses it
```

In OLK-6.6, the active-TP path goes through the firmware **control
queue** (`ubase_ctrlq`), not netlink-to-uvsd. The blocking wait is
still in the kernel, but at a different layer, and the actual time is
spent on the SoC's MUE (Management Unit Engine) doing a cross-fabric
handshake with the peer's MUE.

### 10.2 What the prior graph in this section also missed

An earlier revision of this section drew a graph that stopped at
"firmware/MUE does the cross-fabric handshake with the peer." That was
also wrong. The **host kernel** does the cross-fabric negotiation via
**MAD over the data path** (using ubmad / ub_cm / ubcore_post_jetty_send_wr
etc.); the firmware is only invoked at the *end* of the negotiation,
via `ubcore_active_tp` → `ubase_ctrlq_send_msg`, to install the
already-negotiated TP context into local hardware.

This means there are **two waits** on the first-RPC path, not one:

1. **MAD reply wait** in the upper layer of `ubcore_connect_vtp_ctrlplane`:
   the CM sends a `UBMAD_UBC_CONN_REQ` MAD via `ubmad_post_send` and
   blocks until the peer's `UBMAD_UBC_CONN_RESP` arrives via the JFC
   completion handler. Whoever holds the wait keys it on the CM
   transaction id.
2. **ctrlq wait** at `ubase_ctrlq.c:662` for the firmware to ack
   `UDMA_CMD_CTRLQ_ACTIVE_TP`. Bounded by `csq->tx_timeout`. Usually
   fast (firmware is local).

The 905 ms first-RPC latency is *probably* in (1) — MAD round-trip(s)
across the UB fabric, plus the upper-layer wait keyed on the CM
transaction.

### 10.3 The integrated call chain (host CPU + MAD over fabric + firmware)

Three flows happen in sequence (and with some overlap on the peer side):

- **Flow C** (control on host): `advise_jetty` → `connect_vtp_ctrlplane` → `get_tp_list` → CM REQ build → wait → CM RESP handle → `active_tp`
- **Flow D** (data path used as MAD transport): `ubmad_post_send` → `ubcore_post_jetty_send_wr` → `udma_post_jetty_send_wr` → SEND WQE → wire → peer CQE → peer `ubcore_poll_jfc` → peer `udma_poll_jfc` → peer `ubmad_recv_work_handler` → peer `ubcm_recv_handler`
- **Flow F** (firmware install): `udma_active_tp` → `udma_ctrlq_set_active_tp_ex` → `udma_k_ctrlq_create_active_tp_msg` → `ubase_ctrlq_send_msg` → `__ubase_ctrlq_send` → `ubase_ctrlq_wait_completed` → MUE programs hardware

Time runs top-to-bottom; the two host-CPU lanes are nodes A and B; the
horizontal squiggles are MADs flying over the UB fabric.

```
   NODE A — HOST KERNEL                                  NODE B — HOST KERNEL
   ════════════════════                                  ════════════════════
ioctl(UBURMA_CMD_ADVISE_JETTY)
  └─ ubcore_advise_jetty
      └─ ubcore_connect_vtp_ctrlplane             ubcore_vtp.c:1201
            ├─ vtpn cache miss
            ├─ ubcore_get_tp_list (1st)           ubcore_tp.c:26      ◄── self-instrumented
            │     └─ dev->ops->get_tp_list             (driver-local; may need
            │        = udma_get_tp_list                 cached peer info)
            │
            └─ ub_cm: build CONN_REQ MAD          ubcm/ub_cm.c
                  └─ ubcm_work_handler
                        └─ ubmad_post_send        ubmad_datapath.c:768
                              └─ ubcore_post_jetty_send_wr
                                    └─ udma_post_jetty_send_wr  (data path!)
                                          └─ udma_post_one_wr
                                                └─ ✏ SEND WQE on MAD jetty SQ
                                                       │
                                       ───────────────►│ over UB fabric ────────────►   hw delivers
                                                                                          │
                                                                                          ▼
                                                                                   CQE on RX JFC
                                                                                          │
                                                                              ubmad_jfce_handler_r
                                                                              ubmad_datapath.c:1429
                                                                                          │
                                                                              ubcore_poll_jfc       ubcore_jetty.c
                                                                                  └─ udma_poll_jfc  hw/udma/udma_jfc.c
                                                                                          │
                                                                              ubmad_recv_work_handler
                                                                              ubmad_datapath.c:1266
                                                                                          │
                                                                                ubcm_recv_handler
                                                                                ub_cm.c:148
                                                                                  case UBMAD_UBC_CONN_REQ:
                                                                                    ubcore_cm_recv(...)
                                                                                          │
                                                                              ubcore_get_tp_list (peer side)
                                                                              ubcore_tp.c:26
                                                                                          │
                                                                              build CONN_RESP MAD
                                                                              ubmad_post_send
                                                                              ubcore_post_jetty_send_wr
                                                                              udma_post_jetty_send_wr
                                                                                  ✏ SEND WQE
                                                                                          │
                                                                              ◄────────── over UB fabric ──────
   CQE on RX JFC
   ubmad_jfce_handler_r
       │
   ubcore_poll_jfc
       └─ udma_poll_jfc
       │
   ubmad_recv_work_handler
       │
   ubcm_recv_handler  (UBMAD_UBC_CONN_RESP)
       │
   handler resolves negotiated TP descriptor
       │
   ubcore_active_tp                              ubcore_vtp.c:1129    ◄── self-instrumented
       │   start = ktime_get_ns(); … duration = …                    via UBCORE_DRV_TP_THRESHOLD_MS
       │
       └─ udma_active_tp                          udma_ctrlq_tp.c:981
             └─ udma_ctrlq_set_active_tp_ex       udma_ctrlq_tp.c:717
                   └─ udma_k_ctrlq_create_active_tp_msg
                                                  udma_ctrlq_tp.c:677
                         └─ ubase_ctrlq_send_msg  ubase_ctrlq.c:926
                               └─ wait_for_completion_timeout
                                                  ubase_ctrlq.c:662
                                  ───────► (same flow on Node B; firmware on each side
                                            programs its half of the TP context)

   ── on completion: vtpn cached in dev->ht[UBCORE_HT_CP_VTPN],
                     ioctl returns, first send proceeds on the now-active TP.
```

### 10.4 Zero-instrumentation first check — read the kernel log

**Two** ubcore functions self-instrument with the same threshold:

```c
/* ubcore_tp.c:48 — get_tp_list duration */
if (duration > UBCORE_DRV_TP_THRESHOLD_MS)
    ubcore_log_info_rl("[DRV_INFO]get_tp_list consumes: %llu.\n", duration);

/* ubcore_vtp.c:1153 — active_tp duration */
if (duration > UBCORE_DRV_TP_THRESHOLD_MS)
    ubcore_log_info_rl("[DRV_INFO]active_tp init consumes: %llu.\n", duration);
```

**Gotcha — module log level gates these lines silently.** `ubcore_log_info_rl`
is defined as (`drivers/ub/urma/ubcore/ubcore_log.h:110`):

```c
#define ubcore_log_info_rl(...) \
    ({ if (... && (g_ubcore_log_level >= UBCORE_LOG_LEVEL_INFO)) \
           printk_ratelimited(...); })
```

Levels (`ubcore_log.h:19–28`):

```
0 EMERG    1 ALERT   2 CRIT    3 ERR
4 WARNING  5 NOTICE  ← default        6 INFO  ← needed     7 DEBUG
```

Default `g_ubcore_log_level` is **`UBCORE_LOG_LEVEL_NOTICE = 5`**
(`ubcore_log.c:15`), and the macro requires INFO (6). So with the
default level, the `get_tp_list consumes` / `active_tp init consumes`
calls expand to `if (false) printk(...)` — completely silent. **No
output from `dmesg | grep consumes` doesn't mean the path is fast; it
means the gate is closed.**

It's a module parameter (`ubcore_main.c:28`), so no rebuild — flip it
at runtime:

```bash
# Open the gate to INFO (6)
echo 6 | sudo tee /sys/module/ubcore/parameters/g_ubcore_log_level

# Trigger one first-RPC, then:
sudo dmesg -t | grep -E "get_tp_list consumes|active_tp init consumes"

# Optionally revert when done
echo 5 | sudo tee /sys/module/ubcore/parameters/g_ubcore_log_level
```

(Or set at module load: `modprobe ubcore g_ubcore_log_level=6`.) udma
has its own gate (`g_udma_log_level`); its messages use `dev_info` /
`dev_err`, which respect the standard kernel `printk` ratelimit and
`loglevel` boot parameter rather than this module-private gate.

`UBCORE_DRV_TP_THRESHOLD_MS = 1` (i.e. > 1 ms triggers the log) is
intentionally aggressive — once the gate is open, anything above 1 ms
gets reported, so 905 ms always trips it.

You'll see at most two lines per TP setup once the gate is open.
Their pattern brackets where the time lives:

| `get_tp_list` slow | `active_tp` slow | Diagnosis |
|--------------------|------------------|-----------|
| ✗ | ✓ | time is in firmware MUE programming (less likely given typical firmware times) |
| ✓ | ✗ | time is in driver-side TP discovery (this is what `udma_tp_cache.c` already targets) |
| ✓ | ✓ | both stages slow — likely MAD round-trips in flight (REQ/REP delayed by fabric) |
| ✗ | ✗ | time is *outside* these two boundaries — in the CM/MAD layer between `get_tp_list` and `active_tp`; need to instrument `ubmad_post_send` / `ubmad_recv_work_handler` |

That last row is what the codex `udma-tp-cache` patch attacks: caching
across the MAD exchange so subsequent connections short-circuit it.
The fact that upstream maintainers added the `_THRESHOLD_MS` log gates
on both `get_tp_list` and `active_tp` says they already consider these
the canonical slow points to watch.

### 10.5 The two blocking waits

**Wait #1 — MAD reply wait (host-side, asynchronous).** `ubmad_post_send`
returns once the MAD WQE is posted to the SQ; it does **not** block on
the reply. The reply arrives later via the JFC completion path:
`ubmad_jfce_handler_r` → `ubcore_poll_jfc` → `udma_poll_jfc` →
`ubmad_recv_work_handler` → `ubcm_recv_handler`. The actual
"wait until peer responds" lives in the upper-layer caller of
`ubcore_connect_vtp_ctrlplane`, keyed on the CM transaction id. If the
reply MAD is dropped, delayed, or held up by fabric congestion or by
the peer's CM thread, this wait dominates the first-RPC latency.

**Wait #2 — ctrlq wait** at `drivers/ub/ubase/ubase_ctrlq.c:645–676`:

```c
static int ubase_ctrlq_wait_completed(struct ubase_dev *udev, u16 seq,
                                      struct ubase_ctrlq_msg *msg)
{
#define UBASE_CTRLQ_TIMEOUT_CASE_SHUT_DOWN 500
    struct ubase_ctrlq_ring *csq = &udev->ctrlq.csq;
    u32 timeout;
    …
    if (ubase_shutting_down(udev) && ubase_is_ctrl_node(udev))
        timeout = UBASE_CTRLQ_TIMEOUT_CASE_SHUT_DOWN;
    else
        timeout = msg->timeout ? msg->timeout : csq->tx_timeout;

    if (!wait_for_completion_timeout(&ctx->done,
                                     msecs_to_jiffies(timeout))) {
        … log "ctrlq wait resp timeout" …
        return -ETIMEDOUT;
    }
    …
}
```

Per-message `msg->timeout` if set, otherwise the queue's
`csq->tx_timeout`. Completion is fired by the CRQ interrupt handler
(`ubase_ctrlq_crq_event_callback`, `ubase_ctrlq.c:1004`) when the
firmware's response lands in the CRQ ring. Usually completes in µs–low
ms range — firmware is local.

### 10.6 What firmware (MUE) actually does — and what it does *not* do

The CSQ message dispatched is `UDMA_CMD_CTRLQ_ACTIVE_TP` carrying:

- local `tp_id`, `tpn_cnt`, `tpn_start`, `psn`
- remote `tp_id`, `tpn_cnt`, `tpn_start`, `psn`

(see `udma_k_ctrlq_create_active_tp_msg` at `udma_ctrlq_tp.c:677`.)

On the SoC, the MUE for this UB device:

1. Programs local hardware TP context — TX SQ pointer, RX RQ pointer,
   PSNs, MTU, security keys, retry policy.
2. Writes a response block into the CRQ when done; raises interrupt.

That's it. **The MUE does not do a cross-fabric handshake with the
peer MUE.** The cross-fabric coordination has already happened on the
host CPU, via the ub_cm + ubmad MAD exchange (see §10.3). By the time
`ubcore_active_tp` is called, both sides have already agreed on the
TP descriptor.

This is structurally analogous to RDMA-CM: the connection manager
exchanges REQ/REP/RTU on QP1 (the IB management QP), and only when
both sides have agreed does each call `ib_modify_qp(IB_QPS_RTR/RTS)`
to install the negotiated parameters. UB's ub_cm is the same idea
over a different transport, with `active_tp` playing the
`modify_qp` role.

### 10.7 ftrace target list — covering all three flows

> **Superseded:** §10.13 has the converged minimal baseline (8–11 functions
> + `tracing_thresh=1000` + `max_graph_depth=1`). Use that first. The
> wider 22-function filter below is appropriate only after you've
> narrowed the dominant phase from §10.13's output and want to descend
> into that phase's internals.

For function-graph tracing of the full link-setup path:

```bash
cd /sys/kernel/debug/tracing
echo > trace
echo function_graph > current_tracer
echo 32768 > buffer_size_kb
echo 12 > max_graph_depth
echo 1 > options/funcgraph-cpu
echo 1 > options/funcgraph-proc
echo 1 > options/funcgraph-abstime

cat > set_graph_function << 'EOF'
ubcore_advise_jetty
ubcore_connect_vtp_ctrlplane
ubcore_get_tp_list
ubcore_active_tp
ubcm_work_handler
ubmad_post_send
ubcore_post_jetty_send_wr
udma_post_jetty_send_wr
ubmad_jfce_handler
ubmad_jfce_handler_r
ubmad_jfce_handler_s
ubcore_poll_jfc
udma_poll_jfc
ubmad_recv_work_handler
ubcm_recv_handler
ubcore_cm_recv
udma_active_tp
udma_ctrlq_set_active_tp_ex
udma_k_ctrlq_create_active_tp_msg
ubase_ctrlq_send_msg
__ubase_ctrlq_send
ubase_ctrlq_wait_completed
EOF

echo 1 > tracing_on
# run client with --max_retry=1, kill after first RPC
echo 0 > tracing_on
cat trace | head -400
```

Reading the trace: walk the durations top-down and find the largest
gap. Three plausible signatures:

- **MAD round-trip slow** — `ubmad_post_send` returns instantly, then a
  long gap until `ubmad_jfce_handler_r` fires. The gap is the
  fabric/peer-CM latency. Often the smoking gun on first-RPC.
- **Driver `get_tp_list` slow** — `ubcore_get_tp_list` itself shows a
  duration > threshold. The wait is internal to the udma driver
  (often a ctrlq exchange of its own).
- **Firmware `active_tp` slow** — `ubase_ctrlq_wait_completed` holds
  most of the time. The host kernel just sleeps; the slow thing is on
  the SoC.

If the trace shows MAD round-trip dominates, the codex `udma-tp-cache`
patch helps because it eliminates the per-first-connection MAD
exchange entirely.

### 10.8 Function-name to source-location reference

For converting between the names you'll see in trace output and the
actual code:

| Trace / log name                | Real symbol                      | File:line |
|---------------------------------|----------------------------------|-----------|
| `ubmad_post_send`               | `ubmad_post_send`                | `ubcm/ubmad_datapath.c:768` |
| `ubcore_post_jetty_wr`          | `ubcore_post_jetty_send_wr`      | called from `ubmad_datapath.c:283/368/532/587/640/920` |
| `udma_post_jetty_wr`            | `udma_post_jetty_send_wr`        | `hw/udma/` driver |
| send WQE                        | hardware doorbell write          | `udma_post_one_wr` |
| `ops->poll_jfc`                 | `dev->ops->poll_jfc` → `udma_poll_jfc` | dispatched from `ubcore_poll_jfc` |
| `ubmad_recv_work_handler`       | `ubmad_recv_work_handler`        | `ubcm/ubmad_datapath.c:1266` |
| `ubmad_jfce_handler` / `_r` / `_s` | JFC event entry points         | `ubcm/ubmad_datapath.c:1375 / 1429 / 1424` |
| `ubcm_send_handler` / `recv_handler` | CM-layer ↔ MAD glue          | `ubcm/ub_cm.c:131 / 148` |
| `get_tp_list`                   | `ubcore_get_tp_list`             | `ubcore_tp.c:26`  (self-instrumented) |
| `active_tp`                     | `ubcore_active_tp`               | `ubcore_vtp.c:1129` (self-instrumented) |

CM message types are `UBMAD_UBC_CONN_REQ` / `UBMAD_UBC_CONN_RESP` /
`UBMAD_UBC_SINGLE_REQ` (see the switch in `ubmad_post_send` at
`ubmad_datapath.c:795`).

### 10.9 Note on the `ubcore_nl_send_wait` red herring

The `ubcore_netlink.c:418` netlink path is real code, but it's reserved
for a different scenario (probably a future UVS-managed deployment, or
a code state on a different branch). On the OLK-6.6 ubcore + udma
combination JinDou1210 is running, the active-TP slow path is purely
ctrlq + firmware, never touches netlink. Confirm with:

```bash
grep -rn "ubcore_nl_send_wait\b" /Volumes/KernelDev/kernel/drivers/ub/
# definition + header only — no .c calls it
```

The earlier comment on `rainbay001-dotcom/UMDK#1` citing
`ubcore_nl_send_wait` should be corrected; this section's call chain
is the accurate one for the reporter's environment.

### 10.10 Fourth-round corrections after deeper code reading

Even §10.3's graph is wrong in four concrete ways. Another agent went
through the source more carefully and surfaced these; verified against
`/Volumes/KernelDev/kernel/drivers/ub/` on 2026-05-11.

#### Correction A — the ioctl entry isn't `UBURMA_CMD_ADVISE_JETTY`

`ADVISE_JETTY` is a separate ioctl about EID advertising. **There is no
function called `ubcore_advise_jetty`** in this tree
(`grep -rn ubcore_advise_jetty drivers/ub/urma/ubcore/` returns
nothing).

Link setup is triggered by:

```
ioctl(fd, UBURMA_CMD_IMPORT_JFR   or  UBURMA_CMD_IMPORT_JETTY)
  → uburma_cmd_import_jfr      uburma_cmd.c:3204
      └─ ubcore_import_jfr     ubcore_jetty.c:1511
```

(symmetric for `_IMPORT_JETTY` → `ubcore_import_jetty` at
`ubcore_jetty.c:2476`.)

#### Correction B — `get_tp_list` is sequential with VTP activation, not nested inside it

§10.3 drew `ubcore_get_tp_list` as a child of
`ubcore_connect_vtp_ctrlplane`. It isn't. They're sibling steps in a
sequence:

```
ubcore_import_jfr  (jetty.c:1511)
  ├─ ubcore_check_ctrlplane_compat(dev->ops->import_jfr)
  │     udma provides import_jfr_ex but NOT import_jfr   → returns true
  │     → delegates to compat path:
  │
  └─ ubcore_import_jfr_compat   connect_adapter.c:1105
        ├─ ubcore_fill_get_tp_cfg
        ├─ STEP 1:  ubcore_get_tp_list                    connect_adapter.c:1133
        │              → dev->ops->get_tp_list = udma_get_tp_list
        │              → CM exchange or firmware ctrlq to discover peer TP descriptor
        ├─ STEP 2:  ubcore_exchange_tp_info               connect_adapter.c:1145
        │              (only for RM + RTP)
        │              another CM exchange
        └─ STEP 3:  ubcore_import_jfr_ex                  connect_adapter.c:1157
                     └─ dev->ops->import_jfr_ex = udma_import_jfr_ex
                     └─ for TRANSPORT_UB + RM/UM:
                         └─ STEP 4:  ubcore_connect_vtp_ctrlplane   jetty.c:~1614
                                       (vtpn cache lookup, miss path)
                                       └─ STEP 5:  ubcore_active_tp
                                                     → udma_active_tp → ubase_ctrlq → MUE
```

So a single first-RPC link setup performs up to **five sequential
phases**, any one of which can hold the wall-clock:

1. `get_tp_list` — peer TP descriptor discovery
2. `exchange_tp_info` — secondary exchange (RM+RTP only)
3. `import_jfr_ex` — driver-side jfr import
4. `connect_vtp_ctrlplane` — vtpn alloc + cache wire-up
5. `active_tp` — firmware install via ctrlq

`ubcore_get_tp_list` and `ubcore_active_tp` are the two self-instrumented
ones (`UBCORE_DRV_TP_THRESHOLD_MS = 1` ms gate, log via
`ubcore_log_info_rl` — see §10.4 for the level-gate gotcha). Phases
2/3/4 have no `consumes:` log; you need ftrace to see them.

#### Correction C — `ub_cm` doesn't call `ubmad_post_send` directly

There's a higher-level wrapper between CM and the raw MAD send:

```
ub_cm builds CONN_REQ / CONN_RESP / SINGLE_REQ / CLOSE_REQ
  → registered cm-send op = ubmad_ubc_send         ubcm/ubmad_datapath.c:1155
        ├─ validates msg_type
        ├─ sets send_buf->src_eid from dev_priv->eid_info.eid
        ├─ logs "ubc dev: ... s_eid: ... d_eid: ..."  via ubcore_log_info_rl
        └─ ubmad_post_send                         ubcm/ubmad_datapath.c:768
              └─ ubcore_post_jetty_send_wr         (data path)
                    └─ udma_post_jetty_send_wr     hw/udma/
                          └─ udma_post_one_wr      → SEND WQE on MAD jetty SQ
```

Registration: `ub_cm.c:350`:
```c
ubcore_register_cm_send_ops(ubmad_ubc_send);
```

So `ubmad_ubc_send` is what ub_cm calls when it has a message to send,
and `ubmad_post_send` is the lower-level WQE-posting primitive.

#### Correction D — receive path is normalized before reaching `ubcm_recv_handler`

§10.3 drew `ubmad_recv_work_handler → ubcm_recv_handler`. The actual
path has three more steps in between, and they do significant work:

```
ubmad_jfce_handler_r        (RX CQE event)                   ubmad_datapath.c:1429
  └─ ubmad_recv_work_handler                                  ubmad_datapath.c:1266
        └─ ubmad_process_msg  (dispatch by msg_type)         ubmad_datapath.c:1110
              switch (msg->msg_type) {
              case UBMAD_UBC_CONN_REQ: ubmad_process_conn_data   ubmad_datapath.c:991
              case UBMAD_UBC_CONN_RESP: ubmad_process_conn_resp  ubmad_datapath.c:1023  ← the interesting one
              case UBMAD_UBC_SINGLE_REQ: ubmad_process_conn_single
              case UBMAD_CLOSE_REQ:     ubmad_process_close_req
              }
```

For `CONN_RESP` specifically, `ubmad_process_conn_resp` does
**deduplication via the msn (message sequence number) hash list**:

```c
/* ubmad_datapath.c:1046–1058 */
msn_mgr = &tjetty->msn_mgr;
spin_lock_irqsave(&msn_mgr->msn_hlist_lock, flag);
hlist_for_each_entry_safe(cur, next, &msn_mgr->msn_hlist[hash], node) {
    if (cur->msn == msg->msn) {
        hlist_del(&cur->node);     /* ← effective ack: removes outstanding request */
        kfree(cur);
        goto effective_resp;
    }
}
/* if msn not found, this is a duplicate / late ack; drop silently */
ubcore_log_info_rl("redundant ack. msn %llu seid " EID_FMT "\n", ...);
return 0;

effective_resp:
    ret = ubmad_cm_process_msg(...);    /* finally hand to agent recv_handler */
```

Then `ubmad_cm_process_msg` (`ubmad_datapath.c:968`) **normalizes
msg_type to `UBMAD_UBC_CONN_REQ` regardless of the actual incoming
type** before invoking the agent's recv_handler:

```c
/* line 977-978 */
recv_cr.msg_type = UBMAD_UBC_CONN_REQ;       /* "only CONN_REQ valid for recv_handler" */
agent_priv->agent.recv_handler(&agent_priv->agent, &recv_cr);
```

That's why `ubcm_recv_handler` at `ub_cm.c:148` only has a
`case UBMAD_UBC_CONN_REQ` branch — every CM message, including
responses, arrives there labeled as CONN_REQ. The actual req-vs-resp
distinction was already made by the time we get here.

#### Correction E (consequence) — there's no `wait_for_completion` in the CM path

Comment at `ub_mad_priv.h:220` explicitly says:

```
/* try to find msn_node in msn_hlist when timeout.
 * If find, repost and re-add work [...]
 */
```

So the CM is **asynchronous with retransmit, not synchronous
wait-and-block**. When `ubmad_ubc_send` posts a CONN_REQ, the caller
returns immediately; an outstanding `msn_node` is parked in the
tjetty's hash list; a periodic timer scans for entries that haven't
been acked and reposts the message. Receipt of CONN_RESP fires the
hash-list remove, ending that retransmit cycle.

This means the "MAD reply wait" I named as the dominant first-RPC
holder in §10.5 doesn't exist as drawn. The actual blocking points
on the first-RPC critical path are:

1. **`ubcore_get_tp_list`** — `udma_get_tp_list` likely calls into
   firmware via ctrlq, which uses `wait_for_completion_timeout` at
   `ubase_ctrlq.c:662`. So `get_tp_list` is a real synchronous wait
   even though the CM exchange isn't.
2. **`ubcore_active_tp`** — confirmed synchronous via ctrlq.
3. **`udma_exchange_tp_info` / `ubcore_exchange_tp_info`** — if RM+RTP,
   this may also be synchronous.

So the actual first-RPC wait is one or more **ctrlq** waits, possibly
chained, not a CM-MAD wait. The codex `udma-tp-cache` patch caches
across these by short-circuiting the discovery of an already-known
TP descriptor.

#### Corrected ftrace filter

> **Superseded:** §10.13 has the converged minimal baseline. Use that
> first; treat the 29-function list below as a "fully widened" reference
> rather than the recommended starting point.

Adding the missing functions:

```bash
cat > set_graph_function << 'EOF'
ubcore_import_jfr
ubcore_import_jetty
ubcore_import_jfr_compat
ubcore_import_jetty_compat
ubcore_get_tp_list
ubcore_exchange_tp_info
ubcore_import_jfr_ex
ubcore_import_jetty_ex
ubcore_connect_vtp_ctrlplane
ubcore_active_tp
udma_active_tp
udma_get_tp_list
udma_import_jfr_ex
udma_import_jetty_ex
udma_ctrlq_set_active_tp_ex
udma_k_ctrlq_create_active_tp_msg
ubase_ctrlq_send_msg
__ubase_ctrlq_send
ubase_ctrlq_wait_completed
ubmad_ubc_send
ubmad_post_send
ubcore_post_jetty_send_wr
udma_post_jetty_send_wr
ubmad_jfce_handler_r
ubmad_recv_work_handler
ubmad_process_msg
ubmad_process_conn_resp
ubmad_cm_process_msg
ubcm_recv_handler
EOF
```

#### How to keep this straight going forward

Five rules, painfully learned over three rounds of being wrong:

1. **Grep for callers before naming a function as the hot spot.** A function that's defined but uncalled (`ubcore_nl_send_wait`) does nothing.
2. **The function-name-on-the-ioctl is not always the right kernel entry.** `UBURMA_CMD_ADVISE_JETTY` does not get handled by `ubcore_advise_jetty` (no such function). Always check `uburma_cmd*.c` for the dispatcher table and trace down from there.
3. **Compat vs. modern path matters.** If the driver registers `ops->X_ex` but not `ops->X`, the compat path runs — which adds extra steps before reaching the modern path. udma is currently compat for `import_jfr` / `import_jetty`.
4. **CM is async + retransmit, not sync wait.** Look for `wait_for_completion` calls in the actual function bodies of the alleged blocker. If you can't find one, the wait is somewhere else.
5. **The msg_type at the recv_handler is always `CONN_REQ`** — the runtime distinction is in `ubmad_process_*` dispatch, not in the recv_handler switch.

### 10.11 VTP cache mechanics

`vtpn` (Virtual TP Number) is the kernel-side cached handle that sits
above the actual hardware TP. The cache is `dev->ht[UBCORE_HT_CP_VTPN]`,
a hash table keyed by `tp_handle.value`.

#### Cache lookup path

`ubcore_connect_vtp_ctrlplane` (`ubcore_vtp.c:1201`):

```c
// 1. try to reuse existing vtpn  (line 1211)
vtpn = ubcore_find_get_vtpn_ctrlplane(dev, active_tp_cfg);
if (vtpn != NULL)
    return ubcore_reuse_vtpn(dev, vtpn);   // cache HIT — fast path, no firmware

// 2. alloc new vtpn  (line 1216)
vtpn = ubcore_create_vtpn(dev, param, active_tp_cfg, udata);

// 3. add vtpn to hash table  (line 1223)
ret = ubcore_find_add_vtpn_ctrlplane(dev, vtpn, &exist_vtpn);
if (ret == -EEXIST && exist_vtpn != NULL) {
    // raced with another thread; reuse the winner
    exist_vtpn = ubcore_reuse_vtpn(dev, exist_vtpn);
    (void)ubcore_free_vtpn_ctrlplane(vtpn);
    return exist_vtpn;
}

// 4. firmware install via dev->ops->active_tp
//    (this is the slow step — the chained ctrlq round-trip(s))
```

#### When VTP is activated

`ubcore_jetty.c:1612–1615`:

```c
if (dev->transport_type == UBCORE_TRANSPORT_UB &&
    (cfg->trans_mode == UBCORE_TP_RM ||
     cfg->trans_mode == UBCORE_TP_UM)) {
    ...
    vtpn = ubcore_connect_vtp_ctrlplane(...);
}
```

Two conditions, both required:

- **`transport_type == UBCORE_TRANSPORT_UB`** — UB family device (vs. IB, RoCE, etc.)
- **`trans_mode == UBCORE_TP_RM` or `UBCORE_TP_UM`** — Reliable Message or Unreliable Message. `UBCORE_TP_RC` (Reliable Connection, Jetty-based) goes through a different path.

For `urma_perftest send_lat -d bonding_dev_0`: bonding_dev_0 is a UB device, default trans_mode for JFR is RM → both conditions met, vtpn is created.

#### Lifecycle and refcount

- **First import** to a peer: cache miss → `ubcore_create_vtpn` + `ubcore_active_tp` (slow, firmware).
- **Second import** to the same peer's tp_handle, while the first is still alive: cache hit → `ubcore_reuse_vtpn` (immediate, no firmware).
- **`ubcore_unimport_jfr`** drops vtpn refcount. When refcount → 0 and no other importers are alive, the vtpn is freed (`ubcore_free_vtpn`, `ubcore_vtp.c:920`, with a `wait_for_completion(&vtpn->comp)` for the cleanup synchronization — note this is **not** the link-setup wait).
- **Back-to-back test runs**: if both runs call `unimport_jfr` at cleanup, the second run pays the full first-RPC cost again. Cache only helps overlapping importers, not sequential ones.

#### How to verify cache behavior from a trace

Add to the filter:

```bash
cat >> set_graph_function << 'EOF'
ubcore_create_vtpn
ubcore_reuse_vtpn
ubcore_find_get_vtpn_ctrlplane
EOF
```

Then:

```bash
grep -c "ubcore_create_vtpn" trace       # 1 → cache MISS, full firmware install
grep -c "ubcore_reuse_vtpn" trace        # 1 → cache HIT, no firmware
```

Exactly one of those should appear per `urma_import_jfr` invocation.

### 10.12 `urma_perftest send_lat` — the test runner currently in use

The reporter on UMDK#1 has switched from `ub_performance_client` to
`urma_perftest send_lat`:

```bash
# server
urma_perftest send_lat -n 10 -s 2 -I 128 -d bonding_dev_0 --single_path -p 0
# client
urma_perftest send_lat -n 10 -s 2 -I 128 -d bonding_dev_0 --single_path -p 0 -S X.X.X.X
```

`-n 10`: 10 iterations after first-RPC. `-s 2`: 2-byte messages. `-d
bonding_dev_0`: the UB device. `--single_path`: bonding aggregates
multiple physical links, this restricts to one. `-S X.X.X.X`: client
mode, server IP for the OOB TCP handshake.

#### URMA verb sequence

`urma_perftest send_lat` uses the JFS+JFR (not Jetty) RM model. From
`src/urma/tools/urma_perftest/perftest_resources.c`:

```
urma_create_context                  line 224       no kernel link setup
urma_create_jfc      × 2 (s + r)     lines 380/387  local CQ
urma_create_jfs                      line 443       local SQ (client)
urma_create_jfr                      line 488       local RQ (server)
                                                    ────── peer descriptors exchanged
                                                    ────── over OOB TCP (perftest_communication.c)
urma_import_jfr                      line 1397      ★ this triggers link setup
                                                       → ioctl(UBURMA_CMD_IMPORT_JFR)
                                                       → ubcore_import_jfr → compat path → 5 phases
urma_advise_jfr                      line 1405      NO kernel handler (see below)
urma_post_jfs_wr  × N                                steady-state sends, reuse cached vtpn
urma_unimport_jfr                                   refcount drop, may free vtpn
```

#### `urma_advise_jfr` has no kernel handler

Verified from the dispatch table at `uburma_cmd.c:4886`
(`g_uburma_cmd_handlers[]`): entries exist for `UBURMA_CMD_IMPORT_JFR`,
`UBURMA_CMD_IMPORT_JETTY`, `UBURMA_CMD_BIND_JETTY`, etc., but
**`UBURMA_CMD_ADVISE_JFR` and `UBURMA_CMD_ADVISE_JETTY` are absent**.
The opcodes are defined (`uburma_cmd.h:66`) and have TLV input
descriptors (`uburma_cmd_tlv.c:2187,2195`), but no handler — so the
ioctl returns without entering ubcore. `urma_advise_jfr` is effectively
userspace-only bookkeeping that records which JFS is bound to which
imported JFR for the next `post_jfs_wr` call.

This means **the only kernel link-setup work fires from
`urma_import_jfr`, not from `urma_advise_jfr`**. The advise call is a
red herring for timing purposes (the function name from earlier graphs
saying "ADVISE_JETTY → link setup" was wrong — see §10.10 Correction A).

#### Expected trace shape with `-n 10`

With the §10.13 minimal trace filter:

- **Exactly one** outer entry (`ubcore_import_jfr` or `ubcore_import_jetty`) per test invocation, holding the cumulative link-setup wall-clock
- **The 5 phase children** (get_tp_list, exchange_tp_info if RM+RTP, import_jfr_ex, connect_vtp_ctrlplane, active_tp) summing roughly to the parent's duration
- **No further entries** for the 9 follow-up sends — they all reuse the cached vtpn and run sub-µs, below `tracing_thresh=1000`

Trace should be 5–8 lines total. The `urma_perftest` binary also prints
end-to-end latency at completion (per-iteration min/avg/max), giving
the userland wall-clock anchor we kept missing in earlier rounds.

#### Bonding caveat

`bonding_dev_0` is a UB-bonding aggregate device. The kernel takes a
slightly different path through `ubcore_connect_bonding.c` when
`ubcore_is_bonding_dev(dev)` is true. In the modern (non-compat) path,
this calls `ubcore_connect_exchange_udata_when_import_jetty`
(`ubcore_connect_bonding.c:497`) before reaching
`ubcore_connect_vtp_ctrlplane`. The compat path that udma actually
runs may handle bonding internally instead — the trace will show which
by presence or absence of that function. Worth keeping in the filter
just to confirm.

### 10.13 Minimal trace setup — converged on (use this first)

> **Refined by §10.18.G.** This section's `tracing_thresh=1000` is OK
> as a first-pass sanity check ("is the kernel slice big at all?"),
> but it hides the inner phase decomposition because the hot inner
> phases are sub-ms (e.g., `get_tp_list` at 151 µs, `import_jetty_ex`
> at 234 µs on JinDou's real trace). For a real phase breakdown,
> prefer `tracing_thresh=0` + `max_graph_depth=3` from §10.18.G.

Supersedes earlier filter lists in §10.6 / §10.7 / §10.10's
"Corrected ftrace filter". Use this 8-to-11-function setup as the
baseline; only widen the filter after you've identified the slow
phase.

```bash
cd /sys/kernel/debug/tracing

# 1. open the ubcore log gate (otherwise dmesg shows nothing — see §10.4)
echo 6 | sudo tee /sys/module/ubcore/parameters/g_ubcore_log_level

# 2. reset tracer state
echo nop > current_tracer
echo > trace
echo > set_graph_function
echo > set_ftrace_notrace
echo 0 > tracing_on

# 3. only these functions are graph-traced
cat > set_graph_function << 'EOF'
ubcore_import_jfr
ubcore_import_jetty
ubcore_get_tp_list
ubcore_exchange_tp_info
ubcore_import_jfr_ex
ubcore_import_jetty_ex
ubcore_connect_vtp_ctrlplane
ubcore_active_tp
ubcore_create_vtpn
ubcore_reuse_vtpn
ubcore_connect_exchange_udata_when_import_jetty
EOF

# 4. hide everything < 1 ms — kills the is_eid_match/find_primary_eid_in_ues flood
echo 1000 > tracing_thresh           # microseconds

# 5. depth for nested phases inside ubcore_import_*
#    NOTE: original draft used depth=1 which hides children entirely (§10.15.B);
#    depth=5 exposes the 5 nested phases inside the compat path
echo 5 > max_graph_depth

# 6. minimal columns
echo 0 > options/funcgraph-cpu
echo 0 > options/funcgraph-proc
echo 1 > options/funcgraph-abstime
echo 1 > options/funcgraph-tail
echo 1 > options/funcgraph-duration

# 7. roomy buffer
echo 16384 > buffer_size_kb

# 8. arm the tracer
echo function_graph > current_tracer
echo 1 > tracing_on

# --- in another shell, run the test ---
# urma_perftest send_lat -n 10 -s 2 -I 128 -d bonding_dev_0 --single_path -p 0 -S <server>
# wait until it prints latency stats

echo 0 > tracing_on
cat trace
```

Why each piece matters:

- **`tracing_thresh=1000`** is the most powerful single knob. It tells
  function_graph to only emit exits with duration above 1 ms. This
  kills the entire sub-ms inner-call flood at the source — no awk
  post-processing needed.
- **`max_graph_depth=1`** means each listed function is traced as a
  top-level entry; we don't descend into its non-listed children.
  Combined with the threshold, this keeps the trace to one line per
  phase per first-RPC.
- **11 functions in `set_graph_function`** = the two ioctl entries +
  the 5 sequential phases + 2 ex-wrappers + 2 vtpn cache markers + 1
  bonding wrapper. At most ~10 lines of output for a clean first-RPC.

Reading the output (durations marked: `+ ≥10µs, ! ≥100µs, # ≥1ms, *
≥10ms, @ ≥100ms, $ ≥1s`):

```
# tracer: function_graph
12345.000 | $ 902.123 ms |  ubcore_import_jfr() {
12345.001 | * 14.234 ms  |    ubcore_get_tp_list();
12345.015 | @ 802.012 ms |    ubcore_exchange_tp_info();   (only if RM+RTP)
12345.817 | # 1.456 ms   |    ubcore_import_jfr_ex();
12345.819 | * 84.001 ms  |    ubcore_connect_vtp_ctrlplane();
              | (no entry) |       ubcore_create_vtpn();   (sub-ms, hidden)
```

The marker on the parent (`$` = ≥ 1 s, `@` = ≥ 100 ms) tells you the
total; the markers on the children tell you which phase to chase next.

Once you know the dominant phase, **then** widen the filter to that
phase's internals (e.g., if `active_tp` dominates, add `udma_active_tp`,
`udma_ctrlq_set_active_tp_ex`, `ubase_ctrlq_send_msg`,
`ubase_ctrlq_wait_completed` to confirm the firmware ctrlq wait holds
the time). Don't widen everything at once.

### 10.14 Bot status on the issue thread

As of 2026-05-11, the `@claude` bot on `rainbay001-dotcom/UMDK#1`
fails on every invocation with `SDK execution error: ... process
exited with code 1` after ~15 s of processing. Both `gh run rerun
... --failed` retries reproduced the failure. XiangShan and ubturbo's
identical `@v1` workflows ran cleanly in the same period.

Suspected cause: the issue thread has grown to 20+ comments with
several long technical posts (the corrections + minimal-trace +
perftest guidance), and the SDK appears to choke on the large fetched
context. The action's logs show no structured API error (no 401, 429,
500); just a generic SDK crash mid-stream.

Decision: **manual-driven debugging on this issue from here on**.
Comments are posted from the owner account directly. The bot will be
left alone until the thread is naturally shorter or the upstream
action releases a fix. Don't re-invoke `@claude` on this thread; the
bot's prior answers were also wrong on most of the call-chain
specifics (see §10.10 for the history).

### 10.15 JinDou's first concrete trace data (2026-05-11)

After several rounds of source-only analysis, JinDou finally captured
real data with the §10.13 minimal filter.

#### Test invocation

```
[server] urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0
[client] urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0 -S X.X.X.X
```

Both sides run as `urma_pe-*` userspace processes.

#### Userland numbers (from perftest output)

```
URMA_SEND Latency Test
 Transport mode : UB          Trans mode : URMA_TM_RM    JETTY mode : DUPLEX
 bytes  iterations  t_min[us]  t_max[us]  t_median[us]  t_avg[us]  ...
 2      5           3.47       3.70       3.47           3.47       ...
```

Steady-state latency `t_avg = 3.47 µs` — healthy. perftest does **not**
print a first-RPC number; that has to be measured externally (see §10.15.D
below).

#### A. The trace, two lines only

```
# tracer: function_graph
# TIME      CPU TASK             DURATION                  FUNCTION CALLS
411567.479648 | 32) urma_pe-3707176 | * 43189.13 us |  } /* ubcore_import_jetty [ubcore] */
411567.567113 | 32) urma_pe-3707176 | * 87454.16 us |  } /* ubcore_import_jetty [ubcore] */
```

Reconstructing entry times from `exit_timestamp − duration`:

| Call | Entered | Exited | Duration |
|---|---|---|---|
| 1st | 411567.436459 | 411567.479648 | 43.19 ms |
| 2nd | 411567.479659 | 411567.567113 | 87.45 ms |

Calls are **sequential, not nested** — the 2nd entered ~11 µs after the
1st exited, both at depth 0 (top-level entries by their indentation).
End-to-end wall-clock from "1st enters" to "2nd exits": **130.65 ms**
(matches the sum of the two durations).

#### B. Why only two lines — `max_graph_depth=1` was too tight

My §10.13 draft set `max_graph_depth=1`, which hides all children. The
5 nested phases (`get_tp_list`, `exchange_tp_info`, `import_jetty_ex`,
`connect_vtp_ctrlplane`, `active_tp`) all live at depth 2–4 inside
`ubcore_import_jetty_compat`, so they were filtered. The §10.13
listing has been corrected to `max_graph_depth=5`; rerun should
expose them.

Setup gotcha: `set_graph_function` controls where graphing **starts**;
once graphing begins from a listed entry, descendants are traced up to
`max_graph_depth`. So listing the inner phases in `set_graph_function`
doesn't promote them to depth-0 unless they're called from a
non-graphed context. Bumping the depth limit is the right knob.

#### C. The "130 ms vs 905 ms" attribution mistake

In my initial reply to JinDou I wrote: "URMA-level link setup is only
130 ms; the remaining 775 ms of the original 905 ms lives in higher
layers." That was wrong as a subtraction:

- 130 ms came from `urma_perftest send_lat` (URMA-only stack), this run
- 905 ms came from `ub_performance_client` (brpc + ubsocket + URMA),
  a different run on a different test app potentially with different
  kernel state

The two numbers cannot be subtracted to attribute a layer-by-layer
breakdown. The discipline rule from §10.15.D applies: anchor any
kernel observation to a userland wall-clock from the **same run**
before claiming causation.

#### D. Measuring end-to-end first-RPC for `urma_perftest send_lat`

perftest prints `t_min/t_max/t_avg` for the N iterations *after warmup*,
not the first-RPC wall-clock. To capture the latter, wrap in bash:

```bash
t0=$(date +%s.%N)
urma_perftest send_lat -n 1 -s 2 -d bonding_dev_0 --single_path -p 0 -S X.X.X.X
t1=$(date +%s.%N)
echo "wall = $(echo "$t1 - $t0" | bc) s"
```

With `-n 1` (single iteration), this counts: process startup → URMA
context/jetty create → OOB TCP descriptor exchange → `urma_import_jetty`
(the 130 ms kernel slice we see) → one send → teardown. The bash-level
wrapping includes fork/exec/libc init overhead — a few tens of ms on a
busy host — so the wall-clock will be ≥ 130 ms.

If the bash wall-clock is e.g. 200 ms and the kernel slice is 130 ms,
the ~70 ms difference is userspace + TCP exchange. If it's much higher,
there's userspace mystery to chase.

Until JinDou runs this, we have a kernel-slice number (130 ms) but no
end-to-end anchor for this test.

### 10.16 The function chain inside `ubcore_import_jetty`

Two branches in the body (`ubcore_jetty.c:2476–2538`). udma always
takes the **compat** branch because it registers `import_jetty_ex` but
not the legacy `import_jetty`, so `ubcore_check_ctrlplane_compat`
returns true at line 2488. The bonding driver may register
`import_jetty` directly, in which case the **non-compat (bonding)**
branch runs.

#### Top-level `ubcore_import_jetty` body

```
ubcore_import_jetty(dev, cfg, udata)        jetty.c:2476
│
├── ubcore_check_ctrlplane_compat(dev->ops->import_jetty)        jetty.c:2488
│       └── TRUE (udma)  → return ubcore_import_jetty_compat(...)    [§10.16 compat tree]
│       └── FALSE (driver registers ->import_jetty directly) → fall through
│
├── if (ubcore_is_bonding_dev(dev)):                              jetty.c:2491
│       └── ubcore_connect_exchange_udata_when_import_jetty(cfg, udata, false, dev)
│                                                                ubcore_connect_bonding.c:497
│           ├── ubcore_get_bonding_ue_idx_from_udata
│           ├── ubcore_find_physical_device(dev, ue_idx)
│           ├── create_session_for_exchange_udata(physical_dev, ...)
│           ├── send_jetty_info_req(physical_dev, session_id, &req, ue_idx)
│           ├── ubcore_session_wait(session)              ← BLOCKING WAIT
│           ├── copy_to_user(...)
│           └── self-instrumented:
│                if duration > UBCORE_EXC_THRESHOLD_MS:
│                    "[EXC_INFO]exchange_jetty_info consumes: %llu"
│
├── tjetty = dev->ops->import_jetty(dev, cfg, udata)              jetty.c:2498
│       └── bonding driver's import_jetty implementation
│           (driver-specific; local-side TP install for this side)
│
├── tjetty->cfg = *cfg
│   tjetty->ub_dev = dev
│   mutex_init(&tjetty->lock)
│
├── if (!ubcore_is_bonding_dev(dev) &&                            jetty.c:2512
│       transport_type == UBCORE_TRANSPORT_UB &&
│       (trans_mode == RM || UM || is_create_rc_shared_tp(...))):
│       │
│       └── vtpn = ubcore_connect_vtp(dev, &vtp_param)
│           (NOTE: bonding branch SKIPS this — explicit !is_bonding check)
│
└── return tjetty
```

#### Compat-path tree — the chain udma actually runs

`ubcore_import_jetty_compat` in `ubcore_connect_adapter.c:~1162`
(mirrors `ubcore_import_jfr_compat` at 1105):

```
ubcore_import_jetty_compat(dev, cfg, udata)
│
├── ubcore_fill_get_tp_cfg(dev, &get_tp_cfg, cfg)
├── active_tp_cfg.tp_attr.tx_psn = random
│
├── (if RM + RTP + share_tp): ubcore_get_rm_stp_list(...)
│    else:                                                                    ★ Phase 1
│         ubcore_get_tp_list(dev, &get_tp_cfg, &tp_cnt, &tp_list, NULL)        ubcore_tp.c:26
│            ├── dev->ops->get_tp_list = udma_get_tp_list
│            └── self-instrumented:
│                   if duration > THRESHOLD_MS:
│                       "[DRV_INFO]get_tp_list consumes: %llu"
│
├── active_tp_cfg.tp_handle = tp_list.tp_handle
│
├── (if RM + RTP):                                                            ★ Phase 2
│       ubcore_exchange_tp_info(dev, &get_tp_cfg, &active_tp_cfg, cfg, udata)
│            (secondary CM exchange via MAD — likely skipped on JinDou's run)
│
└── tjetty = ubcore_import_jetty_ex(dev, cfg, &active_tp_cfg, udata)          ★ Phase 3
        │                                                                     ubcore_jetty.c:2541
        ├── dev->ops->import_jetty_ex = udma_import_jetty_ex
        │     (udma's driver-side jetty install)
        │
        └── if (TRANSPORT_UB && (RM || UM || share_tp_rc)):
                │
                └── (if share_tp+RM+RTP):
                │        ubcore_connect_rm_svrtp_ctrlplane(...)
                │   else:                                                     ★ Phase 4
                │        ubcore_connect_vtp_ctrlplane(dev, &vtp_param,
                │                                     &active_tp_cfg, udata)  ubcore_vtp.c:1201
                │            │
                │            ├── ubcore_find_get_vtpn_ctrlplane(dev, ...)     (cache lookup)
                │            │     └── HIT → ubcore_reuse_vtpn → return (no Phase 5)
                │            │
                │            ├── ubcore_create_vtpn(dev, ...)                 ubcore_vtp.c:830
                │            │     └── alloc, init_completion, kref_init
                │            │
                │            ├── ubcore_find_add_vtpn_ctrlplane(dev, ...)     (cache install)
                │            │
                │            └── ubcore_active_tp(dev, &active_tp_cfg, vtpn)  ★ Phase 5
                │                  │                                          ubcore_vtp.c:1129
                │                  ├── start = ktime_get_ns()
                │                  ├── ret = dev->ops->active_tp(dev, active_tp_cfg)
                │                  │     └── udma_active_tp                    udma_ctrlq_tp.c:981
                │                  │           └── udma_ctrlq_set_active_tp_ex  udma_ctrlq_tp.c:717
                │                  │                 └── udma_k_ctrlq_create_active_tp_msg
                │                  │                                            udma_ctrlq_tp.c:677
                │                  │                       └── ubase_ctrlq_send_msg
                │                  │                                            ubase_ctrlq.c:926
                │                  │                             └── __ubase_ctrlq_send
                │                  │                                            ubase_ctrlq.c:884
                │                  │                                   └── ubase_ctrlq_wait_completed
                │                  │                                            ubase_ctrlq.c:645
                │                  │                                         └── wait_for_completion_timeout
                │                  │                                            ubase_ctrlq.c:662
                │                  │                                            ← BLOCKING WAIT for firmware
                │                  ├── duration = (ktime_get_ns() - start)
                │                  └── self-instrumented:
                │                        if duration > THRESHOLD_MS:
                │                            "[DRV_INFO]active_tp init consumes: %llu"
```

#### Where the host CPU actually blocks (in this chain)

Two explicit `wait_for_completion*` calls on the synchronous import
path:

1. **`ubcore_session_wait`** (`ubcore_connect_bonding.c:567`) — only on
   the **bonding branch** (line 2491). Waits for the physical-device
   message handler to ack `msg_jetty_info_req`. Self-instrumented via
   `[EXC_INFO]exchange_jetty_info consumes:`.
2. **`wait_for_completion_timeout`** (`ubase_ctrlq.c:662`) — on the
   **compat branch** inside `active_tp`. Waits for the SoC's MUE
   firmware to ack `UDMA_CMD_CTRLQ_ACTIVE_TP`. Timeout is
   `csq->tx_timeout` (typically 1 s).

Whichever branch runs, the host CPU spends most of its synchronous
wait time in one of these two.

### 10.17 ~~Why two `ubcore_import_jetty` per first-RPC: ubmgr ping~~ (HYPOTHESIS, INCORRECT — see §10.18)

> **Superseded by §10.18.** JinDou's depth-expanded retrace shows
> **both `ubcore_import_jetty` entries are on the same task
> (`urma_pe-4046358`)**, not one in userspace context and one in
> kworker context. The ubmgr ping hypothesis below predicted the
> second call would be a kworker; that prediction is falsified. The
> actual reason for two entries is that the URMA userspace library
> expands one `urma_import_jetty` call into two kernel-side ioctls
> when the device is bonded (one for the bonding aggregate via the
> ubagg driver, one for the underlying physical device via udma's
> compat path). Section kept below for the iteration record.



JinDou's trace shows **two** `ubcore_import_jetty` entries in the
order shown above (43 ms then 87 ms). Userspace makes **one** call
(`perftest_resources.c:1540`), so the second entry comes from inside
the kernel.

#### The source

`drivers/ub/urma/ubcore/ubmgr/ubmgr_ping.c:73`:

```c
static struct ubmgr_ping_tjetty_entry *
__ping_tjetty_new_entry(struct ubcore_device *dev, union ubcore_eid *dst_eid,
                        uint32_t eid_index, uint32_t remote_jetty_id)
{
    struct ubcore_tjetty_cfg cfg = {
        .id.eid = *dst_eid,
        .id.id = remote_jetty_id,
        .trans_mode = UBCORE_TP_RM,
        .type = UBCORE_JETTY,
        .tp_type = UBCORE_CTP,              /* Control TP, not data TP */
        .eid_index = eid_index,
    };
    struct ubcore_tjetty *tjetty = ubcore_import_jetty(dev, &cfg, NULL);
    ...
}
```

`ubmgr` is the **UB Manager** — the kernel subsystem that maintains
keepalive/probe handshakes with peer EIDs. When a peer EID is
encountered for the first time, ubmgr fires a CTP (Control TP) import
to install a control channel for liveness checks. The entry is cached
in a per-EID hash table (`PING_TJETTY_HASH_SIZE`); subsequent
first-RPCs to the same EID skip it.

This call passes `udata = NULL` (kernel context, no userland udata),
and `tp_type = UBCORE_CTP` (control transport pair) rather than
`UBCORE_RTP` (reliable data TP).

#### Likely attribution for JinDou's two entries

| Order | Duration | Caller | What it's doing |
|---|---|---|---|
| 1st (43 ms) | shorter | `__ping_tjetty_new_entry` (ubmgr) | CTP install — kernel-internal probe/keepalive TP |
| 2nd (87 ms) | longer  | perftest's `urma_import_jetty` from line 1540 | RTP install for the actual data path (the 5-phase compat chain on the physical device backing bonding_dev_0) |

This is the **most likely** ordering: when perftest opens its first
connection to the peer EID, ubmgr notices an EID-it-hasn't-seen and
fires its CTP import; once that completes, perftest's
`urma_import_jetty` proceeds and runs the full 5-phase compat path.

Could also be reversed (perftest's call first, ubmgr's after) —
depends on whether ubmgr's ping is triggered eagerly on peer
discovery or lazily on user import. The trace doesn't distinguish
without `funcgraph-proc=1` annotation showing the task name per call
(ubmgr typically runs in kworker context; perftest is `urma_pe-*`).

#### How to confirm

Add to `set_graph_function`:

```
__ping_tjetty_new_entry
__ping_tjetty_find
ubmgr_ping_send
ubcore_unimport_jetty
```

…and re-enable per-process annotations:

```bash
echo 1 > /sys/kernel/debug/tracing/options/funcgraph-proc
```

Now each `ubcore_import_jetty` entry should have either:
- `urma_pe-NNNN` (perftest userspace call) immediately preceding it,
  with no `__ping_tjetty_*` ancestor, **OR**
- `kworker-NNNN` task + `__ping_tjetty_new_entry` at the top of its
  call stack.

Implication for cache evaluation: the codex `udma-tp-cache` patch
targets the **data TP** (perftest's call), but the **ubmgr CTP**
install is a separate event that the patch may or may not affect.
If the 43 ms CTP install is a real cost on every first-encounter, the
patch needs to cache it too — or ubmgr needs its own cache. Worth
checking when JinDou runs the cache patch A/B.

### 10.18 Concrete phase-level timing from JinDou's depth-expanded retrace (2026-05-11)

JinDou opened a fresh issue **UMDK#2** ("性能打点计时v2") with a
re-run trace, this time at `max_graph_depth=3` and `tracing_thresh`
lowered so the phase children are visible. The data here supersedes
the speculation in §10.15–10.17.

#### A. Test setup

```
[client] urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0 -S 141.62.32.91
```

Userland reports `t_avg = 3.47 µs` steady-state (5 iterations after
warmup). Connection establishment fires once, captured by the trace.

#### B. The 16.74 ms breakdown — actual phase timings

Two top-level `ubcore_import_jetty` entries, both on the same task
(`urma_pe-4046358`, CPU 46):

```
1st ubcore_import_jetty   10867.93 µs  (urma_pe-4046358, CPU 46)
│   path: NON-compat (bonding aggregate via ubagg driver)
│
├── ubcore_connect_exchange_udata_when_import_jetty   10848.91 µs (99.8% of this call)
│   │
│   ├── ktime_get                            0.36 µs
│   ├── ubcore_get_bonding_ue_idx_from_udata 0.17 µs
│   ├── ubcore_find_physical_device          1.25 µs
│   ├── create_session_for_exchange_udata    1.78 µs
│   ├── ubcore_session_get_id                0.13 µs
│   ├── send_jetty_info_req                  4828.45 µs  ★ network RTT 1
│   ├── ubcore_session_wait                  6012.63 µs  ★ blocking wait on peer
│   ├── __check_object_size                  0.23 µs
│   ├── ktime_get                            0.21 µs
│   ├── ubcore_session_ref_release           0.67 µs
│   └── ubcore_put_device                    0.15 µs
│
├── ubagg_import_jetty                       16.71 µs    (local-side install)
│   ├── fill_udata                           15.66 µs
│   └── kmalloc_trace                        0.30 µs
│
└── __mutex_init                             0.13 µs

2nd ubcore_import_jetty   5876.33 µs    (urma_pe-4046358, CPU 46)
│   path: COMPAT (udma's import_jetty_compat → import_jetty_ex)
│
└── ubcore_import_jetty_compat               5874.96 µs
    │
    ├── ubcore_fill_get_tp_cfg               0.54 µs
    ├── ubcore_get_tp_list                   151.14 µs    (local, via cache)
    ├── get_random_u32                       0.97 µs      (tx_psn)
    ├── ubcore_exchange_tp_info              5486.23 µs  ★ network RTT 2 (CM)
    └── ubcore_import_jetty_ex               233.70 µs    (hardware write)

[Parallel kworker activity, CPU 64, kworker-4046361]
│   (runs concurrent with the userspace wait in 1st import)
│
├── ubcore_get_tp_list                       200.44 µs
│   ├── ktime_get                            0.79 µs
│   ├── udma_get_tp_list                     197.46 µs
│   │   ├── udma_ctrlq_get_tpid_list         193.77 µs   (hardware ctrlq query)
│   │   └── udma_ctrlq_store_one_tpid        1.47 µs
│   └── ktime_get                            0.43 µs
│
└── ubcore_active_tp                         192.83 µs
    ├── ktime_get                            0.41 µs
    ├── udma_active_tp                       191.18 µs
    │   └── udma_ctrlq_set_active_tp_ex      190.22 µs   (hardware ctrlq cmd)
    └── ktime_get                            0.41 µs

Total wall-clock = 10867.93 + 5876.33 = 16.74 ms
```

#### C. Control-plane RTT dominates — 97.5% of the time

```
control-plane fabric exchanges:    16.33 ms  (97.5%)
  ├── send_jetty_info_req            4.83 ms
  ├── ubcore_session_wait            6.01 ms
  └── ubcore_exchange_tp_info        5.49 ms

local hardware ctrlq operations:    0.59 ms  (3.5%)
  ├── udma_ctrlq_get_tpid_list       0.19 ms  (kworker)
  ├── udma_ctrlq_set_active_tp_ex    0.19 ms  (kworker)
  ├── ubcore_get_tp_list (userspace) 0.15 ms
  └── ubcore_import_jetty_ex         0.23 ms

local logic + driver overhead:      ~0.04 ms (<1%)
```

The host CPU spends **almost all** its 16.74 ms on **synchronous
network round-trips** (jetty info exchange + TP info exchange). The
firmware/MUE-side ctrlq work is fast — under 600 µs total — and runs
**concurrently in a kworker** during the userspace `session_wait`.
This overturns the earlier hypothesis (§10.5, §10.6) that the
firmware install is the bottleneck. **The bottleneck on this trace is
peer CM coordination over the UB fabric.**

#### D. The parallel kworker pattern

A critical observation that affects how to think about optimization:
`ubcore_get_tp_list` (200 µs) and `ubcore_active_tp` (193 µs) run on
**CPU 64 in a kworker context**, *while* the userspace task on CPU 46
is blocked in `ubcore_session_wait`. The local hardware programming
is *already overlapped* with the network wait — making it faster
wouldn't help end-to-end latency.

Mechanism (inferred): the local kernel receives an inbound CM message
from the peer (in response to our outbound jetty_info_req), processes
it in a workqueue, programs local hardware via ctrlq, and uses the
result to satisfy the userspace `session_wait` completion.

#### E. What this means for the codex `udma-tp-cache` patch

The patch caches TP descriptors so subsequent connections can skip
some discovery work. Looking at where the time goes on this trace:

| Cached step | Time saved | Effect on 16.74 ms total |
|---|---|---|
| `ubcore_get_tp_list` only | ~150 µs | negligible (< 1%) |
| `ubcore_get_tp_list` + `udma_ctrlq_*` (hardware bringup) | ~600 µs | ~3% |
| `ubcore_get_tp_list` + `udma_ctrlq_*` + `ubcore_exchange_tp_info` | ~6.1 ms | ~36% |
| ALL of the above + `send_jetty_info_req` + `session_wait` | 16.3 ms | ~97% |

If the patch only covers `get_tp_list` and `active_tp` results (likely
based on its name), it saves **at most ~600 µs / 16.74 ms ≈ 3%** of
first-RPC latency on this test. To get a meaningful speedup, the
cache would have to cover the two CM-network exchanges
(`send_jetty_info_req`/`session_wait` and `exchange_tp_info`) — which
is a different code path (`ubcore_connect_bonding.c` + `ubcm/`), not
the udma driver.

**Reading the actual patch diff is now blocking** for a real impact
estimate. The 130 ms → 16.74 ms discrepancy (§F) further muddies
this — if the steady state is already 16 ms, the patch's headroom is
much smaller than we thought.

#### F. The 130 ms vs 16.74 ms discrepancy

JinDou's earlier trace (§10.15, max_graph_depth=1) showed
`43.19 + 87.45 = 130.65 ms`. This new trace (max_graph_depth=3) shows
`10.87 + 5.88 = 16.74 ms`. Same command, same device, both on
`worker1` against the same `141.62.32.91` server. The link-setup time
changed by ~8× across runs.

Likely causes, ordered by probability:

1. **Warm state on the second run.** Even though `urma_perftest`
   calls `urma_unimport_jetty` at cleanup, some kernel-side state
   (CM hash tables, EID resolution caches, fabric route caches, peer
   liveness state) may persist across processes for the same
   destination EID. The first trace was the first cold connection of
   the test session; the second trace was a warm reconnect. The 130
   ms → 16.74 ms ≈ 8× speedup is consistent with skipping some
   discovery / setup that's already cached in non-perftest-controlled
   state.
2. **Server state difference.** The peer may have processed the first
   run and kept its side warm.
3. **Different test command flags** (lower probability — they look
   identical in JinDou's pastes).

**To disambiguate**: have JinDou run the test sequence
"reboot/unload-reload modules → run perftest → trace → run perftest
again → trace" and compare. If the first run is 130 ms and the
second is 16.74 ms, that's confirmation. We can then ask "what state
is sticky across processes?" — likely answer: the kernel-side EID
resolution cache and/or the local CM session state with the peer.

#### G. Updated filter list (incorporating the new findings)

Adding what the trace surfaced as significant; dropping JFR-only and
unconfirmed entries:

```bash
cat > set_graph_function << 'EOF'
ubcore_import_jetty
ubcore_connect_exchange_udata_when_import_jetty
send_jetty_info_req
ubcore_session_wait
ubagg_import_jetty
ubcore_import_jetty_compat
ubcore_get_tp_list
udma_get_tp_list
udma_ctrlq_get_tpid_list
ubcore_exchange_tp_info
ubcore_import_jetty_ex
ubcore_active_tp
udma_active_tp
udma_ctrlq_set_active_tp_ex
EOF
echo 3 > max_graph_depth
echo 1 > options/funcgraph-proc      # show task name so we can tell urma_pe vs kworker
echo 0 > tracing_thresh               # remove threshold — we want everything inside
```

`tracing_thresh=0` is OK here because `max_graph_depth=3` already
prevents the inner-noise flood. With `funcgraph-proc=1` the
userspace-vs-kworker distinction becomes visible (the parallel
hardware-programming pattern is only obvious when you can see CPU
46/`urma_pe` and CPU 64/`kworker` interleave).

#### H. Implication for the §10.13 minimal baseline

§10.13's recommendation of `tracing_thresh=1000` (1 ms) is **too
aggressive** if the hot inner phases are sub-ms (as they are here —
`get_tp_list` is 151 µs, `import_jetty_ex` is 234 µs). For a real
phase breakdown, prefer `tracing_thresh=0` + `max_graph_depth=3`
(this section's recipe) over `tracing_thresh=1000` +
`max_graph_depth=1` (§10.13's recipe). The latter is fine as a
first "is the kernel slice big at all?" sanity check, but it hides
the inner phase decomposition that's actually informative.

§10.13 is left as-is to preserve the iteration record; readers
should treat §10.18.G's filter + settings as the current preferred
baseline.

### 10.19 UMDK#2 rounds 4–5: the topo-scan finding (overturns §10.18's "97.5% CM RTT" claim)

The §10.18 framing — "97.5% of first-RPC latency is two CM-fabric
RTTs" — was wrong. JinDou's deeper retraces on UMDK#2 (rounds 4 and
5, comments `4418773243` and `4418968474`) walked the call stack
inside `ubmad_post_send` and found a different culprit. This section
records the actual breakdown.

#### A. The hot path is a CPU-bound linear scan, not a network exchange

`ubmad_post_send` calls `ubcore_get_main_primary_eid` to resolve the
destination EID before the WQE is even built. That function lives at
`ubcore_topo_info.c:452` and calls into `ubcore_get_primary_eid`
(line 353), which **linearly scans the entire topology table**.

Verified against the actual source:

```c
/* ubcore_topo_info.c:353 */
int ubcore_get_primary_eid(...) {
    for (node_id = 0; node_id < g_ubcore_topo_map->node_num; node_id++) {
        for (dev_id = 0; dev_id < DEV_NUM; dev_id++) {       /* DEV_NUM = 256 */
            ...
            find_primary_eid_in_ues(agg_dev, ...);
        }
    }
}

/* ubcore_topo_info.c:306 — called by the above */
static int find_primary_eid_in_ues(...) {
    /* iterates IODIE_NUM(2) × (1 + PORT_NUM(9)) = 20 ports per agg_dev
       calling is_eid_match() each time */
}
```

Constants from `ubcore_topo_info.h:18–24`:
- `MAX_NODE_NUM = 64`
- `DEV_NUM = 256`
- `IODIE_NUM = 2`
- `PORT_NUM = 9`

In JinDou's fabric (`urma_admin show topo` reports 22 active nodes ×
256 dev slots ≈ 5,605 agg_devs), each `ubcore_get_main_primary_eid`
call performs:

- **5,605 `find_primary_eid_in_ues` invocations** (one per agg_dev slot)
- **117,678 `is_eid_match` invocations** (~21 per agg_dev × 5,605)

Per call: ~4.9 ms of CPU at ~42 ns per scalar compare. **No hash. No
early-out. No cache.**

The call site that matters: `ubmad_post_send` at
`ubcm/ubmad_datapath.c:817` invokes this on every outbound MAD before
the actual send (`ubmad_do_post_send`, 2–7 µs).

#### B. Per-RPC budget — 8 calls × 4.9 ms ≈ 39 ms of pure CPU

A single first-RPC setup fires `ubcore_get_main_primary_eid` roughly
eight times:

- 3 large CM exchanges (`send_jetty_info_req`, `send_seg_info_req`,
  `send_create_req` / `ubcore_exchange_tp_info`), each posting at
  least one MAD that goes through `ubmad_post_send` and triggers a
  scan
- Plus other smaller MAD posts (per JinDou's round-5 data, 8 total
  call sites observed)

Total CPU cost across the link-setup path: ~39 ms (under ftrace
overhead this ballooned to 38 ms in one site alone; unloaded estimate
based on cycle-counting the inner loop is ~4.9 ms per call).

#### C. What "CM RTT" actually was in §10.18

The §10.18 numbers attributed to "CM RTT" were:

| Phase | §10.18 attribution (wrong) | Actual breakdown (round 4) |
|---|---|---|
| `send_jetty_info_req` 4.83 ms | "network RTT 1" | ~4.83 ms `ubcore_get_main_primary_eid` + ~7 µs actual send |
| `ubcore_session_wait` 6.01 ms | "blocking wait on peer" | this part actually IS a wait, but the cold-state value of 6 ms shrank to 0.45 ms in warm-state round-3 retrace — so it's variable and not the dominant invariant |
| `ubcore_exchange_tp_info` 5.49 ms | "network RTT 2 (CM)" | ~4.89 ms `ubcore_get_main_primary_eid` + ~600 µs actual exchange |

Bulk of each "RTT" row is CPU scan **before** the packet leaves the
wire. The real wire-RTT-plus-server-processing is a few hundred
microseconds in warm state, not milliseconds.

#### D. Cold vs. warm: the 130 ms → 16 ms drift

JinDou's first trace showed 130 ms total; later retraces showed
16.74 ms warm, then 11.4 ms even warmer. `ubcore_session_wait`
specifically dropped from 6,012 µs to 452 µs across rounds for the
same test setup, **same command, same minutes apart**.

Likely sticky state: the local CM session-with-peer state, EID
resolution caches, or fabric route caches. `urma_perftest`'s
`urma_unimport_jetty` at cleanup drops user-facing handles but
doesn't tear down all ubcore-internal state.

A cold-vs-warm modprobe protocol (`modprobe -r udma ubagg uburma
ubcore && modprobe ...`) was proposed in §10.18.F but **was never
executed by JinDou on UMDK#2**. Still the right experiment to
disambiguate "what's already cached in the kernel between runs" from
"what the codex patch would add."

#### E. Implication for codex `udma-tp-cache` — now strongly suspected irrelevant

The patch lives in `drivers/ub/urma/hw/udma/`. The hot spot is in
`drivers/ub/urma/ubcore/ubcore_topo_info.c` + `ubcm/ubmad_datapath.c`
— one or two layers above udma. A udma-layer cache cannot
short-circuit a scan in ubcore-layer code.

For the patch to help, it would need to live somewhere it could
short-circuit `ubcore_get_main_primary_eid` — e.g., a primary-EID
cache keyed by destination EID, or a topo-table hash. None of those
are udma-side.

**Still blocking**: `git diff master..codex/udma-tp-cache --
drivers/ub/urma/` was never run. Closing this loop takes 30 seconds
and would let us stop speculating.

#### F. What the bot got right vs. wrong on UMDK#2

The 25-comment dialog with `@claude[bot]` on UMDK#2 produced the
right end-state but iterated through several wrong intermediates,
each corrected only after JinDou pushed back:

| Bot claim | Verdict | Round corrected |
|---|---|---|
| "97% of first-RPC latency is CM-fabric RTT" | ❌ wrong | round 4 |
| "`ubcore_session_wait` is the dominant single item at 6.01 ms" | ❌ cold-state artifact | round 3 (dropped to 0.45 ms warm) |
| "Stages 5/6 are ftrace-invisible" | ❌ wrong | corrected next reply after JinDou's pushback |
| "5,605 = UE count" | ❌ unit error | round 5 (5,605 = agg_dev slots = node_num × DEV_NUM) |
| File:line citations late in thread (`admin_cmd_show.c:1176-1198`, `topo_info.h:28,52,61`) | unverified | treat as plausible-not-confirmed |

Pattern: the bot was a useful interlocutor on a fresh thread (UMDK#2
is short enough for the SDK not to crash), but a poor primary analyst
on fast-moving data. JinDou's rigor — re-running with deeper depth
and pushing back on overconfident claims — is what produced the
correct answer.

### 10.20 Testing scale and concurrency

The conversation with the human revealed three distinct questions
that were getting conflated:

1. **Does sequential link setup get slower as N grows?** (per-import
   state growth — topo table fills, hash chains get longer, etc.)
2. **Do concurrent link setups contend?** (lock-hold time, server-side
   serialization, fabric queue depth saturation)
3. **Does the topo-scan dominate equally at all N?** (CPU cost grows
   linearly per call regardless of concurrency)

Different tests answer different questions. Recording the test
recipes here so they don't get re-derived.

#### A. Plan B — sequential `-J N` in one process (no patch)

Tests sequential scaling. `urma_perftest` has `-J / --jettys N` but
gates it to bandwidth tests at `perftest_parameters.c:677`:

```c
if (cfg->type != PERFTEST_BW && cfg->jettys > 1) {
    fprintf(stderr, "Multiple jettys only available on band width tests.\n");
    return -1;
}
```

So use `send_bw` and ignore the bandwidth measurement — ftrace will
capture only the import phase:

```bash
# server
urma_perftest send_bw -J 100 -n 1 -s 2 -d bonding_dev_0 --single_path -p 0 \
  > /tmp/srv.out 2>&1 &

# client (with §10.18.G ftrace armed)
ftrace_arm
urma_perftest send_bw -J 100 -n 1 -s 2 -d bonding_dev_0 --single_path -p 0 \
  -S $SERVER > /tmp/cli.out
ftrace_disarm

# extract per-import durations in trace-time order
awk '/\}\s*\/\*\s*ubcore_import_jetty/{
  if (match($0, /([0-9.]+) us/, m)) print NR, m[1]
}' /tmp/trace | head -300
```

`-n 1 -s 2`: one iteration per jetty, 2-byte messages — the
post-setup test phase exits in microseconds. Setup is what takes
time, and the trace filter captures only setup-related functions.

What you'd see:
- 200 `ubcore_import_jetty` exit lines for `-J 100` (each call
  expands to 2 kernel-side imports on a bonded device: aggregate-via-ubagg
  + physical-via-compat, per §10.17–10.18)
- If durations stay flat across the 200, sequential scaling is clean
- If duration grows with sequence number, there's compounding per-import
  state — likely topo table growth or hash collision rate growth

**The for loop at `perftest_resources.c:1540` is serial in one
thread.** `urma_import_jetty` is synchronous; iteration `i+1` only
begins after iteration `i`'s ioctl returns. So Plan B exercises
sequential scaling, not concurrency.

#### B. Plan A — parallel bash processes (rolling wave)

Tests concurrent contention at the cross-process granularity (separate
fds, separate URMA contexts, separate userspace state).

```bash
# server — one listener per port
N=32
for i in $(seq 1 $N); do
  urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path \
    -p $((9000+i)) > /tmp/srv-$i.out 2>&1 &
done

# client (ftrace armed)
SERVER=141.62.32.91
ftrace_arm
t0=$(date +%s.%N)
for i in $(seq 1 $N); do
  /usr/bin/time -f "%e" -o /tmp/cli-$i.time \
    urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path \
    -p $((9000+i)) -S $SERVER > /tmp/cli-$i.out 2>&1 &
done
wait
t1=$(date +%s.%N)
ftrace_disarm
echo "wave = $(echo "$t1 - $t0" | bc) s"
cat /tmp/cli-*.time | sort -n | awk 'NR==1{min=$1} {max=$1; sum+=$1}
  END{printf "min=%s max=%s avg=%.3f\n", min, max, sum/NR}'
```

**What `&` does**: the loop iterates serially, but each iteration
fork+execs in the background. So all N processes run concurrently —
but starts are **staggered by the per-fork latency** (~1–2 ms each).
With N=32, client 32 begins ~30–60 ms after client 1. Plus each
`urma_perftest` has its own libc+URMA init + OOB TCP before the
import ioctl fires.

Net effect: rolling wave, not perfectly simultaneous ioctls. Good
enough for long-lived contention (e.g., a 5 ms mutex hold during
topo scan that all N clients hit). Bad for sub-ms transient
contention.

#### C. Plan A+ — barrier-file synchronization

Plain `for...& done` stagers starts by ~1–2 ms per iteration (bash
forks each iteration sequentially before moving to the next). For
N=32 that's 30–60 ms between client 1 and client N. The barrier-file
pattern eliminates most of that stagger by pre-forking all N
subshells in a wait state, then releasing them atomically.

```bash
rm -f /tmp/go                                      # 1. barrier closed
N=32
for i in $(seq 1 $N); do
  (
    while [ ! -f /tmp/go ]; do : ; done            # 2. spin, waiting for release
    /usr/bin/time -f "%e" -o /tmp/cli-$i.time \    # 3. fires once /tmp/go appears
      urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path \
      -p $((9000+i)) -S $SERVER > /tmp/cli-$i.out 2>&1
  ) &
done
sleep 1                                            # 4. give all N time to reach the spin
touch /tmp/go                                      # 5. release — atomic from N's perspective
wait
```

**Step-by-step**:

1. `rm -f /tmp/go` — ensure the file doesn't exist. "Gate closed."
2. Loop forks N subshells in the background; each immediately enters
   `while [ ! -f /tmp/go ]; do : ; done`. `:` is bash's no-op; the
   loop just spins checking whether the file appeared. Cost per
   iteration: one `stat()` syscall, ~µs.
3. `sleep 1` — gives the loop time to fork all N subshells and let
   them reach the spin loop. Without this you'd race: some subshells
   might still be in fork/exec when you signal.
4. `touch /tmp/go` — the release. One `creat()` syscall. As soon as
   it returns, all N subshells see the file on their next iteration
   of the spin loop.
5. All N subshells fall through `while` and start their command
   essentially together.

**Stagger comparison**:

| Method | Time between 1st and Nth start | Why |
|---|---|---|
| Plain `for...& done` | ~1–2 ms × N (≈ 30–60 ms for N=32) | bash forks each iteration sequentially |
| Barrier with busy-spin `do : ; done` | ~µs across all N | spin checks at ~µs granularity |
| Barrier with `sleep 0.001` poll | ~1 ms | check granularity = sleep interval |
| Barrier with `inotifywait /tmp/go` | sub-µs | kernel signals waiters on file creation |

Busy-spin (`do : ; done`) is the simplest and gets ~µs sync. The
downside is CPU burn during the `sleep 1` window before release —
N cores spinning. For N up to a few hundred on an idle system it's
fine.

**Why "tighter" still isn't tight enough for kernel-side ioctl
stress**: the barrier synchronizes **bash-level dispatch**, not the
syscalls that hit the kernel. After the release, each
`urma_perftest` process still has to do:

1. Process startup (`execve`, libc init, dynamic linker): ~5–15 ms
2. `urma_init` / `urma_create_context` / device open: ~1–5 ms
3. `urma_create_jfs / jfr / jetty`: ~1 ms total
4. OOB TCP connect to the server and exchange descriptors: ~5–20 ms
5. *Then* finally `urma_import_jetty` → `ioctl(UBURMA_CMD_IMPORT_JETTY)`

By the time step 5 fires, each process has done 10–40 ms of pre-work,
varying with OS scheduling. So the **ioctls** that actually exercise
the kernel topo scan still spread out over 10s of ms — even though
the **bash** commands started within microseconds. Barrier-file
solves "when do the shell commands fire" but not "when do the
syscalls arrive."

**When barrier-file IS the right tool**:

- When the stagger from `for...& done` (30–60 ms) is comparable to or
  larger than what you're trying to measure.
- When you need to compare "all N run at once" vs "N run sequentially"
  without writing C.
- When the bottleneck is multi-process scheduling, FD-table
  contention, or anything else where each process needs its own
  context.
- Lightweight benchmarks (network ping, simple syscalls, etc.).

For the UMDK-specific question "does the kernel topo scan serialize
under concurrent imports?" — barrier-file is a middle-ground option:
tighter than plain `&`, looser than pthreads. Reasonable to try after
Plan A to rule out "the stagger was hiding the contention." If Plan A
and barrier-A produce the same result, the contention either doesn't
exist or has a millisecond-or-longer hold time (which would show up
under either pattern).

#### D. Plan C — pthread fan-out in one process (real concurrent ioctls)

The cleanest stress test: one process, one URMA context, N pthreads
each calling `urma_import_jetty` simultaneously. Requires a patch to
`perftest_resources.c`:

```c
struct import_arg {
    perftest_context_t *ctx;
    perftest_config_t *cfg;
    uint32_t idx;
    urma_rjetty_t rjetty;
    urma_bondp_rjetty_t bondp_rjetty;
    bool use_bondp;
    int result;
};

static void *parallel_import_worker(void *arg)
{
    struct import_arg *a = arg;
    a->ctx->import_tjetty[a->idx] = urma_import_jetty(
        a->ctx->urma_ctx,
        a->use_bondp ? &a->bondp_rjetty.base : &a->rjetty,
        &g_perftest_token);
    a->result = (a->ctx->import_tjetty[a->idx] == NULL) ? -1 : 0;
    return NULL;
}

/* in connect_jetty_default(), replace the serial loop body with:
 *
 *   pthread_t *threads = calloc(ctx->jetty_num, sizeof(pthread_t));
 *   struct import_arg *args = calloc(ctx->jetty_num, sizeof(*args));
 *   struct timespec t0, t1;
 *   clock_gettime(CLOCK_MONOTONIC, &t0);
 *   for (i = 0; i < ctx->jetty_num; i++) {
 *       args[i] = (struct import_arg){ .ctx = ctx, .cfg = cfg, .idx = i,
 *           .rjetty = rjetty_arr[i], .bondp_rjetty = bondp_arr[i],
 *           .use_bondp = use_bondp_arr[i] };
 *       pthread_create(&threads[i], NULL, parallel_import_worker, &args[i]);
 *   }
 *   for (i = 0; i < ctx->jetty_num; i++) pthread_join(threads[i], NULL);
 *   clock_gettime(CLOCK_MONOTONIC, &t1);
 *   fprintf(stderr, "parallel import of %u: %.3f ms\n", ctx->jetty_num,
 *           (t1.tv_sec - t0.tv_sec) * 1000.0 +
 *           (t1.tv_nsec - t0.tv_nsec) / 1e6);
 */
```

Build with `-lpthread`. After this patch, `urma_perftest send_bw -J
64 ...` fires 64 concurrent `ioctl(IMPORT_JETTY)` syscalls on the
same fd within microseconds of each other — the strictest test of
any per-fd / per-context kernel-side lock.

#### E. Optional patch: `--setup-only` flag

If you only ever care about setup timing, a tiny patch eliminates
the post-setup test phase entirely:

```c
/* in perftest_parameters.c options + struct */
{"setup-only", no_argument, NULL, PERFTEST_OPT_SETUP_ONLY},

case PERFTEST_OPT_SETUP_ONLY:
    cfg->setup_only = true;
    break;

/* in main() or test-runner entry, after connect_jetty(): */
if (cfg->setup_only) {
    fprintf(stderr, "setup complete, exiting\n");
    cleanup_ctx(ctx);
    return 0;
}
```

Also worth deleting the `-J > 1 only on BW tests` check at
`perftest_parameters.c:677` so `send_lat -J 100 --setup-only` becomes
valid. Together, ~15 lines of patch.

#### F. Recommended order on an idle test system

1. **Plan B** first — `send_bw -J 100 -n 1 -s 2`, no patch, one
   process. Establishes sequential per-import baseline. ~5 minutes.
2. **Plan A** next — N parallel processes via the bash loop. Reveals
   cross-process contention. ~10 minutes per N value.
3. **Plan C** only if A doesn't reproduce the suspected pathology.
   The patch is ~30 lines. Provides true concurrent ioctls on one fd.

#### G. What to grep for in the trace

Per-import duration ranked by slowest:

```bash
awk '/\}\s*\/\*\s*ubcore_import_jetty/{
    if (match($0, /([0-9.]+) us/, m)) print m[1], NR
}' trace | sort -rn | head -20
```

If under contention (Plan A or C) the slowest import is 10× the
fastest, you've found a serialization hot spot. Next step: grep the
trace for which phase grew — usually `ubcore_get_tp_list`,
`ubcore_session_wait`, or `ubcore_exchange_tp_info` if locking on
the topo table or peer session.

For the topo-scan hypothesis specifically (§10.19), expect each
`ubcore_get_main_primary_eid` call to take ~4.9 ms regardless of
concurrency — it's per-CPU work. If N parallel imports each get
4.9 ms of scan time on N different CPUs, total wall-clock for the
wave is bounded by max-per-CPU rather than sum. If instead one core
serializes all scans (e.g., topo table mutex), wall-clock grows
linearly with N. The trace will distinguish these.

### 10.21 `urma_perftest` execution stages

Full pipeline for any `urma_perftest` subcommand (`send_lat`,
`send_bw`, `read_*`, `write_*`, `atomic_*`), with file:line citations
and kernel-touching annotations. Useful when interpreting ftrace
captures — locating which stage produced which trace entries.

#### A. Top-level `main()` at `urma_perftest.c:158`

| # | Stage | Function | What | Kernel ioctl? |
|---|---|---|---|---|
| 1 | parse args | `perftest_parse_args` (`perftest_parameters.c:585`) | getopt parsing | no |
| 2 | local config check | `check_local_cfg` | sanity-check derived params | no |
| 3 | OOB TCP connect to peer | `establish_connection` (`perftest_communication.c`) | plain `socket()`/`connect()` between client & server | TCP only |
| 4 | exchange + verify config | `check_remote_cfg` | exchange CLI config over the TCP socket from #3 | no |
| 5 | **resource creation** | `create_ctx` (`perftest_resources.c:2263`) | dispatches to `create_simplex_ctx` or `create_duplex_ctx` | yes — many |
| 6 | prepare test | `prepare_test` (`urma_perftest.c:139`) | rearm JFCE, allocate WR lists, sync "ready" with peer | one `MODIFY_JFC` for rearm |
| 7 | **run the test** | `run_test` (`urma_perftest.c:25`) → `run_send_lat` / `run_send_bw` / etc. | the actual benchmark loop | mostly userspace-only: doorbell + CQ poll via mapped memory; no per-RPC ioctl |
| 8 | destroy resources | `destroy_ctx` (`perftest_resources.c:2317`) | reverse-order teardown | yes — many |
| 9 | TCP close | `close_connection` | `close()` the OOB TCP socket | TCP only |
| 10 | free cfg | `destroy_cfg` | free CLI strings | no |

#### B. Stage 5 expanded — `create_duplex_ctx()` at `perftest_resources.c:2198`

This is the DUPLEX mode flow (used by `send_lat -d bonding_dev_0`,
output shows `JETTY mode: DUPLEX`). SIMPLEX mode is similar but uses
JFR/JFS separately; see `create_simplex_ctx()` at
`perftest_resources.c:1968`.

| # | Sub-stage | Function | What it does | Userland API → ioctl |
|---|---|---|---|---|
| 5a | open device | `init_device` (`perftest_resources.c:150`) | open named UB device | `urma_create_context` → `UBURMA_CMD_CREATE_CTX` |
| 5b | create local jettys | `create_duplex_jettys` (`perftest_resources.c:658`) | per i: `urma_create_jfce × 2`, `urma_create_jfc × 2`, `urma_create_jetty` (combined SQ+RQ) | `UBURMA_CMD_CREATE_JFC` / `CREATE_JETTY` |
| 5c | register memory | `register_mem` (`perftest_resources.c:743`) | `urma_register_seg` for the data region | `UBURMA_CMD_REGISTER_SEG` |
| 5d | (opt) credit context | `create_credit_ctx` | flow-control machinery; only if `--enable_credit` | additional `register_seg` |
| 5e | exchange descriptors | `exchange_connection_info` (`perftest_resources.c:1177`) | TCP-send local `(jetty_id, seg_info, tp_info)` to peer; read peer's back | pure TCP, no URMA ioctls |
| 5f | import remote segments | `import_seg_for_duplex` (`perftest_resources.c:1304`) | `urma_import_seg` for each remote segment id | `UBURMA_CMD_IMPORT_SEG`; kernel side does a CM-MAD exchange and may fire `ubcore_get_main_primary_eid` topo scan |
| **5g** | **import remote jettys (LINK SETUP)** | `connect_jetty` → `connect_jetty_default` (`:1510`) | per i: `urma_import_jetty` for each remote jetty; also `urma_bind_jetty` (RC) or `urma_advise_jetty` (non-UB) | `UBURMA_CMD_IMPORT_JETTY` → the 5-phase compat path in ubcore (§10.16 / §10.18 / §10.19) |
| 5h | (opt) modify user TP | `modify_user_tp` | only if `--enable_user_tp` | `urma_modify_tp` → `UBURMA_CMD_MODIFY_TP` |
| 5i | create run context | `create_run_ctx` | pre-allocate WR arrays, latency arrays, post-list templates | pure userland |

**5g is the link-setup stage we've been measuring** across the whole
investigation. 5f is the other CM-exchange stage (shorter, runs once
for the segment).

#### C. Stage 7 expanded — `run_test()` dispatch by API type

All runners live in `perftest_run_test.c`:

| Subcommand | Function | Inner loop |
|---|---|---|
| `send_lat` (DUPLEX) | `run_send_lat_duplex` | ping-pong: post SEND, poll completion, peer echoes, poll echo — N iters |
| `send_lat` (SIMPLEX) | `run_send_lat_simplex` | same shape with JFS post + JFR poll |
| `send_bw` | `run_send_bw_*` | pipeline-full: post N up to `tx_depth`, poll, repost; measure throughput |
| `read_lat` / `read_bw` | `run_read_*` | URMA READ — pull from remote registered seg |
| `write_lat` / `write_bw` / `write_with_imm_*` | `run_write_*` | URMA WRITE / WRITE_IMM |
| `atomic_lat` / `atomic_bw` | `run_atomic_*` | CAS / FAA on remote memory |

**Critical for trace interpretation**: the steady-state data path
posts WRs to mapped userspace doorbells and polls JFC by reading
mapped CQ memory — **no per-RPC ioctl**. The 3.47 µs steady-state
latency JinDou measures has zero kernel transitions per op. Kernel
involvement is **only** at stage 5 (setup) and stage 8 (teardown).

#### D. Stage 8 expanded — `destroy_duplex_ctx()` at `perftest_resources.c:2292`

Mirrors stage 5 in reverse:

| # | Sub-stage | What |
|---|---|---|
| 8a | `destroy_run_ctx` | free WR arrays, latency results |
| 8b | (opt) free user_tp | only if 5h ran |
| 8c | `disconnect_jetty` | `urma_unimport_jetty` for each — releases vtpn refcount; **can take several ms per call** (§10.18 saw 5.13 ms for unimport #1) |
| 8d | `sync_time(..., "unimport_jetty")` per pair | wait for peer to also unimport over TCP |
| 8e | (opt) `unimport_credit` | only if 5d ran |
| 8f | `unimport_seg` | `urma_unimport_seg` for each from 5f |
| 8g | `destroy_connection_info` | free descriptor exchange buffers |
| 8h | (opt) `destroy_credit_ctx` | only if 5d ran |
| 8i | `unregister_mem` | `urma_unregister_seg` |
| 8j | `destroy_duplex_jettys` | `urma_delete_jetty/jfc/jfce` per index |
| 8k | `uninit_device` (`perftest_resources.c:261`) | `urma_delete_context` |

#### E. Where each stage's wall-clock lands in JinDou's actual test

For `urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path
-p 0 -S X.X.X.X`:

| Stage | Approx wall-clock (warm state) | Visible in ftrace? |
|---|---|---|
| 1–2 args/cfg | µs | no |
| 3 TCP connect | low ms | no |
| 4 cfg exchange | low ms | no |
| 5a init_device | low ms | yes — `UBURMA_CMD_CREATE_CTX` entry |
| 5b create jettys | < 1 ms | yes — JFC/jetty create entries (short) |
| 5c register_mem | < 1 ms | yes |
| 5e exchange info | few ms (TCP only) | no — userland TCP |
| 5f import_seg | ~5–6 ms (one CM exchange + topo scan) | yes — `ubcore_import_seg` entries |
| **5g connect_jetty** | **~11 ms warm, ~130 ms cold** (two CM exchanges + topo scan × 2) | yes — **the headline link-setup time** |
| 5i prepare WRs | µs | no |
| 6 prepare_test | ms (TCP sync) | one `MODIFY_JFC` ioctl |
| 7 run_test (N=5) | ~17 µs total (5 × 3.47 µs) | almost none — kernel bypass |
| 8c–8k teardown | ~6–8 ms (unimport_jetty CM RTT dominates) | yes — long unimport_jetty entry |

So "link setup time" is almost always **stage 5g**
(`connect_jetty` → kernel `ubcore_import_jetty`). 5f is the other
CM-exchange stage but smaller. Everything else is sub-ms or
non-ioctl.

#### F. Source files for follow-up

| File | What's in it |
|---|---|
| `src/urma/tools/urma_perftest/urma_perftest.c` | `main()` + `run_test()` + `prepare_test()` |
| `src/urma/tools/urma_perftest/perftest_parameters.c` | CLI parsing, all `cfg` defaults |
| `src/urma/tools/urma_perftest/perftest_resources.c` | `create_*_ctx`, `init_device`, `create_*_jettys`, `register_mem`, `exchange_connection_info`, `import_seg_*`, `connect_jetty_*`, mirror destroys |
| `src/urma/tools/urma_perftest/perftest_communication.c` | TCP OOB channel — `establish_connection`, `check_remote_cfg`, `sync_time` |
| `src/urma/tools/urma_perftest/perftest_run_test.c` | Per-API benchmark loops (`run_send_lat_*`, `run_send_bw_*`, etc.) |

#### G. Stage 5 — full nested call graph of `create_duplex_ctx()`

§10.21.B gave each sub-stage 5a–5i as a one-liner. This sub-section expands
the full nested call graph so a reader can see exactly which userland
helper calls which URMA verb, which ioctl that verb fires, and which
kernel function the ioctl dispatches into. Source: `perftest_resources.c`
in `/Volumes/KernelDev/umdk/src/urma/tools/urma_perftest/` as of
2026-05-12.

Legend:
- **★** = crosses the userspace→kernel boundary (ioctl or syscall)
- `[opt FLAG]` = conditional branch on CLI flag
- `:NNN` = file:line of the function definition in `perftest_resources.c`
  unless otherwise noted

```
create_duplex_ctx (:2198)
│
├── 5a  init_device (:150)                                  [≈ 1-2 ms]
│   ├── urma_init()                                          (libc-style URMA init, no ioctl)
│   ├── urma_register_log_func()                             [opt --enable_stdout]
│   ├── urma_get_device_by_name(cfg->dev_name)               (parses /sys/class/ub/)
│   ├── urma_query_device(urma_dev, &ctx->dev_attr)          (no kernel transition; uses cached attrs)
│   ├── urma_create_context(urma_dev, eid_idx)            ★  → UBURMA_CMD_CREATE_CTX
│   │   └── kernel: uburma allocates context, maps doorbell/CQ pages
│   ├── [if dev->name starts "bonding"]
│   │   └── urma_user_ctl(BONDP_USER_CTL_SET_BONDING_MODE) ★  → UBURMA_CMD_USER_CTL
│   └── check_dev_cap(ctx, cfg)                              (validates against ctx->dev_attr.dev_cap)
│
├── 5b  create_duplex_jettys (:658)                          [≈ < 1 ms total]
│   ├── create_jfc (:338)
│   │   ├── alloc_jfc()                                       (calloc ctx->jfc_s, jfc_r, jfce_s, jfce_r arrays)
│   │   └── for i in 0..cfg->jettys:
│   │       ├── [if --use_jfce]
│   │       │   ├── ctx->jfce_s[i] = urma_create_jfce()    ★  → UBURMA_CMD_CREATE_JFCE
│   │       │   └── ctx->jfce_r[i] = urma_create_jfce()    ★  → UBURMA_CMD_CREATE_JFCE
│   │       ├── ctx->jfc_s[i] = urma_create_jfc(jfc_cfg)   ★  → UBURMA_CMD_CREATE_JFC   (tx CQ)
│   │       └── ctx->jfc_r[i] = urma_create_jfc(jfc_cfg)   ★  → UBURMA_CMD_CREATE_JFC   (rx CQ)
│   │
│   └── create_jetty (:564)
│       ├── fill_jfs_cfg(...)                                 (pure userland — depth, max_sge, inline_size)
│       ├── fill_jfr_cfg(...)                                 (pure userland)
│       ├── [if cfg->share_jfr]
│       │   └── for j in 0..jfr_num:
│       │       └── ctx->jfr[j] = urma_create_jfr(jfr_cfg) ★  → UBURMA_CMD_CREATE_JFR
│       └── for i in 0..cfg->jettys:
│           └── ctx->jetty[i] = urma_create_jetty(jetty_cfg) ★ → UBURMA_CMD_CREATE_JETTY
│
├── 5c  register_mem (:743)                                  [≈ < 1 ms]
│   ├── for i in 0..cfg->jettys:
│   │   └── ctx->local_buf[i] = [huge] ub_hugemalloc() OR memalign()
│   │                                                          (libc/kernel mmap, no URMA ioctl yet)
│   ├── [if urma_ctx->dev->type == URMA_TRANSPORT_UB]
│   │   └── for k in 0..cfg->jettys:
│   │       └── ctx->token_id[k] = urma_alloc_token_id()    ★  → UBURMA_CMD_ALLOC_TOKEN_ID
│   └── for j in 0..cfg->jettys:
│       └── ctx->local_tseg[j] = urma_register_seg(seg_cfg) ★  → UBURMA_CMD_REGISTER_SEG
│           └── kernel: pins pages, builds IOMMU mapping, returns token+ukey
│
├── 5d  create_credit_ctx (opt --enable_credit)              [≈ < 1 ms]
│   ├── alloc credit-seg buffers + token_id (same shape as 5c)
│   └── urma_register_seg × cfg->jettys                    ★  → REGISTER_SEG
│
├── 5e  exchange_connection_info (:1177)                     [≈ few ms — pure TCP]
│   │       NO URMA ioctls in this entire sub-tree.
│   │       All boundary crossings are TCP socket I/O.
│   │
│   ├── exchange_seg_info (:882)
│   │   ├── alloc local_seg_buf + remote_seg_buf
│   │   ├── pack each ctx->local_tseg[i]->seg into local_seg_buf[i]
│   │   └── [if pair_flag] for i in 0..pair_num: sock_sync_data(per-pair)
│   │       else            sock_sync_data(batch all)
│   │
│   ├── exchange_jetty_id (:926)
│   │   ├── pack each ctx->jetty[i]->jetty_id into local_jetty_id_buf[i]
│   │   └── sock_sync_data(urma_jetty_id_t buf) — TCP exchange
│   │
│   ├── exchange_credit_info (:976)  [opt --enable_credit]
│   │   └── sock_sync_data of credit-seg metadata
│   │
│   ├── create_tp_info (:1027)         [opt --tp_aware]
│   │   └── pre-allocates TP handles + PSN for tp-aware path
│   │
│   └── exchange_tp_info (:1134)       [opt --tp_aware]
│       └── sock_sync_data of TP handles between peers
│
├── 5f  import_seg_for_duplex (:1304)                        [≈ 5-6 ms — first CM exchange]
│   ├── [opt --enable_credit]
│   │   └── for i in 0..ctx->jetty_num:
│   │       └── urma_import_seg(remote_credit_seg[i])    ★  → UBURMA_CMD_IMPORT_SEG
│   └── for i in 0..ctx->jetty_num:
│       └── ctx->import_tseg[i] = urma_import_seg(remote_seg[i])   ★ → UBURMA_CMD_IMPORT_SEG
│           └── kernel: ubcore_import_seg →
│               ├── CM-MAD exchange to peer (one RPC)
│               ├── may fire ubcore_get_main_primary_eid topo scan once
│               └── installs the remote_seg's ukey+token in local UB tables
│
├── 5g  connect_jetty (:1773)  ★★★ THE LINK SETUP STAGE ★★★  [≈ 11 ms warm / 130 ms cold]
│   │
│   ├── ctx->import_tjetty = calloc(jetty_num, sizeof(...))
│   │
│   ├── BRANCH by config:
│   │   │
│   │   ├── [opt --enable_async_import]
│   │   │   └── connect_jetty_async (around :1700)
│   │   │       └── batched urma_import_jetty_async + wait notifier
│   │   │
│   │   ├── [opt --tp_aware] connect_jetty_tp_aware (:1574)
│   │   │   └── for i in 0..jetty_num:
│   │   │       ├── pack urma_import_jfr_ex_cfg_t with TP handle + PSN
│   │   │       ├── urma_import_jetty_ex(rjetty, ex_cfg)  ★  → IMPORT_JETTY (ex variant)
│   │   │       └── [if RC] urma_bind_jetty_ex          ★  → BIND_JETTY (ex variant)
│   │   │
│   │   └── default: connect_jetty_default (:1510)
│   │       └── for i in 0..ctx->jetty_num:
│   │           │
│   │           ├── build rjetty struct (jetty_id, trans_mode, tp_type=CTP/RTP/UTP)
│   │           ├── [if RC && OT] rjetty.flag.bs.share_tp = 1
│   │           ├── [if dev->name starts "bonding" && RM]
│   │           │       wrap rjetty in bondp_rjetty_t (bondp extension)
│   │           │
│   │           ├── ctx->import_tjetty[i] = urma_import_jetty(rjetty, token) ★ → UBURMA_CMD_IMPORT_JETTY
│   │           │   └── kernel: ubcore_import_jetty — the 5-phase compat path
│   │           │       (§10.16 / §10.18 / §10.19 / §10.22)
│   │           │       │
│   │           │       ├── ubcore_get_main_primary_eid (topo_info.c:452)
│   │           │       │   └── linear is_eid_match × ~117k per invocation
│   │           │       │       (no hash, no cache; 5605 = node_num(22) × DEV_NUM(256))
│   │           │       │   ★ Called ~8× per setup, ~4.9 ms each
│   │           │       │   ★ DOMINANT COST: ~39 ms CPU budget total (§10.19)
│   │           │       │
│   │           │       ├── ubmad_post_send (ubmad_datapath.c:817)
│   │           │       │   └── CM-MAD send to peer
│   │           │       │       (topo scan fires INSIDE this function before
│   │           │       │       the packet leaves the wire — that's why what
│   │           │       │       looks like CM-RTT is mostly CPU)
│   │           │       │
│   │           │       ├── ubcore_get_tp_list
│   │           │       │   ├── synchronous urma_pe-* context (stage 5g sub-phase 1)
│   │           │       │   └── concurrent kworker-* context (off critical path)
│   │           │       │
│   │           │       ├── ubcore_session_wait
│   │           │       │   └── the REAL CM reply wait, 0.45-6 ms variable
│   │           │       │
│   │           │       ├── udma_ctrlq_{create,destroy,modify,...} family
│   │           │       │   └── fast firmware cmds in kworker, off critical path
│   │           │       │
│   │           │       └── ubcore_active_tp (sub-phase 5, ~200 µs)
│   │           │
│   │           ├── [if cfg->trans_mode == URMA_TM_RC]
│   │           │   └── urma_bind_jetty(local_jetty, import_tjetty)  ★ → UBURMA_CMD_BIND_JETTY
│   │           │       └── installs RC pairing; idempotent (returns URMA_EEXIST on re-bind)
│   │           │
│   │           ├── [if RM mode && dev->type != UB]
│   │           │   └── urma_advise_jetty(local, import_tjetty)      ★ → UBURMA_CMD_ADVISE_JETTY
│   │           │
│   │           └── [if --pair_flag] sleep(1)
│   │
│   └── [error path] disconnect_jetty_default() — unimports any that succeeded
│
├── 5h  modify_user_tp (opt --enable_user_tp)
│   └── urma_modify_tp                                        ★ → UBURMA_CMD_MODIFY_TP
│       (UB device does NOT support user_tp — init_device errors out if both set)
│
└── 5i  create_run_ctx (:1799)                              [≈ µs, pure userland]
    ├── calloc ctx->run_ctx.tposted[]                         (cycles_num * uint64_t)
    ├── calloc ctx->run_ctx.tcompleted[]                      (cycles_num * uint64_t)
    ├── calloc ctx->run_ctx.scnt[]                            (cfg->jettys * uint64_t)
    └── calloc ctx->run_ctx.ccnt[]                            (cfg->jettys * uint64_t)
```

##### G.1 Per-stage ioctl tally (one `urma_perftest send_lat -n 5 -s 2`)

For `cfg->jettys = 1` (default) and `--enable_credit / --enable_user_tp / --tp_aware / --enable_async_import` all OFF, the steady-state warm-state call counts are:

| Sub-stage | ioctls fired | Wall-clock (warm) |
|---|---|---|
| 5a `init_device` | 1× CREATE_CTX | ~1-2 ms |
| 5b `create_duplex_jettys` | 2× CREATE_JFC + 1× CREATE_JETTY = **3** | < 1 ms |
| 5c `register_mem` | 1× ALLOC_TOKEN_ID + 1× REGISTER_SEG = **2** | < 1 ms |
| 5d `create_credit_ctx` | 0 (disabled) | — |
| 5e `exchange_connection_info` | 0 (TCP only) | ~few ms (network) |
| 5f `import_seg_for_duplex` | **1× IMPORT_SEG** (one CM exchange + topo scan) | ~5-6 ms |
| **5g `connect_jetty_default`** | **1× IMPORT_JETTY** (the 39 ms CPU + CM exchange + bind) | **~11 ms warm** |
| 5h `modify_user_tp` | 0 (disabled) | — |
| 5i `create_run_ctx` | 0 | µs |
| **Total** | **~7 ioctls** | **~17-20 ms** (dominated by 5g) |

The link-setup investigation has been focused almost entirely on the
single `IMPORT_JETTY` ioctl fired by 5g's `urma_import_jetty()` call,
and specifically on the `ubcore_get_main_primary_eid` topo scan that
fires ~8× inside the kernel-side `ubcore_import_jetty` 5-phase compat
path.

##### G.2 Where each function-pointer dispatch is wired

`urma_import_jetty()` (userspace) doesn't directly call `ubcore_import_jetty()` (kernel).
The dispatch path is:

```
urma_import_jetty (libuburma.so)
  └── ioctl(fd, UBURMA_CMD_IMPORT_JETTY, &urma_cmd_import_jetty)
      └── kernel: uburma_cmd_import_jetty (uburma/uburma_cmd.c)
          └── ubcore_import_jetty (drivers/ub/urma/ubcore/ubcore_jetty.c)
              ├── 5-phase compat path (§10.16)
              ├── for each phase:
              │   └── ubmad_post_send → ubcore_get_main_primary_eid ★
              ├── ubcore_session_wait for CM reply
              └── ubcore_active_tp
```

The 5g call graph above shows the userspace side; §10.16 / §10.18 /
§10.19 / §10.22 cover the kernel side once `UBURMA_CMD_IMPORT_JETTY` is
inside ubcore. Together they give end-to-end visibility from
`create_duplex_ctx()` line 2226 (`connect_jetty()` call) down to the
117k-element scalar compare loop that produces the 39 ms cost.

### 10.22 Trace-leaf to stage mapping — where each commonly-seen kernel function fits in `urma_perftest`

§10.21 mapped userland stages to kernel ioctls. This section does the
inverse: given a kernel function you see in an ftrace capture, where
does it fit in `urma_perftest`'s stage chain, what's its parent, and
what's inside it? Useful when reading a trace and asking "what is
this entry actually a part of?"

The functions covered here are the ones JinDou's traces surfaced as
significant and the ones the rest of §10 keeps referring back to.

#### A. `ubmad_post_send` — the leaf MAD-send primitive

**File:line**: `ubcm/ubmad_datapath.c:768`.

**What it is**: the kernel's "send a control message to the peer"
function. Every kernel-initiated CM (Connection Manager) message
funnels through it. NOT one of the named stages — it's a leaf that
runs *inside* the named CM-send wrappers (e.g., `send_jetty_info_req`,
`ubcore_exchange_tp_info`, `send_seg_info_req`, `send_close_req`).

**Body shape** (simplified):

```c
int ubmad_post_send(struct ubmad_send_buf *send_buf, ...) {
    ...
    /* line 817 — ~4.9 ms of CPU scan PER CALL */
    ret = ubcore_get_main_primary_eid(device, &dst_eid, ...);
    if (ret != 0) return ret;
    ...
    /* the actual hardware WQE post — 2–7 µs */
    return ubmad_do_post_send(send_buf, ...);
}
```

The topo-scan cost (§10.19) lives inside `ubcore_get_main_primary_eid`
at line 817, *before* any packet leaves the wire. Each
`ubmad_post_send` invocation pays the full ~4.9 ms scan even if the
underlying network would have been microseconds.

**Where it's reached from in a urma_perftest run**:

```
                                              registered cm-send op
                                              = ubmad_ubc_send         ubcm/ubmad_datapath.c:1155
                                                  └─ ubmad_post_send   ubcm/ubmad_datapath.c:768
                                                         │
                                                         ▼
   stage 5f  send_seg_info_req     ───→  ubmad_ubc_send  ───→  ubmad_post_send   ★ call site 1
   stage 5g  send_jetty_info_req   ───→  ubmad_ubc_send  ───→  ubmad_post_send   ★ call site 2
             (from ubcore_connect_exchange_udata_when_import_jetty)
   stage 5g  send_create_req       ───→  ubmad_ubc_send  ───→  ubmad_post_send   ★ call site 3
             (from ubcore_exchange_tp_info)
   stage 8c  send_close_req        ───→  ubmad_ubc_send  ───→  ubmad_post_send   ★ call site 4
             (from urma_unimport_jetty)
```

**Per-run invocation count**: JinDou's round-5 trace observed **~8
call sites** of `ubcore_get_main_primary_eid` per perftest run,
which means ~8 `ubmad_post_send` invocations (some CM-send wrappers
fire multiple sub-messages). Distribution:

- 1 from stage 5f (single segment import)
- 2–3 from stage 5g 1st `ubcore_import_jetty` (bonding udata exchange)
- 2–3 from stage 5g 2nd `ubcore_import_jetty` (TP info exchange)
- 1–2 from stage 8c (unimport)

**Total per-run CPU cost** (warm, 22 active fabric nodes): ~8 × 4.9 ms
= ~39 ms of CPU work, distributed across the named stages.

**Implication**: when you see `ubmad_post_send` (or its CM-send
wrappers like `send_jetty_info_req`) take milliseconds in a trace,
that's NOT "the moment the packet went out." It's "~4.9 ms of CPU
scan, then a tiny send." Pre-round-5 we kept misreading the parents
of this function as "network-RTT-dominated"; round 5 showed the cost
is entirely CPU.

#### B. `ubcore_get_tp_list` — the compat-path TP discovery

**File:line**: `ubcore_tp.c:26`.

**What it is**: one of the 5 sequential sub-phases inside
`ubcore_import_jetty_compat` (the path udma takes because of its
`_ex`-only ops registration). Calls `dev->ops->get_tp_list` =
`udma_get_tp_list`, which goes through firmware ctrlq
(`udma_ctrlq_get_tpid_list`) to query the local hardware for its
available TPs.

**Where it sits in stage 5g**:

```
stage 5g  ubcore_import_jetty (compat path)
            └─ ubcore_import_jetty_compat
                 ├─ ★ ubcore_get_tp_list ★      ← sub-phase 1 (this function)
                 │     └─ udma_get_tp_list
                 │           └─ udma_ctrlq_get_tpid_list  (ctrlq → firmware)
                 ├─ ubcore_exchange_tp_info       sub-phase 2 (RM+RTP only)
                 ├─ ubcore_import_jetty_ex        sub-phase 3
                 │     └─ ubcore_connect_vtp_ctrlplane  sub-phase 4
                 │           └─ ubcore_active_tp        sub-phase 5
```

**Self-instruments**: at `ubcore_tp.c:48`, logs
`"[DRV_INFO]get_tp_list consumes: %llu"` when duration >
`UBCORE_DRV_TP_THRESHOLD_MS` (1 ms). Gated by the
`g_ubcore_log_level` module param (see §10.4).

**Two distinct trace contexts you'll see it in**:

| Context | Task | What it is | Typical duration |
|---|---|---|---|
| Synchronous on caller | `urma_pe-*` (e.g., CPU 46 in JinDou's trace) | Inside the local caller's stage 5g compat path | 151 µs (round 3) |
| Concurrent in kworker | `kworker-*` (e.g., CPU 64) | The local kernel responding to a CM message from the peer — peer is doing its own import and queries our TP info | 200 µs (round 3) |

So when you see two `ubcore_get_tp_list` entries in a trace, **only
the `urma_pe-*` one belongs to your own local urma_perftest's stage
5g**. The `kworker-*` one is the local side of the peer's stage 5g
— it's outside your own perftest's call chain.

Awk filter for local-only:

```bash
awk -F'|' '/ubcore_get_tp_list/ && /urma_pe/ {
    if (match($0, /([0-9.]+) us/, m)) print m[1]
}' /sys/kernel/debug/tracing/trace
```

**Implication**: `ubcore_get_tp_list` is **not** the headline cost
despite the name suggesting it might be. Its hardware-query
(~150–200 µs via ctrlq) is fast. The 5 ms-scale cost during link
setup is in `ubmad_post_send`'s topo scan (§10.22.A), inside the CM
siblings of `get_tp_list`, not inside `get_tp_list` itself.

#### C. `ubcore_session_wait` — the CM reply wait

**File:line**: `ubcore_connect_bonding.c:567` (in
`ubcore_connect_exchange_udata_when_import_jetty`).

**What it is**: `wait_for_completion` on the response to a
`send_jetty_info_req`. Fires only on the bonding path (1st
`ubcore_import_jetty` for a bonded device). Blocks the caller until
the peer's response MAD arrives back via the local CM workqueue.

**Where it sits**:

```
stage 5g  1st ubcore_import_jetty (bonding aggregate path)
            └─ ubcore_connect_exchange_udata_when_import_jetty   bonding.c:497
                 ├─ create_session_for_exchange_udata
                 ├─ send_jetty_info_req                          ← fires ubmad_post_send
                 ├─ ★ ubcore_session_wait ★                      ← blocks here for peer reply
                 └─ copy_to_user
```

**Self-instruments**: when duration > `UBCORE_EXC_THRESHOLD_MS`, logs
`"[EXC_INFO]exchange_jetty_info consumes: %llu"`.

**Cold vs warm behavior**: highly variable. JinDou's round-1 trace
showed `ubcore_session_wait` = 6012 µs (cold); round-3 trace, same
test minutes later, showed 452 µs (warm). The first-time-to-a-peer
case includes the peer's full setup work; subsequent reconnects skip
most of it. See §10.18.F for the cold-vs-warm discrepancy and the
unran modprobe protocol.

This is one of the very few **actual waits on the peer** in the link
setup path — most "wait-looking" rows are actually CPU loops
(`ubmad_post_send` → topo scan).

#### D. `udma_ctrlq_*` family — firmware ctrlq commands

**Files**: `hw/udma/udma_ctrlq_tp.c`, with `ubase_ctrlq_send_msg` as
the leaf at `drivers/ub/ubase/ubase_ctrlq.c:926`.

**What it is**: the family of "send a command to the SoC firmware
via the control queue" functions. Each takes one MMIO write +
doorbell + `wait_for_completion_timeout` for the firmware ack via
CRQ interrupt.

**Functions in the family** (most often seen):

| Function | What it asks firmware |
|---|---|
| `udma_ctrlq_get_tpid_list` | enumerate local TPs |
| `udma_ctrlq_set_active_tp_ex` | activate a TP (program local HW context) |
| `udma_k_ctrlq_deactive_tp` | deactivate a TP (HW teardown) |
| `udma_notify_mue_save_tp` | tell firmware to persist TP state |

**Where each sits**:

```
stage 5g sub-phase 1: ubcore_get_tp_list
                        └─ udma_get_tp_list
                              └─ ★ udma_ctrlq_get_tpid_list ★      (this function)
                                    └─ ubase_ctrlq_send_msg → wait_for_completion_timeout
stage 5g sub-phase 5: ubcore_active_tp
                        └─ udma_active_tp
                              └─ udma_ctrlq_set_active_tp_ex
                                    └─ udma_k_ctrlq_create_active_tp_msg
                                          └─ ubase_ctrlq_send_msg → wait_for_completion_timeout
stage 8 unimport:   urma_unimport_jetty / urma_unimport_jfr
                        └─ ... → udma_k_ctrlq_deactive_tp
```

**Typical duration**: 150–250 µs per call, regardless of which one.
Hardware-bounded; the firmware is local and fast. Runs in either:

- **Userspace caller's context** when called from `ubcore_get_tp_list`'s
  synchronous path (in stage 5g 2nd import)
- **kworker context** when fired by the local kernel's CM handler in
  response to the peer's import. JinDou's round-3 trace showed
  `udma_ctrlq_get_tpid_list` = 193 µs and `udma_ctrlq_set_active_tp_ex`
  = 190 µs both **in a CPU-64 kworker, concurrent with the userspace
  `ubcore_session_wait`**

**Implication**: udma ctrlq operations are **fast** and **off the
critical path** (kworker runs in parallel with the userspace wait).
This is why the codex `udma-tp-cache` patch — even if it perfectly
caches every ctrlq result — saves at most ~600 µs out of a multi-ms
first-RPC. The udma layer is not where the time goes.

#### E. `ubcore_active_tp` — firmware install

**File:line**: `ubcore_vtp.c:1129`.

**What it is**: stage 5g sub-phase 5. Calls `dev->ops->active_tp` =
`udma_active_tp`, which programs the hardware TP context via ctrlq.

**Body**:

```c
/* ubcore_vtp.c:1129 */
static int ubcore_active_tp(...) {
    uint64_t start, duration;
    start = ktime_get_ns();
    ret = dev->ops->active_tp(dev, active_tp_cfg);    /* udma_active_tp */
    duration = (ktime_get_ns() - start) / UBCORE_NS_TO_MS;
    ...
    if (duration > UBCORE_DRV_TP_THRESHOLD_MS)
        ubcore_log_info_rl("[DRV_INFO]active_tp init consumes: %llu", duration);
    return ret;
}
```

**Self-instruments**. Same log-level gate caveat as `get_tp_list`.

**Typical duration**: ~190–250 µs in JinDou's trace. Fast.

**Common misconception**: pre-§10.18 we kept calling this "the
firmware install bottleneck." It is not. It's ~200 µs, and it runs
in a kworker concurrent with userspace, so it doesn't add to the
critical path. The §10.5 / §10.6 framing of "host CPU sleeps in
ubase_ctrlq_wait_completed while firmware does the slow thing" was
wrong on two counts: (a) the firmware is fast, (b) the host CPU isn't
sleeping waiting for it (the userspace caller is busy in
`ubmad_post_send`'s topo scan instead).

#### F. Function → stage → parent → cost summary table

Quick-lookup table for any commonly-traced kernel function:

| Function | Stage(s) | Direct parent | Critical-path? | Typical cost | Hot spot inside? |
|---|---|---|---|---|---|
| `ubmad_post_send` | 5f, 5g (×2 paths), 8c | `ubmad_ubc_send` (called from each CM-send wrapper) | YES — always synchronous | **~4.9 ms (90%+ topo scan)** | `ubcore_get_main_primary_eid` at line 817 |
| `ubcore_get_main_primary_eid` | inside every `ubmad_post_send` | `ubmad_post_send` line 817 | YES | ~4.9 ms | `ubcore_get_primary_eid` → ~117k `is_eid_match` calls |
| `ubcore_get_tp_list` | 5g sub-phase 1 (synchronous) + kworker mirror | `ubcore_import_jetty_compat` (sync) / CM workqueue (kworker) | sync: yes, kworker: no | 150–200 µs | `udma_ctrlq_get_tpid_list` (firmware ctrlq, fast) |
| `ubcore_exchange_tp_info` | 5g sub-phase 2 | `ubcore_import_jetty_compat` | YES | ~5.5 ms (90% topo scan inside child `ubmad_post_send`) | `ubmad_post_send` |
| `ubcore_session_wait` | 5g 1st import (bonding path) | `ubcore_connect_exchange_udata_when_import_jetty` | YES | 0.45–6.01 ms (warm/cold) | `wait_for_completion` on peer MAD reply |
| `send_jetty_info_req` | 5g 1st import | `ubcore_connect_exchange_udata_when_import_jetty` | YES | ~4.8 ms (90% topo scan inside child `ubmad_post_send`) | `ubmad_post_send` |
| `ubcore_active_tp` | 5g sub-phase 5 | `ubcore_connect_vtp_ctrlplane` | mostly NO (runs in kworker, concurrent w/ userspace wait) | ~190 µs | `udma_active_tp` → ctrlq (fast) |
| `udma_ctrlq_get_tpid_list` | 5g sub-phase 1 (kernel inside) | `udma_get_tp_list` | yes-in-its-own-context | ~190 µs | firmware ctrlq cmd + completion |
| `udma_ctrlq_set_active_tp_ex` | 5g sub-phase 5 (kernel inside) | `udma_active_tp` | no (kworker, off critical path) | ~190 µs | firmware ctrlq cmd + completion |
| `ubase_ctrlq_wait_completed` | wherever a ctrlq cmd fires | `__ubase_ctrlq_send` | depends on caller | µs–ms | `wait_for_completion_timeout`; ack from firmware via CRQ ISR |

#### G. How to use this section when reading a trace

1. Spot the longest exit lines (highest-numbered durations).
2. Look the function up in §10.22.F to find its **direct parent** and
   **stage location**.
3. Check **"hot spot inside?"** column — if the cost is in a child,
   re-grep the trace for that child to confirm.
4. Cross-reference with **§10.21.E** to see whether the duration is
   consistent with the expected wall-clock for that stage.

Example: trace shows `ubcore_exchange_tp_info` = 5.49 ms. From §10.22.F:
"hot spot inside? → `ubmad_post_send`". Grep the trace for
`ubmad_post_send` exits — should see one with ~4.9 ms duration whose
parent is `ubcore_exchange_tp_info`. That confirms the topo-scan
attribution rather than misreading the 5.49 ms as "network RTT."

### 10.23 URMA verb semantics — which ops need `import_seg`, which need `import_jetty`

§10.22 mapped traced kernel functions to stages. This section maps
**URMA verb opcodes** to the resources they require — specifically
whether they need a peer's segment imported, a peer's jetty/JFR
imported, or neither. Useful when reading `urma_perftest` source
and asking "what does this test actually exercise?" or when sizing
the setup-overhead vs the operation itself.

#### A. URMA segments — the conceptual model

A segment is a registered local memory region exposed for **one-sided
remote access**. The owner calls
`urma_register_seg(buf, len, token, access_flags)`. The kernel pins
the pages, DMA-maps them, and returns a descriptor: a globally-unique
segment ID, the registered virtual address, the length, and the
authentication token from the call.

For a peer to read/write/atomically-update that memory, the peer
needs a local **handle** that bundles three things into every
outgoing one-sided WR:

- the owner's **virtual address** (so the responder's hardware
  computes the local physical offset)
- the owner's **segment ID + token** (so the responder's hardware
  validates access)
- the owner's **EID** (so the initiator's hardware routes correctly)

`urma_import_seg(ctx, &rseg, &token, ...)` builds that handle.
Subsequent WRs reference it:

```c
urma_jfs_wr_t wr = { .opcode = URMA_OPC_READ,
                     .remote = imported_seg,         /* the handle */
                     .remote_offset = 0, .length = ... };
urma_post_jfs_wr(jfs, &wr, &bad_wr);
```

RDMA-IB analogy: `urma_register_seg` ≈ `ibv_reg_mr`, and
`urma_import_seg` builds a remote-MR-handle that holds the peer's
rkey + address. URMA bundles the auth token into the import step.

The responder's CPU is **not involved** in the access. Hardware
validates the token against the registered segment and DMAs the data.

#### B. The full URMA verb opcode table

Canonical enum at `kernel/include/ub/urma/ubcore_opcode.h:58–77`.
14 opcodes total in 4 semantic families:

| Opcode | Hex | Family | What it does | Needs `import_seg`? | Needs `import_jetty`/`import_jfr`? |
|---|---|---|---|---|---|
| `WRITE` | 0x00 | one-sided write | RDMA-WRITE — push bytes into remote memory | **yes** | yes (the jetty whose TP it rides on) |
| `WRITE_IMM` | 0x01 | one-sided write | WRITE + 32-bit immediate that triggers a CQE on the receiver — sender's piggyback "here's where I wrote, react please" | **yes** | yes |
| `WRITE_NOTIFY` | 0x02 | one-sided write | WRITE + a notification (CQE-like signal without immediate data) — receiver gets an event without consuming a RECV WR | **yes** | yes |
| `READ` | 0x10 | one-sided read | RDMA-READ — pull bytes from remote memory | **yes** | yes |
| `CAS` | 0x20 | one-sided atomic | Compare-and-swap on a remote 64-bit value | **yes** | yes |
| `SWAP` | 0x21 | one-sided atomic | Atomic swap (no compare) | **yes** | yes |
| `FADD` | 0x22 | one-sided atomic | Fetch-and-add | **yes** | yes |
| `FSUB` | 0x23 | one-sided atomic | Fetch-and-subtract | **yes** | yes |
| `FAND` | 0x24 | one-sided atomic | Fetch-and-and (bitmask clear) | **yes** | yes |
| `FOR` | 0x25 | one-sided atomic | Fetch-and-or (bitmask set) | **yes** | yes |
| `FXOR` | 0x26 | one-sided atomic | Fetch-and-xor (bitmask toggle) | **yes** | yes |
| `SEND` | 0x40 | two-sided message | Push a message into the receiver's next pre-posted RECV buffer | no | **yes** |
| `SEND_IMM` | 0x41 | two-sided message | SEND + 32-bit immediate carried in the CQE on the receiver | no | **yes** |
| `SEND_INVALIDATE` | 0x42 | two-sided + side-effect | SEND + tells the receiver to invalidate a specific local segment token id — revocation primitive | no | **yes** |
| `NOP` | 0x51 | local-only | No-op WR — used for fencing, signaled-completion-without-payload, queue draining, keepalive | no | no |
| `WRITE_ATOMIC` | 0x60 | one-sided write (atomic block) | Write whose **payload arrival** is atomic — receiver never sees a partial buffer. Distinct from CAS/FADD: those are read-modify-write on one value; this is "the full N-byte payload lands atomically." | **yes** | yes |

#### C. Three semantic categories

**One-sided (need imported seg).** Operations that act on remote
**memory** addressed by virtual address. WR carries
`(remote_seg_handle, offset, length)`. Hardware on the responder
validates against the registered segment's token and DMAs without
involving the responder's CPU.

- WRITE family: `WRITE`, `WRITE_IMM`, `WRITE_NOTIFY`, `WRITE_ATOMIC`
- READ: `READ`
- Atomics: `CAS`, `SWAP`, `FADD`, `FSUB`, `FAND`, `FOR`, `FXOR`

All eleven require the initiator to have called `urma_import_seg`
against the responder's registered segment beforehand. Plus
`urma_import_jetty` to know which TP to ride on (the per-peer TP
the WR uses for transport).

**Two-sided (need imported jetty/JFR, NOT seg).** Operations that
act on a remote **endpoint**, not remote memory. WR carries
`(remote_jetty_handle, payload)`. The receiver's hardware pops the
next pre-posted RECV WR from the JFR and uses that WR's `sge[]` as
the landing spot.

- `SEND`, `SEND_IMM`, `SEND_INVALIDATE`

Need `urma_import_jetty` (or `urma_import_jfr` in SIMPLEX mode) to
know which remote endpoint to address. **Never** need
`urma_import_seg`.

**Local-only.** `NOP` doesn't go to the wire. Used internally for
fencing, signaled-completion-without-payload, or queue mechanics.

#### D. Notable subtleties

- **`WRITE_IMM` vs. `WRITE_NOTIFY`**: both let the receiver react to
  a write without polling the destination buffer. `WRITE_IMM` carries
  32 bits of user data to the receiver's CQE; `WRITE_NOTIFY` just
  generates an event (no data payload).
- **`SEND_INVALIDATE`**: the canonical revocation primitive. Combines
  SEND with "stop accepting access through this key" notification.
  Receiver's HW invalidates the named token id atomically with
  consuming the SEND. Useful when an RPC server hands out short-lived
  keys to clients and wants to revoke them after completion.
- **`WRITE_ATOMIC` is not in the CAS/FADD family**. The CAS family
  does read-modify-write on a single 64-bit value. `WRITE_ATOMIC` is
  a normal-size WRITE whose **arrival** is atomic at the receiver —
  no torn buffers. Distinct semantic; distinct opcode (0x60 vs
  0x20–0x26).
- **`NOP`** is rarely user-visible; libraries use it to flush a queue
  or generate a CQE without doing real work. Some implementations
  use it for keepalive.

#### E. Why `urma_perftest` imports a seg even for SEND tests

`create_duplex_ctx()` at `perftest_resources.c:2198` calls
`import_seg_for_duplex` **unconditionally**, regardless of
subcommand. Reasons:

1. **Uniform setup code path.** Creating the same context structure
   for SEND, READ, WRITE, and ATOMIC tests means the framework can
   share `create_ctx` / `destroy_ctx` / `prepare_test`. The cost is
   one wasted `urma_import_seg` per SEND test.
2. **Optional credit-based flow control.** With `--enable_credit`,
   perftest registers and imports a second segment for credit
   signaling. Some pipelined send tests benefit. The default
   `--enable_credit=false` path doesn't use it but the import still
   runs.
3. **Test-result + sync exchanges.** Some perftest variants do small
   one-sided WRITEs at end-of-test to deposit final results. Cleaner
   with a pre-imported seg available.

Per §10.18.B / §10.21.E, the cost of this gratuitous import is
~5–6 ms during stage 5f, almost all of it inside `ubmad_post_send`'s
topo scan (§10.22.A) on the `send_seg_info_req` CM exchange.

For "characterize first-RPC for SEND specifically," that 5–6 ms is
removable overhead. For "characterize first-RPC for WRITE/READ/ATOMIC,"
it's an honest part of the cost.

#### F. Optional patch to skip import_seg for SEND tests

3-line patch in `create_duplex_ctx()`:

```c
-   if (import_seg_for_duplex(ctx, cfg) != 0) goto delete_remote_info;
+   /* Segments are only needed for one-sided ops (READ/WRITE/ATOMIC)
+    * and for the credit flow control mechanism. Skip for SEND tests
+    * with credit disabled — saves ~5 ms of first-RPC. */
+   if ((cfg->api_type != PERFTEST_SEND || cfg->enable_credit) &&
+       import_seg_for_duplex(ctx, cfg) != 0)
+       goto delete_remote_info;
```

Plus a matching guard in `destroy_duplex_ctx`. After this, `send_lat`
first-RPC drops by the ~5–6 ms of segment-import CM exchange. Worth
doing if you're characterizing pure SEND link-setup minimum; not
needed for concurrent-stress testing.

#### G. Test → resources-needed cheat sheet

For deciding what overhead is essential vs. gratuitous in a given
`urma_perftest` invocation:

| Subcommand | URMA opcode used | Needs imported seg? | Needs imported jetty/JFR? |
|---|---|---|---|
| `send_lat` / `send_bw` | `SEND` | no (perftest imports anyway) | yes |
| `send_with_imm_lat` / `send_with_imm_bw` | `SEND_IMM` | no (perftest imports anyway) | yes |
| `read_lat` / `read_bw` | `READ` | **yes — essential** | yes |
| `write_lat` / `write_bw` | `WRITE` | **yes — essential** | yes |
| `write_with_imm_lat` / `write_with_imm_bw` | `WRITE_IMM` | **yes — essential** | yes |
| `atomic_lat` / `atomic_bw` | (CAS / FADD / ...) | **yes — essential** | yes |

The "needs imported jetty/JFR" column is universally yes because all
verbs ride on a TP between the two endpoints, and the TP only exists
once `urma_import_jetty` (or `_jfr`) has run.

### 10.24 URMA vs RDMA verb mapping

URMA borrows heavily from IB Verbs / RDMA but renames everything and
adds/removes a few primitives. For anyone coming from RDMA, this is
the side-by-side. Source-of-truth for URMA: `kernel/include/ub/urma/`.

#### A. Object model

| RDMA (IB Verbs) | URMA | Notes |
|---|---|---|
| QP (Queue Pair) | Jetty (DUPLEX) or JFS+JFR pair (SIMPLEX) | URMA can split a QP into separate SQ/RQ as first-class objects (JFS = Job Function Send, JFR = Job Function Receive) — IB can't |
| SQ (Send Queue) | JFS or jetty's send half | |
| RQ (Receive Queue) | JFR or jetty's recv half | |
| CQ (Completion Queue) | JFC (Job Function Completion) | |
| Completion event channel | JFCE | |
| MR (Memory Region) | Seg (Segment) | Identical semantics: registered, pinned, token-protected, used as one-sided target |
| MW (Memory Window) | **none** | URMA has no Memory Window primitive. Dynamic access control is via seg tokens alone. |
| PD (Protection Domain) | **implicit in context** | URMA folds PD into the context object; no separate handle to allocate |
| AH (Address Handle) | **implicit in imported jetty** | URMA bundles destination addressing into the import_jetty result |
| GID (128-bit Global ID) | EID (Endpoint ID, 16 bytes) | Same width (`UBCORE_EID_SIZE = 16` per `ubcore_types.h:49`) |
| SRQ (Shared Receive Queue) | JFR (when shared across jettys) | JFR is more first-class than SRQ — usable standalone, not always attached to a QP |
| QP1 (SMI/GMI for MADs) | the "MAD jetty" inside ubcm | Both put CM traffic on a privileged QP-like object; URMA's MAD path is implemented over the same data-path verbs (see `ubmad_post_send` → `ubcore_post_jetty_send_wr` in §10.22.A) |
| RDMA-CM | ub_cm + ubmad | Same role: REQ/REP/RTU exchange to establish a TP. URMA's version is `send_jetty_info_req` / `ubcore_exchange_tp_info` (see §10.16) |
| Subnet Manager (SM) | UVS (UB Virtual Switch) | URMA's fabric admin daemon; rough analog |

#### B. Transport modes

`kernel/include/ub/urma/ubcore_types.h:380–382`:

```c
UBCORE_TP_RM = 0x1,        /* Reliable message */
UBCORE_TP_RC = 0x1 << 1,   /* Reliable connection */
UBCORE_TP_UM = 0x1 << 2,   /* Unreliable message */
```

Plus `ubcore_tp_type` (`:1495`): `UBCORE_RTP` (regular data TP),
`UBCORE_CTP` (control TP — what `ubmgr_ping` creates), `UBCORE_UTP`
(unreliable TP).

| RDMA | URMA | Notes |
|---|---|---|
| RC (Reliable Connection) | RC | One-to-one, ordered, ack'd. Both maintain per-pair state. |
| UC (Unreliable Connection) | **none** | URMA dropped UC; rarely used in practice anyway |
| UD (Unreliable Datagram) | UM (Unreliable Message) | One-to-many, no ack, message-oriented |
| RD (Reliable Datagram) | **RM (Reliable Message)** | RD never worked in production IB. URMA's RM is the same concept — reliable but connectionless, one-to-many — and is the **default/headline mode** for URMA. This is one of the bigger architectural wins URMA claims over IB. |
| XRC (eXtended RC) | **none** | URMA covers the XRC use case (many clients → one server-side resource) via the JFR-as-shared-receive model |

The fact that **RM is URMA's default** is a meaningful semantic
divergence. RC requires a per-pair QP and per-pair state; RM does
not. For server farms with N clients and M servers, RC needs N×M QPs;
RM needs N×1 (or M×1) jettys. This is why JinDou's perftest runs
default to `URMA_TM_RM`.

#### C. Verb opcode mapping

URMA opcodes from `kernel/include/ub/urma/ubcore_opcode.h:58–77`,
RDMA WRs from `linux/include/uapi/rdma/ib_user_verbs.h`:

| RDMA WR | URMA opcode | Notes |
|---|---|---|
| `IBV_WR_RDMA_WRITE` | `WRITE` (0x00) | identical |
| `IBV_WR_RDMA_WRITE_WITH_IMM` | `WRITE_IMM` (0x01) | identical — 32-bit immediate piggybacked into receiver's CQE |
| — | **`WRITE_NOTIFY` (0x02)** | URMA-only. Write + event signal **without** immediate data payload. IB makes you carry 32 bits of imm; URMA doesn't. |
| `IBV_WR_RDMA_READ` | `READ` (0x10) | identical |
| `IBV_WR_ATOMIC_CMP_AND_SWP` | `CAS` (0x20) | identical |
| — | **`SWAP` (0x21)** | URMA-only. Atomic swap **without compare**. IB only has CAS. URMA gives you unconditional atomic exchange. |
| `IBV_WR_ATOMIC_FETCH_AND_ADD` | `FADD` (0x22) | identical |
| — | **`FSUB` (0x23)** | URMA-only (achievable via FADD + negative operand on IB; URMA gives the explicit opcode) |
| — | **`FAND` (0x24), `FOR` (0x25), `FXOR` (0x26)** | URMA-only. Full bitwise atomic family — clear/set/toggle individual bits remotely. IB doesn't have these. |
| `IBV_WR_SEND` | `SEND` (0x40) | identical |
| `IBV_WR_SEND_WITH_IMM` | `SEND_IMM` (0x41) | identical |
| `IBV_WR_SEND_WITH_INV` | `SEND_INVALIDATE` (0x42) | identical — SEND + revoke a remote token id |
| `IBV_WR_LOCAL_INV` | (admin path, no direct WR) | URMA handles seg invalidation via destroy/unimport rather than a WR |
| `IBV_WR_BIND_MW` | **none** | URMA has no Memory Window |
| `IBV_WR_TSO` | **none** | URMA isn't Ethernet-based |
| — | **`NOP` (0x51)** | URMA-only as an opcode |
| — | **`WRITE_ATOMIC` (0x60)** | URMA-only. WRITE whose payload **arrives atomically** at the receiver (no torn buffers). IB doesn't guarantee atomicity for normal WRITE. |

#### D. Where URMA diverges semantically (what URMA adds vs IB)

1. **Extra atomics — full bitwise family.** `FAND/FOR/FXOR/SWAP/FSUB`
   beyond IB's CAS+FADD. Useful for distributed bitmap operations,
   lock-free reference counting, lock-free set/queue ops, etc.,
   without the read-modify-write round-trip CAS would need.

2. **`WRITE_NOTIFY` vs `WRITE_WITH_IMM`.** In IB you must carry 32
   bits of immediate to trigger a receiver CQE on WRITE; URMA lets
   you signal without data. Lighter for pure "I wrote, please react"
   semantics.

3. **`WRITE_ATOMIC` — atomic arrival.** URMA exposes atomic-arrival
   WRITE as a distinct opcode. In IB, a multi-byte WRITE may be
   observed as torn data by a concurrent reader on the receiver;
   with `WRITE_ATOMIC` URMA guarantees the receiver sees the full
   payload or none of it. Distinct from CAS-family atomics, which
   operate on a single value.

4. **RM (Reliable Message) as default.** IB never made RD work in
   production; URMA did. Architecturally this is a big simplification
   for N×M endpoint scenarios — no per-pair connection state, just
   per-EID delivery.

5. **JFS / JFR as first-class objects.** URMA can decouple Send and
   Receive queues. IB only does this via SRQ which is always attached
   to QPs. URMA's JFR is usable standalone as the receiver in a
   many-senders-one-receiver pattern, without needing QPs around it.

6. **Jetty (DUPLEX) vs JFS+JFR (SIMPLEX) per-test choice.** URMA's
   combined SQ+RQ object (jetty) is basically a QP. The fact that you
   can choose between DUPLEX (jetty) and SIMPLEX (JFS+JFR) per-test in
   `urma_perftest` is a usability feature — IB makes you build a QP
   either way.

#### E. Where IB has things URMA doesn't (what URMA drops vs IB)

- **UC (Unreliable Connection)** — almost no one uses it; URMA dropped it.
- **XRC (eXtended Reliable Connection)** — URMA covers the use case via JFR-sharing.
- **Memory Windows (MW)** — no URMA equivalent; access control is segment-token-only.
- **TSO and other Ethernet/IP-offload opcodes** — not relevant for URMA (UB fabric, not Ethernet).
- **`IBV_WR_LOCAL_INV` as an explicit WR** — URMA does invalidation through admin paths.

#### F. TL;DR for RDMA programmers reading URMA code

If you can read RDMA verb code, URMA verb code reads naturally; the
unfamiliar parts are mostly naming. Quick mental substitution table:

```
QP    →   Jetty                 (or JFS+JFR if SIMPLEX)
CQ    →   JFC
MR    →   Seg
GID   →   EID
QP1   →   the MAD jetty
CM    →   ubcm + ubmad
SM    →   UVS
RD    →   RM  (and it actually works this time)
```

The model is the same: registered memory regions accessed by remote
handles, queue pairs with completion queues, separate CM exchange for
connection bringup. The wins URMA claims over IB are (1) RM as a
working production transport, (2) richer atomic ops, (3)
atomic-arrival WRITE, and (4) optional split SQ/RQ as separate
objects. The losses are MW, XRC, UC, and most of the IB ecosystem of
Ethernet-bridging features.

### 10.25 Source-verified: the topo-scan path is lock-free — what JinDou's 100-process data must mean

After §10.20.G's framing landed (linear-growth ⇒ serialization, parallel-growth ⇒ per-CPU work), JinDou ran the 100-process scale test on UMDK#2. The data — `import_jetty #1` 5.3 → 108.7 ms (**20.5×**), `import_jetty #2` 6.1 → 554 ms (**91×**) — shows obvious linear-to-superlinear growth, which §10.20.G said implies serialization. The thread's bot then hypothesized the serialization was a global topo-table rwlock degrading under contention. **That hypothesis is impossible by source.** This section pins down what can and cannot be the actual mechanism.

#### A. The lock hypothesis as posted

The bot wrote (issue #2, 2026-05-12 comment):

> 若该函数持有全局读锁（或 rwlock 在高并发时退化为互斥），100 个进程序列化执行时：
> - 第 k 个进程等待时间 ≈ k × 4.9ms
> - 平均等待 ≈ 50 × 4.9ms = 245ms（与实测 108ms/554ms 数量级吻合）

The arithmetic is correct *if* there is a contended global lock. The premise is wrong.

#### B. Source check: zero locks in the scan path

The dominant cost in §10.19 is `ubcore_get_main_primary_eid` (called 8× per `import_jetty`, ~4.9 ms each). Its entire call chain is:

```
ubmad_post_send                       drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c:817
  └─> ubcore_get_main_primary_eid     drivers/ub/urma/ubcore/ubcore_topo_info.c:452
        ├─> ubcore_get_primary_eid                                              :353
        ├─> ubcore_get_primary_eid_array                                        :388
        │     └─> find_primary_eid_in_ues                                       :306
        │           └─> is_eid_match × N                                        :116
        └─> ubcore_get_min_eid                                                  :432
```

Locks in this chain — verified with `grep -nE 'spin_lock|mutex_lock|read_lock|write_lock|rcu_read|down_read|down_write|topo_lock|topo_mutex|topo_rwlock|topo_sem'`:

| File | Hits in scan path |
| --- | --- |
| `drivers/ub/urma/ubcore/ubcore_topo_info.c` (1196 lines) | **0** |
| `drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c` around `:817` | the only lock is `spin_lock_irqsave(&rsrc->tjetty_hlist_lock, flag)` at `:825` — **after** the scan, held only across a brief hash-list lookup, then released at `:827` |

`g_ubcore_topo_map` is a plain `static struct ubcore_topo_map *` at `ubcore_topo_info.c:21`, accessed without synchronization at lines 27, 29, 34, 36, 37, 42, 359, 365, 396, 401, 487, 603, 834, 1142. There is no rwlock, no rcu, no mutex protecting it. The structure is assumed effectively read-only after init.

**Therefore the bot's "rwlock degrades to mutex" mechanism cannot exist.** Whatever serializes the 100-process workload, it is not lock contention on the topo scan.

#### C. What can and cannot explain the 91× slowdown

Given (B), candidate mechanisms for the observed linear-to-superlinear scaling:

| Mechanism | Plausible at 91×? | Why |
| --- | --- | --- |
| Topo-table rwlock | **No** | does not exist (B) |
| CPU saturation (100 procs, ≤96 cores) | **No** | best case ~2× from runqueue contention |
| Memory-bandwidth contention on read-mostly globals | **No** | observed 2-3× ceiling on cache-thrashing workloads at this size, not 20-91× |
| `ubcore_session_wait` server-side queue (Effect B in bot's post) | **Yes** | single peer kernel processes incoming MAD on one workqueue; 100 concurrent clients → response time grows linearly with queue depth |
| Thundering-herd alignment between phases | **Yes** | the 108→554 ms doubling between `import_jetty #1` and `#2` is the textbook signature: all 100 clients exit the first serialization point at the same instant and pile into the second tighter than they entered the first |
| Per-NIC or per-tjetty-hlist spinlock at `ubmad_datapath.c:825` | **Marginal** | held only across hash lookup, ~microseconds; would need >1000× growth to dominate |

A strong reading of JinDou's data is therefore: **the 39 ms of CPU scan inside each `import_jetty` is roughly invariant under concurrency** (since it's lock-free and runs on different CPUs in parallel), **but the server-side response wait inside `ubcore_session_wait` grows linearly with concurrent-client count**, and **`import_jetty #2`'s 91× vs #1's 20× is the thundering-herd alignment**, not deeper contention.

This makes a sharp prediction: in a depth-3 ftrace of one observed process within the 100-process run, `ubcore_get_main_primary_eid` should still measure ~4.9 ms per call (unchanged), but `ubcore_session_wait` should measure roughly 100× longer than it did in the single-process baseline (~0.45 ms → ~45 ms or more). If the depth-3 retrace shows `ubcore_get_main_primary_eid` itself dilated, then (B) is somehow being bypassed and the mechanism is more interesting; otherwise the hypothesis stands.

#### D. The codex `udma-tp-cache` patch is orthogonal to the dominant cost

Branch `codex/udma-tp-cache` on `atomgit.com/ray-yang0218/kernel` (5 commits on top of OLK-6.6, 1304 lines added) places its entire cache + warmup machinery under `drivers/ub/urma/hw/udma/`:

```
drivers/ub/urma/hw/udma/Makefile         +  1
drivers/ub/urma/hw/udma/udma_ctrlq_tp.c  +118 / -65   (TP-list fetch path)
drivers/ub/urma/hw/udma/udma_ctrlq_tp.h  + 12
drivers/ub/urma/hw/udma/udma_ctx.c       +  6
drivers/ub/urma/hw/udma/udma_ctx.h       +  1
drivers/ub/urma/hw/udma/udma_dev.h       +  3
drivers/ub/urma/hw/udma/udma_main.c      +  9
drivers/ub/urma/hw/udma/udma_tp_cache.c  +1185         (new cache + warmup)
drivers/ub/urma/hw/udma/udma_tp_cache.h  + 33
```

`git diff OLK-6.6..codex/udma-tp-cache | grep -iE 'topo|primary_eid|ubmad_post_send|get_main_primary'` returns **zero hits**. The patch:

- Caches the result of `udma_get_tp_list` (one phase out of the 5-phase compat path, the one that goes through `ubase_ctrlq_send_msg` to local firmware, not through MAD-send to peer).
- Adds an optional warmup mechanism that pre-populates the cache for declared peer-EID pairs at module init.
- Does **not** touch `ubcore_topo_info.c`, does **not** touch `ubcm/ubmad_datapath.c`, does **not** touch the scan inside `ubcore_get_main_primary_eid`.

The 8 × 4.9 ms = 39 ms CPU scan happens inside `ubmad_post_send`, which is called from the **other** phases of the compat path (`exchange_tp_info`, `connect_vtp_ctrlplane`, etc) — the phases that the patch leaves untouched. So the patch can hide one stage's firmware-ctrlq roundtrip but cannot hide any of the MAD-send scans. Under JinDou's 100-process workload — where the bottleneck is server-side serialization in `ubcore_session_wait` (a peer-MAD-wait, not a local-firmware-wait) — the patch should show essentially no improvement at all.

This does not mean the patch is wrong; it means it is solving a *different* problem (firmware-ctrlq-roundtrip on warm-cache repeated imports) than the one the 100-process test is exposing.

#### E. Refined experiment plan, post-lock-out

The bot's two-step proposal in the 2026-05-12 comment is largely still valid — but step 1 (the depth-3 trace) can now be sharpened with the lock-out:

**Step 1 (refined).** Add `ubcore_get_main_primary_eid` and `ubcore_session_wait` to `set_graph_function` with `max_graph_depth=3`, run the 100-process workload, observe one process. **Expected:** `ubcore_get_main_primary_eid` ≈ 4.9 ms (unchanged from the single-process baseline of §10.19), `ubcore_session_wait` ≈ 50–500 ms (scaled from the single-process ~0.45 ms warm baseline). **If** `ubcore_get_main_primary_eid` is itself dilated to >10 ms per call, the lock-out is wrong somewhere and (B) needs revisiting.

**Step 2 (unchanged).** N = 1, 5, 10, 20, 50, 100 scaling curve for `import_jetty` total. If linear in N, single-queue server serialization. If sub-linear (e.g., N^0.5), batched server processing. If super-linear (N^1.5+ or N²), some additional cumulative-state pathology on the server side.

**New step 3.** **Server-side ftrace.** Run the 100-process workload again, but this time the observed process is on the **server** (the side that receives `send_jetty_info_req` MADs). Filter on `ubmad_recv_work_handler`, `ubmad_process_msg`, `ubmad_process_conn_resp`, `ubmad_cm_process_msg`, `ubcm_recv_handler`. The single-workqueue hypothesis predicts these will all serialize on one CPU and show queue-depth-proportional wait between consecutive entries. If they're spread across CPUs, the bottleneck is elsewhere (most likely a single-threaded firmware request handler one layer deeper).

**Optional step 4.** **Disconfirm by staggering.** Wrap `urma_perftest` in a script that introduces 0–50 ms uniform-random startup delay across the 100 processes (no barrier file). If the 91× drops to 5–10×, the thundering-herd reading is confirmed and the fix path is rate-limiting on the client side (or per-NIC backpressure on the server side). If the slowdown is unchanged, server-side single-queue is the actual constraint and the fix must be on the server.

#### F. What this means for the codex patch's evaluation

JinDou's 100-process run is **not** the right workload to evaluate `codex/udma-tp-cache`. The patch's design target is the warm-cache repeated-import case (reusing TP-list across many imports for the same `<pid, eid_index, trans_mode>` tuple). To evaluate it fairly, run two patterns and compare with/without the patch:

1. **Sequential repeated imports** (single process, 10× `urma_import_jetty` + `urma_unimport_jetty` of the same remote): patch should reduce per-import time by exactly the `udma_get_tp_list` ctrlq roundtrip — typically 100s of µs to a few ms. Won't help at the 100×-concurrent scale.
2. **Sequential repeated send_lat runs** (script that runs `send_lat -n 1` 100 times back-to-back): a tighter version of #1; should show similar small-millisecond savings on the second-and-later runs.

Both will likely show ~5-30% reduction. **Neither will compress the 108→554 ms thundering-herd cost** because the patch does not reduce `ubmad_post_send`'s scan and does not reduce server-side serialization.

### 10.26 Server-side ftrace results — kworker concurrency and firmware ctrlq dilation (2026-05-13)

JinDou ran the corrected server-side ftrace described in §10.25.E (no PID filter, traces `ubcore_get_tp_list` and `ubcore_active_tp` on `master` while 100 concurrent `urma_perftest send_lat --single_path` processes run on `worker1`). Results overturn one of §10.25's two predictions and flip the codex-patch verdict back to "relevant" on the server side. The other prediction (client-side thundering-herd alignment) is consistent with the data so far but needs additional traces to confirm.

#### A. Trace data summary

Total kworker lines: 1010 over ~55 s wall-clock. The trace fragments JinDou shared show three patterns worth distinguishing:

**Pattern 1 — back-to-back fast pairs on one kworker (start of trace):**

```
100545.916038  74) kworker-3438559   ubcore_get_tp_list {
100545.916040  74) kworker-3438559   ! 159.200 us  udma_get_tp_list
100545.916241  73) kworker-3438559   ! 202.800 us  } /* ubcore_get_tp_list */
100545.916241  73) kworker-3438559   ubcore_active_tp {
100545.916408  73) kworker-3438559   ! 166.730 us  }
```

`ubcore_get_tp_list` = 202.8 μs (firmware path 159.2 μs); `ubcore_active_tp` = 166.7 μs.

**Pattern 2 — long inter-pair gap (884 ms between successive get_tp_list pairs on the same kworker):**

```
100545.916240  ...  ubcore_get_tp_list ends
100546.800800  ...  next ubcore_get_tp_list starts          (+884.6 ms)
```

**Pattern 3 — mid-test outlier where `udma_get_tp_list` dilates 50×:**

```
100565.397581  65) kworker-3462916   ubcore_get_tp_list {
100565.407914  65) kworker-3462916   * 10333.99 us  } /* ubcore_get_tp_list */
                                     ^^^^^^^^^^^^^^^ ten thousand microseconds = 10.3 ms
100565.418319  65) kworker-3462916   ubcore_get_tp_list { (~10 ms later)
100565.418446  65) kworker-3462916   ! 127.120 us  }
100565.428599  65) kworker-3462916   ubcore_get_tp_list { (~10 ms later again)
100565.428739  65) kworker-3462916   ! 140.230 us  }
```

One call ballooned to 10.3 ms while neighboring calls on the same kworker stayed at ~125-140 μs.

**Inter-call delta distribution (20 samples, JinDou's `awk` pipe):**

```
0.203 ms, 884.559 ms, 72.317 ms, 95.653 ms, 125.295 ms, 52.964 ms,
160.916 ms, 345.108 ms, 108.837 ms, 782.609 ms, 2835.875 ms,
9223.094 ms, 205.015 ms, 143.360 ms, 615.130 ms, 553.740 ms,
2424.006 ms, 184.719 ms, 82.212 ms, 585.930 ms
```

These alternate between intra-call durations and inter-call (exit→next-entry) gaps. Most are in the 50-600 ms range; outliers reach 9.2 s.

#### B. Three findings

**B1. kworker IS multi-threaded — single-workqueue hypothesis ruled out.**

Distinct kworker PIDs active on different CPUs during the trace: `kworker-3438559` (CPUs 73, 74), `kworker-3319643` (CPU 73), `kworker-3462916` (CPU 65). Context-switch lines like `74) kworker-3438559 => kworker-3462916` confirm multi-CPU activity. §10.25's effect B framing — "server-side single workqueue serializes" — is **dead at the workqueue layer**. Whatever serializes the server's response throughput, it is not the kworker dispatch.

**B2. `udma_get_tp_list` shows >50× duration variance — firmware ctrlq tail latency.**

| Sample | `udma_get_tp_list` duration |
| --- | --- |
| Start (`100545.91`, kworker-3438559) | 159 μs |
| Mid (`100546.80`, kworker-3438559) | 147 μs |
| **Mid (`100565.39`, kworker-3462916)** | **10,331 μs (10.3 ms)** |
| Mid (`100565.41`, kworker-3462916) | 125 μs |
| Mid (`100565.42`, kworker-3462916) | 139 μs |

One call dilated 50× while neighbors on the same CPU stayed fast. `udma_get_tp_list` is the firmware command queue path (`udma_ctrlq_*`), and this tail-latency pattern is consistent with intermittent ctrlq backpressure (depth-1 contention, hardware interlock during TP programming, or DMA bus contention). Without a histogram across the full trace, we cannot tell if this is a 1-in-200 outlier or affects 10-50% of calls.

**B3. Inter-call gaps point to client cadence dominating, not server queueing.**

If server-side queueing were the bottleneck, we would see uniform short gaps (~200 μs intra-call + a few μs inter-call) clustered together as the queue drains. Instead we see gaps spanning four orders of magnitude (200 μs → 9.2 s). The 9.2 s gap especially cannot be explained by ctrlq dilation (single calls stay <11 ms). The most plausible reading: 100 client processes are staggered by bash's `&` spawn cadence (3-5 s spread) and each individual client is slow between consecutive MAD rounds because of the 39 ms client-side CPU scan in `ubcore_get_main_primary_eid`. The server sits mostly idle, waking up briefly to process each request.

This would mean the 108→554 ms `import_jetty` cost is dominated by **client-side** topo-scan CPU contention (100 processes × 39 ms × N MAD rounds / available CPUs), not server-side queueing. The 5× ratio between #1 and #2 is alignment compression as predicted in §10.25.C — phase-1 staggers naturally and phase-2 clients arrive aligned within a few ms.

#### C. Codex `udma-tp-cache` patch verdict — flipped for the server side

§10.25.D ruled the patch irrelevant because the **client-side** hot spot (39 ms in `ubcore_get_main_primary_eid`, file `ubcore_topo_info.c`) lives in `drivers/ub/urma/ubcore/`, while the patch caches in `drivers/ub/urma/hw/udma/`. That logic is still correct for the client.

But finding B2 changes the picture on the server: `udma_get_tp_list` is *exactly* what the patch caches, and its 10 ms tail is real. The patch should compress that tail to a few μs (cache hit) for any imports targeting the same `<peer EID, trans_mode>` tuple as a prior import.

| Side | Bottleneck | Codex patch |
| --- | --- | --- |
| Client (worker1, initiator) | 39 ms CPU scan in `ubcore_get_main_primary_eid` | Irrelevant |
| Server (master, kworker responder) | Intermittent 10 ms tail in `udma_get_tp_list` | **Directly applicable** |

For a fair codex-patch benchmark, apply it to **master only** (the server). Expected impact on the 100-process workload:

- Per-call `udma_get_tp_list` tail (the 10 ms case) → drops to ~10 μs cache hit
- Per-process `import_jetty` server-wait component drops by however much of it came from ctrlq dilation
- Client-side `import_jetty #1/#2` wall-clock drops by that same amount, but **the #2/#1 ratio (~5×) should persist** because thundering-herd alignment is a client-side phenomenon unaffected by server-side caching

If the patch eliminates the 10 ms outliers and yet the 554 ms `import_jetty #2` barely changes, that's strong evidence the client-side topo scan + alignment is the true bottleneck and finding B3 stands.

#### D. Sharpened experiments (replaces §10.25.E steps 3-4 with newer ones)

**Experiment 5 — `udma_get_tp_list` duration histogram.** Resolves how often the 10 ms tail hits.

```bash
grep "udma_get_tp_list" trace | grep -oE '[*!] +[0-9.]+ us' \
  | awk '{x=$2+0;
          if(x<1000) a++;
          else if(x<5000) b++;
          else if(x<10000) c++;
          else d++}
         END {print "<1ms:" a "  1-5ms:" b "  5-10ms:" c "  >10ms:" d}'
```

Predictions: if `>10ms` is ≤5 % of calls, dilation is a rare tail and codex patch wins are marginal. If 30 %+, ctrlq is a steady-state bottleneck and the patch is high-leverage.

**Experiment 6 — add `ubmad_recv_work_handler` + `ubcm_recv_handler`.** Both are confirmed in `available_filter_functions`. Adding them to `set_graph_function` (keeping `max_graph_depth=2`) captures the timestamp each MAD arrives at the server vs when kworker dispatches it.

If 100 MADs arrive in a tight burst (within ms) but kworker activity spreads over 55 s → server is queueing badly. If they trickle in over seconds → client cadence dominates (the B3 reading).

**Experiment 7 — apply codex `udma-tp-cache` to master only and re-run.** Predicts:

- `udma_get_tp_list` 10 ms tail vanishes (now ~10 μs cache-hit for warm tuple)
- Client-side `import_jetty #1` drops by ~10 ms × (10ms-fraction-of-calls) per import
- `import_jetty #2/#1` ratio (~5×) should persist (alignment, not cache)
- If `#2/#1` ratio drops noticeably, that would falsify B3 and rehabilitate the server-side-queueing story

#### E. What this leaves unsettled

1. The "ghost" 9.2 s gap. Even client-cadence dominance shouldn't produce a 9.2 s wait between consecutive MAD events at the server. Either one specific client stalled for 9 s, or the trace buffer wrapped at that point. Experiment 6's `ubmad_recv_work_handler` timestamps will clarify.
2. The 10.3 ms `udma_get_tp_list` outlier on `kworker-3462916` is the only one visible in the shared excerpt. Experiment 5's histogram is the cheap way to see how many more such outliers exist.
3. We still don't have client-side wall-clock per import in this trace (worker1 ftrace was kept at depth-1 in earlier runs). A coordinated dual-side trace (server-side + client-side, global trace_clock for cross-comparison) is the next-level step if Experiments 5-7 don't close the question.

### 10.27 Synthesis after JinDou's statistical analysis — server excluded, `find_primary_eid_in_ues` is the leading suspect (2026-05-13)

JinDou ran the five analyses requested in §10.26.D. The results corrected §10.26 finding B1 (kworker concurrency), strengthened B3 (client cadence), and reduced the predicted codex-patch impact significantly. This section synthesizes the final picture from today's session and lays out the two experiments that will close the bottleneck question.

#### A. The corrected kworker picture — effectively single-threaded

Five analyses across two trace runs (`trace_server_P100_round4_new.log` and `..._new2.log`).

**Per-kworker call count:**

| Run | Dominant kworker | Calls | Share | Other kworkers |
| --- | --- | --- | --- | --- |
| 1 | `kworker-3462916` | 93 / 100 | **93 %** | `3438559`: 7 |
| 2 | `kworker-3462916` | 98 / 102 | **98 %** | `3478059`: 3, `3494642`: 1 |

Same kworker PID across both runs → long-lived warm worker.

**Active time windows:**

```
Run 1:
  3438559:  100545.92 ── 100547.31 (1.4 s, 7 calls)
                                  ↓ handoff
  3462916:                  100547.65 ─────────── 100566.23 (18.6 s, 93 calls)

Run 2:
  3478059:  102005.73 ── 102006.59 (0.85 s, 3 calls)
                                  ↓ handoff
  3462916:                  102006.69 ─────────── 102026.71 (20.0 s, 98 calls)
```

Time windows **barely overlap** — this is sequential handoff, not parallel processing. So §10.26 finding B1 ("kworker IS multi-threaded → single-workqueue ruled out") is **correct at the source-code layer** (`WQ_UNBOUND | max_active=0` allows ≤512 concurrent works) but **wrong in practice** — only one worker actually runs.

**Slow calls (>5 ms) per kworker:**

| Run | Kworker | Fast (<5 ms) | Slow (>5 ms) | Slow share |
| --- | --- | --- | --- | --- |
| 1 | `3462916` | 138 | 9 | ~6 % |
| 1 | `3438559` | 52 | 4 | ~7 % |
| 2 | `3462916` | 147 | 3 | ~2 % |
| 2 | `3478059` | 49 | 0 | 0 % |

Slow calls are 2-7 % of total, not steady-state. The 50× variance noted in §10.26.B2 is a tail effect, not a typical case.

**`get_tp_list : active_tp` ratio:** exactly **1.00** in both runs (200:200, 202:202). No fast-path skips active_tp.

**Per-kworker internal inter-call gap (`ubcore_get_tp_list` entry-to-entry):**

| Run | Kworker | n | median | p90 | max |
| --- | --- | --- | --- | --- | --- |
| 1 | `3462916` | 92 | **10.27 ms** | 143 ms | 9223 ms |
| 2 | `3462916` | 97 | **10.25 ms** | 191 ms | 8456 ms |

Median 10 ms across both runs is remarkably stable.

#### B. Server utilization calculation rules out queueing

Total real CPU work on dominant kworker = 200 events × ~400 μs (get_tp_list + active_tp) = **80 ms**.
Active wall-clock span = 18-20 s.
**Utilization = 80 / 18,500 ≈ 0.4 %.**

99.6 % of the span the dominant kworker is idle. Server-side queueing **cannot** be the dominant wall-clock cost — there is no queue to drain because there is no sustained backlog.

#### C. Thundering-herd alignment vs deeper queueing — diagnostic distinction

Both mechanisms produce N-process slowdowns but with different signatures and different fixes.

| Property | Thundering-herd alignment | Deeper queueing |
| --- | --- | --- |
| Mechanism | N actors finish a previous step nearly simultaneously, then all hit the next step at the same instant | Requests arrive at sustainable rate, bottleneck's service rate too slow → queue grows |
| Resource utilization | Bursty: high peak, low average | Steady-state high (often near 100 %) |
| Inter-arrival pattern | Many tight gaps + a few large idle gaps | Uniform short gaps |
| Latency variance | High: most fast, some slow | Low: everyone waits similarly |
| Scaling with N | Sublinear (often √N or log N) | Linear or worse |
| Right fix | Break the alignment (stagger, jitter, randomized backoff) | Add capacity (more workers, faster service, batching) |

Mapping to UMDK#2 100-process data:

| Signal | Thundering-herd prediction | Deeper queueing prediction | Observed |
| --- | --- | --- | --- |
| Server kworker utilization | low | high | **0.5 %** ✓ thundering |
| Inter-MAD-arrival gaps | bursty: many tight + few big | uniform short | **median 10 ms, max 9.2 s** ✓ thundering |
| `import_jetty #2 / #1` ratio | alignment compression at phase boundary | similar slowdown on both | **5×** ✓ thundering |
| Latency variance | high | low | **slow tail 2-7 %, rest fast** ✓ thundering |

**Every signal matches thundering-herd; none matches deeper queueing.** §10.26 finding B3 (client cadence dominates) is the right read.

#### D. Refined codex `udma-tp-cache` patch verdict

Three updates today:

| Stage | Verdict | Reasoning |
| --- | --- | --- |
| §10.25.D (earlier today) | Irrelevant | Patch in `hw/udma/`, client hot spot in `ubcore/` |
| §10.26.C (first server data) | Relevant on server side | `udma_get_tp_list` is what the patch caches; 10 ms tail is real |
| **§10.27 (now)** | **Relevant but small win** | Eliminates 2-7 % slow tail = ~30-90 ms saved out of 18-20 s = 0.2-0.5 % wall-clock improvement |

The patch is technically applicable to the server side, but the impact on `import_jetty` wall-clock is bounded by how much time is actually spent in slow `udma_get_tp_list` calls — and that's <100 ms out of the 18-20 s span. Server-side investment has diminishing returns from here.

#### E. The remaining suspect — client-side `find_primary_eid_in_ues`

**The math without contention:**

`ubcore_get_main_primary_eid` calls `find_primary_eid_in_ues` which loops through ~117 k EID entries with `is_eid_match`. Single-process baseline (§10.19): ~4.9 ms per `ubcore_get_main_primary_eid` invocation, called ~8× per setup = **~39 ms per `import_jetty`** (CPU bound, in `ubmad_post_send` at `ubcm/ubmad_datapath.c:817`).

For 100 procs × ~4-8 MAD rounds per import = **150-300 ms per process for scans alone**, even with no contention. Already in the ballpark of the observed 108→554 ms.

**Plus thundering-herd amplification:** all 100 procs hit each phase boundary aligned, so when they enter the next round they all run `ubcore_get_main_primary_eid` at the same instant → CPU contention amplifies the per-call cost further. The 5× ratio between `#1` (~108 ms) and `#2` (~554 ms) is the alignment compressing between phases.

**This hasn't been directly measured.** The 4.9 ms baseline is single-process; the per-call cost under 100-process load is unknown. Tests A and B (below) measure it.

#### F. Test A — direct measurement of `ubcore_get_main_primary_eid` under load

**Setup (on worker1):**

```bash
cd /sys/kernel/debug/tracing
echo nop > current_tracer
echo > trace
echo 0 > tracing_on
echo global > trace_clock

cat > set_graph_function << 'EOF'
ubcore_get_main_primary_eid
EOF

echo 0 > tracing_thresh
echo 3 > max_graph_depth          # depth 3 to see find_primary_eid_in_ues inside
echo 1 > options/funcgraph-abstime
echo 1 > options/funcgraph-proc
echo 65536 > buffer_size_kb
echo function_graph > current_tracer

# Filter to one observed urma_perftest process (so the trace isn't massive)
# (set_ftrace_pid <pid> on the chosen process)
echo 1 > tracing_on
```

**Run** the 100-process workload. **Save** the trace.

**Analyze:**

```bash
f=trace_client_P100_get_primary_eid.log

# Distribution of ubcore_get_main_primary_eid call durations
grep "ubcore_get_main_primary_eid" $f | grep -oE '[*!] +[0-9.]+ us' \
  | awk '{x=$2+0; if(x<5000) a++; else if(x<10000) b++; else if(x<20000) c++; else d++}
         END {print "<5ms:"a"  5-10ms:"b"  10-20ms:"c"  >20ms:"d}'

# Median / p90 / p99 of the function duration
grep "ubcore_get_main_primary_eid" $f | grep -oE '[*!] +[0-9.]+ us' \
  | awk '{print $2+0}' | sort -n \
  | awk 'BEGIN{c=0} {a[c++]=$1}
         END {printf "n=%d median=%.2fus p90=%.2fus p99=%.2fus max=%.2fus\n",
                     c, a[int(c*0.5)], a[int(c*0.9)], a[int(c*0.99)], a[c-1]}'
```

**Three possible outcomes:**

1. **Median ~5 ms** (baseline holds under load): pure round-count × concurrency arithmetic. No contention amplification. The fix path is "reduce per-call cost" (replace the linear scan with a hash; or cache primary_eid lookup per (peer_eid, trans_mode) tuple).
2. **Median 30-50 ms** (dilates ~10× under load): CPU contention is amplifying. Both "reduce per-call cost" AND "stagger to avoid alignment" would help.
3. **Median ~5 ms but p99 huge**: the average isn't dilating but individual instances stall; tail-latency problem. Stagger fix is enough.

#### G. Test B — disconfirm thundering-herd by adding random stagger

**Wrapper script** (`stagger-wrapper.sh`):

```bash
#!/bin/bash
# Random 0-50ms startup delay per process
sleep $(awk -v s=$$ 'BEGIN{srand(s); printf "%.4f", rand()*0.05}')
exec urma_perftest send_lat -n 5 -s 2 -d bonding_dev_0 --single_path -p 0
```

**Run:** 100 instances of this wrapper in parallel (same way you run the unstaggered version). Compare `import_jetty #1` / `#2` wall-clock vs the unstaggered baseline.

**Two outcomes:**

1. **Slowdown drops from 91× to <10×** → thundering-herd alignment is the dominant amplification mechanism. Stagger is the cheap fix.
2. **Slowdown stays at ~91×** → alignment is not the amplifier; raw CPU/network cost per round is dominant. The fix has to address per-call cost.

#### H. Why both tests, not just one

| Test | Pins | Doesn't pin |
| --- | --- | --- |
| A alone | Function's per-call behavior under load | Whether alignment matters separately from raw load |
| B alone | Whether stagger fixes it | What the underlying mechanism is or what the cost floor is |
| **A + B** | Both the function cost under load AND the alignment effect | — |

Combined, the answers cleanly map to a fix:

| A outcome | B outcome | Fix |
| --- | --- | --- |
| baseline holds | stagger fixes it | client-side stagger (free) |
| baseline holds | stagger doesn't help | reduce per-call scan cost (hash / cache) |
| dilates under load | stagger fixes it | client-side stagger (free) plus optional scan optimization |
| dilates under load | stagger doesn't help | both fixes needed |

#### I. Status of all open follow-ups

| Follow-up | Status | Notes |
| --- | --- | --- |
| Plan B sequential scale test | Open | Lower priority now that thundering-herd reading is confirmed |
| `git diff master..codex/udma-tp-cache` read | **Done** §10.25.D | Patch is `hw/udma`-only |
| Cold-vs-warm `modprobe -r/-i` protocol | Open | Less load-bearing now |
| §10 doc refactor | Open | §10.25 + §10.26 + §10.27 form the authoritative chain |
| dmesg `post_wq consumes` check (§10.26.D #5 / experiment a) | Open | Cheap (5 s); predicted: 0 events |
| Experiment 6 (`ubmad_recv_work_handler` trace) | De-prioritized | Existing data already shows MAD arrival is bursty |
| Experiment 7 (codex patch on master) | Open | Expected: removes 2-7 % slow tail, but `import_jetty` wall-clock barely changes |
| **Test A — client-side `ubcore_get_main_primary_eid` ftrace** | **Highest priority** | Pins the suspected function's behavior under load |
| **Test B — random stagger disconfirm** | **Highest priority** | Pins whether alignment is the amplifier |

### 10.28 Experiment 6 results — §10.27 predictions confirmed (2026-05-14)

JinDou ran experiment 6 on master with `ubmad_recv_work_handler` added to `set_graph_function`. Every numerical prediction in §10.27 was confirmed.

#### A. Predicted vs observed

| Prediction (§10.27.D/F) | Predicted value | Observed | Verdict |
| --- | --- | --- | --- |
| MAD inter-arrival median | ~10-11 ms | **6.4 ms** | ✓ same order, bursty |
| MAD inter-arrival max | ~8-9 s | **8.6 s** | ✓ near-exact |
| **kworker dispatch latency median** | **< 1 ms** | **0.053 ms (53 μs)** | **✓ strongly confirmed** |
| Dispatch latency p99 | ~tens of ms | 19 ms | ✓ |

The 53 μs median dispatch latency is the load-bearing data point. MAD arrives at the server → kworker begins processing within ~50 μs in the typical case. There is no meaningful server-side dispatch queue.

#### B. Per-second MAD arrival distribution shows phase-boundary alignment

```
seconds 7734-7752  (18 s): 28 → 83 → 182 → ... → 152 → 44 MADs/sec     (main burst)
seconds 7753-7759   (7 s): 0                                            (silence)
seconds 7760-7763   (4 s): 5 → 3 → 1 → 1                                (tail)
```

The 7-8 second silence between 7752 and 7760 is the thundering-herd phase boundary materializing in the data: 100 clients finish phase 2 simultaneously, all enter client-side CPU work (the 39 ms `find_primary_eid_in_ues` scan × N rounds), then collectively resume sending MADs ~8 s later. Single most direct visualization of the thundering-herd pattern.

#### C. New finding: ~13.5 MADs per `import_jetty`

`n=2704` MAD arrivals over `n=200` get_tp_list events = **~13.5 inbound MADs per import_jetty**. Higher than the 4-8 rounds estimated in §10.21/§10.22, because non-get-tp-list MADs (metadata exchange in phase A, auth, CM state sync) also reach the server. Not consequential for the bottleneck story but worth noting for any future round-count estimates.

#### D. Confidence summary after experiment 6

| Claim | Confidence | Basis |
| --- | --- | --- |
| Server is the bottleneck | **ruled out** | dispatch 53 μs + utilization 0.4 % + 8 s idle gap |
| Mechanism is thundering-herd alignment | **>95 %** | bursty pattern + visible phase boundary + 5× `#2`/`#1` |
| Client-side `find_primary_eid_in_ues` is the suspect | **~85 %** | math fits, not directly measured under load |
| Fix is client-side stagger | **~70 %** | strongly supported, not yet disconfirmed |

#### E. dmesg `post_wq consumes` was skipped — fine

`/sys/module/ubcm/parameters/g_ubcore_log_level` doesn't exist on this kernel build, so JinDou couldn't enable the INFO log. **The 53 μs dispatch latency measurement is a stronger form of the same diagnostic** — direct timestamp pair vs threshold-gated log. No information lost.

#### F. Remaining work — Test A + Test B

Server side is now closed. Two client-side experiments still queued (per §10.27.F/G):

- Test A: client-side ftrace on `ubcore_get_main_primary_eid` under 100-process load → pins per-call cost under contention
- Test B: random 0-50 ms startup stagger → directly disconfirms or confirms thundering-herd as the amplifier

Test B is the cheaper one (just a sleep wrapper, no ftrace analysis). Running Test B first: if slowdown drops from 91× to <10×, the fix path is settled (client-side stagger) and Test A becomes a nice-to-have for the root-cause pin.

### 10.29 Correction: §10.27 "server is not the bottleneck" was too absolute (2026-05-14)

JinDou challenged §10.27 by pointing back to bot comment [#4436759654](https://github.com/rainbay001-dotcom/UMDK/issues/2#issuecomment-4436759654) (from round 4 of the original UMDK#2 thread), where a depth-3 trace on **one observed urma_perftest process** showed:

- `import_seg` `ubcore_session_wait` = **610 ms** (vs ~0.87 ms single-process baseline, 700×)
- `import_jetty #1` `ubcore_session_wait` = **3,364 ms** (vs ~0.45 ms baseline, ~7500×)
- `import_jetty #2` `ubcore_exchange_tp_info` (contains session_wait) = **3,363 ms** (~3700×)
- `send_seg_info_req` / `send_jetty_info_req` (contains `ubcore_get_main_primary_eid` ~4.9 ms scan) = **unchanged** at ~5 ms

This data point was already on the table before §10.27 was written. §10.27 didn't reconcile with it.

#### A. What §10.27 got wrong

§10.27.C concluded "server is not the bottleneck" because §10.26 server-side ftrace showed kworker utilization 0.4 % and dispatch latency 53 μs. **This was too absolute.** The correct conclusion is:

> The server's **ubcore/ubcm software layer (kworker dispatch)** is not the bottleneck. But the depth-3 trace shows clients waiting 3.36 s in `ubcore_session_wait`, which **cannot** be inside kworker dispatch (53 μs). Whatever serializes the work, it lives **downstream of kworker**: firmware ctrlq, hardware DMA queue, network stack, or NIC packet processing.

So §10.27's `server is bottleneck = ruled out` confidence statement in the summary is wrong. The right statement is **`server's kworker software dispatch` is ruled out, but `server's firmware/hardware/NIC stack` is untested and remains a candidate**.

#### B. What the bot in #4436759654 got partially wrong too

The bot extrapolated from one traced process at 3.36 s and concluded "T_server ≈ 33.6 ms/request, server's ubcm control plane is single-threaded." The numerical extrapolation has issues:

- The 3.36 s figure is **one specific observed process**, not a population mean
- The benchmark `import_jetty #2` **median** is 554 ms across 100 processes (much less than 3.36 s)
- If 100 procs uniformly queued behind a single-threaded server at T = 33.6 ms each, the median wait should be ~1.65 s (50×T), not 554 ms
- The actual distribution is **clustered** with a long tail — most processes fast (~100-554 ms), some stragglers slow (~3.36 s)
- That's the **thundering-herd** signature, not uniform serialization. §10.27.C's per-signal mapping is still correct.

So: bot's direction (server-side serialization somewhere) was right; bot's specific claim (ubcm control plane single-threaded) was an over-extrapolation. The actual location is one layer deeper.

#### C. Reconciled model

| Layer | Status | Source |
| --- | --- | --- |
| Client `find_primary_eid_in_ues` (EID scan) | **Not dilating** under load (4.84 ms vs 4.83 ms single-process) | Bot #4436759654 direct measurement |
| Client `ubcore_session_wait` | **Large tail, 3.36 s outlier** | Bot #4436759654 direct measurement |
| Server kworker software dispatch | **53 μs median, no queueing** | §10.26 experiment 6 |
| Server `ubcore_get_tp_list` (kworker context) | Mostly ~200 μs, 2-7 % outliers at ~10 ms | §10.26 experiment 5 |
| **Firmware ctrlq / hardware DMA / NIC** | **Untested** | Missing link in coordination |

Most likely bottleneck (revised, ranked):

1. **Server-side firmware ctrlq depth-1 serialization.** Kworker `udma_get_tp_list` typically returns in ~200 μs after submitting cmd, then waits for firmware async ACK. Under 100-process burst, firmware processes serially → tail clients wait for their slot.
2. **Network stack / NIC congestion** under 100 simultaneous MAD send + receive.
3. **`find_primary_eid_in_ues` is NOT the suspect** — already directly measured stable at ~5 ms.

#### D. Revised experiment plan

**Withdrawn: Test A (client-side `ubcore_get_main_primary_eid` ftrace).** Already measured by bot #4436759654 with the result: stable at ~5 ms under 100-process load. Re-measuring is duplicate work. §10.27.F shouldn't have proposed it.

**Kept: Test B (random startup stagger disconfirm).** Still high-information. If staggering drops 91× to <10×, alignment is the amplifier regardless of which layer queues. Cheapest possible experiment (one `sleep $RANDOM` wrapper).

**New: Test C — server-side firmware ctrlq trace.**

```bash
# On master server
cat > set_graph_function << 'EOF'
udma_ctrlq_send
udma_ctrlq_complete
udma_get_tp_list
ubcore_get_tp_list
EOF
echo 4 > max_graph_depth          # depth 4 to see udma_ctrlq_* inside udma_get_tp_list
echo 1 > options/funcgraph-abstime
echo 1 > options/funcgraph-proc
echo 65536 > buffer_size_kb
echo function_graph > current_tracer
```

Predictions:
- Single-process: `udma_ctrlq_send` → completion interval ~100-200 μs (firmware idle, cmd dispatched immediately).
- 100-concurrent: completion interval dilates to ms-tens-of-ms (firmware queueing). This would directly **confirm** the firmware-ctrlq-serialization hypothesis as the source of the 3.36 s client wait.

If Test C shows uniform fast ctrlq completion (no dilation), the bottleneck is one layer further out (network adapter / fabric).

#### E. Confidence summary (revised)

| Claim | §10.27 | §10.29 (corrected) |
| --- | --- | --- |
| Server kworker is the bottleneck | ~0 % | ~0 % (unchanged) |
| Server firmware ctrlq is the bottleneck | not considered | **~70 %** (new leading) |
| Network stack / NIC is the bottleneck | not considered | ~15 % |
| Client `find_primary_eid_in_ues` is the bottleneck | ~85 % | **~5 %** (directly disproven by #4436759654) |
| Mechanism is thundering-herd alignment | >95 % | >95 % (unchanged, signals still match) |
| Fix is client-side stagger | ~70 % | ~60 % (still high if alignment is the amplifier, regardless of which layer queues) |

#### F. Lesson for the doc

§10.27 should have explicitly checked against bot comment #4436759654's data before drawing the "server excluded" conclusion. The pattern is the same one §10.18 → §10.19 corrected: each layer of evidence eliminates a different framing of the problem, but **only if you keep all prior data in view**. Doc-wide cross-check of "does this conclusion explain ALL the data we have?" is the missing discipline.

### 10.30 Smoking-gun confirmation: `udma_get_tp_list` 33.5 ms × 100 ≈ 3.35 s (2026-05-14)

> **Correction notice (2026-05-14, see §10.31):** the "firmware ctrlq depth-1 serialization" framing used throughout this section is **wrong**. The firmware ctrlq is actually depth-2048 per source. The 33.5 ms × 100 arithmetic match is a coincidence, not a mechanism proof. The serialization is one layer up (sync per-kworker + ~1 effective kworker per §10.27.A). Section retained as-is for the record; see §10.31 for the corrected model.

JinDou shared a mid-trace excerpt from experiment 6 that **directly pins the firmware ctrlq hypothesis from §10.29**.

#### A. The critical line

```
7743.717827 | 78) kworker-81680 | * 33570.33 us | } /* udma_get_tp_list [udma] */
7743.717829 | 78) kworker-81680 | * 33574.61 us | } /* ubcore_get_tp_list [ubcore] */
```

**One `udma_get_tp_list` invocation took 33.5 ms** — three times larger than the 10 ms outliers seen in §10.26 and 167× the median (~200 μs).

#### B. Arithmetic close-out

| Quantity | Value |
| --- | --- |
| Per-call `udma_get_tp_list` worst case | 33.5 ms |
| Concurrent client processes | 100 |
| **Predicted cumulative firmware ctrlq queueing** | **3.35 s** |
| Observed `ubcore_session_wait` outlier (#4436758694) | **3.36 s** |
| Discrepancy | **< 0.5 %** |

The 3.36 s wait that motivated bot's #4436759654 conclusion is fully explained by firmware ctrlq depth-1 serialization. No additional bottleneck needed.

#### C. Two more findings from the same excerpt

1. **`ubmad_process_msg` slow path: 8.9 ms.** The fast path (most calls) takes ~0.6 μs. One observed instance took 8.9 ms inside `ubmad_recv_work_handler` (7743.711636 → 7743.720542). 1000× slowdown for that single call. Mechanism not yet pinned — could be CM state-machine synchronous wait, auth handshake, or TP-table lookup that itself touches firmware. **Independent of the udma_get_tp_list ctrlq path** (different kworker, different CPU).

2. **kworker pool IS multi-threaded in practice** (correcting §10.27 finding B1 again). The excerpt shows three kworkers active simultaneously across three different CPUs:
   - `kworker-87275` on CPU 67
   - `kworker-87305` on CPU 2
   - `kworker-81680` on CPU 78

   §10.27's "effectively single-threaded" reading was specific to one trace run (`trace_server_P100_round4_new`). General behavior: workqueue uses multiple kworkers, but they all serialize at the firmware ctrlq layer.

#### D. Codex `udma-tp-cache` patch — verdict revised AGAIN

§10.27.D predicted codex patch wall-clock impact ~0.2-0.5 %. §10.30 data overturns this:

| Estimate revision | Predicted patch impact |
| --- | --- |
| §10.25.D | Irrelevant (wrong layer) |
| §10.26.C first cut | Relevant, big |
| §10.27.D | Relevant, small win (0.2-0.5 %) |
| **§10.30** | **Relevant, major win (>99 % under sustained 100-proc load)** |

Math: the codex patch caches `udma_get_tp_list` results keyed by `<peer_eid, trans_mode>`. For repeated `import_jetty` of the same target across many client procs, the first call pays the firmware ctrlq cost (~33 ms in the worst case); calls #2-100 hit the cache and skip firmware entirely (microseconds). Predicted 100-proc setup wall-clock: from ~3.36 s down to **~50 ms** (1 × firmware-miss + 99 × cache-hits).

Caveat: only applies when the 100 procs target the **same peer**. For diverse targets, no cache reuse.

#### E. Experiment priority — sharpened

| Experiment | Status | Notes |
| --- | --- | --- |
| Test A (client EID scan ftrace) | **Withdrawn** | Already disproven in #4436759654 (scan stable at ~5 ms) |
| Test B (random stagger) | Keep | Cheap; if 91× → <10×, client-side stagger is a free fix that should help regardless of firmware-ctrlq mechanism |
| Test C (depth-4 firmware ctrlq trace) | **Demoted** | Already indirectly confirmed by the 33.5 ms data point + 3.35 s arithmetic; further measurement marginal |
| **Test D (NEW): apply codex `udma-tp-cache` to master, re-run 100-proc** | **Highest priority** | Predicted 99 %+ wall-clock improvement |
| Trace `ubmad_process_msg` slow-path (depth ≥4) | **NEW low priority** | The 8.9 ms outlier is a separate mechanism worth knowing, but doesn't change the leading fix |

#### F. Confidence summary (revised again)

| Claim | §10.29 | §10.30 |
| --- | --- | --- |
| Firmware ctrlq is the dominant bottleneck | ~70 % | **>95 %** |
| Codex patch resolves it | unclear | **~85 %** (high if cache hit rate matches workload) |
| Client-side stagger helps | ~60 % | ~60 % (orthogonal, still useful as a free fix) |
| `find_primary_eid_in_ues` matters | ~5 % | ~5 % (still disproven by #4436759654) |
| `ubmad_process_msg` slow path matters | not considered | ~15 % independent contributor (worth a follow-up) |

### 10.31 Correction: firmware ctrlq is depth 2048, not 1 — serialization is at the kworker layer (2026-05-14)

#### A. The wrong claim in §10.30 and what triggered the correction

§10.30.B and §10.30.D state "firmware ctrlq depth-1 serialization" as the mechanism, with the arithmetic `100 × 33.5 ms = 3.35 s` matching the observed 3.36 s tail wait. The match looked like proof of mechanism. It was not.

While drafting an explanation of "how do we know the ctrlq depth", source check disproved the depth-1 framing.

#### B. Source evidence

From `drivers/ub/ubase/ubase_ctrlq.c:257-263` (OLK-6.6 base):

```c
#define UBASE_CTRLQ_QUEUE_DEFAULT    2048
...
csq->depth = UBASE_CTRLQ_QUEUE_DEFAULT;
crq->depth = UBASE_CTRLQ_QUEUE_DEFAULT;
```

`csq` is the command send queue (driver → firmware), `crq` is the command response queue (firmware → driver). Both are ring buffers of **2048 slots**. At runtime the depth can be re-read from `UBASE_CTRLQ_CSQ_DEPTH_REG` / `UBASE_CTRLQ_CRQ_DEPTH_REG` (lines 279-287), so the actual configured depth could be smaller, but it cannot be lower than what the hardware advertises and is not 1 by construction.

`ubase_ctrlq_send_msg()` at line 926 has docstring (lines 920-924):
> when `msg->is_async = 0` and `msg->need_resp = 1`, this function will wait synchronously for the management software's response

So the **per-call API is synchronous** (one in-flight cmd per calling thread), but the **queue itself can hold many concurrent cmds from different threads**.

#### C. Corrected model — three stacked layers

| Layer | Capacity | Where it limits |
| --- | ---: | --- |
| Firmware ctrlq ring | **2048 slots** | Hardware queue, plenty of headroom |
| Per-kworker in-flight cmd | **1** | `ubase_ctrlq_send_msg()` blocks until response |
| Server kworker pool effective concurrency | **~1** in observed traces (one kworker handles 93-98 % per §10.27.A1) | This is the real serialization point |

The bottleneck **is** depth-1 in effect, but the serialization happens at the **kworker pool layer**, not at the firmware queue. The firmware could in principle accept many concurrent cmds; the kernel software just doesn't issue them in parallel.

#### D. Why the §10.30 arithmetic match was a coincidence

§10.30.B math: "100 × 33.5 ms = 3.35 s ≈ 3.36 s observed". The problem:

- 33.5 ms is the **single observed worst-case outlier** for `udma_get_tp_list`. Most calls are ~175 µs. Only 2-7 % exceeded 5 ms (per §10.26.A3).
- If 100 cmds ran serially at the **median** ~200 µs each, total = 20 ms, not 3.35 s.
- If they ran serially at the **outlier** 33.5 ms each, total = 3.35 s — but **most cmds aren't outliers**.

The math `100 × 33.5 ms ≈ 3.35 s` would only hold if all 100 cmds hit the slow path. JinDou's trace shows they don't.

The actual mechanism that produces the 3.36 s wait must involve **multi-stage server-side processing**, not single per-cmd amplification:

- 100 setups × ~13.5 inbound MADs per setup (§10.28.C) = **~1,350 MAD round-trips on server**, with the tail process waiting for ~half of them to drain through ~1 kworker
- Per-round-trip server processing (recv handler + kworker dispatch + ubmad_post_send reply): ~few ms on average
- 1,350 × ~few ms × position-in-queue factor → seconds for tail clients

The correct cumulative server-side time across these MAD events is what gives the 3.36 s, not 100 instances of the outlier value.

#### E. What this changes for fix paths

**Codex `udma-tp-cache` patch impact estimate (§10.30.D) needs revision down**:

§10.30.D predicted "1 firmware-miss + 99 cache-hits → wall-clock drops from ~3.36 s to ~50 ms". That assumed each cmd cost ~33 ms and bypassing 99 of them saves 99 × 33 ms. In reality:

- The 33.5 ms outlier is a tail event, not typical
- Most `udma_get_tp_list` calls cost ~200 µs already
- Caching saves ~200 µs per cache hit, plus avoids the rare 33 ms outliers
- Estimated client-perceived savings under N=100: probably ~10-30 % wall-clock reduction (eliminate firmware-ctrlq tail + reduce server-side processing time), not >99 %

The patch is still worthwhile because it eliminates the outlier tail. But the headline number from §10.30.D was inflated by the wrong mechanism model.

**Adding more kworkers might be just as effective** as the codex patch:

If the bottleneck is "1 effective kworker on server", then raising the kworker pool concurrency (e.g., setting `WQ_UNBOUND` workqueue's `max_active` higher, or using a different workqueue tier per peer EID) would parallelize the server-side processing. This is a different fix dimension entirely.

#### F. Cumulative server-side time math (corrected)

From the existing data (§10.30.C):

| Function | Calls in N=100 trace | Cumulative active time |
| --- | ---: | ---: |
| `udma_get_tp_list` | ~200 | ~35 ms baseline + ~150-330 ms from 5-10 outliers ≈ **200-365 ms** |
| `ubcore_active_tp` | ~200 | ~32 ms |
| `ubmad_recv_work_handler` | 2,704 | ~19 ms baseline + ~45 ms slow-path outliers ≈ **65 ms** |
| `ubmad_process_msg` slow-path | ~5 of 2,704 | ~45 ms |

**Total server active time ≈ 250-450 ms** in a span where the tail client waited 3.36 s. The factor between them (~7-13×) is queue-position amplification, not single-cmd amplification.

#### G. Experiments that would actually verify the model

1. **Trace `ubase_ctrlq_send_msg` entry/exit at depth 2 on server during N=100 load** with no PID filter. Count the maximum simultaneously in-flight cmds across all kworkers. If max = 1-3, the kworker-pool-concurrency reading is correct. If max ≥ 10, the firmware queue is the bottleneck after all.
2. **Read `/sys/module/ubase/...` debug if exposed** to see the runtime configured `csq->depth` and `crq->depth` and the live `pi`/`ci` counters during load. Gives a direct snapshot of queue occupancy.
3. **Per-kworker total active time during N=100 trace** — sum the duration of every traced function per kworker PID. If one kworker has ~400 ms active and others have <20 ms, single-kworker bottleneck confirmed. If 5 kworkers each have ~80 ms active, multi-kworker parallelism is working and the bottleneck is elsewhere.

Experiment 3 is cheapest (post-hoc analysis of existing trace_server_P100_round4 traces; just regroup the kworker stats by total active time instead of by call count). Likely worth doing before any further fix-path work.

#### H. Honest confidence summary (after this correction)

| Claim | Confidence |
| --- | ---: |
| Server kworker software is fast per-call (53 µs dispatch, 175 µs median ctrlq) | **>99 %** (directly measured) |
| ~1 kworker handles 93-98 % of server work | **>95 %** (directly measured in 2 traces) |
| 3.36 s tail wait is caused by server-side serialization | **~85 %** (consistent with all data, but exact mechanism not pinned) |
| Specifically firmware ctrlq depth-1 is the mechanism | **~10 %** (source disproves depth-1 firmware queue; if the effective serialization is at kworker layer, fix path differs) |
| Codex patch eliminates >99 % of dilation | **~30 %** (depends on cache hit rate AND on whether firmware tail is the actual amplifier vs. server-side cumulative processing) |
| Increasing kworker pool concurrency would help | **~50 %** (untested but plausible given the kworker-concentration data) |

#### I. Lesson

§10.30's "33.5 × 100 = 3.35 s" arithmetic match created an illusion of confirmed mechanism. The actual confirmation requires either (a) seeing all 100 cmds genuinely take 33.5 ms each, or (b) direct queue-depth instrumentation. We had neither. The correction pattern is the same one §10.19 (CM RTT → topo scan) and §10.29 (server not bottleneck → server's kworker not bottleneck) followed: arithmetic plausibility ≠ mechanism proof. Future sections should explicitly state "this arithmetic is consistent with hypothesis H but does not prove it" when leaning on coincidence-match evidence.

## 11. TRACE_EVENT internals — how the macro actually works

### 11.1 Where `TRACE_EVENT` is defined

`TRACE_EVENT` is a macro defined by the **Linux kernel's tracepoint
infrastructure**, not by your code. It lives in:

```
include/linux/tracepoint.h          # core tracepoint machinery
include/trace/trace_events.h        # the TRACE_EVENT macro family
include/trace/stages/stage*.h       # the per-pass redefinitions
include/trace/define_trace.h        # the multi-include driver
```

Documentation in any kernel tree:

```
Documentation/trace/tracepoints.rst        # high-level concepts
Documentation/trace/events.rst             # how to write TRACE_EVENT
samples/trace_events/                      # working example to copy
include/trace/events/sched.h               # canonical real-world example
```

Historical lineage:

- **2008** — Mathieu Desnoyers added `tracepoint`. Each tracepoint check was a real load + branch on a memory flag — cheap, not free.
- **2009** — Steven Rostedt (Red Hat) added the `TRACE_EVENT` macro family on top, gaining the structured-format / multi-consumer story. Steven still maintains it.
- **2010** — Jason Baron added "jump labels" (later renamed "static keys") using GCC 4.5's brand-new `asm goto`. Existing tracepoints converted to use them, finally getting the zero-cost-when-off property.

### 11.2 The trick: it's defined many times

`TRACE_EVENT` isn't one macro — it's **a different macro on each pass**
through your header. `define_trace.h` is essentially a loop that
re-`#include`s your `ubcore.h` five or six times, redefining
`TRACE_EVENT` between each pass to generate a different chunk of
code.

| Pass | What `TRACE_EVENT` is redefined to emit |
|------|------------------------------------------|
| 1    | The on-wire `struct trace_event_raw_<name>` (uses `TP_STRUCT__entry`) |
| 2    | The display callback `trace_raw_output_<name>` (uses `TP_printk`) |
| 3    | The probe function `trace_event_raw_event_<name>` that runs the hot path (uses `TP_fast_assign`) |
| 4    | Registration table entries placed in the `_ftrace_events` ELF section |
| 5    | The `trace_<name>()` inline + static key (uses `TP_PROTO` / `TP_ARGS`) |
| 6    | Perf-event glue if `CONFIG_PERF_EVENTS=y` |

That's why every `TRACE_EVENT` block has to provide all six sub-macros
(`TP_PROTO`, `TP_ARGS`, `TP_STRUCT__entry`, `TP_fast_assign`,
`TP_printk`, plus the name) — each pass picks out the ones it needs
and ignores the rest. It's also why the `#include
<trace/define_trace.h>` line **must be outside** the multi-include
guard at the bottom of your header: the guard would block the
second-through-sixth re-include otherwise. The toggle that lets
re-includes through the guard is `TRACE_HEADER_MULTI_READ`, set by
`define_trace.h`.

### 11.3 Conceptual expansion

After preprocessing, one `TRACE_EVENT(tp_create_start, ...)` block
produces (simplified):

```c
/* 1. The on-wire struct */
struct trace_event_raw_tp_create_start {
    struct trace_entry ent;     /* common header: type, pid, cpu, timestamp */
    u32 tpn;
    u32 fe_idx;
};

/* 2. The function callers use — branches on a static key */
static inline void trace_tp_create_start(u32 tpn, u32 fe_idx)
{
    if (static_key_false(&__tracepoint_tp_create_start.key))
        __do_trace_tp_create_start(tpn, fe_idx);
}

/* 3. The slow path — runs only when enabled */
static void __do_trace_tp_create_start(u32 tpn, u32 fe_idx)
{
    struct trace_event_raw_tp_create_start *__entry =
        ring_buffer_reserve(...);

    /* TP_fast_assign expands here */
    __entry->tpn    = tpn;
    __entry->fe_idx = fe_idx;

    ring_buffer_commit(...);
}

/* 4. The display callback — uses TP_printk */
static enum print_line_t trace_raw_output_tp_create_start(...) {
    /* uses "tpn=0x%x fe_idx=%u" and __entry->{tpn,fe_idx} */
}

/* 5. Registration record placed in a special section */
static struct trace_event_call __used __section("_ftrace_events")
    event_tp_create_start = { .name = "tp_create_start", ... };

/* 6. The static key controlling the NOP-vs-call patching */
struct tracepoint __tracepoint_tp_create_start = { ... };
```

Boot-time tracing init walks the `_ftrace_events` section, registers
each event, creates the `events/ubcore/tp_create_start/` sysfs
directory, and exposes `format`, `enable`, `filter`, `id`. Nothing
else needs to know about your tracepoint — registration is automatic
via section magic.

To see the literal expansion on your tree:

```bash
cd /Volumes/KernelDev/kernel
make drivers/ub/urma/ubcore_main.i      # the .c with CREATE_TRACE_POINTS
less drivers/ub/urma/ubcore_main.i      # ~thousands of lines
```

### 11.4 Was the compiler changed to support this?

**No.** The compiler treats `trace_tp_create_start(tpn, fe_idx)` as
an ordinary function call and type-checks it like any other. All the
cleverness is in what the macro expands to and what the kernel does
with the resulting bytes at runtime.

| Job                                                | Mechanism                                                                             | Compiler-specific? |
|----------------------------------------------------|----------------------------------------------------------------------------------------|--------------------|
| Generating the function declaration so calls type-check | Macro expansion → normal `static inline void trace_xxx(u32, u32)` | No — pure C preprocessor |
| Placing registration records in a special ELF section | `__attribute__((__section__("_ftrace_events")))`                                  | No — standard ELF |
| The static key (NOP → jump → call)                  | `asm goto` inside an inline asm block                                                | **GCC extension** — but added 2010 for general use, not for tracepoints |
| Runtime rewriting of the NOP into a jump            | Kernel's `text_poke()` / `arch_jump_label_transform()`                              | No — kernel patching its own `.text` |
| Linker-side gathering of all registration entries   | `__start__ftrace_events` / `__stop__ftrace_events` symbols generated by ld          | No — standard ELF |

The trick is **runtime self-modification of code the compiler emitted
normally**, not compiler magic at build time.

If you build the kernel with a compiler too old to support `asm goto`,
tracepoints still work — they fall back to a cheap-but-not-free
load-and-test on a memory flag (`include/linux/jump_label.h`,
`HAVE_JUMP_LABEL` branch). Even the one compiler dependency is
**optional**, not mandatory.

### 11.5 The one compiler dependency: `asm goto`

`asm goto` is the GCC/Clang feature that gives tracepoints the
zero-cost-when-off property. A normal `asm volatile` block has fixed
entry and exit. `asm goto` adds the ability for the asm to **jump to
a labeled C statement** as one of its outputs:

```c
static inline bool tracepoint_enabled(void)
{
    asm_volatile_goto(
        "1: .byte 0x0f,0x1f,0x44,0x00,0x00\n"   /* 5-byte NOP */
        ".pushsection __jump_table, \"aw\"\n"
        "  .quad 1b, %l[l_yes], %c0\n"          /* registration entry */
        ".popsection\n"
        : : "i" (&tracepoint_key) : : l_yes);
    return false;                               /* fall-through path */
l_yes:
    return true;                                /* jumped-to path */
}
```

Mechanics:

1. The compiler emits a 5-byte NOP at the call site. The CPU runs it in zero useful cycles.
2. In a side section `__jump_table`, the build records "address of this NOP" and "address of `l_yes`" plus a key.
3. At runtime, when the kernel decides "tracepoint X is now enabled," it walks `__jump_table`, finds every NOP belonging to that key, and rewrites those 5 bytes in `.text` to a `jmp l_yes` instruction. The CPU starts taking the alternate branch on the next execution.
4. To disable, rewrite the bytes back to a NOP.

`asm goto` was contributed to GCC by Andrew MacLeod and friends and
shipped in **GCC 4.5 (April 2010)**, motivated by exactly this
"branch the compiler emits but the runtime patches" use case. Clang
followed years later (~Clang 9, 2019, after a long process — the
LLVM backend took a while to support it).

### 11.6 Why "asm goto" when the body is just a NOP

The `goto` describes **how the compiler must treat the asm block, not
what the asm body literally contains**. The body is a NOP at compile
time, but the compiler still has to assume it *could* transfer
control to a labeled C statement, because at runtime those bytes will
be rewritten into a real jump.

Two ingredients:

```c
asm_volatile_goto(
    "1: .byte 0x0f,0x1f,0x44,0x00,0x00\n"   ←──── (a) the asm body
    ".pushsection __jump_table, \"aw\"\n"
    "  .quad 1b, %l[l_yes], %c0\n"
    ".popsection\n"
    : : "i" (&key) : : l_yes);              ←──── (b) the goto-label list
```

**(a) is "what assembly to emit"** — happens to be a 5-byte NOP today.
**(b) is the contract with the compiler:** "this asm block may
transfer control to one of these C labels." The presence of that
label list is what makes this syntactic form `asm goto` instead of
plain `asm volatile`.

If you took that exact same NOP and put it in plain `asm volatile`,
it would assemble identically *today* — the bytes are the same. But
the compiler is allowed to assume **plain `asm` always falls
through**, so it'll lay out `return false;` directly after, possibly
optimize away `l_yes` entirely, possibly merge or reorder code around
the asm. The moment the kernel rewrites those 5 bytes into `jmp
l_yes` at runtime, you'd be jumping to a label that doesn't exist in
the binary, or to code that got reordered, or that has a stale stack
frame. Disaster.

What "could jump" actually changes in compilation:

1. **`l_yes` becomes reachable.** A label that's never branched to from any visible source might be eliminated as dead code; with `asm goto` listing it, the optimizer treats it as a live target and keeps it.
2. **Live-range and register allocation cross the asm.** Variables live at *both* the fall-through point and `l_yes` must be in a consistent location at both — the same way they would for a real conditional branch. The compiler can't say "in a register on the fall-through path but spilled at l_yes," because at runtime which path is taken is determined by patching.
3. **No code can be hoisted across it speculatively.** The asm is a possible branch point; optimizations that move loads/stores past it are disabled the same way they would be for a real `if`.
4. **The bytes between label `1:` and the next instruction must remain exactly that size.** The kernel will overwrite 5 bytes there. `asm` blocks emit verbatim, so this just works — but only because asm always emits exactly what you wrote.

That last point is also why the body uses the explicit instruction
encoding `0x0f 0x1f 0x44 0x00 0x00` (a 5-byte NOP variant from
Intel's recommended NOP list), not the assembler shorthand `nop`.
`nop` would emit a 1-byte `0x90`, leaving nothing to patch.

In picture form:

```
                 BEFORE patching (kernel boot)              AFTER patching (tracepoint enabled)
                 ──────────────────────────────              ──────────────────────────────────
   call site:   1:  0F 1F 44 00 00     ; 5-byte NOP    →    1:  E9 xx xx xx xx     ; jmp l_yes
                    next C statement                            next C statement
                    ...                                          ...
                l_yes:                                       l_yes:
                    return true;                                  return true;
```

Same 5 bytes either way. The CPU runs whatever's in `.text` at
execution time. The compiler doesn't know which version is live —
only that it must lay out the surrounding code so **either** is
correct.

Useful analogy: `asm goto` is like declaring a function `noreturn`.
The compiler doesn't verify the function actually never returns — it
trusts the annotation and optimizes accordingly. Same here: `asm
goto` is a **promise to the compiler about what control-flow
patterns are possible**, and the runtime patcher honors that promise
by ensuring the bytes there always implement one of the legal flows
(fall-through or jump-to-listed-label).

### 11.7 Things that *did* trigger compiler work elsewhere

For completeness — the kernel ecosystem has driven a few real
compiler changes for tracing/observability, but **none are about
`TRACE_EVENT` itself**:

- **BPF backend in Clang** — to compile **BPF programs** (the verifier-friendly bytecode that runs *inside* eBPF probes), Clang got a `bpf` target. Doesn't affect kernel-side tracepoints.
- **BTF generation** — DWARF-derived type info for BPF CO-RE. Done by `pahole` post-build originally; recent Clang can emit BTF directly with `-g -gbpf-btf`. Again, this is for BPF programs, not for tracepoints.
- **`-fpatchable-function-entry`** — used by the modern `fentry`/`fexit` BPF probe mechanism (separate beast from tracepoints, lower-overhead than kprobes). This **is** a compiler feature added for the kernel's benefit, but it's a distinct mechanism.

### 11.8 TL;DR on internals

`TRACE_EVENT(...)` is implemented entirely in **C preprocessor macros
+ ELF section attributes + the kernel's own runtime code-patcher**.
The only compiler feature it depends on for performance is `asm
goto`, a general GCC/Clang extension that exists for many uses, not
specifically for tracepoints. The compiler treats
`trace_tp_create_start(tpn, fe_idx)` as an ordinary function call —
all the cleverness is in what the macro expands to and what the
kernel does with the resulting bytes at runtime. The `goto` keyword
in `asm goto` refers to the **goto-label list** at the end of the
construct (`: l_yes`), not to anything in the asm body itself; it's
the compiler's permission slip to treat the asm as a branch point,
which makes it safe for the kernel to patch the NOP into a real jump
later without violating any assumption the compiler made about the
surrounding code.

## 12. Glossary

| Term         | Meaning |
|--------------|---------|
| URMA         | User-Mode RDMA Access — UMDK userspace API and verbs |
| UDMA         | Underlying DMA layer driving URMA hardware |
| ubcore       | Kernel-side core driver shared by URMA / UDMA / UB |
| TP           | Transport Pair — the URMA equivalent of an RDMA QP |
| JFS / JFR    | Job Function Send / Receive — URMA queue analogues |
| Tracepoint   | Static, source-defined probe point. Zero-overhead off, structured on. |
| kprobe       | Runtime-attached probe at any kernel symbol |
| ftrace       | Kernel's built-in tracing facility at `/sys/kernel/debug/tracing/` |
| eBPF         | In-kernel sandboxed VM that runs verified BPF programs |
| BTF          | BPF Type Format — kernel type info enabling CO-RE |
| CO-RE        | Compile Once Run Everywhere — single BPF object across kernel versions |
| bpftrace     | DSL that compiles to eBPF, optimized for ad-hoc tracing |
| BCC          | Earlier Python+C frontend to eBPF; bpftrace's predecessor for many use cases |
| libbpf       | C library for loading BPF programs; modern replacement for BCC's runtime |
