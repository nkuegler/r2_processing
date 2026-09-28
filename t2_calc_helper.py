#!/usr/bin/env python3

"""
T2 Calculation Helper - Utility Functions
-----------------------------------------

General utility functions for T2 mapping pipeline including file I/O and metadata handling.

Functions:
- save_nifti(): Save data as NIfTI file with optional header customization
- load_nifti_as_tensor(): Load NIfTI file and return as PyTorch tensor
- get_timestamp(): Get current timestamp in ISO format
- copy_corresponding_json(): Copy JSON metadata files between directories
- resample_3d_ants(): Resample 3D NIfTI file to match reference space using ANTS

Author: Niklas Kuegler (kuegler@cbs.mpg.de)
"""

import pathlib as plib
import logging
import subprocess
import sys

import nibabel as nib
import numpy as np
import torch
from scipy.ndimage import gaussian_filter
import os
import shutil
from datetime import datetime
import json

import plotly.graph_objects as go
import plotly.subplots as psub

logging.basicConfig(level=logging.INFO)


def save_nifti(output_path, filename, data, affine, header=None, description=None, suffix=".nii"):
    """
    Save data as a NIfTI file with optional header customization.
    
    Parameters
    ----------
    output_path : pathlib.Path
        Directory path where the file will be saved.
    filename : str
        Name of the file (without extension).
    data : torch.Tensor or numpy.ndarray
        Image data to be saved.
    affine : numpy.ndarray
        4x4 affine transformation matrix for spatial coordinates.
    header : nibabel header, optional
        Template header to copy from. If provided, this header will be used as base.
    description : str, optional
        Description to add to the header (max 80 characters).
    suffix : str, optional
        File extension, default is ".nii".
        
    Returns
    -------
    pathlib.Path
        Path to the saved NIfTI file.
    """

    fn = output_path.joinpath(filename).with_suffix(suffix)
    print(f"save file: {fn}")
    
    # Create image with optional header template
    if header is not None:
        # Use provided header as template
        img = nib.Nifti1Image(data.numpy(), affine, header=header.copy())
    else:
        # Create with default header
        img = nib.Nifti1Image(data.numpy(), affine)
    
    # Customize header
    if description is not None:
        img.header['descrip'] = description.encode('utf-8')[:80]  # Max 80 chars
    
    nib.save(img, fn)
    return fn

def load_nifti_as_tensor(input_path, filename, suffix=".nii"):
    """
    Load a NIfTI image file and return its data as a PyTorch tensor along with metadata.
    
    Parameters
    ----------
    input_path : pathlib.Path
        Directory path where the NIfTI file is located.
    filename : str
        Base filename without extension.
    suffix : str, optional
        File extension, default is ".nii".
        
    Returns
    -------
    tuple
        A tuple containing:
        - data (torch.Tensor): Image data as a PyTorch tensor with dtype float.
        - img (nibabel.Nifti1Image): Original nibabel image object.
        - affine (numpy.ndarray): 4x4 affine transformation matrix.
        - fn (pathlib.Path): Full path to the loaded NIfTI file.
    """

    fn = input_path.joinpath(filename).with_suffix(suffix)
    print(f"load file: {fn}")
    img = nib.load(fn)
    data = torch.from_numpy(img.get_fdata())
    affine = img.affine
    header = img.header

    return data, img, affine, header, fn



def get_timestamp():
    """
    Get current date and time as a formatted string.
    
    Returns
    -------
    str
        Current timestamp in ISO 8601 format
    """
    return datetime.now().isoformat()


def copy_corresponding_json(json_source, json_dest):
    """
    Copy a JSON file corresponding to a NIfTI image from input to output directory.
    
    Parameters
    ----------
    json_source : pathlib.Path
        Path to the source JSON file.
    json_dest : pathlib.Path
        Path where the JSON file should be copied.
        
    Returns
    -------
    None
    """
    
    if json_source.exists():
        shutil.copy2(json_source, json_dest)
        print(f"Copied JSON from {json_source} to {json_dest}")
    else:
        print(f"Warning: JSON file not found at {json_source}")


