#!/usr/bin/env python3

"""
==============================================================================
Denoising and Noise Bias Correction Script
==============================================================================

DESCRIPTION:
    This script performs denoising and noise bias correction on
    MESE data for a single subject/session using PyMRItools (https://github.com/schmidt-jo/PyMRItools). 
    The script applies MP-PCA denoising followed by noise bias correction to improve signal
    quality for subsequent T2 fitting. It handles both 7T (automatic noise masking)
    and 3T (manual noise masking) data processing workflows.

USAGE:
    python t2_calc_denoise_nbc.py [OPTIONS]

REQUIRED ARGUMENTS:
    --subject, -s           Subject identifier (e.g., sub-004)
    --session, -ses         Session identifier (e.g., ses-04)
    --field-strength, -b0   Magnetic field strength in Tesla (3.0 or 7.0)
    --parent-dir, -p        Parent BIDS directory containing raw data
    --output-dir, -o        Output directory for processed results

OPTIONAL ARGUMENTS:
    --noise-mask-dir, -noiseMaskdir  Directory containing manual noise mask files 
                                     (required for 3T data, not used for 7T)

OPERATIONS PERFORMED:
    1. Loading and concatenation of MESE and AFI acquisitions into 4D volumes
    2. AFI resampling to MESE acquisition space using ANTs (for visualization only)
    3. MP-PCA denoising of MESE acquisitions
    4. Noise mask extraction (automatic for 7T, must be drawn manually for 3T)
    5. Noise statistics calculation for bias correction parameters
    6. Noise bias correction
    7. Visualization for quality control

EXAMPLE:
    # For 7T data (automatic noise masking):
    python t2_calc_denoise_nbc.py \\
        --subject sub-001 --session ses-01 --field-strength 7 \\
        --parent-dir /bids/input --output-dir /output/denoise
    
    # For 3T data (manual noise masking required):
    python t2_calc_denoise_nbc.py \\
        --subject sub-001 --session ses-01 --field-strength 3 \\
        --parent-dir /bids/input --output-dir /output/denoise \\
        --noise-mask-dir /masks/manual

NOTES:
    - Requires PyMRItools (https://github.com/schmidt-jo/PyMRItools) checked out at the commit 7d29483
    - Automatic noise mask extraction using autodmri for 7T data
    - Manual noise masks required for 3T data (must NOT contain aliasing artifacts introduced by GRAPPA)
        - Noise mask format: binary NIfTI file matching MESE echo-01 dimensions
        - Expected filename format: {subject}_{session}_acq-semc_echo-01_MESE_noiseMaskManual.nii
    - GPU acceleration automatically used if CUDA is available
    - Quality control plots saved as HTML files
    - Noise statistics saved as JSON for downstream processing

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
==============================================================================
"""

import pathlib as plib
import logging
import json
import re
import argparse


import nibabel as nib
import numpy as np
import torch
from scipy.ndimage import gaussian_filter
import os

logging.basicConfig(level=logging.INFO)

from pymritools.processing.denoising import denoise_mppca
from pymritools.processing.denoising import extract_noise_mask, extract_noise_stats_from_mask, noise_bias_correction

import t2_calc_helper as helper
import t2_calc_helper_plot as plot_helper

### SETUP

### setting data

# Parse command line arguments
parser = argparse.ArgumentParser(description='T2 calculation with B1 correction')
parser.add_argument('--subject', '-s', type=str, required=True, 
                    help='Subject ID (e.g., sub-004)')
parser.add_argument('--session', '-ses', type=str, required=True, 
                    help='Session ID (e.g., ses-04)')
parser.add_argument('--field-strength', '-b0', type=float, required=True, 
                    help='Magnetic field strength in Tesla (e.g., 7)')
parser.add_argument('--parent-dir', '-p', type=str, required=True,
                    help='Parent directory path (e.g., /data/pt_02262/data/TH_bids/bids)')
parser.add_argument('--output-dir', '-o', type=str, required=True,
                    help='Output directory path for final results (e.g., /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2)')
parser.add_argument('--noise-mask-dir', '-noiseMaskdir', type=str, required=False,
                    help='Directory path containing manually drawn noise mask files (required for 3T data, not used for other field strengths)')

args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = float(args.field_strength)

# Validate that noise mask directory is provided for 3T data
if magnetic_field == 3.0 and args.noise_mask_dir is None:
    parser.error("--noise-mask-dir is required when field strength is 3T")


# Define paths based on arguments
parent_dir = plib.Path(f"{args.parent_dir}/{subj}/{sess}")
t2_dir = parent_dir.joinpath("anat/")
afi_dir = parent_dir.joinpath("fmap/")

# Define noise mask directory (only if provided)
manualNoiseMask_dir = plib.Path(args.noise_mask_dir) if args.noise_mask_dir else None

# Define output directory
output_dir = plib.Path(f"{args.output_dir}/{subj}/{sess}/anat/")
output_dir.mkdir(exist_ok=True, parents=True)

output_dir_vis = output_dir.joinpath("figs/")
output_dir_vis.mkdir(exist_ok=True, parents=True)

############################################

