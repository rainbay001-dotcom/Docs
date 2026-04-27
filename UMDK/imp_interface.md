# IMP Interface (HiSilicon Integrated Management Processor)

In Huawei / HiSilicon SoC parlance, **IMP** is the on-die management micro-processor
that runs vendor firmware alongside the main data path. The "IMP interface" is the
host ↔ IMP control channel — concretely, a CMDQ ring + mailbox + a small set of
interrupt vectors, layered on top of MMIO. This doc traces it through the HNS3
NIC driver as it appears in the openEuler kernel, then notes the broader pattern
across Kunpeng / Ascend / HiNIC and the role's UB equivalent (MUE).

Source tree: `~/Documents/Repo/ub-stack/kernel-ub/drivers/net/ethernet/hisilicon/hns3/`
(plus `drivers/roh/hw/hns3/` for the RoH-NIC variant).

---

## 1. What IMP is and what it does

IMP is not a generic Linux concept — it's HiSilicon SoC vocabulary for the on-chip
firmware engine. In HNS3 NICs it owns:

| Responsibility | Why it sits on IMP, not host | Code marker |
|---|---|---|
| Reset orchestration | Coordinates PF + VFs cleanly; can self-trigger on fatal RAS | `HNAE3_IMP_RESET`, `HCLGE_IMP_RESET_BIT` |
| PHY / SFP / qSFP I/O | Hides PHY MDIO / I²C details behind firmware ABI | `HNAE3_DEV_SUPPORT_PHY_IMP_B`, "IMP do not support get SFP speed" |
| RAS handling | Direct access to ECC error registers, can poison reads | `HNAE3_DEV_SUPPORT_RAS_IMP_B`, `HCLGE_IMP_TCM_ECC_ERR_*`, `HCLGE_IMP_RD_POISON_*` |
| VF identity injection | Stamps `mbx_src_vfid` into mailbox messages so PF trusts source | `mbx_src_vfid; /* Auto filled by IMP */` |
| Capability advertisement | Tells host driver which features the firmware exposes | `ae_dev->caps` bits queried by host |

So when host driver code wants the SFP module's speed it doesn't poke I²C — it
sends an opcode over CMDQ and lets IMP firmware read the cage and respond.

---

## 2. The interface, drawn

```
                ┌───────────────────────┐
                │      Host CPU         │
                │  hclge_main.c driver  │
                └──┬────────────────┬───┘
        CMDQ ring  │                │ Vector0 IRQ — bits in HCLGE_VECTOR0_*:
        (DMA, MMIO │                │   bit 1: IMP_RESET_INT_B
        doorbell)  │                │   bit 4: IMP_CMDQ_ERR_B
                   │                │   bit 5: IMP_RD_POISON_B
                   │                │   bit 7: TRIGGER_IMP_RESET_B (host → IMP)
                ┌──▼────────────────▼───┐
                │  IMP — on-chip mgmt   │
                │  CPU running firmware │
                │  (PHY mgmt, RAS, SFP, │
                │   reset orchestration,│
                │   mailbox routing,    │
                │   ITCM with ECC)      │
                └───────────────────────┘
```

Driver writes a 64-byte command descriptor with a 16-bit opcode + payload into
the CMDQ, rings a doorbell, polls or takes an IRQ for completion. Mailbox
messages from VFs travel through the same path; IMP fills `mbx_src_vfid` before
forwarding to PF.

---

## 3. Concrete mechanisms in the HNS3 driver

