#!/bin/bash
# Session cleanup script for T2 processing pipeline
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