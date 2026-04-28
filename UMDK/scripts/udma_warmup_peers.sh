#!/bin/bash
# udma_warmup_peers.sh — pull peer EIDs from UBSE and push them to the
#   udma kernel module's TP-list warmup parameter.
#
# Prereqs:
#   - UBSE daemon running and the local node has joined the cluster
#   - udma kernel module loaded (with the codex/udma-tp-cache patch)
#   - root (writes to /sys/module/udma/parameters/*)
#   - ubsectl in PATH
#
# Companion doc: ../umdk_udma_warmup_deployment.md
#
# Environment variables (all optional):
#   UDMA_WARMUP_DRY_RUN=1            print what would be written, do not write
#   UDMA_WARMUP_VERBOSE=1            chatty output
#   UDMA_WARMUP_ENABLE_CACHE=1       (default 1) also set udma_tp_cache_enable=1
#   UDMA_WARMUP_ENABLE_WARMUP=1      (default 1) also set udma_tp_warmup_enable=1
#   UDMA_WARMUP_INCLUDE_LOCAL=0      (default 0) include local node EID (debug)
#   UDMA_SYSFS_BASE=/sys/module/udma/parameters   override for testing
#   UBSECTL=ubsectl                  override the ubsectl binary path

set -euo pipefail

# ----- defaults -----
: "${UDMA_WARMUP_DRY_RUN:=0}"
: "${UDMA_WARMUP_VERBOSE:=0}"
: "${UDMA_WARMUP_ENABLE_CACHE:=1}"
: "${UDMA_WARMUP_ENABLE_WARMUP:=1}"
: "${UDMA_WARMUP_INCLUDE_LOCAL:=0}"
: "${UDMA_SYSFS_BASE:=/sys/module/udma/parameters}"
: "${UBSECTL:=ubsectl}"

PROG="udma_warmup_peers"

log()  { echo "[$PROG] $*" >&2; }
vlog() { [ "$UDMA_WARMUP_VERBOSE" = "1" ] && log "$*" || true; }
die()  { log "ERROR: $*"; exit 1; }

# ----- preflight -----
command -v "$UBSECTL" >/dev/null 2>&1 \
    || die "ubsectl not found in PATH (set UBSECTL=...)"

if [ ! -d "$UDMA_SYSFS_BASE" ]; then
    die "udma module sysfs not present at $UDMA_SYSFS_BASE — is the module loaded?"
fi

if [ ! -f "$UDMA_SYSFS_BASE/udma_tp_warmup_peer_eids" ]; then
    die "udma_tp_warmup_peer_eids parameter not found — needs codex/udma-tp-cache patch"
fi

if [ "$UDMA_WARMUP_DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root to write sysfs (or set UDMA_WARMUP_DRY_RUN=1)"
fi

# ----- discover local slot id -----
# `ubsectl display node` (no -n) shows the local node row.
# Output sample:
#   computer01(1)         master   4245:4944:...   CC08-A000-...
LOCAL_SLOT=""
if [ "$UDMA_WARMUP_INCLUDE_LOCAL" != "1" ]; then
    LOCAL_SLOT=$("$UBSECTL" display node 2>/dev/null | awk '
        /^[A-Za-z]/ && $1 ~ /\([0-9]+\)/ {
            if (match($1, /\(([0-9]+)\)/, m)) { print m[1]; exit }
        }
    ' || true)
    if [ -z "$LOCAL_SLOT" ]; then
        log "WARN: could not determine local slot from \`$UBSECTL display node\` — peer list will include all nodes"
    else
        vlog "local slot id = $LOCAL_SLOT"
    fi
fi

# ----- pull cluster list and extract peer bonding-EIDs -----
CLUSTER_OUT=$("$UBSECTL" display cluster 2>&1) || \
    die "ubsectl display cluster failed: $CLUSTER_OUT"

# Bail clearly on UBSE-down case.
if echo "$CLUSTER_OUT" | grep -qE "Failed to obtain cluster information|Internal error"; then
    die "UBSE returned cluster error: $(echo "$CLUSTER_OUT" | head -3 | tr '\n' ' ')"
fi

# Sample row format (after header):
#   computer01(1)   master   4245:4944:0000:0000:0000:0000:0100:0000   CC08-A000-...
# Bonding-EID may be "-" if UBSE info is missing for that node.
PEER_EIDS=$(echo "$CLUSTER_OUT" | awk -v skip="$LOCAL_SLOT" '
    /^[A-Za-z]/ && $1 ~ /\([0-9]+\)/ {
        # extract slot from "host(N)"
        if (!match($1, /\(([0-9]+)\)/, m)) next
        slot = m[1]
        if (skip != "" && slot == skip) next
        eid = $3
        if (eid == "-" || eid == "") next
        gsub(":", "", eid)
        # validate 32 hex chars
        if (length(eid) != 32) next
        if (eid !~ /^[0-9a-fA-F]+$/) next
        printf "%s0x%s", (n++ ? "," : ""), eid
    }
    END { if (n) print "" }
')

if [ -z "$PEER_EIDS" ]; then
    log "no peer EIDs derived from cluster (cluster has only local node, or UBSE missing peer data)"
    log "leaving udma_tp_warmup_peer_eids unchanged"
    exit 0
fi

# Count peers for the summary line.
PEER_CNT=$(awk -F, '{print NF}' <<<"$PEER_EIDS")

# ----- write -----
write_param() {
    local name="$1" value="$2"
    local path="$UDMA_SYSFS_BASE/$name"
    if [ "$UDMA_WARMUP_DRY_RUN" = "1" ]; then
        log "DRY-RUN would set $name = $value"
    else
        printf "%s\n" "$value" > "$path" \
            || die "failed to write $path"
        vlog "$name = $(cat "$path")"
    fi
}

write_param udma_tp_warmup_peer_eids "$PEER_EIDS"
[ "$UDMA_WARMUP_ENABLE_CACHE"  = "1" ] && write_param udma_tp_cache_enable  1
[ "$UDMA_WARMUP_ENABLE_WARMUP" = "1" ] && write_param udma_tp_warmup_enable 1

log "set $PEER_CNT peer EID(s)$([ "$UDMA_WARMUP_DRY_RUN" = "1" ] && echo ' (dry-run)')"
exit 0
