# Ophelia

A demultiplexing pipeline for PacBio HiFi amplicon sequencing data using PacBio's lima tool.

**Version 1.1.1**

---

## Quick start

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results \
    --barcode_ref ~/refs/barcodes.fasta
```

Output files are named by barcode pairs (e.g., `bc1002--bc1050.bam`).

For a tidier output layout, add `--reorganise` to sort each sample's files into `barcoded/`, `reports/`, and `unbarcoded/` subfolders.

---

## Table of contents

- [Installation](#installation)
- [Input file requirements](#input-file-requirements)
- [File structure](#file-structure)
- [Run analysis](#run-analysis)
  - [Command-line interface](#command-line-interface)
  - [HPC deployment (Myriad)](#hpc-deployment-myriad)
- [Parameters](#parameters)
- [Output structure](#output-structure)
- [Output reorganisation](#output-reorganisation)
- [Lima reference](#lima-reference)
- [Common workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)

---

## Installation

### AWS / Linux server

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

**Note:** Lima is a compiled C++ binary – it doesn't require Python. Conda/bioconda is just the distribution mechanism.

### Pipeline setup

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

## Input file requirements

### Required files

#### 1. Sequencing data (BAM files)

**Location:** Specified by `--dir_data` parameter
**Format:** PacBio HiFi BAM files (already demultiplexed by primary barcode)

```
data/
├── m84277_251024_160109_s2.hifi_reads.bc2001.bam
├── m84277_251024_160109_s2.hifi_reads.bc2002.bam
├── m84277_251024_160109_s2.hifi_reads.bc2003.bam
└── m84277_251024_160109_s2.hifi_reads.bc2004.bam
```

#### 2. Barcode reference FASTA

**Location:** Specified by `--barcode_ref` parameter
**Format:** FASTA file with barcode sequences

```
>bc1002
ACACACAGACTGTGAG
>bc1003
ACACATCTCGTGAGAG
>bc1050
GATATACGCGAGAGAG
>bc1051
CGTGTCTAGCGCGCGC
```

### Optional files

#### 3. Biosample CSV (optional – for custom SM tags)

**Most users don't need this.** The output filename (`bc1002--bc1050.bam`) is the reliable sample identifier.

Use `--biosample_csv` only if downstream tools require custom sample names in the BAM `@RG SM:` tag.

**Location:** Specified by `--biosample_csv` parameter
**Format:** CSV mapping barcode pairs to sample names

```
Barcodes,Bio Sample
bc1002--bc1050,bcp1-A01-bc1002--bc1050
bc1002--bc1051,bcp1-A02-bc1002--bc1051
bc1003--bc1050,bcp1-B01-bc1003--bc1050
```

**What `--biosample_csv` does:**

| Aspect | Without `--biosample_csv` | With `--biosample_csv` |
| --- | --- | --- |
| **Output filenames** | `bc1002--bc1050.bam` | `bc1002--bc1050.bam` (unchanged) |
| **BAM SM tag** | Preserved from input (e.g., `SM:lib_05`) | Overwritten with biosample name |

Without `--biosample_csv`, lima **preserves** the original `@RG` metadata from the input BAM, including the SM tag set during sequencing run setup (e.g., `SM:lib_05`). With `--biosample_csv`, lima **overrides** the SM tag with your mapped biosample name.

To check the SM tag:

```bash
samtools view -H output.bam | grep "^@RG"
# Without biosample_csv: SM:lib_05 (from sequencing setup)
# With biosample_csv: SM:bcp1-A01-bc1002--bc1050
```

**Note on BOM characters:** The pipeline automatically strips UTF-8 BOM (Byte Order Mark) characters from CSV files. BOM is an invisible character (`EF BB BF` in hex) that Microsoft Excel adds to CSV files. Ophelia detects this and creates a cleaned copy automatically.

---

## File structure

```
ophelia/
├── ophelia                        # Main wrapper script
├── scripts/
│   ├── ophelia_cli.sh             # Core pipeline logic
│   ├── ophelia_myriad.sh          # HPC job submission script
│   └── reorganise_ophelia.sh      # Standalone tool for retrofitting existing output
├── lib/
│   └── reorganise.sh              # Shared reorganisation library
├── logs/                          # Pipeline logs (created automatically)
│   ├── 20260127_143022/           # Timestamped run directories
│   │   ├── ophelia.log
│   │   └── ophelia_params.txt
│   └── ...
├── www/                           # Reference files (barcodes, biosample CSV)
└── README.md
```

---

## Run analysis

### Command-line interface

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
    --threads 8 \
    --reorganise
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

### HPC deployment (Myriad)

#### First-time setup

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

#### Job submission

1. Copy and edit the Myriad template:

   ```bash
   cp scripts/ophelia_myriad.sh scripts/ophelia_myriad_myrun.sh
   nano scripts/ophelia_myriad_myrun.sh   # Edit parameters
   ```

2. **Important:** Ensure the logs directory exists (SGE creates log files before the script runs):

   ```bash
   mkdir -p logs
   ```

3. Submit the job:

   ```bash
   qsub scripts/ophelia_myriad_myrun.sh
   ```

#### Example Myriad job script

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
    --file_pattern "*bc20*.bam" \
    --threads $NSLOTS \
    --reorganise \
    --resume
```

