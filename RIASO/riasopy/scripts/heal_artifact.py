#!/usr/bin/env python3
"""Undo the in-place rewrite auditwheel applies to the cargo artifact, so the same
target directory can be built twice.

maturin **hard-links** ``target/release/deps/libriasopy.so`` to
``target/maturin/libriasopy.so`` and then auditwheel repair rewrites it in place:

    NEEDED libhdf5.so.310  ->  NEEDED libhdf5-40046f04.so.310

cargo still considers the artifact fresh (no relink), so the next maturin run
feeds the already-repaired artifact back to auditwheel, which then looks for
``libhdf5-40046f04.so.310`` -- a name that does not exist in the build
environment -- and fails with ``Cannot repair wheel``.

This script restores the original sonames (auditwheel inserts ``-<8 hex digits>``
right before ``.so``). When sources are unchanged this is the only fix short of
``touch src/lib.rs``, which triggers a 15-25 minute fat-LTO relink. When sources
did change, cargo relinks by itself and this script is a no-op.

It also repairs RPATH: if the artifact still references an absolute directory
that no longer exists (for example after switching build environments),
auditwheel cannot locate the libraries to bundle, so the RPATH is reset to the
current ``$CONDA_PREFIX/lib``.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

NEEDED_RE = re.compile(r"Shared library: \[(lib[\w.+-]*?)-([0-9a-f]{8})(\.so(?:\.\d+)*)\]")
RPATH_RE = re.compile(r"\((?:RPATH|RUNPATH)\).*Library (?:rpath|runpath): \[(.*)\]")


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    cands = sorted((root / "target" / "release" / "deps").glob("libriasopy*.so"))
    if not cands:
        print("  (no target/release/deps/libriasopy*.so found, skipping)")
        return

    healed = 0
    rpath_fixed = 0
    prefix = os.environ.get("CONDA_PREFIX", "")
    for so in cands:
        out = subprocess.run(
            ["readelf", "-d", str(so)], capture_output=True, text=True, check=True
        ).stdout
        m = RPATH_RE.search(out)
        if m:
            stale = [
                p
                for p in m.group(1).split(":")
                if p and not p.startswith("$") and not Path(p).is_dir()
            ]
            if stale and prefix:
                subprocess.run(
                    ["patchelf", "--set-rpath", f"{prefix}/lib", str(so)], check=True
                )
                print(f"  {so.name}: stale RPATH entries {stale} -> {prefix}/lib")
                rpath_fixed += 1
        for m in NEEDED_RE.finditer(out):
            old = f"{m.group(1)}-{m.group(2)}{m.group(3)}"
            new = f"{m.group(1)}{m.group(3)}"
            subprocess.run(
                ["patchelf", "--replace-needed", old, new, str(so)], check=True
            )
            print(f"  {so.name}: {old} -> {new}")
            healed += 1

    if healed == 0 and rpath_fixed == 0:
        print("  cargo artifact is clean (no auditwheel hashed names), nothing to do")
    else:
        print(f"  restored {healed} NEEDED names, {rpath_fixed} RPATH entries")


if __name__ == "__main__":
    sys.exit(main())
