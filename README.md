# Ophelia

**PacBio HiFi amplicon demultiplexing pipeline**  
Version 1.0.2

Ophelia is a wrapper around PacBio's [lima](https://lima.how/) tool. It takes a directory of primary-barcoded HiFi BAM files and demultiplexes them into one BAM per sample using a dual-barcode scheme. It handles multiple input BAMs in a single run, logs everything, and supports resuming interrupted jobs.

---

## Table of contents

- [Installation](#installation)
- [Input files](#input-files)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [Output](#output)
- [Common workflows](#common-workflows)
- [HPC deployment (Myriad)](#hpc-deployment-myriad)
- [Troubleshooting](#troubleshooting)
- [Contact](#contact)
- [Version history](#version-history)

---

## Installation

### Step 1 — Install lima

Lima is distributed via bioconda. Install it into a dedicated conda environment:

**Linux / AWS:**
```bash
# Using micromamba (recommended)
micromamba create -n lima -c bioconda lima
micromamba activate lima

# Or using conda
conda create -n lima -c bioconda lima
conda activate lima
```

**UCL Myriad (one-time setup):**
```bash
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda create -n lima -c bioconda lima -y
```

> Lima is a compiled C++ binary — it doesn't require Python. Conda/bioconda is just the distribution mechanism.

### Step 2 — Clone Ophelia

```bash
cd ~/Scratch/bin
git clone https://github.com/mike-flower/ophelia.git
cd ophelia

# Create logs directory (required before first run)
mkdir -p logs

# Verify the pipeline is executable
./ophelia --help
```

> The `logs/` directory must exist before running. On Myriad, SGE writes job stdout/stderr here before the pipeline script starts.

---

## Input files

You need two files to run Ophelia. A third is optional.

### 1. HiFi BAM files (required)

Primary-barcoded BAM files from a PacBio HiFi run. These are the per-instrument-barcode BAMs produced by the sequencer — Ophelia applies a second round of demultiplexing using your sample barcodes.

Specify the directory containing these files with `--dir_data`.

```
data/
├── m84277_251024_160109_s2.hifi_reads.bc2001.bam
├── m84277_251024_160109_s2.hifi_reads.bc2002.bam
├── m84277_251024_160109_s2.hifi_reads.bc2003.bam
└── m84277_251024_160109_s2.hifi_reads.bc2004.bam
```

### 2. Barcode reference FASTA (required)

A FASTA file listing the barcode sequences you used for your samples. Specify with `--barcode_ref`.

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

A reference file for PacBio M13 barcodes is included in `www/pacbio_M13_barcodes.fasta`.

### 3. Biosample CSV (optional)

**Most users don't need this.** By default, output files are named by barcode pair (e.g. `bc1002--bc1050.bam`), which is the recommended way to track samples.

Use `--biosample_csv` only if a downstream tool specifically requires a custom sample name in the BAM `@RG SM:` tag. It does **not** rename the output files — only the SM tag is changed.

```csv
Barcodes,Bio Sample
bc1002--bc1050,bcp1-A01-bc1002--bc1050
bc1002--bc1051,bcp1-A02-bc1002--bc1051
bc1003--bc1050,bcp1-B01-bc1003--bc1050
```

| | Without `--biosample_csv` | With `--biosample_csv` |
|---|---|---|
| **Output filename** | `bc1002--bc1050.bam` | `bc1002--bc1050.bam` (unchanged) |
| **BAM `@RG SM:` tag** | Preserved from sequencing setup (e.g. `SM:lib_05`) | Overwritten with biosample name |

> **BOM characters:** If you create your CSV in Microsoft Excel, it may add an invisible UTF-8 BOM character (`EF BB BF`) to the start of the file. Ophelia detects and strips this automatically.

---

## Quick start

Activate your lima environment, then run:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta
```

Output files are named by barcode pair: `bc1002--bc1050.bam`, `bc1002--bc1051.bam`, etc.

**Not sure what will happen? Do a dry run first:**

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --dry_run
```

This shows exactly what lima commands would be run, without touching any files.

---

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `--dir_data DIR` | Directory containing input BAM files |
| `--dir_out DIR` | Directory for output files (created if it doesn't exist) |
| `--barcode_ref FILE` | Barcode reference FASTA file |

### Optional — input selection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--file_pattern GLOB` | `*.bam` | Glob pattern for selecting BAM files to process |
| `--threads N` | Auto-detect | Number of CPU threads for lima |
| `--biosample_csv FILE` | *(none)* | CSV to override BAM `@RG SM:` tag (does not rename files) |

### Optional — lima behaviour

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--lima_preset PRESET` | `ASYMMETRIC` | HiFi barcode preset: `ASYMMETRIC`, `SYMMETRIC`, `SYMMETRIC-ADAPTERS`, or `TAILED` |
| `--lima_args "ARGS"` | `--split-named --store-unbarcoded` | Additional arguments passed directly to lima |

**Common lima argument additions:**

| Argument | Description |
|----------|-------------|
| `--split-named` | Name output files by barcode name (`bc1002--bc1050.bam`) rather than index (`0--12.bam`) — included by default |
| `--store-unbarcoded` | Keep reads that couldn't be assigned a barcode — included by default |
| `--peek-guess` | Restrict demux to barcodes detected in the first 50,000 reads (two-pass, slower). Reduces spurious low-count output BAMs and can infer unknown barcode sets — recommended for most runs |
| `--dump-removed` | Save reads that were filtered out |

### Optional — execution

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--resume` | on | Skip BAM files whose output already exists and looks complete |
| `--no-resume` | — | Force re-processing of all files |
| `--dry_run` | — | Print commands without executing anything |
| `--verbose` | — | Enable debug output |

---

## Output

### Results directory

Ophelia creates one subdirectory per input BAM file:

```
dir_out/
├── demux_m84277_260126_193703_s3.hifi_reads.bc2001/     # One folder per input BAM
│   ├── m84277_...bc2001.demux.bc1002--bc1050.bam         # Demultiplexed BAM (one per barcode pair)
│   ├── m84277_...bc2001.demux.bc1002--bc1051.bam
│   ├── m84277_...bc2001.demux.unbarcoded.bam             # Reads that couldn't be assigned
│   ├── m84277_...bc2001.demux.lima.summary               # Pass/fail statistics
│   ├── m84277_...bc2001.demux.lima.report                # Per-read barcode assignments
│   └── m84277_...bc2001.demux.lima.counts                # Read counts per barcode pair
├── demux_m84277_260126_193703_s3.hifi_reads.bc2002/
│   └── ...
├── biosample_cleaned.csv                                 # BOM-stripped CSV (only if applicable)
└── ophelia_summary.txt                                   # Overall pass rates across all input files
```

**File descriptions:**

| File | Description |
|------|-------------|
| `*.demux.*.bam` | Demultiplexed reads for one barcode pair — these are your sample BAMs |
| `*.demux.unbarcoded.bam` | Reads that could not be assigned to any barcode pair |
| `*.lima.summary` | High-level statistics: ZMWs input, passed, failed |
| `*.lima.report` | Detailed per-read barcode assignment information |
| `*.lima.counts` | Read counts per barcode pair |
| `ophelia_summary.txt` | One-line summary per input BAM showing overall pass rate |

### Pipeline logs

Timestamped logs are saved in the Ophelia installation directory, independently of your output directory:

```
ophelia/logs/
├── 20260127_143022/
│   ├── ophelia.log          # Full pipeline log (plain text, no ANSI codes)
│   └── ophelia_params.txt   # All parameters used for this run
├── 20260127_160045/
│   └── ...
```

Each run creates a new timestamped subdirectory, so logs from previous runs are never overwritten.

### Repository structure

```
ophelia/
├── ophelia                   # Main wrapper script (run this)
├── scripts/
│   ├── ophelia_cli.sh        # Core pipeline logic
│   └── ophelia_myriad.sh     # Myriad HPC job submission template
├── logs/                     # Pipeline logs (created automatically)
├── www/                      # Reference files (barcode FASTA, example biosample CSV)
└── README.md
```

---

## Common workflows

### 1. Basic demultiplexing

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta
```

### 2. Process only specific input files

Use `--file_pattern` to restrict which BAMs are processed. For example, to process only `bc2001` and `bc2002`:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --file_pattern "*bc200[1-2].bam"
```

### 3. Filter spurious barcode pairs (recommended)

By default, lima writes a separate output BAM for every barcode pair it scores above threshold, including low-count pairs from cross-talk, sequencing noise, or partial adapters. With a large barcode set this can balloon the output to hundreds of mostly-empty files per input BAM and exhaust disk quotas.

`--peek-guess` runs lima in two passes: it scores the first 50,000 reads to identify which barcode pairs are actually present (mean score ≥ 45, ≥ 10 supporting reads), then demultiplexes the full file against only those pairs. The result is a cleaner, smaller output set with one BAM per real sample.

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess"
```

Use this:
- For routine runs where you want clean output without spurious low-count BAMs (recommended)
- When you're not sure which barcode combinations are present in your data

The trade-off is runtime — `--peek-guess` is slower because lima reads the input twice.

### 4. Resume after interruption

Resume is on by default. If a run is interrupted (job killed, node failure, etc.), just resubmit with the same command — files with a complete `.lima.summary` are skipped automatically.

```bash
# Original run (interrupted)
./ophelia --dir_data ~/data/bam --dir_out ~/results ...

# Resubmit — only incomplete files are reprocessed
./ophelia --dir_data ~/data/bam --dir_out ~/results ...
```

To force all files to be reprocessed regardless:

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --no-resume
```

### 5. Override BAM sample names

If a downstream tool requires a specific sample name in the BAM `@RG SM:` tag:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --biosample_csv ~/refs/biosample.csv
```

This overrides the SM tag but does not rename the output files. Check the result with:

```bash
module load samtools
samtools view -H output.bam | grep "^@RG"
# Example: SM:bcp1-A01-bc1002--bc1050
```

Key `@RG` fields:

| Field | Description |
|-------|-------------|
| `SM:` | Sample name — from sequencing setup by default; overridden by `--biosample_csv` |
| `LB:` | Library name from sequencing setup |
| `BC:` | Actual barcode sequences detected by lima |

---

## HPC deployment (Myriad)

### One-time setup

```bash
# 1. Load conda and create the lima environment
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda create -n lima -c bioconda lima -y

# 2. Clone the pipeline
cd ~/Scratch/bin
git clone https://github.com/mike-flower/ophelia.git
cd ophelia

# 3. Create the logs directory (SGE requires this to exist before job submission)
mkdir -p logs
```

### Submitting a job

1. Copy the template and edit your parameters:
   ```bash
   cp scripts/ophelia_myriad.sh scripts/ophelia_myriad_myrun.sh
   nano scripts/ophelia_myriad_myrun.sh
   ```

2. At minimum, edit the lines marked `<<< EDIT`:
   - `#$ -wd` — path to your ophelia directory
   - `#$ -M` — your email address
   - The `./ophelia` command at the bottom — your data paths

3. Submit:
   ```bash
   qsub scripts/ophelia_myriad_myrun.sh
   ```

### Example job script

```bash
#!/bin/bash -l
#$ -S /bin/bash
#$ -N ophelia_demux
#$ -l h_rt=12:00:00
#$ -pe smp 12
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/ophelia   # <<< EDIT
#$ -o logs/ophelia_$JOB_ID.out
#$ -e logs/ophelia_$JOB_ID.err
#$ -M your.email@ucl.ac.uk                # <<< EDIT
#$ -m bea

echo "Job ID: $JOB_ID | Host: $(hostname) | Cores: $NSLOTS | $(date)"

mkdir -p logs
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
echo "Lima: $(lima --version 2>&1 | head -1)"

cd ~/Scratch/bin/ophelia

./ophelia \
    --dir_data /path/to/bam \
    --dir_out /path/to/results \
    --barcode_ref ~/Scratch/bin/ophelia/www/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess" \
    --threads $NSLOTS \
    --resume

echo "Done: $(date)"
```

### Resource recommendations

Lima is internally parallelised. BAM files are processed one at a time, each using all available threads. Memory usage is low — 4G per core is almost always sufficient.

| Run size | Input files | Reads/file | Cores | Runtime |
|----------|-------------|------------|-------|---------|
| Small | 1–4 | < 100k | 8 | 4h |
| Medium | 4–8 | ~500k | 12 | 12h |
| Large | 8+ | > 1M | 16–24 | 24h |

### Monitoring jobs

```bash
# Check job status
qstat -u $USER

# Watch job status (refreshes every 30s)
watch -n 30 'qstat -u $USER'

# View live output once the job has started
tail -f logs/ophelia_<JOB_ID>.out

# Cancel a job
qdel <JOB_ID>
```

---

## Troubleshooting

### `lima: command not found`

The lima conda environment is not active. Activate it:

```bash
# Linux / AWS
conda activate lima

# Myriad
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

### `scripts/ophelia_cli.sh not found`

Ophelia must be run from its own root directory:

```bash
cd ~/Scratch/bin/ophelia
./ophelia --help
```

### `can't open output file ... logs/ophelia_XXX.out` (Myriad)

SGE creates the log files before the job script runs, so the `logs/` directory must already exist at submission time:

```bash
mkdir -p ~/Scratch/bin/ophelia/logs
qsub scripts/ophelia_myriad.sh
```

### `No BAM files found`

Check the files exist and that your pattern matches them:

```bash
ls /path/to/data/*.bam
```

If the files have a non-standard naming format, adjust the pattern:

```bash
./ophelia --dir_data /path/to/data --file_pattern "*.hifi_reads.*.bam" ...
```

### Low demultiplexing rate

Check the summary file for the affected input BAM:

```bash
cat results/demux_bc2001/*.lima.summary
```

Common causes:
- Wrong barcode reference file
- Wrong `--lima_preset` — try `ASYMMETRIC` vs `SYMMETRIC`
- Mixed-length barcodes in one FASTA — add `--different-barcode-lengths` to `--lima_args`
- Use `--peek-guess` to restrict demux to barcodes actually detected in the data

### Biosample CSV sample names not appearing

The pipeline handles BOM characters automatically. If you suspect a problem, check manually:

```bash
# Check for BOM (will show 'ef bb bf' at the start if present)
head -c 3 biosample.csv | xxd

# Manual fix if needed
perl -pi -e 's/^\xEF\xBB\xBF//' biosample.csv
```

### Checking pipeline logs

```bash
# List all runs
ls ~/Scratch/bin/ophelia/logs/

# View the most recent log
ls -t ~/Scratch/bin/ophelia/logs/ | head -1 | xargs -I{} cat ~/Scratch/bin/ophelia/logs/{}/ophelia.log

# Search for errors in a specific run
grep -i "error\|failed" ~/Scratch/bin/ophelia/logs/20260127_143022/ophelia.log

# View the parameters used for a specific run
cat ~/Scratch/bin/ophelia/logs/20260127_143022/ophelia_params.txt
```

### `Disk quota exceeded` or thousands of tiny output BAMs

By default lima writes one output BAM per detected barcode pair. With a large or noisy barcode set this can produce thousands of mostly-empty files per input BAM, which exhausts both byte and inode quotas on shared filesystems (e.g. UCL Myriad Scratch).

Two strategies:

- **Use `--peek-guess`** (recommended): restricts output to the barcode pairs actually present in your data. See [Common workflow #3](#3-filter-spurious-barcode-pairs-recommended).
- **On Myriad: stage output to node-local `$TMPDIR`** for runs against very large barcode sets, then `rsync` the final tree back to Scratch at the end of the job. This keeps the file count explosion off the quota-controlled filesystem entirely:

  ```bash
  WORK_OUT=$TMPDIR/result_demux
  FINAL_OUT=/home/$USER/Scratch/data/my_run/result_demux
  mkdir -p "$WORK_OUT" "$FINAL_OUT"

  ./ophelia \
      --dir_data /home/$USER/Scratch/data/my_run/bam \
      --dir_out  "$WORK_OUT" \
      --barcode_ref ~/Scratch/bin/ophelia/www/pacbio_M13_barcodes.fasta \
      --lima_args "--split-named --store-unbarcoded --peek-guess" \
      --threads $NSLOTS \
      --resume

  rsync -a "$WORK_OUT/" "$FINAL_OUT/"
  ```

  Request enough `tmpfs` in your job header to hold the working output (`#$ -l tmpfs=200G` is comfortable for most runs).

### Mixed barcode lengths

If your barcode FASTA contains barcodes of different lengths (e.g. 16 bp M13 forward + 10 bp Kinnex reverse), lima needs an explicit flag to score them correctly:

```bash
./ophelia \
    ... \
    --lima_args "--split-named --store-unbarcoded --peek-guess --different-barcode-lengths"
```

Where possible, it's cleaner to split your input BAMs by barcode scheme and use a uniform-length reference for each subset rather than rely on `--different-barcode-lengths`.

### Job killed on Myriad

Request more resources in your job script:

```bash
#$ -l h_rt=24:00:00    # More time
#$ -pe smp 16          # More cores
#$ -l mem=8G           # More memory per core (rarely needed)
```

---

## Contact

**Michael Flower**  
Senior Clinical Research Fellow  
UCL Queen Square Institute of Neurology, London

- Email: [michael.flower@ucl.ac.uk](mailto:michael.flower@ucl.ac.uk)
- GitHub: [github.com/mike-flower](https://github.com/mike-flower)

---

## Version history

### 1.0.3 (April 2026)
- Documentation: clarified that `--peek-guess` is recommended for most runs, not just for unknown-barcode cases — its primary practical benefit is filtering spurious low-count output BAMs
- Documentation: added troubleshooting entry for `Disk quota exceeded` and output-file-count explosion, including `$TMPDIR` staging pattern for Myriad
- Documentation: added troubleshooting entry for mixed-length barcode FASTAs (`--different-barcode-lengths`)
- Default Myriad job template now includes `--peek-guess` in the example `--lima_args`

### 1.0.2 (April 2026)
- `--resume` is now a bare flag; `--no-resume` disables resume behaviour
- Removed spurious `py2` conda fallback from environment setup
- Threads argument validated as integer before use
- Lima preset validated against known values (`ASYMMETRIC`, `SYMMETRIC`, `SYMMETRIC-ADAPTERS`, `TAILED`)
- Log file now written without ANSI colour codes (TTY detection)
- Logging begins before input validation so all errors are captured
- Resume check verifies summary file content, not just existence
- Failed files individually named in final pipeline report
- BOM stripping switched from `sed` to `perl` for cross-platform compatibility
- Barcode suffix extraction refactored into shared helper function
- Fixed `--biosample_csv` help text (overrides SM tag only; does not rename files)

### 1.0.1 (January 2026)
- Pipeline logs moved to `ophelia/logs/` with timestamped subdirectories
- Consistent log filenames: `ophelia.log` and `ophelia_params.txt`
- Results summary (`ophelia_summary.txt`) moved to output directory only

### 1.0.0 (January 2026)
- Initial release
- Single script processes all BAMs in a directory sequentially
- Supports Linux/AWS and UCL Myriad HPC
- Lima arguments passed through via `--lima_args`
- Automatic BOM stripping for biosample CSV
- Resume capability for interrupted runs
- Comprehensive logging and parameter saving
