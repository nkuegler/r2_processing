#!/bin/bash

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