def create_processing_json(json_dest, map_type, processing_info):
    """
    Create a JSON metadata file for processed T2/R2/B1+ maps with processing information.
    
    Parameters
    ----------
    json_dest : pathlib.Path
        Path where the JSON file should be created.
    map_type : str
        Type of map ('T2map', 'R2map', 'TB1map').
    processing_info : dict
        Dictionary containing processing parameters and information.
        Expected keys:
        - subject: Subject ID
        - session: Session ID
        - field_strength: Magnetic field strength in Tesla
        - tr_ratio: TR ratio for AFI (if applicable)
        - flip_angle: Flip angle for AFI in degrees (if applicable)
        - input_files: Dict with 'mese' and 'afi' source files
        - processing_steps: List of processing steps performed
        - software_version: Software versions used
        - timestamp: Processing timestamp
        
    Returns
    -------
    None
    """
    
    # Base metadata structure following BIDS conventions
    metadata = {
        "Description": f"Processed {map_type} from T2 mapping pipeline with B1+ correction",
        "Sources": processing_info.get("input_files", {}),
        "ProcessingSteps": processing_info.get("processing_steps", []),
        "ProcessingParameters": {},
        "SoftwareInformation": processing_info.get("software_version", {}),
        "ProcessingTimestamp": processing_info.get("timestamp", get_timestamp()),
        "Units": "s" if map_type == "T2map" else ("Hz" if map_type == "R2map" else "a.u."),
    }
    
    # Add map-specific parameters
    if map_type in ["T2map", "R2map"]:
        metadata["ProcessingParameters"] = {
            "MagneticFieldStrength": processing_info.get("field_strength"),
            "T2FittingMethod": "Dictionary-based pattern matching",
            "B1CorrectionMethod": f"AFI+EMC regularization (linear weighting between AFI B1+ and EMC B1+, up to {processing_info.get('B1_regularization_threshold')} % error in the AFI B1+ map)" if processing_info.get("field_strength") == 7.0 else "EMC-only (no AFI B1 map used)",
            "DatabasePath": processing_info.get("database_path"),
            "GPUAcceleration": processing_info.get("gpu_used", False)
        }
        
        if processing_info.get("field_strength") == 7.0:
            metadata["ProcessingParameters"]["AFI_TR_Ratio"] = processing_info.get("tr_ratio")
            metadata["ProcessingParameters"]["AFI_FlipAngle"] = processing_info.get("flip_angle")
            
    elif map_type == "TB1map":
        metadata["ProcessingParameters"] = {
            "MagneticFieldStrength": processing_info.get("field_strength"),
            "B1MappingMethod": f"AFI+EMC regularization (linear weighting between AFI B1+ and EMC B1+, up to {processing_info.get('regularization_threshold')} % error in the AFI B1+ map)" if processing_info.get("field_strength") == 7.0 else "EMC-only (no AFI B1 map used)",
            "SmoothingKernel": processing_info.get("smoothing_kernel", 3),
            "RegularizationThreshold": processing_info.get("regularization_threshold", 10.0)
        }
        
        if processing_info.get("field_strength") == 7.0:
            metadata["ProcessingParameters"]["AFI_TR_Ratio"] = processing_info.get("tr_ratio")
            metadata["ProcessingParameters"]["AFI_FlipAngle"] = processing_info.get("flip_angle")
    
    # Write JSON file
    with open(json_dest, 'w') as f:
        json.dump(metadata, f, indent=2)
    
    print(f"Created processing JSON metadata at {json_dest}")


