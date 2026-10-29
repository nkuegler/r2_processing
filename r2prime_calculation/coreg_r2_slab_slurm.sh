#!/bin/bash

# ==============================================================================
# R2 Map Coregistration SLURM Job Script
# ==============================================================================
#
# DESCRIPTION:
#   This script performs rigid body coregistration of R2 maps to PDw reference space
#   using SPM12 in MATLAB. The coregistration aligns the R2 map to match the spatial
#   orientation and position of the PDw reference image using normalized mutual
#   information as the cost function and 4th degree B-spline interpolation for
#   high-quality reslicing.
#
# USAGE:
#   sbatch coreg_r2_slab_slurm.sh <MOVING_IMAGE> <REFERENCE_IMAGE> <OUTPUT_DIR> [OTHER_IMAGE...]
#
# ARGUMENTS:
#   MOVING_IMAGE    - Path to R2 map to be coregistered (moving image)
#   REFERENCE_IMAGE - Path to PDw image serving as reference target
#   OUTPUT_DIR      - Directory where coregistered result will be saved
#   OTHER_IMAGE     - (Optional) Image(s) to reslice with the same transform
#
# OPERATIONS PERFORMED:
#   1. Copy "other" images to output directory (SPM modifies headers in-place)
#   2. Execute coregistration using the SPM batch created in coreg_r2_slab.m
#   3. Move result to output directory
#   4. Create comprehensive JSON sidecar metadata file
#   5. Remove the header-modified copies of the other images
#
# EXAMPLE:
#   sbatch coreg_r2_slab_slurm.sh \
#     /data/input/r2_map.nii \
#     /data/input/pdw_reference.nii \
#     /data/output/coregistered
#
# NOTES:
#   - Uses SPM12 coregistration with rigid body transformation (6 DOF)
#   - Output file will have 'coreg_' prefix added to original filename
#   - SPM's estimate step writes the estimated transform into the header of the
#     moving and all other images in-place. Therefore, the other images are copied
#     to OUTPUT_DIR and the copies are coregistered; the originals stay untouched.
#     (The moving image is backed up as *_orig.nii, but modified in-place.)
#   - Overwrites existing files if output already exists in target directory
#   - Creates comprehensive JSON sidecar with processing metadata
#   - Visual inspection of coregistration quality is recommended
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 8
#SBATCH --mem 8G
#SBATCH --time 30
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/coreg_r2/%j.out

moving_img=$1
reference_img=$2
output_dir="$3"
other_imgs=("${@:4}")

