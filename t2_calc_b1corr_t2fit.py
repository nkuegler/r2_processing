#!/usr/bin/env python3

import pathlib as plib
import logging
import json
import argparse
import subprocess
import sys

import numpy as np
import torch
from scipy.ndimage import gaussian_filter
import os
import glob


logging.basicConfig(level=logging.INFO)


from pymritools.processing.denoising import extract_noise_mask
from pymritools.modeling.b1_afi import calculate_b1, calculate_error_map
from pymritools.config.database import DB
from pymritools.modeling.dictionary import r2_pattern_matching


import t2_calc_helper as helper

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
parser.add_argument('--work-dir', '-w', type=str, required=False,
                    help='Working directory path for temporary files (optional, defaults to Supplementary/ directory in output directory of each session)')
parser.add_argument('--input-dir', '-i', type=str, required=True,
                    help='Input directory path containing source data')
parser.add_argument('--output-dir', '-o', type=str, required=True,
                    help='Output directory path for final results')
parser.add_argument('--tr-ratio', '-trr', type=float, default=5.0,
                    help='TR ratio (TR2/TR1) for AFI B1 calculation (default: 5.0)')
parser.add_argument('--flip-angle', '-fa', type=float, default=55.0,
                    help='Flip angle of the AFI images in degrees (default: 55.0)')
parser.add_argument('--denoise-dir', '-denDir', type=str, required=True,
                    help='Directory path containing denoised data')


args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = args.field_strength
trRatio = args.tr_ratio
fa = args.flip_angle

# Define input directory
input_dir = plib.Path(f"{args.input_dir}/{subj}/{sess}/anat/")
if not input_dir.exists():
    raise FileNotFoundError(f"Input directory does not exist: {input_dir}")

# Set working directory: use provided work_dir or create Supplementary/ in output_dir
if args.work_dir:
    working_dir = plib.Path(f"{args.work_dir}/{subj}/{sess}/anat/")
else:
    working_dir = plib.Path(f"{args.output_dir}/Supplementary/{subj}/{sess}/anat/")

# Define output directory
target_output_dir = plib.Path(f"{args.output_dir}/{subj}/{sess}/anat/")

# Check if denoise directory exists if specified
denoise_dir = plib.Path(f"{args.denoise_dir}/{subj}/{sess}/anat/")
if not denoise_dir.exists():
    raise FileNotFoundError(f"Denoise directory does not exist: {denoise_dir}.")

# Create directories
target_output_dir.mkdir(exist_ok=True, parents=True)

working_dir.mkdir(exist_ok=True, parents=True)
working_dir_vis = working_dir.joinpath("figs/")
working_dir_vis.mkdir(exist_ok=True, parents=True)

### settings T2 fitting
if magnetic_field == 7.0:
    path_db = plib.Path("/data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/emc/emc_database_7T_semc_0p6.pkl")
elif magnetic_field == 3.0:
    path_db = plib.Path("/data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/emc/db_mese_3T_etl10.pkl")
else:
    raise ValueError(f"Unsupported magnetic field strength: {magnetic_field}. Supported values are 3.0 and 7.0 Tesla.")


############################################

mese_suffix = "MESE"
afi_suffix = "TB1AFI"
b1_suffix = "TB1map"
r2_suffix = "R2map"
t2_suffix = "T2map"

### B1+ CORRECTION

# reload gradient nonlinearity corrected images

fname_afi_pattern = f"{subj}_{sess}*_desc-undistortedJac_{afi_suffix}.nii"
afi_files = glob.glob(str(input_dir / fname_afi_pattern))
if not afi_files:
    raise FileNotFoundError(f"No AFI file found matching pattern: {fname_afi_pattern}")
if len(afi_files) > 1:
    logging.warning(f"Multiple AFI files found matching pattern: {fname_afi_pattern}. Using the first one.")
fname_afi_undistorted = plib.Path(afi_files[0]).with_suffix('').stem 
afi_gnlc, afi_img_gnlc, afi_gnlc_aff, afi_gnlc_hdr, path_afi_gnlc = \
    helper.load_nifti_as_tensor(input_path=input_dir, 
                                filename=fname_afi_undistorted)
# Extract description from header
descrip_array_afi = afi_gnlc_hdr.get('descrip', b'')
if descrip_array_afi is not None and np.size(descrip_array_afi) > 0:
    afi_gnlc_description = descrip_array_afi.item().decode('utf-8') if isinstance(descrip_array_afi.item(), bytes) else str(descrip_array_afi.item())
else:
    afi_gnlc_description = ''

fname_mese_pattern = f"{subj}_{sess}*_desc-undistortedJac_{mese_suffix}.nii"
mese_files = glob.glob(str(input_dir / fname_mese_pattern))
if not mese_files:
    raise FileNotFoundError(f"No MESE file found matching pattern: {fname_mese_pattern}")
if len(mese_files) > 1:
    logging.warning(f"Multiple MESE files found matching pattern: {fname_mese_pattern}. Using the first one.")
