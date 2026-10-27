#!/usr/bin/env python3
"""Translate the protocol's exact import closure into its private runtime build."""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys

source, compiler, build, voc, vocroot = map(Path, sys.argv[1:])
sources = {}
for directory in ("src/library", "src/ports/ooc", "src/ports/xml", "src/ports/xmpp"):
    sources.update({p.stem: p for p in (compiler / directory).glob("*.Mod")})
sources.update({p.stem: p for p in source.glob("*.Mod")})
sources.update({name: compiler / "src/runtime" / (file + ".Mod") for name, file in
                [("Platform", "Platformunix"), ("PlatformNative", "PlatformNativeunix"),
                 ("Heap", "Heap"), ("Modules", "Modules")]})
core = {"SYSTEM", "PlatformNative", "Platform", "Heap", "Modules"}
seen, order, dependencies = set(core), [], {}


def visit(name):
    if name in seen:
        return
    seen.add(name)
    path = sources[name]
    text = re.sub(r"\(\*.*?\*\)", "", path.read_text(), flags=re.S)
    imports = re.search(r"\bIMPORT\s+(.*?);", text, re.S)
    dependencies[name] = []
    if imports:
        for entry in imports[1].split(","):
            imported = entry.split(":=")[-1].strip()
            dependencies[name].append(imported)
            visit(imported)
    order.append(name)


visit("BarevStream")
if (source / "TestBarev.Mod").exists():
    visit("TestBarev")
environment = dict(os.environ, VOCROOT=str(vocroot),
                   OBERON=f"{build};{vocroot}/2/sym")
cc = shlex.split(os.environ.get("CC", "cc"))
flags = shlex.split(os.environ.get("CFLAGS", "-O0 -g"))
flags += shlex.split(os.environ.get("OBERON_CFLAGS", ""))
include = "-I" if "tcc" in Path(cc[0]).name else "-iquote"
constants = ["/* Generated from exported integer constants in the Oberon modules. */",
             "#ifndef BAREV_PROTOCOL_CONSTANTS_H", "#define BAREV_PROTOCOL_CONSTANTS_H"]
for module in ("BarevStanzas", "BarevAvatar", "BarevStream"):
    text = re.sub(r"\(\*.*?\*\)", "", sources[module].read_text(), flags=re.S)
    section = re.search(r"\bCONST\s+(.*?)(?:\bTYPE\b|\bPROCEDURE\b)", text, re.S).group(1)
    for name, value in re.findall(r"(\w+)\*\s*=\s*(-?\d+)\s*;", section):
        constants.append(f"#define {module}_{name} ({value})")
constants.append("#endif")
(build / "protocol-constants.h").write_text("\n".join(constants)+"\n")
objects = []
for name in order:
    outputs = [build / (name + suffix) for suffix in (".sym", ".h", ".c", ".o")]
    inputs = [sources[name], build / "SYSTEM.h", build / "config", voc]
    inputs += [build / (dependency + ".sym") for dependency in dependencies[name] if dependency != "SYSTEM"]
    if all(path.exists() for path in outputs) and min(p.stat().st_mtime_ns for p in outputs) >= max(p.stat().st_mtime_ns for p in inputs):
        objects.append(str(build / (name + ".o")))
        continue
    subprocess.run([str(voc), "-O2", "-sFS", str(sources[name])],
                   cwd=build, env=environment, check=True)
    obj = build / (name + ".o")
    subprocess.run([*cc, *flags, "-std=c11", "-fPIC", "-fno-strict-aliasing",
                    "-fvisibility=hidden", include + str(build), include + str(source),
                    "-c", str(build / (name + ".c")), "-o", str(obj)], check=True)
    objects.append(str(obj))
(build / "protocol-test-objects.rsp").write_text("\n".join(map(shlex.quote, objects)) + "\n")
(build / "protocol-objects.rsp").write_text("\n".join(shlex.quote(obj) for obj in objects if Path(obj).stem != "TestBarev") + "\n")
print(f"Built {len(order)} private protocol dependency modules")
