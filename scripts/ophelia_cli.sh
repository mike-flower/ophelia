#!/bin/bash
#==============================================================================
# Ophelia - PacBio Demultiplexing Pipeline
#==============================================================================
#
# A wrapper for PacBio's lima tool for demultiplexing HiFi amplicon sequencing data
# Processes all BAM files in a directory using PacBio's lima tool
#
# Author: Michael Flower
# Institution: UCL Queen Square Institute of Neurology
# Version: 1.1.0
#
#==============================================================================

set -euo pipefail

#==============================================================================
# SCRIPT DIRECTORY
#==============================================================================

# Get the directory where this script is located (ophelia/scripts)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Get the root ophelia directory (parent of scripts/)
OPHELIA_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"

# Source shared reorganisation library (lives at the ophelia repo root, not under scripts/)
# shellcheck source=../lib/reorganise.sh
source "${OPHELIA_ROOT}/lib/reorganise.sh"

#==============================================================================
# DEFAULTS
#==============================================================================

VERSION="1.1.0"

# Required parameters (no defaults)
DIR_DATA=""
DIR_OUT=""
BARCODE_REF=""

# Optional parameters
BIOSAMPLE_CSV=""
FILE_PATTERN="*.bam"
THREADS=0   # 0 = auto-detect

# Lima preset and arguments
LIMA_PRESET="ASYMMETRIC"
LIMA_ARGS="--split-named --store-unbarcoded"

# Reorganisation options (off by default to preserve historical layout)
REORGANISE="FALSE"
DROP_UNBARCODED="FALSE"

# Execution options
DRY_RUN="FALSE"
VERBOSE="FALSE"
RESUME="TRUE"

# Runtime globals (set during execution)
LIMA_VERSION=""
LOG_DIR=""
LOG_FILE=""
RUN_TIMESTAMP=""
INPUT_FILES=()
FAILED_FILES=()

#==============================================================================
# COLOUR OUTPUT
# Colours are disabled automatically when stdout is not a TTY (e.g. in log
# files or SGE job output), so the log file remains clean and grep-friendly.
#==============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

#==============================================================================
# LOGGING
#==============================================================================

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_info() {
    echo -e "${GREEN}[$(timestamp)]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[$(timestamp)] WARNING:${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[$(timestamp)] ERROR:${NC} $*" >&2
}

log_debug() {
    if [[ "${VERBOSE}" == "TRUE" ]]; then
        echo -e "${BLUE}[$(timestamp)] DEBUG:${NC} $*"
    fi
}

