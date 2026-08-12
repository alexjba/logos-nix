#!/usr/bin/env python3
"""Assert every non-system DLL a staged PE imports is shipped beside it.

This is the gate that catches "plugin shipped without its DLLs" -- a class of
bug that is invisible on the build host (nothing links at load time on Linux)
and shows up on Windows only as a module that silently fails to load.

Reads: STAGE, MIN_PES, ASSEMBLE (JSON), OBJDUMP.
"""
import glob
import json
import os
import subprocess
import sys

OBJDUMP = os.environ["OBJDUMP"]
STAGE = os.environ.get("STAGE", "stage")
MIN_PES = int(os.environ.get("MIN_PES", "1"))
ASSEMBLE = json.loads(os.environ.get("ASSEMBLE") or "{}")

# Everything Windows itself provides. Anything else must ship with us.
SYSTEM = (
    "kernel32 ntdll user32 advapi32 ws2_32 mswsock shell32 ole32 "
    "oleaut32 version winmm netapi32 userenv authz mpr crypt32 "
    "bcrypt secur32 dbghelp psapi imm32 gdi32 comdlg32 shlwapi "
    "iphlpapi dnsapi wtsapi32 setupapi winspool rpcrt4 msvcrt "
    "uxtheme dwmapi d3d9 d3d11 d3d12 dxgi dwrite opengl32 wldap32 "
    "normaliz winhttp wininet ncrypt cfgmgr32 powrprof propsys "
    "oleacc avrt ucrtbase"
).split()


def search_dirs(pe_path):
    """Directories this PE's imports may legitimately resolve from.

    Default: the PE's own directory, plus bin/ and lib/ of the staged target it
    belongs to -- that is how every single-derivation target here is laid out.
    `assemble` widens it for apps built from several derivations.
    """
    rel = os.path.relpath(pe_path, STAGE)
    target = rel.split(os.sep)[0]
    root = os.path.join(STAGE, target)
    dirs = [os.path.dirname(pe_path), os.path.join(root, "bin"), os.path.join(root, "lib")]
    for extra in ASSEMBLE.get(target, []):
        dirs.append(os.path.join(STAGE, extra))
    return [d for d in dirs if os.path.isdir(d)]


def is_system(dll):
    # Names are compared case-insensitively with the extension stripped, because
    # import tables mix spellings freely: real trees contain both "KERNEL32.dll"
    # and "KERNEL32.DLL", and "IPHLPAPI.DLL".
    b = os.path.splitext(dll)[0].lower()
    return b in SYSTEM or b.startswith("api-ms-win") or b.startswith("ext-ms-win")


pes = [p for p in glob.glob(os.path.join(STAGE, "**", "*"), recursive=True)
       if p.lower().endswith((".exe", ".dll")) and os.path.isfile(p)]

if len(pes) < MIN_PES:
    sys.exit(f"::error::only {len(pes)} PEs discovered (need >= {MIN_PES}) "
             "— refusing to pass vacuously")

bad = 0
for p in sorted(pes):
    r = subprocess.run([OBJDUMP, "-p", p], capture_output=True, text=True)
    # An objdump that errors would otherwise yield an empty import list,
    # indistinguishable from "no imports" -- i.e. a silent pass.
    if r.returncode != 0:
        print(f"::error::objdump failed on {p}: {r.stderr.strip()[:200]}")
        bad = 1
        continue
    imports = [l.split("DLL Name:")[1].strip()
               for l in r.stdout.splitlines() if "DLL Name:" in l]
    if not imports:
        print(f"::error::{p} has no import table at all")
        bad = 1
        continue
    here = search_dirs(p)
    for dll in imports:
        if is_system(dll):
            continue
        if not any(os.path.exists(os.path.join(d, dll)) for d in here):
            print(f"::error::{p} imports {dll}, not found in {here}")
            bad = 1

print(f"checked {len(pes)} PEs")
sys.exit(bad)
