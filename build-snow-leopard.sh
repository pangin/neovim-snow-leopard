#!/bin/bash
# Build Neovim for Mac OS X 10.6.8 on 32-bit Intel, into $HOME/.local/nvim.
#
#   ./build-snow-leopard.sh deps      bundled dependencies (patched)
#   ./build-snow-leopard.sh nvim      Neovim itself
#   ./build-snow-leopard.sh install   copy into $PREFIX
#   ./build-snow-leopard.sh all       the three above
#   ./build-snow-leopard.sh status
#   ./build-snow-leopard.sh distclean
#
# Run from the root of this source tree. See SNOW_LEOPARD.md for what each
# patch addresses. No sudo; MacPorts under /opt/local is only read.
set -u

MP=${MP:-/opt/local}
PREFIX=${PREFIX:-$HOME/.local/nvim}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 2)}
SRC=$(cd "$(dirname "$0")" && pwd)
PATCHES=$SRC/snow-leopard/deps-patches
LOG=$SRC/build-snow-leopard.log

export PATH=$MP/bin:$MP/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export MACOSX_DEPLOYMENT_TARGET=10.6
CC=$MP/bin/clang-mp-16
LD=$MP/bin/ld-274
[ -x "$CC" ] || { echo "clang-mp-16 not found; install MacPorts clang-16"; exit 1; }
[ -x "$LD" ] || { echo "ld-274 not found; install MacPorts ld64-274 (needed for -export_dynamic)"; exit 1; }

# LegacySupport back-fills clock_gettime, getentropy, strnlen, getline and
# friends; its headers use #include_next so they must come first.
# UV_NO_SSM / UV_NO_POSIX_SPAWN select libuv's own fallbacks (see patches).
# The -Wno-error restores clang 15 behaviour for the SDK's pre-POSIX-2008
# scandir prototype.
CFLAGS="-arch i386 -I$MP/include/LegacySupport -Wno-error=incompatible-function-pointer-types -DUV_NO_SSM -DUV_NO_POSIX_SPAWN"
LDFLAGS="-arch i386 --ld-path=$LD -L$MP/lib -lMacportsLegacySupport"

CMAKE_COMMON=(
  -G "Unix Makefiles"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=i386
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.6
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_C_FLAGS="$CFLAGS"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
  -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
)

log() { printf '\n>>> %s\n' "$*"; }

# Apply a patch to an extracted dependency once; skipped if already applied.
apply_once() { # apply_once <dir> <patchfile>
  local dir="$1" p="$2"
  [ -d "$dir" ] && [ -f "$p" ] || return 0
  if patch -d "$dir" -p1 -N --dry-run -s < "$p" >/dev/null 2>&1; then
    patch -d "$dir" -p1 -N -s < "$p" && echo "  applied $(basename "$p")"
  else
    echo "  already  $(basename "$p")"
  fi
}

do_deps() {
  log "deps: configure"
  cd "$SRC" || exit 1
  cmake -S cmake.deps -B .deps "${CMAKE_COMMON[@]}" || exit 1

  # First pass downloads and extracts everything and will fail inside luajit
  # and libuv on a pristine tree; that is expected. Then patch and rebuild.
  log "deps: first pass (extracts sources; failures in luajit/libuv are expected)"
  cmake --build .deps -- -j"$JOBS" >"$LOG.deps1" 2>&1 || true

  log "deps: applying Snow Leopard patches to extracted sources"
  # (Neovim's own two in-tree changes, src/nvim/channel.c and src/nvim/os/env.c,
  #  are already committed on this branch; snow-leopard/nvim-patches/ holds
  #  them as diffs for reference.)
  apply_once .deps/build/src/luajit "$PATCHES/luajit-01-o-cloexec.patch"
  apply_once .deps/build/src/libuv  "$PATCHES/libuv-01-udp-ssm-and-msgx.patch"
  apply_once .deps/build/src/libuv  "$PATCHES/libuv-02-fork-exec-spawn.patch"

  # Sub-builds configured before the patches cached their state; redo them.
  for d in luajit libuv; do
    rm -f .deps/build/src/$d-stamp/$d-configure .deps/build/src/$d-stamp/$d-build .deps/build/src/$d-stamp/$d-install
    rm -rf .deps/build/src/$d-build
  done

  log "deps: build"
  cmake --build .deps -- -j"$JOBS" || exit 1
}

do_nvim() {
  log "nvim: configure"
  cd "$SRC" || exit 1
  cmake -S . -B build "${CMAKE_COMMON[@]}" -DCMAKE_INSTALL_PREFIX="$PREFIX" || exit 1
  log "nvim: build"
  cmake --build build -- -j"$JOBS" || exit 1
}

do_install() {
  cd "$SRC" || exit 1
  cmake --install build || exit 1
  log "installed"
  file "$PREFIX/bin/nvim"
  "$PREFIX/bin/nvim" --version | head -3
  "$PREFIX/bin/nvim" --headless -c 'lua print(jit and jit.version or "no luajit")' -c qa 2>&1
}

case "${1:-status}" in
  deps)      do_deps ;;
  nvim)      do_nvim ;;
  install)   do_install ;;
  all)       do_deps && do_nvim && do_install ;;
  status)
    echo "deps  : $( [ -d "$SRC/.deps/usr" ] && ls "$SRC/.deps/usr/lib" 2>/dev/null | tr '\n' ' ' || echo not built )"
    echo "nvim  : $( [ -x "$SRC/build/bin/nvim" ] && echo built || echo not built )"
    echo "prefix: $( [ -x "$PREFIX/bin/nvim" ] && "$PREFIX/bin/nvim" --version | head -1 || echo not installed )"
    ;;
  distclean) rm -rf "$SRC/.deps" "$SRC/build" "$LOG" "$LOG.deps1" ;;
  *) echo "usage: $0 deps|nvim|install|all|status|distclean"; exit 2 ;;
esac
