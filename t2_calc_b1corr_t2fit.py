#!/usr/bin/env python3

import pathlib as plib
import logging
import json

import numpy as np
import torch
from scipy.ndimage import gaussian_filter
import os
import shutil

logging.basicConfig(level=logging.INFO)


from pymritools.processing.denoising import extract_noise_mask
from pymritools.modeling.b1_afi import calculate_b1, calculate_error_map
from pymritools.config.database import DB
from pymritools.modeling.dictionary import r2_pattern_matching


import t2_calc_helper as helper
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
# parser.add_argument('--delete-workdir', '-rmwd', action='store_true',
#                     help='Delete the working directory after processing is complete')
parser.add_argument('--tr-ratio', '-trr', type=float, default=5.0,
                    help='TR ratio (TR2/TR1) for AFI B1 calculation (default: 5.0)')
parser.add_argument('--flip-angle', '-fa', type=float, default=55.0,
                    help='Flip angle of the AFI images in degrees (default: 55.0)')


args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = args.field_strength
trRatio = args.tr_ratio
fa = args.flip_angle


# Define paths based on arguments
parent_dir = plib.Path(f"{args.parent_dir}/{subj}/{sess}")
path_t2 = parent_dir.joinpath("anat/")
path_afi = parent_dir.joinpath("fmap/")

# Define output directory
output_dir = plib.Path(f"{args.output_dir}/{subj}/{sess}/anat/")
output_dir.mkdir(exist_ok=True, parents=True)

# Set working directory: use provided work_dir or create Supplementary in output_dir
if args.work_dir:
    working_dir = plib.Path(f"{args.work_dir}/{subj}/{sess}")
else:
    working_dir = output_dir.joinpath("Supplementary/")

# create temporary directory for results
working_dir.mkdir(exist_ok=True, parents=True)
working_dir_vis = working_dir.joinpath("figs/")
working_dir_vis.mkdir(exist_ok=True, parents=True)

### settings T2 fitting
path_db = plib.Path("/data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/emc/emc_database_7T_semc_0p6.pkl")



############################################


### GRADIENT NONLINEARITY CORRECTION

# TODO

ValueError("Gradient nonlinearity correction not implemented yet, skipping this step.")
exit

### B1+ CORRECTION


# reload gradient nonlinearity corrected images
afi_gnlc, afi_img_gnlc, afi_gnlc_aff, _ = \
    helper.load_nifti_as_tensor(input_path=working_dir, 
                                filename="afi_4d_desc-undistortedJac_TB1AFI")

mese_denoise_nbc_gnlc, mese_denoise_nbc_gnlc_img, mese_gnlc_aff, fn_mese4d_proc = \
    helper.load_nifti_as_tensor(input_path=working_dir, 
                                filename="mese_data_denoised_desc-undistortedJac_nbc")
nx, ny, nz, ne = mese_denoise_nbc_gnlc.shape


# extract noise voxels from the data again (this should neglect residual recon artefacts) 
# use original not resampled data
# a) its quicker
# b) resampling can change noise distribution
noise_mask_afi = extract_noise_mask(input_data=afi_gnlc, erode_iter=0)


# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                       filename="afi_noise_mask", 
                       data=noise_mask_afi.to(torch.int32), 
                       affine=afi_gnlc_aff)


# calculate B1 maps from the AFI images
b1 = calculate_b1(
    b1_data=afi_gnlc, r_tr21=trRatio, flip_angle_set_deg=fa, smoothing_kernel=3
)
b1_err = calculate_error_map(
    b1_data=afi_gnlc, mask=noise_mask_afi, flip_angle_set_deg=fa, path_visuals=working_dir
)

# calculate a relative error map
b1_rel_err = np.divide(
    b1_err.numpy(), b1.numpy(), where=b1.numpy() > 1e-9, out=np.zeros_like(b1.numpy())) * 100
# catch exploding values
b1_rel_err = np.clip(b1_rel_err, 0, 200)


