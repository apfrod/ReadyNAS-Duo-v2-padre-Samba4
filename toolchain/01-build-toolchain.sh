#!/usr/bin/env bash
# ============================================================================
# Phase 1 — build the SPARC v7 cross-toolchain with crosstool-NG.
# Output: $TOOLCHAIN_DIR/bin/$TARGET-gcc  and a full sysroot with glibc 2.19.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"
. "$HERE/../common.sh"

log "Phase 1: SPARC cross-toolchain ($TARGET, cpu=$TARGET_CPU, glibc $GLIBC_VERSION, kver $KERNEL_HEADERS)"

# --- 1a. Kernel headers ------------------------------------------------------
# We use crosstool-NG's PACKAGED 2.6.32 headers (CT_LINUX_V_2_6_32 in the
# defconfig), not a custom 2.6.17 tarball: kernel 2.6.17 has no
# `make headers_install` target (added in 2.6.18), so ct-ng can't install it.
# glibc's minimum kernel is pinned to 2.6.17 in the defconfig, so the result
# still runs on the device. Nothing to pre-stage here.

# --- 1b. Build/obtain crosstool-NG ------------------------------------------
CTNG_PREFIX="$BUILD/ctng-$CTNG_VERSION"   # on the state volume, not the repo
CTNG="$CTNG_PREFIX/bin/ct-ng"
if [ ! -x "$CTNG" ]; then
  fetch "https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-$CTNG_VERSION/crosstool-ng-$CTNG_VERSION.tar.xz"
  ctsrc="$(extract "$DL/crosstool-ng-$CTNG_VERSION.tar.xz")"
  log "building crosstool-NG $CTNG_VERSION"
  ( cd "$ctsrc" && ./configure --prefix="$CTNG_PREFIX" && make -j"$(nproc)" && make install )
fi
export PATH="$CTNG_PREFIX/bin:$PATH"

# --- 1c. Materialize the defconfig with real absolute paths -----------------
CTDIR="$BUILD/ctng-work"
mkdir -p "$CTDIR"
# Copy the defconfig and inject runtime paths so ct-ng writes the toolchain
# where the rest of the pipeline expects it.
cp "$HERE/crosstool-ng.defconfig" "$CTDIR/defconfig"
{
  echo "CT_PREFIX_DIR=\"$TOOLCHAIN_DIR\""
  echo "CT_LOCAL_TARBALLS_DIR=\"$DL\""
} >> "$CTDIR/defconfig"

# --- 1d. Configure + build ---------------------------------------------------
cd "$CTDIR"
cp defconfig defconfig.ct    # ct-ng reads a file literally named "defconfig"
log "ct-ng defconfig  (reconcile with 'ct-ng menuconfig' if symbols differ)"
"$CTNG" defconfig DEFCONFIG=defconfig || {
  warn "ct-ng defconfig reported issues — some symbols may have been renamed"
  warn "in crosstool-NG $CTNG_VERSION. Run: (cd $CTDIR && $CTNG menuconfig)"
}

# --- 1c-bis. Pre-seed flaky companion tarballs ------------------------------
# crosstool-NG builds host companion libs (zlib, gmp, mpfr, …) and downloads
# them itself. zlib's upstream mirrors are unreliable (zlib.net removes old
# releases; the SourceForge mirror serves redirects ct-ng's wget mishandles).
# ct-ng checks CT_LOCAL_TARBALLS_DIR ($DL) FIRST, so drop a known-good copy of
# the exact version it wants there. Version is read from the generated .config
# so it stays correct across crosstool-NG bumps.
ZLIBV="$(sed -n 's/^CT_ZLIB_VERSION="\(.*\)"/\1/p' "$CTDIR/.config" 2>/dev/null || true)"
if [ -n "$ZLIBV" ] && [ ! -s "$DL/zlib-$ZLIBV.tar.gz" ] && [ ! -s "$DL/zlib-$ZLIBV.tar.xz" ]; then
  log "pre-seeding zlib $ZLIBV for crosstool-NG (upstream mirror is flaky)"
  fetch "https://zlib.net/fossils/zlib-$ZLIBV.tar.gz" "$DL/zlib-$ZLIBV.tar.gz" \
    || warn "could not pre-seed zlib $ZLIBV — ct-ng may fail to fetch it"
fi

log "ct-ng build  (this is the long one: fetches + builds binutils/gcc/glibc)"
# CT_JOBS via env; keep 1 spare core.
export CT_JOBS="${CT_JOBS:-$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))}"
"$CTNG" build

# --- 1e. Verify --------------------------------------------------------------
add_toolchain_to_path
command -v "$TARGET-gcc" >/dev/null 2>&1 || die "toolchain build did not produce $TARGET-gcc"

log "toolchain built: $("$TARGET-gcc" -dumpversion) at $TOOLCHAIN_DIR"
# Confirm codegen target: compile a trivial object and inspect the ELF header.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo 'int main(void){return 0;}' > "$tmp/t.c"
"$TARGET-gcc" $TARGET_CFLAGS -c "$tmp/t.c" -o "$tmp/t.o"
file "$tmp/t.o" | grep -qi 'SPARC' || warn "object is not SPARC?! check $TARGET-gcc"
file "$tmp/t.o" | grep -qi 'MSB\|big.endian' || warn "object is not big-endian?! check CT_ARCH_BE"
log "codegen check: $(file "$tmp/t.o")"

# Toolchain verified — reclaim the (multi-GB) crosstool-NG build scratch.
# Keeps $TOOLCHAIN_DIR (the toolchain) and $CTNG_PREFIX (ct-ng itself, so a
# rerun skips rebuilding it) and $DL (tarball cache).
reclaim "$CTDIR/.build"
