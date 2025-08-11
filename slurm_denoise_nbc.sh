#!/bin/bash

# T2 Denoising and Noise Bias Correction SLURM Job Script
# 
# This script runs T2 denoising and noise bias correction processing
# on a SLURM cluster for a single subject/session.
#
# Usage: sbatch slurm_denoise_nbc.sh <CONTAINER_PATH> <SUBJECT> <SESSION> <MAGNETIC_FIELD> <PARENT_DIR> <OUTPUT_DIR>
#
# Arguments:
#   CONTAINER_PATH  - Path to Singularity container file (e.g., /path/to/pymritools.sif)
#   SUBJECT         - Subject identifier (e.g., sub-004)
#   SESSION         - Session identifier (e.g., ses-04)
#   MAGNETIC_FIELD  - Magnetic field strength in Tesla (e.g., 7)
#   PARENT_DIR      - Path to parent BIDS directory containing raw data
#   OUTPUT_DIR      - Path to output directory for processed results
#
# The script processes MESE and AFI data using PyMRItools with the following features:
#   - MP-PCA denoising
#   - Noise bias correction
#   - AFI resampling to MESE space
#
# Output is placed in the specified output directory.

#SBATCH -c 16					# 16 cores
#SBATCH --mem 32G				# estimated 32G RAM
#SBATCH --time 90				# estimated 90 minutes maximum
#SBATCH -o /data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j.out	# redirect the output
#

# Extract arguments
CONTAINER_PATH="$1"
SUBJECT="$2"
SESSION="$3"
MAGNETIC_FIELD="$4"
PARENT_DIR="$5"
OUTPUT_DIR="$6"


echo "--------"
echo "Container Path: ${CONTAINER_PATH}"
echo "Subject: ${SUBJECT}"
echo "Session: ${SESSION}"
echo "Magnetic Field: ${MAGNETIC_FIELD}T"
echo "Parent Directory: ${PARENT_DIR}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "--------"

# # Build python command as array
t2_script="/data/u_kuegler_software/git/r2_map_calculation/t2_calc_denoise_nbc.py"
cmd_args=(
    "python3" "${t2_script}"
    "--subject" "${SUBJECT}"
    "--session" "${SESSION}"
    "--field-strength" "${MAGNETIC_FIELD}"
    "--parent-dir" "${PARENT_DIR}"
    "--output-dir" "${OUTPUT_DIR}"
)


singularity exec "${CONTAINER_PATH}" "${cmd_args[@]}"

### for use in the CBS infrastructure (not in the container):
# source ~/bash.conda
# conda activate mri_tools_env

# python3 ${t2_script} \
#     --subject "${SUBJECT}" \
#     --session "${SESSION}" \
#     --field-strength "${MAGNETIC_FIELD}" \
#     --parent-dir "${PARENT_DIR}" \
#     --output-dir "${OUTPUT_DIR}" 



# Check if the processing was successful
if [ $? -eq 0 ]; then
    echo "Denoising and noise bias correction completed successfully"
else
    echo "Error: Denoising and noise bias correction failed"
    exit 1
fi