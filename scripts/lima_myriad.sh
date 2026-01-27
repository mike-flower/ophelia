#!/bin/bash -l
#$ -S /bin/bash
#$ -N lima_demux
#$ -l h_rt=12:00:00
#$ -pe smp 8
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/lima
#$ -o logs/lima_$JOB_ID.out
#$ -e logs/lima_$JOB_ID.err
#$ -M michael.flower@ucl.ac.uk
#$ -m bea

# ==============================================================================
# Lima Pipeline - Myriad Job Script
# ==============================================================================
#
# This script runs the Lima demultiplexing pipeline on UCL's Myriad cluster.
# Edit the parameters in the ./lima command at the bottom.
#
# Cluster: Myriad (UCL)
# Scheduler: Grid Engine (SGE)
# Parallel environment: smp (shared memory)
#
# ==============================================================================
# RESOURCE RECOMMENDATIONS
# ==============================================================================
#
# Lima is well-parallelised. Recommended settings:
#
# Small run (1-4 BAM files, <100k reads each):
#   #$ -pe smp 8
#   #$ -l mem=4G
#   #$ -l h_rt=4:00:00
#
# Medium run (4-8 BAM files, ~500k reads each):
#   #$ -pe smp 16
#   #$ -l mem=4G
#   #$ -l h_rt=12:00:00
#
# Large run (8+ BAM files, >1M reads each):
#   #$ -pe smp 24
#   #$ -l mem=4G
#   #$ -l h_rt=24:00:00
#
# ==============================================================================
# SUBMISSION INSTRUCTIONS
# ==============================================================================
#
# 1. One-time setup (create conda environment):
#
#    module load python/miniconda3/24.3.0-0
#    source $UCL_CONDA_PATH/etc/profile.d/conda.sh
#    conda create -n lima -c bioconda lima
#
# 2. Edit parameters in the ./lima command below
#
# 3. Submit the job:
#    qsub scripts/lima_myriad.sh
#
# 4. Monitor the job:
#    qstat -u $USER
#    watch -n 30 'qstat -u $USER'
#
# 5. Check output:
#    tail -f logs/lima_$JOB_ID.out
#
# 6. Cancel job if needed:
#    qdel <JOB_ID>
#
# ==============================================================================

# Print job info
echo "=============================================="
echo "Lima Pipeline - Myriad Job"
echo "=============================================="
echo "Job ID:       $JOB_ID"
echo "Job Name:     $JOB_NAME"
echo "Host:         $(hostname)"
echo "Date:         $(date)"
echo "Working Dir:  $(pwd)"
echo "Cores:        $NSLOTS"
echo "=============================================="
echo ""

# Create logs directory if it doesn't exist
mkdir -p logs

# Load conda module and activate lima environment
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima

# Verify lima is available
echo "=== Environment Check ==="
echo "Conda env: $CONDA_DEFAULT_ENV"
echo "Lima version: $(lima --version 2>&1 | head -1)"
echo ""

# Change to Lima root directory (parent of scripts/)
cd ~/Scratch/bin/lima

# ==============================================================================
# EDIT PARAMETERS BELOW
# ==============================================================================

./lima \
    --dir_data /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/bam \
    --dir_out /home/skgtmdf/Scratch/data/2025.01.27_pb_demux/results \
    --barcode_ref /home/skgtmdf/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
    --biosample_csv /home/skgtmdf/Scratch/refs/pacbio/biosample.csv \
    --threads $NSLOTS \
    --resume TRUE \
    --lima_args "--split-named --store-unbarcoded"

# ==============================================================================
# EXAMPLE CONFIGURATIONS
# ==============================================================================

# Basic demultiplexing (known barcodes):
# ./lima \
#     --dir_data ~/Scratch/data/my_experiment/bam \
#     --dir_out ~/Scratch/data/my_experiment/demux \
#     --barcode_ref ~/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
#     --threads $NSLOTS

# With barcode inference (unknown barcodes):
# ./lima \
#     --dir_data ~/Scratch/data/my_experiment/bam \
#     --dir_out ~/Scratch/data/my_experiment/demux \
#     --barcode_ref ~/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
#     --threads $NSLOTS \
#     --lima_args "--split-named --store-unbarcoded --peek-guess"

# Process only specific barcode files:
# ./lima \
#     --dir_data ~/Scratch/data/my_experiment/bam \
#     --dir_out ~/Scratch/data/my_experiment/demux \
#     --barcode_ref ~/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
#     --file_pattern "*bc200[1-4].bam" \
#     --threads $NSLOTS

# Dry run (test without executing):
# ./lima \
#     --dir_data ~/Scratch/data/my_experiment/bam \
#     --dir_out ~/Scratch/data/my_experiment/demux \
#     --barcode_ref ~/Scratch/refs/pacbio/pacbio_M13_barcodes.fasta \
#     --dry_run

# ==============================================================================
# END OF SCRIPT
# ==============================================================================

echo ""
echo "=============================================="
echo "Lima pipeline complete!"
echo "Job finished: $(date)"
echo "=============================================="
