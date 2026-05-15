# ubcore logging, ftrace, tracepoints, and kprobes — how kernel observability fits together for UB/URMA

_Created 2026-05-15. Reference for what each kernel observability mechanism is, how they relate, and how to use them concretely on ubcore / UDMA symbols._

## 0. Scope and companions

This doc consolidates four overlapping topics that come up whenever you try to instrument the URMA/UDMA stack:

1. ubcore's **event macros** — the `UBCORE_EVENT_*` async-notification family.
2. ubcore's **logging "tracing"** — the `ubcore_log_*` printk wrapper family in `ubcore_log.h`.
3. **Linux ftrace + tracepoints + `TRACE_EVENT`** — what these are, how they relate, and what `/sys/kernel/tracing/` actually exposes.
4. **kprobes** — what they buy on top, why tracepoints still exist, and a minimal recipe for instrumenting any ubcore function without source changes.

Pairs with:
- [`umdk_get_tp_list_ctrlq_pipeline.md`](umdk_get_tp_list_ctrlq_pipeline.md) — the function call chain you'll most often want to trace.
- [`umdk_urma_jetty_kernel_call_trace.md`](umdk_urma_jetty_kernel_call_trace.md) — broader call-trace doc.
- [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) — §10.30's firmware-ctrlq smoking gun; the kprobe recipes in §6 below are the empirical-validation tool for that thread.

Source tree: `/Volumes/KernelDev/kernel/drivers/ub/`.

---

## 1. ubcore event macros — async notifications

Not really "macros" — an enumerator family plus dispatch plumbing.

### 1.1 Enum

`include/ub/urma/ubcore_types.h:357-376`:

```c
enum ubcore_event_type {
    UBCORE_EVENT_JFC_ERR, UBCORE_EVENT_JFS_ERR, UBCORE_EVENT_JFR_ERR,
    UBCORE_EVENT_JFR_LIMIT_REACHED,
    UBCORE_EVENT_JETTY_ERR, UBCORE_EVENT_JETTY_LIMIT_REACHED,
    UBCORE_EVENT_JETTY_GRP_ERR,
    UBCORE_EVENT_PORT_ACTIVE, UBCORE_EVENT_PORT_DOWN,
    UBCORE_EVENT_DEV_FATAL, UBCORE_EVENT_EID_CHANGE,
    UBCORE_EVENT_TP_ERR, UBCORE_EVENT_TP_SUSPEND, UBCORE_EVENT_TP_FLUSH_DONE,
    UBCORE_EVENT_ELR_ERR, UBCORE_EVENT_ELR_DONE,
    UBCORE_EVENT_MIGRATE_VTP_SWITCH, UBCORE_EVENT_MIGRATE_VTP_ROLLBACK
};
```

### 1.2 Carrier struct (`ubcore_types.h:1250`)

```c
struct ubcore_event {
    struct ubcore_device *ub_dev;
    union {
        struct ubcore_jfc *jfc;     struct ubcore_jfs *jfs;
        struct ubcore_jfr *jfr;     struct ubcore_jetty *jetty;
        struct ubcore_jetty_group *jetty_grp;
        struct ubcore_tp *tp;       struct ubcore_vtp *vtp;
        uint32_t port_id;           uint32_t eid_idx;
    } element;
    enum ubcore_event_type event_type;
};
```

### 1.3 Two delivery paths

| Path | Producer side | Consumer side | Use |
|---|---|---|---|
| **Per-device handler chain** | `ubcore_dispatch_async_event(&event)` at `ubcore_device.c:1431` → queue work to `UBCORE_DISPATCH_EVENT_WQ` → walk `dev->event_handler_list` | `ubcore_register_event_handler(dev, h)` at `:1358` adds to list | Multi-subscriber. UBMAD (`ubmad_event_cb` at `ub_mad.c:134`), UVS, uburma's per-context delivery. |
| **Per-resource callback** | Driver fires `jfae_handler(event, ucontext)` for the affected JFS/JFR/JFC/Jetty | Caller of `ubcore_create_jetty` (`ubcore_jetty.c:541`), `_jfs`, `_jfr`, `_jfc` passes `ubcore_event_callback_t jfae_handler` | Single owner — bound to the resource's user context. Surfaces into userspace via uburma's `'E'` ioctl/eventfd channel. |

