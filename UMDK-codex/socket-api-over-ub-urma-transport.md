# Socket API Above a UB/URMA-Backed Transport

Last updated: 2026-04-25

## Short Answer

Yes. The local source contains two concrete ways for an application to keep a
Linux socket-style interface while the lower transport is tied to UB, URMA, and
UDMA:

1. UMS/USOCK: a socket-compatibility path that maps selected TCP stream sockets
   to an `AF_SMC`/UMS socket implementation and then uses ubcore resources for
   data movement.
2. IPoURMA: a kernel netdev-style adapter where the normal Linux TCP/IP stack
   sends packets through an IP-over-URMA device, and IPoURMA posts ubcore/URMA
   work requests underneath.

These paths are different from a native `liburma` application. A native URMA
application uses `liburma` objects such as Context, Segment, Jetty, JFS, JFR,
and JFC directly. UMS and IPoURMA instead preserve the socket API at the top.

## Boundary

This document answers one specific question:

```text
Can a user open a socket with Linux socket APIs while data is moved through
UB/URMA/UDMA underneath?
```

The answer is yes, but there are two different meanings:

| Meaning | Local implementation | Application API | Lower path |
| --- | --- | --- | --- |
| Existing TCP-style app gets redirected to UB socket transport | UMS/USOCK | `socket()`, `connect()`, `sendmsg()`, `recvmsg()` | `AF_SMC`/UMS -> ubcore -> UDMA |
| Existing TCP/IP app uses a netdev backed by URMA | IPoURMA | normal TCP/IP sockets | Linux TCP/IP -> IPoURMA netdev -> ubcore -> UDMA |
| App calls URMA verbs on top of TCP sockets | Not found locally | `urma_*()` APIs | no socket-backed URMA provider found |

The third row is intentionally explicit. I did not find a socket-backed URMA
provider that lets a program call `urma_post_jetty_send_wr()` while the provider
implements the data path by writing to TCP sockets. The source instead contains
socket compatibility above UB/URMA, plus TCP side channels in examples and
perftests for metadata exchange.

## High-Level Stack Shapes

### Native URMA/UDMA

```text
application using liburma
  -> urma_* public API
  -> UDMA user provider
  -> /dev/uburma/<device> ioctl and mmap for setup
  -> uburma and ubcore
  -> kernel UDMA provider
  -> UMMU and UDMA hardware
```

This is the normal memory-semantics path. The application must be written to
the URMA API.

### UMS/USOCK Socket Compatibility

```text
existing socket application
  -> socket(AF_INET/AF_INET6, SOCK_STREAM, TCP)
  -> ums_run / libums-preload rewrites socket() to AF_SMC
  -> UMS kernel socket operations
  -> UMS connection manager and fallback TCP CLC socket
  -> UMS ubcore client
  -> ubcore Jetty/JFR/JFC/Segment resources
  -> UDMA provider and hardware
```

This path is closest to "socket API, but data over UB/URMA/UDMA." It is not the
same as `liburma`; UMS is a kernel socket implementation that uses ubcore
resources internally.

### IPoURMA TCP/IP Compatibility

```text
existing TCP/IP application
  -> Linux socket API
  -> Linux TCP/IP stack
  -> route points traffic at ipourma netdev
  -> IPoURMA ndo_start_xmit
  -> ubcore Jetty send work request
  -> UDMA provider and hardware
```

This path makes UB/URMA look like a network device to the Linux TCP/IP stack.
The application is ordinary socket code; the routing/device selection decides
whether traffic enters IPoURMA.

## UMS/USOCK Path

UMS means "UB Memory based Socket" in the local source comments. It provides
both an explicit `AF_SMC` mode and an `LD_PRELOAD` mode for existing TCP-style
applications.

### User Entry

`ums_run` injects the preload library:

```text
ums_run <application>
  -> LD_PRELOAD=.../libums-preload.so
  -> exec <application>
```

Source anchors:

| Claim | Source |
| --- | --- |
| `ums_run` names `/usr/lib/libums-preload.so`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:14` |
| `ums_run` appends the library to `LD_PRELOAD`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:45` |
| `ums_run` execs the requested command. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums_run:48` |

The preload library overrides `socket()` and rewrites eligible sockets:

```text
socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
  -> socket(AF_SMC, SOCK_STREAM, SMCPROTO_SMC/SMCPROTO_SMC6)
```

Source anchors:

| Claim | Source |
| --- | --- |
| The preload library defines a replacement `socket()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:77` |
| It recognizes IPv4/IPv6 stream sockets with `IPPROTO_IP` or `IPPROTO_TCP`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:85` |
| It changes the domain to `AF_SMC`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:93` |
| It resolves the original libc `socket()` through `dlopen()` and `dlsym()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/tools/ums-preload.c:113` |

### Kernel Socket Registration

The UMS kernel module registers a socket family and TCP ULP:

```text
UMS module load
  -> proto_register(g_ums_proto/g_ums_proto6)
  -> sock_register(AF_SMC)
  -> ums_ubcore_register_client()
  -> tcp_register_ulp("ums")
