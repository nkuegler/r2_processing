#!/bin/bash

# Script to cycle through a BIDS-like structure and submit SLURM jobs for T2 processing pipeline

# Note: Removed 'set -e' to prevent premature exit during continue statements

usage() {
echo \
"
$(basename $0): Automatically finds and submits SLURM jobs for T2 processing pipeline on all anat directories within a BIDS-like structure.

USAGE:
    $(basename $0) [options] <scanner_name> <parent_directory> <output_directory>

OPTIONS:
    -h | --help: print help text and exit
    -t SECONDS | --delay SECONDS: delay between job submissions in seconds (default: 1)
    -sub SUBJECTS | --subjects SUBJECTS: comma-separated list (no spaces!) of subjects to process (e.g., sub-001,sub-002)
    -ses SESSIONS | --sessions SESSIONS: comma-separated list (no spaces!) of sessions to process (e.g., ses-01,ses-02)
                                        Note: -ses requires -sub to be specified
    -cont CONTAINER_PATH | --container CONTAINER_PATH: path to Singularity container (required)
    -b FIELD | --magnetic-field FIELD: magnetic field strength in Tesla (default: 7)
    -fa ANGLE | --flip-angle ANGLE: flip angle in degrees (default: 55.0)
    -tr RATIO | --tr-ratio RATIO: TR ratio value (default: 5.0)
    --d | --delete-workdir: delete working directories after processing
    --dry-run: show commands that would be executed without actually submitting jobs

ARGUMENTS:
    scanner_name: Scanner/system name (Connectom, Prisma_fit, Skyra_fit, Verio, Magnetom7T, Terra, etc.)
    parent_directory: Parent directory containing BIDS-structured data
    output_directory: Output directory for processed results

DESCRIPTION:
    The script searches for directories matching the pattern: parent_directory/sub-*/ses-*/anat/
    and submits a series of SLURM jobs for T2 processing pipeline in each anat directory found.
    
    Processing pipeline:
    1. Denoising (Python) - runs first
    2. Gradient non-linearity correction (bash) - depends on denoising job
    3. T2 fitting (Python) - depends on gradient correction job
    
    If -sub is specified, only processes the specified subjects. If -ses is also specified,
    only processes the specified sessions for those subjects. Without these flags, processes
    all subjects and sessions found.

    The jobs for each session run sequentially with dependencies.
    
    Creates BIDS structure in output directory: output/sub-xxx/ses-xx/anat/

EXAMPLES:
    $(basename $0) -cont /path/to/container.sif Prisma /data/input /data/output
    $(basename $0) -cont /path/to/container.sif -b 3 -fa 20 -tr 6 Terra /data/input /data/output
    $(basename $0) -cont /path/to/container.sif -sub \"sub-001,sub-002\" Prisma /data/input /data/output
    $(basename $0) -cont /path/to/container.sif -sub \"sub-001\" -ses \"ses-01,ses-02\" Terra /data/input /data/output
    $(basename $0) -cont /path/to/container.sif --dry-run -t 10 Prisma_fit /data/input /data/output

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
"
}

# Default parameters
delay=1
dry_run=false
delete_workdir=false
scanner_name=""
parent_dir=""
output_dir=""
subjects=""
sessions=""
magnetic_field=7
flip_angle=55.0
tr_ratio=5.0
container_path=""

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
        -cont|--container)
            container_path="$2"
            shift 2
            ;;
        -b|--magnetic-field)
            magnetic_field="$2"
            shift 2
            ;;
        -fa|--flip-angle)
            flip_angle="$2"
            shift 2
            ;;
        -tr|--tr-ratio)
            tr_ratio="$2"
            shift 2
            ;;
        --d|--delete-workdir)
            delete_workdir=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -*)
            echo "Error: Unknown option $1"
            usage
            exit 1
            ;;
        *)
            # Accept scanner_name, parent_directory, then output_directory
            if [[ -z "$scanner_name" ]]; then
                scanner_name="$1"
                shift
            elif [[ -z "$parent_dir" ]]; then
                parent_dir="$1"
                shift
            elif [[ -z "$output_dir" ]]; then
                output_dir="$1"
                shift
            else
                echo "Error: Too many arguments specified"
                usage
                exit 1
            fi
            ;;
    esac
done

# Validation
if [[ -z "$container_path" ]]; then
    echo "Error: Container path must be specified with -cont/--container"
    usage
    exit 1
fi

if [[ -z "$scanner_name" ]]; then
    echo "Error: Scanner name must be specified"
    usage
    exit 1
fi

