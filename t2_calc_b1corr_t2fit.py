#!/usr/bin/env python3

"""
==============================================================================
B1+ Correction and T2 Fitting Processing Script
==============================================================================

DESCRIPTION:
    This script performs B1+ correction and T2 fitting processing on MESE and AFI
    data for a single subject/session using PyMRItools (https://github.com/schmidt-jo/PyMRItools). 
    The script processes the input MESE data to produce T2 maps with B1+ field inhomogeneity correction
    using dictionary-based pattern matching and regularization techniques.

USAGE:
    python t2_calc_b1corr_t2fit.py [OPTIONS]

REQUIRED ARGUMENTS:
    --subject, -s           Subject identifier (e.g., sub-004)
    --session, -ses         Session identifier (e.g., ses-04)
    --field-strength, -b0   Magnetic field strength in Tesla (3.0 or 7.0)
    --input-dir, -i         Input directory containing gradient nonlinearity corrected data
    --output-dir, -o        Output directory for final T2/R2 and B1+ maps
    --denoise-dir, -denDir  Directory containing denoised data for noise statistics

OPTIONAL ARGUMENTS:
    --work-dir, -w          Working directory for temporary files (default: output_dir/Supplementary/)
    --tr-ratio, -trr        TR ratio (TR2/TR1) for AFI B1+ calculation (default: 5.0)
    --flip-angle, -fa       Flip angle of AFI images in degrees (default: 55.0)
    --use-custom-b1         Use the custom B1+ map (*_desc-undistorted_B1map.nii) from the input directory
                            (prepared by slurm_bridge_gnlc_b1.sh) instead of the AFI-based B1+ map.

OPERATIONS PERFORMED:
    1. B1+ field mapping from actual flip angle (AFI) imaging (or loading of the custom B1+ map)
    2. B1+ mapping using the echo-modulation curve (EMC) approach from MESE data (only B1_METHOD = "AFIregEMC")
    3. B1+ field regularization (only B1_METHOD = "AFIregEMC": AFI+EMC for 7T, EMC-only for 3T)
    4. Dictionary-based T2 fitting with B1+ correction using pattern matching
    5. R2 map calculation from corrected T2 values
    6. SNR estimation and quality control metrics

EXAMPLE:
    python t2_calc_b1corr_t2fit.py \\
        --subject sub-001 --session ses-01 --field-strength 7 \\
        --input-dir /data/gnlc --output-dir /data/output \\
        --denoise-dir /data/denoise --tr-ratio 5.0 --flip-angle 55.0

NOTES:
    - Requires PyMRItools (https://github.com/schmidt-jo/PyMRItools) checked out at the commit c1b1568
    - Requires pre-computed dictionary databases specific for your sequences
    - The B1+ method without custom B1+ map is set by the hard-coded B1_METHOD below:
      * "AFI":       AFI B1+ map only (3T and 7T)
      * "AFIregEMC": 7T: Combined AFI and EMC approach with error-based weighting; 3T: EMC-only approach
    - GPU acceleration automatically used if CUDA is available
    - Intermediate results saved in working directory for validation
    - Quality control plots saved as HTML files
    - Final outputs placed in BIDS-compatible structure

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
==============================================================================
"""

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
import shutil


logging.basicConfig(level=logging.INFO)


from pymritools.processing.denoising import extract_noise_mask
from pymritools.modeling.b1_afi import calculate_b1, calculate_error_map
from pymritools.config.database import DB
from pymritools.modeling.dictionary import r2_pattern_matching


import t2_calc_helper as helper

### SETUP

### setting data

# ============================================================================
# CONFIGURATION SETTINGS FOR B1+ CORRECTION
# ============================================================================
# B1+ method used when NO custom B1+ map is provided (--use-custom-b1 not set)
#   "AFI"       : AFI B1+ map only (resampled to MESE space, smoothed), at 3T and 7T. EMC fitting is skipped.
#   "AFIregEMC" : 7T -> AFI B1+ regularized with the EMC B1+ estimate (weighted by the AFI relative error, threshold 10 %)
#                 3T -> EMC-only B1+ (AFI is computed for reference but not used)
# (The settings for the custom B1+ map (subdirectory, filename pattern) are defined in t2_processing_main.sh)
B1_METHOD = "AFIregEMC"
VALID_B1_METHODS = ("AFI", "AFIregEMC")

