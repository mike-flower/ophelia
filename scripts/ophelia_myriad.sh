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
#$ -M michael.flower@ucl.ac.uk             # <<< EDIT
#$ -m bea

# See README for setup instructions and resource recommendations.

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
    --reorganise \
    --resume
    # Optional extras:
    #   --drop-unbarcoded   # delete unbarcoded BAMs (irreversible; saves disk space)
    #   --biosample_csv /path/to/biosample.csv
    #   --file_pattern "*bc20*.bam"
    #   --lima_args "--split-named --store-unbarcoded --peek-guess"

# ==============================================================================

echo ""
echo "Done: $(date)"