fname_mese_undistorted = plib.Path(mese_files[0]).with_suffix('').stem
mese_denoise_nbc_gnlc, mese_denoise_nbc_gnlc_img, mese_gnlc_aff, mese_gnlc_hdr, path_mese4d_proc = \
    helper.load_nifti_as_tensor(input_path=input_dir, 
                                filename=fname_mese_undistorted)
nx, ny, nz, ne = mese_denoise_nbc_gnlc.shape
# Extract description from header
descrip_array_mese = mese_gnlc_hdr.get('descrip', b'')
if descrip_array_mese is not None and np.size(descrip_array_mese) > 0:
    mese_proc_description = descrip_array_mese.item().decode('utf-8') if isinstance(descrip_array_mese.item(), bytes) else str(descrip_array_mese.item())
else:
    mese_proc_description = ''

# Clear description arrays to free memory
del descrip_array_afi, descrip_array_mese

# extract noise voxels from the data again (this should neglect residual recon artefacts) 
# use original not resampled data
# a) its quicker
# b) resampling can change noise distribution
noise_mask_afi = extract_noise_mask(input_data=afi_gnlc, erode_iter=0)


# we can save this for reference
fname_afi_noise_mask = f"{fname_afi_undistorted}_noiseMask"
_ = helper.save_nifti(output_path=working_dir, 
                       filename=fname_afi_noise_mask, 
                       data=noise_mask_afi.to(torch.int32), 
                       affine=afi_gnlc_aff,
                       header=afi_gnlc_hdr,
                       description=f"{fname_afi_undistorted} noise mask with {torch.sum(noise_mask_afi)} vox, {helper.get_timestamp()}")


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
fname_afib1 = fname_afi_undistorted.replace(afi_suffix, b1_suffix)
path_afib1 = helper.save_nifti(output_path=working_dir, 
                             filename=fname_afib1, 
                             data=b1_unitless, 
                             affine=afi_gnlc_aff, 
                             header=afi_gnlc_hdr,
                             description=f"B1+ map from {fname_afi_undistorted}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_afi_gnlc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_afib1).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest

fname_afib1_rel_err = f"{fname_afib1}_rel_err"
path_afib1err = helper.save_nifti(output_path=working_dir, 
                             filename=fname_afib1_rel_err, 
                             data=torch.from_numpy(b1_rel_err), 
                             affine=afi_gnlc_aff,
                             header=afi_gnlc_hdr,
                             description=f"B1+ relative error map from {fname_afi_undistorted}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_afi_gnlc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_afib1_rel_err).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest

# once again we want some resampled version brought into the semc image space, we can use linear interpolation here since the b1 and the rel error maps are assumed to vary smoothly

script_dir = plib.Path(__file__).parent

# resample the AFI_B1 data to the MESE space using a ANTS
print("Resample AFI_B1 to MESE space", flush=True)
fname_afib1_resampled = fname_afib1.replace(b1_suffix, f"proc-resampled_{b1_suffix}")
path_afib1_resampled = working_dir.joinpath(fname_afib1_resampled).with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
cmd = [
    str(script_dir / "resample_afi_3D.sh"),
    str(path_afib1),
    str(path_mese4d_proc),
    str(path_afib1_resampled),
    interpolation_mode
]
# os.system(" ".join(cmd))
result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(result.stdout, flush=True)
if result.returncode != 0:
    print(f"Error during resampling B1: {result.stdout}", file=sys.stderr, flush=True)

print("-------------------------", flush=True)


# resample the AFI_B1 relative error data to the MESE space using a ANTS
print("Resample AFI_B1_rel_err to MESE space", flush=True)
fname_afib1err_resampled = fname_afib1_rel_err.replace(b1_suffix, f"proc-resampled_{b1_suffix}")
path_afib1err_resampled = working_dir.joinpath(fname_afib1err_resampled).with_suffix(".nii")
interpolation_mode = "Linear" # "Linear" # "NearestNeighbor" # "BSpline" # BSpline seems to cause issues
cmd = [
    str(script_dir / "resample_afi_3D.sh"),
    str(path_afib1err),
    str(path_mese4d_proc),
    str(path_afib1err_resampled),
    interpolation_mode
]
# os.system(" ".join(cmd))
result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(result.stdout, flush=True)
if result.returncode != 0:
    print(f"Error during resampling B1_rel_err: {result.stdout}", file=sys.stderr, flush=True)
print("-------------------------", flush=True)


b1_afi_re, b1_afi_re_img, b1_afi_re_aff, b1_afi_re_hdr, _ = \
    helper.load_nifti_as_tensor(input_path=working_dir, 
                                filename=fname_afib1_resampled)

b1_afi_re_rel_err, _, _, _, _ = \
    helper.load_nifti_as_tensor(input_path=working_dir,
                                filename=fname_afib1err_resampled)



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
    torch.divide(mese_denoise_nbc_gnlc, 
                 mese_data_norm), 
                 nan=0.0, posinf=0.0, neginf=0.0).contiguous()

# We do a poor mans b1 regularization.
# First run we extract the b1 map the pattern matching would optimize for without providing the afi input
print("T2 pattern matching without AFI input to extract EMC estimates")
t2_emc, b1_emc, _ = r2_pattern_matching(
    input_data=mese_data_normalized, 
    db_mag=db_torch_mag, 
    t2_vals=t2_vals, b1_vals=b1_vals, t1_vals=t1_vals, b1_data=None,
    batch_size=2000, 
    device=torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu"),
)

b1_emc = torch.from_numpy(gaussian_filter(b1_emc.numpy(), sigma=5))


# we can save this for reference
fname_b1_emc = f"{subj}_{sess}_proc-EMC_{b1_suffix}"
_ = helper.save_nifti(output_path=working_dir, 
                      filename=fname_b1_emc, 
                      data=b1_emc, 
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr, 
                      description=f"B1+ map from {fname_mese_undistorted} derived using the echo-modulation curve approach, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_b1_emc).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


r2_emc = torch.nan_to_num( \
            torch.divide(torch.ones_like(t2_emc), 
                         t2_emc), 
                         nan=0.0, posinf=0.0, neginf=0.0)

fname_r2_emc = f"{subj}_{sess}_proc-EMC_{r2_suffix}"
_ = helper.save_nifti(output_path=working_dir, 
                      filename=fname_r2_emc, 
                      data=r2_emc, 
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"R2 map from {fname_mese_undistorted} derived using the echo-modulation curve approach, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_r2_emc).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest

# Now we want to use the AFI B1 estimate and 
# the calculated afi error maps to calculate 
# a combined B1 regularization map.

# we allow for max 10 % relative error in the afi 
# and do a linear weighting between afi b1 and emc b1, 
# essentially if rel afi error is 0 we trust the afi, 
# if relative error of afi is 10% we trust the emc
print("B1 regularization based on AFI relative error")
regularization_factor = 1 - torch.clip(b1_afi_re_rel_err, 0, 10) / 10
b1_reg = regularization_factor * b1_afi_re + (1 - regularization_factor) * b1_emc
b1_reg = torch.from_numpy(gaussian_filter(b1_reg.numpy(), sigma=2))


# we can save this for reference
fname_b1_reg = f"{subj}_{sess}_proc-AFIregEMC_{b1_suffix}"
_ = helper.save_nifti(output_path=working_dir, 
                      filename=fname_b1_reg, 
                      data=b1_reg, 
                      affine=b1_afi_re_aff, 
                      header=b1_afi_re_hdr,
                      description=f"B1+ map created from preprocessed AFI images regularized with EMC B1+ estimate, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_afi_gnlc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_b1_reg).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest

# We now redo the fitting with inputting the b1 regularization. 
# This way the algorithm is not simultaneously optimizing 
# for t2 and b1 but only needs to match the pattern wrt t2.
print("Redo T2 pattern matching with regularized AFI B1 map input")
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
# Load noise statistics from denoise directory
print("Estimate SNR of MESE data")
noise_stats_file = denoise_dir.joinpath(f"{subj}_{sess}_mese_noise_stats").with_suffix(".json")
if noise_stats_file.exists():
    with open(noise_stats_file, 'r') as f:
        noise_stats = json.load(f)
    mese_noise_mean = noise_stats['mese_noise_mean']
    print(f"Original MESE noise mean: {mese_noise_mean}")
else:
    raise FileNotFoundError(f"Noise statistics file not found: {noise_stats_file}")

fit_data_reg_snr = torch.max(mese_denoise_nbc_gnlc, dim=-1).values / mese_noise_mean
# make a threshold map for voxel below 5
snr_threshold = 5.0
fit_data_reg_snr_th = (fit_data_reg_snr < snr_threshold).to(torch.int32)


# we can save this for reference
print("-------------------------------")
print("Saving results")

fname_r2 = f"{subj}_{sess}_{r2_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_r2,
                      data=r2,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"R2 map from {fname_mese_undistorted}, AFI/EMC B1+ correction, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = target_output_dir.joinpath(fname_r2).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


fname_t2 = f"{subj}_{sess}_{t2_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_t2,
                      data=t2,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"T2 map from {fname_mese_undistorted}, AFI/EMC B1+ correction, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = target_output_dir.joinpath(fname_t2).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


fname_b1_reg_fit = f"{subj}_{sess}_{b1_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_b1_reg_fit,
                      data=b1_reg_fit,
                      affine=b1_afi_re_aff,
                      header=b1_afi_re_hdr,
                      description=f"B1+ map created from preprocessed AFI images regularized with EMC B1+ estimate, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_afi_gnlc.with_suffix(".json")
json_dest = target_output_dir.joinpath(fname_b1_reg_fit).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


fname_snr_map = "fit_data_reg_snr"
_ = helper.save_nifti(output_path=working_dir,
                      filename=fname_snr_map,
                      data=fit_data_reg_snr,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"Estimated SNR map of {fname_mese_undistorted}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_snr_map).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


fname_snr_thr_map = "fit_data_reg_snr_thr"
_ = helper.save_nifti(output_path=working_dir,
                      filename=fname_snr_thr_map,
                      data=fit_data_reg_snr_th,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"Thresholded SNR map of {fname_mese_undistorted}, threshold={snr_threshold}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_snr_thr_map).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest