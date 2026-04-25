# UnifiedBus and UMDK Research Findings

Last updated: 2026-04-25

## Scope

This note collects the first-pass research findings from:

- Local UnifiedBus documents on this Mac.
- Public web sources from UnifiedBus, openEuler, Gitee, and AtomGit-facing mirrors.
- The local UMDK repo at `/Users/ray/Documents/Repo/ub-stack/umdk`.
- The local UB kernel repo at `/Users/ray/Documents/Repo/ub-stack/kernel-ub`.
- The newer local openEuler kernel repo at `/Users/ray/Documents/Repo/kernel`.

The focus is UMDK, URMA, and UDMA. Related technologies such as URPC, CAM, ULOCK, USOCK, UMMU, UB Service Core, and UB OS Component are included only where they explain UMDK's place in the stack.

## Local Document Inventory

The local UnifiedBus document set is richer than the public English download set.

### `/Users/ray/Documents/docs/unifiedbus`

| File | Size | Relevance |
| --- | ---: | --- |
| `UB-Base-Specification-2.0-zh.pdf` | 27 MB | Full Chinese UB base specification; contains detailed protocol definitions for Jetty, TP, UMMU, token access control, error handling, and IP-based URMA packet formats. |
| `UB-Software-Reference-Design-for-OS-2.0-zh.pdf` | 1.8 MB | Chinese OS software reference; maps OS components to UB memory management, UMDK, URMA, URPC, UBTurbo, and related flows. |
| `UB-Service-Core-SW-Arch-RD-2.0-zh.pdf` | 1.1 MB | Chinese Service Core reference; cluster services around memory, communication, IO, virtualization, and engine control. |
| `UB-Mgmt-OM-SW-Arch-and-IF-RD-2.0-zh.pdf` | 840 KB | Chinese Management/O&M reference; includes device management and runtime management hooks. |
| `UB-SuperPoD-Architecture-White-Paper-zh.pdf` | 3.3 MB | Chinese SuperPoD white paper. |
| `UB-Base-Specification-2.0-preview-en.pdf` | 320 KB | English preview only. |
| `1-超节点和关键应用场景.pdf` | 7.9 MB | Forum/session material; scanned text extraction was limited. |
| `2-灵衢总线技术和软件参考设计.pdf` | 3.0 MB | Forum/session material; scanned text extraction was limited. |
| `3-灵衢内存池化关键技术和应用.pdf` | 1.8 MB | Forum/session material; scanned text extraction was limited. |
| `5-灵衢设备虚拟化关键技术和应用.pdf` | 3.4 MB | Forum/session material. |
| `6-超节点可靠性关键技术.pdf` | 2.9 MB | Forum/session material. |
| `7-灵衢系统高阶服务关键技术和应用.pdf` | 6.3 MB | Forum/session material; scanned text extraction was limited. |
| `8-超节点编程编译关键技术.pdf` | 1.9 MB | Forum/session material. |

### `/Users/ray/UnifiedBus-docs-2.0`

| File | Size | Relevance |
| --- | ---: | --- |
| `UB-Software-Reference-Design-for-OS-2.0-en.pdf` | 2.1 MB | English OS software reference; the most useful English source for UMDK/URMA flows. |
| `UB-Service-Core-SW-Arch-RD-2.0-en.pdf` | 944 KB | English Service Core reference; maps UBS Comm, UBS Mem, UBS IO, UBS Virt, UBS Engine. |
| `UB-Mgmt-OM-SW-Arch-and-IF-RD-2.0-en.pdf` | 1.2 MB | English O&M reference; includes URMA link establishment and runtime management references. |
| `UB-Base-Specification-2.0-preview-en.pdf` | 320 KB | English base preview. |

Text extraction was performed into `/tmp/unifiedbus-text` with `pdftotext -layout`. The scanned forum slides mostly extracted as image/noise, so the high-confidence local text comes from the specification/reference PDFs.

## Web Sources Checked

Public sources used for orientation:

- UnifiedBus site: https://www.unifiedbus.com/en
- openEuler UB OS Component: https://www.openeuler.org/en/projects/ub-os-component/
- openEuler UB Service Core: https://www.openeuler.org/en/projects/ub-service-core/
- openEuler/Gitee UMDK README mirror: https://gitee.com/openeuler/umdk/blob/master/README.md
- Gitee source package spec: https://gitee.com/src-openeuler/umdk/blob/master/umdk-urma.spec
- UnifiedBus CDN forum PDF about Lingqu communication key technologies: `https://cdn.unifiedbus.com/pdf/2025操作系统峰会-灵衢分论坛-灵衢通信关键技术和应用.pdf`

