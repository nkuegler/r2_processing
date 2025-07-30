#!/usr/bin/env python3


import pathlib as plib
import logging

import nibabel as nib
import numpy as np
import torch
from scipy.ndimage import gaussian_filter
import os

import plotly.graph_objects as go
import plotly.subplots as psub

logging.basicConfig(level=logging.INFO)


def save_nifti(output_path, filename, data, affine, suffix=".nii"):
    """
    Save data as a NIfTI file and return the file path.
    
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
    suffix : str, optional
        File extension, default is ".nii".
        
    Returns
    -------
    pathlib.Path
        Path to the saved NIfTI file.
    """

    fn = output_path.joinpath(filename).with_suffix(suffix)
    print(f"save file: {fn}")
    i = nib.Nifti1Image(data.numpy(), affine)
    nib.save(i, fn)
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

    return data, img, affine, fn



