#!/usr/bin/env python3
"""Collapse the extension module's RPATH to ``$ORIGIN/../riasopy.libs``.

maturin writes the build environment's lib directory (conda's
``$CONDA_PREFIX/lib``) into the extension module's RPATH. On a target machine that
path does not exist and the loader would fall back to the bundled
``riasopy.libs/`` anyway, but:

  * the wheel leaks a build-machine absolute path;
  * if the target machine happens to have that path, it may pick up unrelated
    libraries first.

auditwheel already rewrites the RPATH of the 21 libraries it bundles to
``$ORIGIN``; this script only handles the ``riasopy/*.so`` extension module and
updates the hashes in ``.dist-info/RECORD``.

Usage: ``python scripts/fix_wheel_rpath.py target/wheels/riasopy-*.whl``
(requires patchelf, which the build environment provides.)
"""

import base64
import csv
import hashlib
import io
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

RPATH = "$ORIGIN/../riasopy.libs"


def _sha256(data: bytes) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def _patch(path: Path) -> None:
    subprocess.run(["patchelf", "--set-rpath", RPATH, str(path)], check=True)


def fix(wheel: Path) -> int:
    with zipfile.ZipFile(wheel) as zf:
        infos = zf.infolist()
        blobs = {i.filename: zf.read(i.filename) for i in infos}

    record_name = next(n for n in blobs if n.endswith(".dist-info/RECORD"))
    targets = [n for n in blobs if n.startswith("riasopy/") and n.endswith(".so")]
    if not targets:
        raise SystemExit(f"no riasopy/*.so found in {wheel}")

    with tempfile.TemporaryDirectory() as td:
        for name in targets:
            p = Path(td) / Path(name).name
            p.write_bytes(blobs[name])
            _patch(p)
            blobs[name] = p.read_bytes()

        # keep RECORD sha256/size in sync for the patched entries
        rows = list(csv.reader(io.StringIO(blobs[record_name].decode())))
        for row in rows:
            if row and row[0] in targets and len(row) >= 3:
                row[1] = "sha256=" + _sha256(blobs[row[0]])
                row[2] = str(len(blobs[row[0]]))
        out = io.StringIO()
        csv.writer(out, lineterminator="\n").writerows(rows)
        blobs[record_name] = out.getvalue().encode()

        tmp = wheel.with_suffix(".tmp.whl")
        with zipfile.ZipFile(tmp, "w") as zf:
            for info in infos:
                data = blobs[info.filename]
                zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                zi.compress_type = info.compress_type
                zi.external_attr = info.external_attr
                zf.writestr(zi, data)
        os.replace(tmp, wheel)

    return len(targets)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    wheel = Path(sys.argv[1])
    n = fix(wheel)
    print(f"  RPATH collapsed to {RPATH} for {n} extension module(s): {wheel.name}")


if __name__ == "__main__":
    main()
