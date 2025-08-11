#!/bin/bash
# Final cleanup script for T2 processing pipeline
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