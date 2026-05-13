#!/bin/bash -l
#$ -S /bin/bash
#$ -N ophelia_demux
#$ -l h_rt=12:00:00
#$ -pe smp 8
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/ophelia    # <<< EDIT
#$ -o logs/ophelia_$JOB_ID.out
#$ -e logs/ophelia_$JOB_ID.err
#$ -M your.email@ucl.ac.uk                  # <<< EDIT
#$ -m bea

# This template is sized for a Small run (1-4 files, <100k reads each).
# For Medium/Large runs, bump -pe smp (12-24) and -l h_rt accordingly.
# See README "Resource recommendations" for guidance.

set -euo pipefail

# Print job info
echo "Job ID: $JOB_ID | Host: $(hostname) | Cores: $NSLOTS | $(date)"
echo ""

# Load conda so the 'conda' command is available; ophelia activates the lima env itself.
mkdir -p logs
module load python/miniconda3/24.3.0-0
source "${UCL_CONDA_PATH}/etc/profile.d/conda.sh"
echo ""

cd ~/Scratch/bin/ophelia

# ==============================================================================
# EDIT PARAMETERS BELOW
# (At minimum, update --dir_data, --dir_out, and --barcode_ref for your run)
# ==============================================================================

./ophelia \
    --dir_data /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/bam \
    --dir_out /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/results \
    --barcode_ref /home/skgtmdf/Scratch/bin/ophelia/www/pacbio_M13_barcodes.fasta \
    --threads "${NSLOTS}" \
    --reorganise by-type

# Optional extras (add to the ./ophelia invocation above, before the closing line):
#   --drop-unbarcoded   # delete unbarcoded BAMs (irreversible; saves disk space)
#   --biosample_csv /path/to/biosample.csv
#   --file_pattern "*bc20*.bam"
#   --lima_args "--split-named --store-unbarcoded --peek-guess"
#
# Other reorganise modes:
#   --reorganise by-sample        no reorganisation; raw lima output
#   --reorganise by-sample-type   per-sample dirs with type subdirs
#   --reorganise by-type-sample   pooled type dirs with per-sample subdirs

# ==============================================================================

echo ""
echo "Done: $(date)"
