## Processing steps


The script submits three processing steps as sequential SLURM jobs: 
1. Creation of a reference image by summing all available PDw echoes (as all qMRI maps are present in the PDw space)
    - sum all denoised and gradient nonlinearity corrected PDw echoes together using `fslmaths`
    - save the result as `PDw_echoes_sum.nii` in the specified working directory
2. Co-registration of the R2 (slab) to the reference image
    - use SPM's coregistration (Estimate and Reslice)
    - constructed as SPM batch 
3. Calculation of the R2prime map
    - validation that R2* and R2 are present in the same space (`sform`)
    - `R2' = R2* - R2`
    - set non-positive values to 0


## Some additional info
- all mandatory command line arguments require flags now
- It is required to specify the parent directory of the PDw, the R2*, and the R2 data as input. All of them have to be organized in BIDS format (`/sub-*/ses-*/anat`).
- The output directory will automatically be organized in BIDS structure.
- Each subject/session directory must be present in the PDw dir, R2 dir, and R2* dir for the script to process it. 


## current command:

- for 7T data:
```
# single subject
./r2_coreg_main.sh -sub sub-004 -ses ses-03 -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -pdw /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/LCPCA_distCorr/ -r2 /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ -r2s /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/qMRI_noB1corr/ -o /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b7T/

# all subjects/sessions
./r2_coreg_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -pdw /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/LCPCA_distCorr/ -r2 /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ -r2s /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/qMRI_noB1corr/ -o /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b7T/
```

- for 3T data:
```
./r2_coreg_main.sh -sub sub-001 -ses ses-05 -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -pdw /data/pt_02262/data/TH_bids/bids/derivatives/LCPCA_distCorr/ -r2 /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ -r2s /data/pt_02262/data/TH_bids/bids/derivatives/qMRI_noB1corr/ -o /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b3T/
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
