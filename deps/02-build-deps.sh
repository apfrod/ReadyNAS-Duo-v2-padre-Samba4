#!/usr/bin/env bash
# ============================================================================
# Phase 2 — cross-build Samba's C library dependencies into the sysroot.
# Install prefix = $DEP_PREFIX ($SYSROOT$PREFIX) so pkg-config + headers are
# discoverable when Samba configures, and so rpaths already point at the
# on-device layout ($PREFIX/lib).
#
# Order matters:
#   zlib, popt        (independent)
#   gmp -> nettle
#   libtasn1, libunistring
#   gnutls  (needs nettle, gmp, libtasn1, libunistring)   <-- SMB3 crypto
#
# NOTE: modern Samba (4.12+) does its crypto through GnuTLS, and GnuTLS 3.x
# uses nettle — NOT libgcrypt. So libgcrypt/libgpg-error are deliberately NOT
# built here (they also cross-compile awkwardly: their *-config scripts report
# the runtime prefix, not the sysroot). If a future Samba config genuinely
# needs libgcrypt, add it back with a sysroot-corrected gpgrt-config.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"
. "$HERE/../common.sh"

require_toolchain
export_cross_env

# crosstool-NG marks the finished toolchain (and its sysroot) READ-ONLY to
# protect it. We install our target deps into the sysroot ($DEP_PREFIX =
# $SYSROOT/opt/samba), so restore write permission for ourselves first — this
# also makes the phase safely re-runnable.
if [ -d "$SYSROOT" ] && [ ! -w "$SYSROOT" ]; then
  log "sysroot is read-only (crosstool-NG default) — restoring owner write bit"
  chmod -R u+w "$SYSROOT" 2>/dev/null || warn "could not chmod +w $SYSROOT"
fi

mkdir -p "$DEP_PREFIX/lib" "$DEP_PREFIX/include" "$BUILD"

log "Phase 2: cross-building deps into $DEP_PREFIX"

# Helper: standard autotools cross build. Args: <srcdir> [extra configure args…]
autoconf_build() {
  local srcdir="$1"; shift
  local name; name="$(basename "$srcdir")"
  local b="$BUILD/$name"
  rm -rf "$b"; mkdir -p "$b"; cd "$b"
  log "configure $name"
  # NON-PIC static archives only. The fully-static Samba link needs .a (the
  # device's glibc 2.19 dynamic loader is broken, so everything links static).
  # Crucially --disable-shared makes libtool build NON-PIC objects: on 32-bit
  # SPARC, PIC code uses a 13-bit GOT offset (R_SPARC_GOT13) that OVERFLOWS in a
  # binary this large ("relocation truncated to fit"). Non-PIC uses absolute
  # addressing (no GOT), sidestepping the limit.
  "$srcdir/configure" \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --enable-static --disable-shared --with-pic=no \
    "$@"
  # CCPIC= : nettle's Makefile force-appends CCPIC (-fpic) to its crypto/ECC
  # objects, which overrides our -fno-pic and reintroduces R_SPARC_GOT13. The
  # command-line override wins; harmless for packages that don't use CCPIC.
  make -j"$(nproc)" CCPIC=
  # Install into the sysroot staging prefix (not the real $PREFIX on host).
  make install DESTDIR="$SYSROOT" CCPIC=
  cd "$HERE"
  reclaim "$b"          # per-package build tree is scratch once installed
}

# ---- zlib (its configure is bespoke, not autotools) ------------------------
fetch "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz"
zdir="$(extract "$DL/zlib-$ZLIB_VERSION.tar.gz")"
( b="$BUILD/zlib"; rm -rf "$b"; cp -a "$zdir" "$b"; cd "$b"
  # --static: non-PIC libz.a only (see the SPARC GOT13 note in autoconf_build).
  CHOST="$TARGET" ./configure --prefix="$PREFIX" --static
  # zlib 1.2.13's configure probes for --no-warn-rwx-segments by COMPILING
  # (not linking), so it wrongly bakes this binutils-2.39 flag into the
  # Makefile even though our ld is 2.38 and rejects it. Strip it out.
  sed -i 's/ *-Wl,--no-warn-rwx-segments//g' Makefile
  make -j"$(nproc)"
  make install DESTDIR="$SYSROOT" )
reclaim "$BUILD/zlib"

