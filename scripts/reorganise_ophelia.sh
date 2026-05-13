#!/usr/bin/env bash
# reorganise_ophelia.sh
#
# Standalone tool to reorganise existing Ophelia output (raw lima output)
# without re-running ophelia. Delegates all classification and file-movement
# logic to lib/reorganise.sh, staying in lock-step with ophelia_cli.sh.
#
# Operates only on raw (no-reorganise) output – if any input path already has
# a reorganised layout, the script refuses with a clear message.
#
# Each --path value is auto-detected by content:
#   - if it contains *.demux.* files at the top level, it's processed as a
#     single sample dir
#   - if it contains subdirs that contain *.demux.* files, it's treated as a
#     dir_out parent and those subdirs are processed
#
# The --mode flag mirrors ophelia's --reorganise modes:
#   by-sample-type   move files into <sample>/{barcoded,reports,unbarcoded}/
#   by-type          move files into {barcoded,reports,unbarcoded}/ flat
#   by-type-sample   move files into {barcoded,reports,unbarcoded}/<sample>/
#
# --dir_out is required for by-type and by-type-sample (the top-level destination).
# For by-sample-type it defaults to the parent of each sample dir.

set -euo pipefail

#-----------------------------------------------------------------------------
# Locate and source the shared library
#-----------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OPHELIA_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
LIB="${OPHELIA_ROOT}/lib/reorganise.sh"

if [[ ! -f "${LIB}" ]]; then
    echo "Error: shared library not found at ${LIB}" >&2
    echo "       This script must be run from within a checked-out ophelia repo." >&2
    exit 1
fi
# shellcheck source=../lib/reorganise.sh
source "${LIB}"

#-----------------------------------------------------------------------------
# Defaults
#-----------------------------------------------------------------------------
MODE=""
DIR_OUT=""
DRY_RUN=0
DROP_UNBARCODED=0
PATHS=()

usage() {
    cat <<EOF
Usage: $0 --mode MODE --path <dir> [--path <dir> ...] [OPTIONS]

Reorganise existing raw Ophelia output without re-running lima.

Required:
  --mode MODE         by-sample-type | by-type | by-type-sample
                      (by-sample is the raw output state and a no-op here)
  --path <dir>        sample dir OR a dir_out parent containing sample dirs
                      (can be specified multiple times)

Options:
  --dir_out DIR       top-level output directory for by-type / by-type-sample
                      (default: parent of each sample dir)
  --drop-unbarcoded   delete unbarcoded BAMs instead of moving them (irreversible)
  --dry-run           print planned moves without executing
  -h, --help          show this help

Examples:
  # Reorganise a whole result_ophelia/ directory into pooled type dirs
  $0 --mode by-type --path ~/results/result_ophelia --dir_out ~/results/result_ophelia

  # Dry run first
  $0 --mode by-sample-type --path ~/results/result_ophelia --dry-run

  # Single sample dir
  $0 --mode by-sample-type --path ~/results/result_ophelia/m84277_..._bc2001

  # Multiple paths into a merged dir
  $0 --mode by-type --path /run1/result_ophelia --path /run2/result_ophelia --dir_out /merged

  # Drop unbarcoded BAMs to save space
  $0 --mode by-type --path ~/results/result_ophelia --dir_out ~/results/result_ophelia --drop-unbarcoded
EOF
}

#-----------------------------------------------------------------------------
# Argument parsing
#-----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -lt 2 ]] && { echo "Error: --mode requires a value" >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        --path)
            [[ $# -lt 2 ]] && { echo "Error: --path requires a value" >&2; exit 1; }
            PATHS+=("$2"); shift 2 ;;
        --path=*)    PATHS+=("${1#--path=}"); shift ;;
        --dir_out)
            [[ $# -lt 2 ]] && { echo "Error: --dir_out requires a value" >&2; exit 1; }
            DIR_OUT="$2"; shift 2 ;;
        --dir_out=*) DIR_OUT="${1#--dir_out=}"; shift ;;
        --drop-unbarcoded) DROP_UNBARCODED=1; shift ;;
        --dry-run)         DRY_RUN=1;         shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

#-----------------------------------------------------------------------------
# Validate
#-----------------------------------------------------------------------------
if [[ -z "${MODE}" ]]; then
    echo "Error: --mode is required" >&2
    usage; exit 1
fi

case "${MODE}" in
    by-sample-type|by-type|by-type-sample) ;;
    by-sample)
        echo "Error: --mode by-sample is a no-op (raw output is already by-sample)" >&2
        exit 1
        ;;
    *)
        echo "Error: invalid mode '${MODE}'" >&2
        echo "Valid modes: by-sample-type, by-type, by-type-sample" >&2
        exit 1
        ;;
esac

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "Error: at least one --path required" >&2
    usage; exit 1
fi

if [[ "${MODE}" != "by-sample-type" && -z "${DIR_OUT}" ]]; then
    echo "Error: --dir_out is required for mode '${MODE}'" >&2
    exit 1
fi

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------