| Concern | Mechanism | File:line |
|---|---|---|
| **Command queue** (host → IMP) | DMA ring of 64-byte descriptors; opcode + data | `hns3pf/hclge_cmd.h`, `drivers/roh/hw/hns3/hns3_cmdq.{c,h}` |
| **Mailbox** (IMP ↔ VF / PF) | `mbx_src_vfid` *"Auto filled by IMP"* | `hns3_cmdq.h:96`, `hclge_mbx.h:187` |
| **Capability negotiation** | `HNAE3_DEV_SUPPORT_PHY_IMP_B`, `HNAE3_DEV_SUPPORT_RAS_IMP_B` | `hnae3.h:127, 133, 180, 183` |
| **Reset path (IMP-initiated)** | `HNAE3_IMP_RESET` enum + interrupt bit + ethtool gate | `hnae3.h:335`, `hclge_main.h:170` (`HCLGE_VECTOR0_IMP_RESET_INT_B`), `hns3_ethtool.c:1139` (`{ETH_RESET_MGMT, HNAE3_IMP_RESET}`) |
| **Reset path (host-initiated)** | `HCLGE_TRIGGER_IMP_RESET_B = 7U` | `hns3pf/hclge_main.h:174` |
| **Custom reset variants** | `HNAE3_IMP_RESET_CUSTOM`, `HNAE3_IMP_RESET_FAIL_CUSTOM`, `HNAE3_IMP_RD_POISON_CUSTOM` | `hnae3_ext.h:15, 22, 24` |
| **ITCM ECC errors** | `HCLGE_IMP_TCM_ECC_ERR_INT_EN = 0xFFFF0000`, `HCLGE_IMP_ITCM4_ECC_ERR_INT_EN = 0x300` | `hns3pf/hclge_err.h:26-29` |
| **Read poison from IMP** | `HCLGE_IMP_RD_POISON_ERR_INT_EN = 0x0100`; reported as `HNAE3_IMP_RD_POISON_ERROR` | `hns3pf/hclge_err.h:34-35`, `hns3_enet.c:6450` ("IMP RD poison") |
| **CMDQ error interrupt** | `HCLGE_VECTOR0_IMP_CMDQ_ERR_B = 4U` | `hns3pf/hclge_main.h:171`; reported as "IMP CMDQ error" in `hns3_enet.c:6449` |
| **Debug / debugfs** | `HNAE3_DBG_CMD_IMP_INFO` dumps IMP state | `hnae3.h:370`, `hns3_debugfs.c:190` |
| **Debug visualization** | "IMP reset count: %u" in debugfs | `hns3pf/hclge_debugfs.c:2448` |
| **Stats** | `imp_rst_cnt` — number of IMP-initiated resets | `hns3pf/hclge_main.h:811` |
| **PHY indirection** | If `PHY_IMP_B` set, host queries IMP for SFP/qSFP speed/info instead of poking PHY directly | `hclge_main.c:3241, 3267, 3449` |
| **Custom ext events** | `event_t != HNAE3_IMP_RESET_CUSTOM` filter | `hns3_ext.c:71` |
| **Capability bit cap-table** | feature query runtime exposes `PHY_IMP_B`, `RAS_IMP_B` to userspace | `hns3_debugfs.c:402, 405` |

### Boot / runtime flow worth noting

- Host driver (`hclge_main.c`) on boot **negotiates capabilities** by reading a
  cap bitmap reported by IMP firmware. From that point on, code paths gated on
  `HNAE3_DEV_SUPPORT_PHY_IMP_B` or `HNAE3_DEV_SUPPORT_RAS_IMP_B` either send an
  IMP cmdq opcode or fall back to direct PHY/RAS register access (older silicon).
- The driver explicitly handles **firmware-skew**: comments around
  `hclge_main.c:550, 580, 4002, 4216, 4330, 8728` flag commands the firmware may
  not understand, behaviors that change between firmware versions, and
  silent-disable patterns (e.g. firmware disabling MAC outside PF reset / FLR).
- **IMP-CMDQ self-error** (`HCLGE_VECTOR0_IMP_CMDQ_ERR_B`) and **IMP read poison**
  (`HCLGE_VECTOR0_IMP_RD_POISON_B`) are first-class IRQ vectors — the host driver
  treats firmware-engine faults as just another error class to log + recover from.

---

## 4. Beyond HNS3

**IMP is a generic HiSilicon SoC concept**. Every chip family — Kunpeng CPUs,
Ascend NPUs, HiNICs, Atlas boards — has an IMP-style management CPU running
iBMA / PMU / BMC-aligned firmware that the OS driver talks to over a CMDQ-ish
interface. Search terms in the openEuler kernel for analogues:

```
imp_     IMP_RESET     *_imp_info     mailbox     cmdq
```

The architectural slot — *"on-chip management plane separate from the data path,
talked to via DMA ring + doorbell + a small IRQ vector set"* — is the same
across all of them; only the cmd-queue ABI and capability set differ.

### UB equivalent: MUE

In the UnifiedBus 2.0 spec the same architectural role is filled by **MUE**
(Management UB Entity, spec §10.2.3). The naming is different — and the spec is
careful to distinguish it from data-plane Entities — but it sits in the same
slot: a separate management entity beside the data-plane that exposes a control
channel. UDMA's `udma_mue.c` (in the kernel UDMA HW provider) is the host-side
counterpart. See `umdk_spec_deep_dive.md` for the spec citation.

