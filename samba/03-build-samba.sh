#!/usr/bin/env bash
# ============================================================================
# Phase 3 — cross-compile Samba (minimal SMB2/SMB3 file server) with waf.
#
# The hard part: Samba's waf configure RUNS small test binaries to probe the
# target. We can't run SPARC binaries on x86-64 directly, so we point waf at
# qemu-sparc-static via --cross-execute, and cache every answer in
# cross-answers.txt (--cross-answers) for reproducible, offline reruns.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"
. "$HERE/../common.sh"

require_toolchain
mkdir -p "$BUILD"

SAMBA_TARBALL="samba-$SAMBA_VERSION.tar.gz"
# Samba lives under the version's series dir on the mirror.
fetch "https://download.samba.org/pub/samba/stable/$SAMBA_TARBALL"
sdir="$(extract "$DL/$SAMBA_TARBALL" "samba-$SAMBA_VERSION")"

# --- cross env for waf ------------------------------------------------------
export CC="$TARGET-gcc"
export AR="$TARGET-ar"
export RANLIB="$TARGET-ranlib"
export NM="$TARGET-nm"
# STATIC + NON-PIC build. The device's glibc 2.19 dynamic loader crashes on the
# Infrant CPU (confirmed on hardware: a trivial dynamic "hello" segfaults, a
# static one runs), so we link smbd/nmbd/smbpasswd FULLY STATIC and avoid ld.so.
#   -fno-pic/-fno-PIE : NON-PIC codegen. 32-bit SPARC PIC uses a 13-bit GOT
#     offset (R_SPARC_GOT13) that overflows in a binary this large; non-PIC uses
#     absolute addressing (no GOT). MUST match the non-PIC deps.
#   LINKFLAGS=-static : waf's link-flag var (LDFLAGS alone is dropped for the
#     final binary link). Combined with the SHLIB_MARKER patch below, this makes
#     the external libs (gnutls chain, libc, pthread) link from their .a too.
#   -latomic : 32-bit SPARC v7 needs libatomic for the __atomic_*_4 helpers.
export CFLAGS="$TARGET_CFLAGS -fno-pic -fno-PIE -I$DEP_PREFIX/include"
export LDFLAGS="-L$DEP_PREFIX/lib -latomic"
# Compile the NSS "force files" shim (samba/nssfix.c) and link it into every
# binary. Its constructor calls __nss_configure_lookup before main() so
# getpwnam/getgrnam use the compiled-in 'files' service — the device's
# nsswitch.conf uses 'compat', which a static binary cannot load.
mkdir -p "$BUILD"
"$TARGET-gcc" $TARGET_CFLAGS -fno-pic -c "$HERE/nssfix.c" -o "$BUILD/nssfix.o"
# Emulate the *at() syscall family (openat/fstatat/unlinkat/...). The Infrant
# 2.6.17 kernel does NOT implement them (confirmed on hardware: SYS_openat ->
# ENOSYS), but Samba 4.13's whole VFS is built on them, so every file/dir open
# fails -> the client sees NT_STATUS_NOT_SUPPORTED. atshim.c provides strong
# definitions that override glibc's and fall back to the classic non-*at calls
# via /proc/self/fd/<dirfd>. Proven on-device with attest.c before wiring here.
"$TARGET-gcc" $TARGET_CFLAGS -fno-pic -c "$HERE/atshim.c" -o "$BUILD/atshim.o"
export LINKFLAGS="-static $BUILD/nssfix.o $BUILD/atshim.o"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$DEP_PREFIX/lib/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PYTHON="$(command -v python3)"     # host python drives waf itself
# Samba runs target-built code generators (asn1_compile, compile_et) DIRECTLY
# during the build — not via --cross-execute. With a SPARC binfmt_misc handler
# registered (run.sh does this), the kernel routes those SPARC binaries through
# qemu-sparc-static; QEMU_LD_PREFIX tells qemu where the target sysroot is so it
# can resolve their interpreter + libc. Without this the build dies with
# "asn1_compile: Exec format error".
export QEMU_LD_PREFIX="$SYSROOT"

# qemu wrapper so waf can execute target test binaries. -L gives qemu the
# sysroot to resolve the target's shared libs (glibc, gnutls, …).
CROSS_EXECUTE="qemu-sparc-static -L $SYSROOT"

# Persist the answers file inside the repo (so a clean rebuild is offline).
ANSWERS="$HERE/cross-answers.txt"
touch "$ANSWERS"

cd "$sdir"