# Echo "sample", "parent", "reorganised", or "empty".
# "sample"      → dir contains *.demux.* files at top level (flat sample dir)
# "parent"      → dir contains subdirs that contain *.demux.* files
# "reorganised" → dir or subdirs already have barcoded/reports/unbarcoded layout
# "empty"       → neither (nothing to do)
detect_path_type() {
    local d="${1%/}"
    # `shopt -p nullglob` exits 1 when nullglob is off; `|| true` keeps
    # set -e from killing the script while preserving the stdout for eval.
    local prev_nullglob
    prev_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob

    # Already reorganised at top level (by-type / by-type-sample signature)?
    if is_dir_reorganised "${d}"; then
        eval "${prev_nullglob}"; echo "reorganised"; return
    fi

    # Top-level *.demux.* files → sample dir
    local matches
    matches=("${d}"/*.demux.*)
    if [[ ${#matches[@]} -gt 0 ]]; then
        eval "${prev_nullglob}"; echo "sample"; return
    fi

    # Check subdirs: any sample-level reorganised dir? any flat subdir with .demux.* files?
    local sub
    for sub in "${d}"/*/; do
        [[ -d "${sub}" ]] || continue
        if is_sample_reorganised "${sub}"; then
            eval "${prev_nullglob}"; echo "reorganised"; return
        fi
        matches=("${sub}"*.demux.*)
        if [[ ${#matches[@]} -gt 0 ]]; then
            eval "${prev_nullglob}"; echo "parent"; return
        fi
    done

    eval "${prev_nullglob}"
    echo "empty"
}

#-----------------------------------------------------------------------------
# Per-sample processing
#-----------------------------------------------------------------------------
total_barcoded=0
total_reports=0
total_unbarcoded=0
total_dropped=0
total_skipped=0
n_samples=0

process_sample_dir() {
    local sample_dir="${1%/}"
    local effective_dir_out="${2}"

    if [[ ! -d "${sample_dir}" ]]; then
        echo "Warning: ${sample_dir} is not a directory, skipping" >&2
        return
    fi

    if is_sample_reorganised "${sample_dir}"; then
        echo "Warning: ${sample_dir} already has a reorganised layout, skipping" >&2
        return
    fi

    n_samples=$((n_samples + 1))
    echo "Processing: $(basename "${sample_dir}")"

    if reorganise_sample_dir "${sample_dir}" "${MODE}" "${effective_dir_out}" \
            "${DROP_UNBARCODED}" "${DRY_RUN}"; then
        if [[ "${DROP_UNBARCODED}" -eq 1 ]]; then
            printf '  -> barcoded: %d, reports: %d, dropped: %d, skipped: %d\n' \
                "${REORG_BARCODED}" "${REORG_REPORTS}" "${REORG_DROPPED}" "${REORG_SKIPPED}"
        else
            printf '  -> barcoded: %d, reports: %d, unbarcoded: %d, skipped: %d\n' \
                "${REORG_BARCODED}" "${REORG_REPORTS}" "${REORG_UNBARCODED}" "${REORG_SKIPPED}"
        fi
        total_barcoded=$((total_barcoded + REORG_BARCODED))
        total_reports=$((total_reports + REORG_REPORTS))
        total_unbarcoded=$((total_unbarcoded + REORG_UNBARCODED))
        total_dropped=$((total_dropped + REORG_DROPPED))
        total_skipped=$((total_skipped + REORG_SKIPPED))
    fi
}

#-----------------------------------------------------------------------------
# Main loop
#-----------------------------------------------------------------------------
shopt -s nullglob

for arg in "${PATHS[@]}"; do
    if [[ ! -d "${arg}" ]]; then
        echo "Warning: ${arg} is not a directory, skipping" >&2
        continue
    fi

    path_type=$(detect_path_type "${arg}")

    case "${path_type}" in
        reorganised)
            echo "Error: ${arg} already has a reorganised layout (barcoded/, reports/, or unbarcoded/ present)." >&2
            echo "       This tool only operates on raw lima output." >&2
            exit 1
            ;;
        empty)
            echo "Warning: ${arg} contains no Ophelia output (no *.demux.* files found), skipping" >&2
            continue
            ;;
        sample)
            # Single sample dir – effective dir_out is its parent unless overridden
            effective_dir_out="${DIR_OUT:-$(cd "${arg}/.." && pwd)}"
            process_sample_dir "${arg}" "${effective_dir_out}"
            ;;
        parent)
            effective_dir_out="${DIR_OUT:-$(cd "${arg}" && pwd)}"
            for sample_dir in "${arg}"/*/; do
                # Skip the type subdirs we may have just created mid-loop
                bn=$(basename "${sample_dir%/}")
                [[ "${bn}" == "barcoded" || "${bn}" == "reports" || "${bn}" == "unbarcoded" ]] && continue
                process_sample_dir "${sample_dir}" "${effective_dir_out}"
            done
            ;;
    esac
done

shopt -u nullglob

if [[ ${n_samples} -eq 0 ]]; then
    echo "No samples processed." >&2
    exit 1
fi

echo ""
echo "Summary across ${n_samples} sample(s) (mode: ${MODE}):"
printf '  Total barcoded:   %d\n' "${total_barcoded}"
printf '  Total reports:    %d\n' "${total_reports}"
if [[ "${DROP_UNBARCODED}" -eq 1 ]]; then
    printf '  Total dropped:    %d\n' "${total_dropped}"
else
    printf '  Total unbarcoded: %d\n' "${total_unbarcoded}"
fi
printf '  Total skipped:    %d\n' "${total_skipped}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ""
    echo "Dry-run only. Re-run without --dry-run to execute."
fi
