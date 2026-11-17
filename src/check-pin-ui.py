#!/usr/bin/env python3
"""Run pin-dialog lifecycle checks in an isolated libpurple profile."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="barev-pin-ui-") as profile:
    subprocess.run([str(Path(sys.argv[1]).resolve()), profile], check=True,
                   env=dict(os.environ, G_DEBUG="fatal-criticals"))
