#!/bin/bash

# ==============================================================================
# R2 Prime (R2') Calculation SLURM Job Script
# ==============================================================================
#
# DESCRIPTION:
#   This script calculates R2' maps by subtracting R2 from R2* (R2' = R2* - R2).
#   The script assumes that both R2 and R2* maps are already in the same space
#   with identical sform matrices. It supports both custom Singularity containers 
#   and CBS infrastructure's prebuilt modules.
#
# USAGE:
#   sbatch r2prime_calc.sh <CONTAINER_PATH> <R2_MAP> <R2STAR_MAP> <WORK_DIR> <OUTPUT_DIR> [OUTPUT_NAME]
#
# ARGUMENTS:
#   CONTAINER_PATH  - Path to Singularity container with FSL tools
#   R2_MAP          - Path to R2 map (must be in same space as R2* map)
#   R2STAR_MAP      - Path to R2* map (must be in same space as R2 map)
#   WORK_DIR        - Directory where temporary files will be saved
#   OUTPUT_DIR      - Directory where final results will be saved
#   OUTPUT_NAME     - (Optional) Name of output R2' file (default: "r2prime.nii.gz")
#
# OPERATIONS PERFORMED:
#   1. Validate input files and directories
#   2. Check that sform matrices of R2 and R2* maps are identical
#   3. Calculate R2' = R2* - R2 using FSL tools
#   4. Create mask from R2 map to exclude NaN and non-positive values
#   5. Apply mask and threshold R2' to positive values only
#
# EXAMPLE:
#   sbatch r2prime_calc.sh \
#     /path/to/neuroimaging_container.sif \
#     /data/input/r2_map.nii.gz \
#     /data/input/r2star_map.nii.gz \
#     /data/temp/work \
#     /data/output/r2prime \
#     "custom_r2prime.nii.gz"
#
# NOTES:
#   - Supports both custom containers (custom_container=true) and CBS sc modules
#   - R2 and R2* maps must have identical sform matrices (same space)
#   - WORK_DIR and OUTPUT_DIR will be created if they don't exist
#   - OUTPUT_DIR must be empty or non-existent
#   - Handles NaN values in coregistered R2 maps properly
#   - Final output is automatically decompressed (.nii.gz -> .nii)
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 8
#SBATCH --mem 16G
#SBATCH --time 30
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/coreg_r2/%j.out

# Extract arguments
CONTAINER_PATH="$1"
R2_MAP="$2"
R2STAR_MAP="$3"
WORK_DIR="$4"
OUTPUT_DIR="$5"
OUTPUT_NAME="${6:-r2prime.nii.gz}"  # Default output name if not provided

# Check if required arguments are provided
if [ $# -lt 5 ]; then
    echo "Error: At least 5 arguments required."
    echo "Usage: $0 <CONTAINER_PATH> <R2_MAP> <R2STAR_MAP> <WORK_DIR> <OUTPUT_DIR> [OUTPUT_NAME]"
    exit 1
fi

echo "--------"
echo "Container Path: ${CONTAINER_PATH}"
echo "R2 Map: ${R2_MAP}"
echo "R2* Map: ${R2STAR_MAP}"
echo "Work Directory: ${WORK_DIR}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "Output Name: ${OUTPUT_NAME}"
echo "--------"

# Good scientists abort computations upon unexpected problems
set -e

# Configuration
FSL_VERSION=6.0.6
custom_container=true

# Validate input files exist
if [ ! -f "${R2_MAP}" ]; then
    echo "Error: R2 map file does not exist: ${R2_MAP}"
    exit 1
fi

if [ ! -f "${R2STAR_MAP}" ]; then
    echo "Error: R2* map file does not exist: ${R2STAR_MAP}"
    exit 1
fi

# Validate container exists if using custom container
if [[ ${custom_container} == true ]] && [ ! -f "${CONTAINER_PATH}" ]; then
    echo "Error: Container file does not exist: ${CONTAINER_PATH}"
    exit 1
fi

# Check if the output directory exists and contains files
if [ -d "${OUTPUT_DIR}" ] && [ "$(ls -A "${OUTPUT_DIR}")" ]; then
    echo "Error: Output directory '${OUTPUT_DIR}' is not empty. Aborting execution."
    exit 1
fi

# Create work directory if it does not exist
if [ ! -d "${WORK_DIR}" ]; then
    echo "Creating work directory: ${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
fi

# Create output directory if it does not exist
if [ ! -d "${OUTPUT_DIR}" ]; then
    echo "Creating output directory: ${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
fi

# Configure commands based on container type
if [[ ${custom_container} == true ]]; then
    # Native installations in custom container
    fsl_cmd="singularity exec ${CONTAINER_PATH}"
else
    # Use prebuilt sc containers in CBS infrastructure
    fsl_cmd="sc fsl ${FSL_VERSION}"
fi

# Check that sforms are identical (required for direct subtraction)
echo "Checking sform matrices of input images..."
r2_sform=$(${fsl_cmd} fslorient -getsform "${R2_MAP}")
r2star_sform=$(${fsl_cmd} fslorient -getsform "${R2STAR_MAP}")

if [ "$r2_sform" != "$r2star_sform" ]; then
    echo "Error: sform matrices of R2 and R2* maps do not match."
    echo "R2 sform: $r2_sform"
    echo "R2* sform: $r2star_sform"
    echo "Please run the coregistration of the R2 slab first."
    exit 1
else
    echo "✓ R2 and R2* maps have identical sform matrices - proceeding with calculation."
fi


# ### Calculate R2' = R2* - R2

# define file names of temporary files
R2s_minus_R2="r2s_minus_r2.nii.gz"
R2pos_mask="r2pos_mask.nii.gz"


echo ">>> Calculating R2' = R2* - R2..."
${fsl_cmd} fslmaths "${R2STAR_MAP}" -sub "${R2_MAP}" "${WORK_DIR}/${R2s_minus_R2}"

echo ">>> Creating mask of positive values in the R2 slab..."
# make sure to treat NaN values as zero
${fsl_cmd} fslmaths "${R2_MAP}" -nan -thr 0.000000001 -bin "${WORK_DIR}/${R2pos_mask}"

echo ">>> Applying mask to R2' calculation and restricting the result to positive values..."
${fsl_cmd} fslmaths "${WORK_DIR}/${R2s_minus_R2}" -nan -mul "${WORK_DIR}/${R2pos_mask}" -thr 0.000000001 "${OUTPUT_DIR}/${OUTPUT_NAME}"

# Verify final output was created
if [ ! -f "${OUTPUT_DIR}/${OUTPUT_NAME}" ]; then
    echo "Error: Final R2' map was not created successfully"
    exit 1
fi

echo ">>> Decompressing output file..."
gunzip "${OUTPUT_DIR}/${OUTPUT_NAME}"


echo "---------------------------"
echo "R2' calculation completed successfully!"
echo "Output file: ${OUTPUT_DIR}/${OUTPUT_NAME%.gz}"
echo "Done"