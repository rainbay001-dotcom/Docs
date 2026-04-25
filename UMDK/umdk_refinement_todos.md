# UMDK doc-set — refinement TODO list

_Last updated: 2026-04-25._

A consolidated, prioritized worklist of every open-question, deferred-read, gap, and verification step scattered across the 11 docs in this directory. Treat as the working backlog: pick from the top, do the work, update the relevant doc, strike the entry. New items go to the bottom of their category.

**Conventions used below:**

- **Effort:** S (≤30 min), M (1–3 hours), L (multi-session, may need agents).
- **Priority:** P1 (closes a load-bearing gap or correction), P2 (substantive enrichment), P3 (nice-to-have).
- **Source(s)** = where the question was raised. **Target(s)** = which doc(s) will absorb the answer (or "new doc" if a fresh file is justified).
- Each item should end with a one-line **note on success criteria** — what the answer must contain to count as resolved.

---

## 1. Quick wins (P1 / P2, effort S)

These can be knocked out in an hour or two and would tighten the doc set significantly.

### 1.1 Update `umdk_repo_layout.md` to reflect the new doc set
- **Source:** `umdk_repo_layout.md` is labelled "largely superseded" but still has the original-only file list.
- **Target:** the file itself.
- **Effort:** S.
- **Action:** Either merge it into `umdk_architecture_and_workflow.md` and delete the file, or rewrite it as a 1-page jump-table that defers depth to the other docs. Pick one; don't leave it half-superseded.
- **Success:** no contradictions with the post-restructure umdk tree; clear "for X look at Y" pointers.

### 1.2 Verify the speculative `_(unverified line)_` citations in `umdk_kernel_internals_and_udma_hotpath.md`
- **Source:** that doc's UDMA-hot-path section has ~15 citations tagged `_(unverified line)_` from the agent survey.
- **Target:** same doc — replace with verified `:line` numbers or remove the line cite.
- **Effort:** S (`grep` per file).
- **Action:** open each cited file at the claimed line; confirm or correct.
- **Success:** all `_(unverified line)_` markers gone; either replaced with real `:line` or rewritten to cite only file paths.

### 1.3 Confirm "DFX" expansion in UDMA
- **Source:** `umdk_code_followups.md` Q2 — agent suggested "Diagnosis and FiXture", standard semi-industry usage is "Design For X".
- **Target:** `umdk_kernel_internals_and_udma_hotpath.md` §7 + `umdk_code_followups.md` Q2.
- **Effort:** S.
- **Action:** `grep` for any comment block in `drivers/ub/urma/hw/udma/udma_dfx.{c,h}` that expands DFX; check Huawei/HiSilicon kernel driver conventions in adjacent drivers.
- **Success:** one definitive expansion cited from a comment, or a clear "spec/code never expands it; we adopt X" decision.

### 1.4 Sweep doc-set for "UVS" expansion consistency
- **Source:** Three different expansions appear: "Unified Vector Service" (in the spec doc), "User-space Virtual Switch" (agent guess), and "uvs_admin / TPSA replacement" (architecture doc). Spec doc §11 #1 is now marked partial-resolution; the comparison doc and arch doc need to match.
- **Target:** all docs that mention UVS.
- **Effort:** S.
- **Action:** Pick the canonical phrasing — recommend **"UVS (control library; canonical expansion not asserted in repo headers)"** until confirmation lands. Sweep each doc.
- **Success:** every UVS mention uses identical framing; no doc claims a confirmed expansion.

### 1.5 Sanity-check the `udma_u_ops.c:300-312` citation for `g_udma_provider_ops`
- **Source:** `umdk_code_followups.md` Q7.
- **Target:** same.
- **Effort:** S.
- **Action:** verify line range; agent surveys often drift by a few lines.
- **Success:** line range confirmed or corrected.

### 1.6 Clean up the README index for navigability
- **Source:** README has accumulated 11 entries; can be hard to scan.
- **Target:** `README.md`.
- **Effort:** S.
- **Action:** Reorder by reading-path-for-newcomer (start here → spec concepts → code architecture → deep dives → comparisons). Add a "Reading order" note at top. Maybe collapse the "Pending" section under a `<details>` block if rendering supports it.
- **Success:** a first-time reader can pick the right entry point without reading every blurb.

