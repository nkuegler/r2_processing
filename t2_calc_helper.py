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

Author: Niklas Kuegler (kuegler@cbs.mpg.de)
"""

import pathlib as plib
import logging

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