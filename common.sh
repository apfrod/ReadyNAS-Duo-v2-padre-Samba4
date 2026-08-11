# ============================================================================
# common.sh — shared helpers. Source AFTER config.env:
#     . "$(dirname "$0")/../config.env"   # (path varies per script)
#     . "$(dirname "$0")/../common.sh"
# ============================================================================

# Colored, timestamped logging ------------------------------------------------
_ts() { date +'%H:%M:%S'; }
# All logging goes to STDERR so helpers like extract() can return a value on
# STDOUT via command substitution without the log lines polluting it.
log()  { printf '\033[1;34m[%s] ==>\033[0m %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '\033[1;33m[%s] !! \033[0m %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] XX \033[0m %s\n' "$(_ts)" "$*" >&2; exit 1; }

# Stamp helpers — make each phase idempotent/resumable ------------------------
stamped()   { [ -f "$STAMP/$1" ]; }
stamp()     { mkdir -p "$STAMP"; : > "$STAMP/$1"; log "stamped: $1"; }
unstamp()   { rm -f "$STAMP/$1"; }

# Download to $DL (cached). Usage: fetch <url> [outfile] ----------------------
fetch() {
  url="$1"; out="${2:-$DL/$(basename "$url")}"
  mkdir -p "$DL"
  if [ -s "$out" ]; then log "cached $(basename "$out")"; return 0; fi
  log "downloading $url"
  # -L follow redirects, --fail on 4xx/5xx, retry a few times
  curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url" \
    || die "download failed: $url"
  mv "$out.part" "$out"
}

# Extract a tarball into $SRC and echo the resulting top-level dir -------------
# Usage: srcdir=$(extract <tarball> [expected-dirname])
extract() {
  tarball="$1"; want="${2:-}"
  mkdir -p "$SRC"
  case "$tarball" in
    *.tar.gz|*.tgz)  taropt=xzf ;;
    *.tar.bz2)       taropt=xjf ;;
    *.tar.xz)        taropt=xJf ;;
    *) die "unknown archive type: $tarball" ;;
  esac
  # Determine top dir from the archive itself so version bumps just work.
  top="$want"
  [ -n "$top" ] || top=$(tar tf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -n "$top" ] || die "cannot determine top dir of $tarball"
  if [ ! -d "$SRC/$top" ]; then
    log "extracting $(basename "$tarball")"
    tar "$taropt" "$tarball" -C "$SRC" || die "extract failed: $tarball"
  fi
  printf '%s\n' "$SRC/$top"
}

# Cross-build environment for autotools-based deps (Phase 2) ------------------
export_cross_env() {
  export CC="$TARGET-gcc"
  export CXX="$TARGET-g++"
  export AR="$TARGET-ar"
  export AS="$TARGET-as"
  export LD="$TARGET-ld"
  export RANLIB="$TARGET-ranlib"
  export STRIP="$TARGET-strip"
  export NM="$TARGET-nm"
  # -fno-pic/-fno-PIE: force NON-PIC codegen. On 32-bit SPARC, PIC uses a 13-bit
  # GOT offset (R_SPARC_GOT13) that overflows when everything is statically
  # linked into one large binary; non-PIC uses absolute addressing (no GOT).
  export CFLAGS="$TARGET_CFLAGS -fno-pic -fno-PIE -I$DEP_PREFIX/include"
  export CXXFLAGS="$CFLAGS"
  # rpath points at the on-device self-contained lib dir. (No --dynamic-linker:
  # it breaks qemu cross-execute and the device uses a launcher wrapper anyway.)
  # -latomic: 32-bit SPARC v7 has no inline atomic ops, so gcc emits calls to
  # __atomic_*_4 helpers that live in libatomic; without it, gnutls.so ends up
  # with undefined __atomic_fetch_add_4/sub_4 and Samba's --no-undefined link
  # fails. libatomic.so.1 is bundled at package time.
  export LDFLAGS="-L$DEP_PREFIX/lib -Wl,-rpath,$PREFIX/lib -latomic"
  # pkg-config must only see the sysroot, never the host.
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_LIBDIR="$DEP_PREFIX/lib/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
}

# Make the cross toolchain visible on PATH ------------------------------------
add_toolchain_to_path() {
  case ":$PATH:" in
    *":$TOOLCHAIN_DIR/bin:"*) ;;
    *) export PATH="$TOOLCHAIN_DIR/bin:$PATH" ;;
  esac
}

# Reclaim disposable build scratch AFTER a phase has succeeded ----------------
# Call ONLY once the work that produced the durable output (toolchain, sysroot
# libs, staged install) is done and verified — reaching the call under
# `set -e` already implies the step succeeded.
#
# Cleanup is OPT-IN. By DEFAULT the build KEEPS all source + caches so reruns
# are fast/incremental; reclaim() only deletes when RECLAIM=1 (use that for a
# space-constrained clean build). (KEEP_SCRATCH=1 is still honored as a
# belt-and-suspenders "never reclaim" override.)
#
# Guards (defensive, so a mis-set variable can't wipe anything that matters):
# each path must be absolute, contain no "..", live strictly inside a scratch
# root ($BUILD/$SRC), and not overlap a durable tree (toolchain / sysroot /
# deps prefix / stage / dist / downloads).
reclaim() {
  if [ "${RECLAIM:-0}" != "1" ] || [ "${KEEP_SCRATCH:-0}" = "1" ]; then
    return 0
  fi
  local path
  for path in "$@"; do
    [ -n "$path" ] || continue
    case "$path" in
      /*) : ;;                       # must be absolute
      *)  warn "reclaim: refusing non-absolute path '$path'"; continue ;;
    esac
    case "$path" in
      *..*) warn "reclaim: refusing path with '..': '$path'"; continue ;;
    esac
    # Primary guard: must live under a scratch root.
    case "$path" in
      "$BUILD"/*|"$SRC"/*) : ;;
      *) warn "reclaim: '$path' is not under \$BUILD or \$SRC — skipping"; continue ;;
    esac
    # Secondary guard: never a durable/output tree, even if relocated.
    case "$path" in
      "$TOOLCHAIN_DIR"*|"$SYSROOT"*|"$DEP_PREFIX"*|"$STAGE"*|"$DIST"*|"$DL"*)
        warn "reclaim: '$path' overlaps a protected tree — skipping"; continue ;;
    esac
    [ -d "$path" ] || continue
    log "reclaiming build scratch: $path ($(du -sh "$path" 2>/dev/null | cut -f1) freed)"
    rm -rf "$path" || warn "reclaim: partial cleanup of $path"
  done
}

# Sanity: fail early if the toolchain isn't built yet -------------------------
require_toolchain() {
  add_toolchain_to_path
  command -v "$TARGET-gcc" >/dev/null 2>&1 \
    || die "cross toolchain not found ($TARGET-gcc). Run phase 'toolchain' first."
}
