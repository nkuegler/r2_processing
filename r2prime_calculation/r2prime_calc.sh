#!/bin/bash

parent_dir=$1
r2map=$2
r2starmap=$3
int_mode=$4
output_dir=$5
# default output filename is r2prime.nii.gz, but can be changed by specifying $6


# Good scientists abort computations upon unexpected problems
set -e

## The more scientific way with increased reproducibility:
fsl="sc fsl 6.0.6"
ants="sc ants 2.5.4"

# Check if the output directory exists and contains files
if [ -d "$output_dir" ] && [ "$(ls -A "$output_dir")" ]; then
    echo "Error: Output directory '$output_dir' is not empty. Aborting execution."
    exit 1
fi

# Create output directory if it does not exist
if [ ! -d "$output_dir" ]; then
    mkdir -p "$output_dir"
fi

cp $r2map $output_dir
cp $r2starmap $output_dir

cd $parent_dir
echo "Resampling R2 map into the R2* map space"
echo "Input R2 map: $r2map"
echo "Input R2* map: $r2starmap"
$ants antsApplyTransforms -d 3 -i $r2map -r $r2starmap -o $output_dir/r2_resampled.nii.gz -n $int_mode

echo "Subtracting R2 map from R2* map"
output_filename=${6:-r2prime.nii.gz}
$fsl fslmaths $r2starmap -sub $output_dir/r2_resampled.nii.gz $output_dir/r2s_minus_r2_resampled.nii.gz
echo "Setting pixels to zero where r2_resampled.nii.gz is zero"
$fsl fslmaths $output_dir/r2_resampled.nii.gz -thr 0.000000001 -bin $output_dir/r2_resampled_mask.nii.gz
$fsl fslmaths $output_dir/r2s_minus_r2_resampled.nii.gz -mul $output_dir/r2_resampled_mask.nii.gz $output_dir/r2prime_pos_neg.nii.gz
echo "Restricting R2' map to positive values"
$fsl fslmaths $output_dir/r2prime_pos_neg.nii.gz -thr 0.000000001 $output_dir/$output_filename
echo "R2' map saved to $output_dir/$output_filename"

echo "Cleaning up temporary files"
# rm $output_dir/r2_resampled.nii.gz
# rm $output_dir/r2_resampled_mask.nii.gz
# rm $output_dir/r2s_minus_r2_resampled.nii.gz
# rm $output_dir/r2prime_pos_neg.nii.gz
echo "Done"