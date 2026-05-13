#!/bin/bash
#==============================================================================
# Ophelia - PacBio Demultiplexing Pipeline
#==============================================================================
#
# A wrapper for PacBio's lima tool for demultiplexing HiFi amplicon sequencing data.
# Processes all BAM files in a directory using PacBio's lima tool.
#
# Author: Michael Flower
# Institution: UCL Queen Square Institute of Neurology
# Version: 1.2.1
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

VERSION="1.2.1"

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

# Reorganisation mode. Valid values:
#   by-sample        no reorganisation (= omitting the flag)
#   by-sample-type   <sample>/{barcoded,reports,unbarcoded}/
#   by-type          dir_out/{barcoded,reports,unbarcoded}/
#   by-type-sample   dir_out/{barcoded,reports,unbarcoded}/<sample>/
# Empty string means "flag was not passed" (treated identically to by-sample).
REORGANISE=""
DROP_UNBARCODED="FALSE"

# Execution options
DRY_RUN="FALSE"
VERBOSE="FALSE"

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
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}==============================================${NC}"
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
    --threads N             Number of threads to pass to lima (default: 0, which omits
                            --num-threads entirely so lima picks – typically all visible
                            cores. On HPC pass an explicit value, e.g. "${NSLOTS}")

LIMA ARGUMENTS:
    --lima_preset PRESET    Lima HiFi preset (default: ASYMMETRIC)
                            Options: ASYMMETRIC, SYMMETRIC, SYMMETRIC-ADAPTERS
    --lima_args "ARGS"      Additional lima arguments (default: "--split-named --store-unbarcoded")
                            Common options:
                              --peek-guess        Infer which barcodes are present
                              --split-named       Name files by barcode names
                              --store-unbarcoded  Keep unassigned reads
                              --dump-clips        Save clipped barcode regions to *.lima.clips
                              --min-length N      Override minimum read length after clipping (default 50)

OUTPUT ORGANISATION:
    --reorganise MODE       Move output files into a tidier layout. MODE must be one of:
                              by-sample        no reorganisation; raw lima output
                                               (same as omitting the flag)
                              by-sample-type   per-sample dirs with type subdirs:
                                               <sample>/{barcoded,reports,unbarcoded}/
                              by-type          top-level type dirs, samples pooled flat:
                                               {barcoded,reports,unbarcoded}/
                              by-type-sample   top-level type dirs with per-sample subdirs:
                                               {barcoded,reports,unbarcoded}/<sample>/
    --drop-unbarcoded       Delete unbarcoded BAMs instead of moving them
                            (saves disk space; irreversible; requires --reorganise
                            to be set to a non-by-sample mode)

EXECUTION OPTIONS:
    --dry_run|--dry-run     Show what would be run without executing
    --verbose               Enable verbose output
    --help|-h               Show this help message

    Note: --reorganise also accepts --reorganize (American spelling).

EXAMPLES:

    # Basic demultiplexing (raw output, one dir per input BAM)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta

    # All samples pooled by file type (recommended for downstream pipelines like Duke)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise by-type
    # Then point downstream tools at ~/results/demux/barcoded/

    # Per-sample dirs with type subfolders (sample-centric view)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise by-sample-type

    # By type with per-sample subdirs (large-scale runs with many libraries)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise by-type-sample

    # Drop unbarcoded BAMs to save disk space (irreversible)
    ./ophelia \
        --dir_data ~/data/bam \
        --dir_out ~/results/demux \
        --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
        --reorganise by-type --drop-unbarcoded

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
        --reorganise by-type --dry-run