Public web findings:

- openEuler's UB OS Component page describes UB OS support as extending the OS framework, abstracting heterogeneous hardware, creating a unified memory address space, enabling global scheduling, dynamic resource combination/scaling, and efficient cross-device communication.
- openEuler's UB Service Core page describes five cluster services: UBS Engine, UBS Virt, UBS Mem, UBS Comm, and UBS IO. The page also states UBS Comm provides user-space socket/Verbs over UB style communication protocols.
- The public UMDK README currently describes UMDK as a distributed communication software library centered around memory semantics. Its listed components are URMA, CAM, URPC, ULOCK, and USOCK.
- The public UMDK README says URMA provides one-sided, two-sided, and atomic remote-memory operations and exposes both northbound application APIs and southbound driver APIs.
- The public UMDK README and local QuickStart both point to kernel 6.6 as the current build target for the newer UMDK packaging.
- The Gitee/source RPM spec packaging lineage shows an older `umdk-urma` package split into `lib`, HNS-compatible provider library, `devel`, `tools`, and TPS/UVS binaries. The local UMDK tree has evolved into the broader `umdk` package with URMA, URPC, dlock, UMS, and UDMA build options.

## UMDK in the UnifiedBus Software Stack

The English OS software reference says UMDK provides high-performance communication interfaces for data-center networks, SuperPoD environments, and inter-card communication inside servers. It places UMDK in the "Communication" chapter and breaks it into:

- UDMA driver and user UDMA driver: vendor-provided kernel/user integration.
- `uburma`, `ubcore`, and `liburma`: remote memory access operations including one-sided, two-sided, and atomic operations.
- `liburpc` and `kurpc`: RPC semantic communication.
- UMS: socket compatibility.

The same OS reference describes URMA as the communication mechanism between UB Entities for one-sided DMA access and two-sided message send/receive. It emphasizes:

- Peer-to-peer access between heterogeneous compute devices, bypassing CPUs.
- Connectionless application-level communication by reusing UB transport reliability.
- Relaxed transaction ordering and multipath transmission to reduce head-of-line blocking.

The local UMDK README is consistent with that, but expands the component list:

- URMA: memory semantic API and driver API.
- CAM: communication acceleration for AI workloads and Ascend SuperPoD affinity.
- URPC: high-performance RPC between hosts/devices and RPC acceleration.
- ULOCK: distributed state synchronization and locking.
- USOCK: socket API compatibility.

## URMA Concepts From Local Docs

The URMA API guide and OS software reference define the core objects:

- UBVA: Unified Bus Virtual Address, a hierarchical address across the UB bus. It includes EID/CID, UASID, and VA.
- Segment: a contiguous VA range backed by physical memory. A segment can be registered locally and imported remotely.
- URMA Region: a distributed shared-memory management grouping of one or more segments.
- Jetty: the command/message execution object. It maps to queues for send, receive, completion, and completion event handling.
- JFS: Jetty for Send; submits DMA tasks or messages.
- JFR: Jetty for Receive; posts receive buffers/resources.
- JFC: Jetty for Completion; stores completion records.
- JFCE: Jetty for Completion Event; supports interrupt/event mode and can be associated with multiple JFCs.

URMA operations:

- One-sided: read/write semantics, where only the local process participates once remote segment metadata and permissions are available.
- Two-sided: send/receive message semantics, where the receiver posts receive buffers and polls completions.
- Atomic: compare-and-swap and fetch-and-add style semantics in the English OS reference, with broader atomic capability fields in the current code.
- Completion: all major operations are non-blocking; successful submission means the request entered a queue, not that data movement is complete. Completion is observed through polling or JFCE-based interrupt mode.

## Token and Access-Control Model

The local OS software reference and base specification both emphasize token-based access control:

- Segment access uses token IDs and optional token values to authorize one-sided memory access.
- Jetty access can also use token values. Management-plane exchange is expected to happen through an application-secure channel.
- The Base Specification ties memory access enforcement to UMMU permission tables and token validation.
- The Base Specification distinguishes memory-access and Jetty-access authorization. Memory access can involve TokenID, optional TokenValue, and UMMU checks; Jetty access can involve TCID and optional TokenValue.

Code mapping:

- `urma_sample.c` uses `ctx->token.token = 0xACFE` and passes that token when creating JFR/segment resources and importing remote resources.
- `urma_register_seg()` and `urma_import_seg()` in liburma validate and route segment setup into provider/kernel commands.
- `uburma_cmd_register_seg()` and `uburma_cmd_import_seg()` bridge those operations into `ubcore_register_seg()` and `ubcore_import_seg()`.
- The kernel UDMA/HNS3 driver implements hardware-specific segment registration/import.

## UDMA Role

The current local UMDK UDMA user driver README states:

- UDMA means UnifiedBus Direct Memory Access.
- UDMA is a hardware I/O device providing direct memory access capabilities.
- The UDMA driver integrates with UnifiedBus by implementing the URMA programming API.
- The UDMA driver is split into user space `u-udma` and kernel space `k-udma`.
- `u-udma` enables direct user-space access to device memory for the data path, achieving kernel bypass.
- Control-plane functions still rely on kernel operations through ioctl.
- `k-udma` handles context, Jetty, Segment management, TP connection establishment, and event reporting.
- UDMA depends on UMMU for memory address translation.

The local code confirms this split:

- User provider: `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/hw/udma`
- Kernel driver in paired kernel tree: `/Users/ray/Documents/Repo/ub-stack/kernel-ub/drivers/ub/hw/hns3`
- Newer kernel driver in OLK-6.6 tree: `/Users/ray/Documents/Repo/kernel/drivers/ub/urma/hw/udma`

The newer UMDK provider is named `udma` and registers `g_udma_provider_ops`. It implements an `urma_ops_t` table named `UDMA_OPS`, which backs context, JFC/JFS/JFR/Jetty, segment, token, event, TP, and dataplane operations.

## Repo Pairing Note

There are two kernel trees on this Mac:

- `/Users/ray/Documents/Repo/ub-stack/kernel-ub`: branch `OLK-5.10`, commit `5ae3d7d`.
- `/Users/ray/Documents/Repo/kernel`: branch `OLK-6.6`, commit `8f8378999`.

The current UMDK README and QuickStart target kernel 6.6, while the local `kernel-ub` tree is OLK-5.10. However, `kernel-ub` appears structurally paired with the current `ub-stack` directory and contains the HNS3 UDMA kernel driver that matches the older HNS3 naming style. The OLK-6.6 kernel tree has a newer `drivers/ub/urma/hw/udma` path using generic `udma_*` names.

For documentation, treat:

- `umdk/src/urma/hw/udma` as the current user-space UDMA provider.
- `ub-stack/kernel-ub` as the local paired reference for ubcore/uburma/HNS3 driver mechanics.
- `Documents/Repo/kernel` as the newer openEuler kernel reference for the genericized UDMA driver.

Do not assume ABI compatibility across these two kernel trees without checking the exact release matrix.

## Key Research Conclusions

1. UMDK is the user-space library family for UB memory-semantics communication, not just a single URMA library.
2. URMA is the foundational API and resource model under UMDK communication.
3. UDMA is the hardware/provider implementation that gives URMA direct DMA capability over UB hardware.
4. The main URMA resource model is Context -> JFCE/JFC/JFR/JFS/Jetty -> Segment/Target Segment -> Work Requests -> Completion Records.
5. Control plane goes through liburma command wrappers, `/dev/uburma/<device>`, `uburma`, `ubcore`, and provider-specific kernel callbacks.
6. Data plane is designed for kernel bypass after setup: user-space UDMA owns queues, doorbells, and CQ parsing, while hardware writes completions.
7. Token access control is central to both memory and Jetty operations.
8. Current UMDK packaging is broader than older `umdk-urma`: it includes URMA, URPC, dlock/ULOCK, UMS/USOCK, and CAM-related code.

## Open Questions

- Which exact openEuler release/tag pairs `umdk` commit `d04677a` with the kernel-side UDMA/ubcore implementation?
- Whether the full Chinese base spec in `/Users/ray/Documents/docs/unifiedbus` should be summarized section-by-section for a separate protocol report.
- Whether the OLK-6.6 kernel tree should be treated as authoritative over `kernel-ub` for future code-flow traces.
- How CAM calls into URMA/URPC in production paths; the first pass only mapped its presence and examples.