---

## 2. Remaining Chinese-spec chapters to read (P1 / P2, effort L)

The 28 MB Chinese spec is 518 pp; we've read the ToC + §6 / §7 / §10 / §11 / preview. Other chapters that would close real gaps:

### 2.1 §8 Function Layer — URMA / URPC / Multi-Entity coordination / Entity management (pp. 240–258)
- **Why:** Spec-side API surface for URMA. Would let us validate / correct the IB-verbs↔URMA terminology table from the spec's own definitions of jetty / JFS/JFR/JFC / segment / token semantics.
- **Source:** `umdk_spec_deep_dive.md` §6 #3 (deferred); `umdk_spec_survey.md` §11 #1 (partial).
- **Target:** new section in `umdk_spec_deep_dive.md` (§8 added), updates to `umdk_spec_survey.md` §5 (URMA), §6 (URPC), §7 (UMDK component definitions).
- **Effort:** L (≈18 pages to read).
- **Success:** definitive spec-side definition of every URMA primitive; cite-able rule for which verbs are mandatory vs optional; URPC vs Multi-Entity-coordination vs Entity-management distinguished.

### 2.2 §9 Memory Management — UMMU functions + UB Decoder (pp. 259–287)
- **Why:** UMMU is the IOMMU that everything ends up using; the spec's normative behavior for permission check, page-table walk, and Decoder address-translation would deepen the kernel-internals doc and the comparison-doc UMMU row.
- **Source:** `umdk_spec_deep_dive.md` §6 #4.
- **Target:** new §9 in `umdk_spec_deep_dive.md`; updates to `umdk_kernel_internals_and_udma_hotpath.md` §6 (UMMU) and `umdk_architecture_and_workflow.md` §0 + §1.10.
- **Effort:** L (≈28 pages).
- **Success:** spec-defined UMMU table-lookup flow and EE_bits-aware page selection rules cited; UB Decoder's role in user-physical→UB-address translation explained.

### 2.3 §5 Network Layer — NPI + multipath addressing (pp. 136–148)
- **Why:** NPI is the network-partition identifier referenced from §11.3.2. CNA (Compact Network Address — 16/24-bit) format is also here. Would let us write a complete partition story: NPI (network) vs UPI (Entity).
- **Source:** `umdk_spec_deep_dive.md` §6 #1.
- **Target:** new §5 section in spec-deep-dive; updates to §11 partition references; possible row in comparison-doc partition section.
- **Effort:** M (≈13 pages).
- **Success:** NPI bit-format documented; per-packet vs per-flow LB rule cited; CNA encoding cited.

### 2.4 §6.5 Multipath load balancing + §6.6 Congestion control (pp. 184–191)
- **Why:** **C-AQM (Confined AQM)** — Bojie Li's 2023 talk highlighted credit-based, end-to-end congestion control as a UB innovation. We claim it without spec citation. Section §6.6 is where this lives.
- **Source:** `umdk_spec_deep_dive.md` §6 #2; `umdk_web_research_addenda.md` §9 #3.
- **Target:** add §6.5/§6.6 subsections to spec-deep-dive's §1 Transport.
- **Effort:** M (≈8 pages).
- **Success:** C-AQM mechanism (credit issuance, switch-NIC handshake, queue avoidance) described from spec; cited bit-level fields if any.

### 2.5 §10.5 Virtualization + §10.6 RAS (pp. 333–342)
- **Why:** Virtualization story explains UBMEMPFD / vUMMU more authoritatively than code reading alone. RAS underpins UB-Mesh's reliability claims.
- **Source:** `umdk_spec_deep_dive.md` §6 #5.
- **Target:** spec-deep-dive §3 (Resource Mgmt) extension; updates to `umdk_kernel_internals_and_udma_hotpath.md` §5 (UBMEMPFD).
- **Effort:** M (≈10 pages).
- **Success:** spec-side virtualization model (passthrough vs mediated) clarified; RAS layer/event taxonomy cited.

### 2.6 Appendix H URPC Message Format (pp. 512–517)
- **Why:** Definitive bit-level URPC frame layout. Our `umdk_urpc_and_tools.md` Wire-format section §1.3 is from agent reading of `protocol.h` only — the spec is the source of truth.
- **Source:** `umdk_spec_deep_dive.md` §6 #8.
- **Target:** updates to `umdk_urpc_and_tools.md` §1.3.
- **Effort:** S (6 pages).
- **Success:** every header field in the URPC doc cross-checked against spec App. H; mismatches called out and reconciled.

