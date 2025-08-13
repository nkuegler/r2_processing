#!/bin/bash

# ==============================================================================
# Echo Summation SLURM Job Script
# ==============================================================================
#
# DESCRIPTION:
#   This script sums all PDw echo files matching a specified pattern using FSL tools
#   to create a reference image for coregistration purposes. The script is designed 
#   to run as a SLURM batch job and supports both custom Singularity containers and 
#   the CBS infrastructure's prebuilt `sc` modules (must be specified manually in the script).
#
# USAGE:
#   sbatch ref_sum_echoes.sh <CONTAINER_PATH> <IMAGE_DIR> <OUTPUT_DIR> [FNAME_PATTERN] [OUTPUT_NAME]
#
# ARGUMENTS:
#   CONTAINER_PATH  - Path to Singularity container with FSL tools
#   IMAGE_DIR       - Directory containing input echo files
#   OUTPUT_DIR      - Directory where reference image will be saved
#   FNAME_PATTERN   - (Optional) File pattern to match echo files (default: "*acq-PDw*echo-*part-mag*.nii")
#   OUTPUT_NAME     - (Optional) Name of output file (default: "PDw_echoes_sum.nii.gz")
#
# OPERATIONS PERFORMED:
#   1. Search for echo files matching the specified pattern
#   2. Validate that files were found
#   3. Create output directory if needed
#   4. Sum all echo files using FSL fslmaths
#   5. Decompress output file for compatibility with SPM 
#
# EXAMPLE:
#   sbatch ref_sum_echoes.sh \
#     /path/to/fsl_container.sif \
#     /data/input/anat \
#     /data/output/anat \
#     "*acq-PDw*echo-*part-mag*.nii" \
#     "reference_sum.nii.gz"
#
# NOTES:
#   - Supports both custom containers (custom_container=true) and CBS sc modules
#   - Files are sorted alphabetically before summation for reproducibility
#   - Output file is automatically decompressed (.nii.gz -> .nii) for SPM compatibility
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 4
#SBATCH --mem 4G
#SBATCH --time 10
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/coreg_r2/%j.out

# Extract arguments
CONTAINER_PATH="$1"
IMAGE_DIR="$2"
OUTPUT_DIR="$3"
FNAME_PATTERN="${4:-*acq-PDw*echo-*part-mag*.nii}"  # Default pattern if not provided
OUTPUT_NAME="${5:-PDw_echoes_sum.nii.gz}"           # Default output name if not provided

# Check if required arguments are provided
if [ $# -lt 3 ]; then
    echo "Error: At least 3 arguments required."
    echo "Usage: $0 <CONTAINER_PATH> <IMAGE_DIR> <OUTPUT_DIR> [FNAME_PATTERN] [OUTPUT_NAME]"
    exit 1
fi

echo "--------"
echo "Container Path: ${CONTAINER_PATH}"
echo "Image Directory: ${IMAGE_DIR}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "Filename Pattern: ${FNAME_PATTERN}"
echo "Output Name: ${OUTPUT_NAME}"
echo "--------"

FSL_VERSION=6.0.6
custom_container=true

# Validate container exists if using custom container
if [[ ${custom_container} == true ]] && [ ! -f "${CONTAINER_PATH}" ]; then
    echo "Error: Container file does not exist: ${CONTAINER_PATH}"
    exit 1
fi

# Get list of matching files
echo_files=($(find "${IMAGE_DIR}" -maxdepth 1 -name "${FNAME_PATTERN}" -type f | sort))

# Check if any files were found
if [ ${#echo_files[@]} -eq 0 ]; then
    echo "Error: No files found matching pattern ${FNAME_PATTERN}"
    exit 1
fi

echo "Found ${#echo_files[@]} echo files:"
for file in "${echo_files[@]}"; do
    echo "  $(basename "$file")"
done

# Create output directory if it doesn't exist
if [ ! -d "${OUTPUT_DIR}" ]; then
    mkdir -p "${OUTPUT_DIR}"
fi

# Create output filename for summed echoes
output_file="${OUTPUT_DIR}/${OUTPUT_NAME}"

# Construct a single FSL command to sum all echoes
echo "Summing all echoes to create reference image..."
echo "Output file: ${output_file}"

# Start building the command with the first echo file
if [[ custom_container == true ]]; then
    # Native fsl installation in custom container
    fsl_command="singularity exec \"${CONTAINER_PATH}\" fslmaths \"${echo_files[0]}\""
else
    ## Use prebuilt sc containers in CBS infrastructure
    fsl_command="sc fsl \"$FSL_VERSION\" fslmaths \"${echo_files[0]}\""
fi

# Add all remaining echo files to the command
for ((i=1; i<${#echo_files[@]}; i++)); do
    fsl_command="${fsl_command} -add \"${echo_files[$i]}\""
done

# Add the output file at the end
fsl_command="${fsl_command} \"${output_file}\""

# Print the command for debugging
echo "Executing FSL command:"
echo "   ${fsl_command}"

# Execute the command
eval "${fsl_command}"

echo "---------------------------"
# Check if the command was successful
if [ $? -eq 0 ]; then
    # Unzipping output file if it's compressed
    if [[ "${output_file}" == *.gz ]]; then
        echo "Decompressing output file..."
        gunzip "${output_file}"
        decompressed_file="${output_file%.gz}"
        echo "Reference image created successfully: ${decompressed_file}"
    else
        echo "Reference image created successfully: ${output_file}"
    fi
else
    echo "Error: FSL echo sum command failed"
    exit 1
fi