### 1.4 Purpose

The IB-verbs `ib_async_event` analog, UB-specialized. Hardware (UDMA / ubagg / …) observes something asynchronously — link down, CQE error, EID rebind, peer drop, TP suspend, live-migration phase change — and surfaces it through a *single typed channel* to whoever cares (policy code in UBMAD / UVS / uburma).

This is **not** a "trace" mechanism. It's a control-plane notification fanout. Don't confuse it with the diagnostic logging in §2 or the kernel tracing in §3.

---

## 2. ubcore's "tracing" mechanism — structured printk

Defined in `drivers/ub/urma/ubcore/ubcore_log.h` (120 lines). Not ftrace. Not tracepoints. A printk wrapper with a runtime severity gate and rate-limit variants.

### 2.1 Structured prefix on every line

```
URMA|ubcore|<pid>|<vnr_pid>|<func>:[<line>]|<your message>
```

Built by `ubcore_log()` / `ubcore_default_log()` at `ubcore_log.h:36-44`. Every ubcore log line is greppable by tag, process, and call site.

### 2.2 Five severity levels gated by `g_ubcore_log_level`

```c
enum ubcore_log_level {
    UBCORE_LOG_LEVEL_ERR     = 3,
    UBCORE_LOG_LEVEL_WARNING = 4,
    UBCORE_LOG_LEVEL_NOTICE  = 5,
    UBCORE_LOG_LEVEL_INFO    = 6,
    UBCORE_LOG_LEVEL_DEBUG   = 7,
};
extern uint32_t g_ubcore_log_level;
```

Macros: `ubcore_log_{err,warn,notice,info,debug}`. Each expands to `do { if (g_ubcore_log_level >= LEVEL) pr_<l>(...); } while (0)`. Compile-time present; runtime gated.

### 2.3 Rate-limited siblings

`ubcore_log_{err,warn,notice,info}_rl` — same gate, plus per-call-site `DEFINE_RATELIMIT_STATE(_rs, 5*HZ, 100)`. Prevents soft-lockups from runaway error paths. Max 100 lines per 5s per call site.

Example: `[DRV_INFO]get_tp_list consumes: %llu` in `ubcore_get_tp_list` (`ubcore_tp.c:49`) uses `ubcore_log_info_rl` — gated at INFO (6), rate-limited.

### 2.4 Runtime control

```c
module_param(g_ubcore_log_level, uint, 0644);
MODULE_PARM_DESC(g_ubcore_log_level, " 3: ERR, 4: WARNING, 6: INFO, 7: DEBUG");
```

(`ubcore_main.c:28`.) Adjustable without reload:

```sh
echo 6 > /sys/module/ubcore/parameters/g_ubcore_log_level
```

Default is conservative. Anything above NOTICE is hidden unless raised. **The #1 reason a "where's my log line?" hypothesis is wrong** is the level gate, not a missing call. See [memory:feedback_ubcore_log_level_gate].

### 2.5 What this gives you

- Centralized, structured observability across multi-driver subsystems writing through ubcore.
- `dmesg | grep '|ubcore|'` lights up the whole control plane.
- pid/vnr_pid correlation with userspace.
- Single knob to dial up for an incident.

### 2.6 What it does NOT give you

- No ftrace tracepoint, no `/sys/kernel/tracing/events/ubcore/`.
- Not BPF-hookable.
- Not perf-instrumentable as discrete events.
- Per-event filtering only by severity (not by argument values or call frequency).

For those, you need the real Linux tracing infrastructure (§3-§6).

---

## 3. Linux ftrace, tracepoints, TRACE_EVENT — the layered picture

ftrace is the **engine**. Tracepoints are **hooks** ftrace knows how to consume. `TRACE_EVENT` is the **macro** that declares one of those hooks together with the metadata ftrace needs.

