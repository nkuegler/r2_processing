import json
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
