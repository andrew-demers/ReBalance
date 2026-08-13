#!/bin/bash
##############################################################################
# ReBalance - Unraid Array Disk Usage Balancer
# Moves files from over-used disks to under-used disks to equalise usage %.
#
# Usage:
#   rebalance.sh [--tolerance N] [--dry-run] [--use-cache] [--cache-buffer KB] [--stop]
##############################################################################

STATUS_FILE="/tmp/rebalance_status.json"
LOCK_FILE="/tmp/rebalance.lock"
LOG_FILE="/var/log/rebalance.log"
LOG_MAX=500

TOLERANCE=2
DRY_RUN=false
USE_CACHE=false
CACHE_BUFFER_KB=104857600   # 100 GB default staging budget (KB); overridden by --cache-buffer
STAGE_DIR=""             # set via --stage-dir; auto-detected if empty
MIN_FILE_KB=0            # 0 = no filter; >0 skips files smaller than N KB

##############################################################################
# Argument parsing
##############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true ;;
        --tolerance)    TOLERANCE="${2:-2}"; shift ;;
        --use-cache)    USE_CACHE=true ;;
        --cache-buffer) CACHE_BUFFER_KB="${2:-102400}"; shift ;;
        --stage-dir)    STAGE_DIR="${2}"; shift ;;
        --min-file-kb)  MIN_FILE_KB="${2:-0}"; shift ;;
        --stop)
            if [[ -f "$LOCK_FILE" ]]; then
                pid=$(cat "$LOCK_FILE")
                kill "$pid" 2>/dev/null && echo "Stopped PID $pid" || echo "Process not running"
            else
                echo "Not running"
            fi
            exit 0
            ;;
    esac
    shift
done