```
┌──────────────────────────────────────────────────────────────┐
│ Consumers:  ftrace event tracer │ perf │ BPF │ kmod listeners │
├──────────────────────────────────────────────────────────────┤
│ TRACE_EVENT macro    (declares hook + ftrace event class)    │
├──────────────────────────────────────────────────────────────┤
│ Tracepoint           (kernel/tracepoint.c — static-key       │
│                       call-site mechanism, no UI)            │
├──────────────────────────────────────────────────────────────┤
│ Compiled-in code:    trace_<name>(...) call sites            │
└──────────────────────────────────────────────────────────────┘
```

### 3.1 Tracepoint (the bare hook)

`kernel/tracepoint.c` provides "a list of function pointers behind a static-key gate." When a caller writes `trace_foo(...)` and nothing is attached, cost is one `unlikely`-tagged branch — effectively free. When something attaches (ftrace, perf, BPF, a custom kernel module), the call dispatches to all registered probes.

Tracepoints exist independently of ftrace. A kernel module can register a probe with `tracepoint_probe_register()` without ftrace being loaded.

### 3.2 `TRACE_EVENT` macro — what it generates

Declared in `<trace/events/<subsys>.h>`:

```c
TRACE_EVENT(ubase_ue_req_callback,
    TP_PROTO(struct device *dev, u16 bus_ue_id, void *cmd, u16 len),
    TP_ARGS(dev, bus_ue_id, cmd, len),
    TP_STRUCT__entry(
        __field(u16, bus_ue_id)
        __field(u16, len)
        __string(dev, dev_name(dev))
    ),
    TP_fast_assign(
        __entry->bus_ue_id = bus_ue_id;
        __entry->len = len;
        __assign_str(dev, dev_name(dev));
    ),
    TP_printk("dev=%s bus_ue_id=%u len=%u",
              __get_str(dev), __entry->bus_ue_id, __entry->len)
);
```

Generated by the macro:

1. **`trace_ubase_ue_req_callback(...)`** — the call-site function.
2. **Binary record layout** — `TP_STRUCT__entry` + `TP_fast_assign`. ftrace writes binary into its ring buffer; no string formatting at hot-path time.
3. **`format` file** — emitted into tracefs so consumers can decode the binary.
4. **`TP_printk` formatter** — runs lazily when someone reads `trace`.

Fast binary capture in production, lazy formatting on read. This is why `TRACE_EVENT` is viable in hot paths where `printk` would melt the system.

### 3.3 `/sys/kernel/tracing/events/<subsys>/<event>/` — ftrace's tracefs view

```
/sys/kernel/tracing/events/ubase/ubase_ue_req_callback/
    enable     # write 1 to turn the tracepoint on
    filter     # in-kernel expression, e.g. "len > 64"
    format     # binary-record layout (also read by perf/BPF)
    id         # numeric event id
    trigger    # stacktrace, snapshot, hist
```

**Subtle but important:** `echo 1 > events/.../enable` flips the tracepoint's static key **globally**. ftrace records it into its ring buffer; but **perf and BPF, if also attached, see every fire too**. The static-key fanout handles multi-consumer dispatch; ftrace doesn't broker.

### 3.4 ftrace is more than tracepoints

ftrace predates the tracepoint subsystem. It has several **tracers** (one active at a time, set via `/sys/kernel/tracing/current_tracer`):

| Tracer | Mechanism | Uses tracepoints? |
|---|---|---|
| `function` | mcount / fentry nop-patch | No |
| `function_graph` | mcount / fentry + return-address rewrite | No |
| `irqsoff` / `preemptoff` | latency tracer | No |
| `wakeup` / `wakeup_rt` | scheduler latency | No |
| `nop` | events only, no function tracer | n/a |
| (Events) | the `TRACE_EVENT` consumer | **Yes** |

The `function` tracer is ftrace's namesake feature and is what makes the next section possible.

---

## 4. Why tracepoints exist if kprobes attach anywhere

