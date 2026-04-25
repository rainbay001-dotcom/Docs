# URMA/UDMA Working Flows

Last updated: 2026-04-25

## Purpose

This note traces how URMA and UDMA work from application calls down to the kernel and hardware-facing driver. It combines:

- Local UnifiedBus OS reference flow descriptions.
- Local UMDK docs and sample code.
- Local UMDK source.
- Local UB kernel source.

## Core Runtime Objects

| Object | User-space type | Kernel/common role | UDMA/provider role |
| --- | --- | --- | --- |
| Device | `urma_device_t` | sysfs/cdev-backed UB device | Matched to provider ops |
| Context | `urma_context_t` | per-process device context, EID, async fd | UAR/DB mappings, reserved SQ, provider tables |
| Segment | `urma_target_seg_t`, `urma_seg_t` | local/remote memory registration/import | Memory table/IOMMU/UMMU programming |
| JFC | `urma_jfc_t` | completion queue object | CQE buffer, DB, CQ polling |
| JFCE | `urma_jfce_t` | completion event object/fd | event wait/ack support |
| JFS | `urma_jfs_t` | send queue object | SQ/WQE buffer and send doorbell |
| JFR | `urma_jfr_t` | receive queue object | RQ/SRQ buffer and receive doorbell |
| Jetty | `urma_jetty_t` | combined communication endpoint | QP-like send/receive object |
| Target Segment | `urma_target_seg_t` | imported remote memory descriptor | remote token/address information |
| Target Jetty | `urma_target_jetty_t` | imported remote endpoint | remote Jetty binding/TP setup |
| Completion Record | `urma_cr_t` | operation completion status | parsed from hardware CQE |

## Flow 1: Library Initialization and Device Discovery

Goal: discover URMA devices and bind each to a provider.

High-level flow:

```text
application
  -> urma_init()
  -> load provider shared objects
  -> provider constructors call urma_register_provider_ops()
  -> scan /sys/class/ubcore, fallback /sys/class/uburma
  -> read device attributes
  -> match sysfs device to registered provider
  -> build urma_device_t with /dev/uburma/<dev> path
```

Important local code:

- Provider loading uses `dlopen` in `src/urma/lib/urma/core/urma_main.c`.
- Provider ops are registered through `urma_register_provider_ops()`.
- Sysfs scanning happens through `urma_scan_sysfs_devices()`.
- Sysfs path constants are `/sys/class/ubcore`, `/sys/class/uburma`, and `/dev/uburma`.
- Device attributes include feature bits, maximum JFC/JFS/JFR/Jetty counts, depth limits, SGE limits, maximum read/write/atomic sizes, transport mode, congestion-control algorithm, CEQ count, EID count, and port attributes.

Why it matters:

- The application does not manually choose the UDMA provider by calling UDMA APIs.
- Provider matching happens through device attributes and provider registration.
- All later object creation depends on a valid `urma_device_t`.

## Flow 2: Context Creation

Goal: bind a process to a URMA device/EID and establish user/kernel/provider context.

Application side:

```text
urma_get_device_by_name()
urma_query_device()
urma_get_eid_list()
urma_create_context()
```

Sample code path:

```text
src/urma/examples/urma_sample.c
  init_context()
    urma_get_device_by_name()
    urma_query_device()
    get_eid_index()
    urma_create_context()
```

liburma flow:

```text
urma_create_context()
  -> open /dev/uburma/<dev>
  -> dev->ops->create_context()
```

UDMA provider flow:

```text
udma_u_create_context()
  -> allocate struct udma_u_context
  -> initialize mutexes and local lists
  -> prepare udma_create_ctx_resp as provider-private output
  -> urma_cmd_create_context()
  -> initialize provider context from kernel response
  -> allocate/mmap JFC doorbell page
  -> optionally mmap reserved SQ
  -> initialize user-space JFR/Jetty lookup tables
```

Command boundary:

```text
urma_cmd_create_context()
  -> ioctl(dev_fd, URMA_CMD, URMA_CMD_CREATE_CTX)
  -> uburma_cmd_create_ctx()
  -> ubcore_alloc_ucontext()
  -> hns3_udma_alloc_ucontext() or newer udma_alloc_ucontext()
```

Kernel HNS3 context flow:

```text
hns3_udma_alloc_ucontext()
  -> validate provider private data
  -> lookup EID
  -> allocate UAR
  -> register DCA if requested/supported
  -> copy hns3_udma_create_ctx_resp to user
  -> initialize CQ bank and context lists
```

Outputs to user space can include:

- CQE size
- direct WQE capability
- DCA mode and mmap size
- doorbell base address
- chip/die/function IDs
- JFR/JFS limits
- reserved SQ metadata in the newer generic UDMA path

## Flow 3: Completion Resources

Goal: create completion storage and optional completion-event notification.

Application/sample:

