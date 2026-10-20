#!/bin/bash

# ==============================================================================
# SLURM Bridge Script - Custom B1+ Map Gradient Non-linearity Correction
# ==============================================================================
#
# DESCRIPTION:
#   Bridge script that prepares a custom (pre-calculated) B1+ map for the T2 fitting.
#   The script is used to manage the dependencies between jobs in the SLURM queue.
#
#   The B1+ map (and its JSON sidecar(s)) is staged into a BIDS-like staging directory
#   (STAGING_ROOT/sub-xxx/ses-xx/anat/). Depending on MODE:
#     gnlc         - The B1+ map was calculated from data NOT corrected for gradient
#                    nonlinearities. GNLC is run on the staged B1+ map WITHOUT jacobian
#                    intensity modulation (--no-jacobian, quantitative map).
#     precorrected - The B1+ map was calculated from GNL-corrected data. The map is copied
#                    to the GNLC output directory without correction.
#     asis         - The user forced to use the B1+ map as is (GNLC status not checked).
#                    The map is copied to the GNLC output directory without correction.
#   In the modes 'precorrected' and 'asis', a placeholder SLURM job with the expected
#   GNLC job name is submitted so that downstream dependency chains remain intact.
#
#   The output in the GNLC output directory is always named
#   <B1map stem without 'B1map'>desc-undistorted_B1map.nii (+ .json). The JSON sidecar
#   contains the key 'B1mapGNLCHandling' documenting how the GNLC was handled.
#
# USAGE:
#   slurm_bridge_gnlc_b1.sh <GNLC_SCRIPT> <MODE> <B1MAP_PATH> <SUBJECT> <SESSION> <STAGING_ROOT> <OUTPUT_DIR> <SCANNER_NAME> <GNLC_JOB_NAME> <LOG_PREFIX>
#
# ARGUMENTS:
#   GNLC_SCRIPT    - Path to the batch_gnlc call script (call_slurm_batch_magn.sh)
#   MODE           - gnlc | precorrected | asis
#   B1MAP_PATH     - Path to the custom B1+ map (.nii or .nii.gz)
#   SUBJECT        - Subject ID (e.g., sub-001)
#   SESSION        - Session ID (e.g., ses-01)
#   STAGING_ROOT   - BIDS-like root directory where the B1+ map is staged (GNLC input)
#   OUTPUT_DIR     - GNLC output directory (BIDS-like root)
#   SCANNER_NAME   - Scanner name for the GNLC (e.g., Terra)
#   GNLC_JOB_NAME  - Expected GNLC job name (used for the GNLC job or the placeholder job)
#   LOG_PREFIX     - Log file prefix for the GNLC SLURM job
#
# REQUIREMENTS:
#   - jq
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH --time=10
#SBATCH --mem=1G

GNLC_SCRIPT="$1"
MODE="$2"
B1MAP_PATH="$3"
SUBJECT="$4"
SESSION="$5"
STAGING_ROOT="$6"
OUTPUT_DIR="$7"
SCANNER_NAME="$8"
GNLC_JOB_NAME="$9"
LOG_PREFIX="${10}"

echo "Bridge job: Preparing custom B1+ map (mode: $MODE)"
echo "B1+ map: $B1MAP_PATH"

case "$MODE" in
    gnlc)         gnlc_handling="corrected in pipeline (GNLC, no Jacobian)" ;;
    precorrected) gnlc_handling="already corrected (B1ref.json)" ;;
    asis)         gnlc_handling="used as is (forced, GNLC status not checked)" ;;
    *)
        echo "ERROR: Unknown mode '$MODE'. Must be one of: gnlc, precorrected, asis"
        exit 1
        ;;
esac

if [[ ! -f "$B1MAP_PATH" ]]; then
    echo "ERROR: B1+ map not found: $B1MAP_PATH"
    exit 1
fi

# ============================================================
# STAGING
# ============================================================
b1map_dir="$(dirname "$B1MAP_PATH")"
b1map_name="$(basename "$B1MAP_PATH")"
b1map_stem="${b1map_name%%.nii*}"
b1_prefix="${b1map_stem%B1map}" # e.g., sub-001_ses-01_acq-stx_

