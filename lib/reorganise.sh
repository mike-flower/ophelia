#!/usr/bin/env bash
#==============================================================================
# Ophelia – shared reorganisation library
#==============================================================================
#
# Classifies and moves files from <bam_basename>/ output directories into the
# layout requested by --reorganise MODE. All modes move files; nothing is
# copied or symlinked.
#
# Classification rules (filename-based, barcode-name-agnostic):
#   barcoded/    *.demux.<tok1>--<tok2>.{bam,bam.pbi,consensusreadset.xml}
#   unbarcoded/  *.demux.unbarcoded.*
#   reports/     everything else with .demux. in the name
#                (lima.counts, lima.summary, lima.report, top-level json/xml)
#
# Modes:
#   by-sample        no reorganisation; raw lima output left untouched
#                    (handled at the caller – do not pass to reorganise_sample_dir)
#   by-sample-type   files moved into <sample>/{barcoded,reports,unbarcoded}/
#   by-type          files moved into dir_out/{barcoded,reports,unbarcoded}/
#                    <sample>/ removed once empty
#   by-type-sample   files moved into dir_out/{barcoded,reports,unbarcoded}/<sample>/
#                    <sample>/ removed once empty
#
# Sourced by:
#   - scripts/ophelia_cli.sh         (per-sample reorganisation during a run)
#   - scripts/reorganise_ophelia.sh  (post-hoc retrofitting of existing output)
#
# Lives at lib/reorganise.sh in the ophelia repo root.
#
# This file should be sourced, not executed.
#==============================================================================

# Guard against double-sourcing
[[ "${_OPHELIA_REORGANISE_LIB_LOADED:-0}" == "1" ]] && return 0
_OPHELIA_REORGANISE_LIB_LOADED=1

#------------------------------------------------------------------------------
# Counters – reset and populated by reorganise_sample_dir(). Callers may read
# these after each call.
#------------------------------------------------------------------------------
REORG_BARCODED=0
REORG_REPORTS=0
REORG_UNBARCODED=0
REORG_DROPPED=0
REORG_SKIPPED=0

#------------------------------------------------------------------------------
# classify_file <basename>
#
# Echoes the type bucket for a file: "barcoded", "unbarcoded", "reports",
# or "skip". Used internally and exposed for callers that want to inspect
# files without moving them.
#------------------------------------------------------------------------------
classify_file() {
    local bn="$1"
    if   [[ "${bn}" =~ \.demux\.[^.]+--[^.]+\.(bam(\.pbi)?|consensusreadset\.xml)$ ]]; then
        echo "barcoded"
    elif [[ "${bn}" =~ \.demux\.unbarcoded\. ]]; then
        echo "unbarcoded"
    elif [[ "${bn}" =~ \.demux\. ]]; then
        echo "reports"
    else
        echo "skip"
    fi
}