```

Source anchors:

| Claim | Source |
| --- | --- |
| UMS validates `SOCK_STREAM` and UMS protocols during socket creation. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:799` |
| UMS installs `ums_sock_ops` and allocates the UMS socket. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:804` |
| UMS registers `AF_SMC` as its socket family. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:837` |
| UMS registers protocol objects and the socket family in init. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1040` |
| UMS registers as a ubcore client. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1153` |
| UMS registers TCP ULP `ums`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1159` |
| Module aliases include `AF_SMC` and TCP ULP `ums`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:1216` |

### Connection Setup and Fallback

UMS keeps a TCP socket for CLC handshake and fallback behavior. That is why the
stack still contains TCP even when the intended data path is UB-backed.

```text
UMS socket
  -> internal clcsock = kernel TCP socket
  -> kernel_connect(clcsock, peer)
  -> UMS handshake
  -> use UB path if capability negotiation succeeds
  -> use fallback when UMS/UB path is not usable
```

Source anchors:

| Claim | Source |
| --- | --- |
| UMS creates an internal TCP socket for CLC handshake and fallback. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:810` |
| The internal CLC socket is created with `SOCK_STREAM` and `IPPROTO_TCP`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/ums_mod.c:820` |
| `ums_connect()` only accepts IPv4/IPv6 sockaddr families. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/sockops/ums_connect.c:573` |
| UMS connects the internal CLC TCP socket with `kernel_connect()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/sockops/ums_connect.c:604` |
| If fallback is selected, the socket state follows the fallback connection. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/sockops/ums_connect.c:608` |

### UB/URMA Resource Use

UMS is not just a socket wrapper. It creates and uses ubcore resources:

```text
UMS link
  -> determine local EID from socket/net namespace where possible
  -> create JFC
  -> create JFR
  -> create local Jetty
  -> import and bind remote Jetty
  -> register TX/RX Segments
  -> post Jetty send/recv work requests
  -> poll JFC completions
```

Source anchors:

| Claim | Source |
| --- | --- |
| UMS tries to determine EID from socket address and ubcore EID table. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:110` |
| UMS imports a remote Jetty through ubcore. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:445` |
| UMS binds local and remote Jetty objects through ubcore. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:457` |
| UMS creates a JFR and attaches it to a JFC. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:618` |
| UMS creates a local Jetty with JFS/JFR/JFC settings. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:691` |
| UMS creates JFC objects and rearms them. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:776` |
| UMS registers as a ubcore client. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_ubcore.c:924` |
| UMS posts Jetty send work requests. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_wr.c:236` |
| UMS posts Jetty receive work requests. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_wr.c:342` |
| UMS polls and rearms JFC completions. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_wr.c:497` |
| UMS registers TX/RX segments. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/dev/ums_wr.c:788` |

The `io/ums_tx.c` path also shows data movement through ubcore Jetty sends:

| Claim | Source |
| --- | --- |
| UMS TX uses the peer target segment and target Jetty. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/io/ums_tx.c:436` |
| UMS TX posts `ubcore_post_jetty_send_wr()`. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/io/ums_tx.c:463` |
| UMS TX with immediate data also posts a Jetty send WR. | `/Users/ray/Documents/Repo/ub-stack/umdk/src/usock/ums/kmod/ums/io/ums_tx.c:505` |

### UMS User-Visible Modes

UMS has two practical user modes:

```text
Mode A: native UMS-aware socket app
  socket(AF_SMC, SOCK_STREAM, UMSPROTO_UMS/UMS6)

Mode B: existing TCP socket app
  ums_run <app>
    -> LD_PRELOAD=...libums-preload.so
    -> app calls socket(AF_INET/AF_INET6, SOCK_STREAM, TCP)
    -> preload rewrites to AF_SMC
```

Mode B is the compatibility mode most relevant to existing socket
applications. It can avoid application source changes, but it still depends on
the UMS kernel module, ubcore devices, and viable UB/URMA/UDMA resources.

## IPoURMA Path

IPoURMA is a kernel-level adapter between Linux TCP/IP and UB/URMA. The local
kernel documentation says it sits between the TCP/IP stack and UB, exposes an
Ethernet-like interface, and lets applications use socket APIs over UB without
modification.

### Kernel Device Shape

```text
ubcore_device with IPoURMA feature
  -> IPoURMA ubcore client add_device callback
  -> allocate ipourma net_device
  -> register_netdev(ipourmaN)
  -> Linux TCP/IP can route packets to ipourmaN