# ============================================================================

if B1_METHOD not in VALID_B1_METHODS:
    raise ValueError(f"Invalid B1_METHOD: {B1_METHOD}. Supported values are {VALID_B1_METHODS}.")

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
parser.add_argument('--use-custom-b1', action='store_true',
                    help='Use the custom B1+ map (*_desc-undistorted_B1map.nii) from the input directory instead of the AFI-based B1+ map')


args = parser.parse_args()

# Use parsed arguments
subj = args.subject
sess = args.session
magnetic_field = args.field_strength
trRatio = args.tr_ratio
fa = args.flip_angle
use_custom_b1 = args.use_custom_b1

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
    # path_db = plib.Path("/data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/emc/emc_database_7T_semc_0p6_new.pkl")
    path_db = plib.Path("/data/pt_03187/data/in_vivo/bids/derivatives/relax_R2/emc/histopark7T/emc_database_7T_semc_js_a.pkl") # histopark 7T Leipzig (Terra.X XA60)
    # path_db = plib.Path("/data/pt_02262/data/liege_data/bids/derivatives/relax_R2_new/emc/histopark7T_liege/emc_database_7T_semc_js_histoparkLiege.pkl") # histopark 7T Liege (Terra VE12)
elif magnetic_field == 3.0:
    # path_db = plib.Path("/data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/emc/db_mese_3T_etl10.pkl")
    path_db = plib.Path("/data/pt_03187/data/in_vivo/bids/derivatives/relax_R2/emc/histopark3T/emc_database_3T_semc_js_histopark.pkl")
else:
    raise ValueError(f"Unsupported magnetic field strength: {magnetic_field}. Supported values are 3.0 and 7.0 Tesla.")


############################################

mese_suffix = "MESE"
afi_suffix = "TB1AFI"
b1_suffix = "TB1map"
custom_b1_suffix = "B1map"
r2_suffix = "R2map"
t2_suffix = "T2map"

### B1+ CORRECTION
b1_gauss_sigma = 2  # smoothing kernel for B1+ maps (in voxels)
b1_gauss_sigma_emc = 4

# reload gradient nonlinearity corrected images

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
del descrip_array_mese

if use_custom_b1:
    # ========================================================================
    # CUSTOM B1 MAP WORKFLOW
    # ========================================================================
    print(f"Using custom B1+ map workflow", flush=True)
    
    # Load custom B1 map (prepared by slurm_bridge_gnlc_b1.sh: GNL-corrected without jacobian, or copied as is)
    fname_custom_b1_pattern = f"*_desc-undistorted_{custom_b1_suffix}.nii"
    custom_b1_files = sorted(glob.glob(str(input_dir / fname_custom_b1_pattern)))
    if not custom_b1_files:
        raise FileNotFoundError(f"No custom B1 map found matching pattern: {input_dir / fname_custom_b1_pattern}")
    if len(custom_b1_files) > 1:
        logging.warning(f"Multiple custom B1 maps found matching pattern: {fname_custom_b1_pattern}. Using the first one.")
    path_custom_b1 = plib.Path(custom_b1_files[0])
    custom_b1_filename = path_custom_b1.with_suffix('').name
    logging.info(f"Custom B1 map: {path_custom_b1}")

    # Read how the gradient nonlinearity correction of the custom B1 map was handled
    custom_b1_json = path_custom_b1.with_suffix(".json")
    custom_b1_gnlc_handling = "unknown"
    if custom_b1_json.exists():
        with open(custom_b1_json, 'r') as f:
            custom_b1_gnlc_handling = json.load(f).get("B1mapGNLCHandling", "unknown")
    else:
        logging.warning(f"JSON sidecar of the custom B1 map not found: {custom_b1_json}")
    logging.info(f"GNLC of the custom B1 map: {custom_b1_gnlc_handling}")
    
    # Resample custom B1 map to MESE space
    print("Resample custom B1 map to MESE space", flush=True)
    fname_custom_b1_resampled = custom_b1_filename.replace(f"_{custom_b1_suffix}", f"_proc-resampled_{custom_b1_suffix}")
    path_custom_b1_resampled = working_dir.joinpath(fname_custom_b1_resampled).with_suffix(".nii")
    
    helper.resample_3d_ants(
        input_file=path_custom_b1,
        reference_file=path_mese4d_proc,
        output_file=path_custom_b1_resampled,
        description="Custom B1 map to MESE space",
        interpolation_mode="Linear"
    )
    
    # Load resampled custom B1 map
    b1_custom_re, b1_custom_re_img, b1_custom_re_aff, b1_custom_re_hdr, _ = \
        helper.load_nifti_as_tensor(input_path=working_dir,
                                   filename=fname_custom_b1_resampled)
    
    # Convert to unitless if necessary (assuming input is in percentage)
    # Check if values are in percentage range (0-200) or already unitless (0-2)
    b1_max = b1_custom_re.max().item()
    if b1_max > 2.0:  # Likely in percentage
        b1_custom_re = b1_custom_re / 100
    
    b1_reg = torch.from_numpy(gaussian_filter(b1_custom_re.numpy(), sigma=b1_gauss_sigma))
    fname_b1_reg = f"{subj}_{sess}_proc-CustomB1_{b1_suffix}"
    description_text_b1reg = f"B1+ map from custom external B1+ map, resampled to MESE space, {helper.get_timestamp()}"
    
    # Store references for later
    afi_gnlc = None
    afi_gnlc_description = "N/A (custom B1 map used)"
    b1_afi_re = None
    b1_afi_re_aff = b1_custom_re_aff
    b1_afi_re_hdr = b1_custom_re_hdr
    
