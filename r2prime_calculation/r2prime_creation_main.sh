#!/bin/bash

# Script to cycle through a BIDS-like structure and submit SLURM jobs for R2' creation pipeline

usage() {
echo \
"
$(basename $0): Automatically finds and submits SLURM jobs for R2' (R2prime) creation pipeline on all anat directories within a BIDS-like structure.

USAGE:
    $(basename $0) [options] -cont <container_path> -pdw <pdw_dir> -r2 <r2_dir> -r2s <r2s_dir> -mese <mese_dir> -o <output_dir>

MANDATORY OPTIONS:
    -cont PATH | --container PATH: Path to Singularity container with FSL and coregistration tools
    -pdw DIR | --pdw-dir DIR: Reference directory containing BIDS-structured PDw echo data
    -r2 DIR | --r2-dir DIR: Input directory containing BIDS-structured R2 slab data
    -r2s DIR | --r2s-dir DIR: Directory containing BIDS-structured R2* map data
    -mese DIR | --mese-dir DIR: Directory containing BIDS-structured MESE echoes used for R2/T2 maps
    -o DIR | --output-dir DIR: Output directory for R2' maps

OPTIONAL OPTIONS:
    -h | --help: print help text and exit
    -t SECONDS | --delay SECONDS: delay between job submissions in seconds (default: 1)
    -sub SUBJECTS | --subjects SUBJECTS: comma-separated list (no spaces!) of subjects to process (e.g., sub-001,sub-002)
    -ses SESSIONS | --sessions SESSIONS: comma-separated list (no spaces!) of sessions to process (e.g., ses-01,ses-02)
                                        Note: -ses requires -sub to be specified
    -w DIR | --work-dir DIR: working directory for intermediate files (default: output_dir/Supplementary)
    -fp-pdw PATTERN | --fname-pattern PATTERN: filename pattern for PDw echo files (default: \"*acq-PDw*echo-*part-mag*.nii\")
    -fp-mese PATTERN | --fname-pattern-mese PATTERN: filename pattern for MESE echoes (default: \"*MESE*.nii*\")
    -pw | --preserve-workdir: preserve working directories after processing (default: working directories are deleted)
    --dry-run: show commands that would be executed without actually submitting jobs

DESCRIPTION:
    The script searches for directories matching the pattern: r2_dir/sub-*/ses-*/anat/ (for R2 slabs),
    pdw_dir/sub-*/ses-*/anat/ (for PDw echoes), r2s_dir/sub-*/ses-*/anat/ (for R2* maps), and
    mese_dir/sub-*/ses-*/anat/ (for MESE echoes) and submits a series of SLURM jobs
    for R2/T2 slab coregistration and R2' calculation in each matching directory quartet found.
    
    Processing pipeline:
    1. Reference image creation (sum of PDw echoes)
    2. Reference denoise + N4 bias correction and MESE echo summation + denoise + N4
    3. R2/T2 slab coregistration to reference image
    4. R2' calculation (R2* - R2)
    5. Session cleanup (removes intermediate files for each session)
    6. Final cleanup (removes remaining temporary directory structure)
    
    By default, intermediate files and working directories are automatically cleaned up
    after successful processing. Use --preserve-workdir to keep all intermediate files.

    If -sub is specified, the script processes only the specified subjects. If -ses is also specified,
    it only processes the specified sessions for those subjects. Without these flags, it processes
    all subjects and sessions that are present in all four input directories.

    The jobs for each session run sequentially with dependencies.
    
    Creates BIDS structure in output directory: output/sub-xxx/ses-xx/anat/

    All processing steps automatically generate BIDS-compliant JSON sidecar files alongside
    the imaging data, containing comprehensive processing metadata including input file names, software versions, and technical parameters for reproducibility.

EXAMPLES:
    $(basename $0) -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output
    $(basename $0) -sub "sub-001,sub-002" -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output
    $(basename $0) -sub "sub-001" -ses "ses-01,ses-02" -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output
    $(basename $0) -w /scratch/temp -fp-pdw "*PDw*echo*.nii" --fname-pattern-mese "*MESE*.nii*" -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output
    $(basename $0) -pw -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output
    $(basename $0) --dry-run -t 5 -cont /path/to/container.sif -pdw /data/pdw_echoes -r2 /data/r2_slabs -r2s /data/qMRI -mese /data/mese_echoes -o /data/output

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
"
}

# Default parameters
delay=1
dry_run=false
delete_workdir=true
container_path=""
pdw_dir=""
r2_dir=""
r2s_dir=""
mese_dir=""
output_dir=""
work_dir=""
subjects=""
sessions=""
fname_pattern="*acq-PDw*echo-*part-mag*.nii"
mese_fname_pattern="*MESE*.nii*"
pdw_echoes_sum_base="PDw_echoes_sum.nii"
mese_echoes_sum_base="MESE_echoes_sum.nii"
logs_dir="/data/u_kuegler_software/git/r2_processing/logs/r2prime_calc"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -cont|--container)
            container_path="$2"
            shift 2
            ;;
        -pdw|--pdw-dir)
            pdw_dir="$2"
            shift 2
            ;;
        -r2|--r2-dir)
            r2_dir="$2"
            shift 2
            ;;
        -r2s|--r2s-dir)
            r2s_dir="$2"
            shift 2
            ;;
        -mese|--mese-dir)
            mese_dir="$2"
            shift 2
            ;;
        -o|--output-dir)
            output_dir="$2"
            shift 2
            ;;
        -t|--delay)
            delay="$2"
            shift 2
            ;;
        -sub|--subjects)
            subjects="$2"
            shift 2
            ;;
        -ses|--sessions)
            sessions="$2"
            shift 2
            ;;
        -w|--work-dir)
            work_dir="$2"
            shift 2
            ;;
        -fp-pdw|--fname-pattern)
            fname_pattern="$2"
            shift 2
            ;;
        -fp-mese|--fname-pattern-mese)
            mese_fname_pattern="$2"
            shift 2
            ;;
        -pw|--preserve-workdir)
            delete_workdir=false
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -*)
            echo "Unknown option $1"
            usage
            exit 1
            ;;
        *)
            echo "Unexpected positional argument: $1"
            echo "All arguments must be specified with flags."
            usage
            exit 1
            ;;
    esac
