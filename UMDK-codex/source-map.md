# Source Map

Last updated: 2026-04-25

## UMDK Repo

Local path:

```text
/Users/ray/Documents/Repo/ub-stack/umdk
```

Observed branch/commit:

```text
master @ d04677a
```

## Local UnifiedBus Specification PDFs

Primary local paths:

| Path | Role |
| --- | --- |
| `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-zh.pdf` | Full Chinese UB base specification; primary source for UB stack, transaction layer, URMA functional model, UBoE, and Ethernet interop |
| `/Users/ray/Documents/docs/unifiedbus/UB-Base-Specification-2.0-preview-en.pdf` | English preview of UB base specification |
| `/Users/ray/UnifiedBus-docs-2.0/UB-Base-Specification-2.0-preview-en.pdf` | Duplicate/local English preview set |
| `/Users/ray/UnifiedBus-docs-2.0/UB-Software-Reference-Design-for-OS-2.0-en.pdf` | English OS reference design; primary source for UMDK functional architecture and URMA module architecture |
| `/Users/ray/Documents/docs/unifiedbus/UB-Software-Reference-Design-for-OS-2.0-zh.pdf` | Chinese OS reference design cross-check |
| `/Users/ray/UnifiedBus-docs-2.0/UB-Service-Core-SW-Arch-RD-2.0-en.pdf` | Service Core reference; source for HCOM, Socket-over-UB, HCAL, RoUB positioning |

Extracted text used for search:

| Path | Role |
| --- | --- |
| `/tmp/unifiedbus-text/UB-Base-Specification-2.0-zh.txt` | Full base-spec text extraction |
| `/tmp/unifiedbus-text/UB-Software-Reference-Design-for-OS-2.0-en.txt` | English OS reference extraction |
| `/tmp/unifiedbus-text/UB-Software-Reference-Design-for-OS-2.0-zh.txt` | Chinese OS reference extraction |
| `/tmp/unifiedbus-text/UB-Service-Core-SW-Arch-RD-2.0-en.txt` | English Service Core extraction |

Spec sections most relevant to UMDK/URMA/UDMA:

| Source | Section | Relevance |
| --- | --- | --- |
| UB Base Specification 2.0 | Section 2 | UB architecture, UBPU, UB Controller, UMMU, UB Link, UB Domain, UBoE, protocol stack |
| UB Base Specification 2.0 | Section 4 | Data-link reliability, credit flow control, virtual lanes, retry buffer |
| UB Base Specification 2.0 | Section 5 | Network addressing, CNA/IP formats, routing, multipath, service level, congestion marking |
| UB Base Specification 2.0 | Section 6 | RTP/CTP/UTP/TP Bypass, TP Channel, TPG, PSN, acknowledgements, retransmission, congestion control |
| UB Base Specification 2.0 | Section 7 | Transaction layer, ROI/ROT/ROL/UNO, memory/message/maintenance/management transactions |
| UB Base Specification 2.0 | Section 8.2-8.4 | Segment, Jetty, JFC/JFCE/JFAE, transaction queues, access credentials, URMA async flow |
| UB Base Specification 2.0 | Appendix B | IP/CNA UB packet formats, UPIH/EIDH, IP-based URMA packet formats |
| UB Base Specification 2.0 | Appendix E | Ethernet interop and UBoE |
| UB Base Specification 2.0 | Appendix F | Network management over UB links and ARP hardware type context |
| UB OS Software Reference Design | Section 5.2 | UMDK functional architecture |
| UB OS Software Reference Design | Section 5.3 | URMA overview, module architecture, Jetty/Segment/two-sided/one-sided/atomic/completion behavior |
| UB Service Core Reference | Section 5 | HCOM, Socket-over-UB, HCAL, RoUB compatibility layer positioning |

External comparison references:

