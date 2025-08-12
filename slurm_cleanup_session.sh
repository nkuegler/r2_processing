#!/bin/bash

# ==============================================================================
# Session cleanup script for T2 processing pipeline
# ==============================================================================
#
# DESCRIPTION:
#   This script removes temporary working directories for a specific subject and
#   session after T2 processing pipeline completion. It's designed to be called
#   as part of the automated cleanup process to free up disk space by removing
#   intermediate files that are no longer needed.
#
# USAGE:
#   slurm_cleanup_session.sh <SUBJECT> <SESSION> <TEMP_DIR_DENOISE> <TEMP_DIR_GNLC> <TEMP_DIR_T2FIT>
#
# ARGUMENTS:
#   SUBJECT           - Subject identifier (e.g., sub-001)
#   SESSION           - Session identifier (e.g., ses-01)
#   TEMP_DIR_DENOISE  - Root path to denoising working directory
#   TEMP_DIR_GNLC     - Root path to gradient non-linearity correction working directory
#   TEMP_DIR_T2FIT    - Root path to T2 fitting working directory
#
# DIRECTORIES REMOVED:
#   - ${TEMP_DIR_DENOISE}/${SUBJECT}/${SESSION}/
#   - ${TEMP_DIR_GNLC}/${SUBJECT}/${SESSION}/
#   - ${TEMP_DIR_T2FIT}/${SUBJECT}/${SESSION}/
#
# EXAMPLE:
#   slurm_cleanup_session.sh \
#     sub-001 ses-01 \
#     /scratch/denoise /scratch/gnlc /scratch/t2fit
#
# NOTES:
#   - This script is typically called automatically by the T2 processing pipeline
#
# WARNING:
#   This script permanently deletes all intermediate processing files of the specified session.
#   You can prevent this deletion by using the -pw | --preserve-workdir flag in the main processing script.
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
#
# ==============================================================================

# Arguments: subject session temp_dir_denoise temp_dir_gnlc temp_dir_t2fit

SUBJECT="$1"
SESSION="$2"
TEMP_DIR_DENOISE="$3"
TEMP_DIR_GNLC="$4"
TEMP_DIR_T2FIT="$5"

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Session cleanup: Deleting working directories for ${SUBJECT}/${SESSION}"

# Remove directories if they exist
if [[ -d "$TEMP_DIR_DENOISE/$SUBJECT/$SESSION" ]]; then
    rm -rf "$TEMP_DIR_DENOISE/$SUBJECT/$SESSION"
    echo "Deleted: $TEMP_DIR_DENOISE/$SUBJECT/$SESSION"
fi

if [[ -d "$TEMP_DIR_GNLC/$SUBJECT/$SESSION" ]]; then
    rm -rf "$TEMP_DIR_GNLC/$SUBJECT/$SESSION"
    echo "Deleted: $TEMP_DIR_GNLC/$SUBJECT/$SESSION"
fi

if [[ -d "$TEMP_DIR_T2FIT/$SUBJECT/$SESSION" ]]; then
    rm -rf "$TEMP_DIR_T2FIT/$SUBJECT/$SESSION"
    echo "Deleted: $TEMP_DIR_T2FIT/$SUBJECT/$SESSION"
fi

echo "Session cleanup completed successfully for ${SUBJECT}/${SESSION}"