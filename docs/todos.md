# Todos in T2 processing

## Known Issues and ToDos

### Current Limitations & Planned Improvements

1. **Execution errors spotted**
   - input directory should be checked for files before submitting jobs (allows specifiying "all" sessions even if some don't have MESE/AFI data)
   - don't create output dir if no input data found (or delete if already created) -> better to not create it at all as it solves the issue of empty subject directories when the session dir is deleted (subject dir cannot be deleted as it may contain other sessions)
   - if multiple sessions selected that do not contain MESE data, the T2 processing does not run at all (why? each session should be processed independently)
      - problem is that t2 bridge job cannot find the corresponding GNLC job IDs
      - when selecting only a selection of sessions (including ones that do not contain MESE and/or AFI data), the t2 processing step runs (not sure where this problem arises then -> implement to skip if the necessary data is not available and then try again)
   - full cleanup only works if all sessions are processed -> therefore, no jobs should be submitted if no input data is found for a session
   - goal should be to not specify any -sub -ses and still get valid output for all the sessions that contain MESE and AFI data

1. **sform differences between TB1map and R2map**
   - slight differences (roughly third digit after comma -> maybe rounding inaccuracy) in sform matrices between resulting TB1map and R2map (should be identical after resampling)
   - The B1 map is resampled into the R2 space but the sform matrices differ slightly. This shouldn't have a huge effect (due to low resolution and smoothing during resampling) but it may be worth adjusting this for good measure.

2. **Hard-coded paths** 
   - the following scripts contain hard coded variables -> solve by using relative paths and/or by using singularity container
      - `t2_processing_main.sh`: gnlc_dir, gnlc_slurm_log_dir, --output (twice in the script and twice in the dynamic creation of the bridge jobs, which should go into a separate script anyway)
      - `slurm_b1corr_t2fit.sh`: t2_script
      - `slurm_bridge_cleanup_final.sh`: --output
      - `slurm_denoise_nbc.sh`: t2_script
      - `t2_calc_b1corr_t2fit.py`: database paths
      - `coreg_r2_slab_slurm.sh`: SBATCH -o, and in MATLAB command
      - `coreg_r2_slab.m`: in addpath
      - `r2prime_calc.sh`: SBATCH -o
      - `r2_prime_creation_main.sh`: logs_dir
      - `ref_sum_echoes.sh`: SBATCH -o

3. Add LORAKS reconstruction of rawdata, combined with improved denoising technique (see directory `denoising_new/`).

4. **Bridge Job Refactoring**
   - Move all bridge job scripts to separate files (currently T2 bridge and session cleanup bridge is inline ("dynamic creation"))
   - Bridge job flow currently overly complicated -> works but could be adjusted for convenience at some point in one of the following ways:
      - lookup function to extract job ID as shared utility (use custom job names -> function in separate script that extracts job ID from custom job name)
      - **better alternative:** Use a wrapper script that submits the processing job and waits for job completion (e.g., extract job ID and wait until this job turns from running state to completed) 
         - avoids the need of custom job names for extracting job ID as the next wrapper job can just depend on the current one
      - or adjust bridge jobs to store and read Job IDs in a separate file (similar to how it is done in the final cleanup step in `t2_processing_main.sh`):
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

5. **GNLC Execution**
   - Currently runs outside the container (uses institute-specific FSL/ANTs)
   - Should be integrated into container for portability 
   - See TODOs in `batch_gnlc` repository (rather adjust there and not in this repository)

6. **Logfile output location**
   - check that `--output` parameter in each SLURM call is pre-defined and passed instead of manually specifying it
   - Better organization of log file in clear directories (separate bridge/actual jobs)
      - rename all outfiles to `%j_(bridge)_(denoise|gnlc|t2fit)_subj_sess`
      - separate them in bridge job directory and actual job directory
   - bridge job files should not be stored in the denoise log directory
      
7. **Overwrite flag**
   - Implement overwrite flag for existing files in working and output directories
   - Check for existing output files before processing (e.g., check for `.nii`)

8. **Parallel GNLC Processing**
   - MESE and AFI GNLC use same `undistorted/` directory (need to run sequentially as files are eventually moved away from the working directory) 
   - currently: 60-second delay prevents conflicts (fragile solution)
   - the parallel processing works for now, because the GNLC of the AFI maps is so much faster than of the MESE data. However, problems can arise when they have similar processing times as they write to the same `undistorted` dir in the `output_dir_denoise`
      - to make sure, I added a 60 second delay to the MESE GNLC bridge job
   - **Solution:**
      - Rename files with unique identifiers to avoid conflicts
      - Or process MESE and AFI as two contrasts in single call (may require renaming of the files)
         - rename AFI 4D with `forMESE` -> run contrasts: semc4D,stx4D, pattern: MESE (need to remove resampled AFI and noisy MESE4D)
         - or just add some unique string to the end of the file names of the two important files and remove it when re-loading them
      - Add counter for job names in GNLC script (-> submit jobs with increasing counter in job name)

9. **Field Strength Detection**
   - Auto-detect field strength from sidecar JSON
   - 3T and 7T data is usually located in the same directory -> Currently necessary to manually specify subjects/sessions for these mixed-field datasets.

10. **GPU Monitoring**
   - `nvidia-smi` call in T2 SLURM script currently not functional

11. **Path to database must be manually specified**
   - path to the database for pattern matching specified in `t2_calc_b1corr_t2fit.py`
   - not convenient -> may need to be adjusted by defining it in a separate settings file or similar (flag for specifying the path does not seem the best solution)



### Future Enhancements

- Automated quality control metrics
- Currently, the field strength is the differentiation between different kinds of files. That my not hold with different data as not only the field strength is of importance but also MRI system type, data quality and possibly other factors. The differentiation by field strength may need to be adjusted where it is not the crucial factor. 

---


# Todos in R2prime calculation

## Known Issues and ToDos

### Current Limitations & planned improvements

1. **Hard-coded paths**
   - see in the T2 processing Todo-list

1. **Output Directory Constraint**
   - R2' calculation fails in the last step if output directory is not empty.
   - Must manually clear directory or use different output path
   - This should be checked before submitting the job or the data in the output dir should be overwritten (create overwrite flag)
   - **Solution:**
      - Implement `-f` or `--force` flag to overwrite existing outputs
      - Better handling of re-processing scenarios

2. **Cleanup Script Sharing**
   - Session and final cleanup scripts are shared with T2 processing
   - directory structure may be adjusted for more clarity

3. **Container Integration**
   - Currently supports both custom containers and CBS modules
   - Consolidate to single container approach
   - MATLAB/SPM are not available as container yet

### Future Enhancements

1. **Automated QC Metrics**
   - Calculate coregistration quality metrics
   - Automated detection of alignment failures
   - Summary statistics for R2' value ranges (e.g., in GM, WM, and other regions with known value ranges)

2. **Other ideas**
   - Support for group-level processing summaries
   - Automated detection and correction of common errors

---