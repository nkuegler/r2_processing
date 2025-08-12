#!/bin/bash

# Script to cycle through a BIDS-like structure and submit SLURM jobs for R2 slab coregistration pipeline

usage() {
echo \
"
$(basename $0): Automatically finds and submits SLURM jobs for R2 slab coregistration pipeline on all anat directories within a BIDS-like structure.

USAGE:
    $(basename $0) [options] <container_path> <ref_dir> <input_dir> <output_dir>

OPTIONS:
    -h | --help: print help text and exit
    -t SECONDS | --delay SECONDS: delay between job submissions in seconds (default: 1)
    -sub SUBJECTS | --subjects SUBJECTS: comma-separated list (no spaces!) of subjects to process (e.g., sub-001,sub-002)
    -ses SESSIONS | --sessions SESSIONS: comma-separated list (no spaces!) of sessions to process (e.g., ses-01,ses-02)
                                        Note: -ses requires -sub to be specified
    -w DIR | --work-dir DIR: working directory for intermediate files (default: output_dir/Supplementary)
    -fp PATTERN | --fname-pattern PATTERN: filename pattern for echo files (default: \"*acq-PDw*echo-*part-mag*.nii\")
    --dry-run: show commands that would be executed without actually submitting jobs

ARGUMENTS:
    container_path: Path to Singularity container with FSL and coregistration tools
    ref_dir: Reference directory containing BIDS-structured PDw echo data
    input_dir: Input directory containing BIDS-structured R2 slab data
    output_dir: Output directory for coregistration results

DESCRIPTION:
    The script searches for directories matching the pattern: input_dir/sub-*/ses-*/anat/ (for R2 slabs)
    and ref_dir/sub-*/ses-*/anat/ (for PDw echoes) and submits a series of SLURM jobs for 
    R2 slab coregistration pipeline in each matching directory pair found.
    
    Processing pipeline:
    1. Reference image creation (sum of PDw echoes)
    2. R2 slab coregistration to reference image
    3. [Further processing steps to be added]
    
    If -sub is specified, only processes the specified subjects. If -ses is also specified,
    only processes the specified sessions for those subjects. Without these flags, processes
    all subjects and sessions found.

    The jobs for each session run sequentially with dependencies.
    
    Creates BIDS structure in output directory: output/sub-xxx/ses-xx/anat/

EXAMPLES:
    $(basename $0) /path/to/container.sif /data/pdw_echoes /data/r2_slabs /data/output
    $(basename $0) -sub \"sub-001,sub-002\" /path/to/container.sif /data/pdw_echoes /data/r2_slabs /data/output
    $(basename $0) -sub \"sub-001\" -ses \"ses-01,ses-02\" /path/to/container.sif /data/pdw_echoes /data/r2_slabs /data/output
    $(basename $0) -w /scratch/temp --fname-pattern \"*PDw*echo*.nii\" /path/to/container.sif /data/pdw_echoes /data/r2_slabs /data/output
    $(basename $0) --dry-run -t 5 /path/to/container.sif /data/pdw_echoes /data/r2_slabs /data/output

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
"
}

# Default parameters
delay=1
dry_run=false
container_path=""
ref_dir=""
input_dir=""
output_dir=""
work_dir=""
subjects=""
sessions=""
fname_pattern="*acq-PDw*echo-*part-mag*.nii"
fname_ref_echoSum="PDw_echoes_sum.nii" 

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
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
        -fp|--fname-pattern)
            fname_pattern="$2"
            shift 2
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
            # Positional arguments
            if [[ -z "$container_path" ]]; then
                container_path="$1"
            elif [[ -z "$ref_dir" ]]; then
                ref_dir="$1"
            elif [[ -z "$input_dir" ]]; then
                input_dir="$1"
            elif [[ -z "$output_dir" ]]; then
                output_dir="$1"
            else
                echo "Too many positional arguments"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validation
if [[ -z "$container_path" ]]; then
    echo "Error: Container path must be specified"
    usage
    exit 1
fi

