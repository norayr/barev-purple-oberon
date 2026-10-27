#!/usr/bin/env python3
"""Check ELF isolation and run a private, account-free libpurple host."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile


build = Path(sys.argv[1]).resolve()
exports = {"purple_init_plugin", "g_module_check_init", "g_module_unload"}
for name, expected in [("libbarev-oberon.so", exports),
                       ("libbarev-oberon-test.so", exports | {"barev_oberon_test_api"})]:
    library = build / name
    symbols = subprocess.check_output(["nm", "-D", "--defined-only", str(library)], text=True)
    actual = {line.split()[-1] for line in symbols.splitlines()}
    if actual != expected:
        raise SystemExit(f"Unexpected exports in {name}: {sorted(actual)}")
    dynamic = subprocess.check_output(["readelf", "-d", str(library)], text=True)
    if "libvoc" in dynamic or "TEXTREL" in dynamic:
        raise SystemExit(f"Runtime isolation or text relocation failure in {name}")

with tempfile.TemporaryDirectory(prefix="purple-test-", dir=build) as private:
    environment = dict(os.environ, HOME=private, XDG_CONFIG_HOME=private,
                       XDG_CACHE_HOME=private, XDG_DATA_HOME=private)
    environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
    for library, options in [("libbarev-oberon-test.so", []),
                             ("libbarev-oberon.so", ["--production"])]:
        subprocess.run([str(build / "TestHost"), str(build / library), private, *options],
                       env=environment, check=True, timeout=30)
print("Barev bridge ELF exports and private-runtime isolation checks passed")