log_section() {
    echo ""
    echo -e "${CYAN}===============================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

#==============================================================================
# USAGE
#==============================================================================

show_help() {
    cat << 'EOF'
Ophelia - PacBio Demultiplexing Pipeline
========================================

A wrapper for PacBio's lima tool for demultiplexing HiFi amplicon sequencing data.
Processes all BAM files in a directory sequentially.

USAGE:
    ./ophelia --dir_data DIR --dir_out DIR --barcode_ref FILE [OPTIONS]

REQUIRED ARGUMENTS:
    --dir_data DIR          Directory containing input BAM files
    --dir_out DIR           Output directory for demultiplexed files
    --barcode_ref FILE      Reference barcode FASTA file

OPTIONAL ARGUMENTS:
    --biosample_csv FILE    BioSample CSV to override BAM SM tag (does not rename files)
    --file_pattern GLOB     Pattern to match BAM files (default: *.bam)
    --threads N             Number of threads (default: auto-detect)

LIMA ARGUMENTS:
    --lima_preset PRESET    Lima HiFi preset (default: ASYMMETRIC)
                            Options: ASYMMETRIC, SYMMETRIC, SYMMETRIC-ADAPTERS, TAILED
    --lima_args "ARGS"      Additional lima arguments (default: "--split-named --store-unbarcoded")
                            Common options:
                              --peek-guess        Infer which barcodes are present
                              --split-named       Name files by barcode names
                              --store-unbarcoded  Keep unassigned reads
                              --dump-removed      Save filtered reads

OUTPUT ORGANISATION:
    --reorganise            Sort each sample's output into barcoded/, reports/,
                            and unbarcoded/ subfolders (default: off)
    --drop-unbarcoded       Delete unbarcoded BAMs instead of moving them
                            (saves significant disk space; requires --reorganise)

EXECUTION OPTIONS:
    --resume                Skip already processed files (default: on)
    --no-resume             Force re-processing of all files
    --dry_run               Show what would be run without executing
    --verbose               Enable verbose output
    --help                  Show this help message

EXAMPLES:

    # Basic demultiplexing (you know which barcodes are present)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta

    # With reorganised output layout (recommended for downstream pipelines)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise

    # Reorganise and drop unbarcoded BAMs to save disk space
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise --drop-unbarcoded

    # With SM tag override (files still named by barcode pair)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --biosample_csv ~/refs/biosample.csv

    # Unknown barcodes (infer which are present)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --lima_args "--split-named --store-unbarcoded --peek-guess"

    # Process only bc200* files
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --file_pattern "*bc200*.bam"

    # Dry run to see what would happen
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --dry_run

OUTPUT STRUCTURE:

    Without --reorganise (flat, default):
        dir_out/
        ├── demux_m84277_...bc2001/        # One folder per input BAM
        │   ├── *.demux.<bc1>--<bc2>.bam   # Demultiplexed BAM files
        │   ├── *.demux.unbarcoded.bam     # Unassigned reads
        │   ├── *.lima.summary             # Lima summary statistics
        │   ├── *.lima.report              # Detailed lima report
        │   └── *.lima.counts              # Read counts per barcode
        ├── demux_m84277_...bc2002/
        │   └── ...
        └── ophelia_summary.txt            # Overall summary

    With --reorganise:
        dir_out/
        ├── demux_m84277_...bc2001/
        │   ├── barcoded/                  # *.demux.<bc1>--<bc2>.{bam,bam.pbi,xml}
        │   ├── reports/                   # *.lima.summary, *.lima.report, *.lima.counts
        │   └── unbarcoded/                # *.demux.unbarcoded.* (omitted with --drop-unbarcoded)
        ├── demux_m84277_...bc2002/
        │   └── ...
        └── ophelia_summary.txt

    Logs (in ophelia installation directory):
    ophelia/logs/YYYYMMDD_HHMMSS/
    ├── ophelia.log
    └── ophelia_params.txt

NOTES:
    - Lima is internally parallelised, so files are processed sequentially
    - The biosample CSV should have format: Barcodes,Bio Sample
    - BOM characters in CSV files are automatically stripped
    - Requires lima from bioconda (conda install -c bioconda lima)
    - --reorganise can be applied to existing output by re-running with
      --resume (default); already-flat samples will be tidied without
      re-running lima. For ad-hoc retrofitting of existing directories
      without re-running ophelia, use scripts/reorganise_ophelia.sh

EOF
}

#==============================================================================
# ARGUMENT PARSING
#==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir_data)
                DIR_DATA="$2"
                shift 2
                ;;
            --dir_out)
                DIR_OUT="$2"
                shift 2
                ;;
            --barcode_ref)
                BARCODE_REF="$2"
                shift 2
                ;;
            --biosample_csv)
                BIOSAMPLE_CSV="$2"
                shift 2
                ;;
            --file_pattern)
                FILE_PATTERN="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --lima_preset)
                LIMA_PRESET="$2"
                shift 2
                ;;
            --lima_args)
                LIMA_ARGS="$2"
                shift 2
                ;;
            --reorganise|--reorganize)
                REORGANISE="TRUE"
                shift
                ;;
            --no-reorganise|--no-reorganize)
                REORGANISE="FALSE"
                shift
                ;;
            --drop-unbarcoded)
                DROP_UNBARCODED="TRUE"
                shift
                ;;
            --resume)
                RESUME="TRUE"
                shift
                ;;
            --no-resume)
                RESUME="FALSE"
                shift
                ;;
            --dry_run)
                DRY_RUN="TRUE"
                shift
                ;;
            --verbose)
                VERBOSE="TRUE"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

#==============================================================================
# VALIDATION
#==============================================================================

