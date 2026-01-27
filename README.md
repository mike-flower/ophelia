# Ophelia

A demultiplexing pipeline for PacBio HiFi amplicon sequencing data using PacBio's lima tool.

**Version 1.0.0**

---

## Quick Start

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results --barcode_ref ~/refs/barcodes.fasta
```

With custom sample names in BAM headers:
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
  - [HPC Deployment (Myriad)](#hpc-deployment-myriad)
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

**Note:** Lima is a compiled C++ binary — it doesn't require Python. Conda/bioconda is just the distribution mechanism.

### Pipeline Setup

```bash
# Clone the ophelia pipeline
cd ~/Scratch/bin
git clone https://github.com/mike-flower/ophelia.git
cd ophelia

# Create logs directory (required for Myriad SGE job output)
mkdir -p logs

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

#### 3. Biosample CSV (for custom sample names)

**Location:** Specified by `--biosample_csv` parameter  
**Format:** CSV mapping barcode pairs to sample names

```csv
Barcodes,Bio Sample
bc1002--bc1050,bcp1-A01-bc1002--bc1050
bc1002--bc1051,bcp1-A02-bc1002--bc1051
bc1003--bc1050,bcp1-B01-bc1003--bc1050
```

**What `--biosample_csv` does:**

| Aspect | Without `--biosample_csv` | With `--biosample_csv` |
|--------|---------------------------|------------------------|
| **Output filenames** | `bc1002--bc1050.bam` | `bc1002--bc1050.bam` (unchanged) |
| **BAM SM tag** | `SM:bc1002--bc1050` | `SM:bcp1-A01-bc1002--bc1050` |

The biosample CSV sets the **SM (sample) tag in the BAM read group header**, not the filename. This is what downstream tools (variant callers, Duke pipeline, etc.) use to identify samples.

To verify the SM tag is set correctly:
```bash
samtools view -H output.bam | grep "^@RG"
# Look for SM:bcp1-A01-bc1002--bc1050
```

**Note on BOM characters:** The pipeline automatically strips UTF-8 BOM (Byte Order Mark) characters from CSV files. BOM is an invisible character (`EF BB BF` in hex) that Microsoft Excel adds to the beginning of CSV files. Many Unix tools (including lima) don't expect it and will fail to parse the header correctly. Ophelia detects this and creates a cleaned copy automatically.

---

## File Structure

```
ophelia/
├── ophelia                   # Main wrapper script
├── scripts/
│   ├── ophelia_cli.sh        # Core pipeline logic
│   └── ophelia_myriad.sh     # HPC job submission script
├── logs/                     # Pipeline logs (created automatically)
│   ├── 20260127_143022/      # Timestamped run directories
│   │   ├── ophelia.log
│   │   └── ophelia_params.txt
│   └── ...
├── www/                      # Reference files (barcodes, biosample CSV)
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

**Dry run (test without executing):**
```bash
./ophelia \
    --dir_data /path/to/bam \
    --dir_out /path/to/results \
    --barcode_ref /path/to/barcodes.fasta \
    --dry_run
```

### HPC Deployment (Myriad)

#### First-Time Setup

```bash
# 1. Create conda environment (one-time)
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda create -n lima -c bioconda lima

# 2. Clone the pipeline
cd ~/Scratch/bin
git clone https://github.com/mike-flower/ophelia.git
cd ophelia

# 3. Create logs directory for SGE job output (REQUIRED before job submission)
mkdir -p logs
```

**Note:** The `logs/` directory serves two purposes:
- SGE writes job stdout/stderr here (`ophelia_<JOB_ID>.out/.err`)
- Pipeline creates timestamped subdirectories for run logs (`logs/20260127_143022/ophelia.log`)

#### Job Submission

1. Copy and edit the Myriad template:
   ```bash
   cp scripts/ophelia_myriad.sh scripts/ophelia_myriad_myrun.sh
   nano scripts/ophelia_myriad_myrun.sh  # Edit parameters
   ```

2. **Important:** Ensure the logs directory exists (SGE creates log files before the script runs):
   ```bash
   mkdir -p logs
   ```

3. Submit the job:
   ```bash
   qsub scripts/ophelia_myriad_myrun.sh
   ```

#### Example Myriad Job Script

```bash
#!/bin/bash -l
#$ -S /bin/bash
#$ -N ophelia_demux
#$ -l h_rt=12:00:00
#$ -pe smp 12
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/ophelia
#$ -o logs/ophelia_$JOB_ID.out
#$ -e logs/ophelia_$JOB_ID.err
#$ -M your.email@ucl.ac.uk
#$ -m bea