# --- source patch: tolerate a non-ENOENT opendir() on the modules dir --------
# lib/util/modules.c:load_modules() opendir()s $MODULESDIR/<subsystem> and, on
# ANY failure, returns NULL. Every caller (rpc/vfs/auth/... setup) treats that
# as fatal UNLESS errno==ENOENT ("dir absent => all modules static, fine").
# On the 2.6.17 ReadyNAS opendir() of the absent dir returns ENOSYS, not ENOENT,
# so smbd aborts: "Loading shared DCE/RPC modules failed [Function not
# implemented] ... Samba cannot setup ep pipe". This build is FULLY STATIC with
# --with-static-modules=ALL, so there are never any shared modules to load and
# an opendir() failure is always benign. Return the empty (non-NULL) array
# instead of NULL so callers see "no shared modules" regardless of errno.
if ! grep -q 'readynas: opendir failure is benign' lib/util/modules.c; then
  log "patching lib/util/modules.c: opendir() failure -> empty module list"
  python3 - <<'PYEOF'
import io
p = "lib/util/modules.c"
s = open(p).read()
old = ("\tdir = opendir(path);\n"
       "\tif (dir == NULL) {\n"
       "\t\ttalloc_free(ret);\n"
       "\t\treturn NULL;\n"
       "\t}\n")
new = ("\tdir = opendir(path);\n"
       "\tif (dir == NULL) {\n"
       "\t\t/* readynas: opendir failure is benign in a fully-static build\n"
       "\t\t * (no shared modules exist). Some old kernels report ENOSYS\n"
       "\t\t * rather than ENOENT for the absent dir; return the empty array\n"
       "\t\t * so callers checking errno!=ENOENT don't treat it as fatal. */\n"
       "\t\treturn ret;\n"
       "\t}\n")
assert old in s, "modules.c load_modules opendir block not found (Samba layout changed?)"
open(p, "w").write(s.replace(old, new, 1))
PYEOF
fi

# Configure is skipped on reruns (fast incremental build) UNLESS RECLAIM=1 or
# there's no prior configure. The post-configure patches below (SHLIB_MARKER,
# config.h undefs) are re-applied every run regardless — they're idempotent and
# waf rebuilds whatever they touch.
if [ "${RECLAIM:-0}" = "1" ] || [ ! -f bin/c4che/default_cache.py ]; then
  [ -d bin ] && rm -rf bin
  python3 ./buildtools/bin/waf distclean >/dev/null 2>&1 || true
  DO_CONFIGURE=1
else
  log "incremental build (prior configure kept; set RECLAIM=1 to force clean)"
  DO_CONFIGURE=0
fi

if [ "$DO_CONFIGURE" = "1" ]; then
log "Phase 3: configuring Samba $SAMBA_VERSION (cross, qemu-assisted)"
# Minimal SMB2/SMB3 file server: no AD DC, no winbind, no python bindings.
# --without-pie / --without-relro: Samba hardens binaries into position-
# independent executables (ET_DYN), but the 2.6.17-era SPARC kernel mishandles
# PIE and segfaults them at startup (stock RAIDiator binaries are plain
# ET_EXEC). Building non-PIE ET_EXEC binaries is what actually runs on-device.
python3 ./buildtools/bin/waf configure \
  --cross-compile \
  --cross-execute="$CROSS_EXECUTE" \
  --cross-answers="$ANSWERS" \
  --hostcc="cc" \
  --prefix="$PREFIX" \
  --sysconfdir="$PREFIX/etc" \
  --localstatedir="$PREFIX/var" \
  --with-privatedir="$PREFIX/private" \
  --bundled-libraries=ALL \
  --with-static-modules='ALL,!vfs_snapper' \
  --nonshared-binary='smbd/smbd,nmbd,smbpasswd' \
  --without-pie \
  --without-relro \
  --without-ad-dc \
  --without-ads \
  --without-ldap \
  --without-pam \
  --without-systemd \
  --without-acl-support \
  --without-json \
  --without-libarchive \
  --without-regedit \
  --without-ntvfs-fileserver \
  --disable-python
  # NOTE: only options verified to exist in Samba 4.13's waf are passed here
  # (waf ABORTS on unknown options).
fi   # end DO_CONFIGURE

# --- static-link patches (must run AFTER configure) -------------------------
# 1. waf wraps external libs in SHLIB_MARKER (-Wl,-Bdynamic), which flips the
#    linker back to dynamic mode and defeats -static. Flip it to -Bstatic so the
#    gnutls chain / libc / pthread link from their .a. (gnutls's own deps are
#    folded into gnutls.pc Libs: by the deps phase so they resolve in order.)
log "patching waf SHLIB_MARKER -> -Wl,-Bstatic (force fully-static link)"
for f in bin/c4che/*.py; do
  [ -f "$f" ] || continue
  sed -i "s/SHLIB_MARKER = .*/SHLIB_MARKER = ['-Wl,-Bstatic']/" "$f"
  # Ensure nssfix.o + atshim.o are in the cached LINKFLAGS. waf captures
  # LINKFLAGS at configure time, so on an incremental relink (no reconfigure)
  # the env change above wouldn't take — inject them directly. Idempotent.
  grep -q "nssfix.o" "$f" || \
    sed -i "s|LINKFLAGS = \['-static'|LINKFLAGS = ['-static', '$BUILD/nssfix.o'|" "$f"
  grep -q "atshim.o" "$f" || \
    sed -i "s|LINKFLAGS = \['-static'|LINKFLAGS = ['-static', '$BUILD/atshim.o'|" "$f"
