# R2 Processing Pipeline - Quick Start Guide

This repository contains automated pipelines for processing Multi-Echo Spin-Echo (MESE) MRI data to generate T2/R2 maps and R2' (R2 prime) maps. The pipelines use PyMRItools, FSL, SPM12, and other neuroimaging tools within a SLURM-scheduled batch processing framework.

> **For detailed documentation**, see:
> - [T2 Processing Pipeline Documentation](docs/doc_t2_processing.md)
> - [R2' Calculation Pipeline Documentation](docs/doc_r2prime_calculation.md)

---

## Table of Contents

1. [Quick Overview](#quick-overview)
2. [Prerequisites](#prerequisites)
3. [Setup](#setup)
4. [Usage](#usage)
   - [T2 Processing Pipeline](#use-t2-processing-pipeline)
   - [R2' Calculation Pipeline](#use-r2p-calculation-pipeline)
5. [Common Workflows](#common-workflows)
6. [Monitoring Jobs](#monitoring-jobs)
7. [Getting Help](#getting-help)

---

## Quick Overview

### T2 Processing Pipeline

**Input:** BIDS-structured MESE and AFI data  
**Output:** T2 maps, R2 maps, B1+ maps

**Processing Steps:**
1. MP-PCA Denoising + Noise Bias Correction
2. Gradient Non-linearity Correction (GNLC)
3. B1+ Field Mapping (AFI + EMC)
4. Dictionary-based T2/R2 Fitting

### R2' Calculation Pipeline

**Input:** R2 maps (from T2 processing), R2* maps (from qMRI), PDw echoes (for reference)  
**Output:** R2' maps (R2' = R2* - R2)

**Processing Steps:**
1. Reference Image Creation (PDw echo summation)
2. R2 Slab Coregistration to PDw space
3. R2' Calculation with validation

---

## Prerequisites

### Required Software
- **Singularity/Apptainer** container runtime
- **SLURM** workload manager
- **[batch_gnlc](https://github.com/nkuegler/batch_gnlc/)** repository and its dependencies for gradient non-linearity correction (not available in the container yet)

### Required Data Structures

**For T2 Processing:**
```
parent_directory/
├── sub-XXX/
│   └── ses-YY/
│       ├── anat/
│       │   └── *_MESE.nii[.gz]
│       └── fmap/
│           └── *_TB1AFI.nii[.gz]
```

**For R2' Calculation:**
- R2 maps (from T2 processing): `r2_dir/sub-*/ses-*/anat/*_R2map.nii`
- R2* maps (from qMRI): `r2s_dir/sub-*/ses-*/anat/*_R2starmap.nii`
- PDw echoes: `pdw_dir/sub-*/ses-*/anat/*acq-PDw*echo-*.nii`

### Container

For MPI CBS employees: Pre-built container available at:
```
/data/p_gr_weiskopf_software/singularity/pymritools.sif
```

Or build your own using provided container build file (see [detailed documentation](docs/doc_t2_processing.md#container-setup)).

---

## Setup

### 1. Clone the Repository

```bash
git clone https://github.com/nkuegler/r2_processing.git
cd r2_processing
```

### 2. Prepare Required Files

#### Dictionary Databases
A pre-computed dictionary database is required for R2 pattern matching, specific to your sequence parameters and field strength. The simulation can be performed using [PyMRItools](https://github.com/schmidt-jo/PyMRItools).

Update the path in `t2_calc_b1corr_t2fit.py`:
```python
if magnetic_field == 7.0:
    path_db = plib.Path("/path/to/emc_database_7T_semc_0p6.pkl")
elif magnetic_field == 3.0:
    path_db = plib.Path("/path/to/db_mese_3T_etl10.pkl")
```

#### Scanner-Specific Gradient Coefficients
Ensure gradient coefficients (`.grad` files) are available for your scanner in the [batch_gnlc](https://github.com/nkuegler/batch_gnlc/) repository. These files are proprietary, so they cannot be shared and you must acquire them from the manufacturer of your MRI system.

#### Manual Noise Masks (3T Data Only)
For 3T data, create manual noise masks:
1. Open echo-01 of MESE data in viewer (FSLeyes, etc.)
2. Draw ROI containing only noise voxels (outside brain, avoid GRAPPA artifacts)
3. Save as: `{subject}_{session}_acq-semc_echo-01_MESE_noiseMaskManual.nii`
4. Place in noise mask directory (e.g., `output_dir/manualNoiseMasks/`)

> **Why?** Automatic noise extraction doesn't work reliably for all MRI brain data due to limited air space and GRAPPA aliasing artifacts. See [3T-specific considerations](docs/doc_t2_processing.md#field-strength-considerations). \
> However, field strength is not the only reason for this. It is possible that the `autodmri` noise estimation extraction works for your data regardless of the field strength. 

---

## Usage

<h3 id="use-t2-processing-pipeline">T2 Processing Pipeline</h>

[full documentation](docs/doc_t2_processing.md)

#### Basic Syntax

```bash
./t2_processing_main.sh [OPTIONS] -cont <container> <scanner_name> <input_dir> <output_dir>
```

#### Required Arguments

| Argument | Description |
|----------|-------------|
| `-cont PATH` | Path to Singularity container |
| `<scanner_name>` | Scanner name: `Terra`, `Prisma_fit`, `Skyra_fit`, `Verio`, `Magnetom7T`, `Connectom` |
| `<input_dir>` | Parent directory with BIDS-structured input data |
| `<output_dir>` | Output directory for results |

#### Key Optional Arguments

| Flag | Description | Default |
|------|-------------|---------|
| `-b FIELD` | Magnetic field strength (Tesla) | `7` |
| `-fa ANGLE` | AFI flip angle (degrees) | `55.0` |
| `-tr RATIO` | AFI TR ratio (TR2/TR1) | `5.0` |
| `-sub SUBJECTS` | Comma-separated subject list | All subjects |
| `-ses SESSIONS` | Comma-separated session list (requires `-sub`) | All sessions |
| `-nmd DIR` | Noise mask directory (**required for 3T**) | `output_dir/manualNoiseMasks` |
| `-pw` | Preserve working directories (skip cleanup) | Cleanup enabled |

> For all options, see: `./t2_processing_main.sh --help` or [full documentation](docs/doc_t2_processing.md#command-line-options)

#### Examples

**7T Processing (All Subjects):**
```bash
./t2_processing_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -b 7 \
  Terra \
  /data/bids_input \
  /data/derivatives/relax_R2
```

**3T Processing (Specific Subject):**
```bash
./t2_processing_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -b 3 \
  -fa 60.0 \
  -tr 3.0 \
  -sub sub-001 \
  -ses ses-05 \
  -nmd /data/derivatives/relax_R2/manualNoiseMasks \
  Prisma_fit \
  /data/bids_input \
  /data/derivatives/relax_R2
```

**Preview Commands (Dry Run):**
```bash
./t2_processing_main.sh --dry-run [other options...]
```

---

<h3 id="use-r2p-calculation-pipeline">R2' Calculation Pipeline</h>

[full documentation](docs/doc_r2prime_calculation.md)

#### Basic Syntax

```bash
./r2prime_calculation/r2prime_creation_main.sh -cont <container> -pdw <pdw_dir> -r2 <r2_dir> -r2s <r2s_dir> -o <output_dir>
```

#### Required Arguments

| Flag | Description |
|------|-------------|
| `-cont PATH` | Path to Singularity container |
| `-pdw DIR` | Directory with PDw echoes (denoised, GNLC-corrected) |
| `-r2 DIR` | Directory with R2 maps (from T2 processing) |
| `-r2s DIR` | Directory with R2* maps (from qMRI) |
| `-o DIR` | Output directory for R2' maps |

#### Key Optional Arguments

| Flag | Description | Default |
|------|-------------|---------|
| `-sub SUBJECTS` | Comma-separated subject list | All subjects |
| `-ses SESSIONS` | Comma-separated session list (requires `-sub`) | All sessions |
| `-fp PATTERN` | Filename pattern for PDw echoes | `*acq-PDw*echo-*part-mag*.nii` |
| `-pw` | Preserve working directories | Cleanup enabled |

> For all options, see: `./r2prime_calculation/r2prime_creation_main.sh --help` or [full documentation](docs/doc_r2prime_calculation.md#command-line-options)

#### Examples

**Process All Sessions:**
```bash
./r2prime_calculation/r2prime_creation_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -pdw /data/derivatives/LCPCA_distCorr \
  -r2 /data/derivatives/relax_R2 \
  -r2s /data/derivatives/qMRI_noB1corr \
  -o /data/derivatives/r2prime/b7T
```

**Process Specific Subject/Session:**
```bash
./r2prime_calculation/r2prime_creation_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -sub sub-001 \
  -ses ses-05 \
  -pdw /data/derivatives/LCPCA_distCorr \
  -r2 /data/derivatives/relax_R2 \
  -r2s /data/derivatives/qMRI_noB1corr \
  -o /data/derivatives/r2prime/b3T
```

---

## Common Workflows

### Complete 7T Processing

```bash
# Step 1: T2 Processing
./t2_processing_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -b 7 \
  Terra \
  /data/bids_input \
  /data/derivatives/relax_R2

# Step 2: R2' Calculation (after T2 processing and qMRI complete)
./r2prime_calculation/r2prime_creation_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -pdw /data/derivatives/LCPCA_distCorr \
  -r2 /data/derivatives/relax_R2 \
  -r2s /data/derivatives/qMRI_noB1corr \
  -o /data/derivatives/r2prime/b7T
```

### Complete 3T Processing

```bash
# Step 0: Prepare manual noise masks (see Setup section)

# Step 1: T2 Processing
./t2_processing_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -b 3 \
  -fa 60.0 \
  -tr 3.0 \
  -nmd /data/derivatives/relax_R2/manualNoiseMasks \
  Prisma_fit \
  /data/bids_input \
  /data/derivatives/relax_R2

# Step 2: R2' Calculation
./r2prime_calculation/r2prime_creation_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -pdw /data/derivatives/LCPCA_distCorr \
  -r2 /data/derivatives/relax_R2 \
  -r2s /data/derivatives/qMRI_noB1corr \
  -o /data/derivatives/r2prime/b3T
```

---

## Monitoring Jobs

### Check Job Status

```bash
# View all your jobs
squeue -u $USER

# View specific job details
scontrol show job <job_id>
```

### Check Logs

**T2 Processing:**
```bash
ls -lh logs/denoise/    # Denoising job logs
ls -lh logs/t2fit/      # T2 fitting job logs
ls -lh logs/gnlc/       # GNLC job logs
```

**R2' Calculation:**
```bash
ls -lh logs/r2prime_calc/    # All R2' pipeline logs
```

### Expected Output

**T2 Processing** creates (per subject/session):
```
output_dir/sub-XXX/ses-YY/anat/
├── sub-XXX_ses-YY_R2map.nii
├── sub-XXX_ses-YY_R2map.json
├── sub-XXX_ses-YY_T2map.nii
├── sub-XXX_ses-YY_T2map.json
├── sub-XXX_ses-YY_TB1map.nii
└── sub-XXX_ses-YY_TB1map.json
```

**R2' Calculation** creates (per subject/session):
```
output_dir/sub-XXX/ses-YY/anat/
├── sub-XXX_ses-YY_R2primemap.nii
└── sub-XXX_ses-YY_R2primemap.json
```

---

## Getting Help

### Documentation

- **T2 Processing:** [docs/doc_t2_processing.md](docs/doc_t2_processing.md)

- **R2' Calculation:** [docs/doc_r2prime_calculation.md](docs/doc_r2prime_calculation.md)

  - Detailed pipeline description
  - Processing parameters explained
  - Guidance for troubleshooting

### Command-line Help

```bash
# T2 Processing
./t2_processing_main.sh --help

# R2' Calculation
./r2prime_calculation/r2prime_creation_main.sh --help
```

---

**Author:** Niklas Kuegler (kuegler@cbs.mpg.de)  
**Repository:** https://github.com/nkuegler/r2_processing