# If no --stage-dir supplied, auto-detect the cache pool from Unraid's disk info
if [[ -z "$STAGE_DIR" ]]; then
    _cache_name=$(awk -F= '/^name=/{n=$2} /^type=Cache/{print n; exit}' \
        /var/local/emhttp/disks.ini 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$_cache_name" && -d "/mnt/$_cache_name" ]]; then
        STAGE_DIR="/mnt/${_cache_name}/.rebalance_stage"
    else
        STAGE_DIR="/mnt/cache/.rebalance_stage"
    fi
fi

##############################################################################
# Singleton lock
##############################################################################
if [[ -f "$LOCK_FILE" ]]; then
    existing=$(cat "$LOCK_FILE")
    if kill -0 "$existing" 2>/dev/null; then
        echo "Already running (PID $existing)"
        exit 1
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

##############################################################################
# Global state
##############################################################################
STATE="starting"
START_TIME=$(date +%s)
TARGET_PCT=0

# Disk tables (keyed by disk name e.g. "disk1")
declare -A D_SIZE    # total KB
declare -A D_USED    # used KB
declare -A D_FREE    # free KB
declare -A D_PCT     # integer usage %
declare -A D_MOUNT   # mount path
DISKS=()             # ordered list of disk names

# Plan (parallel arrays, index 0..P_COUNT-1)
declare -a P_STATUS P_SIZE P_SRC P_DST
P_COUNT=0

# Planning progress (which source disk we are currently scanning)
PLAN_SRC_INDEX=0
PLAN_SRC_COUNT=0

# Execution stats
FILES_TOTAL=0
FILES_DONE=0
FILES_SKIPPED=0
BYTES_TOTAL=0    # KB
BYTES_DONE=0     # KB
RATE_KBS=0
ETA_SEC=0
CURRENT_FILE=""

# Log ring buffer
LOG_MSGS=()

##############################################################################
# Cleanup on exit / signal
##############################################################################
_on_exit() {
    [[ "$STATE" == "running" || "$STATE" == "planning" ]] && STATE="stopped"
    CURRENT_FILE=""
    write_status
    # Clean up any files left in the cache staging area
    $USE_CACHE && [[ -d "$STAGE_DIR" ]] && rm -rf "$STAGE_DIR" 2>/dev/null
    rm -f "$LOCK_FILE"
}
trap _on_exit EXIT
trap 'STATE="stopped"; _on_exit; exit 0' SIGTERM SIGINT

##############################################################################
# Utility functions
##############################################################################

log() {
    local ts msg="$*"
    ts=$(date '+%H:%M:%S')
    LOG_MSGS+=("${ts}|${msg}")
    (( ${#LOG_MSGS[@]} > LOG_MAX )) && LOG_MSGS=("${LOG_MSGS[@]:50}")
    echo "[$ts] $msg" >&2
    printf '%s [PID %d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$msg" >> "$LOG_FILE" 2>/dev/null
}

# JSON-encode a string (outputs with surrounding double-quotes)
jstr() {
    local s="$*"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

fmt_kb() {
    local kb=$1
    if   (( kb >= 1073741824 )); then printf '%d TB' "$(( kb / 1073741824 ))"
    elif (( kb >= 1048576 ));    then printf '%d GB' "$(( kb / 1048576 ))"
    elif (( kb >= 1024 ));       then printf '%d MB' "$(( kb / 1024 ))"
    else printf '%d KB' "$kb"
    fi
}

is_in_use() {
    local f="$1"
    if command -v fuser >/dev/null 2>&1; then
        fuser -s "$f" 2>/dev/null && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof "$f" >/dev/null 2>&1 && return 0
    fi
    return 1
}

##############################################################################
# Status JSON writer (atomic via temp file)
##############################################################################
write_status() {
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - START_TIME ))

    # --- disks JSON ---
    local dj="["
    local dfirst=true
    for d in "${DISKS[@]}"; do
        local role="balanced"
        (( D_PCT[$d] > TARGET_PCT + TOLERANCE )) && role="source"
        (( D_PCT[$d] < TARGET_PCT - TOLERANCE )) && role="destination"
        $dfirst || dj+=","
        dfirst=false
        dj+="{\"name\":\"${d}\",\"mount\":$(jstr "${D_MOUNT[$d]}"),\"size_kb\":${D_SIZE[$d]},\"used_kb\":${D_USED[$d]},\"free_kb\":${D_FREE[$d]},\"pct\":${D_PCT[$d]},\"role\":\"${role}\"}"
    done
    dj+="]"

    # --- log JSON (last 100 entries) ---
    local lj="["
    local lfirst=true
    local lstart=$(( ${#LOG_MSGS[@]} > 100 ? ${#LOG_MSGS[@]} - 100 : 0 ))
    for (( li=lstart; li<${#LOG_MSGS[@]}; li++ )); do
        local entry="${LOG_MSGS[$li]}"
        local lt="${entry%%|*}"
        local lm="${entry#*|}"
        $lfirst || lj+=","
        lfirst=false
        lj+="{\"t\":$(jstr "$lt"),\"m\":$(jstr "$lm")}"
    done
    lj+="]"

    # --- plan JSON (first 300 entries) ---
    local pj="["
    local pjfirst=true
    local plimit=$(( P_COUNT < 300 ? P_COUNT : 300 ))
    for (( pi=0; pi<plimit; pi++ )); do
        $pjfirst || pj+=","
        pjfirst=false
        pj+="{\"s\":$(jstr "${P_STATUS[$pi]}"),\"kb\":${P_SIZE[$pi]},\"src\":$(jstr "${P_SRC[$pi]}"),\"dst\":$(jstr "${P_DST[$pi]}")}"
    done
    pj+="]"

    local pct_done=0
    (( BYTES_TOTAL > 0 )) && pct_done=$(( BYTES_DONE * 100 / BYTES_TOTAL ))

    # --- cache staging stats ---
    local stage_kb=0
    $USE_CACHE && [[ -d "$STAGE_DIR" ]] && \
        stage_kb=$(du -sk "$STAGE_DIR" 2>/dev/null | awk '{print $1}')
    stage_kb=${stage_kb:-0}

    local tmp
    tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
    cat > "$tmp" <<EOF
{
  "state": "${STATE}",
  "dry_run": ${DRY_RUN},
  "use_cache": ${USE_CACHE},
  "cache_buffer_kb": ${CACHE_BUFFER_KB},
  "cache_staged_kb": ${stage_kb},
  "tolerance": ${TOLERANCE},
  "target_pct": ${TARGET_PCT},
  "elapsed_sec": ${elapsed},
  "current_file": $(jstr "${CURRENT_FILE}"),
  "stats": {
    "files_total": ${FILES_TOTAL},
    "files_done": ${FILES_DONE},
    "files_skipped": ${FILES_SKIPPED},
    "bytes_total_kb": ${BYTES_TOTAL},
    "bytes_done_kb": ${BYTES_DONE},
    "pct_done": ${pct_done},
    "rate_kbs": ${RATE_KBS},
    "eta_sec": ${ETA_SEC}
  },
  "plan_count": ${P_COUNT},
  "planning_disk_index": ${PLAN_SRC_INDEX},
  "planning_disk_count": ${PLAN_SRC_COUNT},
  "disks": ${dj},
  "plan": ${pj},
  "log": ${lj}
}
EOF
    mv "$tmp" "$STATUS_FILE"
}

##############################################################################
# Disk discovery
##############################################################################
discover_disks() {
    log "Discovering data disks..."
    DISKS=()

    # Use version sort so disk10 comes after disk9
    while IFS= read -r mp; do
        [[ -d "$mp" ]] || continue
        mountpoint -q "$mp" 2>/dev/null || continue

        local name
        name=$(basename "$mp")
        read -r size used free _ <<< "$(df -k "$mp" 2>/dev/null | awk 'NR==2{print $2,$3,$4}')"
        [[ -z "$size" || "$size" -eq 0 ]] && continue

        D_SIZE[$name]=$size
        D_USED[$name]=$used
        D_FREE[$name]=$free
        D_PCT[$name]=$(( used * 100 / size ))
        D_MOUNT[$name]=$mp
        DISKS+=("$name")
    done < <(ls -dv /mnt/disk[0-9]* 2>/dev/null)

    log "Found ${#DISKS[@]} data disks"
}

##############################################################################
# Target percentage calculation
##############################################################################
calc_target() {
    local total_size=0 total_used=0
    for d in "${DISKS[@]}"; do
        (( total_size += D_SIZE[$d] ))
        (( total_used += D_USED[$d] ))
    done
    (( total_size > 0 )) && TARGET_PCT=$(( total_used * 100 / total_size )) || TARGET_PCT=0
    log "Target: ${TARGET_PCT}%  |  Tolerance: ±${TOLERANCE}%"
}

##############################################################################
# Plan builder
##############################################################################
build_plan() {
    STATE="planning"
    write_status

    P_COUNT=0
    P_STATUS=(); P_SIZE=(); P_SRC=(); P_DST=()
    FILES_TOTAL=0; BYTES_TOTAL=0

    # Identify source disks (above target + tolerance), sort by pct DESC
    local sources=()
    for d in "${DISKS[@]}"; do
        (( D_PCT[$d] > TARGET_PCT + TOLERANCE )) && sources+=("$d")
    done

    IFS=$'\n' sources=($(
        for d in "${sources[@]}"; do echo "${D_PCT[$d]} $d"; done | sort -rn | awk '{print $2}'
    ))
    unset IFS

    if [[ ${#sources[@]} -eq 0 ]]; then
        log "All disks are within ±${TOLERANCE}% of target. Nothing to do."
        return 0
    fi

    PLAN_SRC_COUNT=${#sources[@]}
    PLAN_SRC_INDEX=0
    log "Disks needing reduction: ${sources[*]}"

    for src in "${sources[@]}"; do
        [[ -z "${D_MOUNT[$src]}" ]] && continue
        local src_mp="${D_MOUNT[$src]}"
        local need_kb=$(( (D_PCT[$src] - TARGET_PCT) * D_SIZE[$src] / 100 ))
        (( PLAN_SRC_INDEX++ ))
        log "Scanning ${src} (${D_PCT[$src]}%, need to shed ~$(fmt_kb $need_kb))..."
        write_status

        local planned_kb=0
        local file_count=0
        local size_opt=""
        (( MIN_FILE_KB > 0 )) && size_opt="-size +${MIN_FILE_KB}k"

        while IFS=$'\t' read -r fsize_b fpath; do
            # Stop if this source disk is now within tolerance
            (( D_PCT[$src] <= TARGET_PCT + TOLERANCE )) && break

            local fsize_kb=$(( fsize_b / 1024 ))
            (( fsize_kb == 0 )) && fsize_kb=1

            # Derive the relative path and share name
            local rel="${fpath#${src_mp}/}"
            local share="${rel%%/*}"
            # Skip files directly in the mount root (no share dir)
            [[ -z "$share" || "$share" == "$rel" ]] && continue

            # Find best destination: lowest pct that can accept this file
            local best="" best_pct=9999
            for dst in "${DISKS[@]}"; do
                [[ "$dst" == "$src" ]] && continue
                # Only send to disks that are below target + tolerance
                (( D_PCT[$dst] >= TARGET_PCT + TOLERANCE )) && continue
                # Must have room
                (( D_FREE[$dst] < fsize_kb )) && continue
                # Would it stay within tolerance after receiving the file?
                local new_pct=$(( (D_USED[$dst] + fsize_kb) * 100 / D_SIZE[$dst] ))
                (( new_pct > TARGET_PCT + TOLERANCE )) && continue
                # Pick lowest current pct (most free relatively)
                (( D_PCT[$dst] < best_pct )) && { best="$dst"; best_pct="${D_PCT[$dst]}"; }
            done

            [[ -z "$best" ]] && continue

            local dst_path="${D_MOUNT[$best]}/${rel}"
            P_STATUS[$P_COUNT]="pending"
            P_SIZE[$P_COUNT]=$fsize_kb
            P_SRC[$P_COUNT]="$fpath"
            P_DST[$P_COUNT]="$dst_path"
            (( P_COUNT++ ))

            # Update virtual disk state
            (( D_USED[$src] -= fsize_kb ))
            (( D_FREE[$src] += fsize_kb ))
            D_PCT[$src]=$(( D_USED[$src] * 100 / D_SIZE[$src] ))
            (( D_USED[$best] += fsize_kb ))
            (( D_FREE[$best] -= fsize_kb ))
            D_PCT[$best]=$(( D_USED[$best] * 100 / D_SIZE[$best] ))

            (( planned_kb  += fsize_kb ))
            (( BYTES_TOTAL += fsize_kb ))
            (( FILES_TOTAL++ ))
            (( file_count++ ))

            # Periodic status update
            (( file_count % 200 == 0 )) && write_status

        done < <(find "${src_mp}/" -type f ${size_opt} ! -path "*/lost+found/*" -printf '%s\t%p\n' 2>/dev/null)

        log "  ${src}: planned $(fmt_kb $planned_kb) to move"
    done

    FILES_TOTAL=$P_COUNT
    log "Plan complete: ${P_COUNT} files, $(fmt_kb $BYTES_TOTAL) total"
    write_status
}

##############################################################################
# Cache space check helper
##############################################################################
_cache_has_space() {
    local needed_kb="$1"
    # Check against configured buffer ceiling
    local used_kb
    used_kb=$(du -sk "$STAGE_DIR" 2>/dev/null | awk '{print $1}')
    used_kb=${used_kb:-0}
    (( used_kb + needed_kb > CACHE_BUFFER_KB )) && return 1
    # Check actual free bytes on the cache pool
    local free_kb
    free_kb=$(df -k "$STAGE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$free_kb" ]] && return 0
    (( free_kb < needed_kb + 2048 )) && return 1
    return 0
}

##############################################################################
# Rate / ETA update helper (shared by both executors)
##############################################################################
_update_rate() {
    # args: now rate_t0_varname rate_b0_varname
    local now="$1"
    local -n _rt0=$2 _rb0=$3
    local elapsed=$(( now - START_TIME ))
    if (( elapsed > 0 && BYTES_DONE > 0 )); then
        local window=$(( now - _rt0 ))
        if (( window >= 30 )); then
            (( window > 0 )) && RATE_KBS=$(( (BYTES_DONE - _rb0) / window ))
            if (( window >= 60 )); then _rt0=$now; _rb0=$BYTES_DONE; fi
        else
            RATE_KBS=$(( BYTES_DONE / elapsed ))
        fi
        (( RATE_KBS > 0 )) && ETA_SEC=$(( (BYTES_TOTAL - BYTES_DONE) / RATE_KBS )) || ETA_SEC=0
    fi
}

##############################################################################
# Cache-assisted executor
#
# Pipeline: while file[i] is being written to the dest disk (parity write),
# file[i+1] is being read from a source disk into the SSD cache (no parity).
# The two operations run on different physical devices with no contention,
# giving ~1.5-1.75× real-world speedup for large files.
##############################################################################
execute_plan_cached() {
    [[ $P_COUNT -eq 0 ]] && return

    log "Cache-assisted mode — buffer: $(fmt_kb $CACHE_BUFFER_KB), staging: $STAGE_DIR"
    mkdir -p "$STAGE_DIR"

    local rate_t0=$START_TIME rate_b0=0 last_write=0
    # Pre-stage state for the lookahead background job
    local pre_pid="" pre_src="" pre_staged=""

    for (( i=0; i<P_COUNT; i++ )); do
        [[ "$STATE" != "running" ]] && break
        [[ "${P_STATUS[$i]}" != "pending" ]] && continue

        local size_kb="${P_SIZE[$i]}"
        local src="${P_SRC[$i]}"
        local dst="${P_DST[$i]}"
        local dst_dir; dst_dir=$(dirname "$dst")

        # Derive staging path from source path
        local disk_name="${src#/mnt/}"; disk_name="${disk_name%%/*}"
        local rel="${src#/mnt/$disk_name/}"
        local staged="$STAGE_DIR/$rel"
        local staged_dir; staged_dir=$(dirname "$staged")

        CURRENT_FILE="$src"

        # ── Step 1: Ensure this file is in the staging area ────────────────
        if [[ "$pre_src" == "$src" && -n "$pre_pid" ]]; then
            # Already being staged by the background lookahead job — wait for it
            wait "$pre_pid"; local rc=$?
            pre_pid=""; pre_src=""; pre_staged=""
            if [[ $rc -ne 0 || ! -f "$staged" ]]; then
                log "ERROR: pre-stage failed — $(basename "$src")"
                P_STATUS[$i]="error"; (( FILES_SKIPPED++ )); continue
            fi
        else
            # Not pre-staged; do it now (blocking)
            if [[ ! -f "$src" ]]; then
                log "SKIP (gone): $src"
                P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
            fi
            if is_in_use "$src"; then
                log "SKIP (in use): $(basename "$src")"
                P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
            fi
            if ! _cache_has_space "$size_kb"; then
                log "WARN: cache buffer full — moving $(basename "$src") directly"
                # Fall back to direct move for this file
                mkdir -p "$dst_dir"
                local adf; adf=$(df -k "$dst_dir" 2>/dev/null | awk 'NR==2{print $4}')
                if [[ -n "$adf" && "$adf" -lt "$size_kb" ]]; then
                    log "SKIP (no space on dest): $(basename "$src")"
                    P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
                fi
                P_STATUS[$i]="moving"

                local base_done=$BYTES_DONE rc="" err_line=""
                while IFS= read -r line; do
                    if [[ "$line" == __RC:* ]]; then
                        rc="${line#__RC:}"
                    elif [[ "$line" =~ ([0-9]{1,3})% ]]; then
                        local fpct="${BASH_REMATCH[1]}"
                        (( fpct > 100 )) && fpct=100
                        BYTES_DONE=$(( base_done + size_kb * fpct / 100 ))
                        local now; now=$(date +%s)
                        if (( now - last_write >= 3 )); then
                            _update_rate "$now" rate_t0 rate_b0
                            last_write=$now; write_status
                        fi
                    else
                        err_line="$line"
                    fi
                done < <(
                    { rsync -aX --remove-source-files --info=progress2 "$src" "$dst_dir/" 2>&1; printf '__RC:%d\n' "$?"; } | tr '\r' '\n'
                )

                if [[ "$rc" == "0" ]]; then
                    BYTES_DONE=$(( base_done + size_kb ))
                    P_STATUS[$i]="done"; (( FILES_DONE++ ))
                    find "$(dirname "$src")" -mindepth 1 -type d -empty -delete 2>/dev/null
                else
                    BYTES_DONE=$base_done
                    log "ERROR: direct fallback failed — $(basename "$src")${err_line:+ ($err_line)}"
                    P_STATUS[$i]="error"; (( FILES_SKIPPED++ ))
                fi

                local now; now=$(date +%s)
                if (( now - last_write >= 3 )); then
                    _update_rate "$now" rate_t0 rate_b0
                    last_write=$now; write_status
                fi
                continue
            fi
            log "Staging: $(basename "$src") ($(fmt_kb $size_kb))"
            mkdir -p "$staged_dir"
            if ! rsync -a "$src" "$staged_dir/" 2>/dev/null; then
                log "ERROR: staging failed — $(basename "$src")"
                P_STATUS[$i]="error"; (( FILES_SKIPPED++ )); continue
            fi
        fi

        # ── Step 2: Kick off background pre-stage of the NEXT file ─────────
        # This runs while Step 3 below does the slow parity write, giving the
        # pipeline overlap that makes cache mode faster.
        local j
        for (( j=i+1; j<P_COUNT; j++ )); do [[ "${P_STATUS[$j]}" == "pending" ]] && break; done
        if (( j < P_COUNT )); then
            local nsrc="${P_SRC[$j]}"
            local nsz="${P_SIZE[$j]}"
            local ndn="${nsrc#/mnt/}"; ndn="${ndn%%/*}"
            local nstaged="$STAGE_DIR/${nsrc#/mnt/$ndn/}"
            local nstaged_dir; nstaged_dir=$(dirname "$nstaged")
            if [[ -f "$nsrc" ]] && _cache_has_space "$(( size_kb + nsz ))"; then
                mkdir -p "$nstaged_dir"
                rsync -a "$nsrc" "$nstaged_dir/" 2>/dev/null &
                pre_pid=$!; pre_src="$nsrc"; pre_staged="$nstaged"
            fi
        fi

        # ── Step 3: Move staged file → destination disk (parity write) ─────
        if [[ ! -f "$staged" ]]; then
            log "ERROR: staged file missing — $(basename "$src")"
            P_STATUS[$i]="error"; (( FILES_SKIPPED++ ))
            [[ -n "$pre_pid" ]] && { wait "$pre_pid" 2>/dev/null; pre_pid=""; }
            continue
        fi

        local actual_free; actual_free=$(df -k "$dst_dir" 2>/dev/null | awk 'NR==2{print $4}')
        if [[ -n "$actual_free" && "$actual_free" -lt "$size_kb" ]]; then
            log "SKIP (no space on dest): $(basename "$src")"
            P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ ))
            rm -f "$staged"; find "$staged_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
            continue
        fi

        log "Moving ($(fmt_kb $size_kb)): $(basename "$src")  →  ${dst_dir#/mnt/}/"
        P_STATUS[$i]="moving"
        mkdir -p "$dst_dir"

        # rsync from cache to dest; then remove source and staged copy.
        # Streams --info=progress2 so BYTES_DONE (and the UI's % bar) advances
        # mid-file instead of only jumping once per completed file.
        local base_done=$BYTES_DONE rc="" err_line=""
        while IFS= read -r line; do
            if [[ "$line" == __RC:* ]]; then
                rc="${line#__RC:}"
            elif [[ "$line" =~ ([0-9]{1,3})% ]]; then
                local fpct="${BASH_REMATCH[1]}"
                (( fpct > 100 )) && fpct=100
                BYTES_DONE=$(( base_done + size_kb * fpct / 100 ))
                local now; now=$(date +%s)
                if (( now - last_write >= 3 )); then
                    _update_rate "$now" rate_t0 rate_b0
                    last_write=$now; write_status
                fi
            else
                err_line="$line"
            fi
        done < <(
            { rsync -aX --info=progress2 "$staged" "$dst_dir/" 2>&1; printf '__RC:%d\n' "$?"; } | tr '\r' '\n'
        )

        if [[ "$rc" == "0" ]]; then
            rm -f "$src"                # remove original (file safely on dest)
            rm -f "$staged"             # remove staged copy
            find "$staged_dir"    -mindepth 1 -type d -empty -delete 2>/dev/null
            find "$(dirname "$src")" -mindepth 1 -type d -empty -delete 2>/dev/null
            BYTES_DONE=$(( base_done + size_kb ))
            P_STATUS[$i]="done"; (( FILES_DONE++ ))
        else
            BYTES_DONE=$base_done
            log "ERROR: move from cache failed — $(basename "$src")${err_line:+ ($err_line)}"
            P_STATUS[$i]="error"; (( FILES_SKIPPED++ ))
            rm -f "$staged"; find "$staged_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
        fi

        # ── Rate / ETA update ────────────────────────────────────────────────
        local now; now=$(date +%s)
        if (( now - last_write >= 3 )); then
            _update_rate "$now" rate_t0 rate_b0
            last_write=$now; write_status
        fi

    done

    [[ -n "$pre_pid" ]] && wait "$pre_pid" 2>/dev/null
    rm -rf "$STAGE_DIR" 2>/dev/null
    CURRENT_FILE=""
}

##############################################################################
# Plan executor (direct, no cache)
##############################################################################
execute_plan() {
    [[ $P_COUNT -eq 0 ]] && return

    # Dispatch to cache-assisted version if requested
    if $USE_CACHE; then execute_plan_cached; return; fi

    local rate_t0=$START_TIME
    local rate_b0=0
    local last_write=0

    for (( i=0; i<P_COUNT; i++ )); do
        # Honour stop signal
        [[ "$STATE" != "running" ]] && break
        [[ "${P_STATUS[$i]}" != "pending" ]] && continue

        local size_kb="${P_SIZE[$i]}"
        local src="${P_SRC[$i]}"
        local dst="${P_DST[$i]}"
        local dst_dir
        dst_dir=$(dirname "$dst")
        CURRENT_FILE="$src"

        # --- Pre-flight checks ---
        if [[ ! -f "$src" ]]; then
            log "SKIP (gone): ${src}"
            P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
        fi

        if is_in_use "$src"; then
            log "SKIP (in use): $(basename "$src")"
            P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
        fi

        # Re-verify actual free space (plan may be stale)
        local actual_free
        actual_free=$(df -k "$dst_dir" 2>/dev/null | awk 'NR==2{print $4}')
        if [[ -n "$actual_free" && "$actual_free" -lt "$size_kb" ]]; then
            log "SKIP (no space on $(basename "$dst_dir")): $(basename "$src")"
            P_STATUS[$i]="skipped"; (( FILES_SKIPPED++ )); continue
        fi

        # --- Execute (stream rsync's progress so BYTES_DONE advances mid-file) ---
        log "Moving ($(fmt_kb $size_kb)): $(basename "$src")  →  $(basename "$dst_dir" | sed 's|^/mnt/||')/"
        P_STATUS[$i]="moving"
        mkdir -p "$dst_dir"

        local base_done=$BYTES_DONE rc="" err_line=""
        while IFS= read -r line; do
            if [[ "$line" == __RC:* ]]; then
                rc="${line#__RC:}"
            elif [[ "$line" =~ ([0-9]{1,3})% ]]; then
                local fpct="${BASH_REMATCH[1]}"
                (( fpct > 100 )) && fpct=100
                BYTES_DONE=$(( base_done + size_kb * fpct / 100 ))
                local now; now=$(date +%s)
                if (( now - last_write >= 3 )); then
                    _update_rate "$now" rate_t0 rate_b0
                    last_write=$now; write_status
                fi
            else
                err_line="$line"
            fi
        done < <(
            { rsync -aX --remove-source-files --info=progress2 "$src" "${dst_dir}/" 2>&1; printf '__RC:%d\n' "$?"; } | tr '\r' '\n'
        )

        if [[ "$rc" == "0" ]]; then
            BYTES_DONE=$(( base_done + size_kb ))
            P_STATUS[$i]="done"
            (( FILES_DONE++ ))
            find "$(dirname "$src")" -mindepth 1 -type d -empty -delete 2>/dev/null
        else
            BYTES_DONE=$base_done
            log "ERROR: rsync failed — $(basename "$src")${err_line:+ ($err_line)}"
            P_STATUS[$i]="error"
            (( FILES_SKIPPED++ ))
        fi

        # --- Rate / ETA ---
        local now; now=$(date +%s)
        if (( now - last_write >= 3 )); then
            _update_rate "$now" rate_t0 rate_b0
            last_write=$now; write_status
        fi

    done

    CURRENT_FILE=""
}

##############################################################################
# Refresh actual disk stats from df after execution
##############################################################################
refresh_disk_stats() {
    for d in "${DISKS[@]}"; do
        read -r size used free _ <<< "$(df -k "${D_MOUNT[$d]}" 2>/dev/null | awk 'NR==2{print $2,$3,$4}')"
        [[ -n "$size" && "$size" -gt 0 ]] && {
            D_SIZE[$d]=$size
            D_USED[$d]=$used
            D_FREE[$d]=$free
            D_PCT[$d]=$(( used * 100 / size ))
        }
    done
}

##############################################################################
# Main
##############################################################################

# Rotate the persistent log if it has grown large (keep the most recent lines)
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 5242880 )); then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Write status immediately so the PHP poller sees 'starting' right away
write_status

log "ReBalance started — tolerance: ±${TOLERANCE}%  dry_run: ${DRY_RUN}  use_cache: ${USE_CACHE}  full log: ${LOG_FILE}"
$USE_CACHE && log "Cache staging buffer: $(fmt_kb $CACHE_BUFFER_KB)  staging dir: $STAGE_DIR"
discover_disks

if [[ ${#DISKS[@]} -eq 0 ]]; then
    log "ERROR: No mounted data disks found under /mnt/disk[0-9]*"
    STATE="error"
    write_status
    exit 1
fi

calc_target
write_status

build_plan

if [[ $P_COUNT -eq 0 ]]; then
    log "Nothing to move — array is already balanced within ±${TOLERANCE}%."
    STATE="completed"
    write_status
    exit 0
fi

if $DRY_RUN; then
    log "Dry run complete. ${P_COUNT} files ($(fmt_kb $BYTES_TOTAL)) would be moved."
    STATE="planned"
    write_status
    exit 0
fi

STATE="running"
log "Starting execution: ${P_COUNT} files, $(fmt_kb $BYTES_TOTAL) to move"
write_status

execute_plan

refresh_disk_stats
log "Finished. Moved: ${FILES_DONE} files. Skipped/errored: ${FILES_SKIPPED}."
STATE="completed"
write_status
exit 0
