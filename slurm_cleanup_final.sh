#!/bin/bash

# ==============================================================================
# Final cleanup script for T2 processing pipeline
# ==============================================================================
#
# DESCRIPTION:
#   This script performs the final cleanup of all temporary working directories
#   after the complete T2 processing pipeline has finished. It removes the
#   top-level working directories and their entire contents, freeing up disk
#   space used during processing. This is the last step in the cleanup process,
#   executed after all individual session cleanups are complete.
#
# USAGE:
#   slurm_cleanup_final.sh <TEMP_DIR_DENOISE> <TEMP_DIR_GNLC> <TEMP_DIR_T2FIT> <TEMP_DIR_ID> <TEMP_DIR>
#
# ARGUMENTS:
#   TEMP_DIR_DENOISE  - Full path to denoising working directory
#   TEMP_DIR_GNLC     - Full path to gradient non-linearity correction working directory
#   TEMP_DIR_T2FIT    - Full path to T2 fitting working directory
#   TEMP_DIR_ID       - Full path to job ID storage directory
#   TEMP_DIR          - Root working directory path (removed if empty)
#
# OPERATIONS PERFORMED:
#   1. Removes entire denoising working directory tree
#   2. Removes entire GNLC working directory tree
#   3. Removes entire T2 fitting working directory tree
#   4. Removes job ID storage directory tree
#   5. Removes root working directory (only if empty after other removals)
#
# EXAMPLE:
#   slurm_cleanup_final.sh \
#     /scratch/output/Supplementary/denoise \
#     /scratch/output/Supplementary/gnlc \
#     /scratch/output/Supplementary/t2fit \
#     /scratch/output/Supplementary/job_id_files \
#     /scratch/output/Supplementary
#
# NOTES:
#   - This script is typically called automatically as the final step of the pipeline
#   - Should only be executed after ALL session cleanup jobs have completed
#   - Provides timestamped logging for audit trail
#
# WARNING:
#   This script permanently deletes all intermediate processing files. Ensure all
#   final results have been saved to the output directory before running this script.
#   You can prevent this deletion by using the -pw | --preserve-workdir flag in the main processing script.
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
#
# ==============================================================================

# Arguments: temp_dir_denoise temp_dir_gnlc temp_dir_t2fit temp_dir

TEMP_DIR_DENOISE="$1"
TEMP_DIR_GNLC="$2"
TEMP_DIR_T2FIT="$3"
TEMP_DIR_ID="$4"
TEMP_DIR="$5"

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Final cleanup: Removing remaining working directories"

# Remove top-level directories if they exist and are empty
rm -rf "$TEMP_DIR_DENOISE"
rm -rf "$TEMP_DIR_GNLC"
rm -rf "$TEMP_DIR_T2FIT"
rm -rf "$TEMP_DIR_ID"
rmdir "$TEMP_DIR"

echo "Final cleanup completed successfully"