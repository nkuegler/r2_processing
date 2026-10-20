import gzip
import json
import os
import subprocess

import pytest

from conftest import REPO_ROOT, requires_jq

SUBJ, SESS = "sub-001", "ses-01"
B1_STEM = f"{SUBJ}_{SESS}_acq-stx_"
JOB_NAME = "gnlc_b1_test"


@pytest.fixture
def setup(tmp_path):
    # custom B1 map (compressed) + sidecar
    src_dir = tmp_path / "custom_b1" / SUBJ / SESS / "anat" / "Supplementary"
    src_dir.mkdir(parents=True)
    b1map = src_dir / f"{B1_STEM}B1map.nii.gz"
    with gzip.open(b1map, "wb") as f:
        f.write(b"fake nifti")
    (src_dir / f"{B1_STEM}B1map.json").write_text(json.dumps({"Units": "p.u."}))

    # stubs: GNLC call script and sbatch record their arguments
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("gnlc_stub.sh", "sbatch"):
        stub = bin_dir / name
        stub.write_text(f'#!/bin/bash\necho "$@" > "{tmp_path}/{name}.args"\necho "Submitted batch job 123"\n')
        stub.chmod(0o755)

    return tmp_path, b1map, bin_dir


def run_bridge(tmp_path, b1map, bin_dir, mode):
    cmd = [
        "bash", str(REPO_ROOT / "slurm_bridge_gnlc_b1.sh"),
        str(bin_dir / "gnlc_stub.sh"), mode, str(b1map), SUBJ, SESS,
        str(tmp_path / "t2fit"), str(tmp_path / "gnlc"), "Terra", JOB_NAME, str(tmp_path / "log_"),
    ]
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


@requires_jq
def test_gnlc_mode_runs_gnlc_without_jacobian(setup):
    tmp_path, b1map, bin_dir = setup
    result = run_bridge(tmp_path, b1map, bin_dir, "gnlc")
    assert result.returncode == 0, result.stdout

    gnlc_args = (tmp_path / "gnlc_stub.sh.args").read_text().split()
    assert "--nj" in gnlc_args
    assert gnlc_args[gnlc_args.index("-p") + 1] == "B1map"
    assert gnlc_args[gnlc_args.index("-c") + 1] == B1_STEM
    assert gnlc_args[gnlc_args.index("-job-name") + 1] == JOB_NAME

    staged = tmp_path / "t2fit" / SUBJ / SESS / "anat" / f"{B1_STEM}B1map"
    assert staged.with_suffix(".nii").read_bytes() == b"fake nifti"
    staged_json = json.loads(staged.with_suffix(".json").read_text())
    assert staged_json["Units"] == "p.u."
    assert "GNLC" in staged_json["B1mapGNLCHandling"]


@requires_jq
def test_asis_mode_copies_map_and_submits_placeholder(setup):
    tmp_path, b1map, bin_dir = setup
    result = run_bridge(tmp_path, b1map, bin_dir, "asis")
    assert result.returncode == 0, result.stdout

    out = tmp_path / "gnlc" / SUBJ / SESS / "anat" / f"{B1_STEM}desc-undistorted_B1map"
    assert out.with_suffix(".nii").read_bytes() == b"fake nifti"
    assert "forced" in json.loads(out.with_suffix(".json").read_text())["B1mapGNLCHandling"]
    assert f"--job-name={JOB_NAME}" in (tmp_path / "sbatch.args").read_text()
    assert not (tmp_path / "gnlc_stub.sh.args").exists()


def test_unknown_mode_fails(setup):
    tmp_path, b1map, bin_dir = setup
    assert run_bridge(tmp_path, b1map, bin_dir, "foo").returncode == 1
