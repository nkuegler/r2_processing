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
# USAGE:
#   slurm_bridge_gnlc_mese.sh "<GNLC_COMMAND>"
#
# ARGUMENTS:
#   GNLC_COMMAND - Complete GNLC command string to execute for MESE data
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH --time=30
#SBATCH --mem=1G

GNLC_CMD_MESE="$1"

echo "Bridge job: Waiting for denoising completion, then running MESE GNLC"
echo "Denoising job completed."

echo "Waiting 60 seconds to avoid overlap with AFI GNLC job..."
sleep 60 

echo "Running GNLC command:"
echo "$GNLC_CMD_MESE"

# Run GNLC command
$GNLC_CMD_MESE