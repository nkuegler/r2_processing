#!/usr/bin/env python3

"""
T2 Calculation Helper - Plotting Functions
------------------------------------------

Visualization utilities for T2 mapping pipeline data using Plotly.

Functions:
- plot_mese4d_afi4dRe(): Compare 4D MESE and resampled AFI data
- plot_mese_noise_mask(): Visualize noise mask overlay on MESE data
- plot_mese_denoised_data(): Compare original vs denoised MESE data

Author: Niklas Kuegler (kuegler@cbs.mpg.de)
"""

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



def plot_mese4d_afi4dRe(mese_4d, afi_4d, afi_4d_re, path_figs, fig_title):
    """
    Plot 4D MESE and rescaled AFI data in a 3-row subplot layout.

    Creates a visualization with 3 rows showing:
    - Row 1: MESE data from first selected slice
    - Row 2: MESE data from second selected slice  
    - Row 3: Rescaled AFI data from middle slice

    Parameters
    ----------
    mese_4d : torch.Tensor
        4D MESE data with shape (nx, ny, nz, ne) where ne is number of echoes
    afi_4d : torch.Tensor
        4D AFI data with shape (nx, ny, nz, ne) where ne is the number of AFI images
    afi_4d_re : torch.Tensor
        Resampled 4D AFI data with same shape as mese_4d
    path_figs : pathlib.Path
        Directory path where the output HTML figure will be saved
    fig_title : str
        Base filename for the saved figure (extension will be added automatically)

    Returns
    -------
    None
    
    Notes
    -----
    - The function uses a fixed 3-row layout regardless of input data dimensions
    - Slice selection is automatic based on data dimensions
    - All heatmaps use the same color scale (0-2000) for consistency
    - Output is saved as an interactive HTML file using plotly
    - Only the first heatmap (top-left) shows the color scale bar
    """
    nx_mese, ny_mese, nz_mese, ne_mese = mese_4d.shape

    fig = psub.make_subplots(
        rows=3, cols=ne_mese,
        shared_xaxes=True, shared_yaxes=True,
        horizontal_spacing=0.01, vertical_spacing=0.01,
        row_titles=[f"slice: {1 + int((1 + z) / 3 * nz_mese)}" for z in range(2)] + ["afi echoes"],
        column_titles=[f"echo: {e + 1}" for e in range(ne_mese)],
    )
    for z in range(2):
        for e in range(ne_mese):
            showscale = True if (z == 0 and e == 0) else False
            fig.add_trace(
                go.Heatmap(
                    z=mese_4d[:, :, int((1 + z) / 3 * nz_mese), e].numpy(), transpose=True,
                    zmin=0, zmax=2000, showscale=showscale,
                ),
                row=z + 1, col=e + 1,
            )
        for e in range(afi_4d.shape[-1]):
            fig.add_trace(
                go.Heatmap(
                    z=afi_4d_re[:, :, int(2 / 3 * nz_mese), e].numpy(), transpose=True,
                    zmin=0, zmax=2000, showscale=False,
                ),
                row=3, col=e + 1,
            )
    fig.update_xaxes(visible=False)
    fig.update_yaxes(visible=False)
    fn = path_figs.joinpath(fig_title).with_suffix(".html")
    print(f"save file: {fn}")
    fig.write_html(fn)



