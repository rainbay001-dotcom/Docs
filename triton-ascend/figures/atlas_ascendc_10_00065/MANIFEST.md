# Figures from `atlas_ascendc_10_00065` (NPU架构版本351x)

Source URL (verified live 2026-05-09):
https://www.hiascend.com/document/detail/zh/canncommercial/900/programug/Ascendcopdevg/atlas_ascendc_10_00065.html

Page-update date: 2026/04/30

15 figures total, downloaded as PNG. Original CDN file IDs preserved
in the manifest below for traceability.

| # | Renamed file | Original CDN ID | Caption / Topic | Section |
|---|---|---|---|---|
| 1 | `01_hardware_architecture.png` | `zh-cn_image_0000002531522468` | **硬件架构图** — full AIC + AIV + L1/L0A/L0B/L0C/UB + DCache/ICache + SSBuffer + MTE + 指令序列 | Top of article |
| 2 | `02_fig1_220x_high_dim_tiling.png` | `zh-cn_image_0000002531362514` | **图1** NPU架构版本220x 高维切分 (mask via `uint64_t mask[]` / `uint64 mask`, no MaskReg) | Vector unit |
| 3 | `03_fig2_351x_high_dim_tiling.png` | `zh-cn_image_0000002531362516` | **图2** 本架构版本高维切分 (mask via MaskReg into Vector unit) | Vector unit |
| 4 | `04_fig3_ub_bank_layout.png` | `zh-cn_image_0000002531362512` | **图3** UB bank 示意图 — 8 bank groups × 2 banks each | UB structure |
| 5 | `05_loop_mode_normal_aligned.png` | `zh-cn_image_0000002531522466` | Loop mode — Normal, blocks already 32 B aligned | Loop mode |
| 6 | `06_loop_mode_normal_aligned_dup.png` | `zh-cn_image_0000002531522464` | Loop mode — Normal aligned (duplicate of #5; same figure used twice on page) | Loop mode |
| 7 | `07_loop_mode_normal_padded.png` | `zh-cn_image_0000002531362524` | Loop mode — Normal with per-block padding (not 32 B aligned) | Loop mode |
| 8 | `08_loop_mode_compact.png` | `zh-cn_image_0000002531362522` | Loop mode — Compact (single pad at end of group) | Loop mode |
| 9 | `09_channel_merge_s8_u8_16x16_to_16x32.png` | `zh-cn_image_0000002531522458` | Fixpipe channel merge — S8/U8: 16×16 → 16×32 fractal | Fixpipe |
| 10 | `10_channel_merge_s4_u4_16x16_to_16x64.png` | `zh-cn_image_0000002531362518` | Fixpipe channel merge — S4/U4: 16×16 → 16×64 fractal | Fixpipe |
| 11 | `11_channel_split_fp32_16x16_to_16x8.png` | `zh-cn_image_0000002531522462` | Fixpipe channel split — FP32: 16×16 → 16×8 fractal | Fixpipe |
| 12 | `12_ssbuffer_topology.png` | `zh-cn_image_0000002531522460` | SSBuffer connectivity — AIV↔SSBuf↔AIC and AIV0/AIV1↔SSBuf↔AIC via PIPE_S | SSBuffer |
| 13 | `13_same_core_sync_timeline.png` | `zh-cn_image_0000002531362520` | Same-core sync flow timeline (Vector, MTE2, MTE3 with EventIDs 1-6) | Synchronization |
| 14 | `14_cross_core_sync_modes_0_1_2_4.png` | `zh-cn_image_0000002531522456` | Cross-core sync modes 0/1/2/4 visualization | Cross-core sync |
| 15 | `15_cross_core_setflag_waitflag_flow.png` | `zh-cn_image_0000002531362526` | CrossCoreSetFlag/WaitFlag example flow (L0C→GM→UB via Fixpipe and MTE2) | Cross-core sync |

Total: 556 KB
