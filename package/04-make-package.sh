#!/usr/bin/env bash
# ============================================================================
# Phase 4 — assemble the on-device /opt/samba tree and tar it up.
#
# Auto-detects how Samba was linked:
#   * STATIC  (current default): smbd/nmbd are fully static ELF executables with
#     no interpreter. Nothing to bundle, no loader wrapper — the binaries are
#     self-contained. This is required because the device's glibc 2.19 dynamic
#     loader crashes on the Infrant CPU (a dynamic "hello" segfaults; a static
#     one runs).
#   * DYNAMIC (legacy path): bundle our loader + glibc + dep .so and launch each
#     binary through a wrapper that uses the private loader.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"
. "$HERE/../common.sh"

TREE="$STAGE$PREFIX"                 # staged Samba install from Phase 3
[ -d "$TREE" ] || die "no staged Samba at $TREE — run phase 'samba' first"

mkdir -p "$TREE/etc" "$TREE/var" "$TREE/private"

# --- Detect static vs dynamic from the smbd binary --------------------------
SMBD="$TREE/sbin/smbd"
[ -f "$SMBD" ] || SMBD="$TREE/sbin/smbd.real"     # (dynamic rerun leaves smbd as wrapper)
[ -f "$SMBD" ] || die "smbd not found under $TREE/sbin"
if "$TARGET-readelf" -l "$SMBD" 2>/dev/null | grep -q 'INTERP'; then
  MODE=dynamic
else
  MODE=static
fi
log "Phase 4: packaging from $TREE  (linkage: $MODE)"

if [ "$MODE" = dynamic ]; then
  # ---- DYNAMIC: bundle loader + glibc + dep libs, wrap binaries -------------
  mkdir -p "$TREE/lib"
  copy_lib() {
    local name="$1" found=0 f real
    for d in "$SYSROOT/lib" "$SYSROOT/usr/lib"; do
      f="$d/$name"; [ -e "$f" ] || continue
      cp -a "$f" "$TREE/lib/"; found=1
      if [ -L "$f" ]; then
        real="$d/$(readlink "$f")"; [ -e "$real" ] && cp -a "$real" "$TREE/lib/"
      fi
      break
    done
    [ "$found" -eq 1 ] || warn "runtime lib not found in sysroot: $name"
  }
  log "bundling loader + glibc runtime + gcc runtime"
  for l in ld-linux.so.2 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 \
           libresolv.so.2 librt.so.1 libnss_files.so.2 libnss_dns.so.2 \
           libcrypt.so.1 libatomic.so.1 libgcc_s.so.1; do copy_lib "$l"; done
  log "bundling dependency libraries"
  [ -d "$DEP_PREFIX/lib" ] && \
    find "$DEP_PREFIX/lib" -maxdepth 1 -name '*.so*' -exec cp -a {} "$TREE/lib/" \;

  install_wrapper() {   # idempotent: mv real ELF aside once, then (re)write wrapper
    local dir="$1" name="$2" real="$TREE/$dir/$name"
    if [ ! -f "$TREE/$dir/$name.real" ]; then
      [ -x "$real" ] || return 0
      mv "$real" "$TREE/$dir/$name.real"
    fi
    sed -e "s#@PREFIX@#$PREFIX#g" -e "s#@BINREL@#$dir/$name.real#g" \
        "$HERE/files/launcher.template" > "$real"
    chmod +x "$real"
  }
  log "installing launcher wrappers"
  for n in smbd nmbd smbpasswd; do install_wrapper sbin "$n"; done
  for n in smbclient smbcontrol smbstatus testparm net; do install_wrapper bin "$n"; done
else
  # ---- STATIC: nothing to bundle or wrap; binaries are self-contained -------
  # Drop the (unused) shared Samba libs Samba still installs, to shrink the tree.
  log "static build — pruning unused shared libs"
  [ -d "$TREE/lib/private" ] && find "$TREE/lib/private" -name '*.so*' -delete 2>/dev/null || true
  find "$TREE/lib" -maxdepth 1 -name '*.so*' -delete 2>/dev/null || true
fi

# --- Config + init + share skeleton -----------------------------------------
cp "$HERE/files/smb.conf.template" "$TREE/etc/smb.conf"
mkdir -p "$TREE/etc/init.d"
sed "s#@PREFIX@#$PREFIX#g" "$HERE/files/S91samba" > "$TREE/etc/init.d/S91samba"
chmod +x "$TREE/etc/init.d/S91samba"

# --- Strip binaries to save space -------------------------------------------
log "stripping binaries"
if [ "$MODE" = dynamic ]; then
  find "$TREE" -type f \( -name '*.real' -o -name '*.so*' \) -print0 \
    | xargs -0 -r "$TARGET-strip" --strip-unneeded 2>/dev/null || true
else
  # strip the actual executables (smbd/nmbd/… in sbin+bin) and any leftover .so
  for d in sbin bin; do
    [ -d "$TREE/$d" ] && find "$TREE/$d" -type f -exec "$TARGET-strip" --strip-unneeded {} + 2>/dev/null || true
  done
fi

# --- Tar it up --------------------------------------------------------------
mkdir -p "$DIST"
OUT="$DIST/samba4-${SAMBA_VERSION}-sparc-opt.tar.gz"
( cd "$STAGE" && tar czf "$OUT" ".$PREFIX" )
log "package: $OUT"
log "size: $(du -h "$OUT" | cut -f1)"

# --- Host-side smoke test under qemu ----------------------------------------
log "smoke test under qemu-sparc-static ($MODE):"
if [ "$MODE" = dynamic ]; then
  SMOKE=( qemu-sparc-static -L "$SYSROOT" "$TREE/lib/ld-linux.so.2"
          --library-path "$TREE/lib:$TREE/lib/private" "$TREE/sbin/smbd.real" --version )
else
  SMOKE=( qemu-sparc-static "$TREE/sbin/smbd" --version )
fi
if "${SMOKE[@]}" >/tmp/smbd-ver.txt 2>&1; then
  log "  smbd --version => $(head -1 /tmp/smbd-ver.txt)"
else
  warn "  qemu smoke test failed — inspect /tmp/smbd-ver.txt (may still run on real hw)"
fi
log "Phase 4 complete."
