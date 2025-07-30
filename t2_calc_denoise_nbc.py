#!/usr/bin/env python3

import pathlib as plib
import logging
import json
from datetime import datetime

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
import argparse

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
parser.add_argument('--work-dir', '-w', type=str, required=False,
                    help='Working directory path for temporary files (optional, defaults to Supplementary/ directory in output directory of each session)')
parser.add_argument('--output-dir', '-o', type=str, required=True,
                    help='Output directory path for final results (e.g., /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2)')

args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = args.field_strength


# Define paths based on arguments
parent_dir = plib.Path(f"{args.parent_dir}/{subj}/{sess}")
path_t2 = parent_dir.joinpath("anat/")
path_afi = parent_dir.joinpath("fmap/")

# Define output directory
output_dir = plib.Path(f"{args.output_dir}/{subj}/{sess}/anat/")
output_dir.mkdir(exist_ok=True, parents=True)

# Set working directory: use provided work_dir 
# or create Supplementary in output_dir
if args.work_dir:
    working_dir = plib.Path(f"{args.work_dir}/{subj}/{sess}")
else:
    working_dir = output_dir.joinpath("Supplementary/")

# create temporary directory for results
working_dir.mkdir(exist_ok=True, parents=True)
working_dir_vis = working_dir.joinpath("figs/")
working_dir_vis.mkdir(exist_ok=True, parents=True)

############################################

# get mese files
files_t2 = sorted([f for f in path_t2.iterdir() 
                   if f.is_file() and 
                   ".nii" in f.suffixes and 
                   "MESE" in f.stem])
print(f"found t2 files: ")
for f in files_t2:
    print(f"\t\t{f.name}")
# get afi files
files_afi = sorted([f for f in path_afi.iterdir() 
                    if f.is_file() and 
                    ".nii" in f.suffixes and 
                    "stx" in f.stem and 
                    "AFI" in f.stem])
print(f"found afi files: ")
for f in files_afi:
    print(f"\t\t{f.name}")


# want them to be in one 4D volume - could also do this prior via e.g. fslmerge -t
# MESE
mese_aff = nib.load(files_t2[0]).affine
mese_4d = torch.from_numpy( \
    np.array([nib.load(f).get_fdata() for f in files_t2]))
# want dims to be [nx, ny, nz, ne]
mese_4d = torch.movedim(mese_4d, 0, -1)
mese_img = nib.Nifti1Image(mese_4d.numpy(), mese_aff)
nx, ny, nz, ne = mese_4d.shape

# AFI
afi_aff = nib.load(files_afi[0]).affine
afi_data = torch.from_numpy( \
    np.array([nib.load(f).get_fdata() for f in files_afi]))
afi_data = torch.movedim(afi_data, 0, -1)
afi_img = nib.Nifti1Image(afi_data.numpy(), afi_aff)


# at this point we could save the combined volume if wanted
fn_mese4d = helper.save_nifti(output_path=working_dir, 
                              filename="mese_4d_mag", 
                              data=mese_4d, 
                              affine=mese_aff)

fn_afi4d = helper.save_nifti(output_path=working_dir, 
                             filename="afi_4d", 
                             data=afi_data, 
                             affine=afi_aff)

# resample the AFI data to the MESE space using a ANTS
print("Resample AFI to MESE space")
fn_afi4d_resampled = \
    working_dir.joinpath("afi_4d_resampled").with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
cmd = [
    "/data/u_kuegler_software/git/r2_map_calculation/resample_afi_4D.sh",
    str(working_dir),
    fn_afi4d.name,
    fn_mese4d.name,
    fn_afi4d_resampled.name,
    interpolation_mode
]
os.system(" ".join(cmd))

# reload resampled image
fn = working_dir.joinpath("afi_4d_resampled").with_suffix(".nii")
print(f"load file: {fn}")
afi_re_img = nib.load(fn)
afi_re_data = torch.from_numpy(afi_re_img.get_fdata())


# just a quick look for reference if needed
plot_helper.plot_mese4d_afi4dRe(mese_4d, 
                                afi_data,
                                afi_re_data,
                                path_figs=working_dir_vis,
                                fig_title="mese_4d_mag_afi_4d_re")

### DENOISING

# assumes torch tensor input
denoised_data, _, _ = denoise_mppca(input_data=mese_4d, p=1, device=torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu"))

# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                       filename="mese_4d_denoised", 
                       data=denoised_data, 
                       affine=mese_aff)


### NOISE BIAS CORRECTION

# extract noise voxels from the data (this should neglect residual grappa recon artifacts)
noise_mask = extract_noise_mask(input_data=mese_4d, erode_iter=1)
mese_noise_mean = torch.mean(mese_4d[noise_mask])


# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                       filename="mese_noise_mask", 
                       data=noise_mask.to(torch.int32), 
                       affine=mese_aff)

# just a quick look for reference if needed
plot_helper.plot_mese_noise_mask(mese_4d, 
                                 noise_mask, 
                                 path_figs=working_dir_vis, 
                                 fig_title="mese_noise_mask")


# extract noise stats - give visual path if we want to save the figure
sigma, num_channels = extract_noise_stats_from_mask(input_data=mese_4d, mask=noise_mask, path_visuals=working_dir_vis, )

# Save noise statistics as JSON for use in other scripts
noise_stats = {
    'mese_noise_mean': float(mese_noise_mean),
    'sigma': float(sigma),
    'num_channels': int(num_channels),
    'subject': subj,
    'session': sess,
    'magnetic_field': magnetic_field,
    'calculated_at': datetime.now().isoformat(),
    'data_shape': list(mese_4d.shape),
    'noise_mask_voxels': int(torch.sum(noise_mask))
}
mese_noise_stats_file = working_dir.joinpath("mese_noise_stats.json")
with open(mese_noise_stats_file, 'w') as f:
    json.dump(noise_stats, f, indent=2)
print(f"Saved MESE noise statistics to: {mese_noise_stats_file}")


# do noise bias correction on denoised data
denoised_mese_nbc = noise_bias_correction(
    denoised_data=denoised_data, sigma=sigma, num_channels=num_channels
)

# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                       filename="mese_4d_denoised_nbc", 
                       data=denoised_mese_nbc, 
                       affine=mese_aff)


# just a quick look for reference if needed
plot_helper.plot_mese_denoised_data( \
    mese_4d,
    denoised_data, 
    denoised_mese_nbc, 
    path_figs=working_dir_vis, 
    fig_title="mese_denoised_data"
)