| Link | Role |
| --- | --- |
| https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=4792 | `unified-bus` TCP/UDP port 4792 |
| https://www.iana.org/assignments/arp-parameters/arp-parameters.xhtml | ARP hardware type 38 for Unified Bus |
| https://standards.ieee.org/ieee/802.3/10422/ | IEEE 802.3-2022 Ethernet scope |
| https://1.ieee802.org/dcb/802-3bd/ | IEEE PFC/Data Center Bridging context |
| https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/RDMA-Aware%2BProgramming%2BOverview | RDMA verbs/QP baseline |
| https://docs.nvidia.com/networking/display/RDMAAwareProgrammingv17/InfiniBand | InfiniBand native RDMA baseline |
| https://docs.nvidia.com/networking/display/MLNXENv23100550/RDMA%2Bover%2BConverged%2BEthernet%2B%28RoCE%29 | RoCEv1/RoCEv2 encapsulation baseline |

PCIe comparison source anchors:

| Local file | Role |
| --- | --- |
| `/Users/ray/Documents/Repo/kernel/drivers/pci/pci-driver.c` | `pci_bus_type`, PCI driver registration, PCI match/probe/remove path |
| `/Users/ray/Documents/Repo/kernel/drivers/pci/probe.c` | PCI host bridge registration, root bus scan, child bus scan, slot/function scan, `pci_setup_device`, `pci_device_add` |
| `/Users/ray/Documents/Repo/kernel/drivers/pci/bus.c` | `pci_bus_add_device()` and `pci_bus_add_devices()` driver attach path |
| `/Users/ray/Documents/Repo/kernel/include/linux/pci.h` | PCI public types and helper declarations |

Terminology mapping code anchors:

