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