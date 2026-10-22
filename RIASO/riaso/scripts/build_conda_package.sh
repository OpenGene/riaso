#!/bin/bash
# Pack the self-contained `dist/` distribution directory into **a single conda package** (a .conda file).
# Nothing is installed: the only artifact is dist-conda/riaso-<ver>-<build>.conda, and no conda
# environment is touched or required. Installing it somewhere is a separate, explicit step.
#
# Division of labour with build_binary.sh: that one produces the movable dist/, this one rearranges
# dist/ into a conda environment layout, adds the conda metadata, and packs it into a .conda file.
# So build_binary.sh must have run (this script invokes it itself; it is idempotent and takes ~20s when
# no crate changed).
#
# ## Why the layout is rearranged
#
# dist/'s entry point is the top-level `dist/riaso` (the launcher) and the real ELF lives in
# `dist/bin/riaso`. But in a conda environment `bin/` holds **the commands the user types**, i.e.
# `bin/riaso` itself must be the entry point, so the ELF moves to `libexec/riaso` and `bin/riaso` becomes
#
# an environment-flavoured launcher:
#
#   $PREFIX/bin/riaso              <- launcher (just type `riaso` after activation)
#   $PREFIX/libexec/riaso          <- the real ELF, RPATH is still $ORIGIN/../lib
#   $PREFIX/lib/*.so*              <- the 24 bundled shared libraries
#   $PREFIX/fonts/*.ttf            <- the bundled full DejaVu family
#   $PREFIX/etc/fonts/             <- the bundled fontconfig configuration (<dir> is still prefix="relative")
#   $PREFIX/var/cache/fontconfig/  <- font cache directory (left empty, written at run time)
#
# The ELF's RPATH is untouched (`$ORIGIN/../lib` means `dist/lib` in dist and `$PREFIX/lib` in the
# environment -- the two are isomorphic), and so is `../../fonts` in the font configuration -- hence
# **no relinking is needed**.
#
# The launcher is self-locating rather than an `etc/conda/activate.d` hook (conda's native way of
# setting FONTCONFIG_FILE): the latter only takes effect in an **activated** environment, whereas the
# package can just as well be invoked by absolute path, unactivated, exec'd by another script. A
# self-locating launcher holds in both cases.
#
# Usage: ./scripts/build_conda_package.sh
set -euo pipefail

# --- Locate and initialise conda (no hard-coded install prefix) ---
# Order: $CONDA_EXE -> conda on PATH -> common per-user install locations (all relative to $HOME).
# `conda activate` is a shell function, so `conda shell.bash hook` must be evaluated; finding the
# executable alone is not enough.
CONDA_BIN="${CONDA_EXE:-}"
[ -x "$CONDA_BIN" ] || CONDA_BIN="$(type -P conda || true)"
if [ -z "$CONDA_BIN" ]; then
  for _cand in "${HOME:-}/miniconda3/bin/conda" "${HOME:-}/anaconda3/bin/conda" \
               "${HOME:-}/miniforge3/bin/conda" "${HOME:-}/mambaforge/bin/conda"; do
    if [ -x "$_cand" ]; then CONDA_BIN="$_cand"; break; fi
  done
  unset _cand
fi
if [ -z "$CONDA_BIN" ]; then
  echo "✘ conda not found: add it to PATH, or set CONDA_EXE=/path/to/conda" >&2
  exit 1
fi
if _hook="$("$CONDA_BIN" shell.bash hook 2>/dev/null)"; then
  eval "$_hook"
else
  _conda_sh="$(cd "$(dirname "$CONDA_BIN")/.." && pwd)/etc/profile.d/conda.sh"
  if [ -f "$_conda_sh" ]; then source "$_conda_sh"; else
    echo "✘ $CONDA_BIN has no shell.bash hook and $_conda_sh does not exist" >&2
    exit 1
  fi
fi
unset CONDA_BIN _hook _conda_sh
conda activate riaso          # the build environment (see ../environment-linux.yml); also provides cph / fc-match / patchelf
cd "$(dirname "$0")/.."

NAME=riaso
VER="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
BUILD=0
OUT_DIR="$PWD/dist-conda"
STAGE="$OUT_DIR/stage"
PKG_NAME="$NAME-$VER-$BUILD"
PKG="$OUT_DIR/$PKG_NAME.conda"

# --- 1. Make sure dist/ is up to date first ---
echo "=== 1/4 build the self-contained dist/ ==="
./scripts/build_binary.sh
echo ""

