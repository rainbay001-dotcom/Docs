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

Server pod:

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

For "is the codex `tp-cache` patch attacking the right thing?" the
shortest path is: **§2 to confirm the magnitude → §6 to attribute time
to a kernel function → re-run on the patched kernel and compare**. The
ftrace and tracepoint sections are background for when you want to make
the probes permanent.

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