done

# Validation
if [[ -z "$container_path" ]]; then
    echo "Error: Container path must be specified with -cont or --container"
    usage
    exit 1
fi

if [[ -z "$pdw_dir" ]]; then
    echo "Error: PDw directory must be specified with -pdw or --pdw-dir"
    usage
    exit 1
fi

if [[ -z "$r2_dir" ]]; then
    echo "Error: R2 directory must be specified with -r2 or --r2-dir"
    usage
    exit 1
fi

if [[ -z "$r2s_dir" ]]; then
    echo "Error: R2* directory must be specified with -r2s or --r2s-dir"
    usage
    exit 1
fi

if [[ -z "$mese_dir" ]]; then
    echo "Error: MESE directory must be specified with -mese or --mese-dir"
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "Error: Output directory must be specified with -o or --output-dir"
    usage
    exit 1
fi

if [[ ! -d "$pdw_dir" ]]; then
    echo "Error: PDw directory does not exist: $pdw_dir"
    exit 1
fi

if [[ ! -d "$r2_dir" ]]; then
    echo "Error: R2 directory does not exist: $r2_dir"
    exit 1
fi

if [[ ! -d "$r2s_dir" ]]; then
    echo "Error: R2* directory does not exist: $r2s_dir"
    exit 1
fi

if [[ ! -d "$mese_dir" ]]; then
    echo "Error: MESE directory does not exist: $mese_dir"
    exit 1
fi

