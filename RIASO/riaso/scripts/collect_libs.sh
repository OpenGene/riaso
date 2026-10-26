#!/bin/bash
# Compute the **transitive closure** of a binary's shared libraries under a given prefix (BFS along DT_NEEDED).
#
# Each output line is `<referenced name>|<real path>`:
#   - The name is the one written in DT_NEEDED and **must** be used as-is when installing into dist/lib.
#   - Only libraries found under `$PREFIX/lib` (or lib64) are collected; system libraries
#     (libc/libm/libdl/libpthread/libresolv) are not found there, so they are skipped and stay external.
#
# **Why not parse `ldd` output**: ldd deduplicates by SONAME. conda's `libblas.so.3` and
# `liblapack.so.3` are two symlinks to the same file (`libopenblasp-r0.3.34.so`, whose own SONAME
# is `libopenblas.so.0`), so ldd reports only one of the names -- copying by that name loses
# the other and the program fails at run time with `liblapack.so.3: cannot open shared object file`.
# Resolving name by name along DT_NEEDED never misses one.
#
# Usage: collect_libs.sh <binary> <conda prefix>
set -uo pipefail

BIN="$1"
PREFIX="$2"
LIBDIRS=("$PREFIX/lib" "$PREFIX/lib64")
declare -A seenq
queue=("$BIN")

while [ "${#queue[@]}" -gt 0 ]; do
  cur="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r need; do
    [ -z "$need" ] && continue
    for d in "${LIBDIRS[@]}"; do
      if [ -e "$d/$need" ]; then
        real="$(readlink -f "$d/$need")"
        echo "$need|$real"
        if [ -z "${seenq[$real]:-}" ]; then
          seenq["$real"]=1
          queue+=("$real")              # keep walking its NEEDED
        fi
        break
      fi
    done
  done < <(readelf -d "$cur" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
done
