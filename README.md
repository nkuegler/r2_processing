# Current commands:

## Testing
<!-- ```
# 7T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 7 -sub sub-004 -ses ses-04 Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

# 3T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 3 -fa 60.0 -tr 3.0 -sub sub-001 -ses ses-05 -nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/manualNoiseMasks Prisma_fit /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/
``` -->


## Actual data processing
```
# 7T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 7 -sub sub-001,sub-002 -ses ses-04 -pw Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 7 -sub sub-003 -ses ses-03,ses-05,ses-06 -pw Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 7 -sub sub-004 -ses ses-02,ses-03,ses-04 -pw Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 7 -sub sub-005 -ses ses-03,ses-04,ses-05 -pw Terra /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

rm -rf /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/Supplementary

./r2prime_creation_main.sh -pw -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -pdw /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/LCPCA_distCorr/ -r2 /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ -r2s /data/pt_02262/data/TH_bids/bids/derivatives/LORAKS/derivatives/qMRI_noB1corr/ -o /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b7T/


# 3T
./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 3 -fa 60.0 -tr 3.0 -sub sub-001 -ses ses-05,ses-06,ses-07,ses-08,ses-09,ses-10 -pw -nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/manualNoiseMasks Prisma_fit /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 3 -fa 60.0 -tr 3.0 -sub sub-002 -ses ses-06,ses-07 -pw -nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/manualNoiseMasks Prisma_fit /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 3 -fa 60.0 -tr 3.0 -sub sub-003 -ses ses-04,ses-07 -pw -nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/manualNoiseMasks Prisma_fit /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

./t2_processing_main.sh -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -b 3 -fa 60.0 -tr 3.0 -sub sub-005 -ses ses-06,ses-07,ses-08,ses-09 -pw -nmd /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/manualNoiseMasks Prisma_fit /data/pt_02262/data/TH_bids/bids/ /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/

rm -rf /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/Supplementary

./r2prime_creation_main.sh -pw -cont /data/p_gr_weiskopf_software/singularity/pymritools.sif -pdw /data/pt_02262/data/TH_bids/bids/derivatives/LCPCA_distCorr/ -r2 /data/pt_02262/data/TH_bids/bids/derivatives/relax_R2/ -r2s /data/pt_02262/data/TH_bids/bids/derivatives/qMRI_noB1corr/ -o /data/pt_02262/data/TH_bids/bids/derivatives/r2prime/b3T/
```