# --- 2. Rearrange into a conda environment layout ---
echo "=== 2/4 assemble the conda package contents ==="
rm -rf "$OUT_DIR"
mkdir -p "$STAGE"/{bin,libexec,lib,fonts,etc,var/cache/fontconfig}
# Note: var/cache/fontconfig is empty and conda cannot pack empty directories, so it will not exist
# after the package is installed -- fontconfig creates it lazily when it writes the cache, which is
# harmless. (The old install-into-env step used to mkdir it afterwards; there is no install step now.)

cp dist/bin/riaso        "$STAGE/libexec/riaso"      # move the ELF as-is (RPATH untouched)
# -a is required: libblas.so.3 is a symlink to liblapack.so.3 and a plain `cp` would dereference it
# into a second 41 MB copy of openblas (pushing both the package's and the environment's lib from
# 71 MB to 113 MB).
cp -a dist/lib/*         "$STAGE/lib/"
cp dist/fonts/*.ttf      "$STAGE/fonts/"
cp -rL dist/etc/fonts    "$STAGE/etc/fonts"
chmod +x "$STAGE/libexec/riaso"

# Environment-flavoured launcher: the parent of bindir is $PREFIX and the ELF is in libexec/.
cat > "$STAGE/bin/riaso" <<'SH'
#!/bin/sh
# riaso launcher (conda environment flavour) -- no environment variable needs to be set and conda
# activate is not required.
#
# Layout ($PREFIX = the parent directory of the bin/ holding this script):
#   $PREFIX/bin/riaso        this launcher
#   $PREFIX/libexec/riaso    the real ELF, RPATH = $ORIGIN/../lib
#   $PREFIX/lib/*.so*        bundled shared libraries (self-contained, no conda/system dependency)
#   $PREFIX/fonts/*.ttf      bundled DejaVu fonts
#   $PREFIX/etc/fonts/       bundled fontconfig configuration
#
# It does exactly one thing: point the real binary at the bundled fontconfig configuration through
# FONTCONFIG_FILE so plotters can find the DejaVu fonts on any machine (shipped with this package,
# guaranteeing bit-identical rendering across machines). No other environment variable is touched; uses
# shell builtins only (cd / pwd / command), works even with an empty PATH.
self=$0
case $self in
  */*) ;;
  *) self=$(command -v -- "$self" 2>/dev/null) || self=$0 ;;
esac
if command -v readlink >/dev/null 2>&1; then
  rl=$(readlink -f -- "$self" 2>/dev/null) && [ -n "$rl" ] && self=$rl
