#!/usr/bin/env bash
set -euo pipefail

# gpu-guard: kill GPU processes squatting on GPUs Slurm hasn't allocated on this node.

DRY_RUN="${DRY_RUN:-0}"        # DRY_RUN=1 -> log only, never kill (use this first!)
SIGNAL="${SIGNAL:-TERM}"       # TERM by default; set SIGNAL=KILL to be forceful
NODE="$(hostname -s)"          # scontrol usually keys on the SHORT hostname
LOG_TAG="gpu-guard"

log() { logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }

# --- Step 2: which GPU indices has Slurm allocated on this node? -------------
# --oneliner collapses the record to one line; -d gives the detailed GresUsed.
if ! node_line="$(scontrol show node "$NODE" -d --oneliner 2>/dev/null)"; then
  log "ERROR: scontrol failed for node '$NODE'; aborting without killing anything."
  exit 1
fi

# Pull every IDX:... list out of GresUsed=gpu:<type>:<n>(IDX:....)
# \K drops everything before the capture; handles multiple gres lines if present.
declare -A allowed=()
while IFS= read -r idxlist; do
  [[ -z "$idxlist" || "$idxlist" == "N/A" ]] && continue   # IDX:N/A == nothing allocated
  IFS=',' read -ra parts <<<"$idxlist"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then                             # expand ranges like 0-2
      for ((i=${p%-*}; i<=${p#*-}; i++)); do allowed["$i"]=1; done
    else
      allowed["$p"]=1
    fi
  done
done < <(grep -oP 'GresUsed=gpu:[^(]*\(IDX:\K[^)]*' <<<"$node_line" || true)

log "Slurm-allocated GPU indices on $NODE: [${!allowed[*]}]"

# --- Step 1: map GPU UUID -> index, then list running compute apps ----------
# query-compute-apps doesn't reliably expose the GPU *index*, only the UUID,
# so we build a UUID->index map from query-gpu and join on it.
declare -A uuid2idx=()
while IFS=, read -r idx uuid; do
  uuid2idx["${uuid// /}"]="${idx// /}"
done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)

# --- Step 3: kill anything on a GPU that isn't in the allowed set -----------
declare -A kill_pids=()
while IFS=, read -r pid uuid; do
  pid="${pid// /}"; uuid="${uuid// /}"
  [[ -z "$pid" || "$pid" == "[N/A]" ]] && continue
  gidx="${uuid2idx[$uuid]:-?}"
  if [[ -z "${allowed[$gidx]:-}" ]]; then
    kill_pids["$pid"]="$gidx"                              # dedupe: pid may span GPUs
  fi
done < <(nvidia-smi --query-compute-apps=pid,gpu_uuid --format=csv,noheader)

if ((${#kill_pids[@]} == 0)); then
  log "No rogue GPU processes found."
  exit 0
fi

for pid in "${!kill_pids[@]}"; do
  gidx="${kill_pids[$pid]}"
  comm="$(ps -o comm= -p "$pid" 2>/dev/null || echo '?')"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would SIG$SIGNAL pid=$pid ($comm) on unallocated GPU $gidx"
  else
    log "Killing pid=$pid ($comm) on unallocated GPU $gidx with SIG$SIGNAL"
    kill -s "$SIGNAL" "$pid" 2>/dev/null || log "  kill failed for $pid (already gone / no perms)"
  fi
done
