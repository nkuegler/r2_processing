#!/bin/bash

# ==============================================================================
# SLURM Bridge Script - MESE Gradient Non-linearity Correction
# ==============================================================================
#
# DESCRIPTION:
#   Bridge script that executes gradient nonlinearity correction (GNLC) of the MESE data.
#   Adds delay to prevent job overlap with the AFI GNLC job and executes the provided GNLC command.
#   The script is used to manage the dependencies between jobs in the SLURM queue.
#
#   If the GNLC command detects that the file already has NonlinearGradientCorrection=true
#   (i.e., GNLC is skipped), the script copies the denoised file to the GNLC output directory
#   with the correct BIDS-compliant name (inserting _desc-undistortedJac before _MESE) and
#   submits a placeholder SLURM job so that downstream dependency chains remain intact.
#
# USAGE:
#   slurm_bridge_gnlc_mese.sh "<GNLC_COMMAND>" "<SUBJECT>" "<SESSION>" "<SOURCE_DIR>" "<OUTPUT_DIR>" "<GNLC_JOB_NAME>"
#
# ARGUMENTS:
#   GNLC_COMMAND   - Complete GNLC command string to execute for MESE data
#   SUBJECT        - Subject ID (e.g., sub-001)
#   SESSION        - Session ID (e.g., ses-01)
#   SOURCE_DIR     - Denoising output directory (source for fallback copy)
#   OUTPUT_DIR     - GNLC output directory (destination for fallback copy)
#   GNLC_JOB_NAME - Expected GNLC job name (for placeholder job if skipped)
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH --time=30
#SBATCH --mem=1G

GNLC_CMD_MESE="$1"
SUBJECT="$2"
SESSION="$3"
SOURCE_DIR="$4"
OUTPUT_DIR="$5"
GNLC_JOB_NAME="$6"

echo "Bridge job: Waiting for denoising completion, then running MESE GNLC"
echo "Denoising job completed."

echo "Waiting 60 seconds to avoid overlap with AFI GNLC job..."
sleep 60 

echo "Running GNLC command:"
echo "$GNLC_CMD_MESE"

# Run GNLC command and capture output
gnlc_output=$($GNLC_CMD_MESE 2>&1)
gnlc_exit_code=$?
echo "$gnlc_output"

# Check if GNLC was skipped because the file is already corrected
if echo "$gnlc_output" | grep -q "already has NonlinearGradientCorrection=true"; then
    echo ""
    echo "============================================================"
    echo "GNLC was skipped (file already corrected)."
    echo "Copying denoised MESE files to GNLC output directory with correct naming..."
    echo "============================================================"

    source_anat="$SOURCE_DIR/$SUBJECT/$SESSION/anat"
    target_anat="$OUTPUT_DIR/$SUBJECT/$SESSION/anat"
    mkdir -p "$target_anat"

    # Extract filenames reported by the GNLC script from its output
    # Format: "INFO: File <filename> already has NonlinearGradientCorrection=true. Skipping contrast ..."
    skipped_lines=$(echo "$gnlc_output" | grep 'already has NonlinearGradientCorrection=true')
    num_skipped=$(echo "$skipped_lines" | wc -l)

    if [[ $num_skipped -gt 1 ]]; then
        echo "  ERROR: Expected exactly 1 file to be skipped, but found $num_skipped."
        echo "  This is unexpected and likely indicates a problem with the input data."
        echo "  Skipped files:"
        echo "$skipped_lines"
        exit 1
    fi

    # Extract the single filename from the info line
    filename=$(echo "$skipped_lines" | sed -n 's/.*INFO: File \(.*\) already has NonlinearGradientCorrection=true.*/\1/p')

    copy_success=false

    if [[ -z "$filename" ]]; then
        echo "  ERROR: Could not extract filename from GNLC output."
    else
        src_file="$source_anat/$filename"
        if [[ ! -f "$src_file" ]]; then
            echo "  ERROR: File reported by GNLC not found: $src_file"
        else
            # Determine BIDS suffix: last _ENTITY before the extension (e.g., _MESE, _TB1AFI)
            basename_no_ext="${filename%%.*}"
            bids_suffix="_${basename_no_ext##*_}"  # e.g., _MESE

            # Insert _desc-undistortedJac before the BIDS suffix
            new_filename="${filename/$bids_suffix/_desc-undistortedJac${bids_suffix}}"
            if cp "$src_file" "$target_anat/$new_filename"; then
                echo "  Copied NIfTI: $filename -> $new_filename"
                copy_success=true
            else
                echo "  ERROR: Failed to copy NIfTI file."
            fi

            # Also copy JSON sidecar if it exists
            if [[ "$src_file" == *.nii.gz ]]; then
                json_src="${src_file%.nii.gz}.json"
            else
                json_src="${src_file%.nii}.json"
            fi
            if [[ -f "$json_src" ]]; then
                json_name=$(basename "$json_src")
                new_json_name="${json_name/$bids_suffix/_desc-undistortedJac${bids_suffix}}"
                cp "$json_src" "$target_anat/$new_json_name"
                echo "  Copied JSON:  $json_name -> $new_json_name"
            fi
        fi
    fi

    if [[ "$copy_success" == "true" ]]; then
        echo "  Successfully copied file to GNLC output directory."

        # Submit a placeholder SLURM job with the expected GNLC job name
        # so that the downstream T2 fitting bridge can find it in squeue
        if [[ -n "$GNLC_JOB_NAME" ]]; then
            echo "  Submitting placeholder job with name: $GNLC_JOB_NAME"
            sbatch -p short,group_servers,gr_weiskopf \
                --job-name="$GNLC_JOB_NAME" \
                --time=5 --mem=100M \
                --output=/tmp/%j_placeholder_gnlc_mese.out \
                --wrap="echo 'GNLC MESE skipped - file already corrected. Placeholder job for dependency chain.'; sleep 180"
        fi
    else
        echo ""
        echo "  ============================================================"
        echo "  ERROR: MESE data is already corrected for gradient nonlinearities,"
        echo "  but the workaround copy to the GNLC output directory failed."
        echo "  Downstream jobs (T2 fitting, cleanup) will NOT be submitted."
        echo "  Please investigate the issue manually."
        echo "  ============================================================"
        exit 1
    fi
fi