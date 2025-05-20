#!/usr/bin/env python3


from pathlib import Path
import os


sub_ses_dict = {}
# sub_ses_dict['sub-001'] = ['ses-04']
# sub_ses_dict['sub-002'] = ['ses-04']
# sub_ses_dict['sub-003'] = ['ses-01', 'ses-03']
# sub_ses_dict['sub-004'] = ['ses-03', 'ses-04']
sub_ses_dict['sub-005'] = ['ses-03', 'ses-04', 'ses-05']


parent_dir = Path('/data/pt_02262/data/TH_bids')
r2prime_calc_script = Path('/data/u_kuegler_software/git/r2_map_calculation/r2prime_calc.sh')

for sub, ses_list in sub_ses_dict.items():
    for ses in ses_list:
        print("---------------------------")
        print(f"Processing {sub} {ses}")

        # Define the paths
        r2map = Path(f'/data/pt_02262/data/TH_bids/testdata_Taechang/dcm_imported/derivatives/relax_R2/{sub}/{ses}/fit_r2.nii')
        r2starmap = Path(f'/data/pt_02262/data/TH_bids/testdata_Taechang/LORAKS/derivatives/qMRI/{sub}/{ses}/anat/{sub}_{ses}_R2starmap.nii')
        interp_mode = 'BSpline'
        outputdir = Path(f'/data/pt_02262/data/TH_bids/testdata_Taechang/LORAKS/derivatives/R2prime/{sub}/{ses}')
        r2prime_fn = "R2prime.nii"

        # Call the bash script with the paths as arguments
        cmd = f'{r2prime_calc_script} {parent_dir} {r2map} {r2starmap} {interp_mode} {outputdir} {r2prime_fn}'
        os.system(cmd)

