#!/bin/bash

# ==============================================================================
# 3D Image Resampling Utility Script
# ==============================================================================
#
# DESCRIPTION:
#   This script resamples any 3D image to match the spatial dimensions and 
#   orientation of a reference image using ANTs (Advanced Normalization Tools).
#   The script handles 4D multi-echo reference images by automatically cropping
#   to the first echo for resampling purposes.
#
# USAGE:
#   ./resample_afi_3D.sh <input_fn> <reference_fn> <output_fn> <int_mode>
#
# ARGUMENTS:
#   input_fn      - Full path to input 3D image file to be resampled
#   reference_fn  - Full path to reference image file (target space)
#   output_fn     - Full path to output resampled image file
#   int_mode      - Interpolation mode (Linear, NearestNeighbor, BSpline, etc.)
#
# OPERATIONS PERFORMED:
#   1. Cropping reference image to first echo (if multi-echo)
#   2. Spatial resampling using ANTs antsApplyTransforms
#   3. Cleanup of temporary files
#
# EXAMPLE:
#   ./resample_afi_3D.sh \
#     /data/afi/sub-001_ses-01_AFI.nii.gz \
#     /data/mese/sub-001_ses-01_MESE.nii.gz \
#     /data/output/sub-001_ses-01_AFI_resampled.nii.gz \
#     Linear
#
# NOTES:
#   - Can be either run within a custom container (native FSL/ANTs installation) 
#     or on the CBS infrastructure with the pre-built `sc` containers
#   - Reference images with multiple echoes are automatically cropped to the first echo
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

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

echo "Cropping reference image to only one echo"
if [ "$custom_container" = true ]; then
    fslroi "$reference_fn" "$temp_ref" 0 -1 0 -1 0 -1 0 1    # cut the reference image to only one echo
else
    $fsl fslroi "$reference_fn" "$temp_ref" 0 -1 0 -1 0 -1 0 1    # cut the reference image to only one echo
fi

echo "Resampling input image to reference image space"
if [ "$custom_container" = true ]; then
    antsApplyTransforms -d 3 -i "$input_fn" -r "$temp_ref" -o "$output_fn" -n "$int_mode"
else
    $ants antsApplyTransforms -d 3 -i "$input_fn" -r "$temp_ref" -o "$output_fn" -n "$int_mode"
fi


echo "Resampling done"
echo "Cleaning up"
rm "$temp_ref"