```

Source anchors:

| Claim | Source |
| --- | --- |
| IPoURMA is documented as sitting between TCP/IP and UB. | `/Users/ray/Documents/Repo/kernel/Documentation/ub/urma/ipourma/ipourma.rst:10` |
| The documentation says socket applications can communicate over UB through IPoURMA. | `/Users/ray/Documents/Repo/kernel/Documentation/ub/urma/ipourma/ipourma.rst:12` |
| The documentation diagram places APP, Socket API, TCP/IP, IPoURMA, UBCORE, and UDMA in sequence. | `/Users/ray/Documents/Repo/kernel/Documentation/ub/urma/ipourma/ipourma.rst:18` |
| IPoURMA only adds devices for ubcore devices with `ipourma_en`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_main.c:68` |
| IPoURMA restricts this to UDMA-named ubcore devices. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_main.c:72` |
| IPoURMA allocates a netdev and sets ubcore client context data. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_main.c:75` |
| IPoURMA registers the netdev. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_main.c:269` |
| IPoURMA sets Ethernet-like RTNL device attributes. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netlink.c:62` |
| IPoURMA does not support manual `ip link add ... type ipourma`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netlink.c:80` |

### Data Path

Once Linux routes traffic to the IPoURMA netdev, the normal netdev transmit
callback handles skbs and converts the packet path into ubcore/URMA sends:

```text
TCP socket write
  -> Linux TCP/IP creates skb
  -> route selects ipourma netdev
  -> ipourma_start_xmit(skb)
  -> resolve source/destination EID
  -> enqueue or post send
  -> ubcore_post_jetty_send_wr()
```

Source anchors:

| Claim | Source |
| --- | --- |
| `ipourma_start_xmit()` is the netdev TX entry. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netdev.c:395` |
| IPoURMA currently checks for IPv6 packets on TX. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netdev.c:411` |
| IPoURMA resolves EIDs before transmit. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netdev.c:422` |
| IPoURMA calls `ipourma_xmit()` from `ndo_start_xmit`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netdev.c:424` |
| IPoURMA wires `ndo_start_xmit` to `ipourma_start_xmit`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_netdev.c:498` |
| `ipourma_xmit()` adds the IPoURMA header, finds EID index, queues the skb, and schedules/post sends. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c:519` |
| `ipourma_post_send()` posts a Jetty send WR through ubcore. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c:394` |
| The actual post call is `ubcore_post_jetty_send_wr()`. | `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/ulp/ipourma/ipourma_ub.c:409` |

## UMS vs IPoURMA

| Topic | UMS/USOCK | IPoURMA |
| --- | --- | --- |
| Top-level API | Socket API, often through `LD_PRELOAD` rewrite | Normal socket API through Linux TCP/IP |
| Linux integration point | `AF_SMC` socket family and TCP ULP | `net_device` and routing |
| Application change | None when launched through `ums_run`, if compatible | None if routing and device setup direct traffic to IPoURMA |
| Data-unit shape | UMS messages and UB memory socket buffers | Linux skbs/IP packets |
| UB/URMA object use | UMS creates Jetty, JFR, JFC, Segments internally | IPoURMA creates and uses URMA/ubcore resources behind a netdev |
| TCP presence | Internal TCP socket for CLC handshake/fallback | TCP/IP stack remains above IPoURMA |
| Best mental model | Socket compatibility layer over UB memory transport | IP over URMA virtual network device |

## Relationship to UDMA

Neither UMS nor IPoURMA bypasses the normal UB/URMA kernel provider model. At
the bottom, both depend on a ubcore device backed by a UDMA implementation.
That means the final execution still depends on:

- UBASE and UB entity bring-up.
- UDMA auxiliary driver probe.
- `ubcore_device` registration.
- UMMU and token/TID/segment behavior where the path needs remote memory access.
- UDMA device support for the specific operation mode, MTU, queue depth, and
  transport mode.

The user-visible API can be sockets, but the lower capability boundary is still
the UB/URMA/UDMA hardware and driver stack.

## What This Does Not Prove

This source review does not prove that every TCP application can transparently
run over UB/URMA/UDMA. It proves that the local code has socket compatibility
mechanisms.

Open runtime questions still need hardware validation:

- Which kernel modules are enabled and loaded in the target environment.
- Whether `AF_SMC`/UMS and TCP ULP `ums` are available.
- Whether `ums_run` is installed with the expected preload path.
- Whether the target app uses socket patterns compatible with the preload
  rewrite.
- Whether UMS capability negotiation selects UB or falls back to TCP.
- Whether an `ipourmaN` device is created for the target UDMA device.
- Whether routing actually sends application traffic through IPoURMA.
- What sysfs, dmesg, and tool output show for EID mapping, ubcore devices,
  queue state, fallback state, and errors.

## Validation Checklist

For UMS:

```bash
lsmod | grep -E 'ums|ubcore|udma'
cat /proc/net/tcp
UMS_DEBUG=1 ums_run <app>
ss -a -f smc
dmesg | grep -iE 'ums|AF_SMC|tcp ulp|ubcore|udma'
```

For IPoURMA:

```bash
ip link show type ipourma
ip addr show dev ipourma0
ip route get <peer-ip>
ethtool -S ipourma0
dmesg | grep -iE 'ipourma|ubcore|udma|urma'
```

For both paths, the useful question is not just whether `socket()` succeeds.
The useful question is whether the data path leaves the ordinary TCP device and
enters UMS or IPoURMA, and then whether ubcore/UDMA counters or logs confirm UB
transport activity.