def plot_mese_noise_mask(mese_4d, noise_mask, path_figs, fig_title):
    """
    Plot MESE data with noise mask overlay across multiple slices.

    Creates a visualization showing MESE data from the first echo with identified
    noise voxels overlaid as green markers. The function displays 5 evenly
    distributed slices across the z-dimension in a single row layout.

    Parameters
    ----------
    mese_4d : torch.Tensor
        4D MESE data with shape (nx, ny, nz, ne) where ne is number of echoes.
        Only the first echo (index 0) is displayed.
    noise_mask : torch.Tensor
        3D binary mask with shape (nx, ny, nz) indicating noise voxels.
        Non-zero values mark identified noise regions.
    path_figs : pathlib.Path
        Directory path where the output HTML figure will be saved
    fig_title : str
        Base filename for the saved figure (extension will be added automatically)

    Returns
    -------
    None
    
    Notes
    -----
    - Displays 5 slices evenly distributed across the z-dimension
    - MESE data is shown as heatmaps with color scale 0-2000
    - Noise voxels are overlaid as small green markers (#3ad673)
    - Only the first subplot shows the color scale bar
    - Output is saved as an interactive HTML file using plotly
    - Slice indices are calculated to provide even distribution across z-dimension
    """

    nx_mese, ny_mese, nz_mese, ne_mese = mese_4d.shape

    fig = psub.make_subplots(
        rows=1, cols=5,
        shared_xaxes=True, shared_yaxes=True,
        horizontal_spacing=0.01, vertical_spacing=0.01,
        column_titles=[f"slice: {1 + int((1 + z) / 6 * nz_mese)}" for z in range(5)],
    )
    for z in range(5):
        showscale = True if (z == 0) else False
        # plot mese data
        fig.add_trace(
            go.Heatmap(
                z=mese_4d[:, :, int((1 + z) / 6 * nz_mese), 0].numpy(), transpose=True,
                showscale=showscale, zmin=0, zmax=2000,
            ),
            row=1, col=z + 1,
        )
        # plot identified noise voxels
        indices = torch.nonzero(noise_mask[:, :, int((1 + z) / 6 * nz_mese)])
        fig.add_trace(
            go.Scatter(x=indices[:, 0], y=indices[:, 1], mode="markers", showlegend=False, marker=dict(size=2, color="#3ad673")),
            row=1, col=z + 1,
        )
    fig.update_xaxes(visible=False)
    fig.update_yaxes(visible=False)
    fn = path_figs.joinpath(fig_title).with_suffix(".html")
    print(f"save file: {fn}")
    fig.write_html(fn)


def plot_mese_denoised_data(mese_4d, mese_4d_denoised, mese_4d_denoised_nbc, path_figs, fig_title):
    """
    Plot comparison of original and denoised MESE data across all echo times.

    Creates a 3-row visualization comparing original MESE data, denoised MESE data,
    and denoised MESE data with noise bias correction (nbc). All data is displayed
    from the middle slice across all echo times to highlight denoising effects.

    Parameters
    ----------
    mese_4d : torch.Tensor
        4D original MESE data with shape (nx, ny, nz, ne) where ne is number of echoes
    mese_4d_denoised : torch.Tensor
        4D denoised MESE data, same shape as mese_4d
    mese_4d_denoised_nbc : torch.Tensor
        4D denoised MESE data with noise bias correction, same shape as mese_4d
    path_figs : pathlib.Path
        Directory path where the output HTML figure will be saved
    fig_title : str
        Base filename for the saved figure (extension will be added automatically)

    Returns
    -------
    None
    
    Notes
    -----
    - Displays data from the middle slice (nz_mese // 2) for all datasets
    - Uses a lower color scale maximum (0-1000) to better highlight differences
    - Denoised data should appear less granular than original data
    - Data with noise bias correction (nbc) should show lower values in low SNR areas
    - Only the first row shows the color scale bar for consistency
    - Output is saved as an interactive HTML file using plotly
    """

    nx_mese, ny_mese, nz_mese, ne_mese = mese_4d.shape

    fig = psub.make_subplots(
        rows=3, cols=ne_mese,
        shared_xaxes=True, shared_yaxes=True,
        horizontal_spacing=0.01, vertical_spacing=0.01,
        column_titles=[f"echo: {1 + e}" for e in range(ne_mese)],
        row_titles=["mese data", "denoised mese data", "denoised mese data nbc"]
    )
    z = nz_mese // 2
    for di, d in enumerate([mese_4d, mese_4d_denoised, mese_4d_denoised_nbc]):
        showscale = True if (di == 0) else False
        for e in range(ne_mese):
            # plot data
            # set max intensity quite low on purpose to better spot the differences
            # denoised data (and nbc) should look less granular
            # nbc should have lower values outside brain and in los SNR areas
            fig.add_trace(
                go.Heatmap(
                    z=d[:, :, z, e].numpy(), transpose=True,
                    showscale=showscale, zmin=0, zmax=1000,
                ),
                row=1 + di, col=1 + e,
            )
    fig.update_xaxes(visible=False)
    fig.update_yaxes(visible=False)
    fn = path_figs.joinpath(fig_title).with_suffix(".html")
    print(f"save file: {fn}")
    fig.write_html(fn)

