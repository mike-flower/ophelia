# Ophelia

A demultiplexing pipeline for PacBio HiFi amplicon sequencing data using PacBio's lima tool.

**Version 1.2.1**

---

## Quick start

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results \
    --barcode_ref ~/refs/barcodes.fasta \
    --reorganise by-type
```

Output files are named by barcode pair (e.g. `bc1002--bc1050.bam`) and pooled into top-level `barcoded/`, `reports/`, and `unbarcoded/` directories across all samples. Omit `--reorganise` for raw lima output (one directory per input BAM); see [Output reorganisation](#output-reorganisation) for the other modes.

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
  - [HiFi presets](#hifi-presets)
  - [`--peek-guess` and barcode inference](#--peek-guess-and-barcode-inference)
  - [Window size](#window-size)
  - [Minimum read length](#minimum-read-length)
  - [Common flags](#common-flags)
  - [Full lima flag catalog (2.13.0)](#full-lima-flag-catalog-2130)
- [Common workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [Contact](#contact)
- [Version history](#version-history)

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
│   └── reorganise_ophelia.sh      # Standalone tool for retrofitting raw output
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
    --reorganise by-type
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
    --reorganise by-type \
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

The template at `scripts/ophelia_myriad.sh` is the canonical version – see that file for the current job script content. The key fields to edit before submitting are `-wd`, `-M`, and the path arguments to `./ophelia`.

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
| `--lima_preset` | `ASYMMETRIC` | Barcode preset (`ASYMMETRIC`, `SYMMETRIC`, `SYMMETRIC-ADAPTERS`) |
| `--lima_args` | `--split-named --store-unbarcoded` | Additional arguments passed to lima |

See the [Lima reference](#lima-reference) section for what each preset expands to, the meaning of `--peek-guess`, window-size guidance, the minimum read length, and other commonly used flags.

### Output organisation

| Parameter | Default | Description |
| --- | --- | --- |
| `--reorganise MODE` | *(off)* | Move output into a layout. Modes: `by-sample` (no-op, same as omitting the flag), `by-sample-type`, `by-type`, `by-type-sample`. See [Output reorganisation](#output-reorganisation). |
| `--drop-unbarcoded` | Off | Delete unbarcoded BAMs instead of moving them (requires `--reorganise` with a non-`by-sample` mode) |

### Execution options

| Parameter | Default | Description |
| --- | --- | --- |
| `--dry_run` / `--dry-run` | Off | Show commands without executing |
| `--verbose` | Off | Enable debug output |

Ophelia has no resume option – each invocation runs lima on every input BAM. If `--dir_out` already contains a reorganised layout from a previous run, Ophelia refuses to run; see [Re-running on an existing dir_out](#re-running-on-an-existing-dir_out).

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

**Raw output** (no `--reorganise`, or `--reorganise by-sample`):

```
dir_out/
├── m84277_..._bc2001/                         # One folder per input BAM
│   ├── m84277_..._bc2001.demux.bc1002--bc1050.bam
│   ├── m84277_..._bc2001.demux.bc1002--bc1051.bam
│   ├── m84277_..._bc2001.demux.unbarcoded.bam
│   ├── m84277_..._bc2001.demux.lima.summary
│   ├── m84277_..._bc2001.demux.lima.report
│   └── m84277_..._bc2001.demux.lima.counts
├── m84277_..._bc2002/
│   └── ...
├── biosample_cleaned.csv                      # BOM-stripped CSV (if applicable)
└── ophelia_summary.txt
```

**`--reorganise by-sample-type`** – per-sample dirs with type subdirs:

```
dir_out/
├── m84277_..._bc2001/
│   ├── barcoded/                  # *.demux.<bc1>--<bc2>.{bam,bam.pbi,xml}
│   ├── reports/                   # *.lima.summary, *.lima.report, *.lima.counts
│   └── unbarcoded/                # *.demux.unbarcoded.* (omitted with --drop-unbarcoded)
├── m84277_..._bc2002/
│   └── ...
└── ophelia_summary.txt
```

**`--reorganise by-type`** – top-level type dirs, all samples pooled flat:

```
dir_out/
├── barcoded/
│   ├── m84277_..._bc2001.demux.bc1002--bc1050.bam
│   ├── m84277_..._bc2001.demux.bc1002--bc1050.bam.pbi
│   ├── m84277_..._bc2002.demux.bc1003--bc1050.bam
│   └── ...
├── reports/
│   ├── m84277_..._bc2001.demux.lima.summary
│   └── ...
├── unbarcoded/                    # omitted with --drop-unbarcoded
│   └── ...
└── ophelia_summary.txt
```

**`--reorganise by-type-sample`** – top-level type dirs with per-sample subdirs:

```
dir_out/
├── barcoded/
│   ├── m84277_..._bc2001/
│   │   ├── m84277_..._bc2001.demux.bc1002--bc1050.bam
│   │   └── ...
│   └── m84277_..._bc2002/
├── reports/
│   └── (same pattern)
├── unbarcoded/                    # omitted with --drop-unbarcoded
│   └── (same pattern)
└── ophelia_summary.txt
```

### Output files

| File | Description |
| --- | --- |
| `*.demux.<bc1>--<bc2>.bam` | Demultiplexed BAM files (one per barcode pair) |
| `*.demux.unbarcoded.bam` | Reads that couldn't be assigned to a barcode pair |
| `*.lima.summary` | Summary statistics (reads processed, passed, etc.) |
| `*.lima.report` | Detailed per-read barcode assignments |
| `*.lima.counts` | Read counts per barcode pair |
| `ophelia_summary.txt` | Overall demux summary (pass rates per file) |

---

## Output reorganisation

By default, lima writes all of a sample's output files (per-barcode BAMs, unbarcoded BAMs, lima reports, JSON metadata) into a single flat directory per input BAM. `--reorganise MODE` lets you choose a tidier layout. All modes move files; nothing is copied or symlinked.

### Modes

**`by-sample`** *(default; same as omitting the flag)*

```
dir_out/
├── <bam_basename>/
│   ├── *.demux.<bc1>--<bc2>.bam
│   ├── *.demux.unbarcoded.bam
│   └── *.lima.*
└── ...
```

Raw lima output. One directory per input BAM, all files flat inside.

**`by-sample-type`** – sample-centric with type subdirs

```
dir_out/
├── <bam_basename>/
│   ├── barcoded/
│   ├── reports/
│   └── unbarcoded/
└── ...
```

Easy to work with one sample at a time. Consuming across samples (e.g. globbing all barcoded BAMs) requires a per-sample loop.

**`by-type`** *(recommended for downstream pipelines)*

```
dir_out/
├── barcoded/
├── reports/
└── unbarcoded/
```

All samples pooled flat by file type. Filenames retain library identity (e.g. `m84277_..._bc2001.demux.bc1002--bc1050.bam`), so there are no collisions across samples. Downstream tools like Duke can be pointed at `dir_out/barcoded/` in a single command with no per-library loop.

**`by-type-sample`** – type-centric with per-sample subdirs

```
dir_out/
├── barcoded/<sample>/
├── reports/<sample>/
└── unbarcoded/<sample>/
```

Like `by-type`, but type directories are subdivided by sample. Useful at large scale (dozens of libraries) where the flat `by-type` directories would become unwieldy to browse.

Classification is purely filename-based and barcode-name-agnostic, so it works regardless of which barcode kit you used.

### Saving disk space – `--drop-unbarcoded`

Unbarcoded BAMs are often the largest single output (frequently several GB) and are rarely needed once you've confirmed the demux QC looks reasonable. The `--drop-unbarcoded` flag deletes them outright instead of moving them. This is irreversible, so it's opt-in and requires `--reorganise` with a non-`by-sample` mode.

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise by-type --drop-unbarcoded
```

