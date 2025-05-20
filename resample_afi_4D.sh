#!/bin/bash

# This script is used to resample a 4D image to the space of a reference image using ANTs.
# It takes the following arguments:
# 1. parent_dir: The directory where the input and reference images are located.
# 2. input_fn: The name of the input image file to be resampled.
# 3. reference_fn: The name of the reference image file to which the input image will be resampled.
# 4. output_fn: The name of the output image file after resampling.
# 5. int_mode: The interpolation mode to be used for resampling (e.g., Linear, NearestNeighbor, etc.).
# Usage: ./resample_afi_4D.sh <parent_dir> <input_fn> <reference_fn> <output_fn> <int_mode>

# The implementation uses singularity containers provided by the IT department of the MPI CBS. It will only work in the infrastructure of the institute.
# This is only preliminary.

parent_dir=$1
input_fn=$2
reference_fn=$3
output_fn=$4
int_mode=$5


# Good scientists abort computations upon unexpected problems
set -e

## The more scientific way with increased reproducibility:
fsl="sc fsl 6.0.6"
ants="sc ants 2.5.4"

cd $parent_dir
echo "Cropping reference image to only two echoes"
$fsl fslroi $reference_fn ref_tmp.nii.gz 0 -1 0 -1 0 -1 0 2    # cut the reference image to only two echoes
echo "Resampling input image to reference image space"
$ants antsApplyTransforms -d 4 -i $input_fn -r ref_tmp.nii.gz -o $output_fn -n $int_mode
echo "Resampling done"
echo "Cleaning up"
rm ref_tmp.nii.gz