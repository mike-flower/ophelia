#!/usr/bin/env bash
#==============================================================================
# Ophelia – shared reorganisation library
#==============================================================================
#
# Provides reorganise_sample_dir(), the core function for sorting Ophelia demux
# output into barcoded/, reports/, and unbarcoded/ subfolders.
#
# Sourced by:
#   - scripts/ophelia_cli.sh         (per-sample reorganisation during a run)
#   - scripts/reorganise_ophelia.sh  (post-hoc retrofitting of existing output)
#
# Lives at lib/reorganise.sh in the ophelia repo root.
#
# Classification rules (filename-based, barcode-name-agnostic):
#   barcoded/    *.demux.<tok1>--<tok2>.{bam,bam.pbi,consensusreadset.xml}
#   unbarcoded/  *.demux.unbarcoded.*
#   reports/     everything else with .demux. in the name
#                (lima.counts, lima.summary, lima.report, top-level json/xml)
#
# This file should be sourced, not executed.
#==============================================================================

# Guard against double-sourcing
[[ "${_OPHELIA_REORGANISE_LIB_LOADED:-0}" == "1" ]] && return 0
_OPHELIA_REORGANISE_LIB_LOADED=1

#------------------------------------------------------------------------------
# Counters – populated by reorganise_sample_dir(). Callers may read these
# after each call. Reset at the start of every call.
#------------------------------------------------------------------------------
REORG_BARCODED=0
REORG_REPORTS=0
REORG_UNBARCODED=0
REORG_DROPPED=0
REORG_SKIPPED=0

#------------------------------------------------------------------------------
# reorganise_sample_dir <sample_dir> [drop_unbarcoded] [dry_run]
#
# Arguments:
#   sample_dir       Path to a single demux_*/ directory
#   drop_unbarcoded  1 = delete unbarcoded files, 0 = move them (default 0)
#   dry_run          1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if sample_dir is not a directory.
#
# Behaviour:
#   - Idempotent: re-running on an already-reorganised dir is a no-op
#     (the regexes only match files that haven't been moved yet).
#   - Subfolders that already exist are reused.
#   - Unrecognised files are left in place and counted as skipped.
#------------------------------------------------------------------------------
reorganise_sample_dir() {
    local sample_dir="${1%/}"
    local drop_unbarcoded="${2:-0}"
    local dry_run="${3:-0}"

    REORG_BARCODED=0
    REORG_REPORTS=0
    REORG_UNBARCODED=0
    REORG_DROPPED=0
    REORG_SKIPPED=0

    if [[ ! -d "${sample_dir}" ]]; then
        return 1
    fi

    if [[ "${dry_run}" -eq 0 ]]; then
        mkdir -p "${sample_dir}/barcoded" "${sample_dir}/reports"
        if [[ "${drop_unbarcoded}" -eq 0 ]]; then
            mkdir -p "${sample_dir}/unbarcoded"
        fi
    fi

    local f bn
    shopt -s nullglob
    for f in "${sample_dir}"/*; do
        [[ -f "${f}" ]] || continue   # skip subdirs (incl. the ones we just made)
        bn=$(basename "${f}")

        if   [[ "${bn}" =~ \.demux\.[^.]+--[^.]+\.(bam(\.pbi)?|consensusreadset\.xml)$ ]]; then
            _reorg_move "${f}" "${sample_dir}/barcoded" "${dry_run}"
            REORG_BARCODED=$((REORG_BARCODED + 1))
        elif [[ "${bn}" =~ \.demux\.unbarcoded\. ]]; then
            if [[ "${drop_unbarcoded}" -eq 1 ]]; then
                _reorg_drop "${f}" "${dry_run}"
                REORG_DROPPED=$((REORG_DROPPED + 1))
            else
                _reorg_move "${f}" "${sample_dir}/unbarcoded" "${dry_run}"
                REORG_UNBARCODED=$((REORG_UNBARCODED + 1))
            fi
        elif [[ "${bn}" =~ \.demux\. ]]; then
            _reorg_move "${f}" "${sample_dir}/reports" "${dry_run}"
            REORG_REPORTS=$((REORG_REPORTS + 1))
        else
            REORG_SKIPPED=$((REORG_SKIPPED + 1))
        fi
    done
    shopt -u nullglob

    return 0
}

#------------------------------------------------------------------------------
# locate_summary_file <sample_dir> <output_prefix>
#
# Echoes the path to the lima.summary file (flat or reorganised), or empty
# string if not found. Used by ophelia_cli.sh for resume + summary logic.
#------------------------------------------------------------------------------
locate_summary_file() {
    local sample_dir="${1%/}"
    local output_prefix="$2"
    local flat="${sample_dir}/${output_prefix}.lima.summary"
    local reorg="${sample_dir}/reports/${output_prefix}.lima.summary"

    if   [[ -f "${flat}"  ]]; then echo "${flat}"
    elif [[ -f "${reorg}" ]]; then echo "${reorg}"
    else                           echo ""
    fi
}

#------------------------------------------------------------------------------
# Internal helpers
#------------------------------------------------------------------------------
_reorg_move() {
    local src="$1"
    local dest_dir="$2"
    local dry_run="$3"

    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] %-70s -> %s/\n' "$(basename "${src}")" "$(basename "${dest_dir}")" >&2
    else
        mv -- "${src}" "${dest_dir}/"
    fi
}

_reorg_drop() {
    local src="$1"
    local dry_run="$2"

    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] DROP %s\n' "$(basename "${src}")" >&2
    else
        rm -f -- "${src}"
    fi
}