#### Monitoring jobs

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

#### Resource recommendations

| Run Size | Files | Reads/File | Cores | Memory | Runtime |
| --- | --- | --- | --- | --- | --- |
| Small | 1-4 | <100k | 8 | 4G | 4h |
| Medium | 4-8 | ~500k | 12 | 4G | 12h |
| Large | 8+ | >1M | 16-24 | 4G | 24h |

Lima is well-parallelised internally. Files are processed sequentially (one at a time), each using multiple threads.

---

## Parameters

### Required parameters

| Parameter | Description |
| --- | --- |
| `--dir_data` | Directory containing input BAM files |
| `--dir_out` | Directory for output files |
| `--barcode_ref` | FASTA file with barcode sequences |

### Optional parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `--biosample_csv` | *(none)* | CSV mapping barcodes to sample names (overrides SM tag) |
| `--file_pattern` | `*.bam` | Glob pattern for BAM files to process |
| `--threads` | Auto-detect | Number of CPU threads for lima |

### Lima arguments

| Parameter | Default | Description |
| --- | --- | --- |
| `--lima_preset` | `ASYMMETRIC` | Barcode preset (`ASYMMETRIC`, `SYMMETRIC`, `TAILED`) |
| `--lima_args` | `--split-named --store-unbarcoded` | Additional arguments passed to lima |

