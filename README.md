# r2_map_calculation
This script uses the PyMRItools by Jochen Schmidt (schmidt-jo) to calculate R2 maps from Multi-Echo Spin-Echo data.


+ Run one of the notebooks (`niklas_t2.ipynb` or `niklas_t2_3T.ipynb`)
    + `resample_afi_3D.sh` and `resample_afi_4D.sh` are used to resample volumes during the notebook execution
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

Building PyMRItools Apptainer Container

## Building the Container

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
apptainer exec pymritools.sif <command>
```
or
```bash
apptainer shell pymritools.sif
```

The container automatically activates the conda environment on execution.


# Script

- need to adjust path_db in `t2_calc_b1corr_t2fit.py`
- for the 3T data, autodmri does not work well. Therefore you have to manually draw noise masks.
