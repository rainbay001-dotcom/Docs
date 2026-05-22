# UBSocket vs plain TCP sockets vs Linux SMC-R

_Last updated: 2026-05-22._

Three POSIX-socket-compatible stacks, three very different mechanisms for moving bytes between processes. Same outward API; very different cost model. This doc compares them axis-by-axis so the architectural lineage of ubsocket — and where it diverges from the prior art — is unambiguous.

Scope:
- **TCP sockets**: Linux BSD sockets over the kernel TCP/IP stack — the baseline.
- **SMC-R**: Linux kernel feature (`AF_SMC`, in mainline since v4.11, originated by IBM for z/OS), promotes TCP connections to RoCE RDMA transparently after a Connection-Layer-Control (CLC) handshake; falls back to plain TCP on failure. The `SMC-D` variant uses the ISM device for intra-host; structurally similar.
- **ubsocket**: LD_PRELOAD userspace shim that intercepts POSIX socket calls and re-routes the data plane to UMQ → URMA → UB; falls back to plain TCP per fd.

ubsocket and SMC-R are structurally **the same pattern with different placement and fabric**: keep TCP as the bootstrap, switch the data plane to RDMA. Where they differ is *where the interception lives* (kernel vs userspace) and *what RDMA fabric* they target (RoCE vs UB).

Companion docs:
- [`umdk_ubsocket_umq_urma_stack.md`](umdk_ubsocket_umq_urma_stack.md) — the full ubsocket → UMQ → URMA call chain that this doc summarizes
- [`umdk_umq_jetty_pair_design.md`](umdk_umq_jetty_pair_design.md) — UMQ's paired IO+FC jetty design (the analog of SMC-R's link group + LLC)

---

## 1. One-line framing

| Stack | What it actually is |
| --- | --- |
| **TCP sockets** | Stream over the Linux TCP/IP stack; kernel-copy data path; universal. |
| **SMC-R** | Linux kernel `AF_SMC` socket family; CLC handshake on top of TCP; data plane = RDMA WRITE into peer's RMB (Receive Memory Buffer) ring; LLC messages for credit/flow control; transparent TCP fallback. |
| **ubsocket** | Userspace `LD_PRELOAD` shim (`librpc_adapter_brpc.so`); intercepts POSIX socket calls; data plane = UMQ → URMA → UB jetty pair; bind-info exchanged over the original TCP socket; per-fd TCP fallback. |

---

## 2. Axis-by-axis comparison