| Local symbol family | Local file |
| --- | --- |
| `urma_device_t`, `urma_context_t`, `urma_jfs_t`, `urma_jfr_t`, `urma_jfc_t`, `urma_jetty_t`, `urma_seg_t` | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_types.h` |
| `urma_create_jfc`, `urma_create_jfs`, `urma_create_jfr`, `urma_create_jetty`, `urma_register_seg`, post/poll APIs | `/Users/ray/Documents/Repo/ub-stack/umdk/src/urma/lib/urma/core/include/urma_api.h` |
| `ubcore_device`, `ubcore_ops`, `ubcore_jfs`, `ubcore_jfr`, `ubcore_jfc`, `ubcore_jetty`, `ubcore_target_seg` | `/Users/ray/Documents/Repo/kernel/include/ub/urma/ubcore_types.h` |
| `ib_device`, `ib_device_ops`, `ib_qp`, `ib_cq`, `ib_mr`, `ib_pd`, `ib_ucontext` | `/Users/ray/Documents/Repo/kernel/include/rdma/ib_verbs.h` |

Top-level layout:

| Path | Role |
| --- | --- |
| `README.md` | Current high-level UMDK introduction |
| `umdk.spec` | RPM/package build logic and feature switches |
| `doc/en/urma` | URMA quickstart, user guide, API guide |
| `doc/en/urpc` | URPC and UMQ guides |
| `doc/en/cam` | CAM API guide |
| `src/urma` | URMA stack, UDMA user provider, UVS support, tools, examples |
| `src/urpc` | URPC framework and UMQ implementation |
| `src/cam` | CAM communication acceleration |
| `src/ulock` | distributed lock |
| `src/usock` | UMS/socket compatibility |

Key URMA user-space files:

| Path | Role |
| --- | --- |
| `src/urma/lib/urma/core/urma_main.c` | Initialization, provider loading, device list, context API |
| `src/urma/lib/urma/core/urma_device.c` | sysfs and cdev discovery |
| `src/urma/lib/urma/core/urma_cmd.c` | ioctl command wrappers |
| `src/urma/lib/urma/core/urma_cmd_tlv.c` | TLV command wrappers |
| `src/urma/lib/urma/core/urma_cp_api.c` | control-plane APIs |
| `src/urma/lib/urma/core/urma_dp_api.c` | data-plane APIs |
| `src/urma/lib/urma/core/include/urma_api.h` | public URMA API |
| `src/urma/lib/urma/core/include/urma_provider.h` | provider-facing ABI |
| `src/urma/lib/urma/bond` | bonding/multipath provider |
| `src/urma/lib/uvs` | UVS/TPSA APIs and ioctls |

Key UB-Mesh/topology user-space files:

| Path | Role |
| --- | --- |
| `src/urma/lib/uvs/core/include/uvs_api.h` | UVS topology types, path sets, topology nodes, aggregate devices, set/get topology APIs |
| `src/urma/lib/uvs/core/tpsa_api.c` | `uvs_set_topo_info()` and topology propagation into ubagg and ubcore |
| `src/urma/lib/uvs/core/uvs_ubagg_ioctl.c` | user-space ioctl path for ubagg and ubcore topology set/get |
| `src/urma/lib/urma/bond/bondp_provider_ops.c` | bond provider topology fetch and fallback behavior |
| `src/urma/lib/urma/bond/utils/topo_info.c` | bond provider topology-map helpers |
| `src/urma/tools/urma_admin/admin_cmd_show.c` | `urma_admin show topo` implementation |
| `src/urma/tools/urma_ping/ping_run.c` | topology-aware ping helper logic |
| `src/cam/comm_operator/ascend_kernels` | CAM/MoE tiling code with `level0:fullmesh` collective hints |

Key URPC/UMQ files:

| Path | Role |
| --- | --- |
| `src/urpc/include/framework/urpc_framework_api.h` | Public URPC API for init/uninit, allocator registration, remote memory-segment access, channel create/destroy, server attach/refresh/detach, server start, and queue add/remove/pair/unpair |
| `src/urpc/include/umq/umq_api.h` | Public UMQ API for queue init/create/bind, buffer allocation, enqueue/dequeue, interrupts, and async events |
| `src/urpc/framework/lib/control/cp.c` | URPC channel control implementation, including channel create/destroy, server attach/refresh/detach, queue add/remove, and pair/unpair |
| `src/urpc/framework/lib/datapath/dp.c` | URPC datapath implementation |
| `src/urpc/umq/umq_ub/core/private/umq_pro_ub.c` | UB backend that polls URMA JFCs, posts Jetty receives, handles TX/RX completions, and flushes Jetty state |
| `src/urpc/umq/umq_ipc` | IPC UMQ transport implementation |
| `src/urpc/umq/umq_ubmm` | UB memory-management related UMQ transport implementation |
| `src/urpc/tools/urpc_admin/urpc_admin.c` | URPC admin tool; connects to `<path>/urpc.sock.<pid>` and sends Unix-domain IPC control requests |
| `src/urpc/tools/perftest` | URPC/UMQ performance tests |

Key UMS/USOCK files:

| Path | Role |
| --- | --- |
| `src/usock/ums/kmod/ums/ums_mod.c` | UMS kernel module entry, AF_SMC protocol registration, TCP ULP registration, ubcore client registration, and socket operations |
| `src/usock/ums/tools/ums-preload.c` | LD_PRELOAD socket wrapper; maps eligible TCP stream sockets to AF_SMC |
| `src/usock/ums/tools/ums_run` | Wrapper script that injects `/usr/lib/libums-preload.so` and execs the target command |
| `src/usock/ums/tools/ums_admin/ums_admin.c` | UMS DFX/admin tool using generic netlink family `UMS_GENL_DFX` |
| `src/usock/ums/kmod/ums/cm` | UMS connection-management path |
| `src/usock/ums/kmod/ums/llc` | UMS link-layer control path |
| `src/usock/ums/kmod/ums/cdc` | UMS CDC path |
| `src/usock/ums/kmod/ums/dev/ums_ubcore.c` | UMS ubcore client and URMA object lifecycle: EID selection, Jetty/JFR/JFC creation, import/bind, segment registration |
| `src/usock/ums/kmod/ums/dev/ums_wr.c` | UMS ubcore WR post/poll/rearm path |
| `src/usock/ums/kmod/ums/io/ums_tx.c` | UMS TX data path that posts Jetty send WRs |

Discovered tool paths:

| Tool | Path | Role |
| --- | --- | --- |
| `urma_admin` | `src/urma/tools/urma_admin` | URMA device/resource/EID/topology admin tool |
| `urma_ping` | `src/urma/tools/urma_ping` | URMA connectivity/topology diagnostic tool |
| `urma_perftest` | `src/urma/tools/urma_perftest` | URMA performance tests |
| `urpc_admin` | `src/urpc/tools/urpc_admin` | URPC process control/DFX through Unix-domain IPC |
| URPC perftest | `src/urpc/tools/perftest` | URPC/UMQ performance tests |
| `ums_admin` | `src/usock/ums/tools/ums_admin` | UMS generic-netlink DFX status tool |
| `ums_run` | `src/usock/ums/tools/ums_run` | UMS preload runner for socket applications |

No local source named `ubtool`, `ub_tool`, `ub tool`, or `ub-tool` was found in
the checked UMDK, current kernel, or paired kernel trees during this pass.

Key UDMA user provider files:

| Path | Role |
| --- | --- |
| `src/urma/hw/udma/README.md` | UDMA user driver overview |
| `src/urma/hw/udma/udma_u_ops.c` | provider ops table and context lifecycle |
| `src/urma/hw/udma/udma_u_main.c` | provider registration |
| `src/urma/hw/udma/udma_u_abi.h` | provider-private ABI |
| `src/urma/hw/udma/udma_u_jfc.c` | JFC and completion polling |
| `src/urma/hw/udma/udma_u_jfs.c` | JFS and send WQE posting |
| `src/urma/hw/udma/udma_u_jfr.c` | JFR and receive posting |
| `src/urma/hw/udma/udma_u_jetty.c` | Jetty management and Jetty send/receive posting |
| `src/urma/hw/udma/udma_u_segment.c` | segment register/import/unimport |
| `src/urma/hw/udma/udma_u_db.c` | doorbell allocation/mapping |
| `src/urma/hw/udma/udma_u_ctrlq_tp.c` | control-queue TP operations |
| `src/urma/hw/udma/udma_u_ctl.c` | provider user-control operations |

## Paired UB Kernel Repo

Local path:

```text
/Users/ray/Documents/Repo/ub-stack/kernel-ub
```

Observed branch/commit:

```text
OLK-5.10 @ 5ae3d7d
```

Key paths:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/ubcore` | shared URMA kernel core |
| `drivers/ub/urma/uburma` | user-kernel command bridge and cdev path |
| `drivers/ub/hw/hns3` | HNS3 UDMA kernel driver |
| `drivers/net/ethernet/hisilicon/hns3` | related HNS3 network/UNIC support |

