#!/bin/bash

# ==============================================================================
# Reference Denoise + N4 and MESE Echo Summation + ANTs Denoise + N4 Bias Correction
# ==============================================================================
#
# DESCRIPTION:
#   Denoises and N4-corrects the reference image, then sums all MESE echoes
#   in the input directory using FSL fslmaths and runs ANTs DenoiseImage and
#   N4BiasFieldCorrection on the summed image. Outputs denoised and
#   N4-corrected images to a target directory for subsequent coregistration.
#
# USAGE:
#   sbatch denoise_n4_ref_mese.sh <CONTAINER_PATH> <REFERENCE_IMAGE> <MESE_DIR> <OUTPUT_DIR> [FNAME_PATTERN] [OUTPUT_NAME]
#
# ARGUMENTS:
#   CONTAINER_PATH  - Path to Singularity container with FSL + ANTs tools
#   REFERENCE_IMAGE - Path to reference image (e.g., PDw_echoes_sum.nii)
#   MESE_DIR        - Directory containing MESE echo files
#   OUTPUT_DIR      - Directory where outputs will be stored
#   FNAME_PATTERN   - (Optional) Pattern to match echo files (default: "*MESE*.nii*")
#   OUTPUT_NAME     - (Optional) Summed output name (default: "MESE_echoes_avg.nii.gz")
#
# OUTPUTS:
#   <OUTPUT_DIR>/<ref_base>_denoised.nii
#   <OUTPUT_DIR>/<ref_base>_n4.nii
#   <OUTPUT_DIR>/<avg_base>.nii
#   <OUTPUT_DIR>/<avg_base>_denoised.nii
#   <OUTPUT_DIR>/<avg_base>_n4.nii
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH -c 4
#SBATCH --mem 8G
#SBATCH --time 20
#SBATCH -o /data/u_kuegler_software/git/r2_processing/logs/coreg_r2/%j.out

CONTAINER_PATH="$1"
REFERENCE_IMAGE="$2"
MESE_DIR="$3"
OUTPUT_DIR="$4"
FNAME_PATTERN="${5:-*MESE*.nii*}"
OUTPUT_NAME="${6:-MESE_echoes_avg.nii.gz}"

if [ $# -lt 4 ]; then
    echo "Error: 4 arguments required."
    echo "Usage: $0 <CONTAINER_PATH> <REFERENCE_IMAGE> <MESE_DIR> <OUTPUT_DIR> [FNAME_PATTERN] [OUTPUT_NAME]"
    exit 1
fi

set -e

print_cmd() {
    local quoted=()
    local token
    for token in "$@"; do
        quoted+=("$(printf '%q' "$token")")
    done
    echo "${quoted[*]}"
}

run_cmd() {
    echo "[RUN] $(print_cmd "$@")" >&2
    "$@"
}

ensure_tool_exists() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Error: Required tool '$tool' is not available in PATH"
        exit 1
    }
}

ensure_tool_exists_in_container() {
    local container="$1"
    local tool="$2"
    singularity exec "$container" bash -lc "command -v $tool >/dev/null 2>&1" || {
        echo "Error: Required tool '$tool' is not available in container"
        exit 1
    }
}

strip_nii_ext() {
    local name="$1"
    name="${name%.nii.gz}"
    name="${name%.nii}"
    echo "$name"
}

if [ ! -f "$REFERENCE_IMAGE" ]; then
    echo "Error: Reference image not found: $REFERENCE_IMAGE"
    exit 1
fi

if [ ! -d "$MESE_DIR" ]; then
    echo "Error: MESE directory not found: $MESE_DIR"
    exit 1
fi

if [ -n "$CONTAINER_PATH" ]; then
    if [ ! -f "$CONTAINER_PATH" ]; then
        echo "Error: Container file does not exist: $CONTAINER_PATH"
        exit 1
    fi
    ensure_tool_exists singularity
    ensure_tool_exists_in_container "$CONTAINER_PATH" fslmaths
    ensure_tool_exists_in_container "$CONTAINER_PATH" DenoiseImage
    ensure_tool_exists_in_container "$CONTAINER_PATH" N4BiasFieldCorrection
    RUNNER_PREFIX=(singularity exec "$CONTAINER_PATH")
else
    ensure_tool_exists fslmaths
    ensure_tool_exists DenoiseImage
    ensure_tool_exists N4BiasFieldCorrection
    RUNNER_PREFIX=()
fi

mkdir -p "$OUTPUT_DIR"

ref_base=$(basename "$REFERENCE_IMAGE")
ref_base=$(strip_nii_ext "$ref_base")
ref_denoised="$OUTPUT_DIR/${ref_base}_denoised.nii"
ref_n4="$OUTPUT_DIR/${ref_base}_n4.nii"

echo "Denoising + N4 correcting reference image..."
run_cmd "${RUNNER_PREFIX[@]}" DenoiseImage -d 3 -i "$REFERENCE_IMAGE" -o "$ref_denoised"
run_cmd "${RUNNER_PREFIX[@]}" N4BiasFieldCorrection -d 3 -i "$ref_denoised" -o "$ref_n4"

echo "Searching MESE echoes in: $MESE_DIR"
echo "Pattern: $FNAME_PATTERN"
mapfile -t echo_files < <(find "$MESE_DIR" -maxdepth 1 -type f -name "$FNAME_PATTERN" | sort)

if [ ${#echo_files[@]} -eq 0 ]; then
    echo "Error: No echo files found in $MESE_DIR matching pattern $FNAME_PATTERN"
    exit 1
fi

echo "Found ${#echo_files[@]} echoes"
for file in "${echo_files[@]}"; do
    echo "  $(basename "$file")"
done

mese_avg_output="$OUTPUT_DIR/$OUTPUT_NAME"
mese_avg_base=$(basename "$mese_avg_output")
mese_avg_base=$(strip_nii_ext "$mese_avg_base")
mese_avg_output_nii="$OUTPUT_DIR/${mese_avg_base}.nii"
mese_avg_denoised="$OUTPUT_DIR/${mese_avg_base}_denoised.nii"
mese_avg_n4="$OUTPUT_DIR/${mese_avg_base}_n4.nii"

echo "Summing MESE echoes with fslmaths..."
fsl_cmd=("${RUNNER_PREFIX[@]}" fslmaths "${echo_files[0]}")
for ((i=1; i<${#echo_files[@]}; i++)); do
    fsl_cmd+=( -add "${echo_files[$i]}" )
done
fsl_cmd+=( "$mese_avg_output" )
run_cmd "${fsl_cmd[@]}"

if [[ "$mese_avg_output" == *.gz ]]; then
    echo "Decompressing averaged output..."
    run_cmd gunzip -f "$mese_avg_output"
fi

echo "Denoising + N4 correcting averaged MESE image..."
run_cmd "${RUNNER_PREFIX[@]}" DenoiseImage -d 3 -i "$mese_avg_output_nii" -o "$mese_avg_denoised"
run_cmd "${RUNNER_PREFIX[@]}" N4BiasFieldCorrection -d 3 -i "$mese_avg_denoised" -o "$mese_avg_n4"

echo "Outputs:"
echo "  $ref_denoised"
echo "  $ref_n4"
echo "  $mese_avg_output_nii"
echo "  $mese_avg_denoised"
echo "  $mese_avg_n4"