```text
ctx->jfce = urma_create_jfce(ctx->urma_ctx)
ctx->jfc = urma_create_jfc(ctx->urma_ctx, &jfc_cfg)
if event_mode:
    urma_rearm_jfc(ctx->jfc, false)
```

liburma:

```text
urma_create_jfc()
  -> validate config against device caps
  -> ctx->ops->create_jfc()
```

UDMA provider:

```text
udma_u_create_jfc()
  -> validate depth
  -> allocate CQE buffer
  -> allocate software DB
  -> prepare provider-private create_jfc command with buffer and DB addresses
  -> urma_cmd_create_jfc()
  -> initialize CI/arm state and returned IDs/capabilities
```

Kernel command path:

```text
uburma_cmd_create_jfc()
  -> allocate user object
  -> ubcore_create_jfc()
  -> provider callback hns3_udma_create_jfc()
  -> copy command response to user space
```

Completion models:

- Polling mode: application repeatedly calls `urma_poll_jfc()`.
- Event mode: application calls `urma_rearm_jfc()`, waits with `urma_wait_jfc()`, drains completions with `urma_poll_jfc()`, acknowledges with `urma_ack_jfc()`, then rearms.

## Flow 4: JFR, JFS, and Jetty Creation

Goal: create receive/send resources and bind them into a communication endpoint.

Sample setup:

```text
urma_jfr_cfg_t jfr_cfg = {
  depth,
  tag_matching,
  order_type,
  trans_mode,
  min_rnr_timer,
  jfc,
  token_value,
  max_sge
}
ctx->jfr = urma_create_jfr(ctx->urma_ctx, &jfr_cfg)

urma_jfs_cfg_t jfs_cfg = {
  depth,
  order_type,
  multi_path,
  trans_mode,
  priority,
  max_sge,
  max_inline_data,
  rnr_retry,
  err_timeout,
  jfc
}

urma_jetty_cfg_t jetty_cfg = {
  share_jfr = 1,
  jfs_cfg = jfs_cfg,
  shared.jfr = ctx->jfr
}
ctx->jetty = urma_create_jetty(ctx->urma_ctx, &jetty_cfg)
```

liburma responsibilities:

- Validate user configs against device attributes.
- Convert public types to command/kernel types.
- Dispatch to provider ops.

UDMA provider responsibilities:

- Allocate queue structures.
- Allocate WQE/RQE buffers.
- Allocate software doorbells.
- Pass queue buffer addresses to kernel via provider-private command data.
- Store returned queue IDs/QPN/flags.
- Track JFR/Jetty lookup tables for completion parsing.

Kernel responsibilities:

- Allocate object IDs.
- Program queue contexts.
- Register objects in ubcore and driver tables.
- Create or modify transport resources as needed.

## Flow 5: Segment Registration and Import

Goal: make local memory usable by UB hardware, and import remote memory descriptors for one-sided operations.

Local registration:

```text
allocate VA
set urma_reg_seg_flag_t
set token_value
urma_register_seg(ctx, &seg_cfg)
```

Sample:

```text
ctx->va = memalign(PAGE_SIZE, MEM_SIZE)
seg_cfg.va = ctx->va
seg_cfg.len = MEM_SIZE
seg_cfg.token_value = ctx->token
seg_cfg.flag.access = READ | WRITE | ATOMIC
ctx->local_tseg = urma_register_seg(ctx->urma_ctx, &seg_cfg)
```

Remote import:

```text
exchange remote segment descriptor out of band
urma_import_seg(ctx, &remote_seg, &token, 0, import_flag)
```

What gets exchanged:

- EID
- UASID
- segment VA/UBA
- segment length
- segment flags/permissions
- token ID
- token value through secure/application-controlled channel

Code path:

```text
urma_register_seg()
  -> provider register_seg()
  -> urma_cmd_register_seg()
  -> uburma_cmd_register_seg()
  -> ubcore_register_seg()
  -> hns3_udma_register_seg()

urma_import_seg()
  -> provider import_seg()
  -> urma_cmd_import_seg()
  -> uburma_cmd_import_seg()
  -> ubcore_import_seg()
  -> hns3_udma_import_seg()
```

Security model:

- A registered segment grants hardware-visible access only according to the configured permissions.
- One-sided remote access requires imported target-segment metadata and matching token credentials.
- The base spec ties this to TokenID/TokenValue checks and UMMU permission enforcement.

## Flow 6: Out-of-Band Metadata Exchange

URMA data movement requires the peer to know remote memory and Jetty metadata. The sample uses TCP sockets as an out-of-band channel:

```text
seg_jetty_info_t:
  eid
  uasid
  seg_va
  seg_len
  seg_flag
  seg_token_id
  jetty_id
```

Server:

```text
listen on TCP
pack local segment/Jetty info
accept client
exchange seg_jetty_info_t
import client's Jetty
```