### 2.7 Appendix G Device Hot-Plug (pp. 508–511)
- **Why:** Open question in arch doc §6 #5: hot-remove atomicity. Spec defines the protocol-level hot-plug contract.
- **Source:** `umdk_architecture_and_workflow.md` §6 #5; `umdk_spec_deep_dive.md` §6 #7.
- **Target:** new short section or updates in arch doc §4.7 (Teardown) + spec-deep-dive.
- **Effort:** S (4 pages).
- **Success:** hot-removal vs hot-add flows cited; required event sequence between UBFM, UBPU, and OS captured.

### 2.8 Appendix B Packet Formats + Appendix D Configuration Space Registers (pp. 369–500)
- **Why:** Bit-level reference. Mostly useful when deep-diving HW; not critical for a software reader. But if anyone needs to write a new provider, this is the source of truth.
- **Source:** `umdk_spec_deep_dive.md` §6 #6.
- **Target:** new doc `umdk_wire_formats_reference.md` (or skip and just point to the PDF — likely the right call).
- **Effort:** XL — these are register-table-heavy pages. Consider deferring indefinitely unless a use case appears.
- **Success:** decision recorded ("we don't pull this in; cite the spec PDF directly when needed").

---

## 3. Code reading queue (P1 / P2)

### 3.1 Live-migration story via `ubcore_vtp` (P1)
- **Why:** `ubcore_vtp.c` (virtual-TP) is referenced in arch doc §2.1 but its semantics aren't traced. Live-migration is one of the spec-level RAS use cases.
- **Source:** `umdk_architecture_and_workflow.md` §6 #7; `umdk_kernel_internals_and_udma_hotpath.md` §10 #5; `umdk_code_followups.md` residual #6.
- **Target:** new sub-section in arch doc §2.1 + open-question in `umdk_code_followups.md` resolved.
- **Effort:** M (single Explore agent run).
- **Success:** VTP state machine, INIT/MIGRATE/ROLLBACK transitions, jetty rebinding flow, and any cross-host coordination hooks documented with file:line.

### 3.2 OBMM cross-supernode routing path (P1)
- **Why:** Cache coherence (the §11.4 / kernel-internals §4 row) is solved. But how a remote-supernode access actually routes — UB packets vs UBoE, which kernel function decides — wasn't traced.
- **Source:** `umdk_code_followups.md` residual #3.
- **Target:** `umdk_kernel_internals_and_udma_hotpath.md` §4 (OBMM extension).
- **Effort:** M.
- **Success:** end-to-end data flow for a cross-supernode page-fault (or invalidation) traced from `obmm_import.c` through to the UB transport hand-off.

### 3.3 DCA / HEM removal rationale OLK-5.10 → 6.6 (P2)
- **Why:** Repeatedly flagged across docs. The HW/firmware reason is unknown without Huawei release notes.
- **Source:** `umdk_kernel_internals_and_udma_hotpath.md` §10 #4; `umdk_architecture_and_workflow.md` §6 #1.
- **Target:** kernel-internals doc §7.8.
- **Effort:** S–M; mostly require an external doc / commit log read. Try `git log -- drivers/ub/urma/hw/udma/` in OLK-6.6 for first-commit messages and search Huawei release notes.
- **Success:** even a tentative "removed because HW now has fixed pools sized for max workload" (with cite to a commit message or Huawei doc) is enough.

### 3.4 Bond provider in liburma — multipath policy (P2)
- **Why:** Multipath jetty-group failover is documented at the spec level; userspace policy (hash function, failure-detection cadence, convergence time) is in `bondp_*` files we haven't read.
- **Source:** `umdk_architecture_and_workflow.md` §4.9 (TODO line); §6 #3.
- **Target:** `umdk_architecture_and_workflow.md` §4.9 + `umdk_urpc_and_tools.md` cross-ref.
- **Effort:** M (one focused Explore agent).
- **Success:** specific hash function (e.g. xxh64 of dest+seq?), heartbeat frequency, expected convergence time on TP failure documented.

