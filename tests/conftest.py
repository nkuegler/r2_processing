import pathlib as plib
import shutil

import pytest

REPO_ROOT = plib.Path(__file__).resolve().parent.parent

requires_jq = pytest.mark.skipif(shutil.which("jq") is None, reason="jq not installed")
