#!/bin/bash
#===============================================================================
# Lima Pipeline - Command Line Interface
#===============================================================================
#
# PacBio demultiplexing pipeline for HiFi amplicon sequencing data
# Processes all BAM files in a directory using PacBio's lima tool
#
# Author: Michael Flower
# Institution: UCL Queen Square Institute of Neurology
# Version: 1.0.0
#
#===============================================================================

set -euo pipefail

#===============================================================================
# DEFAULTS
#===============================================================================

# Required parameters (no defaults)
DIR_DATA=""
DIR_OUT=""
BARCODE_REF=""

# Optional parameters
BIOSAMPLE_CSV=""
FILE_PATTERN="*.bam"
THREADS=0  # 0 = auto-detect

# Lima preset and arguments
LIMA_PRESET="ASYMMETRIC"
LIMA_ARGS="--split-named --store-unbarcoded"

# Execution options
DRY_RUN="FALSE"
VERBOSE="FALSE"
RESUME="TRUE"

#===============================================================================
# COLOUR OUTPUT
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#===============================================================================
# LOGGING
#===============================================================================

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
    echo -e "${CYAN}=================================================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}=================================================================${NC}"
    echo ""
}

#===============================================================================
# USAGE
#===============================================================================

show_help() {
    cat << 'EOF'
Lima Pipeline - PacBio Demultiplexing
=====================================

Demultiplex PacBio HiFi amplicon sequencing data using lima.
Processes all BAM files in a directory sequentially.

USAGE:
    ./lima --dir_data DIR --dir_out DIR --barcode_ref FILE [OPTIONS]

REQUIRED ARGUMENTS:
    --dir_data DIR          Directory containing input BAM files
    --dir_out DIR           Output directory for demultiplexed files
    --barcode_ref FILE      Reference barcode FASTA file

OPTIONAL ARGUMENTS:
    --biosample_csv FILE    BioSample CSV for sample naming (renames output files)
    --file_pattern GLOB     Pattern to match BAM files (default: *.bam)
    --threads N             Number of threads (default: auto-detect)

LIMA ARGUMENTS:
    --lima_preset PRESET    Lima HiFi preset (default: ASYMMETRIC)
                            Options: ASYMMETRIC, SYMMETRIC, SYMMETRIC-ADAPTERS
    --lima_args "ARGS"      Additional lima arguments (default: "--split-named --store-unbarcoded")
                            Common options:
                              --peek-guess        Infer which barcodes are present
                              --split-named       Name files by barcode names
                              --store-unbarcoded  Keep unassigned reads
                              --dump-removed      Save filtered reads

EXECUTION OPTIONS:
    --resume TRUE|FALSE     Skip already processed files (default: TRUE)
    --dry_run               Show what would be run without executing
    --verbose               Enable verbose output
    --help                  Show this help message

EXAMPLES:

    # Basic demultiplexing (you know which barcodes are present)
    ./lima \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta

    # With sample renaming (files named by biosample)
    ./lima \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --biosample_csv ~/refs/biosample.csv

    # Unknown barcodes (infer which are present)
    ./lima \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --lima_args "--split-named --store-unbarcoded --peek-guess"

    # Process only bc200* files
    ./lima \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --file_pattern "*bc200*.bam"

    # Dry run to see what would happen
    ./lima \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --dry_run

OUTPUT STRUCTURE:
    dir_out/
    ├── demux_bc2001/           # One folder per input BAM
    │   ├── *.demux.*.bam       # Demultiplexed BAM files
    │   ├── *.lima.summary      # Lima summary statistics
    │   ├── *.lima.report       # Detailed lima report
    │   └── *.lima.counts       # Read counts per barcode
    ├── demux_bc2002/
    │   └── ...
    ├── logs/
    │   ├── lima_YYYYMMDD_HHMMSS.log
    │   └── lima_params_YYYYMMDD_HHMMSS.txt
    └── lima_summary.txt        # Overall summary

NOTES:
    - Lima is internally parallelised, so files are processed sequentially
    - The biosample CSV should have format: Barcodes,Bio Sample
    - BOM characters in CSV files are automatically stripped
    - Requires lima from bioconda (conda install -c bioconda lima)

EOF
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

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
            --resume)
                RESUME="$2"
                shift 2
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

#===============================================================================
# VALIDATION
#===============================================================================

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

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "Use --help for usage information"
        exit 1
    fi

    log_info "Validation complete"
}

#===============================================================================
# ENVIRONMENT SETUP
#===============================================================================

