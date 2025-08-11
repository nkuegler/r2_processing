#!/bin/bash

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