Key kernel files:

| Path | Role |
| --- | --- |
| `drivers/ub/urma/uburma/uburma_cmd.c` | command dispatcher from user ioctl to ubcore |
| `drivers/ub/urma/uburma/uburma_uobj.c` | user object management |
| `drivers/ub/urma/ubcore/ubcore_device.c` | device registration, sysfs, context allocation |
| `drivers/ub/urma/ubcore/ubcore_jetty.c` | JFC/JFS/JFR/Jetty/Jetty group core lifecycle |
| `drivers/ub/urma/ubcore/ubcore_segment.c` | segment registration/import core lifecycle |
| `drivers/ub/urma/ubcore/ubcore_tp.c` | transport path management |
| `drivers/ub/hw/hns3/hns3_udma_main.c` | HNS3 UDMA ops table, context, mmap, registration |
| `drivers/ub/hw/hns3/hns3_udma_abi.h` | HNS3 user/kernel private ABI |
| `drivers/ub/hw/hns3/hns3_udma_jfc.c` | kernel JFC implementation |
| `drivers/ub/hw/hns3/hns3_udma_jfs.c` | kernel JFS implementation |
| `drivers/ub/hw/hns3/hns3_udma_jfr.c` | kernel JFR implementation |
| `drivers/ub/hw/hns3/hns3_udma_jetty.c` | kernel Jetty implementation |
| `drivers/ub/hw/hns3/hns3_udma_segment.c` | kernel segment implementation |
| `drivers/ub/hw/hns3/hns3_udma_tp.c` | kernel TP implementation |
| `drivers/ub/hw/hns3/hns3_udma_user_ctl.c` | provider extension command handlers |

