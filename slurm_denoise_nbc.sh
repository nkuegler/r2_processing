#!/bin/bash

# ==============================================================================
# T2 Denoising and Noise Bias Correction SLURM Job Script
# ==============================================================================
#
# DESCRIPTION:
#   This script performs T2 denoising and noise bias correction processing on
#   MESE data for a single subject/session using PyMRItools within a
#   Singularity container. The script applies LC-PCA denoising followed by
#   noise bias correction to improve signal quality for subsequent T2 fitting.
#
# USAGE:
#   sbatch slurm_denoise_nbc.sh <CONTAINER_PATH> <SUBJECT> <SESSION> <MAGNETIC_FIELD> <PARENT_DIR> <OUTPUT_DIR> [NOISEMASK_DIR]
#
# ARGUMENTS:
#   CONTAINER_PATH  - Path to Singularity container with PyMRItools, FSL, and ANTS
#   SUBJECT         - Subject identifier (e.g., sub-004)
#   SESSION         - Session identifier (e.g., ses-04)
#   MAGNETIC_FIELD  - Magnetic field strength in Tesla (e.g., 7)
#   PARENT_DIR      - Path to parent BIDS directory containing raw data
#   OUTPUT_DIR      - Path to output directory for processed results
#   NOISEMASK_DIR   - (Optional) Path to manual noise mask files (required for 3T)
#
# OPERATIONS PERFORMED:
#   1. LC-PCA denoising of MESE acquisitions
#   2. Noise bias correction using manually-drawn or automatically created noise masks
#   3. Visualization of the results for quality control of denoised data
#
# EXAMPLE:
#   sbatch slurm_denoise_nbc.sh \
#     /path/to/pymritools.sif sub-001 ses-01 7 \
#     /bids/input /output/denoise /noise/masks
#
# NOTES:
#   - Manual noise masks required for 3T data processing
#   - Denoised outputs serve as input for subsequent GNLC processing
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 16					# 16 cores
#SBATCH --mem 32G				# estimated 32G RAM
#SBATCH --time 90				# estimated 90 minutes maximum
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/denoise/%j.out	# redirect the output


# Extract arguments
CONTAINER_PATH="$1"
SUBJECT="$2"
SESSION="$3"
MAGNETIC_FIELD="$4"
PARENT_DIR="$5"
OUTPUT_DIR="$6"
NOISEMASK_DIR="$7"  # Optional parameter


echo "--------"
echo "Container Path: ${CONTAINER_PATH}"
echo "Subject: ${SUBJECT}"
echo "Session: ${SESSION}"
echo "Magnetic Field: ${MAGNETIC_FIELD}T"
echo "Parent Directory: ${PARENT_DIR}"
echo "Output Directory: ${OUTPUT_DIR}"
if [[ -n "$NOISEMASK_DIR" ]]; then
    echo "Noise Mask Directory: ${NOISEMASK_DIR}"
fi
echo "--------"

# # Build python command as array
t2_script="/data/u_kuegler_software/git/r2_processing/t2_calc_denoise_nbc.py"
cmd_args=(
    "python3" "${t2_script}"
    "--subject" "${SUBJECT}"
    "--session" "${SESSION}"
    "--field-strength" "${MAGNETIC_FIELD}"
    "--parent-dir" "${PARENT_DIR}"
    "--output-dir" "${OUTPUT_DIR}"
)

# Add noise mask directory if provided
if [[ -n "$NOISEMASK_DIR" ]]; then
    cmd_args+=("--noise-mask-dir" "${NOISEMASK_DIR}")
fi


singularity exec "${CONTAINER_PATH}" "${cmd_args[@]}"

### for use in the CBS infrastructure (not in the container):
# source ~/bash.conda
# conda activate mri_tools_env

# # Build python command as array
# cmd_args=(
#     "python3" "${t2_script}"
#     "--subject" "${SUBJECT}"
#     "--session" "${SESSION}"
#     "--field-strength" "${MAGNETIC_FIELD}"
#     "--parent-dir" "${PARENT_DIR}"
#     "--output-dir" "${OUTPUT_DIR}"
# )
# 
# # Add noise mask directory if provided
# if [[ -n "$NOISEMASK_DIR" ]]; then
#     cmd_args+=("--noise-mask-dir" "${NOISEMASK_DIR}")
# fi
#
# # Run the command
# "${cmd_args[@]}" 



# Check if the processing was successful
if [ $? -eq 0 ]; then
    echo "Denoising and noise bias correction completed successfully"
else
    echo "Error: Denoising and noise bias correction failed"
    exit 1
fi