#------------------------------------------------------------------------------
# reorganise_sample_dir <sample_dir> <mode> <dir_out>
#                       [drop_unbarcoded] [dry_run]
#
# Arguments:
#   sample_dir       Path to a single <bam_basename>/ directory
#   mode             by-sample-type | by-type | by-type-sample
#                    ("by-sample" is a no-op handled by the caller; do not
#                    pass it to this function.)
#   dir_out          Top-level output directory (used by by-type* modes)
#   drop_unbarcoded  1 = delete unbarcoded files, 0 = move them (default 0)
#   dry_run          1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if sample_dir is not a directory or mode is invalid.
#
# Behaviour:
#   - by-sample-type: moves files into <sample_dir>/{barcoded,reports,unbarcoded}/.
#   - by-type:        moves files into <dir_out>/{barcoded,reports,unbarcoded}/.
#                     <sample_dir> is rmdir'd afterwards (succeeds only if empty).
#   - by-type-sample: moves files into <dir_out>/{barcoded,reports,unbarcoded}/<sample>/.
#                     <sample_dir> is rmdir'd afterwards.
#------------------------------------------------------------------------------
reorganise_sample_dir() {
    local sample_dir="${1%/}"
    local mode="$2"
    local dir_out="${3%/}"
    local drop_unbarcoded="${4:-0}"
    local dry_run="${5:-0}"

    REORG_BARCODED=0
    REORG_REPORTS=0
    REORG_UNBARCODED=0
    REORG_DROPPED=0
    REORG_SKIPPED=0

    if [[ ! -d "${sample_dir}" ]]; then
        return 1
    fi

    local sample_name
    sample_name=$(basename "${sample_dir}")

    # Determine the target root for each file type based on mode
    local dest_barcoded dest_reports dest_unbarcoded
    case "${mode}" in
        by-sample-type)
            dest_barcoded="${sample_dir}/barcoded"
            dest_reports="${sample_dir}/reports"
            dest_unbarcoded="${sample_dir}/unbarcoded"
            ;;
        by-type)
            dest_barcoded="${dir_out}/barcoded"
            dest_reports="${dir_out}/reports"
            dest_unbarcoded="${dir_out}/unbarcoded"
            ;;
        by-type-sample)
            dest_barcoded="${dir_out}/barcoded/${sample_name}"
            dest_reports="${dir_out}/reports/${sample_name}"
            dest_unbarcoded="${dir_out}/unbarcoded/${sample_name}"
            ;;
        *)
            return 1
            ;;
    esac

    # Create destination directories upfront (skip unbarcoded if dropping)
    if [[ "${dry_run}" -eq 0 ]]; then
        mkdir -p "${dest_barcoded}" "${dest_reports}"
        if [[ "${drop_unbarcoded}" -eq 0 ]]; then
            mkdir -p "${dest_unbarcoded}"
        fi
    fi

    # Save and restore nullglob state. `shopt -p nullglob` exits 1 when
    # nullglob is off, which would trip `set -e` in the caller; `|| true`
    # forces a 0 exit while preserving the stdout we need for the eval.
    local prev_nullglob
    prev_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob

    local f bn bucket
    for f in "${sample_dir}"/*; do
        [[ -f "${f}" ]] || continue   # skip subdirs (incl. the ones we just made)
        bn=$(basename "${f}")
        bucket=$(classify_file "${bn}")

        case "${bucket}" in
            barcoded)
                _reorg_move "${f}" "${dest_barcoded}" "${dry_run}"
                REORG_BARCODED=$((REORG_BARCODED + 1))
                ;;
            unbarcoded)
                if [[ "${drop_unbarcoded}" -eq 1 ]]; then
                    _reorg_drop "${f}" "${dry_run}"
                    REORG_DROPPED=$((REORG_DROPPED + 1))
                else
                    _reorg_move "${f}" "${dest_unbarcoded}" "${dry_run}"
                    REORG_UNBARCODED=$((REORG_UNBARCODED + 1))
                fi
                ;;
            reports)
                _reorg_move "${f}" "${dest_reports}" "${dry_run}"
                REORG_REPORTS=$((REORG_REPORTS + 1))
                ;;
            skip)
                REORG_SKIPPED=$((REORG_SKIPPED + 1))
                ;;
        esac
    done

    eval "${prev_nullglob}"

    # Post-move cleanup for by-type modes: rmdir the now-empty <sample_dir>.
    # --ignore-fail-on-non-empty means we never error here; if there are
    # unrecognised files left behind, the dir stays put and the user sees them.
    if [[ "${dry_run}" -eq 0 ]]; then
        case "${mode}" in
            by-type|by-type-sample)
                rmdir --ignore-fail-on-non-empty "${sample_dir}" 2>/dev/null || true
                ;;
        esac
    elif [[ "${mode}" == "by-type" || "${mode}" == "by-type-sample" ]]; then
        printf '  [dry-run] RMDIR  %s\n' "$(basename "${sample_dir}")" >&2
    fi

    return 0
}

#------------------------------------------------------------------------------
# locate_summary_file <dir_out> <bam_name>
#
# Searches for the lima.summary file across all locations it may occupy
# depending on the reorganisation mode. Echoes the path or empty string.
# Used by ophelia_cli.sh's generate_summary, which runs after the move step.
#
# NOT used by the dir_out state check: that uses is_dir_reorganised /
# is_sample_reorganised and refuses any non-flat layout outright.
#
# Arguments:
#   dir_out   Top-level output directory
#   bam_name  Input BAM basename without .bam
#------------------------------------------------------------------------------
locate_summary_file() {
    local dir_out="${1%/}"
    local bam_name="$2"
    local prefix="${bam_name}.demux"
    local sum="${prefix}.lima.summary"

    # Probe in mode order. by-sample first (most common, the raw/flat case).
    local candidates=(
        "${dir_out}/${bam_name}/${sum}"                  # by-sample (bare/flat)
        "${dir_out}/${bam_name}/reports/${sum}"          # by-sample-type
        "${dir_out}/reports/${sum}"                      # by-type
        "${dir_out}/reports/${bam_name}/${sum}"          # by-type-sample
    )

    local loc
    for loc in "${candidates[@]}"; do
        if [[ -f "${loc}" ]]; then
            echo "${loc}"
            return
        fi
    done
    echo ""
}

#------------------------------------------------------------------------------
# is_sample_reorganised <sample_dir>
#
# Returns 0 if sample_dir contains any of the by-sample-type subdirectories
# (barcoded/, reports/, unbarcoded/), 1 otherwise. Used by the integrated
# CLI's dir_out state check and by the standalone reorganise tool to refuse
# already-reorganised input.
#------------------------------------------------------------------------------
is_sample_reorganised() {
    local sample_dir="${1%/}"
    [[ -d "${sample_dir}/barcoded"   ]] && return 0
    [[ -d "${sample_dir}/reports"    ]] && return 0
    [[ -d "${sample_dir}/unbarcoded" ]] && return 0
    return 1
}

#------------------------------------------------------------------------------
# is_dir_reorganised <dir_out>
#
# Returns 0 if dir_out has top-level barcoded/, reports/, or unbarcoded/
# subdirectories (signature of by-type or by-type-sample layouts). Used by
# the integrated CLI's dir_out state check and by the standalone reorganise
# tool to refuse already-reorganised input.
#------------------------------------------------------------------------------
is_dir_reorganised() {
    local dir_out="${1%/}"
    [[ -d "${dir_out}/barcoded"   ]] && return 0
    [[ -d "${dir_out}/reports"    ]] && return 0
    [[ -d "${dir_out}/unbarcoded" ]] && return 0
    return 1
}

#------------------------------------------------------------------------------
# Internal helpers
#------------------------------------------------------------------------------
_reorg_move() {
    local src="$1" dest_dir="$2" dry_run="$3"
    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] MOVE %-70s -> %s/\n' \
            "$(basename "${src}")" "$(basename "${dest_dir}")" >&2
    else
        mv -- "${src}" "${dest_dir}/"
    fi
}

_reorg_drop() {
    local src="$1" dry_run="$2"
    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] DROP %s\n' "$(basename "${src}")" >&2
    else
        rm -f -- "${src}"
    fi
}