validate_inputs() {
    local errors=0

    log_info "Validating inputs..."

    # Required parameters
    if [[ -z "${DIR_DATA}" ]]; then
        log_error "Missing required argument: --dir_data"
        errors=$((errors + 1))
    elif [[ ! -d "${DIR_DATA}" ]]; then
        log_error "Data directory not found: ${DIR_DATA}"
        errors=$((errors + 1))
    fi

    if [[ -z "${DIR_OUT}" ]]; then
        log_error "Missing required argument: --dir_out"
        errors=$((errors + 1))
    fi

    if [[ -z "${BARCODE_REF}" ]]; then
        log_error "Missing required argument: --barcode_ref"
        errors=$((errors + 1))
    elif [[ ! -f "${BARCODE_REF}" ]]; then
        log_error "Barcode reference file not found: ${BARCODE_REF}"
        errors=$((errors + 1))
    fi

    # Optional file validation
    if [[ -n "${BIOSAMPLE_CSV}" && ! -f "${BIOSAMPLE_CSV}" ]]; then
        log_error "Biosample CSV file not found: ${BIOSAMPLE_CSV}"
        errors=$((errors + 1))
    fi

    # Validate threads is a non-negative integer
    if [[ -n "${THREADS}" && ! "${THREADS}" =~ ^[0-9]+$ ]]; then
        log_error "--threads must be a positive integer, got: ${THREADS}"
        errors=$((errors + 1))
    fi

    # Validate lima preset
    local valid_presets=("ASYMMETRIC" "SYMMETRIC" "SYMMETRIC-ADAPTERS" "TAILED")
    local preset_valid=false
    for p in "${valid_presets[@]}"; do
        if [[ "${LIMA_PRESET}" == "${p}" ]]; then
            preset_valid=true
            break
        fi
    done
    if [[ "${preset_valid}" == "false" ]]; then
        log_error "Invalid --lima_preset: ${LIMA_PRESET}"
        log_error "Valid options: ${valid_presets[*]}"
        errors=$((errors + 1))
    fi

    # --drop-unbarcoded requires --reorganise (it operates on the unbarcoded subdir)
    if [[ "${DROP_UNBARCODED}" == "TRUE" && "${REORGANISE}" != "TRUE" ]]; then
        log_error "--drop-unbarcoded requires --reorganise to be enabled"
        errors=$((errors + 1))
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "Use --help for usage information"
        exit 1
    fi

    log_info "Validation complete"
}

#==============================================================================
# ENVIRONMENT SETUP
#==============================================================================

setup_environment() {
    log_info "Setting up environment..."

    # Detect and activate conda/micromamba environment
    if command -v micromamba &> /dev/null; then
        log_debug "Found micromamba"
        eval "$(micromamba shell hook --shell bash 2>/dev/null)" || true
        if micromamba activate lima 2>/dev/null; then
            log_debug "Activated lima environment (micromamba)"
        else
            log_debug "Could not activate lima environment via micromamba, checking PATH"
        fi
    elif command -v conda &> /dev/null; then
        log_debug "Found conda"
        # Source conda for Myriad/HPC environments
        if [[ -n "${UCL_CONDA_PATH:-}" ]]; then
            source "${UCL_CONDA_PATH}/etc/profile.d/conda.sh"
        elif [[ -f "${CONDA_PREFIX:-}/etc/profile.d/conda.sh" ]]; then
            source "${CONDA_PREFIX}/etc/profile.d/conda.sh"
        fi
        eval "$(conda shell.bash hook 2>/dev/null)" || true
        if conda activate lima 2>/dev/null; then
            log_debug "Activated lima environment (conda)"
        else
            log_debug "Could not activate lima environment via conda, checking PATH"
        fi
    else
        log_debug "No conda/micromamba found, assuming lima is in PATH"
    fi

    # Check lima is available
    if ! command -v lima &> /dev/null; then
        log_error "lima not found in PATH"
        echo ""
        echo "To install lima:"
        echo "  conda install -c bioconda lima"
        echo ""
        echo "On UCL Myriad:"
        echo "  module load python/miniconda3/24.3.0-0"
        echo "  source \$UCL_CONDA_PATH/etc/profile.d/conda.sh"
        echo "  conda create -n lima -c bioconda lima"
        echo "  conda activate lima"
        exit 1
    fi

    LIMA_VERSION=$(lima --version 2>&1 | head -1)
    log_info "Using lima: ${LIMA_VERSION}"
}

#==============================================================================
# BIOSAMPLE CSV PREPROCESSING
#==============================================================================