The kernel ships both because they optimize opposite ends of the stability/flexibility tradeoff.

| Property | Tracepoint (`TRACE_EVENT`) | kprobe |
|---|---|---|
| Stability | Named contract; held across kernel versions | Symbol+offset; breaks silently when code shifts |
| Off-cost | Static-key branch (~0) | None until attached |
| On-cost (fentry-based) | ~one indirect call | Same |
| On-cost (true int3 mid-function) | n/a | Software breakpoint trap → handler → emulate/single-step → return. **Orders of magnitude more expensive.** |
| Self-described args | Yes — `TP_PROTO` types in `format` file | No — raw registers + manual fetch expressions (or BTF/fprobe) |
| Semantic placement | At the moment of interest, after the relevant locals are live | Only at instructions the compiler emitted |
| Cross-inline reach | Author places where state exists; survives inlining | If the function got inlined, there's no symbol to attach to |
| Hot-path safe | Designed for 10M events/sec | Limited; mid-function int3 in a hot path will hurt |
| ABI promise | Yes — production tools pin to event names + fields | No — debugging archaeology only |

Mental model:

- **Tracepoints are production observability** — a published API. The maintainer says: *this event matters, its shape is stable, build tools on top of it.*
- **kprobes are debugging archaeology** — an inspection. You say: *I don't care what the maintainer published; I want to know what's happening here right now.*

Removing tracepoints because "kprobes can do anything" would force every observability tool to pin to a specific kernel build. Both jobs are real, both mechanisms exist.

### 4.1 Why ubcore has neither (today)

Tracepoints are a stability commitment. ubcore is still pre-upstream and churning fast — locking in tracepoint contracts now creates future migration debt. ubase, one layer below and changing more slowly, has paid the cost and exposes `trace_ubase_*` events in `drivers/ub/ubase/ubase_trace.h`.

Once URMA/ubcore stabilizes (likely around the LWN/lore RFC), adding `TRACE_EVENT` for `get_tp_list`, `create_vtp`, `dispatch_event`, `cm_send/recv`, and the hot ctrlq paths would be a meaningful operability upgrade. Until then: function tracer + kprobes (§5, §6).

---

## 5. Tracing ubcore functions today — ftrace function tracer

You can trace `ubcore_get_tp_list`, `udma_get_tp_list`, `ubase_ctrlq_send_msg`, and `ubase_ctrlq_notify_completed` **right now** without source modifications. Every non-`notrace` function compiled with `CONFIG_FUNCTION_TRACER=y` has a patchable nop at entry; ftrace flips it to a call-into-tracer when you enable it.

### 5.1 Recipe — get_tp_list pipeline timing

```sh
cd /sys/kernel/tracing
echo function_graph > current_tracer
echo 'ubcore_get_tp_list udma_get_tp_list udma_tp_cache_* udma_ctrlq_fetch_tpid_list ubase_ctrlq_*' \
    > set_graph_function
echo 1 > tracing_on

# in another shell: run urma_perftest

echo 0 > tracing_on
cat trace > /tmp/gtl_trace.log
```

Output (`function_graph` style):

```
 1)               |  ubcore_get_tp_list() {
 1)               |    udma_get_tp_list() {
 1)               |      udma_tp_cache_get_or_fetch() {
 1)               |        udma_ctrlq_fetch_tpid_list() {
 1)               |          ubase_ctrlq_send_msg() {
 1) # 2843.521 us |            ubase_ctrlq_wait_completed();
 1) # 2845.118 us |          }
 1) # 2845.402 us |        }
       ...
```

The exact call tree from `umdk_get_tp_list_ctrlq_pipeline.md`, measured. The 2.84 ms cost lands entirely in `wait_for_completion_timeout` inside `ubase_ctrlq_wait_completed` — empirical validation of `umdk_link_setup_timing.md` §10.30.

### 5.2 Useful variants