### 3.5 ipourma per-jetty vs per-CPU scaling (P2)
- **Why:** Open-question on throughput design.
- **Source:** `umdk_architecture_and_workflow.md` §6 #4.
- **Target:** arch doc §2.4.
- **Effort:** S (read `ipourma_netdev.c` jetty alloc).
- **Success:** definitive "one jetty per netdev" or "one per CPU" answer cited.

### 3.6 Two-UMMU-driver split rationale (P3)
- **Why:** `ummu-core` vs `logic_ummu` — agent guessed "abstract vs implementation"; would be nice to confirm.
- **Source:** `umdk_kernel_internals_and_udma_hotpath.md` §10 #6.
- **Target:** kernel-internals §6.
- **Effort:** S.
- **Success:** one-paragraph confirmation; or clear "vendor split for future-proofing" call-out.

### 3.7 UDMA UE-message firmware path (P3)
- **Why:** Code-followups Q1 resolved at the kernel layer (MUE = Management UB Entity) but the on-chip microcontroller side is opaque from openEuler source.
- **Source:** `umdk_code_followups.md` residual #5.
- **Target:** maybe spec deep dive §10 if ever resolved; or a permanent "out-of-scope: firmware blob" note.
- **Effort:** L (likely needs Huawei docs).
- **Success:** decision recorded.

### 3.8 UNIC offload quirks (P3)
- **Why:** Any UB-specific net-stack offloads beyond standard `ethtool -k`?
- **Source:** `umdk_kernel_internals_and_udma_hotpath.md` §10 #8.
- **Target:** kernel-internals §8.
- **Effort:** S (`grep` `ethtool_ops` definition).
- **Success:** any UB-specific feature cited (e.g. UB-aware QoS, segmentation).

### 3.9 CAM ↔ URMA wire-level path verification (P2)
- **Why:** Academic-papers doc §3 says CAM goes via CANN/HCCL underneath. We claim — but never traced — that CANN's UB driver layer ends up calling into ubcore. Worth confirming.
- **Source:** `umdk_cam_dlock_usock.md` §5 #1; `umdk_academic_papers.md` §6 #3.
- **Target:** `umdk_cam_dlock_usock.md` §1.6.
- **Effort:** L — CANN source is split between open and closed pieces; may need a partial reading.
- **Success:** either a direct call-graph (e.g. `hccl → libascend_ub.so → /dev/ub_uburma_*`) or an explicit "we couldn't find the CANN-side; behavior is opaque from openEuler source alone".

### 3.10 dlock max scale + planned HA (P3)
- **Why:** Replica path is stubbed (we know). Saturation point is unknown.
- **Source:** `umdk_cam_dlock_usock.md` §5 #2, #6.
- **Target:** `umdk_cam_dlock_usock.md` §2.
- **Effort:** M; needs a benchmark run or a commit-history read for HA roadmap.
- **Success:** order-of-magnitude scale answer; or pointer to upstream issue/RFP.

### 3.11 UMS performance vs raw TCP (P3)
- **Why:** Practical question for adoption decisions.
- **Source:** `umdk_cam_dlock_usock.md` §5 #4.
- **Target:** `umdk_cam_dlock_usock.md` §3.
- **Effort:** L; would need a real test bed.
- **Success:** at least a published-elsewhere number cited; or "no public benchmarks yet".

---

## 4. Verification + cross-doc consistency (P1 / P2)

### 4.1 Comparison-doc performance cell — sanity check
- **Source:** `umdk_vs_ib_rdma_ethernet.md` §2.6 was updated with CloudMatrix384 numbers (196 GB/s, 1.2 µs); but the IB column ("0.7-1 µs NDR ConnectX-7") is from generic knowledge.
- **Target:** comparison doc §2.6.
- **Effort:** S.
- **Action:** Find a NVIDIA-published or peer-reviewed NDR-class number to cite alongside; rephrase to say "approximate".
- **Success:** every cell either has a citation or is explicitly tagged "approximate, no public benchmark".

### 4.2 Reconcile UVS-naming between spec doc, comparison doc, arch doc, code-followups
- **Source:** see §1.4 above.
- **Effort:** S.
- (Quick win — listed both places intentionally.)

