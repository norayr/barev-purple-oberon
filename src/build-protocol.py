#!/usr/bin/env python3
"""Translate local modules against VOC's installed libraries."""
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import sys

source, build, headers, archive = map(Path, sys.argv[1:5])
voc = Path(shutil.which(sys.argv[5]) or sys.argv[5])
generated = build / "oberon"
generated.mkdir(parents=True, exist_ok=True)
symbols = build / "voc-symbols"
symbols.mkdir(parents=True, exist_ok=True)
installed_symbols = headers.parent / "sym"
for path in (*installed_symbols.glob("*.sym"), *installed_symbols.glob("Errors.Txt")):
    target = symbols / path.name
    if not target.exists() or target.read_bytes() != path.read_bytes():
        shutil.copyfile(path, target)
if "Sockets_ConnectFrom" not in (headers / "Sockets.h").read_text():
    raise SystemExit("VOC needs the updated Internet/Sockets library with nonblocking TCP support")
for module, entry in (("Files", "NewMemory"), ("PNG0", "DecodeBytes"),
                      ("PNG0", "EncodeBytes"), ("JPEG0", "DecodeBytes"), ("JPEG0", "EncodeBytes")):
    path = headers / (module + ".h")
    if not path.is_file() or module + "_" + entry not in path.read_text():
        raise SystemExit("VOC 4.0.6 or newer is required, including its memory-file and native picture-codec libraries")
sources = {p.stem: p for p in source.glob("*.Mod")}
seen, order, dependencies = set(), [], {}


def stage_headers(path, visited=None):
    """Copy only imported headers so Oberon bindings cannot shadow C headers."""
    if visited is None:
        visited = set()
    if path in visited or not path.is_file():
        return
    visited.add(path)
    for name in re.findall(r'^\s*#\s*include\s*"([^"]+)"', path.read_text(), re.M):
        if (source / name).is_file():
            stage_headers(source / name, visited)
        elif Path(name).stem in sources:
            stage_headers(generated / name, visited)
        elif (headers / name).is_file():
            target = generated / name
            data = (headers / name).read_bytes()
            if not target.exists() or target.read_bytes() != data:
                target.write_bytes(data)
            stage_headers(headers / name, visited)


for path in source.iterdir():
    if path.suffix in (".c", ".h"):
        stage_headers(path)


def visit(name):
    if name in seen or name not in sources:
        return
    seen.add(name)
    path = sources[name]
    text = re.sub(r"\(\*.*?\*\)", "", path.read_text(), flags=re.S)
    imports = re.search(r"\bIMPORT\s+(.*?);", text, re.S)
    dependencies[name] = []
    if imports:
        for entry in imports[1].split(","):
            imported = entry.split(":=")[-1].strip()
            if imported in sources:
                dependencies[name].append(imported)
            visit(imported)
    order.append(name)


visit("BarevBridge")
visit("BarevStream")
visit("BarevIO")
visit("BarevPictures")
production = set(order) - {"BarevBridge"}
if (source / "TestBarev.Mod").exists():
    visit("TestBarev")
environment = dict(os.environ, OBERON=str(generated)+";"+str(symbols), MODULES="")
cc = shlex.split(os.environ.get("CC", "cc"))
flags = shlex.split(os.environ.get("CFLAGS", "-O0 -g"))
flags += shlex.split(os.environ.get("OBERON_CFLAGS", ""))
include = "-I" if "tcc" in Path(cc[0]).name else "-iquote"
constants = ["/* Generated from exported integer constants in the Oberon modules. */",
             "#ifndef BAREV_PROTOCOL_CONSTANTS_H", "#define BAREV_PROTOCOL_CONSTANTS_H"]
for module in ("BarevStanzas", "BarevAvatar", "BarevStream", "BarevFiles", "BarevFileStanzas", "BarevNetwork", "BarevImages"):
    text = re.sub(r"\(\*.*?\*\)", "", sources[module].read_text(), flags=re.S)
    section = re.search(r"\bCONST\s+(.*?)(?:\bTYPE\b|\bPROCEDURE\b)", text, re.S).group(1)
    for name, value in re.findall(r"(\w+)\*\s*=\s*(-?\d+)\s*;", section):
        constants.append(f"#define {module}_{name} ({value})")
constants.append("#endif")
(generated / "protocol-constants.h").write_text("\n".join(constants)+"\n")
objects = []
for name in order:
    outputs = [generated / (name + suffix) for suffix in (".sym", ".h", ".c", ".o")]
    inputs = [sources[name], source.parent / "Makefile", source / "build-protocol.py",
              headers / "SYSTEM.h", archive, build / "config", voc]
    inputs += [generated / (dependency + ".sym") for dependency in dependencies[name]]
    if all(path.exists() for path in outputs) and min(p.stat().st_mtime_ns for p in outputs) >= max(p.stat().st_mtime_ns for p in inputs):
        objects.append(str(generated / (name + ".o")))
        continue
    subprocess.run([str(voc), "-O2", "-sFS", str(sources[name])],
                   cwd=generated, env=environment, check=True)
    stage_headers(generated / (name+".c"))
    obj = generated / (name + ".o")
    subprocess.run([*cc, *flags, "-std=c11", "-fPIC", "-fno-strict-aliasing",
                    "-fvisibility=hidden", include + str(generated), include + str(source),
                    "-c", str(generated / (name + ".c")), "-o", str(obj)], check=True)
    objects.append(str(obj))
protocol = [obj for obj in objects if Path(obj).stem != "BarevBridge"]
(build / "protocol-test-objects.rsp").write_text("\n".join(map(shlex.quote, protocol)) + "\n")
(build / "protocol-objects.rsp").write_text("\n".join(shlex.quote(obj) for obj in protocol if Path(obj).stem in production) + "\n")
print(f"Built {len(order)} local modules against the installed VOC libraries")
