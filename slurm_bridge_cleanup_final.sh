#!/bin/bash

# ==============================================================================
# SLURM Bridge Script - Final Cleanup
# ==============================================================================
#
# DESCRIPTION:
#   Bridge script that coordinates final cleanup after all session cleanups complete.
#   Reads cleanup job IDs from file and submits final cleanup with proper dependencies.
#   Handles the final stage of working directory cleanup in the T2 processing pipeline.
#
# USAGE:
#   slurm_bridge_cleanup_final.sh <CLEANUP_SCRIPT> <TEMP_DIR_DENOISE> <TEMP_DIR_GNLC> <TEMP_DIR_T2FIT> <TEMP_DIR_ID> <TEMP_DIR> <DEPENDENCY_ID_FILE>
#
# ARGUMENTS:
#   CLEANUP_SCRIPT     - Path to final cleanup script to execute
#   TEMP_DIR_*         - Temporary directory paths to be cleaned up
#   DEPENDENCY_ID_FILE - File containing session cleanup job IDs for dependencies
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH --job-name=bridge_cleanup_final
#SBATCH --time=30
#SBATCH --mem=1G
#SBATCH --output=/data/u_kuegler_software/git/r2_map_calculation/logs/%j_bridge_final_cleanup.out

CLEANUP_SCRIPT="$1"
TEMP_DIR_DENOISE="$2"
TEMP_DIR_GNLC="$3"
TEMP_DIR_T2FIT="$4"
TEMP_DIR_ID="$5"
TEMP_DIR="$6"
DEPENDENCY_ID_FILE="$7"

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Final cleanup bridge job: Waiting for all session cleanup bridge jobs completion"


echo "Reading cleanup job IDs from file: $DEPENDENCY_ID_FILE"
# Check if the cleanup IDs file exists and has content
if [[ ! -f "$DEPENDENCY_ID_FILE" ]]; then
    echo "Error: Cleanup session IDs file not found: $DEPENDENCY_ID_FILE"
    exit 1
fi

# Read all cleanup job IDs from the file
cleanup_job_ids=()
while IFS= read -r line; do
    if [[ -n "$line" && "$line" =~ ^[0-9]+$ ]]; then
        cleanup_job_ids+=("$line")
    fi
done < "$DEPENDENCY_ID_FILE"

if [[ ${#cleanup_job_ids[@]} -eq 0 ]]; then
    echo "Error: No valid cleanup job IDs found in file"
    exit 1
fi

echo "Found ${#cleanup_job_ids[@]} cleanup job IDs: ${cleanup_job_ids[*]}"


# Build dependency string for actual cleanup job IDs
if [[ ${#cleanup_job_ids[@]} -gt 1 ]]; then
    cleanup_dependency_list=$(IFS=':'; echo "${cleanup_job_ids[*]}")
    final_cleanup_dependency="--dependency=afterok:$cleanup_dependency_list"
elif [[ ${#cleanup_job_ids[@]} -eq 1 ]]; then
    final_cleanup_dependency="--dependency=afterok:${cleanup_job_ids[0]}"
fi

# Submit final cleanup job with dependency on actual cleanup job IDs
final_cleanup_cmd="sbatch $final_cleanup_dependency \
    --job-name=cleanup_final \
    --time=10 \
    --mem=1G \
    --output=/data/u_kuegler_software/git/r2_map_calculation/logs/%j_final_cleanup.out \
    -p short,group_servers,gr_weiskopf \
    \"$CLEANUP_SCRIPT\" \
    \"$TEMP_DIR_DENOISE\" \
    \"$TEMP_DIR_GNLC\" \
    \"$TEMP_DIR_T2FIT\" \
    \"$TEMP_DIR_ID\" \
    \"$TEMP_DIR\""

echo "Submitting final cleanup job with command:"
echo "$final_cleanup_cmd"

echo "------------------------------"
final_cleanup_out=$(eval "$final_cleanup_cmd")

# Extract and log final cleanup job ID
if [[ $final_cleanup_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
    final_cleanup_job_id="${BASH_REMATCH[1]}"
    echo "Final cleanup job ID: $final_cleanup_job_id (depends on ${#cleanup_job_ids[@]} cleanup jobs: ${cleanup_job_ids[*]})"
else
    echo "Error: Could not extract final cleanup job ID from sbatch output"
    exit 1
fi