if [[ -z "$ref_dir" ]]; then
    echo "Error: Reference directory must be specified"
    usage
    exit 1
fi

if [[ -z "$input_dir" ]]; then
    echo "Error: Input directory must be specified"
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "Error: Output directory must be specified"
    usage
    exit 1
fi

if [[ ! -d "$ref_dir" ]]; then
    echo "Error: Reference directory does not exist: $ref_dir"
    exit 1
fi

if [[ ! -d "$input_dir" ]]; then
    echo "Error: Input directory does not exist: $input_dir"
    exit 1
fi

if [[ ! -f "$container_path" ]]; then
    echo "Error: Container file does not exist: $container_path"
    exit 1
fi

# Add trailing slashes to directory paths for consistency
[[ "$ref_dir" != */ ]] && ref_dir="${ref_dir}/"
[[ "$input_dir" != */ ]] && input_dir="${input_dir}/"
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

# Verify required scripts exist
if [[ ! -f "$ref_sum_script" ]]; then
    echo "Error: Reference summation SLURM script not found at $ref_sum_script"
    exit 1
fi

if [[ ! -f "$coreg_script" ]]; then
    echo "Error: Coregistration SLURM script not found at $coreg_script"
    exit 1
fi

# Find all anat directories in the BIDS-like structure
echo "Searching for anat directories in:"
echo "  R2 slab directory: $input_dir"
echo "  PDw data directory: $ref_dir"
if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Filtering for subjects: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Filtering for sessions: ${session_array[*]}"
    fi
fi

anat_dirs=()