mese_suffix = "MESE"
afi_suffix = "TB1AFI"

# get mese files
files_t2 = sorted([f for f in t2_dir.iterdir() 
                   if f.is_file() and 
                   ".nii" in f.suffixes and 
                   f.stem.endswith(mese_suffix)])
print(f"found t2 files: ")
for f in files_t2:
    print(f"\t\t{f.name}")
fname_mese_orig = files_t2[0].with_suffix('').stem

# get afi files
files_afi = sorted([f for f in afi_dir.iterdir() 
                    if f.is_file() and 
                    ".nii" in f.suffixes and 
                    "stx" in f.stem and 
                    f.stem.endswith(afi_suffix)])
print(f"found afi files: ")
for f in files_afi:
    print(f"\t\t{f.name}")
fname_afi_orig = files_afi[0].with_suffix('').stem


# want them to be in one 4D volume - could also do this prior via e.g. fslmerge -t
# MESE
mese_aff = nib.load(files_t2[0]).affine
mese_hdr = nib.load(files_t2[0]).header
# Extract description from header
descrip_array = mese_hdr.get('descrip', b'')
if descrip_array is not None and np.size(descrip_array) > 0:
    mese_description = descrip_array.item().decode('utf-8') if isinstance(descrip_array.item(), bytes) else str(descrip_array.item())
else:
    mese_description = ''
mese_4d = torch.from_numpy( \
    np.array([nib.load(f).get_fdata() for f in files_t2]))
# want dims to be [nx, ny, nz, ne]
mese_4d = torch.movedim(mese_4d, 0, -1)
nx, ny, nz, ne = mese_4d.shape

# AFI
afi_aff = nib.load(files_afi[0]).affine
afi_hdr = nib.load(files_afi[0]).header
afi_data = torch.from_numpy( \
    np.array([nib.load(f).get_fdata() for f in files_afi]))
afi_data = torch.movedim(afi_data, 0, -1)


# at this point we could save the combined volume if wanted
# Replace the acq- entity by adding 4D to the original (match only until next underscore)
fname_mese_4d = re.sub(r'(_acq-[^_]+)', r'\g<1>4D', fname_mese_orig)
path_mese4d = helper.save_nifti(output_path=output_dir, 
                              filename=fname_mese_4d, 
                              data=mese_4d, 
                              affine=mese_aff,
                              header=mese_hdr)
# Copy the MESE JSON file
mese_json_source = t2_dir.joinpath(fname_mese_orig).with_suffix(".json")
mese_json_dest = output_dir.joinpath(fname_mese_4d).with_suffix(".json")
helper.copy_corresponding_json(mese_json_source, mese_json_dest)

# For AFI, strip numbers from the acquisition entity and add 4D
fname_afi_4d = f"{subj}_{sess}_acq-stx4D_{afi_suffix}"
# fname_afi_4d = f"{subj}_{sess}_acq-stx4D_forMESE_{afi_suffix}"
path_afi4d = helper.save_nifti(output_path=output_dir, 
                             filename=fname_afi_4d, 
                             data=afi_data, 
                             affine=afi_aff,
                             header=afi_hdr)
# Copy the AFI JSON file
afi_json_source = afi_dir.joinpath(fname_afi_orig).with_suffix(".json")
afi_json_dest = output_dir.joinpath(fname_afi_4d).with_suffix(".json")
helper.copy_corresponding_json(afi_json_source, afi_json_dest)

# resample the AFI data to the MESE space using a ANTS
print("Resample AFI to MESE space")
fname_afi_4d_resampled = fname_afi_4d.replace(afi_suffix, f"proc-resampled_{afi_suffix}")
path_afi4d_resampled = output_dir.joinpath(fname_afi_4d_resampled).with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
script_dir = plib.Path(__file__).parent
cmd = [
    str(script_dir / "resample_4D.sh"),
    str(path_afi4d),
    str(path_mese4d),
    str(path_afi4d_resampled),
    interpolation_mode
]
os.system(" ".join(cmd))

# reload resampled image
afi_re_data, afi_re_img, _, _, _ = \
    helper.load_nifti_as_tensor(input_path=output_dir, 
                                filename=fname_afi_4d_resampled)


# just a quick look for reference if needed
plot_helper.plot_mese4d_afi4dRe(mese_4d, 
                                afi_data,
                                afi_re_data,
                                path_figs=output_dir_vis,
                                fig_title="mese_4d_mag_afi_4d_resampled",)

### DENOISING

