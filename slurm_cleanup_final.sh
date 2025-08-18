#!/bin/bash

# ==============================================================================
# Final cleanup script for neuroimaging processing pipelines
# ==============================================================================
#
# DESCRIPTION:
#   This script performs the final cleanup of all temporary working directories
#   after the complete processing pipeline has finished. It can operate in two modes:
#   
#   1. SELECTIVE CLEANUP: When subdirectories are specified, removes each specified
#      subdirectory with rm -rf, then attempts to remove the root directory with rmdir
#      (only succeeds if empty after subdirectory removal).
#   
#   2. COMPLETE CLEANUP: When no subdirectories are specified, recursively removes the entire
#      root directory tree with rm -rf, including all contents.
#   
#   This is the last step in the cleanup process, executed after all individual
#   session cleanups are complete, freeing up disk space used during processing.
#
#   This script is flexible and can be used by different processing pipelines
#   (T2 processing, R2' creation, etc.) by passing different sets of subdirectories
#   or by specifying only the root directory for complete removal.
#
# USAGE:
#   slurm_cleanup_final.sh <TEMP_DIR> [<SUBDIR_1>] [SUBDIR_2] [SUBDIR_3] [...]
#
# ARGUMENTS:
#   TEMP_DIR         - Root temporary directory path
#   SUBDIR_1          - First subdirectory to remove (optional - see modes below)
#   SUBDIR_2          - Second subdirectory to remove (optional)
#   SUBDIR_3          - Third subdirectory to remove (optional)
#   [...]             - Additional subdirectories to remove (optional)
#
# OPERATION MODES:
#   MODE 1 - SELECTIVE CLEANUP (when subdirectories are specified):
#     1. Removes each specified subdirectory tree with rm -rf
#     2. Attempts to remove root directory with rmdir (only if empty)
#   
#   MODE 2 - COMPLETE CLEANUP (when no subdirectories specified):
#     1. Removes entire root directory tree with rm -rf (including all contents)
#
# EXAMPLES:
#   # T2 processing pipeline - SELECTIVE CLEANUP (4 subdirectories)
#   slurm_cleanup_final.sh \
#     /scratch/output/Supplementary \
#     /scratch/output/Supplementary/denoise \
#     /scratch/output/Supplementary/gnlc \
#     /scratch/output/Supplementary/t2fit \
#     /scratch/output/Supplementary/job_id_files
#   
#   # R2' creation pipeline - COMPLETE CLEANUP
#   slurm_cleanup_final.sh \
#     /scratch/output/Supplementary
#
# NOTES:
#   - This script is typically called automatically as the final step of processing pipelines
#   - Should only be executed after ALL session cleanup jobs have completed
#   - Provides timestamped logging for audit trail
#   - Compatible with T2 processing pipeline, R2' creation pipeline, and others
#   - Supports variable number of subdirectory arguments for flexibility
#   - SELECTIVE vs COMPLETE cleanup mode determined by presence of subdirectory arguments
#
# WARNING:
#   This script permanently deletes all intermediate processing files. Ensure all
#   final results have been saved to the output directory before running.
#   You can prevent this deletion by using the -pw | --preserve-workdir flag in the main processing script.
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
#
# ==============================================================================

TEMP_DIR="$1"
shift

# Remaining arguments are the subdirectories to clean up
SUBDIRS=("$@")

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Final cleanup: Removing temporary directories"

# Check if we have any subdirectories to process
if [[ ${#SUBDIRS[@]} -eq 0 ]]; then
    echo "Warning: No subdirectories specified for cleanup"
    # Remove the temp directory entirely since no subdirectories were specified
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        if [[ $? -eq 0 ]]; then
            echo "> Removed entire temporary directory: $TEMP_DIR"
        else
            echo "Error: Failed to remove temporary directory: $TEMP_DIR"
            exit 1
        fi
    else
        echo "Temporary directory not found: $TEMP_DIR"
    fi
    exit 0
fi

echo "Processing ${#SUBDIRS[@]} subdirectory/directories:"

# Initialize counter for successfully removed directories
cnt_rmSubdirs=0

# Remove subdirectories
for subdir in "${SUBDIRS[@]}"; do
    if [[ -d "$subdir" ]]; then
        rm -rf "$subdir"

        if [[ $? -eq 0 ]]; then
            # echo "Removed: $subdir"
            ((cnt_rmSubdirs++))
        else
            echo "Error: Failed to remove subdirectory: $subdir"
            exit 1
        fi
    else
        echo "Not found (skipping): $subdir"
    fi
done
echo "> Removed $cnt_rmSubdirs subdirectories successfully"

# Try to remove the temporary directory (will only succeed if empty)
if [[ -d "$TEMP_DIR" ]]; then
    rmdir "$TEMP_DIR" 2>/dev/null && echo "Final cleanup successful: Removed temporary directory: $TEMP_DIR" || echo "Temporary directory not empty or removal failed: $TEMP_DIR"
else
    echo "Temporary directory not found: $TEMP_DIR"
fi