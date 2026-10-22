import gzip
import json
import struct
import subprocess

import pytest

from conftest import REPO_ROOT, requires_jq

B1_STEM = "sub-001_ses-01_acq-stx_"


def b1_gnlc_status(b1map_path):
    result = subprocess.run(
        ["bash", "-c", f'source "{REPO_ROOT / "b1_gnlc_utils.sh"}"; b1_gnlc_status "$1"', "_", str(b1map_path)],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


@pytest.fixture
def b1map(tmp_path):
    path = tmp_path / f"{B1_STEM}B1map.nii"
    path.touch()
    return path


@requires_jq
@pytest.mark.parametrize("b1ref_content, expected", [
    ({"NonlinearGradientCorrection": True}, "true"),
    ({"NonlinearGradientCorrection": False}, "false"),
    ({"history": {"acqpar": {"NonlinearGradientCorrection": True}}}, "true"),
    ({"history": {"acqpar": {"NonlinearGradientCorrection": False}}}, "false"),
    ({"SomethingElse": 1}, "unknown"),
])
def test_status_from_b1ref(b1map, b1ref_content, expected):
    (b1map.parent / f"{B1_STEM}B1ref.json").write_text(json.dumps(b1ref_content))
    assert b1_gnlc_status(b1map) == expected


@requires_jq
def test_status_without_b1ref_is_unknown(b1map):
    (b1map.parent / f"{B1_STEM}B1map.json").write_text(json.dumps({"NonlinearGradientCorrection": False}))
    assert b1_gnlc_status(b1map) == "unknown"


@requires_jq
def test_status_from_b1map_json(b1map):
    (b1map.parent / f"{B1_STEM}B1map.json").write_text(json.dumps({"NonlinearGradientCorrection": True}))
    assert b1_gnlc_status(b1map) == "true"


@requires_jq
def test_status_from_differently_named_b1ref(b1map):
    (b1map.parent / "sub-001_ses-01_acq-other_B1ref.json").write_text(json.dumps({"NonlinearGradientCorrection": False}))
    assert b1_gnlc_status(b1map) == "false"


def run_util(func, path):
    result = subprocess.run(
        ["bash", "-c", f'source "{REPO_ROOT / "b1_gnlc_utils.sh"}"; {func} "$1"', "_", str(path)],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def write_nifti_header(path, qform_code, sform_code, version=1, endian="<"):
    if version == 1:
        hdr = bytearray(352)
        struct.pack_into(f"{endian}i", hdr, 0, 348)
        struct.pack_into(f"{endian}hh", hdr, 252, qform_code, sform_code)
    else:
        hdr = bytearray(544)
        struct.pack_into(f"{endian}i", hdr, 0, 540)
        struct.pack_into(f"{endian}ii", hdr, 344, qform_code, sform_code)
    opener = gzip.open if path.name.endswith(".gz") else open
    with opener(path, "wb") as f:
        f.write(bytes(hdr))
    return path


@pytest.mark.parametrize("name", ["B1map.nii", "B1map.nii.gz"])
@pytest.mark.parametrize("version", [1, 2])
@pytest.mark.parametrize("endian", ["<", ">"])
def test_xform_codes(tmp_path, name, version, endian):
    path = write_nifti_header(tmp_path / name, 2, 1, version, endian)
    assert run_util("b1_nifti_xform_codes", path) == "2 1"


def test_xform_codes_invalid(tmp_path):
    path = tmp_path / "B1map.nii"
    path.write_bytes(b"fake nifti")
    assert run_util("b1_nifti_xform_codes", path) == "invalid"
    assert run_util("b1_scanner_anat_status", path) == "unknown"


@pytest.mark.parametrize("qform_code, sform_code, expected", [
    (1, 1, "true"),
    (1, 0, "true"),
    (0, 1, "true"),
    (0, 0, "false"),
    (2, 2, "false"),
    (1, 2, "false"),
    (2, 1, "false"),
])
def test_scanner_anat_status(tmp_path, qform_code, sform_code, expected):
    path = write_nifti_header(tmp_path / "B1map.nii", qform_code, sform_code)
    assert run_util("b1_scanner_anat_status", path) == expected
