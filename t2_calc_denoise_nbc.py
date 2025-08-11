#!/usr/bin/env python3

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

args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = args.field_strength


# Define paths based on arguments
parent_dir = plib.Path(f"{args.parent_dir}/{subj}/{sess}")
t2_dir = parent_dir.joinpath("anat/")
afi_dir = parent_dir.joinpath("fmap/")

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
    str(script_dir / "resample_afi_4D.sh"),
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
noise_mask = extract_noise_mask(input_data=mese_4d, erode_iter=1)
mese_noise_mean = torch.mean(mese_4d[noise_mask])


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