OUTPUT STRUCTURE:

    no --reorganise flag (or --reorganise by-sample) – raw lima output:
        dir_out/
        ├── m84277_...bc2001/
        │   ├── *.demux.bc1002--bc1050.bam
        │   ├── *.demux.unbarcoded.bam
        │   ├── *.lima.summary
        │   ├── *.lima.report
        │   └── *.lima.counts
        ├── m84277_...bc2002/
        │   └── ...
        └── ophelia_summary.txt

    --reorganise by-sample-type – per-sample dirs with type subdirs:
        dir_out/
        ├── m84277_...bc2001/
        │   ├── barcoded/    # *.demux.<bc1>--<bc2>.{bam,bam.pbi,xml}
        │   ├── reports/     # *.lima.summary, *.lima.report, *.lima.counts
        │   └── unbarcoded/  # *.demux.unbarcoded.* (omitted with --drop-unbarcoded)
        ├── m84277_...bc2002/
        │   └── ...
        └── ophelia_summary.txt

    --reorganise by-type – top-level type dirs, all samples pooled flat:
        dir_out/
        ├── barcoded/
        │   ├── m84277_...bc2001.demux.bc1002--bc1050.bam
        │   ├── m84277_...bc2002.demux.bc1003--bc1050.bam
        │   └── ...
        ├── reports/
        │   ├── m84277_...bc2001.demux.lima.summary
        │   └── ...
        ├── unbarcoded/      # omitted with --drop-unbarcoded
        │   └── ...
        └── ophelia_summary.txt

    --reorganise by-type-sample – top-level type dirs with per-sample subdirs:
        dir_out/
        ├── barcoded/
        │   ├── m84277_...bc2001/
        │   │   ├── *.demux.bc1002--bc1050.bam
        │   │   └── ...
        │   └── m84277_...bc2002/
        ├── reports/
        │   └── (same pattern)
        ├── unbarcoded/      # omitted with --drop-unbarcoded
        │   └── (same pattern)
        └── ophelia_summary.txt

    Logs (in ophelia installation directory):
    ophelia/logs/YYYYMMDD_HHMMSS/
    ├── ophelia.log
    └── ophelia_params.txt

NOTES:
    - Lima is internally parallelised, so files are processed sequentially.
    - The biosample CSV should have format: Barcodes,Bio Sample
    - BOM characters in CSV files are automatically stripped
    - Requires lima from bioconda (conda install -c bioconda lima)
    - If --dir_out already contains a reorganised layout (presence of
      barcoded/, reports/, or unbarcoded/ at top level or inside a sample
      dir), Ophelia refuses to run rather than risk producing mixed output.
      Delete --dir_out and re-invoke from scratch to re-process.
    - There is no resume option. Each invocation runs lima on every input BAM.
      For ad-hoc retrofitting of existing raw output into a reorganised
      layout without re-running lima, use scripts/reorganise_ophelia.sh.

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
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    log_error "--reorganise requires a mode value: --reorganise MODE"
                    log_error "Valid modes: by-sample, by-sample-type, by-type, by-type-sample"
                    exit 1
                fi
                REORGANISE="$2"
                shift 2
                ;;
            --drop-unbarcoded)
                DROP_UNBARCODED="TRUE"
                shift
                ;;
            --dry_run|--dry-run)
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
    if [[ ! "${THREADS}" =~ ^[0-9]+$ ]]; then
        log_error "--threads must be a non-negative integer, got: ${THREADS}"
        errors=$((errors + 1))
    fi

    # Validate lima preset
    local valid_presets=("ASYMMETRIC" "SYMMETRIC" "SYMMETRIC-ADAPTERS")
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

    # Validate reorganise mode (if set)
    if [[ -n "${REORGANISE}" ]]; then
        case "${REORGANISE}" in
            by-sample|by-sample-type|by-type|by-type-sample) ;;
            *)
                log_error "Invalid --reorganise mode: ${REORGANISE}"
                log_error "Valid modes: by-sample, by-sample-type, by-type, by-type-sample"
                errors=$((errors + 1))
                ;;
        esac
    fi

    # --drop-unbarcoded requires --reorganise to be set to a non-by-sample mode
    # (it operates on the unbarcoded/ subdir which only exists after reorganisation)
    if [[ "${DROP_UNBARCODED}" == "TRUE" ]]; then
        if [[ -z "${REORGANISE}" || "${REORGANISE}" == "by-sample" ]]; then
            log_error "--drop-unbarcoded requires --reorganise with mode by-sample-type, by-type, or by-type-sample"
            errors=$((errors + 1))
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "Use --help for usage information"
        exit 1
    fi

    log_info "Validation complete"
}

#==============================================================================
# DIR_OUT STATE CHECK
#
# Refuses to run if --dir_out already contains a reorganised layout. Mixing
# fresh lima output into an existing reorganised tree produces inconsistent
# state (new files reorganised, old reorganised files untouched, possible
# duplicates between layouts), so we require the user to clear it out first
# or point at a fresh path. A fresh dir_out, an empty one, or one with raw
# (flat) output from a prior run is all fine – lima will simply overwrite the
# old files with the new ones.
#==============================================================================

