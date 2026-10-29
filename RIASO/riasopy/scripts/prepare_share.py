#!/usr/bin/env python3
"""Generate ``python/riasopy/share`` from the build environment (fonts + fontconfig config).

For the wheel to run without the build machine, it must ship:

* ``$CONDA_PREFIX/fonts/*.ttf`` -- from the conda package ``font-ttf-dejavu``;
* ``$CONDA_PREFIX/etc/fonts``  -- from the conda package ``fontconfig``.

The source tree does **not** store this share (it used to be a copy of the binary
dist and could drift from the build environment). ``build_wheel.sh`` calls this
script before maturin and removes the directory again after packaging.

Three things in conda's ``fonts.conf`` are unusable on a target machine and are
rewritten here:

1. ``<dir>`` entries hard-code build-machine absolute paths => only
   ``<dir prefix="relative">../../fonts</dir>`` is kept (resolved relative to the
   config file itself, landing on ``share/fonts``);
2. the ``prefix`` attribute of ``<cachedir>`` has no effect => those lines are
   dropped, otherwise every run prints ``No writable cache directories`` twice;
3. ``<include ...>conf.d</include>`` resolves against the libfontconfig
   build-time CONFIGDIR (a build-machine absolute path; ``prefix="relative"``
   was measured to have **no effect** on it) => the contents of ``conf.d/*.conf``
   are **inlined in file-name order** into ``fonts.conf``, then the ``<include>``
   line and the whole ``conf.d/`` directory are removed, so the wheel contains no
   include that needs a build-machine path to resolve.

In the conda package ``conf.d`` entries are symlinks into
``share/fontconfig/conf.avail``; they are dereferenced when copied.
``conf.d/README`` is a maintainer note that contains a build-machine path and is
not parsed by fontconfig (it only reads ``.conf`` files); the whole directory is
deleted after inlining.

Usage::

    python scripts/prepare_share.py                # defaults: --prefix $CONDA_PREFIX
    python scripts/prepare_share.py --dest /tmp/x  # generate elsewhere for inspection
    python scripts/prepare_share.py --clean        # remove share during build cleanup

Note: this network filesystem can report ``ENOTEMPTY`` for a directory whose
files are already gone (stale metadata); ``rm -rf`` and ``shutil.rmtree`` both
fail. Everything here therefore renames the directory into ``target/`` first
(rename frees the path immediately) and only then tries to delete it.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REL_DIR = '<dir prefix="relative">../../fonts</dir>'
INCLUDE_OLD = '<include ignore_missing="yes">conf.d</include>'

_DIR_RE = re.compile(r"^<dir\b.*</dir>$")
_CACHEDIR_RE = re.compile(r"^<cachedir\b.*</cachedir>$")


def _find_fonts(prefix: Path) -> Path:
    for cand in (prefix / "fonts", prefix / "share" / "fonts"):
        if cand.is_dir() and any(cand.glob("*.ttf")):
            return cand
    raise SystemExit(
        f"cannot find a font directory with .ttf files under {prefix} "
        "(the build environment needs the conda package font-ttf-dejavu)"
    )


def _conf_d_body(conf_dir: Path) -> str:
    """Inline every ``conf.d/*.conf`` into one config fragment.

    The order matches how fontconfig handles an ``<include>`` of a directory
    (sorted by file name). Each file has its XML declaration / DOCTYPE / outer
    ``<fontconfig>`` root stripped, and nested ``<include>`` lines (which point at
    build-machine user config directories) are dropped.

    Note: a comment may precede the root element, so the ``<fontconfig>`` removal
    must **not** be anchored with ``^``. Leaving it unbalanced makes fontconfig
    fail to parse the file and **silently fall back to the system default
    configuration** (which looks like it works but reads the build machine's font
    directory).
    """
    parts = []
    for f in sorted(conf_dir.glob("*.conf")):
        t = f.read_text(encoding="utf-8")
        t = re.sub(r"<\?xml.*?\?>", "", t, flags=re.S)
        t = re.sub(r"<!DOCTYPE[^>]*>", "", t)
        t = re.sub(r"<fontconfig(\s[^>]*)?>", "", t, count=1)
        t = re.sub(r"</fontconfig>\s*$", "", t)
        t = "\n".join(ln for ln in t.splitlines() if "<include" not in ln)
        parts.append(f"<!-- inlined conf.d/{f.name} -->\n" + t.strip("\n"))
    return "\n".join(parts) + "\n"


def _rewrite_conf(conf: Path) -> None:
    out = []
    dir_done = False
    include_done = False
    for line in conf.read_text(encoding="utf-8").splitlines(keepends=True):
        s = line.strip()
        if _CACHEDIR_RE.match(s):
            continue
        if _DIR_RE.match(s):
            if not dir_done:
                out.append("\t" + REL_DIR + "\n")
                dir_done = True
            continue
        if s == INCLUDE_OLD:
            out.append(_conf_d_body(conf.parent / "conf.d"))
            include_done = True
            continue
        out.append(line)
    if not dir_done:
        raise SystemExit(f"{conf} has no <dir> line; cannot insert the relative font directory")
    if not include_done:
        raise SystemExit(f"{conf} has no {INCLUDE_OLD}; unexpected layout")
    text = "".join(out)
    if "<include" in text:
        raise SystemExit(f"{conf} still contains <include> (would resolve via the build CONFIGDIR)")
    conf.write_text(text, encoding="utf-8")


def _self_check(prefix: Path, conf: Path, fonts_dir: Path) -> None:
    """Use fc-match to prove the generated config only sees bundled fonts.

    The **full resolved path** must be inside ``fonts_dir``: merely looking for
    "DejaVu" in the output is not enough, because a config that fails to parse
    makes fontconfig silently fall back to the system default configuration,
    which also has DejaVu.
    """
    fc_match = prefix / "bin" / "fc-match"
    if not fc_match.is_file():
        return
    env = dict(os.environ, FONTCONFIG_FILE=str(conf))
    env.pop("FONTCONFIG_PATH", None)
    r = subprocess.run(
        [str(fc_match), "-f", "%{file}\n", "sans-serif"],
        capture_output=True,
        text=True,
        env=env,
    )
    resolved = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    inside = bool(resolved) and Path(resolved).is_relative_to(fonts_dir.resolve())
    if r.returncode != 0 or not inside or "error" in r.stderr.lower():
        raise SystemExit(
            f"fc-match self-check failed: rc={r.returncode} resolved={resolved!r} "
            f"err={r.stderr!r}"
        )
    print(f"  fc-match self-check: {resolved}")


def _vacate(dest: Path) -> None:
    """Move dest aside and best-effort delete it (direct rmtree may hit ENOTEMPTY)."""
    if not dest.exists():
        return
    root = Path(__file__).resolve().parent.parent
    stale = root / "target" / f".share-stale-{os.getpid()}"
    stale.parent.mkdir(parents=True, exist_ok=True)
    if stale.exists():
        shutil.rmtree(stale, ignore_errors=True)
    try:
        os.replace(dest, stale)
    except OSError:
        shutil.rmtree(dest)
        return
    shutil.rmtree(stale, ignore_errors=True)


def prepare(prefix: Path, dest: Path) -> None:
    fonts = _find_fonts(prefix)
    config_prefix = Path(os.environ.get("RIASOPY_FONTCONFIG_PREFIX", str(prefix)))
    src_conf = config_prefix / "etc" / "fonts" / "fonts.conf"
    if not src_conf.is_file():
        raise SystemExit(
            f"cannot find {src_conf} (the build environment needs the conda package fontconfig)"
        )

    _vacate(dest)
    (dest / "fonts").mkdir(parents=True)
    ttf = sorted(fonts.glob("*.ttf"))
    for f in ttf:
        shutil.copy2(f, dest / "fonts" / f.name)

    # symlinks=False (default) dereferences the conf.d symlinks into real files
    shutil.copytree(config_prefix / "etc" / "fonts", dest / "etc" / "fonts")
    _rewrite_conf(dest / "etc" / "fonts" / "fonts.conf")
    # Everything is inlined now: drop conf.d entirely so nobody assumes it is read
    # (this also removes the README's build-machine path).
    conf_d = dest / "etc" / "fonts" / "conf.d"
    if conf_d.exists():
        shutil.rmtree(conf_d, ignore_errors=True)
    _self_check(config_prefix, dest / "etc" / "fonts" / "fonts.conf", dest / "fonts")
    print(f"  share generated: {len(ttf)} ttf from {fonts}, config from {config_prefix / 'etc/fonts'}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--prefix",
        default=os.environ.get("CONDA_PREFIX", ""),
        help="build environment prefix (default: $CONDA_PREFIX)",
    )
    ap.add_argument(
        "--dest",
        default=str(Path(__file__).resolve().parent.parent / "python" / "riasopy" / "share"),
        help="output directory (default: python/riasopy/share)",
    )
    ap.add_argument(
        "--clean", action="store_true", help="only remove --dest (build cleanup), do not generate"
    )
    args = ap.parse_args()
    if args.clean:
        _vacate(Path(args.dest))
        print(f"  removed {args.dest}")
        return
    if not args.prefix:
        raise SystemExit("no --prefix given and not inside a conda environment")
    prepare(Path(args.prefix), Path(args.dest))


if __name__ == "__main__":
    main()
