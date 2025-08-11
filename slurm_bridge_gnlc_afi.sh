#!/bin/bash

#SBATCH --time=10
#SBATCH --mem=1G

GNLC_CMD_AFI="$1"

echo "Bridge job: Waiting for denoising completion, then running AFI GNLC"
echo "Denoising job completed, running GNLC command:"
echo "$GNLC_CMD_AFI"

# Run GNLC command
$GNLC_CMD_AFI