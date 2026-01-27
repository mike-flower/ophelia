# Ophelia

A demultiplexing pipeline for PacBio HiFi amplicon sequencing data using PacBio's lima tool.

**Version 1.0.0**

---

## Quick Start

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results --barcode_ref ~/refs/barcodes.fasta
```

With sample renaming:
```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results --barcode_ref ~/refs/barcodes.fasta \
          --biosample_csv ~/refs/biosample.csv
```

---

## Table of Contents

- [Installation](#installation)
- [Input File Requirements](#input-file-requirements)
- [File Structure](#file-structure)
- [Run Analysis](#run-analysis)
  - [Command-Line Interface](#command-line-interface)
  - [HPC Deployment](#hpc-deployment)
- [Parameters](#parameters)
- [Output Structure](#output-structure)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)

---

## Installation

### AWS / Linux Server

```bash
# Using micromamba (recommended)
micromamba create -n lima -c bioconda lima
micromamba activate lima

# Or using conda
conda create -n lima -c bioconda lima
conda activate lima
```

### UCL Myriad

```bash
# One-time setup
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda create -n lima -c bioconda lima

# Each session
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

### Pipeline Setup

```bash
# Clone the ophelia pipeline
cd ~/Scratch/bin
git clone https://github.com/mike-flower/ophelia.git
cd ophelia

# Verify it's executable (should be from git)
./ophelia --help
```

---

## Input File Requirements

### Required Files

#### 1. Sequencing Data (BAM files)

**Location:** Specified by `--dir_data` parameter  
**Format:** PacBio HiFi BAM files (already demultiplexed by primary barcode)

```
data/
├── m84277_251024_160109_s2.hifi_reads.bc2001.bam
├── m84277_251024_160109_s2.hifi_reads.bc2002.bam
├── m84277_251024_160109_s2.hifi_reads.bc2003.bam
└── m84277_251024_160109_s2.hifi_reads.bc2004.bam
```

#### 2. Barcode Reference FASTA

**Location:** Specified by `--barcode_ref` parameter  
**Format:** FASTA file with barcode sequences

```fasta
>bc1002
ACACACAGACTGTGAG
>bc1003
ACACATCTCGTGAGAG
>bc1050
GATATACGCGAGAGAG
>bc1051
CGTGTCTAGCGCGCGC
```

### Optional Files

#### 3. Biosample CSV (for sample naming)

**Location:** Specified by `--biosample_csv` parameter  
**Format:** CSV mapping barcode pairs to sample names

```csv
Barcodes,Bio Sample
bc1002--bc1050,bcp1-A01-bc1002--bc1050
bc1002--bc1051,bcp1-A02-bc1002--bc1051
bc1003--bc1050,bcp1-B01-bc1003--bc1050
```

**Effect of `--biosample_csv`:**
- Without: Output files named by barcode (e.g., `bc1002--bc1050.bam`)
- With: Output files named by biosample (e.g., `bcp1-A01-bc1002--bc1050.bam`)
- Also sets the SM (sample) tag in BAM read groups

**Note:** The pipeline automatically strips UTF-8 BOM characters from CSV files (common when saving from Excel).

---

## File Structure

```
ophelia/
├── ophelia                   # Main wrapper script
├── scripts/
│   ├── ophelia_cli.sh        # Core pipeline logic
│   └── ophelia_myriad.sh     # HPC job submission script
└── README.md
```

---

## Run Analysis

### Command-Line Interface

**Basic usage:**
```bash
./ophelia --dir_data DIR --dir_out DIR --barcode_ref FILE [OPTIONS]
```

**Full example:**
```bash
./ophelia \
    --dir_data /path/to/bam \
    --dir_out /path/to/results \
    --barcode_ref /path/to/barcodes.fasta \
    --biosample_csv /path/to/biosample.csv \
    --threads 8
```

**View all options:**
```bash
./ophelia --help
```

### HPC Deployment

#### Job Submission (Myriad)

1. Edit parameters in `scripts/ophelia_myriad.sh`
2. Submit the job:
   ```bash
   qsub scripts/ophelia_myriad.sh
   ```

#### Monitoring Jobs

```bash
# Check job status
qstat -u $USER

# Watch job status (updates every 30s)
watch -n 30 'qstat -u $USER'

# View live output
tail -f logs/ophelia_$JOB_ID.out

# Cancel job
qdel <JOB_ID>
```

#### Resource Recommendations

| Run Size | Files | Reads/File | Cores | Memory | Runtime |
|----------|-------|------------|-------|--------|---------|
| Small    | 1-4   | <100k      | 8     | 4G     | 4h      |
| Medium   | 4-8   | ~500k      | 16    | 4G     | 12h     |
| Large    | 8+    | >1M        | 24    | 4G     | 24h     |

---

## Parameters

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `--dir_data` | Directory containing input BAM files |
| `--dir_out` | Output directory for results |
| `--barcode_ref` | Reference barcode FASTA file |

### Optional Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--biosample_csv` | none | CSV mapping barcodes to sample names |
| `--file_pattern` | `*.bam` | Glob pattern to match input files |
| `--threads` | auto | Number of threads for lima |

