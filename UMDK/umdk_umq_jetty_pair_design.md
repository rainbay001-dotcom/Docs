# UMQ jetty-pair design: IO + FC, layered flow control, ordering tolerance

_Last updated: 2026-05-06._

URPC's UMQ (Userspace Message Queue) lives one layer above core URMA — it's the message-passing layer URPC uses to ferry RPC traffic over UB. Each UMQ instance allocates **two paired jettys** to its peer: one for data (**IO jetty**) and one for out-of-band signaling (**FC jetty**). This design encodes a specific stack of decisions about layered flow control and reorder tolerance. Captures all of those.

Source: `git@atomgit.com:ray-yang0218/umdk.git`, paths under `src/urpc/umq/umq_ub/core/` and `src/urpc/include/umq/`.

Companions (URMA layer beneath UMQ):
- [`umdk_urma_object_model.md`](umdk_urma_object_model.md) — URMA primer (EID, FE/VFE, jetty, TP)
- [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) — exact RM vs RC differences

---

## 1. The two jettys

From `src/urpc/include/umq/umq_dfx_types.h:153-156`:
```c
uint32_t local_io_jetty_id;   /* I/O jetty ID within the UMQ */
uint32_t local_fc_jetty_id;   /* flow-control jetty ID within the UMQ */
uint32_t remote_io_jetty_id;  /* peer's IO jetty bound to ours */
uint32_t remote_fc_jetty_id;  /* peer's FC jetty bound to ours */
```

Indexed by enum `UB_QUEUE_JETTY_IO`, `UB_QUEUE_JETTY_FLOW_CONTROL`. Both are `urma_jetty_t` underneath; UMQ uses them for different protocol roles.

| | IO Jetty | FC Jetty |
| --- | --- | --- |
| Created | always | only if `queue->flow_control.enabled` |
| Carries | RPC payloads, application messages | credit-return, heartbeat, idle-check |
| JFC depth | `queue->tx_depth + 1` (line 962, "+1 for flush done") | `UMQ_UB_FLOW_CONTORL_JETTY_DEPTH` (constant, line 832) |
| Sized for | application throughput | small, infrequent control traffic |
| `share_jfr` | allowed | **forbidden** — explicit at line 866: `// NOTICE: fc jetty don't use share jfr` |
| RX pre-fill | drained as messages consumed | up-front: `UMQ_UB_FLOW_CONTORL_JETTY_DEPTH × rqe_post_factor` posts at create time (line 869-873) |
| Drives idle checker | no | yes (`umq_ub_idle_checker_init`, line 884-887) |