| Want | How |
|---|---|
| Just one function | `echo foo > set_ftrace_filter` |
| All ubcore funcs | `echo 'ubcore_*' > set_ftrace_filter` |
| Add more (don't clobber) | `>>` instead of `>` |
| Exclude noisy callees | `echo bar > set_ftrace_notrace` |
| Per-PID only | `echo <pid> > set_ftrace_pid` |
| Stack trace on hit | `echo 1 > options/func_stack_trace` |
| Call graph from one entry | `function_graph` + `set_graph_function` |

### 5.3 Caveats

- **`inline` functions are gone** by the time ftrace sees the binary — `static inline` helpers won't be in `available_filter_functions`. Instrument the non-inlined caller, or use BPF + BTF.
- **`notrace`-tagged functions** (NMI / early-entry / recursion-sensitive) are blacklisted. Most ubcore code is fine.
- **Modules must be loaded first** — ftrace only knows symbols after `modprobe ubcore`.
- **`function_graph` measures wall-clock**, including sleeps. A 2.8 ms `ubcore_get_tp_list` is mostly `wait_for_completion_timeout`, not CPU work. For this investigation that's what you want.

### 5.4 Front-ends

Tedious to poke tracefs directly. Use:

- `trace-cmd record -p function_graph -g ubcore_get_tp_list -- ./urma_perftest …`
- perf-tools: `funcgraph ubcore_get_tp_list`, `funccount 'ubcore_*'`, `funclatency ubcore_get_tp_list`.
- `bpftrace` — see §6.3.

---

## 6. kprobe minimal recipes for ubcore

When you need to peek at function arguments or mid-function state — without tracepoints and without modifying source.

### 6.1 Tracefs `kprobe_events` — no module, no compile

aarch64 (NPU server, args in `x0, x1, x2, …`):

```sh
cd /sys/kernel/tracing

echo 'p:gtl_in  ubcore_get_tp_list dev=%x0 cfg=%x1 tp_cnt_p=%x2 tp_cnt=+0(%x2):u32' \
    >> kprobe_events
echo 'r:gtl_out ubcore_get_tp_list ret=$retval' >> kprobe_events

echo 1 > events/kprobes/gtl_in/enable
echo 1 > events/kprobes/gtl_out/enable
echo 1 > tracing_on
# run urma_perftest
cat trace
```

x86_64: swap `%x0,%x1,%x2` for `%di,%si,%dx` (SysV ABI).

Output:

```
urma_perftest-12345 [007] .... 891.234: gtl_in:  (ubcore_get_tp_list+0x0/0x90) dev=0xffff8881... cfg=0xffffc900... tp_cnt_p=0xffffc900... tp_cnt=128
urma_perftest-12345 [007] .... 891.237: gtl_out: (ubcore_get_tp_list+0x88/0x90 <- udma_get_tp_list+0x18) ret=0
```

`+0(%x2):u32` = dereference register x2 (the `tp_cnt` pointer) at offset 0, read as u32. That's how you reach through pointers without a kernel module.

### 6.2 Cleanup

```sh
echo 0 > events/kprobes/gtl_in/enable
echo 0 > events/kprobes/gtl_out/enable
echo > kprobe_events
```

(Disable before clearing; the kernel rejects removing an active probe.)

### 6.3 bpftrace — one liner, no tracefs poking

Latency per call:

```sh
bpftrace -e '
kprobe:ubcore_get_tp_list   { @start[tid] = nsecs; }
kretprobe:ubcore_get_tp_list {
    $dur = (nsecs - @start[tid]) / 1000;
    printf("pid=%d tid=%d dur_us=%d ret=%d\n", pid, tid, $dur, retval);
    delete(@start[tid]);
}'
```

Log-2 histogram across a whole perftest run:

```sh
bpftrace -e '
kprobe:ubcore_get_tp_list    { @s[tid] = nsecs; }
kretprobe:ubcore_get_tp_list { @us = hist((nsecs - @s[tid]) / 1000); delete(@s[tid]); }'
```

Run perftest, Ctrl-C, and you have the empirical distribution behind `umdk_link_setup_timing.md` §10.30.

BTF-driven (kernel BTF present at `/sys/kernel/btf/vmlinux`; no register math, architecture-portable):

```sh
bpftrace -e '
kfunc:ubcore_get_tp_list {
    printf("dev=%p cfg=%p tp_cnt_in=%d\n", args->dev, args->cfg, *args->tp_cnt);
}
kretfunc:ubcore_get_tp_list {
    printf("ret=%d tp_cnt_out=%d\n", retval, *args->tp_cnt);
}'
```

`kfunc`/`kretfunc` are the modern preferred form when BTF is available.

### 6.4 C kernel-module form (only when stateful in-kernel logic is needed)

```c
// kp_gtl.c
#include <linux/module.h>
#include <linux/kprobes.h>

static int gtl_entry(struct kprobe *p, struct pt_regs *regs)
{
    pr_info("gtl: dev=%px cfg=%px tp_cnt_p=%px\n",
            (void *)regs->regs[0],   // aarch64: x0
            (void *)regs->regs[1],   // x1
            (void *)regs->regs[2]);  // x2
    return 0;
}

static struct kprobe kp = {
    .symbol_name = "ubcore_get_tp_list",
    .pre_handler = gtl_entry,
};

static int __init kp_init(void) { return register_kprobe(&kp); }
static void __exit kp_exit(void) { unregister_kprobe(&kp); }
module_init(kp_init);
module_exit(kp_exit);
MODULE_LICENSE("GPL");
```

```sh
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo insmod kp_gtl.ko
dmesg -w
```

99% of the time the tracefs one-liner or bpftrace is what you want. This form is for permanent debugging modules or stateful handlers.

---

## 7. Which tool for which job

| Situation | Pick |
|---|---|
| "Where's my expected log line?" | First check `g_ubcore_log_level` (§2.4) |
| Visibility of an existing log site, more verbose | Raise `g_ubcore_log_level` to 6 (INFO) or 7 (DEBUG) |
| Function call graph + timing, no source change | ftrace `function_graph` (§5.1) |
| Peek at a function's arguments | kprobe tracefs (§6.1) or `bpftrace kfunc` (§6.3) |
| Histogram / aggregation across a run | `bpftrace` (§6.3) |
| Hookable in production, hot-path safe | A real `TRACE_EVENT` — ubcore doesn't have one yet; use ubase's where it overlaps |
| Async notification to other kernel/user consumers | The event API (§1) — but this is control plane, not observability |
| Stateful in-kernel handler | C kprobe module (§6.4) |
| Mid-function state inspection | kprobe with offset (`ubcore_get_tp_list+0x42`) + fetch expressions |

## 8. The relationship cheat-sheet

```
┌────────────────────────────────────────────────────────────────┐
│  ubcore async notifications: enum ubcore_event_type + dispatch │  §1
│  (control plane fanout — NOT observability)                    │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  ubcore_log_*  →  pr_<level>  →  printk  →  dmesg              │  §2
│  (severity-gated structured log; no tracefs, no perf, no BPF)  │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  TRACE_EVENT(...)                                              │  §3
│     ├─ generates trace_<name>(...) call-site (a tracepoint)    │
│     └─ generates ftrace event metadata (format, filter, …)     │
│  Consumed by: ftrace event tracer / perf / BPF                 │
│  (ubcore has NONE; ubase has many)                             │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  ftrace function tracer  (mcount/fentry nop-patch)             │  §5
│  Works on any non-notrace, non-inlined function — no source    │
│  change needed. function_graph adds entry/exit + duration.     │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  kprobe  (symbol+offset, int3 or fentry-patch)                 │  §6
│  Attach anywhere. No ABI promise, more expensive, no self-     │
│  description. Powerful but brittle. bpftrace kfunc/BTF is the  │
│  modern preferred surface when BTF is present.                 │
└────────────────────────────────────────────────────────────────┘
```

When someone says "ubcore tracing," ask which they mean — it's almost always §2 (the `ubcore_log_*` macros) but occasionally §1 (the event API). For real ftrace-style tracing, ubcore today gives you §5 and §6, not §3.
