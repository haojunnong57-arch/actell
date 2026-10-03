# SPDX-License-Identifier: GPL-3.0-or-later
"""Read only pinned test-reference files, verified before execution."""
import hashlib
import json
from pathlib import Path

def reference_file(name):
    base = Path(__file__).resolve().parent / "upstream_reference"
    manifest = json.loads((base / "manifest.json").read_text())
    assert manifest["commit"] == "cd895d17ce8a97d883c10f87b26c7356d5e0ccb1"
    assert name in manifest["files"]
    file = base / name
    assert hashlib.sha256(file.read_bytes()).hexdigest() == manifest["files"][name], "Reference hash mismatch"
    return file