def resample_3d_ants(input_file, reference_file, output_file, description="", interpolation_mode="Linear"):
    """
    Resample a 3D NIfTI file to match the space and resolution of a reference file using ANTS.
    
    This function uses the resample_3D.sh script (which calls FSL and ANTS commands) to perform
    spatial resampling via linear or nearest neighbor interpolation.
    
    Parameters
    ----------
    input_file : pathlib.Path or str
        Path to the 3D NIfTI file to be resampled.
    reference_file : pathlib.Path or str
        Path to the reference 4D NIfTI file defining the target space.
    output_file : pathlib.Path or str
        Path where the resampled file will be saved.
    description : str, optional
        Description of the resampling operation for logging (default: "").
    interpolation_mode : str, optional
        Interpolation mode for resampling. Options: "Linear" (default), "NearestNeighbor", "BSpline".
        Default is "Linear" which is suitable for smooth data like B1+ maps. (BSpline seems to cause issues)
        
    Returns
    -------
    pathlib.Path
        Path to the output resampled file.
        
    Raises
    ------
    RuntimeError
        If the resample_3D.sh script fails (non-zero exit code).
    
    Notes
    -----
    - Requires resample_3D.sh script in the same directory as this module
    - Requires ANTS to be installed and in PATH
    - The reference file should be a 4D image; only the geometry/affine is used
    """
    
    # Get the directory containing this script
    script_dir = plib.Path(__file__).parent
    resample_script = script_dir / "resample_3D.sh"
    
    if not resample_script.exists():
        raise FileNotFoundError(f"Resample script not found at {resample_script}")
    
    # Convert to Path objects if strings
    input_file = plib.Path(input_file)
    reference_file = plib.Path(reference_file)
    output_file = plib.Path(output_file)
    
    # Build the command
    cmd = [
        str(resample_script),
        str(input_file),
        str(reference_file),
        str(output_file),
        interpolation_mode
    ]
    
    # Print status message
    if description:
        print(f"Resampling: {description}", flush=True)
    else:
        print(f"Resampling {input_file.name} to match {reference_file.name}", flush=True)
    
    # Execute the resampling command
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, flush=True)
    
    if result.returncode != 0:
        error_msg = f"Error during resampling: {result.stdout}"
        print(error_msg, file=sys.stderr, flush=True)
        raise RuntimeError(error_msg)
    
    print("-------------------------", flush=True)
    
    return output_file


def copy_custom_b1map_to_workdir(custom_b1_root_dir, subject, session, working_dir, custom_b1_subdir, custom_b1_pattern):
    """
    Load custom B1+ map from BIDS-compatible directory structure.
    
    Expected structure: custom_b1_root_dir/sub-xxx/ses-xx/anat/Supplementary/<custom_b1_pattern>
    
    Args:
        custom_b1_root_dir: Root directory containing BIDS-structured custom B1 maps
        subject: Subject identifier (e.g., 'sub-001')
        session: Session identifier (e.g., 'ses-01')
        working_dir: Working directory where to copy the B1 map
        custom_b1_subdir: Subdirectory within the anat/ directory containing custom B1 maps
        custom_b1_pattern: Filename pattern for custom B1 map (glob pattern)
    Returns:
        path_custom_b1: Path to the loaded custom B1 map in working directory
        custom_b1_filename: Filename of the custom B1 map
        
    Raises:
        FileNotFoundError: If no B1 map found matching the pattern
    """
    custom_b1_source_dir = plib.Path(custom_b1_root_dir) / subject / session / "anat" / custom_b1_subdir
    
    if not custom_b1_source_dir.exists():
        raise FileNotFoundError(
            f"Custom B1 map directory does not exist: {custom_b1_source_dir}\n"
            f"Expected structure: {custom_b1_root_dir}/{subject}/{session}/anat/{custom_b1_subdir}/")
    
    # Find B1 map matching the pattern
    b1_files = list(custom_b1_source_dir.glob(custom_b1_pattern))
    
    if not b1_files:
        raise FileNotFoundError(
            f"No B1 map files found in {custom_b1_source_dir} matching pattern '{custom_b1_pattern}'.\n"
            f"Please check the directory and pattern.")
    
    if len(b1_files) > 1:
        logging.warning(f"Multiple B1 map files found matching pattern '{custom_b1_pattern}'. Using the first one.")
        logging.warning(f"Found files: {[f.name for f in b1_files]}")
    
    b1_source_file = b1_files[0]
    custom_b1_filename = b1_source_file.stem  # filename without extension
    
    # Copy B1 map to working directory
    b1_dest_file = working_dir / (b1_source_file.name)
    shutil.copy2(b1_source_file, b1_dest_file)
    logging.info(f"Copied custom B1 map to working directory: {b1_dest_file}")
    
    # Copy corresponding JSON sidecar if it exists
    json_source = b1_source_file.with_suffix('.json')
    if json_source.exists():
        json_dest = b1_dest_file.with_suffix('.json')
        shutil.copy2(json_source, json_dest)
        logging.info(f"Copied corresponding JSON sidecar: {json_dest}")
    
    return b1_dest_file, custom_b1_filename