preprocess_biosample_csv() {
    if [[ -z "${BIOSAMPLE_CSV}" ]]; then
        return 0
    fi

    log_info "Checking biosample CSV..."

    # Check for BOM character and create a cleaned copy if found
    # Uses perl for cross-platform compatibility (BSD sed does not support hex escapes)
    if head -c 3 "${BIOSAMPLE_CSV}" | grep -q $'\xef\xbb\xbf'; then
        log_warn "BOM character detected in biosample CSV"

        local cleaned_csv="${DIR_OUT}/biosample_cleaned.csv"
        perl -pe 's/^\xEF\xBB\xBF//' "${BIOSAMPLE_CSV}" > "${cleaned_csv}"
        log_info "Created BOM-stripped copy: ${cleaned_csv}"
        BIOSAMPLE_CSV="${cleaned_csv}"
    fi

    # Validate CSV format
    local header
    header=$(head -1 "${BIOSAMPLE_CSV}")
    if [[ ! "${header}" =~ [Bb]arcode.*[Ss]ample ]]; then
        log_warn "Biosample CSV header format may not be correct: ${header}"
        log_warn "Expected format: Barcodes,Bio Sample"
    fi

    # Count entries
    local entries
    entries=$(($(wc -l < "${BIOSAMPLE_CSV}") - 1))
    log_info "Biosample CSV contains ${entries} entries"
}

#==============================================================================
# FIND INPUT FILES
#==============================================================================

find_input_files() {
    log_info "Searching for BAM files matching: ${FILE_PATTERN}"

    INPUT_FILES=()
    while IFS= read -r -d '' file; do
        INPUT_FILES+=("$file")
    done < <(find "${DIR_DATA}" -maxdepth 1 -name "${FILE_PATTERN}" -type f -print0 | sort -z)

    if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
        log_error "No BAM files found in ${DIR_DATA} matching pattern: ${FILE_PATTERN}"
        exit 1
    fi

    log_info "Found ${#INPUT_FILES[@]} BAM file(s) to process:"
    for f in "${INPUT_FILES[@]}"; do
        echo "    - $(basename "$f")"
    done
}

#==============================================================================
# REORGANISE WRAPPER
# Calls the shared library function and logs the result.
#==============================================================================

reorganise_with_logging() {
    local sample_dir="$1"
    local label="${2:-Reorganised}"

    local drop_flag=0
    [[ "${DROP_UNBARCODED}" == "TRUE" ]] && drop_flag=1

    local dry_flag=0
    [[ "${DRY_RUN}" == "TRUE" ]] && dry_flag=1

    if reorganise_sample_dir "${sample_dir}" "${drop_flag}" "${dry_flag}"; then
        # Only log if at least one file was touched
        local total=$((REORG_BARCODED + REORG_REPORTS + REORG_UNBARCODED + REORG_DROPPED))
        if [[ ${total} -gt 0 ]]; then
            local msg="  ${label}: barcoded=${REORG_BARCODED}, reports=${REORG_REPORTS}, unbarcoded=${REORG_UNBARCODED}"
            if [[ "${DROP_UNBARCODED}" == "TRUE" ]]; then
                msg="${msg}, dropped=${REORG_DROPPED}"
            fi
            log_info "${msg}"
        fi
    else
        log_debug "  Reorganise skipped (no sample dir): ${sample_dir}"
    fi
}

#==============================================================================
# PROCESS SINGLE BAM FILE
#==============================================================================