Both share the same `urma_ctx`, the same `jfs_jfce` in interrupt mode, and the same peer (each side's IO and FC jettys bind pairwise: local IO ↔ remote IO, local FC ↔ remote FC).

## 2. Why FC jetty exists despite HW flow control

The hardware *does* implement flow control — RTP's per-peer credit handshake prevents wire-level drop. The `urma_tp_cc_alg` family (DCQCN, LDCP, HC3, ACC) provides fabric-level congestion control. So the obvious question: with both already in HW, why does UMQ need a separate FC channel?

The answer is that "flow control" is overloaded — there are three distinct concerns at three layers:

| Concern | Layer | Lives in |
| --- | --- | --- |
| **Congestion control** ("too many senders flooding the fabric") | Network / fabric | `urma_tp_cc_alg` (DCQCN, LDCP, HC3, …) — HW |
| **Wire-level flow control** ("don't drop packets at receiver's RX buffer") | Transport / per-TP | RTP's per-peer credit handshake — HW |
| **Application-buffer flow control** ("sender posting messages faster than the consumer thread can process them") | Application | UMQ's FC jetty |

HW handles the first two; the FC jetty handles the third. None of them subsume the others.

### What HW credits actually guarantee

Wire-level credit handshakes say: "Receiver has at least one Receive Work Request posted; your next SEND will land in a buffer rather than triggering an RNR-NACK and retransmit." That's all.

✅ Bytes won't be dropped on arrival.
✅ Byte stream survives transient queue-full.

❌ **Doesn't** guarantee the receiver app's higher-layer message buffer is ready for *another* logical message.
❌ **Doesn't** know whether the consumer thread is alive at any particular rate.
❌ **Doesn't** detect a receiver sitting on 8000 already-arrived messages waiting to be processed.

HW credits answer "will the bytes land?" — a transport-layer question. App credits answer "is my consumer keeping up?" — an application-layer question.

### Why HW credits aren't enough for UMQ specifically

1. **UMQ uses RM, not RC.** RM's HW E2E flow control is weaker (multi-target, not pairwise). For fan-in (many senders → one consumer), HW per-pair credits don't compose into a useful answer to "is the consumer overloaded?"

2. **RNR-NACK is too late.** Without app-level back-pressure, the only feedback loop is: sender posts → HW arrives → receiver has no RWR → RNR-NACK → exponential back-off retry. RNR retries cost wire round-trips, block subsequent WRs, and cascade into transport timeouts. App credits prevent the post in the first place.

3. **RWR pre-posting is bounded by HW resources.** JFR depth caps at thousands. App credits live in software counters; can be millions, can be per-class, per-priority.

4. **HW credits don't survive teardown / migrate.** Bonding failover, link flap, reconnect — every wire-level event invalidates HW per-pair state. App credits persist.

5. **Per-class differentiation.** A real RPC system has multiple message classes — small requests, bulk responses, heartbeats. Each class wants different back-pressure thresholds. HW credits are per-QP/TP, undifferentiated.

6. **Liveness detection.** HW transport state shows the link is up, not whether the peer's consumer thread is responsive. UMQ's idle-check on the FC jetty catches the "everything below the app is fine but the app is hung" case.

7. **Sub-UMQ accounting.** UMQ supports multiple logical sub-queues sharing infrastructure. App credits can be per-sub-UMQ; HW credits can't.

### The head-of-line argument (the load-bearing one)

If you sent both IO and FC traffic on a single jetty:
- Receiver's RX queue gets backed up with data → can't post receive buffers fast enough.
- Credit-return messages from the receiver are stuck behind data on its TX queue.
- Sender stops sending → can't get credits back → deadlock.

Splitting onto two jettys with separate JFR buffers + JFCs means credit-return messages have their own progress path, independent of how backed up the data plane is. This is the classic out-of-band signaling pattern.

### CC algorithms don't help here

DCQCN, LDCP, etc. respond to **fabric** signals — ECN marks, switch buffer fill — and slow the sender's wire byte rate. They do nothing about the receiver application's processing rate. A fabric with zero congestion plus a slow consumer is still a problem; CC algorithms see no congestion and tell the sender to keep going.

## 3. Does RC mode need an FC jetty?

If UMQ ran in RC instead of RM, the trade-off shifts because RC's HW guarantees are stronger. But the application-level concerns don't disappear — they're mode-independent.

### What RC gives you for free

| | RM | RC |
| --- | --- | --- |
| Per-pair wire-level credits | weaker (multi-target) | strong (1:1 pair, well-defined) |
| Fan-in problem | real | nonexistent (1:1 binding) |
| Credit-state survives across all WRs | no | yes (QP state machine) |
| RNR-NACK retry semantics | basic | per-pair with retry budget |

So the wire-level "next packet won't be dropped" problem is genuinely tighter in RC.

### What FC jetty would still provide in RC mode

1. **App-level processing-rate back-pressure.** RC's HW credits say "you have a free RWR" — RX-buffer count, not consumer-rate gauge. A receiver with a fast NIC and slow processing thread will keep accepting data into RWRs and falling behind in software.

2. **Head-of-line blocking on the IO queue.** If your IO jetty's TX queue is fully posted (waiting on RWRs to free up at the receiver), you can't post a credit-return on the same queue. The TX path is full. RC's per-pair credits don't help — you've used them up. Without a separate channel, credit-return for the IO jetty would be stuck behind the very data it's trying to throttle.

3. **Liveness / heartbeat.** HW transport state shows the link is up, not whether the peer's consumer thread is responsive.

4. **Sub-UMQ accounting and per-class priority.** RC gives you one credit pool per QP. App credits can be partitioned per sub-UMQ, per priority class, per logical message type.

Of these, **#2 (head-of-line blocking) is the load-bearing argument**. The other three are application-policy concerns; #2 is fundamental.

### When you could plausibly skip FC jetty in RC

Single sender + single receiver, bulk transfer (not RPC), consumer rate reliably ≥ producer rate, tolerance for occasional RNR-NACK retries, no need for app-level liveness. Some classic IB apps (e.g., RDMA-attached block I/O) work this way.

### When you'd want FC jetty even in RC

RPC-style with bursty workloads, GC/scheduling pauses on consumer, multiple message priority classes, fast detection of peer hangs, want clean back-pressure without RNR-NACK retry storms. Most production RPC systems fall here — it's why MPI implementations, UCX, NCCL all layer credit protocols on top of IB RC even though RC has wire-level FC.

### Mode summary

| Transport mode | HW flow control quality | FC jetty needed? |
| --- | --- | --- |
| **UM** (Unreliable Message) | none — UD-style fire-and-forget | yes (and you also need app-level retry) |
| **RM** (Reliable Message) | weak pairwise; multi-target | **yes** — what UMQ does today |
| **RC** (Reliable Connection) | strong pairwise (HW E2E credits) | **probably yes for production**; technically optional for simple bulk workloads |

RC doesn't *require* the FC jetty pattern the way RM does, but the application-level reasons (head-of-line, app processing rate, liveness, priority) are mode-independent. FC jetty remains the right design for any RPC-style or back-pressure-sensitive workload regardless of underlying TP type.

## 4. How UMQ handles target-side reorder under OI

UMQ runs in RM mode with `URMA_DEF_ORDER`, which the driver maps to **OI (initiator ordering)** for RM. That means:
- Sender CQ in submission order ✓
- Target may observe message effects out-of-order ✓

So how does UMQ deal with reorder at the receiver? **It tolerates reorder rather than buffering and reordering.** Two design choices make this work without any reorder buffer in software.

### Configuration site

In `umq_ub.c:1351`:
```c
queue->order_type = URMA_DEF_ORDER;
```

`URMA_DEF_ORDER` lets the driver pick the strongest legal mode for `trans_mode`:

| trans_mode | Driver picks |
| --- | --- |
| RC | OT (target ordering) |
| RM | OI (initiator ordering) |
| UM | NO (none) |

The order_type is also exposed as a per-UMQ option (`info->queue_info->order_type` at `umq_ub.c:485`), so applications can override. By default it stays at DEF_ORDER → OI for RM.

### Five mechanisms by which reorder doesn't matter

**1. Each message is self-contained at the wire level.** A UMQ message is one or a few WRs. Wire-level reliability says: bytes within a single SEND arrive atomically — full payload or none. Reorder happens at message-boundary granularity, not byte granularity. Each message carries its own header and correlation metadata; receiver doesn't have to wait for "the next missing chunk."

**2. Credits are cumulative / commutative.** The receiver's per-jetty `rx_consumed_jetty_table[jetty_id]` (allocated at `umq_ub_impl.c:651`) is an atomic monotone counter. Credit-update messages on the FC jetty carry a count; sender's update rule is "advance to the latest absolute value," not "add a delta." If credit-updates arrive out of order — say sender sees `consumed=200` then later `consumed=180` — sender ignores the stale one. Cumulative monotone counters are reorder-safe by construction. No sequence numbers needed.

**3. Heartbeats are stateless.** Each idle-check/probe stands alone. Order between consecutive probes doesn't matter.

**4. Application-level correlation handles RPC ordering.** For RPC use cases, URPC uses correlation IDs in message headers — not wire order. A receiver gets back four out-of-order responses, looks at each `correlation_id`, and matches each to its waiting caller. UMQ's job is "messages arrive intact, each independent." URPC's job is "match this response to that request."

**5. Sub-UMQs are independent.** The `umq_ctx_jetty_table[jetty_id]` mapping (`umq_ub_impl.c:986`) routes incoming messages to their corresponding sub-UMQ based on the destination jetty ID stamped in the WR. Different sub-UMQs receive messages independently; cross-sub-UMQ reorder doesn't matter because they're logically separate queues.

### What would break if UMQ assumed target ordering

- **Multipath under bonding** — RM-mode TPs can spread across paths intentionally; ordering across paths is best-effort at HW level. App credits still work; manual sequencing would not.
- **Credit-update interleaving** — without the cumulative-counter design, sender might decrement-by-credit and end up with negative budgets after a reorder.
- **Multi-jetty fan-in** — when several senders write to one consumer's IO jetty, each sender's stream is internally OI-ordered but the interleave between senders is undefined. UMQ's per-sub-UMQ accounting handles this; an ordering-dependent design would not.

### What if the application needs strict target ordering

Two paths:
1. **Switch to RC mode** at queue creation. UMQ exposes `option->trans_mode`; setting it to `URMA_TM_RC` will get OT (target ordering) under DEF_ORDER. Accept the 1:1 binding constraint.
2. **Build an order layer above UMQ.** Sender stamps a per-stream sequence number, receiver reorders before delivering to consumer. Standard pattern when transport is unordered.

The path of least surprise is #1 — pick the trans_mode whose default ordering matches your needs. If the app truly needs streaming-byte semantics, RM is the wrong UMQ mode.

## 5. The whole stack, top-down

```
Application                  RPC requests + responses with correlation IDs
                             (URPC layer matches via correlation_id, not wire order)
        │
        ▼
UMQ                          IO jetty (data) + FC jetty (out-of-band signal)
                             - app-level credit accounting (cumulative monotone)
                             - heartbeats / idle checks on FC
                             - per-sub-UMQ routing
        │
        ▼
URMA (RM, RTP, OI)           Reliable message-mode TP, initiator ordering
                             - HW E2E credits prevent wire-level drop
                             - per-WR destination addressing
                             - one TP serves many jettys
        │
        ▼
Wire / fabric                Congestion control (DCQCN/LDCP/HC3/ACC)
                             - byte-rate management
                             - ECN-driven backoff
```

Every layer addresses a different concern; removing any of them creates a different failure mode:

- Drop **CC**: fabric melts under load, tail latency goes nonlinear.
- Drop **HW E2E credits**: wire-level packet drops + RNR retransmit storms.
- Drop **app credits (FC jetty)**: receiver overruns its processing capacity, RNR-NACK churn, or silent message-buffer overflow.
- Drop **app correlation IDs**: receiver can't match concurrent in-flight responses to requests.

UMQ's IO+FC jetty pair is one specific layer in this stack — the application-buffer flow control layer. The HW does what HW does; UMQ does what HW can't.

## 6. Mental model

- **HW flow control** answers "will bytes land safely?" — bytes/RWR-count ceiling.
- **HW congestion control** answers "is the fabric oversubscribed?" — byte-rate ceiling.
- **App flow control (FC jetty)** answers "is my consumer keeping up?" — message-processing-rate ceiling.

URMA RM's OI ordering trades target-side reorder for multi-target flexibility and fan-in support. UMQ pays for that trade-off with reorder-tolerant design at the application layer (independent messages, monotone counters, correlation IDs). Net result: a clean, layered design where each concern is solved at the right level — and that's why UMQ has two jettys per instance.

## 7. References

- `src/urpc/umq/umq_ub/core/umq_ub_impl.c` — IO + FC jetty creation, `rx_consumed_jetty_table`, RX pre-fill.
- `src/urpc/umq/umq_ub/core/private/umq_ub.c` — `queue->order_type = URMA_DEF_ORDER` (line 1351), order_type plumbed into jetty/JFR cfg.
- `src/urpc/umq/umq_ub/core/private/umq_ub.c` — disconnect / cleanup paths showing IO + FC pairing.
- `src/urpc/include/umq/umq_dfx_types.h:153-156` — `local_io_jetty_id` / `local_fc_jetty_id` definitions.
- `src/urma/lib/urma/core/include/urma_types.h` — `urma_order_type_t`, `urma_transport_mode_t`.
- `src/urma/lib/urma/core/urma_cp_api.c:627-630` — order-type × trans_mode legality matrix.