| Axis | TCP socket | SMC-R | ubsocket |
| --- | --- | --- | --- |
| **Where intercepted** | n/a — *is* the stack | Linux kernel — new `AF_SMC` family (300); netfilter / pnet table policy can auto-promote `AF_INET` | Userspace `LD_PRELOAD` — wraps glibc `socket`/`connect`/`writev`/… via `dlsym(RTLD_NEXT)` (`src/ubsocket/socket_adapter.h`) |
| **App changes** | none | none if `AF_SMC` enabled via sysctl/policy; or app uses `socket(AF_SMC, …)` | none — `LD_PRELOAD=librpc_adapter_brpc.so` + env vars (`UBSOCKET_TRANS_MODE=ub`, `UBSOCKET_DEV_NAME=...`, …) |
| **Fabric / wire** | Ethernet / IP / TCP | RoCEv1/v2 (Ethernet-class lossless), or SMC-D over ISM for intra-host | UB (Huawei Unified Bus) via URMA; can also bind IB via `UMQ_TRANS_MODE_IB` |
| **Hardware required** | any NIC | RoCE-capable RNIC | UB-capable NPU / bonding device, or IB HCA |
| **Bootstrap channel** | n/a | The TCP 3-way handshake itself: CLC piggybacks on the first TCP segments to negotiate RDMA capability | TCP connect completes normally; then `queue_bind_info` blob (≤512 B containing `{eid, jetty_id, tp_mode, tp_type, token, fc_info, notify_buf, order_type}`) is exchanged over that TCP socket before `umq_bind` (`brpc_file_descriptor.h:680-702`) |
| **Steady-state data path** | `copy_from_user` → `tcp_write_xmit` → IP → softirq RX → `copy_to_user` | RDMA WRITE into peer's RMB ring + LLC frames for credit / connection control | `urma_post_jetty_send_wr` (opcode chosen by `umq_ub_fill_wr_impl` in `umq_ub.c:3147` — SEND / SEND_IMM / WRITE_IMM / READ) |
| **Copy semantics** | one copy each way (TX into skb, RX out of skb) | zero-copy on RX (data lands directly in pre-registered RMB); one local copy on TX before RDMA WRITE — peer CPU uninvolved | zero-copy *if* app uses bRPC IOBuf (the IOBuf allocator is hooked to come from registered memory via `brpc_iobuf_adapter.cpp`); else one userspace copy into a qbuf |
| **Memory registration** | n/a | RMB ring per link group, registered at link-group setup | Single `urma_register_seg` over the whole IO pool (`UBSOCKET_POOL_INITIAL_SIZE` MB, default 1024 MB) at `umq_init`; every qbuf is a slot inside it (`sges[].tseg = tseg_list[mempool_id]`). Pool grows in 64 MB chunks to `UBSOCKET_POOL_MAX_SIZE`. |
| **Sharing across connections** | none | **Link Group**: many `AF_SMC` connections share one RoCE QP path + one set of RMBs to a given peer | **Main UMQ + share-JFR**: many ubsocket fds share one JFR (and its JFC/JFCE) per (device, trans_mode). `UBSOCKET_ENABLE_SHARE_JFR=true` is default. URMA-level: `urma_post_jfr_wr` (shared) vs `urma_post_jetty_recv_wr` (per-jetty). |
| **Flow control** | TCP congestion + sliding window | LLC credit messages over the RDMA path | Dedicated **flow-control jetty** parallel to the IO jetty; credit windows in shared memory (see `umdk_umq_jetty_pair_design.md`) |
| **Completion delivery** | softirq → epoll | RDMA CQ → kernel softirq → poll handler → wakes the socket fd | URMA JFC event → JFCE eventfd → ubsocket's epoll mux drains via `umq_get_cq_event` (= `urma_wait_jfc` + `urma_ack_jfc`) then `umq_dequeue` (= `urma_poll_jfc`) |
| **Fallback to TCP** | n/a | CLC handshake fails or peer doesn't support SMC → the underlying TCP connection just continues as plain TCP | If `umq_init` / `umq_create` / `umq_bind` fail, `SOCKET_FD_TRANS_MODE_TCP` is set and all subsequent ops on that fd go through the recorded original libc symbols. **Per-fd**, not per-process. |
| **Privileged?** | unprivileged | unprivileged for app; kernel module + RDMA dev permissions | unprivileged for app; needs `umdk-urma` rpm + access to `uburma` char dev |
| **Per-connection state lives** | `struct sock`, `tcp_sock` (kernel) | `struct smc_sock`, link group context (kernel) | `BrpcFileDescriptor` + `ub_queue_t` (jetty + JFC + JFCE + bind ctx) — all userspace |
| **Process isolation** | each `struct sock` independent | link group is per-process | each process has its own `Brpc::Context` and main UMQ; no sharing across processes |
| **Bytestream or message** | byte stream (TCP semantics) | byte stream (SMC preserves TCP semantics — the design goal) | byte stream at the app level; ubsocket adds a framed message layer (`UbsocketMsgHeader { msgId, payloadLen, checksum, msgType }` in `ubsocket_io.h`) for RPC framing |
| **Ordering** | in-order per flow (TCP) | in-order per flow (LLC enforces it across the RDMA WRITE stream) | in-order via URMA RC jetty pair (`urma_bind_jetty` only in RC mode); RM mode relaxed |
| **Reliability** | TCP retransmission | RoCE link reliability + LLC error recovery | URMA RC jetty (ack-based) |
| **Code lives at** | `net/ipv4/tcp*.c` | `net/smc/` (mainline) | `src/ubsocket/` (userspace) + `src/hcom/umq/` + `liburma.so` (userspace) |
| **Loadable / swappable** | n/a | Kernel module `smc` | LD_PRELOAD swap; transport backend `libumq_ub.so` itself is `dlopen`'d, so swap UB ↔ IB at install time via `UBSOCKET_TRANS_MODE` |
| **Multi-host / single-host** | both | SMC-R = cross-host (RoCE); SMC-D = same-host (ISM or hardware) | UB targets in-pod / scale-up topology; cross-host depends on UB fabric reach |
| **Year of design** | 1980s (BSD); RDMA add-ons in the 2000s | 2017 mainlined; based on z/OS SMC from ~2013 | 2024-2026 (ubs-comm_9477 code base) |

