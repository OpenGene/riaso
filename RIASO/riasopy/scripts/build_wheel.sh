#!/bin/bash
# Build an x86_64 Linux wheel requiring glibc 2.28 or newer.

set -euo pipefail

# Build natively on the supported baseline; a newer host would raise the ABI.
if [ "$(getconf GNU_LIBC_VERSION)" != "glibc 2.28" ]; then
  echo "Build inside quay.io/pypa/manylinux_2_28_x86_64 (glibc 2.28 required)." >&2
  exit 1
fi

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
# Build environment and runtime environment are separate: riasopy-build has
# maturin/gcc/hdf5 etc., while riasopy only has the installed wheel (no maturin).
# Override with RIASOPY_ENV if needed.
ENV_NAME="${RIASOPY_ENV:-riasopy-build}"
conda activate "$ENV_NAME"
echo "  build environment: $ENV_NAME ($(command -v python))"
cd "$(dirname "$0")/.."

# --- 1. Let pkg-config locate conda's hdf5 ---
# conda-forge's hdf5 ships no .pc file, so maturin cannot find libhdf5 while resolving the external
# .so dependencies during packaging (cargo check does not link, so it stays invisible there).
# Add one idempotently.
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
pkg-config --exists hdf5 && echo "  hdf5 located (pkg-config)" || { echo "  pkg-config still cannot find hdf5"; exit 1; }

# --- 2. Distribution-safe compile options ---
# Use unset rather than export RUSTFLAGS="": cargo treats them as different
# fingerprints and mixing them forces a full rebuild of the dependency tree
# (both are the same baseline: no target-cpu/target-feature).
unset RUSTFLAGS
echo "RUSTFLAGS unset (baseline x86-64, no AVX-512/AVX2 leakage)"

# --- 3. Assemble the runtime font assets ---
# The source tree does not store share/ (that used to be a copy of the binary
# dist and could drift from the build environment): generate it from the build
# environment's fontconfig + font-ttf-dejavu, and delete it right after maturin.
python scripts/prepare_share.py
# Let the script clean up: on this network FS rm -rf hits ENOTEMPTY, so it
# renames the directory into target/ first and deletes it there.
trap 'python scripts/prepare_share.py --clean; echo "  removed python/riasopy/share (source tree stays clean)"' EXIT

# --- 4. Build ---
# maturin hard-links the cargo artifact and auditwheel repair rewrites it in
# place; restore the sonames before a second build in the same target directory.
python scripts/heal_artifact.py
maturin build --release --locked --compatibility manylinux_2_28

# --- 5. Collapse the extension module's RPATH to $ORIGIN/../riasopy.libs ---
# maturin writes the build environment's $CONDA_PREFIX/lib into the RPATH;
# dropping it is what makes the wheel truly self-contained.
WHEEL=$(ls -t target/wheels/riasopy-*manylinux_2_28_x86_64*.whl | sed -n '1p')
python scripts/fix_wheel_rpath.py "$WHEEL"

echo ""
echo "Done. The wheel is in:"
ls -la target/wheels/riasopy-*.whl