print(f"b1 values (%): {b1.min():.2f}, {b1.max():.2f}")
# we want to make b1 a unitless value, no more percentages anymore
b1_unitless = b1 / 100
print(f"b1 values (unitless): {b1_unitless.min():.2f}, {b1_unitless.max():.2f}")


# we can save this for reference
fn_afib1 = helper.save_nifti(output_path=working_dir, 
                             filename="afi_b1", 
                             data=b1_unitless, 
                             affine=afi_gnlc_aff)

fn_afib1err = helper.save_nifti(output_path=working_dir, 
                             filename="afi_b1_rel_err", 
                             data=b1_rel_err, 
                             affine=afi_gnlc_aff)


# once again we want some resampled version brought into the semc image space, we can use linear interpolation here since the b1 and the rel error maps are assumed to vary smoothly

# resample the AFI_B1 data to the MESE space using a ANTS
print("Resample AFI_B1 to MESE space")
basename_afib1_resampled = "afi_b1_resampled"
fn_afib1_resampled = working_dir.joinpath(basename_afib1_resampled).with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
cmd = [
    "/data/u_kuegler_software/git/r2_map_calculation/resample_afi_3D.sh",
    str(working_dir),
    fn_afib1.name,
    fn_mese4d_proc.name,
    fn_afib1_resampled.name,
    interpolation_mode
]
os.system(" ".join(cmd))
print("-------------------------")


# resample the AFI_B1 relative error data to the MESE space using a ANTS
print("Resample AFI_B1_rel_err to MESE space")
basename_afib1err_resampled = "afi_b1_rel_err_resampled"
fn_afib1err_resampled = working_dir.joinpath(basename_afib1err_resampled).with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
cmd = [
    "/data/u_kuegler_software/git/r2_map_calculation/resample_afi_3D.sh",
    str(working_dir),
    fn_afib1err.name,
    fn_mese4d_proc.name,
    fn_afib1err_resampled.name,
    interpolation_mode
]
os.system(" ".join(cmd))
print("-------------------------")


b1_re, b1_re_img, b1_re_aff, _ = \
    helper.load_nifti_as_tensor(input_path=working_dir, 
                                filename=basename_afib1_resampled)

b1_rel_err_re, _, _, _ = \
    helper.load_nifti_as_tensor(input_path=working_dir,
                                filename=basename_afib1err_resampled)



### T2 FITTING

# load the lookup dictionary
db = DB.load(path_db)
# get torch tensors
# make sure that you have checked out the correct commit of pymritools 
# (otherwise the get_torch_tensors_t1t2b1e() function may raise an error)
db_torch_mag, db_torch_phase = db.get_torch_tensors_t1t2b1e()

# normalize database, use magnitude only for now
db_mag_norm = torch.linalg.norm(db_torch_mag, dim=-1, keepdim=True)
db_torch_mag /= db_mag_norm
# get t2 and b1 values that have been simulated
t1_vals, t2_vals, b1_vals = db.get_t1_t2_b1_values()

# normalize mese data
mese_data_norm = torch.linalg.norm(mese_denoise_nbc_gnlc, dim=-1, keepdim=True)
mese_data_normalized = torch.nan_to_num(
    torch.divide(mese_denoise_nbc_gnlc, mese_data_norm), nan=0.0, posinf=0.0, neginf=0.0
).contiguous()

# We do a poor mans b1 regularization.
# First run we extract the b1 map the pattern matching would optimize for without providing the afi input
t2_emc, b1_emc, _ = r2_pattern_matching(
    input_data=mese_data_normalized, 
    db_mag=db_torch_mag, 
    t2_vals=t2_vals, b1_vals=b1_vals, t1_vals=t1_vals, b1_data=None,
    batch_size=2000, 
    device=torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu"),
)

b1_emc = torch.from_numpy(gaussian_filter(b1_emc.numpy(), sigma=5))


# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                      filename="b1_emc", 
                      data=b1_emc, 
                      affine=mese_gnlc_aff)

r2_emc = torch.nan_to_num( \
            torch.divide(torch.ones_like(t2_emc), t2_emc), 
            nan=0.0, 
            posinf=0.0, 
            neginf=0.0)

_ = helper.save_nifti(output_path=working_dir, 
                      filename="r2_emc", 
                      data=r2_emc, 
                      affine=mese_gnlc_aff)

# Now we want to use the AFI B1 estimate and 
# the calculated afi error maps to calculate 
# a combined B1 regularization map.

# we allow for max 10 % relative error in the afi 
# and do a linear weighting between afi b1 and emc b1, 
# essentially if rel afi error is 0 we trust the afi, 
# if relative error of afi is 10% we trust the emc
regularization_factor = 1 - torch.clip(b1_rel_err_re, 0, 10) / 10
b1_reg = regularization_factor * b1_re + (1 - regularization_factor) * b1_emc
b1_reg = torch.from_numpy(gaussian_filter(b1_reg.numpy(), sigma=2))


# we can save this for reference
_ = helper.save_nifti(output_path=working_dir, 
                      filename="b1_reg", 
                      data=b1_reg, 
                      affine=b1_re_aff)

# We now redo the fitting with inputting the b1 regularization. 
# This way the algorithm is not simultaneously optimizing 
# for t2 and b1 but only needs to match the pattern wrt t2.

t2, b1_reg_fit, l2_min_err = r2_pattern_matching(
    input_data=mese_data_normalized, 
    db_mag=db_torch_mag, 
    t2_vals=t2_vals, b1_vals=b1_vals, t1_vals=t1_vals, b1_data=b1_reg,
    batch_size=2000, 
    device=torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu"),
)


# want to get r2
div_mask = t2 > 1e-9
r2 = torch.zeros_like(t2)
r2[div_mask] = torch.divide(torch.ones_like(r2[div_mask]), t2[div_mask])
# want to get a rough snr estimate, dividing mese max value with noise mean value
# Load noise statistics
noise_stats_file = working_dir.joinpath("mese_noise_stats.json")
if noise_stats_file.exists():
    with open(noise_stats_file, 'r') as f:
        noise_stats = json.load(f)
    mese_noise_mean = noise_stats['mese_noise_mean']
    print(f"Loaded noise mean: {mese_noise_mean}")
else:
    raise FileNotFoundError(f"Noise statistics file not found: {noise_stats_file}")

fit_data_reg_snr = torch.max(mese_denoise_nbc_gnlc, dim=-1).values / mese_noise_mean
# make a threshold map for voxel below 5
fit_data_reg_snr_th = (fit_data_reg_snr < 5).to(torch.int32)


# we can save this for reference
_ = helper.save_nifti(output_path=output_dir,
                      filename=f"{subj}_{sess}_R2map",
                      data=r2,
                      affine=mese_gnlc_aff)

_ = helper.save_nifti(output_path=output_dir,
                      filename=f"{subj}_{sess}_T2map",
                      data=t2,
                      affine=mese_gnlc_aff)

_ = helper.save_nifti(output_path=working_dir,
                      filename=f"{subj}_{sess}_TB1map",
                      data=b1_reg_fit,
                      affine=b1_re_aff)

_ = helper.save_nifti(output_path=working_dir,
                      filename="fit_data_reg_snr",
                      data=fit_data_reg_snr,
                      affine=mese_gnlc_aff)

_ = helper.save_nifti(output_path=working_dir,
                      filename="fit_data_reg_snr_thr",
                      data=fit_data_reg_snr_th,
                      affine=mese_gnlc_aff)

# # Now handled in the main bash script
# # Clean up working directory if requested
# if args.delete_workdir:
#     print(f"Deleting working directory: {working_dir}")
#     shutil.rmtree(working_dir)
#     print("Working directory deleted successfully")