---

## 3. Architectural similarities — ubsocket ↔ SMC-R

The two are remarkably parallel — different fabrics, same playbook:

1. **TCP-as-OOB-bootstrap.** Both keep TCP for the handshake and switch to RDMA for data. SMC-R embeds CLC into the TCP segments themselves; ubsocket lets the TCP handshake finish normally and then talks one round trip over the same TCP socket carrying the URMA bind blob. Either way: no separate management network needed.
2. **Per-connection RDMA peering object hidden behind a fd.** SMC-R wraps a link-group + RMB inside `smc_sock`. ubsocket wraps a `ub_queue_t` (= local jetty + JFCs + bind_ctx) inside `BrpcFileDescriptor`. The application sees an int fd.
3. **One memory region, many slots.** SMC-R: RMB ring shared across connections in a link group. ubsocket: IO pool registered once with `urma_register_seg`, every qbuf is a slot inside it. Both amortize per-message registration cost away.
4. **Connection multiplexing onto fewer hardware queues.** SMC-R link group: one RDMA QP path for many connections to the same peer. ubsocket share-JFR: one JFR / JFC / JFCE for many connections on the same device. Per-connection state stays in software; expensive hardware queues stay few.
5. **Graceful TCP fallback at connection setup**, no app awareness needed.
6. **In-band flow control on top of RDMA.** SMC-R uses LLC frames; ubsocket uses a dedicated FC jetty parallel to the IO jetty. Both choose **not** to rely solely on the RDMA fabric for credit management.

---

## 4. Key differences that matter

### a) Userspace vs kernel

SMC-R lives in the Linux kernel. That has real consequences:

- SMC-R inherits kernel socket buffer semantics (cgroup accounting, `TCP_INFO`, `getsockopt`, `SO_REUSEPORT`, etc.) — anything Linux exposes for TCP keeps working.
- ubsocket has to re-implement what it needs (its own epoll multiplexer in `polling_epoll.cpp`, its own fd tracking, its own `fcntl` / `ioctl` handling) and explicitly chooses *not* to forward operations that are awkward in userspace.
- Conversely, ubsocket can avoid syscalls on the hot path entirely once registered — `urma_post_jetty_send_wr` is a userspace doorbell ring. SMC-R still goes through `sendmsg`/`recvmsg` syscall machinery.

### b) Network model

SMC-R targets **cross-host RDMA on Ethernet (RoCE)** — datacenter scale. ubsocket targets **UB**, which is in-pod / scale-up topology (NPU-to-NPU within a server or rack via UnifiedBus, not across a datacenter). Different design points; the UMQ flow-control jetty is more critical at UB scale because there is no Ethernet-style PFC backstop.

### c) Protocol semantics on the wire

- SMC-R: the RDMA primitive is essentially RDMA WRITE into the peer's pre-shared RMB ring + LLC messages for sync. Mostly one-sided.
- ubsocket / UMQ: dynamic choice between `URMA_OPC_SEND` (two-sided), `_SEND_IMM`, `_WRITE_IMM`, and `_READ` (RNDV pull) inside `umq_ub_fill_wr_impl` (`umq_ub.c:3147`). More choice → potentially better large-message handling, but more state to coordinate (RNDV needs the peer to advertise an addr first).

### d) Pluggability

- SMC-R: one backend (RoCE), one kernel module. SMC-D adds same-host via ISM but is structurally the same code.
- ubsocket: transport is **dlopen-loaded by `trans_mode`**. Today: `UB / IB / UCP / IPC / UBMM / UB_PLUS / UBMM_PLUS`. The same `librpc_adapter_brpc.so` can run over IB if `UBSOCKET_TRANS_MODE=ib` and `libumq_ib.so` is on disk. Two layers of `dlopen` make this swap install-time, not compile-time.

### e) Lock primitives

ubsocket *registers down* its mutex/rwlock ops into UMQ (`umq_external_mutex_lock_ops_register` / `umq_external_rwlock_ops_register` in `ub_lock_ops.cpp:239,259`). SMC-R uses kernel locking primitives natively — no such injection. This is unique to ubsocket because it has to coexist with bRPC's bthread M:N scheduler in the same userspace: UMQ's internal state must lock using bthread-aware primitives, not OS mutexes.

