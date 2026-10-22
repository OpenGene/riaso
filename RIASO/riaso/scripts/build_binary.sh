#!/bin/bash
# One-shot build of a **self-contained** riaso distribution directory (runs on any x86_64 Linux, no environment setup).
#
# Structurally identical to riasopy/scripts/build_wheel.sh: the same distribution-safe compile
# options and an equivalent conda environment (providing the .pc and .so for hdf5 / arpack) --
# but a **separate** one, `riaso` (see ../environment-linux.yml), not riasopy's. The other
# difference is the artifact: a wheel there, a directly movable `dist/` directory here.
#
# Artifact layout:
#   dist/riaso                      <- launcher (sh, the only entry point)
#   dist/bin/riaso                  <- the real ELF, RPATH = $ORIGIN/../lib
#   dist/lib/*.so*                  <- 24 non-system shared libraries, RPATH = $ORIGIN
#   dist/fonts/*.ttf                <- the full DejaVu family (22 files)
#   dist/etc/fonts/                 <- fontconfig configuration tree (relative <dir>; conf.d inlined into fonts.conf)
#   dist/var/cache/fontconfig/      <- font cache directory (left empty, written at run time)
#
# Why the launcher is needed: plotters' ttf backend resolves `("sans-serif", n)` through
# font-kit, which goes through **fontconfig** -- and this machine (like any clean compute node)
# has **no /usr/share/fonts**, so fonts exist only in the conda environment's fonts/. With conda hidden,
# the pipeline was measured to **hard-fail**:
#   riaso: failed to draw the QC plot: backend error: Font loading error: No such font: sans-serif normal
# So the fonts and the configuration are bundled together and the launcher points the binary at them
# via FONTCONFIG_FILE. (plotters' ab_glyph embedded-font backend was rejected: its draw implementation
# is entirely different from the ttf backend, so switching would change the **text pixels of every single
# plot** and invalidate every already-accepted figure.) The configuration keeps only in-package fonts and
# **excludes system directories such as /usr/share/fonts** -- so rendering is bit-identical across machines
# (measured: 122/125 byte-identical against the conda-fontconfig build; the only differences are the three

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
conda activate riaso
cd "$(dirname "$0")/.."

# known noise sources generated_at / out_root / UMAP floats).
#
# --- 1. Let pkg-config locate conda's hdf5 ---
# conda-forge's hdf5 ships no .pc file, so the link step cannot find libhdf5. Add one idempotently.
# (cargo check does not link, so a missing file stays invisible there; only a real link exposes it.)
export HDF5_DIR="${HDF5_DIR:-$CONDA_PREFIX}"
PC_DIR="$CONDA_PREFIX/lib/pkgconfig"
PC="$PC_DIR/hdf5.pc"
if [ ! -f "$PC" ]; then
  echo "  hdf5.pc not found, generating it -> $PC"
  mkdir -p "$PC_DIR"
  cat > "$PC" <<EOF