Client:

```text
connect to server TCP endpoint
exchange seg_jetty_info_t
import server segment
import server Jetty
optionally bind Jetty for RC/RS modes
```

This is consistent with the docs: tokens and descriptors are management-plane information and must be exchanged outside the data plane, usually through an application-secure channel.

## Flow 7: Importing and Binding Remote Jetty

Goal: create a local handle for a remote endpoint.

Sample:

```text
urma_rjetty_t remote_jetty = {
  jetty_id = remote_jetty_id,
  trans_mode,
  type = URMA_JETTY,
  tp_type,
  order_type,
  share_tp
}
t_jetty = urma_import_jetty(ctx, &remote_jetty, &token)
if RC/RS:
  urma_bind_jetty(local_jetty, t_jetty)
```

Code path:

```text
urma_import_jetty()
  -> provider import_jetty/import_jetty_ex
  -> urma_cmd_import_jetty()
  -> uburma_cmd_import_jetty()
  -> ubcore import path
  -> provider kernel callback
```

Binding matters for connected modes where the local Jetty must establish or attach a transport path to the remote target.

## Flow 8: One-Sided Write/Read

Goal: move data using remote memory semantics without involving the remote application after setup.

Sample write:

```text
src_sge.addr = local VA
src_sge.tseg = local registered segment
dst_sge.addr = remote segment UBVA/VA
dst_sge.tseg = imported target segment
wr.opcode = URMA_OPC_WRITE
wr.tjetty = imported target Jetty
urma_post_jetty_send_wr(local_jetty, &wr, &bad_wr)
poll_jfc_wait()
```

Sample read:

```text
swap source/destination segment descriptors
wr.opcode = URMA_OPC_READ
urma_post_jetty_send_wr()
poll_jfc_wait()
```

Data-path code path:

```text
urma_post_jetty_send_wr()
  -> ctx->ops->post_jetty_send_wr()
  -> udma_u_post_jetty_send_wr()
  -> prepare WQE/SQE in user memory
  -> ring doorbell/MMIO
  -> hardware executes
  -> hardware writes CQE
  -> urma_poll_jfc()
  -> udma_u_poll_jfc()
  -> parse CQE into urma_cr_t
```

Kernel involvement:

- The kernel is involved in setup: context, Jetty, segment, target import, TP setup.
- The steady-state data submission and completion polling are user-space/provider operations designed for kernel bypass.

## Flow 9: Two-Sided Send/Receive

Goal: exchange messages where receiver explicitly posts receive buffers.

Receiver/server:

```text
for N receives:
  prepare sge over local registered segment
  wr.src = sg
  wr.user_ctx = offset
  urma_post_jetty_recv_wr(local_jetty, &wr, &bad_wr)

loop:
  poll_jfc_wait()
  if completion is receive:
    read message from receive buffer
    repost receive buffer
```

Sender/client:

```text
prepare local send buffer
send_wr.src = local sg
jfs_wr.opcode = URMA_OPC_SEND
jfs_wr.tjetty = imported target Jetty
jfs_wr.complete_enable = 1
urma_post_jetty_send_wr(local_jetty, &jfs_wr, &bad_wr)
poll_jfc_wait()
```

Response path in sample:

- Server receives a send completion with remote identity.
- Server finds the matching imported target Jetty for the client.
- Server posts a response send WR.
- Client had already posted a receive WR and polls both send completion and receive response completion.

## Flow 10: Completion Polling and Event Mode

Polling mode:

```text
while not complete:
  cnt = urma_poll_jfc(jfc, cr_cnt, cr)
  if cnt > 0:
    inspect cr.status, cr.opcode, cr.user_ctx
```

Event mode:

```text
urma_rearm_jfc(jfc, false)
submit work
cnt = urma_wait_jfc(jfce, 1, timeout, &ev_jfc)
urma_poll_jfc(jfc, 1, &cr)
urma_ack_jfc(&ev_jfc, &ack_cnt, 1)
urma_rearm_jfc(jfc, false)
```

Important semantics:

- Submission success does not mean operation completion.
- Buffer reuse is safe only after successful completion.
- If JFC contains unread completions, rearm can fail.
- Completion `user_ctx` is the usual way to correlate a CQE/CR with the originating WR.
- Receive completions carry the buffer context and valid completion length.
- Immediate data appears in completion records when enabled.

## Flow 11: Atomic Operations

The OS reference design describes atomic CAS and FAA operations. The API guide mentions broader atomic operation categories and the current device attributes expose capability fields for:

- CAS
- swap
- fetch-and-add
- fetch-and-sub
- fetch-and-and
- fetch-and-or
- fetch-and-xor

Atomic operation shape:

```text
register local segment
import remote segment
prepare atomic WR with local/remote addresses and operand
post through JFS/Jetty send path
poll JFC for completion
```