### f) Bytestream framing

SMC-R preserves TCP semantics exactly: byte stream, no framing. ubsocket adds an **explicit framing header** (`UbsocketMsgHeader { msgId, payloadLen, checksum, msgType=REQUEST/RESPONSE }`) at the `ubsocket_io.h` layer. This is an extra protocol concession to bRPC's RPC model; pure byte-stream apps see it as transparent if their reads are framed-message-shaped, but in principle ubsocket is **not** a fully transparent TCP replacement at the wire level — only at the API level.

### g) Quoted speed-up

ubsocket's README claims **+40% over native TCP on bRPC**. Public SMC-R benchmarks have varied widely (IBM has published 30-50% latency reduction and 2-3× bandwidth gains on heavy workloads, depending on message size and queue depth). Neither number is broadly comparable without knowing workload shape and fabric — but the *order of magnitude* is similar, which is consistent with both being instances of the same architectural pattern. The win in both cases comes from removing kernel copies and softirq overhead, not from raw fabric speed.

---

## 5. When each fits

| If you have… | Use… |
| --- | --- |
| No RDMA hardware, or apps small enough that kernel-copy cost is dwarfed by app work | plain TCP |
| A fleet of RoCE-capable Linux hosts, existing TCP services, and ability to load a kernel module | SMC-R (sysctl-enabled, transparent for AF_INET, no app rebuild) |
| UB (or IB) hardware, an app you can `LD_PRELOAD`, and need bRPC-grade RPC perf in a userspace deploy | ubsocket |
| Same-host accelerated comms in a Linux VM, no RNIC | SMC-D over ISM (similar to SMC-R but for intra-host); ubsocket can also run over `UMQ_TRANS_MODE_IPC` for the same niche |

The two RDMA-side options aren't competitors so much as **"same idea, different fabric, different scoping"** — SMC-R on RoCE in the kernel; ubsocket on UB in userspace. Either makes sense, neither obsoletes the other.

---

## 6. Cross-reference map

| Concept | TCP | SMC-R | ubsocket / UMQ / URMA |
| --- | --- | --- | --- |
| Connection endpoint | `struct sock` | `struct smc_sock` | `BrpcFileDescriptor` + `ub_queue_t` |
| Shared resource for many connections | none | Link Group + RMBs | Main UMQ + shared JFR |
| Send queue | TCP write queue | RDMA SQ in QP | URMA jetty's SQ side (`urma_post_jetty_send_wr`) |
| Recv queue | TCP receive queue | RMB ring | URMA JFR or jetty RQ (`urma_post_jfr_wr` / `urma_post_jetty_recv_wr`) |
| Completion notification | softirq | RDMA CQ event | JFCE eventfd → `urma_wait_jfc` |
| Flow control | sliding window | LLC credit message | FC jetty + window in shared memory |
| Bootstrap | TCP 3-way handshake | TCP 3-way handshake + CLC piggyback | TCP connect + `queue_bind_info` exchange |
| Wire | TCP/IP | RoCE | URMA over UB (or IB) |
| Fallback | n/a | plain TCP if CLC fails | plain TCP if `umq_init`/`umq_bind` fails (per-fd) |

---

## 7. Caveats

- The SMC-R column reflects the widely-published design of `net/smc/` in mainline Linux and IBM's SMC documentation. Specific implementation details (exact LLC message types, current RMB ring format, sysctl knobs) may have evolved between kernel versions. The ubsocket column is verified against `atomgit:ray-yang0218/ubs-comm_9477@d6a6a4d` traced 2026-05-22 — see [`umdk_ubsocket_umq_urma_stack.md`](umdk_ubsocket_umq_urma_stack.md) for file:line citations.
- "Zero-copy" claims for both SMC-R and ubsocket depend on the app cooperating: SMC-R needs the app to use sendmsg with MSG_ZEROCOPY-equivalent semantics or it copies into the RMB ring; ubsocket needs the app to use a bRPC IOBuf (or otherwise allocate from the IO pool) or it copies into a qbuf. Neither is universally zero-copy for arbitrary `write(2)` patterns.
- Performance numbers (the +40% etc.) are claims by the respective projects on specific workloads. They're directionally consistent across both RDMA-side options because the wins come from the same source (kernel-copy removal + softirq removal), but neither number is a substitute for benchmarking your own workload.