# assumes torch tensor input
denoised_data, _, _ = denoise_mppca(input_data=mese_4d, p=1, device=torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu"))

# we can save this for reference
fname_mese_4d_denoised = fname_mese_4d.replace(mese_suffix, f"proc-denoised_{mese_suffix}")
_ = helper.save_nifti(output_path=output_dir, 
                       filename=fname_mese_4d_denoised, 
                       data=denoised_data, 
                       affine=mese_aff,
                       header=mese_hdr,
                       description=f"Denoised; {mese_description}")
# Copy the MESE JSON file
mese_json_source = t2_dir.joinpath(fname_mese_orig).with_suffix(".json")
mese_json_dest = output_dir.joinpath(fname_mese_4d_denoised).with_suffix(".json")
helper.copy_corresponding_json(mese_json_source, mese_json_dest)


### NOISE BIAS CORRECTION

# extract noise voxels from the data (this should neglect residual grappa recon artifacts)
if magnetic_field == 7.0:
    noise_mask = extract_noise_mask(input_data=mese_4d, erode_iter=1)
    mese_noise_mean = torch.mean(mese_4d[noise_mask])
elif magnetic_field == 3.0:
    # created noise mask for MESE data echo 1 -> load (should not include aliasing artifacts introduced by grappa)
    fname_man_noise_mask = f"{subj}_{sess}_acq-semc_echo-01_MESE_noiseMaskManual"
    expected_file_path = manualNoiseMask_dir / f"{fname_man_noise_mask}.nii"
    
    # Check if the manual noise mask file exists
    if not expected_file_path.exists():
        raise FileNotFoundError(
            f"Manual noise mask file not found: {expected_file_path}\n\n"
            f"For 3T data processing, you need to manually draw a noise mask and save it as:\n"
            f"  {expected_file_path}\n\n"
            f"Instructions for creating the noise mask:\n"
            f"1. Open the first echo of the MESE sequence in your favorite image viewer\n"
            f"2. The mask should contain only noise regions OUTSIDE of the head\n"
            f"3. Avoid including aliasing artifacts that may be introduced by GRAPPA\n"
            f"4. Save the mask as a binary NIfTI file (.nii format)\n"
            f"5. Ensure the mask has the same spatial dimensions as one echo of your MESE data\n\n"
            f"Please create this file and run the script again."
        )

    # Load the manually drawn noise mask
    noise_mask, noise_mask_img, _, _, _ = \
        helper.load_nifti_as_tensor(input_path=manualNoiseMask_dir, 
                                    filename=fname_man_noise_mask)
    # Stack the noise mask along a new dimension to match the number of echoes in MESE data
    noise_mask = noise_mask.unsqueeze(-1).expand(-1, -1, -1, ne)
    mese_noise_mean = torch.mean(mese_4d[noise_mask.to(torch.bool)])
else:
    raise ValueError(f"Unsupported magnetic field strength: {magnetic_field}. Supported values are 3.0 and 7.0 Tesla.")


# we can save this for reference
fname_mese_4d_noise_mask = f"{fname_mese_4d}_noiseMask"
_ = helper.save_nifti(output_path=output_dir, 
                       filename=fname_mese_4d_noise_mask, 
                       data=noise_mask.to(torch.int32), 
                       affine=mese_aff,
                       header=mese_hdr,
                       description=f"{fname_mese_4d} noise mask with {torch.sum(noise_mask)} vox")


# just a quick look for reference if needed
plot_helper.plot_mese_noise_mask(mese_4d, 
                                 noise_mask, 
                                 path_figs=output_dir_vis, 
                                 fig_title="mese_noise_mask")


# extract noise stats - give visual path if we want to save the figure
sigma, num_channels = extract_noise_stats_from_mask(input_data=mese_4d, mask=noise_mask, path_visuals=output_dir_vis, )

# Save noise statistics as JSON for use in other scripts
noise_stats = {
    'mese_noise_mean': float(mese_noise_mean),
    'sigma': float(sigma),
    'num_channels': int(num_channels),
    'subject': subj,
    'session': sess,
    'magnetic_field': magnetic_field,
    'calculated_at': helper.get_timestamp(),
    'data_shape': list(mese_4d.shape),
    'noise_mask_voxels': int(torch.sum(noise_mask))
}
mese_noise_stats_file = output_dir.joinpath(f"{subj}_{sess}_mese_noise_stats.json")
with open(mese_noise_stats_file, 'w') as f:
    json.dump(noise_stats, f, indent=2)
print(f"Saved MESE noise statistics to: {mese_noise_stats_file}")


# do noise bias correction on denoised data
denoised_mese_nbc = noise_bias_correction(
    denoised_data=denoised_data, sigma=sigma, num_channels=num_channels
)

# we can save this for reference
fname_mese_4d_denoised_nbc = fname_mese_4d_denoised.replace(f"_proc-denoised", f"_proc-denoisedNbc")
_ = helper.save_nifti(output_path=output_dir, 
                       filename=fname_mese_4d_denoised_nbc, 
                       data=denoised_mese_nbc, 
                       affine=mese_aff,
                       header=mese_hdr,
                       description=f"Denoised + NoiseBiasCorrected; {mese_description}")
# Copy the MESE JSON file
mese_json_source = t2_dir.joinpath(fname_mese_orig).with_suffix(".json")
mese_json_dest = output_dir.joinpath(fname_mese_4d_denoised_nbc).with_suffix(".json")
helper.copy_corresponding_json(mese_json_source, mese_json_dest)


# just a quick look for reference if needed
plot_helper.plot_mese_denoised_data( \
    mese_4d,
    denoised_data, 
    denoised_mese_nbc, 
    path_figs=output_dir_vis, 
    fig_title="mese_denoised_data"
)