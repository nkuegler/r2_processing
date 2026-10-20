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
# FUNCTIONS:
#   b1_gnlc_status <B1MAP_PATH>
#       Echoes "true", "false" or "unknown" to stdout (reason is written to stderr).
#
# REQUIREMENTS:
#   - jq
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
