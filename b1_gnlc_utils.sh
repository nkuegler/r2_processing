#!/bin/bash

# ==============================================================================
# B1+ Map Gradient Non-linearity Correction (GNLC) Utilities
# ==============================================================================
#
# DESCRIPTION:
#   Helper functions to determine whether a custom (pre-calculated) B1+ map was
#   calculated from gradient nonlinearity-corrected data. This file is sourced by
#   t2_processing_main.sh.
#
#   The B1map JSON sidecar usually does not contain this information. It is taken
#   from the corresponding *B1ref.json (e.g., written by the hMRI toolbox), which
#   contains the key NonlinearGradientCorrection of the underlying AFI acquisition.
#
#   A B1+ map that still needs GNLC must be in scanner anatomical coordinates
#   (qform_code/sform_code = 1): The distortion field is defined relative to the gradient
#   isocenter in scanner coordinates. If the affine matrix of the image includes a
#   coregistration rotation or translation (e.g., the hMRI toolbox/SPM sets the codes to
#   2 = aligned anat after coregistering the AFI images to the structural images), the
#   correction may be applied at the wrong physical positions.
#
# FUNCTIONS:
#   b1_gnlc_status <B1MAP_PATH>
#       Echoes "true", "false" or "unknown" to stdout (reason is written to stderr).
#   b1_nifti_xform_codes <NIFTI_PATH>
#       Echoes "<qform_code> <sform_code>" of a NIfTI-1/-2 file (.nii or .nii.gz) or "invalid".
#   b1_scanner_anat_status <NIFTI_PATH>
#       Echoes "true", "false" or "unknown" to stdout (header codes are written to stderr).
#   b1_print_not_scanner_anat_error <B1MAP_PATH> [<B1MAP_PATH> ...]
#       Prints the error message (with options for the user) for B1+ maps that need
#       GNLC but are not in scanner anatomical coordinates.
#
# REQUIREMENTS:
#   - jq
#   - gzip, head, od
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
# ==============================================================================

# Echo the value of the (possibly nested) key NonlinearGradientCorrection in a JSON file:
# "true", "false", "missing" (key not found) or "invalid" (file could not be parsed)
_b1_json_gnlc_value() {
    local json_file="$1"
    jq -r '[.. | objects | select(has("NonlinearGradientCorrection")) | .NonlinearGradientCorrection]
           | if length == 0 then "missing" else (.[0] | tostring) end' "$json_file" 2>/dev/null || echo "invalid"
}