prefix=${CONDA_PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: hdf5
Description: HDF5 (without high-level)
Version: 1.14.6
Requires:
Libs: -L\${libdir} -lhdf5
Cflags: -I\${includedir}
EOF
fi
pkg-config --exists hdf5 && echo "  ✓ hdf5 located (pkg-config)" || { echo "  ✘ pkg-config still cannot find hdf5"; exit 1; }

# --- 2. Distribution-safe compile options ---
# Baseline x86-64, no AVX-512/AVX2 leakage: the release artifact must run on any x86_64 machine,
# and binding native CPU features (AVX2/FMA) at compile time would SIGILL on older CPUs.
# rustc's default target-cpu for x86_64-unknown-linux-gnu is already this baseline.
#
# Note the use of `unset` rather than `export RUSTFLAGS=""`: cargo treats "RUSTFLAGS is set (even to
# the empty string)" and "not set" as **different fingerprints**, so setting it empty explicitly makes
# a bin that needs no byte changed redo the whole ~11-minute fat-LTO link.
if [ -n "${RUSTFLAGS:-}" ]; then
  echo "  ⚠ ignoring external RUSTFLAGS='${RUSTFLAGS}' (release builds are pinned to baseline x86-64)"
  unset RUSTFLAGS
fi
echo "RUSTFLAGS not set (= baseline x86-64, no AVX-512/AVX2 leakage)"

# --- 3. Put the target directory under the project ---
# Default: ./target (i.e. riaso/target), so build artifacts stay next to the sources instead of vanishing
# from /dev/shm on reboot. Still overridable from the outside: CARGO_TARGET_DIR=/somewhere ./scripts/build_binary.sh
# Caveat: if this repo lives on a network filesystem (NFS, ...), override this and point it at
# local disk -- linking artifacts above ~800MB deadlocks in kernel space (ofs_sem_down) there. The release
# binary is ~21MB, but intermediate rlibs / test binaries reach the GB range.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"
echo "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"

# --- 4. Build ---
cargo build --release --bin riaso

PATCHELF="$CONDA_PREFIX/bin/patchelf"
[ -x "$PATCHELF" ] || { echo "  ✘ patchelf not found ($PATCHELF)"; exit 1; }

# --- 5. Assemble the skeleton ---
rm -rf dist
mkdir -p dist/bin dist/lib dist/fonts dist/etc dist/var/cache/fontconfig
cp "$CARGO_TARGET_DIR/release/riaso" dist/bin/riaso
chmod +x dist/bin/riaso

# --- 6. Bundle the shared libraries (the key to self-containment) ---
# Walk the DT_NEEDED transitive closure rather than parsing ldd's output: ldd deduplicates by SONAME,
# so it reports only one name for libblas.so.3 / liblapack.so.3 (two symlinks to the same openblas
# file), and copying by that name necessarily loses the other. See the comments in collect_libs.sh.
echo ""
echo "Collecting shared libraries..."
declare -A real_of_name   # referenced name -> real path
while IFS='|' read -r nm real; do
  [ -z "${nm:-}" ] && continue
  real_of_name["$nm"]="$real"
done < <("$(dirname "$0")/collect_libs.sh" dist/bin/riaso "$CONDA_PREFIX")

declare -A name_of_real   # real path -> first name copied (one copy per file, the rest are symlinks)
for nm in "${!real_of_name[@]}"; do
  real="${real_of_name[$nm]}"
  if [ -n "${name_of_real[$real]:-}" ]; then
    ln -sf "${name_of_real[$real]}" "dist/lib/$nm"   # liblapack.so.3 -> libblas.so.3, saves 41MB
  else
    cp "$real" "dist/lib/$nm"
    name_of_real["$real"]="$nm"
  fi
done
echo "  dist/lib: $(ls -1 dist/lib | wc -l) entries"

# --- 7. RPATH ---
# --force-rpath keeps DT_RPATH (not DT_RUNPATH): $ORIGIN expands in both, but RPATH also takes
# part in the lookup of dependencies-of-dependencies, which is simpler for a bundle.
$PATCHELF --force-rpath --set-rpath '$ORIGIN/../lib' dist/bin/riaso
for f in dist/lib/*; do
  [ -f "$f" ] || continue
  [ -L "$f" ] && continue
  # The copied libraries carry a conda-forge `$ORIGIN/.` relative RPATH (relocatable);
  # rewrite them all to `$ORIGIN` (= dist/lib itself) to be safe.
  $PATCHELF --force-rpath --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

# --- 8. Fonts + fontconfig configuration tree ---
cp "$CONDA_PREFIX"/fonts/*.ttf dist/fonts/
cp -rL "$CONDA_PREFIX/etc/fonts" dist/etc/fonts   # -L: dereference the conf.d symlinks into real files
python3 - dist/etc/fonts/fonts.conf <<'PY'
import glob, os, re, shutil, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# Drop every absolute <dir>/<cachedir> (/usr/share/fonts, conda's share/fonts and fonts, xdg,
# ~/.fonts, ...) -- keep only in-package fonts so rendering is consistent across machines.
s = re.sub(r'\n\t*<dir[^>]*>.*?</dir>', '', s)
s = re.sub(r'\n\t*<cachedir[^>]*>.*?</cachedir>', '', s)
# prefix="relative" only works for <dir> (verified: it resolves against the directory of this
# configuration file). It has **no effect** on <cachedir>: that one is resolved against the
# run-time cwd, so every start prints "Fontconfig error: No writable cache directories" plus a
# build-machine absolute path. Do not emit a <cachedir> line at all; fontconfig falls back to its
# default cache location and font resolution is unaffected.
s = s.replace('\n<!-- Font directory list -->\n',
              '\n<!-- Font directory list -->\n\t<dir prefix="relative">../../fonts</dir>\n')
#
# Nor keep <include ...>conf.d</include>: prefix="relative" is equally ineffective for <include>,
# which resolves against libfontconfig's **compile-time CONFIGDIR** (the build machine's conda
# path); elsewhere it fails to resolve and echoes that path. Inline conf.d/*.conf in file-name
# order instead, then delete the conf.d directory -- the package then has nothing that depends
# on a build-machine path.
#
# Note: a comment may precede the root <fontconfig> element, so its removal must
# **not** be anchored with ^. Leaving it unbalanced makes fontconfig fail to parse
# and **silently fall back to the system default configuration** (the self-check
# then resolves a font outside the package).
cdir = os.path.join(os.path.dirname(p), 'conf.d')
body = []
for f in sorted(glob.glob(os.path.join(cdir, '*.conf'))):
    t = open(f, encoding='utf-8').read()
    t = re.sub(r'<\?xml.*?\?>', '', t, flags=re.S)
    t = re.sub(r'<!DOCTYPE[^>]*>', '', t)
    t = re.sub(r'<fontconfig(\s[^>]*)?>', '', t, count=1)
    t = re.sub(r'</fontconfig>\s*$', '', t)
    t = '\n'.join(ln for ln in t.splitlines() if '<include' not in ln)
    body.append('<!-- inlined conf.d/%s -->\n%s' % (os.path.basename(f), t.strip('\n')))
s = re.sub(r'\n\t*<include[^>]*>conf\.d</include>', '\n' + '\n'.join(body), s)
if '<include' in s:
    raise SystemExit('fonts.conf still contains <include>, which resolves via the build CONFIGDIR')
open(p, 'w', encoding='utf-8').write(s)
shutil.rmtree(cdir, ignore_errors=True)
PY
echo "  dist/fonts: $(ls -1 dist/fonts/*.ttf | wc -l) ttf; dist/etc/fonts: $(find dist/etc/fonts -type f | wc -l) files"

# --- 9. Launcher ---
# Uses shell builtins only (cd / pwd / command); works even with an empty PATH.
cat > dist/riaso <<'SH'
#!/bin/sh
# riaso self-contained launcher -- no environment variable needs to be set.
#
# It does exactly one thing: locate its own directory and point the real binary at the bundled
# fontconfig configuration (relative paths, movable as a whole) via FONTCONFIG_FILE, so plotters can
# find the DejaVu fonts **on any machine** (shipped with this distribution, no dependency on
# /usr/share/fonts, guaranteeing bit-identical rendering across machines).
# No other environment variable is touched.
#
# Uses shell builtins only (cd / pwd / command); works even with an empty PATH.
self=$0
case $self in
  */*) ;;
  *) self=$(command -v -- "$self" 2>/dev/null) || self=$0 ;;