process_bam() {
    local input_bam="$1"
    local bam_name
    bam_name=$(basename "${input_bam}" .bam)

    local output_subdir
    output_subdir="${DIR_OUT}/demux_${bam_name}"

    local output_prefix="${bam_name}.demux"
    local output_bam="${output_subdir}/${output_prefix}.bam"

    echo ""
    log_info "Processing: ${bam_name}"
    log_info "  Input:  ${input_bam}"
    log_info "  Output: ${output_subdir}/"

    # Check if already processed (resume logic). Layout-aware: looks for the
    # summary file in either the flat or reorganised location.
    if [[ "${RESUME}" == "TRUE" ]]; then
        local summary_file
        summary_file=$(locate_summary_file "${output_subdir}" "${output_prefix}")
        if [[ -n "${summary_file}" ]] && grep -q "ZMWs above all thresholds" "${summary_file}" 2>/dev/null; then
            log_info "  Skipping (already processed, --resume)"
            # If layout is flat but reorganise is requested, tidy up now.
            if [[ "${REORGANISE}" == "TRUE" && "${summary_file}" == "${output_subdir}/${output_prefix}.lima.summary" ]]; then
                reorganise_with_logging "${output_subdir}" "Reorganised (resume)"
            fi
            return 0
        fi
    fi

    # Create output directory
    mkdir -p "${output_subdir}"

    # Build lima command
    local lima_cmd=("lima")
    lima_cmd+=("${input_bam}")
    lima_cmd+=("${BARCODE_REF}")
    lima_cmd+=("${output_bam}")
    lima_cmd+=("--hifi-preset" "${LIMA_PRESET}")

    # Add biosample CSV if provided
    if [[ -n "${BIOSAMPLE_CSV}" ]]; then
        lima_cmd+=("--biosample-csv" "${BIOSAMPLE_CSV}")
    fi

    # Add threads if specified
    if [[ "${THREADS}" -gt 0 ]]; then
        lima_cmd+=("--num-threads" "${THREADS}")
    fi

    # Add user-specified lima arguments (word splitting intentional)
    # shellcheck disable=SC2206
    lima_cmd+=(${LIMA_ARGS})

    log_debug "  Command: ${lima_cmd[*]}"

    # Execute or dry run
    if [[ "${DRY_RUN}" == "TRUE" ]]; then
        log_info "  [DRY RUN] Would execute: ${lima_cmd[*]}"
        if [[ "${REORGANISE}" == "TRUE" ]]; then
            log_info "  [DRY RUN] Would then reorganise output into barcoded/reports/unbarcoded/"
        fi
        return 0
    fi

    # Run lima
    if "${lima_cmd[@]}"; then
        log_info "  ✓ Complete"

        # Report summary statistics (look in flat location since lima just wrote there)
        local summary_file="${output_subdir}/${output_prefix}.lima.summary"
        if [[ -f "${summary_file}" ]]; then
            local zmw_input zmw_pass
            zmw_input=$(grep "^ZMWs input" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "?")
            zmw_pass=$(grep "^ZMWs above all thresholds" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "?")
            log_info "  Stats: ${zmw_pass}/${zmw_input} reads passed filters"
        fi

        # Reorganise this sample's output if requested
        if [[ "${REORGANISE}" == "TRUE" ]]; then
            reorganise_with_logging "${output_subdir}" "Reorganised"
        fi

        return 0
    else
        log_error "  ✗ Failed: ${bam_name}"
        return 1
    fi
}

#==============================================================================
# GENERATE SUMMARY
#==============================================================================

generate_summary() {
    local summary_file="${DIR_OUT}/ophelia_summary.txt"

    log_info "Generating summary..."

    {
        echo "Ophelia Pipeline Summary"
        echo "========================"
        echo ""
        echo "Date: $(date)"
        echo "Version: ${VERSION}"
        echo "Lima version: ${LIMA_VERSION}"
        echo ""
        echo "Parameters:"
        echo "  dir_data:        ${DIR_DATA}"
        echo "  dir_out:         ${DIR_OUT}"
        echo "  barcode_ref:     ${BARCODE_REF}"
        echo "  biosample_csv:   ${BIOSAMPLE_CSV:-none}"
        echo "  lima_preset:     ${LIMA_PRESET}"
        echo "  lima_args:       ${LIMA_ARGS}"
        echo "  reorganise:      ${REORGANISE}"
        echo "  drop_unbarcoded: ${DROP_UNBARCODED}"
        echo ""
        echo "Files processed: ${#INPUT_FILES[@]}"
        echo ""
        echo "Results:"

        for f in "${INPUT_FILES[@]}"; do
            local bam_name
            bam_name=$(basename "$f" .bam)
            local output_subdir
            output_subdir="${DIR_OUT}/demux_${bam_name}"

            # Layout-aware lookup for the summary file
            local summary
            summary=$(locate_summary_file "${output_subdir}" "${bam_name}.demux")
            if [[ -n "${summary}" ]]; then
                local zmw_input zmw_pass pct
                zmw_input=$(grep "^ZMWs input" "${summary}" | grep -oE '[0-9]+' | head -1 || echo "0")
                zmw_pass=$(grep "^ZMWs above all thresholds" "${summary}" | grep -oE '[0-9]+' | head -1 || echo "0")
                if [[ "${zmw_input}" -gt 0 ]]; then
                    pct=$(awk "BEGIN {printf \"%.1f\", ${zmw_pass}/${zmw_input}*100}")
                else
                    pct="0.0"
                fi
                echo "  ${bam_name}: ${zmw_pass}/${zmw_input} (${pct}%)"
            else
                echo "  ${bam_name}: [not processed]"
            fi
        done
    } > "${summary_file}"

    log_info "Summary written to: ${summary_file}"
}

