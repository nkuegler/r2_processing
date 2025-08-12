# r2_map_calculation
This script uses the PyMRItools by Jochen Schmidt (schmidt-jo) to calculate R2 maps from Multi-Echo Spin-Echo data.

## Requirements
- Requires PyMRItools (https://github.com/schmidt-jo/PyMRItools) checked out at the commit `7d29483`
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


# Building the container

I mostly used the prepared viper GPU container from [PyMRItools](https://github.com/schmidt-jo/PyMRItools/tree/niklas_loraks/apptainer). However, I adjusted it to check out the correct commit of PyMRItools. 

## Building the PyMRItools Singularity Container

Navigate to the container directory:

```bash
cd container
```

**Move the container build file to `/tmp` and build it there. It seems to be problematic to build the container directly in storage unified `/data`**

```bash
# do this on your local machine. It will take long, but the /tmp folder should be large enough and there are no restrictions how much of that storage you can use
mkdir /tmp/container_build
cp pymritools_singularity.def pymritools_environment.yml /tmp/container_build
cd /tmp/container_build

# check the space on your /tmp directory (at least 10 GB should be available)
df -h .
```

Build the Singularity container:

```bash
sudo singularity build pymritools.sif pymritools_singularity.def
# or rather
singularity build --fakeroot pymritools.sif pymritools_singularity.def
```

After building the container, you can move the resulting `.sif` file anywhere you want:

```bash
mv pymritools.sif /path/to/your/directory
```

The pre-built container is available at `/data/p_gr_weiskopf_software/singularity/pymritools.sif`


The build process will:

    Use ROCm Ubuntu 24.04 as the base image
    Install Miniforge3 (minimal Conda distribution)
    Create a conda environment named "mri_tools_env"
    Install all dependencies specified in viper_environment.yml
    Install additional pip packages including:
        triton
        autodmri
        twixtools
        pypulseq
        PyTorch with ROCm 6.2.4 support

## Using the Container

Once built, you can run commands inside the container using:
```bash
singularity exec pymritools.sif <command>
```
or
```bash
singularity shell pymritools.sif
```

The container automatically activates the conda environment on execution.


# Script

- need to adjust `path_db` in `t2_calc_b1corr_t2fit.py`
- for the 3T data, autodmri does not work well. Therefore you have to manually draw noise masks.


The GNLC call script must find the files matching the pattern. Therefore, this is run after the denoising job is finished. An intermediate bridge job (one for MESE and one for AFI) is started that depends on the successful completion of the denoising job, and submits the two corresponding GNLC scripts with pre-defined job IDs. The last step (T2 fitting) depends on the pre-defined job IDs which are assigned to the GNLC jobs.
This would lead to the problem that the GNLC job ID will not yet be available to submit the T2fit job. Therefore, a second bridge job is submitted which will depend on the successful completion of the first bridge script and will eventually submit the T2fitting job with the dependency 


Denoising job → submitted first
GNLC bridge jobs → depend on denoising completion, submit GNLC jobs with custom names
T2 fitting bridge job → depends on GNLC bridge jobs completion
Waits 10 seconds for GNLC jobs to appear in queue
Extracts actual job IDs using squeue and custom job names
Submits T2 fitting job with proper dependencies on actual GNLC job IDs
-> similar approach with the later submitted cleanup jobs

JSON creation along the processing not extensively tested

Final cleanup bridge job depends on all session cleanup bridge jobs. When it runs, it makes the actual final cleanup dependent on all of the session cleanups.

for now, only the denoising and the b1corr/t2fitting jobs are running in the container. GNLC still depends on the institute's specific environments/containers (e.g., `FSL`) -> may be adjusted at some point

The main script runs denoising, GNLC of AFI and MESE images, and B1correction/T2fitting as sequential jobs. After that, the working directory of each session and then the the remains of the working directory is c
leaned up in separate jobs. The dependency of the SLURM jobs is currently handled by intermediate/bridge jobs that submit the actual processing jobs and handle the job dependencies.
Actual python processing scripts using PyMRItools (adapted from Jupyter Notebooks) + helper script" -m "One processing script handles the denoising of the MESE data. The other one does the B1+ correction and the T2 fitting via pattern matching. In between, the Gradient nonlinearity correction has to be performed. The python scripts also transfer and/or adapt the NIfTI headers and copy the corresponding json files. // The helper scripts provide functions that are used regularly across the scripts (e.g., for saving, loading, copying jsons, plotting). The plotting functions are not very generalized, and rather put into this separate script to unclutter the processing python scripts than for re-use purposes."
(see commits from 2025-08-11 for more descriptions of the separate files)

# ToDos: 
- GNLC of AFI and MESE need to run sequentially as they would use the same `undistorted/` directory in the input directory (this would cause issues as files would eventually be moved away from this working directory) 
    - can they run in one call as two contrasts? maybe rename them, so that this works? 
        - rename AFI 4D with `forMESE` -> run contrasts: semc4D,stx4D, pattern: MESE (need to remove resampled AFI and noisy MESE4D)
        - or just add some unique string to the end of the file names of the two important files and remove it when re-loading them
    - would need to add a counter for the job name in GNLC script (-> submits jobs with increasing counter in job name)
    - the parallel processing works for now, because the GNLC of the AFI maps is so much faster than of the MESE data. However, problems can arise when they have similar runtimes as they write to the same `undistorted` dir in the `output_dir_denoise`
        - to make sure, I added a 60 second delay to the MESE GNLC bridge job
- function in bridge jobs to extract job ID from the custom job name -> as actual function (separate script so it can be used by multiple bridge jobs)
- OR: instead of using a custom job name and then extracting the ID, store IDs in a job id file in the working directory (see code snipped below and also some parts in the `t2_processing_main.sh`)
    - (this still requires bridge jobs)
- **other option to submit jobs: submit an wrapper script that submits the job and then waits for this job to finish (e.g., extract the ID and wait until this ID turns from running state to completed) -> using this approach, the next wrapper job can just depend on this wrapper job**
- executing the GNLC inside the container does not work at the moment! -> see todos in README in the `batch_gnlc` repository
- investigate why nvidia-smi call in t2 slurm script does not work



```
# Append job IDs as they're created
echo "DENOISE_JOB_ID=$denoise_job_id" >> "$job_file"
echo "MESE_GNLC_JOB_NAME=$mese_gnlc_job_name" >> "$job_file"
echo "AFI_GNLC_JOB_NAME=$afi_gnlc_job_name" >> "$job_file"
echo "T2FIT_JOB_ID=$t2fit_job_id" >> "$job_file"

# Read back easily
source "$job_file"
echo "Previously saved T2 fit job: $T2FIT_JOB_ID"
```

# Current command:

```
# 7T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif --d -b 7 -sub sub-004 -ses ses-04 Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_autom/

# 3T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif --d -b 3 -fa 60.0 -tr 3.0 -sub sub-001 -ses ses-05 Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_autom/
# --nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2_autom/manualNoiseMasks
```