check_dir_out_state() {
    [[ -d "${DIR_OUT}" ]] || return 0   # fresh dir, nothing to check

    # Top-level layout (by-type / by-type-sample signature)
    local found_top=""
    if   [[ -d "${DIR_OUT}/barcoded"   ]]; then found_top="barcoded"
    elif [[ -d "${DIR_OUT}/reports"    ]]; then found_top="reports"
    elif [[ -d "${DIR_OUT}/unbarcoded" ]]; then found_top="unbarcoded"
    fi

    if [[ -n "${found_top}" ]]; then
        log_error "${DIR_OUT}/${found_top}/ exists – this indicates a previous run"
        log_error "produced a reorganised layout (by-type or by-type-sample)."
        log_error ""
        log_error "Ophelia refuses to run on an existing reorganised --dir_out to"
        log_error "avoid mixing fresh lima output with old reorganised files."
        log_error ""
        log_error "To re-run: delete ${DIR_OUT} and re-invoke from scratch, or"
        log_error "point --dir_out at a fresh path."
        exit 1
    fi

    # Per-sample layout (by-sample-type signature).
    # `shopt -p nullglob` exits 1 when nullglob is off; `|| true` keeps
    # set -e from killing the script while preserving the stdout for eval.
    local prev_nullglob
    prev_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob
    local sample_dir
    for sample_dir in "${DIR_OUT}"/*/; do
        if is_sample_reorganised "${sample_dir}"; then
            eval "${prev_nullglob}"
            log_error "${sample_dir} contains a reorganised layout (barcoded/,"
            log_error "reports/, or unbarcoded/ subdirectory) – this indicates a"
            log_error "previous run used --reorganise by-sample-type."
            log_error ""
            log_error "Ophelia refuses to run on an existing reorganised --dir_out to"
            log_error "avoid mixing fresh lima output with old reorganised files."
            log_error ""
            log_error "To re-run: delete ${DIR_OUT} and re-invoke from scratch, or"
            log_error "point --dir_out at a fresh path."
            exit 1
        fi
    done
    eval "${prev_nullglob}"
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
        elif [[ -n "${CONDA_PREFIX:-}" && -f "${CONDA_PREFIX}/etc/profile.d/conda.sh" ]]; then
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

    # Check lima is available. In dry-run we warn instead of exiting, so the
    # canonical "preview the run from my laptop before qsub" workflow works on
    # machines without lima installed.
    if ! command -v lima &> /dev/null; then
        if [[ "${DRY_RUN}" == "TRUE" ]]; then
            log_warn "lima not found in PATH – an actual run would fail here"
            LIMA_VERSION="(unknown - dry run)"
            return 0
        fi
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

    # Validate CSV format. Done up front against the original path so it
    # works even in dry-run (where we substitute BIOSAMPLE_CSV below without
    # actually writing the cleaned copy). The header regex tolerates a BOM
    # prefix on the first line.
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

    # Check for BOM character and create a cleaned copy if found.
    # Uses perl for cross-platform compatibility (BSD sed does not support hex escapes).
    if head -c 3 "${BIOSAMPLE_CSV}" | grep -q $'\xef\xbb\xbf'; then
        log_warn "BOM character detected in biosample CSV"

        local cleaned_csv="${DIR_OUT}/biosample_cleaned.csv"
        if [[ "${DRY_RUN}" == "TRUE" ]]; then
            log_info "  [DRY RUN] Would create BOM-stripped copy at ${cleaned_csv}"
            # Point BIOSAMPLE_CSV at the would-be cleaned copy so the dry-run
            # lima command preview matches what an actual run would execute.
            BIOSAMPLE_CSV="${cleaned_csv}"
        else
            perl -pe 's/^\xEF\xBB\xBF//' "${BIOSAMPLE_CSV}" > "${cleaned_csv}"
            log_info "Created BOM-stripped copy: ${cleaned_csv}"
            BIOSAMPLE_CSV="${cleaned_csv}"
        fi
    fi
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
# Skips the call entirely for by-sample (no-op) and empty REORGANISE.
#==============================================================================

should_reorganise() {
    [[ -n "${REORGANISE}" && "${REORGANISE}" != "by-sample" ]]
}

reorganise_with_logging() {
    local sample_dir="$1"
    local label="${2:-Reorganised}"

    should_reorganise || return 0

    local drop_flag=0
    [[ "${DROP_UNBARCODED}" == "TRUE" ]] && drop_flag=1

    local dry_flag=0
    [[ "${DRY_RUN}" == "TRUE" ]] && dry_flag=1

    if reorganise_sample_dir "${sample_dir}" "${REORGANISE}" "${DIR_OUT}" \
            "${drop_flag}" "${dry_flag}"; then
        # Only log if at least one file was touched
        local total=$((REORG_BARCODED + REORG_REPORTS + REORG_UNBARCODED + REORG_DROPPED))
        if [[ ${total} -gt 0 ]]; then
            local msg="  ${label} (${REORGANISE}): barcoded=${REORG_BARCODED}, reports=${REORG_REPORTS}, unbarcoded=${REORG_UNBARCODED}"
            if [[ "${DROP_UNBARCODED}" == "TRUE" ]]; then
                msg="${msg}, dropped=${REORG_DROPPED}"
            fi
            log_info "${msg}"
        fi
    else
        log_debug "  Reorganise skipped (no sample dir or invalid mode): ${sample_dir}"
    fi
}

#==============================================================================
# PROCESS SINGLE BAM FILE
#==============================================================================

process_bam() {
    local input_bam="$1"
    local bam_name
    bam_name=$(basename "${input_bam}" .bam)

    # Output directory: bare BAM basename, no prefix (breaking change from 1.1.x)
    local output_subdir
    output_subdir="${DIR_OUT}/${bam_name}"

    local output_prefix="${bam_name}.demux"
    local output_bam="${output_subdir}/${output_prefix}.bam"

    echo ""
    log_info "Processing: ${bam_name}"
    log_info "  Input:  ${input_bam}"
    log_info "  Output: ${output_subdir}/"

    # Create output directory
    if [[ "${DRY_RUN}" != "TRUE" ]]; then
        mkdir -p "${output_subdir}"
    fi

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
        if should_reorganise; then
            log_info "  [DRY RUN] Would then reorganise output (${REORGANISE})"
        fi
        return 0
    fi

    # Run lima
    if "${lima_cmd[@]}"; then
        log_info "  ✓ Complete"

        # Report summary statistics (read from the flat location – lima just wrote there)
        local summary_file="${output_subdir}/${output_prefix}.lima.summary"
        if [[ -f "${summary_file}" ]]; then
            local reads_input reads_pass
            reads_input=$(grep -E "^(ZMWs|Reads) input" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "0")
            reads_pass=$(grep -E "^(ZMWs|Reads) above all thresholds" "${summary_file}" | grep -oE '[0-9]+' | head -1 || echo "0")
            log_info "  Stats: ${reads_pass}/${reads_input} reads passed filters"
        fi

        # Reorganise this sample's output if requested
        reorganise_with_logging "${output_subdir}" "Reorganised"

        return 0
    else
        log_error "  ✗ Failed: ${bam_name}"
        return 1
    fi
}

#==============================================================================
# GENERATE SUMMARY
# Uses locate_summary_file to find the summary regardless of which layout
# the run ended up in.
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
        echo "  reorganise:      ${REORGANISE:-by-sample (default)}"
        echo "  drop_unbarcoded: ${DROP_UNBARCODED}"
        echo ""
        echo "Files processed: ${#INPUT_FILES[@]}"
        echo ""
        echo "Results:"

        for f in "${INPUT_FILES[@]}"; do
            local bam_name
            bam_name=$(basename "$f" .bam)

            # Layout-aware lookup for the summary file (across all reorganise modes)
            local summary
            summary=$(locate_summary_file "${DIR_OUT}" "${bam_name}")
            if [[ -n "${summary}" ]]; then
                local reads_input reads_pass pct
                reads_input=$(grep -E "^(ZMWs|Reads) input" "${summary}" | grep -oE '[0-9]+' | head -1 || echo "0")
                reads_pass=$(grep -E "^(ZMWs|Reads) above all thresholds" "${summary}" | grep -oE '[0-9]+' | head -1 || echo "0")
                if [[ "${reads_input}" -gt 0 ]]; then
                    pct=$(awk "BEGIN {printf \"%.1f\", ${reads_pass}/${reads_input}*100}")
                else
                    pct="0.0"
                fi
                echo "  ${bam_name}: ${reads_pass}/${reads_input} (${pct}%)"
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
        echo "reorganise=${REORGANISE:-by-sample (default)}"
        echo "drop_unbarcoded=${DROP_UNBARCODED}"
        echo ""
        echo "# Execution"
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

    # Refuse to overwrite an existing reorganised dir_out
    check_dir_out_state

    # Create output directory (skip in dry-run to keep it side-effect-free)
    if [[ "${DRY_RUN}" == "TRUE" ]]; then
        log_info "Output directory: ${DIR_OUT} (would be created – dry run)"
    else
        mkdir -p "${DIR_OUT}"
        log_info "Output directory: ${DIR_OUT}"
    fi

    # Announce the layout we'll write
    if should_reorganise; then
        local layout_msg="Output layout: ${REORGANISE}"
        if [[ "${DROP_UNBARCODED}" == "TRUE" ]]; then
            layout_msg="${layout_msg} (unbarcoded files will be DELETED)"
        fi
        log_info "${layout_msg}"
    else
        log_info "Output layout: by-sample (raw lima output, no reorganisation)"
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