echo "moving image: $moving_img"
echo "reference image: $reference_img"
echo "output directory: $output_dir"
if (( ${#other_imgs[@]} > 0 )); then
    echo "other images:"
    for img in "${other_imgs[@]}"; do
        echo "  $img"
    done
fi
echo "--------------------------"

# save original moving image before coregistration
cp "$moving_img" "${moving_img%.nii}_orig.nii" 

# Check if coregistration input files exist
if [[ ! -f "$moving_img" ]]; then
    echo "Error: Moving image not found: $moving_img"
    exit 1
fi
if [[ ! -f "$reference_img" ]]; then
    echo "Error: Reference image not found: $reference_img"
    exit 1
fi
if (( ${#other_imgs[@]} > 0 )); then
  for img in "${other_imgs[@]}"; do
    if [[ ! -f "$img" ]]; then
      echo "Error: Other image not found: $img"
      exit 1
    fi
  done
fi

# Ensure output_dir has trailing slash
if [[ ! "$output_dir" =~ /$ ]]; then
    output_dir="${output_dir}/"
fi

# Create output directory if it doesn't exist
if [ ! -d "$output_dir" ]; then
    echo "Creating output directory: $output_dir"
    mkdir -p "$output_dir"
fi

# Copy other images to the output directory and coregister the copies instead,
# since SPM's estimate step modifies the header (affine) of all images in-place
other_imgs_orig=("${other_imgs[@]}")
other_imgs_copies=()
if (( ${#other_imgs[@]} > 0 )); then
  for i in "${!other_imgs[@]}"; do
    img="${other_imgs[$i]}"
    img_copy="${output_dir}$(basename "$img")"
    if [ "$img" -ef "$img_copy" ]; then
      echo "Warning: Other image is already in output directory, its header will be modified in-place: $img"
      continue
    fi
    echo "Copying other image to output directory: $img_copy"
    cp "$img" "$img_copy" || { echo "Error: Failed to copy $img to $img_copy"; exit 1; }
    other_imgs[$i]="$img_copy"
    other_imgs_copies+=("$img_copy")
  done
fi

# Define r2prime_calculation directory path
r2prime_calc_dir="/data/u_kuegler_software/git/r2_processing/r2prime_calculation"

####### !!! If parameters of the co-registration are changed, update the JSON file creation section below accordingly !!! #######

### Run MATLAB/SPM coregistration
echo "Starting coregistration..."
if (( ${#other_imgs[@]} > 0 )); then
  if (( ${#other_imgs[@]} == 1 )); then
    # if only R2 as other image
    other_img1="${other_imgs[0]}"
    MATLAB -v 24.2 matlab -batch "coreg_r2_slab('$moving_img','$reference_img','$other_img1'); exit" -sd "$r2prime_calc_dir"
  elif (( ${#other_imgs[@]} == 2 )); then
    # if both R2 and T2 as other images
    MATLAB -v 24.2 matlab -batch "other1='${other_imgs[0]}'; other2='${other_imgs[1]}'; other_imgs_tmp={ [other1 ',1'] ; [other2 ',1'] }; coreg_r2_slab('$moving_img','$reference_img',other_imgs_tmp); exit" -sd "$r2prime_calc_dir"
  else
    echo "Error: Expected 1 or 2 other images, got ${#other_imgs[@]}"
    exit 1
  fi
else
    MATLAB -v 24.2 matlab -batch "coreg_r2_slab('$moving_img','$reference_img');exit" -sd "$r2prime_calc_dir"
fi
matlab_exit_code=$?

# Check if MATLAB execution was successful
if [ $matlab_exit_code -ne 0 ]; then
    echo "Error: MATLAB coregistration failed with exit code $matlab_exit_code"
    exit 1
fi

echo "--------------------------"

echo "Processing coregistered image..."
result_inputs=("$moving_img" "${other_imgs[@]}")

TIMESTAMP=$(date -Iseconds)
other_json="[]"
if (( ${#other_imgs_orig[@]} > 0 )); then
  other_json="["
  for img in "${other_imgs_orig[@]}"; do
    if [[ "$other_json" != "[" ]]; then
      other_json+=", "
    fi
    other_json+="\"$img\""
  done
  other_json+="]"
fi

for result_input in "${result_inputs[@]}"; do
  result_dir=$(dirname "$result_input")
  result_basename=$(basename "$result_input")
  coregistered_result="${result_dir}/coreg_${result_basename}"
  output_file="$output_dir/coreg_${result_basename}"

  echo "Looking for coregistered result: $coregistered_result"

  if [ ! -f "$coregistered_result" ]; then
    echo "Error: Coregistered result not found at $coregistered_result"
    exit 1
  fi

  # Check if the file is already in the output directory (use realpath to normalize paths)
  if [ "$(realpath -m "$coregistered_result")" = "$(realpath -m "$output_file")" ]; then
    echo "Coregistered result is already in output directory."
    echo "Coregistration completed successfully. Result available at:"
    echo "   $output_file"
  else
    if [ -f "$output_file" ]; then
      echo "File already exists in output directory: $output_file"
      echo "Removing old version and moving new result..."
      rm -f "$output_file"
      rm -f "${output_file%.nii}.json"
    else
      echo "Moving coregistered result to $output_dir"
    fi

    mv "$coregistered_result" "$output_dir"
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

  cat > "${JSON_FILE}" << EOF
{
  "Description": "Coregistered image aligned to reference PDw space using SPM",
  "Sources": {
    "moving_image": "${moving_img}",
    "reference_image": "${reference_img}",
    "other_images": ${other_json}
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
      "HistogramSmoothing": "[7 7]"
    },
    "ResliceOptions": {
      "Interpolation": "4th Degree B-Spline",
      "Wrapping": "No wrap",
      "Masking": "No mask", 
      "FileNamePrefix": "coreg_"
    }
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
    "ReferenceSpace": "PDw image coordinate system",
    "QualityCheck": "Visual inspection recommended"
  }
}
EOF
    echo "JSON sidecar created: ${JSON_FILE}"
done

# Remove the copies of the other images (header modified by SPM), so only the coregistered files remain
for img_copy in "${other_imgs_copies[@]}"; do
  echo "Removing temporary copy: $img_copy"
  rm -f "$img_copy"
done