if [[ ${#subject_array[@]} -eq 0 ]]; then
    # No subject filter - find all anat directories that exist in both input_dir and ref_dir
    while IFS= read -r -d '' anat_dir; do
        # Extract subject/session from input_dir path
        if [[ $anat_dir =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
            subject="${BASH_REMATCH[1]}"
            session="${BASH_REMATCH[2]}"
            # Check if corresponding directory exists in ref_dir
            ref_anat_path="$ref_dir/$subject/$session/anat"
            if [[ -d "$ref_anat_path" ]]; then
                anat_dirs+=("$anat_dir")
            fi
        fi
    done < <(find "$input_dir" -maxdepth 3 -type d -path "*/sub-*/ses-*/anat" -print0 2>/dev/null)
else
    # Filter by specified subjects and optionally sessions
    for subject in "${subject_array[@]}"; do
        if [[ ${#session_array[@]} -eq 0 ]]; then
            # Process all sessions for this subject
            while IFS= read -r -d '' anat_dir; do
                # Check if corresponding directory exists in ref_dir
                if [[ $anat_dir =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
                    subject_match="${BASH_REMATCH[1]}"
                    session_match="${BASH_REMATCH[2]}"
                    ref_anat_path="$ref_dir/$subject_match/$session_match/anat"
                    if [[ -d "$ref_anat_path" ]]; then
                        anat_dirs+=("$anat_dir")
                    fi
                fi
            done < <(find "$input_dir" -maxdepth 3 -type d -path "*/${subject}/ses-*/anat" -print0 2>/dev/null)
        else
            # Process only specified sessions for this subject
            for session in "${session_array[@]}"; do
                anat_path="$input_dir/$subject/$session/anat"
                ref_anat_path="$ref_dir/$subject/$session/anat"
                if [[ -d "$anat_path" && -d "$ref_anat_path" ]]; then
                    anat_dirs+=("$anat_path")
                fi
            done
        fi
    done
fi

if [[ ${#anat_dirs[@]} -eq 0 ]]; then
    if [[ ${#subject_array[@]} -gt 0 ]]; then
        echo "Error: No matching anat directory pairs found for specified subjects/sessions"
        echo "Subjects: ${subject_array[*]}"
        if [[ ${#session_array[@]} -gt 0 ]]; then
            echo "Sessions: ${session_array[*]}"
        fi
    else
        echo "Error: No matching anat directory pairs found"
        echo "Pattern: */sub-*/ses-*/anat in both input_dir and ref_dir"
    fi
    echo "Please check that both directories contain the expected BIDS-like structure"
    exit 1
fi

echo "Found ${#anat_dirs[@]} matching anat directory pairs to process"
echo "Processing parameters:"
echo "  Container: $container_path"
echo "  Reference directory (PDw echoes): $ref_dir"
echo "  Input directory (R2 slabs): $input_dir"
echo "  Output directory: $output_dir"
echo "  Filename pattern: $fname_pattern"
if [[ -n "$work_dir" ]]; then
    echo "  Working directory: $work_dir"
else
    echo "  Working directory: $output_dir/Supplementary"
fi
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

# Counter for job numbering
job_counter=1
total_sessions=${#anat_dirs[@]}
skipped_sessions=0

# Arrays to track job IDs for dependencies
declare -A ref_sum_job_ids
declare -A coreg_job_ids

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
        
        # Get corresponding reference directory for PDw echoes
        ref_anat_path="$ref_dir/$subject/$session/anat"
        
        echo "  Subject: $subject, Session: $session"
        # echo "  R2 slab directory: $anat_path"
        # echo "  PDw echo directory: $ref_anat_path"
        # echo "  Working directory: $target_working_dir"
        # echo "  Output directory: $target_output_dir"
        
        # ================================================================
        # JOB 1: REFERENCE IMAGE CREATION (sum of PDw echoes)
        # ================================================================
        echo "  Submitting reference image creation job..."

        ref_sum_cmd="sbatch -p short,group_servers,gr_weiskopf \"$ref_sum_script\" \"$container_path\" \"$ref_anat_path\" \"$target_working_dir\" \"$fname_pattern\" \"${fname_ref_echoSum}.gz\""

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
        # JOB 2: R2 SLAB COREGISTRATION
        # ================================================================
        echo "  Submitting R2 slab coregistration job..."
        
        # Get dependency on reference image creation job
        ref_sum_job_id="${ref_sum_job_ids[$session_id]}"

        coreg_moving_img="$anat_path/${subject}_${session}_R2map.nii"
        coreg_ref_img="$target_working_dir/$fname_ref_echoSum"

        # does not run in custom container for now
        coreg_cmd="sbatch -p short,group_servers,gr_weiskopf --dependency=afterok:$ref_sum_job_id \"$coreg_script\" \"$coreg_moving_img\" \"$coreg_ref_img\" \"$target_working_dir\""
        
        if [[ "$dry_run" == "false" ]]; then

            # Check if coregistration input files exist
            if [[ ! -f "$coreg_moving_img" ]]; then
                echo "    Error: Moving image not found: $coreg_moving_img"
                ((skipped_sessions++))
                ((job_counter++))
                scancel "$ref_sum_job_id"
                echo "    Reference image creation job cancelled"
                continue
            fi

            # echo "    Command: $coreg_cmd"
            coreg_out=$(eval $coreg_cmd)
            # echo "    $coreg_out"
            
            if [[ $coreg_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                coreg_job_id="${BASH_REMATCH[1]}"
                echo "    R2 slab coregistration job ID: $coreg_job_id (depends on job: $ref_sum_job_id)"
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
        # PLACEHOLDER: FUTURE PROCESSING STEPS
        # ================================================================
        echo "  [Further processing steps will be added here]"





        
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

echo
echo "=========================================="
echo "R2 slab coregistration pipeline submission completed!"
echo "Total sessions found: $total_sessions"
echo "Sessions skipped: $skipped_sessions"
echo "Sessions processed: $((total_sessions - skipped_sessions))"
echo "Processing pipeline per session:"
echo "  1. Reference image creation (PDw echo summation)"
echo "  2. R2 slab coregistration to reference image"
echo "  3. [Further processing steps to be added]"
if [[ "$dry_run" == "false" ]]; then
    echo "Check job status with: squeue -u \$USER"
    echo "Monitor logs in the respective SLURM script log directories"
else
    echo "This was a dry run - no jobs were actually submitted"
fi
echo "=========================================="