setup_environment() {
    log_info "Setting up environment..."

    # Detect and activate conda/micromamba environment
    if command -v micromamba &> /dev/null; then
        log_debug "Found micromamba"
        eval "$(micromamba shell hook --shell bash 2>/dev/null)" || true
        if micromamba activate py2 2>/dev/null; then
            log_debug "Activated py2 environment (micromamba)"
        else
            log_debug "Could not activate py2, trying base environment"
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
        if conda activate py2 2>/dev/null; then
            log_debug "Activated py2 environment (conda)"
        elif conda activate lima 2>/dev/null; then
            log_debug "Activated lima environment (conda)"
        else
            log_debug "Could not activate environment, assuming lima is in PATH"
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

#===============================================================================
# BIOSAMPLE CSV PREPROCESSING
#===============================================================================

preprocess_biosample_csv() {
    if [[ -z "${BIOSAMPLE_CSV}" ]]; then
        return 0
    fi

    log_info "Checking biosample CSV..."

    # Check for BOM character
    if head -c 3 "${BIOSAMPLE_CSV}" | grep -q $'\xef\xbb\xbf'; then
        log_warn "BOM character detected in biosample CSV"

        # Create cleaned copy in output directory
        local cleaned_csv="${DIR_OUT}/biosample_cleaned.csv"
        sed '1s/^\xEF\xBB\xBF//' "${BIOSAMPLE_CSV}" > "${cleaned_csv}"
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

#===============================================================================
# FIND INPUT FILES
#===============================================================================

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

#===============================================================================
# PROCESS SINGLE BAM FILE
#===============================================================================

process_bam() {
    local input_bam="$1"
    local bam_name
    bam_name=$(basename "${input_bam}" .bam)

    # Extract barcode suffix for output directory naming
    local barcode_suffix
    barcode_suffix=$(echo "${bam_name}" | grep -oE 'bc[0-9]+' | tail -1 || echo "")

    local output_subdir
    if [[ -n "${barcode_suffix}" ]]; then
        output_subdir="${DIR_OUT}/demux_${barcode_suffix}"
    else
        output_subdir="${DIR_OUT}/${bam_name}"
    fi

    local output_prefix="${bam_name}.demux"
    local output_bam="${output_subdir}/${output_prefix}.bam"

    echo ""
    log_info "Processing: ${bam_name}"
    log_info "  Input:  ${input_bam}"
    log_info "  Output: ${output_subdir}/"

    # Check if already processed (resume logic)
    if [[ "${RESUME}" == "TRUE" ]]; then
        local summary_file="${output_subdir}/${output_prefix}.lima.summary"
        if [[ -f "${summary_file}" ]]; then
            log_info "  Skipping (already processed, --resume TRUE)"
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
        return 0
    fi

    # Run lima
    if "${lima_cmd[@]}"; then
        log_info "  ✓ Complete"

        # Report summary statistics
        local summary_file="${output_subdir}/${output_prefix}.lima.summary"
        if [[ -f "${summary_file}" ]]; then
            local zmw_input zmw_pass
            zmw_input=$(grep "^ZMWs input" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "?")
            zmw_pass=$(grep "^ZMWs above all thresholds" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "?")
            log_info "  Stats: ${zmw_pass}/${zmw_input} reads passed filters"
        fi
        return 0
    else
        log_error "  ✗ Failed"
        return 1
    fi
}

#===============================================================================
# GENERATE SUMMARY
#===============================================================================

generate_summary() {
    local summary_file="${DIR_OUT}/lima_summary.txt"

    log_info "Generating summary..."

    {
        echo "Lima Pipeline Summary"
        echo "====================="
        echo ""
        echo "Date: $(date)"
        echo "Lima version: ${LIMA_VERSION}"
        echo ""
        echo "Parameters:"
        echo "  dir_data:      ${DIR_DATA}"
        echo "  dir_out:       ${DIR_OUT}"
        echo "  barcode_ref:   ${BARCODE_REF}"
        echo "  biosample_csv: ${BIOSAMPLE_CSV:-none}"
        echo "  lima_preset:   ${LIMA_PRESET}"
        echo "  lima_args:     ${LIMA_ARGS}"
        echo ""
        echo "Files processed: ${#INPUT_FILES[@]}"
        echo ""
        echo "Results:"

        for f in "${INPUT_FILES[@]}"; do
            local bam_name
            bam_name=$(basename "$f" .bam)
            local barcode_suffix
            barcode_suffix=$(echo "${bam_name}" | grep -oE 'bc[0-9]+' | tail -1 || echo "")

            local output_subdir
            if [[ -n "${barcode_suffix}" ]]; then
                output_subdir="${DIR_OUT}/demux_${barcode_suffix}"
            else
                output_subdir="${DIR_OUT}/${bam_name}"
            fi

            local summary="${output_subdir}/${bam_name}.demux.lima.summary"
            if [[ -f "${summary}" ]]; then
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

#===============================================================================
# SAVE PARAMETERS
#===============================================================================

save_parameters() {
    local params_file="${DIR_OUT}/logs/lima_params_$(date +%Y%m%d_%H%M%S).txt"

    mkdir -p "${DIR_OUT}/logs"

    {
        echo "Lima Pipeline Parameters"
        echo "========================"
        echo ""
        echo "Timestamp: $(date)"
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
        echo "# Execution"
        echo "resume=${RESUME}"
        echo "dry_run=${DRY_RUN}"
        echo "verbose=${VERBOSE}"
    } > "${params_file}"

    log_info "Parameters saved to: ${params_file}"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    local start_time
    start_time=$(date +%s)

    # Parse arguments
    parse_args "$@"

    # Show banner
    log_section "Lima Pipeline - PacBio Demultiplexing"

    # Validate
    validate_inputs

    # Create output directory
    mkdir -p "${DIR_OUT}"
    mkdir -p "${DIR_OUT}/logs"

    # Setup logging
    LOG_FILE="${DIR_OUT}/logs/lima_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${LOG_FILE}") 2>&1

    log_info "Log file: ${LOG_FILE}"

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

    for bam_file in "${INPUT_FILES[@]}"; do
        if process_bam "${bam_file}"; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
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
    log_info "Log file:    ${LOG_FILE}"

    if [[ ${failed} -gt 0 ]]; then
        log_warn "Some files failed to process. Check log for details."
        exit 1
    fi
}

# Run main
main "$@"