if [[ ! -f "$container_path" ]]; then
    echo "Error: Container file does not exist: $container_path"
    exit 1
fi

# Add trailing slashes to directory paths for consistency
[[ "$pdw_dir" != */ ]] && pdw_dir="${pdw_dir}/"
[[ "$r2_dir" != */ ]] && r2_dir="${r2_dir}/"
[[ "$r2s_dir" != */ ]] && r2s_dir="${r2s_dir}/"
[[ "$mese_dir" != */ ]] && mese_dir="${mese_dir}/"
[[ "$output_dir" != */ ]] && output_dir="${output_dir}/"
[[ -n "$work_dir" && "$work_dir" != */ ]] && work_dir="${work_dir}/"

# Validate sessions flag usage
if [[ -n "$sessions" && -z "$subjects" ]]; then
    echo "Error: -ses/--sessions flag requires -sub/--subjects to be specified"
    usage
    exit 1
fi

# Validate numeric parameters
if ! [[ "$delay" =~ ^[0-9]+$ ]]; then
    echo "Error: Delay must be a positive integer"
    exit 1
fi

# Convert comma-separated subjects and sessions to arrays if specified
if [[ -n "$subjects" ]]; then
    IFS=',' read -ra subject_array <<< "$subjects"
else
    subject_array=()
fi

if [[ -n "$sessions" ]]; then
    IFS=',' read -ra session_array <<< "$sessions"
else
    session_array=()
fi

# Create output directory if it doesn't exist
if [[ ! -d "$output_dir" ]]; then
    echo "Creating output directory: $output_dir"
    if [[ "$dry_run" == "false" ]]; then
        mkdir -p "$output_dir"
    fi
fi

# Get the absolute path of the directory containing this script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define paths to SLURM scripts
ref_sum_script="$script_dir/ref_sum_echoes.sh"
coreg_script="$script_dir/coreg_r2_slab_slurm.sh"
denoise_script="$script_dir/denoise_n4_ref_mese.sh"
r2prime_script="$script_dir/r2prime_calc.sh"
session_cleanup_script="$script_dir/../slurm_cleanup_session.sh"
final_cleanup_script="$script_dir/../slurm_cleanup_final.sh"

# Verify required scripts exist
if [[ ! -f "$ref_sum_script" ]]; then
    echo "Error: Reference summation SLURM script not found at $ref_sum_script"
    exit 1
fi

if [[ ! -f "$coreg_script" ]]; then
    echo "Error: Coregistration SLURM script not found at $coreg_script"
    exit 1
fi

if [[ ! -f "$denoise_script" ]]; then
    echo "Error: Denoise/N4 SLURM script not found at $denoise_script"
    exit 1
fi

if [[ ! -f "$r2prime_script" ]]; then
    echo "Error: R2' calculation SLURM script not found at $r2prime_script"
    exit 1
fi

if [[ ! -f "$session_cleanup_script" ]]; then
    echo "Error: Session cleanup SLURM script not found at $session_cleanup_script"
    exit 1
fi

if [[ ! -f "$final_cleanup_script" ]]; then
    echo "Error: Final cleanup SLURM script not found at $final_cleanup_script"
    exit 1
fi

# Find all anat directories in the BIDS-like structure
echo "Searching for anat directories in:"
echo "  R2 data directory: $r2_dir"
echo "  PDw data directory: $pdw_dir"
echo "  R2* data directory: $r2s_dir"
echo "  MESE data directory: $mese_dir"
if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Filtering for subjects: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Filtering for sessions: ${session_array[*]}"
    fi
fi

anat_dirs=()