### Lima Arguments

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--lima_preset` | `ASYMMETRIC` | Lima HiFi preset (`ASYMMETRIC`, `SYMMETRIC`, `SYMMETRIC-ADAPTERS`) |
| `--lima_args` | `--split-named --store-unbarcoded` | Additional lima command-line arguments |

**Common lima arguments:**

| Argument | Description |
|----------|-------------|
| `--split-named` | Name output files by barcode names (not indices) |
| `--store-unbarcoded` | Keep reads that couldn't be assigned a barcode |
| `--peek-guess` | Infer which barcodes are present (for unknown samples) |
| `--dump-removed` | Save reads that were filtered out |

### Execution Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--resume` | `TRUE` | Skip files that have already been processed |
| `--dry_run` | `FALSE` | Show commands without executing |
| `--verbose` | `FALSE` | Enable debug output |

---

## Output Structure

```
dir_out/
├── demux_bc2001/                              # One folder per input BAM
│   ├── m84277_...bc2001.demux.bc1002--bc1050.bam
│   ├── m84277_...bc2001.demux.bc1002--bc1051.bam
│   ├── m84277_...bc2001.demux.bcp1-A01-bc1002--bc1050.bam  # (with biosample)
│   ├── m84277_...bc2001.demux.lima.summary    # Summary statistics
│   ├── m84277_...bc2001.demux.lima.report     # Detailed report
│   └── m84277_...bc2001.demux.lima.counts     # Per-barcode counts
├── demux_bc2002/
│   └── ...
├── logs/
│   ├── ophelia_20260127_143022.log            # Pipeline log
│   └── ophelia_params_20260127_143022.txt     # Saved parameters
└── ophelia_summary.txt                        # Overall summary
```

### Output Files

| File | Description |
|------|-------------|
| `*.demux.*.bam` | Demultiplexed BAM files (one per barcode pair) |
| `*.lima.summary` | Summary statistics (ZMWs processed, passed, etc.) |
| `*.lima.report` | Detailed per-read barcode assignments |
| `*.lima.counts` | Read counts per barcode pair |
| `ophelia_summary.txt` | Overall pipeline summary |

---

## Common Workflows

### 1. Basic Demultiplexing

When you know which barcode combinations are present:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta
```

### 2. With Sample Renaming

Files named by human-readable sample names instead of barcode pairs:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --biosample_csv ~/refs/biosample.csv
```

### 3. Unknown Barcodes

When you don't know which barcode combinations are present (lima will infer):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess"
```

### 4. Process Specific Files

Process only certain barcode files:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --file_pattern "*bc200[1-4].bam"
```

### 5. Test Run (Dry Run)

See what would happen without actually running:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --dry_run
```

### 6. Re-run Failed Files

The resume feature skips completed files:

```bash
# First run (some files fail)
./ophelia --dir_data ~/data/bam --dir_out ~/results ...

# Fix issues, then re-run (only processes failed files)
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --resume TRUE
```

To force re-processing of all files:

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --resume FALSE
```

---

## Troubleshooting

**"lima: command not found"**
```bash
# Activate conda environment
conda activate lima

# Or on Myriad:
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

**"scripts/ophelia_cli.sh not found"**
```bash
# Run from the ophelia root directory
cd ~/Scratch/bin/ophelia
./ophelia --help
```

**"No BAM files found"**
```bash
# Check files exist
ls /path/to/data/*.bam

# Try different pattern
./ophelia --dir_data /path/to/data --file_pattern "*.hifi_reads.*.bam" ...
```

**"Biosample CSV parsing error"**
```bash
# BOM character issue (common from Excel)
# The pipeline handles this automatically, but to check:
head -c 3 biosample.csv | xxd

# Manual fix if needed:
sed -i '1s/^\xEF\xBB\xBF//' biosample.csv
```

**"Low demultiplexing rate"**

Check the `*.lima.summary` file:
```bash
cat results/demux_bc2001/*.lima.summary
```

Common causes:
- Wrong barcode reference file
- Wrong `--lima_preset` (try `ASYMMETRIC` vs `SYMMETRIC`)
- Try `--peek-guess` to see which barcodes are actually present

**"Job killed on Myriad"**
```bash
# Request more resources in ophelia_myriad.sh:
#$ -l h_rt=24:00:00    # More time
#$ -pe smp 16          # More cores
#$ -l mem=8G           # More memory per core
```

---

## Key Differences: `--peek-guess` vs `--biosample_csv`

| Feature | `--peek-guess` | `--biosample_csv` |
|---------|----------------|-------------------|
| **Use when** | Unknown which barcodes are present | Known barcode-to-sample mapping |
| **Speed** | Slower (two-pass) | Faster (single-pass) |
| **Output naming** | By barcode pairs | By biosample name |
| **BAM SM tag** | Barcode pair | Biosample name |

**Note:** Don't combine `--peek-guess` with `--biosample_csv` — use one or the other.

---

## Contact

**Michael Flower**  
Senior Clinical Research Fellow  
Department of Neurodegenerative Disease  
UCL Queen Square Institute of Neurology  
London, UK

- Email: michael.flower@ucl.ac.uk
- GitHub: https://github.com/mike-flower

---

## Version History

### 1.0.0 (January 2026)
- Initial release
- Single script processes all BAMs in a directory
- Supports both AWS and Myriad HPC
- Pass-through of lima arguments via `--lima_args`
- Automatic BOM stripping for biosample CSV
- Resume capability for interrupted runs
- Comprehensive logging and parameter saving