if [[ -z "$parent_dir" ]]; then
    echo "Error: Parent directory must be specified"
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "Error: Output directory must be specified"
    usage
    exit 1
fi

if [[ ! -d "$parent_dir" ]]; then
    echo "Error: Parent directory does not exist: $parent_dir"
    exit 1
fi

if [[ ! -f "$container_path" ]]; then
    echo "Error: Container file does not exist: $container_path"
    exit 1
fi

# Validate scanner name
valid_scanners=("Connectom" "Prisma_fit" "Skyra_fit" "Verio" "Magnetom7T" "Terra")
scanner_valid=false
for valid in "${valid_scanners[@]}"; do
    if [[ "$scanner_name" == "$valid" ]]; then
        scanner_valid=true
        break
    fi
done
if [[ "$scanner_valid" == "false" ]]; then
    echo "Error: Invalid scanner name '$scanner_name'. Must be one of: ${valid_scanners[*]}"
    exit 1
fi

# Validate sessions flag usage
if [[ -n "$sessions" && -z "$subjects" ]]; then
    echo "Error: -ses/--sessions flag requires -sub/--subjects to be specified"
    usage
    exit 1
fi

# Validate numeric parameters
if ! [[ "$magnetic_field" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Error: Magnetic field must be a number"
    exit 1
fi

if ! [[ "$flip_angle" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Error: Flip angle must be a number"
    exit 1
fi

if ! [[ "$tr_ratio" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Error: TR ratio must be a number"
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
gnlc_dir="/data/u_kuegler_software/git/batch_gnlc/correct_MagOnly/"

# Define paths to SLURM scripts
denoise_script="$script_dir/slurm_denoise_nbc.sh"
gnlc_script="$gnlc_dir/call_slurm_batch_magn.sh" # calls SLURM script
t2fit_script="$script_dir/slurm_b1corr_t2fit.sh" 

if [[ ! -f "$denoise_script" ]]; then
    echo "Error: Denoising SLURM script not found at $denoise_script"
    exit 1
fi

if [[ ! -f "$gnlc_script" ]]; then
    echo "Error: GNLC SLURM script not found at $gnlc_script"
    exit 1
fi

if [[ ! -f "$t2fit_script" ]]; then
    echo "Error: T2 fitting SLURM script not found at $t2fit_script"
    exit 1
fi

# Find all anat directories in the BIDS-like structure
echo "Searching for anat directories in: $parent_dir"
if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Filtering for subjects: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Filtering for sessions: ${session_array[*]}"
    fi
fi

anat_dirs=()

if [[ ${#subject_array[@]} -eq 0 ]]; then
    # No subject filter - find all anat directories
    while IFS= read -r -d '' anat_dir; do
        anat_dirs+=("$anat_dir")
    done < <(find "$parent_dir" -maxdepth 3 -type d -path "*/sub-*/ses-*/anat" -print0 2>/dev/null)
else
    # Filter by specified subjects and optionally sessions
    for subject in "${subject_array[@]}"; do
        if [[ ${#session_array[@]} -eq 0 ]]; then
            # No session filter - find all sessions for this subject
            while IFS= read -r -d '' anat_dir; do
                anat_dirs+=("$anat_dir")
            done < <(find "$parent_dir" -maxdepth 3 -type d -path "*/${subject}/ses-*/anat" -print0 2>/dev/null)
        else
            # Filter by specific sessions for this subject
            for session in "${session_array[@]}"; do
                while IFS= read -r -d '' anat_dir; do
                    anat_dirs+=("$anat_dir")
                done < <(find "$parent_dir" -maxdepth 3 -type d -path "*/${subject}/${session}/anat" -print0 2>/dev/null)
            done
        fi
    done
fi

if [[ ${#anat_dirs[@]} -eq 0 ]]; then
    if [[ ${#subject_array[@]} -gt 0 ]]; then
        echo "Error: No anat directories found for specified subjects/sessions"
        echo "Subjects: ${subject_array[*]}"
        if [[ ${#session_array[@]} -gt 0 ]]; then
            echo "Sessions: ${session_array[*]}"
        fi
    else
        echo "Error: No anat directories found matching pattern: */sub-*/ses-*/anat"
    fi
    echo "Please check that the parent directory contains the expected BIDS-like structure"
    exit 1
fi

echo "Found ${#anat_dirs[@]} anat directories to process"
echo "Processing parameters:"
echo "  Container: $container_path"
echo "  Scanner: $scanner_name"
echo "  Magnetic field: ${magnetic_field}T"
echo "  Flip angle: ${flip_angle}°"
echo "  TR ratio: ${tr_ratio}"
echo "Working directory cleanup: $(if [[ "$delete_workdir" == "true" ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
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

# Counter for job numbering
job_counter=1
total_sessions=${#anat_dirs[@]}
skipped_sessions=0

# Array to track job IDs for dependencies
declare -A denoise_job_ids
declare -A gnlc_job_ids
declare -A t2fit_job_ids

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
        
        # Create working directory
        working_dir="$target_output_dir/Supplementary"
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$working_dir"
        fi
        
        # Create unique session identifier
        session_id="${subject}_${session}"
        
        echo "  Subject: $subject, Session: $session"
        echo "  Input directory: $anat_path"
        echo "  Output directory: $target_output_dir"
        echo "  Working directory: $working_dir"
        
        # ================================================================
        # JOB 1: DENOISING
        # ================================================================
        echo "  Submitting denoising job..."

        denoise_cmd="sbatch -p short,group_servers,gr_weiskopf \"$denoise_script\" \"$container_path\" \"$subject\" \"$session\" \"$magnetic_field\" \"$parent_dir\" \"$output_dir\""

        if [[ "$dry_run" == "false" ]]; then
            out=$(eval $denoise_cmd)
            echo "    $out"
            
            # Extract job ID from sbatch output
            if [[ $out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                denoise_job_id="${BASH_REMATCH[1]}"
                denoise_job_ids[$session_id]="$denoise_job_id"
                echo "    Denoising job ID: $denoise_job_id"
            else
                echo "    Error: Could not extract job ID from sbatch output"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: Would submit denoising job with command:" 
            echo "    $denoise_cmd"
            denoise_job_ids[$session_id]="DRY_RUN_DENOISE_JOB_ID"
        fi
        
        # ================================================================
        # JOB 2: GRADIENT NON-LINEARITY CORRECTION
        # ================================================================
        echo "  Submitting gradient non-linearity correction job..."
        
        # Get dependency on denoising job
        denoise_job_id="${denoise_job_ids[$session_id]}"
        
        # define settings for GNLC
        contrast_mese="_proc-denoisedNbc" # file_pattern="${contrast}*${pattern}"
        file_pattern_mese="MESE"
        output_dir_mese="$output_dir" # use the parent output directory here!

        contrast_afi="acq-stx4D_TB1" # file_pattern="${contrast}*${pattern}"
        file_pattern_afi="AFI" # has to be chosen like this to avoid the resampled AFI to be included
        output_dir_afi="$output_dir" # use the parent output directory here!
        
        # Define GNLC commands
        gnlc_cmd_mese="bash $gnlc_script -c $contrast_mese -p $file_pattern_mese -sub $subject -ses $session -dep $denoise_job_id $scanner_name $parent_dir $output_dir_mese"
        gnlc_cmd_afi="bash $gnlc_script -c $contrast_afi -p $file_pattern_afi -sub $subject -ses $session -dep $denoise_job_id $scanner_name $parent_dir $output_dir_afi"
        
        if [[ "$dry_run" == "false" ]]; then
            # Array to collect all job IDs from MESE and AFI GNLC calls
            all_gnlc_job_ids=()
            
            # ============================================================
            # MESE GNLC CALL
            # ============================================================
            echo "    Running MESE GNLC call..."
            gnlc_call_mese=$($gnlc_cmd_mese)
            
            # Extract job IDs from MESE GNLC call
            mese_job_ids=()
            while IFS= read -r line; do
                if [[ $line =~ Job\ ([0-9]+)\ submitted ]]; then
                    mese_gnlc_job_id="${BASH_REMATCH[1]}"
                    mese_job_ids+=("$mese_gnlc_job_id")
                    all_gnlc_job_ids+=("$mese_gnlc_job_id")
                    echo "    Captured GNLC job ID (MESE): $mese_gnlc_job_id"
                fi
            done <<< "$gnlc_call_mese"
            
            # Check if we got any job IDs from MESE call
            if [[ ${#mese_job_ids[@]} -eq 0 ]]; then
                echo "    WARNING: No job IDs found in MESE GNLC call script output. Skipping session."
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
            
            # ============================================================
            # AFI GNLC CALL (parallel to MESE)
            # ============================================================
            echo "    Running AFI GNLC call..."

            gnlc_call_afi=$($gnlc_cmd_afi)

            # Extract job IDs from AFI GNLC call
            afi_job_ids=()
            while IFS= read -r line; do
                if [[ $line =~ Job\ ([0-9]+)\ submitted ]]; then
                    afi_gnlc_job_id="${BASH_REMATCH[1]}"
                    afi_job_ids+=("$afi_gnlc_job_id")
                    all_gnlc_job_ids+=("$afi_gnlc_job_id")
                    echo "    Captured GNLC job ID (AFI): $afi_gnlc_job_id"
                fi
            done <<< "$gnlc_call_afi"

            # Check if we got any job IDs from AFI call
            if [[ ${#afi_job_ids[@]} -eq 0 ]]; then
                echo "    WARNING: No job IDs found in AFI GNLC call script output. Skipping session."
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi

            # Store all job IDs for this session (comma-separated for multiple jobs)
            IFS=',' gnlc_job_ids_string="${all_gnlc_job_ids[*]}"
            gnlc_job_ids[$session_id]="$gnlc_job_ids_string"
            echo "    All GNLC job IDs: ${all_gnlc_job_ids[*]} (depends on successful job: $denoise_job_id)"
        else
            echo "    DRY RUN: Would run GNLC call script for MESE data with the following command:"
            echo "    $gnlc_cmd_mese"
            echo "    DRY RUN: Would run GNLC call script for AFI data with the following command:"
            echo "    $gnlc_cmd_afi"
            echo "    DRY RUN: Jobs would depend on successful denoising job: $denoise_job_id"
            gnlc_job_ids[$session_id]="DRY_RUN_GNLC_JOB_ID1,DRY_RUN_GNLC_JOB_ID2"
        fi 

        
        # ================================================================
        # JOB 3: B1+ CORRECTION and T2 FITTING
        # ================================================================
        echo "  Submitting B1+ correction and T2 fitting job..."

        # Get dependency on all GNLC jobs
        gnlc_job_ids_string="${gnlc_job_ids[$session_id]}"
        IFS=',' read -ra gnlc_job_ids_array <<< "$gnlc_job_ids_string"
        
        # Build dependency string for multiple jobs
        if [[ ${#gnlc_job_ids_array[@]} -gt 1 ]]; then
            # Multiple jobs - create dependency on all of them
            dependency_list=$(IFS=':'; echo "${gnlc_job_ids_array[*]}")
            t2fit_dependency="--dependency=afterok:$dependency_list"
        else
            # Single job
            t2fit_dependency="--dependency=afterok:${gnlc_job_ids_array[0]}"
        fi


        t2fit_cmd="sbatch -p short,group_servers,gr_weiskopf $t2fit_dependency \"$t2fit_script\" \"$container_path\" \"$subject\" \"$session\" \"$magnetic_field\" \"$parent_dir\" \"$output_dir\" \"$tr_ratio\" \"$flip_angle\" \"$delete_workdir\""
        
        if [[ "$dry_run" == "false" ]]; then
            out=$(eval $t2fit_cmd)
            echo "    $out"
            
            # Extract job ID from sbatch output
            if [[ $out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                t2fit_job_id="${BASH_REMATCH[1]}"
                t2fit_job_ids[$session_id]="$t2fit_job_id"
                echo "    T2 fitting job ID: $t2fit_job_id (depends on successful jobs: ${gnlc_job_ids_array[*]})"
            else
                echo "    Error: Could not extract job ID from sbatch output"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: Would submit T2 fitting job with command:" 
            echo "    $t2fit_cmd"
            echo "    DRY RUN: Job would depend on successful GNLC jobs: ${gnlc_job_ids_array[*]}"
            t2fit_job_ids[$session_id]="DRY_RUN_T2FIT_JOB_ID"
        fi
        
        # Add delay between session processing (except for the last session)
        if [[ $job_counter -lt $total_sessions ]]; then
            echo "  Waiting ${delay}s before processing next session..."
            if [[ "$dry_run" == "false" ]]; then
                sleep "$delay"
            fi
        fi
        
        ((job_counter++))
    else
        echo "Warning: Could not extract subject/session from path: $anat_path"
        echo "Skipping this directory..."
        ((skipped_sessions++))
        continue
    fi
done

echo
echo "=========================================="
echo "T2 processing pipeline submission completed!"
echo "Total sessions found: $total_sessions"
echo "Sessions skipped: $skipped_sessions"
echo "Sessions processed: $((total_sessions - skipped_sessions))"
echo "Processing pipeline per session:"
echo "  1. Denoising → 2. Gradient non-linearity correction → 3. B1+ correction and T2 fitting"
if [[ "$dry_run" == "false" ]]; then
    echo "Check job status with: squeue -u \$USER"
    echo "Monitor logs in the respective SLURM script log directories"
else
    echo "This was a dry run - no jobs were actually submitted"
fi
echo "=========================================="