# Load environment
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima

# Change to ophelia directory
cd ~/Scratch/bin/ophelia

# Run pipeline
./ophelia \
    --dir_data /home/skgtmdf/Scratch/data/my_experiment/bam \
    --dir_out /home/skgtmdf/Scratch/data/my_experiment/result_ophelia \
    --barcode_ref /home/skgtmdf/Scratch/bin/ophelia/www/pacbio_M13_barcodes.fasta \
    --biosample_csv /home/skgtmdf/Scratch/bin/ophelia/www/biosample.csv \
    --file_pattern "*bc20*.bam" \
    --threads $NSLOTS \
    --resume TRUE
```

#### Monitoring Jobs

```bash
# Check job status
qstat -u $USER

# Watch job status (updates every 30s)
watch -n 30 'qstat -u $USER'

# Check job details (useful for debugging)
qstat -j <JOB_ID>

# View live output (after job starts)
tail -f logs/ophelia_<JOB_ID>.out

# Cancel job
qdel <JOB_ID>
```

#### Resource Recommendations

| Run Size | Files | Reads/File | Cores | Memory | Runtime |
|----------|-------|------------|-------|--------|---------|
| Small    | 1-4   | <100k      | 8     | 4G     | 4h      |
| Medium   | 4-8   | ~500k      | 12    | 4G     | 12h     |
| Large    | 8+    | >1M        | 16-24 | 4G     | 24h     |

Lima is well-parallelised internally. Memory usage is typically low (4G per core is usually sufficient).

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
| `--biosample_csv` | none | CSV mapping barcodes to sample names (sets SM tag in BAM) |
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
| `--split-named` | Name output files by barcode names (`bc1002--bc1050.bam`) instead of indices (`0--12.bam`) |
| `--store-unbarcoded` | Keep reads that couldn't be assigned a barcode |
| `--peek-guess` | Infer which barcodes are present (slower, two-pass) |
| `--dump-removed` | Save reads that were filtered out |

### Execution Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--resume` | `TRUE` | Skip files that have already been processed |
| `--dry_run` | `FALSE` | Show commands without executing |
| `--verbose` | `FALSE` | Enable debug output |

---

## Output Structure

**Pipeline logs** (in ophelia installation directory):
```
ophelia/logs/
├── 20260127_143022/                           # Timestamped run directory
│   ├── ophelia.log                            # Full pipeline log
│   └── ophelia_params.txt                     # Parameters used
├── 20260127_160045/
│   ├── ophelia.log
│   └── ophelia_params.txt
```

**Results** (in your specified output directory):
```
dir_out/
├── demux_bc2001/                              # One folder per input BAM
│   ├── m84277_...bc2001.demux.bc1002--bc1050.bam
│   ├── m84277_...bc2001.demux.bc1002--bc1051.bam
│   ├── m84277_...bc2001.demux.unbarcoded.bam  # Unassigned reads
│   ├── m84277_...bc2001.demux.lima.summary    # Summary statistics
│   ├── m84277_...bc2001.demux.lima.report     # Detailed report
│   └── m84277_...bc2001.demux.lima.counts     # Per-barcode counts
├── demux_bc2002/
│   └── ...
├── biosample_cleaned.csv                      # BOM-stripped CSV (if applicable)
└── ophelia_summary.txt                        # Overall demux summary
```

### Output Files

**In results directory:**

| File | Description |
|------|-------------|
| `*.demux.*.bam` | Demultiplexed BAM files (one per barcode pair) |
| `*.demux.unbarcoded.bam` | Reads that couldn't be assigned to a barcode pair |
| `*.lima.summary` | Summary statistics (ZMWs processed, passed, etc.) |
| `*.lima.report` | Detailed per-read barcode assignments |
| `*.lima.counts` | Read counts per barcode pair |
| `ophelia_summary.txt` | Overall demux summary (pass rates per file) |

**In ophelia/logs/YYYYMMDD_HHMMSS/:**

| File | Description |
|------|-------------|
| `ophelia.log` | Complete pipeline log with timestamps |
| `ophelia_params.txt` | All parameters used for the run |

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

Output files will be named by barcode pairs (e.g., `bc1002--bc1050.bam`) and the BAM SM tag will also be the barcode pair.

### 2. With Custom Sample Names (SM tag)

Set human-readable sample names in the BAM read group header:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --biosample_csv ~/refs/biosample.csv
```

Output filenames remain barcode pairs, but the SM tag in the BAM header will be the biosample name. This is what downstream tools use for sample identification.

### 3. Unknown Barcodes

When you don't know which barcode combinations are present (lima will infer):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess"
```

