#!/bin/bash

# ==============================================================================
# Session cleanup script for neuroimaging processing pipelines
# ==============================================================================
#
# DESCRIPTION:
#   This script removes temporary working directories for a specific subject and
#   session after processing pipeline completion. It's designed to be called
#   as part of the automated cleanup process to free up disk space by removing
#   intermediate files that are no longer needed.
#
#   This script is flexible and can be used by different processing pipelines
#   (T2 processing, R2' creation, etc.) by passing different sets of directories.
#
# USAGE:
#   slurm_cleanup_session.sh <SUBJECT> <SESSION> <TEMP_DIR_1> [TEMP_DIR_2] [TEMP_DIR_3] [...]
#
# ARGUMENTS:
#   SUBJECT           - Subject identifier (e.g., sub-001)
#   SESSION           - Session identifier (e.g., ses-01)
#   TEMP_DIR_1        - First temporary directory root path
#   TEMP_DIR_2        - Second temporary directory root path (optional)
#   TEMP_DIR_3        - Third temporary directory root path (optional)
#   [...]             - Additional temporary directory root paths (optional)
#
# DIRECTORIES REMOVED:
#   For each provided TEMP_DIR: ${TEMP_DIR}/${SUBJECT}/${SESSION}/
#
# EXAMPLES:
#   # T2 processing pipeline (3 directories)
#   slurm_cleanup_session.sh \
#     sub-001 ses-01 \
#     /scratch/denoise /scratch/gnlc /scratch/t2fit
#   
#   # R2' creation pipeline (1 directory)
#   slurm_cleanup_session.sh \
#     sub-001 ses-01 \
#     /scratch/r2prime_work
#
# NOTES:
#   - This script is typically called automatically by processing pipelines
#   - Supports variable number of directory arguments for flexibility
#   - Compatible with T2 processing pipeline, R2' creation pipeline, and others
#
# WARNING:
#   This script permanently deletes all intermediate processing files of the specified session.
#   You can prevent this deletion by using the -pw | --preserve-workdir flag in the main processing script.
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
#
# ==============================================================================

SUBJECT="$1"
SESSION="$2"

# Shift to remove subject and session from argument list
shift 2

# Remaining arguments are the directories to clean up
TEMP_DIRS=("$@")

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Session cleanup: Deleting temporary directories for ${SUBJECT}/${SESSION}"

# Check if we have any directories to process
if [[ ${#TEMP_DIRS[@]} -eq 0 ]]; then
    echo "Warning: No directories specified for cleanup"
    exit 0
fi

echo "Processing ${#TEMP_DIRS[@]} temporary directory root(s):"

# Remove directories if they exist
for temp_dir in "${TEMP_DIRS[@]}"; do
    target_path="$temp_dir/$SUBJECT/$SESSION"
    if [[ -d "$target_path" ]]; then
        rm -rf "$target_path"
        if [[ $? -eq 0 ]]; then
            echo "Deleted: $target_path"
        else
            echo "Error: Failed to remove session's temporary directory"
            exit 1
        fi
    else
        echo "Not found (skipping): $target_path"
    fi
done

echo "Session cleanup completed successfully for ${SUBJECT}/${SESSION}"