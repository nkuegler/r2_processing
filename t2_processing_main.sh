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
    -w DIR | --work-dir DIR: working directory for intermediate files (default: output_directory/Supplementary). Three subdirectories will be created inside the working directory: denoise, gnlc, t2fit.
    -nmd | --noise-mask-dir DIR: directory containing noise masks (default: output_directory/manualNoiseMasks, only used for 3T data)
    -pw | --preserve-workdir: preserve working directories after processing (default: working directories are deleted)
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
    $(basename $0) -cont /path/to/container.sif -b 3 -fa 20 -tr 6 --noise-mask-dir /data/noise_masks Terra /data/input /data/output
    $(basename $0) -cont /path/to/container.sif -w /scratch/temp --preserve-workdir Prisma /data/input /data/output
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
delete_workdir=true
scanner_name=""
parent_dir=""
output_dir=""
work_dir=""
subjects=""
sessions=""
magnetic_field=7
flip_angle=55.0
tr_ratio=5.0
container_path=""
noise_mask_dir=""

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
        -w|--work-dir)
            work_dir="$2"
            shift 2
            ;;
        -nmd|--noise-mask-dir)
            noise_mask_dir="$2"
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

# Validate noise mask directory requirement for 3T data
if [[ "$magnetic_field" == "3" || "$magnetic_field" == "3.0" ]]; then
    # Set default noise mask directory if not specified
    if [[ -z "$noise_mask_dir" ]]; then
        noise_mask_dir="$output_dir/manualNoiseMasks"
    fi
    
    # Validate that the directory exists
    if [[ ! -d "$noise_mask_dir" ]]; then
        echo "Error: Noise mask directory does not exist: $noise_mask_dir"
        echo "For 3T data, please ensure the default noise mask directory exists or specify a different path with --noise-mask-dir"
        exit 1
    fi
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
session_cleanup_script="$script_dir/slurm_cleanup_session.sh"
final_cleanup_script="$script_dir/slurm_cleanup_final.sh"

# Define paths to SLURM bridge/intermediate scripts
gnlc_mese_bridge_script="$script_dir/slurm_bridge_gnlc_mese.sh"
gnlc_afi_bridge_script="$script_dir/slurm_bridge_gnlc_afi.sh"
final_cleanup_bridge_script="$script_dir/slurm_bridge_cleanup_final.sh"

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

if [[ ! -f "$session_cleanup_script" ]]; then
    echo "Error: Session cleanup SLURM script not found at $session_cleanup_script"
    exit 1
fi

if [[ ! -f "$final_cleanup_script" ]]; then
    echo "Error: Final cleanup SLURM script not found at $final_cleanup_script"
    exit 1
fi

if [[ ! -f "$gnlc_mese_bridge_script" ]]; then
    echo "Error: GNLC Mese bridge SLURM script not found at $gnlc_mese_bridge_script"
    exit 1
fi

if [[ ! -f "$gnlc_afi_bridge_script" ]]; then
    echo "Error: GNLC AFI bridge SLURM script not found at $gnlc_afi_bridge_script"
    exit 1
fi

if [[ ! -f "$final_cleanup_bridge_script" ]]; then
    echo "Error: Final cleanup bridge SLURM script not found at $final_cleanup_bridge_script"
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
if [[ -n "$noise_mask_dir" ]]; then
    echo "  Noise mask directory: $noise_mask_dir"
fi
if [[ -n "$work_dir" ]]; then
    echo "  Working directory: $work_dir"
else
    echo "  Working directory: $output_directory/Supplementary"
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

# create file to store job IDs
job_id_storage_dir="$working_dir/job_id_files"
if [[ "$dry_run" == "false" ]]; then
    mkdir -p "$job_id_storage_dir"
fi

cleanup_sess_id_file="$job_id_storage_dir/cleanup_session_ids.txt"
# Create or reset global cleanup file
if [[ -f "$cleanup_sess_id_file" ]]; then
    rm -f "$cleanup_sess_id_file"
fi
touch "$cleanup_sess_id_file"