if [[ ${#subject_array[@]} -eq 0 ]]; then
    # No subject filter - find all anat directories that exist in r2_dir, pdw_dir, r2s_dir, and mese_dir
    while IFS= read -r -d '' anat_dir; do
        # Extract subject/session from r2_dir path
        if [[ $anat_dir =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
            subject="${BASH_REMATCH[1]}"
            session="${BASH_REMATCH[2]}"
            # Check if corresponding directories exist in pdw_dir, r2s_dir, and mese_dir
            pdw_anat_path="$pdw_dir/$subject/$session/anat"
            r2s_anat_path="$r2s_dir/$subject/$session/anat"
            mese_anat_path="$mese_dir/$subject/$session/anat"
            if [[ -d "$pdw_anat_path" && -d "$r2s_anat_path" && -d "$mese_anat_path" ]]; then
                anat_dirs+=("$anat_dir")
            fi
        fi
    done < <(find "$r2_dir" -maxdepth 3 -type d -path "*/sub-*/ses-*/anat" -print0 2>/dev/null)
else
    # Filter by specified subjects and optionally sessions
    for subject in "${subject_array[@]}"; do
        if [[ ${#session_array[@]} -eq 0 ]]; then
            # Process all sessions for this subject
            while IFS= read -r -d '' anat_dir; do
                # Check if corresponding directories exist in pdw_dir, r2s_dir, and mese_dir
                if [[ $anat_dir =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
                    subject_match="${BASH_REMATCH[1]}"
                    session_match="${BASH_REMATCH[2]}"
                    pdw_anat_path="$pdw_dir/$subject_match/$session_match/anat"
                    r2s_anat_path="$r2s_dir/$subject_match/$session_match/anat"
                    mese_anat_path="$mese_dir/$subject_match/$session_match/anat"
                    if [[ -d "$pdw_anat_path" && -d "$r2s_anat_path" && -d "$mese_anat_path" ]]; then
                        anat_dirs+=("$anat_dir")
                    fi
                fi
            done < <(find "$r2_dir" -maxdepth 3 -type d -path "*/${subject}/ses-*/anat" -print0 2>/dev/null)
        else
            # Process only specified sessions for this subject
            for session in "${session_array[@]}"; do
                anat_path="$r2_dir/$subject/$session/anat"
                pdw_anat_path="$pdw_dir/$subject/$session/anat"
                r2s_anat_path="$r2s_dir/$subject/$session/anat"
                mese_anat_path="$mese_dir/$subject/$session/anat"
                if [[ -d "$anat_path" && -d "$pdw_anat_path" && -d "$r2s_anat_path" && -d "$mese_anat_path" ]]; then
                    anat_dirs+=("$anat_path")
                fi
            done
        fi
    done
fi

if [[ ${#anat_dirs[@]} -eq 0 ]]; then
    if [[ ${#subject_array[@]} -gt 0 ]]; then
        echo "Error: No matching anat directory quartets found for specified subjects/sessions"
        echo "Subjects: ${subject_array[*]}"
        if [[ ${#session_array[@]} -gt 0 ]]; then
            echo "Sessions: ${session_array[*]}"
        fi
    else
        echo "Error: No matching anat directory quartets found"
        echo "Pattern: */sub-*/ses-*/anat in r2_dir, pdw_dir, r2s_dir, and mese_dir"
    fi
    echo "Please check that all four directories contain the expected BIDS-like structure"
    exit 1
fi

echo "Found ${#anat_dirs[@]} matching anat directory quartets to process"
echo "Processing parameters:"
echo "  Container: $container_path"
echo "  PDw directory: $pdw_dir"
echo "  R2 directory: $r2_dir"
echo "  R2* directory: $r2s_dir"
echo "  MESE directory: $mese_dir"
echo "  Output directory: $output_dir"
echo "  PDw filename pattern: $fname_pattern"
echo "  MESE filename pattern: $mese_fname_pattern"
if [[ -n "$work_dir" ]]; then
    echo "  Working directory: $work_dir"
else
    echo "  Working directory: $output_dir/Supplementary"
fi
echo "Working directory cleanup: $(if [[ "$delete_workdir" == "true" ]]; then echo "ENABLED (default)"; else echo "DISABLED"; fi)"
if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Subjects filter: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Sessions filter: ${session_array[*]}"
    fi
fi

echo "=========================================="
echo "Directories to be processed:"
for anat_path in "${anat_dirs[@]}"; do
    if [[ $anat_path =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
        subject="${BASH_REMATCH[1]}"
        session="${BASH_REMATCH[2]}"
        echo "${subject}/${session}/anat"
    fi
done
echo "=========================================="

# Create working directory
if [[ -n "$work_dir" ]]; then
    working_dir="$work_dir"
else
    working_dir="$output_dir/Supplementary"
fi

if [[ "$dry_run" == "false" ]]; then
    mkdir -p "$working_dir"
fi

# Create logs directory
if [[ "$dry_run" == "false" ]]; then
    mkdir -p "$logs_dir"
fi

# Counter for job numbering
job_counter=1
total_sessions=${#anat_dirs[@]}
skipped_sessions=0

# Arrays to track job IDs for dependencies
declare -A ref_sum_job_ids
declare -A denoise_job_ids
declare -A coreg_job_ids
declare -A r2prime_job_ids

# Array to store session cleanup job IDs if cleanup is enabled
session_cleanup_job_ids=()

r2_suffix="R2map"
r2s_suffix="R2starmap"
r2p_suffix="R2primemap"
t2_suffix="T2map"


# Cycle through each anat directory and submit SLURM jobs
for anat_path in "${anat_dirs[@]}"; do
    echo
    echo "Processing anat directory: $anat_path (Session $job_counter/$total_sessions)"
    
    # Extract subject and session from the path
    if [[ $anat_path =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
        subject="${BASH_REMATCH[1]}"
        session="${BASH_REMATCH[2]}"
        
        # Create corresponding directory structure in output
        target_output_dir="$output_dir/$subject/$session/anat"
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$target_output_dir"
        fi

        # Create corresponding directory structure in working directory
        target_working_dir="$working_dir/$subject/$session/anat"
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$target_working_dir"
        fi
        
        # Create unique session identifier
        session_id="${subject}_${session}"

        pdw_echoes_sum_name="${subject}_${session}_${pdw_echoes_sum_base}"
        pdw_echoes_sum_n4_name="${subject}_${session}_${pdw_echoes_sum_base%.nii}_n4.nii"
        mese_echoes_sum_name="${subject}_${session}_${mese_echoes_sum_base}"
        mese_echoes_sum_n4_name="${subject}_${session}_${mese_echoes_sum_base%.nii}_n4.nii"
        
        # Get corresponding directories for PDw and MESE echoes
        pdw_anat_path="$pdw_dir/$subject/$session/anat"
        mese_anat_path="$mese_dir/$subject/$session/anat"
        
        echo "  Subject: $subject, Session: $session"
        # echo "  R2 slab directory: $anat_path"
        # echo "  PDw echo directory: $ref_anat_path"
        # echo "  Working directory: $target_working_dir"
        # echo "  Output directory: $target_output_dir"
        
        # ================================================================
        # JOB 1: REFERENCE IMAGE CREATION (sum of PDw echoes)
        # ================================================================
        echo "  Submitting reference image creation job..."

        ref_sum_cmd="sbatch -p short,group_servers,gr_weiskopf --output=\"$logs_dir/%j_createRef_${subject}_${session}.out\" \"$ref_sum_script\" \"$container_path\" \"$pdw_anat_path\" \"$target_working_dir\" \"$fname_pattern\" \"${pdw_echoes_sum_name}.gz\""

        if [[ "$dry_run" == "false" ]]; then
            # echo "    Command: $ref_sum_cmd"
            ref_sum_out=$(eval $ref_sum_cmd)
            # echo "    $ref_sum_out"
            
            if [[ $ref_sum_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                ref_sum_job_id="${BASH_REMATCH[1]}"
                echo "    Reference image creation job ID: $ref_sum_job_id"
                ref_sum_job_ids[$session_id]="$ref_sum_job_id"
            else
                echo "    Error: Could not extract reference image creation job ID"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: $ref_sum_cmd"
            ref_sum_job_ids[$session_id]="DRY_RUN_REF_SUM_JOB_ID"
        fi
        
        # ================================================================
        # JOB 2: REFERENCE DENOISE + N4 AND MESE ECHO SUMMATION + DENOISE + N4
        # ================================================================
        echo "  Submitting reference + MESE denoise + N4 correction job..."

        # Get dependency on reference image creation job
        ref_sum_job_id="${ref_sum_job_ids[$session_id]}"

        denoise_ref_img="$target_working_dir/$pdw_echoes_sum_name"
        denoise_cmd="sbatch -p short,group_servers,gr_weiskopf --dependency=afterok:$ref_sum_job_id --output=\"$logs_dir/%j_denoiseN4_${subject}_${session}.out\" \"$denoise_script\" \"$container_path\" \"$denoise_ref_img\" \"$mese_anat_path\" \"$target_working_dir\" \"$mese_fname_pattern\" \"${mese_echoes_sum_name}.gz\""
        
        if [[ "$dry_run" == "false" ]]; then
            # Check if MESE directory exists
            if [[ ! -d "$mese_anat_path" ]]; then
                echo "    Error: MESE directory not found: $mese_anat_path"
                ((skipped_sessions++))
                ((job_counter++))
                scancel "$ref_sum_job_id"
                echo "    Reference image creation job cancelled"
                continue
            fi

            # echo "    Command: $denoise_cmd"
            denoise_out=$(eval $denoise_cmd)
            # echo "    $denoise_out"

            if [[ $denoise_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                denoise_job_id="${BASH_REMATCH[1]}"
                echo "    Denoise + N4 job ID: $denoise_job_id (depends on job: $ref_sum_job_id)"
                denoise_job_ids[$session_id]="$denoise_job_id"
            else
                echo "    Error: Could not extract denoise job ID"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: $denoise_cmd"
            denoise_job_ids[$session_id]="DRY_RUN_DENOISE_JOB_ID"
        fi

        # ================================================================
        # JOB 3: R2 SLAB COREGISTRATION
        # ================================================================
        echo "  Submitting R2 slab coregistration job..."

        # Get dependency on denoise job
        denoise_job_id="${denoise_job_ids[$session_id]}"

        moving_img="$target_working_dir/$mese_echoes_sum_n4_name"
        ref_img="$target_working_dir/$pdw_echoes_sum_n4_name"
        r2_img="$anat_path/${subject}_${session}_${r2_suffix}.nii"
        t2_img="$anat_path/${subject}_${session}_${t2_suffix}.nii"

        # does not run in custom container for now
        # coregistered R2 is saved directly into the R2 input directory (anat_path)
        coreg_cmd="sbatch -p short,group_servers,gr_weiskopf --dependency=afterok:$denoise_job_id --output=\"$logs_dir/%j_coregR2_${subject}_${session}.out\" \"$coreg_script\" \"$moving_img\" \"$ref_img\" \"$target_working_dir\" \"$t2_img\" \"$r2_img\""

        if [[ "$dry_run" == "false" ]]; then

            # Check if coregistration input files exist
            if [[ ! -f "$r2_img" ]]; then
                echo "    Error: R2 map not found: $r2_img"
                ((skipped_sessions++))
                ((job_counter++))
                scancel "$ref_sum_job_id"
                scancel "$denoise_job_id"
                echo "    Reference image creation and denoise jobs cancelled"
                continue
            fi

            if [[ ! -f "$t2_img" ]]; then
                echo "    Error: T2 map not found: $t2_img"
                ((skipped_sessions++))
                ((job_counter++))
                scancel "$ref_sum_job_id"
                scancel "$denoise_job_id"
                echo "    Reference image creation and denoise jobs cancelled"
                continue
            fi

            # echo "    Command: $coreg_cmd"
            coreg_out=$(eval $coreg_cmd)
            # echo "    $coreg_out"
            
            if [[ $coreg_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                coreg_job_id="${BASH_REMATCH[1]}"
                echo "    R2 slab coregistration job ID: $coreg_job_id (depends on job: $denoise_job_id)"
                coreg_job_ids[$session_id]="$coreg_job_id"
            else
                echo "    Error: Could not extract coregistration job ID"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: $coreg_cmd"
            coreg_job_ids[$session_id]="DRY_RUN_COREG_JOB_ID"
        fi
        
        # ================================================================
        # JOB 4: R2 PRIME CALCULATION
        # ================================================================
        echo "  Submitting R2' calculation job..."
        
        # Get dependency on coregistration job
        coreg_job_id="${coreg_job_ids[$session_id]}"

        # Construct paths for R2' calculation
        r2_map="$target_working_dir/coreg_${subject}_${session}_${r2_suffix}.nii"
        r2star_map="$r2s_dir/$subject/$session/anat/${subject}_${session}_${r2s_suffix}.nii"
        fname_r2prime="${subject}_${session}_${r2p_suffix}.nii.gz" # only filename, no path

        r2prime_cmd="sbatch -p short,group_servers,gr_weiskopf --dependency=afterok:$coreg_job_id --output=\"$logs_dir/%j_calcR2prime_${subject}_${session}.out\" \"$r2prime_script\" \"$container_path\" \"$r2_map\" \"$r2star_map\" \"$target_working_dir\" \"$target_output_dir\" \"$fname_r2prime\""

        if [[ "$dry_run" == "false" ]]; then
            # Check if R2* map file exists
            if [[ ! -f "$r2star_map" ]]; then
                echo "    Error: R2* map not found: $r2star_map"
                ((skipped_sessions++))
                ((job_counter++))
                scancel "$ref_sum_job_id"
                scancel "$coreg_job_id"
                echo "    Reference image creation and coregistration jobs cancelled"
                continue
            fi

            # echo "    Command: $r2prime_cmd"
            r2prime_out=$(eval $r2prime_cmd)
            # echo "    $r2prime_out"
            
            if [[ $r2prime_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                r2prime_job_id="${BASH_REMATCH[1]}"
                echo "    R2' calculation job ID: $r2prime_job_id (depends on job: $coreg_job_id)"
                r2prime_job_ids[$session_id]="$r2prime_job_id"
            else
                echo "    Error: Could not extract R2' calculation job ID"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: $r2prime_cmd"
            r2prime_job_ids[$session_id]="DRY_RUN_R2PRIME_JOB_ID"
        fi

        # ================================================================
        # JOB 5: SESSION CLEANUP (if delete_workdir is enabled)
        # ================================================================
        if [[ "$delete_workdir" == "true" ]]; then
            echo "  Submitting session cleanup job..."
            
            # Get dependency on R2' calculation job
            r2prime_job_id="${r2prime_job_ids[$session_id]}"
            
            if [[ "$dry_run" == "false" ]]; then
                cleanup_cmd="sbatch -p short,group_servers,gr_weiskopf --dependency=afterok:$r2prime_job_id --time=10 --mem=1G --output=\"$logs_dir/%j_cleanup_${subject}_${session}.out\" \"$session_cleanup_script\" \"$subject\" \"$session\" \"$working_dir\""

                cleanup_out=$(eval $cleanup_cmd)
                
                if [[ $cleanup_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                    cleanup_job_id="${BASH_REMATCH[1]}"
                    echo "    Session cleanup job ID: $cleanup_job_id (depends on job: $r2prime_job_id)"
                    session_cleanup_job_ids+=("$cleanup_job_id")
                else
                    echo "    Warning: Could not extract session cleanup job ID"
                fi
            else
                echo "    DRY RUN: Would submit session cleanup job for: $subject/$session in $working_dir"
                session_cleanup_job_ids+=("DRY_RUN_SESSION_CLEANUP_${session_id}")
            fi
        fi

        
        # Add delay between session processing (except for the last session)
        if [[ $job_counter -lt $total_sessions ]]; then
            if [[ "$dry_run" == "false" ]]; then
                if [[ $delay -gt 0 ]]; then
                    echo "  Waiting $delay seconds before next submission..."
                    sleep $delay
                fi
            fi
        fi
        
        ((job_counter++))
    else
        echo "  Warning: Could not extract subject/session from path: $anat_path"
        ((skipped_sessions++))
        ((job_counter++))
        continue
    fi
done

# ================================================================
# FINAL CLEANUP JOB (if delete_workdir is enabled and session cleanup jobs exist)
# ================================================================
if [[ "$delete_workdir" == "true" && \
      ${#session_cleanup_job_ids[@]} -gt 0 && \
      $((total_sessions - skipped_sessions)) -gt 0 ]]; then
    
    echo
    echo "--------------------------------------"
    echo "Creating final cleanup job for remaining parts of the working directory..."
    
    if [[ "$dry_run" == "false" ]]; then
        # Join all session cleanup job IDs with colons for dependency
        cleanup_deps=$(IFS=:; echo "${session_cleanup_job_ids[*]}")
        final_cleanup_dependency="--dependency=afterok:$cleanup_deps"

        final_cleanup_cmd="sbatch -p short,group_servers,gr_weiskopf $final_cleanup_dependency --output=\"$logs_dir/%j_final_cleanup.out\" --time=10 --mem=1G \"$final_cleanup_script\" \"$working_dir\""

        echo "Submitting final cleanup job with dependency on ${#session_cleanup_job_ids[@]} session cleanup jobs..."
        final_cleanup_out=$(eval $final_cleanup_cmd)
        
        if [[ $final_cleanup_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
            final_cleanup_job_id="${BASH_REMATCH[1]}"
            echo "Final cleanup job ID: $final_cleanup_job_id (depends on session cleanup job(s): ${session_cleanup_job_ids[*]})"
            echo "   Will remove entire working directory: $working_dir after all sessions are processed."
        else
            echo "Warning: Could not extract final cleanup job ID"
        fi
    else
        echo "DRY RUN: Would submit final cleanup job that:"
        echo "  - Depends on ${#session_cleanup_job_ids[@]} session cleanup jobs"
        echo "  - Removes entire working directory: $working_dir"
    fi
elif [[ "$delete_workdir" == "true" ]]; then
    echo
    if [[ ${#session_cleanup_job_ids[@]} -eq 0 || $((total_sessions - skipped_sessions)) -eq 0 ]]; then
        echo "> No final cleanup needed - no sessions were processed successfully"
    fi
fi

echo
echo "=========================================="
echo "Total sessions found: $total_sessions"
echo "Sessions skipped: $skipped_sessions"
echo "Sessions processed: $((total_sessions - skipped_sessions))"
echo "Processing pipeline per session:"
echo "  1. Reference image creation (PDw echo summation)"
echo "  2. Reference denoise + N4 and MESE echo summation + denoise + N4"
echo "  3. R2/T2 slab coregistration to reference image"
echo "  4. R2' calculation (R2* - R2)"
if [[ "$delete_workdir" == "true" ]]; then
    echo "  5. Session cleanup → 6. Final cleanup (after all sessions)"
    echo "Working directory cleanup: ENABLED (default)"
else
    echo "Working directory cleanup: DISABLED (--preserve-workdir specified)"
fi
if [[ "$dry_run" == "false" ]]; then
    echo "Check job status with: squeue -u \$USER"
    echo "Monitor logs in the respective SLURM script log directories"
else
    echo "This was a dry run - no jobs were actually submitted"
fi
echo "=========================================="