else:
    # ========================================================================
    # STANDARD AFI (+ EMC) B1 MAP WORKFLOW
    # ========================================================================
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
        b1_data=afi_gnlc, r_tr21=trRatio, smoothing_kernel=3, flip_angle_set_deg=fa,
    )
    b1_err = calculate_error_map(
        b1_data=afi_gnlc, mask=noise_mask_afi, flip_angle_set_deg=fa, ratio_tr_n=trRatio, path_visuals=working_dir
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
    ### > corresponding JSON file is created at the end of this script

    fname_afib1_rel_err = f"{fname_afib1}_rel_err"
    path_afib1err = helper.save_nifti(output_path=working_dir,
                                 filename=fname_afib1_rel_err,
                                 data=torch.from_numpy(b1_rel_err),
                                 affine=afi_gnlc_aff,
                                 header=afi_gnlc_hdr,
                                 description=f"B1+ relative error map from {fname_afi_undistorted}, {helper.get_timestamp()}")

    # once again we want some resampled version brought into the semc image space, we can use linear interpolation here since the b1 and the rel error maps are assumed to vary smoothly

    # resample the AFI_B1 data to the MESE space
    print("Resample AFI_B1 to MESE space", flush=True)
    fname_afib1_resampled = fname_afib1.replace(b1_suffix, f"proc-resampled_{b1_suffix}")
    path_afib1_resampled = working_dir.joinpath(fname_afib1_resampled).with_suffix(".nii")
    
    helper.resample_3d_ants(
        input_file=path_afib1,
        reference_file=path_mese4d_proc,
        output_file=path_afib1_resampled,
        description="AFI B1 to MESE space",
        interpolation_mode="Linear"
    )

    # resample the AFI_B1 relative error data to the MESE space
    print("Resample AFI_B1_rel_err to MESE space", flush=True)
    fname_afib1err_resampled = fname_afib1_rel_err.replace(b1_suffix, f"proc-resampled_{b1_suffix}")
    path_afib1err_resampled = working_dir.joinpath(fname_afib1err_resampled).with_suffix(".nii")
    
    helper.resample_3d_ants(
        input_file=path_afib1err,
        reference_file=path_mese4d_proc,
        output_file=path_afib1err_resampled,
        description="AFI B1 relative error to MESE space",
        interpolation_mode="Linear"
    )

    b1_afi_re, b1_afi_re_img, b1_afi_re_aff, b1_afi_re_hdr, _ = \
        helper.load_nifti_as_tensor(input_path=working_dir,
                                    filename=fname_afib1_resampled)

    b1_afi_re_rel_err, _, _, _, _ = \
        helper.load_nifti_as_tensor(input_path=working_dir,
                                    filename=fname_afib1err_resampled)

    del descrip_array_afi


### T2 FITTING

# load the lookup dictionary
db = DB.load(path_db)
# get torch tensors
# make sure that you have checked out the correct commit of pymritools 
# (otherwise the get_torch_tensors_t1t2b1e() function may raise an error)
db_torch_mag, db_torch_phase = db.get_torch_tensors_t1t2b1b0e()

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

# Each workflow defines the B1+ map used as fixed input for the final T2 pattern matching:
# b1_reg, fname_b1_reg, description_text_b1reg
if use_custom_b1:
    # ========================================================================
    # CUSTOM B1 WORKFLOW: B1+ map prepared above (resampled and smoothed custom B1+ map)
    # ========================================================================
    print("Using custom B1+ map as input for T2 pattern matching", flush=True)

elif B1_METHOD == "AFI":
    # ========================================================================
    # AFI-ONLY WORKFLOW: Smoothed AFI B1+ map, no EMC fitting
    # ========================================================================
    print("Using AFI B1+ map (without EMC regularization) as input for T2 pattern matching", flush=True)
    b1_reg = torch.from_numpy(gaussian_filter(b1_afi_re.numpy(), sigma=b1_gauss_sigma))
    fname_b1_reg = f"{subj}_{sess}_proc-AFI_{b1_suffix}"
    description_text_b1reg = f"B1+ map created from preprocessed AFI images (no EMC regularization), {helper.get_timestamp()}"

elif B1_METHOD == "AFIregEMC":
    # ========================================================================
    # AFI+EMC WORKFLOW: First EMC (joint B1+/T2 fit), then AFI+EMC regularization (7T) or EMC-only (3T)
    # ========================================================================
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

    b1_emc = torch.from_numpy(gaussian_filter(b1_emc.numpy(), sigma=b1_gauss_sigma_emc))

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
    ### > corresponding JSON file is created at the end of this script

    # Now we want to use the AFI B1 estimate and 
    # the calculated afi error maps to calculate 
    # a combined B1 regularization map.

    if magnetic_field == 7.0:
        # we allow for max 10 % relative error in the afi 
        # and do a linear weighting between afi b1 and emc b1, 
        # essentially if rel afi error is 0 we trust the afi, 
        # if relative error of afi is 10% we trust the emc
        print("B1 regularization based on AFI relative error")
        regularization_threshold = 10.0  # in percent
        regularization_factor = 1 - torch.clip(b1_afi_re_rel_err, 0, regularization_threshold) / regularization_threshold
        b1_reg = regularization_factor * b1_afi_re + (1 - regularization_factor) * b1_emc
        b1_reg = torch.from_numpy(gaussian_filter(b1_reg.numpy(), sigma=b1_gauss_sigma))
        fname_b1_reg = f"{subj}_{sess}_proc-AFIregEMC_{b1_suffix}"
        description_text_b1reg = f"B1+ map created from preprocessed AFI images regularized with EMC B1+ estimate, {helper.get_timestamp()}"
    elif magnetic_field == 3.0:
        # We know from experience that the EMC B1+ estimate is quite good for 3T data.
        # Therefore, we don't use the AFI B1+ estimate at all here.
        # TODO: This decision should be systematically evaluated and potentially adjusted.
        b1_reg = torch.from_numpy(gaussian_filter(b1_emc.numpy(), sigma=b1_gauss_sigma))
        fname_b1_reg = f"{subj}_{sess}_proc-EMC_{b1_suffix}"
        description_text_b1reg = f"B1+ map estimated using echo-modulation curve (EMC) approach, {helper.get_timestamp()}"
    else: 
        raise ValueError(f"Unsupported magnetic field strength: {magnetic_field}. Supported values are 3.0 and 7.0 Tesla.")

# we can save this for reference
# fname_b1_reg defined above
_ = helper.save_nifti(output_path=working_dir, 
                      filename=fname_b1_reg, 
                      data=b1_reg, 
                      affine=b1_afi_re_aff, 
                      header=b1_afi_re_hdr,
                      description=description_text_b1reg)
### > corresponding JSON file is created at the end of this script

# (Re)do the fitting with the B1+ map as fixed input. 
# This way the algorithm is not simultaneously optimizing 
# for t2 and b1 but only needs to match the pattern wrt t2.
# (For B1_METHOD = "AFIregEMC", this is the second run after the joint B1+/T2 fit of the EMC estimation.)
print(f"T2 pattern matching with B1+ map input ({fname_b1_reg})", flush=True)
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

mese_data_reg_snr = torch.max(mese_denoise_nbc_gnlc, dim=-1).values / mese_noise_mean
# make a threshold map for voxel below 5
snr_threshold = 5.0
mese_data_reg_snr_th = (mese_data_reg_snr < snr_threshold).to(torch.int32)


# we can save this for reference
print("-------------------------------")
print("Saving results")

# Prepare processing information for JSON metadata
if use_custom_b1:
    b1_label = "custom B1+ correction"
    b1_correction_method = f"External custom B1+ map (gradient nonlinearity correction: {custom_b1_gnlc_handling}), resampled to MESE space and smoothed"
    b1_processing_steps = [
        f"Loading external custom B1+ map (gradient nonlinearity correction: {custom_b1_gnlc_handling})",
        "Resampling custom B1+ map to MESE space using linear interpolation",
        "Spatial smoothing of resampled custom B1+ map"
    ]
elif B1_METHOD == "AFI":
    b1_label = "AFI B1+ correction"
    b1_correction_method = "AFI-only (AFI B1+ map resampled to MESE space and smoothed, no EMC regularization)"
    b1_processing_steps = [
        "B1+ field mapping from AFI data",
        "Resampling AFI B1+ map to MESE space using linear interpolation",
        "Spatial smoothing of resampled AFI B1+ map"
    ]
elif magnetic_field == 7.0:
    b1_label = "AFI+EMC B1+ correction"
    b1_correction_method = f"AFI+EMC regularization (linear weighting between AFI B1+ and EMC B1+, up to {regularization_threshold} % error in the AFI B1+ map)"
    b1_processing_steps = [
        "B1+ field mapping from AFI data",
        "Echo-modulation curve (EMC) B1+ estimation from MESE data (joint B1+/T2 pattern matching)",
        f"B1+ regularization ({b1_correction_method})",
        "Spatial smoothing of regularized B1+ map"
    ]
else:
    b1_label = "EMC B1+ correction"
    b1_correction_method = "EMC-only (no AFI B1 map used)"
    b1_processing_steps = [
        "Echo-modulation curve (EMC) B1+ estimation from MESE data (joint B1+/T2 pattern matching)",
        f"B1+ regularization ({b1_correction_method})",
        "Spatial smoothing of EMC B1+ map"
    ]

processing_info = {
    "subject": subj,
    "session": sess,
    "field_strength": magnetic_field,
    "tr_ratio": trRatio,
    "flip_angle": fa,
    "input_files": {
        "mese": fname_mese_undistorted,
        **({"b1_map": custom_b1_filename} if use_custom_b1 else {"afi": fname_afi_undistorted})
    },
    "processing_steps": b1_processing_steps + [
        "Dictionary-based T2 fitting with B1+ map as fixed input",
        "R2 map calculation from T2 values"
    ],
    "software_version": {
        "PyMRItools": helper.get_pymritools_version(),
        "processing_script": "t2_calc_b1corr_t2fit.py"
    },
    "database_path": str(path_db),
    "gpu_used": torch.cuda.is_available(),
    "B1_method": "custom" if use_custom_b1 else B1_METHOD,
    "B1_correction_method": b1_correction_method,
    # AFI B1+ map contributes to the final B1+ map
    "afi_used": not use_custom_b1 and (B1_METHOD == "AFI" or magnetic_field == 7.0),
    "B1_smoothing_kernel": [b1_gauss_sigma, b1_gauss_sigma_emc] if (not use_custom_b1 and B1_METHOD == "AFIregEMC") else [b1_gauss_sigma],
    "B1_regularization_threshold": regularization_threshold if (not use_custom_b1 and B1_METHOD == "AFIregEMC" and magnetic_field == 7.0) else "N/A",
    "timestamp": helper.get_timestamp()
}
if use_custom_b1:
    processing_info["B1mapGNLCHandling"] = custom_b1_gnlc_handling

fname_r2 = f"{subj}_{sess}_{r2_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_r2,
                      data=r2,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"R2 map from {fname_mese_undistorted}, {b1_label}, {helper.get_timestamp()}")