done
# 2. Samba builds its heimdal code generators (asn1_compile/compile_et) as target
#    binaries and runs them during the build. If any come out dynamic they need
#    interpreter /usr/lib/ld.so.1; give qemu that path under the sysroot.
ln -sf ../../lib/ld-linux.so.2 "$SYSROOT/usr/lib/ld.so.1" 2>/dev/null || true

# 3. CROSS-COMPILE KERNEL-FEATURE FIX. Samba's configure probes run under qemu,
#    which reports the *host* kernel (6.10), so it enabled syscalls the device's
#    2.6.17 kernel lacks. They link (glibc 2.19 has the wrappers) but ENOSYS at
#    runtime — e.g. tevent's eventfd() wakeup makes smbd panic "failed to setup
#    SIGTERM handler". Undefine the too-new ones in every generated config.h;
#    Samba/libreplace/tevent then take their portable fallbacks (eventfd->pipe,
#    accept4->accept+fcntl, epoll_create1->epoll_create, …). Everything below
#    was added to Linux AFTER 2.6.17.
log "undefining post-2.6.17 syscall macros in config.h (cross-compile saw host kernel 6.10)"
# Confirmed MISSING on the device by dist/hwtest/hwsyscall. Most were already
# 'absent' in Samba's config (its configure/libreplace picked the portable
# variants: accept/epoll_create/pipe/inotify_init, all present on 2.6.17). The
# ones that WERE enabled and had to be turned off: eventfd (the SIGTERM panic),
# fallocate, utimensat, and HAVE_LINUX_SPLICE (splice() — smbd's recvfile; it
# has a runtime fallback but we disable it cleanly). The absent names below are
# harmless no-ops, kept so a future clean build stays correct.
_too_new='HAVE_EVENTFD HAVE_SIGNALFD HAVE_EPOLL_CREATE1 HAVE_PIPE2 HAVE_ACCEPT4
          HAVE_DUP3 HAVE_INOTIFY_INIT1 HAVE_TIMERFD_CREATE HAVE_FALLOCATE
          HAVE_UTIMENSAT HAVE_LINUX_SPLICE'
while IFS= read -r cfg; do
  for m in $_too_new; do
    sed -i "s|^#define $m 1\$|/* $m disabled: not in kernel 2.6.17 */|" "$cfg"
  done
done < <(find bin -name config.h)

log "building Samba static (only the on-device binaries: smbd, nmbd, smbpasswd) …"
# Build ONLY the nonshared binaries. A full build would also link the tool
# binaries (smbstatus, net, …) which stay shared and would fail under -static.
python3 ./buildtools/bin/waf build --targets=smbd/smbd,nmbd,smbpasswd -j"$(nproc)"

# --- manual static install (waf install won't do a --targets subset) --------
log "installing static binaries into staging ($STAGE)"
rm -rf "$STAGE$PREFIX"
mkdir -p "$STAGE$PREFIX/sbin" "$STAGE$PREFIX/bin" "$STAGE$PREFIX/etc" "$STAGE$PREFIX/var" "$STAGE$PREFIX/private"
cp -a bin/default/source3/smbd/smbd "$STAGE$PREFIX/sbin/smbd"
cp -a bin/default/source3/nmbd/nmbd "$STAGE$PREFIX/sbin/nmbd"
# smbpasswd lives under source3/utils
sp="$(find bin/default -type f -name smbpasswd | head -1)"
[ -n "$sp" ] && cp -a "$sp" "$STAGE$PREFIX/bin/smbpasswd" || warn "smbpasswd binary not found"

# --- verify the produced binary is static + the right machine ---------------
smbd_bin="$STAGE$PREFIX/sbin/smbd"
[ -x "$smbd_bin" ] || die "smbd not found at $smbd_bin — check the build log above"
log "smbd: $(file "$smbd_bin")"
file "$smbd_bin" | grep -qi 'SPARC' || warn "smbd is NOT SPARC — cross env leaked host cc?"
file "$smbd_bin" | grep -qi 'MSB\|big.endian' || warn "smbd is NOT big-endian"
if "$TARGET-readelf" -l "$smbd_bin" 2>/dev/null | grep -q INTERP; then
  warn "smbd is DYNAMIC (has an interpreter) — the static link did not take; it will crash on-device"
else
  log "smbd is STATIC (no interpreter) — good"
fi

# Staged install captured in $STAGE and verified — the Samba build tree (the
# largest scratch in the pipeline) is now disposable. Keep $DL's tarball so a
# rerun re-extracts without downloading.
cd "$HERE"
reclaim "$sdir"

log "Phase 3 complete. cross-answers cached at $ANSWERS ($(wc -l <"$ANSWERS") lines)"