**Note:** `--peek-guess` is slower (two-pass) and should not be combined with `--biosample_csv`.

### 4. Process Specific Files

Process only certain barcode files (e.g., exclude `unassigned.bam`):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --file_pattern "*bc20*.bam"
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

### 6. Resume After Interruption

The `--resume TRUE` option (default) skips files that have already been processed. Ophelia checks for the existence of `.lima.summary` files to determine completion.

```bash
# First run (interrupted or some files fail)
./ophelia --dir_data ~/data/bam --dir_out ~/results ...

# Re-run (only processes incomplete files)
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --resume TRUE
```

To force re-processing of all files:

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --resume FALSE
```

---

## Troubleshooting

### "lima: command not found"

```bash
# Activate conda environment
conda activate lima

# Or on Myriad:
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

### "scripts/ophelia_cli.sh not found"

```bash
# Run from the ophelia root directory
cd ~/Scratch/bin/ophelia
./ophelia --help
```

### "can't open output file ... logs/ophelia_XXX.out: No such file or directory" (Myriad)

SGE creates log files **before** the job script runs, so the logs directory must exist beforehand:

```bash
cd ~/Scratch/bin/ophelia
mkdir -p logs
qsub scripts/ophelia_myriad.sh
```

### "No BAM files found"

```bash
# Check files exist
ls /path/to/data/*.bam

# Try different pattern
./ophelia --dir_data /path/to/data --file_pattern "*.hifi_reads.*.bam" ...
```

### "Biosample CSV parsing error" or sample names not appearing

The pipeline automatically handles BOM characters, but you can check manually:

```bash
# Check for BOM (will show ef bb bf at start if present)
head -c 3 biosample.csv | xxd

# Manual fix if needed
sed -i '1s/^\xEF\xBB\xBF//' biosample.csv
```

**What is BOM?** BOM (Byte Order Mark) is an invisible character (`EF BB BF` in hex) that Microsoft Excel and some Windows programs add to the beginning of UTF-8 files. Lima and many Unix tools don't expect it, causing the header to be misread. Ophelia automatically creates a BOM-stripped copy (`biosample_cleaned.csv`) in the output directory.

### "Low demultiplexing rate"

Check the `*.lima.summary` file:
```bash
cat results/demux_bc2001/*.lima.summary
```

Common causes:
- Wrong barcode reference file
- Wrong `--lima_preset` (try `ASYMMETRIC` vs `SYMMETRIC`)
- Try `--peek-guess` to see which barcodes are actually present

### Checking Pipeline Logs

```bash
# List all runs
ls ~/Scratch/bin/ophelia/logs/

# View most recent log
ls -t ~/Scratch/bin/ophelia/logs/ | head -1 | xargs -I {} cat ~/Scratch/bin/ophelia/logs/{}/ophelia.log

# Check for errors in a specific run
grep -i "error\|failed" ~/Scratch/bin/ophelia/logs/20260127_143022/ophelia.log

# View parameters used
cat ~/Scratch/bin/ophelia/logs/20260127_143022/ophelia_params.txt
```

### "Job killed on Myriad"

Request more resources in your job script:
```bash
#$ -l h_rt=24:00:00    # More time
#$ -pe smp 16          # More cores
#$ -l mem=8G           # More memory per core
```

### Checking BAM SM tags

To verify the biosample CSV worked correctly:
```bash
module load samtools  # Or: conda install -n lima -c bioconda samtools
samtools view -H output.bam | grep "^@RG"
```

Look for `SM:bcp1-A01-bc1002--bc1050` (your biosample name) rather than `SM:bc1002--bc1050` (barcode pair).

---

## Key Differences: `--peek-guess` vs `--biosample_csv`

| Feature | `--peek-guess` | `--biosample_csv` |
|---------|----------------|-------------------|
| **Use when** | Unknown which barcodes are present | Known barcode-to-sample mapping |
| **Speed** | Slower (two-pass) | Faster (single-pass) |
| **Output naming** | By barcode pairs | By barcode pairs |
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

### 1.0.1 (January 2026)
- Moved pipeline logs to `ophelia/logs/` with timestamped subdirectories
- Consistent log filenames: `ophelia.log` and `ophelia_params.txt`
- Results summary (`ophelia_summary.txt`) now in output directory only

### 1.0.0 (January 2026)
- Initial release
- Single script processes all BAMs in a directory
- Supports both AWS and Myriad HPC
- Pass-through of lima arguments via `--lima_args`
- Automatic BOM stripping for biosample CSV
- Resume capability for interrupted runs
- Comprehensive logging and parameter saving
