# Documentation: R2' (R2 Prime) Calculation Pipeline

This page describes the R2' (R2 prime) calculation pipeline for creating R2' maps from Multi-Parametric Mapping (MPM) data. The pipeline combines R2* maps from quantitative MRI (qMRI) processing with R2 maps from the T2 processing pipeline to calculate `R2' = R2* - R2`, which represents the reversible transverse relaxation rate contribution.

> **R2' (R2 prime)** is the reversible contribution to transverse relaxation, calculated as the difference between the effective transverse relaxation rate (R2*) and the irreversible transverse relaxation rate (R2). R2' is sensitive to local field inhomogeneities, particularly those induced by tissue microstructure and magnetic susceptibility variations.<br>
> R2' mapping is valuable for investigating tissue iron content, blood oxygenation (BOLD effect), and microstructural properties of brain tissue.<br>

The scripts that are described on this page are part of the **r2_processing** repository, located in the `r2prime_calculation/` subdirectory. The main processing script `r2prime_creation_main.sh` orchestrates the entire pipeline by submitting SLURM jobs for automated batch processing of BIDS-structured MRI data.

---

## Table of Contents

1. [Overview](#overview)
2. [Requirements](#requirements)
3. [Processing Pipeline](#processing-pipeline)
   - [Pipeline Stages](#pipeline-stages)
   - [Data Flow](#data-flow)
   - [Job Dependencies](#job-dependencies)
4. [Usage](#usage)
   - [Main Script](#main-script)
   - [Command-line Options](#command-line-options)
   - [Examples](#examples)
5. [Processing Details](#processing-details)
   - [Stage 1: Reference Image Creation](#stage-1-reference-image-creation)
   - [Stage 2: R2 Slab Coregistration](#stage-2-r2-slab-coregistration)
   - [Stage 3: R2' Calculation](#stage-3-r2-calculation)
   - [Stage 4: Cleanup](#stage-4-cleanup)
6. [Output Structure](#output-structure)
7. [File Description](#file-description)
8. [Quality Control](#quality-control)
9. [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)
10. [Integration with T2 Processing](#integration-with-t2-processing)

---

## Overview

The R2' calculation pipeline performs the following operations:

1. **Reference Image Creation** - Sums all PDw (Proton Density weighted) echoes to create a high-SNR reference image 
   - all qMRI maps are present in the PDw space
   - PDw echoes should be denoised and gradient nonlinearity corrected
2. **R2 Slab Coregistration** - Aligns R2 maps (from T2 processing) to the PDw reference space using SPM12 (*Estimate and Reslice*); the coregistered R2 map and its JSON sidecar are saved directly into the R2 input directory
3. **R2' Calculation** - Computes `R2' = R2* - R2` with appropriate masking and validation
4. **Cleanup** - Removes intermediate working directories (optional)

The pipeline is designed to work with BIDS-structured derivatives from:
- **T2 processing pipeline** (provides R2 maps)
- **qMRI processing** (provides R2* maps)
- **MPM processing** (provides PDw echoes for reference)

All processing steps automatically generate BIDS-compliant JSON sidecar files alongside the imaging data, containing comprehensive processing metadata including input file names, software versions, and technical parameters to assure reproducibility.


---

## Requirements

### Software Dependencies

- **Singularity/Apptainer** - For container execution
- **SLURM** - For job scheduling
- **FSL 6.0.6 or later** - For image manipulation (fslmaths, fslorient)
- **SPM12** - For coregistration
- **MATLAB R2024b or compatible** - For running SPM12

Aside from MATLAB-based software (SPM12 and MATLAB), the provided singularity container can be used as a full working environment with all necessary binaries for running the scripts in this repository. \
**If you are planning to avoid the container**, you need to set set up an environment containing all necessary software tools and packages (and adjust the code in several locations).

### Data Requirements

The pipeline requires three BIDS-structured input directories (PDw, R2*, R2), each containing the same subjects/sessions:

1. **PDw Directory** - Proton density weighted echo data
   ```
   pdw_dir/
   ├── sub-XXX/
   │   └── ses-YY/
   │       └── anat/
   │           ├── *acq-PDw*echo-01*part-mag*.nii
   │           ├── *acq-PDw*echo-02*part-mag*.nii
   │           └── ... (all PDw echoes)
   ```

2. **R2 Directory** - R2 maps from T2 processing pipeline
   ```
   r2_dir/
   ├── sub-XXX/
   │   └── ses-YY/
   │       └── anat/
   │           └── *_R2map.nii
   ```

3. __R2* Directory__ - R2* maps from qMRI processing
   ```
   r2s_dir/
   ├── sub-XXX/
   │   └── ses-YY/
   │       └── anat/
   │           └── *_R2starmap.nii
   ```

**Important:** Each subject/session must be present in **all three directories** for processing to proceed.


### Container Requirements

A Singularity container with FSL tools is required. The container path must be specified with the `-cont` flag.

> **Note:** If you are working in the compute infrastructure of the MPI CBS (Leipzig, Germany), the **pre-built container** may be found at: `/data/p_gr_weiskopf_software/singularity/pymritools.sif` \
> If you cannot access it, you can build the container yourself. Instructions on how to do this are available in the documentation of the T2 processing pipeline.

---

## Processing Pipeline

### Pipeline Stages

The pipeline consists of four main stages, executed sequentially for each subject/session:

```
┌──────────────────────────────────────────────────────────────┐
│ Stage 1: Reference Image Creation                            │
│ - Sum all PDw echoes using FSL's fslmaths to create high-SNR │
│   reference for coregistration                               │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────────────┐
│ Stage 2: R2 Slab Coregistration                              │
│ - Align R2 map to PDw reference space using SPM12            │
│ - Rigid body transformation (6 DOF)                          │
│ - 4th degree B-spline interpolation                          │
│ - Coregistered output saved to R2 input directory            │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────────────┐
│ Stage 3: R2' Calculation                                     │
│ - Validate sform matrix alignment between R2* and R2         │
│ - Calculate R2' = R2* - R2                                   │
│ - Apply masking and thresholding                             │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────────────┐
│ Stage 4: Cleanup (optional, default: enabled)                │
│ - Session cleanup (per-session working directories)          │
│ - Final cleanup (entire working directory structure)         │
└──────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Input Data (Three BIDS Directories)
    │
    ├── PDw echoes (pdw_dir/sub-*/ses-*/anat/)
    ├── R2 maps (r2_dir/sub-*/ses-*/anat/)
    └── R2* maps (r2s_dir/sub-*/ses-*/anat/)
    │
    ↓
Reference Image (working_dir/)
    │
    └── PDw_echoes_sum.nii (sum of all PDw echoes)
    │
    ↓
Coregistered R2 (r2_dir/)
    │
    └── coreg_*_R2map.nii (R2 aligned to PDw space)
    │
    ↓
Final R2' Output (output_dir/)
    │
    └── *_R2primemap.nii + .json
```

> Additional helper files will be created but deleted in the cleanup step. Use the `--preserve-workdir` flag to avoid the deletion of intermediate files.

### Job Dependencies

The pipeline uses SLURM job dependencies to ensure correct execution order:

```
Session Processing:
─────────────────────────────────────────────────────────────

Reference Creation Job (Job ID: 12345)
    │
    └──> R2 Coregistration Job (depends on Job 12345)
            │
            └──> R2' Calculation Job (depends on Coregistration)

If cleanup enabled:
    │
    └──> Session Cleanup Job (depends on R2' Calculation)

Final Cleanup (after all sessions):
─────────────────────────────────────────────────────────────

Final Cleanup Job (depends on all Session Cleanup jobs)
    │
    └──> Removes entire working directory structure
```

**Dependency Chain:**
1. Coregistration waits for reference image creation
2. R2' calculation waits for coregistration completion
3. Session cleanup waits for R2' calculation
4. Final cleanup waits for all session cleanups

This ensures that:
- Reference image exists before attempting coregistration
- R2 map is properly aligned before subtraction
- Intermediate files are preserved until final outputs are created
- Global cleanup only occurs after all sessions complete

---

## Usage

### Main Script

The main entry point is `r2prime_creation_main.sh`, which automatically discovers and processes all subjects/sessions present in all three input directories.

```bash
./r2prime_creation_main.sh [options] -cont <container> -pdw <pdw_dir> -r2 <r2_dir> -r2s <r2s_dir> -o <output_dir>
```

> Currently, there are still some hard-coded paths left in the code. You can find information about that in the [Open ToDo's](docs/todos.md).

### Command-line Options

#### Mandatory Flags

All required arguments **must be specified with flags**:

| Flag | Description |
|------|-------------|
| `-cont PATH`<br>`--container PATH` | Path to Singularity container with FSL and coregistration tools |
| `-pdw DIR`<br>`--pdw-dir DIR` | Directory containing BIDS-structured PDw echo data |
| `-r2 DIR`<br>`--r2-dir DIR` | Directory containing BIDS-structured R2 slab data |
| `-r2s DIR`<br>`--r2s-dir DIR` | Directory containing BIDS-structured R2* map data |
| `-o DIR`<br>`--output-dir DIR` | Output directory for R2' maps (creates BIDS structure) |


#### Optional Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-t SECONDS`<br>`--delay SECONDS` | Delay between job submissions in seconds | `1` |
| `-sub SUBJECTS`<br>`--subjects SUBJECTS` | Comma-separated list of subjects to process<br>(e.g., `sub-001,sub-002`) | All subjects |
| `-ses SESSIONS`<br>`--sessions SESSIONS` | Comma-separated list of sessions to process<br>(e.g., `ses-01,ses-02`)<br>**Requires `-sub` to be specified** | All sessions |
| `-w DIR`<br>`--work-dir DIR` | Working directory for intermediate files | `output_dir/Supplementary` |
| `-fp PATTERN`<br>`--fname-pattern PATTERN` | Filename pattern for echo files | `*acq-PDw*echo-*part-mag*.nii` |
| `-pw`<br>`--preserve-workdir` | Preserve working directories after processing<br>(skip cleanup) | Cleanup enabled |
| `--dry-run` | Show commands without executing | Execute jobs |
| `-h`<br>`--help` | Display help message and exit | - |

### Examples

#### Basic Processing (All Subjects/Sessions)

```bash
./r2prime_creation_main.sh \
  -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif \
  -pdw /data/derivatives/LORAKS/derivatives/LCPCA_distCorr/ \
  -r2 /data/derivatives/relax_R2/ \
  -r2s /data/derivatives/LORAKS/derivatives/qMRI/ \
  -o /data/derivatives/r2prime/b7T/
```

#### Processing Specific Subjects

```bash
./r2prime_creation_main.sh \
  -sub "sub-001,sub-002" \
  -cont /path/to/container.sif \
  -pdw /data/pdw_echoes \
  -r2 /data/r2_slabs \
  -r2s /data/qMRI \
  -o /data/output
```

#### Processing Specific Sessions for Specific Subjects

```bash
./r2prime_creation_main.sh \
  -sub "sub-001" \
  -ses "ses-05,ses-06,ses-07" \
  -cont /path/to/container.sif \
  -pdw /data/pdw_echoes \
  -r2 /data/r2_slabs \
  -r2s /data/qMRI \
  -o /data/output
```

#### Custom Working Directory with Preservation

```bash
./r2prime_creation_main.sh \
  -w /scratch/temp \
  -pw \
  -cont /path/to/container.sif \
  -pdw /data/pdw_echoes \
  -r2 /data/r2_slabs \
  -r2s /data/qMRI \
  -o /data/output
```

#### Custom Echo File Pattern

```bash
./r2prime_creation_main.sh \
  --fname-pattern "*PDw*echo*.nii" \
  -cont /path/to/container.sif \
  -pdw /data/pdw_echoes \
  -r2 /data/r2_slabs \
  -r2s /data/qMRI \
  -o /data/output
```

#### Dry Run (Preview Commands)

```bash
./r2prime_creation_main.sh \
  --dry-run \
  -t 5 \
  -cont /path/to/container.sif \
  -pdw /data/pdw_echoes \
  -r2 /data/r2_slabs \
  -r2s /data/qMRI \
  -o /data/output
```

#### 7T vs 3T Processing

No adjustments are needed for processing a different field strength. However, make sure that you separate the output maps in different directories for convenience (e.g., `-o /data/derivatives/r2prime/b7T/` and `-o /data/derivatives/r2prime/b3T/`).

---

## Processing Details

### Stage 1: Reference Image Creation

**Script:** `ref_sum_echoes.sh`

#### Operations Performed

1. **Echo File Discovery**
   - Searches PDw directory for files matching specified pattern
   - Default pattern: `*acq-PDw*echo-*part-mag*.nii`
   - Files are sorted alphabetically for reproducibility
   - Validates that at least one echo file is found

2. **Echo Summation**
   - Uses FSL `fslmaths` to sum all echo files
   - Chained `-add` operations: `fslmaths echo1 -add echo2 -add echo3 ... output`
   - Creates high-SNR reference image for coregistration
   - Output: `PDw_echoes_sum.nii.gz` (or custom name if specified)

3. **File Decompression**
   - Automatically decompresses output (.nii.gz → .nii)
   - Required for SPM12 compatibility in next stage

4. **Metadata Preservation**
   - Copies JSON sidecar from first echo file
   - Preserves acquisition parameters for documentation

#### Why PDw Echoes?

PDw (Proton Density weighted) images are used because:
- All qMRI maps are calculated in PDw space
- Minimal T1 or T2 weighting provides good anatomical contrast
- Summing multiple echoes improves SNR for robust coregistration

#### Output Files

| File | Description |
|------|-------------|
| `PDw_echoes_sum.nii` | Sum of all PDw echoes (decompressed) |
| `PDw_echoes_sum.json` | JSON sidecar (copied from first echo) |

---

### Stage 2: R2 Slab Coregistration

**Scripts:** `coreg_r2_slab_slurm.sh` → `coreg_r2_slab.m`

#### Operations Performed

1. **Input Validation**
   - Verifies moving image (R2 map) exists
   - Verifies reference image (PDw sum) exists
   - Creates output directory if needed

2. **SPM12 Coregistration**
   - Executes MATLAB/SPM12 batch processing
   - Calls `coreg_r2_slab.m` MATLAB function
   - Performs rigid body alignment (6 degrees of freedom)
   - Uses normalized mutual information as cost function

3. **Result Management**
   - Moves coregistered file to the R2 input directory
   - Adds `coreg_` prefix to filename
   - Overwrites existing files if present
   - Validates successful completion

4. **JSON Metadata Creation**
   - Creates comprehensive sidecar file
   - Documents all processing parameters (including software versions and timestamps)

#### SPM12 Coregistration Parameters

**Estimation Options:**
- **Cost Function:** Normalized Mutual Information (NMI)
  - Robust to intensity differences between modalities
  - Suitable for aligning different contrasts (R2 vs PDw)
- **Separation:** [4 2 1 0.6] mm
  - Multi-resolution optimization from coarse to fine
- **Tolerances:** [0.02 0.02 0.02 0.001 0.001 0.001 0.01 0.01 0.01 0.001 0.001 0.001]
  - Translation and rotation convergence thresholds
- **Histogram Smoothing:** [7 7] mm FWHM
  - Reduces noise in mutual information calculation

**Reslicing Options:**
- **Interpolation:** 4th Degree B-Spline
  - High-quality interpolation for quantitative data
  - Minimizes interpolation artifacts
- **Wrapping:** No wrap [0 0 0]
  - Appropriate for brain imaging (no periodic boundaries)
- **Masking:** No mask
  - Uses entire image for alignment
- **Prefix:** `coreg_`
  - Custom prefix for output files

**Transformation Type:**
- Rigid body (6 DOF): 3 translations + 3 rotations
- No scaling or shearing
- Preserves quantitative values

#### Why Coregistration is Necessary

R2 maps from T2 processing may have different:
- Field of view (often smaller slab)
- Spatial resolution
- Image matrix size
- Subject positioning between sessions

Coregistration aligns the R2 map to match the PDw/R2* space, enabling accurate voxel-wise subtraction.

#### Output Files

| File | Description |
|------|-------------|
| `coreg_*_R2map.nii` | Coregistered R2 map in PDw space |
| `coreg_*_R2map.json` | Processing metadata with SPM parameters |

#### MATLAB Function: coreg_r2_slab.m

The MATLAB function creates and executes an SPM batch for coregistration:

```matlab
function coreg_r2_slab(moving, reference)
    % Inputs:
    %   moving    - Path to R2 map (will be moved to align)
    %   reference - Path to PDw sum (target alignment)
    %
    % Outputs:
    %   Coregistered image with 'coreg_' prefix
```

The function:
1. Adds SPM12 to MATLAB path
2. Initializes SPM job manager
3. Configures coregistration batch with parameters
4. Executes batch processing
5. Saves output with 'coreg_' prefix

---

### Stage 3: R2' Calculation

**Script:** `r2prime_calc.sh`

#### Operations Performed

1. **Input Validation**
   - Verifies R2 map exists (coregistered version)
   - Verifies R2* map exists
   - Validates container if using custom container
   - Checks output directory is empty (prevents overwriting)

2. **Spatial Alignment Validation**
   - Extracts sform matrices from both maps
   - Compares matrices for exact match
   - Aborts if sforms don't match (indicates misalignment)
   - Ensures voxel-wise correspondence for subtraction

3. **R2' Calculation**
   - Computes: R2' = R2* - R2
   - Uses FSL `fslmaths` for subtraction
   - Saves intermediate result

4. **Masking and Thresholding**
   - Creates positive value mask from R2 map
   - Handles NaN values (treats as zero)
   - Applies mask to R2' calculation
   - Thresholds result to positive values only ($R_2' \ge 0$)

5. **File Management**
   - Decompresses final output (.nii.gz → .nii)
   - Creates comprehensive JSON metadata
   - Documents all processing steps and validation

#### Mathematical Operations

The calculation proceeds as follows:

1. **Initial Subtraction:**
   ```
   R2' = R2* - R2
   ```

2. **Mask Creation:**
   ```
   mask = (R2 > threshold) AND (R2 is not NaN)
   threshold = 0.000000001 Hz (effectively > 0)
   ```

3. **Final R2' with Masking:**
   ```
   R2'_final = R2' × mask
   R2'_final = max(R2'_final, 0)  # Threshold to positive values
   ```

#### Why Masking is Important

**NaN Handling:**
- Coregistration can introduce NaN values at image edges
- NaN propagation would corrupt R2' calculation
- Mask ensures clean arithmetic operations

**Positive Value Constraint:**
- Negative R2' values are theoretically impossible
- May arise from noise or registration imperfections
- Thresholding removes non-physical values

**R2-based Masking:**
- Only calculates R2' where R2 is valid
- Excludes background and edge voxels
- Ensures reliable results in tissue regions

#### sform Validation

The script validates that R2 and R2* have identical sform matrices:

```bash
r2_sform=$(fslorient -getsform R2_map)
r2star_sform=$(fslorient -getsform R2star_map)

if [ "$r2_sform" != "$r2star_sform" ]; then
    echo "Error: sform matrices do not match"
    exit 1
fi
```

This ensures:
- Images are in the same coordinate system
- Voxel-to-voxel correspondence
- Accurate subtraction

#### Output Files

| File | Description |
|------|-------------|
| `*_R2primemap.nii` | Final R2' map (decompressed) |
| `*_R2primemap.json` | Processing metadata with validation info |

#### Intermediate Files (in work_dir)

| File | Description |
|------|-------------|
| `r2s_minus_r2.nii.gz` | Raw subtraction before masking |
| `r2pos_mask.nii.gz` | Binary mask of positive R2 values |

---

### Stage 4: Cleanup

The cleanup stage is identical to the T2 processing pipeline cleanup, with two levels:

#### Session Cleanup

**Script:** `slurm_cleanup_session.sh`

**Operations:**
- Removes session-specific working directory: `working_dir/{subject}/{session}/`
- Executed after R2' calculation completes for each session
- Runs in parallel for different sessions

#### Final Cleanup

**Script:** `slurm_cleanup_final.sh`

**Operations:**
- Waits for ALL session cleanup jobs to complete
- Removes entire working directory structure: `working_dir/` (with `rm -rf`)
- Only runs after all sessions are processed

**Disabling Cleanup:**

Use the `--preserve-workdir` or `-pw` flag to retain intermediate files:

```bash
./r2prime_creation_main.sh -pw -cont /path/to/container.sif ...
```

This preserves:
- PDw echo sum reference images
- Coregistered R2 maps
- Intermediate masking files
- Useful for quality control and debugging

---

## Output Structure

The pipeline creates a BIDS-compatible output structure:

```
output_directory/
├── sub-001/
│   ├── ses-01/
│   │   └── anat/
│   │       ├── sub-001_ses-01_R2primemap.nii
│   │       └── sub-001_ses-01_R2primemap.json
│   ├── ses-02/
│   │   └── anat/
│   │       └── ... (same structure)
│   └── ses-03/
│       └── anat/
│           └── ... (same structure)
├── sub-002/
│   └── ... (same structure)
└── Supplementary/  (unless --preserve-workdir used)
    └── sub-XXX/
        └── ses-YY/
            └── anat/
                ├── PDw_echoes_sum.nii
                ├── PDw_echoes_sum.json
                ├── r2s_minus_r2.nii.gz
                └── r2pos_mask.nii.gz

r2_directory/
└── sub-XXX/
    └── ses-YY/
        └── anat/
            ├── *_R2map.nii          (original R2 map)
            ├── coreg_*_R2map.nii    (coregistered R2 map, added by pipeline)
            └── coreg_*_R2map.json   (coregistration metadata, added by pipeline)
```

**Note:** The `Supplementary/` directory is automatically removed after processing unless `--preserve-workdir` is specified.

---

## File Description

### Main Scripts

| File | Type | Description |
|------|------|-------------|
| `r2prime_creation_main.sh` | Bash | Main orchestration script; submits all jobs with dependencies |
| `ref_sum_echoes.sh` | Bash/SLURM | Reference image creation from PDw echo summation |
| `coreg_r2_slab_slurm.sh` | Bash/SLURM | R2 slab coregistration to reference space |
| `coreg_r2_slab.m` | MATLAB | SPM12 batch creation and execution for coregistration |
| `r2prime_calc.sh` | Bash/SLURM | R2' calculation with validation and masking |

### Shared Scripts

These scripts are located in the parent directory and shared with T2 processing:

| File | Type | Description |
|------|------|-------------|
| `slurm_cleanup_session.sh` | Bash/SLURM | Session-specific cleanup script |
| `slurm_cleanup_final.sh` | Bash/SLURM | Final global cleanup script |

### Log Directory

| Directory | Description |
|-----------|-------------|
| `logs/r2prime_calc/` | SLURM output logs for all R2' pipeline jobs |

---

## Quality Control

### Visual Inspection

After processing, it's important to visually inspect the results:

1. **Check Coregistration Quality**
   - Overlay coregistered R2 map on PDw reference
   - Verify anatomical alignment
   - Check for registration failures or artifacts
   - Recommended tool: `FSLeyes`

2. **Inspect R2' Maps**
   - Check for reasonable value ranges
   - Look for artifacts or unrealistic patterns
   - Compare with R2 and R2* source maps
   - Verify masking is appropriate

   Expected R2' values in brain tissue:
   - Gray matter: ~2-8 Hz
   - White matter: ~5-15 Hz
   - Basal ganglia (high iron): ~10-30 Hz

3. **Validate Input Alignment**
   - Ensure R2* and coregistered R2 are well-aligned
   - Check that no large spatial offsets exist
   - Verify consistent anatomy across maps

### Automated Checks

The pipeline includes several automated quality checks:

1. **File Existence Checks**
   - Validates all input files exist before processing
   - Cancels dependent jobs if inputs are missing

2. **sform Validation**
   - Ensures R2 and R2* have identical spatial coordinates
   - Prevents calculation if misaligned
   - Critical for accurate voxel-wise subtraction

3. **Output Directory Check**
   - Verifies output directory is empty before R2' calculation
   - Prevents accidental overwriting
   - Can be overridden by manually clearing directory

### Coregistration Quality Assessment

- **Important:** Ensure correct gradient coefficients for GNLC
- Incorrect GNLC coefficients (e.g., using Terra/7T coefficients for Prisma/3T data) will cause poor alignment (use gradient files matching your MRI system)

---

## Monitoring and Troubleshooting

### Check Job Status

```bash
# View all your jobs
squeue -u $USER

# View specific job details
scontrol show job <job_id>

# Check job output logs
ls -lh /data/u_kuegler_software/git/r2_processing/logs/r2prime_calc/
tail /data/u_kuegler_software/git/r2_processing/logs/r2prime_calc/<job_id>*.out
```

### Common Errors and Solutions

**Error:** "No matching anat directory triplets found"
- **Solution:** Verify subject/session exists in all three input directories (PDw, R2, R2*)

**Error:** "Output directory is not empty"
- **Solution:** Clear output directory or use different path; or implement overwrite flag

### Debugging Tips

1. **Use dry-run mode first:**
   ```bash
   ./r2prime_creation_main.sh --dry-run [other options]
   ```
   This shows what commands would be executed without running jobs

2. **Preserve working directory:**
   ```bash
   ./r2prime_creation_main.sh -pw [other options]
   ```
   Allows inspection of intermediate files for debugging

3. **Process single session first:**
   ```bash
   ./r2prime_creation_main.sh -sub sub-001 -ses ses-01 [other options]
   ```
   Test on one session before batch processing

4. **Check log files:**
   All SLURM job output is logged to `logs/r2prime_calc/`
   Look for error messages and stack traces

---

## Integration with T2 Processing

The R2' calculation pipeline is designed to work seamlessly with the T2 processing pipeline:

### Workflow Integration

```
Raw MESE Data
    │
    ↓
[T2 Processing Pipeline]
    │
    ├─→ R2 maps (output: derivatives/relax_R2/)
    │
    └─→ (Combined with qMRI processing)
            │
            ├─→ R2* maps (output: derivatives/qMRI/)
            ├─→ PDw echoes (output: derivatives/MPM/)
            │
            ↓
    [R2' Calculation Pipeline]
            │
            ↓
        R2' maps (output: derivatives/r2prime/)
```

### Directory Organization

Typical derivative structure:

```
derivatives/
├── relax_R2/              # From T2 processing
│   └── sub-*/ses-*/anat/
│       └── *_R2map.nii
├── qMRI/                  # From qMRI processing
│   └── sub-*/ses-*/anat/
│       └── *_R2starmap.nii
├── LCPCA_distCorr/        # denoised and distortion-corrected images
│   └── sub-*/ses-*/anat/
│       └── *PDw*echo*.nii
└── r2prime/               # From this pipeline
    ├── b7T/
    │   └── sub-*/ses-*/anat/
    │       └── *_R2primemap.nii
    └── b3T/
        └── sub-*/ses-*/anat/
            └── *_R2primemap.nii
```

---

## References

- **R2' Theory:** Yablonskiy DA, Haacke EM. MRM 1994
- **SPM12:** Wellcome Centre for Human Neuroimaging (https://www.fil.ion.ucl.ac.uk/spm/)
- **FSL:** FMRIB Software Library (https://fsl.fmrib.ox.ac.uk/fsl/)
- **qMRI Methods:** Weiskopf N. et al., Front Neurosci 2014

---

**Author:** Niklas Kuegler (kuegler@cbs.mpg.de)

**Last Updated:** February 15, 2026