# Counter for job numbering
job_counter=1
total_sessions=${#anat_dirs[@]}
skipped_sessions=0

# Array to track job IDs for dependencies
declare -A denoise_job_ids
declare -A gnlc_job_ids
declare -A t2fit_job_ids
session_cleanup_bridge_job_ids=()

# Cycle through each anat directory and submit SLURM jobs
for anat_path in "${anat_dirs[@]}"; do
    echo
    echo "Processing anat directory: $anat_path (Session $job_counter/$total_sessions)"
    
    # Extract subject and session from the path
    if [[ $anat_path =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
        subject="${BASH_REMATCH[1]}"
        session="${BASH_REMATCH[2]}"
        
        # Check for existing .nii files in working directory structure
        existing_files=$(find "$working_dir"/*/"$subject"/"$session"/anat -maxdepth 1 -name "*.nii*" 2>/dev/null | wc -l)
        if [[ $existing_files -gt 0 ]]; then
            echo "  Found $existing_files existing .nii files in $working_dir/*/$subject/$session/anat"
            echo "  Skipping this session."
            ((skipped_sessions++))
            ((job_counter++))
            continue
        fi

        # Create corresponding directory structure in output
        target_output_dir="$output_dir/$subject/$session/anat"
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$target_output_dir"
        fi
        
        # Create unique session identifier
        session_id="${subject}_${session}"

        # Create job ID storage file for this session
        job_id_file="$job_id_storage_dir/job_ids_${session_id}.txt"
        # Create or reset job file
        if [[ -f "$job_id_file" ]]; then
            rm -f "$job_id_file"
        fi
        touch "$job_id_file"
        
        echo "  Subject: $subject, Session: $session"
        echo "  Input directory: $anat_path"
        echo "  Output directory: $target_output_dir"
        echo "  Working directory: $working_dir"
        
        # ================================================================
        # JOB 1: DENOISING
        # ================================================================
        echo "  Submitting denoising job..."

        output_dir_denoise="$working_dir/denoise"
        
        denoise_cmd="sbatch -p short,group_servers,gr_weiskopf \"$denoise_script\" \"$container_path\" \"$subject\" \"$session\" \"$magnetic_field\" \"$parent_dir\" \"$output_dir_denoise\""
        # Add noise mask directory as last argument if specified (only relevant for 3T data)
        if [[ -n "$noise_mask_dir" ]]; then
            denoise_cmd="$denoise_cmd \"$noise_mask_dir\""
        fi

        if [[ "$dry_run" == "false" ]]; then
            out=$(eval $denoise_cmd)
            echo "    $out"
            
            # Extract job ID from sbatch output
            if [[ $out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                denoise_job_id="${BASH_REMATCH[1]}"
                denoise_job_ids[$session_id]="$denoise_job_id"
                echo "    Denoising job ID: $denoise_job_id"
            else
                echo "    Error: Could not extract denoising job ID from sbatch output"
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
        contrast_mese="proc-denoisedNbc" # file_pattern="${contrast}*${pattern}"
        file_pattern_mese="MESE"

        contrast_afi="acq-stx4D_TB1" # file_pattern="${contrast}*${pattern}"
        file_pattern_afi="AFI" # has to be chosen like this to avoid the resampled AFI to be included
        
        output_dir_gnlc="$working_dir/gnlc"

        # Generate unique job IDs for GNLC jobs
        timestamp=$(date +%s)
        random_suffix=$((RANDOM % 10000))
        mese_gnlc_job_name="gnlc_mese_${session_id}_${timestamp}_${random_suffix}"
        afi_gnlc_job_name="gnlc_afi_${session_id}_${timestamp}_$((random_suffix + 1))"
        
        # Define GNLC commands with predetermined job IDs
        # input and output directories are the working directory
        gnlc_slurm_log_dir="/data/u_kuegler_software/git/r2_map_calculation/logs/gnlc/"

        # container is currently not used in the GNLC script
        gnlc_cmd_mese="bash $gnlc_script -c $contrast_mese -p $file_pattern_mese -sub $subject -ses $session -job-name $mese_gnlc_job_name -log "$gnlc_slurm_log_dir/gnlc_mese_" $scanner_name $output_dir_denoise $output_dir_gnlc" # -container $container_path
        gnlc_cmd_afi="bash $gnlc_script -c $contrast_afi -p $file_pattern_afi -sub $subject -ses $session -job-name $afi_gnlc_job_name -log "$gnlc_slurm_log_dir/gnlc_afi_" $scanner_name $output_dir_denoise $output_dir_gnlc" # -container $container_path

        if [[ "$dry_run" == "false" ]]; then
            
            # ============================================================
            # INTERMEDIATE JOB FOR MESE GNLC
            # ============================================================
            echo "    Submitting intermediate job for MESE GNLC ..."
            
            # Submit bridge job
            bridge_mese_gnlc_out=$(sbatch -p short,group_servers,gr_weiskopf \
                --dependency=afterok:${denoise_job_id} \
                --job-name=bridge_mese_${session_id} \
                --output=/data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j_bridge_mese_${session_id}.out \
                "$gnlc_mese_bridge_script" \
                "$gnlc_cmd_mese")

            echo "    $bridge_mese_gnlc_out"
            echo "    MESE GNLC will use custom job name: $mese_gnlc_job_name"
            
            # ============================================================
            # INTERMEDIATE JOB FOR AFI GNLC
            # ============================================================
            echo "    Submitting intermediate job for AFI GNLC ..."
            
            # Submit bridge job
            bridge_afi_out=$(sbatch -p short,group_servers,gr_weiskopf \
                --dependency=afterok:${denoise_job_id} \
                --job-name=bridge_afi_${session_id} \
                --output=/data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j_bridge_afi_${session_id}.out \
                "$gnlc_afi_bridge_script" \
                "$gnlc_cmd_afi")

            echo "    $bridge_afi_out"
            echo "    AFI GNLC will use custom job name: $afi_gnlc_job_name"

            # Store bridge job IDs for this session (to track bridge job completion)
            gnlc_bridge_job_ids=()
            
            # Extract bridge job IDs from bridge job outputs
            if [[ $bridge_mese_gnlc_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                bridge_mese_id="${BASH_REMATCH[1]}"
                gnlc_bridge_job_ids+=("$bridge_mese_id")
            fi
            
            if [[ $bridge_afi_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                bridge_afi_id="${BASH_REMATCH[1]}"
                gnlc_bridge_job_ids+=("$bridge_afi_id")
            fi
            
            echo "    Bridge job IDs: ${gnlc_bridge_job_ids[*]} (will trigger GNLC jobs: $mese_gnlc_job_name, $afi_gnlc_job_name)"
            
            # Store for T2 fitting dependency
            gnlc_job_ids[$session_id]="${mese_gnlc_job_name},${afi_gnlc_job_name}"
        else
            echo "    DRY RUN: Would generate GNLC job names:"
            echo "      MESE GNLC Job name: $mese_gnlc_job_name"
            echo "      AFI GNLC Job name: $afi_gnlc_job_name"
            echo "    DRY RUN: Would submit bridge jobs with commands:"
            echo "      MESE: $gnlc_cmd_mese"
            echo "      AFI: $gnlc_cmd_afi"
            echo "    DRY RUN: Bridge jobs would depend on successful denoising job: $denoise_job_id"
            gnlc_job_ids[$session_id]="${mese_gnlc_job_name},${afi_gnlc_job_name}"
            gnlc_bridge_job_ids=("DRY_RUN_BRIDGE_MESE_ID" "DRY_RUN_BRIDGE_AFI_ID")
        fi 

        
        # ================================================================
        # JOB 3: B1+ CORRECTION and T2 FITTING
        # ================================================================
        echo "  Creating T2 fitting bridge job..."

        # takes input from output_dir_gnlc (and one file from output_dir_denoise)
        # uses working dir: working_dir_t2fit
        # outputs results to output_dir
        working_dir_t2fit="$working_dir/t2fit"

        # Generate unique job name for T2 fitting job
        t2fit_job_name="t2fit_${session_id}_${timestamp}"

        if [[ "$dry_run" == "false" ]]; then
            # Build dependency on bridge jobs
            bridge_dependency=""
            if [[ ${#gnlc_bridge_job_ids[@]} -gt 1 ]]; then
                dependency_list=$(IFS=':'; echo "${gnlc_bridge_job_ids[*]}")
                bridge_dependency="--dependency=afterok:$dependency_list"
            elif [[ ${#gnlc_bridge_job_ids[@]} -eq 1 ]]; then
                bridge_dependency="--dependency=afterok:${gnlc_bridge_job_ids[0]}"
            fi
            
            # Create T2 fitting bridge script
            t2fit_bridge_script="/tmp/bridge_t2fit_${session_id}_${timestamp}.sh"
            cat > "$t2fit_bridge_script" << EOF
#!/bin/bash
#SBATCH $bridge_dependency
#SBATCH --job-name=bridge_t2fit_${session_id}
#SBATCH --time=30
#SBATCH --mem=1G
#SBATCH --output=/data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j_bridge_t2fit_${session_id}.out

t2fit_job_name="$1"

echo "T2 fitting bridge job: Waiting for GNLC bridge jobs completion"
echo "Bridge jobs completed, waiting 10 seconds for GNLC jobs to start..."
sleep 10

echo "Extracting actual GNLC job IDs from squeue..."

# Function to get job ID by job name
get_job_id_by_name() {
    local job_name=\$1
    local max_attempts=30
    local attempt=1
    
    while [[ \$attempt -le \$max_attempts ]]; do
        # Get job ID for the specified job name
        job_id=\$(squeue -u \$USER --name="\$job_name" --noheader --format="%i" | head -n1 | tr -d ' ')
        
        if [[ -n "\$job_id" && "\$job_id" =~ ^[0-9]+\$ ]]; then
            echo "\$job_id"
            return 0
        fi
        
        echo "Attempt \$attempt: Job '\$job_name' not found in queue, waiting 5 seconds..." >&2
        sleep 5
        ((attempt++))
    done
    
    echo "Error: Could not find job ID for job name '\$job_name' after \$max_attempts attempts" >&2
    return 1
}

# Get actual job IDs
mese_gnlc_job_id=\$(get_job_id_by_name "$mese_gnlc_job_name")
afi_gnlc_job_id=\$(get_job_id_by_name "$afi_gnlc_job_name")

if [[ -z "\$mese_gnlc_job_id" || -z "\$afi_gnlc_job_id" ]]; then
    echo "Error: Could not extract GNLC job IDs"
    echo "MESE GNLC job ID: \$mese_gnlc_job_id"
    echo "AFI GNLC job ID: \$afi_gnlc_job_id"
    exit 1
fi

echo "Successfully extracted GNLC job IDs:"
echo "MESE GNLC job ID: \$mese_gnlc_job_id"
echo "AFI GNLC job ID: \$afi_gnlc_job_id"

# Submit T2 fitting job with dependency on actual GNLC job IDs
t2fit_dependency="--dependency=afterok:\${mese_gnlc_job_id}:\${afi_gnlc_job_id}"
t2fit_cmd="sbatch -p short,group_servers,gr_weiskopf \${t2fit_dependency} --gpus=1 --job-name=$t2fit_job_name \"$t2fit_script\" \"$container_path\" \"$subject\" \"$session\" \"$magnetic_field\" \"$output_dir_gnlc\" \"$working_dir_t2fit\" \"$output_dir\" \"$tr_ratio\" \"$flip_angle\" \"$output_dir_denoise\" \"$delete_workdir\""

echo "Submitting T2 fitting job with command:"
echo "\$t2fit_cmd"

echo "------------------------------"
t2fit_out=\$(eval \$t2fit_cmd)
# echo "T2 fitting job submission result: \$t2fit_out"

# Extract and log T2 fitting job ID
if [[ \$t2fit_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
    t2fit_job_id="\${BASH_REMATCH[1]}"
    echo "T2 fitting job ID: \$t2fit_job_id (job name: $t2fit_job_name, depends on GNLC jobs: \$mese_gnlc_job_id, \$afi_gnlc_job_id)"
    # echo "T2FIT_JOB_ID=\$t2fit_job_id" >> "$job_id_file"
else
    echo "Error: Could not extract T2 fitting job ID from sbatch output"
    exit 1
fi

# Clean up bridge script
rm -f "$t2fit_bridge_script"
EOF
            
            # Submit T2 fitting bridge job
            echo "    Submitting T2 fitting bridge job..."
            t2fit_bridge_out=$(sbatch -p short,group_servers,gr_weiskopf "$t2fit_bridge_script" "$t2fit_job_name")
            echo "    $t2fit_bridge_out"
            
            declare -A t2fit_bridge_job_ids

            if [[ $t2fit_bridge_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                t2fit_bridge_id="${BASH_REMATCH[1]}"
                echo "    T2 fitting bridge job ID: $t2fit_bridge_id (depends on GNLC bridge jobs: ${gnlc_bridge_job_ids[*]})"
                echo "    This bridge job will extract GNLC job IDs and submit the B1+ correction and T2 fitting job"
                t2fit_bridge_job_ids[$session_id]="$t2fit_bridge_id"
            else
                echo "    Error: Could not extract T2 fitting bridge job ID"
                ((skipped_sessions++))
                ((job_counter++))
                continue
            fi
        else
            echo "    DRY RUN: Would create T2 fitting bridge job that:"
            echo "      - Depends on bridge jobs: ${gnlc_bridge_job_ids[*]}"
            echo "      - Waits 10 seconds for GNLC jobs to start"
            echo "      - Extracts actual job IDs for: $mese_gnlc_job_name, $afi_gnlc_job_name"
            echo "      - Submits T2 fitting job with dependency on extracted GNLC job IDs"
            t2fit_bridge_job_ids[$session_id]="DRY_RUN_T2FIT_BRIDGE_JOB_ID"
        fi

        # ================================================================
        # JOB 4: SESSION CLEANUP (if delete_workdir is enabled)
        # ================================================================
        if [[ "$delete_workdir" == "true" ]]; then
            echo "  Creating session cleanup bridge job..."
            
            if [[ "$dry_run" == "false" ]]; then
                # Create session cleanup bridge script
                cleanup_bridge_script="/tmp/bridge_cleanup_${session_id}_${timestamp}.sh"
                cat > "$cleanup_bridge_script" << EOF
#!/bin/bash
#SBATCH --dependency=afterok:$t2fit_bridge_id
#SBATCH --job-name=bridge_cleanup_${session_id}
#SBATCH --time=30
#SBATCH --mem=1G
#SBATCH --output=/data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j_bridge_cleanup_${session_id}.out

t2fit_job_name="$1"


echo "Cleanup bridge job: Waiting for T2 fitting bridge job completion"
echo "T2 fitting bridge job completed, waiting 10 seconds for T2 fitting job to start..."
sleep 10

echo "Extracting actual T2 fitting job ID from squeue..."

# Function to get job ID by job name
get_job_id_by_name() {
    local job_name=\$1
    local max_attempts=30
    local attempt=1
    
    while [[ \$attempt -le \$max_attempts ]]; do
        # Get job ID for the specified job name
        job_id=\$(squeue -u \$USER --name="\$job_name" --noheader --format="%i" | head -n1 | tr -d ' ')
        
        if [[ -n "\$job_id" && "\$job_id" =~ ^[0-9]+\$ ]]; then
            echo "\$job_id"
            return 0
        fi
        
        echo "Attempt \$attempt: Job '\$job_name' not found in queue, waiting 5 seconds..." >&2
        sleep 5
        ((attempt++))
    done
    
    echo "Error: Could not find job ID for job name '\$job_name' after \$max_attempts attempts" >&2
    return 1
}

# Get actual T2 fitting job ID
t2fit_job_id=\$(get_job_id_by_name "$t2fit_job_name")

if [[ -z "\$t2fit_job_id" ]]; then
    echo "Error: Could not extract T2 fitting job ID"
    echo "T2 fitting job name: $t2fit_job_name"
    exit 1
fi

echo "Successfully extracted T2 fitting job ID: \$t2fit_job_id"

# Submit session cleanup job with dependency on actual T2 fitting job ID
cleanup_dependency="--dependency=afterok:\$t2fit_job_id"
cleanup_cmd="sbatch -p short,group_servers,gr_weiskopf \${cleanup_dependency} --job-name=cleanup_${session_id} --time=10 --mem=1G --output=/data/u_kuegler_software/git/r2_map_calculation/logs/denoise/%j_cleanup_${subject}_${session}.out \"$session_cleanup_script\" \"$subject\" \"$session\" \"$output_dir_denoise\" \"$output_dir_gnlc\" \"$working_dir_t2fit\""

echo "Submitting session cleanup job with command:"
echo "\$cleanup_cmd"

echo "------------------------------"
cleanup_out=\$(eval \$cleanup_cmd)
# echo "Session cleanup job submission result: \$cleanup_out"

# Extract and log cleanup job ID
if [[ \$cleanup_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
    cleanup_job_id="\${BASH_REMATCH[1]}"
    echo "Session cleanup job ID: \$cleanup_job_id (depends on T2 fitting job: \$t2fit_job_id)"
    echo "\$cleanup_job_id" >> "$cleanup_sess_id_file"
else
    echo "Error: Could not extract session cleanup job ID from sbatch output"
    exit 1
fi

# Clean up bridge script
rm -f "$cleanup_bridge_script"
EOF
                
                # Submit session cleanup bridge job
                cleanup_bridge_out=$(sbatch -p short,group_servers,gr_weiskopf "$cleanup_bridge_script" "$t2fit_job_name")
                echo "    $cleanup_bridge_out"
                
                if [[ $cleanup_bridge_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                    cleanup_bridge_job_id="${BASH_REMATCH[1]}"
                    session_cleanup_bridge_job_ids+=("$cleanup_bridge_job_id")
                    echo "    Session cleanup bridge job ID: $cleanup_bridge_job_id (depends on T2 fitting bridge job: $t2fit_bridge_id)"
                    echo "    This bridge job will extract T2 fitting job ID and submit session cleanup job"
                else
                    echo "    Warning: Could not extract session cleanup bridge job ID from sbatch output"
                fi
            else
                echo "    DRY RUN: Would create session cleanup bridge job that:"
                echo "      - Depends on T2 fitting bridge job completion"
                echo "      - Extracts actual T2 fitting job ID using job name: $t2fit_job_name"
                echo "      - Submits cleanup job with dependency on extracted T2 fitting job ID"
                session_cleanup_bridge_job_ids+=("DRY_RUN_SESSION_CLEANUP_BRIDGE_${session_id}")
            fi
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

# ================================================================
# FINAL CLEANUP JOB (if delete_workdir is enabled and session cleanup jobs exist)
# ================================================================
if [[ "$delete_workdir" == "true" && \
    ${#session_cleanup_bridge_job_ids[@]} -gt 0 && \
    $((total_sessions - skipped_sessions)) -gt 0 ]]; then
    
    echo
    echo "--------------------------------------"
    echo "Creating final cleanup bridge job for remaining parts of the working directory..."
    
    if [[ "$dry_run" == "false" ]]; then        
        # Build dependency string for all session cleanup jobs
        if [[ ${#session_cleanup_bridge_job_ids[@]} -gt 1 ]]; then
            dependency_list=$(IFS=':'; echo "${session_cleanup_bridge_job_ids[*]}")
            final_cleanup_bridge_dependency="--dependency=afterok:$dependency_list"
        elif [[ ${#session_cleanup_bridge_job_ids[@]} -eq 1 ]]; then
            final_cleanup_bridge_dependency="--dependency=afterok:${session_cleanup_bridge_job_ids[0]}"
        fi

        # Submit final cleanup bridge job
        final_cleanup_bridge_out=$(sbatch -p short,group_servers,gr_weiskopf "$final_cleanup_bridge_dependency" "$final_cleanup_bridge_script" \
            "$final_cleanup_script" \
            "$output_dir_denoise" \
            "$output_dir_gnlc" \
            "$working_dir_t2fit" \
            "$job_id_storage_dir" \
            "$working_dir" \
            "$cleanup_sess_id_file")

        echo "$final_cleanup_bridge_out"
        
        if [[ $final_cleanup_bridge_out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
            final_cleanup_bridge_job_id="${BASH_REMATCH[1]}"
            echo "Final cleanup bridge job ID: $final_cleanup_bridge_job_id (depends on session cleanup bridge jobs: ${session_cleanup_bridge_job_ids[*]})"
            echo "This bridge job will extract cleanup job IDs and submit the final cleanup job with proper dependencies"
        else
            echo "Warning: Could not extract final cleanup bridge job ID from sbatch output"
        fi

    else
        echo "DRY RUN: Would create final cleanup bridge job that:"
        echo "  - Depends on ${#session_cleanup_bridge_job_ids[@]} session cleanup bridge jobs: ${session_cleanup_bridge_job_ids[*]}"
        echo "  - Reads cleanup job IDs from: $cleanup_sess_id_file"
        echo "  - Removes working directories: $output_dir_denoise, $output_dir_gnlc, $working_dir_t2fit, $working_dir"
    fi
elif [[ "$delete_workdir" == "true" ]]; then
    echo
    if [[ ${#session_cleanup_bridge_job_ids[@]} -eq 0 || $((total_sessions - skipped_sessions)) -eq 0 ]]; then
        echo "> No session cleanup jobs were created or no sessions were processed."
        echo "> No cleanup needed"
    fi
fi




echo
echo "=========================================="
echo "T2 processing pipeline submission completed!"
echo "Total sessions found: $total_sessions"
echo "Sessions skipped: $skipped_sessions"
echo "Sessions processed: $((total_sessions - skipped_sessions))"
echo "Processing pipeline per session:"
echo "  1. Denoising → 2. Gradient non-linearity correction → 3. B1+ correction and T2 fitting"
if [[ "$delete_workdir" == "true" ]]; then
    echo "  4. Session cleanup → 5. Final cleanup (after all sessions)"
else
    echo "  Working directories will be preserved (--preserve-workdir specified)"
fi
if [[ "$dry_run" == "false" ]]; then
    echo "Check job status with: squeue -u \$USER"
    echo "Monitor logs in the respective SLURM script log directories"
else
    echo "This was a dry run - no jobs were actually submitted"
fi
echo "=========================================="