See the [Lima reference](#lima-reference) section for what each preset expands to, the meaning of `--peek-guess`, window-size guidance, the minimum read length, and other commonly used flags.

### Output organisation

| Parameter | Default | Description |
| --- | --- | --- |
| `--reorganise` | Off | Sort each sample's output into `barcoded/`, `reports/`, `unbarcoded/` subfolders |
| `--drop-unbarcoded` | Off | Delete unbarcoded BAMs instead of moving them (requires `--reorganise`) |

### Execution options

| Parameter | Default | Description |
| --- | --- | --- |
| `--resume` | On | Skip files that have already been processed |
| `--no-resume` | – | Force re-processing of all files |
| `--dry_run` | Off | Show commands without executing |
| `--verbose` | Off | Enable debug output |

---

## Output structure

**Pipeline logs** (in ophelia installation directory):

```
ophelia/logs/
├── 20260127_143022/               # Timestamped run directory
│   ├── ophelia.log                # Full pipeline log
│   └── ophelia_params.txt         # Parameters used
├── 20260127_160045/
│   ├── ophelia.log
│   └── ophelia_params.txt
```

**Results without `--reorganise`** (flat layout, default):

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

**Results with `--reorganise`:**

```
dir_out/
├── demux_bc2001/
│   ├── barcoded/                              # *.demux.<bc1>--<bc2>.{bam,bam.pbi,xml}
│   │   ├── m84277_...bc2001.demux.bc1002--bc1050.bam
│   │   ├── m84277_...bc2001.demux.bc1002--bc1050.bam.pbi
│   │   └── m84277_...bc2001.demux.bc1002--bc1050.consensusreadset.xml
│   ├── reports/                               # Lima reports + top-level metadata
│   │   ├── m84277_...bc2001.demux.lima.summary
│   │   ├── m84277_...bc2001.demux.lima.report
│   │   ├── m84277_...bc2001.demux.lima.counts
│   │   └── m84277_...bc2001.demux.json
│   └── unbarcoded/                            # Omitted with --drop-unbarcoded
│       └── m84277_...bc2001.demux.unbarcoded.bam
├── demux_bc2002/
│   └── ...
├── biosample_cleaned.csv
└── ophelia_summary.txt
```

### Output files

**In results directory:**

| File | Description |
| --- | --- |
| `*.demux.<bc1>--<bc2>.bam` | Demultiplexed BAM files (one per barcode pair) |
| `*.demux.unbarcoded.bam` | Reads that couldn't be assigned to a barcode pair |
| `*.lima.summary` | Summary statistics (reads processed, passed, etc.) |
| `*.lima.report` | Detailed per-read barcode assignments |
| `*.lima.counts` | Read counts per barcode pair |
| `ophelia_summary.txt` | Overall demux summary (pass rates per file) |

**In ophelia/logs/YYYYMMDD_HHMMSS/:**

| File | Description |
| --- | --- |
| `ophelia.log` | Complete pipeline log with timestamps |
| `ophelia_params.txt` | All parameters used for the run |

---

## Output reorganisation

By default, lima writes all of a sample's output files (per-barcode BAMs, unbarcoded BAMs, lima reports, JSON metadata) into a single flat directory. This works fine for most analyses, but can become unwieldy when there are many barcodes or when downstream pipelines only care about the per-barcode BAMs.

The `--reorganise` flag sorts each sample's output into three subfolders:

- **`barcoded/`** – the per-barcode BAMs and their indices/manifests (`*.demux.<bc1>--<bc2>.{bam,bam.pbi,consensusreadset.xml}`)
- **`reports/`** – everything lima emits about the run as a whole (`*.lima.summary`, `*.lima.report`, `*.lima.counts`, top-level JSON/XML)
- **`unbarcoded/`** – reads that couldn't be assigned to a barcode pair (`*.demux.unbarcoded.*`)

Classification is purely filename-based and barcode-name-agnostic, so it works regardless of which barcode kit you used.

### Saving disk space – `--drop-unbarcoded`

Unbarcoded BAMs are often the largest single output (frequently several GB) and are rarely needed once you've confirmed the demux QC looks reasonable. The `--drop-unbarcoded` flag deletes them outright instead of moving them to `unbarcoded/`. This is irreversible, so it's opt-in and requires `--reorganise` to be enabled.

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise --drop-unbarcoded
```

### Retrofitting an existing output directory

There are two ways to apply the reorganised layout to an existing flat output directory:

**Option 1 – re-run ophelia with `--reorganise --resume`.** The resume logic is layout-aware, so already-completed samples won't be re-run through lima; they'll just be tidied. This is the cleanest approach if you still have the original parameters to hand.

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise \
    --resume
```

**Option 2 – use the standalone `reorganise_ophelia.sh` script.** This is the right choice when you don't want to (or can't) re-supply the original ophelia parameters, when the lima environment isn't available, or when reorganising someone else's output. It does the file classification only, with no dependency on lima/conda.

