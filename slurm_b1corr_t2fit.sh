#!/bin/bash

# T2 B1+ Correction and T2 Fitting SLURM Job Script
# 
# This script runs B1+ correction and T2 fitting processing
# on a SLURM cluster for a single subject/session.
#
# Usage: sbatch slurm_b1corr_t2fit.sh [--gpu=1] <CONTAINER_PATH> <SUBJECT> <SESSION> <MAGNETIC_FIELD> <INPUT_DIR> <WORK_DIR> <OUTPUT_DIR> <TR_RATIO> <FLIP_ANGLE> <DENOISE_DIR>
#
# Arguments:
#   CONTAINER_PATH  - Path to Singularity container
#   SUBJECT         - Subject identifier (e.g., sub-004)
#   SESSION         - Session identifier (e.g., ses-04)
#   MAGNETIC_FIELD  - Magnetic field strength in Tesla (e.g., 7)
#   INPUT_DIR       - Path to input directory containing processed data
#   WORK_DIR        - Path to working directory for temporary files
#   OUTPUT_DIR      - Path to output directory for processed results
#   TR_RATIO        - TR ratio (TR2/TR1) for AFI B1 calculation (e.g., 5.0)
#   FLIP_ANGLE      - Flip angle of the AFI images in degrees (e.g., 55.0)
#   DENOISE_DIR     - Directory path containing denoised data
#
# The script processes MESE and AFI data using PyMRItools with the following features:
#   - B1+ mapping from AFI data
#   - B1+ mapping EMC
#   - B1+ correction and regularization
#   - Dictionary-based T2 fitting
#   - R2 map calculation
#
# Output is placed in the specified output directory with intermediate results
# optionally saved in the working directory.

#SBATCH -c 16					# 16 cores
#SBATCH --mem 32G				# estimated 32G RAM
#SBATCH --time 90				# estimated 90 minutes maximum
#SBATCH -o /data/u_kuegler_software/git/r2_map_calculation/logs/t2fit/%j.out	# redirect the output
#

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
t2_script="/data/u_kuegler_software/git/r2_map_calculation/t2_calc_b1corr_t2fit.py"
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
if [ $? -eq 0 ]; then
    echo "B1+ correction and T2 fitting completed successfully"
else
    echo "Error: B1+ correction and T2 fitting failed"
    exit 1
fi

# Terminate nvidia-smi
# kill $NVIDIASMI_PID