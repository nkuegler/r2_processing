function coreg_r2_slab(moving, reference)

    %% CO-REGISTRATION BATCH CREATION
    % Creates an SPM batch structure for co-registration of functional/structural images
    %
    % This function generates an SPM batch job to perform co-registration of a moving
    % image file to a reference image file. The co-registration process aligns the
    % moving image to match the spatial orientation and position of the reference image.
    %
    % INPUTS:
    %   moving    - String or char array specifying the full path to the moving 
    %               image file that will be co-registered (moved to align with reference)
    %   reference - String or char array specifying the full path to the reference 
    %               image file that serves as the target for alignment
    %
    % OUTPUTS:
    %   None - The function creates a matlab batch and runs it. The output of the 
    %          co-registration will be saved to the same directory as the moving file 
    %          with a prefix 'coreg_'.
    %
    % EXAMPLE:
    %   coreg_r2_slab('/path/to/moving.nii', '/path/to/reference.nii');
    %
    % NOTE:
    %   - Adds SPM12 to the MATLAB path
    %   - Input files should be in a format supported by SPM (e.g., NIfTI)
    %   - The moving file will be resliced to match the reference file's orientation and resolution
    %   - Uses SPM's 'estwrite' option which estimates transformation and writes resliced image
    %   - Uses 4th degree B-spline interpolation for high-quality reslicing
    %   - Uses normalized mutual information as cost function for robust alignment
    %   - Uses custom prefix 'coreg_' for the co-registered image instead of SPM's default 'r' prefix
    %   - Performs rigid body transformation (6 degrees of freedom: 3 translations + 3 rotations)

    addpath('/data/u_kuegler_software/git/spm12');

    %%%%%%%% !!! If parameters of the co-registration are changed, update the JSON file creation section in the coreg_r2_slab_slurm.sh accordingly !!! %%%%%%%%

    % Create maps
    % spm fmri % show spm progresses
    clear matlabbatch
    spm_jobman('initcfg') ;

    matlabbatch{1}.spm.spatial.coreg.estwrite.ref = cellstr(reference);
    matlabbatch{1}.spm.spatial.coreg.estwrite.source = cellstr(moving);
    matlabbatch{1}.spm.spatial.coreg.estwrite.other = {''};
    matlabbatch{1}.spm.spatial.coreg.estwrite.eoptions.cost_fun = 'nmi';
    matlabbatch{1}.spm.spatial.coreg.estwrite.eoptions.sep = [4 2 1 0.6];
    matlabbatch{1}.spm.spatial.coreg.estwrite.eoptions.tol = [0.02 0.02 0.02 0.001 0.001 0.001 0.01 0.01 0.01 0.001 0.001 0.001];
    matlabbatch{1}.spm.spatial.coreg.estwrite.eoptions.fwhm = [7 7];
    matlabbatch{1}.spm.spatial.coreg.estwrite.roptions.interp = 4;
    matlabbatch{1}.spm.spatial.coreg.estwrite.roptions.wrap = [0 0 0];
    matlabbatch{1}.spm.spatial.coreg.estwrite.roptions.mask = 0;
    matlabbatch{1}.spm.spatial.coreg.estwrite.roptions.prefix = 'coreg_';


    spm_jobman('run', matlabbatch) % run batch
end