### Retrofitting raw output

Existing raw output can be reorganised post-hoc with the standalone `scripts/reorganise_ophelia.sh` tool. This is the right choice when you don't want to re-run lima – it does the file classification only, with no dependency on the lima/conda environment.

```bash
# Pooled by type
scripts/reorganise_ophelia.sh \
    --mode by-type \
    --path /path/to/result_ophelia \
    --dir_out /path/to/result_ophelia

# Per-sample type subdirs
scripts/reorganise_ophelia.sh --mode by-sample-type --path /path/to/result_ophelia

# Dry run first to preview
scripts/reorganise_ophelia.sh --mode by-type --path /path/to/result_ophelia \
    --dir_out /path/to/result_ophelia --dry-run

# Drop unbarcoded BAMs to reclaim disk space
scripts/reorganise_ophelia.sh --mode by-type --path /path/to/result_ophelia \
    --dir_out /path/to/result_ophelia --drop-unbarcoded
```

The standalone tool only operates on raw output. If you point it at an already-reorganised directory, it refuses with an error – mid-flight layout migration is not supported. To switch layouts on a directory that's already reorganised, you'd need to manually move files back to flat first (or just re-run lima from scratch).

Both the integrated `--reorganise` flag and the standalone script use the same classification logic (`lib/reorganise.sh`), so the resulting layouts are identical.