So when you read code on either side of the UB stack:

- **HNS3 / RoH** call this engine **IMP**, talk to it through CMDQ + mailbox.
- **UDMA / UB** call it **MUE**, talk to it through the UB Function Layer.
- Both are the same architectural pattern: on-chip firmware-driven management
  plane, address-mapped command queue, capability-gated feature flags.

---

## 5. File map (HNS3 in this repo)

| File | What's in it |
|---|---|
| `drivers/net/ethernet/hisilicon/hns3/hnae3.h` | Top-level capability/event enum table — `HNAE3_DEV_SUPPORT_{PHY,RAS}_IMP_B`, `HNAE3_IMP_{RESET,RD_POISON_ERROR}`, `HNAE3_DBG_CMD_IMP_INFO` |
| `drivers/net/ethernet/hisilicon/hns3/hnae3_ext.h` | Custom extension enums — `HNAE3_IMP_RESET_CUSTOM`, `_FAIL_CUSTOM`, `_RD_POISON_CUSTOM` |
| `drivers/net/ethernet/hisilicon/hns3/hns3_ethtool.c` | `ETH_RESET_MGMT → HNAE3_IMP_RESET` translation |
| `drivers/net/ethernet/hisilicon/hns3/hns3_enet.c` | Error message strings — "IMP CMDQ error", "IMP RD poison" |
| `drivers/net/ethernet/hisilicon/hns3/hns3_debugfs.c` | `HNAE3_DBG_CMD_IMP_INFO` debugfs dump entry, `PHY_IMP_B` / `RAS_IMP_B` cap-query display |
| `drivers/net/ethernet/hisilicon/hns3/hns3_ext.c` | Custom event filter `event_t != HNAE3_IMP_RESET_CUSTOM` |
| `drivers/net/ethernet/hisilicon/hns3/hns3pf/hclge_main.{c,h}` | Driver IMP usage — SFP queries, IRQ vector bits, reset path, `imp_rst_cnt` stat |
| `drivers/net/ethernet/hisilicon/hns3/hns3pf/hclge_err.h` | TCM ECC + read-poison error register enables |
| `drivers/net/ethernet/hisilicon/hns3/hns3pf/hclge_ext.c` | Reset-type translation table mapping `HNAE3_IMP_RESET → HNAE3_IMP_RESET_FAIL_CUSTOM` for ext events |
| `drivers/net/ethernet/hisilicon/hns3/hns3pf/hclge_debugfs.c` | "IMP reset count: %u" debugfs print |
| `drivers/net/ethernet/hisilicon/hns3/hns3pf/hclge_cmd.h` | CMDQ command-queue descriptor structures |
| `drivers/net/ethernet/hisilicon/hns3/hclge_mbx.h` | Mailbox structure with `mbx_src_vfid; /* Auto filled by IMP */` |
| `drivers/roh/hw/hns3/hns3_cmdq.{c,h}` | RoH variant of the same CMDQ + mailbox pattern |

---

## 6. Decisive shape

IMP is the **on-chip management firmware** for HiSilicon NICs (and the same
pattern across their other SoCs). The "IMP interface" is the **host ↔ IMP control
plane** built from:

1. **CMDQ** — a DMA ring of 64-byte command descriptors + MMIO doorbell, used
   for sync/async opcodes (PHY mgmt, SFP query, reset request, RAS arming, …).
2. **Mailbox** — VF / PF messages routed through IMP, which auto-stamps source
   VF id.
3. **Vector0 IRQ bits** — a small set of dedicated interrupt bits for
   IMP-originated events: `IMP_RESET`, `IMP_CMDQ_ERR`, `IMP_RD_POISON`, plus
   one bit for the host to *ask* IMP to reset.
4. **Capability bits** advertised by firmware on boot, gating which paths use
   IMP vs direct register access.
5. **Per-direction RAS** — both ITCM ECC (firmware memory) and read-poison
   semantics (IMP reading host memory) are first-class error classes in the
   Vector0 bitmap.

In the UB / UMDK stack the equivalent role is filled by **MUE** — same
architectural slot, different name and ABI, talked to via the UB Function Layer
instead of HNS3 CMDQ.
