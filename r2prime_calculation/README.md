## Create reference image from PDw

- create reference image: 
    - add all denoised and gradient nonlinearity corrected PDw echoes together using `fslmaths`
    - save the result as `PDw_echoes_sum.nii` in the specified working directory

- use SPM's coregistration (Estimate and Reslice)
    - constructed as SPM batch 
    - run in a slurm job

## current command:

- for 7T data:
```
./r2_coreg_main.sh -sub sub-004 -ses ses-03 /data/p_gr_weiskopf_software/singularity/pymritools.sif /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/LCPCA_distCorr/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_autom/ /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b7T/
```

- for 3T data:
```
./r2_coreg_main.sh -sub sub-001 -ses ses-05 /data/p_gr_weiskopf_software/singularity/pymritools.sif /data/pt_02262/data/TH_bids/bids/derivatives/LCPCA_distCorr/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_autom/ /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b3T/
```


## Analysis of the co-registered brains
- 7T looks good (sub-004 ses-03)
    - maybe a few pixels offset in some regions (however, the contrasts are also not fully comparable)
- 3T worse (sub-001 ses-05)
    - R2 map looks a little bloated compared to the reference (still quite ok)
- check co-registration of each file separately



# Todos:
- include R2prime calculation as third step
- cleanup option (when processing implementation is finished completely)