## Newer openEuler Kernel Repo

Local path:

```text
/Users/ray/Documents/Repo/kernel
```

Observed branch/commit:

```text
OLK-6.6 @ 8f8378999
```

Key files:

| Path | Role |
| --- | --- |
| `drivers/ub/ubfi/ub_fi.c` | UB firmware-interface module entry; selects ACPI UBRT or DTS UBIOS table |
| `drivers/ub/ubfi/ubrt.c` | Parses UB root table and dispatches UBC/UMMU subtables |
| `drivers/ub/ubfi/ubc.c` | Creates `struct ub_bus_controller`, resources, IRQs, MSI domain, and `ubc_list` |
| `drivers/ub/ubfi/ubc.h` | Firmware `struct ubc_node`; includes `ummu_mapping`, CNA/EID ranges, DMA CCA |
| `drivers/ub/ubfi/ummu.c` | Parses UMMU table, matches ACPI/DTS platform devices, renames `ummu.N`, attaches resources |
| `include/ub/ubfi/ubfi.h` | UMMU node and UBRT fwnode definitions |
| `drivers/ub/ubus/ub-driver.c` | Defines and registers `ub_bus_type`; DMA/IOMMU configuration hook |
| `drivers/ub/ubus/ubus_driver.c` | UB bus match/probe/remove/uevent callbacks and host-probe sequence |
| `drivers/ub/ubus/enum.c` | UBC-rooted topology scan, `ub_entity` creation, route calculation, activation |
| `include/ub/ubus/ubus.h` | `struct ub_entity`, `struct ub_driver`, UB bus API |
| `drivers/ub/ubus/vendor/hisilicon/hisi-ubus.c` | Hisilicon management subsystem registration and platform-driver match |
| `drivers/ub/ubase/ubase_main.c` | UBASE module init and UB driver registration |
| `drivers/ub/ubase/ubase_ubus.c` | UBASE `struct ub_driver` probe/remove and UB entity initialization |
| `drivers/ub/urma/hw/udma/Kconfig` | Defines `CONFIG_UB_UDMA` and dependencies |
| `drivers/ub/urma/hw/udma/Makefile` | Builds the `udma` module objects |
| `drivers/ub/urma/hw/udma/udma_main.c` | module entry, auxiliary driver, ubcore ops, caps |
| `drivers/ub/urma/hw/udma/udma_dev.h` | main `struct udma_dev` |
| `drivers/ub/urma/hw/udma/udma_common.c` | memory pinning, UMMU MATT map/unmap, ID allocation |
| `drivers/ub/urma/hw/udma/udma_ctl.c` | extended/user-control paths |
| `drivers/ub/urma/hw/udma/udma_ctx.c` | user context, SVA/separated TID allocation, mmap support |
| `drivers/ub/urma/hw/udma/udma_db.c` | doorbell management |
| `drivers/ub/urma/hw/udma/udma_tid.c` | token ID/TID allocation and KSVA table management |
| `drivers/ub/urma/hw/udma/udma_segment.c` | segment register/import, UMMU grant/ungrant, MATT mapping |
| `drivers/ub/urma/hw/udma/udma_jfc.c` | completion queue |
| `drivers/ub/urma/hw/udma/udma_jfs.c` | send queue |
| `drivers/ub/urma/hw/udma/udma_jfr.c` | receive queue |
| `drivers/ub/urma/hw/udma/udma_jetty.c` | Jetty object |
| `drivers/ub/urma/hw/udma/udma_ctrlq_tp.c` | control queue and TP |
| `drivers/ub/urma/hw/udma/udma_eid.c` | EID/IP helpers |
| `Documentation/ub/urma/ipourma/ipourma.rst` | IPoURMA documentation: socket API/TCP-IP stack over IPoURMA, UBCORE, and UDMA |
| `drivers/ub/urma/ulp/ipourma/ipourma_main.c` | IPoURMA ubcore client, feature gating, netdev allocation, and registration |
| `drivers/ub/urma/ulp/ipourma/ipourma_netdev.c` | IPoURMA netdev operations, including `ndo_start_xmit` from Linux TCP/IP into IPoURMA |
| `drivers/ub/urma/ulp/ipourma/ipourma_ub.c` | IPoURMA ubcore/URMA send path, skb handling, EID resolution, Jetty import/use, and `ubcore_post_jetty_send_wr()` |
| `drivers/ub/urma/ulp/ipourma/ipourma_netlink.c` | IPoURMA RTNL link kind and netdev setup behavior |
| `drivers/net/ub/unic/unic_main.c` | UNIC module entry, auxiliary driver, probe/remove, IP/netdevice notifiers |
| `drivers/net/ub/unic/unic_netdev.c` | UNIC netdev queue setup, traffic class mapping, NAPI/channel enable, net up/down, link status |
| `drivers/net/ub/unic/unic_tx.c` | UNIC transmit path |
| `drivers/net/ub/unic/unic_rx.c` | UNIC receive path |
| `drivers/net/ub/unic/unic_txrx.c` | UNIC TX/RX channel glue |
| `drivers/net/ub/unic/unic_qos_hw.c` | UNIC QoS hardware handling |
| `drivers/net/ub/unic/unic_dcbnl.c` | UNIC DCB/netlink behavior |
| `drivers/ub/cdma/cdma_main.c` | CDMA module entry, auxiliary driver, class creation, char-device creation, reset callbacks |
| `drivers/ub/cdma/cdma_chardev.c` | CDMA `/dev/cdma/dev`, `CDMA_SYNC` ioctl, mmap handling |
| `drivers/ub/cdma/cdma_ioctl.c` | CDMA user command dispatcher and handlers for context, CTP, queue, JFS, JFC, JFCE, Segment |
| `drivers/ub/cdma/cdma_tid.c` | CDMA device-level KSVA/SVA/IOPF enablement, TID allocation, and UMMU grant/ungrant |
| `drivers/ub/cdma/cdma_context.c` | CDMA context-level KSVA/SVA/separated-TID allocation and teardown |
| `drivers/ub/cdma/cdma_segment.c` | CDMA Segment pin, token, TID, and UMMU grant/ungrant handling |
| `include/uapi/ub/cdma/cdma_abi.h` | CDMA UAPI command, mmap, completion, and object ABI |
| `include/ub/cdma/cdma_api.h` | Kernel-facing CDMA client API |
| `drivers/ub/urma/ubcore/ubcore_topo_info.h` | ubcore topology node, aggregate device, path, and path-set structures |
| `drivers/ub/urma/ubcore/ubcore_topo_info.c` | ubcore topology map helpers and path-set selection |
| `drivers/ub/urma/ubcore/ubcore_uvs_cmd.c` | ubcore topology set/get and path-set global commands |
| `drivers/ub/urma/ubagg/ubagg_ioctl.c` | ubagg topology set and aggregate topology handling |
| `include/uapi/ub/urma/udma/udma_abi.h` | kernel UAPI ABI |

