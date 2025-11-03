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