#==============================================================================
# SAVE PARAMETERS
#==============================================================================

save_parameters() {
    local params_file="${LOG_DIR}/ophelia_params.txt"

    {
        echo "Ophelia Pipeline Parameters"
        echo "==========================="
        echo ""
        echo "Version: ${VERSION}"
        echo "Timestamp: $(date)"
        echo "Log directory: ${LOG_DIR}"
        echo ""
        echo "# Required"
        echo "dir_data=${DIR_DATA}"
        echo "dir_out=${DIR_OUT}"
        echo "barcode_ref=${BARCODE_REF}"
        echo ""
        echo "# Optional"
        echo "biosample_csv=${BIOSAMPLE_CSV}"
        echo "file_pattern=${FILE_PATTERN}"
        echo "threads=${THREADS}"
        echo ""
        echo "# Lima arguments"
        echo "lima_preset=${LIMA_PRESET}"
        echo "lima_args=${LIMA_ARGS}"
        echo ""
        echo "# Output organisation"
        echo "reorganise=${REORGANISE}"
        echo "drop_unbarcoded=${DROP_UNBARCODED}"
        echo ""
        echo "# Execution"
        echo "resume=${RESUME}"
        echo "dry_run=${DRY_RUN}"
        echo "verbose=${VERBOSE}"
    } > "${params_file}"

    log_info "Parameters saved to: ${params_file}"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    local start_time
    start_time=$(date +%s)

    # Parse arguments
    parse_args "$@"

    # Show banner
    log_section "Ophelia v${VERSION} - PacBio Demultiplexing Pipeline"

    # Set up logging BEFORE validation so all output (including errors) is captured.
    # Log dir is in the ophelia root, independent of DIR_OUT, so it can be created
    # even if DIR_OUT hasn't been validated yet.
    RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="${OPHELIA_ROOT}/logs/${RUN_TIMESTAMP}"
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/ophelia.log"

    # Redirect stdout/stderr: terminal sees ANSI colours, log file is plain text
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}")) 2>&1

    log_info "Log directory: ${LOG_DIR}"

    # Validate inputs (errors now captured in log)
    validate_inputs

    # Create output directory
    mkdir -p "${DIR_OUT}"
    log_info "Output directory: ${DIR_OUT}"

    if [[ "${REORGANISE}" == "TRUE" ]]; then
        if [[ "${DROP_UNBARCODED}" == "TRUE" ]]; then
            log_info "Output layout: reorganised (unbarcoded files will be DELETED)"
        else
            log_info "Output layout: reorganised (barcoded/, reports/, unbarcoded/)"
        fi
    fi

    # Save parameters
    save_parameters

    # Setup environment
    setup_environment

    # Preprocess biosample CSV
    preprocess_biosample_csv

    # Find input files
    find_input_files

    # Process each BAM file
    log_section "Processing BAM Files"

    local failed=0
    local succeeded=0
    FAILED_FILES=()

    for bam_file in "${INPUT_FILES[@]}"; do
        if process_bam "${bam_file}"; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            FAILED_FILES+=("$(basename "${bam_file}")")
        fi
    done

    # Generate summary
    if [[ "${DRY_RUN}" != "TRUE" ]]; then
        generate_summary
    fi

    # Final report
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    log_section "Pipeline Complete"

    log_info "Results:     ${DIR_OUT}"
    log_info "Succeeded:   ${succeeded}"
    log_info "Failed:      ${failed}"
    log_info "Duration:    $(printf "%02d:%02d:%02d" ${hours} ${minutes} ${seconds}) (HH:MM:SS)"
    log_info "Logs:        ${LOG_DIR}"

    if [[ ${failed} -gt 0 ]]; then
        log_warn "The following files failed to process:"
        for f in "${FAILED_FILES[@]}"; do
            log_warn "  - ${f}"
        done
        log_warn "Check log for details: ${LOG_FILE}"
        exit 1
    fi
}

# Run main
main "$@"