esac
if command -v readlink >/dev/null 2>&1; then
  rl=$(readlink -f -- "$self" 2>/dev/null) && [ -n "$rl" ] && self=$rl
fi
here=${self%/*}
[ "$here" = "$self" ] && here=.
here=$(CDPATH= cd -- "$here" && pwd -P) || exit 1

FONTCONFIG_FILE="$here/etc/fonts/fonts.conf"
export FONTCONFIG_FILE

exec "$here/bin/riaso" "$@"
SH
chmod +x dist/riaso

# --- 10. Self-check: runs with zero environment variables and does not depend on conda ---
echo ""
echo "Self-check (env -i, zero environment variables)..."
fail=0
nf=$(env -i ldd dist/bin/riaso 2>/dev/null | grep -c 'not found' || true)
fromenv=$(env -i ldd dist/bin/riaso 2>/dev/null | grep -c "$CONDA_PREFIX" || true)
echo "  shared libs not found: $nf     from conda env: $fromenv     (both should be 0)"
[ "$nf" = "0" ] && [ "$fromenv" = "0" ] || { env -i ldd dist/bin/riaso | grep -E 'not found|'"$CONDA_PREFIX"; fail=1; }

if env -i ./dist/riaso -V >/dev/null 2>&1; then echo "  ✓ ./dist/riaso -V works under env -i"; else echo "  ✘ launcher failed"; fail=1; fi

# Fonts: the resolution result must land inside dist/fonts
FCM="$CONDA_PREFIX/bin/fc-match"
if [ -x "$FCM" ]; then
  fc() { env -i FONTCONFIG_FILE="$PWD/dist/etc/fonts/fonts.conf" "$FCM" -f '%{file}\n' sans-serif; }
  got=$(fc 2>/dev/null | tail -1)
  fcerr=$(fc 2>&1 >/dev/null)
  case "$got" in
    "$PWD"/dist/fonts/*) echo "  ✓ sans-serif -> ${got#$PWD/}" ;;
    *) echo "  ✘ sans-serif resolved outside the package: $got"; fail=1 ;;
  esac
  # If the config fails to parse, fontconfig silently falls back to the system default
  # configuration, so stderr must also be checked for "Fontconfig error".
  case "$fcerr" in
    *"Fontconfig error"*) echo "  ✘ Fontconfig error (config did not parse?): $fcerr"; fail=1 ;;
    "") ;;
    *) echo "  ⚠ fontconfig warning: $fcerr" ;;
  esac
fi

echo ""
echo "✔ Done. Self-contained distribution directory:"
# Do not use `du -sh`: on a network filesystem two consecutive reads of the same directory
# can differ 20-fold; and do not use `cat lib/*` (it expands the liblapack.so.3 symlink and counts the
# same openblas file twice, adding 41MB).
size_of() { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.1f MB", s/1048576}'; }
printf "  %-8s %s\n" "bin"   "$(size_of dist/bin)"
printf "  %-8s %s\n" "lib"   "$(size_of dist/lib)"
printf "  %-8s %s\n" "fonts" "$(size_of dist/fonts)"
printf "  %-8s %s\n" "etc"   "$(size_of dist/etc)"
printf "  %-8s %s\n" "total" "$(size_of dist)"
echo "Usage: copy the whole dist/ to the target machine and run ./riaso ... (no environment setup needed)"
[ "$fail" = "0" ] && echo "" && echo "sha256(bin/riaso) = $(sha256sum dist/bin/riaso | cut -d' ' -f1)" || exit 1
