#!/bin/bash

# This script is used to resample a 3D image to the space of a reference image using ANTs.
# It takes the following arguments:
# 1. input_fn: The full path to the input image file to be resampled.
# 2. reference_fn: The full path to the reference image file to which the input image will be resampled.
# 3. output_fn: The full path to the output image file after resampling.
# 4. int_mode: The interpolation mode to be used for resampling (e.g., Linear, NearestNeighbor, etc.).
# Usage: ./resample_afi_3D.sh <input_fn> <reference_fn> <output_fn> <int_mode>

# The implementation uses singularity containers provided by the IT department of the MPI CBS. It will only work in the infrastructure of the institute.
# This is only preliminary.

input_fn=$1
reference_fn=$2
output_fn=$3
int_mode=$4

# Check if all required arguments are provided
if [ $# -ne 4 ]; then
    echo "Error: Exactly 4 arguments required."
    echo "Usage: $0 <input_fn> <reference_fn> <output_fn> <int_mode>"
    exit 1
fi


# Good scientists abort computations upon unexpected problems
set -e

custom_container=true

## Use this for running the script outside of the singularity container (MPI CBS infrastructure):
if [ "$custom_container" = false ]; then
    fsl="sc fsl 6.0.6"
    ants="sc ants 2.5.4"
fi

# Extract directory from output path for temporary files
output_dir=$(dirname "$output_fn")
temp_ref="${output_dir}/ref_tmp.nii.gz"

echo "Cropping reference image to only two echoes"
if [ "$custom_container" = true ]; then
    fslroi "$reference_fn" "$temp_ref" 0 -1 0 -1 0 -1 0 1    # cut the reference image to only two echoes
else
    $fsl fslroi "$reference_fn" "$temp_ref" 0 -1 0 -1 0 -1 0 1    # cut the reference image to only two echoes
fi

echo "Resampling input image to reference image space"
echo "Resampling input image to reference image space"
if [ "$custom_container" = true ]; then
    antsApplyTransforms -d 3 -i "$input_fn" -r "$temp_ref" -o "$output_fn" -n "$int_mode"
else
    $ants antsApplyTransforms -d 3 -i "$input_fn" -r "$temp_ref" -o "$output_fn" -n "$int_mode"
fi


echo "Resampling done"
echo "Cleaning up"
rm "$temp_ref"