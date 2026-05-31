# bpftrace uprobe mechanics + ASLR-relative call-site localization

_Last updated: 2026-05-25._

A methodology reference for tracing call-site latency in stripped user-space binaries with `bpftrace`. Two complementary parts:

1. **What actually happens** when you fire a bpftrace uprobe/uretprobe script (lifecycle from parse to detach).
2. **How to localize a slow call site** without symbols, using ASLR-invariant relative offsets — the trick that pinned the `index=2 → exchange_seg_info` finding in [UMDK#7](https://github.com/rainbay001-dotcom/UMDK/issues/7).

Companion docs:
- [`umdk_urma_perftest_call_chain.md`](umdk_urma_perftest_call_chain.md) — the urma_perftest send_lat call chain that the worked example sits on
- [`umdk_urma_perftest_ctp.md`](umdk_urma_perftest_ctp.md) — CTP vs RTP cold-start comparison; the slow-tail measurement that started this trace
- [`umdk_ubcore_logging_and_tracing.md`](umdk_ubcore_logging_and_tracing.md) — ubcore-side ftrace/tracepoint/kprobe equivalents

Worked example throughout: a 100-way concurrent `urma_perftest send_lat --ctp` workload, where one specific `sock_sync_data` call site blocks 1-8 seconds while every other call site stays under 256 µs. The script under analysis is the one [JinDou1210 ran](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4509158242).

---

## 1. The script

```bash
cat > /tmp/lr_check2.bt <<'BPF_EOF'
uprobe:/usr/bin/urma_perftest:sock_sync_data
{
    @s[tid] = nsecs;
    @call_n[tid] = (@call_n[tid] + 1);
}
uretprobe:/usr/bin/urma_perftest:sock_sync_data
/ @s[tid] /
{
    $us = (nsecs - @s[tid]) / 1000;
    if ($us > 1000000) {
        @slow_callers[@call_n[tid], ustack(2)] = count();
    } else {
        @fast_callers[@call_n[tid], ustack(2)] = count();
    }
    delete(@s[tid]);
}
END {
    printf("=== SLOW (>1s) callers by index ===\n");
    print(@slow_callers);
    printf("\n=== FAST callers by index ===\n");
    print(@fast_callers);
    clear(@s);
    clear(@call_n);
}
BPF_EOF

sudo bpftrace /tmp/lr_check2.bt > /tmp/lr2.txt 2>&1 &
```

Conceptual structure: tag each `sock_sync_data` entry with a timestamp + per-TID call counter; on return, classify slow vs fast by the call counter and the 2-frame user stack.

---

## 2. Lifecycle of a bpftrace run

### 2.1 Shell setup (before bpftrace runs)

```bash
sudo bpftrace /tmp/lr_check2.bt > /tmp/lr2.txt 2>&1 &
```

- `> /tmp/lr2.txt` — fd 1 redirected to the file (truncated if it exists).
- `2>&1` — fd 2 duplicated onto fd 1, so stderr lands in the same file.
- `&` — background; shell prints `[1] <PID>` and returns.
- The redirection happens **in the child** before `execve`, so bpftrace inherits already-redirected fds.

`sudo` checks its credential cache; if the tty cache is cold, it tries to prompt — and **deadlocks invisibly** because stdout/stderr are now in a file. Symptom: backgrounded job appears to hang with `/tmp/lr2.txt` empty. Fix: `sudo -v` interactively before backgrounding.

### 2.2 Parse / compile / verify

This is the visible 50-300 ms before "Attaching..." shows up:

1. **Parse** the script into AST.
2. **Type-check**. `@s[tid]` infers as `map<u32,u64>`. `@slow_callers[i64, stack]` infers as `map<(i64,stack), u64>`.
3. **Resolve probe targets**. For `uprobe:/usr/bin/urma_perftest:sock_sync_data`, bpftrace opens the ELF, walks `.symtab` (or DWARF debug info if the binary is stripped — needs a `-debuginfo` package on the system or `.gnu_debuglink`-linked file) to find `sock_sync_data`'s offset within `.text`. Fail-fast if the symbol can't be resolved.
4. **Compile** each probe action to BPF bytecode. `if ($us > 1000000)` becomes a conditional jump; `ustack(2)` becomes a call to `bpf_get_stackid` with `BPF_F_USER_STACK` and depth 2.
5. **`bpf(BPF_PROG_LOAD, …)`** submits each program. **Kernel verifier runs here** — bounded loops, valid pointer arithmetic, no out-of-bounds map access. Verifier rejection fails before any probe attaches.

### 2.3 Maps

`bpf(BPF_MAP_CREATE, …)` per `@`-variable plus internal scratch maps. Default capacity is 4096 entries per key dimension; bump with `BPFTRACE_MAP_KEYS_MAX=…` for fan-in heavy workloads.

### 2.4 Probe attachment

For each `uprobe:/usr/bin/urma_perftest:sock_sync_data`:

1. bpftrace writes to `/sys/kernel/debug/tracing/uprobe_events` (or uses `perf_event_open` with the uprobe pmu directly on newer kernels):
   ```
   p:bpftrace_<id>/uprobe_at_<offset> /usr/bin/urma_perftest:<offset>
   ```
2. Kernel creates a `uprobe` for `(inode, offset)`. **The file on disk is NOT modified.**
3. When a process with that inode mapped + the target page faulted-in is found, the kernel **single-steps in and replaces the instruction at the target offset with a breakpoint** (`brk #0` on aarch64; `int3` on x86_64). COW semantics — only the process's page-table copy is modified.

uretprobe attachment is similar, but additionally the kernel installs a return trampoline: when the function does `ret`, control lands in kernel space first, fires the uretprobe BPF, then jumps to the original return address.

bpftrace prints `Attaching 3 probes...` — note **3**, not 2. The `END` block counts as a probe.

### 2.5 Steady state

Every call to `sock_sync_data` in any process now triggers:

1. CPU hits `brk` → kernel exception handler → runs the entry BPF program:
   ```
   @s[tid] = nsecs;                         # bpf_ktime_get_ns()
   @call_n[tid] = (@call_n[tid] + 1);       # atomic-ish map update
   ```
   ~1-3 µs end-to-end on modern CPUs. Stays on the same CPU.
2. Kernel single-steps the original instruction in a per-uprobe slot, returns to userspace.
3. `sock_sync_data` runs normally.
4. On `ret`, the trampoline catches it, runs the uretprobe BPF:
   ```
   $us = (nsecs - @s[tid]) / 1000;
   if ($us > 1000000) {
       @slow_callers[@call_n[tid], ustack(2)] = count();
   } else {
       @fast_callers[@call_n[tid], ustack(2)] = count();
   }
   delete(@s[tid]);
   ```
   - `ustack(2)` calls `bpf_get_stackid(BPF_F_USER_STACK)` — kernel walks two user-mode frames (FP-chain or DWARF), hashes them, stores the stack itself in a stack-trace map.
   - `@slow_callers[index, stack]` does the hash + atomic increment in kernel.
5. Returns to userspace at the saved LR.

`delete(@s[tid])` is essential — without it, `@s` would grow unboundedly with every TID that ever called `sock_sync_data`.

### 2.6 bpftrace userspace main loop

bpftrace itself blocks on `epoll_wait` for signals. It is **not** polling maps; map updates happen entirely in kernel via the BPF programs. bpftrace's userspace CPU usage between START and END is near zero.

### 2.7 What's in `/tmp/lr2.txt` during the run

Just:
```
Attaching 3 probes...
```
Nothing else until END fires. `tail -f /tmp/lr2.txt` won't show live updates. If streaming is needed, use explicit `printf` calls inside probe handlers.

### 2.8 SIGINT → END → cleanup

`kill -SIGINT $BPF` triggers:

1. SIGINT delivered → bpftrace signal handler sets stop flag → `epoll_wait` returns.
2. END block runs:
   ```
   printf("=== SLOW (>1s) callers by index ===\n");
   print(@slow_callers);
   ...
   ```
   bpftrace iterates the map via `bpf(BPF_MAP_LOOKUP_BATCH, …)`, looks up each `stack_id` in the stack-trace map, formats.
3. **Detach probes**: bpftrace writes `-:bpftrace_<id>/...` to `uprobe_events`. Kernel walks every process that had the uprobe installed and **restores the original instruction** at the target offset.
4. `close()` on map fds → kernel frees the maps.
5. Exit.

Now `/tmp/lr2.txt` has the full output. `wait $BPF` collects exit status.

### 2.9 Common ways the script silently misbehaves

| Symptom | Cause | Fix |
| --- | --- | --- |
| `/tmp/lr2.txt` empty | sudo prompting for password into a redirected stdout | `sudo -v` first, then background |
| `Could not resolve symbol` | Binary stripped, no debuginfo, `sock_sync_data` is `static` | Install `*-debuginfo` rpm; or `bpftrace -l 'uprobe:/usr/bin/urma_perftest:*sock_sync*'` to see what *is* resolvable |
| Stack frames all `0x0` or repeated | FP omitted at compile time; aarch64 default with `-fomit-frame-pointer` | Use `ustack(2, perf)` or unwind manually via DWARF |
| Map-full warnings | 4096-entry cap exceeded | `BPFTRACE_MAP_KEYS_MAX=…` env var |
| `@s[tid]` leaks | Process exited between entry and return | `clear(@s)` in END (this script already does) |
| END never runs | bpftrace crashed | Always check `wait $BPF; echo $?` |
| `'lr' is not a valid register on this architecture (arm64)` | `reg("lr")` only works on x86_64 in bpftrace's syntax — aarch64 link-register isn't named in the `reg()` map | Use `ustack(2)` to get the return address from frame 0 instead (this is what the script above does) |

---

## 3. ASLR-invariant call-site localization

The bpftrace output from the experiment showed something like:

```
@slow_callers[2,
    0xaaaab9f59430
    0xaaaab9f5af80
]: 1
@slow_callers[2,
    0xaaad145b9430
    0xaaad145baf80
]: 1
@slow_callers[2,
    0xaaad43289430
    0xaaad4328af80
]: 1
... (36 entries total, all with @slow_callers[2, ...]) ...
```

36 different stack traces, all with `index=2`, all from different PIDs (different high bits in the addresses). Symbols never resolved. The conclusion was still **all 36 came from the same call site — `exchange_seg_info` at `perftest_resources.c:903`**. Here's how the reasoning works.

### 3.1 Why no symbols

`bpftrace`'s `ustack` symbolizer needs either:
1. The symbol in `.symtab` (binary not stripped), or
2. The symbol exported in `.dynsym`, or
3. Separate debuginfo file (`/usr/lib/debug/.../<binary>.debug`, found via `.gnu_debuglink` in the main binary).

`sock_sync_data` is `static` in `perftest_resources.c` — never in `.dynsym`. Distro `urma-perftest` packages are usually stripped (no `.symtab`). If the debuginfo rpm isn't installed in bpftrace's search path, the symbolizer returns raw PCs.

Note that *uprobe attachment* and *ustack symbolization* are different code paths. Attachment uses the symbol-to-offset resolution at script-load time; ustack symbolization uses runtime PC-to-symbol resolution. They can have different success states — uprobes attached fine here (because debuginfo *is* installed for `addr2line` purposes), but stack symbolization missed.

### 3.2 ASLR only moves the base

PIE binaries get loaded at a randomized base address per process:

```
PID 9091:  base = 0xaaaab9f50000   →  any function at fn_offset is at 0xaaaab9f50000 + fn_offset
PID 9092:  base = 0xaaad145b0000   →  same fn_offset is at 0xaaad145b0000 + fn_offset
```

The **`.text`-internal layout is compile-time fixed**. Two processes running the exact same binary have the exact same `fn_offset` for `sock_sync_data` (and every other function); they differ only in where the binary as a whole sits in their VA space.

On Linux, ASLR aligns the load base on `PAGE_SIZE = 4 KiB`, so the **low 12 bits of any PC are identical across PIDs**. In practice, since `.text` is usually much larger than 4 KiB and only the start of `.text` is page-aligned, the **low ~16-20 bits** of any specific PC are stable across PIDs. That's what shows up in the bpftrace output.

### 3.3 The match

Look at the low 16 bits of frame 0 across all 36 slow events:

```
0xaaaab9f5_9430
0xaaad145b_9430
0xaaad4328_9430
0xaaaaefee_9430
... (all ending in _9430)
```

Probability of 36 independent ASLR samples coincidentally matching their low 16 bits = ~`2^(-16*35)` ≈ 0. So all 36 events come from the **same physical PC** within `urma_perftest`.

Same logic for frame 1: all `..._af80`. Same call site for the *caller's caller* too.

### 3.4 Static cross-reference with addr2line

To name the call site, you need a static map from offset to source. Two complementary tools:

```bash
# 1. List all BL sock_sync_data sites
objdump -d /usr/bin/urma_perftest | grep -B1 'bl.*sock_sync_data'
# expect ~7 hits per perftest_resources.c

# 2. Translate each offset to source location
DBG=/usr/lib/debug/usr/bin/urma_perftest-*.aarch64.debug
for off in 0x73d8 0x83b0 0x93b4 0x9428 0x94f8 0x9580 0x98d4; do
    echo -n "$off → "
    addr2line -e /usr/bin/urma_perftest -f -C "$off" 2>/dev/null \
        || addr2line -e $DBG -f -C "$off"
done
```

Actual output from JinDou1210's run on the live system ([UMDK#7 comment 4508578988](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4508578988), 2026-05-21 13:10:15 UTC):

```
0x73d8 → check_remote_cfg     perftest_parameters.c:1546
0x83b0 → sync_time            perftest_communication.c:351
0x93b4 → exchange_seg_info    perftest_resources.c:896
0x9428 → exchange_seg_info    perftest_resources.c:903   ← matches the bpftrace `_9430` low-bit signature (= 0x9428 + 8)
0x94f8 → exchange_jetty_id    perftest_resources.c:943
0x9580 → exchange_jetty_id    perftest_resources.c:950
0x98d4 → exchange_tp_info     perftest_resources.c:1153
```

All 7 `bl sock_sync_data` call sites in `urma_perftest` are accounted for; only `0x9428` (`exchange_seg_info:903`) matches the bpftrace return-address signature. Combined with the disasm at the next subsection, that nails the slow site.

For frame 1 (`_af80`) the same `addr2line` call gives `exchange_connection_info perftest_resources.c:1181` — the line where `exchange_seg_info(...)` is invoked.

### 3.5 Why the bpftrace offset is `0x9430` and not `0x9428`

The 8-byte gap is normal:

- `addr2line` returns the **first** instruction belonging to a source line. A line like `sock_sync_data(sock_fd[i], len, local, remote);` typically compiles to multiple instructions (argument setup + `bl`). `0x9428` is the first instruction of line 903 (an argument-setup `ldr`).
- The `bl sock_sync_data` itself is the **last** instruction of that line, at `0x942c` (AArch64 `bl` is 4 bytes).
- The **return address** is `bl_pc + 4 = 0x9430`.
- `ustack` reports return addresses (where execution will resume in the caller after the called function returns), not the BL itself.

Verify with disasm:
```bash
objdump -d /usr/bin/urma_perftest | awk '/<sock_sync_data>:/{f=0} /<exchange_seg_info>:/{f=1} f{print}' \
  | grep -B1 -A1 '942[0-9a-f]:'
```
Expect:
```
9428:  ...     ldr  x3, [...]
942c:  ...     bl   <sock_sync_data>
9430:  ...     mov  ...                   ← next instruction; uprobe sees this
```

### 3.6 Putting it together — full reasoning chain

| Step | Tool | Output |
| --- | --- | --- |
| 1 | bpftrace uretprobe with `ustack(2)` + `@call_n[tid]` index | `@slow_callers[2, <stack>]` for 36 ASLR'd traces |
| 2 | Visual inspection of low 16 bits of frame 0 | All `_9430` → same PC |
| 3 | Same for frame 1 | All `_af80` → same caller's caller |
| 4 | `objdump -d \| grep bl.*sock_sync_data` | 7 candidate call sites at offsets {0x73d8, 0x83b0, 0x93b4, 0x9428, 0x94f8, 0x9580, 0x98d4} |
| 5 | `addr2line 0x9428` | `exchange_seg_info perftest_resources.c:903` |
| 6 | `addr2line 0xaf80` | `exchange_connection_info perftest_resources.c:1181` |
| 7 | Cross-check: `0x9430` = `0x942c + 4` = return address from BL at line 903 | ✓ |

Conclusion: **all `index=2` slow events are `exchange_seg_info` line 903's `sock_sync_data` call**.

No debuginfo loaded into bpftrace. No recompile of perftest. Just runtime addresses + a binary on disk + addr2line.

### 3.7 How `addr2line` actually resolves the offset

The chain above treats `addr2line` as a black box. It isn't. Knowing what it reads is useful when it surprises you (e.g., reports `??:?`, or gives an unexpected line, or claims a different function than you expected).

#### 3.7.1 What addr2line is reading

The binary contains (or links to) several DWARF debug sections in the ELF:

| Section | Purpose |
| --- | --- |
| `.debug_info` | Type/function/variable DIEs (Debug Information Entries). `DW_TAG_subprogram` entries with `DW_AT_low_pc`/`DW_AT_high_pc` ranges → that's how addr2line names the **function**. |
| `.debug_aranges` | Optimization index: address ranges → compilation-unit (CU) offsets. Lets addr2line skip straight to the right CU instead of scanning all of `.debug_info`. |
| `.debug_line` | The **line number program** — bytecode that, when executed, generates the `(address, file, line, column)` table. This produces the `:903` part. |
| `.debug_str` / `.debug_line_str` | String table; file names and function names live here. |

For stripped binaries, these sections sit in a **separate file**. addr2line finds it via either:

1. `.gnu_debuglink` — a tiny section in the main binary pointing at a filename plus CRC. addr2line looks under `/usr/lib/debug/<dir>/<file>.debug`.
2. **Build-ID** — `.note.gnu.build-id` in the main binary holds a SHA-1-ish ID; addr2line looks for `/usr/lib/debug/.build-id/<aa>/<bbbbbb…>.debug`.

That's why Jin's `DBG=/usr/lib/debug/usr/bin/urma_perftest-25.12.0-B084.oe2403sp3.aarch64.debug` line works: the strip-then-debuginfo-package workflow puts the actual DWARF in a separate `.debug` file.

#### 3.7.2 The line number program — bytecode state machine

`.debug_line` is **not** a flat table. It's compressed bytecode that, when executed by a DWARF consumer, generates the line table. Registers include `address`, `file`, `line`, `column`, `op_index`; opcodes say things like "advance address by N, advance line by M, emit a row".

For our query `addr2line 0x9428`:

1. **Find the CU.** Walk `.debug_aranges`; locate the CU whose address range contains `0x9428` → `perftest_resources.c`'s CU.
2. **Find the function.** Inside that CU's `.debug_info`, walk `DW_TAG_subprogram` entries until one's `[low_pc, high_pc)` range contains `0x9428` → `exchange_seg_info`.
3. **Find the source line.** Execute the line program for this CU forward. The generated table looks like:
   ```
   address     file                       line
   0x93b0      perftest_resources.c       882    ← exchange_seg_info entry
   ...
   0x9420      perftest_resources.c       902    ← previous source line
   0x9428      perftest_resources.c       903    ← <-- query lands here
   0x9430      perftest_resources.c       904    ← next source line
   ```
   addr2line returns the row with the largest `address ≤ query`. For `0x9428` that's `(perftest_resources.c, 903)`.

Crucially the state machine only emits a row where `(file, line)` **changes** — not for every instruction. That's why `0x9428` and `0x942c` both map to line 903 (one row covers both), but `0x9430` maps to 904 (a new row).

#### 3.7.3 Why `addr2line 0x9428` and `addr2line 0x9430` differ by one source line

The relevant disasm:

```
0x9428:  ldr   x3, [sp, #16]         ; setup arg `remote`           ← line 903 starts here
0x942c:  bl    <sock_sync_data>      ; the call                     ← still line 903
0x9430:  ldrsb w0, [x0]              ; check return value           ← line 904 starts here
```

The compiler attributes both the arg-setup `ldr` (`0x9428`) and the `bl` itself (`0x942c`) to **line 903** — they're all part of "the statement that calls `sock_sync_data`". So the line table has *one* row for `[0x9428, 0x9430)`, all marked line 903. At `0x9430` execution has moved into the next source statement → new row, line 904.

Hence:
- `addr2line 0x9428` → line 903 ✓
- `addr2line 0x942c` → line 903 (same row)
- `addr2line 0x9430` → line 904 (next row)

The bpftrace stack frame is the *return address* (= `bl_pc + 4 = 0x942c + 4 = 0x9430`), so passing it directly to addr2line gives `:904` — **correct but answers a different question** ("where did execution resume?" vs "where was the call?"). Subtract 4-8 bytes (or just disasm and find the BL) to get the call site.

#### 3.7.4 Inspecting the table yourself

You don't have to trust addr2line. Dump the decoded line table directly:

```bash
# Either tool works:
readelf --debug-dump=decodedline /usr/bin/urma_perftest 2>/dev/null \
    | grep -B2 -A2 -E ' 90[2-5] ' | head -30

objdump --dwarf=decodedline /usr/bin/urma_perftest 2>/dev/null \
    | awk '/perftest_resources.c/{file=1} file && /^perftest_resources.c/{print}' \
    | awk '$2 >= 900 && $2 <= 910'
```

Expected rough format:

```
File name              Line number    Starting address    Stmt
perftest_resources.c            902             0x9420       x
perftest_resources.c            903             0x9428       x
perftest_resources.c            904             0x9430       x
perftest_resources.c            905             0x9438       x
```

And/or use `objdump -d -S` for inline-source-with-disasm (requires debuginfo):

```bash
objdump -d -S /usr/bin/urma_perftest 2>/dev/null \
    | awk '/<exchange_seg_info>:/{p=1} p; /^$/{if(p) exit}' \
    | head -60
```

Output interleaves C source with instructions:

```
903:        sock_sync_data(sock_fd[i], len, local, remote);
    9420:   ...
    9428:   ldr   x3, ...
    942c:   bl    <sock_sync_data>
904:        if (...
    9430:   ldrsb w0, ...
```

Four independent tools (bpftrace stack, objdump grep for BL, addr2line, objdump -S) — one consistent story. That's what made this analysis confident enough to act on.

#### 3.7.5 PIE/ASLR vs DWARF addresses

DWARF records addresses as the binary's **internal** virtual addresses — for a PIE binary the recorded base is 0, so DWARF addresses are effectively file offsets within the loaded image. Runtime PCs = ASLR_base + DWARF_address. The low ~16-20 bits of a runtime PC therefore equal the low bits of the DWARF address (modulo `2^N` where `2^N ≥` `.text` size). That's why the workflow

```
bpftrace runtime PC  →  read low 16 bits  →  addr2line on those bits
```

works without ever knowing any specific PID's ASLR base. No subtraction needed in practice — the low bits *are* the DWARF address.

#### 3.7.6 Failure modes of addr2line

- **Inlined functions** — use `addr2line -i` to print the inlining chain. Without `-i`, only the outermost frame shows up.
- **LTO** — link-time optimization re-orders `.text`, changing offsets. addr2line still works on the linked binary, but offsets from one build don't match another.
- **`-O2` statement merging** — overlapping address ranges per line; addr2line picks per its heuristic.
- **Wrong debuginfo file** — `.gnu_debuglink` CRC mismatch makes addr2line silently fall back to "no debug info". Verify with `readelf -p .gnu_debuglink /usr/bin/urma_perftest` and check the file exists at the linked path.
- **Address outside any function** — addr2line returns `??:?`. Usually means a runtime PC wasn't reduced to a DWARF address, or the binary was re-stripped after the runtime was captured.

For the `index=2` case none of these bit, which is why the pipeline `bpftrace ustack → low 16 bits → addr2line → cross-check with objdump -d -S` produced a definitive answer on first try.

---

## 4. When this trick works (and when it doesn't)

### Works

- Stripped binary in production; debuginfo file available on disk (for offline `addr2line`).
- Containers / different machines / different distro versions — as long as the binary is the same.
- Multi-process fan-in (100s of PIDs) where eyeballing full PCs is unreasonable but low-bit comparison is O(1).
- ARM64 / x86_64 / RISC-V — instruction lengths differ but the relationship between BL/CALL site and return address is fixed per ISA.

### Doesn't work

- **JIT or dynamically loaded code** — offsets aren't compile-time constants.
- **Inlined call sites** — the same C-source-level call can compile to different `.text` offsets in different callers.
- **Multiple `.text` sections** — uncommon, but some LTO / `-ffunction-sections` configs split this up.
- **Frame pointer omitted + DWARF unwind disabled** — `ustack` returns garbage; even relative offsets are unreliable.

---

## 5. Generalization — the "extract call-site signature" pattern

Anytime you have N samples with raw addresses and want to know whether they come from the same call site:

1. Extract a low-bit "signature" from each frame's PC (last 16-20 bits).
2. Group by signature. Identical signature = identical call site (with very high probability).
3. If you have the binary on disk, run `addr2line` on the signature to name the site.
4. Cross-check by adding `±4 bytes` (or whatever the call instruction width is on your ISA) and matching against `objdump`'s disassembly.

The pattern shows up beyond bpftrace too: any time you symbolize raw stack traces from core dumps, perf samples, or eBPF outputs without symbol metadata, the same offset-grouping trick localizes events to call sites.

---

## 6. Worked-example data

Multi-author work — running record across UMDK#7:

- **objdump grep + addr2line script**: drafted in [comment 4509072961](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4509072961) (rainbay001-dotcom, 13:07:39 UTC).
- **addr2line actual run**: executed by **JinDou1210** in [comment 4508578988](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4508578988) at 13:10:15 UTC. Output covers all 7 BL sites (table reproduced in §3.4).
- **First bpftrace stack-capture attempt** (in the same Jin comment): failed with `'lr' is not a valid register on this architecture (arm64)` — switched to `ustack(2)` for the next iteration (see §2.9).
- **Successful bpftrace run with `ustack(2)`**: [comment 4509158242](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4509158242) (JinDou1210) — produced the 36 raw-PC traces all ending `_9430` / `_af80`.
- **Address-grouping analysis**: [comment 4509181983](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4509181983) (rainbay001-dotcom) — combined Jin's bpftrace output + Jin's addr2line output to pin `index=2` to `exchange_seg_info:903`.
- **Methodology explainer**: [comment 4534495084](https://github.com/rainbay001-dotcom/UMDK/issues/7#issuecomment-4534495084) (rainbay001-dotcom, 2026-05-25) — the post that this doc consolidates and extends.

Key numbers:

- 100 concurrent `urma_perftest send_lat --ctp -n 5 -s 2` instances.
- 36 events landed in `@slow_callers[2, ...]` (call index = 2, duration > 1 s).
- All 36 frame 0 PCs end in `_9430`; all 36 frame 1 PCs end in `_af80`.
- `addr2line` maps offset `0x9428` to `exchange_seg_info perftest_resources.c:903` (the else branch's `sock_sync_data` call).
- `addr2line` maps offset `0xaf80` to `exchange_connection_info perftest_resources.c:1181` (where it invokes `exchange_seg_info`).
- Wall-clock distribution per call: 6 events < 1 ms, 15 events ~1.5 ms, 73 events 1-8 s.

Total time spent in `index=2` `sock_sync_data` across 100 PIDs ≈ 492 seconds. Average ~4.9 s per PID. **The entire slow tail of 100-way `--ctp` send_lat is one specific `exchange_seg_info` TCP exchange waiting for the server side to finish its register_seg burst.**

The methodology in this doc is what produced that pin-point conclusion from address-only data.