### 4.3 Cross-check every "100+ uburma sub-commands" claim
- **Source:** Architecture doc §2.2 says 101; spec-survey doc says ~100; old earlier draft had ~130.
- **Effort:** S.
- **Action:** `grep -c 'UBURMA_CMD_[A-Z]' drivers/ub/urma/uburma/uburma_cmd.h` — already done once (101). Make sure all docs say "101" or none-too-precise "≈100".
- **Success:** one consistent number across docs.

### 4.4 Verify the kernel-module load-order quotation matches current README
- **Source:** UMDK README is updated frequently (master branch, latest 2026-04-24). Our quote of `ubfi → ummu → ubus → ... → udma` was verified once but may drift.
- **Target:** spec doc §7.3, kernel-internals §9.
- **Effort:** S.
- **Action:** `cd ~/Documents/Repo/ub-stack/umdk && git pull && grep -n insmod README.md`.
- **Success:** load-order quote matches HEAD; if not, update.

### 4.5 Code-followups Q1 historical — keep or refactor
- **Source:** Code-followups Q1 has been amended; original "UE = User Engine" (agent claim) is now flagged as superseded by spec reading. Decide whether to leave it as a learning record or rewrite cleanly.
- **Effort:** S.
- **Action:** Recommend leaving it as-is — visible record of how an answer evolved is useful; just make sure the "current authoritative" is unambiguous.

### 4.6 Sweep for stale "TODO" / "(unverified)" / "(confirm)" markers
- **Source:** organic accumulation across docs.
- **Effort:** S.
- **Action:** `grep -rn -i 'TODO\|unverified\|(confirm)\|TBD\|FIXME' UMDK/`. For each match, decide: resolved (delete marker), still-pending (move to this doc), permanently unanswerable (replace with explicit "out of scope").
- **Success:** no more orphan markers.

---

## 5. Web research follow-ups (P2 / P3)

### 5.1 LWN.net targeted re-search
- **Source:** `umdk_web_research_addenda.md` §1.5 — direct LWN search yielded no UB-specific articles via WebFetch (UI-only page).
- **Effort:** S.
- **Action:** Try Google-search-restricted-to-LWN: `site:lwn.net "URMA" OR "ubcore" OR "UnifiedBus"`. Also check `lwn.net/Search` directly via browser if WebFetch fails.
- **Success:** any LWN article found and summarized; or "still none" recorded with date.

### 5.2 lore.kernel.org thread fetch — alternate paths
- **Source:** Same — Anubis bot-protection blocked WebFetch.
- **Effort:** S.
- **Action:** Try `gh api` with the lore.kernel.org repo (some lists mirror to GitHub), or try the openEuler `mailweb.openeuler.org` Hyperkitty interface directly.
- **Success:** at least one substantive ubcore/URMA discussion captured.

### 5.3 UB OS Component repo location
- **Source:** Huawei announced "UB OS Component" as open-source for upstream openEuler import; specific repo URL unknown.
- **Source-doc:** `umdk_web_research_addenda.md` §9 #4.
- **Effort:** S.
- **Action:** Search `gitee.com/openeuler/`, `gitcode.com/openeuler/`, and openEuler doc center for "UB OS Component". May just be an alias for `drivers/ub/` we already have.
- **Success:** repo URL recorded or alias confirmed.

### 5.4 Bojie Li 2023 talk — "Orchestrator engine" follow-up
- **Source:** `umdk_web_research_addenda.md` §3 mentions an "Orchestrator" programmable engine; not visible in current `drivers/ub/`. Possibly renamed (UVS? UBFM?), dropped, or held back.
- **Effort:** M.
- **Action:** Read the 2023 talk slides (linked from Bojie Li post) for more context; cross-search openEuler kernel for similar names; check if it became part of UVS or UBFM.
- **Success:** Orchestrator's status (renamed-to-X / dropped / not-public) determined.

### 5.5 NCCL/RCCL public-numbers comparison
- **Source:** Comparison doc §2.6 needs comparable IB / RoCE numbers.
- **Effort:** S.
- **Action:** Find official NVIDIA NCCL allreduce or NDR ConnectX-7 latency benchmarks; cite.
- **Success:** comparison doc has at least one peer-cited NCCL/IB number.

