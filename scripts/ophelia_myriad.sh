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

# Print job info
echo "Job ID: $JOB_ID | Host: $(hostname) | Cores: $NSLOTS | $(date)"
echo ""

# Environment
mkdir -p logs
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
echo "Lima: $(lima --version 2>&1 | head -1)"
echo ""

cd ~/Scratch/bin/ophelia

# ==============================================================================
# EDIT PARAMETERS BELOW
# ==============================================================================

./ophelia \
    --dir_data /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/bam \
    --dir_out /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/results \
    --barcode_ref /home/skgtmdf/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
    --threads $NSLOTS \
    --resume

# ==============================================================================

echo ""
echo "Done: $(date)"
