#!/bin/bash

# ==============================================================================
# B1+ Correction and T2 Fitting SLURM Job Script
# ==============================================================================
#
# DESCRIPTION:
#   This script performs B1+ correction and T2 fitting processing on MESE and AFI
#   data for a single subject/session using PyMRItools within a Singularity container.
#   The script processes the input MESE data to produce T2 maps with B1+ field inhomogeneity correction.
#
# USAGE:
#   sbatch slurm_b1corr_t2fit.sh [--gpu=1] <CONTAINER_PATH> <SUBJECT> <SESSION> <MAGNETIC_FIELD> <INPUT_DIR> <WORK_DIR> <OUTPUT_DIR> <TR_RATIO> <FLIP_ANGLE> <DENOISE_DIR>
#
# ARGUMENTS:
#   CONTAINER_PATH  - Path to Singularity container with PyMRItools, FSL, and ANTS
#   SUBJECT         - Subject identifier (e.g., sub-004)
#   SESSION         - Session identifier (e.g., ses-04)
#   MAGNETIC_FIELD  - Magnetic field strength in Tesla (e.g., 7)
#   INPUT_DIR       - Path to input directory containing pre-processed data
#   WORK_DIR        - Path to working directory for temporary files
#   OUTPUT_DIR      - Path to output directory for final results
#   TR_RATIO        - TR ratio (TR2/TR1) for AFI B1+ calculation (e.g., 5.0)
#   FLIP_ANGLE      - Flip angle of AFI images in degrees (e.g., 55.0)
#   DENOISE_DIR     - Path to directory containing denoised data
#
# OPERATIONS PERFORMED:
#   1. B1+ field mapping from AFI data
#   2. B1+ mapping using the echo-modulation curve (EMC) approach
#   3. B1+ field regularization
#   4. Dictionary-based T2 fitting with B1+ correction
#   5. R2 map calculation from corrected T2 values
#
# EXAMPLE:
#   sbatch slurm_b1corr_t2fit.sh \
#     /path/to/pymritools_7d29483.sif sub-001 ses-01 7 \
#     /input/gnlc /work/t2fit /output 5.0 55.0 /input/denoise
#
# NOTES:
#   - (optional) Enabling GPU support for processing speeds up processing drastically (--gpus=1 in SLURM)
#   - Intermediate results saved in working directory
#   - Final outputs placed in BIDS-compatible structure
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 16					# 16 cores
#SBATCH --mem 32G				# estimated 32G RAM
#SBATCH --time 90				# estimated 90 minutes maximum
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/t2fit/%j.out	# redirect the output


# Extract arguments
CONTAINER_PATH="$1"
SUBJECT="$2"
SESSION="$3"
MAGNETIC_FIELD="$4"
INPUT_DIR="$5" 
WORK_DIR="$6"
OUTPUT_DIR="$7"
TR_RATIO="$8"
FLIP_ANGLE="$9"
DENOISE_DIR="${10}"


echo "--------"
echo "Container Path: ${CONTAINER_PATH}"
echo "Subject: ${SUBJECT}"
echo "Session: ${SESSION}"
echo "Magnetic Field: ${MAGNETIC_FIELD}T"
echo "Input Directory: ${INPUT_DIR}"
echo "Working Directory: ${WORK_DIR}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "TR Ratio: ${TR_RATIO}"
echo "Flip Angle: ${FLIP_ANGLE}°"
echo "Denoise Directory: ${DENOISE_DIR}"
echo "--------"

# this job requests using a GPU 
# here we monitor the GPU usage
nvidia-smi # --query-gpu=timestamp,utilization.gpu,utilization.memory,temperature.gpu,memory.free,memory.used --format=csv -l 1 > "$WORK_DIR/nvidia_gpu_usage.csv" &
# NVIDIASMI_PID=$!


# Build python command as array
t2_script="/data/u_kuegler_software/git/r2_processing/t2_calc_b1corr_t2fit.py"
cmd_args=(
    "python3" "${t2_script}"
    "--subject" "${SUBJECT}"
    "--session" "${SESSION}"
    "--field-strength" "${MAGNETIC_FIELD}"
    "--input-dir" "${INPUT_DIR}"
    "--work-dir" "${WORK_DIR}"
    "--output-dir" "${OUTPUT_DIR}"
    "--tr-ratio" "${TR_RATIO}"
    "--flip-angle" "${FLIP_ANGLE}"
    "--denoise-dir" "${DENOISE_DIR}"
)

singularity exec "${CONTAINER_PATH}" "${cmd_args[@]}"
EXIT_CODE=$?


### for use in the CBS infrastructure (not in the container):
# source ~/bash.conda
# conda activate mri_tools_env

# python3 ${t2_script} \
#     --subject "${SUBJECT}" \
#     --session "${SESSION}" \
#     --field-strength "${MAGNETIC_FIELD}" \
#     --input-dir "${INPUT_DIR}" \
#     --work-dir "${WORK_DIR}" \
#     --output-dir "${OUTPUT_DIR}" \
#     --tr-ratio "${TR_RATIO}" \
#     --flip-angle "${FLIP_ANGLE}" \
#     --denoise-dir "${DENOISE_DIR}"

echo "------------------------------------------"
# Check if the processing was successful
if [ ${EXIT_CODE} -eq 0 ]; then
    echo "B1+ correction and T2 fitting completed successfully"
else
    echo "Error: B1+ correction and T2 fitting failed (exit code: ${EXIT_CODE})"
    exit ${EXIT_CODE}
fi

# Terminate nvidia-smi
# kill $NVIDIASMI_PID