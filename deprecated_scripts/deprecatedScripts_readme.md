# r2_processing
This script uses the PyMRItools by Jochen Schmidt (schmidt-jo) to calculate R2 maps from Multi-Echo Spin-Echo data.

## Requirements
- Requires [PyMRItools](https://github.com/schmidt-jo/PyMRItools) checked out at the commit `7d29483`
- Requires pre-computed dictionary databases specific for your sequences


+ Run one of the notebooks (`niklas_t2.ipynb` or `niklas_t2_3T.ipynb`)
    + `resample_3D.sh` and `resample_4D.sh` are used to resample volumes during the notebook execution
+ when finished, adjust and run `call_r2prime.py` to calculate R2prime from the corresponding maps 

## 3T data 

- use `niklas_t2_3T.ipynb`
- does not use AFI but solely the EMC B1 map
- for the 3T data, the `autodmri` approach (`pymritools.processing.denoising.extract_noise_mask()`) for extracting noise voxels does not work
    - probably due to the fact that the whole slab is almost completely filled with the brain (not much air around the head included)
    - two solutions: 
        1. use inverse brain mask as noise mask 
            - however, grappa reconstructed data shows severe aliasing artifacts outside of the brain
        2. better: 
            - draw a mask in echo-01 of the MESE data which contains only noise voxels (outside of the brain and no aliasing artifacts visible)
            - save it to the output directory (`../derivatives/relax_R2/sub-xxx/ses-xx`) with the file name `mese_noise_mask_manual.nii`



## Processing workflow in the Jupyter notebooks

- Denoising of the MESE data
    - using the first part of the Jupyter notebook
- Gradient Nonlinearity correction
    - correcting the magnitude maps of the denoised MESE data 
    - make sure that resampled AFI is also corrected for the nonlinearities
- B1+ calculation
    - using part of the Jupyter notebook
    - make sure to use the denoised and corrected MESE data and the corrected AFI images
- T2 fitting
    - using the last part of the Jupyter Notebook
- followed by R2prime calculation
    - including co-registration of R2 to R2*
    - preliminary scripts do not exist anymore -> use the R2' calculation pipeline


### Denoising
- Just run the Jupyter Notebook until the bias corrected denoised image is saved

### Gradient Nonlinearity correction
- MESE and AFI 4D qformcode and sformcode must be adjusted
    - **(not necessary in the full pipeline. I cannot remember, why that was an issue before?)**
    ```bash
    fslorient -setsformcode 1 file.nii
    fslorient -setqformcode 1 file.nii
    ```

```bash
mv afi_4d.nii afi_4d_TB1AFI.nii

getserver -sb
./call_slurm_batch_magn.sh -c mese -p _nbc -sub sub-004 -ses ses-04 Terra /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_gnlc/mese/
./call_slurm_batch_magn.sh -c afi -p _TB1AFI -sub sub-004 -ses ses-04 Terra /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_gnlc/afi/
```

- MESE and AFI data must be named with correct suffix
    - MESE noise bias corrected GNLC
    - AFI original GNLC → will be resampled again later


