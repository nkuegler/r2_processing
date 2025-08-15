#!/bin/bash

#
#SBATCH -c 8
#SBATCH --mem 8G
#SBATCH --time 30
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/coreg_r2/%j.out

moving_img=$1
reference_img=$2
output_dir="$3"

echo "moving image: $moving_img"
echo "reference image: $reference_img"
echo "output directory: $output_dir"
echo "--------------------------"


# Check if coregistration input files exist
if [[ ! -f "$moving_img" ]]; then
    echo "Error: Moving image not found: $moving_img"
    exit 1
fi
if [[ ! -f "$reference_img" ]]; then
    echo "Error: Reference image not found: $reference_img"
    exit 1
fi

# Ensure output_dir has trailing slash
if [[ ! "$output_dir" =~ /$ ]]; then
    output_dir="${output_dir}/"
fi

####### !!! If parameters of the co-registration are changed, update the JSON file creation section below accordingly !!! #######

### Run MATLAB/SPM coregistration
echo "Starting coregistration..."
MATLAB -v 24.2 matlab -batch "coreg_r2_slab('$moving_img','$reference_img');exit" -sd /data/u_kuegler_software/git/r2_processing/r2prime_calculation
matlab_exit_code=$?

# Check if MATLAB execution was successful
if [ $matlab_exit_code -ne 0 ]; then
    echo "Error: MATLAB coregistration failed with exit code $matlab_exit_code"
    exit 1
fi

echo "--------------------------"

echo "Processing coregistered image..."
# Construct the path to the coregistered result
moving_dir=$(dirname "$moving_img")
moving_basename=$(basename "$moving_img")
coregistered_result="${moving_dir}/coreg_${moving_basename}"
output_file="$output_dir/coreg_${moving_basename}"

echo "Looking for coregistered result: $coregistered_result"

# Check if the coregistered result exists
if [ ! -f "$coregistered_result" ]; then
    echo "Error: Coregistered result not found at $coregistered_result"
    exit 1
fi

# Create output directory if it doesn't exist
if [ ! -d "$output_dir" ]; then
    echo "Creating output directory: $output_dir"
    mkdir -p "$output_dir"
fi

# Check if the file is already in the output directory
if [ "$coregistered_result" = "$output_file" ]; then
    echo "Coregistered result is already in output directory."
    echo "Coregistration completed successfully. Result available at:"
    echo "   $output_file"
elif [ -f "$output_file" ]; then
    echo "File already exists in output directory: $output_file"
    echo "Removing old version and moving new result..."
    rm -f "$output_file"
    rm -f "${output_file%.nii}.json"
    mv "$coregistered_result" "$output_dir"
    if [ $? -eq 0 ]; then
        echo "Coregistration completed successfully. Result saved to:" 
        echo "   $output_file"
    else
        echo "Error: Failed to move coregistered result"
        exit 1
    fi
else
    # Move the coregistered result to the specified output location
    echo "Moving coregistered result to $output_dir"
    mv "$coregistered_result" "$output_dir"
    # Check if the move was successful
    if [ $? -eq 0 ]; then
        echo "Coregistration completed successfully. Result saved to:" 
        echo "   $output_file"
    else
        echo "Error: Failed to move coregistered result"
        exit 1
    fi
fi

# Create JSON sidecar file (common for all cases)
echo "Creating JSON sidecar file..."
JSON_FILE="${output_file%.nii}.json"
TIMESTAMP=$(date -Iseconds)

cat > "${JSON_FILE}" << EOF
{
  "Description": "Coregistered R2 map aligned to reference R2* space using SPM",
  "Sources": {
    "moving_image": "${moving_img}",
    "reference_image": "${reference_img}"
  },
  "ProcessingSteps": [
    "SPM coregistration of moving image to reference space"
  ],
  "ProcessingParameters": {
    "CoregistrationMethod": "SPM Coregister (estimate and reslice)",
    "TransformationType": "Rigid body (6 DOF) with image reslicing",
    "EstimationOptions": {
      "ObjectiveFunction": "Normalized Mutual Information",
      "Separation": "[4 2 1 0.6]",
      "Tolerances": "[0.02 0.02 0.02 0.001 0.001 0.001 0.01 0.01 0.01 0.001 0.001 0.001]",
      "HistogramSmoothing": "[7 7]
    },
    "ResliceOptions": {
      "Interpolation": "4th Degree B-Spline",
      "Wrapping": "No wrap",
      "Masking": "No mask", 
      "FileNamePrefix": "coreg_"
    },
  },
  "SoftwareInformation": {
    "MATLAB": "R2024b",
    "SPM": "SPM12",
    "ProcessingScript": "coreg_r2_slab_slurm.sh",
    "MATLABFunction": "coreg_r2_slab.m"
  },
  "ProcessingTimestamp": "${TIMESTAMP}",
  "Units": "Hz",
  "CoregistrationDetails": {
    "ReferenceSpace": "R2* map coordinate system",
    "QualityCheck": "Visual inspection recommended",
  }
}
EOF

echo "JSON sidecar created: ${JSON_FILE}"