The same token/segment access rules as one-sided read/write apply.

## Flow 12: Transport Path and Multipath

Transport mode options from the sample:

- `0`: RM
- `1`: RC
- `2`: UM
- `3`: RS, mapped to RC with order/share settings in the sample

TP type options:

- `0`: `URMA_RTP`
- `1`: `URMA_CTP`
- `2`: `URMA_UTP`

The sample enforces:

- Bonding devices support specific combinations, such as RM plus multipath or RC.
- Non-bonding devices reject multipath and require consistent transport mode/TP type choices.

Relevant components:

- `lib/urma/bond`: user-space bonding provider and scheduling logic.
- `ubagg`: kernel-side aggregation/multipath support.
- `udma_u_ctrlq_tp.c`: user UDMA control queue TP operations.
- `hns3_udma_tp.c`: kernel HNS3 TP modification.
- `ubcore_tp.c`, `ubcore_tpg.c`, `ubcore_utp.c`, `ubcore_ctp.c`, `ubcore_vtp.c`: kernel transport abstractions in `kernel-ub`.

## Flow 13: Admin, Debug, and Observability

URMA exposes device/resource attributes via sysfs:

```text
/sys/class/ubcore/<dev>/
```

Fallback legacy path:

```text
/sys/class/uburma/<dev>/
```

Character device path:

```text
/dev/uburma/<dev>
```

Tools:

- `urma_admin show`: query device/resource attributes and statuses.
- `urma_perftest`: bandwidth/latency tests for send/recv, read/write, atomics.
- `urma_ping`: connectivity diagnostics.

Kernel-side debug/maintenance:

- `hns3_udma_debugfs.c`
- `hns3_udma_dfx.c`
- `hns3_udma_sysfs.c`
- `hns3_udma_user_ctl.c`
- ubcore log level module parameter.

Provider user-control path:

```text
urma user_ctl API
  -> udma_u_user_ctl()
  -> URMA_CMD_USER_CTL
  -> uburma_cmd_user_ctl()
  -> hns3_udma_user_ctl()
```

HNS3 user-control operations include:

- Flush CQE.
- Configure/query POE channel.
- DCA register/deregister/shrink/attach/detach/query.
- Kernel-side query hardware ID/configuration operations.

## Flow 14: Runtime Load and Smoke Test

The QuickStart load flow:

```text
insmod ub/ubfi/ubfi.ko.xz cluster=1
insmod iommu/ummu-core/ummu-core.ko.xz
insmod ub/hisi-ub/kernelspace/ummu/drivers/ummu.ko.xz
insmod ub/hisi-ub/kernelspace/ubus/ubus.ko.xz ...
insmod ub/hisi-ub/kernelspace/ubus/vendor/hisi/hisi_ubus.ko.xz ...
insmod ub/hisi-ub/kernelspace/ubase/ubase.ko.xz
insmod ub/hisi-ub/kernelspace/unic/unic.ko.xz ...
insmod ub/hisi-ub/kernelspace/cdma/cdma.ko.xz
modprobe ubcore uburma
modprobe udma dfx_switch=1 jfc_arm_mode=2 is_active=0 fast_destroy_tp=0
modprobe ubagg
```

Smoke test:

```text
systemctl start scbus-daemon.service
urma_admin show
server: urma_perftest send_bw -d bonding_dev_0 -s 2 -n 10 -I 128 -p 1
client: urma_perftest send_bw -d bonding_dev_0 -s 2 -n 10 -I 128 -p 1 -S <server_ip>
```

## End-to-End Mental Model

URMA/UDMA has a split-brain design by intent:

```text
Setup/control path:
  application
    -> liburma
    -> u-udma provider
    -> ioctl
    -> uburma
    -> ubcore
    -> k-udma/HNS3 UDMA
    -> UMMU/UBASE/hardware

Steady-state data path:
  application
    -> liburma dataplane wrapper
    -> u-udma provider
    -> write WQE/CQE-visible memory
    -> ring user-mapped doorbell
    -> hardware DMA/transport
    -> hardware writes CQE
    -> user polls/parses CQE
```

This explains why the codebase is split the way it is:

- liburma owns API stability and generic validation.
- provider code owns hardware-specific fast-path details.
- uburma owns safe user/kernel object mapping.
- ubcore owns shared semantic resource management.
- k-udma owns hardware programming and privileged operations.

## Next Workflow Traces To Expand

- Exact `urma_cmd_tlv.c` TLV field mapping for create/import/bind commands.
- Full `udma_u_post_jfs_wr()` WQE encoding.
- Full `udma_u_poll_jfc()` CQE decoding and error mapping.
- `hns3_udma_create_tp()` and TP state transitions.
- DCA lifecycle from environment/config to user-control operations.
- Bonding/multipath scheduling in `lib/urma/bond`.
