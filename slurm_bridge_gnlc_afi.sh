#!/bin/bash

# ==============================================================================
# SLURM Bridge Script - AFI Gradient Non-linearity Correction
# ==============================================================================
#
# DESCRIPTION:
#   Bridge script that executes gradient nonlinearity correction (GNLC) of the AFI data.
#   Executes the provided GNLC command.
#   The script is used to manage the dependencies between jobs in the SLURM queue.
#
# USAGE:
#   slurm_bridge_gnlc_afi.sh "<GNLC_COMMAND>"
#
# ARGUMENTS:
#   GNLC_COMMAND - Complete GNLC command string to execute for AFI data
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

#SBATCH --time=10
#SBATCH --mem=1G

GNLC_CMD_AFI="$1"

echo "Bridge job: Waiting for denoising completion, then running AFI GNLC"
echo "Denoising job completed, running GNLC command:"
echo "$GNLC_CMD_AFI"

# Run GNLC command
$GNLC_CMD_AFI