fi
bindir=${self%/*}
[ "$bindir" = "$self" ] && bindir=.
bindir=$(CDPATH= cd -- "$bindir" && pwd -P) || exit 1
prefix=${bindir%/*}

FONTCONFIG_FILE="$prefix/etc/fonts/fonts.conf"
export FONTCONFIG_FILE

exec "$prefix/libexec/riaso" "$@"
SH
chmod +x "$STAGE/bin/riaso"

# --- 3. conda metadata ---
# Write only the three things conda actually reads at install time: index.json (identity), files
# (the file list) and paths.json (sha256/size of every file, recorded into conda-meta for verify).
# **Do not write info/has_prefix**: every path inside the package is a self-locating relative path,
# there is no text needing prefix substitution, and listing it would only make conda rewrite paths
# inside the launcher.
mkdir -p "$STAGE/info"
cat > "$STAGE/info/index.json" <<EOF
{"name": "$NAME", "version": "$VER", "build": "$BUILD", "build_number": $BUILD,
 "subdir": "linux-64", "depends": [], "license": "MIT",
 "summary": "RIASO - spatial transcriptomics pipeline (self-contained binary: shared libraries and fonts)"}
EOF

cat > "$STAGE/info/about.json" <<'EOF'
{"description": "RIASO self-contained distribution: the riaso binary + all non-system shared libraries + DejaVu fonts + fontconfig configuration.",
 "license": "MIT", "summary": "Spatial transcriptomics pipeline (self-contained binary)"}
EOF

# The paths.json field name is `_path` (not `path`) -- conda's PathData._path has no alias, so a wrong
# name raises a ValidationError during "Preparing transaction".
# Symlink entries follow the conda-forge convention: path_type="softlink" with sha256/size_in_bytes
# taken from the **target file** (libcurl/bzip2 and others do exactly this), so opening with open()
# here and following the link is correct.
python3 - "$STAGE" <<'PY'
import hashlib, json, os, sys
stage = sys.argv[1]
files, paths = [], []
for root, dirs, fns in os.walk(stage):
    if os.path.basename(root) == 'info' or '/info' in root:
        continue
    for fn in sorted(fns):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, stage)
        files.append(rel)
        with open(full, 'rb') as fh:
            data = fh.read()
        paths.append({"_path": rel,
                      "path_type": "softlink" if os.path.islink(full) else "hardlink",
                      "sha256": hashlib.sha256(data).hexdigest(),
                      "size_in_bytes": len(data)})
files.sort()
open(os.path.join(stage, 'info', 'files'), 'w').write('\n'.join(files) + '\n')
json.dump({"paths_version": 1, "paths": paths},
          open(os.path.join(stage, 'info', 'paths.json'), 'w'), indent=2)
n_link = sum(1 for p in paths if p['path_type'] == 'softlink')
print(f"  file list: {len(files)} entries ({n_link} symlinks)")
PY

# --- 4. Self-check: run against STAGE, before packing ---
# STAGE already has the $PREFIX layout (bin/riaso launcher + libexec/riaso + lib/ + fonts/ + etc/fonts/)
# and the launcher derives $PREFIX from its own location, so the checks that used to be run against an
# installed environment run verbatim against STAGE. Nothing needs to be installed to produce them.
echo ""
echo "=== 3/4 self-check ==="
fail=0
if cmp -s dist/bin/riaso "$STAGE/libexec/riaso"; then
  echo "  ✓ libexec/riaso is byte-identical to dist/bin/riaso"
else
  echo "  ✘ the ELF differs from dist"; fail=1
fi

# libblas.so.3 / liblapack.so.3 are a "real file + symlink" pair; dereferencing them at any step of
# packing or installing pushes lib from 71 MB to 113 MB. At least one must stay a symlink.
if [ -L "$STAGE/lib/libblas.so.3" ] || [ -L "$STAGE/lib/liblapack.so.3" ]; then
  echo "  ✓ the openblas alias in lib is still a symlink"
else
  echo "  ✘ the symlink was dereferenced into two real files (+41 MB)"; fail=1
fi
n_lib=$(find "$STAGE/lib" -maxdepth 1 -type f | wc -l)
echo "  lib/: $(ls -1 "$STAGE/lib" | wc -l) entries ($n_lib real files), $(find "$STAGE/lib" -maxdepth 1 -type f -printf '%s\n' | awk '{s+=$1} END{printf "%.1f MB", s/1048576}') total"

nf=$(env -i ldd "$STAGE/libexec/riaso" 2>/dev/null | grep -c 'not found' || true)
fr=$(env -i ldd "$STAGE/libexec/riaso" 2>/dev/null | grep -cF "$CONDA_PREFIX/lib/" || true)
echo "  shared libs not found: $nf     from the build env: $fr     (both should be 0)"
[ "$nf" = "0" ] && [ "$fr" = "0" ] || fail=1

if env -i "$STAGE/bin/riaso" -V >/dev/null 2>&1; then
  echo "  ✓ bin/riaso -V works under env -i (zero environment variables)"
else
  echo "  ✘ launcher failed"; fail=1
fi
ver=$(env -i "$STAGE/bin/riaso" -V 2>/dev/null | head -1)

FCM="$CONDA_PREFIX/bin/fc-match"
if [ -x "$FCM" ]; then
  got=$(env -i FONTCONFIG_FILE="$STAGE/etc/fonts/fonts.conf" "$FCM" -v sans-serif 2>/dev/null \
        | sed -n 's/.*file: "\(.*\)".*/\1/p' | head -1)
  case "$got" in
    "$STAGE"/fonts/*) echo "  ✓ sans-serif -> ${got#$STAGE/}" ;;
    *) echo "  ✘ sans-serif resolved outside the package: $got"; fail=1 ;;
  esac
fi

[ "$fail" = "0" ] || { echo ""; echo "✘ self-check failed -- the package was NOT created"; exit 1; }

# --- 5. Pack ---
echo ""
echo "=== 4/4 create the conda package ==="
cph create "$STAGE" "$PKG" >/dev/null
echo "  $PKG  ($(find "$PKG" -printf '%s\n' | awk '{printf "%.1f MB", $1/1048576}'))"
rm -rf "$STAGE"   # intermediate directory (~72 MB), rebuildable from dist/ at any time

echo ""
echo "✔ Done. The conda package is ready (nothing was installed):"
echo "  $PKG"
echo "  $ver"
echo "  Install it with: conda install -n <env> --offline $PKG"
echo "  (the package declares no dependencies; the target environment is yours to create)"