### 5.6 Huawei CloudMatrix reliability story (currently absent from paper)
- **Source:** `umdk_academic_papers.md` §2.9 — paper omits this; flagged.
- **Effort:** L.
- **Action:** Search Huawei whitepapers, Huawei Connect 2025/2026 follow-ups, openEuler community posts.
- **Success:** any concrete reliability data point for a 384-NPU supernode cited; or "still unpublished" recorded with date.

---

## 6. New-doc proposals (P3)

Hold off on these unless a concrete need arises — extending an existing doc is usually preferable.

### 6.1 `umdk_wire_formats_reference.md`
- **Why:** Bit-level packet header layouts (transport headers, UPIH, EIDH, BTAH, ATAH, RTPH, NTH).
- **When justified:** if anyone starts writing a new HW provider or a packet decoder.
- **Source:** §2.8 above.

### 6.2 `umdk_glossary.md`
- **Why:** A consolidated glossary; current terminology is split across spec_survey §10, vs_ib_rdma_ethernet §1, spec_deep_dive ad-hoc.
- **When justified:** when the doc set crosses 15 files or a reader explicitly asks "where do I look up term X".

### 6.3 `umdk_getting_started.md`
- **Why:** Entry-point doc walking a newcomer through "I have an Ascend SuperPoD, what do I install + run to do my first URMA send".
- **When justified:** if anyone outside this team needs to onboard.

### 6.4 `umdk_zh.md` translations
- **Why:** Other dirs in this repo (linux-memory-compression/) follow an EN+ZH bilingual pattern. UMDK is currently EN-only.
- **When justified:** when at least the spec-survey or comparison docs stabilize.

### 6.5 `umdk_changelog.md`
- **Why:** This doc set has churned a lot. A changelog organized by date would help future-readers see what was true when.
- **When justified:** if doc-set growth slows; right now the diary at `~/Documents/diary/` serves the same purpose.

---

## 7. Permanent-out-of-scope items

These are dead-ends — record the decision and stop trying.

### 7.1 `ipver=609` definition
- **Status:** confirmed not in public openEuler tree. Lives in vendor HAL / firmware blob. Stop searching; cite as "vendor-internal" in any future mention.
- **Source:** `umdk_code_followups.md` Q3 + residual #1; multiple other docs.

### 7.2 CAM CMake `add_kernels_compile()` macro definition
- **Status:** confirmed not in public umdk tree (lives in parent CMake outside the dir). Cite as "build orchestration in private/parent CMake".
- **Source:** `umdk_code_followups.md` Q9 + residual #2.

### 7.3 Architecture doc §2.5 ipver=609 follow-up
- **Source:** kernel-internals §10 #1 still phrased as "to confirm in `drivers/ub/ubus/vendor/hisi/`".
- **Action:** Update that line to "vendor-internal — stop searching" instead. Quick win — fold into §1.6 README cleanup.

---

## 8. How to use this list

**Workflow.**

1. Pick a P1 quick-win from §1, do it, push, strike the entry. Repeat until §1 is empty or you've done 3.
2. Pick at most one P1 from §2/§3 per session. They're each multi-hour.
3. Use the agent pattern — for code reads (§3) prefer `Explore` agents with the prompt scoped to the specific question; for spec reads (§2) do them yourself in 20-page Read chunks.
4. **Always** end a session with: which doc(s) absorbed the result, push, strike.

**Order recommended for next session.**

If you've got an hour:
1. §1.6 (README cleanup) — quick win, improves discoverability.
2. §1.4 (UVS naming sweep) — quick win, removes a small inconsistency.
3. §4.6 (TODO sweep) — quick win, makes this list authoritative.

If you've got a half-day:
1. §3.1 (live-migration trace) — closes a P1 hole, single agent call.
2. §2.1 (Chinese spec §8 Function Layer) — biggest doc-quality return per page.

If you've got a full day:
1. §2.1 + §2.2 + §2.4 (Function Layer + Memory Mgmt + Congestion Control) — closes the spec story for everything we currently document.

---

## 9. Removed entries (for traceability)

When an entry is fully resolved, move it here with date + one-line summary. Keeps a permanent record without bloating the active list.

_(empty as of doc creation 2026-04-25)_

---

_Companion: every other doc in this directory. Update this file whenever an answer lands; keep the active list ≤30 entries to stay scannable._