staging_anat="$STAGING_ROOT/$SUBJECT/$SESSION/anat"
mkdir -p "$staging_anat"
staged_nii="$staging_anat/${b1map_stem}.nii"
staged_json="$staging_anat/${b1map_stem}.json"

# GNLC only processes uncompressed .nii files
if [[ "$b1map_name" == *.nii.gz ]]; then
    gunzip -c "$B1MAP_PATH" > "$staged_nii" || { echo "ERROR: Failed to decompress $B1MAP_PATH"; exit 1; }
else
    cp "$B1MAP_PATH" "$staged_nii" || { echo "ERROR: Failed to copy $B1MAP_PATH"; exit 1; }
fi
echo "  Staged B1+ map: $staged_nii"

if [[ -f "$b1map_dir/${b1map_stem}.json" ]]; then
    cp "$b1map_dir/${b1map_stem}.json" "$staged_json"
else
    echo "{}" > "$staged_json"
fi
if jq --arg h "$gnlc_handling" '.B1mapGNLCHandling = $h' "$staged_json" > "$staged_json.tmp"; then
    mv "$staged_json.tmp" "$staged_json"
    echo "  Staged B1+ map JSON: $staged_json (B1mapGNLCHandling: $gnlc_handling)"
else
    rm -f "$staged_json.tmp"
    echo "ERROR: Failed to update JSON file: $staged_json"
    exit 1
fi

# Keep the B1ref JSON for provenance
b1ref_json="$b1map_dir/${b1_prefix}B1ref.json"
if [[ -f "$b1ref_json" ]]; then
    cp "$b1ref_json" "$staging_anat/"
fi

# ============================================================
# GNLC OR COPY
# ============================================================
if [[ "$MODE" == "gnlc" ]]; then
    gnlc_cmd=(
        bash "$GNLC_SCRIPT"
        --nj
        -c "$b1_prefix"
        -p "B1map"
        -sub "$SUBJECT"
        -ses "$SESSION"
        -job-name "$GNLC_JOB_NAME"
        -log "$LOG_PREFIX"
        "$SCANNER_NAME" "$STAGING_ROOT" "$OUTPUT_DIR"
    )
    echo "Running GNLC command:"
    echo "${gnlc_cmd[*]}"

    gnlc_output=$("${gnlc_cmd[@]}" 2>&1)
    echo "$gnlc_output"

    if ! echo "$gnlc_output" | grep -q "Submitted batch job"; then
        echo ""
        echo "  ============================================================"
        echo "  ERROR: No GNLC job was submitted for the B1+ map."
        echo "  Downstream jobs (T2 fitting, cleanup) will NOT be submitted."
        echo "  Please investigate the issue manually."
        echo "  ============================================================"
        exit 1
    fi
else
    target_anat="$OUTPUT_DIR/$SUBJECT/$SESSION/anat"
    mkdir -p "$target_anat"
    out_stem="${b1_prefix}desc-undistorted_B1map"

    if cp "$staged_nii" "$target_anat/${out_stem}.nii" && cp "$staged_json" "$target_anat/${out_stem}.json"; then
        echo "  Copied B1+ map without GNLC: $target_anat/${out_stem}.nii"
    else
        echo "  ERROR: Failed to copy B1+ map to the GNLC output directory."
        echo "  Downstream jobs (T2 fitting, cleanup) will NOT be submitted."
        exit 1
    fi

    # Submit a placeholder SLURM job with the expected GNLC job name
    # so that the downstream T2 fitting bridge can find it in squeue
    echo "  Submitting placeholder job with name: $GNLC_JOB_NAME"
    sbatch -p short,group_servers,gr_weiskopf \
        --job-name="$GNLC_JOB_NAME" \
        --time=5 --mem=100M \
        --output=/tmp/%j_placeholder_gnlc_b1.out \
        --wrap="echo 'GNLC of the B1+ map skipped ($MODE). Placeholder job for dependency chain.'; sleep 180"
fi