b1_gnlc_status() {
    local b1map_path="$1"
    local b1map_dir b1map_name b1map_stem
    b1map_dir="$(dirname "$b1map_path")"
    b1map_name="$(basename "$b1map_path")"
    b1map_stem="${b1map_name%%.nii*}"

    # 1. B1map JSON sidecar (usually without GNLC information)
    local b1map_json="$b1map_dir/${b1map_stem}.json"
    if [[ -f "$b1map_json" && "$(_b1_json_gnlc_value "$b1map_json")" == "true" ]]; then
        echo "  B1map JSON has NonlinearGradientCorrection=true: $b1map_json" >&2
        echo "true"
        return 0
    fi

    # 2. Corresponding B1ref JSON sidecar
    local b1ref_json="$b1map_dir/${b1map_stem%B1map}B1ref.json"
    if [[ ! -f "$b1ref_json" ]]; then
        local b1ref_candidates=()
        while IFS= read -r -d '' f; do
            b1ref_candidates+=("$f")
        done < <(find "$b1map_dir" -maxdepth 1 -type f -name "*B1ref.json" -print0 2>/dev/null | sort -z)

        if [[ ${#b1ref_candidates[@]} -eq 0 ]]; then
            echo "  No *B1ref.json found in $b1map_dir" >&2
            echo "unknown"
            return 0
        fi
        if [[ ${#b1ref_candidates[@]} -gt 1 ]]; then
            echo "  Warning: Multiple *B1ref.json files found in $b1map_dir. Using the first one: $(basename "${b1ref_candidates[0]}")" >&2
        fi
        b1ref_json="${b1ref_candidates[0]}"
    fi

    local value
    value="$(_b1_json_gnlc_value "$b1ref_json")"
    case "$value" in
        true|false)
            echo "      NonlinearGradientCorrection=$value in $b1ref_json" >&2
            echo "$value"
            ;;
        missing)
            echo "      Key NonlinearGradientCorrection not found in $b1ref_json" >&2
            echo "unknown"
            ;;
        *)
            echo "      Could not read NonlinearGradientCorrection from $b1ref_json (value: $value)" >&2
            echo "unknown"
            ;;
    esac
    return 0
}

# Echo the unsigned integer of <NBYTES> bytes at <OFFSET> with endianness <le|be>
# from the array "hdr" (header bytes) of the calling function
_b1_hdr_uint() {
    local endian="$1" offset="$2" nbytes="$3" value=0 i
    for ((i = 0; i < nbytes; i++)); do
        if [[ "$endian" == "le" ]]; then
            value=$(( value | hdr[offset + i] << (8 * i) ))
        else
            value=$(( value << 8 | hdr[offset + i] ))
        fi
    done
    echo "$value"
}

b1_nifti_xform_codes() {
    local nii_path="$1"
    local hdr=()
    if [[ "$nii_path" == *.gz ]]; then
        hdr=($(gzip -dc "$nii_path" 2>/dev/null | head -c 540 | od -An -v -tu1))
    else
        hdr=($(head -c 540 "$nii_path" 2>/dev/null | od -An -v -tu1))
    fi
    if [[ ${#hdr[@]} -lt 348 ]]; then
        echo "invalid"
        return 0
    fi

    # sizeof_hdr (348: NIfTI-1, 540: NIfTI-2) also determines the endianness
    local endian qform_offset="" sform_offset nbytes
    for endian in le be; do
        case "$(_b1_hdr_uint "$endian" 0 4)" in
            348) qform_offset=252; sform_offset=254; nbytes=2; break ;;
            540) qform_offset=344; sform_offset=348; nbytes=4; break ;;
        esac
    done
    if [[ -z "$qform_offset" || ${#hdr[@]} -lt $((sform_offset + nbytes)) ]]; then
        echo "invalid"
        return 0
    fi

    echo "$(_b1_hdr_uint "$endian" "$qform_offset" "$nbytes") $(_b1_hdr_uint "$endian" "$sform_offset" "$nbytes")"
}

b1_scanner_anat_status() {
    local nii_path="$1" codes qform_code sform_code
    codes="$(b1_nifti_xform_codes "$nii_path")"
    if [[ "$codes" == "invalid" ]]; then
        echo "      Could not read qform_code/sform_code from the NIfTI header of $nii_path" >&2
        echo "unknown"
        return 0
    fi
    read -r qform_code sform_code <<< "$codes"
    echo "      NIfTI header: qform_code=$qform_code, sform_code=$sform_code (1 = scanner anat)" >&2

    # Scanner anatomical: no code other than 0 (unset) or 1 (scanner anat), and at least one code is 1
    if [[ "$qform_code" -le 1 && "$sform_code" -le 1 && ( "$qform_code" -eq 1 || "$sform_code" -eq 1 ) ]]; then
        echo "true"
    else
        echo "false"
    fi
    return 0
}

b1_print_not_scanner_anat_error() {
    echo "ERROR: The following custom B1+ maps were calculated from data NOT corrected for gradient nonlinearities"
    echo "  and are NOT in scanner anatomical coordinates (qform_code/sform_code != 1). The following sessions were skipped:"
    printf "    %s\n" "$@"
    cat <<EOF

Explanation:
Correcting non-scanner anatomical data for gradient nonlinearities is not guaranteed to be correct:
The distortion field is defined relative to the gradient isocenter in scanner coordinates. If the affine
matrix of the image includes a coregistration rotation or translation, the correction is applied at the
wrong physical positions. (The hMRI toolbox/SPM sets qform_code/sform_code to 2 (aligned anat), because
the AFI images are coregistered to the space of the structural images.)

Options to process these sessions:
1. Gold standard: Correct the weighted AFI images for gradient nonlinearities and calculate the B1+ map
   from the corrected images. In the hMRI toolbox, the B1+ map is created during the "Create hMRI maps"
   step, i.e., correct the AFI images before this step and feed the corrected images into the toolbox
   processing.
2. Use -b1asis/--b1-use-as-is. The processing works, but the B1+ maps are NOT corrected for gradient
   nonlinearities. Depending on the system, the effect is small to considerable; it mainly leads to
   deviations in the periphery (very small effect near the isocenter).
3. If the B1+ map has the same affine matrix as the original (weighted) AFI images, i.e., the
   coregistration did not change it, set qform_code and sform_code to 1 (scanner anat) and run again.
   Compare the affine matrices, e.g., with nibabel:
     python -c "import sys, nibabel as nib; [print(f, nib.load(f).affine, sep='\\n') for f in sys.argv[1:]]" <B1map.nii> <AFI.nii>
   Set the codes (keep a backup of the original file), either with FSL:
     fslorient -setqformcode 1 <B1map.nii>
     fslorient -setsformcode 1 <B1map.nii>
   or with nibabel:
     python -c "import sys, nibabel as nib; img = nib.load(sys.argv[1]); img = nib.Nifti1Image(img.get_fdata(), img.affine, img.header); img.set_qform(img.get_qform(), code=1); img.set_sform(img.get_sform(), code=1); nib.save(img, sys.argv[1])" <B1map.nii>
EOF
}