# Create processing JSON metadata
json_dest = target_output_dir.joinpath(fname_r2).with_suffix(".json")
helper.create_processing_json(json_dest, "R2map", processing_info)


fname_t2 = f"{subj}_{sess}_{t2_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_t2,
                      data=t2,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"T2 map from {fname_mese_undistorted}, {b1_label}, {helper.get_timestamp()}")
# Create processing JSON metadata
json_dest = target_output_dir.joinpath(fname_t2).with_suffix(".json")
helper.create_processing_json(json_dest, "T2map", processing_info)


fname_b1_reg_fit = f"{subj}_{sess}_{b1_suffix}"
_ = helper.save_nifti(output_path=target_output_dir,
                      filename=fname_b1_reg_fit,
                      data=b1_reg_fit,
                      affine=b1_afi_re_aff,
                      header=b1_afi_re_hdr,
                      description=description_text_b1reg)
# Create processing JSON metadata
json_dest = target_output_dir.joinpath(fname_b1_reg_fit).with_suffix(".json")
helper.create_processing_json(json_dest, "TB1map", processing_info)


fname_snr_map = "mese_data_reg_snr"
_ = helper.save_nifti(output_path=working_dir,
                      filename=fname_snr_map,
                      data=mese_data_reg_snr,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"Estimated SNR map of {fname_mese_undistorted}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_snr_map).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


fname_snr_thr_map = "mese_data_reg_snr_thr"
_ = helper.save_nifti(output_path=working_dir,
                      filename=fname_snr_thr_map,
                      data=mese_data_reg_snr_th,
                      affine=mese_gnlc_aff,
                      header=mese_gnlc_hdr,
                      description=f"Thresholded SNR map of {fname_mese_undistorted}, threshold={snr_threshold}, {helper.get_timestamp()}")
# Copy the JSON file
json_source = path_mese4d_proc.with_suffix(".json")
json_dest = working_dir.joinpath(fname_snr_thr_map).with_suffix(".json")
helper.copy_corresponding_json(json_source, json_dest)
del json_source, json_dest


### Create JSON metadata for intermediate processing results

if not use_custom_b1:
    # AFI B1+ map JSON
    afi_b1_processing_info = processing_info.copy()
    afi_b1_processing_info["processing_steps"] = [
        "B1+ field mapping from AFI data using actual flip angle technique",
        "Unit conversion from percentage to ratio",
        "Spatial smoothing during B1+ calculation"
    ]
    afi_b1_processing_info["input_files"] = {
        "afi": fname_afi_undistorted
    }
    afi_b1_processing_info["B1_correction_method"] = "AFI-only"
    afi_b1_processing_info["afi_used"] = True
    afi_b1_processing_info["B1_regularization_threshold"] = "n/a (AFI-only)"
    json_dest = working_dir.joinpath(fname_afib1).with_suffix(".json")
    helper.create_processing_json(json_dest, "TB1map", afi_b1_processing_info)

if not use_custom_b1 and B1_METHOD == "AFIregEMC":
    # EMC R2 map JSON
    emc_processing_info = processing_info.copy()
    emc_processing_info["processing_steps"] = [
        "Echo-modulation curve (EMC) B1+ estimation from MESE data",
        "Dictionary-based T2 fitting using EMC B1+ only (no AFI regularization)",
        "R2 map calculation from EMC-derived T2 values"
    ]
    emc_processing_info["B1_correction_method"] = "EMC-only (joint B1+/T2 pattern matching)"
    emc_processing_info["afi_used"] = False
    emc_processing_info["B1_regularization_threshold"] = "n/a (EMC-only)"
    json_dest = working_dir.joinpath(fname_r2_emc).with_suffix(".json")
    helper.create_processing_json(json_dest, "R2map", emc_processing_info)

# B1+ map used as input for the final T2 fitting (custom, AFI-only or regularized)
b1_reg_processing_info = processing_info.copy()
b1_reg_processing_info["processing_steps"] = b1_processing_steps
json_dest = working_dir.joinpath(fname_b1_reg).with_suffix(".json")
helper.create_processing_json(json_dest, "TB1map", b1_reg_processing_info)