## Important Symbols

UMDK/liburma:

- `urma_init`
- `urma_register_provider_ops`
- `urma_scan_sysfs_devices`
- `urma_get_device_by_name`
- `urma_create_context`
- `urma_create_jfc`
- `urma_create_jfs`
- `urma_create_jfr`
- `urma_create_jetty`
- `urma_register_seg`
- `urma_import_seg`
- `urma_post_jetty_send_wr`
- `urma_post_jetty_recv_wr`
- `urma_poll_jfc`

UMDK/URPC/UMQ:

- `urpc_init`
- `urpc_channel_create`
- `urpc_channel_server_attach`
- `urpc_channel_queue_add`
- `urpc_channel_queue_pair`
- `umq_init`
- `umq_create`
- `umq_bind`
- `umq_enqueue`
- `umq_dequeue`
- `umq_ub_poll_rx`
- `umq_ub_poll_tx`
- `umq_ub_fill_fc_rx_buf`

UMDK/UMS:

- `ums_init`
- `ums_sock_register`
- `ums_ubcore_register_client`
- `tcp_register_ulp`
- `ums_create`
- `ums_sock_alloc`
- `socket` in `ums-preload.c`
- `ums_wr_tx_send`
- `ums_wr_rx_post`
- `ums_tx_ub_write`

Kernel IPoURMA:

- `ipourma_ubcore_add_device`
- `ipourma_alloc_netdev`
- `ipourma_register_netdev`
- `ipourma_start_xmit`
- `ipourma_xmit`
- `ipourma_post_send`

Kernel UNIC/CDMA:

- `unic_probe`
- `unic_enable_channels`
- `unic_link_status_change`
- `cdma_probe`
- `cdma_ioctl`
- `cdma_cmd_parse`
- `cdma_alloc_dev_tid`
- `cdma_alloc_context`
- `cdma_register_seg`
- `cdma_seg_grant`

UMDK/u-UDMA:

- `g_udma_ops`
- `g_udma_provider_ops`
- `udma_u_create_context`
- `udma_u_create_jfc`
- `udma_u_create_jfs`
- `udma_u_create_jfr`
- `udma_u_create_jetty`
- `udma_u_register_seg`
- `udma_u_import_seg`
- `udma_u_post_jfs_wr`
- `udma_u_post_jetty_send_wr`
- `udma_u_poll_jfc`

UMDK/UVS/topology:

- `uvs_set_topo_info`
- `uvs_get_topo_info`
- `uvs_ubagg_ioctl_set_topo`
- `uvs_ubcore_ioctl_set_topo`
- `struct urma_topo_node`
- `uvs_path_set_t`
- `get_topo_info_from_ko`
- `create_topo_map`
- `cmd_show_topo`

kernel-ub:

- `uburma_cmd_create_ctx`
- `uburma_cmd_create_jfs`
- `uburma_cmd_create_jfr`
- `uburma_cmd_create_jfc`
- `uburma_cmd_create_jetty`
- `uburma_cmd_import_seg`
- `uburma_cmd_import_jetty`
- `ubcore_register_device`
- `ubcore_alloc_ucontext`
- `ubcore_create_jfc`
- `ubcore_create_jfs`
- `ubcore_create_jetty`
- `ubcore_register_seg`
- `ubcore_import_seg`
- `g_hns3_udma_dev_ops`

OLK-6.6 kernel:

- `ubfi_init()`: loads UBRT/UBIOS firmware information.
- `handle_ubc_table()`: creates firmware-reported UB controllers.
- `handle_ummu_table()`: links firmware UMMU records to platform devices.
- `ub_bus_type`: Linux bus named `ub`.
- `ub_uevent()`: emits `UB_ID`, `UB_MODULE`, `UB_TYPE`, `UB_CLASS`, `UB_VERSION`, `UB_SEQ_NUM`, `UB_ENTITY_NAME`, and `MODALIAS=ub:*`.
- `ub_enum_probe()`: scans and activates UB topology.
- `ubase_ubus_probe()`: binds a UB entity to UBASE.
- `g_dev_ops`: UDMA implementation of `struct ubcore_ops`.
- `udma_probe()`: auxiliary-device probe path.
- `udma_set_ubcore_dev()`: configures and registers the ubcore device.
- `udma_alloc_dev_tid()`: enables IOPF/SVA/KSVA and obtains a device TID.
- `udma_alloc_ucontext()`: obtains per-user-context UMMU TID.
- `udma_alloc_tid()`: maps ubcore token IDs to UMMU TIDs.
- `udma_register_seg()`: UDMA Segment registration and UMMU grant/map path.
- `struct ubcore_topo_node`: kernel topology node with `1D-fullmesh` and Clos type comments.
- `ubcore_cmd_set_topo()`: creates/updates global ubcore topology map and Jetty resources.
- `ubagg_cmd_set_topo_info()`: creates/updates ubagg topology map.
- `ubcore_get_path_set()`: resolves aggregate EIDs into topology-aware path sets.
- `query_caps_from_firmware()`: queries hardware/firmware resources.
- `udma_query_device_attr()`: exposes device capabilities to ubcore/user space.