# ---- popt ------------------------------------------------------------------
fetch "http://ftp.rpm.org/popt/releases/popt-1.x/popt-$POPT_VERSION.tar.gz"
autoconf_build "$(extract "$DL/popt-$POPT_VERSION.tar.gz")" --disable-nls

# ---- gmp -------------------------------------------------------------------
fetch "https://gmplib.org/download/gmp/gmp-$GMP_VERSION.tar.xz"
# CRITICAL: --disable-assembly. GMP's SPARC asm targets v8 (hardware umul/smul,
# integer divide) which the Infrant v7 core does NOT implement — using it would
# emit illegal instructions. Generic C is correct (if slower).
autoconf_build "$(extract "$DL/gmp-$GMP_VERSION.tar.xz")" \
  --disable-assembly --enable-cxx=no ABI=32

# ---- nettle (needs gmp) ----------------------------------------------------
fetch "https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VERSION.tar.gz"
# --disable-fat: no runtime CPU-dispatch (which forces PIC .o and pulls in
# R_SPARC_GOT13). Combined with --disable-shared this yields non-PIC archives.
autoconf_build "$(extract "$DL/nettle-$NETTLE_VERSION.tar.gz")" \
  --with-include-path="$DEP_PREFIX/include" \
  --with-lib-path="$DEP_PREFIX/lib" \
  --disable-documentation --disable-assembler --disable-fat

# ---- libtasn1 --------------------------------------------------------------
fetch "https://ftp.gnu.org/gnu/libtasn1/libtasn1-$LIBTASN1_VERSION.tar.gz"
autoconf_build "$(extract "$DL/libtasn1-$LIBTASN1_VERSION.tar.gz")" --disable-doc

# ---- libunistring ----------------------------------------------------------
fetch "https://ftp.gnu.org/gnu/libunistring/libunistring-$LIBUNISTRING_VERSION.tar.gz"
autoconf_build "$(extract "$DL/libunistring-$LIBUNISTRING_VERSION.tar.gz")"

# ---- gnutls (SMB2/3 signing + encryption) ----------------------------------
fetch "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.6/gnutls-$GNUTLS_VERSION.tar.xz"
autoconf_build "$(extract "$DL/gnutls-$GNUTLS_VERSION.tar.xz")" \
  --with-included-libtasn1=no \
  --with-included-unistring=no \
  --without-p11-kit \
  --without-tpm \
  --without-idn \
  --disable-hardware-acceleration \
  --disable-doc --disable-tests --disable-tools \
  --disable-nls --disable-cxx \
  GMP_CFLAGS="-I$DEP_PREFIX/include" GMP_LIBS="-L$DEP_PREFIX/lib -lgmp" \
  NETTLE_CFLAGS="-I$DEP_PREFIX/include" NETTLE_LIBS="-L$DEP_PREFIX/lib -lnettle -lgmp" \
  HOGWEED_CFLAGS="-I$DEP_PREFIX/include" HOGWEED_LIBS="-L$DEP_PREFIX/lib -lhogweed -lnettle -lgmp" \
  LIBTASN1_CFLAGS="-I$DEP_PREFIX/include" LIBTASN1_LIBS="-L$DEP_PREFIX/lib -ltasn1"

log "Phase 2 complete. Sanity check gnutls presence:"
ls -1 "$DEP_PREFIX/lib/"libgnutls* "$DEP_PREFIX/lib/pkgconfig/gnutls.pc" 2>/dev/null \
  || die "gnutls did not install into $DEP_PREFIX — Samba configure will fail"

# For the STATIC Samba link, Samba reads gnutls.pc's `Libs:` (not Libs.private),
# so it only sees -lgnutls and the static link is missing gnutls's own deps
# (libtasn1/nettle/hogweed/gmp/unistring). Fold the full chain into `Libs:` so
# they link in the correct order.
gpc="$DEP_PREFIX/lib/pkgconfig/gnutls.pc"
if [ -f "$gpc" ] && ! grep -q -- '-lhogweed' "$gpc"; then
  log "folding gnutls static dep chain into gnutls.pc Libs:"
  sed -i 's|^Libs: .*|Libs: -L${libdir} -lgnutls -lhogweed -lnettle -lgmp -ltasn1 -lunistring -latomic|' "$gpc"
fi
log "deps installed under $DEP_PREFIX (static, non-PIC)"