```bash
# Reorganise a whole result_ophelia/ directory
scripts/reorganise_ophelia.sh --path /path/to/result_ophelia

# Dry run first to preview the moves
scripts/reorganise_ophelia.sh --path /path/to/result_ophelia --dry-run

# Reorganise a single sample directory
scripts/reorganise_ophelia.sh --path /path/to/result_ophelia/demux_m84277_...bc2001

# Reorganise multiple runs in one invocation
scripts/reorganise_ophelia.sh \
    --path /path/to/run1/result_ophelia \
    --path /path/to/run2/result_ophelia

# Drop unbarcoded BAMs to reclaim disk space
scripts/reorganise_ophelia.sh --path /path/to/result_ophelia --drop-unbarcoded
```

Both the integrated `--reorganise` flag and the standalone script use the same classification logic (in `lib/reorganise.sh`), so the resulting layout is identical.

---

## Lima reference

Ophelia is a thin wrapper around lima – any lima option can be passed through using `--lima_args "…"`. The full option list is available via `lima --help` once you've activated the conda environment. The notes below cover the lima details that most often affect Ophelia users' decisions.

### HiFi presets

`--lima_preset` selects a bundled set of lima parameters tuned for HiFi data. The actual flags each preset expands to are:

| Preset | Equivalent lima flags |
| --- | --- |
| `SYMMETRIC` | `--ccs --min-score 0 --min-end-score 80 --min-ref-span 0.75 --same --single-end` |
| `SYMMETRIC-ADAPTERS` | `--ccs --min-score 0 --min-end-score 80 --min-ref-span 0.75 --same --ignore-missing-adapters --single-end` |
| `ASYMMETRIC` | `--ccs --min-score 80 --min-end-score 50 --min-ref-span 0.75 --different --min-scoring-regions 2` |
| `TAILED` | (lima's tailed-amplicon recommended settings) |

Use `ASYMMETRIC` for designs where forward and reverse primers carry different barcodes (most amplicon pooling, including Kinnex 16S). Use `SYMMETRIC` for designs where the same barcode appears on both ends.

### `--peek-guess` and barcode inference

`--peek-guess` is the easy way to handle the case "I don't know which barcodes are present in this pool". Lima demultiplexes the first batch of ZMWs, then keeps only the barcodes whose mean score exceeds a threshold. The exact thresholds depend on what other flags are active:

| Mode | Equivalent flags |
| --- | --- |
| Default | `--peek 50000 --guess 45 --guess-min-count 10` |
| With `--ccs` | `--peek 50000 --guess 75 --guess-min-count 10` |
| With `--isoseq` | `--peek 50000 --guess 75 --guess-min-count 100` |

Since the HiFi presets all enable `--ccs` internally, `--peek-guess` in Ophelia uses the higher score threshold (75) and a 10-ZMW minimum count.

A practical pitfall: if your barcode FASTA contains barcodes you didn't actually use, `--peek-guess` will sometimes whitelist a few of them on the basis of stray matches. If you see anomalous barcode pairs in the output (e.g., R-R combinations in an asymmetric demux), check `*.lima.guess` in `reports/` to see which barcodes were inferred, then trim the FASTA to only the barcodes you actually pooled.

### Window size

The "window size" is how far in from each read end lima searches for barcodes. Two flags control it (default behaviour: use the multiplier):

| Flag | Meaning | Default |
| --- | --- | --- |
| `--window-size-multi N` | Window size = `N × barcode_length` | `3` (i.e., 48bp for a 16bp barcode) |
| `--window-size N` | Explicit window size in bp; overrides the multiplier | `0` (use multiplier) |

**Note on flag naming:** lima 2.13's binary uses `--window-size` (bp) and `--window-size-multi` (multiplier). The lima.how web docs show `--window-size-bp` and `--window-size-mult` – these names refer to older or newer versions of the binary. Always check `lima --help` against your installed version.

For most standard PacBio barcode pools, the default window (3 × barcode length) is fine. You may want to enlarge the window when:

- The library design includes a **pad or spacer between the adapter and the barcode** (e.g., a 5bp `GGTAG` pad outside a 16bp asymmetric barcode pushes the barcode further from the read end – the default 48bp window can be borderline if there's also residual adapter sequence)
- Reads have **longer-than-usual residual adapter** for any other reason
- You're seeing unexpectedly low pass rates with no obvious other cause

For a 16bp barcode with a ~5bp pad, `--window-size 100` is a comfortable choice that adds enough headroom without meaningful CPU cost (the amplicon insert is far too long for a 100bp window to risk false-positive barcode hits in the middle).

### Minimum read length

`--min-length` sets the minimum sequence length (after barcode clipping) for a read to be retained. Lima's default is **50 bp** and you'll rarely want to change it.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--min-length N` | `50` | Minimum read length in bp after clipping |

To check the default in your installed lima version:

```bash
lima --help 2>&1 | grep -E "min-length"
# -l,--min-length INT    Minimum sequence length after clipping. [50]
```

To override it via Ophelia, add it to `--lima_args`:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results \
    --barcode_ref ~/refs/barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --min-length 30"
```

#### When to lower it (usually: don't)

Each amplicon has a **physical length floor** defined by the fixed flanking sequence – adapter handles, barcodes, and primers. Lowering `--min-length` below that floor never recovers usable reads; it just retains junk that fails downstream filters anyway.

To work out the floor for your design, sum:

```
[adapter handle][barcode][primer F][insert][primer R RC][barcode RC][adapter handle RC]
```

For a Kinnex 16S library with 22 bp Kinnex/Iso-Seq handles, 10 bp kxF/kxR barcodes, and 22 bp HTT Ciosi primers, the fixed flanks alone total **108 bp**. A meaningful amplicon is at least ~130–140 bp (108 bp flanks + ~30 bp shortest plausible insert). Anything below ~100 bp is adapter dimer, primer dimer, or fragmentation artefact, and can't physically contain a full barcode pair – lima will reject these regardless of `--min-length`.

The default of 50 bp is below the physical floor for almost every realistic PacBio amplicon design, so lowering it is rarely productive.

#### Interpreting "Below min length" in lima.summary

Lima's failure categories in `lima.summary` **are not mutually exclusive** – a single rejected read can be counted in multiple "Below ..." rows. For example:

```
Reads input                    : 30883297
Reads above all thresholds (A) : 16275054
Reads below any threshold  (B) : 14608243

Read marginals for (B):
Below min length               : 10158140
Below min score                : 4319974
Below min end score            : 1696109
Below min score lead           : 10335876
...
```

The marginal counts sum to ~28M, but only 14.6M unique reads failed. Most reads that fail "min length" also fail "min score lead" and other thresholds. So a large "Below min length" number doesn't necessarily mean a large pool of recoverable reads – it usually means the short-read population is broadly poor-quality.

#### How to decide whether to lower it

If lowering `--min-length` is genuinely on the table, check the length distribution of unbarcoded reads first:

```bash
# Length distribution of rejected reads (binned in 20bp intervals)
samtools view demux_*/unbarcoded/*.unbarcoded.bam | awk '{ print length($10) }' | \
    awk '{ bin = int($1/20)*20; n[bin]++ } END { for (b in n) printf "%4d\t%d\n", b, n[b] }' | \
    sort -n
```

- If the rejected reads are concentrated **below ~100 bp** with a long tail of sub-50 bp reads, they're junk – lowering won't help.
- If you see a substantial population at **130–250 bp** being rejected, that's where the recoverable yield lives. The right `--min-length` is the lower bound of that population (not zero).

In most cases the bigger lever for recovering yield is **using `--biosample_csv` to constrain lima to the valid barcode pairs in your design** – this both eliminates false-positive pairs and improves `score-lead` calls on legitimate reads. Threshold tweaking is a second-order optimisation.

### Other useful flags

These come up often enough to be worth knowing about, even though they're documented in `lima --help`:

| Flag | Use |
| --- | --- |
| `--split-named` | Name output files by barcode names rather than indices (Ophelia uses this by default) |
| `--store-unbarcoded` | Keep reads that couldn't be assigned a barcode (Ophelia uses this by default; pair with `--drop-unbarcoded` after QC to reclaim disk space) |
| `--peek-guess` | Infer which barcodes are present (slower; two-pass) |
| `--dump-removed` | Save reads filtered out by quality thresholds (not just unbarcoded) |
| `--min-length N` | Override the default minimum read length after clipping (default 50; see [Minimum read length](#minimum-read-length) above) |
| `--min-score N` | Override the preset's minimum barcode score (lower = more permissive) |
| `--min-score-lead N` | Minimum score margin between best and second-best barcode call (lower = more permissive) |
| `--min-passes N` | Require N full passes through the SMRTbell (default 0; rarely needed for HiFi) |
| `--num-threads N` | Threads (Ophelia sets this from `--threads`, no need to pass directly) |

### Quick reference – passing args through Ophelia

Anything that doesn't have a dedicated Ophelia flag goes inside `--lima_args`:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results \
    --barcode_ref ~/refs/barcodes.fasta \
    --lima_preset ASYMMETRIC \
    --lima_args "--split-named --store-unbarcoded --peek-guess --window-size 100" \
    --reorganise
```

Ophelia explicitly handles `--biosample-csv` (via `--biosample_csv`), `--num-threads` (via `--threads`), and `--hifi-preset` (via `--lima_preset`) – passing these inside `--lima_args` will cause a duplicate-flag error from lima. Everything else is fair game.

---

## Common workflows

### 1. Basic demultiplexing (recommended)

Standard workflow for most users:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise
```

Output files are named by barcode pairs (e.g., `bc1002--bc1050.bam`). The filename is the reliable sample identifier for downstream analysis. The `--reorganise` flag is recommended when feeding output into downstream pipelines that only need the per-barcode BAMs.

### 2. Process specific files

Process only certain barcode files (e.g., exclude `unassigned.bam`):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --file_pattern "*bc20*.bam" \
    --reorganise
```

### 3. Unknown barcodes

When you don't know which barcode combinations are present (lima will infer):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess"
```

**Note:** `--peek-guess` is slower (two-pass).

### 4. Test run (dry run)

See what would happen without actually running:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --dry_run
```

### 5. Resume after interruption

The `--resume` option (default) skips files that have already been processed. Ophelia checks for the existence of a complete `.lima.summary` file (in either the flat or reorganised layout) to determine completion.

```bash
# First run (interrupted or some files fail)
./ophelia --dir_data ~/data/bam --dir_out ~/results ...

# Re-run (only processes incomplete files)
./ophelia --dir_data ~/data/bam --dir_out ~/results ...
```

To force re-processing of all files:

```bash
./ophelia --dir_data ~/data/bam --dir_out ~/results ... --no-resume
```

### 6. Custom SM tags (optional)

If downstream tools require custom sample names in the BAM `@RG SM:` tag:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --biosample_csv ~/refs/biosample.csv
```

This overrides the original SM tag (e.g., `SM:lib_05` from sequencing setup) with your biosample name. Most users don't need this – use filenames for sample tracking instead.

### 7. Save disk space on confirmed runs

Once a demux has been QC'd and you're confident the unbarcoded reads aren't needed:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise --drop-unbarcoded
```

Or retrofit an existing run:

```bash
scripts/reorganise_ophelia.sh --path ~/results/demux --drop-unbarcoded
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

### "shared library not found at .../lib/reorganise.sh"

This appears if you've copied an individual script out of the repo. Both `scripts/ophelia_cli.sh` and `scripts/reorganise_ophelia.sh` rely on `lib/reorganise.sh` at the ophelia repo root. Run them from inside a checked-out ophelia repo, or copy both the `scripts/` and `lib/` directories together.

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

### "ophelia_summary.txt shows 0/0 for every sample"

This was a bug in versions ≤1.1.0 caused by lima's output format changing: lima ≤2.7 wrote "ZMWs input" / "ZMWs above all thresholds" in `lima.summary`, while lima ≥2.8 writes "Reads input" / "Reads above all thresholds (A)". Ophelia's parser only matched the older "ZMWs" form, so per-sample stats reported 0/0 on newer lima versions even though the demux had run successfully.

Fixed in v1.1.1 – the parser now accepts both forms. If you're on v1.1.0 or earlier, update by pulling the latest from GitHub:

```bash
cd ~/Scratch/bin/ophelia
git pull
```

The barcoded BAMs from earlier runs are unaffected (this was a reporting bug only). Re-run with `--resume` to regenerate `ophelia_summary.txt` with correct numbers without re-running lima.

### "Low demultiplexing rate"

Check the `*.lima.summary` file (in `reports/` if you used `--reorganise`):

```bash
cat results/demux_bc2001/*.lima.summary           # flat layout
cat results/demux_bc2001/reports/*.lima.summary   # reorganised layout
```

Common causes:

- Wrong barcode reference file
- Wrong `--lima_preset` (try `ASYMMETRIC` vs `SYMMETRIC`)
- Try `--peek-guess` to see which barcodes are actually present
- Inspect the failure breakdown in `lima.summary` to see whether reads are failing on length, barcode score, score-lead, or end-score. See the [Minimum read length](#minimum-read-length) section for guidance on interpreting these.

### Checking pipeline logs

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
#$ -l h_rt=24:00:00     # More time
#$ -pe smp 16           # More cores
#$ -l mem=8G            # More memory per core
```

### Checking BAM read group header

To inspect the full `@RG` metadata:

```bash
module load samtools
samtools view -H output.bam | grep "^@RG"
```

Example output:

```
@RG ID:60310e2c/0--16 PL:PACBIO SM:lib_05 LB:MF_Pool2_5-8 BC:ACACACAGACTGTGAG-GATATACGCGAGAGAG ...
```

Key fields:

- `SM:` – Sample name (from sequencing setup, or overridden by `--biosample_csv`)
- `LB:` – Library name from sequencing setup
- `BC:` – Actual barcode sequences detected

---

## Contact

**Michael Flower**
Senior Clinical Research Fellow
Department of Neurodegenerative Disease
UCL Queen Square Institute of Neurology
London, UK

- Email: [michael.flower@ucl.ac.uk](mailto:michael.flower@ucl.ac.uk)
- GitHub: <https://github.com/mike-flower>

---

## Version history

### 1.1.1 (May 2026)

- **Bugfix:** `ophelia_summary.txt` no longer reports 0/0 for every sample when run with lima ≥2.8. Lima's `lima.summary` output format changed between major versions (older versions said "ZMWs input" / "ZMWs above all thresholds"; newer versions say "Reads input" / "Reads above all thresholds (A)"), and Ophelia's parser only matched the older form. The resume check, post-lima inline stats, and final summary parser now all accept both forms.
- Documentation: added a Minimum read length section to the [Lima reference](#lima-reference), covering the default (50 bp), the amplicon-length floor concept, how to interpret "Below min length" in lima.summary, and when (rarely) it's worth lowering.

### 1.1.0 (May 2026)

- Added `--reorganise` flag to sort each sample's output into `barcoded/`, `reports/`, and `unbarcoded/` subfolders
- Added `--drop-unbarcoded` flag to delete unbarcoded BAMs (requires `--reorganise`)
- Resume logic is now layout-aware: `--resume` correctly detects completed samples in either the flat or reorganised layout
- Extracted classification logic into a shared library (`lib/reorganise.sh`) used by both `scripts/ophelia_cli.sh` and the standalone `scripts/reorganise_ophelia.sh` retrofit tool
- Re-running with `--reorganise --resume` will tidy already-completed flat samples without re-running lima

### 1.0.2 (January 2026)

- Made `--biosample_csv` clearly optional in documentation
- Clarified SM tag behaviour: preserved from input without biosample_csv, overridden with it
- Simplified quick start and common workflows
- Basic demultiplexing (without biosample_csv) is now the primary workflow

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