### Re-running on an existing dir_out

Ophelia has no resume mode. Every invocation runs lima on every input BAM. To protect against producing inconsistent mixed output, Ophelia refuses to run if `--dir_out` already contains a reorganised layout (any of `barcoded/`, `reports/`, `unbarcoded/` at top level, or a `<sample>/barcoded/` etc. inside a sample dir).

To re-run on a directory that has already been processed:

- **Previous run produced raw output** (no `--reorganise`, or `--reorganise by-sample`): re-running is safe. Lima will overwrite each sample's output files with the new ones and produce a clean result.
- **Previous run was reorganised**: delete `--dir_out` and re-invoke from scratch, or point `--dir_out` at a fresh path. Trying to merge a fresh lima run into an existing reorganised tree produces a confusing half-state, which is why it's refused.

If you only want to *change the layout* of an existing raw run without re-running lima, use `scripts/reorganise_ophelia.sh` instead – see [Retrofitting raw output](#retrofitting-raw-output) above.

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

Use `ASYMMETRIC` for designs where forward and reverse primers carry different barcodes (most amplicon pooling, including Kinnex 16S). Use `SYMMETRIC` for designs where the same barcode appears on both ends. For tailed-library designs (same barcode on both ends, opposite orientation), `SYMMETRIC` is the right choice – lima has no separate `TAILED` HiFi preset.

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

### Common flags

These come up most often. The full lima 2.13.0 flag catalog is in the next section.

| Flag | Use |
| --- | --- |
| `--split-named` | Name output files by barcode names rather than indices (Ophelia uses this by default) |
| `--store-unbarcoded` | Keep reads that couldn't be assigned a barcode (Ophelia uses this by default; pair with `--drop-unbarcoded` after QC to reclaim disk space) |
| `--peek-guess` | Infer which barcodes are present (slower; two-pass) |
| `--dump-clips` | Save the clipped barcode regions to `<prefix>.lima.clips` (useful for QC of barcode boundaries) |
| `--no-clip` | Identify barcode pairs but leave them in the read sequence |
| `--min-length N` | Override the default minimum read length after clipping (default 50; see [Minimum read length](#minimum-read-length) above) |
| `--min-score N` | Override the preset's minimum barcode score (lower = more permissive) |
| `--min-score-lead N` | Minimum score margin between best and second-best barcode call (lower = more permissive) |
| `--min-passes N` | Require N full passes through the SMRTbell (default 0; rarely needed for HiFi) |
| `--window-size N` | Explicit barcode search window in bp (default 0 = use multiplier) – see [Window size](#window-size) above |

### Full lima flag catalog (2.13.0)

The sections below mirror the grouping in `lima --help` on lima 2.13.0 (the version on UCL Myriad's bioconda channel) so you can cross-reference them against your installed binary at any time. Pass any of these flags via `--lima_args`, except for the three that have dedicated Ophelia flags (`--hifi-preset`, `--biosample-csv`, `--num-threads`) which must not be duplicated inside `--lima_args`.

**Defaults marked with ★ are flags Ophelia adds automatically.**

#### Library design

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-s, --same` | flag | off | Only keep same-barcode pairs (`bc1002--bc1002`) in output |
| `-d, --different` | flag | off | Only keep different-barcode pairs in output. Enforces `--min-passes ≥ 1` |
| `-N, --neighbors` | flag | off | Only output barcode pairs that are neighbours in the barcode file |
| `--hifi-preset` | str | none | Recommended HiFi parameter preset (Ophelia: use `--lima_preset` instead) |
| `--omit-barcode-infix` | flag | off | Omit the barcode pair infix in output filenames |

#### Input limitations

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-p, --per-read` | flag | off | Tag per read rather than per ZMW (CLR subread workflows) |
| `-f, --score-full-pass` | flag | off | Only score subreads flanked by adapters on both sides |
| `-n, --max-scored-barcode-pairs` | int | 0 | Use at most N barcode pair regions for identification (0 = all) |
| `-b, --max-scored-barcodes` | int | 0 | Analyse at most N barcodes per ZMW (0 = no cap) |
| `-a, --max-scored-adapters` | int | 0 | Analyse at most N adapters per ZMW (0 = no cap) |
| `-u, --min-passes` | int | 0 | Minimum number of full passes through the SMRTbell |
| `-l, --min-length` | int | 50 | Minimum sequence length after barcode clipping (see [Minimum read length](#minimum-read-length)) |
| `-L, --max-input-length` | int | 0 | Maximum input sequence length (0 = no cap) |
| `-M, --bad-adapter-ratio` | float | 0 | Maximum ratio of bad adapters per ZMW before rejection |
| `-P, --shared-prefix` | flag | off | Allow barcodes to be substrings of others (needed for some custom barcode sets) |
| `--fail-reads-only` | flag | off | Only process `fail_reads.bam` files from the input dataset XML |

#### Barcode region

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-w, --window-size-multi` | float | 3 | Search window size as a multiplier of barcode length |
| `-W, --window-size` | int | 0 | Explicit search window size in bp; overrides the multiplier when set (see [Window size](#window-size)) |
| `-r, --min-ref-span` | float | 0.5 | Minimum reference span as a fraction of barcode length (presets override this to 0.75) |
| `-R, --min-scoring-regions` | int | 1 | Minimum barcode regions with sufficient span (ASYMMETRIC preset sets this to 2) |

#### Score filters

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-m, --min-score` | int | 0 | Reads with combined barcode score ≤ this are dropped |
| `-i, --min-end-score` | int | 0 | Minimum per-end barcode score (applied to leading and trailing flanks separately) |
| `-x, --min-signal-increase` | int | 10 | Minimum score difference between first and combined for a pair to be called "different" |
| `-y, --min-score-lead` | int | 10 | Minimum score lead between best and second-best barcode call |

#### Aligner configuration

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `--ccs` | flag | off | CCS-tuned alignment penalties (`-A 1 -B 4 -D 3 -I 3 -X 4`); all HiFi presets enable this |
| `-A, --match-score` | int | 4 | Sequence match score |
| `-B, --mismatch-penalty` | int | 13 | Mismatch penalty |
| `-D, --deletion-penalty` | int | 7 | Deletion penalty |
| `-I, --insertion-penalty` | int | 7 | Insertion penalty |
| `-X, --branch-penalty` | int | 4 | Branch penalty |

#### Output splitting

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `--split` | flag | off | Split output by barcode pair index |
| `--split-named` | flag | ★ on | Split output by resolved barcode pair name (Ophelia adds this) |
| `-F, --files-per-directory` | int | 0 | Group split output into subdirectories of N files each (0 = single dir) |
| `--split-subdirs` | flag | off | Place each barcode in its own subdirectory |
| `-U, --reuse-biosample-uuids` | flag | off | Reuse UUIDs from BioSample entries (XML output only) |
| `--reuse-source-uuid` | flag | off | Reuse UUID from input dataset XML |
| `--no-clip` | flag | off | Call barcode pairs but do not clip them from the read sequence |

#### Output restrictions

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `--output-handles` | int | 500 | Maximum number of simultaneously open output files |
| `--dump-clips` | flag | off | Dump clipped barcode regions to `<prefix>.lima.clips` |
| `--store-unbarcoded` | flag | ★ on | Store unbarcoded reads to a separate file (Ophelia adds this; combine with `--drop-unbarcoded` after QC to reclaim disk space) |
| `--no-output` | flag | off | Skip demultiplexed BAM output entirely (reports only) |
| `--no-reports` | flag | off | Skip the lima reports (`.summary` / `.report` / `.counts`) |
| `--output-missing-pairs` | flag | off | Emit empty BAMs for all biosample barcode pairs, even those with zero reads |

#### Single-side library options

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-S, --single-side` | flag | off | Assign barcodes from a single side by score clustering |
| `--scored-adapter-ratio` | float | 0.25 | Minimum ratio of scored to sequenced adapters |
| `--ignore-missing-adapters` | flag | off | Ignore consensus-read flanks labelled as missing-adapter (SYMMETRIC-ADAPTERS preset enables this) |

#### IsoSeq

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `--isoseq` | flag | off | IsoSeq-specific demultiplexing (not used by typical Ophelia HD/amplicon workflows) |

#### Inference and biosample handling

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `--peek` | int | 0 | Demux only the first N ZMWs and report mean barcode score (for barcode-set sanity-checking) |
| `--guess` | int | 0 | Two-pass inference: keep barcode pairs with mean score ≥ N (0 = disabled) |
| `--guess-min-count` | int | 0 | Minimum ZMW count for a barcode pair to be whitelisted during inference |
| `--peek-guess` | flag | off | Shortcut for `--peek 50000 --guess 45 --guess-min-count 10` (with `--ccs`: 75/10; with `--isoseq`: 75/100) |
| `--ignore-xml-biosamples` | flag | off | Ignore `<BioSamples>` entries from XML input |
| `--biosample-csv` | str | none | Map barcode pairs to biosample names (Ophelia: use `--biosample_csv` instead) |
| `--overwrite-biosample-names` | flag | off | In `--isoseq` mode, overwrite existing SM tag values |

#### Index sorting (CCS only)

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-k, --keep-tag-idx-order` | flag | off | Keep identified barcode pair index order in the BC tag |
| `-K, --keep-split-idx-order` | flag | off | Keep identified barcode pair index order in split output filenames |

#### Logging and runtime

| Flag | Type | Default | Description |
| --- | --- | --- | --- |
| `-j, --num-threads` | int | 0 | Thread count; 0 = autodetect (Ophelia sets this from `--threads`, don't pass directly) |
| `--log-level` | str | WARN | Log verbosity: TRACE, DEBUG, INFO, WARN, FATAL |
| `--log-file` | file | – | Log to a file instead of stderr |

### Quick reference – passing args through Ophelia

Anything that doesn't have a dedicated Ophelia flag goes inside `--lima_args`:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results \
    --barcode_ref ~/refs/barcodes.fasta \
    --lima_preset ASYMMETRIC \
    --lima_args "--split-named --store-unbarcoded --peek-guess --window-size 100" \
    --reorganise by-type
```

Ophelia explicitly handles `--biosample-csv` (via `--biosample_csv`), `--num-threads` (via `--threads`), and `--hifi-preset` (via `--lima_preset`) – passing these inside `--lima_args` will cause a duplicate-flag error from lima. Everything else is fair game.

---

## Common workflows

### 1. Pool by type for downstream consumption (recommended)

The most common workflow when feeding output into downstream pipelines (e.g. Duke):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise by-type
# Then point downstream tools at ~/results/demux/barcoded/
```

Output files are named by barcode pair (e.g., `bc1002--bc1050.bam`) and pooled flat in `dir_out/barcoded/`. Filenames retain library identity so there are no cross-sample collisions.

### 2. Sample-centric view (one sample at a time)

When you want to work with each library as a self-contained unit:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise by-sample-type
```

### 3. Raw lima output

If you'd rather have one flat directory per input BAM (no reorganisation):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta
```

### 4. Process specific files

Process only certain BAM files (e.g., exclude `unassigned.bam`):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --file_pattern "*bc20*.bam" \
    --reorganise by-type
```

### 5. Unknown barcodes

When you don't know which barcode combinations are present (lima will infer):

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --lima_args "--split-named --store-unbarcoded --peek-guess"
```

**Note:** `--peek-guess` is slower (two-pass).

### 6. Test run (dry run)

See what would happen without actually running:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise by-type \
    --dry_run
```

### 7. Re-running on an existing dir_out

Ophelia has no resume mode – every invocation processes every input BAM. If the previous run produced raw output (no `--reorganise`), re-running is safe: lima will overwrite the per-sample files cleanly.

If the previous run was reorganised, Ophelia will refuse to run. Delete `--dir_out` and start over, or point at a fresh path:

```bash
rm -rf ~/results/demux
./ophelia --dir_data ~/data/bam --dir_out ~/results/demux ...
```

See [Re-running on an existing dir_out](#re-running-on-an-existing-dir_out) for the full rationale.

### 8. Custom SM tags (optional)

If downstream tools require custom sample names in the BAM `@RG SM:` tag:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --biosample_csv ~/refs/biosample.csv \
    --reorganise by-type
```

This overrides the original SM tag (e.g., `SM:lib_05` from sequencing setup) with your biosample name. Most users don't need this – use filenames for sample tracking instead.

### 9. Save disk space on confirmed runs

Once a demux has been QC'd and you're confident the unbarcoded reads aren't needed:

```bash
./ophelia \
    --dir_data ~/data/bam \
    --dir_out ~/results/demux \
    --barcode_ref ~/refs/pacbio_M13_barcodes.fasta \
    --reorganise by-type --drop-unbarcoded
```

Or retrofit an existing raw run:

```bash
scripts/reorganise_ophelia.sh \
    --mode by-type \
    --path ~/results/demux \
    --dir_out ~/results/demux \
    --drop-unbarcoded
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

### "exists at top level" or "contains a reorganised layout"

This appears when `--dir_out` already has a `barcoded/`, `reports/`, or `unbarcoded/` directory (either at the top level or inside a sample dir) from a previous reorganised run. Ophelia refuses to mix fresh lima output into an existing reorganised tree. To proceed:

- Delete `--dir_out` and re-run from scratch (cleanest), or
- Point `--dir_out` at a fresh path.

To change the layout of an existing raw run without re-running lima, use `scripts/reorganise_ophelia.sh` instead.

### "--reorganise requires a mode value"

As of v1.2.0, `--reorganise` requires a mode value. Old scripts that used `--reorganise` bare will fail with this error. Update to one of:

```bash
--reorganise by-sample       # raw output (same as omitting the flag)
--reorganise by-sample-type  # per-sample dirs with type subdirs
--reorganise by-type         # pooled type dirs (recommended for downstream)
--reorganise by-type-sample  # pooled type dirs with per-sample subdirs
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

### "Low demultiplexing rate"

Check the `*.lima.summary` file (location depends on `--reorganise` mode):

```bash
cat results/m84277_..._bc2001/*.lima.summary           # raw layout
cat results/m84277_..._bc2001/reports/*.lima.summary   # by-sample-type
cat results/reports/m84277_..._bc2001.demux.lima.summary  # by-type
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

### 1.2.1 (May 2026)

- **Bugfix:** `--lima_preset TAILED` is no longer accepted by ophelia's validation. Lima has no `TAILED` HiFi preset (the only valid values are `ASYMMETRIC`, `SYMMETRIC`, and `SYMMETRIC-ADAPTERS`, verified against lima 2.13.0's `--help`). Previously ophelia's allowlist included `TAILED` so the value passed ophelia's check and only failed when lima itself rejected it. For tailed-library designs, use `SYMMETRIC`.
- **Bugfix:** `--dry_run` no longer requires `lima` in `PATH`. The lima check is now downgraded to a warning during dry-run, so the canonical "preview from my laptop before `qsub`" workflow works on machines without lima installed.
- **Bugfix:** dry-run lima command preview now shows the would-be cleaned biosample CSV path (`<dir_out>/biosample_cleaned.csv`) rather than the original BOM-containing path, matching what an actual run would execute.
- **Docs:** `--dump-removed` removed from the "useful flags" list and the help text – the flag does not exist in lima 2.13.0. Replaced with `--dump-clips` (which dumps clipped barcode regions to `<prefix>.lima.clips`) where the QC use case applies.
- **Docs:** Expanded the lima reference with a full flag catalog organised to mirror `lima --help`'s own sections, verified against lima 2.13.0 on UCL Myriad. Covers Library design, Input limitations, Barcode region, Score filters, Aligner configuration, Output splitting/restrictions, Single-side, IsoSeq, Inference, Index sorting, and Logging.
- **Docs:** `--threads` help text now describes the actual behaviour (`0` omits `--num-threads` so lima picks – usually all visible cores) rather than the vague "auto-detect".
- **Docs:** `--help` now documents the `--reorganize` and `-h` aliases.
- **Docs:** Myriad template now flags itself as Small-run sized and points to the README's resource table for scaling up. Optional-extras comment block moved below the command to remove indentation ambiguity.
- Minor: removed an unused `local` declaration in `reorganise_ophelia.sh`'s `detect_path_type`.

### 1.2.0 (May 2026)

- **Breaking:** `--reorganise` now requires a mode value. Scripts that used `--reorganise` bare must be updated (typically to `--reorganise by-sample-type` to preserve previous behaviour, or `--reorganise by-type` for the new pooled layout).
- **Breaking:** sample output directories are now named after the BAM basename with no prefix. Previously they were `demux_<bam_basename>/`; now they are `<bam_basename>/`. Downstream pipelines that glob `demux_*/` need to be updated.
- **Breaking:** the `--resume` / `--no-resume` flags have been removed. Each invocation now runs lima on every input BAM. If `--dir_out` already contains a reorganised layout, Ophelia refuses to run rather than risk producing inconsistent mixed output. Resilience against long-running jobs is better handled at the scheduling layer (e.g. one job per BAM) than via in-script resume logic.
- **New:** four `--reorganise` modes: `by-sample` (raw output, default), `by-sample-type`, `by-type`, `by-type-sample`. See [Output reorganisation](#output-reorganisation).
- **New:** `--reorganise by-type` pools all samples' barcoded BAMs into one top-level `barcoded/` directory across libraries. Recommended for feeding into downstream pipelines.
- `--no-reorganise` removed (use `--reorganise by-sample` or omit the flag entirely).
- Standalone `reorganise_ophelia.sh` updated: requires `--mode`, refuses already-reorganised input, auto-detects sample dirs vs parent dirs by content.
- Dry-run no longer touches `dir_out` or writes `biosample_cleaned.csv`. The timestamped `logs/<timestamp>/` directory and its `ophelia.log` / `ophelia_params.txt` are still written so the preview is reproducible.
- Library: `reorganise_sample_dir` now takes `(sample_dir, mode, dir_out, drop_unbarcoded, dry_run)`; `locate_summary_file` probes all four mode layouts; nullglob state is saved and restored.
- Myriad template updated to use `--reorganise by-type` and a placeholder email.

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
