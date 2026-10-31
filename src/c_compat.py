"""Run the unmodified C plugin's message/preview receiver in an offline host."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile


def receive(build, kind, data):
    library = os.environ.get("BAREV_C_IMAGE_LIBRARY")
    if not library:
        raise AssertionError("BAREV_C_IMAGE_LIBRARY is required for C receiver checks")
    with tempfile.TemporaryDirectory(prefix="c-compatibility-", dir=build) as directory:
        profile = Path(directory)
        source = profile / "input"
        source.write_bytes(data)
        environment = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                           XDG_CACHE_HOME=directory, XDG_DATA_HOME=directory,
                           G_DEBUG="fatal-criticals")
        environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
        result = subprocess.run([str(Path(build) / "CCompatibilityHost"), directory,
                                 str(Path(library).resolve()), kind, str(source)],
                                env=environment, capture_output=True, timeout=30)
        if result.returncode:
            raise AssertionError(("C receiver failed", kind, result.returncode,
                                  result.stdout.decode(errors="replace"), result.stderr.decode(errors="replace")))
        prefix = b"MARKUP " if kind == "markup" else b"IMAGE "
        lines = [line for line in result.stdout.splitlines() if line.startswith(prefix)]
        assert len(lines) == 1, result.stdout
        return base64.b64decode(lines[0].split(maxsplit=1)[1])
